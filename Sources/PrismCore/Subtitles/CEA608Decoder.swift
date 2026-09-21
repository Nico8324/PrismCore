import Foundation

/// A CEA-608 ("line 21") caption decoder: byte pairs in, `SubtitleCue`s out.
///
/// ### The model
///
/// 608 is not a cue format. It is a **terminal**: a 15×32 grid of character
/// cells and a stream of commands that move a cursor, print characters, erase,
/// scroll and swap buffers. A cue is something we synthesise by watching that
/// terminal, because the wire never says "this caption ends here" — it says
/// "erase" or "swap", and whatever was on screen until that instant was the
/// caption.
///
/// So the timing rule is: an interval opens when the display last changed
/// wholesale, and closes at the next such change, carrying the text that is on
/// screen *at the moment it closes*. Only three commands change the display
/// wholesale — `EOC` (the pop-on flip), `EDM` (erase displayed memory) and
/// `CR` (the roll-up scroll). Printing a character does not: it adds to what is
/// already showing.
///
/// That folding is what makes roll-up readable. Under it, a row that is typed
/// out word by word between two carriage returns is emitted as one cue
/// spanning the whole interval — the completed row is visible from the moment
/// its first word appeared. It is a whole row early, which no viewer notices,
/// where the faithful alternative is one cue per character: tens of thousands
/// of ~40 ms cues per programme, each a WebVTT block AVPlayer has to parse.
///
/// ### Channels
///
/// Each 608 field carries two interleaved services — field 1 is CC1/CC2, field
/// 2 is CC3/CC4 — selected by bit 3 of a control code's first byte. Characters
/// go to whichever service the last control code named, so the *field* is the
/// unit that has to be decoded as a whole (`CEA608FieldDecoder`) even when only
/// one of its two channels is wanted.
///
/// ### What this does not do
///
/// Colour, flash, underline and italics are parsed far enough to be skipped,
/// not rendered. The system caption renderer applies the viewer's own style to
/// a WebVTT rendition — which is the accessibility behaviour people configure
/// on purpose — and a `<i>` we invented would fight it. Cell-accurate
/// positioning is dropped for the same reason the bitmap OCR path drops it.
enum CEA608 {

    static let rowCount = 15
    static let columnCount = 32

    /// The 15×32 cell grid. Two of these exist per channel: the one on screen
    /// and the one being built behind it (which is what "pop-on" means).
    struct Screen: Equatable {
        private(set) var cells: [[Character]] = Array(
            repeating: Array(repeating: " ", count: CEA608.columnCount), count: CEA608.rowCount
        )

        mutating func write(_ character: Character, row: Int, column: Int) {
            guard (0..<CEA608.rowCount).contains(row),
                  (0..<CEA608.columnCount).contains(column)
            else { return }
            cells[row][column] = character
        }

        mutating func clear() {
            cells = Array(
                repeating: Array(repeating: " ", count: CEA608.columnCount),
                count: CEA608.rowCount
            )
        }

        mutating func clearRow(_ row: Int) {
            guard (0..<CEA608.rowCount).contains(row) else { return }
            cells[row] = Array(repeating: " ", count: CEA608.columnCount)
        }

        /// Blank from `column` to the end of `row` — the `DER` command.
        mutating func clearToEndOfRow(_ row: Int, from column: Int) {
            guard (0..<CEA608.rowCount).contains(row) else { return }
            for index in max(0, column)..<CEA608.columnCount { cells[row][index] = " " }
        }

        /// Move every row in `base - count + 1 ... base` up one, blanking the
        /// row that becomes free. The roll-up scroll.
        mutating func rollUp(baseRow: Int, windowRows: Int) {
            let top = max(0, baseRow - windowRows + 1)
            guard top < baseRow, baseRow < CEA608.rowCount else {
                clearRow(baseRow)
                return
            }
            for row in top..<baseRow { cells[row] = cells[row + 1] }
            clearRow(baseRow)
        }

        /// Carry a roll-up window's rows from one base row to another.
        ///
        /// A roll-up preamble moves the *window*, not a cursor inside it: the
        /// rows already rolled up travel with it. Left where they were, they
        /// keep printing under the new text — a caption that says two unrelated
        /// things at once, which is what a base-row change mid-programme
        /// (common whenever the lower third is busy) would produce.
        mutating func moveWindow(fromBase oldBase: Int, toBase newBase: Int, windowRows: Int) {
            guard oldBase != newBase, windowRows > 0 else { return }
            var carried: [Int: [Character]] = [:]
            for offset in 0..<windowRows {
                let source = oldBase - offset
                guard (0..<CEA608.rowCount).contains(source) else { continue }
                carried[offset] = cells[source]
                clearRow(source)
            }
            for (offset, row) in carried {
                let destination = newBase - offset
                guard (0..<CEA608.rowCount).contains(destination) else { continue }
                cells[destination] = row
            }
        }

        /// The grid as cue text: non-blank rows, each trimmed, joined by
        /// newlines. Leading indentation is placement, not content, and is
        /// dropped along with the rest of the positioning.
        var text: String {
            cells
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    /// The caption style in force. Only which memory writes land in matters
    /// here; the grid is the same in all three.
    enum Mode: Equatable {
        /// Built off-screen, revealed whole by `EOC`. What scripted content
        /// and every subtitle-quality caption track uses.
        case popOn
        /// Written straight to the screen, scrolled by `CR`. What live
        /// captioning (news, sport) uses.
        case rollUp(windowRows: Int)
        /// Written straight to the screen with no scroll. Rare, and mostly
        /// used for a caption that appears letter by letter.
        case paintOn
    }
}

/// One of the four caption services (CC1…CC4): its two memories, its cursor,
/// and the interval bookkeeping that turns them into cues.
final class CEA608ChannelDecoder {

    /// A caption left standing by a stream whose erase never comes would sit on
    /// screen for the rest of the film. The bitmap path caps an open cue at the
    /// same ten seconds and for the same reason.
    static let maximumCueSeconds = 10.0

    private var displayed = CEA608.Screen()
    private var nonDisplayed = CEA608.Screen()
    private var mode: CEA608.Mode = .popOn
    private var cursorRow = CEA608.rowCount - 1
    private var cursorColumn = 0
    /// The bottom row of the roll-up window; `CR` scrolls against it.
    private var rollUpBaseRow = CEA608.rowCount - 1

    /// Start of the interval the current screen contents cover, in source
    /// seconds. `nil` until the first caption byte gives us a clock.
    private var intervalStart: Double?

    /// When the contents now on screen were *displayed*, in source seconds.
    ///
    /// Separate from `intervalStart` on purpose, and the distinction is the
    /// whole point of the cap. A segment boundary opens a new interval over the
    /// same caption — nothing about the screen changed. Measured from the
    /// interval, a caption displayed at 1 s and split at 6, 12, 18 … renewed
    /// its ten seconds at every boundary and was re-emitted for the rest of the
    /// programme: the exact failure the cap exists to prevent, performed by the
    /// mechanism meant to prevent it. Only a wholesale display change moves
    /// this — which is also why roll-up is unaffected, since every carriage
    /// return genuinely redisplays the rows it scrolls.
    private var displayedSince: Double?
    private var closed: [SubtitleCue] = []

    /// Whether this service has ever printed a character. The scout reads it to
    /// decide whether the channel deserves a rendition at all — a service that
    /// is addressed but never printed is an empty row in the subtitle menu.
    private(set) var hasPrintedText = false

    /// Cues completed so far, handed over and forgotten.
    func drainCues() -> [SubtitleCue] {
        defer { closed = [] }
        return closed
    }

    /// The cue that would be emitted if the display were erased now — what a
    /// segment boundary and end-of-stream both need, since neither is a
    /// caption command and neither may leave a cue open.
    func splitPending(at boundary: Double) -> SubtitleCue? {
        guard let start = intervalStart, start < boundary else { return nil }
        // `displayedSince` deliberately stays put: a boundary is a cut in the
        // rendition, not a caption command, and the screen it cuts across is
        // still showing what it was showing before.
        intervalStart = boundary
        return cue(from: start, to: boundary)
    }

    /// A seek: pre-seek screen contents must not bleed into the new position,
    /// and the open interval dies unwritten (its end lies in a region nobody
    /// is going to play through).
    func reanchor() {
        displayed.clear()
        nonDisplayed.clear()
        intervalStart = nil
        displayedSince = nil
        closed = []
    }

    // MARK: - The wire

    /// One parity-stripped byte pair addressed to this service.
    func ingest(control: (UInt8, UInt8)?, characters: (UInt8, UInt8)?, at seconds: Double) {
        if intervalStart == nil { intervalStart = seconds }
        if displayedSince == nil { displayedSince = seconds }
        if let control { apply(control: control, at: seconds) }
        if let characters {
            print(byte: characters.0)
            if characters.1 != 0 { print(byte: characters.1) }
        }
    }

    private func apply(control pair: (UInt8, UInt8), at seconds: Double) {
        // Bit 3 of the first byte picked the service; the command itself is the
        // same code with or without it, so it is normalised away here. 0x15 is
        // 0x14's twin for the same reason.
        var command = pair.0 & ~UInt8(0x08)
        let operand = pair.1
        // 0x15 is 0x14's alternate for the miscellaneous commands — but ONLY
        // for those. With an operand of 0x40 or more the same byte is a
        // preamble address code for rows 5 and 6, and folding it into 0x14
        // would move every one of those captions to row 14.
        if command == 0x15, (0x20...0x2F).contains(operand) { command = 0x14 }

        switch (command, operand) {
        case (0x14, 0x20):  // RCL — resume caption loading: pop-on
            mode = .popOn
        case (0x14, 0x21):  // BS — backspace
            cursorColumn = max(0, cursorColumn - 1)
            writingScreen { $0.write(" ", row: cursorRow, column: cursorColumn) }
        case (0x14, 0x24):  // DER — delete to end of row
            writingScreen { $0.clearToEndOfRow(cursorRow, from: cursorColumn) }
        case (0x14, 0x25), (0x14, 0x26), (0x14, 0x27):  // RU2 / RU3 / RU4
            let rows = Int(operand - 0x23)
            // A mode switch into roll-up clears the screen: the pop-on caption
            // standing there belongs to a style that just ended.
            if case .rollUp = mode {} else {
                closeInterval(at: seconds)
                displayed.clear()
                nonDisplayed.clear()
            }
            mode = .rollUp(windowRows: rows)
            rollUpBaseRow = cursorRow
            cursorColumn = 0
        case (0x14, 0x29):  // RDC — resume direct captioning: paint-on
            mode = .paintOn
        case (0x14, 0x2C):  // EDM — erase displayed memory
            closeInterval(at: seconds)
            displayed.clear()
        case (0x14, 0x2D):  // CR — carriage return (roll-up scroll)
            guard case .rollUp(let windowRows) = mode else { break }
            closeInterval(at: seconds)
            displayed.rollUp(baseRow: rollUpBaseRow, windowRows: windowRows)
            cursorRow = rollUpBaseRow
            cursorColumn = 0
        case (0x14, 0x2E):  // ENM — erase non-displayed memory
            nonDisplayed.clear()
        case (0x14, 0x2F):  // EOC — end of caption: the pop-on flip
            closeInterval(at: seconds)
            swap(&displayed, &nonDisplayed)
            mode = .popOn
        case (0x17, 0x21), (0x17, 0x22), (0x17, 0x23):  // tab offset 1…3
            cursorColumn = min(CEA608.columnCount - 1, cursorColumn + Int(operand - 0x20))
        case (0x11, 0x20...0x2F):
            // Mid-row style change. The code itself occupies a cell as a
            // space, which is why the styling can be dropped but the cell
            // cannot — losing it closes up the gap between two words.
            print(character: " ")
        case (0x11, 0x30...0x3F):
            print(character: Self.specialNorthAmerican[Int(operand - 0x30)])
        case (0x12, 0x20...0x3F):
            printExtended(Self.extendedSpanishFrench[Int(operand - 0x20)])
        case (0x13, 0x20...0x3F):
            printExtended(Self.extendedPortugueseGerman[Int(operand - 0x20)])
        default:
            // Preamble Address Code: row, and either an indent or a style.
            if (0x10...0x17).contains(command), (0x40...0x7F).contains(operand) {
                applyPreamble(command: command, operand: operand)
            }
            // Everything else — flash on, text-mode restart, the reserved
            // codes — is deliberately inert. A command we do not model must
            // not move the cursor by accident.
        }
    }

    private func applyPreamble(command: UInt8, operand: UInt8) {
        guard let row = Self.preambleRow(command: command, operand: operand) else { return }
        cursorRow = row
        if case .rollUp(let windowRows) = mode {
            // In roll-up a PAC moves the whole window, not the cursor within
            // it: the base row is where the text lands, where CR scrolls, and
            // where the rows already rolled up have to follow.
            displayed.moveWindow(fromBase: rollUpBaseRow, toBase: row, windowRows: windowRows)
            rollUpBaseRow = row
        }
        // Bit 4 set means the code carries an indent instead of a colour.
        cursorColumn = operand & 0x10 != 0 ? Int((operand >> 1) & 0x07) * 4 : 0
    }

    /// The PAC row table. Not derivable — it is a lookup the standard simply
    /// states, and the rows are deliberately out of numeric order.
    static func preambleRow(command: UInt8, operand: UInt8) -> Int? {
        let lower: Int
        let upper: Int
        switch command {
        case 0x11: (lower, upper) = (1, 2)
        case 0x12: (lower, upper) = (3, 4)
        case 0x15: (lower, upper) = (5, 6)
        case 0x16: (lower, upper) = (7, 8)
        case 0x17: (lower, upper) = (9, 10)
        case 0x10: (lower, upper) = (11, 11)
        case 0x13: (lower, upper) = (12, 13)
        case 0x14: (lower, upper) = (14, 15)
        default: return nil
        }
        return (operand & 0x20 != 0 ? upper : lower) - 1
    }

    // MARK: - Printing

    private func print(byte: UInt8) {
        guard byte >= 0x20 else { return }
        print(character: Self.basicNorthAmerican[Int(byte - 0x20)])
    }

    /// An extended character is transmitted *after* a plain stand-in that
    /// non-extended decoders display instead, so it replaces the cell before
    /// the cursor rather than taking a new one.
    private func printExtended(_ character: Character) {
        cursorColumn = max(0, cursorColumn - 1)
        print(character: character)
    }

    private func print(character: Character) {
        hasPrintedText = hasPrintedText || character != " "
        writingScreen { $0.write(character, row: cursorRow, column: cursorColumn) }
        cursorColumn = min(CEA608.columnCount - 1, cursorColumn + 1)
    }

    /// Pop-on builds behind the screen; roll-up and paint-on write on it.
    private func writingScreen(_ body: (inout CEA608.Screen) -> Void) {
        if case .popOn = mode {
            body(&nonDisplayed)
        } else {
            body(&displayed)
        }
    }

    // MARK: - Intervals

    /// The screen contents held during `[intervalStart, seconds)` become a cue,
    /// and a fresh interval opens. Called only by the commands that replace
    /// what is on screen — see the type comment for why printing does not.
    private func closeInterval(at seconds: Double) {
        if let start = intervalStart, let cue = cue(from: start, to: seconds) {
            closed.append(cue)
        }
        intervalStart = seconds
        // This is a wholesale display change, so the caption's allowance starts
        // here — unlike a segment split, which leaves it where it was.
        displayedSince = seconds
    }

    private func cue(from start: Double, to end: Double) -> SubtitleCue? {
        let text = TextSubtitleConverter.sanitize(displayed.text)
        guard !text.isEmpty else { return nil }
        // Capped, not dropped: a caption whose erase never arrives is still a
        // caption, it just must not outstay the scene it belongs to. The
        // allowance runs from when the caption was displayed, never from the
        // interval — see `displayedSince` for what measuring it from the
        // interval did.
        let expiry = (displayedSince ?? start) + Self.maximumCueSeconds
        let cappedEnd = min(end, expiry)
        guard cappedEnd > start else { return nil }
        return SubtitleCue(start: start, end: cappedEnd, text: text)
    }

    // MARK: - Character sets

    /// The basic set, indexed from 0x20. ASCII except for the ten cells the
    /// standard spends on accented Spanish and a solid block.
    static let basicNorthAmerican: [Character] = {
        var table: [Character] = (0x20...0x7F).map { Character(UnicodeScalar($0)!) }
        let overrides: [(Int, Character)] = [
            (0x2A, "á"), (0x5C, "é"), (0x5E, "í"), (0x5F, "ó"), (0x60, "ú"),
            (0x7B, "ç"), (0x7C, "÷"), (0x7D, "Ñ"), (0x7E, "ñ"), (0x7F, "█"),
        ]
        for (code, character) in overrides { table[code - 0x20] = character }
        return table
    }()

    /// 0x11 0x30…0x3F. 0x39 is the "transparent space", which is a space that
    /// does not overwrite — close enough to a space that the difference has
    /// never been visible in a WebVTT rendering.
    static let specialNorthAmerican: [Character] = [
        "®", "°", "½", "¿", "™", "¢", "£", "♪",
        "à", " ", "è", "â", "ê", "î", "ô", "û",
    ]

    /// 0x12 0x20…0x3F.
    static let extendedSpanishFrench: [Character] = [
        "Á", "É", "Ó", "Ú", "Ü", "ü", "´", "¡",
        "*", "'", "—", "©", "℠", "•", "“", "”",
        "À", "Â", "Ç", "È", "Ê", "Ë", "ë", "Î",
        "Ï", "ï", "Ô", "Ù", "ù", "Û", "«", "»",
    ]

    /// 0x13 0x20…0x3F.
    static let extendedPortugueseGerman: [Character] = [
        "Ã", "ã", "Í", "Ì", "ì", "Ò", "ò", "Õ",
        "õ", "{", "}", "\\", "^", "_", "|", "~",
        "Ä", "ä", "Ö", "ö", "ß", "¥", "¤", "│",
        "Å", "å", "Ø", "ø", "┌", "┐", "└", "┘",
    ]
}

/// One 608 field and the two services interleaved on it.
///
/// The field is the decodable unit, not the channel: a byte pair carries no
/// service of its own, it goes to whichever service the last control code on
/// this field named.
final class CEA608FieldDecoder {

    /// Index 0 is the field's first service (CC1 or CC3), index 1 its second
    /// (CC2 or CC4).
    let channels = [CEA608ChannelDecoder(), CEA608ChannelDecoder()]
    private var currentChannel = 0
    /// Control codes are transmitted twice so a dropped field can be survived.
    /// Acting on both would erase twice, scroll twice, or print two spaces.
    private var lastControl: (UInt8, UInt8)?

    /// Whether this field can carry XDS. Only field 2 does; on field 1 the
    /// `0x01…0x0F` pairs are simply not printable and need no packet state.
    private let carriesXDS: Bool

    /// Whether an XDS packet is currently open on this field.
    ///
    /// XDS — programme name, rating, time of day — shares field 2 with CC3 and
    /// CC4, and **only its framing pairs are outside the printable range**. The
    /// payload between them is ordinary text. Judging each pair on its own,
    /// which this used to do, therefore rejected the brackets and fed the
    /// programme name straight into the caption memory a viewer is reading. An
    /// XDS packet is state, not a property of a pair: once it opens, every pair
    /// belongs to it until `0x0F` closes it or a caption control code takes the
    /// field back.
    private var inXDSPacket = false

    init(carriesXDS: Bool) {
        self.carriesXDS = carriesXDS
    }

    /// One `cc_data` byte pair, already known to belong to this field.
    func ingest(_ data0: UInt8, _ data1: UInt8, at seconds: Double) {
        // Parity is stripped rather than checked. The bytes reached us inside
        // an SEI message in a container with its own integrity, so a parity
        // failure here means an encoder that set the bit wrong far more often
        // than it means a corrupted byte — and dropping a valid control code
        // costs a whole caption, where accepting a corrupt one costs a glyph.
        let byte0 = data0 & 0x7F
        let byte1 = data1 & 0x7F

        // Padding. Also the shape XDS and the DTVCC types leave behind.
        if byte0 == 0 && byte1 == 0 { return }

        if (0x10...0x1F).contains(byte0) {
            // A caption control code takes the field back mid-packet. The
            // standard allows that and real broadcast relies on it: XDS is
            // transmitted in the gaps between captions, and the remainder of an
            // interrupted packet arrives later under a continuation class code.
            // Suppressing until `0x0F` regardless would swallow every caption
            // after the first packet a caption ever interrupted.
            inXDSPacket = false
            if let last = lastControl, last == (byte0, byte1) {
                // Consumed: a third transmission of the same pair is a new
                // command, not a repeat, so the memory is cleared rather than
                // kept.
                lastControl = nil
                return
            }
            lastControl = (byte0, byte1)
            currentChannel = byte0 & 0x08 != 0 ? 1 : 0
            channels[currentChannel].ingest(
                control: (byte0, byte1), characters: nil, at: seconds
            )
            return
        }

        lastControl = nil
        if carriesXDS {
            // 0x01…0x0E open (odd class) or continue (even class) an XDS
            // packet; 0x0F ends it and carries the checksum.
            if (0x01...0x0E).contains(byte0) {
                inXDSPacket = true
                return
            }
            if byte0 == 0x0F {
                inXDSPacket = false
                return
            }
            // Printable, but claimed: it is this packet's payload, not caption
            // text. See `inXDSPacket`.
            if inXDSPacket { return }
        }
        // A byte below 0x20 that is not a control code is not printable.
        guard byte0 >= 0x20 else { return }
        channels[currentChannel].ingest(
            control: nil, characters: (byte0, byte1), at: seconds
        )
    }

    func splitPending(at boundary: Double) -> [(channel: Int, cue: SubtitleCue)] {
        channels.enumerated().compactMap { index, channel in
            channel.splitPending(at: boundary).map { (index, $0) }
        }
    }

    func reanchor() {
        for channel in channels { channel.reanchor() }
        lastControl = nil
        inXDSPacket = false
    }
}
