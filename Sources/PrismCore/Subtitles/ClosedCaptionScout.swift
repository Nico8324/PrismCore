import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// Decides, before a single segment is written, which CEA-608 services this
/// source carries.
///
/// ### Why this has to happen up front
///
/// A caption service only becomes selectable by putting it in the master
/// playlist's `SUBTITLES` group, and the master is written before the copy loop
/// starts — its URIs, codecs and languages are all static. There is no way to
/// add a rendition to a manifest AVPlayer has already read. So the question
/// "does this file have captions, and on which channels" has to be answered
/// from packets, before the muxer exists.
///
/// ### The cost, stated honestly
///
/// Absence cannot be proven cheaply: nothing in a container declares that its
/// video carries no captions, so the only answer is to look. This reads at most
/// `maximumVideoPackets` video packets — around a second of pictures — and then
/// the caller rewinds. On a captioned source it usually stops far sooner, at
/// the first printed character. That is the whole added startup cost, paid once
/// per session, and it buys the copy loop the right to do nothing at all for a
/// source that has no captions: no reader is built, and the per-packet tap is
/// never installed.
///
/// The scan is skipped outright unless the stream is H.264 or HEVC **and** the
/// input is seekable — an unseekable live source cannot be rewound, and a
/// second of video lost off the head of a live stream is a worse trade than a
/// caption track nobody asked for.
enum ClosedCaptionScout {

    /// One second at 24 fps and a little more at 30, which is far enough in for
    /// a caption encoder's first `RCL`/`EOC` cycle on real broadcast content.
    static let maximumVideoPackets = 28
    /// Packets of any stream to walk past while hunting for that many video
    /// packets — a bound for a container whose interleaving is pathological.
    static let maximumPackets = 200

    struct Finding {
        /// Channel numbers (1…4) worth a rendition, ascending.
        let channels: [Int]
        /// How the video packets frame their NAL units, for the reader the
        /// copy loop will build.
        let framing: HEVCNALUnits.Framing
        let codec: HEVCNALUnits.Codec
    }

    /// The framing and codec of a video track, or `nil` for a codec that has no
    /// SEI to carry captions in.
    static func carriage(
        codecID: AVCodecID, nalUnitLengthSize: Int?
    ) -> (framing: HEVCNALUnits.Framing, codec: HEVCNALUnits.Codec)? {
        let codec: HEVCNALUnits.Codec
        switch codecID {
        case AV_CODEC_ID_H264: codec = .h264
        case AV_CODEC_ID_HEVC: codec = .hevc
        default: return nil
        }
        // No `avcC`/`hvcC` means no length prefixes, which means Annex-B start
        // codes — the shape the MPEG-TS demuxer produces, and the shape most
        // captioned recordings arrive in.
        if let lengthSize = nalUnitLengthSize, (1...4).contains(lengthSize) {
            return (.lengthPrefixed(lengthSize), codec)
        }
        return (.annexB, codec)
    }

    /// Consume packets from `input` looking for captions. **Leaves the read
    /// position where it stopped** — the caller must rewind.
    static func scan(
        input: UnsafeMutablePointer<AVFormatContext>,
        videoStreamIndex: Int32,
        framing: HEVCNALUnits.Framing,
        codec: HEVCNALUnits.Codec
    ) -> Finding? {
        guard let packet = av_packet_alloc() else { return nil }
        var packetRef: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&packetRef) }

        let timeBase = input.pointee.streams[Int(videoStreamIndex)]!.pointee.time_base
        let tick = av_q2d(timeBase)
        let reader = ClosedCaptionReader(framing: framing, codec: codec)
        // Presence per 608 field, which is what decides CC1 and CC3: a field
        // that is transmitted at all was put there by a caption encoder. CC2
        // and CC4 share their field with CC1/CC3 and are invisible until they
        // print, so they are declared on printed text only — the second
        // service is rare, and an empty row in the subtitle menu is worse than
        // a missing one (the same rule the rest of this directory follows).
        var fieldSeen = [false, false]
        var videoPackets = 0
        var packets = 0

        while videoPackets < maximumVideoPackets, packets < maximumPackets,
              av_read_frame(input, packet) >= 0 {
            defer { av_packet_unref(packet) }
            packets += 1
            guard packet.pointee.stream_index == videoStreamIndex,
                  let data = packet.pointee.data, packet.pointee.size > 0
            else { continue }
            videoPackets += 1

            let bytes = UnsafeBufferPointer(start: data, count: Int(packet.pointee.size))
            for triplet in A53CaptionData.triplets(in: bytes, framing: framing, codec: codec) {
                if let field = triplet.cea608Field { fieldSeen[field - 1] = true }
            }
            // Decode order does not matter to a presence question, and the
            // scan is too short to fill the reader's reorder window — so the
            // packets are fed with the PTS they carry and whatever text comes
            // out is enough to answer "does this service print".
            let seconds = packet.pointee.pts != swift_AV_NOPTS_VALUE()
                ? Double(packet.pointee.pts) * tick
                : Double(videoPackets)
            reader.ingest(bytes, presentationSeconds: seconds)
            _ = reader.flush(at: seconds)
            if reader.hasPrintedText(channel: 1) { break }
        }

        var channels: [Int] = []
        if fieldSeen[0] { channels.append(1) }
        if reader.hasPrintedText(channel: 2) { channels.append(2) }
        if fieldSeen[1] { channels.append(3) }
        if reader.hasPrintedText(channel: 4) { channels.append(4) }
        guard !channels.isEmpty else { return nil }
        return Finding(channels: channels.sorted(), framing: framing, codec: codec)
    }
}
