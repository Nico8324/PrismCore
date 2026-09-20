import Testing
import Foundation
@testable import PrismCore

/// The top-level element walk that produces `headerBytes` /
/// `firstClusterOffset` / `indexLocation`.
///
/// Every case here is about the same rule from the design note: **the export
/// never guesses.** Most of these assertions are therefore negative — they
/// prove that a walk which could not determine something says `unknown`
/// rather than the plausible answer. A consumer on the other side of a network
/// cannot tell the two apart, which is exactly why this side must.
@Suite("Container layout scanner")
struct ContainerLayoutScannerTests {

    // MARK: - Byte builders

    /// An EBML element ID, as it is written down (marker bits included).
    private func id(_ value: UInt32) -> [UInt8] {
        var bytes: [UInt8] = []
        var shift = 24
        var started = false
        while shift >= 0 {
            let byte = UInt8((value >> UInt32(shift)) & 0xFF)
            if byte != 0 || started { bytes.append(byte); started = true }
            shift -= 8
        }
        return bytes.isEmpty ? [0] : bytes
    }

    /// A length, always in the 8-byte form. Real muxers use the shortest one
    /// that fits; the widest is the one whose marker arithmetic is easiest to
    /// get wrong, so it is the one worth exercising.
    private func size(_ value: Int) -> [UInt8] {
        var bytes: [UInt8] = [0x01]
        for shift in stride(from: 48, through: 0, by: -8) {
            bytes.append(UInt8((value >> shift) & 0xFF))
        }
        return bytes
    }

    private func element(_ elementID: UInt32, _ payload: [UInt8]) -> [UInt8] {
        id(elementID) + size(payload.count) + payload
    }

    private func reader(_ bytes: [UInt8]) -> ContainerLayoutScanner.Reader {
        let data = Data(bytes)
        return { offset, count in
            guard offset >= 0, count > 0,
                  let start = Int(exactly: offset), start + count <= data.count
            else { return nil }
            return Data(data[start..<(start + count)])
        }
    }

    private let ebmlHeader: UInt32 = 0x1A45_DFA3
    private let segment: UInt32 = 0x1853_8067
    private let seekHead: UInt32 = 0x114D_9B74
    private let seek: UInt32 = 0x4DBB
    private let seekID: UInt32 = 0x53AB
    private let seekPosition: UInt32 = 0x53AC
    private let tracks: UInt32 = 0x1654_AE6B
    private let cues: UInt32 = 0x1C53_BB6B
    private let cluster: UInt32 = 0x1F43_B675

    /// A Matroska whose Segment children are exactly `children`, plus the
    /// offset its Segment's data starts at (what `SeekPosition` is relative
    /// to — the one Matroska offset that is easy to be a header's length out
    /// on).
    private func matroska(children: [UInt8]) -> (bytes: [UInt8], segmentDataStart: Int) {
        let header = element(ebmlHeader, [0xDE, 0xAD, 0xBE, 0xEF])
        let framing = id(segment) + size(children.count)
        return (header + framing + children, header.count + framing.count)
    }

    // MARK: - Matroska

    @Test("Tail Cues announced by a SeekHead: both scalars land on the first Cluster")
    func matroskaTailCues() throws {
        // Laid out the way mkvmerge writes one: SeekHead, Tracks, media, Cues.
        // Built twice because `SeekPosition` has to point at the Cues, whose
        // offset is only known once everything before it has been sized — the
        // first pass measures, the second writes the real pointer.
        func build(cuesRelativePosition: Int) -> (bytes: [UInt8], segmentDataStart: Int, clusterOffset: Int, cuesOffset: Int) {
            let seekEntry = element(seek,
                element(seekID, id(cues)) + element(seekPosition, [
                    UInt8((cuesRelativePosition >> 24) & 0xFF),
                    UInt8((cuesRelativePosition >> 16) & 0xFF),
                    UInt8((cuesRelativePosition >> 8) & 0xFF),
                    UInt8(cuesRelativePosition & 0xFF),
                ])
            )
            let head = element(seekHead, seekEntry)
            let trackList = element(tracks, [UInt8](repeating: 0x42, count: 64))
            let media = element(cluster, [UInt8](repeating: 0x11, count: 256))
            let index = element(cues, [UInt8](repeating: 0x33, count: 32))
            let children = head + trackList + media + index
            let built = matroska(children: children)
            return (
                built.bytes, built.segmentDataStart,
                built.segmentDataStart + head.count + trackList.count,
                built.segmentDataStart + head.count + trackList.count + media.count
            )
        }
        let measured = build(cuesRelativePosition: 0)
        let file = build(cuesRelativePosition: measured.cuesOffset - measured.segmentDataStart)

        let layout = ContainerLayoutScanner.scan(
            formatName: "matroska,webm", byteSize: Int64(file.bytes.count), read: reader(file.bytes)
        )
        #expect(layout.firstMediaOffset == Int64(file.clusterOffset))
        #expect(layout.headerBytes == file.clusterOffset)
        #expect(layout.indexLocation == .tail)
    }

    @Test("Cues written before the first Cluster read as an index at the head")
    func matroskaHeadCues() throws {
        let index = element(cues, [UInt8](repeating: 0x33, count: 32))
        let media = element(cluster, [UInt8](repeating: 0x11, count: 128))
        let file = matroska(children: index + media)
        let layout = ContainerLayoutScanner.scan(
            formatName: "matroska,webm", byteSize: Int64(file.bytes.count), read: reader(file.bytes)
        )
        #expect(layout.indexLocation == .head)
        #expect(layout.firstMediaOffset == Int64(file.segmentDataStart + index.count))
    }

    @Test("No Cues and no SeekHead is `unknown`, never `none`")
    func matroskaSilenceIsNotEvidence() throws {
        // The whole point of the `none` case's "positive evidence" rule. This
        // walk reads the head; a file's Cues live at the tail; concluding
        // `none` from not having looked would send a consumer straight past a
        // real index and cost it a keyframe-basis plan, silently.
        let file = matroska(
            children: element(tracks, [UInt8](repeating: 0x42, count: 32))
                + element(cluster, [UInt8](repeating: 0x11, count: 64))
        )
        let layout = ContainerLayoutScanner.scan(
            formatName: "matroska,webm", byteSize: Int64(file.bytes.count), read: reader(file.bytes)
        )
        #expect(layout.indexLocation == .unknown)
        // The layout scalars are still honest and still useful — the two
        // questions are independent.
        #expect(layout.firstMediaOffset != nil)
    }

    @Test("A Segment of unknown length describes nothing")
    func matroskaStreamedSegment() throws {
        // 0x01FFFFFFFFFFFFFF: the all-ones 8-byte length a muxer writes while
        // it is still writing the file. There is no settled layout to report.
        let header = element(ebmlHeader, [0xDE, 0xAD])
        let bytes = header + id(segment) + [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
            + element(cluster, [UInt8](repeating: 0x11, count: 32))
        let layout = ContainerLayoutScanner.scan(
            formatName: "matroska,webm", byteSize: Int64(bytes.count), read: reader(bytes)
        )
        #expect(layout == .unknown)
    }

    @Test("Bytes that are not a Matroska at all describe nothing")
    func matroskaGarbage() throws {
        let bytes = [UInt8](repeating: 0x5A, count: 512)
        let layout = ContainerLayoutScanner.scan(
            formatName: "matroska,webm", byteSize: Int64(bytes.count), read: reader(bytes)
        )
        #expect(layout == .unknown)
    }

    @Test("A truncated file stops the walk instead of inventing an offset")
    func matroskaTruncated() throws {
        var file = matroska(
            children: element(tracks, [UInt8](repeating: 0x42, count: 64))
                + element(cluster, [UInt8](repeating: 0x11, count: 256))
        ).bytes
        file.removeLast(300)
        let layout = ContainerLayoutScanner.scan(
            formatName: "matroska,webm", byteSize: Int64(file.count), read: reader(file)
        )
        #expect(layout.firstMediaOffset == nil)
        #expect(layout.indexLocation == .unknown)
    }

    // MARK: - ISO-BMFF

    private func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        let total = payload.count + 8
        return [
            UInt8((total >> 24) & 0xFF), UInt8((total >> 16) & 0xFF),
            UInt8((total >> 8) & 0xFF), UInt8(total & 0xFF),
        ] + Array(type.utf8) + payload
    }

    @Test("A faststart MP4 reports its index at the head and its header through moov")
    func mp4Faststart() throws {
        let ftyp = box("ftyp", [UInt8](repeating: 0x01, count: 16))
        let moov = box("moov", [UInt8](repeating: 0x02, count: 128))
        let free = box("free", [UInt8](repeating: 0x00, count: 8))
        let bytes = ftyp + moov + free + box("mdat", [UInt8](repeating: 0x03, count: 512))
        let layout = ContainerLayoutScanner.scan(
            formatName: "mov,mp4,m4a,3gp,3g2,mj2", byteSize: Int64(bytes.count), read: reader(bytes)
        )
        #expect(layout.indexLocation == .head)
        #expect(layout.firstMediaOffset == Int64(ftyp.count + moov.count + free.count))
        // Through the `free` box, not merely through `moov`: a consumer sizing
        // its first read wants the whole metadata prefix, and the box it
        // cannot name is still part of it.
        #expect(layout.headerBytes == ftyp.count + moov.count + free.count)
    }

    @Test("A non-faststart MP4 reports a tail index and no header length")
    func mp4TailMoov() throws {
        let ftyp = box("ftyp", [UInt8](repeating: 0x01, count: 16))
        let bytes = ftyp + box("mdat", [UInt8](repeating: 0x03, count: 512))
            + box("moov", [UInt8](repeating: 0x02, count: 128))
        let layout = ContainerLayoutScanner.scan(
            formatName: "mov,mp4,m4a,3gp,3g2,mj2", byteSize: Int64(bytes.count), read: reader(bytes)
        )
        #expect(layout.indexLocation == .tail)
        #expect(layout.firstMediaOffset == Int64(ftyp.count))
        // The bytes before `mdat` are not a metadata region worth reading —
        // the metadata is at the other end — so there is no header length to
        // report and reporting `ftyp.count` would size a first read that
        // learns nothing.
        #expect(layout.headerBytes == nil)
    }

    @Test("A size-0 mdat (to end of file) is still located")
    func mp4OpenEndedMdat() throws {
        let ftyp = box("ftyp", [UInt8](repeating: 0x01, count: 16))
        let moov = box("moov", [UInt8](repeating: 0x02, count: 64))
        let mdatHeader: [UInt8] = [0, 0, 0, 0] + Array("mdat".utf8)
        let bytes = ftyp + moov + mdatHeader + [UInt8](repeating: 0x03, count: 256)
        let layout = ContainerLayoutScanner.scan(
            formatName: "mov,mp4,m4a,3gp,3g2,mj2", byteSize: Int64(bytes.count), read: reader(bytes)
        )
        #expect(layout.firstMediaOffset == Int64(ftyp.count + moov.count))
        #expect(layout.indexLocation == .head)
    }

    @Test("A format this walk does not know describes nothing")
    func unknownFormat() throws {
        let layout = ContainerLayoutScanner.scan(
            formatName: "mpegts", byteSize: 4096, read: reader([UInt8](repeating: 0x47, count: 4096))
        )
        #expect(layout == .unknown)
    }
}
