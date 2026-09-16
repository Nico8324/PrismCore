import Foundation

/// Where a text cue asked to be drawn — when the source said so at all.
///
/// Almost every cue says nothing and wants the renderer's default: bottom
/// centre. The ones that do speak up matter out of proportion to their
/// number: a `{\an8}` moves dialogue to the top of the frame so it does not
/// sit on burned-in signs or a second speaker's caption, and a WebVTT
/// `line:` does the same for a sidecar. Dropping that used to leave two
/// captions stacked on one another, which is the failure this type exists
/// to prevent — it is carried both into the served rendition (as WebVTT cue
/// settings) and to hosts that draw text themselves (`TimedTextCue`).
///
/// Two models had to meet here. ASS positions an *anchor point* (a numpad
/// alignment, optionally a `\pos`); WebVTT positions a *box edge* (`line:` is
/// where the box top lands, `position:` where its aligned edge lands). The
/// anchor is what the source meant, so it is what is stored; the settings
/// string is a rendering of it, and the two conversions are separate so a
/// host can ignore the WebVTT reading entirely.
public struct TextCuePlacement: Sendable, Equatable {

    /// A point on the picture, normalized to `0…1` on both axes, `y` measured
    /// from the top. Usually inside the frame, but a script may anchor
    /// outside it on purpose, so the range is not clamped here — a host
    /// that cannot draw off-picture decides for itself.
    public struct Anchor: Sendable, Equatable {
        public let x: Double
        public let y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// Numpad alignment, as ASS spells it: `1` bottom-left through `3`
    /// bottom-right, `4`–`6` the middle row, `7`–`9` the top row. `2` is the
    /// everyday bottom-centre.
    public let alignment: Int

    /// Anchor from `\pos(x,y)` (normalized against the script's play
    /// resolution) or from a WebVTT `line:`/`position:` percentage pair.
    /// `nil` when only a row/column was named.
    public let anchor: Anchor?

    /// `nil` for an alignment outside `1…9` — a malformed `\an0` must not
    /// invent a placement.
    public init?(alignment: Int, anchor: Anchor? = nil) {
        guard (1...9).contains(alignment) else { return nil }
        self.alignment = alignment
        self.anchor = anchor
    }

    // MARK: - Geometry

    public enum Row: Sendable, Equatable { case bottom, middle, top }
    public enum Column: Sendable, Equatable { case start, center, end }

    public var row: Row {
        switch alignment {
        case 1...3: return .bottom
        case 4...6: return .middle
        default: return .top
        }
    }

    public var column: Column {
        switch alignment % 3 {
        case 1: return .start
        case 2: return .center
        default: return .end
        }
    }

    /// Numpad alignment for a legacy SSA `\a` value (`1`–`3` bottom, `+4`
    /// top, `+8` middle), or `nil` for anything else.
    static func alignment(fromLegacySSA value: Int) -> Int? {
        switch value {
        case 1...3: return value
        case 5...7: return value + 2      // 5,6,7 → 7,8,9
        case 9...11: return value - 5     // 9,10,11 → 4,5,6
        default: return nil
        }
    }

    // MARK: - WebVTT cue settings

    /// The cue settings the served rendition should carry for this placement,
    /// or `nil` when the placement is the renderer's own default (bottom
    /// centre with no anchor) and printing anything would only invite a
    /// parser quirk.
    ///
    /// The mapping is deliberately restricted to the setting forms every
    /// WebVTT renderer has accepted since the first drafts — bare `line:NN%`,
    /// `position:NN%`, `align:start|center|end`. The line-alignment suffix
    /// (`line:NN%,end`) would model the anchor exactly, but it arrived later
    /// and a renderer that rejects it drops the whole setting; the box-top
    /// adjustment below is the trade for staying inside the safe subset.
    var webVTTSettings: String? {
        var fields: [String] = []

        if let anchor {
            // `line:` names the box TOP. A bottom-row anchor names where the
            // text's baseline sits, so the box starts roughly two lines
            // above it; a middle anchor about one. Nominal heights — the
            // renderer's line height is unknown here — but they keep a
            // `\pos` at the bottom from sliding the cue off the frame.
            let percent = Self.percent(anchor.y)
            let top: Int?
            switch row {
            case .top: top = percent
            case .middle: top = max(0, percent - 5)
            // A bottom anchor in the bottom band IS the default look.
            case .bottom: top = percent >= 85 ? nil : max(0, percent - 10)
            }
            if let top { fields.append("line:\(top)%") }
            fields.append("position:\(Self.percent(anchor.x))%")
        } else {
            switch row {
            case .top: fields.append("line:5%")
            case .middle: fields.append("line:45%")
            case .bottom: break
            }
        }

        // With no explicit position, `align:` alone moves the box to the
        // named edge (the spec's `position:auto` follows the alignment), so
        // a column is one setting rather than two.
        switch column {
        case .start: fields.append("align:start")
        case .end: fields.append("align:end")
        case .center: break
        }

        return fields.isEmpty ? nil : fields.joined(separator: " ")
    }

    /// The placement a WebVTT cue-settings string asks for, or `nil` when it
    /// asks for nothing this type models (a `size:` alone, `vertical:` text).
    ///
    /// Reads the same three settings `webVTTSettings` writes, plus the older
    /// `left`/`right`/`middle` spellings real tools still emit. A `line:`
    /// given as a line *number* names only the half of the frame (the
    /// rendered line height is unknown), so it yields a row and no anchor.
    init?(webVTTSettings settings: String) {
        var column: Column?
        var row: Row?
        var lineFraction: Double?
        var positionFraction: Double?

        for field in settings.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let parts = field.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let value = String(parts[1])
            switch parts[0].lowercased() {
            case "vertical":
                // Vertical text has no numpad reading; pretending it does
                // would put a sideways caption at a horizontal anchor.
                if value == "rl" || value == "lr" { return nil }
            case "align":
                switch value.lowercased() {
                case "start", "left": column = .start
                case "center", "centre", "middle": column = .center
                case "end", "right": column = .end
                default: continue
                }
            case "line":
                let pieces = value.split(separator: ",", omittingEmptySubsequences: false)
                guard let head = pieces.first else { continue }
                if let fraction = Self.fraction(String(head)) {
                    lineFraction = fraction
                    row = fraction < 1.0 / 3 ? .top : (fraction < 2.0 / 3 ? .middle : .bottom)
                } else if let number = Int(head) {
                    // Negative line numbers count up from the bottom.
                    row = number < 0 ? .bottom : .top
                } else {
                    continue
                }
                if pieces.count > 1 {
                    switch pieces[1].lowercased() {
                    case "start": row = .top
                    case "center", "centre", "middle": row = .middle
                    case "end": row = .bottom
                    default: break
                    }
                }
            case "position":
                let head = value.split(separator: ",", omittingEmptySubsequences: false).first ?? ""
                guard let fraction = Self.fraction(String(head)) else { continue }
                positionFraction = fraction
            default:
                continue
            }
        }

        guard column != nil || row != nil || positionFraction != nil else { return nil }
        let resolvedColumn = column ?? .center
        let resolvedRow = row ?? .bottom
        let rowBase: Int
        switch resolvedRow {
        case .bottom: rowBase = 1
        case .middle: rowBase = 4
        case .top: rowBase = 7
        }
        let columnOffset: Int
        switch resolvedColumn {
        case .start: columnOffset = 0
        case .center: columnOffset = 1
        case .end: columnOffset = 2
        }

        var anchor: Anchor?
        if let y = lineFraction {
            // An anchor needs both axes. `position:` alone would fix x with
            // no y to pair it with, so it contributes only through the
            // column above; a `line:` percentage without a `position:` takes
            // its x from the column's edge, which is where the box lands.
            let x = positionFraction ?? [0.0, 0.5, 1.0][columnOffset]
            anchor = Anchor(x: x, y: y)
        }
        self.init(alignment: rowBase + columnOffset, anchor: anchor)
    }

    /// A cue-settings string reduced to what the served rendition may carry.
    ///
    /// The source's own settings are the most faithful placement there is,
    /// so a WebVTT track's are passed through — but a settings string sits on
    /// the *timing line* of the cue, where a stray newline or `-->` breaks
    /// the block the same way it would inside the payload. Only the five
    /// settings the format defines survive, each with a value drawn from the
    /// characters those settings can legally contain; `region:` is dropped
    /// because the rendition writes no `REGION` blocks for it to refer to.
    /// `nil` when nothing survives.
    static func sanitizedWebVTTSettings(_ raw: String) -> String? {
        let allowed: Set<String> = ["line", "position", "align", "size", "vertical"]
        var kept: [String] = []
        var seen: Set<String> = []
        for field in raw.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }) {
            let parts = field.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let name = parts[0].lowercased()
            let value = parts[1]
            guard allowed.contains(name), seen.insert(name).inserted,
                  !value.isEmpty, value.count <= 32,
                  value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "%" || $0 == "." || $0 == "," || $0 == "-") })
            else { continue }
            kept.append("\(name):\(value)")
        }
        return kept.isEmpty ? nil : kept.joined(separator: " ")
    }

    /// `NN%` → `0…1`, clamped: out of range is a malformed file, not a
    /// different intent.
    private static func fraction(_ value: String) -> Double? {
        guard value.hasSuffix("%"), let percent = Double(value.dropLast()) else { return nil }
        return min(1, max(0, percent / 100))
    }

    private static func percent(_ fraction: Double) -> Int {
        Int((min(1, max(0, fraction)) * 100).rounded())
    }
}
