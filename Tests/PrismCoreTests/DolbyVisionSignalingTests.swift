import Testing
import Foundation
@testable import PrismCore

// MARK: - hvcC fixtures with parameter-set arrays

/// Builds an `hvcC` whose 22-byte header is a real Main10 PTL and whose arrays
/// are whatever the test asks for.
///
/// - Parameter arrays: `(nalType, arrayCompleteness, [nalPayload])` in the order
///   they should be written.
private func hvcC(
    lengthSizeMinusOne: UInt8 = 3,
    arrays: [(type: UInt8, complete: Bool, units: [[UInt8]])]
) -> Data {
    var bytes = [UInt8](repeating: 0, count: 22)
    bytes[0] = 1                     // configurationVersion
    bytes[1] = 2                     // profile_space 0, tier 0, profile_idc 2
    bytes[2] = 0x20                  // compatibility flags 0x20000000
    bytes[6] = 0xB0                  // first constraint byte
    bytes[12] = 153                  // level_idc 5.1
    bytes[21] = lengthSizeMinusOne   // constantFrameRate/etc zero + lengthSizeMinusOne

    bytes.append(UInt8(arrays.count))
    for array in arrays {
        bytes.append((array.complete ? 0x80 : 0x00) | array.type)
        bytes.append(UInt8((array.units.count >> 8) & 0xFF))
        bytes.append(UInt8(array.units.count & 0xFF))
        for unit in array.units {
            bytes.append(UInt8((unit.count >> 8) & 0xFF))
            bytes.append(UInt8(unit.count & 0xFF))
            bytes.append(contentsOf: unit)
        }
    }
    return Data(bytes)
}

private let vps: [UInt8] = [0x40, 0x01, 0x0C, 0x01]
private let sps: [UInt8] = [0x42, 0x01, 0x01, 0x02, 0x20]
private let pps: [UInt8] = [0x44, 0x01, 0xC0]
private let prefixSEI: [UInt8] = [0x4E, 0x01, 0x05, 0xFF]

/// Reads back the `(type, complete, units)` triples of a record.
private func arrays(of data: Data) -> [(type: UInt8, complete: Bool, units: [[UInt8]])] {
    let bytes = [UInt8](data)
    var result: [(type: UInt8, complete: Bool, units: [[UInt8]])] = []
    var cursor = 23
    guard bytes.count > 22 else { return result }
    for _ in 0..<Int(bytes[22]) {
        guard cursor + 3 <= bytes.count else { break }
        let header = bytes[cursor]
        let count = Int(bytes[cursor + 1]) << 8 | Int(bytes[cursor + 2])
        cursor += 3
        var units: [[UInt8]] = []
        for _ in 0..<count {
            guard cursor + 2 <= bytes.count else { break }
            let length = Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1])
            cursor += 2
            guard cursor + length <= bytes.count else { break }
            units.append(Array(bytes[cursor..<(cursor + length)]))
            cursor += length
        }
        result.append((type: header & 0x3F, complete: header & 0x80 != 0, units: units))
    }
    return result
}

// MARK: - hvcC normalization

@Suite("hvcC normalization")
struct HVCCNormalizerTests {

    @Test("a record that is already hvc1-correct is left alone")
    func noChangeReturnsNil() {
        let record = hvcC(arrays: [
            (type: 32, complete: true, units: [vps]),
            (type: 33, complete: true, units: [sps]),
            (type: 34, complete: true, units: [pps]),
        ])
        #expect(HVCCNormalizer.normalize(hvcC: record) == nil)
    }

    @Test("array_completeness=0 is raised to 1")
    func completenessIsAsserted() throws {
        let record = hvcC(arrays: [
            (type: 32, complete: false, units: [vps]),
            (type: 33, complete: false, units: [sps]),
            (type: 34, complete: false, units: [pps]),
        ])
        let normalized = try #require(HVCCNormalizer.normalize(hvcC: record))
        // Computed outside the macro: #expect decomposes a trailing function call
        // into a rethrows helper, and a key-path-as-function argument reads as
        // throwing there.
        let completeness = arrays(of: normalized).map(\.complete)
        #expect(completeness == [true, true, true])
    }

    @Test("SEI arrays are dropped, VPS/SPS/PPS survive in order")
    func seiIsDropped() throws {
        let record = hvcC(arrays: [
            (type: 33, complete: true, units: [sps]),
            (type: 39, complete: true, units: [prefixSEI]),
            (type: 32, complete: true, units: [vps]),
            (type: 34, complete: true, units: [pps]),
        ])
        let normalized = try #require(HVCCNormalizer.normalize(hvcC: record))
        let result = arrays(of: normalized)
        #expect(result.map(\.type) == [32, 33, 34])
        #expect(result.map(\.units) == [[vps], [sps], [pps]])
    }

    @Test("out-of-order arrays are reordered even when otherwise correct")
    func reordering() throws {
        let record = hvcC(arrays: [
            (type: 34, complete: true, units: [pps]),
            (type: 33, complete: true, units: [sps]),
            (type: 32, complete: true, units: [vps]),
        ])
        let normalized = try #require(HVCCNormalizer.normalize(hvcC: record))
        #expect(arrays(of: normalized).map(\.type) == [32, 33, 34])
    }

    @Test("two arrays of the same type are merged, keeping every parameter set")
    func mergesSplitArrays() throws {
        let secondSPS: [UInt8] = [0x42, 0x01, 0x02, 0x03]
        let record = hvcC(arrays: [
            (type: 32, complete: true, units: [vps]),
            (type: 33, complete: true, units: [sps]),
            (type: 33, complete: true, units: [secondSPS]),
            (type: 34, complete: true, units: [pps]),
        ])
        let normalized = try #require(HVCCNormalizer.normalize(hvcC: record))
        let result = arrays(of: normalized)
        #expect(result.map(\.type) == [32, 33, 34])
        #expect(result[1].units == [sps, secondSPS])
    }

    @Test("the profile_tier_level header survives byte for byte")
    func headerIsUntouched() throws {
        let record = hvcC(arrays: [
            (type: 33, complete: false, units: [sps]),
        ])
        let normalized = try #require(HVCCNormalizer.normalize(hvcC: record))
        #expect(normalized.prefix(22) == record.prefix(22))
        // Which is the property that matters: the CODECS string is printed from
        // this header, and it must still describe the init segment.
        let before = try #require(HEVCConfigurationRecord.parse(hvcC: record))
        let after = try #require(HEVCConfigurationRecord.parse(hvcC: normalized))
        #expect(before == after)
    }

    @Test("a record with no SPS is refused rather than rewritten")
    func refusesRecordWithoutSPS() {
        let record = hvcC(arrays: [(type: 39, complete: false, units: [prefixSEI])])
        #expect(HVCCNormalizer.normalize(hvcC: record) == nil)
    }

    @Test("truncated arrays are refused")
    func refusesTruncated() {
        var bytes = [UInt8](hvcC(arrays: [(type: 33, complete: false, units: [sps])]))
        bytes.removeLast(3)
        #expect(HVCCNormalizer.normalize(hvcC: Data(bytes)) == nil)
    }

    @Test("lengthSizeMinusOne is read back as the NAL prefix width")
    func lengthSizeIsRead() {
        #expect(HEVCNALUnits.lengthSize(fromHVCC: hvcC(lengthSizeMinusOne: 3, arrays: [])) == 4)
        #expect(HEVCNALUnits.lengthSize(fromHVCC: hvcC(lengthSizeMinusOne: 1, arrays: [])) == 2)
    }
}

// MARK: - NAL walking and rewriting

/// Length-prefixes NAL units the way a demuxed mp4/mkv packet carries them.
private func packet(_ units: [[UInt8]], lengthSize: Int = 4) -> [UInt8] {
    var bytes: [UInt8] = []
    for unit in units {
        for shift in stride(from: (lengthSize - 1) * 8, through: 0, by: -8) {
            bytes.append(UInt8((unit.count >> shift) & 0xFF))
        }
        bytes.append(contentsOf: unit)
    }
    return bytes
}

/// An HEVC NAL header for `type` / `layerID`, plus one payload byte.
private func nal(type: UInt8, layerID: UInt8 = 0, payload: UInt8 = 0xAA) -> [UInt8] {
    [
        (type << 1) | ((layerID >> 5) & 0x01),
        ((layerID & 0x1F) << 3) | 1,
        payload,
    ]
}

@Suite("HEVC NAL units")
struct HEVCNALUnitsTests {

    @Test("types and layer ids are read out of the two-byte header")
    func parsesHeaders() throws {
        let bytes = packet([
            nal(type: 33),
            nal(type: 62),
            nal(type: 1, layerID: 1),
        ])
        let units = try #require(HEVCNALUnits.units(in: bytes, lengthSize: 4))
        #expect(units.map(\.type) == [33, 62, 1])
        #expect(units.map(\.layerID) == [0, 0, 1])
    }

    @Test("every prefix width frames the same units", arguments: [1, 2, 4])
    func everyLengthSize(lengthSize: Int) throws {
        let bytes = packet([nal(type: 33), nal(type: 34)], lengthSize: lengthSize)
        let units = try #require(HEVCNALUnits.units(in: bytes, lengthSize: lengthSize))
        #expect(units.map(\.type) == [33, 34])
    }

    @Test("a keep-everything rewrite reports no change")
    func keepIsNil() {
        let bytes = packet([nal(type: 33), nal(type: 1)])
        #expect(HEVCNALUnits.rewrite(bytes, lengthSize: 4) { _ in .keep } == nil)
    }

    @Test("dropping a unit removes it and its length prefix")
    func dropsUnits() throws {
        let bytes = packet([nal(type: 1), nal(type: 62), nal(type: 1, payload: 0xBB)])
        let rewritten = try #require(
            HEVCNALUnits.rewrite(bytes, lengthSize: 4) { $0.type == 62 ? .drop : .keep }
        )
        let units = try #require(HEVCNALUnits.units(in: rewritten, lengthSize: 4))
        #expect(units.map(\.type) == [1, 1])
        #expect(rewritten.count == bytes.count - (4 + 3))
    }

    @Test("a replacement of a different length is re-framed correctly")
    func replacesUnits() throws {
        let bytes = packet([nal(type: 62), nal(type: 1)])
        let longer = nal(type: 62) + [0x01, 0x02, 0x03]
        let rewritten = try #require(
            HEVCNALUnits.rewrite(bytes, lengthSize: 4) {
                $0.type == 62 ? .replace(longer) : .keep
            }
        )
        let units = try #require(HEVCNALUnits.units(in: rewritten, lengthSize: 4))
        #expect(units.count == 2)
        #expect(Array(units[0].bytes) == longer)
        #expect(units[1].type == 1)
    }

    @Test("a length that overruns the buffer is refused, not best-effort parsed")
    func refusesOverrun() {
        var bytes = packet([nal(type: 33)])
        bytes.removeLast()
        #expect(HEVCNALUnits.units(in: bytes, lengthSize: 4) == nil)
    }

    @Test("a zero length is refused rather than looping forever")
    func refusesZeroLength() {
        #expect(HEVCNALUnits.units(in: [0, 0, 0, 0, 0x42, 0x01], lengthSize: 4) == nil)
    }
}

// MARK: - Profile 7 declaration

@Suite("Profile 7 → 8.1 declaration")
struct DolbyVisionConversionDeclarationTests {

    private func profile7() -> DolbyVisionConfiguration {
        DolbyVisionConfiguration(
            versionMajor: 1,
            versionMinor: 0,
            profile: 7,
            level: 6,
            rpuPresent: true,
            enhancementLayerPresent: true,
            baseLayerPresent: true,
            baseLayerSignalCompatibilityID: 0
        )
    }

    @Test("the conversion tallies land per packet, and a packet that went out stale is counted")
    func conversionAccounting() throws {
        // The converter cannot be constructed without libdovi, which is the
        // same gap that let the `unspec63` bug ship untested — so skip where
        // the library isn't linked rather than fail. `isEnhancementLayer` above
        // is the part that stays provable everywhere.
        guard DolbyVisionRPUConverter.isAvailable else { return }
        let converter = try #require(DolbyVisionRPUConverter(lengthSize: 4))

        // A framed packet carrying an enhancement layer: dropped, counted once.
        _ = converter.convert(packet: packet([nal(type: 1), nal(type: 63, payload: 0xEE)]))
        #expect(converter.droppedEnhancementLayerNALs == 1)
        #expect(converter.staleUnconvertedPackets == 0)

        // A framed packet with nothing to change moves nothing and is not stale
        // — `rewrite` reporting "no change" is the normal case, not a refusal.
        _ = converter.convert(packet: packet([nal(type: 1)]))
        #expect(converter.droppedEnhancementLayerNALs == 1)
        #expect(converter.staleUnconvertedPackets == 0)

        // A packet that does not frame goes to the muxer unexamined, and the
        // tallies cannot see it: `rewrite` validates the whole packet before
        // `dispose` runs, so nothing is ever decided. It is counted here.
        _ = converter.convert(packet: [0xFF, 0xFF, 0xFF, 0xFF, 0x01])
        #expect(converter.staleUnconvertedPackets == 1)
        #expect(converter.droppedEnhancementLayerNALs == 1)
    }

    @Test("the enhancement layer is found by NAL type 63, not by layer id")
    func enhancementLayerIsUnspec63() {
        // The EL of a muxed dual-layer stream is `unspec63` and sits on
        // `nuh_layer_id == 0`, exactly like the base layer and the RPU. A
        // layer-id test therefore never finds it: that is how the EL used to
        // ride through into a stream whose `dvvC` said `el_present = 0`, and
        // how a Profile 7 FEL title came to play as a black picture with sound.
        #expect(DolbyVisionRPUConverter.isEnhancementLayer(type: 63, layerID: 0))
        // A layered carriage is still enhancement layer wherever it is.
        #expect(DolbyVisionRPUConverter.isEnhancementLayer(type: 1, layerID: 1))
        // What this predicate must never claim: the base layer's pictures, its
        // parameter sets, or the RPU. The RPU is rewritten — or dropped when
        // libdovi refuses it, which is a different decision made below this
        // predicate, not enhancement-layer carriage.
        #expect(!DolbyVisionRPUConverter.isEnhancementLayer(type: 62, layerID: 0))
        #expect(!DolbyVisionRPUConverter.isEnhancementLayer(type: 1, layerID: 0))
        #expect(!DolbyVisionRPUConverter.isEnhancementLayer(type: 32, layerID: 0))
        #expect(!DolbyVisionRPUConverter.isEnhancementLayer(type: 33, layerID: 0))
        #expect(!DolbyVisionRPUConverter.isEnhancementLayer(type: 34, layerID: 0))
    }

    @Test("the converted configuration is single-layer 8.1 at the same level")
    func convertedShape() {
        let converted = profile7().convertedToProfile81
        #expect(converted.profile == 8)
        #expect(converted.baseLayerSignalCompatibilityID == 1)
        #expect(converted.level == 6)
        #expect(converted.enhancementLayerPresent == false)
        #expect(converted.isDualLayer == false)
        #expect(converted.profileName == "8.1")
    }

    @Test("a converted P7 earns the db1p supplemental claim a raw P7 cannot")
    func supplementalCodecs() throws {
        let record = try #require(
            HEVCConfigurationRecord.parse(
                hvcC: hvcC(arrays: [(type: 33, complete: true, units: [sps])])
            )
        )
        func variant(
            dolbyVision: DolbyVisionConfiguration
        ) -> MasterPlaylistBuilder.VariantDescription {
            MasterPlaylistBuilder.VariantDescription(
                bandwidth: 30_000_000,
                resolution: .init(width: 3840, height: 2160),
                frameRate: 23.976,
                dynamicRange: .pq,
                videoCodec: .hevc(record),
                dolbyVision: dolbyVision,
                displayIsDolbyVisionCapable: true,
                audioRenditions: [.init(name: "English", codecString: "ec-3", uri: "audio0/index.m3u8")]
            )
        }

        // Dual-layer P7 has no brand: nothing honest to claim, so no
        // SUPPLEMENTAL-CODECS at all.
        #expect(
            MasterPlaylistBuilder.supplementalCodecsString(for: variant(dolbyVision: profile7()))
                == nil
        )
        // Converted, it is a normal 8.1 stream with an HDR10 base.
        #expect(
            MasterPlaylistBuilder.supplementalCodecsString(
                for: variant(dolbyVision: profile7().convertedToProfile81)
            ) == "dvh1.08.06/db1p"
        )
    }

    @Test("the primary codec stays the HEVC base — 8.1 is not profile 5")
    func primaryCodecIsBase() throws {
        let record = try #require(
            HEVCConfigurationRecord.parse(
                hvcC: hvcC(arrays: [(type: 33, complete: true, units: [sps])])
            )
        )
        let variant = MasterPlaylistBuilder.VariantDescription(
            bandwidth: 30_000_000,
            frameRate: 23.976,
            dynamicRange: .pq,
            videoCodec: .hevc(record),
            dolbyVision: profile7().convertedToProfile81,
            displayIsDolbyVisionCapable: true
        )
        #expect(MasterPlaylistBuilder.primaryVideoCodecString(for: variant).hasPrefix("hvc1."))
    }
}

// MARK: - Normalization end to end

/// Walks an ISO-BMFF box tree looking for `hvcC`, returning its payload.
///
/// Deliberately dumb: descends only the containers that lead to a sample entry
/// (`moov` → `trak` → `mdia` → `minf` → `stbl` → `stsd`), and treats an `hvc1` /
/// `hev1` sample entry as a container whose children start 78 bytes in (the
/// `VisualSampleEntry` fixed fields). Enough to read our own init segment; not a
/// general parser.
private func findHVCC(in data: Data) -> Data? {
    func walk(_ range: Range<Int>, insideSampleEntry: Bool) -> Data? {
        var cursor = range.lowerBound
        while cursor + 8 <= range.upperBound {
            let size = Int(data[cursor]) << 24 | Int(data[cursor + 1]) << 16
                | Int(data[cursor + 2]) << 8 | Int(data[cursor + 3])
            let type = String(decoding: data[(cursor + 4)..<(cursor + 8)], as: UTF8.self)
            guard size >= 8, cursor + size <= range.upperBound else { return nil }
            let payload = (cursor + 8)..<(cursor + size)

            if type == "hvcC" { return data.subdata(in: payload) }
            switch type {
            case "moov", "trak", "mdia", "minf", "stbl":
                if let found = walk(payload, insideSampleEntry: false) { return found }
            case "stsd":
                // version/flags(4) + entry_count(4), then the sample entries.
                if payload.count > 8,
                   let found = walk((payload.lowerBound + 8)..<payload.upperBound,
                                    insideSampleEntry: true) {
                    return found
                }
            case "hvc1", "hev1", "dvh1", "dvhe":
                if payload.count > 78,
                   let found = walk((payload.lowerBound + 78)..<payload.upperBound,
                                    insideSampleEntry: false) {
                    return found
                }
            default:
                break
            }
            cursor += size
        }
        return nil
    }
    return walk(0..<data.count, insideSampleEntry: false)
}

@Suite("hvcC normalization, end to end")
struct HVCCNormalizationIntegrationTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    @Test("the served init segment's hvcC is in hvc1 form, whatever the source's was")
    func servedRecordIsNormalized() async throws {
        let source = try fixture("hevc_eac3.mkv")
        let session = try PrismCoreSession(url: source)
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        // The init segment is what AVPlayer parses the sample entry out of, so
        // it — not our in-memory record — is what has to be right.
        let initURL = playlist.deletingLastPathComponent().appendingPathComponent("init.mp4")
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        var initSegment = Data()
        while ContinuousClock.now < deadline {
            if let (data, response) = try? await URLSession.uncached.data(from: initURL),
               (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty {
                initSegment = data
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let served = try #require(findHVCC(in: initSegment), "no hvcC in the served init segment")

        // The property that matters: nothing left to normalize. Every array is
        // complete, none is an SEI array, and they are in VPS/SPS/PPS order.
        #expect(HVCCNormalizer.normalize(hvcC: served) == nil)

        // And the PTL still describes the same stream — normalization must never
        // change what the CODECS string says.
        let sourceInfo = try SourceProbe.probe(url: source)
        let sourceRecord = try #require(sourceInfo.video?.hevcConfiguration)
        let servedRecord = try #require(HEVCConfigurationRecord.parse(hvcC: served))
        #expect(sourceRecord == servedRecord)
    }
}

// MARK: - Master rejection

@Suite("Master rejection")
struct MasterRejectionTests {

    @Test("each rejection code matches", arguments: [-11868, -11848, -1002])
    func matchesCodes(code: Int) {
        let error = NSError(domain: "AVFoundationErrorDomain", code: code)
        #expect(MasterRejection.matches(error))
        #expect(PrismCoreSession.isMasterRejection(error))
    }

    @Test("a code nested under NSUnderlyingErrorKey still matches")
    func matchesNested() {
        let underlying = NSError(domain: NSURLErrorDomain, code: -1002)
        let wrapper = NSError(
            domain: "AVFoundationErrorDomain",
            code: -11800,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )
        #expect(MasterRejection.matches(wrapper))
    }

    @Test("an unrelated failure does not match")
    func ignoresOthers() {
        #expect(!MasterRejection.matches(NSError(domain: NSURLErrorDomain, code: -1009)))
        #expect(!MasterRejection.matches(nil))
    }

    @Test("a cyclic underlying-error chain terminates")
    func toleratesCycle() {
        // Two errors referencing each other: the depth bound is what keeps a
        // host's failure handler from hanging on framework-supplied input.
        let inner = NSError(domain: "A", code: 1)
        let outer = NSError(domain: "B", code: 2, userInfo: [NSUnderlyingErrorKey: inner])
        let cyclic = NSError(domain: "C", code: 3, userInfo: [NSUnderlyingErrorKey: outer])
        #expect(!MasterRejection.matches(cyclic))
    }
}

// MARK: - Display capabilities

@Suite("Display capabilities")
struct DisplayCapabilitiesTests {

    @Test("the conservative default claims nothing")
    func conservative() {
        #expect(DisplayCapabilities.conservative.isHDRReady == false)
        #expect(DisplayCapabilities.conservative.isDolbyVisionCapable == false)
        #expect(DisplayCapabilities.conservative.source == .unavailable)
    }

    @Test("a caller-supplied pair is reported as caller-sourced")
    func callerSourced() {
        let capabilities = DisplayCapabilities(isHDRReady: true, isDolbyVisionCapable: true)
        #expect(capabilities.source == .caller)
    }

    @Test("reading the current display answers without crashing")
    @MainActor
    func currentIsReadable() {
        // What it *says* depends on the machine running the suite (and a headless
        // CI host has no screen at all), so the assertion is only that the read
        // completes and reports where it came from. The values themselves need a
        // device to verify — see the README's Status section.
        let capabilities = DisplayCapabilities.current()
        #expect(capabilities.source != .caller)
        if capabilities.isDolbyVisionCapable {
            #expect(capabilities.isHDRReady, "DV without HDR is not a reachable state")
        }
    }
}

// MARK: - Atmos declaration

@Suite("Atmos / CHANNELS=16/JOC")
struct ObjectAudioDeclarationTests {

    @Test("object audio prints the JOC form, not the bed's channel count")
    func jocWinsOverCount() {
        // An Atmos EAC3 track's ch_layout really does read 6; 16 is the fixed
        // figure HLS asks for, so the count must NOT win here.
        #expect(
            MasterPlaylistBuilder.channelsAttribute(channelCount: 6, isObjectAudio: true)
                == "16/JOC"
        )
        #expect(
            MasterPlaylistBuilder.channelsAttribute(channelCount: nil, isObjectAudio: true)
                == "16/JOC"
        )
    }

    @Test("without object audio it is the plain count, and nothing when unknown")
    func plainCount() {
        #expect(MasterPlaylistBuilder.channelsAttribute(channelCount: 6, isObjectAudio: false) == "6")
        #expect(MasterPlaylistBuilder.channelsAttribute(channelCount: 2, isObjectAudio: false) == "2")
        #expect(MasterPlaylistBuilder.channelsAttribute(channelCount: nil, isObjectAudio: false) == nil)
        // A container that reports zero channels knows nothing; CHANNELS is
        // optional, and omitting it beats declaring a lie.
        #expect(MasterPlaylistBuilder.channelsAttribute(channelCount: 0, isObjectAudio: false) == nil)
    }

    @Test("an Atmos rendition reaches the master as CHANNELS=\"16/JOC\"")
    func masterCarriesJOC() throws {
        let record = try #require(
            HEVCConfigurationRecord.parse(
                hvcC: hvcC(arrays: [(type: 33, complete: true, units: [sps])])
            )
        )
        let variant = MasterPlaylistBuilder.VariantDescription(
            bandwidth: 30_000_000,
            frameRate: 23.976,
            videoCodec: .hevc(record),
            audioRenditions: [
                .init(
                    name: "English",
                    codecString: "ec-3",
                    channels: MasterPlaylistBuilder.channelsAttribute(
                        channelCount: 6, isObjectAudio: true
                    ),
                    uri: "audio0/index.m3u8"
                )
            ]
        )
        let master = try MasterPlaylistBuilder.build(variant)
        #expect(master.contains("CHANNELS=\"16/JOC\""))
        // The codec tag stays plain EAC3 — JOC is not a codec, it rides inside.
        #expect(master.contains("ec-3"))
    }
}

// MARK: - dec3 / Atmos declaration in the served init segment

/// Finds a box payload by type, descending the containers that lead to a sample
/// entry. Handles both visual (children 78 bytes in) and audio (28 bytes in)
/// sample entries.
private func findBox(_ wanted: String, in data: Data) -> Data? {
    func walk(_ range: Range<Int>) -> Data? {
        var cursor = range.lowerBound
        while cursor + 8 <= range.upperBound {
            let size = Int(data[cursor]) << 24 | Int(data[cursor + 1]) << 16
                | Int(data[cursor + 2]) << 8 | Int(data[cursor + 3])
            let type = String(decoding: data[(cursor + 4)..<(cursor + 8)], as: UTF8.self)
            guard size >= 8, cursor + size <= range.upperBound else { return nil }
            let payload = (cursor + 8)..<(cursor + size)

            if type == wanted { return data.subdata(in: payload) }
            switch type {
            case "moov", "trak", "mdia", "minf", "stbl":
                if let found = walk(payload) { return found }
            case "stsd":
                if payload.count > 8, let found = walk((payload.lowerBound + 8)..<payload.upperBound) {
                    return found
                }
            case "hvc1", "hev1", "dvh1", "dvhe":
                if payload.count > 78, let found = walk((payload.lowerBound + 78)..<payload.upperBound) {
                    return found
                }
            case "ec-3", "ac-3", "mp4a":
                if payload.count > 28, let found = walk((payload.lowerBound + 28)..<payload.upperBound) {
                    return found
                }
            default:
                break
            }
            cursor += size
        }
        return nil
    }
    return walk(0..<data.count)
}

@Suite("dec3 in the served init segment")
struct EAC3ConfigurationTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    // MARK: Parser rules

    @Test("a plain DD+ box parses and declares no Atmos")
    func plainBox() throws {
        // data_rate=192, num_ind_sub-1=0, fscod=0, bsid=16, reserved, asvc,
        // bsmod=0, acmod=7, lfeon=1, reserved, num_dep_sub=0, reserved.
        var writer = BitAccumulator()
        writer.write(192, 13); writer.write(0, 3)
        writer.write(0, 2); writer.write(16, 5); writer.write(0, 1); writer.write(0, 1)
        writer.write(0, 3); writer.write(7, 3); writer.write(1, 1)
        writer.write(0, 3); writer.write(0, 4); writer.write(0, 1)
        let config = try #require(EAC3Configuration.parse(dec3: writer.bytes))
        #expect(config.declaresAtmos == false)
        #expect(config.channelCount == 6)   // 5.1 — the bed, hence 16/JOC in HLS
        #expect(config.dataRate == 192)
    }

    @Test("the TS 103 420 type-A tail is what declares Atmos")
    func atmosBox() throws {
        var writer = BitAccumulator()
        writer.write(768, 13); writer.write(0, 3)
        writer.write(0, 2); writer.write(16, 5); writer.write(0, 1); writer.write(0, 1)
        writer.write(0, 3); writer.write(7, 3); writer.write(1, 1)
        writer.write(0, 3); writer.write(0, 4); writer.write(0, 1)
        writer.write(0, 7); writer.write(1, 1); writer.write(12, 8)
        let config = try #require(EAC3Configuration.parse(dec3: writer.bytes))
        #expect(config.declaresAtmos)
        #expect(config.atmosComplexityIndex == 12)
        // Still 5.1 in the box — the objects are not channels.
        #expect(config.channelCount == 6)
    }

    @Test("a truncated box is unreadable, which is not the same as 'no Atmos'")
    func truncatedBox() {
        #expect(EAC3Configuration.parse(dec3: [0x00, 0x01]) == nil)
    }

    // MARK: The real thing

    @Test("the served init segment carries a readable dec3 for a stream-copied EAC3 track")
    func servedInitSegmentHasDec3() async throws {
        let session = try PrismCoreSession(url: try fixture("hevc_eac3.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        // Muxed shape (no master for this fixture's shape) keeps audio in the
        // variant's own init segment; a master would put it in audio0/.
        let base = playlist.deletingLastPathComponent()
        let candidates = ["init.mp4", "audio0/init.mp4"]
        var box: Data?
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline, box == nil {
            for candidate in candidates {
                if let (data, response) = try? await URLSession.uncached.data(
                       from: base.appendingPathComponent(candidate)
                   ),
                   (response as? HTTPURLResponse)?.statusCode == 200,
                   let found = findBox("dec3", in: data) {
                    box = found
                    break
                }
            }
            if box == nil { try await Task.sleep(for: .milliseconds(100)) }
        }

        let payload = try #require(box, "no dec3 box in any served init segment")
        let config = try #require(
            EAC3Configuration.parse(dec3: [UInt8](payload)),
            "the muxer wrote a dec3 we cannot read back"
        )
        // What a synthetic fixture can prove: the box exists, frames correctly,
        // and describes the right bed. What it CANNOT prove is the Atmos path —
        // ffmpeg-generated EAC3 carries no JOC, so this must read false here.
        // Verifying the extension survives a stream-copy needs a real Atmos file
        // and a device; that is the open item, and this parser is what the check
        // will use.
        #expect(config.declaresAtmos == false)
        #expect(config.channelCount > 0)

        // The same track, as the session reports it. This is the negative half
        // of the JOC walk and the reason it can be trusted to run on EVERY
        // stream-copied E-AC-3 track: asked of a plain DD+ stream, it answers
        // no rather than inventing a plausible index.
        let findings = await session.objectAudio
        let finding = try #require(findings.first, "the eac3 track was never asked")
        #expect(finding.isObjectAudio == false)
        #expect(finding.complexityIndex == nil)
        #expect(finding.claimedByMetadata == false)
        #expect(finding.wasMissedByMetadata == false)
    }
}

/// The finding type's own semantics — small, but the meaning of
/// `wasMissedByMetadata` is the whole point of publishing it.
@Suite("Object audio findings")
struct ObjectAudioFindingTests {

    @Test("A metadata claim the bitstream confirms is not a miss")
    func confirmedClaim() {
        let finding = ObjectAudioFinding(
            streamIndex: 1, complexityIndex: 16, claimedByMetadata: true
        )
        #expect(finding.isObjectAudio)
        #expect(finding.wasMissedByMetadata == false)
    }

    @Test("Atmos the container never claimed is the case worth reporting")
    func silentAtmos() {
        let finding = ObjectAudioFinding(
            streamIndex: 1, complexityIndex: 16, claimedByMetadata: false
        )
        #expect(finding.isObjectAudio)
        #expect(finding.wasMissedByMetadata)
    }

    @Test("Asked and answered no — a settled negative, not an absent answer")
    func settledNegative() {
        let finding = ObjectAudioFinding(
            streamIndex: 1, complexityIndex: nil, claimedByMetadata: true
        )
        #expect(finding.isObjectAudio == false)
        #expect(finding.wasMissedByMetadata == false)
    }
}

/// Writes MSB-first bit fields — the mirror of the parser's reader, for building
/// box payloads in tests.
private struct BitAccumulator {
    private(set) var bytes: [UInt8] = []
    private var bitCount = 0

    mutating func write(_ value: Int, _ width: Int) {
        for shift in stride(from: width - 1, through: 0, by: -1) {
            if bitCount % 8 == 0 { bytes.append(0) }
            if (value >> shift) & 1 == 1 {
                bytes[bytes.count - 1] |= 1 << (7 - UInt8(bitCount % 8))
            }
            bitCount += 1
        }
    }
}

// MARK: - Filling in a parameter-set-less record

@Suite("Parameter-set harvesting")
struct ParameterSetFillTests {

    /// The shape some MP4/TS sources ship: a valid 23-byte header, no arrays.
    private func emptyRecord() -> Data {
        var bytes = [UInt8](repeating: 0, count: 23)
        bytes[0] = 1
        bytes[1] = 2        // profile_space 0, tier 0, profile_idc 2
        bytes[2] = 0x20     // compatibility flags 0x20000000
        bytes[6] = 0xB0
        bytes[12] = 153     // level 5.1
        bytes[21] = 3       // lengthSizeMinusOne
        bytes[22] = 0       // numOfArrays
        return Data(bytes)
    }

    @Test("a record with no arrays is recognized as carrying no parameter sets")
    func recognizesEmptyRecord() {
        #expect(HVCCNormalizer.carriesNoParameterSets(hvcC: emptyRecord()))
        let withSets = hvcC(arrays: [(type: 33, complete: true, units: [sps])])
        #expect(HVCCNormalizer.carriesNoParameterSets(hvcC: withSets) == false)
    }

    @Test("filling in keeps the profile_tier_level byte for byte")
    func keepsHeader() throws {
        let source = emptyRecord()
        let filled = try #require(
            HVCCNormalizer.record(
                fillingIn: source, withParameterSets: [32: [vps], 33: [sps], 34: [pps]]
            )
        )
        // The CODECS string is printed from this header, so filling arrays must
        // not change what the manifest already claimed.
        #expect(filled.prefix(22) == source.prefix(22))
        #expect(HEVCConfigurationRecord.parse(hvcC: filled) == HEVCConfigurationRecord.parse(hvcC: source))
    }

    @Test("the filled record is already in hvc1 form")
    func fillsInNormalizedForm() throws {
        let filled = try #require(
            HVCCNormalizer.record(
                fillingIn: emptyRecord(), withParameterSets: [32: [vps], 33: [sps], 34: [pps]]
            )
        )
        // Nothing left for the normalizer to do: arrays in VPS/SPS/PPS order,
        // completeness asserted.
        #expect(HVCCNormalizer.normalize(hvcC: filled) == nil)
        #expect(arrays(of: filled).map(\.type) == [32, 33, 34])
    }

    @Test("without an SPS there is nothing worth filling in")
    func refusesWithoutSPS() {
        #expect(
            HVCCNormalizer.record(fillingIn: emptyRecord(), withParameterSets: [32: [vps]]) == nil
        )
        #expect(HVCCNormalizer.record(fillingIn: emptyRecord(), withParameterSets: [:]) == nil)
    }

    @Test("growing a box re-frames every enclosing size")
    func reframesAncestors() throws {
        // moov > trak > mdia > minf > stbl > stsd > hvc1 > hvcC, the real depth.
        func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
            let size = payload.count + 8
            return [
                UInt8((size >> 24) & 0xFF), UInt8((size >> 16) & 0xFF),
                UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF),
            ] + Array(type.utf8) + payload
        }
        let hvcCBox = box("hvcC", [1, 2, 3])
        let entry = box("hvc1", [UInt8](repeating: 0, count: 78) + hvcCBox)
        let stsd = box("stsd", [0, 0, 0, 0, 0, 0, 0, 1] + entry)
        let tree = box("moov", box("trak", box("mdia", box("minf", box("stbl", stsd)))))

        let data = Data(tree)
        let location = try #require(ISOBMFFPatch.locate("hvcC", in: data))
        // moov, trak, mdia, minf, stbl, stsd, hvc1 — the real nesting depth.
        #expect(location.ancestorStarts.count == 7)
        let grown = ISOBMFFPatch.replacePayload(
            at: location, in: data, with: Data([1, 2, 3, 4, 5])
        )
        #expect(grown.count == data.count + 2)
        // Every level has to agree with the new length, or the tree stops parsing
        // at the first stale one — which is exactly how an empty box appears.
        let relocated = try #require(ISOBMFFPatch.locate("hvcC", in: grown))
        #expect(grown.subdata(in: relocated.payload) == Data([1, 2, 3, 4, 5]))
        let outerSize = Int(grown[0]) << 24 | Int(grown[1]) << 16
            | Int(grown[2]) << 8 | Int(grown[3])
        #expect(outerSize == grown.count)
    }
}
