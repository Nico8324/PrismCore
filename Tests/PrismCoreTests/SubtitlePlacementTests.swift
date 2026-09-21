import Testing
import Foundation
@testable import PrismCore

/// Styling and placement retention: what an ASS override block or a WebVTT
/// cue-settings string turns into, on the served rendition and on the cue a
/// host draws itself. Pure value tests — no demuxer, no FFmpeg.
@Suite("Subtitle styling and placement")
struct SubtitlePlacementTests {

    private func convert(_ payload: String, kind: TextSubtitleConverter.Kind = .subrip,
                         playResolution: TextSubtitleConverter.PlayResolution? = nil)
        -> TextSubtitleConverter.Converted?
    {
        TextSubtitleConverter.convert(Data(payload.utf8), kind: kind, playResolution: playResolution)
    }

    // MARK: - Inline styles

    @Test("Italic, bold and underline overrides become balanced WebVTT tags")
    func inlineStylesBecomeTags() {
        #expect(convert("{\\i1}Ahoj{\\i0} světe")?.text == "<i>Ahoj</i> světe")
        #expect(convert("{\\b1}tučně{\\b0}")?.text == "<b>tučně</b>")
        #expect(convert("{\\b700}weight{\\b0}")?.text == "<b>weight</b>")
        #expect(convert("{\\u1}pod{\\u0}")?.text == "<u>pod</u>")
    }

    @Test("Overlapping style ranges are re-nested rather than crossed")
    func overlappingStylesNest() {
        // Italic opens first and bold closes first — a naive translation
        // would emit `<i><b>…</i></b>`, which no WebVTT renderer accepts.
        let text = convert("{\\i1}a {\\b1}b{\\i0} c{\\b0} d")?.text
        #expect(text == "<i>a </i><b><i>b</i></b> <b>c</b> d")
    }

    @Test("A style left open is closed at the end of the cue; \\r resets it")
    func openStyleClosedAtEnd() {
        #expect(convert("{\\i1}never closed")?.text == "<i>never closed</i>")
        #expect(convert("{\\i1}styled{\\r} plain")?.text == "<i>styled</i> plain")
        #expect(convert("{\\i1}styled{\\rAlt} plain")?.text == "<i>styled</i> plain")
    }

    @Test("A tag spanning an ASS line break stays balanced across the lines")
    func tagSpansLineBreak() {
        #expect(convert("{\\i1}first\\Nsecond{\\i0}")?.text == "<i>first\nsecond</i>")
    }

    @Test("Overrides that cover no visible text emit no tags, and an all-override event is no cue")
    func emptyStyledRangesEmitNothing() {
        #expect(convert("{\\i1}{\\i0}plain")?.text == "plain")
        #expect(convert("{\\i1} {\\i0}plain")?.text == "plain")
        #expect(convert("{\\i1}{\\an8}") == nil)
    }

    @Test("Colour, font, karaoke and drawing overrides are removed; comments too; unbalanced braces are left alone")
    func otherOverridesRemoved() {
        #expect(convert("{\\c&H00FFFF&\\fnArial\\fs20\\blur2\\bord3\\alpha&H80&}text")?.text == "text")
        #expect(convert("{\\k20}ka{\\k30}ra")?.text == "kara")
        #expect(convert("{a comment}text")?.text == "text")
        #expect(convert("{unbalanced text")?.text == "{unbalanced text")
        #expect(convert("{\\iclip(1,2,3,4)}not italic")?.text == "not italic")
        #expect(convert("{\\iclip(1,2,3,4)}not italic")?.placement == nil)
    }

    // MARK: - Alignment and position

    @Test("\\an lifts the numpad alignment into the placement and out of the text")
    func numpadAlignment() throws {
        let converted = try #require(convert("{\\an8}Top of the frame"))
        #expect(converted.text == "Top of the frame")
        #expect(converted.placement == TextCuePlacement(alignment: 8))
        #expect(converted.placement?.row == .top)
        #expect(converted.placement?.column == .center)
        #expect(converted.placement?.webVTTSettings == "line:5%")
    }

    @Test("Legacy SSA \\a values map onto the numpad")
    func legacyAlignment() {
        #expect(convert("{\\a6}x")?.placement?.alignment == 8)   // 6 = top centre
        #expect(convert("{\\a10}x")?.placement?.alignment == 5)  // 10 = middle centre
        #expect(convert("{\\a1}x")?.placement?.alignment == 1)
        #expect(convert("{\\a4}x")?.placement == nil)             // not a legal value
        #expect(convert("{\\an0}x")?.placement == nil)
        #expect(convert("{\\an10}x")?.placement == nil)
    }

    @Test("Every alignment renders settings a bottom-centre cue would not carry")
    func alignmentSettings() {
        func settings(_ alignment: Int) -> String? { TextCuePlacement(alignment: alignment)?.webVTTSettings }
        #expect(settings(2) == nil)
        #expect(settings(1) == "align:start")
        #expect(settings(3) == "align:end")
        #expect(settings(5) == "line:45%")
        #expect(settings(7) == "line:5% align:start")
        #expect(settings(9) == "line:5% align:end")
    }

    @Test("\\pos is normalized against the play resolution; without one only the alignment survives")
    func positionNormalized() throws {
        let hd = TextSubtitleConverter.PlayResolution(width: 1920, height: 1080)
        let converted = try #require(
            convert("0,Default,,0,0,0,,{\\an8\\pos(960,108)}Sign", kind: .ass, playResolution: hd)
        )
        #expect(converted.text == "Sign")
        #expect(converted.placement?.alignment == 8)
        #expect(converted.placement?.anchor == .init(x: 0.5, y: 0.1))
        #expect(converted.placement?.webVTTSettings == "line:10% position:50%")

        // A `\pos` with no `\an` anchors like the default style: bottom centre.
        let bare = try #require(convert("0,Default,,0,0,0,,{\\pos(192,1000)}x", kind: .ass, playResolution: hd))
        #expect(bare.placement?.alignment == 2)
        #expect(bare.placement?.anchor == .init(x: 0.1, y: 1000.0 / 1080))

        // No resolution (an SRT with pasted-in overrides): the point has no unit.
        let unitless = try #require(convert("{\\an8\\pos(960,108)}Sign"))
        #expect(unitless.placement == TextCuePlacement(alignment: 8))
        #expect(convert("{\\pos(960,108)}no alignment")?.placement == nil)
    }

    @Test("A bottom-row anchor in the bottom band renders as the default; higher up it names a box top")
    func bottomAnchorSettings() {
        let low = TextCuePlacement(alignment: 2, anchor: .init(x: 0.5, y: 0.92))
        #expect(low?.webVTTSettings == "position:50%")
        let raised = TextCuePlacement(alignment: 1, anchor: .init(x: 0.2, y: 0.6))
        #expect(raised?.webVTTSettings == "line:50% position:20% align:start")
        let middle = TextCuePlacement(alignment: 5, anchor: .init(x: 0.5, y: 0.5))
        #expect(middle?.webVTTSettings == "line:45% position:50%")
        // Off-picture anchors are kept on the placement but clamped in print.
        let outside = TextCuePlacement(alignment: 8, anchor: .init(x: 1.4, y: -0.2))
        #expect(outside?.anchor == .init(x: 1.4, y: -0.2))
        #expect(outside?.webVTTSettings == "line:0% position:100%")
    }

    @Test("Play resolution comes from the ASS header, with libass defaults for what it omits")
    func playResolutionFromHeader() {
        let header = "[Script Info]\r\nScriptType: v4.00+\r\nPlayResX: 1920\r\nPlayResY: 1080\r\n\r\n[V4+ Styles]\r\n"
        #expect(TextSubtitleConverter.playResolution(fromASSHeader: Data(header.utf8)) == .init(width: 1920, height: 1080))
        #expect(TextSubtitleConverter.playResolution(fromASSHeader: Data("[Script Info]\nTitle: x\n".utf8)) == .assDefault)
        #expect(TextSubtitleConverter.playResolution(fromASSHeader: Data("PlayResY: 720\n".utf8)) == .init(width: 960, height: 720))
        #expect(TextSubtitleConverter.playResolution(fromASSHeader: Data("PlayResX: 0\nPlayResY: -5\n".utf8)) == .assDefault)
        #expect(TextSubtitleConverter.playResolution(fromASSHeader: nil) == nil)
        #expect(TextSubtitleConverter.playResolution(fromASSHeader: Data()) == nil)
    }

    // MARK: - WebVTT cue settings

    @Test("Source cue settings are reduced to the five the format defines, with safe values")
    func settingsSanitized() {
        #expect(TextCuePlacement.sanitizedWebVTTSettings("line:85% align:start") == "line:85% align:start")
        #expect(TextCuePlacement.sanitizedWebVTTSettings("position:10%,line-left size:80% vertical:rl")
                == "position:10%,line-left size:80% vertical:rl")
        // Unknown settings, region references and anything malformed go.
        #expect(TextCuePlacement.sanitizedWebVTTSettings("region:fred foo:bar line:0") == "line:0")
        #expect(TextCuePlacement.sanitizedWebVTTSettings("bare -->") == nil)
        #expect(TextCuePlacement.sanitizedWebVTTSettings("line:5%\nBogus --> 00:00:09.000") == "line:5%")
        #expect(TextCuePlacement.sanitizedWebVTTSettings("line:<script>") == nil)
        #expect(TextCuePlacement.sanitizedWebVTTSettings("align:start align:end") == "align:start")
        #expect(TextCuePlacement.sanitizedWebVTTSettings("") == nil)
    }

    @Test("A settings string reads back as a placement for the host")
    func settingsToPlacement() {
        #expect(TextCuePlacement(webVTTSettings: "line:10% align:start") == TextCuePlacement(alignment: 7, anchor: .init(x: 0, y: 0.1)))
        #expect(TextCuePlacement(webVTTSettings: "line:50%") == TextCuePlacement(alignment: 5, anchor: .init(x: 0.5, y: 0.5)))
        #expect(TextCuePlacement(webVTTSettings: "line:90% position:30%") == TextCuePlacement(alignment: 2, anchor: .init(x: 0.3, y: 0.9)))
        // A line NUMBER names a half of the frame only — no anchor.
        #expect(TextCuePlacement(webVTTSettings: "line:0") == TextCuePlacement(alignment: 8))
        #expect(TextCuePlacement(webVTTSettings: "line:-1") == TextCuePlacement(alignment: 2))
        #expect(TextCuePlacement(webVTTSettings: "align:right") == TextCuePlacement(alignment: 3))
        // Line alignment suffix wins over the percentage's band.
        #expect(TextCuePlacement(webVTTSettings: "line:90%,start")?.row == .top)
        #expect(TextCuePlacement(webVTTSettings: "size:50%") == nil)
        #expect(TextCuePlacement(webVTTSettings: "vertical:rl line:10%") == nil)
    }

    @Test("SRT sidecars honour the ASS alignment authors paste in")
    func srtSidecarPlacement() {
        let cues = TextSubtitleConverter.cues(fromSRT: "1\n00:00:01,000 --> 00:00:03,000\n{\\an8}<i>Up here</i>\n")
        #expect(cues.first?.text == "<i>Up here</i>")
        #expect(cues.first?.settings == "line:5%")
        #expect(cues.first?.placement == TextCuePlacement(alignment: 8))
    }

    // MARK: - Rendition

    @Test("Settings print on the timing line and survive a boundary clamp; the header-only shape is unchanged")
    func renderedSettings() throws {
        let cue = SubtitleCue(start: 1, end: 3, text: "up", settings: "line:5%", placement: TextCuePlacement(alignment: 8))
        let body = WebVTTRenditionWriter.render(cues: [cue, SubtitleCue(start: 4, end: 5, text: "plain")], mpegtsOffset: 0)
        #expect(body.contains("00:00:01.000 --> 00:00:03.000 line:5%\nup\n\n"))
        #expect(body.contains("00:00:04.000 --> 00:00:05.000\nplain\n\n"))

        let clamped = cue.clamped(to: 2...6)
        #expect(clamped.start == 2)
        #expect(clamped.settings == "line:5%")
        #expect(clamped.placement == cue.placement)
        #expect(cue.ending(at: 2.5).settings == "line:5%")
    }
}
