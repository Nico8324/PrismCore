import Testing
import Foundation
import Libavcodec
import Libavutil
@testable import PrismCore

/// Dialogue boost: the route decision (pure), the filter's actual gain math
/// (real avfilter graph, no media file), the bridge integration, and the
/// master-playlist declaration. The full EAC3 rendition needs an FFmpeg build
/// with the `eac3` encoder, which stock MPVKit lacks — those paths are gated
/// the same way the bridge's are, and the session-level test pins the
/// *graceful skip* instead, which is the behaviour every build must have.
@Suite("Dialogue boost routing")
struct DialogueBoostRoutingTests {

    private let base = HLSRemuxer.AudioRoute(index: 1, mode: .streamCopy)

    @Test("One boost route per requested level, duplicates collapsed, order kept")
    func routesPerLevel() {
        let routes = HLSRemuxer.dialogueBoostRoutes(
            requested: [.high, .medium, .high],
            base: base,
            trackChannelCount: 6,
            boostIsBuildable: true
        )
        #expect(routes == [
            HLSRemuxer.AudioRoute(index: 1, mode: .boost(.high)),
            HLSRemuxer.AudioRoute(index: 1, mode: .boost(.medium)),
        ])
    }

    @Test("No base rendition means nothing to derive from")
    func noBaseNoBoost() {
        #expect(HLSRemuxer.dialogueBoostRoutes(
            requested: [.medium], base: nil, trackChannelCount: 6, boostIsBuildable: true
        ).isEmpty)
    }

    @Test("A stereo default track gets no boost — there is no centre to favour")
    func stereoIsIneligible() {
        #expect(HLSRemuxer.dialogueBoostRoutes(
            requested: [.medium], base: base, trackChannelCount: 2, boostIsBuildable: true
        ).isEmpty)
    }

    @Test("A build that can't decode or encode produces no routes")
    func unbuildableIsSkipped() {
        #expect(HLSRemuxer.dialogueBoostRoutes(
            requested: [.medium, .high], base: base, trackChannelCount: 6,
            boostIsBuildable: false
        ).isEmpty)
    }

    @Test("Nothing requested, nothing produced")
    func emptyRequest() {
        #expect(HLSRemuxer.dialogueBoostRoutes(
            requested: [], base: base, trackChannelCount: 6, boostIsBuildable: true
        ).isEmpty)
    }
}

@Suite("Dialogue boost filter")
struct DialogueBoostFilterTests {

    private static let sampleRate: Int32 = 48_000

    /// A frame whose every channel carries a constant, so per-channel gain is
    /// directly readable off the output.
    private func makeFrame(
        channels: Int32, value: Float, samples: Int32 = 1024, pts: Int64 = 0
    ) throws -> UnsafeMutablePointer<AVFrame> {
        let frame = try #require(av_frame_alloc())
        frame.pointee.nb_samples = samples
        frame.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
        frame.pointee.sample_rate = Self.sampleRate
        av_channel_layout_default(&frame.pointee.ch_layout, channels)
        try FFmpegError.check(av_frame_get_buffer(frame, 0), "av_frame_get_buffer")
        for channel in 0..<Int(channels) {
            frame.pointee.extended_data[channel]!.withMemoryRebound(
                to: Float.self, capacity: Int(samples)
            ) { plane in
                for index in 0..<Int(samples) { plane[index] = value }
            }
        }
        frame.pointee.pts = pts
        return frame
    }

    /// Mean |sample| of one channel, reading planar or packed float — `pan`'s
    /// output format is the graph's business, not the test's.
    private func meanAbs(of frame: UnsafeMutablePointer<AVFrame>, channel: Int) throws -> Double {
        let samples = Int(frame.pointee.nb_samples)
        let channels = Int(frame.pointee.ch_layout.nb_channels)
        let format = AVSampleFormat(rawValue: frame.pointee.format)
        var total = 0.0
        switch format {
        case AV_SAMPLE_FMT_FLTP:
            frame.pointee.extended_data[channel]!.withMemoryRebound(
                to: Float.self, capacity: samples
            ) { plane in
                for index in 0..<samples { total += Double(abs(plane[index])) }
            }
        case AV_SAMPLE_FMT_FLT:
            frame.pointee.extended_data[0]!.withMemoryRebound(
                to: Float.self, capacity: samples * channels
            ) { interleaved in
                for index in 0..<samples {
                    total += Double(abs(interleaved[index * channels + channel]))
                }
            }
        default:
            throw FFmpegError(code: -1, operation: "unexpected output format \(format.rawValue)")
        }
        return total / Double(samples)
    }

    @Test("The centre keeps unity while the bed is attenuated by the level's gain",
          arguments: [DialogueBoostLevel.medium, .high])
    func centreFavoured(level: DialogueBoostLevel) throws {
        guard DialogueBoostFilter.isAvailable else { return }
        let filter = DialogueBoostFilter(
            level: level, timeBase: AVRational(num: 1, den: Self.sampleRate)
        )
        defer { filter.close() }

        // 5.1 default layout: FL FR FC LFE SL SR — the centre is index 2.
        var perChannel: [Double] = []
        var outputPTS: Int64?
        for pass in 0..<4 {
            let frame = try makeFrame(channels: 6, value: 0.5, pts: Int64(pass) * 1024)
            defer { var frame: UnsafeMutablePointer<AVFrame>? = frame; av_frame_free(&frame) }
            try filter.push(frame) { filtered in
                if perChannel.isEmpty {
                    outputPTS = filtered.pointee.pts
                    perChannel = try (0..<6).map { try meanAbs(of: filtered, channel: $0) }
                }
            }
        }
        try filter.flush { _ in }

        try #require(perChannel.count == 6, "the graph emitted nothing")
        #expect(outputPTS == 0, "pan must not shift timestamps")
        let expectedBed = 0.5 * level.backgroundGain
        for (channel, mean) in perChannel.enumerated() {
            let expected = channel == 2 ? 0.5 : expectedBed
            #expect(
                abs(mean - expected) < 0.005,
                "channel \(channel): \(mean) instead of \(expected)"
            )
        }
    }

    @Test("A stereo frame passes through untouched — the declared-layout lie path")
    func stereoPassesThrough() throws {
        guard DialogueBoostFilter.isAvailable else { return }
        let filter = DialogueBoostFilter(
            level: .medium, timeBase: AVRational(num: 1, den: Self.sampleRate)
        )
        defer { filter.close() }

        let frame = try makeFrame(channels: 2, value: 0.5, pts: 7)
        defer { var frame: UnsafeMutablePointer<AVFrame>? = frame; av_frame_free(&frame) }
        var seen = 0
        try filter.push(frame) { filtered in
            seen += 1
            #expect(filtered.pointee.pts == 7)
            let left = try meanAbs(of: filtered, channel: 0)
            let right = try meanAbs(of: filtered, channel: 1)
            #expect(left == 0.5)
            #expect(right == 0.5)
        }
        try filter.flush { _ in }
        #expect(seen == 1)
    }
}

/// The bridge with the boost in its path — the same LPCM-in, stub-encoder-out
/// harness the plain bridge pipeline uses, so it runs on stock MPVKit.
@Suite("Dialogue boost bridge")
struct DialogueBoostBridgeTests {

    private static let sampleRate: Int32 = 48_000

    private static var stubEncoder: AVCodecID? {
        for candidate in [AV_CODEC_ID_FLAC, AV_CODEC_ID_AAC, AV_CODEC_ID_ALAC]
        where avcodec_find_encoder(candidate) != nil {
            return candidate
        }
        return nil
    }

    private func makeCodecpar(channels: Int32) -> UnsafeMutablePointer<AVCodecParameters> {
        let par = avcodec_parameters_alloc()!
        par.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        par.pointee.codec_id = AV_CODEC_ID_PCM_S16LE
        par.pointee.format = AV_SAMPLE_FMT_S16.rawValue
        par.pointee.sample_rate = Self.sampleRate
        par.pointee.bits_per_coded_sample = 16
        par.pointee.block_align = channels * 2
        av_channel_layout_default(&par.pointee.ch_layout, channels)
        return par
    }

    private func makePacket(
        samples: Int32, channels: Int32, pts: Int64
    ) -> UnsafeMutablePointer<AVPacket> {
        let packet = av_packet_alloc()!
        av_new_packet(packet, samples * channels * 2)
        packet.pointee.data.withMemoryRebound(to: Int16.self, capacity: Int(samples * channels)) {
            for index in 0..<Int(samples * channels) {
                $0[index] = Int16(truncatingIfNeeded: index * 17)
            }
        }
        packet.pointee.pts = pts
        packet.pointee.dts = pts
        packet.pointee.duration = Int64(samples)
        return packet
    }

    @Test("A boosted 5.1 bridge still anchors on the source and stays monotonic")
    func boostedPipelineKeepsTimestamps() throws {
        guard DialogueBoostFilter.isAvailable else { return }
        let target = try #require(Self.stubEncoder, "no audio encoder in this FFmpeg build")
        let par = makeCodecpar(channels: 6)
        defer { var par: UnsafeMutablePointer<AVCodecParameters>? = par; avcodec_parameters_free(&par) }

        let bridge = try AudioBridge(
            codecpar: par,
            timeBase: AVRational(num: 1, den: Self.sampleRate),
            globalHeader: false,
            dialogueBoost: .medium,
            targetCodec: target
        )
        defer { bridge.close() }
        #expect(bridge.routeDescription.contains("dialogue boost (medium)"))

        let startPTS: Int64 = 96_000
        var timestamps: [Int64] = []
        for index in 0..<20 {
            let packet = makePacket(samples: 1_000, channels: 6, pts: startPTS + Int64(index) * 1_000)
            defer { var packet: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&packet) }
            try bridge.feed(packet) { timestamps.append($0.pointee.pts) }
        }
        try bridge.flush { timestamps.append($0.pointee.pts) }

        #expect(!timestamps.isEmpty, "the boosted bridge produced no packets")
        #expect(timestamps.first == startPTS, "the filter must not cost the source anchor")
        #expect(timestamps == timestamps.sorted())
    }

    @Test("A stereo source refuses the boost at setup, so the rendition is skipped")
    func stereoRefusedAtSetup() throws {
        guard DialogueBoostFilter.isAvailable else { return }
        let target = try #require(Self.stubEncoder, "no audio encoder in this FFmpeg build")
        let par = makeCodecpar(channels: 2)
        defer { var par: UnsafeMutablePointer<AVCodecParameters>? = par; avcodec_parameters_free(&par) }

        #expect {
            try AudioBridge(
                codecpar: par,
                timeBase: AVRational(num: 1, den: Self.sampleRate),
                globalHeader: false,
                dialogueBoost: .medium,
                targetCodec: target
            )
        } throws: { error in
            guard case AudioBridge.Failure.dialogueBoostIneligible = error else { return false }
            return true
        }
    }
}

@Suite("Dialogue boost declaration")
struct DialogueBoostDeclarationTests {

    @Test("A boost rendition declares the speech-intelligibility characteristic")
    func masterCarriesCharacteristic() throws {
        let variant = MasterPlaylistBuilder.VariantDescription(
            bandwidth: 8_000_000,
            videoCodec: .explicit("avc1.640028"),
            audioRenditions: [
                .init(name: "Main", codecString: "ec-3", channels: "6",
                      uri: "audio0/index.m3u8", isDefault: true),
                .init(name: "Main (Dialogue Boost)", codecString: "ec-3", channels: "6",
                      uri: "audio1/index.m3u8", isDefault: false,
                      characteristics: [dialogueBoostCharacteristic]),
            ]
        )
        let master = try MasterPlaylistBuilder.build(variant)
        #expect(master.contains(
            "CHARACTERISTICS=\"public.accessibility.enhances-speech-intelligibility\""
        ))
        // Only on the boost rendition — one line, not two.
        let lines = master.split(separator: "\n").filter { $0.contains("CHARACTERISTICS") }
        #expect(lines.count == 1)
        #expect(lines.first?.contains("Dialogue Boost") == true)
    }

    @Test("The boost rendition's NAME appends the level's suffix to the track's")
    func renditionNameCarriesSuffix() {
        let track = AudioTrackInfo(
            streamIndex: 1, codecName: "eac3", profileName: nil,
            channelCount: 6, channelLayoutDescription: "5.1",
            sampleRate: 48_000, language: "en", title: "Main",
            isObjectAudio: false, copyability: .streamCopy
        )
        let directory = FileManager.default.temporaryDirectory
        for (level, suffix) in [
            (DialogueBoostLevel.medium, "Main (Dialogue Boost)"),
            (.high, "Main (Dialogue Boost+)"),
        ] {
            let writer = AudioRenditionWriter(
                route: .init(index: 1, mode: .boost(level)),
                track: track, ordinal: 1, parent: directory
            )
            let rendition = writer.rendition(groupID: "aud", isDefault: false)
            #expect(rendition.name == suffix)
            #expect(rendition.characteristics == [dialogueBoostCharacteristic])
            // Whatever the build's bridge encodes to: EAC3 where the
            // encoder exists, AAC otherwise.
            #expect(rendition.codecString == MasterPlaylistBuilder.audioCodecString(
                forCodecName: AudioBridge.defaultTargetCodecName
            ))
            #expect(writer.dialogueBoostInfo == DialogueBoostRendition(level: level, name: suffix))
        }
        // The base rendition stays clean of all of it.
        let base = AudioRenditionWriter(
            route: .init(index: 1, mode: .streamCopy),
            track: track, ordinal: 0, parent: directory
        )
        #expect(base.rendition(groupID: "aud", isDefault: true).characteristics.isEmpty)
        #expect(base.dialogueBoostInfo == nil)
    }
}

/// The behaviour every build must have, encoder or not: requesting a boost
/// never breaks a session, and the session reports exactly what the master
/// declares — nothing, on a build that can't produce it or a source with no
/// centre channel.
@Suite("Dialogue boost session", .serialized)
struct DialogueBoostSessionTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    @Test("Requesting a boost is safe on any build, and the report matches the master")
    func requestIsBestEffort() async throws {
        let session = try PrismCoreSession(
            url: try fixture("h264_multi_audio.mkv"),
            dialogueBoost: [.medium, .high]
        )
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        let master = try String(
            contentsOf: await session.workDirectory.appendingPathComponent("master.m3u8"),
            encoding: .utf8
        )
        let reported = await session.dialogueBoostRenditions
        // Whatever was reported is declared, and nothing is declared that
        // wasn't reported — the host's UI builds rows from this list.
        for rendition in reported {
            #expect(master.contains("NAME=\"\(rendition.name)\""))
        }
        let declared = master.split(separator: "\n")
            .filter { $0.contains("CHARACTERISTICS") }.count
        #expect(declared == reported.count)
        // Stock MPVKit has no eac3 encoder, and the fixture's tracks are
        // stereo besides — on that build this pins the graceful skip.
        if !PrismCoreSession.isDialogueBoostAvailable {
            #expect(reported.isEmpty)
            #expect(!master.contains("Dialogue Boost"))
        }
        #expect(playlist.lastPathComponent == "master.m3u8")
    }
}
