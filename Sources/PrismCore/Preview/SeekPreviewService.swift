import Foundation
import CoreGraphics
import Libavcodec
import Libavformat
import Libavutil
import Libswscale

/// Scrub-bar thumbnails for any source libavformat can open — the floating
/// frame a player HUD shows while the user drags the seek bar.
///
/// This is deliberately its own small pipeline, not a reuse of the playback
/// paths, and independent of which engine is actually *playing* the title:
///
/// - It opens its **own context**. An `AVFormatContext` is not safe for
///   concurrent use, and the producer's is busy producing — a thumbnail
///   request must never stall playback, only itself.
/// - It decodes on the **CPU only**. A thumbnail is one keyframe scaled to
///   ~300 px: VideoToolbox would win milliseconds and cost a hardware session
///   per preview strip, plus the fallback complexity playback genuinely
///   needs and this doesn't. `sws_scale` also IS the delivery format step —
///   the decode and the downscale are one pipeline stage here.
/// - The image comes back as a `CGImage`, because the only consumer is a HUD
///   about to draw it. No `CVPixelBuffer`, no `CMSampleBuffer` — those exist
///   for renderers.
///
/// A request decodes the keyframe at-or-before the timestamp (`av_seek_frame`
/// BACKWARD lands there; keyframes decode standalone, so one packet usually
/// suffices) and the result is cached by the keyframe's PTS: scrubbing within
/// one GOP is a dictionary hit, not a decode. When the source has a harvested
/// keyframe map (`KeyframeIndexCache`, issue #34), requests resolve to their
/// keyframe *before* seeking, so even the first touch of a GOP that is
/// already cached skips the demuxer entirely.
///
/// Known caveats, accepted for v1: HDR (PQ/HLG) sources are converted by
/// matrix, not tone-mapped — previews look flatter than the picture. Dolby
/// Vision Profile 5 (IPT-PQc2) has no honest RGB conversion here at all; the
/// host should not offer engine previews for P5 (`SourceInfo` says).
public actor SeekPreviewService {

    public enum Failure: Error {
        /// The service was closed; requests after `close()` are a caller bug.
        case closed
        /// The source has no video stream, or its codec has no decoder in
        /// this FFmpeg build.
        case undecodable(String)
        /// The demuxer delivered no decodable keyframe near the timestamp —
        /// a truncated tail, or a seek the transport couldn't do.
        case noFrame
    }

    /// Long-edge bound of produced thumbnails, display pixels.
    private let maxDimension: Int
    private let url: URL
    private let httpHeaders: [String: String]
    private let coordinatedHTTP: Bool
    /// The host's byte source, when it supplies one. This service opens its
    /// OWN context, so it takes its own instance: a preview seeks all over
    /// the file while the producer reads forward, and one shared cursor
    /// between them would corrupt both.
    private let inputFactory: PrismCoreInputFactory?
    /// The cross-session keyframe map, when the host gave the session one —
    /// same directory, same identity, so a file that played once resolves
    /// scrub positions without touching the demuxer.
    private let keyframeCacheDirectory: URL?

    private var input: UnsafeMutablePointer<AVFormatContext>?
    private var interruptGuard: ReadInterruptGuard?
    private var decoder: ThumbnailDecoder?
    private var videoStreamIndex: Int32 = -1
    private var timeBase = AVRational(num: 1, den: 1)
    private var durationSeconds: Double = 0
    private var keyframeMap: [Int64]?
    private var closed = false
    private var opened = false

    /// Thumbnails by the PTS of the keyframe they decode, plus insertion
    /// order for LRU. 32 × a ~300 px RGBA image ≈ 10 MB ceiling.
    private var cache: [Int64: CGImage] = [:]
    private var cacheOrder: [Int64] = []
    private let cacheLimit = 32
    /// What decoding taught us, when no harvested map exists: keyframe PTS →
    /// the highest position PROVEN to belong to it. A request at T that
    /// decoded keyframe P proves no keyframe exists in (P, T] — the demuxer
    /// would have landed on it — so everything in [P, T] shares P's
    /// thumbnail. Forward of T the next keyframe may lurk anywhere, and
    /// guessing would pin a wrong picture into an image cache; those requests
    /// seek. Evicted together with the thumbnail they describe.
    private var covered: [Int64: Int64] = [:]

    /// How many demux+decode passes ran — the cache's witness in tests.
    private(set) var decodeCount = 0

    public init(
        url: URL,
        httpHeaders: [String: String] = [:],
        maxDimension: Int = 320,
        keyframeIndexCacheDirectory: URL? = nil,
        coordinatedHTTP: Bool = false,
        input: PrismCoreInputFactory? = nil
    ) {
        self.url = url
        self.inputFactory = input
        self.httpHeaders = httpHeaders
        self.coordinatedHTTP = coordinatedHTTP
        self.maxDimension = max(32, maxDimension)
        self.keyframeCacheDirectory = keyframeIndexCacheDirectory
    }

    deinit {
        // The context is owned here and deinit cannot hop to the actor; by
        // the time deinit runs nothing else can touch these fields.
        decoder?.close()
        if input != nil { avformat_close_input(&input) }
    }

    /// Tear the demuxer and decoder down now. Idempotent; later requests
    /// throw `.closed`.
    public func close() {
        closed = true
        decoder?.close()
        decoder = nil
        if input != nil { avformat_close_input(&input) }
        interruptGuard = nil
        cache = [:]
        cacheOrder = []
        covered = [:]
    }

    /// The thumbnail for the keyframe at-or-before `seconds`.
    ///
    /// Serial by actor design: a scrub sweep queues its requests, and each is
    /// one keyframe's decode. Callers that only want the newest position
    /// should cancel superseded tasks — cancellation is honoured between the
    /// seek and the decode.
    public func thumbnail(at seconds: Double) async throws -> CGImage {
        guard !closed else { throw Failure.closed }
        try openIfNeeded()
        guard let input, let decoder else { throw Failure.undecodable("no context") }

        let clamped = durationSeconds > 0 ? min(max(seconds, 0), durationSeconds) : max(seconds, 0)
        let targetPTS = Int64(clamped / av_q2d(timeBase))

        // Known keyframe for this position? The harvested cross-session map
        // answers exactly; without one, the learned coverage answers for
        // positions inside a proven [keyframe, seen] interval.
        let mappedKeyframe = keyframeMap.flatMap { Self.keyframe(atOrBefore: targetPTS, in: $0) }
            ?? coveredKeyframe(for: targetPTS)
        if let mappedKeyframe, let hit = cache[mappedKeyframe] {
            touch(mappedKeyframe)
            return hit
        }

        try Task.checkCancellation()

        // Everything below runs under a wall-clock bound. It matters on
        // exactly one shape: a cue-less Matroska over a slow transport turns
        // a timestamp seek into a linear scan (the 1.1.1 field case), and a
        // thumbnail is the last thing that may stall for a minute — better
        // no floating frame than a frozen scrub bar.
        let want = mappedKeyframe ?? targetPTS
        interruptGuard?.arm(budget: .seconds(3))
        defer {
            interruptGuard?.disarm()
            // An aborted read latches AVERROR_EXIT in the AVIOContext;
            // clearing it is what lets the NEXT request try again.
            if let pb = input.pointee.pb, pb.pointee.error < 0 { pb.pointee.error = 0 }
        }

        // Two passes, because containers land differently. An INDEXED seek
        // (Matroska Cues, MP4) puts the read position on the covering
        // keyframe — the first video packet is that keyframe and one decode
        // answers. MPEG-TS has no index: its binary search lands on a raw
        // byte position, usually a few packets PAST the covering keyframe
        // (the search runs on DTS, a keyframe's DTS trails its PTS), and
        // nothing decodes until the next GOP. So: try the exact seek, and if
        // the landing packet is not a keyframe, seek again a second early
        // and walk forward — the extra decodes cover at most that second
        // plus one GOP.
        var result = try decodePass(
            input: input, decoder: decoder, seekTo: want, want: want, requireKeyLanding: true
        )
        if result == nil {
            let bias = Int64(1.0 / av_q2d(timeBase))
            result = try decodePass(
                input: input, decoder: decoder,
                seekTo: max(0, want - bias), want: want, requireKeyLanding: false
            )
        }
        guard let (framePTS, image) = result else { throw Failure.noFrame }

        decodeCount += 1
        store(image, pts: framePTS)
        covered[framePTS] = max(covered[framePTS] ?? framePTS, targetPTS)
        return image
    }

    /// One seek-and-decode attempt. Returns the thumbnail-worthy frame — the
    /// latest KEYFRAME at-or-before `want` that the walk saw — or `nil` when
    /// `requireKeyLanding` is set and the landing packet wasn't a keyframe
    /// (the caller's cue to re-seek with a bias).
    private func decodePass(
        input: UnsafeMutablePointer<AVFormatContext>,
        decoder: ThumbnailDecoder,
        seekTo: Int64,
        want: Int64,
        requireKeyLanding: Bool
    ) throws -> (pts: Int64, image: CGImage)? {
        _ = av_seek_frame(input, videoStreamIndex, seekTo, AVSEEK_FLAG_BACKWARD)
        decoder.flush()

        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        guard let packet else { return nil }

        // The walk: skip to the first keyframe packet (a decoder fed mid-GOP
        // emits nothing until the next IDR anyway — feeding it garbage only
        // burns time), then decode forward. Every decoded KEYFRAME at-or-
        // before `want` replaces the candidate; the first frame at-or-past
        // `want` ends the walk — by then the candidate is exactly the
        // covering keyframe, which is also what makes the learned-coverage
        // proof sound. A keyframe past `want` (nothing earlier decodable)
        // still answers: a late picture beats no picture. Only candidates
        // are scaled into images; the frames merely walked over cost a
        // decode, never a render.
        var sawKeyPacket = false
        var candidate: (pts: Int64, image: CGImage)?
        var finished = false
        var scanned = 0
        let visit: ThumbnailDecoder.FrameVisitor = { pts, isKeyframe, makeImage in
            if (isKeyframe && pts <= want) || candidate == nil {
                if let image = try makeImage() { candidate = (pts, image) }
            }
            if pts >= want, candidate != nil { finished = true }
        }
        while !finished, scanned < 4096 {
            guard av_read_frame(input, packet) >= 0 else { break }
            defer { av_packet_unref(packet) }
            guard Int32(packet.pointee.stream_index) == videoStreamIndex else { continue }
            scanned += 1
            let isKeyPacket = packet.pointee.flags & AV_PKT_FLAG_KEY != 0
            if !sawKeyPacket {
                if !isKeyPacket {
                    if requireKeyLanding { return nil }
                    continue
                }
                sawKeyPacket = true
            }
            try decoder.decodeAll(packet: packet, maxDimension: maxDimension, visit: visit)
        }
        if !finished {
            // EOF (a request at the very tail): drain what the decoder holds.
            try decoder.decodeAll(packet: nil, maxDimension: maxDimension, visit: visit)
        }
        decoder.flush()
        return candidate
    }

    // MARK: - Setup

    private func openIfNeeded() throws {
        guard !opened else { return }
        opened = true

        var openOptions = SourceOpenTuning.makeOptions(httpHeaders: httpHeaders)
        defer { av_dict_free(&openOptions) }

        // The guard exists before the open (issue #39's rule) even though no
        // index-load seek runs here: thumbnail seeks on a cue-less source can
        // degenerate to the same linear scan, and `close()` mid-request must
        // be able to abort a blocking read rather than wait it out.
        let interruptGuard = ReadInterruptGuard()
        self.interruptGuard = interruptGuard
        var context = interruptGuard.makeContext()
        // Host bytes win over the coordinated HTTP reader — both would claim
        // `pb`, and only one of them is what the host asked for.
        if let inputFactory, let context {
            do { try interruptGuard.installCustomInput(on: context, factory: inputFactory) }
            catch { avformat_free_context(context); throw error }
        } else if coordinatedHTTP, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let context {
            do { try interruptGuard.installHTTPInput(on: context, url: url, headers: httpHeaders) }
            catch { avformat_free_context(context); throw error }
        }
        interruptGuard.arm(budget: SourceOpenTuning.probeBudget)
        defer { interruptGuard.disarm() }
        let sourceSpec = url.isFileURL ? url.path : url.absoluteString
        do {
            try FFmpegError.check(
                avformat_open_input(&context, sourceSpec, nil, &openOptions),
                "avformat_open_input(preview)"
            )
        } catch {
            throw interruptGuard.customInputFailure ?? interruptGuard.originFailure ?? error
        }
        guard let context else { throw Failure.undecodable("open failed") }
        input = context
        do {
            try FFmpegError.check(
                avformat_find_stream_info(context, nil), "avformat_find_stream_info(preview)"
            )
        } catch {
            // The analysis reads too, and a host or origin that dies here dies
            // exactly as it would have during the open — same order, same
            // answer: whoever supplied the bytes knows more than the errno
            // they were reduced to.
            throw interruptGuard.customInputFailure ?? interruptGuard.originFailure ?? error
        }

        let best = av_find_best_stream(context, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard best >= 0, let stream = context.pointee.streams[Int(best)] else {
            throw Failure.undecodable("no video stream")
        }
        videoStreamIndex = best
        timeBase = stream.pointee.time_base
        if context.pointee.duration > 0 {
            durationSeconds = Double(context.pointee.duration) / Double(AV_TIME_BASE)
        }
        decoder = try ThumbnailDecoder(
            codecpar: stream.pointee.codecpar, timeBase: timeBase
        )

        // A harvested keyframe map makes position → keyframe a lookup. Shared
        // by identity with the session that harvested it, so it only ever
        // matches the exact same bits.
        if let keyframeCacheDirectory {
            let cache = KeyframeIndexCache(directory: keyframeCacheDirectory)
            let identity = KeyframeIndexCache.identity(
                sourceURL: url,
                sizeBytes: context.pointee.pb.map { avio_size($0) } ?? -1,
                durationMicroseconds: context.pointee.duration
            )
            if let entry = cache.lookup(identity: identity),
               entry.timeBaseNum == timeBase.num, entry.timeBaseDen == timeBase.den,
               entry.keyframePTS.count >= 2 {
                keyframeMap = entry.keyframePTS.sorted()
            }
        }
    }

    /// The keyframe whose proven interval contains `pts`, from the learned
    /// coverage. `nil` means "not proven" — the caller seeks.
    private func coveredKeyframe(for pts: Int64) -> Int64? {
        covered.first { keyframe, upTo in pts >= keyframe && pts <= upTo }?.key
    }

    /// Largest keyframe ≤ `pts`, or the first one (a request before the first
    /// keyframe still shows the opening frame).
    static func keyframe(atOrBefore pts: Int64, in sorted: [Int64]) -> Int64? {
        guard let first = sorted.first else { return nil }
        guard pts >= first else { return first }
        var low = 0, high = sorted.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if sorted[mid] <= pts { low = mid } else { high = mid - 1 }
        }
        return sorted[low]
    }

    // MARK: - Cache

    private func store(_ image: CGImage, pts: Int64) {
        if cache[pts] == nil { cacheOrder.append(pts) }
        cache[pts] = image
        while cacheOrder.count > cacheLimit {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
            covered.removeValue(forKey: evicted)
        }
    }

    private func touch(_ pts: Int64) {
        if let index = cacheOrder.firstIndex(of: pts) {
            cacheOrder.remove(at: index)
            cacheOrder.append(pts)
        }
    }
}

/// The service's decode stage: libavcodec on the CPU, straight through
/// `sws_scale` into an RGB `CGImage` at thumbnail size. One type so the codec
/// context, the scaler and their lifetimes live together.
private final class ThumbnailDecoder {

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var scaler: UnsafeMutablePointer<SwsContext>?
    private var scalerKey: String = ""
    private let timeBase: AVRational

    init(codecpar: UnsafeMutablePointer<AVCodecParameters>?, timeBase: AVRational) throws {
        self.timeBase = timeBase
        guard let codecpar else {
            throw SeekPreviewService.Failure.undecodable("no codec parameters")
        }
        guard let decoder = avcodec_find_decoder(codecpar.pointee.codec_id) else {
            let name = avcodec_get_name(codecpar.pointee.codec_id).map { String(cString: $0) } ?? "?"
            throw SeekPreviewService.Failure.undecodable(name)
        }
        guard let context = avcodec_alloc_context3(decoder) else {
            throw SeekPreviewService.Failure.undecodable("context allocation")
        }
        codecContext = context
        try FFmpegError.check(
            avcodec_parameters_to_context(context, codecpar),
            "avcodec_parameters_to_context(preview)"
        )
        context.pointee.pkt_timebase = timeBase
        // Thumbnails have no realtime deadline, but they do queue behind one
        // another on the actor — two threads keep a 4K HEVC keyframe near
        // scrub cadence without lighting up the whole machine.
        context.pointee.thread_count = 2
        try FFmpegError.check(
            avcodec_open2(context, decoder, nil), "avcodec_open2(preview)"
        )
        guard let allocated = av_frame_alloc() else {
            throw SeekPreviewService.Failure.undecodable("frame allocation")
        }
        frame = allocated
    }

    deinit { close() }

    func close() {
        av_frame_free(&frame)
        if codecContext != nil { avcodec_free_context(&codecContext) }
        if let scaler { sws_freeContext(scaler) }
        scaler = nil
    }

    func flush() {
        if let codecContext { avcodec_flush_buffers(codecContext) }
    }

    /// Sees every frame one packet produced: its timestamp, whether it is a
    /// keyframe, and a render thunk. Rendering is the visitor's decision —
    /// the walk decodes whole GOPs but only ever scales its candidates.
    typealias FrameVisitor = (
        _ pts: Int64, _ isKeyframe: Bool, _ makeImage: () throws -> CGImage?
    ) throws -> Void

    /// Feed one packet (`nil` = EOF drain; the caller flushes afterwards, a
    /// drained decoder takes no more packets until reset) and visit every
    /// frame that comes out.
    func decodeAll(
        packet: UnsafeMutablePointer<AVPacket>?, maxDimension: Int, visit: FrameVisitor
    ) throws {
        guard let codecContext, let frame else { return }
        let sendResult = avcodec_send_packet(codecContext, packet)
        // EAGAIN means "take my frames first" — exactly what the loop does.
        if packet != nil, sendResult < 0, sendResult != swift_AVERROR(EAGAIN) {
            throw FFmpegError(code: sendResult, operation: "avcodec_send_packet(preview)")
        }
        while true {
            let result = avcodec_receive_frame(codecContext, frame)
            if result == swift_AVERROR(EAGAIN) || result == swift_AVERROR_EOF() { return }
            try FFmpegError.check(result, "avcodec_receive_frame(preview)")
            defer { av_frame_unref(frame) }
            let pts = frame.pointee.best_effort_timestamp != swift_AV_NOPTS_VALUE()
                ? frame.pointee.best_effort_timestamp
                : (frame.pointee.pts != swift_AV_NOPTS_VALUE() ? frame.pointee.pts : 0)
            // frame.h: CORRUPT=1<<0, KEY=1<<1 — the macro doesn't import.
            let isKeyframe = frame.pointee.flags & (1 << 1) != 0
            try visit(pts, isKeyframe) {
                try self.makeImage(from: frame, maxDimension: maxDimension)
            }
        }
    }

    /// `sws_scale` the frame to RGB at thumbnail size and wrap it as a
    /// `CGImage`. The scaler is cached across frames of one geometry (the
    /// overwhelmingly common case) and rebuilt when the source changes shape.
    private func makeImage(
        from frame: UnsafeMutablePointer<AVFrame>, maxDimension: Int
    ) throws -> CGImage? {
        let sourceWidth = Int(frame.pointee.width)
        let sourceHeight = Int(frame.pointee.height)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        // Display geometry honours the sample aspect ratio — anamorphic DVD
        // rips must not come out squeezed in the one UI element whose whole
        // job is looking like the picture.
        let sar = frame.pointee.sample_aspect_ratio
        let displayWidth = sar.num > 0 && sar.den > 0
            ? Double(sourceWidth) * Double(sar.num) / Double(sar.den)
            : Double(sourceWidth)
        let scale = min(1, Double(maxDimension) / max(displayWidth, Double(sourceHeight)))
        // Even dimensions keep every swscale fast path available.
        let outWidth = max(2, Int(displayWidth * scale) & ~1)
        let outHeight = max(2, Int(Double(sourceHeight) * scale) & ~1)

        let key = "\(frame.pointee.format)/\(sourceWidth)x\(sourceHeight)→\(outWidth)x\(outHeight)"
        if scaler == nil || scalerKey != key {
            if let scaler { sws_freeContext(scaler) }
            scaler = sws_getContext(
                Int32(sourceWidth), Int32(sourceHeight),
                AVPixelFormat(rawValue: frame.pointee.format),
                Int32(outWidth), Int32(outHeight),
                AV_PIX_FMT_RGB0,   // RGBX: opaque, no alpha math anywhere
                Int32(SWS_BILINEAR.rawValue), nil, nil, nil
            )
            scalerKey = key
        }
        guard let scaler else {
            throw SeekPreviewService.Failure.undecodable("sws_getContext")
        }

        let bytesPerRow = outWidth * 4
        var data = Data(count: bytesPerRow * outHeight)
        let scaled: Int32 = data.withUnsafeMutableBytes { buffer -> Int32 in
            var destination: [UnsafeMutablePointer<UInt8>?] = [
                buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), nil, nil, nil,
            ]
            var strides: [Int32] = [Int32(bytesPerRow), 0, 0, 0]
            return withUnsafePointer(to: frame.pointee.data) { planes in
                planes.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: 8) { source in
                    withUnsafePointer(to: frame.pointee.linesize) { lines in
                        lines.withMemoryRebound(to: Int32.self, capacity: 8) { stride in
                            sws_scale(
                                scaler, source, stride, 0, Int32(sourceHeight),
                                &destination, &strides
                            )
                        }
                    }
                }
            }
        }
        guard scaled > 0 else { return nil }

        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: outWidth,
            height: outHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
