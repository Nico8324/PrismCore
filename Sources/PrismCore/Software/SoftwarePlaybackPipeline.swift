import Foundation
import AVFoundation
import CoreMedia
import Libavcodec
import Libavformat
import Libavutil

/// The software decode path (roadmap phase 7): demux with libavformat, decode
/// with libavcodec, render with `AVSampleBufferDisplayLayer` +
/// `AVSampleBufferAudioRenderer` under an `AVSampleBufferRenderSynchronizer`.
///
/// This is where sources go that AVPlayer's HLS-fMP4 pipeline cannot carry at
/// all — VP9/VP8, MPEG-2, MPEG-4 ASP, VC-1, interlaced H.264. Unlike the rest
/// of PrismCore, it is a *player*, not a service: there is no AVPlayer to hand a
/// URL to, so this type owns the transport and the clock.
///
/// ```swift
/// let pipeline = SoftwarePlaybackPipeline()
/// try pipeline.load(url: webmURL)          // synchronous; call off the main thread
/// // or, after a routing probe: try pipeline.load(probed: probedSource)
/// hostView.layer.addSublayer(pipeline.displayLayer!)
/// pipeline.play()
/// ```
///
/// ## Pacing, and why audio is not gated on video
///
/// Both renderers publish `isReadyForMoreMediaData` and both call back through
/// `requestMediaDataWhenReady`. The obvious loop — one cursor, paced on the
/// *video* renderer's readiness — is a classic pipeline trap: as soon
/// as video stops draining (a backgrounded app, a display layer off screen, a
/// decode that briefly outruns the queue) the gate never reopens, and audio
/// starves behind it even though its own renderer is begging for data. That is
/// audible as a dropout, and it is a coupling bug, not a throughput problem.
///
/// So the loop reads while *either* stream still wants data, decodes into two
/// small pending queues, and each renderer drains its own queue on its own
/// callback. Video being full therefore cannot stop audio from being read,
/// decoded and enqueued; the cost is that chasing audio past a full video queue
/// lets the video queue grow by roughly the container's interleave distance,
/// which a hard cap bounds (see `Pacing`). A pathological interleave stops reads
/// instead of growing memory — the honest failure. An independent
/// audio look-ahead cursor is the refinement this shape leaves room for.
///
/// ## Audio track switching
///
/// `selectAudioTrack(streamIndex:)` swaps the audio decoder mid-playback,
/// leaving the clock and the video renderer untouched (issue #35). The new
/// decoder is built *before* the old one is torn down — a track whose decoder
/// can't open leaves the current track playing rather than leaving silence —
/// and the demuxer is then rewound to the clock's present so the new track
/// starts where the listener is, not where the read cursor had run ahead to.
/// The rewind re-reads video the renderer already holds; those frames are
/// dropped by timestamp instead of re-enqueued, which is what keeps the video
/// path a bystander. On a source that refuses the rewind (no index), the new
/// track joins at the read position instead — a gap of the queue's look-ahead,
/// which beats refusing the switch.
///
/// ## Not here yet
///
/// Subtitle rendering belongs to the host: poll `activeSubtitleCues` for an
/// overlay. Bitmap subtitles and external subtitle files are not selected here.
/// `.ended` fires from a synchronizer
/// boundary at the last presentation end — when the speaker has finished the
/// last buffer, not when it was enqueued.
public final class SoftwarePlaybackPipeline: @unchecked Sendable {

    // MARK: - Public surface

    public enum State: String, Sendable, Equatable {
        case idle
        case loading
        case paused
        case playing
        /// The renderers have played out the last decoded buffer.
        case ended
        case failed
    }

    public enum Failure: Error, CustomStringConvertible {
        case alreadyLoaded
        case notLoaded
        /// The container has no stream this path can decode.
        case noDecodableStream
        /// A renderer kept failing after being flushed and re-primed.
        case rendererFailed

        public var description: String {
            switch self {
            case .alreadyLoaded: return "pipeline is single-use — make a new one per load"
            case .notLoaded: return "load(url:) has not run"
            case .noDecodableStream: return "no decodable video or audio stream in the source"
            case .rendererFailed: return "a renderer failed repeatedly; flushing and re-priming did not recover it"
            }
        }
    }

    /// Queue depths, in decoded buffers.
    ///
    /// Small on purpose: these queues exist to decouple the two renderers'
    /// drain schedules, not to buffer playback (the renderers do that
    /// themselves, and a deep queue here only delays a seek's flush).
    struct Pacing {
        /// ~0.25 s at 24 fps.
        var videoDepth = 6
        /// ~0.5–0.7 s of audio, depending on the codec's frame size. Deeper than
        /// video because audio dropouts are far more noticeable than a late
        /// frame, so this is the queue that should be able to ride out a stall.
        var audioDepth = 24
        /// Multiple of the depth at which reads stop even though the other
        /// stream still wants data. Bounds the "chasing audio past a full video
        /// queue" case above.
        var hardCapMultiplier = 4
        /// Bytes of decoded video the pending queue may hold, whatever the
        /// frame count says. Frames are not a unit of memory: 24 pending
        /// frames is 3 MB of 480p and 600 MB of 4K P010, and the frame-count
        /// cap alone let a UHD source chase audio straight into a jetsam kill.
        /// 64 MB is ~5 frames of 4K 10-bit, ~20 of 1080p — enough to decouple
        /// the renderers, which is all this queue is for.
        var maxPendingVideoBytes = 64 << 20
        /// How much content a seek may decode-and-discard before it gives up
        /// on landing at the target and shows from the keyframe instead.
        var maxSeekDiscardSeconds = 2.0
    }

    /// Called on the feed queue whenever `state` changes. Set before `load`.
    public var onStateChange: (@Sendable (State) -> Void)?

    public var state: State {
        stateLock.withLock { storedState }
    }

    /// Master-clock time, i.e. the presentation time being rendered. On the
    /// source's own axis (the pipeline never rebases timestamps to zero).
    public var currentTime: CMTime {
        timeline.currentTime
    }

    /// Whole-source duration in seconds — **what the pipeline currently
    /// knows**, not a constant. `nil` until `load`, and possibly for a while
    /// after: a container can withhold its duration (a Matroska written to a
    /// pipe carries none, and libavformat does not estimate one for it), in
    /// which case this becomes non-`nil` the moment the knowledge arrives —
    /// at the latest on EOF, when the last timestamp read *is* the duration.
    /// A host that copies this once at load keeps the `nil` forever; re-read
    /// it alongside the position (#58). Stays `nil` only for sources that
    /// genuinely have no end (live ingests).
    public var durationSeconds: Double? {
        stateLock.withLock { storedDurationSeconds }
    }

    /// The pipeline's own output level, `0…1`. Scales the audio renderer, not
    /// the device — a host's volume drag has no honest system-level lever, so
    /// this is the same contract AVPlayer's `volume` offers.
    public var volume: Float {
        get { (audioSink as? AudioRendererSink)?.renderer.volume ?? 1 }
        set { (audioSink as? AudioRendererSink)?.renderer.volume = max(0, min(1, newValue)) }
    }

    /// The layer to put in the host's view hierarchy. `nil` when the pipeline
    /// was built with injected sinks (tests).
    public var displayLayer: AVSampleBufferDisplayLayer? {
        (videoSink as? DisplayLayerVideoSink)?.layer
    }

    /// What each decoder ended up doing, for diagnostics: which route the video
    /// took (VideoToolbox zero-copy vs CPU) and the audio's output format.
    public var routeDescription: String {
        [videoDecoder?.routeDescription, audioDecoder?.routeDescription]
            .compactMap { $0 }
            .joined(separator: "; ")
    }

    /// The probe's description of the loaded source — the same facts
    /// `SourceProbe` reports for routing (tracks with language/title/channels,
    /// chapters, subtitle streams), read off this pipeline's own context at
    /// `load`. `nil` before `load`.
    ///
    /// This is the enumeration half of track selection: a host transport lists
    /// `sourceInfo.audioTracks` (or `selectableAudioTracks`, already filtered
    /// to what this build can decode) and drives `selectAudioTrack` with the
    /// entry's `streamIndex`.
    public var sourceInfo: SourceInfo? {
        stateLock.withLock { storedSourceInfo }
    }

    /// The audio tracks `selectAudioTrack(streamIndex:)` will accept: every
    /// audio stream this build has a decoder for, in stream order. A track in
    /// `sourceInfo.audioTracks` but not here exists in the container and cannot
    /// be played by this build — worth showing disabled, not hiding.
    public var selectableAudioTracks: [AudioTrackInfo] {
        stateLock.withLock { storedSelectableAudioTracks }
    }

    /// The source stream index of the audio track currently feeding the
    /// renderer — the selection a host's audio menu marks. `nil` when the
    /// source has no decodable audio (or before `load`).
    public var selectedAudioStreamIndex: Int? {
        stateLock.withLock {
            storedSelectedAudioStreamIndex >= 0 ? Int(storedSelectedAudioStreamIndex) : nil
        }
    }

    /// Embedded text tracks supported by the same converter as HLS. Bitmap
    /// tracks remain in `sourceInfo` but are not selectable on this surface.
    public var selectableSubtitleTracks: [SubtitleTrackInfo] {
        stateLock.withLock { storedSourceInfo?.textSubtitleTracks ?? [] }
    }

    /// `nil` means Off, including initially. Stream indices belong to the source.
    public var selectedSubtitleStreamIndex: Int? {
        stateLock.withLock { storedSelectedSubtitleStreamIndex }
    }

    /// Poll alongside `currentTime` to draw (or clear) a host subtitle overlay.
    /// Times use the source axis, like this pipeline's clock. Text is WebVTT
    /// payload with optional inline tags, not an attributed string. Reading this
    /// never waits for demux I/O. Cues expire even when no more packets arrive.
    public var activeSubtitleCues: [TimedTextCue] {
        guard let index = selectedSubtitleStreamIndex else { return [] }
        return subtitleCues.active(streamIndex: index, at: CMTimeGetSeconds(currentTime))
    }

    /// Select embedded text or `nil` for Off. Conversion runs as packets arrive
    /// for every supported text track, so switching needs no A/V flush or seek,
    /// including while paused. Completion runs on the feed queue; dispatch to
    /// the main queue for UI work and do not call synchronous load/stop from it.
    public func selectSubtitleTrack(
        streamIndex: Int?, completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        feedQueue.async { [self] in
            guard !stopped, storedStateIsResumable,
                  streamIndex == nil || selectableSubtitleTracks.contains(where: { $0.streamIndex == streamIndex })
            else { completion?(false); return }
            stateLock.withLock { storedSelectedSubtitleStreamIndex = streamIndex }
            completion?(true)
        }
    }

    // MARK: - Collaborators

    private let videoSink: VideoSampleSink
    private let audioSink: AudioSampleSink
    private let timeline: RenderTimeline
    private let pacing: Pacing
    private let allowHardwareDecode: Bool

    /// Everything below — the demuxer, the decoders, the pending queues — is
    /// touched only on this serial queue, which is also the queue both renderers
    /// call back on. That is the whole concurrency story: no locks around
    /// libav* state, because there is only ever one thread in it.
    private let feedQueue = DispatchQueue(label: "cz.aether.prismcore.software.feed", qos: .userInitiated)
    /// Fixed for this pipeline; create a replacement to change already queued
    /// audio. Positive values present audio later. Range: -2...2 seconds.
    public private(set) var audioDelaySeconds: Double = 0

    private let stateLock = NSLock()
    private var storedState: State = .idle
    private var storedDurationSeconds: Double?
    private var storedSourceInfo: SourceInfo?
    private let subtitleCues = SoftwareSubtitleCueStore()
    private var storedSelectedSubtitleStreamIndex: Int?
    private var storedSelectableAudioTracks: [AudioTrackInfo] = []
    /// Mirror of `audioStreamIndex` (feed-queue state) for cross-thread reads.
    private var storedSelectedAudioStreamIndex: Int32 = -1
    public var audioDelivery: AudioDelivery {
        stateLock.withLock {
            guard let info = storedSourceInfo else { return .pending }
            if info.audioTracks.isEmpty { return .noAudioInSource }
            return storedSelectedAudioStreamIndex >= 0 ? .decoded : .unavailable
        }
    }

    // MARK: - Feed-queue state

    private var input: UnsafeMutablePointer<AVFormatContext>?
    private var packet: UnsafeMutablePointer<AVPacket>?
    /// The guard `input`'s blocking reads were CREATED with — an adopted
    /// context brings the probe's, a self-opened one gets its own before the
    /// open (see `ReadInterruptGuard` for why it cannot be added later). Under
    /// `stateLock` rather than feed-queue confined because `stop()` trips it
    /// from the caller's thread, *before* it can get onto the feed queue: the
    /// queue may be blocked inside a read against a server that stopped
    /// answering, and the trip is what brings that read back.
    private var interruptGuard: ReadInterruptGuard?
    /// Where an adopted context came from, kept alive until teardown: the
    /// guard's callback holds an unretained pointer and `ProbedSource` is what
    /// owns the guard on that path.
    private var adoptedSource: ProbedSource?
    private var videoDecoder: SoftwareVideoDecoder?
    private var audioDecoder: SoftwareAudioDecoder?
    private var videoStreamIndex: Int32 = -1
    private var audioStreamIndex: Int32 = -1

    private var pendingVideo: [CMSampleBuffer] = []
    /// Decoded bytes held in `pendingVideo`, kept alongside so the byte cap
    /// is one comparison rather than a walk of the queue per packet.
    private var pendingVideoBytes = 0
    private var pendingAudio: [CMSampleBuffer] = []
    /// Set while the system reports memory pressure: the pending window
    /// shrinks to the minimum that still decouples the renderers, and the
    /// pixel pool is flushed of its idle buffers. Restored on `.normal`.
    private var underMemoryPressure = false
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    /// The synchronizer boundary that turns "last buffer enqueued" into
    /// "last buffer played" — `.ended` fires from it, not from the enqueue.
    private var endObserver: Any?
    private var endGeneration: UInt64 = 0
    /// End (PTS + duration) of the newest audio buffer handed to the sink,
    /// and of the newest video frame — the later of the two is where the
    /// presentation actually ends.
    private var lastEnqueuedAudioEnd: CMTime = .invalid
    private var lastEnqueuedVideoEnd: CMTime = .invalid
    /// Renderer-failure recoveries in the current window, so a renderer that
    /// fails on every re-prime ends the session instead of looping forever.
    private var rendererRecoveries: [ContinuousClock.Instant] = []

    private var reachedEOF = false
    /// EOF reached but the frame-threaded video decoder still holds frames.
    /// They come out one per pump iteration, under the byte cap, instead of
    /// all at once — a full drain of a 4K tail into a blocked sink is exactly
    /// the allocation burst the cap exists to prevent.
    private var videoTailPending = false
    private var stopped = false
    /// The furthest packet end (PTS + duration, seconds) the demuxer has seen
    /// — the duration-of-record for a container that never states one (#58).
    /// Feed-queue confined, like the rest of the demux state; a seek can only
    /// lower the current position, never this maximum.
    private var maxSeenPacketEndSeconds: Double = 0
    /// The newest video PTS handed to the sink — where the renderer's picture
    /// horizon is. A track switch rewinds the demuxer to the clock's present,
    /// so the video decoder re-emits frames the renderer already holds; this
    /// is the watermark that identifies them.
    private var lastEnqueuedVideoPTS: CMTime = .invalid
    /// Set by a track switch: drop re-decoded video up to and including this
    /// PTS (the renderer already has it), cleared once a frame passes it.
    private var discardVideoUpTo: CMTime = .invalid
    /// Set by a track switch: drop audio that ends at or before this time —
    /// the rewind lands on a keyframe *before* the clock's present, and audio
    /// from that gap would either be dropped late by the renderer (playing) or
    /// worse, played as a stale burst (paused). Cleared once a buffer crosses it.
    private var discardAudioBefore: CMTime = .invalid
    /// False until the master clock has been parked on the first decoded
    /// buffer's timestamp. Cleared by a seek, which re-anchors on the first
    /// buffer after it.
    private var clockAnchored = false
    private var anchorTime: CMTime = .zero
    /// The PTS of the first frame decoded inside a seek's discard window —
    /// how far before the target the keyframe landed. Bounds the window: past
    /// `Pacing.maxSeekDiscardSeconds` of discarded content the frames are
    /// shown from the keyframe instead of thrown away (see `acceptVideo`).
    private var seekDiscardOrigin: CMTime?
    /// True while the discard window belongs to a seek (bounded), false for a
    /// track switch's (unbounded — those frames are on screen already).
    private var discardIsBounded = false

    /// Seek coalescing. Bumped on the CALLER's thread by every `seek(to:)`, so
    /// a seek block that runs later can tell it has been superseded and skip
    /// the flush-and-refill the next block is about to redo.
    private let seekLock = NSLock()
    private var seekGeneration: UInt64 = 0

    // MARK: - Init

    /// The shipping configuration: a real display layer, audio renderer and
    /// synchronizer.
    public convenience init(allowHardwareDecode: Bool = true, audioDelaySeconds: Double = 0) {
        let video = DisplayLayerVideoSink()
        let audio = AudioRendererSink()
        self.init(
            videoSink: video,
            audioSink: audio,
            timeline: SynchronizerTimeline(),
            allowHardwareDecode: allowHardwareDecode,
            audioDelaySeconds: audioDelaySeconds
        )
    }

    // Injecting the FFmpeg call lets tests refuse a seek without network timing.
    private let demuxSeek: (UnsafeMutablePointer<AVFormatContext>, Int64) -> Int32

    /// Injected seam — the constructor tests use. See `SampleBufferSinks.swift`
    /// for why the boundary sits here.
    init(
        videoSink: VideoSampleSink,
        audioSink: AudioSampleSink,
        timeline: RenderTimeline,
        pacing: Pacing = Pacing(),
        allowHardwareDecode: Bool = true,
        audioDelaySeconds: Double = 0,
        demuxSeek: @escaping (UnsafeMutablePointer<AVFormatContext>, Int64) -> Int32 = { input, target in
            avformat_seek_file(input, -1, Int64.min, target, target, AVSEEK_FLAG_BACKWARD)
        }
    ) {
        self.demuxSeek = demuxSeek
        self.videoSink = videoSink
        self.audioSink = audioSink
        self.timeline = timeline
        self.pacing = pacing
        self.allowHardwareDecode = allowHardwareDecode
        self.audioDelaySeconds = AudioDelay.normalized(audioDelaySeconds)
    }

    deinit {
        // Best effort: a pipeline dropped without stop() still must not leak an
        // AVFormatContext. Safe to run here because deinit means nothing else
        // holds a reference, so no feed-queue work can be in flight.
        teardown()
    }

    // MARK: - Transport

    /// Open the source, pick streams, build decoders, and decode enough to park
    /// the master clock on the first frame. Synchronous — call it off the main
    /// thread, like `HLSRemuxer.run()`.
    ///
    /// The open is bounded (`SourceOpenTuning.probeBudget`): a server that
    /// accepts the connection and then starves the reads would otherwise pin
    /// the caller inside `avformat_open_input` for as long as the socket lives,
    /// with no error and no way for the host to give up. On expiry this throws.
    /// - Parameter startAt: where playback should begin, on the source's own
    ///   axis. Seeked BEFORE the first frame is decoded: a resume that loads at
    ///   the head and then seeks pays for a keyframe's worth of decode it
    ///   throws straight away, and shows the wrong picture for that long.
    ///   `nil` (or zero) starts at the head.
    public func load(url: URL, httpHeaders: [String: String] = [:], startAt: CMTime? = nil, coordinatedHTTP: Bool = false) throws {
        try load(startAt: startAt) {
            try openInput(url: url, httpHeaders: httpHeaders, coordinatedHTTP: coordinatedHTTP)
        }
    }

    /// Adopt the context a routing probe already opened, instead of opening
    /// the source a second time. The same handover `PrismCoreSession(probed:)`
    /// does, for the same reason: over a network the second open is a real
    /// round trip and a real download inside the wait the user is watching —
    /// and the *context* has to travel, not merely the probe's conclusions,
    /// because `avformat_find_stream_info` fills state the decoders need (see
    /// `ProbedSource`).
    ///
    /// A `ProbedSource` whose context was already taken (handed to a session
    /// that then declined, say) falls back to a fresh open of `probed.url`, so
    /// the call never fails for a reason the host cannot see.
    public func load(probed: ProbedSource, startAt: CMTime? = nil) throws {
        try load(startAt: startAt) {
            if let adopted = probed.consumeContext() {
                try adoptInput(adopted, from: probed)
            } else {
                try openInput(url: probed.url, httpHeaders: probed.httpHeaders,
                              coordinatedHTTP: probed.interruptGuard.usesCoordinatedHTTP)
            }
        }
    }

    private func load(startAt: CMTime?, opening open: () throws -> Void) throws {
        try feedQueue.sync {
            guard input == nil, !stopped else { throw Failure.alreadyLoaded }
            setState(.loading)
            do {
                try open()
                try makeDecoders()
                if let startAt, startAt.isValid, startAt > .zero, let input {
                    // Before priming, not after: the head keyframe would be
                    // decoded, shown, and thrown away by the seek. A source
                    // that refuses the seek (no index) simply starts at the
                    // head — the same degradation `seek(to:)` accepts.
                    if seekDemuxer(input, to: startAt) {
                        beginDiscarding(upTo: startAt)
                    }
                }
                // Prime only as far as the first frame: park the clock on it
                // and hand it to the layer, so the host has a picture before
                // it ever calls play(). The rest of the queue depth fills on
                // the renderers' own pull — `load` returning a decode-window
                // later than it has to is latency the user sees on every open.
                try pumpUntilAnchored()
                startRequestingSamples()
                observeRendererFailures()
                installMemoryPressureSource()
                setState(.paused)
                feedQueue.async { [weak self] in self?.pump() }
            } catch {
                teardown()
                setState(.failed)
                throw error
            }
        }
    }

    public func play() {
        feedQueue.async { [self] in
            guard input != nil, !stopped else { return }
            // Resuming from `.ended` would need a seek first; a host that wants
            // replay calls seek(to: .zero) then play().
            guard storedStateIsResumable else { return }
            timeline.setRate(1, time: clockAnchored ? timeline.currentTime : anchorTime)
            setState(.playing)
            pump()
        }
    }

    public func pause() {
        feedQueue.async { [self] in
            guard input != nil, !stopped, state == .playing else { return }
            timeline.setRate(0, time: timeline.currentTime)
            setState(.paused)
        }
    }

    /// Seek to `time`: libavformat lands on the keyframe at or before it, the
    /// decoders are flushed, and frames between the keyframe and the target are
    /// decoded but discarded (up to `Pacing.maxSeekDiscardSeconds` of them), so
    /// the clock re-anchors on the first frame at or after `time`. Beyond that
    /// window — a very long GOP — playback resumes at the keyframe instead,
    /// which is late by less than showing nothing while a whole GOP decodes.
    ///
    /// Seeks coalesce: a scrub that queues several before the first has run
    /// executes only the newest, because each earlier one would flush and
    /// refill a queue the next one flushes again.
    public func seek(to time: CMTime) {
        performSeek(to: time, forceRefill: false)
    }

    /// - Parameter forceRefill: flush and re-prime even when the demuxer
    ///   refuses the seek (renderer recovery needs the flush more than the
    ///   position).
    private func performSeek(to time: CMTime, forceRefill: Bool) {
        let generation = seekLock.withLock {
            seekGeneration += 1
            return seekGeneration
        }
        feedQueue.async { [self] in
            guard let input, !stopped else { return }
            // Superseded before it ran: the newer seek does the work.
            guard isCurrentSeek(generation) else { return }
            let wasPlaying = state == .playing

            // Stop the clock first: refilling under a running clock means every
            // buffer we enqueue lands in the clock's past and is dropped.
            timeline.setRate(0, time: timeline.currentTime)

            guard seekDemuxer(input, to: time) || forceRefill else {
                // A source with no index (raw MPEG-2 TS) can refuse; leaving the
                // demuxer where it is beats tearing the session down.
                setState(wasPlaying ? .playing : .paused)
                if wasPlaying { timeline.setRate(1, time: timeline.currentTime) }
                return
            }
            // `forceRefill` with a refused seek: a renderer recovery on a
            // non-seekable source. The demuxer stays where it is and the
            // renderers are re-fed from there — a gap of the queue's
            // look-ahead, which beats staying black.

            videoDecoder?.flushBuffers()
            audioDecoder?.flushBuffers()
            clearPendingVideo()
            pendingAudio.removeAll()
            // Hold the last frame instead of blanking: the post-seek keyframe can
            // be half a second of decode away on exactly the codecs this path
            // serves, and a black flash reads as a bug.
            videoSink.flush(removingDisplayedImage: false)
            audioSink.flush()
            reachedEOF = false
            videoTailPending = false
            clockAnchored = false
            cancelEndObserver()
            // The renderer's queue is gone with the flush, and any in-flight
            // track-switch discard is moot — the seek moved the target.
            lastEnqueuedVideoPTS = .invalid
            lastEnqueuedVideoEnd = .invalid
            lastEnqueuedAudioEnd = .invalid
            subtitleCues.reset()
            beginDiscarding(upTo: time)

            do {
                try pumpUntilAnchored(bailingIfSuperseded: generation)
            } catch {
                fail(error)
                return
            }
            guard isCurrentSeek(generation) else {
                // A newer seek arrived while this one was decoding towards its
                // target; it is queued right behind us and will flush anyway,
                // so don't restart the clock on a position nobody wants.
                return
            }
            setState(wasPlaying ? .playing : .paused)
            if wasPlaying {
                timeline.setRate(1, time: anchorTime)
            }
            pump()
        }
    }

    private func isCurrentSeek(_ generation: UInt64) -> Bool {
        seekLock.withLock { seekGeneration == generation }
    }

    /// Position the demuxer at the keyframe at or before `time`. Stream index
    /// -1 + `AV_TIME_BASE` units lets libavformat pick its reference stream
    /// instead of us rescaling onto a guess; `avformat_seek_file` rather than
    /// `av_seek_frame` because the latter trips assertions in matroskadec with
    /// nested elements (AGENTS.md). Returns false when the source refused (no
    /// index — raw MPEG-2 TS), in which case the position is unchanged.
    ///
    /// Bounded by the read guard: a Matroska without Cues turns a timestamp
    /// seek into a linear scan of the whole container (66 s on one 5.4 GB
    /// file, AGENTS.md), and over a starving server that scan never ends. On
    /// expiry the seek fails like a refused one, and the latched
    /// `AVERROR_EXIT` is cleared so the context can read again.
    private func seekDemuxer(_ input: UnsafeMutablePointer<AVFormatContext>, to time: CMTime) -> Bool {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds < Double(Int64.max) / Double(AV_TIME_BASE) else { return false }
        let target = Int64(max(0, seconds) * Double(AV_TIME_BASE))
        let readGuard = stateLock.withLock { interruptGuard }
        readGuard?.arm(budget: Self.seekBudget)
        let result = demuxSeek(input, target)
        // Cancellation is permanent: disarming a seek must not undo a stop
        // that arrived while FFmpeg was blocked inside it.
        readGuard?.disarm()
        if let pb = input.pointee.pb, pb.pointee.error < 0 {
            pb.pointee.error = 0
        }
        guard result >= 0 else { return false }
        avformat_flush(input)
        return true
    }

    /// Generous like the probe's: a healthy index seek is milliseconds, so
    /// the budget only ever cuts off a scan that was not going to finish.
    static let seekBudget: Duration = SourceOpenTuning.probeBudget

    /// Arm the decode-and-discard window after a seek: the keyframe libavformat
    /// landed on is *before* the target, and everything between is decoded
    /// (the decoder needs it as reference) but not shown. Video strictly
    /// before the target goes, audio that ENDS at or before it goes, and the
    /// clock anchors on the first survivor — so playback resumes where the
    /// user asked, not where the GOP happened to start. `seekDiscardOrigin`
    /// bounds the window (see `acceptVideo`).
    private func beginDiscarding(upTo target: CMTime) {
        // `<` semantics on a `<=` comparison: one microsecond back, so the frame
        // exactly at the target survives.
        discardVideoUpTo = target - CMTime(value: 1, timescale: 1_000_000)
        discardAudioBefore = target
        seekDiscardOrigin = nil
        discardIsBounded = true
    }

    /// Read and decode until the clock is anchored on a first frame and one
    /// drain pass has offered it to the sink — the minimum `load` must do
    /// before it can return. Bounded by EOF and by the pending caps, the same
    /// way `pump` is.
    private func pumpUntilAnchored(bailingIfSuperseded generation: UInt64? = nil) throws {
        while !stopped, !reachedEOF || videoTailPending {
            if let generation, !isCurrentSeek(generation) { return }
            if clockAnchored {
                drainPending()
                return
            }
            let videoCapped = pendingVideoBytes >= pacing.maxPendingVideoBytes
                || pendingVideo.count >= pacing.videoDepth * pacing.hardCapMultiplier
            let audioCapped = pendingAudio.count >= pacing.audioDepth * pacing.hardCapMultiplier
            if videoCapped || audioCapped { return }
            if reachedEOF, let videoDecoder {
                videoTailPending = try videoDecoder.receiveOneAtEOF(emit: acceptVideo)
            } else {
                try readAndDecodeOnePacket()
            }
        }
        drainPending()
    }

    /// Switch the audio to another of the source's tracks, mid-playback,
    /// without touching the clock or the video renderer (issue #35).
    ///
    /// `streamIndex` is the source stream index, i.e.
    /// `AudioTrackInfo.streamIndex` from `selectableAudioTracks`. Selecting the
    /// already-playing track is a no-op that still reports success. The switch
    /// is refused (`completion(false)`) when the pipeline isn't in a playable
    /// state, the index isn't a selectable audio stream, or the new track's
    /// decoder fails to open — in every refusal the current track keeps
    /// playing, because the old decoder is only torn down *after* the new one
    /// stands.
    ///
    /// The audible gap depends on transport and decode-to-playhead time. The
    /// clock continues running and the video renderer keeps its queued frames.
    /// Works identically while paused — the new
    /// track is primed at the paused position and plays on `play()`.
    ///
    /// - Parameter completion: called on the feed queue with whether the
    ///   switch happened. Optional — fire-and-forget is fine for a menu tap;
    ///   read `selectedAudioStreamIndex` for the settled answer.
    public func selectAudioTrack(
        streamIndex: Int,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        feedQueue.async { [self] in
            guard let input, !stopped, storedStateIsResumable else {
                completion?(false)
                return
            }
            if audioStreamIndex >= 0, streamIndex == Int(audioStreamIndex) {
                completion?(true)
                return
            }
            guard streamIndex >= 0, streamIndex < Int(input.pointee.nb_streams),
                  let stream = input.pointee.streams[streamIndex],
                  stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO
            else {
                completion?(false)
                return
            }

            // New decoder first: a track whose decoder can't open must leave
            // the current track playing, not playback silent.
            let newDecoder: SoftwareAudioDecoder
            do {
                newDecoder = try SoftwareAudioDecoder(
                    codecpar: stream.pointee.codecpar,
                    timeBase: stream.pointee.time_base
                )
            } catch {
                completion?(false)
                return
            }

            // Rewind the demuxer to the clock's present so the new track picks
            // up where the listener is, not where the read cursor had run
            // ahead to. `.invalid` clock (never anchored) means nothing has
            // played yet — the read position IS the present, skip the seek.
            let now = timeline.currentTime
            // Positive output delay means the source audio we need is earlier
            // than the playhead; negative delay needs later source samples.
            let audioTarget = now - CMTime(seconds: audioDelaySeconds, preferredTimescale: 1_000_000)
            let rewound = now.isNumeric && seekDemuxer(input, to: min(now, audioTarget))

            let hadAudio = audioDecoder != nil
            audioDecoder?.close()
            audioDecoder = newDecoder
            audioStreamIndex = Int32(streamIndex)
            stateLock.withLock { storedSelectedAudioStreamIndex = Int32(streamIndex) }
            pendingAudio.removeAll()
            audioSink.flush()
            cancelEndObserver()
            discardAudioBefore = audioTarget

            if rewound {
                // A refused rewind at EOF cannot enqueue a new audio boundary;
                // keep the old horizon so audio-only playback does not end now.
                lastEnqueuedAudioEnd = .invalid
                // The rewind re-reads video the renderer already holds: flush
                // the decoder (its reference chain broke with the seek) and
                // drop re-decoded frames up to the renderer's horizon, so the
                // video path never notices the switch happened.
                videoDecoder?.flushBuffers()
                clearPendingVideo()
                discardVideoUpTo = lastEnqueuedVideoPTS
                discardIsBounded = false
                // The rewind lands on a keyframe before the present; audio
                // from that gap is late (playing) or a stale burst on resume
                // (paused) — drop it here rather than trusting the renderer.
                reachedEOF = false
                videoTailPending = false
            }

            if !hadAudio {
                // The source loaded without a working audio decoder (the best
                // stream's codec is missing from this build) — the sink was
                // never attached, so the switch is also the audio bring-up.
                timeline.attach(audioSink)
                audioSink.requestSamples(on: feedQueue) { [weak self] in
                    self?.pump()
                }
            }

            pump()
            completion?(state != .failed)
        }
    }

    /// Tear everything down. The pipeline is single-use afterwards.
    public func stop() {
        // Trip the read guard BEFORE queueing behind the feed loop: the loop
        // may be blocked inside `av_read_frame` against a server that stopped
        // answering, and `feedQueue.sync` would wait on exactly that read.
        // With the guard tripped the read aborts (`AVERROR_EXIT`), the loop
        // fails out, and the sync below gets its turn. Permanent cancellation
        // survives a concurrently finishing seek disarming its deadline.
        stateLock.withLock { interruptGuard }?.cancel()
        feedQueue.sync {
            guard !stopped else { return }
            stopped = true
            timeline.setRate(0, time: timeline.currentTime)
            videoSink.stopRequestingSamples()
            audioSink.stopRequestingSamples()
            videoSink.stopObservingFailure()
            audioSink.stopObservingFailure()
            videoSink.flush(removingDisplayedImage: true)
            audioSink.flush()
            teardown()
            setState(.idle)
        }
    }

    /// Block until the feed queue has run everything already scheduled on it.
    /// Exists for tests, whose assertions would otherwise race the async
    /// transport calls; harmless in production and never called there.
    func waitForFeedQueue() {
        feedQueue.sync { }
    }

    /// Park the feed queue until `gate` is signalled. Exists so a test can
    /// queue several transport calls and know they are pending *together* —
    /// the precondition seek coalescing is about. Never called in production.
    func blockFeedQueueForTesting(until gate: DispatchSemaphore) {
        feedQueue.async { gate.wait() }
    }

    // MARK: - Setup

    /// Same open pattern as `HLSRemuxer` / `SourceProbe`: the caller's headers
    /// ride the demux connection, dropped HTTP connections reconnect, and the
    /// analysis runs under the shared read caps (`SourceOpenTuning`) — over a
    /// network this open IS the wait the user sees.
    private func openInput(url: URL, httpHeaders: [String: String], coordinatedHTTP: Bool = false) throws {
        var openOptions = SourceOpenTuning.makeOptions(httpHeaders: httpHeaders)
        defer { av_dict_free(&openOptions) }

        // The guard has to exist before the open — the blocking reads check
        // the URLContext's copy of the callback, taken at creation — and it
        // is armed across open + analysis so a starving server produces an
        // error instead of a caller parked forever (`stop()` trips it too).
        let readGuard = ReadInterruptGuard()
        stateLock.withLock { interruptGuard = readGuard }
        var context = readGuard.makeContext()
        if coordinatedHTTP, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let context {
            do { try readGuard.installHTTPInput(on: context, url: url, headers: httpHeaders) }
            catch { avformat_free_context(context); throw error }
        }
        readGuard.arm(budget: SourceOpenTuning.probeBudget)
        defer { readGuard.disarm() }

        let sourceSpec = url.isFileURL ? url.path : url.absoluteString
        try FFmpegError.check(
            avformat_open_input(&context, sourceSpec, nil, &openOptions),
            "avformat_open_input"
        )
        input = context
        try FFmpegError.check(avformat_find_stream_info(context, nil), "avformat_find_stream_info")
        // `find_stream_info` swallows aborted reads — cut off mid-analysis it
        // returns success with half-filled parameters. The clock is the honest
        // witness (see `SourceProbe.open`).
        if readGuard.shouldInterrupt {
            throw FFmpegError(code: swift_AVERROR_EXIT(), operation: "open budget exhausted")
        }
        try describeInput()
    }

    /// Take over a probe's context: its guard, its description, and a read
    /// position the probe left wherever its reads ended (the interlace
    /// verification decodes a dozen frames). Playback starts at the head, so
    /// rewind and flush before the first packet is read.
    private func adoptInput(
        _ context: UnsafeMutablePointer<AVFormatContext>, from probed: ProbedSource
    ) throws {
        input = context
        adoptedSource = probed
        stateLock.withLock { interruptGuard = probed.interruptGuard }
        // An expired probe budget latched AVERROR_EXIT in the AVIOContext and
        // the first read here would return it verbatim; the probe clears it,
        // but a context that travelled through other hands may not have been.
        if let pb = context.pointee.pb, pb.pointee.error < 0 {
            pb.pointee.error = 0
        }
        guard seekDemuxer(context, to: .zero) else {
            // A source that cannot rewind (a range-less HTTP server, a pipe)
            // would start wherever the probe's interlace verification left
            // it — the first frames of the film silently clipped. A fresh
            // open costs the round trip this path was meant to save, and is
            // the only way to start at the head there.
            teardownInput()
            try openInput(url: probed.url, httpHeaders: probed.httpHeaders,
                          coordinatedHTTP: probed.interruptGuard.usesCoordinatedHTTP)
            return
        }
        try describeInput(using: probed.info)
    }

    /// Close the demux context (and release what travels with it) without
    /// touching decoders or sinks — the adopt-then-reopen fallback.
    private func teardownInput() {
        if input != nil {
            let readGuard = stateLock.withLock { interruptGuard }
            withExtendedLifetime(readGuard) {
                avformat_close_input(&input)
            }
        }
        adoptedSource = nil
        stateLock.withLock { interruptGuard = nil }
    }

    /// Publish duration and the per-stream description off the open context,
    /// and allocate the read packet. `info` lets an adopted context reuse the
    /// probe's answer — which includes the verified interlace verdict that
    /// costs decoded frames and must not be paid twice.
    private func describeInput(using info: SourceInfo? = nil) throws {
        guard let context = input else { throw Failure.notLoaded }
        let known = context.pointee.duration
        if known != swift_AV_NOPTS_VALUE() {
            stateLock.withLock { storedDurationSeconds = Double(known) / Double(AV_TIME_BASE) }
        }

        // The probe's per-stream description, off this very context — track
        // menus and chapter markers for the host, plus the enumeration half of
        // audio selection. No interlace verification on a self-opened context:
        // that read consumes packets, and this context's read position is the
        // playback.
        let description = info ?? SourceProbe.describe(input: context)
        let selectable = description.audioTracks.filter { track in
            guard track.streamIndex < Int(context.pointee.nb_streams),
                  let stream = context.pointee.streams[track.streamIndex]
            else { return false }
            return avcodec_find_decoder(stream.pointee.codecpar.pointee.codec_id) != nil
        }
        stateLock.withLock {
            storedSourceInfo = description
            storedSelectableAudioTracks = selectable
        }

        guard let allocated = av_packet_alloc() else {
            throw FFmpegError(code: -1, operation: "av_packet_alloc")
        }
        packet = allocated
    }

    private func makeDecoders() throws {
        guard let input else { throw Failure.notLoaded }

        let video = av_find_best_stream(input, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        if video >= 0, let stream = input.pointee.streams[Int(video)] {
            do {
                // Declared interlaced → run the deinterlacer. Routing only
                // sends *verified* interlaced sources here, so this mostly
                // agrees with the probe; when a host loads the pipeline
                // directly, `bwdif deint=interlaced` still passes progressive
                // frames through untouched, so over-engaging costs the
                // hardware route, never correctness.
                let fieldOrder = stream.pointee.codecpar.pointee.field_order
                let declaredInterlaced = fieldOrder == AV_FIELD_TT
                    || fieldOrder == AV_FIELD_BB
                    || fieldOrder == AV_FIELD_TB
                    || fieldOrder == AV_FIELD_BT
                videoDecoder = try SoftwareVideoDecoder(
                    codecpar: stream.pointee.codecpar,
                    timeBase: stream.pointee.time_base,
                    averageFrameRate: stream.pointee.avg_frame_rate,
                    allowHardware: allowHardwareDecode,
                    deinterlace: declaredInterlaced
                )
                videoStreamIndex = video
                timeline.attach(videoSink)
            } catch {
                // No decoder for this video codec in this build. Audio-only
                // playback of a video file is a poor experience but a better one
                // than a failed load, and `SoftwareDecoderAvailability` is how a
                // router avoids getting here in the first place.
                videoDecoder = nil
                videoStreamIndex = -1
            }
        }

        let audio = av_find_best_stream(input, AVMEDIA_TYPE_AUDIO, -1, video, nil, 0)
        if audio >= 0, let stream = input.pointee.streams[Int(audio)] {
            do {
                audioDecoder = try SoftwareAudioDecoder(
                    codecpar: stream.pointee.codecpar,
                    timeBase: stream.pointee.time_base
                )
                audioStreamIndex = audio
                stateLock.withLock { storedSelectedAudioStreamIndex = audio }
                timeline.attach(audioSink)
            } catch {
                audioDecoder = nil
                audioStreamIndex = -1
            }
        }

        guard videoDecoder != nil || audioDecoder != nil else {
            throw Failure.noDecodableStream
        }
    }

    /// Both renderers pull on the same serial queue, so a callback can never run
    /// concurrently with the feed loop — it just re-enters it.
    private func startRequestingSamples() {
        if videoDecoder != nil {
            videoSink.requestSamples(on: feedQueue) { [weak self] in
                self?.pump()
            }
        }
        if audioDecoder != nil {
            audioSink.requestSamples(on: feedQueue) { [weak self] in
                self?.pump()
            }
        }
    }

    // MARK: - The feed loop

    /// One pass of drain-then-read. Always on `feedQueue`.
    private func pump() {
        guard !stopped, input != nil else { return }
        do {
            while !stopped {
                drainPending()

                let videoDepth = underMemoryPressure ? min(2, pacing.videoDepth) : pacing.videoDepth
                let audioDepth = underMemoryPressure ? min(8, pacing.audioDepth) : pacing.audioDepth
                let videoWantsMore = videoDecoder != nil && pendingVideo.count < videoDepth
                let audioWantsMore = audioDecoder != nil && pendingAudio.count < audioDepth
                guard videoWantsMore || audioWantsMore || reachedEOF else { return }

                // The bound on "read for whoever is still hungry": one stream's
                // queue may run ahead of its depth while we chase the other, but
                // not without limit — and for video the limit is BYTES, because
                // a frame count says nothing about what 4K costs.
                let videoByteCap = underMemoryPressure
                    ? pacing.maxPendingVideoBytes / 4
                    : pacing.maxPendingVideoBytes
                let videoCapped = pendingVideoBytes >= videoByteCap
                    || pendingVideo.count >= videoDepth * pacing.hardCapMultiplier
                let audioCapped = pendingAudio.count >= audioDepth * pacing.hardCapMultiplier

                if reachedEOF {
                    if videoTailPending, !videoCapped, let videoDecoder {
                        videoTailPending = try videoDecoder.receiveOneAtEOF(emit: acceptVideo)
                        continue
                    }
                    if !videoTailPending, pendingVideo.isEmpty, pendingAudio.isEmpty {
                        scheduleEndedIfNeeded()
                    }
                    return
                }
                if videoCapped || audioCapped { return }

                try readAndDecodeOnePacket()
            }
        } catch {
            fail(error)
        }
    }

    /// Hand each sink as much as it will take. Per-sink, so a full video
    /// renderer never blocks the audio renderer.
    private func drainPending() {
        while let next = pendingVideo.first, videoSink.isReadyForMoreSamples {
            videoSink.enqueue(next)
            pendingVideo.removeFirst()
            pendingVideoBytes = max(0, pendingVideoBytes - Self.decodedByteCount(of: next))
            let pts = CMSampleBufferGetPresentationTimeStamp(next)
            if pts.isValid, !lastEnqueuedVideoPTS.isValid || pts > lastEnqueuedVideoPTS {
                lastEnqueuedVideoPTS = pts
            }
            let end = Self.presentationEnd(of: next)
            if end.isValid, !lastEnqueuedVideoEnd.isValid || end > lastEnqueuedVideoEnd {
                lastEnqueuedVideoEnd = end
            }
        }
        while let next = pendingAudio.first, audioSink.isReadyForMoreSamples {
            let delivered: CMSampleBuffer
            do { delivered = try AudioDelay.shifted(next, seconds: audioDelaySeconds) }
            catch { fail(error); return }
            audioSink.enqueue(delivered)
            pendingAudio.removeFirst()
            let end = Self.presentationEnd(of: delivered)
            if end.isValid, !lastEnqueuedAudioEnd.isValid || end > lastEnqueuedAudioEnd {
                lastEnqueuedAudioEnd = end
            }
        }
    }

    private func appendPendingVideo(_ sampleBuffer: CMSampleBuffer) {
        pendingVideo.append(sampleBuffer)
        pendingVideoBytes += Self.decodedByteCount(of: sampleBuffer)
    }

    private func clearPendingVideo() {
        pendingVideo.removeAll()
        pendingVideoBytes = 0
    }

    /// What a decoded frame costs in memory: the pixel buffer's planes as
    /// allocated (stride × height, so padding counts — it is real memory).
    /// Falls back to width × height × 1.5 for a buffer with no image (never
    /// the case on this path, but the cap must not become zero if it were).
    private static func decodedByteCount(of sampleBuffer: CMSampleBuffer) -> Int {
        guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return 0 }
        if CVPixelBufferIsPlanar(image) {
            var total = 0
            for plane in 0..<CVPixelBufferGetPlaneCount(image) {
                total += CVPixelBufferGetBytesPerRowOfPlane(image, plane)
                    * CVPixelBufferGetHeightOfPlane(image, plane)
            }
            if total > 0 { return total }
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(image)
        if rowBytes > 0 { return rowBytes * CVPixelBufferGetHeight(image) }
        return CVPixelBufferGetWidth(image) * CVPixelBufferGetHeight(image) * 3 / 2
    }

    /// PTS + duration, or the PTS alone when the buffer carries no duration.
    private static func presentationEnd(of sampleBuffer: CMSampleBuffer) -> CMTime {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        guard pts.isValid else { return .invalid }
        return duration.isValid && duration > .zero ? pts + duration : pts
    }

    // MARK: - End of playout

    /// Every buffer is with the renderers; `.ended` must still wait until the
    /// speaker has finished the last one. Firing it on the last enqueue — as
    /// this pipeline once did — cut off roughly the renderer's queue depth of
    /// audio, half a second on AAC, because hosts tear down on `.ended`. So
    /// the synchronizer is asked to call back when its clock reaches the last
    /// presentation end, and only that callback flips the state.
    private func scheduleEndedIfNeeded() {
        guard state != .ended, endObserver == nil else { return }
        var end: CMTime = lastEnqueuedVideoEnd
        if lastEnqueuedAudioEnd.isValid, !end.isValid || lastEnqueuedAudioEnd > end {
            end = lastEnqueuedAudioEnd
        }
        guard end.isValid else {
            // Nothing was ever enqueued (an empty source): there is no
            // presentation to wait for.
            setState(.ended)
            return
        }
        let generation = endGeneration
        endObserver = timeline.observeBoundary(end, on: feedQueue) { [weak self, end] in
            guard let self, !self.stopped, self.endGeneration == generation else { return }
            self.endObserver = nil
            // A seek in between cancelled the observer, so reaching here
            // means the same run reached its end.
            self.timeline.setRate(0, time: end)
            self.setState(.ended)
        }
    }

    private func cancelEndObserver() {
        endGeneration &+= 1
        if let endObserver {
            timeline.cancelBoundaryObserver(endObserver)
        }
        endObserver = nil
    }

    // MARK: - Memory pressure

    /// Shrink under pressure instead of being killed under it. The pending
    /// window drops to the minimum that still decouples the renderers, and the
    /// pixel pool returns its idle buffers — those are the two allocations
    /// this pipeline owns that are not already bounded by the renderers.
    private func installMemoryPressureSource() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical, .normal], queue: feedQueue
        )
        source.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            let event = source.data
            if event.contains(.critical) || event.contains(.warning) {
                self.underMemoryPressure = true
                self.videoDecoder?.releaseIdlePixelBuffers()
            } else if event.contains(.normal) {
                self.underMemoryPressure = false
                // Depth is back; the next pull refills it.
                self.pump()
            }
        }
        source.activate()
        memoryPressureSource = source
    }

    // MARK: - Renderer failure

    /// A renderer that failed (the app came back from the background with its
    /// decode session gone, a `requiresFlushToResumeDecoding` on the display
    /// layer, an audio route change the renderer did not survive) shows black
    /// or goes silent for good unless it is flushed and re-fed — the samples
    /// it holds are not coming back. Recover by flushing everything, seeking
    /// to where the clock is, and priming again as a `seek` would; give up
    /// after three in ten seconds, because a renderer that fails on every
    /// re-prime is telling us something a fourth attempt will not fix.
    private func recoverRenderers() {
        guard input != nil, !stopped, storedStateIsResumable else { return }
        let now = ContinuousClock.now
        rendererRecoveries.removeAll { now - $0 > .seconds(10) }
        rendererRecoveries.append(now)
        guard rendererRecoveries.count <= 3 else {
            fail(Failure.rendererFailed)
            return
        }
        let resumeAt = timeline.currentTime.isValid ? timeline.currentTime : anchorTime
        performSeek(to: resumeAt, forceRefill: true)
    }

    private func observeRendererFailures() {
        videoSink.observeFailure(on: feedQueue) { [weak self] in self?.recoverRenderers() }
        audioSink.observeFailure(on: feedQueue) { [weak self] in self?.recoverRenderers() }
    }

    private func readAndDecodeOnePacket() throws {
        guard let input, let packet else { return }

        let readResult = av_read_frame(input, packet)
        if readResult == swift_AVERROR_EOF() {
            reachedEOF = true
            // A container that never stated its duration has now been read to
            // the end, and the furthest packet end IS the duration — the one
            // moment the pipeline can stop answering nil honestly (#58).
            if maxSeenPacketEndSeconds > 0,
               stateLock.withLock({ storedDurationSeconds == nil }) {
                stateLock.withLock { storedDurationSeconds = maxSeenPacketEndSeconds }
            }
            // Drain the decoders: a frame-threaded decoder holds several frames
            // at EOF, and they are real picture. Audio's tail is a few small
            // buffers; video's is pulled a frame at a time by `pump`, under
            // the byte cap.
            videoTailPending = videoDecoder != nil
            try audioDecoder?.decode(nil, emit: acceptAudio)
            return
        }
        try FFmpegError.check(readResult, "av_read_frame")
        defer { av_packet_unref(packet) }

        // The duration is knowledge, not a constant: the header may not have
        // carried one at `load`, and libavformat can learn it later. While the
        // answer is still nil, keep looking — one comparison per packet, and
        // it stops mattering the moment either source of truth lands (#58).
        if stateLock.withLock({ storedDurationSeconds == nil }) {
            let known = input.pointee.duration
            if known != swift_AV_NOPTS_VALUE(), known > 0 {
                stateLock.withLock { storedDurationSeconds = Double(known) / Double(AV_TIME_BASE) }
            }
            let streamIndex = Int(packet.pointee.stream_index)
            if packet.pointee.pts != swift_AV_NOPTS_VALUE(),
               streamIndex < Int(input.pointee.nb_streams),
               let stream = input.pointee.streams[streamIndex] {
                let end = Double(packet.pointee.pts + max(packet.pointee.duration, 0))
                    * av_q2d(stream.pointee.time_base)
                if end > maxSeenPacketEndSeconds { maxSeenPacketEndSeconds = end }
            }
        }

        if let stream = input.pointee.streams[Int(packet.pointee.stream_index)],
           let kind = SubtitleRenditionSet.kind(for: stream.pointee.codecpar.pointee.codec_id) {
            subtitleCues.ingest(packet, timeBase: stream.pointee.time_base, kind: kind,
                                currentTime: clockAnchored ? CMTimeGetSeconds(timeline.currentTime) : .nan)
        }

        switch Int32(packet.pointee.stream_index) {
        case videoStreamIndex:
            try videoDecoder?.decode(packet, emit: acceptVideo)
        case audioStreamIndex:
            try audioDecoder?.decode(packet, emit: acceptAudio)
        default:
            break   // a stream we didn't select (second audio track, subtitles)
        }
    }

    private func acceptVideo(_ sampleBuffer: CMSampleBuffer) throws {
        // A track switch's rewind re-decodes frames the renderer already
        // holds; re-enqueuing them would make the video path a participant in
        // an audio-only operation. Drop up to the watermark, then stand down.
        if discardVideoUpTo.isValid {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if pts.isValid, pts <= discardVideoUpTo {
                // A seek's window is bounded: a keyframe further before the
                // target than the cap means decoding seconds of picture
                // nobody sees, on exactly the codecs (MPEG-2 broadcast, VC-1)
                // where CPU decode is slowest. Then show from the keyframe —
                // late, but at once. Decided on the FIRST decoded frame, so a
                // too-long window costs nothing before it is abandoned. A
                // track switch's window is never bounded: those frames ARE on
                // screen already.
                if seekDiscardOrigin == nil { seekDiscardOrigin = pts }
                if discardIsBounded, let origin = seekDiscardOrigin,
                   CMTimeGetSeconds(discardVideoUpTo - origin) > pacing.maxSeekDiscardSeconds {
                    discardVideoUpTo = .invalid
                    discardAudioBefore = .invalid
                } else {
                    return
                }
            } else {
                discardVideoUpTo = .invalid
            }
        }
        anchorClock(on: sampleBuffer)
        appendPendingVideo(sampleBuffer)
    }

    private func acceptAudio(_ sampleBuffer: CMSampleBuffer) throws {
        // The switch's rewind lands on a keyframe before the clock's present;
        // the new track's audio from that gap must not reach the renderer
        // (late while playing, a stale burst on resume while paused).
        if discardAudioBefore.isValid {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let duration = CMSampleBufferGetDuration(sampleBuffer)
            let end = duration.isValid ? pts + duration : pts
            if end.isValid, end <= discardAudioBefore { return }
            discardAudioBefore = .invalid
        }
        // Video anchors the clock when there is video: starting the clock at an
        // audio buffer that precedes the first frame (common — audio leads in
        // most interleaves) would put the first frames in the clock's past.
        if videoDecoder == nil {
            anchorClock(on: sampleBuffer)
        }
        pendingAudio.append(sampleBuffer)
    }

    /// Park the master clock on the first buffer of a run (load, or after a
    /// seek). Rate stays where it is: `play()` starts it, and a seek that was
    /// playing restarts it once the queues are refilled.
    private func anchorClock(on sampleBuffer: CMSampleBuffer) {
        guard !clockAnchored else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard time.isValid else { return }
        anchorTime = time
        clockAnchored = true
        timeline.setRate(0, time: time)
    }

    private var storedStateIsResumable: Bool {
        switch state {
        case .paused, .playing: return true
        case .idle, .loading, .ended, .failed: return false
        }
    }

    private func fail(_ error: any Error) {
        // A read or decode error ends the session: the renderers keep whatever
        // they were given (so the last second still plays out) and the state
        // tells the host to route elsewhere.
        videoSink.stopRequestingSamples()
        audioSink.stopRequestingSamples()
        timeline.setRate(0, time: timeline.currentTime)
        failureError = error
        setState(.failed)
    }

    /// The terminal error, if any. Polled by a host that saw `.failed`.
    public private(set) var failureError: (any Error)?

    // MARK: - Teardown

    private func teardown() {
        cancelEndObserver()
        subtitleCues.reset()
        stateLock.withLock { storedSelectedSubtitleStreamIndex = nil }
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        videoDecoder?.close()
        videoDecoder = nil
        audioDecoder?.close()
        audioDecoder = nil
        clearPendingVideo()
        pendingAudio.removeAll()
        timeline.detach(videoSink)
        timeline.detach(audioSink)
        if packet != nil {
            av_packet_free(&packet)
        }
        if input != nil {
            // The guard's callback runs on the teardown reads too (a tail
            // request being torn down), and it holds an unretained pointer —
            // keep the guard alive through the close.
            let readGuard = stateLock.withLock { interruptGuard }
            withExtendedLifetime(readGuard) {
                avformat_close_input(&input)
            }
        }
        adoptedSource = nil
        stateLock.withLock { interruptGuard = nil }
        videoStreamIndex = -1
        audioStreamIndex = -1
        stateLock.withLock { storedSelectedAudioStreamIndex = -1 }
    }

    private func setState(_ newState: State) {
        let changed: Bool = stateLock.withLock {
            guard storedState != newState else { return false }
            storedState = newState
            return true
        }
        guard changed else { return }
        onStateChange?(newState)
    }
}
