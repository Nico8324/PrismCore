import Testing
import Libavcodec
@testable import PrismCore

/// The bridge's two pure pieces. Everything that touches libavcodec state needs
/// a media fixture (see the PR notes); the arithmetic below is where the bugs
/// that produce clicks and drift actually live, so it's tested on its own.
@Suite("AudioBridge framing")
struct FrameChunkerTests {

    /// EAC3's framing: 1536 samples, no short frames allowed.
    private func eac3Chunker() -> FrameChunker {
        FrameChunker(frameSize: 1536, padsFinalFrame: true)
    }

    /// Stock MPVKit has no eac3 encoder; with EAC3 as the only target every DTS
    /// source left the remux path. AAC is FFmpeg's own and always present.
    @Test("The bridge targets eac3 when the build has it and aac otherwise")
    func targetFollowsTheBuild() {
        let hasEAC3 = avcodec_find_encoder(AV_CODEC_ID_EAC3) != nil
        #expect(AudioBridge.defaultTargetCodec == (hasEAC3 ? AV_CODEC_ID_EAC3 : AV_CODEC_ID_AAC))
        #expect(AudioBridge.defaultTargetCodecName == (hasEAC3 ? "eac3" : "aac"))
        #expect(AudioBridge.isEncoderAvailable)
        #expect(AudioBridge.canBridge(codecID: AV_CODEC_ID_DTS) == (avcodec_find_decoder(AV_CODEC_ID_DTS) != nil))
    }

    @Test("Nothing is emitted until a full encoder frame exists")
    func withholdsPartialFrames() {
        var chunker = eac3Chunker()
        chunker.appended(1000)
        #expect(chunker.nextFullChunk() == nil)
        chunker.appended(535)
        #expect(chunker.nextFullChunk() == nil)
        chunker.appended(1)
        #expect(chunker.nextFullChunk() == FrameChunker.Chunk(samples: 1536, silencePadding: 0))
        #expect(chunker.pending == 0)
    }

    @Test("A large push drains as whole frames and keeps the remainder")
    func drainsWholeFrames() {
        var chunker = eac3Chunker()
        // One decoded TrueHD frame's worth of samples doesn't divide by 1536.
        chunker.appended(1536 * 3 + 200)
        var emitted = 0
        while let chunk = chunker.nextFullChunk() {
            #expect(chunk == FrameChunker.Chunk(samples: 1536, silencePadding: 0))
            emitted += 1
        }
        #expect(emitted == 3)
        #expect(chunker.pending == 200)
    }

    @Test("Flush pads the final short frame to the encoder's frame size")
    func flushPadsTail() {
        var chunker = eac3Chunker()
        chunker.appended(1536 + 500)
        #expect(chunker.nextChunkForFlush() == FrameChunker.Chunk(samples: 1536, silencePadding: 0))
        #expect(chunker.nextChunkForFlush() == FrameChunker.Chunk(samples: 500, silencePadding: 1036))
        #expect(chunker.nextChunkForFlush() == nil)
    }

    @Test("An encoder that accepts short frames gets no silence")
    func flushWithoutPadding() {
        var chunker = FrameChunker(frameSize: 4608, padsFinalFrame: false)
        chunker.appended(700)
        #expect(chunker.nextChunkForFlush() == FrameChunker.Chunk(samples: 700, silencePadding: 0))
        #expect(chunker.nextChunkForFlush() == nil)
    }

    @Test("Flushing an empty FIFO produces nothing")
    func flushEmpty() {
        var chunker = eac3Chunker()
        #expect(chunker.nextChunkForFlush() == nil)
    }
}

@Suite("AudioBridge timestamps")
struct BridgeClockTests {

    /// 48 kHz, 100 ms gap tolerance — the bridge's own configuration.
    private func clock() -> BridgeClock {
        BridgeClock(sampleRate: 48_000, gapTolerance: 4_800)
    }

    @Test("The first frame anchors the counter on the source, not on zero")
    func anchorsOnSource() {
        var clock = clock()
        // A producer starting 60 s into the file: the source PTS is 2_880_000
        // samples, and audio must land there, not at 0.
        clock.observe(framePTS: 2_880_000, frameSamples: 1536, fifoDepth: 0)
        #expect(clock.stamp(1536) == 2_880_000)
        #expect(clock.stamp(1536) == 2_880_000 + 1536)
    }

    @Test("Continuous frames don't re-anchor; the counter just runs")
    func countsThroughContinuity() {
        var clock = clock()
        clock.observe(framePTS: 100_000, frameSamples: 2_000, fifoDepth: 0)
        _ = clock.stamp(1536)
        // Next frame arrives exactly where predicted, and the FIFO still holds
        // the 464-sample remainder — a re-anchor here would rewind those.
        clock.observe(framePTS: 102_000, frameSamples: 2_000, fifoDepth: 464)
        #expect(clock.stamp(1536) == 100_000 + 1536)
    }

    @Test("A gap larger than tolerance re-anchors instead of drifting")
    func reanchorsAcrossGap() {
        var clock = clock()
        clock.observe(framePTS: 0, frameSamples: 1536, fifoDepth: 0)
        _ = clock.stamp(1536)
        // Half a second of missing audio: the next packet's own timestamp wins,
        // so video stays in sync (and nothing fabricates PCM for the hole).
        clock.observe(framePTS: 24_000, frameSamples: 1536, fifoDepth: 0)
        #expect(clock.stamp(1536) == 24_000)
    }

    @Test("Jitter inside tolerance is absorbed, not treated as a gap")
    func absorbsJitter() {
        var clock = clock()
        clock.observe(framePTS: 0, frameSamples: 1536, fifoDepth: 0)
        _ = clock.stamp(1536)
        clock.observe(framePTS: 1536 + 40, frameSamples: 1536, fifoDepth: 0)
        #expect(clock.stamp(1536) == 1536)
    }

    @Test("An anchor reaches back past samples already in the FIFO")
    func anchorAccountsForFIFODepth() {
        var clock = clock()
        // 512 samples of an earlier, timestamp-less frame are buffered; they
        // belong before this frame, so the anchor sits 512 ticks earlier.
        clock.observe(framePTS: 10_000, frameSamples: 1536, fifoDepth: 512)
        #expect(clock.stamp(512) == 10_000 - 512)
        #expect(clock.stamp(1536) == 10_000)
    }

    @Test("Frames without timestamps keep counting and don't look like a gap")
    func toleratesMissingTimestamps() {
        var clock = clock()
        clock.observe(framePTS: 5_000, frameSamples: 1536, fifoDepth: 0)
        #expect(clock.stamp(1536) == 5_000)
        clock.observe(framePTS: nil, frameSamples: 1536, fifoDepth: 0)
        #expect(clock.stamp(1536) == 5_000 + 1536)
        // The next timestamped frame re-anchors (the unknown stretch can't be
        // verified as continuous), which is the conservative choice.
        clock.observe(framePTS: 9_000, frameSamples: 1536, fifoDepth: 0)
        #expect(clock.stamp(1536) == 9_000)
    }
}

@Suite("Audio stream routing")
struct AudioRoutingTests {

    private let bridgeEverything: (AVCodecID) -> Bool = { AudioBridge.bridgeableAudio.contains($0) }
    private let bridgeNothing: (AVCodecID) -> Bool = { _ in false }

    @Test("A copyable best track is stream-copied, never bridged")
    func prefersCopyOfBest() {
        let candidates = [
            HLSRemuxer.AudioCandidate(index: 1, codecID: AV_CODEC_ID_EAC3),
            HLSRemuxer.AudioCandidate(index: 2, codecID: AV_CODEC_ID_DTS),
        ]
        let route = HLSRemuxer.chooseAudio(candidates: candidates, best: 1, canBridge: bridgeEverything)
        #expect(route == HLSRemuxer.AudioRoute(index: 1, mode: .streamCopy))
    }

    @Test("A DTS-HD MA main track now wins over an AC3 compatibility track")
    func bridgesBestInsteadOfDowngrading() {
        // The v0 regression this phase fixes: index 1 is the 7.1 main track,
        // index 2 the 2.0 compat track, and v0 played the compat track.
        let candidates = [
            HLSRemuxer.AudioCandidate(index: 1, codecID: AV_CODEC_ID_DTS),
            HLSRemuxer.AudioCandidate(index: 2, codecID: AV_CODEC_ID_AC3),
        ]
        let route = HLSRemuxer.chooseAudio(candidates: candidates, best: 1, canBridge: bridgeEverything)
        #expect(route == HLSRemuxer.AudioRoute(index: 1, mode: .bridge))
    }

    @Test("Without a usable encoder the v0 fallback to copyable audio survives")
    func fallsBackWhenBridgeUnavailable() {
        let candidates = [
            HLSRemuxer.AudioCandidate(index: 1, codecID: AV_CODEC_ID_TRUEHD),
            HLSRemuxer.AudioCandidate(index: 2, codecID: AV_CODEC_ID_AC3),
        ]
        let route = HLSRemuxer.chooseAudio(candidates: candidates, best: 1, canBridge: bridgeNothing)
        #expect(route == HLSRemuxer.AudioRoute(index: 2, mode: .streamCopy))
    }

    @Test("A bridgeable non-best track is used when nothing is copyable")
    func bridgesNonBestTrack() {
        let candidates = [
            HLSRemuxer.AudioCandidate(index: 3, codecID: AV_CODEC_ID_TRUEHD),
        ]
        // No "best" (a container the demuxer couldn't rank) still routes.
        let route = HLSRemuxer.chooseAudio(candidates: candidates, best: nil, canBridge: bridgeEverything)
        #expect(route == HLSRemuxer.AudioRoute(index: 3, mode: .bridge))
    }

    @Test("A source with no usable audio at all selects none")
    func noAudioRoute() {
        let candidates = [
            HLSRemuxer.AudioCandidate(index: 1, codecID: AV_CODEC_ID_TRUEHD),
        ]
        #expect(HLSRemuxer.chooseAudio(candidates: candidates, best: 1, canBridge: bridgeNothing) == nil)
        #expect(HLSRemuxer.chooseAudio(candidates: [], best: nil, canBridge: bridgeEverything) == nil)
    }

    @Test("Every viable track becomes a rendition, the preferred one leading")
    func routesAllViableTracks() {
        let candidates = [
            HLSRemuxer.AudioCandidate(index: 1, codecID: AV_CODEC_ID_AC3),
            HLSRemuxer.AudioCandidate(index: 2, codecID: AV_CODEC_ID_EAC3),
            HLSRemuxer.AudioCandidate(index: 3, codecID: AV_CODEC_ID_DTS),
        ]
        // The demuxer's best is index 2; it leads because the first rendition is
        // the one flagged DEFAULT. The rest keep container order.
        let routes = HLSRemuxer.routeAll(candidates: candidates, best: 2, canBridge: bridgeEverything)
        #expect(routes == [
            HLSRemuxer.AudioRoute(index: 2, mode: .streamCopy),
            HLSRemuxer.AudioRoute(index: 1, mode: .streamCopy),
            HLSRemuxer.AudioRoute(index: 3, mode: .bridge),
        ])
    }

    @Test("Tracks that can be neither copied nor bridged are left out entirely")
    func skipsUnroutableTracks() {
        let candidates = [
            HLSRemuxer.AudioCandidate(index: 1, codecID: AV_CODEC_ID_TRUEHD),
            HLSRemuxer.AudioCandidate(index: 2, codecID: AV_CODEC_ID_AAC),
        ]
        // A dormant bridge (no eac3 encoder in this build) drops the TrueHD
        // track rather than serving a rendition AVPlayer would choke on.
        let dormant = HLSRemuxer.routeAll(candidates: candidates, best: 1, canBridge: bridgeNothing)
        #expect(dormant == [HLSRemuxer.AudioRoute(index: 2, mode: .streamCopy)])

        // With the encoder present the same source carries both, TrueHD first
        // (it is the best track, and bridged surround beats an AAC downmix).
        let live = HLSRemuxer.routeAll(candidates: candidates, best: 1, canBridge: bridgeEverything)
        #expect(live == [
            HLSRemuxer.AudioRoute(index: 1, mode: .bridge),
            HLSRemuxer.AudioRoute(index: 2, mode: .streamCopy),
        ])
    }

    @Test("A silent source produces no renditions")
    func noRenditionsWithoutAudio() {
        #expect(HLSRemuxer.routeAll(candidates: [], best: nil, canBridge: bridgeEverything).isEmpty)
    }

    @Test("The bridgeable set covers the codecs phase 3 promised, and no copyable one")
    func bridgeableSetShape() {
        for codec in [AV_CODEC_ID_TRUEHD, AV_CODEC_ID_DTS, AV_CODEC_ID_MP3,
                      AV_CODEC_ID_MP2, AV_CODEC_ID_OPUS, AV_CODEC_ID_VORBIS] {
            #expect(AudioBridge.bridgeableAudio.contains(codec))
        }
        // Copyable codecs must never be routed through a re-encode — that would
        // be the Atmos downgrade this whole design exists to avoid.
        for codec in [AV_CODEC_ID_AAC, AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3,
                      AV_CODEC_ID_FLAC, AV_CODEC_ID_ALAC] {
            #expect(!AudioBridge.bridgeableAudio.contains(codec))
        }
    }

    @Test("The codecs this phase targets all have decoders in the linked FFmpeg")
    func decodersPresent() {
        for codec in [AV_CODEC_ID_TRUEHD, AV_CODEC_ID_DTS, AV_CODEC_ID_MP3, AV_CODEC_ID_MP2,
                      AV_CODEC_ID_OPUS, AV_CODEC_ID_VORBIS, AV_CODEC_ID_PCM_S16LE,
                      AV_CODEC_ID_PCM_S24LE, AV_CODEC_ID_PCM_BLURAY] {
            let name = avcodec_get_name(codec).map { String(cString: $0) } ?? "?"
            #expect(avcodec_find_decoder(codec) != nil, "no decoder for \(name)")
        }
    }

    @Test("A codec whose decoder this build lacks is never routed to the bridge")
    func gatesOnDecoderAvailability() {
        // Stock MPVKit ships `truehd` but not the older `mlp` decoder, so MLP is
        // in the bridgeable *class* yet unbridgeable in practice — exactly the
        // distinction `canBridge` exists to make, so a missing decoder becomes a
        // routing decision instead of a mid-session failure.
        if avcodec_find_decoder(AV_CODEC_ID_MLP) == nil {
            #expect(AudioBridge.bridgeableAudio.contains(AV_CODEC_ID_MLP))
            #expect(!AudioBridge.canBridge(codecID: AV_CODEC_ID_MLP))
        }
    }

    @Test("Bridging is only offered when the EAC3 encoder actually exists")
    func gatesOnEncoderAvailability() {
        // Documents the current MPVKit reality: no eac3 encoder is compiled in,
        // so every bridge route is off and v0's behaviour stands. The assertion
        // is written both ways so it keeps holding once the fork enables it.
        #expect(
            AudioBridge.canBridge(codecID: AV_CODEC_ID_TRUEHD) == AudioBridge.isEncoderAvailable
        )
    }
}

/// End-to-end exercise of the real libav* chain — decoder, resampler, FIFO,
/// encoder, flush — without a media file: the "compressed" input is LPCM, which
/// a `pcm_s16le` decoder reads directly, and the target encoder is one this
/// FFmpeg build actually has (stock MPVKit compiles no eac3 encoder, so the
/// EAC3-specific numbers still need the integration fixture noted in the PR).
@Suite("AudioBridge pipeline")
struct AudioBridgePipelineTests {

    private static let sampleRate: Int32 = 48_000

    /// An encoder present in every MPVKit build, standing in for eac3.
    private static var stubEncoder: AVCodecID? {
        for candidate in [AV_CODEC_ID_FLAC, AV_CODEC_ID_AAC, AV_CODEC_ID_ALAC]
        where avcodec_find_encoder(candidate) != nil {
            return candidate
        }
        return nil
    }

    /// `codecpar` describing interleaved 16-bit LPCM.
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

    /// One packet of `samples` frames of a quiet ramp, timestamped in the
    /// stream's time base (1/sampleRate, so a PTS *is* a sample index).
    private func makePacket(
        samples: Int32,
        channels: Int32,
        pts: Int64
    ) -> UnsafeMutablePointer<AVPacket> {
        let packet = av_packet_alloc()!
        av_new_packet(packet, samples * channels * 2)
        packet.pointee.data.withMemoryRebound(to: Int16.self, capacity: Int(samples * channels)) { words in
            for index in 0..<Int(samples * channels) {
                words[index] = Int16(truncatingIfNeeded: index * 17)
            }
        }
        packet.pointee.pts = pts
        packet.pointee.dts = pts
        packet.pointee.duration = Int64(samples)
        return packet
    }

    @Test("A 5.1 source runs decode → resample → FIFO → encode and anchors on the source PTS")
    func runsWholePipeline() throws {
        let target = try #require(Self.stubEncoder, "no audio encoder in this FFmpeg build")
        let channels: Int32 = 6
        let par = makeCodecpar(channels: channels)
        defer { var par: UnsafeMutablePointer<AVCodecParameters>? = par; avcodec_parameters_free(&par) }

        let bridge = try AudioBridge(
            codecpar: par,
            timeBase: AVRational(num: 1, den: Self.sampleRate),
            globalHeader: false,
            targetCodec: target
        )
        defer { bridge.close() }

        // Start 2 s in, so an anchored (rather than zero-based) timeline is
        // observable: the first emitted packet must land at 96_000, not 0.
        let startPTS: Int64 = 96_000
        let samplesPerPacket: Int32 = 1_000
        var timestamps: [Int64] = []

        for index in 0..<20 {
            let pts = startPTS + Int64(index) * Int64(samplesPerPacket)
            let packet = makePacket(samples: samplesPerPacket, channels: channels, pts: pts)
            defer { var packet: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&packet) }
            try bridge.feed(packet) { encoded in
                timestamps.append(encoded.pointee.pts)
            }
        }
        try bridge.flush { encoded in
            timestamps.append(encoded.pointee.pts)
        }

        #expect(!timestamps.isEmpty, "the bridge produced no packets")
        #expect(bridge.progress.inputPackets == 20)
        #expect(bridge.progress.decodedFrames > 0)
        #expect(bridge.progress.resampledSamples == 20_000)
        #expect(bridge.progress.outputPackets == timestamps.count)
        #expect(timestamps.first == startPTS)
        #expect(timestamps == timestamps.sorted(), "timestamps must be monotonic")
        // 20 000 input samples went in and the flush leaves nothing behind, so
        // the output spans the input's duration: the last packet starts within
        // one encoder frame of the end and never past it. (Exactly *at* the end
        // is legal — an encoder with `CAP_DELAY` can emit one trailing packet
        // stamped at the tail boundary.)
        let end = startPTS + 20 * Int64(samplesPerPacket)
        #expect(timestamps.last! <= end)
        #expect(timestamps.last! >= end - 2 * 4_608)
        #expect(bridge.routeDescription.contains("pcm_s16le"))
    }

    @Test("Feeding after the flush is a no-op, not an error storm")
    func feedAfterFlushIsInert() throws {
        let target = try #require(Self.stubEncoder, "no audio encoder in this FFmpeg build")
        let par = makeCodecpar(channels: 2)
        defer { var par: UnsafeMutablePointer<AVCodecParameters>? = par; avcodec_parameters_free(&par) }

        let bridge = try AudioBridge(
            codecpar: par,
            timeBase: AVRational(num: 1, den: Self.sampleRate),
            globalHeader: false,
            targetCodec: target
        )
        defer { bridge.close() }

        let packet = makePacket(samples: 5_000, channels: 2, pts: 0)
        defer { var packet: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&packet) }
        try bridge.feed(packet) { _ in }
        try bridge.flush { _ in }

        var afterFlush = 0
        try bridge.feed(packet) { _ in afterFlush += 1 }
        try bridge.flush { _ in afterFlush += 1 }
        #expect(afterFlush == 0)
    }

    @Test("A gap in the source re-anchors the output instead of drifting")
    func gapReanchors() throws {
        let target = try #require(Self.stubEncoder, "no audio encoder in this FFmpeg build")
        let par = makeCodecpar(channels: 2)
        defer { var par: UnsafeMutablePointer<AVCodecParameters>? = par; avcodec_parameters_free(&par) }

        let bridge = try AudioBridge(
            codecpar: par,
            timeBase: AVRational(num: 1, den: Self.sampleRate),
            globalHeader: false,
            targetCodec: target
        )
        defer { bridge.close() }

        var timestamps: [Int64] = []
        let emit: AudioBridge.Emit = { timestamps.append($0.pointee.pts) }

        // 10 000 samples, then a 5 s hole, then more audio. The packets after
        // the hole must carry post-hole timestamps — silence-filling would put
        // them 5 s early and desync the rest of the file.
        for index in 0..<10 {
            let packet = makePacket(samples: 1_000, channels: 2, pts: Int64(index) * 1_000)
            defer { var packet: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&packet) }
            try bridge.feed(packet, emit: emit)
        }
        let afterGapStart: Int64 = 10_000 + 5 * Int64(Self.sampleRate)
        for index in 0..<10 {
            let packet = makePacket(
                samples: 1_000,
                channels: 2,
                pts: afterGapStart + Int64(index) * 1_000
            )
            defer { var packet: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&packet) }
            try bridge.feed(packet, emit: emit)
        }
        try bridge.flush(emit: emit)

        #expect(timestamps.first == 0)
        #expect(timestamps.contains { $0 >= afterGapStart - 4_608 })
        #expect(timestamps.last! >= afterGapStart)
        // No fabricated PCM: the count stays near 20 000 samples' worth, not
        // 250 000 (the gap filled in).
        let span = timestamps.last! - timestamps.first!
        #expect(span > 5 * Int64(Self.sampleRate), "the gap must move the timeline")
        #expect(timestamps.count < 20, "no silence was invented to cover the gap")
    }
}
