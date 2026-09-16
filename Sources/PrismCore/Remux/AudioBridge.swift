import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Libswresample

/// Decode → resample → re-encode for audio the HLS-fMP4 pipeline can't
/// stream-copy (roadmap phase 3).
///
/// `HLSRemuxer` copies AAC/AC3/EAC3/FLAC/ALAC bit-for-bit — that path must never
/// change, because it's the one that keeps Atmos objects alive. Everything else
/// (TrueHD, MLP, DTS, DTS-HD MA, MP3, MP2, Opus, Vorbis, PCM) is either illegal
/// in ISOBMFF/HLS or something AVPlayer won't decode, so v0 either dropped it or
/// fell back to a lesser compatibility track. This bridge gives those sources a
/// track AVPlayer *does* take, in surround.
///
/// Target codec is **EAC3 at 128 kbps per channel** (256 stereo, 768 for 5.1).
/// The reasoning is about the sink, not the file: AVPlayer hands an encoded
/// EAC3 elementary stream to HDMI as a bitstream, so a soundbar or a basic AVR
/// decodes its own 5.1 — which is the majority install base. The lossless
/// alternative (FLAC 7.1) makes AVPlayer emit multichannel LPCM, and a route
/// that only accepts stereo LPCM silently downmixes it, i.e. the lossless
/// choice is the one that loses surround more often. Object metadata is gone
/// either way: FFmpeg's EAC3 encoder produces no JOC, so a TrueHD-MAT or
/// DTS:X source arrives here already reduced to its channel bed. That's an
/// accepted downgrade for tracks that otherwise wouldn't play at all — a real
/// EAC3+JOC source never enters this class, it stream-copies.
///
/// Shape of the pipeline, and why each stage exists:
///
/// ```
/// compressed packets ─► decoder ─► swresample ─► av_audio_fifo ─► EAC3 encoder ─► packets
///                                  (to FLTP,      (1536-sample     (encoder tb =
///                                   48 kHz,        framing)         1/sample_rate)
///                                   negotiated
///                                   layout)
/// ```
///
/// - The resampler is unavoidable: the encoder wants FLTP at one of its
///   supported rates, decoders hand out whatever they like (S32P for the
///   lossless XLL/MLP family, FLTP for Opus/Vorbis, S16 for MP2, …).
/// - The FIFO is unavoidable too: FFmpeg's EAC3 encoder is a fixed-frame-size
///   encoder (1536 samples/frame) with neither `VARIABLE_FRAME_SIZE` nor
///   `SMALL_LAST_FRAME`, and one decoded TrueHD/DTS frame is nothing like 1536
///   samples. Feeding it a short frame is an immediate `EINVAL`, so PCM is
///   accumulated and handed over in exact frames.
/// - Timestamps ride the encoder's own time base (1/sample_rate) and are
///   *anchored on the source*, never counted from zero: the caller rescales the
///   emitted packets onto the output stream. A zero-based audio timeline inside
///   fragments whose video carries real source PTS is the classic way to make
///   AVPlayer accept a playlist and then play nothing.
///
/// Availability: this needs FFmpeg's `eac3` encoder, which stock MPVKit does
/// **not** compile in (it ships the ac3/eac3 *decoders* only).
/// `isEncoderAvailable` reports that honestly and `HLSRemuxer` keeps its v0
/// fallback when the answer is no — see the notes on that property.
final class AudioBridge {
    private(set) var progress = AudioBridgeProgress()
    var onProgress: ((AudioBridgeProgress) -> Void)?

    enum Failure: Error, CustomStringConvertible {
        /// FFmpeg was built without the `eac3` encoder (stock MPVKit). Nothing
        /// the host can do at runtime; the build has to enable it.
        case encoderUnavailable
        /// No decoder for the source codec in this FFmpeg build.
        case decoderUnavailable(String)
        /// The source's channel count is outside what the encoder can express.
        case channelLayoutUnsupported(Int32)
        /// Dialogue boost was asked of a track it can't honestly apply to —
        /// no centre channel to favour (stereo/mono), or a layout `pan` can't
        /// express. The rendition is skipped; the base track is unaffected.
        case dialogueBoostIneligible(String)
        case allocationFailed(String)

        var description: String {
            switch self {
            case .encoderUnavailable:
                return "FFmpeg build has neither an eac3 nor an aac encoder"
            case .decoderUnavailable(let name):
                return "FFmpeg build has no decoder for \(name)"
            case .channelLayoutUnsupported(let count):
                return "no encoder channel layout fits \(count) source channels"
            case .dialogueBoostIneligible(let why):
                return "dialogue boost is not applicable: \(why)"
            case .allocationFailed(let what):
                return "\(what) allocation failed"
            }
        }
    }

    /// A packet the bridge produced, plus the time base its timestamps are in.
    /// The caller rescales onto its output stream — the bridge deliberately
    /// knows nothing about the muxer.
    typealias Emit = (UnsafeMutablePointer<AVPacket>) throws -> Void

    // MARK: - Codec classification

    /// Codecs worth bridging: everything AVPlayer's fMP4 path can't take by
    /// stream-copy but that we can still decode. Kept explicit rather than
    /// "anything not copyable" so an exotic source (say a codec whose decoder
    /// this build lacks) is diagnosed as unroutable instead of failing halfway
    /// through a session.
    static let bridgeableAudio: Set<AVCodecID> = [
        AV_CODEC_ID_TRUEHD, AV_CODEC_ID_MLP,
        AV_CODEC_ID_DTS,
        AV_CODEC_ID_MP3, AV_CODEC_ID_MP2,
        AV_CODEC_ID_OPUS, AV_CODEC_ID_VORBIS,
        AV_CODEC_ID_PCM_S16LE, AV_CODEC_ID_PCM_S16BE,
        AV_CODEC_ID_PCM_S24LE, AV_CODEC_ID_PCM_S24BE,
        AV_CODEC_ID_PCM_S32LE, AV_CODEC_ID_PCM_S32BE,
        AV_CODEC_ID_PCM_F32LE, AV_CODEC_ID_PCM_BLURAY, AV_CODEC_ID_PCM_DVD,
    ]

    /// DTS-HD MA / DTS-X are `AV_CODEC_ID_DTS` with a profile, so no separate
    /// entry is needed above — libavcodec's `dca` decoder handles the core plus
    /// the XLL extension substream, and what reaches the encoder is the bed.

    /// Whether FFmpeg in *this* build can encode the bridge's target codec.
    ///
    /// Stock MPVKit answers `false`: its FFmpeg is configured for a player, so
    /// audio encoders are limited to aac/alac/flac/pcm. The bridge is written
    /// against `eac3` anyway because that's the codec the surround story needs,
    /// and enabling it is a one-line configure change in the MPVKit fork Aether
    /// already vendors (`--enable-encoder=eac3`; it's native FFmpeg code, no
    /// external library, no licensing change). Until then this gate keeps the
    /// v0 behaviour intact instead of turning a playable source into a failed
    /// session.
    static var isEncoderAvailable: Bool {
        findEncoder(defaultTargetCodec) != nil
    }

    /// What the bridge re-encodes to: EAC3 when the build has that encoder, for
    /// the reasons in the type's docs, otherwise AAC, which every FFmpeg build
    /// carries because it is FFmpeg's own code.
    ///
    /// Stock MPVKit ships no `eac3` encoder, and with EAC3 as the only target
    /// every DTS or TrueHD source left the remux path for the software renderer
    /// — which draws its own frames, so on visionOS the film lost docking, the
    /// picker and the theater (Cinema, 2026-09-06). AAC 5.1 keeps the source on
    /// `AVPlayer`: no bitstream passthrough to an AVR, which the headset and
    /// the phone never had, and a bed mix either way. The encoder is asked
    /// through the same negotiation as EAC3 (layouts, rates, FLTP, 1024-sample
    /// frames), so nothing below this line knows which one answered.
    static var defaultTargetCodec: AVCodecID {
        findEncoder(AV_CODEC_ID_EAC3) != nil ? AV_CODEC_ID_EAC3 : AV_CODEC_ID_AAC
    }

    /// FFmpeg's name for `defaultTargetCodec` — what the master playlist's
    /// `CODECS` attribute is derived from before a bridge exists.
    static var defaultTargetCodecName: String {
        avcodec_get_name(defaultTargetCodec).map { String(cString: $0) } ?? "aac"
    }

    private static func findEncoder(_ codecID: AVCodecID) -> UnsafePointer<AVCodec>? {
        avcodec_find_encoder(codecID)
    }

    /// Can this stream actually be bridged here and now — right class of codec,
    /// decoder present, encoder present?
    static func canBridge(codecID: AVCodecID) -> Bool {
        bridgeableAudio.contains(codecID)
            && avcodec_find_decoder(codecID) != nil
            && isEncoderAvailable
    }

    /// Can this build decode `codecID` and re-encode it — the dialogue-boost
    /// question, which deliberately ignores `bridgeableAudio`: a boost
    /// rendition is derived from tracks that normally *stream-copy* (EAC3,
    /// AC3, AAC, …), and those decoders every player build ships.
    static func canDecodeForBoost(codecID: AVCodecID) -> Bool {
        avcodec_find_decoder(codecID) != nil && isEncoderAvailable
    }

    // MARK: - State

    private var decoderCtx: UnsafeMutablePointer<AVCodecContext>?
    private var encoderCtx: UnsafeMutablePointer<AVCodecContext>?
    private var swrCtx: OpaquePointer?
    private var fifo: OpaquePointer?

    private var decodedFrame: UnsafeMutablePointer<AVFrame>?
    private var encoderFrame: UnsafeMutablePointer<AVFrame>?
    private var encodedPacket: UnsafeMutablePointer<AVPacket>?

    /// Scratch for one `swr_convert` output, grown on demand.
    private var convertedData: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?
    private var convertedCapacity: Int32 = 0

    /// The input side the resampler is currently configured for. Re-derived
    /// from every decoded frame rather than trusted from `codecpar`, because
    /// libswresample reads the raw planes according to *its* configuration: a
    /// dca/mlp stream often reports `AV_SAMPLE_FMT_NONE` until a frame has been
    /// decoded, and reading S32P planes as FLTP is loud digital noise, not a
    /// subtle bug.
    private var swrInFormat = AV_SAMPLE_FMT_NONE
    private var swrInRate: Int32 = 0
    private var swrInLayout = AVChannelLayout()

    /// Present only on a dialogue-boost rendition's bridge: decoded frames
    /// detour through `abuffer → pan → abuffersink` before the resampler.
    private var boostFilter: DialogueBoostFilter?

    private var clock: BridgeClock
    private var chunker: FrameChunker

    /// `avcodec_send_frame(enc, nil)` puts the encoder in a terminal draining
    /// state, so a flushed bridge accepts no more input. Latched so a late
    /// `feed` after EOF is a no-op instead of an error storm.
    private var drained = false

    private let sourceTimeBase: AVRational

    // MARK: - Lifecycle

    /// Opens decoder and encoder eagerly, because the caller needs
    /// `configure(outputStream:)` to fill in codec parameters *before*
    /// `avformat_write_header` — the muxer writes the audio sample entry from
    /// them.
    ///
    /// - Parameters:
    ///   - codecpar: the source stream's parameters.
    ///   - timeBase: the source stream's time base; packet timestamps arrive in it.
    ///   - globalHeader: set when the output format wants extradata in the
    ///     header (`AVFMT_GLOBALHEADER`). EAC3 has no extradata, but the flag
    ///     is what tells an encoder not to repeat headers in-band, so it is
    ///     passed through rather than assumed.
    ///   - dialogueBoost: when set, decoded frames pass a centre-favouring
    ///     filter graph before re-encoding (see `DialogueBoostFilter`).
    ///     Throws `dialogueBoostIneligible` for a source whose declared layout
    ///     has no centre to favour, so the caller can skip the rendition
    ///     instead of serving a duplicate of the base track.
    init(
        codecpar: UnsafePointer<AVCodecParameters>,
        timeBase: AVRational,
        globalHeader: Bool,
        dialogueBoost: DialogueBoostLevel? = nil,
        targetCodec: AVCodecID = AudioBridge.defaultTargetCodec
    ) throws {
        self.sourceTimeBase = timeBase

        // Decoder.
        let codecID = codecpar.pointee.codec_id
        guard let decoder = avcodec_find_decoder(codecID) else {
            let name = avcodec_get_name(codecID).map { String(cString: $0) } ?? "unknown"
            throw Failure.decoderUnavailable(name)
        }
        guard let decCtx = avcodec_alloc_context3(decoder) else {
            throw Failure.allocationFailed("decoder context")
        }
        decoderCtx = decCtx
        try FFmpegError.check(
            avcodec_parameters_to_context(decCtx, codecpar),
            "avcodec_parameters_to_context(audio decoder)"
        )
        // Decoded frames get their PTS in this time base — the one packets
        // arrive in — which is what the anchoring math below assumes.
        decCtx.pointee.pkt_timebase = timeBase
        try FFmpegError.check(avcodec_open2(decCtx, decoder, nil), "avcodec_open2(audio decoder)")

        // Encoder.
        guard let encoder = Self.findEncoder(targetCodec) else { throw Failure.encoderUnavailable }
        guard let encCtx = avcodec_alloc_context3(encoder) else {
            throw Failure.allocationFailed("encoder context")
        }
        encoderCtx = encCtx

        let sourceChannels = codecpar.pointee.ch_layout.nb_channels
        // Shallow value copy so the immutable `codecpar` can be passed to the
        // layout API (which takes non-const pointers); never uninitialized,
        // because a custom-order layout's channel map still belongs to codecpar.
        var sourceParameterLayout = codecpar.pointee.ch_layout
        var sourceLayout = AVChannelLayout()
        defer { av_channel_layout_uninit(&sourceLayout) }
        if sourceChannels > 0, av_channel_layout_check(&sourceParameterLayout) != 0 {
            try FFmpegError.check(
                av_channel_layout_copy(&sourceLayout, &sourceParameterLayout),
                "av_channel_layout_copy(source)"
            )
        } else {
            // TrueHD/DTS can report an unresolved layout before the first frame
            // is decoded. 5.1 is the useful guess for this codec class; the
            // resampler reconfigures its *input* side per frame anyway, so a
            // wrong guess costs a downmix, not a broken session.
            av_channel_layout_default(&sourceLayout, sourceChannels > 0 ? sourceChannels : 6)
        }

        if let dialogueBoost {
            guard DialogueBoostFilter.isAvailable else {
                throw Failure.dialogueBoostIneligible("this FFmpeg build has no pan filter")
            }
            // The declared layout is a claim (see the guess above), so this is
            // a precheck, not the verdict: the filter re-derives eligibility
            // from every decoded frame and passes through if the claim lied.
            // Refusing here is what keeps a stereo track from paying for a
            // rendition that could only duplicate it.
            guard DialogueBoostFilter.layoutIsEligible(&sourceLayout) else {
                throw Failure.dialogueBoostIneligible(
                    "\(Self.describe(sourceLayout)) has no centre channel to favour"
                )
            }
            boostFilter = DialogueBoostFilter(level: dialogueBoost, timeBase: timeBase)
        }

        var encoderLayout = try Self.negotiateLayout(for: encoder, source: sourceLayout)
        defer { av_channel_layout_uninit(&encoderLayout) }
        try FFmpegError.check(
            av_channel_layout_copy(&encCtx.pointee.ch_layout, &encoderLayout),
            "av_channel_layout_copy(encoder)"
        )

        let channels = encoderLayout.nb_channels
        encCtx.pointee.sample_rate = Self.negotiateSampleRate(
            for: encoder,
            source: codecpar.pointee.sample_rate
        )
        encCtx.pointee.sample_fmt = Self.negotiateSampleFormat(for: encoder)
        // 128 kbps per channel: 256 stereo, 768 for 5.1 — the rates broadcast
        // EAC3 uses for the same layouts, comfortably transparent for a bed mix
        // and well inside what every HDMI sink accepts. A lossless target
        // ignores it.
        encCtx.pointee.bit_rate = Int64(channels) * 128_000
        // Encoder time base is samples: the only tick that can't drift against
        // the sample count the FIFO hands out.
        encCtx.pointee.time_base = AVRational(num: 1, den: encCtx.pointee.sample_rate)
        if globalHeader {
            encCtx.pointee.flags |= AV_CODEC_FLAG_GLOBAL_HEADER
        }
        try FFmpegError.check(avcodec_open2(encCtx, encoder, nil), "avcodec_open2(encoder)")

        // `frame_size` is authoritative only after open (1536 for EAC3). A zero
        // here would mean a variable-frame-size encoder, in which case any
        // chunk is legal and we pick something segment-friendly.
        let frameSize = encCtx.pointee.frame_size > 0 ? Int(encCtx.pointee.frame_size) : 1536
        let capabilities = encoder.pointee.capabilities
        let acceptsShortFrame =
            capabilities & AV_CODEC_CAP_VARIABLE_FRAME_SIZE != 0
            || capabilities & AV_CODEC_CAP_SMALL_LAST_FRAME != 0
        chunker = FrameChunker(frameSize: frameSize, padsFinalFrame: !acceptsShortFrame)
        clock = BridgeClock(
            sampleRate: encCtx.pointee.sample_rate,
            // A tenth of a second: larger than any jitter a container's audio
            // timestamps show, far smaller than a real gap (a missing chunk of
            // audio in a badly muxed MKV, or the seek discontinuity a later
            // phase's demand-driven producer will create).
            gapTolerance: Int64(encCtx.pointee.sample_rate) / 10
        )

        guard let fifo = av_audio_fifo_alloc(encCtx.pointee.sample_fmt, channels, Int32(frameSize * 4)) else {
            throw Failure.allocationFailed("audio FIFO")
        }
        self.fifo = fifo

        decodedFrame = av_frame_alloc()
        encodedPacket = av_packet_alloc()
        guard decodedFrame != nil, encodedPacket != nil else {
            throw Failure.allocationFailed("bridge frame/packet")
        }
        encoderFrame = try Self.makeEncoderFrame(encCtx, frameSize: frameSize)
    }

    deinit {
        close()
    }

    func close() {
        boostFilter?.close()
        boostFilter = nil
        av_frame_free(&decodedFrame)
        av_frame_free(&encoderFrame)
        av_packet_free(&encodedPacket)
        if let fifo {
            av_audio_fifo_free(fifo)
            self.fifo = nil
        }
        if swrCtx != nil {
            swr_free(&swrCtx)
        }
        av_channel_layout_uninit(&swrInLayout)
        if convertedData != nil {
            av_freep(&convertedData!.pointee)
            av_freep(&convertedData)
            convertedCapacity = 0
        }
        if decoderCtx != nil { avcodec_free_context(&decoderCtx) }
        if encoderCtx != nil { avcodec_free_context(&encoderCtx) }
    }

    /// Re-anchor without rebuilding: the decoder, encoder, resampler and
    /// filter graph all survive a demand-driven seek, only their BUFFERED
    /// state is stale — decoder frames from before the jump, PCM in the
    /// FIFO, the resampler's delay line, and the clock's notion of where the
    /// next frame should land. Opening a fresh bridge per seek (decoder open,
    /// encoder open, FIFO, frame allocations — per rendition, per seek) was
    /// most of what a scrub cost on a bridged track; this is the cheap
    /// equivalent. The muxer is still rebuilt by the caller (frag_discont
    /// needs a new one for the tfdt), and the encoder is NOT flushed: every
    /// `send_frame` is drained on the spot, so it holds nothing.
    ///
    /// Not after `flush`: EOF put both codec contexts into their terminal
    /// drain state, and while `avcodec_flush_buffers` revives a decoder, an
    /// encoder without `AV_CODEC_CAP_ENCODER_FLUSH` (EAC3's) cannot be
    /// reopened that way — `feed` would return at once and every reproduced
    /// segment would be silent (review finding). `isDrained` tells the
    /// caller to rebuild instead; a re-anchor after EOF is the rarer case.
    var isDrained: Bool { drained }

    func reset() {
        progress = AudioBridgeProgress()
        progress.encoderFrameSamples = Int(encoderCtx?.pointee.frame_size ?? 0)
        onProgress?(progress)
        if let decoderCtx { avcodec_flush_buffers(decoderCtx) }
        if let fifo { av_audio_fifo_reset(fifo) }
        // The resampler's delay line belongs to the old position; dropping
        // the context makes `reconfigureResamplerIfNeeded` build a fresh one
        // on the next frame, exactly as for a format change.
        if swrCtx != nil { swr_free(&swrCtx) }
        swrInFormat = AV_SAMPLE_FMT_NONE
        swrInRate = 0
        boostFilter?.reset()
        chunker.reset()
        clock.reset()
    }

    // MARK: - Output stream description

    /// Time base of the packets `feed`/`flush` emit (1/sample_rate).
    var timeBase: AVRational {
        encoderCtx?.pointee.time_base ?? AVRational(num: 1, den: 48_000)
    }

    /// FFmpeg's name for the codec this bridge emits (`eac3` or `aac`) — the
    /// honest source of the rendition's `CODECS` tag.
    var outputCodecName: String? {
        guard let encoderCtx else { return nil }
        return avcodec_get_name(encoderCtx.pointee.codec_id).map { String(cString: $0) }
    }

    /// Channels the encoder actually emits — the negotiated layout, not the
    /// source's (FFmpeg's EAC3 encoder caps at 6, so a 7.1 source leaves as
    /// 5.1). This is the honest `CHANNELS` value for the rendition.
    var outputChannelCount: Int? {
        guard let encoderCtx, encoderCtx.pointee.ch_layout.nb_channels > 0 else { return nil }
        return Int(encoderCtx.pointee.ch_layout.nb_channels)
    }

    /// Human-readable "what did we do to this track", for diagnostics and for
    /// the host's track UI (`"TrueHD 7.1 → EAC3 5.1"`).
    var routeDescription: String {
        guard let decoderCtx, let encoderCtx else { return "audio bridge (closed)" }
        let from = avcodec_get_name(decoderCtx.pointee.codec_id).map { String(cString: $0) } ?? "?"
        let to = avcodec_get_name(encoderCtx.pointee.codec_id).map { String(cString: $0) } ?? "?"
        let boost = boostFilter.map { " + dialogue boost (\($0.level.rawValue))" } ?? ""
        return "\(from) \(Self.describe(decoderCtx.pointee.ch_layout))"
            + " → \(to) \(Self.describe(encoderCtx.pointee.ch_layout))"
            + " @ \(encoderCtx.pointee.bit_rate / 1000) kbps" + boost
    }

    /// Fill an output stream's `codecpar` from the encoder — the parameters the
    /// muxer needs, taken from the context that will actually produce the
    /// packets (never copied from the source, whose codec no longer applies).
    func configure(outputStream: UnsafeMutablePointer<AVStream>) throws {
        guard let encoderCtx else { throw Failure.encoderUnavailable }
        try FFmpegError.check(
            avcodec_parameters_from_context(outputStream.pointee.codecpar, encoderCtx),
            "avcodec_parameters_from_context(encoder)"
        )
        outputStream.pointee.time_base = encoderCtx.pointee.time_base
    }

    // MARK: - Feeding

    /// Push one compressed source packet through the pipeline, emitting however
    /// many EAC3 packets the accumulated PCM completed (frequently zero, since
    /// input and output framing don't line up).
    func feed(_ packet: UnsafeMutablePointer<AVPacket>, emit: Emit) throws {
        guard !drained, let decoderCtx else { return }
        progress.inputPackets += 1
        progress.encoderFrameSamples = Int(encoderCtx?.pointee.frame_size ?? 0)
        defer { onProgress?(progress) }
        let sendResult = avcodec_send_packet(decoderCtx, packet)
        if sendResult < 0, sendResult != swift_AVERROR(EAGAIN) {
            throw FFmpegError(code: sendResult, operation: "avcodec_send_packet(audio)")
        }
        try drainDecoder(emit: emit)
        // EAGAIN means the decoder still holds output; the drain above cleared
        // it, so the packet is safe to re-offer.
        if sendResult == swift_AVERROR(EAGAIN) {
            try FFmpegError.check(
                avcodec_send_packet(decoderCtx, packet),
                "avcodec_send_packet(audio, retry)"
            )
            try drainDecoder(emit: emit)
        }
    }

    /// End of source: drain decoder, resampler, FIFO and encoder in that order.
    /// After this the bridge is spent (see `drained`).
    func flush(emit: Emit) throws {
        guard !drained, let decoderCtx, let encoderCtx else { return }
        defer { onProgress?(progress) }

        try FFmpegError.check(
            avcodec_send_packet(decoderCtx, nil),
            "avcodec_send_packet(audio, flush)"
        )
        try drainDecoder(emit: emit)

        // Boost-graph tail before the resampler's: downstream stages drain in
        // pipeline order or the last frames land behind earlier ones.
        if let boostFilter {
            try boostFilter.flush { filtered in
                try self.absorb(filtered)
            }
        }

        // Resampler tail: whatever its internal delay line still holds.
        if swrCtx != nil {
            try convertIntoFIFO(frame: nil)
        }
        try encodeFromFIFO(final: true, emit: emit)

        drained = true
        try FFmpegError.check(avcodec_send_frame(encoderCtx, nil), "avcodec_send_frame(flush)")
        try drainEncoder(emit: emit)
        if progress.inputPackets > 0 && progress.outputPackets == 0 {
            throw AudioBridgeFailure.producedNoAudio(progress)
        }
    }

    private func drainDecoder(emit: Emit) throws {
        guard let decoderCtx, let frame = decodedFrame else { return }
        while true {
            let result = avcodec_receive_frame(decoderCtx, frame)
            if result == swift_AVERROR(EAGAIN) || result == swift_AVERROR_EOF() { return }
            try FFmpegError.check(result, "avcodec_receive_frame(audio)")
            progress.decodedFrames += 1
            defer { av_frame_unref(frame) }

            if let boostFilter {
                // Frames come out of the graph in the same time base with the
                // same sample count, so the clock and FIFO logic in `absorb`
                // don't know the detour happened.
                try boostFilter.push(frame) { filtered in
                    try self.absorb(filtered)
                }
            } else {
                try absorb(frame)
            }
            try encodeFromFIFO(final: false, emit: emit)
        }
    }

    /// One decoded (or filtered) frame into the FIFO, resampler reconfigured
    /// and the clock told first — the invariant order of the ingest side.
    private func absorb(_ frame: UnsafeMutablePointer<AVFrame>) throws {
        try reconfigureResamplerIfNeeded(for: frame)
        noteTimestamps(of: frame)
        try convertIntoFIFO(frame: frame)
    }

    // MARK: - Resampling

    private func reconfigureResamplerIfNeeded(for frame: UnsafeMutablePointer<AVFrame>) throws {
        guard let encoderCtx else { return }
        let frameFormat = AVSampleFormat(rawValue: frame.pointee.format)
        let matches = swrCtx != nil
            && frameFormat == swrInFormat
            && frame.pointee.sample_rate == swrInRate
            && av_channel_layout_compare(&frame.pointee.ch_layout, &swrInLayout) == 0
        if matches { return }

        // A reconfiguration drops whatever the old context buffered. That only
        // happens on the first frame or on a genuine mid-stream format change
        // (a container splicing two encodings), where a sub-millisecond seam is
        // the cheaper outcome than a rebuilt-and-resynced pipeline.
        if swrCtx != nil {
            swr_free(&swrCtx)
        }

        var newContext: OpaquePointer?
        try FFmpegError.check(
            swr_alloc_set_opts2(
                &newContext,
                &encoderCtx.pointee.ch_layout,
                encoderCtx.pointee.sample_fmt,
                encoderCtx.pointee.sample_rate,
                &frame.pointee.ch_layout,
                frameFormat,
                frame.pointee.sample_rate,
                0,
                nil
            ),
            "swr_alloc_set_opts2"
        )
        guard let newContext else { throw Failure.allocationFailed("resampler") }
        try FFmpegError.check(swr_init(newContext), "swr_init")
        swrCtx = newContext

        swrInFormat = frameFormat
        swrInRate = frame.pointee.sample_rate
        av_channel_layout_uninit(&swrInLayout)
        try FFmpegError.check(
            av_channel_layout_copy(&swrInLayout, &frame.pointee.ch_layout),
            "av_channel_layout_copy(resampler input)"
        )
    }

    /// Resample one frame (or `nil` to drain the delay line) and append the
    /// result to the FIFO.
    private func convertIntoFIFO(frame: UnsafeMutablePointer<AVFrame>?) throws {
        guard let encoderCtx, let swr = swrCtx, let fifo else { return }

        let inSamples = frame?.pointee.nb_samples ?? 0
        // Ask the resampler how much it may produce: rate conversion and its
        // own delay both make this larger than the input count.
        let outSamples = Int32(swr_get_out_samples(swr, inSamples))
        guard outSamples > 0 else { return }
        try growConvertedBuffer(to: outSamples)

        let inputPlanes: UnsafeMutablePointer<UnsafePointer<UInt8>?>? = frame.flatMap {
            UnsafeMutableRawPointer($0.pointee.extended_data)?
                .assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
        }
        let produced = swr_convert(swr, convertedData, outSamples, inputPlanes, inSamples)
        try FFmpegError.check(produced, "swr_convert")
        guard produced > 0 else { return }

        try FFmpegError.check(
            av_audio_fifo_realloc(fifo, av_audio_fifo_size(fifo) + produced),
            "av_audio_fifo_realloc"
        )
        let planes = UnsafeMutableRawPointer(convertedData!)
            .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        try FFmpegError.check(
            av_audio_fifo_write(fifo, planes, produced),
            "av_audio_fifo_write"
        )
        chunker.appended(Int(produced))
        progress.resampledSamples += Int(produced)
    }

    private func growConvertedBuffer(to samples: Int32) throws {
        guard let encoderCtx else { return }
        if convertedCapacity >= samples, convertedData != nil { return }
        if convertedData != nil {
            av_freep(&convertedData!.pointee)
            av_freep(&convertedData)
        }
        try FFmpegError.check(
            av_samples_alloc_array_and_samples(
                &convertedData,
                nil,
                encoderCtx.pointee.ch_layout.nb_channels,
                samples,
                encoderCtx.pointee.sample_fmt,
                0
            ),
            "av_samples_alloc_array_and_samples"
        )
        convertedCapacity = samples
    }

    // MARK: - Timestamps

    /// Convert the frame's source timestamp into encoder ticks and let the
    /// clock decide whether this frame continues the timeline or re-anchors it.
    private func noteTimestamps(of frame: UnsafeMutablePointer<AVFrame>) {
        guard let encoderCtx, let fifo else { return }
        let outRate = Int64(encoderCtx.pointee.sample_rate)
        let raw = frame.pointee.pts != swift_AV_NOPTS_VALUE()
            ? frame.pointee.pts
            : frame.pointee.best_effort_timestamp

        let pts: Int64? = raw != swift_AV_NOPTS_VALUE()
            ? av_rescale_q(raw, sourceTimeBase, encoderCtx.pointee.time_base)
            : nil
        // The frame's duration expressed in output samples, so the clock can
        // predict where the next frame should land regardless of the rate
        // conversion the resampler is doing.
        let sourceRate = Int64(frame.pointee.sample_rate > 0 ? frame.pointee.sample_rate : encoderCtx.pointee.sample_rate)
        let samplesAtOutputRate = Int(av_rescale(Int64(frame.pointee.nb_samples), outRate, sourceRate))

        let depth = Int(av_audio_fifo_size(fifo))
        clock.observe(framePTS: pts, frameSamples: samplesAtOutputRate, fifoDepth: depth)
    }

    // MARK: - Encoding

    private func encodeFromFIFO(final: Bool, emit: Emit) throws {
        guard let encoderCtx, let fifo, let frame = encoderFrame else { return }
        while let chunk = final ? chunker.nextChunkForFlush() : chunker.nextFullChunk() {
            try FFmpegError.check(av_frame_make_writable(frame), "av_frame_make_writable")
            let planes = UnsafeMutableRawPointer(frame.pointee.extended_data)!
                .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
            let read = av_audio_fifo_read(fifo, planes, Int32(chunk.samples))
            try FFmpegError.check(read, "av_audio_fifo_read")
            guard read > 0 else { break }

            if chunk.silencePadding > 0 {
                // Only ever the last frame at EOF: the encoder's fixed framing
                // has to be satisfied, so the tail gets up to 1535 samples
                // (32 ms) of silence. This is not gap filling — a *gap* inside
                // the stream re-anchors the clock instead, because fabricating
                // PCM to cover it would drift audio against video for the rest
                // of the file.
                av_samples_set_silence(
                    frame.pointee.extended_data,
                    Int32(chunk.samples),
                    Int32(chunk.silencePadding),
                    encoderCtx.pointee.ch_layout.nb_channels,
                    encoderCtx.pointee.sample_fmt
                )
            }
            let frameSamples = chunk.samples + chunk.silencePadding
            frame.pointee.nb_samples = Int32(frameSamples)
            // Advance by the real sample count: padding is a codec framing
            // artefact, not duration the source had.
            let pts = clock.stamp(chunk.samples)
            frame.pointee.pts = pts
            frame.pointee.duration = Int64(frameSamples)

            try FFmpegError.check(avcodec_send_frame(encoderCtx, frame), "avcodec_send_frame(encoder)")
            try drainEncoder(emit: emit)
        }
    }

    private func drainEncoder(emit: Emit) throws {
        guard let encoderCtx, let packet = encodedPacket else { return }
        while true {
            let result = avcodec_receive_packet(encoderCtx, packet)
            if result == swift_AVERROR(EAGAIN) || result == swift_AVERROR_EOF() { return }
            try FFmpegError.check(result, "avcodec_receive_packet(encoder)")
            defer { av_packet_unref(packet) }
            // EAC3 has no reordering, so dts follows pts; being explicit keeps
            // the muxer from inventing one.
            if packet.pointee.dts == swift_AV_NOPTS_VALUE() {
                packet.pointee.dts = packet.pointee.pts
            }
            packet.pointee.pos = -1
            try emit(packet)
            progress.outputPackets += 1
        }
    }

    // MARK: - Encoder capability negotiation

    /// Pick the encoder layout closest to the source's.
    ///
    /// FFmpeg's EAC3 encoder tops out at 5.1 — it declares mono … 5.1 and
    /// nothing wider — so a 7.1 TrueHD or DTS-HD MA source is downmixed to 5.1
    /// by the resampler rather than refused. Negotiating against the encoder's
    /// declared list instead of hardcoding that keeps the code honest if a
    /// build ever ships a wider EAC3 encoder (or a different target codec).
    private static func negotiateLayout(
        for encoder: UnsafePointer<AVCodec>,
        source: AVChannelLayout
    ) throws -> AVChannelLayout {
        var source = source
        var result = AVChannelLayout()

        var raw: UnsafeRawPointer?
        var count: Int32 = 0
        let query = avcodec_get_supported_config(
            nil, encoder, AV_CODEC_CONFIG_CHANNEL_LAYOUT, 0, &raw, &count
        )
        // No list means "anything goes" — keep the source layout.
        guard query >= 0, let raw, count > 0 else {
            try FFmpegError.check(
                av_channel_layout_copy(&result, &source),
                "av_channel_layout_copy(any-layout encoder)"
            )
            return result
        }

        let supported = raw.assumingMemoryBound(to: AVChannelLayout.self)
        var exact: AVChannelLayout?
        var widestFit: AVChannelLayout?
        for index in 0..<Int(count) {
            var candidate = supported[index]
            guard candidate.nb_channels > 0 else { break }
            if av_channel_layout_compare(&candidate, &source) == 0 {
                exact = candidate
                break
            }
            // Otherwise: the most channels that don't exceed the source, so a
            // 7.1 source lands on 5.1 and a mono source stays mono.
            if candidate.nb_channels <= source.nb_channels,
               candidate.nb_channels > (widestFit?.nb_channels ?? 0) {
                widestFit = candidate
            }
        }
        guard var chosen = exact ?? widestFit else {
            throw Failure.channelLayoutUnsupported(source.nb_channels)
        }
        try FFmpegError.check(
            av_channel_layout_copy(&result, &chosen),
            "av_channel_layout_copy(negotiated)"
        )
        return result
    }

    /// 48 kHz unless the source already sits on another rate the encoder
    /// supports — resampling rate is avoidable work and a small quality loss.
    private static func negotiateSampleRate(for encoder: UnsafePointer<AVCodec>, source: Int32) -> Int32 {
        var raw: UnsafeRawPointer?
        var count: Int32 = 0
        let query = avcodec_get_supported_config(
            nil, encoder, AV_CODEC_CONFIG_SAMPLE_RATE, 0, &raw, &count
        )
        guard query >= 0, let raw, count > 0 else { return source > 0 ? source : 48_000 }
        let rates = raw.assumingMemoryBound(to: Int32.self)
        var supported: [Int32] = []
        for index in 0..<Int(count) where rates[index] > 0 {
            supported.append(rates[index])
        }
        if supported.contains(source) { return source }
        if supported.contains(48_000) { return 48_000 }
        return supported.max() ?? 48_000
    }

    /// EAC3 is FLTP-only; ask anyway so the code survives a codec swap.
    private static func negotiateSampleFormat(for encoder: UnsafePointer<AVCodec>) -> AVSampleFormat {
        var raw: UnsafeRawPointer?
        var count: Int32 = 0
        let query = avcodec_get_supported_config(
            nil, encoder, AV_CODEC_CONFIG_SAMPLE_FORMAT, 0, &raw, &count
        )
        guard query >= 0, let raw, count > 0 else { return AV_SAMPLE_FMT_FLTP }
        let formats = raw.assumingMemoryBound(to: AVSampleFormat.self)
        for index in 0..<Int(count) where formats[index] == AV_SAMPLE_FMT_FLTP {
            return AV_SAMPLE_FMT_FLTP
        }
        return formats[0]
    }

    private static func makeEncoderFrame(
        _ encoderCtx: UnsafeMutablePointer<AVCodecContext>,
        frameSize: Int
    ) throws -> UnsafeMutablePointer<AVFrame> {
        guard let frame = av_frame_alloc() else {
            throw Failure.allocationFailed("encoder frame")
        }
        frame.pointee.nb_samples = Int32(frameSize)
        frame.pointee.format = encoderCtx.pointee.sample_fmt.rawValue
        frame.pointee.sample_rate = encoderCtx.pointee.sample_rate
        try FFmpegError.check(
            av_channel_layout_copy(&frame.pointee.ch_layout, &encoderCtx.pointee.ch_layout),
            "av_channel_layout_copy(encoder frame)"
        )
        try FFmpegError.check(av_frame_get_buffer(frame, 0), "av_frame_get_buffer(audio)")
        return frame
    }

    private static func describe(_ layout: AVChannelLayout) -> String {
        var layout = layout
        var buffer = [CChar](repeating: 0, count: 64)
        guard av_channel_layout_describe(&layout, &buffer, buffer.count) > 0 else {
            return "\(layout.nb_channels)ch"
        }
        return String(cString: buffer)
    }
}

// MARK: - Pure helpers

/// Turns "however many samples the resampler just produced" into the exact
/// frames a fixed-frame-size encoder accepts.
///
/// Split out from the bridge because the arithmetic is where an off-by-one
/// silently becomes a click every 32 ms, and it's testable without media: it
/// only tracks a sample count that mirrors the C FIFO's depth.
struct FrameChunker {
    /// Samples per encoder frame (1536 for EAC3).
    let frameSize: Int
    /// Whether a short final frame has to be padded with silence. False for
    /// encoders advertising `SMALL_LAST_FRAME`/`VARIABLE_FRAME_SIZE`.
    let padsFinalFrame: Bool

    /// Samples believed to be sitting in the FIFO.
    private(set) var pending = 0

    init(frameSize: Int, padsFinalFrame: Bool) {
        self.frameSize = max(1, frameSize)
        self.padsFinalFrame = padsFinalFrame
    }

    struct Chunk: Equatable {
        /// Real samples to read out of the FIFO.
        let samples: Int
        /// Silence appended to reach `frameSize`; only ever non-zero on the
        /// final chunk of a flush.
        let silencePadding: Int
    }

    mutating func appended(_ samples: Int) {
        pending += max(0, samples)
    }

    /// Forget the samples believed buffered — paired with a FIFO reset.
    mutating func reset() { pending = 0 }

    /// One full frame, or nil while the FIFO is short. Mid-stream this is the
    /// only accessor used — a partial frame stays buffered for the next packet.
    mutating func nextFullChunk() -> Chunk? {
        guard pending >= frameSize else { return nil }
        pending -= frameSize
        return Chunk(samples: frameSize, silencePadding: 0)
    }

    /// Full frames first, then the tail. At EOF nothing may stay behind, so the
    /// remainder is emitted either short (capable encoder) or padded.
    mutating func nextChunkForFlush() -> Chunk? {
        if let full = nextFullChunk() { return full }
        guard pending > 0 else { return nil }
        let tail = pending
        pending = 0
        return Chunk(samples: tail, silencePadding: padsFinalFrame ? frameSize - tail : 0)
    }
}

/// PTS bookkeeping for the encoder side, in encoder ticks (1 tick = 1 sample).
///
/// Two jobs, both about staying glued to the source timeline:
///
/// 1. **Anchor, don't count from zero.** The first frame's own timestamp sets
///    the counter, so bridged audio shares the video's timeline — including a
///    producer that starts mid-file, where a zero-based audio track would sit a
///    whole start-offset away from the video inside the same fragments and
///    AVPlayer would just play nothing.
/// 2. **Re-anchor across gaps.** When input timestamps jump further than
///    tolerance, the counter jumps with them instead of fabricating PCM to
///    bridge the hole: silence inserted to "fill" a gap makes every later frame
///    late by the gap's length, which is drift you can hear.
///
/// Pure and independently testable — it never touches libav* state.
struct BridgeClock {
    let sampleRate: Int32
    let gapTolerance: Int64

    /// PTS to stamp the next encoder frame with.
    private(set) var nextPTS: Int64 = 0
    private var anchored = false
    /// Where the next input frame is expected to start, if the stream is
    /// continuous.
    private var expectedInputPTS: Int64?

    /// Spelled out rather than left to the memberwise initializer.
    ///
    /// A struct with `private` stored properties gets a `private` memberwise
    /// init, and `private` means *this declaration's scope* — not the file. So
    /// `AudioBridge`, a different type a few hundred lines up in this same file,
    /// could not call it. Xcode 26.6 rejects that outright; a newer Swift lets it
    /// through, which is how it reached a release: every local build here runs on
    /// the beta toolchain, and Xcode Cloud — on the stable one — failed the
    /// archive (Aether build 358).
    init(sampleRate: Int32, gapTolerance: Int64) {
        self.sampleRate = sampleRate
        self.gapTolerance = gapTolerance
    }

    /// Record a decoded frame *before* its samples enter the FIFO.
    ///
    /// - Parameters:
    ///   - framePTS: the frame's timestamp in encoder ticks, or nil when the
    ///     source has none (then the counter simply keeps running).
    ///   - frameSamples: the frame's length in encoder ticks.
    ///   - fifoDepth: samples already buffered. Those belong *before* this
    ///     frame, so an anchor has to reach back past them or their packets
    ///     would be stamped with this frame's time.
    mutating func observe(framePTS: Int64?, frameSamples: Int, fifoDepth: Int) {
        guard let framePTS else {
            // Unknown timestamp: a re-anchor here would be a guess. Keep
            // counting, and don't let the next frame look like a gap.
            expectedInputPTS = nil
            return
        }
        let previousExpectation = expectedInputPTS
        expectedInputPTS = framePTS + Int64(frameSamples)

        let isDiscontinuous = previousExpectation.map { abs(framePTS - $0) > gapTolerance } ?? true
        if !anchored || isDiscontinuous {
            nextPTS = framePTS - Int64(fifoDepth)
            anchored = true
        }
    }

    /// Forget the anchor: the next frame's own timestamp re-anchors the
    /// counter, exactly as the first frame did — what a re-anchored producer
    /// needs, since the next frame comes from wherever the seek landed.
    mutating func reset() {
        anchored = false
        expectedInputPTS = nil
    }

    /// Take the PTS for a frame carrying `samples` of real audio.
    mutating func stamp(_ samples: Int) -> Int64 {
        defer { nextPTS += Int64(samples) }
        return nextPTS
    }
}
