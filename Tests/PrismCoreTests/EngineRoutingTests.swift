import Testing
import Foundation
import Libavcodec
@testable import PrismCore

/// Routing decisions, over the real fixtures and over synthesized `SourceInfo`
/// for the cases no fixture can express.
@Suite("Engine routing")
struct EngineRoutingTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    // MARK: - Over real containers

    @Test("H.264 + AAC takes the remux path — the native one always wins when available")
    func copyableGoesNative() throws {
        let info = try SourceProbe.probe(url: try fixture("h264_aac.mkv"))
        let decision = try PrismCoreEngine.decide(for: info)
        #expect(decision.engine == .remux)
    }

    @Test("HEVC + EAC3 takes the remux path — this is the Atmos carrier, it must not decode")
    func atmosCarrierGoesNative() throws {
        let info = try SourceProbe.probe(url: try fixture("hevc_eac3.mkv"))
        let decision = try PrismCoreEngine.decide(for: info)
        // Routing this to software would decode EAC3 to PCM and lose passthrough
        // — the exact thing PrismCore exists to stop doing.
        #expect(decision.engine == .remux)
    }

    @Test("VP9 takes the software path — no native path exists for it at all")
    func vp9GoesSoftware() throws {
        let info = try SourceProbe.probe(url: try fixture("vp9.webm"))
        #expect(info.nativeReadiness == .unsupported)
        let decision = try PrismCoreEngine.decide(for: info)
        #expect(decision.engine == .software)
        #expect(decision.reason.contains("vp9"))
    }

    @Test("DTS-only audio: the bridge takes it when the encoder exists, software when it doesn't")
    func dtsDependsOnTheBuild() throws {
        let info = try SourceProbe.probe(url: try fixture("h264_dts.mkv"))
        #expect(info.nativeReadiness == .requiresAudioBridge)

        // With the EAC3 encoder the native path keeps everything it is good at.
        #expect(
            try PrismCoreEngine.decide(for: info, isAudioBridgeAvailable: true).engine == .remux
        )
        // Without it, remuxing could only serve silent video — so decode both in
        // software and keep the sound. This is phase 7 improving a case the
        // native path only appeared to handle.
        let withoutEncoder = try PrismCoreEngine.decide(for: info, isAudioBridgeAvailable: false)
        #expect(withoutEncoder.engine == .software)
        #expect(withoutEncoder.reason.contains("sound"))
    }

    // MARK: - Cases no fixture can express

    private func info(
        videoCodec: String,
        videoCopyability: StreamCopyability,
        audio: [StreamCopyability]
    ) -> SourceInfo {
        SourceInfo(
            formatName: "matroska",
            duration: 60,
            video: VideoTrackInfo(
                streamIndex: 0,
                codecName: videoCodec,
                profileName: nil,
                profile: 0,
                level: 0,
                width: 1920,
                height: 1080,
                sampleAspectRatio: nil,
                bitDepth: 8,
                colorPrimariesName: nil,
                colorTransferName: nil,
                colorSpaceName: nil,
                isBT2020: false,
                frameRate: 25,
                frameRateSource: .averageFrameRate,
                fieldOrder: .progressive,
                hevcConfiguration: nil,
                avcConfiguration: nil,
                av1Configuration: nil,
                nalUnitLengthSize: nil,
                dolbyVision: nil,
                dynamicRange: .sdr,
                copyability: videoCopyability
            ),
            audioTracks: audio.enumerated().map { index, copyability in
                AudioTrackInfo(
                    streamIndex: index + 1,
                    codecName: "aac",
                    profileName: nil,
                    channelCount: 2,
                    channelLayoutDescription: "stereo",
                    sampleRate: 48_000,
                    language: "eng",
                    title: nil,
                    isObjectAudio: false,
                    copyability: copyability
                )
            }
        )
    }

    /// An availability report that claims exactly the codecs it is given.
    private func availability(with codecs: [String]) -> SoftwareDecoderAvailability {
        SoftwareDecoderAvailability(
            entries: codecs.map {
                .init(codecName: $0, mediaType: .video, decoderName: $0, supportsVideoToolbox: false)
            }
        )
    }

    @Test("a codec with neither a native path nor a decoder is declined, not guessed at")
    func declinesWhatItCannotPlay() {
        let source = info(videoCodec: "cinepak", videoCopyability: .unsupported, audio: [.streamCopy])
        #expect(throws: PrismCoreEngine.RoutingFailure.self) {
            try PrismCoreEngine.decide(for: source, availability: availability(with: ["vp9"]))
        }
    }

    @Test("declining names the codec, so a host can log something actionable")
    func declineNamesTheCodec() {
        let source = info(videoCodec: "vc1", videoCopyability: .unsupported, audio: [])
        do {
            _ = try PrismCoreEngine.decide(for: source, availability: availability(with: []))
            Issue.record("expected a routing failure")
        } catch let failure as PrismCoreEngine.RoutingFailure {
            guard case .noDecoderForVideo(let name) = failure else {
                Issue.record("wrong failure: \(failure)")
                return
            }
            #expect(name == "vc1")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("an audio-only source is not this engine's business")
    func audioOnlyIsDeclined() {
        let source = SourceInfo(
            formatName: "matroska", duration: 60, video: nil,
            audioTracks: [
                AudioTrackInfo(
                    streamIndex: 0, codecName: "flac", profileName: nil, channelCount: 2,
                    channelLayoutDescription: "stereo", sampleRate: 48_000, language: nil,
                    title: nil, isObjectAudio: false, copyability: .streamCopy
                )
            ]
        )
        do {
            _ = try PrismCoreEngine.decide(for: source)
            Issue.record("expected a routing failure")
        } catch let failure as PrismCoreEngine.RoutingFailure {
            guard case .noVideoStream = failure else {
                Issue.record("wrong failure: \(failure)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("a silent source still takes the native path — no audio is not a problem to solve")
    func silentSourceGoesNative() throws {
        let source = info(videoCodec: "h264", videoCopyability: .streamCopy, audio: [])
        #expect(try PrismCoreEngine.decide(for: source).engine == .remux)
    }

    // MARK: - open()

    @Test("open() on a VP9 source returns a loaded software pipeline")
    func opensSoftwarePipeline() async throws {
        let playback = try await PrismCoreEngine.open(url: try fixture("vp9.webm"))
        guard case .software(let pipeline) = playback else {
            Issue.record("VP9 must not come back as a remux session")
            return
        }
        defer { pipeline.stop() }
        // Loaded and paused: the host attaches the layer before starting it.
        #expect(pipeline.state == .paused)
        #expect(pipeline.displayLayer != nil)
    }

    @Test("open() on an MKV returns a started session and a playable playlist")
    func opensRemuxSession() async throws {
        let playback = try await PrismCoreEngine.open(url: try fixture("h264_aac.mkv"))
        guard case .remux(let session, let playlist) = playback else {
            Issue.record("a copyable MKV must take the remux path")
            return
        }
        defer { Task { await session.stop() } }
        #expect(playlist.isFileURL == false)
        #expect(playlist.lastPathComponent.hasSuffix(".m3u8"))
        let (data, response) = try await URLSession.uncached.data(from: playlist)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).hasPrefix("#EXTM3U"))
    }
}

/// The probe's bridgeable set used to be a hand-copied duplicate of
/// `AudioBridge`'s, and it drifted — the bridge grew MP3/MP2/Opus/Vorbis/PCM
/// while the copy stayed at the three lossless codecs. These pin the two
/// together so a future addition to the bridge can't silently fail to reach
/// routing again.
@Suite("Probe and bridge agree on what is bridgeable")
struct BridgeableAgreementTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    @Test("an MP3-audio MKV is reported as needing the bridge, not as unsupported")
    func mp3NeedsTheBridge() throws {
        // The regression this exists for: MP3 is in AudioBridge's set and the
        // remuxer's own routing would bridge it, but the probe called the whole
        // source `.unsupported` — so routing never saw the option. Invisible
        // while the EAC3 encoder is missing (everything is unbridgeable then),
        // and live the day the MPVKit fork enables it.
        let info = try SourceProbe.probe(url: try fixture("h264_mp3.mkv"))
        let audio = try #require(info.audioTracks.first)
        #expect(audio.codecName == "mp3")
        #expect(audio.copyability == .requiresAudioBridge)
        #expect(info.nativeReadiness == .requiresAudioBridge)
    }

    @Test("with an encoder that source takes the native path; without one, software")
    func mp3RoutesBothWays() throws {
        let info = try SourceProbe.probe(url: try fixture("h264_mp3.mkv"))
        #expect(
            try PrismCoreEngine.decide(for: info, isAudioBridgeAvailable: true).engine == .remux
        )
        #expect(
            try PrismCoreEngine.decide(for: info, isAudioBridgeAvailable: false).engine == .software
        )
    }

    @Test("every codec the bridge accepts is a codec the probe calls bridgeable")
    func setsCannotDrift() {
        // Straight through the probe's own classifier, so adding a codec to
        // AudioBridge.bridgeableAudio can never again leave the probe behind.
        for codecID in AudioBridge.bridgeableAudio {
            let hasDecoder = avcodec_find_decoder(codecID) != nil
            #expect(
                SourceProbe.isBridgeableForTesting(codecID) == hasDecoder,
                "\(String(cString: avcodec_get_name(codecID))) disagrees"
            )
        }
    }
}

/// AV1 is the one codec whose native-path eligibility depends on the *device*:
/// Apple's hardware AV1 decoder arrived with the A17 Pro and M3, and there is no
/// software decoder behind VideoToolbox — so on an M1 or M2 (Vision Pro included)
/// an AV1 variant offered to AVPlayer doesn't play slowly, it doesn't play.
@Suite("AV1 depends on the device")
struct AV1RoutingTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    @Test("with hardware AV1 the source stream-copies; without it, it does not")
    func copyabilityFollowsTheDevice() {
        #expect(
            SourceProbe.isVideoStreamCopyable(AV_CODEC_ID_AV1, isAV1HardwareSupported: true)
        )
        #expect(
            SourceProbe.isVideoStreamCopyable(AV_CODEC_ID_AV1, isAV1HardwareSupported: false)
                == false
        )
        // The two that never depend on the device.
        for codec in [AV_CODEC_ID_H264, AV_CODEC_ID_HEVC] {
            #expect(SourceProbe.isVideoStreamCopyable(codec, isAV1HardwareSupported: false))
        }
    }

    @Test("an AV1 source's av1C is read, so it can be declared honestly")
    func readsTheConfigurationRecord() throws {
        let info = try SourceProbe.probe(url: try fixture("av1_aac.mkv"))
        let video = try #require(info.video)
        #expect(video.codecName == "av1")
        let record = try #require(
            video.av1Configuration, "no av1C — an AV1 source with no record can't be declared"
        )
        #expect(record.profile == 0)          // Main
        #expect(record.bitDepth == 8)
        // The CODECS string AVPlayer would be given.
        let codecString = MasterPlaylistBuilder.av1CodecString(record)
        #expect(codecString.hasPrefix("av01.0."))
        #expect(codecString.hasSuffix(".08"))
    }

    @Test("the AV1 codec string follows the spec's shape")
    func codecStringShape() {
        #expect(
            MasterPlaylistBuilder.av1CodecString(
                .init(profile: 0, levelIndex: 8, tier: 0, bitDepth: 10, isMonochrome: false)
            ) == "av01.0.08M.10"
        )
        // High tier, and a two-digit level that must not lose its leading zero.
        #expect(
            MasterPlaylistBuilder.av1CodecString(
                .init(profile: 1, levelIndex: 5, tier: 1, bitDepth: 8, isMonochrome: false)
            ) == "av01.1.05H.08"
        )
        // Professional profile carries the only twelve-bit case.
        #expect(
            MasterPlaylistBuilder.av1CodecString(
                .init(profile: 2, levelIndex: 16, tier: 0, bitDepth: 12, isMonochrome: false)
            ) == "av01.2.16M.12"
        )
    }

    @Test("twelve-bit is only read for the Professional profile")
    func bitDepthRules() throws {
        func record(profile: UInt8, highBitDepth: Bool, twelveBit: Bool) throws -> AV1ConfigurationRecord {
            var byte2: UInt8 = 0
            if highBitDepth { byte2 |= 0x40 }
            if twelveBit { byte2 |= 0x20 }
            let bytes: [UInt8] = [0x81, (profile << 5) | 8, byte2, 0]
            return try #require(AV1ConfigurationRecord.parse(av1C: Data(bytes)))
        }
        #expect(try record(profile: 0, highBitDepth: false, twelveBit: false).bitDepth == 8)
        #expect(try record(profile: 0, highBitDepth: true, twelveBit: false).bitDepth == 10)
        // twelve_bit set outside Professional is not a twelve-bit stream.
        #expect(try record(profile: 0, highBitDepth: true, twelveBit: true).bitDepth == 10)
        #expect(try record(profile: 2, highBitDepth: true, twelveBit: true).bitDepth == 12)
    }

    @Test("a record with the wrong marker or version is refused, not guessed at")
    func refusesBadRecords() {
        #expect(AV1ConfigurationRecord.parse(av1C: Data([0x01, 0x08, 0x00, 0x00])) == nil)  // no marker
        #expect(AV1ConfigurationRecord.parse(av1C: Data([0x82, 0x08, 0x00, 0x00])) == nil)  // version 2
        #expect(AV1ConfigurationRecord.parse(av1C: Data([0x81, 0x08])) == nil)              // too short
    }

    @Test("routing sends AV1 to the native path only where the hardware is")
    func routingFollowsTheDevice() throws {
        let info = try SourceProbe.probe(url: try fixture("av1_aac.mkv"))
        // This machine's real answer decides which of the two the probe reported,
        // so assert the pairing rather than one fixed outcome.
        if SourceProbe.isVideoStreamCopyable(AV_CODEC_ID_AV1) {
            #expect(info.nativeReadiness == .streamCopy)
            #expect(try PrismCoreEngine.decide(for: info).engine == .remux)
        } else {
            #expect(info.nativeReadiness == .unsupported)
            // libdav1d is what makes AV1 play at all on such a device.
            #expect(try PrismCoreEngine.decide(for: info).engine == .software)
        }
    }
}
