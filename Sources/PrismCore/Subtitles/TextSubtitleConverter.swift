import Foundation

/// Turns text-subtitle payloads into WebVTT cue text — the whole conversion
/// half of phase 6, as pure Swift.
///
/// **Why no `avcodec_decode_subtitle2`.** libavcodec would happily decode every
/// text codec into an ASS event line, but that buys nothing here: the payloads
/// this pipeline sees (a Matroska `S_TEXT/UTF8` block, an `S_TEXT/ASS` event, a
/// `tx3g` sample) are already the text itself, so a decoder would only add a
/// codec-availability dependency on the FFmpeg build (MPVKit's trim is exactly
/// the kind of surprise that cost us the `hls` muxer, see `FMP4SegmentWriter`)
/// and make every rule untestable without a demuxer. Everything below is a
/// value-in/value-out function with a unit test.
///
/// The output is WebVTT-safe by construction: no `-->` inside a payload, no
/// blank line inside a cue (either would terminate it early), unknown markup
/// escaped rather than emitted.
enum TextSubtitleConverter {

    /// The payload shapes we know how to read.
    enum Kind: Equatable {
        /// SubRip / plain text: the payload IS the cue text (Matroska stores
        /// `S_TEXT/UTF8` that way; the timing lives in the packet).
        case subrip
        /// ASS / SSA event: comma-separated fields, text last, `{\…}` override
        /// blocks inside it.
        case ass
        /// WebVTT payload (`S_TEXT/WEBVTT`) — already the target syntax. Cue
        /// settings ride in packet side data, which the caller reads
        /// (`TextCuePlacement.sanitizedWebVTTSettings`) — the payload alone
        /// carries none.
        case webvtt
        /// ISO/QuickTime timed text (`tx3g`): 16-bit big-endian length, then
        /// UTF-8, then optional style boxes we ignore.
        case movText
    }

    /// The coordinate space an ASS script's `\pos` values live in — its
    /// `PlayResX`/`PlayResY`. Needed to normalize an anchor; without it a
    /// `\pos` is a number in an unknown unit and is dropped.
    struct PlayResolution: Equatable {
        var width: Double
        var height: Double

        /// What libass assumes when a script declares neither dimension.
        static let assDefault = PlayResolution(width: 384, height: 288)
    }

    /// One converted payload: WebVTT-safe text plus whatever placement the
    /// source's own markup asked for.
    struct Converted: Equatable {
        var text: String
        var placement: TextCuePlacement?
    }

    // MARK: - Packet payloads

    /// Cue text for one packet payload, or `nil` when the payload carries no
    /// visible text (an ASS karaoke-only event, an empty tx3g sample — both
    /// real and both must not become an empty cue).
    static func cueText(from payload: Data, kind: Kind) -> String? {
        convert(payload, kind: kind, playResolution: nil)?.text
    }

    /// Text and placement for one packet payload; `nil` on no visible text.
    /// `playResolution` is the ASS script's, for `\pos` — `nil` keeps the
    /// alignment and drops the point.
    static func convert(_ payload: Data, kind: Kind, playResolution: PlayResolution?) -> Converted? {
        let raw: String?
        switch kind {
        case .subrip, .webvtt:
            raw = String(data: payload, encoding: .utf8)
        case .ass:
            raw = String(data: payload, encoding: .utf8).map(assEventText)
        case .movText:
            raw = movTextPayload(payload)
        }
        guard let raw else { return nil }
        let converted = sanitizeStyled(raw, playResolution: playResolution)
        return converted.text.isEmpty ? nil : converted
    }

    /// `PlayResX`/`PlayResY` from an ASS script header (the stream's
    /// extradata). A header that names neither gets libass's default; no
    /// header at all — a non-ASS track — gets `nil`, so its `\pos` blocks
    /// (an SRT with ASS overrides pasted in) contribute only their alignment.
    static func playResolution(fromASSHeader header: Data?) -> PlayResolution? {
        guard let header, !header.isEmpty,
              let text = String(data: header, encoding: .utf8) ?? String(data: header, encoding: .isoLatin1)
        else { return nil }
        var width: Double?
        var height: Double?
        for rawLine in normalized(text).split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = Double(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            if key == "playresx" { width = value } else if key == "playresy" { height = value }
        }
        // libass fills a lone dimension from the other at 4:3; a zero or
        // negative value is a corrupt header, treated as absent.
        switch (width.flatMap { $0 > 0 ? $0 : nil }, height.flatMap { $0 > 0 ? $0 : nil }) {
        case let (w?, h?): return PlayResolution(width: w, height: h)
        case let (w?, nil): return PlayResolution(width: w, height: w * 3 / 4)
        case let (nil, h?): return PlayResolution(width: h * 4 / 3, height: h)
        case (nil, nil): return .assDefault
        }
    }

    /// The `Text` field of an ASS event line.
    ///
    /// Three shapes reach us, and the field count differs in each — so the
    /// shape is detected rather than assumed:
    ///
    /// - a full `Dialogue:` line (an `.ass` file, or `mp4` ASS): 9 fields
    ///   before `Text` (`Layer,Start,End,Style,Name,ML,MR,MV,Effect`);
    /// - libavcodec's internal ASS line: 8 (`ReadOrder,Layer,Style,Name,…`),
    ///   recognizable because field 2 is the numeric `Layer`;
    /// - a Matroska `S_TEXT/ASS` block: 7 (`Layer,Style,Name,…`) — the start
    ///   and end times were lifted into the block's own timing.
    static func assEventText(_ line: String) -> String {
        var body = line.trimmingCharacters(in: .whitespacesAndNewlines)
        var fieldsBeforeText = 7

        if let range = body.range(of: "Dialogue:") {
            body = String(body[range.upperBound...])
            fieldsBeforeText = 9
        } else {
            let head = body.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
            if head.count >= 2, Int(head[1].trimmingCharacters(in: .whitespaces)) != nil {
                fieldsBeforeText = 8
            }
        }

        let parts = body.split(
            separator: ",",
            maxSplits: fieldsBeforeText,
            omittingEmptySubsequences: false
        )
        // Too few fields to be an event line: treat the whole thing as text
        // rather than losing the cue.
        guard parts.count > fieldsBeforeText else { return body }
        return String(parts[fieldsBeforeText])
    }

    /// `tx3g` sample: 16-bit big-endian text length, then UTF-8. Anything after
    /// that is style/highlight boxes, which the WebVTT rendition doesn't carry.
    private static func movTextPayload(_ payload: Data) -> String? {
        guard payload.count >= 2 else { return nil }
        let bytes = [UInt8](payload)
        let length = Int(bytes[0]) << 8 | Int(bytes[1])
        guard length > 0, payload.count >= 2 + length else { return nil }
        return String(data: payload[(payload.startIndex + 2)..<(payload.startIndex + 2 + length)], encoding: .utf8)
    }

    // MARK: - Sidecar files

    /// Cues from a whole `.srt` file.
    ///
    /// Lenient on purpose — real sidecars carry a BOM, CRLF endings, missing
    /// sequence numbers and stray blank lines, and a strict parser that drops
    /// the file is worse than one that drops a malformed block.
    static func cues(fromSRT text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var timing: (start: Double, end: Double)?
        var lines: [String] = []

        func flush() {
            defer { timing = nil; lines = [] }
            guard let timing else { return }
            // SRT has no placement syntax of its own, so authors borrow the
            // ASS `{\an8}` — common enough that every desktop player honours
            // it. `\pos` has no resolution to be measured against here.
            let body = sanitizeStyled(lines.joined(separator: "\n"), playResolution: nil)
            guard !body.text.isEmpty, timing.end > timing.start else { return }
            cues.append(SubtitleCue(
                start: timing.start, end: timing.end, text: body.text,
                settings: body.placement?.webVTTSettings, placement: body.placement
            ))
        }

        for rawLine in normalized(text).split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
                continue
            }
            if let parsed = parseTimingLine(line) {
                // A second timing line without a blank separator: the previous
                // block ends here.
                if timing != nil { flush() }
                timing = parsed
                continue
            }
            // A bare number before a timing line is the sequence index.
            if timing == nil, Int(line) != nil { continue }
            if timing != nil { lines.append(line) }
        }
        flush()
        return cues
    }

    /// Cues from a whole `.vtt` file. Header, `NOTE` / `STYLE` / `REGION`
    /// blocks and cue identifiers are dropped. Cue settings after the timing
    /// (`line:`, `align:`) are kept — reduced to the safe subset — because
    /// they are the one placement a sidecar author could express, and the
    /// system caption renderer honours them.
    static func cues(fromWebVTT text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var timing: (start: Double, end: Double, settings: String?)?
        var lines: [String] = []
        var skippingBlock = false

        func flush() {
            defer { timing = nil; lines = [] }
            guard let timing else { return }
            let body = sanitizeStyled(lines.joined(separator: "\n"), playResolution: nil)
            guard !body.text.isEmpty, timing.end > timing.start else { return }
            let settings = timing.settings.flatMap(TextCuePlacement.sanitizedWebVTTSettings)
            cues.append(SubtitleCue(
                start: timing.start, end: timing.end, text: body.text,
                settings: settings ?? body.placement?.webVTTSettings,
                placement: settings.flatMap(TextCuePlacement.init(webVTTSettings:)) ?? body.placement
            ))
        }

        for rawLine in normalized(text).split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
                skippingBlock = false
                continue
            }
            if skippingBlock { continue }
            if line.hasPrefix("WEBVTT") || line.hasPrefix("X-TIMESTAMP-MAP") { continue }
            if line.hasPrefix("NOTE") || line.hasPrefix("STYLE") || line.hasPrefix("REGION") {
                skippingBlock = true
                continue
            }
            if let parsed = parseTimingLineWithSettings(line) {
                if timing != nil { flush() }
                timing = parsed
                continue
            }
            if timing != nil { lines.append(line) }
            // else: a cue identifier line — dropped.
        }
        flush()
        return cues
    }

    /// `00:00:01,000 --> 00:00:03,000` (SRT) or `00:01.000 --> 00:03.000`
    /// (WebVTT short form), with any trailing cue settings ignored.
    static func parseTimingLine(_ line: String) -> (start: Double, end: Double)? {
        parseTimingLineWithSettings(line).map { ($0.start, $0.end) }
    }

    /// The timing line with whatever followed the end timestamp — WebVTT cue
    /// settings, verbatim and unvalidated (`nil` when nothing did).
    static func parseTimingLineWithSettings(_ line: String) -> (start: Double, end: Double, settings: String?)? {
        guard let arrow = line.range(of: "-->") else { return nil }
        let startText = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
        let tail = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
        let pieces = tail.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
        let endField = pieces.first.map(String.init) ?? ""
        guard let start = parseTimestamp(startText), let end = parseTimestamp(endField) else {
            return nil
        }
        let settings = pieces.count > 1 ? String(pieces[1]).trimmingCharacters(in: .whitespaces) : ""
        return (start, end, settings.isEmpty ? nil : settings)
    }

    /// `[HH:]MM:SS[.,]mmm` → seconds. Both separators, both field counts.
    static func parseTimestamp(_ text: String) -> Double? {
        let unified = text.replacingOccurrences(of: ",", with: ".")
        let parts = unified.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var seconds = 0.0
        for part in parts.dropLast() {
            guard let value = Double(part) else { return nil }
            seconds = seconds * 60 + value
        }
        guard let last = Double(parts[parts.count - 1]) else { return nil }
        return seconds * 60 + last
    }

    // MARK: - WebVTT safety

    /// Markup WebVTT understands. Everything else is escaped so a stray `<`
    /// in dialogue can't swallow the rest of the line as a tag.
    private static let allowedTags: Set<String> = [
        "i", "b", "u", "v", "c", "lang", "ruby", "rt",
    ]

    /// Make a payload safe to sit inside a WebVTT cue: no cue-terminating
    /// blank lines, no `-->`, ASS overrides translated or gone, unknown
    /// markup escaped. Text only — `sanitizeStyled` also keeps the placement.
    static func sanitize(_ text: String) -> String {
        sanitizeStyled(text, playResolution: nil).text
    }

    /// `sanitize`, plus the placement the ASS override blocks asked for.
    static func sanitizeStyled(_ text: String, playResolution: PlayResolution?) -> Converted {
        var result = normalized(text)

        // ASS override blocks (`{\i1}`, `{\an8}`, `{\pos(…)}`). The inline
        // styles WebVTT has words for become its tags; the placement is
        // lifted out; colours, fonts, karaoke and drawing are dropped, since
        // the system caption renderer applies the viewer's style anyway.
        let translated = translateOverrides(result, playResolution: playResolution)
        result = translated.text
        // ASS line breaks and hard spaces, in their literal escaped form.
        result = result.replacingOccurrences(of: "\\N", with: "\n")
        result = result.replacingOccurrences(of: "\\n", with: "\n")
        result = result.replacingOccurrences(of: "\\h", with: " ")

        result = escapeAndMarkup(result)

        // A blank line inside a cue ends it, so collapse runs of newlines and
        // drop trailing whitespace per line.
        let lines = result
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Converted(text: lines.joined(separator: "\n"), placement: translated.placement)
    }

    private static func normalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Translates `{…}` override blocks: `\i` / `\b` / `\u` become balanced
    /// WebVTT tags, `\an` / `\a` / `\pos` become the placement, everything
    /// else in a block is removed. Unbalanced braces are left alone rather
    /// than eating the rest of the line.
    ///
    /// Tags are opened lazily (on the first visible character they cover) and
    /// closed as a group whenever the active set changes, so the output is
    /// always properly nested and never carries an empty `<i></i>` — WebVTT
    /// tolerates neither overlap nor, in some renderers, an unclosed tag at
    /// the end of a cue.
    static func translateOverrides(_ text: String, playResolution: PlayResolution?) -> Converted {
        guard text.contains("{") else { return Converted(text: text, placement: nil) }

        // Balance check first: the walk below has no way back once it has
        // emitted tags for a block that never closes.
        var depth = 0
        for character in text {
            if character == "{" { depth += 1 } else if character == "}" { depth = max(0, depth - 1) }
        }
        guard depth == 0 else { return Converted(text: text, placement: nil) }

        var output = ""
        var block: String?
        var desired = OverrideStyle()
        var open: [String] = []
        var alignment: Int?
        var anchor: TextCuePlacement.Anchor?

        func closeAll() {
            for tag in open.reversed() { output += "</\(tag)>" }
            open = []
        }

        for character in text {
            if let current = block {
                if character == "}" {
                    block = nil
                    apply(overrides: current, to: &desired, alignment: &alignment,
                          anchor: &anchor, playResolution: playResolution)
                } else {
                    block = current + String(character)
                }
                continue
            }
            if character == "{" {
                block = ""
                continue
            }
            // Only a visible character commits the pending style; whitespace
            // between `{\i1}` and the word would otherwise open a tag over
            // nothing. Whitespace does close a style that just ended, so the
            // space after `{\i0}` is not italic — a renderer underlines it.
            if desired.tags != open {
                if !character.isWhitespace {
                    closeAll()
                    open = desired.tags
                    for tag in open { output += "<\(tag)>" }
                } else {
                    closeAll()
                }
            }
            output.append(character)
        }
        closeAll()

        var placement: TextCuePlacement?
        if let alignment {
            placement = TextCuePlacement(alignment: alignment, anchor: anchor)
        } else if anchor != nil {
            // A `\pos` with no `\an` is anchored the way the default style
            // aligns, which for practically every script is bottom-centre.
            placement = TextCuePlacement(alignment: 2, anchor: anchor)
        }
        return Converted(text: output, placement: placement)
    }

    /// The inline state an override walk accumulates.
    private struct OverrideStyle: Equatable {
        var bold = false
        var italic = false
        var underline = false

        /// Tag names in the one fixed nesting order the output uses.
        var tags: [String] {
            var result: [String] = []
            if bold { result.append("b") }
            if italic { result.append("i") }
            if underline { result.append("u") }
            return result
        }
    }

    /// Applies one block's tags. `\r` resets the inline style (its optional
    /// style-name argument is ignored — named styles are not parsed).
    private static func apply(
        overrides block: String, to style: inout OverrideStyle,
        alignment: inout Int?, anchor: inout TextCuePlacement.Anchor?,
        playResolution: PlayResolution?
    ) {
        // A block without a backslash is a comment (or an SRT author's stray
        // braces) and is removed whole, as before.
        for rawTag in block.split(separator: "\\", omittingEmptySubsequences: false).dropFirst() {
            let tag = rawTag.trimmingCharacters(in: .whitespaces)
            if tag.hasPrefix("pos(") {
                guard let playResolution, playResolution.width > 0, playResolution.height > 0,
                      let close = tag.firstIndex(of: ")")
                else { continue }
                let args = tag[tag.index(tag.startIndex, offsetBy: 4)..<close]
                    .split(separator: ",")
                    .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard args.count == 2, args[0].isFinite, args[1].isFinite else { continue }
                anchor = TextCuePlacement.Anchor(
                    x: args[0] / playResolution.width, y: args[1] / playResolution.height
                )
            } else if tag.hasPrefix("an"), let value = Int(tag.dropFirst(2)) {
                if (1...9).contains(value) { alignment = value }
            } else if tag.hasPrefix("a"), let value = Int(tag.dropFirst(1)) {
                if let mapped = TextCuePlacement.alignment(fromLegacySSA: value) { alignment = mapped }
            } else if tag.hasPrefix("i"), let value = Int(tag.dropFirst(1)) {
                style.italic = value != 0
            } else if tag.hasPrefix("u"), let value = Int(tag.dropFirst(1)) {
                style.underline = value != 0
            } else if tag.hasPrefix("b"), let value = Int(tag.dropFirst(1)) {
                // `\b1` and `\b700` (a weight) both mean bold; `\b0` is off.
                style.bold = value != 0
            } else if tag.hasPrefix("r"), !tag.hasPrefix("rnd") {
                // `\r` / `\rStyleName`; `\rnd` is a renderer's jitter, not a reset.
                style = OverrideStyle()
            }
        }
    }

    /// Escapes `&`, neutralizes `-->`, keeps known tags and escapes the rest.
    private static func escapeAndMarkup(_ text: String) -> String {
        var output = ""
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            switch character {
            case "&":
                if let entity = entity(in: text, at: index) {
                    output += entity
                    index = text.index(index, offsetBy: entity.count)
                    continue
                }
                output += "&amp;"
            case "<":
                if let tag = tag(in: text, at: index) {
                    // `font` is the one common tag WebVTT has no equivalent for
                    // (SRT files are full of `<font color=…>`); drop the tag,
                    // keep the words.
                    if tag.name != "font" {
                        output += tag.text
                    }
                    index = text.index(index, offsetBy: tag.text.count)
                    continue
                }
                output += "&lt;"
            case "-":
                // `-->` may not appear in a cue payload at all.
                if text[index...].hasPrefix("-->") {
                    output += "--&gt;"
                    index = text.index(index, offsetBy: 3)
                    continue
                }
                output.append(character)
            default:
                output.append(character)
            }
            index = text.index(after: index)
        }
        return output
    }

    /// An HTML character reference starting at `index`, if there is one.
    private static func entity(in text: String, at index: String.Index) -> String? {
        let tail = text[index...]
        guard let semicolon = tail.firstIndex(of: ";"), semicolon != tail.startIndex else { return nil }
        let body = tail[tail.index(after: tail.startIndex)..<semicolon]
        guard !body.isEmpty, body.count <= 10 else { return nil }
        let isNumeric = body.hasPrefix("#") && body.dropFirst().allSatisfy(\.isNumber)
        let isNamed = body.allSatisfy { $0.isLetter || $0.isNumber }
        guard isNumeric || isNamed else { return nil }
        return String(tail[tail.startIndex...semicolon])
    }

    /// A WebVTT-legal tag starting at `index`, with its name, if there is one.
    private static func tag(in text: String, at index: String.Index) -> (name: String, text: String)? {
        let tail = text[index...]
        guard let close = tail.firstIndex(of: ">") else { return nil }
        let inner = tail[tail.index(after: tail.startIndex)..<close]
        guard !inner.isEmpty, !inner.contains("<") else { return nil }
        let nameField = inner.hasPrefix("/") ? inner.dropFirst() : inner[...]
        let name = String(nameField.prefix { $0.isLetter || $0.isNumber }).lowercased()
        guard allowedTags.contains(name) || name == "font" else { return nil }
        // Only the name prefix is validated, so the rest of the tag is emitted
        // verbatim — and an inner ending in `--` composes `-->` with the
        // closing bracket, the one sequence that may never appear in a cue.
        // `<i-->` in a mangled SRT did exactly that (found by the fuzz
        // harness); rejecting it here routes the `<` to `&lt;` and the `--`
        // to the `-->` neutralizer instead.
        guard !inner.hasSuffix("--") else { return nil }
        return (name, String(tail[tail.startIndex...close]))
    }
}
