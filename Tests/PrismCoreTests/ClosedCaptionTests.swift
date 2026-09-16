import Testing
import Foundation
import Libavcodec
@testable import PrismCore

/// Embedded CEA-608 closed captions: the SEI carriage, the terminal, and the
/// reordering that stands between the two.
///
/// Every fixture here is synthesised, because there is no other way: no FFmpeg
/// build can *encode* A/53 caption SEI, so a committable media file carrying
/// known caption bytes does not exist. What can be built exactly is the
/// bitstream — a real H.264 Annex-B access unit with a real SEI message inside
/// it — which is what `CaptionFixture` writes.
@Suite("Closed captions")
struct ClosedCaptionTests {

    // MARK: - Fixtures

    /// Builds the bytes a captioned encoder would have produced.
    enum CaptionFixture {

        /// One `cc_data` entry: which wire, and the two caption bytes.
        struct Triplet {
            var type: UInt8 = 0  // NTSC field 1
            var byte0: UInt8
            var byte1: UInt8

            /// 608 bytes travel with odd parity in bit 7. The decoder strips
            /// it rather than checking it, and these fixtures set it so that
            /// the stripping is what is being exercised, not bypassed.
            var withParity: (UInt8, UInt8) { (Self.oddParity(byte0), Self.oddParity(byte1)) }

            static func oddParity(_ byte: UInt8) -> UInt8 {
                let value = byte & 0x7F
                return value.nonzeroBitCount % 2 == 0 ? value | 0x80 : value
            }
        }

        static func pair(_ byte0: UInt8, _ byte1: UInt8) -> Triplet {
            Triplet(byte0: byte0, byte1: byte1)
        }

        /// Two ASCII characters as one 608 byte pair.
        static func text(_ characters: String) -> [Triplet] {
            let bytes = Array(characters.utf8)
            return stride(from: 0, to: bytes.count, by: 2).map { index in
                Triplet(byte0: bytes[index], byte1: index + 1 < bytes.count ? bytes[index + 1] : 0)
            }
        }

        /// The ATSC A/53 user-data payload of an SEI `user_data_registered`
        /// message.
        static func t35Payload(_ triplets: [Triplet]) -> [UInt8] {
            var payload: [UInt8] = [
                0xB5,              // itu_t_t35_country_code: USA
                0x00, 0x31,        // terminal provider code
                0x47, 0x41, 0x39, 0x34,  // "GA94"
                0x03,              // user_data_type_code: cc_data
            ]
            // process_cc_data_flag set, cc_count in the low five bits.
            payload.append(0x40 | UInt8(triplets.count & 0x1F))
            payload.append(0xFF)  // em_data, never used by anything
            for triplet in triplets {
                let (byte0, byte1) = triplet.withParity
                // marker bits 11111, cc_valid = 1, then cc_type.
                payload.append(0xF8 | 0x04 | (triplet.type & 0x03))
                payload.append(byte0)
                payload.append(byte1)
            }
            return payload
        }

        /// One SEI NAL's RBSP: message header, payload, stop bit.
        static func seiRBSP(payloadType: Int, payload: [UInt8]) -> [UInt8] {
            var rbsp: [UInt8] = []
            var type = payloadType
            while type >= 255 { rbsp.append(0xFF); type -= 255 }
            rbsp.append(UInt8(type))
            var size = payload.count
            while size >= 255 { rbsp.append(0xFF); size -= 255 }
            rbsp.append(UInt8(size))
            rbsp += payload
            rbsp.append(0x80)  // rbsp_trailing_bits
            return rbsp
        }

        /// Insert `emulation_prevention_three_byte` wherever the bitstream
        /// would otherwise contain a start code.
        static func escaped(_ rbsp: [UInt8]) -> [UInt8] {
            var output: [UInt8] = []
            var zeroRun = 0
            for byte in rbsp {
                if zeroRun >= 2 && byte <= 0x03 {
                    output.append(0x03)
                    zeroRun = 0
                }
                zeroRun = byte == 0 ? zeroRun + 1 : 0
                output.append(byte)
            }
            return output
        }

        /// An H.264 access unit in Annex-B carriage: a stub slice NAL, then the
        /// caption SEI. Deliberately not SEI-first — the walk must find it
        /// wherever the encoder put it.
        static func h264AnnexB(_ triplets: [Triplet], payloadType: Int = 4) -> [UInt8] {
            var packet: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84, 0x00, 0x21]
            packet += [0x00, 0x00, 0x01, 0x06]
            packet += escaped(seiRBSP(payloadType: payloadType, payload: t35Payload(triplets)))
            return packet
        }

        /// The same message in an HEVC prefix SEI, length-prefixed the way the
        /// mov and matroska demuxers hand packets over.
        static func hevcLengthPrefixed(_ triplets: [Triplet]) -> [UInt8] {
            // nal_unit_type 39 (prefix SEI) in bits 6…1 of the first header byte.
            var nal: [UInt8] = [39 << 1, 0x01]
            nal += escaped(seiRBSP(payloadType: 4, payload: t35Payload(triplets)))
            var packet: [UInt8] = []
            for shift in stride(from: 24, through: 0, by: -8) {
                packet.append(UInt8((nal.count >> shift) & 0xFF))
            }
            return packet + nal
        }
    }

    /// Feed a reader one packet's worth of caption bytes at a given
    /// presentation time.
    private func ingest(
        _ reader: ClosedCaptionReader,
        _ triplets: [CaptionFixture.Triplet],
        at seconds: Double
    ) {
        let packet = CaptionFixture.h264AnnexB(triplets)
        packet.withUnsafeBufferPointer { reader.ingest($0, presentationSeconds: seconds) }
    }

    private func makeReader() -> ClosedCaptionReader {
        ClosedCaptionReader(framing: .annexB, codec: .h264)
    }

    // Control codes, by the names the standard gives them.
    private static let resumeCaptionLoading = CaptionFixture.pair(0x14, 0x20)
    private static let eraseNonDisplayed = CaptionFixture.pair(0x14, 0x2E)
    private static let endOfCaption = CaptionFixture.pair(0x14, 0x2F)
    private static let eraseDisplayed = CaptionFixture.pair(0x14, 0x2C)
    private static let carriageReturn = CaptionFixture.pair(0x14, 0x2D)
    private static let rollUpTwoRows = CaptionFixture.pair(0x14, 0x25)
    /// Preamble address code for row 15, column 0.
    private static let addressRow15 = CaptionFixture.pair(0x14, 0x60)
    /// Preamble address code for row 1, column 0.
    private static let addressRow1 = CaptionFixture.pair(0x11, 0x40)
    /// Preamble address code for row 4, column 0 — high enough on the screen to
    /// hold a two-row roll-up window.
    private static let addressRow4 = CaptionFixture.pair(0x12, 0x60)

    // MARK: - Carriage

    @Test("A/53 cc_data is found in an H.264 Annex-B access unit")
    func extractsFromAnnexB() {
        let packet = CaptionFixture.h264AnnexB([CaptionFixture.pair(0x14, 0x2F)])
        let triplets = packet.withUnsafeBufferPointer {
            A53CaptionData.triplets(in: $0, framing: .annexB, codec: .h264)
        }
        #expect(triplets.count == 1)
        #expect(triplets.first?.isValid == true)
        #expect(triplets.first?.cea608Field == 1)
        #expect(triplets.first?.data0 == CaptionFixture.Triplet.oddParity(0x14))
    }

    @Test("A/53 cc_data is found in a length-prefixed HEVC packet")
    func extractsFromLengthPrefixedHEVC() {
        let packet = CaptionFixture.hevcLengthPrefixed([
            CaptionFixture.pair(0x14, 0x2F), CaptionFixture.Triplet(type: 1, byte0: 0x14, byte1: 0x2F),
        ])
        let triplets = packet.withUnsafeBufferPointer {
            A53CaptionData.triplets(in: $0, framing: .lengthPrefixed(4), codec: .hevc)
        }
        #expect(triplets.count == 2)
        #expect(triplets.map(\.cea608Field) == [1, 2])
    }

    /// The registration fields are the only thing separating caption user data
    /// from Dolby's, HDR10+'s, or an encoder's watermark — all of which are SEI
    /// payload type 4 as well.
    @Test("User data that is not ATSC's is left alone")
    func ignoresForeignUserData() {
        var payload = CaptionFixture.t35Payload([CaptionFixture.pair(0x14, 0x2F)])
        payload[3] = 0x44  // "DA94" — not GA94
        var packet: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x06]
        packet += CaptionFixture.escaped(
            CaptionFixture.seiRBSP(payloadType: 4, payload: payload)
        )
        let triplets = packet.withUnsafeBufferPointer {
            A53CaptionData.triplets(in: $0, framing: .annexB, codec: .h264)
        }
        #expect(triplets.isEmpty)
    }

    @Test("An SEI message of another type carries no captions")
    func ignoresOtherSEIPayloadTypes() {
        // Payload type 5 is unregistered user data: same shape, not ours.
        let packet = CaptionFixture.h264AnnexB([CaptionFixture.pair(0x14, 0x2F)], payloadType: 5)
        let triplets = packet.withUnsafeBufferPointer {
            A53CaptionData.triplets(in: $0, framing: .annexB, codec: .h264)
        }
        #expect(triplets.isEmpty)
    }

    /// A caption byte pair of `00 00` would be written into the bitstream as
    /// `00 00 03`; read back without unescaping, every field after it shifts.
    @Test("Emulation prevention bytes are removed before the message is read")
    func removesEmulationPrevention() {
        let triplets = [
            CaptionFixture.Triplet(byte0: 0x00, byte1: 0x00),
            CaptionFixture.pair(0x14, 0x2F),
        ]
        let packet = CaptionFixture.h264AnnexB(triplets)
        // The fixture really does need escaping, or this test proves nothing.
        #expect(packet.contains(0x03))
        let decoded = packet.withUnsafeBufferPointer {
            A53CaptionData.triplets(in: $0, framing: .annexB, codec: .h264)
        }
        #expect(decoded.count == 2)
        #expect(decoded.last?.data1 == CaptionFixture.Triplet.oddParity(0x2F))
    }

    // MARK: - Pop-on

    @Test("A pop-on caption starts at the flip and ends at the erase")
    func popOnCaptionSpansFlipToErase() {
        let reader = makeReader()
        ingest(reader, [
            Self.resumeCaptionLoading, Self.eraseNonDisplayed, Self.addressRow15,
        ] + CaptionFixture.text("HI"), at: 1.0)
        ingest(reader, [Self.endOfCaption], at: 1.5)
        ingest(reader, [Self.eraseDisplayed], at: 4.0)

        let cues = reader.flush(at: 10.0)
        #expect(cues.count == 1)
        #expect(cues.first?.channel == 1)
        #expect(cues.first?.cue.text == "HI")
        // Source seconds, the same axis `TextSubtitleConverter` puts a text
        // cue's start on and the axis the WebVTT writer rebases from.
        #expect(cues.first?.cue.start == 1.5)
        #expect(cues.first?.cue.end == 4.0)
    }

    /// The flip is the only moment a pop-on caption becomes visible. Emitting
    /// it when the characters arrive would put every caption on screen while it
    /// was still being written behind the scenes.
    @Test("Text written before the flip is not yet a cue")
    func popOnTextIsInvisibleUntilTheFlip() {
        let reader = makeReader()
        ingest(reader, [
            Self.resumeCaptionLoading, Self.addressRow15,
        ] + CaptionFixture.text("HI"), at: 1.0)
        ingest(reader, [Self.eraseDisplayed], at: 2.0)
        #expect(reader.flush(at: 3.0).isEmpty)
    }

    @Test("A second flip ends the caption before it")
    func popOnFlipEndsThePreviousCaption() {
        let reader = makeReader()
        ingest(reader, [Self.resumeCaptionLoading, Self.addressRow15] + CaptionFixture.text("ON"), at: 0.5)
        ingest(reader, [Self.endOfCaption], at: 1.0)
        ingest(reader, [Self.resumeCaptionLoading, Self.eraseNonDisplayed, Self.addressRow15]
            + CaptionFixture.text("TW"), at: 1.2)
        ingest(reader, [Self.endOfCaption], at: 3.0)
        ingest(reader, [Self.eraseDisplayed], at: 5.0)

        let cues = reader.flush(at: 10.0)
        #expect(cues.map(\.cue.text) == ["ON", "TW"])
        #expect(cues.map(\.cue.start) == [1.0, 3.0])
        #expect(cues.map(\.cue.end) == [3.0, 5.0])
    }

    /// Two rows written through two preamble address codes must stay two rows.
    @Test("A preamble address code puts text on its own row")
    func preambleAddressCodesSeparateRows() {
        let reader = makeReader()
        ingest(reader, [Self.resumeCaptionLoading, Self.addressRow1] + CaptionFixture.text("UP")
            + [Self.addressRow15] + CaptionFixture.text("DN"), at: 0.5)
        ingest(reader, [Self.endOfCaption], at: 1.0)
        ingest(reader, [Self.eraseDisplayed], at: 2.0)
        #expect(reader.flush(at: 3.0).first?.cue.text == "UP\nDN")
    }

    /// 0x15 is the miscellaneous-command byte *and* the row 5/6 address code.
    /// Folding the two together put every row-5 caption on row 14.
    @Test("Row 5 is addressed by the byte that also carries the erase commands")
    func rowFiveAddressIsNotAMiscellaneousCommand() {
        #expect(CEA608ChannelDecoder.preambleRow(command: 0x15, operand: 0x40) == 4)
        #expect(CEA608ChannelDecoder.preambleRow(command: 0x15, operand: 0x60) == 5)
        #expect(CEA608ChannelDecoder.preambleRow(command: 0x14, operand: 0x60) == 14)
    }

    // MARK: - Roll-up

    @Test("Roll-up emits a row per carriage return and scrolls the window")
    func rollUpEmitsPerCarriageReturn() {
        let reader = makeReader()
        ingest(reader, [Self.rollUpTwoRows, Self.addressRow15], at: 0.0)
        ingest(reader, CaptionFixture.text("AA"), at: 0.5)
        ingest(reader, [Self.carriageReturn], at: 2.0)
        ingest(reader, CaptionFixture.text("BB"), at: 2.5)
        ingest(reader, [Self.carriageReturn], at: 4.0)
        ingest(reader, [Self.eraseDisplayed], at: 6.0)

        let cues = reader.flush(at: 10.0)
        // The completed row is visible from the moment its first character
        // appeared — see `CEA608` on why the alternative is one cue per glyph.
        #expect(cues.map(\.cue.text) == ["AA", "AA\nBB", "BB"])
        #expect(cues.map(\.cue.start) == [0.0, 2.0, 4.0])
        #expect(cues.map(\.cue.end) == [2.0, 4.0, 6.0])
    }

    /// A roll-up preamble moves the whole window, so the scroll has to follow
    /// it — against the old base row, the text scrolls out from under itself.
    @Test("A base-row change moves the roll-up window")
    func rollUpBaseRowChangeMovesTheWindow() {
        let reader = makeReader()
        ingest(reader, [Self.rollUpTwoRows, Self.addressRow15], at: 0.0)
        ingest(reader, CaptionFixture.text("AA"), at: 0.2)
        ingest(reader, [Self.carriageReturn], at: 1.0)
        // The encoder lifts the window up the screen mid-programme, which real
        // broadcast does whenever the lower third is busy. The row already
        // rolled up has to travel with it.
        ingest(reader, [Self.addressRow4] + CaptionFixture.text("BB"), at: 1.2)
        ingest(reader, [Self.carriageReturn], at: 2.0)
        ingest(reader, CaptionFixture.text("CC"), at: 2.2)
        ingest(reader, [Self.eraseDisplayed], at: 3.0)

        let cues = reader.flush(at: 5.0)
        #expect(cues.map(\.cue.text) == ["AA", "AA\nBB", "BB\nCC"])
        #expect(cues.map(\.cue.start) == [0.0, 1.0, 2.0])
    }

    /// Switching out of pop-on has to take the pop-on caption off the screen:
    /// it belongs to a style that just ended.
    @Test("Entering roll-up clears the pop-on caption standing on screen")
    func rollUpClearsAPopOnCaption() {
        let reader = makeReader()
        ingest(reader, [Self.resumeCaptionLoading, Self.addressRow15] + CaptionFixture.text("OL"), at: 0.5)
        ingest(reader, [Self.endOfCaption], at: 1.0)
        ingest(reader, [Self.rollUpTwoRows, Self.addressRow15], at: 2.0)
        ingest(reader, CaptionFixture.text("NW"), at: 2.5)
        ingest(reader, [Self.carriageReturn], at: 3.0)

        let cues = reader.flush(at: 4.0)
        // "OL" ends the instant roll-up begins. "NW" appears twice because it
        // genuinely is on screen twice: once as the row being typed, and again
        // after the carriage return rolled it up a line, where it stays.
        #expect(cues.map(\.cue.text) == ["OL", "NW", "NW"])
        #expect(cues.map(\.cue.start) == [1.0, 2.0, 3.0])
        #expect(cues.first?.cue.end == 2.0)
    }

    // MARK: - Character sets

    @Test("A special character decodes, and replaces nothing")
    func specialCharacterDecodes() {
        let reader = makeReader()
        // 0x11 0x37 is the eighth-note, which captioned music cues are full of.
        ingest(reader, [Self.resumeCaptionLoading, Self.addressRow15,
                        CaptionFixture.pair(0x11, 0x37)] + CaptionFixture.text("AB"), at: 0.5)
        ingest(reader, [Self.endOfCaption], at: 1.0)
        ingest(reader, [Self.eraseDisplayed], at: 2.0)
        #expect(reader.flush(at: 3.0).first?.cue.text == "♪AB")
    }

    /// An extended character is transmitted after a plain stand-in for decoders
    /// that cannot render it. Ours can, so the stand-in has to be overwritten —
    /// left in place, every accented word gains a letter.
    @Test("An extended character replaces the stand-in before it")
    func extendedCharacterReplacesTheStandIn() {
        let reader = makeReader()
        ingest(reader, [Self.resumeCaptionLoading, Self.addressRow15]
            + CaptionFixture.text("AE")                      // the stand-in "E"
            + [CaptionFixture.pair(0x12, 0x21)], at: 0.5)     // extended "É"
        ingest(reader, [Self.endOfCaption], at: 1.0)
        ingest(reader, [Self.eraseDisplayed], at: 2.0)
        #expect(reader.flush(at: 3.0).first?.cue.text == "AÉ")
    }

    @Test("The basic character set substitutes where the standard says it does")
    func basicCharacterSetSubstitutions() {
        #expect(CEA608ChannelDecoder.basicNorthAmerican[0x41 - 0x20] == "A")
        #expect(CEA608ChannelDecoder.basicNorthAmerican[0x2A - 0x20] == "á")
        #expect(CEA608ChannelDecoder.basicNorthAmerican[0x5C - 0x20] == "é")
        #expect(CEA608ChannelDecoder.basicNorthAmerican[0x7E - 0x20] == "ñ")
    }

    // MARK: - Transmission

    /// Control codes are sent twice on purpose. Acting on both erases twice,
    /// scrolls twice, and loses a row of roll-up per carriage return.
    @Test("A doubled control code is acted on once")
    func doubledControlCodeIsActedOnOnce() {
        let reader = makeReader()
        ingest(reader, [Self.rollUpTwoRows, Self.rollUpTwoRows, Self.addressRow15], at: 0.0)
        ingest(reader, CaptionFixture.text("AA"), at: 0.5)
        ingest(reader, [Self.carriageReturn, Self.carriageReturn], at: 1.0)
        ingest(reader, CaptionFixture.text("BB"), at: 1.5)
        ingest(reader, [Self.eraseDisplayed], at: 2.0)

        let cues = reader.flush(at: 3.0)
        // One scroll, so "AA" is still in the window above "BB". Two scrolls
        // would have pushed it out of a two-row window.
        #expect(cues.map(\.cue.text) == ["AA", "AA\nBB"])
    }

    /// CC2 shares field 1 with CC1; the service is chosen by one bit of the
    /// control code, and characters follow whichever was named last.
    @Test("The second service of a field is decoded separately")
    func secondChannelOfAFieldIsSeparate() {
        let reader = makeReader()
        // 0x1C is 0x14 with the channel bit set: the same commands, on CC2.
        ingest(reader, [
            Self.resumeCaptionLoading, Self.addressRow15,
        ] + CaptionFixture.text("EN") + [
            CaptionFixture.pair(0x1C, 0x20), CaptionFixture.pair(0x1C, 0x60),
        ] + CaptionFixture.text("ES"), at: 0.5)
        ingest(reader, [Self.endOfCaption, CaptionFixture.pair(0x1C, 0x2F)], at: 1.0)
        ingest(reader, [Self.eraseDisplayed, CaptionFixture.pair(0x1C, 0x2C)], at: 2.0)

        let cues = reader.flush(at: 3.0)
        #expect(cues.count == 2)
        #expect(cues.first(where: { $0.channel == 1 })?.cue.text == "EN")
        #expect(cues.first(where: { $0.channel == 2 })?.cue.text == "ES")
    }

    /// Field 2's services are CC3 and CC4 — the usual home of a Spanish track.
    @Test("Field 2 decodes as CC3")
    func secondFieldIsChannelThree() {
        let reader = makeReader()
        func field2(_ pairs: [CaptionFixture.Triplet]) -> [CaptionFixture.Triplet] {
            pairs.map { CaptionFixture.Triplet(type: 1, byte0: $0.byte0, byte1: $0.byte1) }
        }
        ingest(reader, field2([Self.resumeCaptionLoading, Self.addressRow15]
            + CaptionFixture.text("ES")), at: 0.5)
        ingest(reader, field2([Self.endOfCaption]), at: 1.0)
        ingest(reader, field2([Self.eraseDisplayed]), at: 2.0)

        let cues = reader.flush(at: 3.0)
        #expect(cues.map(\.channel) == [3])
        #expect(cues.first?.cue.text == "ES")
    }

    /// CEA-708 is deliberately not decoded. What matters is that its presence
    /// changes nothing about the 608 bytes travelling beside it.
    @Test("DTVCC triplets are skipped without disturbing the 608 decode")
    func dtvccTripletsAreSkipped() {
        let reader = makeReader()
        let dtvcc = CaptionFixture.Triplet(type: 3, byte0: 0x21, byte1: 0x42)
        ingest(reader, [dtvcc, Self.resumeCaptionLoading, Self.addressRow15]
            + CaptionFixture.text("HI") + [dtvcc], at: 0.5)
        ingest(reader, [Self.endOfCaption], at: 1.0)
        ingest(reader, [Self.eraseDisplayed], at: 2.0)
        #expect(reader.flush(at: 3.0).first?.cue.text == "HI")
    }

    // MARK: - Decode order

    /// The trap this whole reader exists for. `av_read_frame` hands packets
    /// over in decode order; on a stream with B-frames the erase can be read
    /// *before* the flip it is meant to end. Decoded in that order the caption
    /// never closes, and the text on screen is a caption behind.
    @Test("Caption bytes are reordered from decode order to presentation order")
    func decodeOrderIsReorderedToPresentationOrder() {
        let reader = makeReader()
        // Decode order I, P, B — presentation order 0.0, 0.3, 0.4.
        ingest(reader, [Self.resumeCaptionLoading, Self.addressRow15]
            + CaptionFixture.text("AB"), at: 0.0)
        ingest(reader, [Self.eraseDisplayed], at: 0.4)   // the P frame, read second
        ingest(reader, [Self.endOfCaption], at: 0.3)     // the B frame, read third

        let cues = reader.flush(at: 1.0)
        #expect(cues.count == 1)
        #expect(cues.first?.cue.text == "AB")
        #expect(cues.first?.cue.start == 0.3)
        #expect(cues.first?.cue.end == 0.4)
    }

    /// The window has to hold at least a stream's reorder depth, or a
    /// late-arriving frame is decoded after the frames that follow it.
    @Test("The reorder window is at least H.264's maximum reorder depth")
    func reorderWindowCoversTheWorstCase() {
        #expect(ClosedCaptionReader.maximumReorderDepth >= 16)
    }

    // MARK: - Segment boundaries and end of stream

    /// A rendition is cut on the video's segment boundaries, and a cue only
    /// reaches the file it overlaps — so a caption standing across a cut has to
    /// become a cue on both sides of it.
    @Test("A caption standing across a segment boundary is split at the cut")
    func captionIsSplitAtASegmentBoundary() {
        let reader = makeReader()
        ingest(reader, [Self.resumeCaptionLoading, Self.addressRow15] + CaptionFixture.text("HI"), at: 0.5)
        ingest(reader, [Self.endOfCaption], at: 1.0)

        let atBoundary = reader.advance(to: 6.0)
        #expect(atBoundary.map(\.cue.text) == ["HI"])
        #expect(atBoundary.first?.cue.start == 1.0)
        #expect(atBoundary.first?.cue.end == 6.0)

        ingest(reader, [Self.eraseDisplayed], at: 8.0)
        let rest = reader.flush(at: 12.0)
        #expect(rest.map(\.cue.text) == ["HI"])
        #expect(rest.first?.cue.start == 6.0)
        #expect(rest.first?.cue.end == 8.0)
    }

    /// An open-ended last cue sits on screen forever. The bitmap path caps one
    /// at ten seconds; a caption whose erase never comes is capped the same way.
    @Test("A caption whose erase never arrives is capped, not left open")
    func unterminatedCaptionIsCapped() {
        let reader = makeReader()
        ingest(reader, [Self.resumeCaptionLoading, Self.addressRow15] + CaptionFixture.text("HI"), at: 0.5)
        ingest(reader, [Self.endOfCaption], at: 1.0)

        let cues = reader.flush(at: 600.0)
        #expect(cues.count == 1)
        #expect(cues.first?.cue.start == 1.0)
        #expect(cues.first?.cue.end == 1.0 + CEA608ChannelDecoder.maximumCueSeconds)
    }

    /// A demand-driven seek re-reads a different region: the screen and the
    /// reorder window both belong to where the producer *was*.
    @Test("A re-anchor drops the pre-seek screen and the queued frames")
    func reanchorDropsPreSeekState() {
        let reader = makeReader()
        ingest(reader, [Self.resumeCaptionLoading, Self.addressRow15] + CaptionFixture.text("HI"), at: 0.5)
        ingest(reader, [Self.endOfCaption], at: 1.0)
        reader.reanchor()
        #expect(reader.flush(at: 5.0).isEmpty)
    }

    // MARK: - Renditions

    @Test("A caption rendition is labelled by channel, and by language when there is one")
    func renditionNaming() {
        #expect(ClosedCaptionReader.renditionName(channel: 1, language: nil) == "CC1")
        #expect(ClosedCaptionReader.renditionName(channel: 3, language: "eng") == "English (CC3)")
    }

    /// The scout picks the carriage from the extradata: no `avcC` means the
    /// packets arrive with Annex-B start codes, which is what MPEG-TS produces
    /// and what most captioned recordings are.
    @Test("Carriage is chosen by the presence of a configuration record")
    func carriageSelection() {
        let annexB = ClosedCaptionScout.carriage(codecID: AV_CODEC_ID_H264, nalUnitLengthSize: nil)
        #expect(annexB?.framing == .annexB)
        #expect(annexB?.codec == .h264)
        let lengthPrefixed = ClosedCaptionScout.carriage(codecID: AV_CODEC_ID_HEVC, nalUnitLengthSize: 4)
        #expect(lengthPrefixed?.framing == .lengthPrefixed(4))
        #expect(lengthPrefixed?.codec == .hevc)
        // A codec with no SEI to hide captions in is not scanned at all.
        #expect(ClosedCaptionScout.carriage(codecID: AV_CODEC_ID_VP9, nalUnitLengthSize: nil) == nil)
    }

    /// Cue text goes through the same sanitizer as every other subtitle source,
    /// because the 608 character set can spell `-->` and a cue that contains one
    /// ends the cue early.
    @Test("Caption text is WebVTT-safe")
    func captionTextIsWebVTTSafe() {
        let reader = makeReader()
        ingest(reader, [Self.resumeCaptionLoading, Self.addressRow15]
            + CaptionFixture.text("--> <b"), at: 0.5)
        ingest(reader, [Self.endOfCaption], at: 1.0)
        ingest(reader, [Self.eraseDisplayed], at: 2.0)
        let text = reader.flush(at: 3.0).first?.cue.text
        #expect(text != nil)
        #expect(text?.contains("-->") == false)
    }
}
