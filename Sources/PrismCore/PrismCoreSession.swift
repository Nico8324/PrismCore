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
    public var audioDelaySeconds: Double { configuration.audioDelaySeconds }
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
        /// Clamped to ±2 s when the session is built, so a value read back here
        /// is the one in force, not the one asked for.
        public var audioDelaySeconds: Double
        public var coordinatedHTTP: Bool
    }

    /// What this session was built from — the starting point for
    /// `makeSession(changing:)`.
    public var options: Options { configuration }

    private let configuration: Options
    /// A session mints at most one successor (`makeSession(changing:)`).
    private var hasSuccessor = false
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
        audioDelaySeconds: Double = 0,
        coordinatedHTTP: Bool = false
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
            audioDelaySeconds: audioDelaySeconds,
            coordinatedHTTP: coordinatedHTTP
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
    public init(
        url: URL,
        httpHeaders: [String: String] = [:],
        display: DisplayCapabilities,
        segmentCacheBytes: Int? = 1 << 30,
        forceMuxedShape: Bool = false,
        probed: ProbedSource? = nil,
        keyframeIndexCacheDirectory: URL? = nil,
        dialogueBoost: [DialogueBoostLevel] = [],
        audioDelaySeconds: Double = 0,
        coordinatedHTTP: Bool = false
    ) throws {
        self.configuration = Options(
            sourceURL: url,
            httpHeaders: httpHeaders,
            display: display,
            segmentCacheBytes: segmentCacheBytes,
            forceMuxedShape: forceMuxedShape,
            keyframeIndexCacheDirectory: keyframeIndexCacheDirectory,
            dialogueBoost: dialogueBoost,
            audioDelaySeconds: AudioDelay.normalized(audioDelaySeconds),
            coordinatedHTTP: coordinatedHTTP || probed?.interruptGuard.usesCoordinatedHTTP == true
        )

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
            probed: probed,
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
        self.server = LoopbackHTTPServer(provider: provider)
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
        audioDelaySeconds: Double = 0,
        coordinatedHTTP: Bool = false
    ) throws -> PrismCoreSession {
        try PrismCoreSession(
            url: url,
            httpHeaders: httpHeaders,
            display: .current(),
            segmentCacheBytes: segmentCacheBytes,
            forceMuxedShape: forceMuxedShape,
            keyframeIndexCacheDirectory: keyframeIndexCacheDirectory,
            dialogueBoost: dialogueBoost,
            audioDelaySeconds: audioDelaySeconds,
            coordinatedHTTP: coordinatedHTTP
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
        var options = configuration
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
            audioDelaySeconds: options.audioDelaySeconds,
            coordinatedHTTP: options.coordinatedHTTP
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
    /// once everything that playlist references exists on disk — the point where
    /// AVPlayer can be pointed at it without racing an empty directory.
    public func start(startupTimeout: Duration = .seconds(20)) async throws -> URL {
        precondition(!started, "PrismCoreSession is single-use — make a new one per load")
        started = true

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
                return base.appendingPathComponent(ready)
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
    public func stop() async {
        stopped = true
        // `cancel()` is the only stop signal the producer has (it also wakes a
        // parked one); the join then waits for the thread to notice, exactly as
        // awaiting the task's value used to.
        remuxer.cancel()
        await producer?.join()
        remuxer.residentSegments.clear()
        await cachedPreview.clear()
        await server.stop()
        try? FileManager.default.removeItem(at: workDirectory)
    }

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
