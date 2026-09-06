import Foundation
import CoreGraphics
import Libavcodec
import Libavutil

/// Decodes one bitmap subtitle stream (PGS / DVB / DVD) into timed
/// *compositions* — a `CGImage` to show, or a clear.
///
/// Bitmap subtitles are event streams, not cue streams: a packet either
/// presents a composition (one or more palettized rects) or presents nothing,
/// which is the "take it down" event. Whoever consumes this therefore owns a
/// pending-cue lifecycle; this type only turns packets into pixels and times.
///
/// The pixels come out composited onto black at the composition's own
/// bounding box: subtitle glyphs are light-on-transparent, and black is the
/// background that makes them legible to an OCR pass (and to a human looking
/// at a debug dump).
final class BitmapSubtitleDecoder {

    /// One decoded event on the stream's timeline (source seconds).
    struct Event {
        let startSeconds: Double
        /// Explicit end when the codec carries one (DVD subtitles usually do,
        /// PGS ends with a clear event instead), `nil` otherwise.
        let endSeconds: Double?
        /// The composition to show — `nil` is a clear.
        let image: CGImage?
    }

    enum Failure: Error {
        case decoderUnavailable(String)
        case allocationFailed(String)
    }

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private let codecName: String
    private let timeBase: AVRational

    init(codecpar: UnsafePointer<AVCodecParameters>, timeBase: AVRational) throws {
        let codecID = codecpar.pointee.codec_id
        codecName = avcodec_get_name(codecID).map { String(cString: $0) } ?? "unknown"
        self.timeBase = timeBase
        guard let decoder = avcodec_find_decoder(codecID) else {
            throw Failure.decoderUnavailable(codecName)
        }
        guard let context = avcodec_alloc_context3(decoder) else {
            throw Failure.allocationFailed("subtitle decoder context")
        }
        codecContext = context
        try FFmpegError.check(
            avcodec_parameters_to_context(context, codecpar),
            "avcodec_parameters_to_context(subtitle)"
        )
        // Without this, libavcodec cannot place the composition on a timeline
        // and `AVSubtitle.pts` stays NOPTS — every event would be dropped as
        // untimed. Found the hard way against a real remux.
        context.pointee.pkt_timebase = timeBase
        try FFmpegError.check(
            avcodec_open2(context, decoder, nil),
            "avcodec_open2(subtitle decoder)"
        )
    }

    deinit {
        if codecContext != nil {
            avcodec_free_context(&codecContext)
        }
    }

    /// A seek: PGS palette / object state is epoch-scoped, and pre-seek state
    /// composited into post-seek events is wrong twice over. Until the next
    /// epoch start the decoder may produce nothing — that is the honest
    /// outcome of joining mid-epoch.
    func flush() {
        guard let codecContext else { return }
        avcodec_flush_buffers(codecContext)
    }

    /// Decode one packet. Most packets complete no composition (PGS spreads
    /// one over several), so an empty array is the common return.
    func decode(_ packet: UnsafeMutablePointer<AVPacket>) -> [Event] {
        guard let codecContext else { return [] }
        var subtitle = AVSubtitle()
        var gotSubtitle: Int32 = 0
        let result = avcodec_decode_subtitle2(codecContext, &subtitle, &gotSubtitle, packet)
        guard result >= 0, gotSubtitle != 0 else { return [] }
        defer { avsubtitle_free(&subtitle) }

        // `pts` is on AV_TIME_BASE; display times are milliseconds after it.
        // When the codec couldn't place it, the packet's own timestamp on the
        // stream time base is the honest substitute.
        let base: Double
        if subtitle.pts != swift_AV_NOPTS_VALUE() {
            base = Double(subtitle.pts) / Double(AV_TIME_BASE)
        } else if packet.pointee.pts != swift_AV_NOPTS_VALUE() {
            base = Double(packet.pointee.pts) * av_q2d(timeBase)
        } else {
            return []
        }
        let start = base + Double(subtitle.start_display_time) / 1000
        let end = Self.explicitEndMilliseconds(
            start: subtitle.start_display_time, end: subtitle.end_display_time
        ).map { base + Double($0) / 1000 }

        guard subtitle.num_rects > 0 else {
            return [Event(startSeconds: start, endSeconds: nil, image: nil)]
        }
        guard let image = Self.compose(subtitle) else { return [] }
        return [Event(startSeconds: start, endSeconds: end, image: image)]
    }

    /// The codec's end display time, or `nil` when it is only saying "until told otherwise".
    ///
    /// FFmpeg's PGS decoder reports every composition with `end_display_time` of
    /// `UINT32_MAX`: not an end, its marker for "the clear will say". Taken at face value
    /// that is a cue 49 days long, closed on the spot, which the writer then clamps to every
    /// segment boundary and repeats into every later segment — and the clear, when it comes,
    /// finds nothing pending to close. Observed on a Vision Pro as captions piling up on top
    /// of one another (2026-09-06). DVD subtitles carry a real end; those are kept.
    static func explicitEndMilliseconds(start: UInt32, end: UInt32) -> UInt32? {
        guard end != UInt32.max, end > start else { return nil }
        return end
    }

    // MARK: - Pixels

    /// All bitmap rects of one composition, blended onto black inside their
    /// common bounding box (relative rect positions carry line breaks).
    private static func compose(_ subtitle: AVSubtitle) -> CGImage? {
        var rects: [UnsafeMutablePointer<AVSubtitleRect>] = []
        for index in 0..<Int(subtitle.num_rects) {
            guard let rect = subtitle.rects[index],
                  rect.pointee.type == SUBTITLE_BITMAP,
                  rect.pointee.w > 0, rect.pointee.h > 0,
                  rect.pointee.data.0 != nil, rect.pointee.data.1 != nil
            else { continue }
            rects.append(rect)
        }
        guard !rects.isEmpty else { return nil }

        let minX = rects.map { Int($0.pointee.x) }.min()!
        let minY = rects.map { Int($0.pointee.y) }.min()!
        let maxX = rects.map { Int($0.pointee.x) + Int($0.pointee.w) }.max()!
        let maxY = rects.map { Int($0.pointee.y) + Int($0.pointee.h) }.max()!
        let width = maxX - minX
        let height = maxY - minY
        guard width > 0, height > 0, width <= 4096, height <= 4096 else { return nil }

        // Opaque black canvas, BGRA.
        var canvas = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 3, to: canvas.count, by: 4) { canvas[index] = 255 }

        for rect in rects {
            let pixels = rect.pointee.data.0!
            let palette = rect.pointee.data.1!.withMemoryRebound(
                to: UInt32.self, capacity: Int(rect.pointee.nb_colors)
            ) { UnsafeBufferPointer(start: $0, count: Int(rect.pointee.nb_colors)) }
            let stride = Int(rect.pointee.linesize.0)
            let offsetX = Int(rect.pointee.x) - minX
            let offsetY = Int(rect.pointee.y) - minY

            for row in 0..<Int(rect.pointee.h) {
                for column in 0..<Int(rect.pointee.w) {
                    let colorIndex = Int(pixels[row * stride + column])
                    guard colorIndex < palette.count else { continue }
                    // Palette entries are ARGB in native byte order.
                    let argb = palette[colorIndex]
                    let alpha = UInt32((argb >> 24) & 0xFF)
                    guard alpha > 0 else { continue }
                    let red = (argb >> 16) & 0xFF
                    let green = (argb >> 8) & 0xFF
                    let blue = argb & 0xFF
                    let target = ((offsetY + row) * width + offsetX + column) * 4
                    // Source-over onto black: out = src × alpha.
                    canvas[target] = UInt8(blue * alpha / 255)
                    canvas[target + 1] = UInt8(green * alpha / 255)
                    canvas[target + 2] = UInt8(red * alpha / 255)
                }
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &canvas,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        return context.makeImage()
    }
}
