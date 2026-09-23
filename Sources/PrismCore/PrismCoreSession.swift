import Foundation
import CoreGraphics

/// One playback session: remux `sourceURL` into HLS-fMP4 on disk and serve it
/// from the loopback. The host plays the returned playlist URL with its own
/// `AVPlayer` — PrismCore v0 is a service, not a player (see README).
///
/// ```swift
/// let session = try PrismCoreSession(url: mkvURL)
/// let playlist = try await session.start()
/// player.replaceCurrentItem(with: AVPlayerItem(url: playlist))
/// …
/// await session.stop()
/// ```
///
/// The URL that comes back is the **master** playlist whenever the source has
/// audio worth carrying as alternate renditions (`master.m3u8`), and the media
/// playlist (`index.m3u8`) when it hasn't — a silent source, or one whose master
/// couldn't be written honestly (see `HLSRemuxer`). Hosts should treat the URL as
/// opaque: the shape is a property of the source, not of the API.
///
/// ## The tvOS playback contract
///
/// On tvOS the panel's HDMI mode has to be programmed **before** AVPlayer sees
/// the playlist — tvOS validates an HDR variant's `VIDEO-RANGE` against the
/// panel's *current* mode, synchronously, so a PQ master handed to an
/// SDR-parked panel fails outright (`-11848`/`-11868`) instead of switching or
/// tone-mapping. The order that works:
///
/// ```swift
/// let playlist = try await session.start()
/// if let choice = await session.displayCriteria {   // 1. program the panel
///     criteriaController.apply(choice)
///     await criteriaController.waitForSwitch()      // 2. let it settle
/// }
/// player.replaceCurrentItem(with: AVPlayerItem(url: playlist))  // 3. then load
/// player.play()
/// ```
///
/// AVKit's `appliesPreferredDisplayCriteriaAutomatically` must be `false` for
/// these sessions: it derives criteria from the chosen variant's format
/// description, which only exists *after* the variant passes the very
/// validation the switch has to precede — and its late write races the one
/// above into a double handshake. `MasterRejection` remains the backstop for
/// the panel states no read can prove (Match Content off on an HDR panel).
public actor PrismCoreSession {
    private let cachedPreview = CachedSegmentPreview()
    private var stopped = false
    /// The audio offset the producer is muxing with right now, in seconds —
    /// what a host should show as the current lip-sync correction.
    ///
    /// Not necessarily the last value handed to `setAudioDelaySeconds(_:)`:
    /// see `pendingAudioDelaySeconds` and the contract on that method.
    public var audioDelaySeconds: Double { remuxer.audioDelaySeconds }

    /// A requested offset the producer has not taken up yet, or `nil` when
    /// there is none. Non-nil means what is being served still carries
    /// `audioDelaySeconds`.
    ///
    /// The moment it clears, nothing muxed with the old offset can be served
    /// any more: a fetch made at that instant either gets a rewritten segment
    /// or waits for one. So "poll this, then refresh the player" is safe
    /// without a delay of the host's own — the cost is the re-buffer
    /// `pendingReanchor` documents, not a stale correction.
    public var pendingAudioDelaySeconds: Double? { remuxer.pendingAudioDelaySeconds }

    /// `audioDelaySeconds` and `pendingAudioDelaySeconds` sampled together.
    /// Internal: only a caller asserting how the two RELATE needs them
    /// atomic, and that caller is a test (see `HLSRemuxer.audioDelayReport`).
    var audioDelayReport: (serving: Double, pending: Double?) { remuxer.audioDelayReport }

    /// What `setAudioDelaySeconds(_:)` did.
    public enum AudioDelayChange: Sendable, Equatable {
        /// In force before the call returned. Only happens before `start()`,
        /// when no segment has been written with the old value.
        case inForce
        /// Accepted, and a producer re-anchor has been asked for. Segments
        /// muxed with the old offset are discarded as it lands, so nothing
        /// stale can be served afterwards — but AVPlayer plays what it has
        /// ALREADY buffered (several seconds) at the old offset, and only
        /// hears the new one once that drains or the host seeks. Poll
        /// `pendingAudioDelaySeconds` for the moment it takes effect.
        case pendingReanchor
        /// This session cannot change the offset: its source could not be
        /// planned (live, or a container with no usable index), so the
        /// producer runs once head-to-EOF and never re-anchors. The request
        /// is NOT stored — a new session is the only way. Nothing changed.
        case unsupported
        /// The session is stopped. Nothing changed.
        case sessionStopped
    }

    /// Change the audio offset while the title is playing — lip-sync
    /// correction is something a viewer turns with the picture in front of
    /// them, not a value chosen before the first frame.
    ///
    /// Clamped to +/-2 s; a non-finite value becomes zero. Video, subtitles
    /// and the source clock are untouched.
    ///
    /// **When it takes effect.** On this (remux) path, never immediately: the
    /// engine serves fMP4 segments that were written with the previous offset,
    /// and the offset moves audio dts, which cannot step backwards inside a
    /// fragment the muxer is already writing. The call asks the producer to
    /// re-anchor at the playhead; at that re-anchor the new offset goes in
    /// force and every segment written with the old one is discarded, so a
    /// later seek cannot serve audio at the offset the viewer corrected away
    /// from. The cost is visible: the picture re-buffers while production
    /// catches up, and the host should tell the viewer so. The return value
    /// and `pendingAudioDelaySeconds` are the honest report of where the
    /// change stands — `audioDelaySeconds` only ever names what is in force.
    ///
    /// The software path answers a different question with the same name:
    /// `SoftwarePlaybackPipeline.setAudioDelaySeconds(_:completion:)` takes
    /// effect at the renderer, within the queue's depth, with no re-buffer.
    @discardableResult
    public func setAudioDelaySeconds(_ seconds: Double) -> AudioDelayChange {
        guard !stopped else { return .sessionStopped }
        guard started else {
            // Nothing is on disk yet, so there is nothing to invalidate and
            // no re-anchor to wait for.
            remuxer.audioDelaySeconds = seconds
            return .inForce
        }
        return remuxer.requestAudioDelay(seconds) ? .pendingReanchor : .unsupported
    }
    /// Summary of usable base audio routes. Inspect audioTrackDeliveries when
    /// multiple renditions have different outcomes; the host owns selection.
    public nonisolated var audioDelivery: AudioDelivery { remuxer.audioDeliveryStore.summary }
    public nonisolated var audioTrackDeliveries: [AudioTrackDelivery] { remuxer.audioDeliveryStore.snapshot }

    /// Completed video intervals on the SOURCE timestamp axis, which may have
    /// a nonzero origin. Not AVPlayer.loadedTimeRanges. Poll for timeline UI.
    public nonisolated var residentRanges: [ResidentRange] { remuxer.residentSegments.ranges }

    /// A segment-granularity still, or nil when that interval is not resident.
    /// Never opens the source or asks the producer to seek. The requested time
    /// uses the same source axis as residentRanges.
    public func cachedThumbnail(at seconds: Double, maxDimension: Int = 320) async throws -> CGImage? {
        guard !stopped, let snapshot = remuxer.residentSegments.snapshot(at: seconds, root: workDirectory) else { return nil }
        let image = try await cachedPreview.image(index: snapshot.index, data: snapshot.data, maxDimension: maxDimension)
        return stopped ? nil : image
    }

    public enum SessionError: Error {
        /// The remux produced no playable playlist within the startup budget.
        case startupTimedOut(underlying: (any Error)?)
        /// A registration call that only makes sense before `start()` arrived
        /// after it. Silently ignoring it would leave a subtitle track the host
        /// believes exists but that no rendition backs.
        case alreadyStarted
        /// A second successor was asked of a session that already minted one.
        /// Successors chain, they do not fan out — see `makeSession(changing:)`.
        case alreadySuperseded
    }

    /// Everything the session was built from, kept verbatim so a successor can
    /// be a faithful clone. A session is single-use, so "play this differently"
    /// — a rejected master, a dialogue-boost level the viewer just asked for —
    /// has to mean "a new session with the same inputs, one value moved".
    ///
    /// Read it off a session with `options`, hand a mutated copy back through
    /// `makeSession(changing:)`.
    public struct Options: Sendable, Equatable {
        /// The media this session plays. Not settable through a clone: a
        /// successor is the *same* title with one setting moved, and it
        /// inherits this session's external-subtitle registrations and cue
        /// handler — replaying those onto a different file would attach
        /// somebody else's captions to it.
        public private(set) var sourceURL: URL
        /// Request headers for a remote source, unchangeable for the same
        /// reason: they are how the source is reached, not how it is played.
        public private(set) var httpHeaders: [String: String]
        /// What the display can present. Clamping `isDolbyVisionCapable` is
        /// what the DV-less rejection tier does.
        public var display: DisplayCapabilities
        /// Disk budget for produced segments; `nil` keeps everything. A
        /// successor gets its own directory, so this budget applies to it
        /// alone — see `makeSession(changing:)` on stopping the predecessor.
        public var segmentCacheBytes: Int?
        /// Mux the one best audio track into the variant (v0 shape) instead of
        /// serving a master with renditions.
        public var forceMuxedShape: Bool
        public var keyframeIndexCacheDirectory: URL?
        public var dialogueBoost: [DialogueBoostLevel]
        /// Which audio rendition is marked DEFAULT, and which track dialogue
        /// boost derives from. No match leaves the source's own order standing.
        public var preferredAudioLanguage: String?
        /// Which subtitle rendition is marked DEFAULT. Nothing is marked
        /// without it — see the doc on the initializer before pairing this
        /// with a host-drawn overlay.
        public var preferredSubtitleLanguage: String?
        /// Clamped to ±2 s when the session is built, so a value read back here
        /// is the one in force, not the one asked for.
        public var audioDelaySeconds: Double
        public var coordinatedHTTP: Bool
        /// Whether the server is reachable beyond `127.0.0.1`. Carried by a
        /// clone, or a master rejection would quietly drop an AirPlayed
        /// session back onto an address the receiver cannot reach.
        public var reachability: LoopbackHTTPServer.Reachability
    }

    /// Where this session's server is reachable, and whether it still is.
    ///
    /// `.loopback` for every session that did not opt into LAN reachability.
    /// A session that did should be watched for `.addressLost` (a Wi-Fi to
    /// Ethernet swap mid-playback): the served URL cannot be revived, so the
    /// honest response is to stop and start a new session.
    public var serviceAddress: LoopbackHTTPServer.ServiceAddress {
        get async { await server.serviceAddress }
    }

    /// What this session was built from — the starting point for
    /// `makeSession(changing:)`.
    ///
    /// `audioDelaySeconds` reads back as the value last **asked for**, which on
    /// the remux path can still be waiting on a re-anchor here. That is the
    /// value a successor should be built with (it writes every segment itself,
    /// so the request is in force there from the first packet); read
    /// `PrismCoreSession.audioDelaySeconds` for what this session is serving.
    public var options: Options {
        var current = configuration
        current.audioDelaySeconds = audioDelayForClone
        return current
    }

    private let configuration: Options
    /// How this session's bytes are fetched, when the host supplies them.
    /// Deliberately NOT in `Options`: it belongs with `sourceURL` — a clone is
    /// the same title reached the same way, one *playback* setting moved — and
    /// a closure cannot be `Equatable`, which `Options` is.
    private let inputFactory: PrismCoreInputFactory?
    /// A session mints at most one successor (`makeSession(changing:)`).
    private var hasSuccessor = false

    /// What a clone (fallback session) carries: the value the host last asked
    /// for, pending or not. A fresh session writes every segment itself, so a
    /// request this one could not take up yet is in force there from the
    /// first packet.
    private var audioDelayForClone: Double {
        remuxer.pendingAudioDelaySeconds ?? remuxer.audioDelaySeconds
    }
    /// External subtitle registrations, replayed onto a fallback session.
    private var externalSubtitles: [(url: URL, language: String?, name: String?, isForced: Bool)] = []
    /// The host's cue sink, replayed onto a fallback session the same way —
    /// a master rejection must not silently cost the host its captions.
    private var timedTextCueHandler: (@Sendable (TimedTextCue) -> Void)?
    /// Where this session's playlists and segments live. Internal so the
    /// startup-cost benchmark can watch artifacts appear as they land.
    let workDirectory: URL
    private let server: LoopbackHTTPServer
    private let remuxer: HLSRemuxer
    /// The producer's per-write broadcast: what `start()` sleeps on until
    /// the video variant is playable, and what the provider's pending serves
    /// sleep on until their file lands (replacing two 10 ms polls).
    private let landed = ProductionSignal()
    /// The remux's own thread. Not a `Task`: `run()` blocks in FFmpeg reads and
    /// parks at EOF, which is a contract violation on the cooperative pool and
    /// a deadlock once several sessions do it at once (#44, `ProducerThread`).
    private var producer: ProducerThread?
    private var started = false

    /// What the Profile 7 → 8.1 conversion did, or `nil` when this source isn't a
    /// converted P7. Populated from the first produced segment onwards, so it can
    /// be read as soon as playback starts.
    ///
    /// Worth logging rather than ignoring: `isClean` false means the master's
    /// `dvh1.08.xx/db1p` claim doesn't describe every frame.
    /// Total compressed bytes the remux has read from the SOURCE — the number
    /// behind an honest "network" figure for a session played off this
    /// engine's loopback server, where AVFoundation's own access log can only
    /// see the loopback. Monotonic from session start; differentiate between
    /// two reads to get a rate. Slightly under the wire truth (container
    /// framing isn't counted).
    /// `nonisolated`: the counter is lock-guarded inside the remuxer, and the
    /// host polls it from its stats timer — hopping the actor for a read
    /// would serialize a diagnostics poll behind remux work.
    public nonisolated var sourceBytesRead: Int64 { remuxer.sourceBytesRead }

    public var dolbyVisionConversion: DolbyVisionConversionStats? {
        remuxer.dolbyVisionConversionStats
    }

    /// What the **bitstream** said about object audio on this session's
    /// stream-copied E-AC-3 tracks, one finding per track, in stream order.
    ///
    /// Empty until the first such track has been asked (a segment's worth of
    /// packets into production), and it stays empty for a source that has no
    /// stream-copied E-AC-3 track to ask about. A track that never appears here
    /// was never a candidate; a track that appears with `isObjectAudio == false`
    /// was asked and answered no.
    ///
    /// Worth surfacing rather than repeating `AudioTrackInfo.isObjectAudio`:
    /// that flag is the container's claim, and the container is frequently
    /// silent about JOC. `wasMissedByMetadata` is exactly the case where saying
    /// "Dolby Atmos" needs this answer instead of that one.
    public var objectAudio: [ObjectAudioFinding] {
        remuxer.objectAudioFindings
    }

    /// Whether this build can produce dialogue-boost renditions at all: the
    /// EAC3 encoder (absent from stock MPVKit — the same gate as the audio
    /// bridge) and libavfilter's `pan`. Read this before offering the control
    /// in UI; a per-source answer (does the default track have a centre
    /// channel, did the renditions land) is `dialogueBoostRenditions` after
    /// `start()`.
    public static var isDialogueBoostAvailable: Bool {
        AudioBridge.isEncoderAvailable && DialogueBoostFilter.isAvailable
    }

    /// The dialogue-boost renditions the served master actually declares —
    /// level plus the exact `NAME`, which is the matching
    /// `AVMediaSelectionOption.displayName`. Populated once the master is
    /// written (any time after `start()` returns); empty when none were
    /// requested, the build can't produce them, the default track has no
    /// centre channel, or the session fell back to the muxed shape. The
    /// robust way to *find* the options is the
    /// `.enhancesSpeechIntelligibility` media characteristic; this list is
    /// for building the host's own level picker.
    public var dialogueBoostRenditions: [DialogueBoostRendition] {
        remuxer.dialogueBoostRenditions
    }

    /// The source's chapter marks (Matroska `Chapters`, MP4 chapter tracks),
    /// in start order — empty for a source without them.
    ///
    /// Populated once the remux has probed the source, so it is ready by the
    /// time `start()` returns. Chapters are the host's to present: HLS has no
    /// way to carry them, so nothing about the served playlist changes — this
    /// is the data behind a chapter-skip button or timeline markers. A host
    /// that routed via `SourceProbe.open` already holds the same list on
    /// `ProbedSource.info.chapters` (which is also where the software path
    /// gets it), and this property merely saves it the bookkeeping.
    public var chapters: [ChapterInfo] {
        remuxer.sourceChapters
    }

    /// The remux's terminal error, if it failed after startup. Hosts can poll
    /// this when AVPlayer reports a stalled item.
    public private(set) var remuxError: (any Error)?

    /// The same failure, classified — what the host branches on.
    ///
    /// `remuxError` keeps its shape and meaning (a host logging it verbatim
    /// keeps working); this is the machine-readable read of it. Both are `nil`
    /// until the remux dies.
    public var remuxFailure: PrismCoreError? {
        remuxError.map(PrismCoreError.classify)
    }

    /// The display criteria to program before AVPlayer loads this session's
    /// playlist — step 1 of the tvOS playback contract (see the type doc).
    ///
    /// Populated once the remux has probed the source, so it is ready by the
    /// time `start()` returns. `nil` only before that, or when the remux died
    /// before probing. Computed from the same declared Dolby Vision
    /// configuration the manifest claims (a converted P7 asks for DV as its
    /// declared 8.1), and clamped to the session's `DisplayCapabilities` — a
    /// non-DV display is asked for the base layer's range, a non-HDR-ready
    /// display for a rate-only (SDR) switch. Platforms whose panels engage
    /// HDR on demand (built-in iPhone/iPad/Mac displays) can ignore it; over
    /// HDMI it is the difference between playing and `-11848`.
    public var displayCriteria: DisplayCriteriaChoice? {
        remuxer.displayCriteriaChoice
    }

    /// - Parameters:
    ///   - displayIsHDRReady: whether the display this session plays to is in
    ///     (or will switch into) the source's own dynamic range. Only a host
    ///     knows this, and getting it wrong is expensive: an HDR variant offered
    ///     to an SDR-parked panel is rejected outright rather than tone-mapped,
    ///     so the default is `false` and an HDR source then keeps v0's
    ///     media-playlist shape — which means its audio stays muxed and
    ///     unswitchable until the host opts in. Phase 4 is where this becomes a
    ///     read instead of a parameter.
    ///   - displayIsDolbyVisionCapable: whether that display can present Dolby
    ///     Vision. Same reasoning; `false` simply omits the DV claims.
    ///   - segmentCacheBytes: disk budget for produced segments. Only
    ///     enforced when the source got a demand-driven plan — there a deleted
    ///     segment is reproduced on the next fetch, so the budget bounds disk,
    ///     not seekability. `nil` keeps everything for the session's lifetime.
    ///   - forceMuxedShape: skip the master/renditions shape and mux the one
    ///     best audio track into the variant (v0 shape). This is the host's
    ///     fallback when AVPlayer refuses a served master (-11868 / -11848 /
    ///     -1002): make a NEW session with this set — the rejected master's
    ///     variant alone would be silent video, renditions live only in
    ///     masters.
    ///   - keyframeIndexCacheDirectory: where harvested keyframe maps persist
    ///     across sessions (issue #34) — a host-owned cache directory
    ///     (`Caches/…` is right: entries are cheap to lose). A source whose
    ///     container carries no usable seek index (Matroska without Cues,
    ///     MPEG-TS) plays sequentially on its first run while the producer
    ///     harvests every keyframe it reads anyway; the next play of the same
    ///     source plans on that map — full demand-driven seeking, as if the
    ///     file had an index. `nil` (the default) turns persistence off.
    ///   - dialogueBoost: extra "Dialogue Boost" audio renditions to derive
    ///     from the default track, one per level. See the `dialogueBoost`
    ///     doc on the primary initializer.
    public init(
        url: URL,
        httpHeaders: [String: String] = [:],
        displayIsHDRReady: Bool = false,
        displayIsDolbyVisionCapable: Bool = false,
        segmentCacheBytes: Int? = 1 << 30,
        forceMuxedShape: Bool = false,
        keyframeIndexCacheDirectory: URL? = nil,
        dialogueBoost: [DialogueBoostLevel] = [],
        preferredAudioLanguage: String? = nil,
        preferredSubtitleLanguage: String? = nil,
        audioDelaySeconds: Double = 0,
        coordinatedHTTP: Bool = false,
        input: PrismCoreInputFactory? = nil,
        reachability: LoopbackHTTPServer.Reachability = .loopbackOnly
    ) throws {
        try self.init(
            url: url,
            httpHeaders: httpHeaders,
            display: DisplayCapabilities(
                isHDRReady: displayIsHDRReady,
                isDolbyVisionCapable: displayIsDolbyVisionCapable
            ),
            segmentCacheBytes: segmentCacheBytes,
            forceMuxedShape: forceMuxedShape,
            keyframeIndexCacheDirectory: keyframeIndexCacheDirectory,
            dialogueBoost: dialogueBoost,
            preferredAudioLanguage: preferredAudioLanguage,
            preferredSubtitleLanguage: preferredSubtitleLanguage,
            audioDelaySeconds: audioDelaySeconds,
            coordinatedHTTP: coordinatedHTTP,
            input: input,
            reachability: reachability
        )
    }

    /// The same session, taking the display's capabilities as one value.
    ///
    /// Prefer this over the two booleans: `DisplayCapabilities.current()` reads
    /// them from the display the host is actually playing to, which is what phase
    /// 4 set out to replace the caller-supplied guess with. The booleans stay for
    /// callers that genuinely know better than the read — a host mirroring to an
    /// external panel, or a test pinning a shape.
    ///
    /// - Parameter dialogueBoost: extra **Dialogue Boost** renditions to derive
    ///   from the default audio track — the engine-side answer to a feature
    ///   AVFoundation cannot host: `audioMix` (and every audio tap) is ignored
    ///   on HLS items, which is what this engine serves. Each level becomes an
    ///   alternate rendition (decoded, centre-favoured, re-encoded to EAC3)
    ///   in the master's audio group, marked with the
    ///   `public.accessibility.enhances-speech-intelligibility`
    ///   characteristic; the base track stays bit-for-bit untouched (Atmos
    ///   included), and the host flips levels via `AVMediaSelection` like any
    ///   other track. Opt-in because each level costs a full decode → filter →
    ///   encode chain for the length of the session. Best-effort by design:
    ///   levels that can't be built (no centre channel, or a build without
    ///   the EAC3 encoder / `pan` filter — check `isDialogueBoostAvailable`)
    ///   are skipped, and `dialogueBoostRenditions` reports what actually
    ///   made it into the served master. Renditions live only in a master, so
    ///   the muxed fallback shape drops them.
    /// - Parameter preferredAudioLanguage: the language the viewer wants to
    ///   hear, as a BCP-47 / ISO-639 tag (`"cs"`, `"ces"`, `"cze"` and
    ///   `"cs-CZ"` all mean the same thing — see `LanguageMatch`). The
    ///   matching track becomes the master's `DEFAULT` rendition, and — since
    ///   dialogue boost derives from the default track — the track a boost
    ///   level is built from.
    ///
    ///   This exists because selecting afterwards is visible: without it the
    ///   DEFAULT is whichever track the *source* ordered first, so a viewer
    ///   who wants Czech audio mounts the item, hears English, and switches —
    ///   one wrong-language moment at every start, and on the remux path a
    ///   switch also costs a rendition fetch.
    ///
    ///   What it does **not** do: it drops no track (every viable track is
    ///   still an alternate rendition the host can select), and it changes no
    ///   decode, bridge or stream-copy decision — a preferred track that this
    ///   build can neither copy nor bridge is passed over exactly as it would
    ///   be otherwise. No match at all is a no-op, never an error: the
    ///   source's own default stands.
    /// - Parameter preferredSubtitleLanguage: the language the viewer wants to
    ///   read, matched the same way. The matching rendition is the only one
    ///   ever marked `DEFAULT=YES,AUTOSELECT=YES`, which is what makes AVKit
    ///   engage it at load instead of starting with subtitles off. A full
    ///   rendition wins the flag over a forced one of the same language;
    ///   `FORCED` itself is untouched, and so is every other rendition.
    ///
    ///   Do **not** pass this together with `setTimedTextCueHandler` unless
    ///   the host suppresses its own overlay: engaging the rendition means
    ///   AVKit draws the cues, and the handler draws them again.
    public init(
        url: URL,
        httpHeaders: [String: String] = [:],
        display: DisplayCapabilities,
        segmentCacheBytes: Int? = 1 << 30,
        forceMuxedShape: Bool = false,
        probed: ProbedSource? = nil,
        keyframeIndexCacheDirectory: URL? = nil,
        dialogueBoost: [DialogueBoostLevel] = [],
        preferredAudioLanguage: String? = nil,
        preferredSubtitleLanguage: String? = nil,
        audioDelaySeconds: Double = 0,
        coordinatedHTTP: Bool = false,
        input: PrismCoreInputFactory? = nil,
        reachability: LoopbackHTTPServer.Reachability = .loopbackOnly
    ) throws {
        self.configuration = Options(
            sourceURL: url,
            httpHeaders: httpHeaders,
            display: display,
            segmentCacheBytes: segmentCacheBytes,
            forceMuxedShape: forceMuxedShape,
            keyframeIndexCacheDirectory: keyframeIndexCacheDirectory,
            dialogueBoost: dialogueBoost,
            preferredAudioLanguage: preferredAudioLanguage,
            preferredSubtitleLanguage: preferredSubtitleLanguage,
            audioDelaySeconds: AudioDelay.normalized(audioDelaySeconds),
            coordinatedHTTP: coordinatedHTTP || probed?.interruptGuard.usesCoordinatedHTTP == true,
            reachability: reachability
        )
        // A `ProbedSource` that was probed through a host input carries its
        // factory; a session built from one must not have to be told twice
        // where its bytes come from.
        self.inputFactory = input ?? probed?.inputFactory

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.workDirectory = directory
        // The demand seam (phase 5): the provider turns a fetch of a
        // not-yet-produced planned segment into a producer re-anchor and a
        // pending serve. Sources the remuxer can't plan (live, junk index)
        // never publish a plan, and the provider then behaves exactly like
        // the plain directory provider.
        let demand = DemandCoordinator()
        let landed = self.landed
        let remuxer = HLSRemuxer(
            sourceURL: url,
            httpHeaders: httpHeaders,
            outputDirectory: directory,
            // `offersHDR`, not `isHDRReady`: a panel currently presenting HDR
            // takes an HDR master even when the capability read came back
            // empty, so the certain signal rescues the conservative one.
            displayIsHDRReady: display.offersHDR,
            displayIsDolbyVisionCapable: display.isDolbyVisionCapable,
            demand: demand,
            segmentCacheBytes: segmentCacheBytes,
            forceMuxed: forceMuxedShape,
            dialogueBoost: dialogueBoost,
            preferredAudioLanguage: preferredAudioLanguage,
            preferredSubtitleLanguage: preferredSubtitleLanguage,
            probed: probed,
            input: inputFactory,
            keyframeCacheDirectory: keyframeIndexCacheDirectory,
            landed: landed
        )
        self.remuxer = remuxer
        remuxer.audioDelaySeconds = AudioDelay.normalized(audioDelaySeconds)
        remuxer.coordinatedHTTP = configuration.coordinatedHTTP
        var provider = PlanSegmentProvider(root: directory, coordinator: demand, landed: landed)
        // The demand seam for lazy OCR: a `.vtt` fetch is what arms a bitmap
        // rendition, so a 29-PGS-track disc pays for the one track someone
        // selected, not all of them.
        provider.subtitleDemand = { [subtitles = remuxer.subtitles] path in
            subtitles.noteSegmentDemand(path: path)
        }
        // The same seam for lazy dialogue-boost renditions: an init/segment
        // fetch under `audioN/` is what arms one, so the two levels the host
        // requests on every session cost nothing until someone picks one.
        provider.audioDemand = { [remuxer] path in
            remuxer.noteAudioDemand(path: path)
        }
        // And the seam that makes a runtime audio-delay change atomic from the
        // outside: the producer marks the old offset's segments unservable
        // before `pendingAudioDelaySeconds` clears, so a host that refreshes
        // the player the moment it clears cannot be handed them off disk while
        // the unlink queue is still catching up.
        provider.isSuperseded = { [store = remuxer.residentSegments] index in
            store.isSuperseded(index: index)
        }
        self.server = LoopbackHTTPServer(provider: provider, reachability: reachability)
    }

    /// A session for the display the host is playing to right now.
    ///
    /// `@MainActor` because the display read is (see `DisplayCapabilities`), and
    /// the host's playback code is there already. This is the initializer Aether's
    /// routing should use: it is what makes an HDR or Dolby Vision source get a
    /// master playlist at all, since the caller-supplied defaults are `false`.
    @MainActor
    public static func readingCurrentDisplay(
        url: URL,
        httpHeaders: [String: String] = [:],
        segmentCacheBytes: Int? = 1 << 30,
        forceMuxedShape: Bool = false,
        keyframeIndexCacheDirectory: URL? = nil,
        dialogueBoost: [DialogueBoostLevel] = [],
        preferredAudioLanguage: String? = nil,
        preferredSubtitleLanguage: String? = nil,
        audioDelaySeconds: Double = 0,
        coordinatedHTTP: Bool = false,
        input: PrismCoreInputFactory? = nil,
        reachability: LoopbackHTTPServer.Reachability = .loopbackOnly
    ) throws -> PrismCoreSession {
        try PrismCoreSession(
            url: url,
            httpHeaders: httpHeaders,
            display: .current(),
            segmentCacheBytes: segmentCacheBytes,
            forceMuxedShape: forceMuxedShape,
            keyframeIndexCacheDirectory: keyframeIndexCacheDirectory,
            dialogueBoost: dialogueBoost,
            preferredAudioLanguage: preferredAudioLanguage,
            preferredSubtitleLanguage: preferredSubtitleLanguage,
            audioDelaySeconds: audioDelaySeconds,
            coordinatedHTTP: coordinatedHTTP,
            input: input,
            reachability: reachability
        )
    }

    // MARK: - Master rejection (phase 4)

    /// Does this `AVPlayerItem.error` mean AVPlayer refused the master playlist,
    /// rather than that the source is unplayable?
    ///
    /// See `MasterRejection` for the three codes and why they are what they are.
    /// A host that gets `true` should stop this session, take
    /// `makeMuxedFallbackSession()`, and play that — *not* fall back to another
    /// engine, because the source itself was never the problem.
    public static func isMasterRejection(_ error: (any Error)?) -> Bool {
        MasterRejection.matches(error)
    }

    /// A successor over the same source with one or more `Options` moved: the
    /// single door for "play this title again, differently".
    ///
    /// ```swift
    /// let boosted = try await session.makeSession { $0.dialogueBoost = [.medium] }
    /// let playlist = try await boosted.start()
    /// player.replaceCurrentItem(with: AVPlayerItem(url: playlist))
    /// await player.seek(to: resumeTime)
    /// await session.stop()                       // the caller's job, see below
    /// ```
    ///
    /// A session is single-use — the served shape is decided before the first
    /// packet and the output layout follows from it — so every setting that
    /// reaches the remux can only be changed by building another session. This
    /// method spares the host re-stating what it already told this one:
    /// registered external subtitles and the timed-text cue handler are
    /// replayed onto the successor, and every option the closure leaves alone
    /// (the audio delay included) is carried verbatim. `sourceURL` and
    /// `httpHeaders` are deliberately not settable; the replay is what makes
    /// them part of this session's identity.
    ///
    /// **This is not a seamless swap.** Nothing is transplanted: the successor
    /// starts from zero, and the host replaces its `AVPlayerItem` and seeks the
    /// new one to wherever it wants to resume. There is no shared playhead and
    /// no continuity of playback; expecting one is how a "toggle" ends up
    /// looking like a crash.
    ///
    /// ## Lifecycle
    ///
    /// - The caller still owns `stop()` on the predecessor, and still has to
    ///   call it. Nothing here stops it: at the moment of the call the host's
    ///   player may still be drawing frames off it, and a factory that killed
    ///   the item under the player would be the worse surprise. Stop it as
    ///   soon as the successor's playlist is loaded.
    /// - The successor **never** shares the predecessor's work directory. Two
    ///   live sessions over one directory means two producers writing segment
    ///   files under the same names and two `segmentCacheBytes` sweepers
    ///   deleting each other's output, which reads as random mid-title stalls;
    ///   and the predecessor's `stop()` removes the whole directory out from
    ///   under a successor that is still serving from it. Each session mints
    ///   its own (the initializer takes no directory), which also means the
    ///   disk budget applies per session — one more reason to stop the
    ///   predecessor promptly rather than leave it producing.
    /// - A session mints **at most one** successor; a second call throws
    ///   `SessionError.alreadySuperseded`. Successors chain — clone the
    ///   session you are playing, not the one you left behind — because every
    ///   session carries a producer reading the source and a server on its own
    ///   port, and fanning out from one long-lived session is how a host ends
    ///   up with several of each on one title.
    ///
    /// `async` only because replaying the registrations means calling into the
    /// successor's actor.
    public func makeSession(changing: (inout Options) -> Void) async throws -> PrismCoreSession {
        var options = self.options
        changing(&options)
        return try await makeSuccessor(with: options)
    }

    /// The one clone path: `makeSession(changing:)` and both master-rejection
    /// fallbacks come through here, so the replay and the lifecycle rules
    /// cannot drift apart from each other.
    private func makeSuccessor(with options: Options) async throws -> PrismCoreSession {
        guard !hasSuccessor else { throw SessionError.alreadySuperseded }
        let successor = try PrismCoreSession(
            url: options.sourceURL,
            httpHeaders: options.httpHeaders,
            display: options.display,
            segmentCacheBytes: options.segmentCacheBytes,
            forceMuxedShape: options.forceMuxedShape,
            // No `probed`: this session consumed the probe it was handed, and
            // an already-read context cannot open a second remux.
            probed: nil,
            keyframeIndexCacheDirectory: options.keyframeIndexCacheDirectory,
            dialogueBoost: options.dialogueBoost,
            preferredAudioLanguage: options.preferredAudioLanguage,
            preferredSubtitleLanguage: options.preferredSubtitleLanguage,
            audioDelaySeconds: options.audioDelaySeconds,
            coordinatedHTTP: options.coordinatedHTTP,
            // Carried, never chosen: a successor that quietly went back to
            // native I/O would fail to open a source only the host can read.
            input: inputFactory,
            // Carried for the same reason, and the default is what makes this
            // easy to lose: a successor that fell back to `.loopbackOnly`
            // would serve 127.0.0.1 to an AirPlay receiver that cannot reach
            // it, and the rejection tier is exactly when that happens.
            reachability: options.reachability
        )
        // A tripwire, not a doubt about today's initializer: the day someone
        // adds a work-directory parameter for a test or a cache, this is the
        // invariant that must not be quietly given up (see Lifecycle above).
        precondition(
            successor.workDirectory != workDirectory,
            "a successor session must not share its predecessor's work directory"
        )
        // Only after the successor exists: a throwing build leaves this session
        // clonable, so a host that hits a transient error can try again.
        hasSuccessor = true
        try await replayExternalSubtitles(onto: successor)
        return successor
    }

    /// A fresh session over the same source with `forceMuxedShape` set: no
    /// master, the one best audio track muxed into the variant, media playlist
    /// served directly.
    ///
    /// This is the recovery path for a refused master, and it has to be a *new*
    /// session because the shape is decided before the first packet and the
    /// output layout follows from it — there is nothing to re-negotiate in place.
    /// Registered external subtitles are replayed onto the clone so the host
    /// doesn't have to remember them, though in this shape nothing selects them:
    /// a `SUBTITLES` group exists only inside a master.
    ///
    /// Calling this on a session that is *already* muxed-shape returns an
    /// equivalent new session rather than refusing — a rejection here means
    /// something other than the shape was wrong, and the caller's own retry
    /// policy is the right place to stop, not this factory.
    ///
    /// Lifecycle as `makeSession(changing:)`: the caller stops the predecessor,
    /// and this counts as that session's one successor.
    public func makeMuxedFallbackSession() async throws -> PrismCoreSession {
        try await makeSession { options in
            options.forceMuxedShape = true
            // `dialogueBoost` is carried for fidelity though this shape cannot
            // serve it: boost renditions live in a master, and this shape has
            // none. Dropping it here would instead make the next clone off the
            // fallback session silently forget the host ever asked.
        }
    }

    /// The next session to try after AVPlayer refused this one's master —
    /// the tiered version of `makeMuxedFallbackSession()`, and what a host's
    /// rejection handler should reach for.
    ///
    /// A refused master that claimed **Dolby Vision** gets one retry without
    /// the claim first: same audio renditions, same subtitles, same
    /// `VIDEO-RANGE`, no `dvh1`/`SUPPLEMENTAL-CODECS`. The DV claim is
    /// validated against the panel's *current* mode, and on the one panel
    /// state no read can prove — Match Content off with the output parked in
    /// HDR10 — dropping it is the difference between playing with everything
    /// selectable and falling all the way to the muxed shape. A panel parked
    /// in SDR refuses the retry too (`VIDEO-RANGE=PQ` is still a claim), and
    /// the *retry's* own fallback — this method on the new session — then
    /// takes the muxed tier, because it has no DV claim left to drop.
    ///
    /// A master that never claimed DV skips straight to the muxed shape,
    /// exactly as before.
    public func makeMasterRejectionFallbackSession() async throws -> PrismCoreSession {
        guard remuxer.masterDeclaresDolbyVision else {
            return try await makeMuxedFallbackSession()
        }
        return try await makeSession { options in
            let display = options.display
            options.display = DisplayCapabilities(
                isHDRReady: display.isHDRReady,
                // The one clamp of this tier: no DV may be claimed, however
                // capable the link says the panel is — capability is exactly
                // the read the rejection just proved wrong.
                isDolbyVisionCapable: false,
                panelIsCurrentlyHDR: display.panelIsCurrentlyHDR,
                source: display.source
            )
            // This tier keeps the master; only the claim goes.
            options.forceMuxedShape = false
        }
    }

    /// Registered external subtitles are part of the source's identity as far
    /// as fallbacks are concerned — every clone replays them so the host
    /// doesn't have to remember what it registered. The timed-text cue handler
    /// rides along for the same reason: a master rejection must not silently
    /// cost the host its captions.
    ///
    /// A startup-checkpoint registration deliberately does NOT ride along: it
    /// describes one session's startup, and by the time a master rejection is
    /// known that startup has finished and the stream has ended. The host
    /// registers again on the clone if it still wants to watch.
    private func replayExternalSubtitles(onto fallback: PrismCoreSession) async throws {
        for subtitle in externalSubtitles {
            try await fallback.addExternalSubtitle(
                url: subtitle.url,
                language: subtitle.language,
                name: subtitle.name,
                isForced: subtitle.isForced
            )
        }
        if let handler = timedTextCueHandler {
            await fallback.setTimedTextCueHandler(handler)
        }
    }

    // MARK: - Subtitles (phase 6)

    /// Register an external subtitle file (`.srt` / `.vtt`) as its own WebVTT
    /// rendition, before `start()`.
    ///
    /// The whole file is converted once at remux setup and then segmented on the
    /// video's own boundaries, exactly like an embedded text track — so an
    /// external track behaves identically from AVPlayer's side. The rendition
    /// set is fixed when the remux starts (it has to be: the master playlist a
    /// host builds from `subtitleRenditions` is read once at item creation),
    /// hence the `alreadyStarted` refusal.
    ///
    /// - Parameters:
    ///   - url: A local file URL. Remote sidecars are the host's to fetch —
    ///     PrismCore has no download machinery and would only duplicate the
    ///     header handling the host already does.
    ///   - language: ISO-639 tag for `LANGUAGE`, e.g. `"cs"` / `"ces"`.
    ///   - name: Display name for `NAME`; defaults to the language tag.
    ///   - isForced: Marks the rendition `FORCED=YES`.
    public func addExternalSubtitle(
        url: URL,
        language: String? = nil,
        name: String? = nil,
        isForced: Bool = false
    ) throws {
        guard !started else { throw SessionError.alreadyStarted }
        remuxer.subtitles.addExternalFile(
            .init(url: url, language: language, name: name, isForced: isForced)
        )
        // Remembered so a muxed fallback session can be a faithful clone.
        externalSubtitles.append((url: url, language: language, name: name, isForced: isForced))
    }

    /// Stream every embedded subtitle cue to the host as the demux produces
    /// it, rebased onto the played timeline (see `TimedTextCue`).
    ///
    /// The WebVTT renditions keep working regardless — this is the *other*
    /// delivery, for a host that draws captions itself and wants them on the
    /// player's own clock instead of AVPlayer's rendition schedule. Callable
    /// before or after `start()`: a handler registered late is first replayed
    /// everything produced so far, in production order, so it can't miss the
    /// opening dialogue. Cues follow the demux, which follows playback — a
    /// seek forward means that region's cues arrive when the remux reaches
    /// it, and a re-demuxed region is deduplicated here, not by the host.
    ///
    /// External files registered via `addExternalSubtitle` are *not* streamed:
    /// the host handed those in and already owns their text.
    public func setTimedTextCueHandler(_ handler: (@Sendable (TimedTextCue) -> Void)?) {
        timedTextCueHandler = handler
        remuxer.subtitles.setCueHandler(handler)
    }

    // MARK: - Startup checkpoints

    /// Live stages of this session's `start()`, in order, each stamped with
    /// the time it happened at. Register **before** `start()`.
    ///
    /// ```swift
    /// let session = try PrismCoreSession(url: mkvURL, display: .current())
    /// let checkpoints = try await session.startupCheckpoints()
    /// Task { for await mark in checkpoints { log("\(mark.elapsed): \(mark.phase)") } }
    /// let playlist = try await session.start()
    /// ```
    ///
    /// **Why a stream and not a handler**, when `setTimedTextCueHandler` set
    /// the opposite precedent: cues are an endless feed with no terminus, and
    /// the host draws each one and forgets it. Startup has a terminus, and the
    /// terminus is the point — "no more checkpoints are coming" is what
    /// dismisses the spinner, and an `AsyncStream` says that in the language
    /// the host is already awaiting in. A callback would need a sentinel
    /// value, and a sentinel a host forgets to handle is a spinner that never
    /// stops.
    ///
    /// The stream is buffered without limit and always finishes: after the
    /// final `.playlistServable`, when `start()` throws (the error is the
    /// thrown one — the stream just ends), and on `stop()` for a session that
    /// registered and was torn down without ever starting. A host awaiting a
    /// stream that never ends would be a worse bug than the blindness this
    /// fixes.
    ///
    /// Not replayed onto a fallback session (unlike external subtitles and the
    /// cue handler): this stream describes the startup of *this* session, and
    /// that startup is over by the time a master rejection is known. A host
    /// taking `makeMasterRejectionFallbackSession()` registers again on the
    /// new session, whose startup is a new and separately interesting thing.
    ///
    /// Calling this twice finishes the earlier stream and hands out a new one;
    /// there is one startup to describe, so there is one consumer.
    public func startupCheckpoints() throws -> AsyncStream<StartupCheckpoint> {
        guard !started else { throw SessionError.alreadyStarted }
        let (stream, continuation) = AsyncStream<StartupCheckpoint>.makeStream(
            // Unbounded because a host that registers, starts, and only then
            // gets around to its `for await` must still see `.sourceOpened`:
            // the stages are the record of where the time went, and a dropped
            // one turns the log into a guess. Five values per session.
            bufferingPolicy: .unbounded
        )
        checkpoints?.finish()
        checkpoints = continuation
        return stream
    }

    /// The registered stream's continuation, `nil` when nobody asked — which
    /// is what keeps the producer's sink nil and the whole feature free.
    private var checkpoints: AsyncStream<StartupCheckpoint>.Continuation?

    /// When `start()` was called — the zero every checkpoint's `elapsed` is
    /// measured from.
    private var startupReference: ContinuousClock.Instant?

    private func note(_ phase: StartupPhase) {
        guard let checkpoints, let startupReference else { return }
        checkpoints.yield(
            StartupCheckpoint(phase: phase, elapsed: ContinuousClock.now - startupReference)
        )
    }

    /// The WebVTT subtitle renditions this session serves, in declaration order
    /// (embedded text tracks first, then registered external files).
    ///
    /// Populated once the remux has opened the source, i.e. any time after
    /// `start()` returns. The session's own master playlist already declares
    /// them — this is informational (a host listing tracks in its UI). A
    /// `SUBTITLES` group only exists in a master playlist, so a session served
    /// media-direct produces the renditions on disk but nothing selects them.
    public var subtitleRenditions: [MasterPlaylistBuilder.SubtitleRendition] {
        remuxer.subtitles.renditions
    }

    /// Start the loopback server and the remux, and return the playlist URL
    /// once it is servable — the point where AVPlayer can be pointed at it
    /// without racing an empty directory.
    ///
    /// **Servable is not "every referenced file exists".** In the planned-VOD
    /// shape the complete playlist, every `#EXTINF` of it, is written before
    /// the first packet is read, so readiness turns on the init segment alone —
    /// and the init is written *before* the first media segment, deliberately,
    /// so a reader that saw the manifest can always fetch what it references.
    /// Between those two writes the playlist is servable and no media segment
    /// exists. That is covered by design, not by luck: a fetch goes through
    /// `PlanSegmentProvider`, which answers a miss by asking for production and
    /// waiting. A caller that bypasses the server and reads the work directory
    /// gets no such guarantee and must wait for the file itself.
    public func start(startupTimeout: Duration = .seconds(20)) async throws -> URL {
        precondition(!started, "PrismCoreSession is single-use — make a new one per load")
        started = true
        // A host that gave up while the session was still being built — the
        // viewer closed the player during loading — can reach `stop()` first.
        // Nothing below checks for it: the producer would run and the listener
        // would serve, both for good, with `stop()` already spent.
        guard !stopped else { throw CancellationError() }
        let reference = ContinuousClock.now
        startupReference = reference
        // Every exit finishes the stream — the success path below emits
        // `.playlistServable` first, and `defer` runs after the return value
        // is built. Put on the ONE statement that covers all five throw sites:
        // a host awaiting a stream a failed startup forgot to end is a hang,
        // which is worse than the blindness this feature removes.
        defer {
            checkpoints?.finish()
            checkpoints = nil
        }

        // The producer's sink is installed BEFORE the thread that calls it
        // exists — that ordering is what lets the remuxer read it without a
        // lock on its own hot path (see `HLSRemuxer.onStartupPhase`). Left nil
        // when nobody registered, so an unwatched session pays a nil check per
        // stage and nothing else.
        if let checkpoints {
            remuxer.onStartupPhase = { phase in
                checkpoints.yield(
                    StartupCheckpoint(phase: phase, elapsed: ContinuousClock.now - reference)
                )
            }
        }

        // The producer first, the listener second: the remux's opening move
        // is a source open over the network (hundreds of milliseconds on a
        // remote server), and nothing about it needs the port — so the bind
        // overlaps it instead of preceding it. The signal is broadcast when
        // the thread exits too, so a producer that dies in its first
        // millisecond wakes the gate below rather than being waited out.
        let remuxer = self.remuxer
        let landed = self.landed
        let producer = ProducerThread(name: "cz.zmrhal.prismcore.remux") {
            defer { landed.broadcast() }
            try remuxer.run()
        }
        self.producer = producer
        watchForTerminalError(producer)

        let base: URL
        do {
            base = try await server.start()
        } catch {
            // No listener means no session: the producer is already writing
            // into the work directory and must not be left running for a
            // server that never came up. Cancelled, not joined: the flag is
            // checked once per packet, and a producer parked in a slow
            // network read would hold the join for the length of that read —
            // the host should get the bind error now. `stop()` still joins
            // and removes the work directory, exactly as for any session.
            remuxer.cancel()
            throw error
        }

        let deadline = ContinuousClock.now.advanced(by: startupTimeout)
        while ContinuousClock.now < deadline {
            // Generation BEFORE the disk check (see `ProductionSignal`): a
            // cut that lands between the check and the wait then returns the
            // wait immediately instead of costing a backstop interval.
            let generation = landed.currentGeneration
            if let ready = Self.readyPlaylistName(
                in: workDirectory, lazyRenditions: remuxer.lazyRenditionPlaylistURIs
            ) {
                let playlist = base.appendingPathComponent(ready)
                note(.playlistServable(playlist))
                return playlist
            }
            // A remux that already died will never produce the playlist —
            // surface its error instead of burning the whole timeout. The
            // producer's own record is read here rather than `remuxError`: the
            // watcher that copies it over is a Task, and a startup that fails
            // in the first millisecond can beat it.
            if let failure = producer.failureIfAny {
                throw SessionError.startupTimedOut(underlying: failure)
            }
            // Finished without a playlist and without throwing: nothing more is
            // coming, so don't burn the rest of the timeout waiting for it.
            if producer.isFinished { break }
            if let remuxError { throw SessionError.startupTimedOut(underlying: remuxError) }
            // Woken by the producer's broadcast after each write. The 10 ms
            // poll this replaces was itself a fix for a 100 ms one quantizing
            // startups (103 ms returned for 33 ms ready); the wake removes the
            // interval altogether, and the backstop only exists for a landing
            // nobody announced.
            await landed.wait(after: generation, backstop: .milliseconds(250))
        }
        throw SessionError.startupTimedOut(underlying: remuxError)
    }

    /// Cancel the remux, stop serving, and remove the session's segments.
    ///
    /// **Bounded, and silent.** It returns within `producerStopGrace` even
    /// when the producer does not — see the detach below — and it never
    /// throws: there is nothing a host could do about a wedged transport from
    /// a `catch`, and a teardown that can fail is a teardown every caller
    /// wraps in an empty one.
    public func stop() async {
        stopped = true
        // Idempotent after a `start()` that already finished it; this covers
        // the session that registered for checkpoints and was torn down
        // without ever starting — its consumer is awaiting a stream that would
        // otherwise never end.
        checkpoints?.finish()
        checkpoints = nil
        // `cancel()` is the only stop signal the producer has (it also wakes a
        // parked one, and releases a conforming host input's blocked read);
        // the join then waits for the thread to notice.
        remuxer.cancel()
        let joined = await producer?.join(within: Self.producerStopGrace) ?? true
        remuxer.residentSegments.clear()
        await cachedPreview.clear()
        await server.stop()
        try? FileManager.default.removeItem(at: workDirectory)
        if !joined, let producer {
            // Deliberately leaked. The alternative is to keep waiting, and
            // what the caller is waiting on is a thread parked inside a host's
            // synchronous `read` that no signal can reach — a host input that
            // does not conform to `CancellablePrismCoreInput`, or one that
            // does and is not honouring it. `stop()` is called by a host
            // leaving the player, often from the main actor; a hung `stop()`
            // is a hung app, which is strictly worse than one thread the
            // process never gets back.
            //
            // Nothing is thrown for it, on purpose: the host cannot fix its
            // own wedged transport from the `catch`, so an error here buys an
            // empty `catch` in every caller and nothing else. The notice is
            // the honest channel.
            PrismCoreLog.notice(
                "stop(): producer still inside a host read after "
                + "\(Self.producerStopGrace); detaching the thread and returning"
            )
            let directory = workDirectory
            // The removal above races the leaked producer: it may create a
            // segment file between the walk and the rmdir, which leaves the
            // directory behind with bytes in it — a tmp leak that nothing
            // else would ever come back for. So a second removal is queued
            // behind the thread's real exit. Suspended, not blocked: it holds
            // no pool thread while it waits, and if the host NEVER returns it
            // simply never runs, which costs one suspended task.
            Task.detached(priority: .utility) {
                await producer.join()
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    /// A host that drops a started session without `stop()` would otherwise
    /// leave its producer muxing, its listener serving and its segments on
    /// disk for the life of the process — nothing else holds a way back to
    /// them. The same teardown as `stop()`, unawaited.
    deinit {
        guard started, !stopped else { return }
        PrismCoreLog.notice("PrismCoreSession released without stop(); tearing it down")
        remuxer.cancel()
        let server = server, producer = producer, directory = workDirectory
        Task.detached(priority: .utility) {
            await server.stop()
            await producer?.join()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// How long `stop()` waits for the producer before detaching it.
    ///
    /// The floor comes from a measurement, because detaching a producer that
    /// was going to come back is not a saved teardown — it is the work
    /// directory being deleted underneath a thread still muxing into it. Every
    /// `stop()` in this suite was timed (2026-09-17, M4, debug build, whole
    /// suite in parallel): **76 joins, all but one between 0.17 µs and
    /// 235 ms**, median ~1.5 ms. The flag is checked once per packet, a parked
    /// producer is woken on the coordinator, and since 3.1.0 one inside its
    /// own open is aborted there too (`HLSRemuxer.run`). The one exception is
    /// the test that wedges a host read on purpose.
    ///
    /// Two seconds is ~8.5× that worst observed case — the margin a slower
    /// device, a big final fragment flush and a host's own cancellation round
    /// trip deserve. It is also what caught the measurement's real finding: at
    /// 2 s a starving-origin teardown was detaching at 2.3 s because `cancel()`
    /// could not reach a guard the producer had not published yet. Fixing that
    /// is what brought the worst case down to 235 ms; the grace was not raised
    /// to hide it.
    ///
    /// The ceiling is the other side: `stop()` is awaited on the way out of a
    /// player, frequently while the app is being backgrounded, and iOS gives a
    /// suspending app only a few seconds before the watchdog. Two seconds
    /// leaves room inside that and is short enough that a user who sees it
    /// reads it as a slow dismissal rather than a freeze.
    static let producerStopGrace: Duration = .seconds(2)

    // MARK: - Readiness

    /// The playlist to hand out, once it is genuinely playable — or `nil` while
    /// the remux is still finding its feet.
    ///
    /// The remuxer writes the master first (its contents are known before the
    /// first packet), so the master's presence is what decides the shape. What
    /// takes a moment is the first cut, and the gate waits for exactly one
    /// thing from it: the **video variant** playable — an `EXTINF` and its
    /// `EXT-X-MAP` init segment on disk.
    ///
    /// The renditions have to exist (playlist on disk — a 404 on a playlist
    /// fails the item outright) and have the init segment their `EXT-X-MAP`
    /// names, but they need NOT list a segment yet. The gate used to demand
    /// an `EXTINF` from every one of them, which in the sequential shape made
    /// startup wait for a bridged track whose first cut carried no audio. An
    /// unproduced rendition *segment* goes through the loopback's demand seam
    /// (`PlanSegmentProvider.handleMiss` answers `.pending` and serves it
    /// when the producer lands it), so it is not the gate's job. The init
    /// stays a requirement on purpose: a declared track that never delivers
    /// a packet never mints one, and returning a master whose default
    /// rendition can never become playable would move the failure from
    /// `start()` (where the host can fall back) to AVPlayer.
    ///
    /// `lazyRenditions` (relative playlist URIs) are declared renditions that
    /// produce nothing — no init either — until a fetch arms them
    /// (`HLSRemuxer.lazyRenditionPlaylistURIs`). Only their playlist has to
    /// exist; AVPlayer fetches an init only for the rendition it selected,
    /// and that fetch is what makes the init.
    ///
    /// `nonisolated static` so a test can run the gate over a hand-built
    /// directory without a producer behind it.
    nonisolated static func readyPlaylistName(
        in workDirectory: URL, lazyRenditions: Set<String> = []
    ) -> String? {
        let master = workDirectory.appendingPathComponent(HLSRemuxer.masterPlaylistFileName)
        guard let masterText = try? String(contentsOf: master, encoding: .utf8) else {
            return isPlayable(playlist: HLSRemuxer.mediaPlaylistFileName, in: workDirectory)
                ? HLSRemuxer.mediaPlaylistFileName
                : nil
        }
        let referenced = playlistURIs(inMaster: masterText)
        guard !referenced.isEmpty else { return nil }
        // The variant is the plain URI after EXT-X-STREAM-INF — the builder
        // writes exactly one, and it is the only playlist whose first cut
        // AVPlayer cannot start without.
        var variant: String?
        var expectingVariantURI = false
        for rawLine in masterText.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if expectingVariantURI, !line.hasPrefix("#") { variant = line; break }
            expectingVariantURI = line.hasPrefix("#EXT-X-STREAM-INF:")
        }
        guard let variant, isPlayable(playlist: variant, in: workDirectory) else { return nil }
        for uri in referenced where uri != variant {
            if lazyRenditions.contains(uri) {
                guard FileManager.default.fileExists(
                    atPath: workDirectory.appendingPathComponent(uri).path
                ) else { return nil }
                continue
            }
            guard hasInitIfMapped(playlist: uri, in: workDirectory) else { return nil }
        }
        return HLSRemuxer.masterPlaylistFileName
    }

    /// Every media playlist a master refers to: the `URI` of each `EXT-X-MEDIA`
    /// rendition, plus the plain URI line that follows each `EXT-X-STREAM-INF`.
    static func playlistURIs(inMaster text: String) -> [String] {
        var uris: [String] = []
        var expectingVariantURI = false
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if expectingVariantURI, !line.hasPrefix("#") {
                uris.append(line)
                expectingVariantURI = false
                continue
            }
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                expectingVariantURI = true
                continue
            }
            if line.hasPrefix("#EXT-X-MEDIA:"), let uri = attribute("URI", in: line) {
                uris.append(uri)
            }
        }
        return uris
    }

    /// One quoted attribute value out of a tag line. Deliberately minimal — the
    /// only attribute read back is `URI`, and the builder wrote it.
    private static func attribute(_ name: String, in line: String) -> String? {
        guard let start = line.range(of: "\(name)=\"") else { return nil }
        let rest = line[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// Does this relative media playlist exist, list a segment, and have the
    /// init segment it maps to?
    private nonisolated static func isPlayable(playlist relativePath: String, in workDirectory: URL) -> Bool {
        let url = workDirectory.appendingPathComponent(relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              text.contains("#EXTINF")
        else { return false }
        return hasInitIfMapped(playlist: relativePath, in: workDirectory)
    }

    /// Does this relative media playlist exist and, when it names an
    /// `EXT-X-MAP`, have that init segment on disk? (No `EXTINF` demanded.)
    private nonisolated static func hasInitIfMapped(playlist relativePath: String, in workDirectory: URL) -> Bool {
        let url = workDirectory.appendingPathComponent(relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        guard let mapLine = text.split(separator: "\n").first(where: {
            $0.hasPrefix("#EXT-X-MAP:")
        }) else { return true }
        guard let mapURI = Self.attribute("URI", in: String(mapLine)) else { return true }
        let initSegment = url.deletingLastPathComponent().appendingPathComponent(mapURI)
        return FileManager.default.fileExists(atPath: initSegment.path)
    }

    private func watchForTerminalError(_ producer: ProducerThread) {
        Task { [weak self] in
            await producer.join()
            if let failure = producer.failureIfAny {
                await self?.record(error: failure)
            }
        }
    }

    private func record(error: any Error) {
        remuxError = error
    }
}
