import Foundation

/// Hand-built **valid** inputs, one flavour per fuzz target, plus the
/// deterministic RNG/mutator both fuzzing shapes share.
///
/// Structure matters more than realism: a mutator flipping bytes in a valid
/// box tree explores the parser's deep branches, where the same flips in
/// random noise die at the first syncword. Each seed is asserted *accepted* by
/// its parser in `FuzzSmokeTests.seedsAreAccepted` — a corpus the parser
/// rejects at the first field exercises nothing, and that assertion is what
/// keeps the corpus honest as the parsers evolve.
package enum FuzzSeeds {

    /// Seeds per target name, keys matching `FuzzTargets.all`.
    package static let corpus: [String: [[UInt8]]] = [
        "eac3-syncframe": [[0x0B, 0x77] + Array(repeating: 0x00, count: 64), eac3LikeFrame],
        "dec3": [dec3Payload, audioInitSegment],
        "hevc-nalunits": [hevcPacket],
        "hvcc-normalize": [hvcCRecord, videoInitSegment],
        "isobmff-patch": [videoInitSegment, audioInitSegment],
        "text-subtitles": [
            Array(srtText.utf8), Array(vttText.utf8), Array(assEvent.utf8), tx3gSample,
        ],
    ]

    /// A `dec3` payload that declares the type-A extension — every field the
    /// parser walks, ending in `flag_ec3_extension_type_a = 1`, index 16.
    package static let dec3Payload: [UInt8] = {
        var writer = BitWriter()
        writer.write(448, bits: 13)  // data_rate
        writer.write(0, bits: 3)     // num_ind_sub - 1
        writer.write(0, bits: 2)     // fscod
        writer.write(16, bits: 5)    // bsid
        writer.write(0, bits: 1)     // reserved
        writer.write(0, bits: 1)     // asvc
        writer.write(0, bits: 3)     // bsmod
        writer.write(7, bits: 3)     // acmod 3/2
        writer.write(1, bits: 1)     // lfeon
        writer.write(0, bits: 3)     // reserved
        writer.write(0, bits: 4)     // num_dep_sub: none
        writer.write(0, bits: 1)     // reserved (no dependents)
        writer.write(0, bits: 7)     // reserved
        writer.write(1, bits: 1)     // flag_ec3_extension_type_a
        writer.write(16, bits: 8)    // complexity_index_type_a
        return writer.bytes
    }()

    /// An E-AC-3 syncframe whose BSI the JOC walk follows end to end, into an
    /// `addbsi` carrying the type-A extension. The optional blocks (mixing,
    /// informational metadata) are switched off here; they are reachable from
    /// this seed by single-bit mutations, which is what a seed is for.
    package static let eac3LikeFrame: [UInt8] = {
        var writer = BitWriter()
        writer.write(0x0B77, bits: 16)  // syncword
        writer.write(0, bits: 2)        // strmtyp: independent
        writer.write(0, bits: 3)        // substreamid
        writer.write(128, bits: 11)     // frmsiz
        writer.write(0, bits: 2)        // fscod
        writer.write(3, bits: 2)        // numblkscod: 6 blocks
        writer.write(7, bits: 3)        // acmod
        writer.write(1, bits: 1)        // lfeon
        writer.write(16, bits: 5)       // bsid: E-AC-3
        writer.write(0, bits: 5)        // dialnorm
        writer.write(0, bits: 1)        // compre
        writer.write(0, bits: 1)        // mixmdate
        writer.write(0, bits: 1)        // infomdate
        writer.write(1, bits: 1)        // addbsie
        writer.write(1, bits: 6)        // addbsil: 2 bytes
        writer.write(0, bits: 7)        // reserved
        writer.write(1, bits: 1)        // flag_ec3_extension_type_a
        writer.write(16, bits: 8)       // complexity_index_type_a
        for _ in 0..<32 { writer.write(0, bits: 8) }
        return writer.bytes
    }()

    /// Three length-prefixed (4-byte) NALs: SPS (type 33, layer 0), an
    /// enhancement-layer NAL (layer 1), and an RPU (type 62) — one of each
    /// disposition the Dolby Vision rewrite takes.
    package static let hevcPacket: [UInt8] = {
        func nal(type: UInt8, layerID: UInt8, payload: [UInt8]) -> [UInt8] {
            let header0 = (type << 1) | (layerID >> 5)
            let header1 = (layerID & 0x1F) << 3 | 1
            let body = [header0, header1] + payload
            let length = UInt32(body.count)
            return [
                UInt8(length >> 24), UInt8((length >> 16) & 0xFF),
                UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF),
            ] + body
        }
        return nal(type: 33, layerID: 0, payload: [0x01, 0x02, 0x03])
            + nal(type: 1, layerID: 1, payload: [0x04, 0x05])
            + nal(type: 62, layerID: 0, payload: [0x7C, 0x01, 0xFF, 0xEE])
    }()

    /// An `hvcC` needing normalization: SEI array to drop, PPS-before-SPS
    /// order to fix, `array_completeness = 0` to assert.
    package static let hvcCRecord: [UInt8] = {
        var record: [UInt8] = [1]                 // configurationVersion
        record += Array(repeating: 0, count: 21)  // PTL + fixed fields
        record[21] = 0x03                         // lengthSizeMinusOne = 3
        record += [3]                             // numOfArrays
        func array(complete: Bool, type: UInt8, units: [[UInt8]]) -> [UInt8] {
            var out: [UInt8] = [(complete ? 0x80 : 0x00) | type]
            out += [UInt8(units.count >> 8), UInt8(units.count & 0xFF)]
            for unit in units {
                out += [UInt8(unit.count >> 8), UInt8(unit.count & 0xFF)] + unit
            }
            return out
        }
        record += array(complete: false, type: 39, units: [[0x4E, 0x01]])        // SEI
        record += array(complete: false, type: 34, units: [[0x44, 0x01, 0xC0]])  // PPS
        record += array(complete: false, type: 33, units: [[0x42, 0x01, 0x01]])  // SPS
        return record
    }()

    /// `moov/trak/mdia/minf/stbl/stsd/hvc1/hvcC` — the six-deep nesting the
    /// splice has to keep honest.
    package static let videoInitSegment: [UInt8] = initSegment(
        sampleEntry: "hvc1", fixedFieldCount: 78, configBox: ("hvcC", hvcCRecord)
    )

    /// Same tree with an audio entry (28 fixed bytes) around the `dec3`.
    package static let audioInitSegment: [UInt8] = initSegment(
        sampleEntry: "ec-3", fixedFieldCount: 28, configBox: ("dec3", dec3Payload)
    )

    package static let srtText = """
    1
    00:00:01,000 --> 00:00:03,000
    <i>Hello</i> {\\i1}there{\\i0}

    2
    00:00:04,500 --> 00:00:06,000
    Second cue & a <font color="red">tag</font>
    """

    package static let vttText = """
    WEBVTT

    NOTE a comment block

    cue-1
    00:01.000 --> 00:03.000 line:85%
    First cue

    00:00:04.000 --> 00:00:05.000
    Second
    """

    /// Carries every override the translation reads: a `\pos` to normalize,
    /// an `\an` to lift out, an italic toggle to turn into a tag.
    package static let assEvent =
        "Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\\an8\\pos(4,5)}{\\i1}Hi{\\i0}\\Nthere"

    /// tx3g: 16-bit big-endian length, UTF-8 text, then a style box to ignore.
    package static let tx3gSample: [UInt8] = {
        let text = Array("Sample".utf8)
        return [0, UInt8(text.count)] + text + [0, 0, 0, 8] + Array("styl".utf8)
    }()

    // MARK: helpers

    private static func box(_ type: String, payload: [UInt8]) -> [UInt8] {
        let size = UInt32(payload.count + 8)
        return [
            UInt8(size >> 24), UInt8((size >> 16) & 0xFF),
            UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF),
        ] + Array(type.utf8) + payload
    }

    private static func initSegment(
        sampleEntry: String, fixedFieldCount: Int, configBox: (String, [UInt8])
    ) -> [UInt8] {
        let entry = box(
            sampleEntry,
            payload: Array(repeating: 0, count: fixedFieldCount)
                + box(configBox.0, payload: configBox.1)
        )
        let stsd = box("stsd", payload: [0, 0, 0, 0, 0, 0, 0, 1] + entry)
        let tree = box(
            "moov",
            payload: box(
                "trak",
                payload: box("mdia", payload: box("minf", payload: box("stbl", payload: stsd)))
            )
        )
        return box("ftyp", payload: Array("iso5".utf8)) + tree
    }

    private struct BitWriter {
        var bytes: [UInt8] = []
        private var bitCount = 0

        mutating func write(_ value: Int, bits: Int) {
            for shift in stride(from: bits - 1, through: 0, by: -1) {
                if bitCount % 8 == 0 { bytes.append(0) }
                let bit = UInt8((value >> shift) & 1)
                bytes[bytes.count - 1] |= bit << (7 - UInt8(bitCount % 8))
                bitCount += 1
            }
        }
    }
}

/// SplitMix64: tiny, seedable, identical everywhere. `SystemRandomNumberGenerator`
/// would make every fuzz failure unreproducible, which defeats the harness.
package struct SplitMix64 {
    private var state: UInt64
    package init(seed: UInt64) { state = seed }

    package mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    package mutating func bytes(count: Int) -> [UInt8] {
        (0..<count).map { _ in UInt8(truncatingIfNeeded: next()) }
    }

    /// One of the classic corpus mutations, chosen per call: byte flips,
    /// truncation, duplication, a random splice, or appended noise.
    package mutating func mutate(_ seed: [UInt8]) -> [UInt8] {
        var output = seed
        switch next() % 5 {
        case 0:  // flip 1–8 bytes
            for _ in 0..<(1 + next() % 8) where !output.isEmpty {
                output[Int(next() % UInt64(output.count))] = UInt8(truncatingIfNeeded: next())
            }
        case 1:  // truncate
            output = Array(output.prefix(Int(next() % UInt64(max(1, output.count)))))
        case 2:  // duplicate a slice
            if !output.isEmpty {
                let start = Int(next() % UInt64(output.count))
                let length = Int(next() % UInt64(output.count - start + 1))
                output.insert(contentsOf: output[start..<(start + length)], at: start)
            }
        case 3:  // splice random bytes mid-buffer
            let at = output.isEmpty ? 0 : Int(next() % UInt64(output.count))
            output.insert(contentsOf: bytes(count: Int(next() % 16)), at: at)
        default:  // append noise
            output += bytes(count: Int(next() % 64))
        }
        return output
    }
}
