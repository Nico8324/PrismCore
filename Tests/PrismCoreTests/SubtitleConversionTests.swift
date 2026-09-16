import Testing
import Foundation
@testable import PrismCore

/// The pure half of phase 6: payload → cue text, sidecar file → cues, cues →
/// segmented WebVTT. No demuxer, no FFmpeg — every rule here is pinned by a
/// value-in/value-out test, which is the whole reason the converter doesn't go
/// through `avcodec_decode_subtitle2` (see `TextSubtitleConverter`).
@Suite("Subtitle conversion")
struct SubtitleConversionTests {

    // MARK: - Packet payloads

    @Test("SubRip payload is the cue text, italics survive")
    func subripPayload() throws {
        let text = try #require(
            TextSubtitleConverter.cueText(from: Data("Ahoj <i>světe</i>".utf8), kind: .subrip)
        )
        #expect(text == "Ahoj <i>světe</i>")
    }

    @Test("A mangled tag ending in -- cannot smuggle --> into a cue")
    func mangledTagCannotTerminateCue() throws {
        // `<i-->`: the tag validator used to check only the name prefix ("i")
        // and emit the rest verbatim — inner `i--` plus the closing bracket is
        // `-->`, the one sequence that ends a WebVTT cue mid-payload. Found by
        // the fuzz harness mutating an SRT seed (hunt, first minute).
        let text = try #require(
            TextSubtitleConverter.cueText(from: Data("before <i--> after".utf8), kind: .subrip)
        )
        #expect(!text.contains("-->"))
        #expect(text.contains("after"), "the words around the mangled tag must survive")
    }

    @Test("Matroska ASS event: 7 fields before the text, italics kept, position lifted out")
    func matroskaASSEvent() throws {
        let payload = "0,Default,,0,0,0,,{\\pos(192,240)}{\\i1}Ahoj{\\i0}\\Nsvěte"
        let text = try #require(TextSubtitleConverter.cueText(from: Data(payload.utf8), kind: .ass))
        #expect(text == "<i>Ahoj</i>\nsvěte")
    }

    @Test("libavcodec ASS line: numeric second field means 8 fields before the text")
    func internalASSEvent() throws {
        let payload = "12,0,Default,,0,0,0,,Line from the internal form"
        let text = try #require(TextSubtitleConverter.cueText(from: Data(payload.utf8), kind: .ass))
        #expect(text == "Line from the internal form")
    }

    @Test("Full Dialogue: line has 9 fields before the text")
    func fullDialogueLine() throws {
        let payload = "Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,Hello, world"
        let text = try #require(TextSubtitleConverter.cueText(from: Data(payload.utf8), kind: .ass))
        // Commas INSIDE the text survive — only the structural ones are fields.
        #expect(text == "Hello, world")
    }

    @Test("An ASS event that is nothing but overrides produces no cue")
    func emptyASSEvent() {
        let payload = "0,Default,,0,0,0,,{\\pos(0,0)}"
        #expect(TextSubtitleConverter.cueText(from: Data(payload.utf8), kind: .ass) == nil)
    }

    @Test("mov_text: 16-bit length prefix, trailing style boxes ignored")
    func movTextPayload() throws {
        var payload = Data([0x00, 0x05])
        payload.append(Data("Hello".utf8))
        payload.append(Data([0x00, 0x00, 0x00, 0x0C]))   // a style box we drop
        let text = try #require(TextSubtitleConverter.cueText(from: payload, kind: .movText))
        #expect(text == "Hello")
    }

    // MARK: - WebVTT safety

    @Test("`-->` inside a payload is neutralized — it would end the cue")
    func arrowIsEscaped() throws {
        let text = try #require(
            TextSubtitleConverter.cueText(from: Data("wait --> what".utf8), kind: .subrip)
        )
        #expect(!text.contains("-->"))
        #expect(text == "wait --&gt; what")
    }

    @Test("Unknown markup is escaped, <font> is dropped, entities pass through")
    func markupHandling() throws {
        let payload = "<font color=\"#fff\">a &amp; b</font> 3<5 &nbsp; ok"
        let text = try #require(TextSubtitleConverter.cueText(from: Data(payload.utf8), kind: .subrip))
        #expect(text == "a &amp; b 3&lt;5 &nbsp; ok")
    }

    @Test("Blank lines inside a cue are collapsed — they would terminate it")
    func blankLinesCollapse() throws {
        let text = try #require(
            TextSubtitleConverter.cueText(from: Data("first\n\n\nsecond\n".utf8), kind: .subrip)
        )
        #expect(text == "first\nsecond")
    }

    @Test("Timestamps print HH:MM:SS.mmm and round to whole milliseconds")
    func timestampFormatting() {
        #expect(webVTTTimestamp(0) == "00:00:00.000")
        #expect(webVTTTimestamp(1.5) == "00:00:01.500")
        #expect(webVTTTimestamp(3661.007) == "01:01:01.007")
        // Rounding the components separately would print "00:00:60.000".
        #expect(webVTTTimestamp(59.9996) == "00:01:00.000")
    }

    // MARK: - Sidecar files

    @Test("SRT sidecar: BOM, CRLF and a missing sequence number all survive")
    func srtSidecar() {
        let file = "\u{FEFF}1\r\n00:00:01,000 --> 00:00:03,000\r\nfirst line\r\nsecond line\r\n\r\n"
            + "00:00:04,500 --> 00:00:05,000\r\nno index here\r\n"
        let cues = TextSubtitleConverter.cues(fromSRT: file)
        #expect(cues.count == 2)
        #expect(cues.first == SubtitleCue(start: 1, end: 3, text: "first line\nsecond line"))
        #expect(cues.last?.start == 4.5)
    }

    @Test("VTT sidecar: header, NOTE/STYLE blocks and identifiers dropped, cue settings kept")
    func vttSidecar() {
        let file = """
        WEBVTT

        NOTE this is a comment
        spanning two lines

        STYLE
        ::cue { color: yellow }

        intro
        00:01.000 --> 00:03.000 line:90% align:center
        short form timing

        00:00:04.000 --> 00:00:06.000
        second
        """
        let cues = TextSubtitleConverter.cues(fromWebVTT: file)
        #expect(cues.count == 2)
        #expect(cues.first?.start == 1)
        #expect(cues.first?.end == 3)
        #expect(cues.first?.text == "short form timing")
        #expect(cues.first?.settings == "line:90% align:center")
        #expect(cues.first?.placement == TextCuePlacement(alignment: 2, anchor: .init(x: 0.5, y: 0.9)))
        #expect(cues.last?.text == "second")
        #expect(cues.last?.settings == nil)
    }

    @Test("A cue whose end is not after its start is dropped")
    func degenerateCueDropped() {
        let cues = TextSubtitleConverter.cues(fromSRT: "1\n00:00:02,000 --> 00:00:02,000\nzero length\n")
        #expect(cues.isEmpty)
    }

    // MARK: - Segmented WebVTT

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreSubs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A cue spanning a boundary appears in both segments, clamped")
    func cueRepeatedAcrossBoundary() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try WebVTTRenditionWriter(directory: root.appendingPathComponent("subs0"))

        writer.add(SubtitleCue(start: 1, end: 3, text: "inside"))
        writer.add(SubtitleCue(start: 5.5, end: 6.5, text: "across"))
        try writer.flushSegment(start: 0, end: 6)
        try writer.flushSegment(start: 6, end: 8)
        try writer.finish()

        let first = try String(contentsOf: root.appendingPathComponent("subs0/seg00000.vtt"), encoding: .utf8)
        let second = try String(contentsOf: root.appendingPathComponent("subs0/seg00001.vtt"), encoding: .utf8)

        #expect(first.hasPrefix("WEBVTT\n"))
        #expect(first.contains("00:00:01.000 --> 00:00:03.000\ninside"))
        #expect(first.contains("00:00:05.500 --> 00:00:06.000\nacross"))
        #expect(second.contains("00:00:06.000 --> 00:00:06.500\nacross"))
        // The fully-contained cue is not repeated.
        #expect(!second.contains("inside"))
    }

    @Test("Every segment carries the timestamp map; the origin lands on the 90 kHz axis")
    func timestampMap() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try WebVTTRenditionWriter(directory: root.appendingPathComponent("subs0"))
        // A mid-stream capture: the fMP4 timeline starts at 10 s, so the map
        // has to say so — and the cue prints relative to that origin.
        writer.setTimelineOrigin(seconds: 10)
        writer.add(SubtitleCue(start: 11, end: 12, text: "one second in"))
        try writer.flushSegment(start: 10, end: 16)

        let segment = try String(contentsOf: root.appendingPathComponent("subs0/seg00000.vtt"), encoding: .utf8)
        #expect(segment.contains("X-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000"))
        #expect(segment.contains("00:00:01.000 --> 00:00:02.000\none second in"))
    }

    @Test("An empty range still writes a header-only segment, so the counts match")
    func emptySegmentStillWritten() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try WebVTTRenditionWriter(directory: root.appendingPathComponent("subs0"))
        try writer.flushSegment(start: 0, end: 6)
        try writer.finish()

        let segment = try String(contentsOf: root.appendingPathComponent("subs0/seg00000.vtt"), encoding: .utf8)
        // The blank line matters: without it the header block never ends and
        // the parser reads the map line itself as a cue with no timings.
        #expect(segment == "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n\n")

        let playlist = try String(contentsOf: root.appendingPathComponent("subs0/index.m3u8"), encoding: .utf8)
        #expect(playlist.contains("seg00000.vtt"))
        #expect(playlist.contains("#EXT-X-ENDLIST"))
        // A WebVTT rendition has no init segment to map.
        #expect(!playlist.contains("#EXT-X-MAP"))
    }

    @Test("Every segment shape parses as blocks: header ended, no cue left open")
    func everySegmentIsBlockWellFormed() throws {
        let bodies = [
            WebVTTRenditionWriter.render(cues: [], mpegtsOffset: 0),
            WebVTTRenditionWriter.render(
                cues: [SubtitleCue(start: 1, end: 2, text: "one")], mpegtsOffset: 900_000
            ),
            WebVTTRenditionWriter.render(
                cues: [
                    SubtitleCue(start: 1, end: 2, text: "one"),
                    SubtitleCue(start: 3, end: 4, text: "two\nlines"),
                ],
                mpegtsOffset: 0
            ),
        ]

        for body in bodies {
            // Blocks are what the parser sees: split on blank lines, the first
            // is the header and every other one must open with a timing line.
            // This is the check that would have caught the empty segment whose
            // map line became a cue.
            let blocks = body
                .components(separatedBy: "\n\n")
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            #expect(blocks.first?.hasPrefix("WEBVTT\n") == true)
            for block in blocks.dropFirst() {
                #expect(block.split(separator: "\n").first?.contains(" --> ") == true)
            }
        }
    }
}
