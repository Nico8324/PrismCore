import Foundation

/// A bounded walk of a container's **top-level elements**, to find where its
/// metadata ends, where its media begins, and — when the container says so
/// without being read to the end — where its index lives.
///
/// Why a hand walk rather than libavformat. There is no public API for any of
/// this: `AVFormatContext` exposes streams, not the byte layout that produced
/// them, and the two quantities a remote consumer needs (`headerBytes`,
/// `firstClusterOffset`) are defined in the container's coordinates, which
/// only the container's own framing gives. The alternatives were both
/// dishonest — `avio_tell` after the open is the *probe buffer's* position,
/// not the header's length, and the first packet's `pos` is a demuxer-internal
/// convention that differs per format. This walk reads framing headers only:
/// element IDs and their declared lengths. It never parses payloads, so there
/// is no bitstream to get wrong.
///
/// The reader is injected so the whole thing is testable from bytes, without
/// FFmpeg and without a file — which is also what lets the Matroska and MP4
/// paths be fuzzed like every other hand-written parser in this repository.
enum ContainerLayoutScanner {

    /// What a walk found. Everything optional, nothing inferred: an element
    /// the walk did not reach leaves its field `nil`, and a question the
    /// framing did not answer leaves `indexLocation` at `.unknown`.
    struct Layout: Equatable {
        var headerBytes: Int?
        var firstMediaOffset: Int64?
        var indexLocation: IndexLocation = .unknown

        static let unknown = Layout()
    }

    /// How far into the source a walk may reach before giving up.
    ///
    /// Generous against a real header (a Matroska with dozens of tracks and
    /// cover art runs to a few hundred kilobytes) and short enough that a file
    /// whose framing is nonsense cannot walk the caller to the end of a 24 GB
    /// remux one bogus length at a time. Past it: `unknown`, which is the
    /// honest answer and costs a consumer nothing but the read it makes today.
    static let scanCeiling: Int64 = 16 << 20

    /// A hard bound on elements visited, for framing that is *valid* but
    /// pathological — thousands of `Void` elements, a SeekHead with a
    /// thousand entries. The ceiling above bounds bytes; this bounds work.
    static let maxElements = 4096

    /// Reads `count` bytes at `offset`, or returns nil when it cannot. A short
    /// read is a nil, not a truncation: every caller below needs its whole
    /// field, and a half-read length is how a walk invents an offset.
    typealias Reader = (_ offset: Int64, _ count: Int) -> Data?

    /// Walk `formatName`'s top-level elements. Formats this does not know
    /// return `.unknown` — including every format whose layout is not a
    /// metadata prefix followed by media, which is most of the streaming ones.
    ///
    /// `formatName` is libavformat's own spelling (`matroska,webm`,
    /// `mov,mp4,m4a,3gp,3g2,mj2`), matched by substring because that list is
    /// one string per demuxer and is not stable in its ordering.
    static func scan(formatName: String, byteSize: Int64?, read: Reader) -> Layout {
        if formatName.contains("matroska") || formatName.contains("webm") {
            return scanMatroska(byteSize: byteSize, read: read)
        }
        if formatName.contains("mp4") || formatName.contains("mov") {
            return scanISOBMFF(byteSize: byteSize, read: read)
        }
        return .unknown
    }

    // MARK: - Matroska / WebM

    private static let ebmlHeaderID: UInt32 = 0x1A45_DFA3
    private static let segmentID: UInt32 = 0x1853_8067
    private static let seekHeadID: UInt32 = 0x114D_9B74
    private static let cuesID: UInt32 = 0x1C53_BB6B
    private static let clusterID: UInt32 = 0x1F43_B675
    private static let seekEntryID: UInt32 = 0x4DBB
    private static let seekIDID: UInt32 = 0x53AB
    private static let seekPositionID: UInt32 = 0x53AC

    static func scanMatroska(byteSize: Int64?, read: Reader) -> Layout {
        var layout = Layout()
        let limit = min(byteSize ?? scanCeiling, scanCeiling)

        // The EBML header, then the Segment. Anything else at byte 0 is not a
        // Matroska whose layout this walk understands.
        guard let header = element(at: 0, limit: limit, read: read),
              header.id == ebmlHeaderID,
              let headerEnd = header.end,
              let segment = element(at: headerEnd, limit: limit, read: read),
              segment.id == segmentID
        else { return .unknown }

        // A Segment of unknown length is a live stream being written. Its
        // children can still be walked, but the file has no settled layout to
        // describe, and describing one would be the guess this refuses.
        guard let segmentLength = segment.length else { return .unknown }
        let segmentDataStart = segment.dataStart
        let segmentEnd = min(segmentDataStart + segmentLength, limit)

        var cuesOffset: Int64?
        var cursor = segmentDataStart
        var visited = 0
        while cursor < segmentEnd, visited < maxElements {
            visited += 1
            guard let child = element(at: cursor, limit: segmentEnd, read: read) else { break }
            switch child.id {
            case clusterID:
                // Media begins here, so the metadata prefix ends here. Both
                // scalars fall out of the same offset, which is exactly what
                // the wire contract defines them as for this container.
                layout.firstMediaOffset = child.start
                layout.headerBytes = Int(exactly: child.start)
                if let cuesOffset {
                    layout.indexLocation = cuesOffset < child.start ? .head : .tail
                }
                return layout
            case cuesID:
                cuesOffset = child.start
            case seekHeadID:
                // The SeekHead is how a tail index announces itself before
                // anything has read the tail. Its absence proves nothing, so a
                // walk that finds no Cues entry here leaves `unknown` standing
                // rather than concluding `none`: plenty of muxers write Cues
                // and never index them in a SeekHead, and `none` would send a
                // consumer past a real index.
                if cuesOffset == nil,
                   let found = cuesOffsetInSeekHead(
                       child, segmentDataStart: segmentDataStart, read: read
                   ) {
                    cuesOffset = found
                }
            default:
                break
            }
            guard let next = child.end, next > cursor else { break }
            cursor = next
        }
        return layout
    }

    /// The Cues position a SeekHead points at, in absolute coordinates.
    /// `SeekPosition` is relative to the Segment's *data* start, which is the
    /// one offset in Matroska that is easy to be off by a header's length on.
    private static func cuesOffsetInSeekHead(
        _ seekHead: Element, segmentDataStart: Int64, read: Reader
    ) -> Int64? {
        guard let seekHeadEnd = seekHead.end else { return nil }
        var cursor = seekHead.dataStart
        var visited = 0
        while cursor < seekHeadEnd, visited < maxElements {
            visited += 1
            guard let entry = element(at: cursor, limit: seekHeadEnd, read: read),
                  let entryEnd = entry.end else { return nil }
            if entry.id == seekEntryID {
                var isCues = false
                var position: Int64?
                var inner = entry.dataStart
                while inner < entryEnd, visited < maxElements {
                    visited += 1
                    guard let field = element(at: inner, limit: entryEnd, read: read),
                          let fieldEnd = field.end, let fieldLength = field.length
                    else { return nil }
                    switch field.id {
                    case seekIDID:
                        // The payload is the target's element ID, stored with
                        // its own marker bits — the same encoding `element`
                        // reads, so compare against the same constant.
                        if let bytes = read(field.dataStart, Int(min(fieldLength, 8))),
                           bytes.count == Int(fieldLength) {
                            isCues = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } == cuesID
                        }
                    case seekPositionID:
                        if let bytes = read(field.dataStart, Int(min(fieldLength, 8))),
                           bytes.count == Int(fieldLength) {
                            position = bytes.reduce(Int64(0)) { ($0 << 8) | Int64($1) }
                        }
                    default:
                        break
                    }
                    inner = fieldEnd
                }
                if isCues, let position { return segmentDataStart + position }
            }
            cursor = entryEnd
        }
        return nil
    }

    /// One EBML element's framing.
    private struct Element {
        let id: UInt32
        let start: Int64
        let dataStart: Int64
        /// `nil` for an element of unknown (streamed) length.
        let length: Int64?
        var end: Int64? { length.map { dataStart + $0 } }
    }

    /// Read an element's ID and declared length at `offset`.
    ///
    /// Both are EBML variable-length integers whose first byte's leading zeros
    /// give the total width. The ID keeps its marker bits (that is how IDs are
    /// written down); the length has them stripped, and an all-ones value
    /// means "unknown", which is a live stream and not a layout.
    private static func element(at offset: Int64, limit: Int64, read: Reader) -> Element? {
        guard offset >= 0, offset < limit,
              let first = read(offset, 1)?.first else { return nil }
        let idWidth = leadingMarkerWidth(first)
        guard idWidth >= 1, idWidth <= 4,
              let idBytes = read(offset, idWidth), idBytes.count == idWidth
        else { return nil }
        let id = idBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }

        let lengthOffset = offset + Int64(idWidth)
        guard let lengthFirst = read(lengthOffset, 1)?.first else { return nil }
        let lengthWidth = leadingMarkerWidth(lengthFirst)
        guard lengthWidth >= 1, lengthWidth <= 8,
              let lengthBytes = read(lengthOffset, lengthWidth), lengthBytes.count == lengthWidth
        else { return nil }
        var value: UInt64 = UInt64(lengthFirst & (0xFF >> UInt8(lengthWidth)))
        for byte in lengthBytes.dropFirst() { value = (value << 8) | UInt64(byte) }
        // All value bits set = unknown length.
        let unknownLength = (UInt64(1) << UInt64(7 * lengthWidth)) - 1
        let length: Int64? = value == unknownLength ? nil : Int64(exactly: value)
        if value != unknownLength, length == nil { return nil }

        if let length, length < 0 { return nil }
        // A declared length that runs past our own bound is reported as it
        // stands: the bound is this walk's, not the file's, and the caller's
        // loop is what stops. Silently clamping it would move an element's end
        // and, with it, the next element's start.
        return Element(
            id: id, start: offset,
            dataStart: lengthOffset + Int64(lengthWidth), length: length
        )
    }

    /// How many bytes an EBML variable-length integer occupies, from the
    /// position of its highest set bit. Zero means a corrupt marker byte.
    private static func leadingMarkerWidth(_ first: UInt8) -> Int {
        guard first != 0 else { return 0 }
        return first.leadingZeroBitCount + 1
    }

    // MARK: - ISO-BMFF (MP4 / MOV)

    static func scanISOBMFF(byteSize: Int64?, read: Reader) -> Layout {
        var layout = Layout()
        let limit = min(byteSize ?? scanCeiling, scanCeiling)

        var cursor: Int64 = 0
        var visited = 0
        var moovEnd: Int64?
        while cursor < limit, visited < maxElements {
            visited += 1
            guard let head = read(cursor, 8), head.count == 8 else { break }
            let bytes = [UInt8](head)
            var size = Int64(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
                             | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
            let type = String(decoding: bytes[4..<8], as: UTF8.self)
            var headerLength: Int64 = 8
            if size == 1 {
                guard let extended = read(cursor + 8, 8), extended.count == 8 else { break }
                size = extended.reduce(Int64(0)) { ($0 << 8) | Int64($1) }
                headerLength = 16
            } else if size == 0 {
                // "To the end of the file" — the last box. Only `mdat` is
                // written this way in practice, and it is the one we want.
                size = (byteSize ?? limit) - cursor
            }
            guard size >= headerLength else { break }

            switch type {
            case "moov":
                moovEnd = cursor + size
            case "mdat":
                layout.firstMediaOffset = cursor
                // The index for this container is `stss`/`stts` inside `moov`.
                // Its position relative to `mdat` is the whole faststart
                // question, and both answers here are positive evidence: the
                // box was seen, at a known offset, on one side or the other.
                if let moovEnd {
                    layout.indexLocation = .head
                    // The metadata prefix ends at the later of the two — a
                    // `free` box or a `uuid` may sit between `moov` and
                    // `mdat`, and a consumer sizing its first read wants the
                    // whole prefix, not just the part it can name.
                    layout.headerBytes = Int(exactly: max(moovEnd, cursor))
                } else {
                    layout.indexLocation = .tail
                    // `moov` follows the media, so the bytes before `mdat` are
                    // not the metadata region a consumer would want to read —
                    // reporting them as `headerBytes` would size a first read
                    // that learns nothing. Left absent on purpose.
                }
                return layout
            default:
                break
            }
            guard cursor + size > cursor else { break }
            cursor += size
        }
        return layout
    }
}
