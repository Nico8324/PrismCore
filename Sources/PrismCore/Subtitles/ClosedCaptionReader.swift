import Foundation

/// Turns a session's video packets into CEA-608 caption cues.
///
/// Sits between `A53CaptionData` (carriage) and `CEA608FieldDecoder`
/// (meaning), and owns the one thing neither of them can see: **order**.
///
/// ### Decode order is not presentation order
///
/// `av_read_frame` hands packets out in *decode* order. On any stream with
/// B-frames that is not the order the frames are shown in — a typical
/// `IPBB` group arrives I, P, B, B while it is presented I, B, B, P. The
/// caption bytes inside each frame's SEI belong to the frame's **presentation**
/// instant, and 608 is a stateful terminal: replayed out of order, an erase
/// lands before the caption it was meant to clear, a roll-up scrolls before the
/// row it was meant to push up, and a pop-on flip reveals the buffer one
/// caption late. The damage is not a wrong timestamp on the right text — it is
/// the wrong text.
///
/// So packets are held in a small window sorted by PTS and released from its
/// low end, which puts them back in presentation order before a single byte
/// reaches a decoder. The window has to be at least as deep as the stream's
/// reorder depth; `maximumReorderDepth` is H.264's own ceiling (16 frames),
/// which no real encoder approaches and every real encoder is covered by.
final class ClosedCaptionReader {

    /// H.264 allows a decoded-picture buffer of 16, so 16 frames is the most
    /// any conforming stream can displace a picture by. Holding that many
    /// frames of captions costs well under a second of latency against a
    /// producer that runs seconds ahead of the player.
    static let maximumReorderDepth = 16

    /// A caption cue and the service it belongs to (1…4 = CC1…CC4).
    struct ChannelCue {
        let channel: Int
        let cue: SubtitleCue
    }

    private let framing: HEVCNALUnits.Framing
    private let codec: HEVCNALUnits.Codec
    /// Index 0 is 608 field 1 (CC1/CC2), index 1 is field 2 (CC3/CC4).
    private let fields = [CEA608FieldDecoder(), CEA608FieldDecoder()]
    /// Pending frames, ascending by presentation time. Small and almost always
    /// already sorted, which is why an insertion into an array beats a heap.
    private var window: [(seconds: Double, triplets: [A53CaptionData.Triplet])] = []

    init(framing: HEVCNALUnits.Framing, codec: HEVCNALUnits.Codec) {
        self.framing = framing
        self.codec = codec
    }

    /// Whether a service has printed anything — what the scout reads to decide
    /// which channels are worth a rendition.
    func hasPrintedText(channel: Int) -> Bool {
        guard let (field, index) = Self.route(channel: channel) else { return false }
        return fields[field].channels[index].hasPrintedText
    }

    /// One video packet, at its **presentation** time in source seconds.
    ///
    /// Cheap to decline: a packet with no SEI user data costs one NAL walk and
    /// no allocation, which is the price every frame of every source without
    /// captions would pay — and the reason this reader is only built at all
    /// once the scout has seen captions in the stream.
    func ingest(_ bytes: UnsafeBufferPointer<UInt8>, presentationSeconds: Double) {
        let triplets = A53CaptionData.triplets(in: bytes, framing: framing, codec: codec)
        guard !triplets.isEmpty else { return }
        insert((presentationSeconds, triplets))
        while window.count > Self.maximumReorderDepth {
            decode(window.removeFirst())
        }
    }

    private func insert(_ entry: (seconds: Double, triplets: [A53CaptionData.Triplet])) {
        var position = window.count
        while position > 0, window[position - 1].seconds > entry.seconds { position -= 1 }
        window.insert(entry, at: position)
    }

    private func decode(_ entry: (seconds: Double, triplets: [A53CaptionData.Triplet])) {
        for triplet in entry.triplets {
            // CEA-708 (cc_type 2 and 3) is deliberately dropped here. See
            // `ClosedCaptionReader` in the README: a DTVCC service decode needs
            // the window model — up to eight windows with their own anchors,
            // sizes, pen states and row locks — and a half-built one puts text
            // on screen in the wrong place while claiming to be a caption
            // track. Declining is honest; approximating is not. Nothing is
            // lost on the content this path exists for: a 708 encoder that
            // drops the 608 compatibility bytes is vanishingly rare, and when
            // one does, no rendition appears rather than a broken one.
            guard let field = triplet.cea608Field else { continue }
            fields[field - 1].ingest(triplet.data0, triplet.data1, at: entry.seconds)
        }
    }

    /// Every cue completed since the last call.
    func drainCues() -> [ChannelCue] {
        var cues: [ChannelCue] = []
        for (fieldIndex, field) in fields.enumerated() {
            for (channelIndex, channel) in field.channels.enumerated() {
                let number = fieldIndex * 2 + channelIndex + 1
                cues.append(contentsOf: channel.drainCues().map { ChannelCue(channel: number, cue: $0) })
            }
        }
        return cues
    }

    /// A segment boundary.
    ///
    /// Two things have to happen, in this order. First the reorder window is
    /// drained of every frame *presented* before the boundary: those frames
    /// have all been read by now (the boundary is a keyframe, and decode order
    /// cannot run more than the window behind), and leaving their captions
    /// queued would attribute up to sixteen frames of dialogue to the next
    /// segment — the rendition is cut on the video's boundaries and a cue only
    /// reaches the file it overlaps. Frames whose presentation time is *past*
    /// the boundary stay queued, so an open GOP's late arrivals still find
    /// their place.
    ///
    /// Then whatever is on screen becomes writable up to the boundary, and a
    /// fresh interval opens on the other side.
    func advance(to boundary: Double) -> [ChannelCue] {
        while let first = window.first, first.seconds < boundary {
            decode(window.removeFirst())
        }
        return drainCues() + splitPending(at: boundary)
    }

    private func splitPending(at boundary: Double) -> [ChannelCue] {
        var cues: [ChannelCue] = []
        for (fieldIndex, field) in fields.enumerated() {
            for (channelIndex, cue) in field.splitPending(at: boundary) {
                cues.append(ChannelCue(channel: fieldIndex * 2 + channelIndex + 1, cue: cue))
            }
        }
        return cues
    }

    /// End of stream: release the reorder window, then close what is open.
    /// An unflushed window is a lost caption; an unclosed interval is a caption
    /// that never ends.
    func flush(at endSeconds: Double) -> [ChannelCue] {
        while !window.isEmpty { decode(window.removeFirst()) }
        return drainCues() + splitPending(at: endSeconds)
    }

    /// A demand-driven jump. The window holds packets from before the seek,
    /// whose times are on the far side of it.
    func reanchor() {
        window = []
        for field in fields { field.reanchor() }
    }

    /// `(field index, channel index)` for CC1…CC4.
    static func route(channel: Int) -> (field: Int, index: Int)? {
        guard (1...4).contains(channel) else { return nil }
        return ((channel - 1) / 2, (channel - 1) % 2)
    }

    /// What the rendition is called in the player's subtitle menu. The channel
    /// number is the label viewers of captioned broadcast know ("CC1"), and it
    /// is the only thing that distinguishes two services of one stream — they
    /// share the video track's language metadata, when there is any.
    static func renditionName(channel: Int, language: String?) -> String {
        let endonym = language.flatMap { code -> String? in
            let locale = Locale(identifier: code)
            return locale.localizedString(forLanguageCode: code)?.capitalized(with: locale)
        }
        guard let endonym else { return "CC\(channel)" }
        return "\(endonym) (CC\(channel))"
    }
}
