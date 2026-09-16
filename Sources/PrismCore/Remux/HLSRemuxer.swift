import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// Stream-copies one video stream plus **every viable audio stream** out of any
/// container libavformat can demux, into HLS-fMP4 on disk — segmenting with our
/// own `FMP4SegmentWriter` (the `hls` muxer is absent from MPVKit's libavformat
/// build; see that type's doc) and writing the playlists ourselves.
///
/// This is the v0 producer: it starts at the head of the source and runs to
/// EOF, growing EVENT playlists AVPlayer can start playing immediately.
/// Cuts happen only at video keyframes at-or-after each `segmentSeconds`
/// boundary, so every segment opens decodable on its own (what the playlist's
/// `EXT-X-INDEPENDENT-SEGMENTS` promises). Because it *stream-copies*, the
/// bits AVPlayer receives are the source's own: an EAC3+JOC (Atmos) track
/// stays object audio all the way to HDMI, and HDR metadata rides the
/// untouched HEVC bitstream.
///
/// Audio is the one place where "stream-copy" isn't the whole story: codecs
/// AVPlayer's fMP4 path can't take (TrueHD, DTS-HD MA, MP3, Opus, …) are routed
/// through `AudioBridge`, which decodes and re-encodes them to EAC3 so surround
/// survives (phase 3). Copyable audio never touches the bridge.
///
/// Text subtitles are carried too (phase 6), but never into the fMP4: their
/// packets go to `SubtitleRenditionSet`, which converts them to segmented WebVTT
/// renditions cut on these same boundaries. Bitmap subtitles are skipped — the
/// probe reports them so the host can draw its own overlay.
///
/// ## Two output shapes, and when each is used
///
/// - **Renditions** (the normal shape). The variant carries video only, and
///   each audio track becomes an HLS alternate rendition with its own segment
///   writer, playlist and subdirectory (`audio0/…`, `audio1/…`), wrapped by a
///   `master.m3u8`. This is what makes track switching possible at all: a
///   selectable audio group only exists in a master playlist.
/// - **Muxed** (the v0 shape, kept as the fallback). One audio track is muxed
///   into the video's own segments and the media playlist is served directly.
///   Used whenever a master playlist would be *dishonest or refused* — the
///   source has no derivable `CODECS` string (HEVC or H.264 with Annex-B
///   extradata), its dynamic range can't be declared to this display, or Dolby
///   Vision Profile 5 meets a non-DV display. Renditions live in the master, so
///   no master means the audio has to ride inside the variant or not at all;
///   falling back to v0's single muxed track is strictly better than serving
///   silence.
///
/// Phase 4 added two edits to the otherwise byte-for-byte video copy, neither of
/// which touches picture data:
///
/// - The `hvcC` is normalized into the form a `hvc1` sample entry has to have
///   (`HVCCNormalizer`). This happens **twice**, on purpose: on the input
///   extradata, which decides which parameter sets exist at all, and again on the
///   produced init segment, because the muxer rebuilds the record when it writes
///   the sample entry and leaves `array_completeness = 0` under a `hvc1` name.
/// - A Dolby Vision Profile 7 source has its RPUs converted to 8.1 with the
///   enhancement layer dropped (`DolbyVisionRPUConverter`), so a dual-layer file
///   Apple can't decode arrives as a single-layer one it can.
final class HLSRemuxer: @unchecked Sendable {
    let residentSegments = ResidentSegmentStore()
    let audioDeliveryStore = AudioDeliveryStore()
    var audioDelaySeconds: Double = 0
    var coordinatedHTTP = false
    private let activeGuardLock = NSLock()
    private var activeGuard: ReadInterruptGuard?

    /// How a selected audio stream reaches the output.
    enum AudioRouteMode: Equatable {
        /// Bits pass through untouched (AAC/AC3/EAC3/FLAC/ALAC, Atmos included).
        case streamCopy
        /// Decoded and re-encoded to EAC3 by `AudioBridge`.
        case bridge
        /// Decoded, centre-favoured by `DialogueBoostFilter`, re-encoded to
        /// EAC3 — an EXTRA rendition derived from a track that also ships as
        /// its own copy/bridge rendition. This exists because the host-side
        /// alternative doesn't: AVFoundation ignores `audioMix` (and so every
        /// `MTAudioProcessingTap`) on an HLS item, which is what this engine
        /// serves, so the only place dialogue can be lifted is before the mux.
        case boost(DialogueBoostLevel)

        var dialogueBoostLevel: DialogueBoostLevel? {
            if case .boost(let level) = self { return level }
            return nil
        }
    }

    struct AudioRoute: Equatable {
        let index: Int32
        let mode: AudioRouteMode
    }

    /// One audio stream as the routing decision sees it. Deliberately a plain
    /// value so the decision itself is pure and testable without a demuxer.
    struct AudioCandidate: Equatable {
        let index: Int32
        let codecID: AVCodecID
        /// The container's own claim that this track is the film's original
        /// soundtrack (`AV_DISPOSITION_ORIGINAL`).
        ///
        /// Rarely set, and worth a great deal when it is: it is a statement
        /// about the film rather than about the encode, and it is the only
        /// language signal a library can read without asking a metadata
        /// service what language the picture was shot in.
        var isOriginal: Bool = false
        /// The container's own default flag (`AV_DISPOSITION_DEFAULT`).
        ///
        /// Weaker than it looks, which is why it sits low in `chooseAudio`'s
        /// order: a market-specific disc puts its dub first and flags it
        /// default, so trusting this above all else is what opens an English
        /// film in Russian.
        var isDefault: Bool = false

        init(index: Int32, codecID: AVCodecID, isOriginal: Bool = false, isDefault: Bool = false) {
            self.index = index
            self.codecID = codecID
            self.isOriginal = isOriginal
            self.isDefault = isDefault
        }
    }

    /// What the produced presentation looks like — decided once, before the
    /// first packet, because both the muxer layout and the served URL depend
    /// on it. See the type's doc for the reasoning.
    enum OutputShape: Equatable {
        /// Video-only variant plus one rendition per route, behind a master.
        case renditions([AudioRoute])
        /// v0: the one audio track (if any) muxed into the video's segments.
        case muxed(AudioRoute?)
    }

    enum Failure: Error {
        case noVideoStream
        /// The video codec can't ride AVPlayer's HLS-fMP4 pipeline (VP9,
        /// MPEG-2, …) — the caller should route this source to Prism/libmpv.
        case videoCodecNotNativelyPlayable(String)
    }

    static let masterPlaylistFileName = "master.m3u8"
    static let mediaPlaylistFileName = "index.m3u8"
    static let initFileName = "init.mp4"
    /// One audio group is enough: every rendition is an alternate of the same
    /// programme (see `MasterPlaylistBuilder` on why not one group per codec).
    static let audioGroupID = "aud"

    // The video-copyability question lives in `SourceProbe.isVideoStreamCopyable`.
    // There used to be a second copy of the codec set here; it had no readers, and
    // an unread duplicate of a rule is exactly how the audio sets drifted apart.
    /// Audio that can be stream-copied into fMP4 and decoded (or passed
    /// through) by the system. TrueHD/DTS need the phase-3 bridge.
    private static let copyableAudio: Set<AVCodecID> = [
        AV_CODEC_ID_AAC, AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3,
        AV_CODEC_ID_FLAC, AV_CODEC_ID_ALAC,
    ]

    private let sourceURL: URL
    private let httpHeaders: [String: String]
    private let outputDirectory: URL
    /// Segment length target. 6 s is the HLS-classic default; the keyframe
    /// cadence decides the real cuts.
    private let segmentSeconds: Int
    /// The FIRST segment's target, shorter than the rest: it is the one
    /// `start()` waits for, and under `delay_moov` nothing — not even the
    /// init segment — exists until it is cut. See
    /// `SegmentPlan.defaultFirstSegmentSeconds`.
    private let firstSegmentSeconds: Int
    /// Broadcast after every file the producer lands, so the session's
    /// readiness gate and the provider's pending serves wake on the write
    /// instead of polling for it. `nil` = nobody is listening (tests that
    /// drive the remuxer directly).
    private let landed: ProductionSignal?
    /// Whether the display this session plays to is in (or can enter) the
    /// source's own dynamic range. See `PrismCoreSession` for why the default
    /// is `false`.
    private let displayIsHDRReady: Bool
    private let displayIsDolbyVisionCapable: Bool
    /// Present = demand-driven session (phase 5): plan the segmentation
    /// upfront, publish complete VOD playlists, and re-anchor the producer
    /// wherever the loopback reports AVPlayer is fetching.
    private let demand: DemandCoordinator?
    /// Disk budget for produced segments, planned mode only (`nil` keeps
    /// everything). See `SegmentRetention` for the policy.
    private let segmentCacheBytes: Int?
    /// Skip the renditions shape even when a master is possible — the host's
    /// answer to AVPlayer refusing a master (-11868/-11848/-1002): a fresh
    /// session with the one best audio track muxed into the variant.
    private let forceMuxed: Bool
    /// Dialogue-boost renditions to derive from the DEFAULT audio track, in
    /// the order requested. Empty (the default) produces nothing extra. Only
    /// the renditions shape can carry them — a boost lives in the master's
    /// audio group, and the muxed shape has no master.
    private let dialogueBoost: [DialogueBoostLevel]
    /// Cross-session keyframe map (issue #34): consulted before the plan's
    /// index-load seek, fed by the sequential producer of a source whose own
    /// index couldn't be trusted. `nil` = no persistence, exactly as before.
    private let keyframeCache: KeyframeIndexCache?
    /// The plan's index-load seek budget, passed through to
    /// `SegmentPlan.build`. A knob for tests: a zero budget reproduces the
    /// field shape — the scan bounded out, the index never loaded — on a
    /// local file whose scan would otherwise finish instantly.
    private let indexLoadBudget: Duration
    /// The routing probe's already-open context, when the host passed one.
    /// `run()` consumes it (once) instead of opening the source again; holding
    /// the reference also means an unconsumed one is closed when this remuxer
    /// is released rather than leaked.
    private let probed: ProbedSource?

    /// Set by `cancel()`; checked once per packet in the copy loop.
    private let cancelled = LockedFlag()

    /// Called on the producer thread after each variant segment file lands,
    /// with its index. A test seam: a 30 s fixture produces in milliseconds,
    /// so "cancel mid-file" can only be made deterministic from inside the
    /// cut path. `nil` in production.
    var onSegmentLanded: ((Int) -> Void)?

    /// The WebVTT subtitle renditions produced alongside the fMP4 (phase 6).
    /// Exposed so the session can register external files before the run and
    /// read the produced renditions for the master playlist.
    let subtitles: SubtitleRenditionSet

    /// What the Profile 7 → 8.1 conversion actually did, once the remux has run.
    ///
    /// Written from the copy loop's thread, read by the session's actor, hence the
    /// lock. `nil` for every source that isn't a converted P7.
    ///
    /// This is not diagnostics for their own sake. A P7 source whose RPUs all
    /// failed to convert is indistinguishable at playback from one that converted
    /// cleanly — both play, one as Dolby Vision and one as plain HDR10 — so
    /// without a count the only symptom of a broken conversion is a viewer saying
    /// the DV logo never appeared.
    private let conversionStatsLock = NSLock()

    /// Total compressed bytes read from the SOURCE so far — the sum of packet
    /// sizes the copy loop has pulled through `av_read_frame`. Slightly under
    /// the wire truth (container framing isn't counted), which is the right
    /// side to err on for a stats display. Monotonic; the host differentiates
    /// it into a rate between its own polls.
    private let sourceBytesLock = NSLock()
    private var sourceBytesReadStorage: Int64 = 0

    var sourceBytesRead: Int64 {
        sourceBytesLock.lock()
        defer { sourceBytesLock.unlock() }
        return sourceBytesReadStorage
    }

    private func countSourceBytes(_ bytes: Int32) {
        guard bytes > 0 else { return }
        sourceBytesLock.lock()
        sourceBytesReadStorage &+= Int64(bytes)
        sourceBytesLock.unlock()
    }
    private var storedConversionStats: DolbyVisionConversionStats?

    var dolbyVisionConversionStats: DolbyVisionConversionStats? {
        conversionStatsLock.withLock { storedConversionStats }
    }

    /// Frames a JOC walk may read before "no JOC" is the answer. Shared by both
    /// output shapes so a source's verdict can't depend on which one carried it.
    static let atmosSniffPacketBudget = 24

    /// What the bitstream said about object audio, per source stream index —
    /// written from the producer thread as each track settles, read by the
    /// session from wherever the host asks.
    private let objectAudioLock = NSLock()
    private var storedObjectAudio: [Int: ObjectAudioFinding] = [:]

    /// Settled findings, in stream order. Empty until the first
    /// stream-copied E-AC-3 track has been asked.
    var objectAudioFindings: [ObjectAudioFinding] {
        objectAudioLock.withLock {
            storedObjectAudio.values.sorted { $0.streamIndex < $1.streamIndex }
        }
    }

    func recordObjectAudio(_ finding: ObjectAudioFinding) {
        objectAudioLock.withLock { storedObjectAudio[finding.streamIndex] = finding }
    }

    /// The display criteria this session wants programmed before AVPlayer
    /// loads its playlist. Known once the probe has run — i.e. from the
    /// moment the playlists exist — and `nil` before that.
    private let criteriaChoiceLock = NSLock()
    private var storedCriteriaChoice: DisplayCriteriaChoice?
    /// Whether the served master claims Dolby Vision (`dvh1` primary or
    /// `SUPPLEMENTAL-CODECS`) — what the rejection fallback's first tier
    /// drops. `false` before the master is written, and for masters with no
    /// DV claim to drop.
    private var storedMasterDeclaresDolbyVision = false

    var displayCriteriaChoice: DisplayCriteriaChoice? {
        criteriaChoiceLock.withLock { storedCriteriaChoice }
    }

    /// The container's chapter marks, known once the probe has run — the same
    /// lifecycle as `displayCriteriaChoice`. Written once from the producer
    /// thread, read from the session's actor, hence the lock.
    private let chaptersLock = NSLock()
    private var storedChapters: [ChapterInfo] = []

    var sourceChapters: [ChapterInfo] {
        chaptersLock.withLock { storedChapters }
    }

    var masterDeclaresDolbyVision: Bool {
        criteriaChoiceLock.withLock { storedMasterDeclaresDolbyVision }
    }

    /// The dialogue-boost renditions the served master actually declares —
    /// empty when none were requested, none could be built in this FFmpeg
    /// build, or the shape ended up without a master. Written once from the
    /// producer thread when the master lands, read from the session's actor.
    private let dialogueBoostLock = NSLock()
    private var storedDialogueBoostRenditions: [DialogueBoostRendition] = []

    var dialogueBoostRenditions: [DialogueBoostRendition] {
        dialogueBoostLock.withLock { storedDialogueBoostRenditions }
    }

    /// The renditions of the running session, by directory name — what the
    /// loopback's demand seam arms (`noteAudioDemand`). Written once on the
    /// producer thread before the master lands; `arm()` itself is
    /// thread-safe, so the server may call it from any connection.
    private let renditionsLock = NSLock()
    private var storedRenditionsByDirectory: [String: AudioRenditionWriter] = [:]
    private var storedLazyRenditionPlaylistURIs: Set<String> = []

    /// Relative playlist URIs of renditions that are declared in the master
    /// but produce nothing until a fetch arms them. The readiness gate must
    /// not wait for their init segment: it is minted by the first cut AFTER
    /// arming, and nobody has armed anything when `start()` is waiting.
    var lazyRenditionPlaylistURIs: Set<String> {
        renditionsLock.withLock { storedLazyRenditionPlaylistURIs }
    }

    /// The provider reports every init/segment fetch under `audioN/` here.
    /// Returns `true` when this fetch is the one that armed a lazy rendition
    /// — the provider then forces a re-anchor so the rendition joins at a
    /// boundary. `false` for eager renditions, already-armed ones, and paths
    /// that name no rendition.
    func noteAudioDemand(path: String) -> Bool {
        guard let directory = path.split(separator: "/").first else { return false }
        let rendition = renditionsLock.withLock { storedRenditionsByDirectory[String(directory)] }
        return rendition?.arm() ?? false
    }

    private func recordConversionStats(_ converter: DolbyVisionRPUConverter) {
        let stats = DolbyVisionConversionStats(
            convertedRPUs: converter.convertedRPUs,
            failedRPUs: converter.failedRPUs,
            droppedEnhancementLayerNALs: converter.droppedEnhancementLayerNALs,
            staleUnconvertedPackets: converter.staleUnconvertedPackets
        )
        conversionStatsLock.withLock { storedConversionStats = stats }
    }

    init(
        sourceURL: URL,
        httpHeaders: [String: String] = [:],
        outputDirectory: URL,
        segmentSeconds: Int = 6,
        firstSegmentSeconds: Int = SegmentPlan.defaultFirstSegmentSeconds,
        displayIsHDRReady: Bool = false,
        displayIsDolbyVisionCapable: Bool = false,
        demand: DemandCoordinator? = nil,
        segmentCacheBytes: Int? = nil,
        forceMuxed: Bool = false,
        dialogueBoost: [DialogueBoostLevel] = [],
        probed: ProbedSource? = nil,
        keyframeCacheDirectory: URL? = nil,
        indexLoadBudget: Duration = SegmentPlan.indexLoadBudget,
        landed: ProductionSignal? = nil
    ) {
        self.probed = probed
        self.landed = landed
        self.keyframeCache = keyframeCacheDirectory.map { KeyframeIndexCache(directory: $0) }
        self.indexLoadBudget = indexLoadBudget
        self.sourceURL = sourceURL
        self.httpHeaders = httpHeaders
        self.outputDirectory = outputDirectory
        self.segmentSeconds = segmentSeconds
        self.firstSegmentSeconds = firstSegmentSeconds
        self.subtitles = SubtitleRenditionSet(outputDirectory: outputDirectory)
        self.displayIsHDRReady = displayIsHDRReady
        self.displayIsDolbyVisionCapable = displayIsDolbyVisionCapable
        self.demand = demand
        self.segmentCacheBytes = segmentCacheBytes
        self.forceMuxed = forceMuxed
        self.dialogueBoost = dialogueBoost
    }

    func cancel() {
        cancelled.set()
        activeGuardLock.withLock { activeGuard?.cancel() }
        // A producer parked at EOF is asleep on the coordinator, not spinning —
        // setting the flag is not enough to get its thread back.
        demand?.wake()
    }

    /// Runs the whole demux → remux loop synchronously; call on a **dedicated
    /// thread**, never a cooperative-pool one: it blocks in FFmpeg reads for as
    /// long as production takes and parks at EOF for the length of the session.
    /// Returns normally on EOF or cancellation, throws on setup/write failures.
    func run() throws {
        var input: UnsafeMutablePointer<AVFormatContext>?

        // Adopt the routing probe's context when the host handed one over —
        // the source is already open and already analysed, so this whole
        // block is a rewind instead of a round trip. Only the CONTEXT can be
        // inherited, never merely its conclusions: `find_stream_info` fills
        // fields the muxer needs (an EAC3 track's frame size), so a context
        // that skipped it produces a right-looking manifest and a failing
        // `av_interleaved_write_frame`. That is the whole reason this is a
        // handover and not a cache.
        let adoptedInfo: SourceInfo?
        // Whichever branch opens (or adopts) the context, the guard is the one
        // its blocking reads were CREATED with — a callback cannot be added to
        // a context after `avformat_open_input` (issue #39), so an adopted
        // context brings the probe's guard along and a self-opened one gets
        // its own before the open.
        let interruptGuard: ReadInterruptGuard
        // The probe left an adopted context wherever its reads ended — the
        // interlace verification decodes a dozen frames. Production starts at
        // the head, but the rewind is deferred until the plan is built: the
        // index-load path ends with its own seek to 0, and over HTTP every
        // seek is a Range request, so rewinding here first was a round trip
        // spent to arrive where the next call was going anyway.
        var needsRewindToHead = false
        if let adopted = probed?.consumeContext(), let probed {
            input = adopted
            interruptGuard = probed.interruptGuard
            needsRewindToHead = true
            adoptedInfo = probed.info
        } else {
            // HTTP(S) inputs carry the caller's headers (a Plex token, a WebDAV
            // authorization) on the demux connection itself, under the shared
            // read caps (see `SourceOpenTuning`).
            var openOptions = SourceOpenTuning.makeOptions(httpHeaders: httpHeaders)
            defer { av_dict_free(&openOptions) }

            interruptGuard = ReadInterruptGuard()
            input = interruptGuard.makeContext()
            if coordinatedHTTP, ["http", "https"].contains(sourceURL.scheme?.lowercased() ?? ""), let input {
                do { try interruptGuard.installHTTPInput(on: input, url: sourceURL, headers: httpHeaders) }
                catch { avformat_free_context(input); throw error }
            }
            // Bounded like the probe's open, and for the same reason: a
            // server that accepts and then starves the reads would otherwise
            // pin this producer forever — the session's startup timeout fires,
            // but the blocked thread never comes back. On expiry the open
            // throws and the session surfaces a startup error instead.
            interruptGuard.arm(budget: SourceOpenTuning.probeBudget)
            let sourceSpec = sourceURL.isFileURL ? sourceURL.path : sourceURL.absoluteString
            try FFmpegError.check(
                avformat_open_input(&input, sourceSpec, nil, &openOptions),
                "avformat_open_input"
            )
            guard let opened = input else { throw Failure.noVideoStream }
            try FFmpegError.check(
                avformat_find_stream_info(opened, nil), "avformat_find_stream_info"
            )
            interruptGuard.disarm()
            adoptedInfo = nil
        }
        activeGuardLock.withLock {
            activeGuard = interruptGuard
            if cancelled.isSet { interruptGuard.cancel() }
        }
        // Ours to close either way now: a consumed `ProbedSource` has given up
        // ownership, and an unconsumed one never had this context. The guard
        // outlives the close — its callback runs on the teardown reads too.
        defer {
            avformat_close_input(&input)
            activeGuardLock.withLock { activeGuard = nil }
            withExtendedLifetime(interruptGuard) {}
        }
        guard let input else { throw Failure.noVideoStream }

        // The probe already reads everything both decisions below need — which
        // streams exist, what they are, whether they copy, their languages and
        // the video's HDR/DV signaling. An adopted context brings that answer
        // with it (including the verified interlace verdict, which costs
        // decoded frames and must not be paid twice); otherwise derive it here
        // from our own context.
        let info = adoptedInfo ?? SourceProbe.describe(input: input)
        audioDeliveryStore.prepare(indexes: info.audioTracks.map(\.streamIndex))
        // Chapters can't ride the served HLS (the format has no way to carry
        // them), so the session surfaces them as API instead — publish before
        // any packet work so they are readable the moment `start()` returns.
        chaptersLock.withLock { storedChapters = info.chapters }
        guard let videoTrack = info.video else { throw Failure.noVideoStream }
        guard videoTrack.copyability == .streamCopy else {
            throw Failure.videoCodecNotNativelyPlayable(videoTrack.codecName)
        }
        let videoIndex = Int32(videoTrack.streamIndex)

        // Subtitle renditions are set up before the muxer: their packets never
        // reach it (in-band timed text is not HLS-conformant — muxing it in
        // gets the whole stream rejected by AVPlayer), they become WebVTT files
        // alongside the fMP4 segments.
        let subtitleStreams = try subtitles.prepare(input: input)

        let candidates = audioCandidates(input)
        let bestAudio = av_find_best_stream(input, AVMEDIA_TYPE_AUDIO, -1, videoIndex, nil, 0)
        let routes = Self.routeAll(candidates: candidates, best: bestAudio >= 0 ? bestAudio : nil)

        // Can this source be honestly wrapped in a master playlist at all? The
        // answer decides the whole output shape, so it is settled before a
        // single muxer exists. `variant` here is the video half only; the
        // renditions are added once their encoders are up (a bridged rendition's
        // CHANNELS comes from the encoder), and they can't change the verdict —
        // every `SignalingError` is about the video.
        // Profile 7 is dual-layer and undecodable here, but its base layer is
        // plain HDR10 — so rather than handing the source to Prism we convert its
        // RPUs to 8.1 and drop the enhancement layer as the packets go past. The
        // converter is nil for every other source (and when libdovi isn't in this
        // build), and then nothing below changes.
        let dolbyVisionConverter = makeDolbyVisionConverter(video: videoTrack)
        // What the manifest may claim: the *converted* configuration when we are
        // converting, the source's own otherwise. Declaring 8.1 for a stream
        // whose RPUs are still P7 would be the one lie AVKit can't detect at
        // parse time and can only fail on at the display.
        let outputDolbyVision = dolbyVisionConverter != nil
            ? videoTrack.dolbyVision?.convertedToProfile81
            : videoTrack.dolbyVision

        // What the panel should be asked for before AVPlayer loads any of
        // this. Computed from the same declared configuration the manifest
        // claims, so the criteria and the playlist never disagree about what
        // is being played.
        let criteriaChoice = DisplayCriteriaChoice.forSource(
            dynamicRange: videoTrack.dynamicRange,
            declaredDolbyVision: outputDolbyVision,
            display: DisplayCapabilities(
                isHDRReady: displayIsHDRReady,
                isDolbyVisionCapable: displayIsDolbyVisionCapable
            ),
            frameRate: videoTrack.frameRate
        )
        criteriaChoiceLock.withLock { storedCriteriaChoice = criteriaChoice }

        let videoVariant = makeVideoVariant(
            input: input, video: videoTrack, dolbyVision: outputDolbyVision
        )
        let masterIsPossible = videoVariant.map { (try? MasterPlaylistBuilder.build($0)) != nil } ?? false

        let shape: OutputShape = (!routes.isEmpty && masterIsPossible && !forceMuxed)
            ? .renditions(routes)
            : .muxed(Self.chooseAudio(candidates: candidates, best: bestAudio >= 0 ? bestAudio : nil))

        // Demand-driven mode needs a trustworthy upfront segmentation. Only a
        // keyframe-based plan qualifies — uniform-plan boundaries are time
        // targets, and a playlist that promises durations the producer can't
        // hit at keyframes would drift against what AVPlayer fetched. The one
        // shape excluded is muxed-with-bridge: re-anchoring would mean
        // resetting an encoder mid-fragment, and that combination only occurs
        // when a master was refused anyway.
        let demandEligible: Bool = {
            guard demand != nil else { return false }
            if case .muxed(let audio) = shape, audio?.mode == .bridge { return false }
            return true
        }()

        // The source's identity for the keyframe cache — from the opened
        // context, so the size is the transport's own answer (HTTP and file
        // alike) and the duration is the container's.
        let cacheIdentity: String? = keyframeCache.map { _ in
            KeyframeIndexCache.identity(
                sourceURL: sourceURL,
                sizeBytes: input.pointee.pb.map { avio_size($0) } ?? -1,
                durationMicroseconds: input.pointee.duration
            )
        }
        // A previous play's harvested keyframe map, when its time base still
        // matches the stream's. It replaces the demuxer index in the plan —
        // and skips the index-load seek, so a cache hit starts faster than
        // even a well-indexed first play.
        let cachedEntry: KeyframeIndexCache.Entry? = {
            guard demandEligible, let keyframeCache, let cacheIdentity,
                  // A plan is a promise to re-anchor, and a re-anchor is a
                  // seek — on a transport that can't (an HTTP server that
                  // ignores Range), the cached map would plan a session whose
                  // first real seek kills it. Unseekable sources keep the
                  // sequential shape the map can't improve.
                  let pb = input.pointee.pb, pb.pointee.seekable != 0,
                  let entry = keyframeCache.lookup(identity: cacheIdentity)
            else { return nil }
            let timeBase = input.pointee.streams[Int(videoIndex)]!.pointee.time_base
            guard entry.timeBaseNum == timeBase.num, entry.timeBaseDen == timeBase.den,
                  entry.keyframePTS.count >= 2
            else { return nil }
            return entry
        }()
        let cachedKeyframes = cachedEntry?.keyframePTS
        // A partial map (a play cancelled before EOF) plans its prefix
        // exactly and the tail on the uniform stride — see `keyframePlan`.
        let cachedCoveredThrough: Int64? = cachedEntry.flatMap { $0.complete ? nil : $0.coveredThroughPTS }

        let (builtPlan, planRewoundToHead): (SegmentPlan?, Bool) = demandEligible
            ? SegmentPlan.buildReportingPosition(
                input: input, videoStreamIndex: videoIndex, targetSeconds: segmentSeconds,
                firstSegmentSeconds: firstSegmentSeconds,
                indexLoadBudget: indexLoadBudget,
                interruptGuard: interruptGuard, cachedKeyframes: cachedKeyframes,
                cachedCoveredThroughPTS: cachedCoveredThrough
            )
            : (nil, false)
        if needsRewindToHead, !planRewoundToHead {
            // The plan did not pass through the head (cached map, an index
            // loaded at open, or no plan at all): rewind the adopted context
            // ourselves. `avformat_flush` drops the probe's queued packets.
            _ = av_seek_frame(input, -1, 0, AVSEEK_FLAG_BACKWARD)
            avformat_flush(input)
        }
        let plannedPlan: SegmentPlan? = builtPlan?.basis == .keyframeIndex ? builtPlan : nil
        let planIsPartial = plannedPlan != nil && cachedCoveredThrough != nil

        // Harvest for next time (issue #34): this session degraded to the
        // sequential shape even though it could have been planned — the map
        // is not in the file. The producer is about to read every packet
        // head-to-EOF anyway (sequential mode never re-anchors, so coverage
        // is complete), and each video keyframe it sees goes into the sidecar
        // the NEXT play's plan builds from. Strictly a by-product: no plan
        // possible at all (`builtPlan == nil`, a live source) means the next
        // play can't use a map either, so nothing is collected.
        //
        // A session planned on a PARTIAL map harvests too, to extend the
        // prefix: only a contiguous run counts, so keyframes are appended
        // while the current run started at-or-before the covered end
        // (`harvestRunExtendsCoverage`) — a seek into the un-covered tail
        // sees keyframes with a hole before them, and the gap witness would
        // reject the whole map if they were stored.
        let shouldHarvestKeyframes = keyframeCache != nil && cacheIdentity != nil
            && demandEligible && builtPlan != nil && (plannedPlan == nil || planIsPartial)
        var harvestedKeyframes: [Int64]? = shouldHarvestKeyframes ? (cachedKeyframes ?? []) : nil
        var harvestCoveredThrough: Int64? = cachedCoveredThrough
        var harvestRunExtendsCoverage = true

        // MARK: Output setup

        var renditions: [AudioRenditionWriter] = []
        defer { renditions.forEach { $0.close() } }
        var muxedBridge: AudioBridge?
        defer { muxedBridge?.close() }
        // The video stream is the one output stream we describe ourselves rather
        // than mirroring: its `hvcC` needs normalizing for the `hvc1` sample
        // entry, and a converted P7 has to carry an 8.1 `dvvC` instead of the
        // source's own record.
        var plan: [FMP4SegmentWriter.StreamPlan] = [
            .init(inputIndex: videoIndex) { [self] outStream in
                try configureVideoOutput(
                    outStream,
                    input: input,
                    videoIndex: videoIndex,
                    // The DV configuration to *declare*. Passed even when we are
                    // not converting: it decides the sample entry's fourcc, and a
                    // Profile 5 stream needs `dvh1` whatever else is true.
                    declaredDolbyVision: outputDolbyVision,
                    // Only a conversion has to replace the source's own record.
                    rewriteDolbyVisionRecord: dolbyVisionConverter != nil,
                    // A display that cannot present Dolby Vision must not be
                    // sent a `dvvC` box, whatever the manifest says.
                    stripDolbyVisionRecord: !displayIsDolbyVisionCapable
                )
            }
        ]

        switch shape {
        case .renditions(let routes):
            let byIndex = Dictionary(
                uniqueKeysWithValues: info.audioTracks.map { ($0.streamIndex, $0) }
            )
            for (ordinal, route) in routes.enumerated() {
                guard let track = byIndex[Int(route.index)] else { continue }
                let rendition = AudioRenditionWriter(
                    route: route,
                    track: track,
                    ordinal: ordinal,
                    parent: outputDirectory
                )
                rendition.onObjectAudioSettled = { [weak self] finding in
                    self?.recordObjectAudio(finding)
                }
                rendition.onBridgeProgress = { [audioDeliveryStore, index = Int(route.index)] progress in
                    audioDeliveryStore.update(index: index, delivery: .bridged, bridge: progress)
                }
                // One track that can't be set up (a channel layout the EAC3
                // encoder can't express, say) costs that rendition, not the
                // session: the other tracks and the picture still play, which
                // is the whole point of not muxing them together.
                // An empty planned boundary keeps its index and is declared
                // to the demand seam (see `AudioRenditionWriter.cut`).
                rendition.onPlannedSegment = { [demand, name = rendition.directoryName] index, produced in
                    let path = name + "/" + String(format: "seg%05d.m4s", index)
                    if produced {
                        demand?.clearUnproducible(path: path)
                    } else {
                        demand?.markUnproducible(path: path)
                    }
                }
                do {
                    rendition.audioDelaySeconds = audioDelaySeconds
                    try rendition.open(input: input)
                    renditions.append(rendition)
                    audioDeliveryStore.update(index: Int(route.index),
                        delivery: route.mode == .streamCopy ? .streamCopy : .bridged)
                } catch {
                    rendition.close()
                }
            }
            // Dialogue-boost renditions, derived from the DEFAULT track only
            // (routes[0] — the one `chooseAudio` picked): the feature is "the
            // dialogue is hard to hear on the track I'm listening to", and one
            // extra decode→filter→encode chain per level is already real CPU;
            // one per level per TRACK would be a five-language MKV paying for
            // ten encoders nobody selected. Appended after the base loop so a
            // boost never displaces a language, and skipped one-by-one on
            // failure exactly like the base renditions.
            let defaultCodecID = candidates
                .first { $0.index == renditions.first?.route.index }?.codecID
            for route in Self.dialogueBoostRoutes(
                requested: dialogueBoost,
                base: renditions.first?.route,
                trackChannelCount: renditions.first.map { $0.track.channelCount } ?? 0,
                boostIsBuildable: defaultCodecID.map {
                    AudioBridge.canDecodeForBoost(codecID: $0) && DialogueBoostFilter.isAvailable
                } ?? false
            ) {
                guard let track = byIndex[Int(route.index)] else { continue }
                let rendition = AudioRenditionWriter(
                    route: route,
                    track: track,
                    ordinal: renditions.count,
                    parent: outputDirectory,
                    // Lazy in the planned shape: declared now, produced from
                    // the first fetch under its directory, which re-anchors
                    // production to the demanded segment. The host requests
                    // every level on every session; a decode→filter→encode
                    // chain per level ran for the whole film whether or not
                    // anyone picked it. Eager in the sequential shape, whose
                    // provider has no demand seam (a miss is a 404 there) —
                    // that shape keeps today's cost, and today's behaviour.
                    lazy: plannedPlan != nil
                )
                // An empty planned boundary keeps its index and is declared
                // to the demand seam (see `AudioRenditionWriter.cut`).
                rendition.onPlannedSegment = { [demand, name = rendition.directoryName] index, produced in
                    let path = name + "/" + String(format: "seg%05d.m4s", index)
                    if produced {
                        demand?.clearUnproducible(path: path)
                    } else {
                        demand?.markUnproducible(path: path)
                    }
                }
                do {
                    rendition.audioDelaySeconds = audioDelaySeconds
                    try rendition.open(input: input)
                    renditions.append(rendition)
                } catch {
                    rendition.close()
                }
            }
            // The master is static — URIs, codecs and languages are all known
            // now — so it lands before the first segment. `PrismCoreSession`
            // reads its presence to decide which URL it hands out.
            if var variant = videoVariant, !renditions.isEmpty {
                // Registered BEFORE the master lands: the readiness gate reads
                // the master the moment it appears, and a lazy rendition it
                // did not know about would hold the gate for an init that is
                // not coming until someone arms it.
                renditionsLock.withLock {
                    storedRenditionsByDirectory = Dictionary(
                        uniqueKeysWithValues: renditions.map { ($0.directoryName, $0) }
                    )
                    storedLazyRenditionPlaylistURIs = Set(
                        renditions.filter(\.isLazy).map(\.playlistURI)
                    )
                }
                variant.audioRenditions = renditions.enumerated().map { ordinal, rendition in
                    // DEFAULT on the first rendition only, which is the track
                    // `chooseAudio` would have picked (see `routeAll`).
                    rendition.rendition(groupID: Self.audioGroupID, isDefault: ordinal == 0)
                }
                // The WebVTT renditions `prepare` set up above. Declaring them
                // here is what makes them exist for AVPlayer: the segments are
                // produced either way, but only the master's SUBTITLES group
                // puts them in the legible selection group.
                variant.subtitles = subtitles.renditions
                try Data(try MasterPlaylistBuilder.build(variant).utf8).write(
                    to: outputDirectory.appendingPathComponent(Self.masterPlaylistFileName),
                    options: .atomic
                )
                // Remembered for the rejection fallback: a master whose DV
                // claim may be what the panel refused gets one retry without
                // it before the muxed shape (see the session's factory).
                let claimsDV = MasterPlaylistBuilder.declaresDolbyVision(variant)
                criteriaChoiceLock.withLock { storedMasterDeclaresDolbyVision = claimsDV }
                // Report only what the master actually declares — a requested
                // level that couldn't be built must not be promised to the
                // host, whose UI builds rows from this list.
                let boostInfos = renditions.compactMap(\.dialogueBoostInfo)
                dialogueBoostLock.withLock { storedDialogueBoostRenditions = boostInfos }
            }

        case .muxed(let audio):
            // Bridge first — its encoder parameters must be on the output stream
            // BEFORE write_header (empty_moov writes the sample entries then).
            if let audio {
                if audio.mode == .bridge {
                    let inStream = input.pointee.streams[Int(audio.index)]!
                    let bridge = try AudioBridge(
                        codecpar: inStream.pointee.codecpar,
                        timeBase: inStream.pointee.time_base,
                        // mp4/mov is a global-header muxer by definition; the
                        // encoder's extradata must land in codecpar, not in-band.
                        globalHeader: true
                    )
                    muxedBridge = bridge
                    bridge.onProgress = { [audioDeliveryStore, index = Int(audio.index)] progress in
                        audioDeliveryStore.update(index: index, delivery: .bridged, bridge: progress)
                    }
                    audioDeliveryStore.update(index: Int(audio.index), delivery: .bridged)
                    plan.append(.init(inputIndex: audio.index) { outStream in
                        try bridge.configure(outputStream: outStream)
                    })
                } else {
                    plan.append(.init(inputIndex: audio.index))
                    audioDeliveryStore.update(index: Int(audio.index), delivery: .streamCopy)
                }
            }
        }

        let muxedBridgeIndex: Int32? = {
            guard case .muxed(let audio) = shape, audio?.mode == .bridge else { return nil }
            return audio?.index
        }()
        // Grouped, not unique-keyed: a dialogue-boost rendition shares its
        // input stream with the base rendition it derives from, so one source
        // packet can feed several writers.
        let renditionsByInputIndex = Dictionary(
            grouping: renditions, by: { Int($0.route.index) }
        )

        var writer = FMP4SegmentWriter()
        writer.audioDelaySeconds = audioDelaySeconds
        _ = try writer.open(input: input, plan: plan)   // delay_moov: header emits nothing
        var streamMap = writer.streamMap
        let playlist = MediaPlaylistWriter(directory: outputDirectory)

        // Planned VOD: every playlist is complete before the first packet —
        // from here on, playlists are read-only and segments land as files.
        if let plannedPlan, let demand {
            let durations = plannedPlan.entries.map(\.duration)
            try playlist.writePlannedVOD(durations: durations) { index in
                String(format: "seg%05d.m4s", index)
            }
            for rendition in renditions {
                try rendition.writePlannedVOD(durations: durations)
            }
            try subtitles.writePlannedVOD(durations: durations)
            demand.publish(plan: plannedPlan)
            demand.setProducing(index: 0)
        }

        // Segmentation state, tracked on the INPUT video stream's time base
        // (the packet still carries it when the cut decision is made).
        let videoTimeBase = input.pointee.streams[Int(videoIndex)]!.pointee.time_base
        let tickSeconds = av_q2d(videoTimeBase)
        let boundaryStep = Int64((Double(segmentSeconds) / tickSeconds).rounded())
        // Sequential (EVENT) sessions have no plan to read the short head
        // from, so the first boundary is computed here: the same shorter
        // stride the planner uses, for the same reason (startup waits for
        // this cut). Clamped like the planner's — the knob only shortens.
        let firstBoundaryStep = Int64(
            (Double(min(firstSegmentSeconds, segmentSeconds)) / tickSeconds).rounded()
        )
        var segmentStartPTS: Int64?
        var nextBoundaryPTS: Int64 = 0
        var lastVideoEndPTS: Int64?
        var segmentIndex = 0
        /// Post-reanchor: discard packets until the anchor keyframe arrives
        /// (a BACKWARD seek may land at an earlier keyframe than requested).
        var droppingUntilPTS: Int64?

        /// The planned end of segment `index` — the next entry's start — or
        /// "never" past the last entry (EOF closes it).
        func plannedBoundary(after index: Int) -> Int64 {
            guard let plannedPlan, index + 1 < plannedPlan.entries.count else { return .max }
            return plannedPlan.entries[index + 1].startPTS
        }

        // Retention: planned mode, where a deleted segment is reproduced on
        // demand — and, since 1.11, the sequential shape too, with the lead
        // cap keeping the producer near the playhead so eviction only ever
        // reaches far behind it. There a deleted EVENT segment is NOT
        // reproducible (no plan to re-anchor on): a backward seek to one is a
        // 404 AVPlayer treats as a failed segment. Accepted, and documented,
        // against the alternative — a sequential remux of a 50 GB film wrote
        // all 50 GB to the device before this. Never ahead of the playhead.
        var retention: SegmentRetention? = (plannedPlan != nil || demand != nil)
            ? segmentCacheBytes.map { SegmentRetention(budgetBytes: $0) }
            : nil
        demand?.nominalSegmentSeconds = Double(segmentSeconds)

        // Unlinks run off the producer thread: a `removeItem` per victim per
        // rendition sat in the cut path, between a landed segment and the
        // next packet. Serial, so two evictions never race each other; a
        // re-production of an evicted index needs a miss first, which needs
        // the unlink done — the window in which a fresh file could be hit by
        // a stale unlink is the queue's own latency (milliseconds) against a
        // demuxer seek, and the fetch that finds the stale file still serves
        // the same bytes.
        let unlinkQueue = DispatchQueue(label: "cz.zmrhal.prismcore.unlink", qos: .utility)

        /// Record a landed segment's disk cost (variant + every rendition
        /// file of the same index, as their cuts reported it — no `stat`)
        /// and delete whatever the policy evicts.
        func recordAndEvict(index: Int, videoBytes: Int, renditionBytes: Int) {
            guard retention != nil else { return }
            // Indexes with an outstanding demand serve are off limits — the
            // fetch that re-anchored production here is still waiting for its
            // file, and production has usually run several segments past it
            // by the time this records (issue #43). In the sequential shape
            // everything from the playhead on is off limits too.
            var protected = demand?.demandProtectedIndexes ?? []
            if plannedPlan == nil, let playhead = demand?.playheadIndex, playhead <= index {
                for ahead in playhead...index { protected.insert(ahead) }
            }
            let victims = retention!.record(
                index: index, bytes: videoBytes + renditionBytes, producing: index, protected: protected
            )
            guard !victims.isEmpty else { return }
            residentSegments.retire(victims)
            let directories = [outputDirectory] + renditions.map {
                outputDirectory.appendingPathComponent($0.directoryName)
            }
            unlinkQueue.async { [residentSegments] in
                for victim in victims {
                    residentSegments.unlinkRetired(index: victim, directories: directories)
                }
            }
        }

        // The muxed shape's candidate for a JOC declaration: any stream-copied
        // E-AC-3 track. The bridge's output carries no JOC, so it never
        // qualifies — but the probe's `isObjectAudio` deliberately does NOT
        // narrow this (see `AudioRenditionWriter.sniffAtmosIfNeeded`): that flag
        // is a metadata claim libavformat often cannot make, and gating on it
        // silently downgraded real Atmos to DD+.
        let muxedAtmosTrack: AudioTrackInfo? = {
            guard case .muxed(let audio) = shape, let audio, audio.mode == .streamCopy
            else { return nil }
            return info.audioTracks.first {
                $0.streamIndex == Int(audio.index) && $0.codecName == "eac3"
            }
        }()
        /// `complexity_index_type_a` read out of the first readable syncframe.
        /// Captured by `writeInitSegmentIfAbsent`, which needs it by the time the
        /// first cut mints the moov — by then plenty of audio packets have gone
        /// past, so it is there.
        var muxedAtmosComplexityIndex: Int?
        /// Frames the walk has read, and whether it has settled — same budget
        /// and same meaning as the rendition writer's.
        var muxedAtmosPacketsRead = 0
        var muxedAtmosSettled = false

        // Sources whose VPS/SPS/PPS travel in band ship a 23-byte `hvcC` with no
        // arrays, and FFmpeg then writes an empty box — an `hvc1` entry promising
        // parameter sets that aren't there. Harvest them from the bitstream and
        // fill the record in when the init segment is written.
        let videoExtradata: Data? = {
            let par = input.pointee.streams[Int(videoIndex)]!.pointee.codecpar.pointee
            guard let extradata = par.extradata, par.extradata_size > 0 else { return nil }
            return Data(bytes: extradata, count: Int(par.extradata_size))
        }()
        let needsParameterSetHarvest = videoTrack.codecName == "hevc"
            && videoTrack.nalUnitLengthSize != nil
            && videoExtradata.map(HVCCNormalizer.carriesNoParameterSets(hvcC:)) == true
        /// NAL type → units, deduplicated. VPS/SPS/PPS only.
        var harvestedParameterSets: [UInt8: [[UInt8]]] = [:]

        /// Write the init segment the first time one is minted.
        ///
        /// Two things happen here. The `hvcC` gets its final correction: the muxer
        /// rebuilds the record when it writes the sample entry and leaves
        /// `array_completeness = 0` under a `hvc1` name, so normalizing the
        /// source's extradata alone never reaches the artifact AVPlayer parses.
        /// And a re-anchored muxer mints its moov again — the one already served
        /// must not change under AVPlayer's cached `EXT-X-MAP`, so the first write
        /// wins.
        func writeInitSegmentIfAbsent(_ initSegment: Data) throws {
            let initURL = outputDirectory.appendingPathComponent(Self.initFileName)
            guard !FileManager.default.fileExists(atPath: initURL.path) else { return }
            var bytes = HVCCNormalizer.patch(initSegment: initSegment) ?? initSegment
            // Fill in parameter sets the source never put in its record.
            if needsParameterSetHarvest, let sourceRecord = videoExtradata,
               let filled = HVCCNormalizer.patch(
                   initSegment: bytes,
                   sourceRecord: sourceRecord,
                   withParameterSets: harvestedParameterSets
               ) {
                bytes = filled
            }
            // And the JOC declaration FFmpeg leaves out of `dec3` — the
            // difference between Atmos and plain DD+ at the speaker. Muxed shape
            // only; a rendition patches its own init segment.
            if let index = muxedAtmosComplexityIndex,
               let withAtmos = EAC3Configuration.patch(
                   initSegment: bytes, atmosComplexityIndex: index
               ) {
                bytes = withAtmos
            }
            try bytes.write(to: initURL, options: .atomic)
        }

        func emitSegment(endPTS: Int64) throws {
            // Whatever this cut wrote — init alone, or init + variant +
            // renditions — is on disk by the time the defer runs, which is
            // the ordering the signal's contract demands (state, then wake).
            defer { landed?.broadcast() }
            let (initSegment, media) = try writer.cutSegment()
            // The first cut also mints the init segment (see cutSegment's
            // doc); write it BEFORE the playlist entry so a reader that saw
            // the manifest can always fetch what it references.
            if let initSegment, !initSegment.isEmpty {
                try writeInitSegmentIfAbsent(initSegment)
            }
            // A boundary that produced no video bytes writes nothing anywhere,
            // renditions included: skipping the cut on all of them together is
            // what keeps their segment lists one-to-one with the video's.
            guard !media.isEmpty, let start = segmentStartPTS else { return }
            let duration = max(0.001, Double(endPTS - start) * tickSeconds)
            let file = String(format: "seg%05d.m4s", segmentIndex)
            try residentSegments.publish(index: segmentIndex, start: Double(start) * tickSeconds,
                end: Double(endPTS) * tickSeconds, data: media, root: outputDirectory)
            if plannedPlan == nil {
                try playlist.appendSegment(duration: duration, file: file)
            }
            onSegmentLanded?(segmentIndex)
            // Same wall-time window, so rendition segment N covers variant
            // segment N — cut only when a media segment really landed.
            try subtitles.flushSegment(
                start: Double(start) * tickSeconds,
                end: Double(endPTS) * tickSeconds
            )
            segmentIndex += 1
            // Every rendition cuts on the SAME source-time boundary the video
            // just used — HLS expects comparable segmentation across renditions,
            // and a rendition that drifted into its own cadence would make
            // AVPlayer's switch between them a resync.
            var renditionBytes = 0
            for rendition in renditions {
                renditionBytes += try rendition.cut(durationSeconds: duration)
            }
            demand?.setProducing(index: segmentIndex)
            recordAndEvict(index: segmentIndex - 1, videoBytes: media.count, renditionBytes: renditionBytes)
            // Refreshed per segment rather than once at EOF: a host that wants to
            // log "Dolby Vision engaged" can read it as soon as playback starts,
            // and a session that is cancelled halfway still leaves a real count.
            if let dolbyVisionConverter { recordConversionStats(dolbyVisionConverter) }
        }

        /// Demand-driven jump: abandon the in-flight fragment, seek the
        /// demuxer to the anchor's keyframe, and stand up fresh muxers whose
        /// tfdt carries absolute time (`restart` → frag_discont), so the
        /// produced segment sits exactly where the planned playlist put it.
        func reanchor(to anchor: Int) throws {
            guard let plannedPlan else { return }
            let target = plannedPlan.entries[anchor].startPTS
            try FFmpegError.check(
                av_seek_frame(input, videoIndex, target, AVSEEK_FLAG_BACKWARD),
                "av_seek_frame"
            )
            writer = FMP4SegmentWriter()
            writer.audioDelaySeconds = audioDelaySeconds
            _ = try writer.open(input: input, plan: plan, restart: true)
            streamMap = writer.streamMap
            for rendition in renditions {
                try rendition.reanchor(input: input, segmentIndex: anchor)
            }
            subtitles.reanchor(segmentIndex: anchor, startSeconds: Double(target) * tickSeconds)
            segmentIndex = anchor
            segmentStartPTS = nil
            nextBoundaryPTS = plannedBoundary(after: anchor)
            droppingUntilPTS = target
            demand?.setProducing(index: anchor)
            // A run that starts inside the covered prefix extends it; one
            // that starts past it leaves a hole and must not be stored.
            harvestRunExtendsCoverage = harvestCoveredThrough.map { target <= $0 } ?? true
        }

        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        guard let packet else { return }

        // MARK: Copy loop
        // In planned mode the producer never truly ends at EOF: an earlier
        // re-anchor may have skipped segments nobody produced, and a seek back
        // to one of them arrives AFTER the demuxer ran dry. So the produce
        // loop parks at EOF and waits for anchor requests until the session
        // is cancelled; sequential (v0) sessions run it exactly once.
        var reachedEOF = false
        produce: while true {
            reachedEOF = false
            while !cancelled.isSet {
                let readResult = av_read_frame(input, packet)
                if readResult == swift_AVERROR_EOF() {
                    reachedEOF = true
                    break
                }
                if readResult < 0 {
                    // Transient read errors on network sources: the reconnect
                    // options above handle the socket; anything that still
                    // surfaces here ends the remux (the playlists stay valid up
                    // to the last written segment).
                    throw FFmpegError(code: readResult, operation: "av_read_frame")
                }
                countSourceBytes(packet.pointee.size)
                defer { av_packet_unref(packet) }

                // A fetch outside the producer's window re-anchors it — checked
                // once per packet; nil is the hot path. A FORCED request is
                // honoured even for the segment already in production: a lazy
                // rendition was armed and joins only through a muxer rebuild
                // at a boundary, and the partial fragment abandoned by the
                // restart was never on disk.
                if plannedPlan != nil, let request = demand?.takeAnchorRequestDetailed(),
                   request.index != segmentIndex || request.forced,
                   request.index >= 0, request.index < (plannedPlan?.entries.count ?? 0) {
                    try reanchor(to: request.index)
                    // The packet in hand was read at the OLD position. Were it
                    // a keyframe past the anchor (a backward seek from further
                    // on), the discard check below would take it for the
                    // anchor keyframe and the segment would open on a picture
                    // from the wrong place, followed by lower timestamps from
                    // the seek target. The next read comes from the anchor.
                    continue
                }

                // Between a seek and the anchor keyframe, everything is discard:
                // the plan's PTS is an indexed keyframe, so it WILL arrive, and
                // pre-anchor packets belong to a segment nobody asked for.
                if let target = droppingUntilPTS {
                    let isAnchorKeyframe = Int32(packet.pointee.stream_index) == videoIndex
                        && packet.pointee.flags & AV_PKT_FLAG_KEY != 0
                        && packet.pointee.pts != swift_AV_NOPTS_VALUE()
                        && packet.pointee.pts >= target
                    if isAnchorKeyframe {
                        droppingUntilPTS = nil
                    } else {
                        continue
                    }
                }

                // Subtitle packets are consumed here and never handed to the muxer.
                if subtitleStreams.contains(Int32(packet.pointee.stream_index)) {
                    subtitles.ingest(packet)
                    continue
                }

                let streamIndex = Int(packet.pointee.stream_index)
                let inStream = input.pointee.streams[streamIndex]!
                let sourceTimeBase = inStream.pointee.time_base

                if Int32(streamIndex) == videoIndex {
                    // Cut BEFORE writing a boundary keyframe, so the keyframe opens
                    // the next segment (every segment starts decodable on its own —
                    // what EXT-X-INDEPENDENT-SEGMENTS promises).
                    if packet.pointee.pts != swift_AV_NOPTS_VALUE() {
                        let pts = packet.pointee.pts
                        let isKey = packet.pointee.flags & AV_PKT_FLAG_KEY != 0
                        // The keyframe harvest (issue #34): the packet is in
                        // hand either way, so the cost is one append on a
                        // packet already being examined for cut points.
                        if isKey, harvestRunExtendsCoverage {
                            harvestedKeyframes?.append(pts)
                            harvestCoveredThrough = max(harvestCoveredThrough ?? pts, pts)
                        }
                        if isKey {
                            if segmentStartPTS == nil {
                                segmentStartPTS = pts
                                // Index 0 only: a re-anchored producer also
                                // arrives here with no start, and its segment
                                // is a full one the plan already sized.
                                nextBoundaryPTS = plannedPlan != nil
                                    ? plannedBoundary(after: segmentIndex)
                                    : pts + (segmentIndex == 0 ? firstBoundaryStep : boundaryStep)
                                // The presentation origin: what the WebVTT timestamp
                                // maps are anchored to (see WebVTTRenditionWriter).
                                subtitles.setTimelineOrigin(seconds: Double(pts) * tickSeconds)
                            } else if pts >= nextBoundaryPTS {
                                try emitSegment(endPTS: pts)
                                // A segment just landed — the one moment the
                                // lead cap can pause without leaving a partial
                                // fragment behind. Parks only in planned mode
                                // (sequential has no demand) and only once
                                // production has run producerLeadSegments past
                                // the last fetch; an anchor request or a fetch
                                // wakes it, and the per-packet check right
                                // above handles whichever it was.
                                // The sequential shape parks on the same cap
                                // (its provider reports hits too): the cost
                                // is that a sequential harvest completes only
                                // when the viewer reaches the end, the gain
                                // is not demuxing and writing the whole film
                                // while they are on minute two.
                                demand?.parkWhileAhead(
                                    producing: segmentIndex,
                                    isCancelled: { [cancelled] in cancelled.isSet }
                                )
                                segmentStartPTS = pts
                                nextBoundaryPTS = plannedPlan != nil
                                    ? plannedBoundary(after: segmentIndex)
                                    : pts + boundaryStep
                            }
                        }
                        lastVideoEndPTS = pts + max(packet.pointee.duration, 0)
                    }
                    // P7 → 8.1: rewrite the RPUs and drop the enhancement layer
                    // before the bits reach the muxer. Returns nil for a packet
                    // that needed neither, which is every packet of every other
                    // source — the cost there is one NAL walk, no copy.
                    if let dolbyVisionConverter, let data = packet.pointee.data,
                       packet.pointee.size > 0 {
                        // The walk runs on the packet's own buffer, and a changed
                        // packet is written ONCE into a fresh av_malloc'd buffer
                        // that replaces the packet's — no `[UInt8]` copy in, no
                        // grow + memcpy out.
                        try Self.rewritePayload(of: packet) { source, allocate in
                            dolbyVisionConverter.convert(packet: source, into: allocate)
                        }
                    }
                    if needsParameterSetHarvest, harvestedParameterSets[33] == nil,
                       packet.pointee.flags & AV_PKT_FLAG_KEY != 0,
                       let lengthSize = videoTrack.nalUnitLengthSize,
                       let data = packet.pointee.data, packet.pointee.size > 0 {
                        // Keyframes carry the sets — gated on the flag, so a
                        // non-keyframe costs nothing, not even the walk.
                        let bytes = UnsafeBufferPointer(start: data, count: Int(packet.pointee.size))
                        for unit in HEVCNALUnits.units(in: bytes, lengthSize: lengthSize) ?? []
                        where HVCCNormalizer.keptNALTypes.contains(unit.type) && unit.layerID == 0 {
                            let value = Array(unit.bytes)
                            var existing = harvestedParameterSets[unit.type] ?? []
                            if !existing.contains(value) {
                                existing.append(value)
                                harvestedParameterSets[unit.type] = existing
                            }
                        }
                    }
                    if let mapped = streamMap[streamIndex] {
                        try write(packet, to: mapped, from: sourceTimeBase, writer: writer)
                    }
                    continue
                }

                if let sharers = renditionsByInputIndex[streamIndex] {
                    if sharers.count == 1 {
                        try sharers[0].write(packet, sourceTimeBase: sourceTimeBase)
                    } else {
                        // Each writer gets its own reference: the stream-copy
                        // path rescales timestamps IN the packet, so a shared
                        // one would reach the second writer already converted
                        // to the first one's time base. A clone is a refcount
                        // bump, not a payload copy.
                        for rendition in sharers {
                            var clone: UnsafeMutablePointer<AVPacket>? = av_packet_clone(packet)
                            guard let cloned = clone else { continue }
                            defer { av_packet_free(&clone) }
                            try rendition.write(cloned, sourceTimeBase: sourceTimeBase)
                        }
                    }
                    continue
                }

                guard let mapped = streamMap[streamIndex] else { continue }

                if let muxedBridge, Int32(streamIndex) == muxedBridgeIndex {
                    // Timestamps on the way in stay in the source stream's time
                    // base — the bridge's decoder is configured for it — and come
                    // back out on the encoder's, so only one rescale is left.
                    try muxedBridge.feed(packet) { encoded in
                        try write(encoded, to: mapped, from: muxedBridge.timeBase, writer: writer)
                    }
                    continue
                }

                if let muxedAtmosTrack, !muxedAtmosSettled,
                   streamIndex == muxedAtmosTrack.streamIndex,
                   let data = packet.pointee.data, packet.pointee.size > 0 {
                    // A partial first frame simply doesn't answer; the next one
                    // usually does, so the sniff stays open — but only for a
                    // bounded number of frames, after which "no JOC" is the
                    // answer rather than a question nobody closed.
                    muxedAtmosPacketsRead += 1
                    muxedAtmosComplexityIndex = EAC3Syncframe.atmosComplexityIndex(
                        in: UnsafeBufferPointer(start: data, count: Int(packet.pointee.size))
                    )
                    if muxedAtmosComplexityIndex != nil
                        || muxedAtmosPacketsRead >= Self.atmosSniffPacketBudget {
                        muxedAtmosSettled = true
                        recordObjectAudio(
                            ObjectAudioFinding(
                                streamIndex: muxedAtmosTrack.streamIndex,
                                complexityIndex: muxedAtmosComplexityIndex,
                                claimedByMetadata: muxedAtmosTrack.isObjectAudio
                            )
                        )
                    }
                }

                try write(packet, to: mapped, from: sourceTimeBase, writer: writer)
            }

            // A cancelled session is being torn down, so flushing the encoders would
            // only add work; on EOF the tail is real audio the file has.
            if reachedEOF {
                if let muxedBridge, let mapped = muxedBridgeIndex.flatMap({ streamMap[Int($0)] }) {
                    try muxedBridge.flush { encoded in
                        try write(encoded, to: mapped, from: muxedBridge.timeBase, writer: writer)
                    }
                }
                for rendition in renditions {
                    try rendition.flushBridge()
                }
            }

            // Final segment: whatever is buffered since the last cut, plus the
            // trailer's tail bytes, is one segment. A sub-6s source cuts here for
            // the first time, so this can also mint the init segment.
            let closingPTS = lastVideoEndPTS ?? nextBoundaryPTS
            let (initSegment, media) = try writer.cutSegment()
            if let initSegment, !initSegment.isEmpty {
                try writeInitSegmentIfAbsent(initSegment)
            }
            var finalSegment = media
            finalSegment.append(try writer.finish())
            let finalDuration = max(0.001, Double(closingPTS - (segmentStartPTS ?? closingPTS)) * tickSeconds)
            if !finalSegment.isEmpty, segmentStartPTS != nil {
                let file = String(format: "seg%05d.m4s", segmentIndex)
                try residentSegments.publish(index: segmentIndex,
                    start: Double(segmentStartPTS!) * tickSeconds, end: Double(closingPTS) * tickSeconds,
                    data: finalSegment, root: outputDirectory)
                if plannedPlan == nil {
                    try playlist.appendSegment(duration: finalDuration, file: file)
                }
                recordAndEvict(index: segmentIndex, videoBytes: finalSegment.count, renditionBytes: 0)
                if let start = segmentStartPTS {
                    try subtitles.flushSegment(
                        start: Double(start) * tickSeconds,
                        end: Double(closingPTS) * tickSeconds
                    )
                }
            }
            for rendition in renditions {
                try rendition.finish(durationSeconds: finalDuration, endList: reachedEOF)
            }
            // A sub-first-target source cuts here for the first time, so this
            // can be the write the readiness gate is waiting on.
            landed?.broadcast()
            if reachedEOF {
                try subtitles.finish()
                // ENDLIST only on a genuinely finished remux — a cancelled one leaves the
                // event playlist open-ended, and the session dir dies with stop().
                // (Planned playlists were born ended.)
                if plannedPlan == nil {
                    try playlist.finish()
                }
            }
            // Persist the harvest — complete when this contiguous run reached
            // EOF, partial otherwise (a cancelled play). A partial map used to
            // be thrown away as "worse than none", because a map that passes
            // the witnesses while covering half the file would plan segments
            // whose keyframes it never saw; it is now stored WITH its covered
            // end, and the planner trusts it only up to there
            // (`SegmentPlan.keyframePlan(coveredThroughPTS:)`), so the next
            // play of a source that could not be planned gets a seekable VOD
            // over exactly the prefix this one watched.
            if let keyframeCache, let cacheIdentity,
               let harvested = harvestedKeyframes, harvested.count >= 2,
               let covered = harvestCoveredThrough {
                let complete = reachedEOF && harvestRunExtendsCoverage
                keyframeCache.store(.init(
                    identity: cacheIdentity,
                    timeBaseNum: videoTimeBase.num,
                    timeBaseDen: videoTimeBase.den,
                    keyframePTS: Array(Set(harvested)).sorted(),
                    complete: complete,
                    coveredThroughPTS: complete ? nil : covered
                ))
            }

            // Park: EOF reached with a plan published — wait for demand.
            guard plannedPlan != nil, reachedEOF, !cancelled.isSet else { break produce }
            var idleAnchor: Int?
            while !cancelled.isSet {
                if let anchor = demand?.takeAnchorRequest(),
                   anchor >= 0, anchor < (plannedPlan?.entries.count ?? 0) {
                    idleAnchor = anchor
                    break
                }
                // Parked is where a SEEK finds the producer, so this wait was
                // the first hop of seek latency. It is now a real block on the
                // coordinator's condition: the fetch that asks for a segment
                // signals it, so the hop costs nothing at all, and a parked
                // producer stops burning a thread's worth of wakeups for the
                // length of a film (#44).
                demand?.waitForAnchorRequest(isCancelled: { [cancelled] in cancelled.isSet })
            }
            guard let anchor = idleAnchor else { break produce }
            try reanchor(to: anchor)
        }
    }

    /// Rescale one packet onto an output stream and hand it to the muxer.
    /// `sourceTimeBase` is the packet's own base — the input stream's for
    /// copied packets, the encoder's for bridged ones.
    private func write(
        _ packet: UnsafeMutablePointer<AVPacket>,
        to outputIndex: Int32,
        from sourceTimeBase: AVRational,
        writer: FMP4SegmentWriter
    ) throws {
        guard let output = writer.context else { return }
        let outStream = output.pointee.streams[Int(outputIndex)]!
        av_packet_rescale_ts(packet, sourceTimeBase, outStream.pointee.time_base)
        packet.pointee.stream_index = outputIndex
        packet.pointee.pos = -1
        try writer.write(packet)
    }

    // MARK: - Setup

    private func audioCandidates(_ input: UnsafeMutablePointer<AVFormatContext>) -> [AudioCandidate] {
        var candidates: [AudioCandidate] = []
        for index in 0..<Int(input.pointee.nb_streams) {
            let par = input.pointee.streams[index]!.pointee.codecpar.pointee
            guard par.codec_type == AVMEDIA_TYPE_AUDIO else { continue }
            let disposition = input.pointee.streams[index]!.pointee.disposition
            candidates.append(AudioCandidate(
                index: Int32(index),
                codecID: par.codec_id,
                isOriginal: disposition & AV_DISPOSITION_ORIGINAL != 0,
                isDefault: disposition & AV_DISPOSITION_DEFAULT != 0
            ))
        }
        return candidates
    }

    /// Every audio track worth carrying, as its own rendition.
    ///
    /// Order matters: the preferred track — whatever `chooseAudio` would have
    /// selected as the single one, i.e. the demuxer's best copyable or bridged
    /// track — comes first, because the first rendition is the one flagged
    /// `DEFAULT` in the master. The rest follow in container order, which is the
    /// order a user expects to see them listed in.
    ///
    /// Tracks that are neither copyable nor bridgeable here and now (no decoder
    /// in this build, or no EAC3 encoder — see `AudioBridge.isEncoderAvailable`)
    /// are skipped: a rendition AVPlayer can't play is worse than an absent one,
    /// because a failed rendition fetch can fail the whole item.
    static func routeAll(
        candidates: [AudioCandidate],
        best: Int32?,
        canBridge: (AVCodecID) -> Bool = { AudioBridge.canBridge(codecID: $0) }
    ) -> [AudioRoute] {
        let viable: [AudioRoute] = candidates.compactMap { candidate in
            if copyableAudio.contains(candidate.codecID) {
                return AudioRoute(index: candidate.index, mode: .streamCopy)
            }
            if canBridge(candidate.codecID) {
                return AudioRoute(index: candidate.index, mode: .bridge)
            }
            return nil
        }
        guard let preferred = chooseAudio(candidates: candidates, best: best, canBridge: canBridge),
              let position = viable.firstIndex(where: { $0.index == preferred.index })
        else { return viable }
        var ordered = viable
        ordered.remove(at: position)
        ordered.insert(preferred, at: 0)
        return ordered
    }

    /// Which extra dialogue-boost renditions to derive, given what the
    /// session asked for and what this build and source can deliver.
    ///
    /// Pure on purpose (same rule as `routeAll`): the decision is what must
    /// not drift, and it has to be testable without a demuxer or an encoder.
    ///
    /// - `base` is the DEFAULT rendition's route — boosts derive from the
    ///   track people are actually listening to, and only from it (cost).
    /// - `trackChannelCount >= 3` is the honest floor: a boost lifts a centre
    ///   channel, and stereo has none to lift. (Stereo needs FFmpeg's
    ///   `dialoguenhance`, which no current build ships — see
    ///   `DialogueBoostFilter`.) The layout-level check happens again at
    ///   bridge setup, where the real `AVChannelLayout` exists.
    /// - `boostIsBuildable` folds in the runtime reads: a decoder for the
    ///   track's codec, the EAC3 encoder, the `pan` filter.
    /// - Duplicate requested levels collapse to the first occurrence; a
    ///   rendition per repeated level would collide on NAME and pay twice.
    static func dialogueBoostRoutes(
        requested: [DialogueBoostLevel],
        base: AudioRoute?,
        trackChannelCount: Int,
        boostIsBuildable: Bool
    ) -> [AudioRoute] {
        guard let base, boostIsBuildable, trackChannelCount >= 3 else { return [] }
        var seen = Set<DialogueBoostLevel>()
        return requested.compactMap { level in
            guard seen.insert(level).inserted else { return nil }
            return AudioRoute(index: base.index, mode: .boost(level))
        }
    }

    /// Decide which single audio stream to carry, and how — the muxed shape's
    /// selection, and the one that decides which rendition is `DEFAULT`.
    ///
    /// Order of preference, and the reasoning:
    ///
    /// 0. A track the container marks as the film's **original** soundtrack.
    ///    Everything below this line ranks by what the audio *is* — codec,
    ///    channels, whether the bits can pass through untouched — and none of
    ///    that has any bearing on which language a film is meant to be heard
    ///    in. A dual-audio release whose dub is the richer encode used to win
    ///    on those grounds alone, so the film opened in the dub. Where the
    ///    source says which track is the original, that answers a different and
    ///    better question, and it goes first.
    /// 1. The demuxer's *best* stream when it is stream-copyable — untouched
    ///    bits beat anything we could re-encode, and this is the case that keeps
    ///    Atmos alive.
    /// 2. The best stream through the bridge. Before phase 3 this case fell back
    ///    to a lesser copyable track, which meant a DTS-HD MA 7.1 main track
    ///    lost to an AC3 2.0 compatibility track — the bridge makes the main
    ///    track the better answer even at a re-encode's cost.
    /// 3. The container's own **default** flag. Below the two above on purpose:
    ///    a market-specific disc flags its dub default, so this is a hint about
    ///    the release rather than about the film. It still beats container
    ///    order, which is what the two rungs below fall back to.
    /// 4. Any copyable stream, for sources whose best track can't be bridged
    ///    either (no decoder in this build, or no EAC3 encoder — see
    ///    `AudioBridge.isEncoderAvailable`). This is v0's behaviour, preserved
    ///    as the fallback rather than removed.
    /// 5. Any bridgeable stream at all.
    ///
    /// Rungs 0 and 3 are additive: a source that marks neither gets exactly the
    /// order it got before, which is why adding them cannot cost an Atmos track.
    ///
    /// What this still cannot do is prefer a *language*. That needs to know what
    /// the picture was shot in, which is a fact about the film that no container
    /// reliably carries — a host that knows it (from a metadata service, or from
    /// the person) is better placed, and can select over the top of the
    /// `DEFAULT` this produces.
    ///
    /// `canBridge` is injected so the decision can be exercised as a pure
    /// function in tests, independent of what the linked FFmpeg supports.
    static func chooseAudio(
        candidates: [AudioCandidate],
        best: Int32?,
        canBridge: (AVCodecID) -> Bool = { AudioBridge.canBridge(codecID: $0) }
    ) -> AudioRoute? {
        /// How this track would be carried, or `nil` when it cannot be.
        func route(_ candidate: AudioCandidate) -> AudioRoute? {
            if copyableAudio.contains(candidate.codecID) {
                return AudioRoute(index: candidate.index, mode: .streamCopy)
            }
            if canBridge(candidate.codecID) {
                return AudioRoute(index: candidate.index, mode: .bridge)
            }
            return nil
        }

        if let original = candidates.first(where: \.isOriginal), let route = route(original) {
            return route
        }
        if let best, let bestCandidate = candidates.first(where: { $0.index == best }) {
            if copyableAudio.contains(bestCandidate.codecID) {
                return AudioRoute(index: best, mode: .streamCopy)
            }
            if canBridge(bestCandidate.codecID) {
                return AudioRoute(index: best, mode: .bridge)
            }
        }
        if let flagged = candidates.first(where: \.isDefault), let route = route(flagged) {
            return route
        }
        if let copyable = candidates.first(where: { copyableAudio.contains($0.codecID) }) {
            return AudioRoute(index: copyable.index, mode: .streamCopy)
        }
        if let bridgeable = candidates.first(where: { canBridge($0.codecID) }) {
            return AudioRoute(index: bridgeable.index, mode: .bridge)
        }
        return nil
    }

    // MARK: - Video output stream

    /// Describe the video output stream: mirror the source's parameters, then
    /// make the two corrections a stream-copied HEVC track needs.
    ///
    /// Both edits have to happen here rather than after `write_header`, because
    /// with `delay_moov` the sample entries are built from `codecpar` at
    /// moov-flush time — the init segment is minted from whatever this closure
    /// leaves behind.
    private func configureVideoOutput(
        _ outStream: UnsafeMutablePointer<AVStream>,
        input: UnsafeMutablePointer<AVFormatContext>,
        videoIndex: Int32,
        declaredDolbyVision: DolbyVisionConfiguration?,
        rewriteDolbyVisionRecord: Bool,
        stripDolbyVisionRecord: Bool
    ) throws {
        let inStream = input.pointee.streams[Int(videoIndex)]!
        try FFmpegError.check(
            avcodec_parameters_copy(outStream.pointee.codecpar, inStream.pointee.codecpar),
            "avcodec_parameters_copy"
        )
        let par = outStream.pointee.codecpar!
        // The sample entry's fourcc, and it has to be said explicitly.
        //
        // FFmpeg's mp4 muxer defaults HEVC to **`hev1`**, not `hvc1` — a default
        // this code previously trusted to be `hvc1`, which was simply wrong.
        // Two things went wrong because of it, and only a real Matroska file
        // showed either:
        //
        // 1. Apple's HLS authoring rules want `hvc1`. `hev1` means parameter sets
        //    may arrive in band, which an HLS init segment is not supposed to
        //    rely on.
        // 2. `HVCCNormalizer` asserts `array_completeness = 1` — "every parameter
        //    set is in this entry" — which directly contradicts `hev1`, and
        //    movenc resolves that contradiction by writing **no `hvcC` box at
        //    all**. The record didn't just stay unnormalized; it disappeared. The
        //    synthetic fixture never caught it because its record already had
        //    completeness set, so the normalizer left it alone.
        //
        // P5 has no base layer: its picture is IPT-PQc2, not YCbCr, and the
        // *sample entry* is the only thing that tells a decoder so. An `hvc1`
        // entry over P5 decodes to the familiar green-and-purple picture, and it
        // also contradicts the `dvh1.05.xx` the master playlist declares — a
        // mismatch AVPlayer checks the manifest against. Declaring it in the
        // manifest alone was the bug; the fourcc is the other half.
        //
        // 8.x deliberately keeps `hvc1`: its base layer IS plain-HEVC-compatible,
        // and the `dvvC` box is what upgrades it. Saying `dvh1` there would deny
        // the fallback that makes 8.1 worth having.
        par.pointee.codec_tag = declaredDolbyVision?.isSingleLayerDVOnly == true
            ? Self.fourCC("dvh1")
            : (par.pointee.codec_id == AV_CODEC_ID_HEVC ? Self.fourCC("hvc1") : 0)

        // `hvcC` → `hvc1`-correct form. Only HEVC has the problem (an `avcC`
        // carries no arrays to normalize), and `normalize` returns nil when the
        // record was already right, so the common case keeps the source's own
        // extradata pointer.
        if par.pointee.codec_id == AV_CODEC_ID_HEVC,
           let extradata = par.pointee.extradata, par.pointee.extradata_size > 0 {
            let current = Data(bytes: extradata, count: Int(par.pointee.extradata_size))
            if let normalized = HVCCNormalizer.normalize(hvcC: current) {
                try Self.setExtradata(normalized, on: par)
            }
        }

        // A converted P7 must be *declared* 8.1: movenc writes the `dvcC`/`dvvC`
        // box from this side data (picking the fourcc by profile — `dvcC` through
        // 7, `dvvC` from 8), and a box that still said profile 7 would send an
        // Apple TV looking for an enhancement layer that is no longer there.
        // Unconverted sources keep the record `avcodec_parameters_copy` brought
        // across, which is already theirs.
        if rewriteDolbyVisionRecord, let declaredDolbyVision {
            try Self.setDolbyVisionConfiguration(declaredDolbyVision, on: par)
        }

        // Dropping the manifest's Dolby Vision claim is only half of dropping
        // Dolby Vision. `avcodec_parameters_copy` brought the source's
        // `AV_PKT_DATA_DOVI_CONF` across, movenc writes it into the sample
        // entry as a `dvvC` box, and a `hvc1` entry carrying a `dvvC` is
        // refused by AVPlayer's compatibility gate **on its own** — with or
        // without a `SUPPLEMENTAL-CODECS` attribute in the manifest.
        //
        // That made the master-rejection fallback's first tier unwinnable for
        // every Dolby Vision source. The tier exists to retry without the DV
        // claim; it re-served the same `dvvC`, was refused for the same reason,
        // and its whole cost — a new session, which over a network means
        // reopening and reprobing the source and producing its first segments
        // again, ~6.4 s in one field log — bought a second identical `-11868`
        // before the muxed tier finally played.
        //
        // Only ever for a profile with a real base layer. Profile 5's picture
        // is IPT-PQc2 and the record is what says so: strip it there and the
        // green-and-purple misread is what plays. P5 on a non-DV display is
        // already handled a level up, by refusing to build a master at all.
        if Self.shouldStripDolbyVisionRecord(
            declared: declaredDolbyVision, displayIsDolbyVisionCapable: !stripDolbyVisionRecord
        ) {
            av_packet_side_data_remove(
                par.pointee.coded_side_data,
                &par.pointee.nb_coded_side_data,
                AV_PKT_DATA_DOVI_CONF
            )
        }
    }

    /// Whether the served sample entry must carry **no** `dvvC`/`dvcC` box.
    ///
    /// Pure, and separate from the muxer plumbing above, because the rule is
    /// what is worth pinning: the byte-level effect needs a real Dolby Vision
    /// source (ffmpeg cannot synthesize an RPU, hence `RealMediaVerification`),
    /// while the decision is three cases that must not drift.
    ///
    /// - A configuration AVFoundation cannot present as DV is stripped on ANY
    ///   display (`isPresentableAsDolbyVision`). This is the case a DV-capable
    ///   display used to fall straight through: a Profile 7 source that isn't
    ///   being converted keeps the record `avcodec_parameters_copy` brought
    ///   across, so the served `hvc1` entry carries a `dvcC` announcing a
    ///   dual-layer stream — an enhancement layer Apple has no decoder for and,
    ///   for a converted stream, one that is not even there any more. The
    ///   manifest prints no claim for these profiles (`dolbyVisionBrand`
    ///   returns nil for 7, for 8.2 and for anything unrecognised), and a
    ///   sample entry that claims what the manifest doesn't is exactly the
    ///   mismatch the note above says AVPlayer refuses on its own.
    /// - A DV-capable display otherwise keeps the record: it is what engages DV.
    /// - Profile 5 keeps it on any display, because for P5 the record is not an
    ///   upgrade but the *description* — its picture is IPT-PQc2, and an entry
    ///   that omits the record has it read as YCbCr (the green-and-purple
    ///   misread). P5 on a non-DV display is refused a master a level up
    ///   instead, which is the honest answer there.
    /// - Everything else — a base-layer-compatible profile going to a display
    ///   that cannot present DV — is stripped, so the sample entry matches a
    ///   manifest that is no longer claiming DV.
    static func shouldStripDolbyVisionRecord(
        declared: DolbyVisionConfiguration?, displayIsDolbyVisionCapable: Bool
    ) -> Bool {
        guard let declared else { return false }
        guard declared.isPresentableAsDolbyVision else { return true }
        guard !displayIsDolbyVisionCapable else { return false }
        return !declared.isSingleLayerDVOnly
    }

    /// A big-endian fourcc as libavcodec's `codec_tag` wants it: first character
    /// in the low byte (what FFmpeg's `MKTAG` macro builds, and the macro doesn't
    /// survive the C importer).
    static func fourCC(_ code: String) -> UInt32 {
        let bytes = Array(code.utf8)
        precondition(bytes.count == 4, "a fourcc is four ASCII characters")
        return UInt32(bytes[0]) | UInt32(bytes[1]) << 8
            | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    }

    /// Replace a codecpar's extradata with `data`.
    ///
    /// The allocation rules are libavcodec's, not ours: the buffer must come from
    /// `av_malloc` with `AV_INPUT_BUFFER_PADDING_SIZE` zeroed bytes past the end
    /// (bitstream readers over-read by design), and the old buffer must be freed
    /// with `av_free`. Getting either wrong is a crash inside FFmpeg, not a Swift
    /// error.
    private static func setExtradata(
        _ data: Data,
        on par: UnsafeMutablePointer<AVCodecParameters>
    ) throws {
        let padding = Int(AV_INPUT_BUFFER_PADDING_SIZE)
        guard let buffer = av_malloc(data.count + padding) else {
            throw FFmpegError(code: -1, operation: "av_malloc(extradata)")
        }
        data.withUnsafeBytes { source in
            _ = memcpy(buffer, source.baseAddress!, data.count)
        }
        _ = memset(buffer.advanced(by: data.count), 0, padding)
        av_free(par.pointee.extradata)
        par.pointee.extradata = buffer.assumingMemoryBound(to: UInt8.self)
        par.pointee.extradata_size = Int32(data.count)
    }

    /// Put an `AVDOVIDecoderConfigurationRecord` on the stream as
    /// `AV_PKT_DATA_DOVI_CONF`, replacing whatever the source's own record said.
    ///
    /// `av_packet_side_data_add` takes ownership of the buffer (hence `av_malloc`)
    /// and replaces an existing entry of the same type, which is exactly the
    /// semantics wanted here: `avcodec_parameters_copy` already brought the P7
    /// record across.
    private static func setDolbyVisionConfiguration(
        _ configuration: DolbyVisionConfiguration,
        on par: UnsafeMutablePointer<AVCodecParameters>
    ) throws {
        let size = MemoryLayout<AVDOVIDecoderConfigurationRecord>.size
        guard let buffer = av_malloc(size) else {
            throw FFmpegError(code: -1, operation: "av_malloc(dovi conf)")
        }
        let record = buffer.assumingMemoryBound(to: AVDOVIDecoderConfigurationRecord.self)
        record.pointee = AVDOVIDecoderConfigurationRecord()
        record.pointee.dv_version_major = configuration.versionMajor
        record.pointee.dv_version_minor = configuration.versionMinor
        record.pointee.dv_profile = configuration.profile
        record.pointee.dv_level = configuration.level
        record.pointee.rpu_present_flag = configuration.rpuPresent ? 1 : 0
        record.pointee.el_present_flag = configuration.enhancementLayerPresent ? 1 : 0
        record.pointee.bl_present_flag = configuration.baseLayerPresent ? 1 : 0
        record.pointee.dv_bl_signal_compatibility_id = configuration.baseLayerSignalCompatibilityID

        guard av_packet_side_data_add(
            &par.pointee.coded_side_data,
            &par.pointee.nb_coded_side_data,
            AV_PKT_DATA_DOVI_CONF,
            buffer,
            size,
            0
        ) != nil else {
            av_free(buffer)
            throw FFmpegError(code: -1, operation: "av_packet_side_data_add(DOVI_CONF)")
        }
    }

    /// Rewrite a demuxed packet's payload through `rewrite`, which walks the
    /// current buffer and, only if it changes something, asks for an output
    /// buffer of the exact size and fills it. That buffer is `av_malloc`ed
    /// here (with `AV_INPUT_BUFFER_PADDING_SIZE` zeroed bytes, as libavcodec's
    /// readers over-read by design) and swapped into the packet as its new
    /// `AVBufferRef` — the demuxer's buffer, possibly shared, is released
    /// rather than made writable and grown. One write of the new bytes, no
    /// copy of the old ones.
    private static func rewritePayload(
        of packet: UnsafeMutablePointer<AVPacket>,
        rewrite: (UnsafeBufferPointer<UInt8>, (Int) -> UnsafeMutablePointer<UInt8>?) -> Bool
    ) throws {
        guard let data = packet.pointee.data, packet.pointee.size > 0 else { return }
        let source = UnsafeBufferPointer(start: UnsafePointer(data), count: Int(packet.pointee.size))
        var replacement: UnsafeMutablePointer<AVBufferRef>?
        var replacementSize = 0
        let changed = rewrite(source) { size in
            let padding = Int(AV_INPUT_BUFFER_PADDING_SIZE)
            guard let buffer = av_buffer_alloc(Int(size + padding)) else { return nil }
            _ = memset(buffer.pointee.data.advanced(by: size), 0, padding)
            replacement = buffer
            replacementSize = size
            return buffer.pointee.data
        }
        guard changed, let replacement else {
            if let stale = replacement { var buffer: UnsafeMutablePointer<AVBufferRef>? = stale; av_buffer_unref(&buffer) }
            return
        }
        // Side data and timestamps stay; only the payload's backing moves.
        av_buffer_unref(&packet.pointee.buf)
        packet.pointee.buf = replacement
        packet.pointee.data = replacement.pointee.data
        packet.pointee.size = Int32(replacementSize)
    }

    /// A converter for this source, or `nil` when there is nothing to convert.
    ///
    /// Only Profile 7 qualifies. P5 has no HDR10 base to fall back to (its
    /// conversion target would be a different picture, not a different wrapper),
    /// 8.x is already single-layer, and a source with no DV configuration has no
    /// RPUs to rewrite.
    private func makeDolbyVisionConverter(video: VideoTrackInfo) -> DolbyVisionRPUConverter? {
        guard let dv = video.dolbyVision, dv.isDualLayer, dv.rpuPresent else { return nil }
        guard video.hevcConfiguration != nil else { return nil }
        // The prefix width comes from the record itself; a source whose hvcC we
        // couldn't parse never gets here (no `CODECS` string either, so it plays
        // media-direct).
        return DolbyVisionRPUConverter(lengthSize: video.nalUnitLengthSize)
    }

    // MARK: - Master playlist description

    /// The video half of the master's variant, or `nil` when this source can't
    /// be declared honestly (no `CODECS` string to be had, or a dynamic range
    /// this display isn't ready for). `nil` routes the session to the muxed
    /// shape — see the type's doc.
    ///
    /// - Parameter dolbyVision: the configuration to *declare*, which is the
    ///   converted 8.1 record for a P7 source being converted and the source's
    ///   own otherwise.
    private func makeVideoVariant(
        input: UnsafeMutablePointer<AVFormatContext>,
        video: VideoTrackInfo,
        dolbyVision: DolbyVisionConfiguration?
    ) -> MasterPlaylistBuilder.VariantDescription? {
        guard let codec = videoCodecDeclaration(for: video) else { return nil }

        guard Self.masterVariantPermitted(
            dynamicRange: video.dynamicRange,
            dolbyVision: dolbyVision,
            displayIsHDRReady: displayIsHDRReady,
            displayIsDolbyVisionCapable: displayIsDolbyVisionCapable
        ) else { return nil }

        return MasterPlaylistBuilder.VariantDescription(
            mediaPlaylistURI: Self.mediaPlaylistFileName,
            bandwidth: sourceBandwidth(input: input),
            resolution: video.width > 0 && video.height > 0
                ? .init(width: video.width, height: video.height)
                : nil,
            frameRate: video.frameRate,
            dynamicRange: video.dynamicRange,
            videoCodec: codec,
            dolbyVision: dolbyVision,
            displayIsDolbyVisionCapable: displayIsDolbyVisionCapable
        )
    }

    /// Whether this source may be wrapped in a master playlist for this
    /// display at all. `false` routes the session media-direct.
    ///
    /// - A range the display can't take must not be claimed, and must not be
    ///   *mis*-claimed either: declaring an HDR10 stream as SDR doesn't fool
    ///   the compatibility gate (it reads the bitstream's own `colr`), it only
    ///   makes the manifest a lie. So an HDR source on a display the host
    ///   hasn't vouched for gets no master, which is exactly the shape v0
    ///   already served it.
    /// - Profile 5 on a non-DV display gets no master either, *proactively*:
    ///   its primary tag is a bare `dvh1.05.xx` (there is no base codec to
    ///   fall back to and no `SUPPLEMENTAL-CODECS` brand for P5), so a non-DV
    ///   client's variant filter rejects the whole master with `-11868` —
    ///   there is no sibling variant it could pick instead. Media-direct is
    ///   the route that works there: AVPlayer tone-maps from the `dvh1`
    ///   sample entry. Serving the master just to watch it be refused would
    ///   burn a failed load on every P5 play.
    static func masterVariantPermitted(
        dynamicRange: DynamicRange,
        dolbyVision: DolbyVisionConfiguration?,
        displayIsHDRReady: Bool,
        displayIsDolbyVisionCapable: Bool
    ) -> Bool {
        guard dynamicRange == .sdr || displayIsHDRReady else { return false }
        if let dv = dolbyVision, dv.isSingleLayerDVOnly, !displayIsDolbyVisionCapable {
            return false
        }
        return true
    }

    /// How the video codec is declared — from the container's own configuration
    /// record, never guessed. Annex-B extradata (MPEG-TS) has no record, so
    /// there is no honest `CODECS` string and the source plays media-direct
    /// rather than risk an over-claim AVPlayer checks against the init segment.
    private func videoCodecDeclaration(
        for video: VideoTrackInfo
    ) -> MasterPlaylistBuilder.VideoCodec? {
        if let hevc = video.hevcConfiguration { return .hevc(hevc) }
        if let avc = video.avcConfiguration { return .avc(avc) }
        if let av1 = video.av1Configuration { return .av1(av1) }
        return nil
    }

    /// `BANDWIDTH` for the single variant: the container's own bit rate, or the
    /// streams' summed rates, or the file's size over its duration.
    ///
    /// A one-variant master has nothing to switch between, so this attribute is
    /// informational — but it is mandatory, and AVPlayer uses it to size its
    /// read-ahead, so an order-of-magnitude-honest number is worth the three
    /// lookups. The last resort is a deliberately generous 4K-ish figure:
    /// over-stating it costs a bigger buffer, under-stating it can make AVPlayer
    /// pace fetches below what the stream needs.
    private func sourceBandwidth(input: UnsafeMutablePointer<AVFormatContext>) -> Int {
        if input.pointee.bit_rate > 0 { return Int(input.pointee.bit_rate) }

        var summed: Int64 = 0
        for index in 0..<Int(input.pointee.nb_streams) {
            summed += max(0, input.pointee.streams[index]!.pointee.codecpar.pointee.bit_rate)
        }
        if summed > 0 { return Int(summed) }

        if sourceURL.isFileURL, input.pointee.duration != swift_AV_NOPTS_VALUE(),
           input.pointee.duration > 0,
           let size = try? FileManager.default
               .attributesOfItem(atPath: sourceURL.path)[.size] as? Int, size > 0 {
            let seconds = Double(input.pointee.duration) / Double(AV_TIME_BASE)
            return max(1, Int(Double(size) * 8 / seconds))
        }
        return 25_000_000
    }
}

/// Tiny lock-protected flag — the cancel signal crossing from the session
/// actor into the synchronous copy loop.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.withLock { value }
    }

    func set() {
        lock.withLock { value = true }
    }
}
