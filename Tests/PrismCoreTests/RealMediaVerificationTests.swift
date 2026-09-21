import Testing
import Foundation
@testable import PrismCore

/// Verification against **real media**, which the synthetic fixtures cannot
/// stand in for.
///
/// Skipped unless `PRISMCORE_MEDIA` points at a file, so the ordinary suite stays
/// hermetic:
///
/// ```
/// PRISMCORE_MEDIA=~/Downloads/some.dv.mkv swift test --filter RealMedia
/// ```
///
/// These exist because two of this package's headline claims are unfalsifiable
/// with generated fixtures. ffmpeg cannot synthesize a Dolby Vision RPU, and it
/// cannot synthesize EAC3 with joint object coding — so "the P7 conversion works"
/// and "Atmos survives the remux" were, until this file, pure reasoning. What
/// still needs a device is narrower than it was: whether a display engages Dolby
/// Vision and whether a receiver decodes the objects. Everything up to the bytes
/// we hand over is checkable right here.
@Suite(
    "Real media verification",
    .enabled(if: ProcessInfo.processInfo.environment["PRISMCORE_MEDIA"] != nil)
)
struct RealMediaVerificationTests {

    private var mediaURL: URL {
        let path = ProcessInfo.processInfo.environment["PRISMCORE_MEDIA"] ?? ""
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// Everything the probe found, printed. Not an assertion — a report, so the
    /// run is self-documenting when something below fails.
    @Test("report what the source is")
    func report() throws {
        let info = try SourceProbe.probe(url: mediaURL)
        var lines = ["source: \(mediaURL.lastPathComponent)", "container: \(info.formatName)"]
        if let video = info.video {
            lines.append(
                """
                video: \(video.codecName) \(video.width)×\(video.height) \
                \(video.bitDepth.map { "\($0)-bit" } ?? "?") \
                \(video.dynamicRange.rawValue) \
                \(video.frameRate.map { String(format: "%.3f fps", $0) } ?? "? fps")
                """
            )
            if let dv = video.dolbyVision {
                lines.append(
                    """
                    dolby vision: profile \(dv.profileName) level \(dv.level) \
                    rpu=\(dv.rpuPresent) el=\(dv.enhancementLayerPresent) \
                    bl=\(dv.baseLayerPresent) compat=\(dv.baseLayerSignalCompatibilityID)
                    """
                )
            } else {
                lines.append("dolby vision: none")
            }
            lines.append("hvcC parsed: \(video.hevcConfiguration != nil)")
        }
        for track in info.audioTracks {
            lines.append(
                """
                audio: \(track.codecName) \(track.channelCount)ch \
                \(track.channelLayoutDescription ?? "?") \
                atmos=\(track.isObjectAudio) \(track.copyability.rawValue)
                """
            )
        }
        lines.append("readiness: \(info.nativeReadiness.rawValue)")
        lines.append(
            "routing: " + ((try? PrismCoreEngine.decide(for: info).engine.rawValue) ?? "declined")
        )
        print("\n" + lines.joined(separator: "\n") + "\n")
    }

    /// The claim this file was written for: does libdovi actually convert the
    /// RPUs of a real Profile 7 stream?
    ///
    /// Forced through `PrismCoreSession` rather than `PrismCoreEngine.open`, since
    /// a P7 disc rip usually carries DTS or TrueHD audio and the router would
    /// therefore (correctly) send it to the software path, where no conversion
    /// happens.
    @Test("Profile 7 converts to 8.1, with every RPU accounted for")
    func profile7Conversion() async throws {
        let info = try SourceProbe.probe(url: mediaURL)
        // Not applicable is not a failure: point this at a P5/P8 or non-DV file
        // and there is simply nothing to convert.
        guard let dv = info.video?.dolbyVision, dv.isDualLayer else {
            print("(skipped: not a Profile 7 source — nothing to convert)")
            return
        }

        let session = try PrismCoreSession(
            url: mediaURL,
            display: DisplayCapabilities(isHDRReady: true, isDolbyVisionCapable: true)
        )
        _ = try await session.start()
        defer { Task { await session.stop() } }

        // Let a few segments land — the counters are refreshed per segment.
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        var stats: DolbyVisionConversionStats?
        while ContinuousClock.now < deadline {
            if let current = await session.dolbyVisionConversion, current.convertedRPUs > 0 {
                stats = current
                break
            }
            try await Task.sleep(for: .milliseconds(200))
        }

        let result = try #require(
            stats,
            """
            no RPU was converted. Either libdovi refused every one of them, or the \
            converter never ran — check that Libdovi is linked in this build \
            (DolbyVisionRPUConverter.isAvailable = \(DolbyVisionRPUConverter.isAvailable)).
            """
        )
        print(
            """

            dolby vision conversion: converted=\(result.convertedRPUs) \
            failed=\(result.failedRPUs) \
            droppedELNALs=\(result.droppedEnhancementLayerNALs)

            """
        )
        #expect(result.failedRPUs == 0, "libdovi refused \(result.failedRPUs) RPUs")
        // This count reading zero used to be explained away as "Matroska keeps
        // the EL in block additions the demuxer never hands us". That was
        // wrong, and it hid the converter's central bug: the EL is `unspec63`
        // on `nuh_layer_id == 0`, so the old `layerID != 0` drop test never
        // matched and the enhancement layer rode through into a stream whose
        // `dvvC` declared `el_present = 0` — which is what made a P7 FEL title
        // play as a black picture with sound.
        //
        // So it is asserted now: a dual-layer source reporting no dropped EL
        // NALs means the drop path stopped matching again, and the only
        // visible symptom of that is a viewer reporting a black screen.
        #expect(result.droppedEnhancementLayerNALs > 0, "no enhancement-layer NAL was dropped from a Profile 7 source. The EL is unspec63 (NAL type 63) and shares nuh_layer_id == 0 with the base layer, so a layer-id test cannot find it - check DolbyVisionRPUConverter.isEnhancementLayer.")
    }

    /// Fetch the served init segment, waiting for the producer to mint it.
    private func fetchInitSegment(base: URL) async throws -> Data {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < deadline {
            if let (data, response) = try? await URLSession.uncached.data(
                   from: base.appendingPathComponent("init.mp4")
               ),
               (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty {
                return data
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        return Data()
    }

    /// A display that cannot present Dolby Vision must not be served a `dvvC`
    /// box, however the manifest is written: `hvc1` + `dvvC` is refused by
    /// AVPlayer's compatibility gate on its own. This is the case the
    /// master-rejection fallback's DV-less tier lands in, and while it still
    /// served the record that tier could never win — it bought a second
    /// identical `-11868` for the price of a whole new session.
    ///
    /// Profile 5 is exempt and is skipped here: its record describes an
    /// IPT-PQc2 picture rather than upgrading a base layer, so stripping it
    /// would be the green-and-purple misread. Such a source is refused a
    /// master a level up instead.
    @Test("a non-DV display is served no Dolby Vision record")
    func nonDVDisplayGetsNoDVRecord() async throws {
        let info = try SourceProbe.probe(url: mediaURL)
        let dv = try #require(
            info.video?.dolbyVision, "source carries no Dolby Vision — nothing to strip"
        )
        try #require(!dv.isSingleLayerDVOnly, "profile 5 keeps its record by design")

        let session = try PrismCoreSession(
            url: mediaURL,
            display: DisplayCapabilities(isHDRReady: true, isDolbyVisionCapable: false)
        )
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        let initSegment = try await fetchInitSegment(base: playlist.deletingLastPathComponent())
        try #require(!initSegment.isEmpty, "no init segment was served")
        #expect(findBoxPayload("dvvC", in: initSegment) == nil)
        #expect(findBoxPayload("dvcC", in: initSegment) == nil)
    }

    /// The init segment is what AVPlayer parses, so it is what has to be right:
    /// the `hvcC` in `hvc1` form, the sample entry's fourcc, and the DV record
    /// rewritten to whatever we now claim.
    @Test("the served init segment declares what the manifest claims")
    func servedInitSegment() async throws {
        let info = try SourceProbe.probe(url: mediaURL)
        let session = try PrismCoreSession(
            url: mediaURL,
            display: DisplayCapabilities(isHDRReady: true, isDolbyVisionCapable: true)
        )
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        let base = playlist.deletingLastPathComponent()
        let initSegment = try await fetchInitSegment(base: base)
        try #require(!initSegment.isEmpty, "no init segment was served")

        // hvcC: nothing left to normalize, and the PTL unchanged from the source.
        if let record = findBoxPayload("hvcC", in: initSegment) {
            print("served hvcC: \(record.count) bytes")
            // Not empty, even when the source's own record carried no parameter
            // sets: those get harvested from the bitstream and filled in, because
            // FFmpeg writes an empty box for such a source and an `hvc1` entry
            // then promises parameter sets that aren't there.
            #expect(!record.isEmpty, "served hvcC is empty — nothing to configure a decoder from")
            guard !record.isEmpty else { return }
            #expect(
                HVCCNormalizer.normalize(hvcC: record) == nil,
                "the served hvcC still needs normalizing"
            )
            if let source = info.video?.hevcConfiguration {
                #expect(HEVCConfigurationRecord.parse(hvcC: record) == source)
            }
        }

        // The DV record we serve, versus what the source said.
        let dvBox = findBoxPayload("dvvC", in: initSegment)
            ?? findBoxPayload("dvcC", in: initSegment)
        if let dvBox, dvBox.count >= 5 {
            let bytes = [UInt8](dvBox)
            let servedProfile = bytes[2] >> 1
            let servedCompatibility = bytes[4] >> 4
            print(
                """

                served DV record: profile \(servedProfile) compat \(servedCompatibility) \
                (source said profile \(info.video?.dolbyVision?.profile ?? 0) \
                compat \(info.video?.dolbyVision?.baseLayerSignalCompatibilityID ?? 0))

                """
            )
            if info.video?.dolbyVision?.isDualLayer == true {
                // A converted P7 must go out as single-layer 8.1 over an HDR10
                // base — that is exactly what the master's db1p brand promises.
                #expect(servedProfile == 8)
                #expect(servedCompatibility == 1)
            }
        }

        // Atmos, when the source has it: the box, not the playlist attribute, is
        // what makes AVFoundation take the Dolby/MAT route.
        if info.audioTracks.contains(where: { $0.isObjectAudio && $0.codecName == "eac3" }) {
            // Resolved before the macro: #require's expansion can't await.
            var dec3Payload = findBoxPayload("dec3", in: initSegment)
            if dec3Payload == nil, let rendition = try? await fetchRenditionInit(base: base) {
                dec3Payload = findBoxPayload("dec3", in: rendition)
            }
            let dec3 = try #require(dec3Payload, "an Atmos source produced no dec3 box")
            let config = try #require(EAC3Configuration.parse(dec3: [UInt8](dec3)))
            print("\nserved dec3: \(config)\n")
            // FFmpeg's mp4 muxer drops the TS 103 420 type-A extension on a
            // stream copy (plain `ffmpeg -c copy` produces the same
            // extension-less box), so PrismCore reads the signal out of the
            // bitstream itself and patches the box — `EAC3Syncframe` plus
            // `EAC3Configuration.patch`. Without that this reads false and
            // AVFoundation plays a real Atmos track as plain Dolby Digital Plus,
            // which is the single most consequential thing this harness found.
            #expect(
                config.declaresAtmos,
                "the source is Atmos but the served dec3 does not declare it"
            )
        }
    }

    private func fetchRenditionInit(base: URL) async throws -> Data? {
        for ordinal in 0..<4 {
            if let (data, response) = try? await URLSession.uncached.data(
                   from: base.appendingPathComponent("audio\(ordinal)/init.mp4")
               ),
               (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty {
                return data
            }
        }
        return nil
    }
}

/// Box-tree lookup shared by the checks above. Descends only what leads to a
/// sample entry; visual entries carry 78 fixed bytes before their children,
/// audio entries 28.
private func findBoxPayload(_ wanted: String, in data: Data) -> Data? {
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
