import Foundation
import Libavformat
import Libavcodec
import Libavutil

// MARK: - Value types

/// How a variant's dynamic range is declared to AVPlayer. The raw values are
/// exactly the `VIDEO-RANGE` attribute values HLS defines, so the playlist
/// builder can print them directly.
public enum DynamicRange: String, Sendable, Equatable {
    case sdr = "SDR"
    /// HDR10 and every Dolby Vision profile whose base layer is PQ.
    case pq = "PQ"
    case hlg = "HLG"
}

/// The `hvcC` profile_tier_level fields, which are the only honest source for
/// an HEVC `CODECS` string.
///
/// `AVCodecParameters.profile` / `.level` alone cannot produce one: they carry
/// no tier flag, no profile space and — critically — no
/// `general_profile_compatibility_flags`, the element AVPlayer checks the
/// declaration against. So we read the record itself.
public struct HEVCConfigurationRecord: Sendable, Equatable {
    /// `general_profile_space`, 0…3 (printed as the '', 'A', 'B', 'C' prefix).
    public let profileSpace: UInt8
    /// `general_tier_flag`: 0 = Main tier ('L'), 1 = High tier ('H').
    public let tierFlag: UInt8
    /// `general_profile_idc`: 1 = Main, 2 = Main10, 4 = Rext, …
    public let profileIDC: UInt8
    /// `general_profile_compatibility_flags`, stored order (NOT reversed).
    /// A real Main10 record stores `0x20000000`.
    public let profileCompatibilityFlags: UInt32
    /// `general_constraint_indicator_flags`: 48 bits, right-aligned in the
    /// `UInt64` (byte 0 of the 6 is the most significant of the low 48).
    public let constraintIndicatorFlags: UInt64
    /// `general_level_idc` = level × 30 (L4.0 = 120, L5.1 = 153).
    public let levelIDC: UInt8

    public init(
        profileSpace: UInt8,
        tierFlag: UInt8,
        profileIDC: UInt8,
        profileCompatibilityFlags: UInt32,
        constraintIndicatorFlags: UInt64,
        levelIDC: UInt8
    ) {
        self.profileSpace = profileSpace
        self.tierFlag = tierFlag
        self.profileIDC = profileIDC
        self.profileCompatibilityFlags = profileCompatibilityFlags
        self.constraintIndicatorFlags = constraintIndicatorFlags
        self.levelIDC = levelIDC
    }

    /// Parses an ISO 14496-15 `HEVCDecoderConfigurationRecord` (the `hvcC` /
    /// `hev1` box payload, which is what libavformat hands us as HEVC
    /// `extradata` for MP4- and Matroska-sourced streams).
    ///
    /// Returns `nil` for anything else — most importantly Annex-B extradata
    /// (MPEG-TS sources, where the parameter sets arrive in band). Deriving a
    /// PTL from Annex-B means parsing the SPS, which phase 4 deliberately does
    /// not do: without a record we simply have no HEVC `CODECS` string, and
    /// the caller routes media-direct instead of guessing one.
    public static func parse(hvcC data: Data) -> HEVCConfigurationRecord? {
        // configurationVersion(1) + PTL(12) + … + numOfArrays: 23 bytes of
        // fixed header before the parameter-set arrays begin.
        guard data.count >= 23 else { return nil }
        let bytes = [UInt8](data)
        guard bytes[0] == 1 else { return nil }

        let ptl = bytes[1]
        var constraints: UInt64 = 0
        for index in 6...11 {
            constraints = (constraints << 8) | UInt64(bytes[index])
        }
        return HEVCConfigurationRecord(
            profileSpace: (ptl & 0xC0) >> 6,
            tierFlag: (ptl & 0x20) >> 5,
            profileIDC: ptl & 0x1F,
            profileCompatibilityFlags: (UInt32(bytes[2]) << 24) | (UInt32(bytes[3]) << 16)
                | (UInt32(bytes[4]) << 8) | UInt32(bytes[5]),
            constraintIndicatorFlags: constraints,
            levelIDC: bytes[12]
        )
    }
}

/// The three `avcC` bytes an H.264 `CODECS` string is made of.
///
/// The HEVC story above needs the whole profile_tier_level; H.264 needs exactly
/// `AVCProfileIndication`, `profile_compatibility` and `AVCLevelIndication`,
/// which is what `avc1.PPCCLL` prints. Read from the record rather than from
/// `AVCodecParameters.profile`/`.level` for the same reason: the compatibility
/// byte (constraint_set flags) exists nowhere else, and AVPlayer checks the
/// declaration against the init segment's own `avcC`.
public struct AVCConfigurationRecord: Sendable, Equatable {
    /// `AVCProfileIndication`: 66 = Baseline, 77 = Main, 100 = High.
    public let profileIDC: UInt8
    /// `profile_compatibility`, the constraint_set flags byte.
    public let profileCompatibility: UInt8
    /// `AVCLevelIndication` = level × 10 (L4.0 = 40, L5.1 = 51).
    public let levelIDC: UInt8

    public init(profileIDC: UInt8, profileCompatibility: UInt8, levelIDC: UInt8) {
        self.profileIDC = profileIDC
        self.profileCompatibility = profileCompatibility
        self.levelIDC = levelIDC
    }

    /// Parses an ISO 14496-15 `AVCDecoderConfigurationRecord` (the `avcC` box
    /// payload, which is what libavformat hands us as H.264 `extradata` for
    /// MP4- and Matroska-sourced streams).
    ///
    /// `nil` for Annex-B extradata (MPEG-TS), exactly like the `hvcC` parse:
    /// without a record there is no honest `CODECS` string, and the caller
    /// routes media-direct instead of guessing one.
    public static func parse(avcC data: Data) -> AVCConfigurationRecord? {
        // configurationVersion(1) + the three PTL bytes + lengthSizeMinusOne.
        guard data.count >= 5 else { return nil }
        let bytes = [UInt8](data)
        guard bytes[0] == 1 else { return nil }
        return AVCConfigurationRecord(
            profileIDC: bytes[1],
            profileCompatibility: bytes[2],
            levelIDC: bytes[3]
        )
    }
}

/// The `av1C` fields an AV1 `CODECS` string is made of (AV1 Codec ISO Media File
/// Format Binding, §2.3).
///
/// Small, but it has to be read rather than assumed: the level and tier decide
/// whether a decoder will accept the stream at all, and RFC 6381's AV1 form
/// carries them.
public struct AV1ConfigurationRecord: Sendable, Equatable {
    /// `seq_profile`: 0 = Main, 1 = High, 2 = Professional.
    public let profile: UInt8
    /// `seq_level_idx_0`, printed as two digits (level 4.0 is index 8).
    public let levelIndex: UInt8
    /// `seq_tier_0`: 0 = Main tier ('M'), 1 = High tier ('H').
    public let tier: UInt8
    /// Luma bit depth, derived from `high_bitdepth` + `twelve_bit`: 8, 10 or 12.
    public let bitDepth: UInt8
    public let isMonochrome: Bool

    public init(
        profile: UInt8, levelIndex: UInt8, tier: UInt8, bitDepth: UInt8, isMonochrome: Bool
    ) {
        self.profile = profile
        self.levelIndex = levelIndex
        self.tier = tier
        self.bitDepth = bitDepth
        self.isMonochrome = isMonochrome
    }

    /// Parses an `AV1CodecConfigurationRecord` (the `av1C` box payload, which is
    /// what libavformat hands over as AV1 extradata).
    ///
    /// `nil` for anything whose marker and version bytes don't match — an AV1
    /// stream with no config record has no honest `CODECS` string, and the caller
    /// then serves it media-direct rather than guessing a level.
    public static func parse(av1C data: Data) -> AV1ConfigurationRecord? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        // marker(1) must be 1, version(7) must be 1.
        guard bytes[0] & 0x80 != 0, bytes[0] & 0x7F == 1 else { return nil }

        let profile = (bytes[1] & 0xE0) >> 5
        let levelIndex = bytes[1] & 0x1F
        let tier = (bytes[2] & 0x80) >> 7
        let highBitDepth = bytes[2] & 0x40 != 0
        let twelveBit = bytes[2] & 0x20 != 0
        let monochrome = bytes[2] & 0x10 != 0

        // Twelve-bit exists only in the Professional profile; elsewhere the
        // high-bitdepth flag alone means 10.
        let bitDepth: UInt8
        if profile == 2, highBitDepth, twelveBit {
            bitDepth = 12
        } else {
            bitDepth = highBitDepth ? 10 : 8
        }

        return AV1ConfigurationRecord(
            profile: profile,
            levelIndex: levelIndex,
            tier: tier,
            bitDepth: bitDepth,
            isMonochrome: monochrome
        )
    }
}

/// The container's `AVDOVIDecoderConfigurationRecord` (the `dvcC` / `dvvC`
/// box), which is what decides the whole DV signaling route.
public struct DolbyVisionConfiguration: Sendable, Equatable {
    public let versionMajor: UInt8
    public let versionMinor: UInt8
    /// `dv_profile`: 5, 7, 8, … (the *major* profile only).
    public let profile: UInt8
    /// `dv_level`: the DV level, printed zero-padded in the codec tag.
    public let level: UInt8
    public let rpuPresent: Bool
    public let enhancementLayerPresent: Bool
    public let baseLayerPresent: Bool
    /// `dv_bl_signal_compatibility_id` — the sub-profile: 1 = HDR10 base
    /// (8.1), 2 = SDR/Rec.709 base (8.2), 4 = HLG base (8.4), 6 = Blu-ray
    /// HDR10 base. Zero for the profiles that have no base layer (5).
    public let baseLayerSignalCompatibilityID: UInt8

    public init(
        versionMajor: UInt8,
        versionMinor: UInt8,
        profile: UInt8,
        level: UInt8,
        rpuPresent: Bool,
        enhancementLayerPresent: Bool,
        baseLayerPresent: Bool,
        baseLayerSignalCompatibilityID: UInt8
    ) {
        self.versionMajor = versionMajor
        self.versionMinor = versionMinor
        self.profile = profile
        self.level = level
        self.rpuPresent = rpuPresent
        self.enhancementLayerPresent = enhancementLayerPresent
        self.baseLayerPresent = baseLayerPresent
        self.baseLayerSignalCompatibilityID = baseLayerSignalCompatibilityID
    }

    /// "5", "8.1", "8.4", "7" — the human profile name used in logs and in
    /// routing decisions.
    public var profileName: String {
        baseLayerSignalCompatibilityID == 0
            ? "\(profile)"
            : "\(profile).\(baseLayerSignalCompatibilityID)"
    }

    /// True for profiles whose base layer no Apple platform can present as DV
    /// *and* whose base is not even HDR: 8.2 carries a Rec.709 base, so the
    /// only honest signaling is plain `hvc1` SDR — no supplemental codec, no
    /// DV, on any display.
    public var hasSDRCompatibleBase: Bool {
        profile == 8 && baseLayerSignalCompatibilityID == 2
    }

    /// Profile 5 has no base layer at all (IPT-PQ), so it is either presented
    /// as DV or not at all.
    public var isSingleLayerDVOnly: Bool { profile == 5 }

    /// Profile 7 is dual-layer; Apple has no decoder for it. Phase 4's
    /// groundwork only *reports* it — the live RPU conversion to 8.1 is the
    /// next step.
    public var isDualLayer: Bool { profile == 7 }

    /// Whether a stream **declared as this configuration** can be presented as
    /// Dolby Vision by AVFoundation at all.
    ///
    /// The same three cases `MasterPlaylistBuilder` already decides between,
    /// named once so the manifest and the sample entry cannot disagree about
    /// them — the manifest reads it through `dolbyVisionBrand`, the muxer
    /// through `HLSRemuxer.shouldStripDolbyVisionRecord`:
    ///
    /// - **5** — presentable, and the record is not an upgrade but the
    ///   *description* of an IPT-PQc2 picture.
    /// - **8.1 / 8.4**, and their AV1 siblings **10.1 / 10.4** — presentable:
    ///   an HDR10 or HLG base the `dvvC` upgrades. Profile 10 is listed by
    ///   Apple's HLS authoring appendices alongside 8; it cannot reach the HEVC
    ///   remux path today, and it is named here so that when it can, a record
    ///   the platform supports is not thrown away by this rule.
    /// - **everything else** — 8.2's Rec.709 base, dual-layer 7, and any
    ///   profile we don't recognise. No manifest claim is printed for these, so
    ///   no record may be written for them either.
    public var isPresentableAsDolbyVision: Bool {
        if isSingleLayerDVOnly { return true }
        guard profile == 8 || profile == 10 else { return false }
        return baseLayerSignalCompatibilityID == 1 || baseLayerSignalCompatibilityID == 4
    }
}

/// What the native (HLS-fMP4 + AVPlayer) path can do with a stream.
public enum StreamCopyability: String, Sendable, Equatable {
    /// Rides the fMP4 pipeline untouched.
    case streamCopy
    /// Needs the phase-3 audio bridge (TrueHD / DTS family → EAC3).
    case requiresAudioBridge
    /// Neither: this source has to keep going to Prism/libmpv for now.
    case unsupported
}

public struct VideoTrackInfo: Sendable, Equatable {

    /// How the stream's pictures are scanned — after verification, not as
    /// declared. Broadcast H.264 routinely arrives *flagged* interlaced while
    /// carrying progressive frames ("progressive in interlaced carriage"),
    /// and trusting the flag would evict exactly those sources from the
    /// native path for no visual gain — so a declared-interlaced H.264 stream
    /// is verified against a handful of decoded frames before it is reported
    /// interlaced here.
    public enum FieldOrder: String, Sendable, Equatable {
        case progressive
        case topFieldFirst
        case bottomFieldFirst
        /// The container didn't say and no verification ran — treated as
        /// progressive by routing (never evict on a guess).
        case unknown

        public var isInterlaced: Bool {
            self == .topFieldFirst || self == .bottomFieldFirst
        }
    }

    /// A pixel (sample) aspect ratio, kept rational — `64/45` is exact where
    /// `1.4222…` is not.
    public struct AspectRatio: Sendable, Equatable {
        public let numerator: Int
        public let denominator: Int

        public init(numerator: Int, denominator: Int) {
            self.numerator = numerator
            self.denominator = denominator
        }
    }

    public let streamIndex: Int
    public let codecName: String
    public let profileName: String?
    /// `AVCodecParameters.profile` / `.level` as libavcodec reports them.
    public let profile: Int32
    public let level: Int32
    public let width: Int
    public let height: Int
    /// The pixel aspect ratio the display should honor, container-level over
    /// bitstream (an MKV's DisplayWidth/Height outranks the codec's VUI —
    /// anamorphic DVD rips are usually tagged only at the container).
    /// `nil` when neither says — treated as square.
    public let sampleAspectRatio: AspectRatio?
    /// Luma bit depth from the pixel format, `nil` if the format is unknown.
    public let bitDepth: Int?
    public let colorPrimariesName: String?
    public let colorTransferName: String?
    public let colorSpaceName: String?
    public let isBT2020: Bool
    public let frameRate: Double?
    public let frameRateSource: FrameRateSource
    /// The stream's declared bit rate in bits/second (`codecpar->bit_rate`),
    /// `nil` when the container doesn't say — MKV video very often doesn't.
    public let bitRate: Int64?
    /// Verified scan type; see `FieldOrder`. Interlaced video cannot ride the
    /// native path honestly — AVPlayer does not deinterlace, so a stream-copy
    /// would play with combing — which is why `copyability` reflects this.
    public let fieldOrder: FieldOrder
    public let hevcConfiguration: HEVCConfigurationRecord?
    /// The `avcC` bytes, for H.264 sources (`nil` for anything else).
    public let avcConfiguration: AVCConfigurationRecord?
    /// The `av1C` fields, for AV1 sources (`nil` for anything else).
    public let av1Configuration: AV1ConfigurationRecord?
    /// How many bytes each NAL unit's length prefix occupies in this stream's
    /// packets (`lengthSizeMinusOne + 1`), read from the configuration record.
    ///
    /// Needed by anything that has to walk the packets' NAL units rather than
    /// pass them through — today that is the Profile 7 → 8.1 RPU conversion.
    /// `nil` for Annex-B sources and non-HEVC/AVC codecs, which is also exactly
    /// when that conversion can't run.
    public let nalUnitLengthSize: Int?
    public let dolbyVision: DolbyVisionConfiguration?
    public let dynamicRange: DynamicRange
    public let copyability: StreamCopyability


    /// Explicit, with new-field defaults — the SourceInfo rule: fields can be
    /// added without breaking the tests (or hosts) that construct fixtures.
    public init(
        streamIndex: Int,
        codecName: String,
        profileName: String?,
        profile: Int32,
        level: Int32,
        width: Int,
        height: Int,
        sampleAspectRatio: AspectRatio?,
        bitDepth: Int?,
        colorPrimariesName: String?,
        colorTransferName: String?,
        colorSpaceName: String?,
        isBT2020: Bool,
        frameRate: Double?,
        frameRateSource: FrameRateSource,
        bitRate: Int64? = nil,
        fieldOrder: FieldOrder,
        hevcConfiguration: HEVCConfigurationRecord?,
        avcConfiguration: AVCConfigurationRecord?,
        av1Configuration: AV1ConfigurationRecord?,
        nalUnitLengthSize: Int?,
        dolbyVision: DolbyVisionConfiguration?,
        dynamicRange: DynamicRange,
        copyability: StreamCopyability
    ) {
        self.streamIndex = streamIndex
        self.codecName = codecName
        self.profileName = profileName
        self.profile = profile
        self.level = level
        self.width = width
        self.height = height
        self.sampleAspectRatio = sampleAspectRatio
        self.bitDepth = bitDepth
        self.colorPrimariesName = colorPrimariesName
        self.colorTransferName = colorTransferName
        self.colorSpaceName = colorSpaceName
        self.isBT2020 = isBT2020
        self.frameRate = frameRate
        self.frameRateSource = frameRateSource
        self.bitRate = bitRate
        self.fieldOrder = fieldOrder
        self.hevcConfiguration = hevcConfiguration
        self.avcConfiguration = avcConfiguration
        self.av1Configuration = av1Configuration
        self.nalUnitLengthSize = nalUnitLengthSize
        self.dolbyVision = dolbyVision
        self.dynamicRange = dynamicRange
        self.copyability = copyability
    }

    public enum FrameRateSource: String, Sendable, Equatable {
        case averageFrameRate
        case realFrameRate
        case unknown
    }
}

public struct AudioTrackInfo: Sendable, Equatable {
    public let streamIndex: Int
    public let codecName: String
    public let profileName: String?
    public let channelCount: Int
    public let channelLayoutDescription: String?
    public let sampleRate: Int
    /// Declared bits/second (`codecpar->bit_rate`); audio containers usually
    /// carry it. `nil` when absent.
    public let bitRate: Int64?
    public let language: String?
    public let title: String?
    /// Whether this track carries **object audio** — Dolby Atmos.
    ///
    /// Only meaningful for EAC3, where the objects ride as JOC inside a stream
    /// PrismCore copies untouched, and where HLS has a way to say so
    /// (`CHANNELS="16/JOC"`). It is reported for TrueHD and DTS-HD MA X too, but
    /// there it is *informational only*: those need the audio bridge, and the
    /// bridge decodes to PCM and re-encodes to EAC3, which destroys the objects.
    /// A bridged track is surround, never Atmos — so nothing must ever declare
    /// JOC on the bridge's output.
    ///
    /// Read from `AVCodecParameters.profile`, which libavformat only fills in
    /// once the parser has seen real packets — hence after
    /// `avformat_find_stream_info`, which `probe` always runs.
    public let isObjectAudio: Bool
    public let copyability: StreamCopyability

    /// Explicit, with new-field defaults — same rule as `VideoTrackInfo`.
    public init(
        streamIndex: Int,
        codecName: String,
        profileName: String?,
        channelCount: Int,
        channelLayoutDescription: String?,
        sampleRate: Int,
        bitRate: Int64? = nil,
        language: String?,
        title: String?,
        isObjectAudio: Bool,
        copyability: StreamCopyability
    ) {
        self.streamIndex = streamIndex
        self.codecName = codecName
        self.profileName = profileName
        self.channelCount = channelCount
        self.channelLayoutDescription = channelLayoutDescription
        self.sampleRate = sampleRate
        self.bitRate = bitRate
        self.language = language
        self.title = title
        self.isObjectAudio = isObjectAudio
        self.copyability = copyability
    }
}

public struct SubtitleTrackInfo: Sendable, Equatable {

    /// What PrismCore can do with the track.
    public enum Kind: String, Sendable, Equatable {
        /// Text codec (SubRip / ASS / SSA / WebVTT / mov_text): carried as a
        /// WebVTT `SUBTITLES` rendition, so it survives PiP and AirPlay.
        case textRendition
        /// Bitmap codec (PGS / DVB / DVD / XSUB) or teletext: **not** carried.
        /// Reported so the host can render it in its own overlay — a rendition
        /// would need OCR, which phase 6 doesn't ship.
        case bitmapHostOnly
        /// Something we neither convert nor recognize as bitmap.
        case unsupported
    }

    public let streamIndex: Int
    public let codecName: String
    public let language: String?
    public let title: String?
    public let kind: Kind
    public let isDefault: Bool
    public let isForced: Bool
    public let isHearingImpaired: Bool
}

/// One chapter mark from the container — a Matroska `Chapters` edition entry
/// or an MP4 chapter track, both of which libavformat parses into the same
/// `AVChapter` list.
///
/// Chapters are navigation metadata, not media: HLS has no way to carry them,
/// so they never reach AVPlayer through the served playlist. They are reported
/// here so a host can draw its own chapter markers and drive its skip
/// controls — the same facts either playback path can use, since both start
/// from this probe.
public struct ChapterInfo: Sendable, Equatable {
    /// The chapter's display title, `nil` when the container tagged none.
    public let title: String?
    /// Start position in seconds on the source's timeline.
    public let start: Double
    /// End position in seconds; `nil` when the container declared none (or
    /// declared one that doesn't follow the start — a chapter cannot honestly
    /// end before it begins, so a nonsense end reports as "no end" rather
    /// than as a fact). A host treating chapters as jump points can ignore
    /// this; one drawing ranges should end an open chapter at the next
    /// chapter's start, or the source's duration for the last.
    public let end: Double?

    public init(title: String?, start: Double, end: Double?) {
        self.title = title
        self.start = start
        self.end = end
    }
}

/// Everything Aether's engine routing needs to decide PrismCore vs Prism, and
/// everything `MasterPlaylistBuilder` needs to sign the manifest — read in one
/// libavformat open.
public struct SourceInfo: Sendable, Equatable {
    public let formatName: String
    /// Source duration in seconds; `nil` when the container doesn't know
    /// (some live ingests).
    public let duration: Double?
    public let video: VideoTrackInfo?
    public let audioTracks: [AudioTrackInfo]
    /// Every subtitle stream, text and bitmap alike — the bitmap ones are
    /// reported precisely because PrismCore does *not* carry them (phase 6),
    /// and the host has to know they exist to offer them in its own overlay.
    public let subtitleTracks: [SubtitleTrackInfo]
    /// The container's chapter marks, in start order. Empty for a source
    /// without them — most containers — never `nil`.
    public let chapters: [ChapterInfo]

    /// Explicit so `subtitleTracks` (and later `chapters`) could be added
    /// without breaking callers that predate them.
    public init(
        formatName: String,
        duration: Double?,
        video: VideoTrackInfo?,
        audioTracks: [AudioTrackInfo],
        subtitleTracks: [SubtitleTrackInfo] = [],
        chapters: [ChapterInfo] = []
    ) {
        self.formatName = formatName
        self.duration = duration
        self.video = video
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
        self.chapters = chapters
    }

    /// Text subtitle tracks PrismCore turns into WebVTT renditions.
    public var textSubtitleTracks: [SubtitleTrackInfo] {
        subtitleTracks.filter { $0.kind == .textRendition }
    }

    /// Bitmap subtitle tracks the host has to render itself.
    public var bitmapSubtitleTracks: [SubtitleTrackInfo] {
        subtitleTracks.filter { $0.kind == .bitmapHostOnly }
    }

    /// The single question the router asks: can PrismCore take this source
    /// today?
    ///
    /// `.streamCopy` when video and at least one audio track copy as-is,
    /// `.requiresAudioBridge` when video copies but every audio track needs
    /// the phase-3 encoder, `.unsupported` when the video itself can't ride
    /// the pipeline (VP9, MPEG-2, …).
    public var nativeReadiness: StreamCopyability {
        guard let video, video.copyability == .streamCopy else { return .unsupported }
        if audioTracks.isEmpty { return .streamCopy }
        if audioTracks.contains(where: { $0.copyability == .streamCopy }) { return .streamCopy }
        if audioTracks.contains(where: { $0.copyability == .requiresAudioBridge }) {
            return .requiresAudioBridge
        }
        return .unsupported
    }

    /// The first stream-copyable audio track, i.e. the one the v0 remuxer
    /// would pick (an AC3 compat track beats a DTS main track).
    public var preferredCopyableAudioTrack: AudioTrackInfo? {
        audioTracks.first { $0.copyability == .streamCopy }
    }
}

// MARK: - Probe

/// Opens a URL with libavformat and reports it. Read-only and one-shot: no
/// muxer, no output, nothing left running — the router calls this *before*
/// deciding which engine gets the source, so it must be cheap and total.
public enum SourceProbe {

    public enum Failure: Error {
        case openFailed(any Error)
        case noStreams
    }

    /// Codecs AVPlayer's HLS-fMP4 pipeline accepts via stream-copy.
    /// Deliberately the same set `HLSRemuxer` enforces — the probe's verdict
    /// has to match what the remuxer will actually accept.
    private static let copyableVideo: Set<AVCodecID> = [AV_CODEC_ID_H264, AV_CODEC_ID_HEVC]

    /// Can this video stream ride the fMP4 pipeline to `AVPlayer`?
    ///
    /// H.264 and HEVC always. **AV1 only where the device decodes it in
    /// hardware** — there is no software AV1 decoder behind VideoToolbox, so on an
    /// M1 or M2 (Vision Pro included) an AV1 variant would be offered and then not
    /// play. Where it isn't supported the answer is `.unsupported`, which routes
    /// the source to PrismCore's own software path and libdav1d.
    ///
    /// `isAV1HardwareSupported` is injected so the rule is testable on either kind
    /// of machine.
    static func isVideoStreamCopyable(
        _ codecID: AVCodecID,
        isAV1HardwareSupported: Bool = HardwareDecodeSupport.isAV1Supported
    ) -> Bool {
        if codecID == AV_CODEC_ID_AV1 { return isAV1HardwareSupported }
        return copyableVideo.contains(codecID)
    }
    private static let copyableAudio: Set<AVCodecID> = [
        AV_CODEC_ID_AAC, AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3,
        AV_CODEC_ID_FLAC, AV_CODEC_ID_ALAC,
    ]
    /// Audio the fMP4 pipeline can't carry but the phase-3 bridge can re-encode
    /// to EAC3.
    ///
    /// Deliberately `AudioBridge`'s own set rather than a copy of it. It used to
    /// be a copy, and the copy drifted: the bridge grew MP3/MP2/Opus/Vorbis/PCM
    /// while this list stayed at the three lossless codecs, so the probe reported
    /// an MP3-audio MKV as `.unsupported` — a verdict the remuxer disagreed with,
    /// since its own routing asks `AudioBridge.canBridge`. The drift was invisible
    /// only because the EAC3 encoder is absent from stock MPVKit, which makes
    /// *everything* unbridgeable; it would have surfaced the day the fork enables
    /// the encoder. One set, no synchronizing.
    private static func isBridgeable(_ codecID: AVCodecID) -> Bool {
        // A decoder has to exist too — a codec in the bridgeable class that this
        // build can't decode is not bridgeable, it is unsupported. The *encoder*
        // question deliberately stays out: `.requiresAudioBridge` describes the
        // stream, and whether the bridge can run today is the router's call (see
        // `PrismCoreEngine.decide`, which takes it as a parameter).
        AudioBridge.bridgeableAudio.contains(codecID) && avcodec_find_decoder(codecID) != nil
    }

    /// `isBridgeable` for the test that pins it against `AudioBridge`'s set.
    /// Exists so the classifier itself can stay private.
    static func isBridgeableForTesting(_ codecID: AVCodecID) -> Bool {
        isBridgeable(codecID)
    }

    public static func probe(
        url: URL,
        httpHeaders: [String: String] = [:],
        input: PrismCoreInputFactory? = nil
    ) throws -> SourceInfo {
        // The context is closed when the returned `ProbedSource` goes out of
        // scope here — this overload is for callers that only want the answer.
        try open(url: url, httpHeaders: httpHeaders, input: input).info
    }

    /// Probe a source and **keep the open context**, so a session over the same
    /// source can produce from it instead of opening again.
    ///
    /// This is the routing entry point worth using: `PrismCoreEngine.decide`
    /// takes the `info`, and a source that routes to the remux path can be
    /// handed straight to `PrismCoreSession(probed:display:)`, which adopts the
    /// context. A source that routes elsewhere simply releases it — see
    /// `ProbedSource` for why the context, and not merely its conclusions, is
    /// what has to travel.
    /// - Parameter budget: wall-clock bound on the WHOLE probe — open, stream
    ///   analysis, interlace verification. On expiry the blocked read aborts
    ///   and this throws, which is the property the router depends on: a
    ///   probe that answers nothing is a playback that falls back to nothing
    ///   (five silent play attempts over four minutes in the 2026-08-14
    ///   field log, all blocked inside one open against a starved server).
    /// `open`, run on a dedicated thread so the cooperative pool never
    /// blocks in it.
    ///
    /// `open` is synchronous and blocks on the transport for the whole probe
    /// — up to `budget` (10 s) against a starved server. Called from an
    /// `async` context that is a cooperative-pool thread held hostage, and
    /// a host that probes several sources at once (a row of episodes, a
    /// fallback racing a transcode) can park enough of them to stall every
    /// other `await` in the process (#44 was the producer-side twin). This
    /// hops to a one-shot `ProducerThread`, hands the `ProbedSource` back
    /// through a continuation, and returns to the pool. The interrupt guard
    /// and the budget are `open`'s own; nothing about the probe changes.
    ///
    /// Task cancellation is observed at the boundary: a probe already in
    /// flight runs to its verdict or its budget (the thread is not killed;
    /// an FFmpeg read cannot be interrupted from outside except through the
    /// guard, which the budget already arms), and a cancelled caller gets
    /// `CancellationError` while the result is released.
    public static func openDetached(
        url: URL,
        httpHeaders: [String: String] = [:],
        budget: Duration = SourceOpenTuning.probeBudget,
        coordinatedHTTP: Bool = false,
        input: PrismCoreInputFactory? = nil
    ) async throws -> ProbedSource {
        try Task.checkCancellation()
        let outcome: Result<ProbedSource, any Error> = await withCheckedContinuation { continuation in
            let thread = ProducerThread(name: "cz.zmrhal.prismcore.probe") {
                continuation.resume(returning: Result {
                    try open(url: url, httpHeaders: httpHeaders, budget: budget,
                             coordinatedHTTP: coordinatedHTTP, input: input)
                })
            }
            // Kept alive by its own closure until it exits; nothing to join.
            withExtendedLifetime(thread) {}
        }
        if Task.isCancelled {
            // The probe finished after the caller stopped caring: releasing
            // the `ProbedSource` closes its context.
            throw CancellationError()
        }
        return try outcome.get()
    }

    /// - Parameter input: a host-supplied byte source (`PrismCoreInput`) for a
    ///   transport libavformat cannot open itself. One instance is taken for
    ///   this open; `url` is then only a naming hint for format probing, never
    ///   fetched. `nil` (the default) keeps native FFmpeg I/O.
    public static func open(
        url: URL,
        httpHeaders: [String: String] = [:],
        budget: Duration = SourceOpenTuning.probeBudget,
        coordinatedHTTP: Bool = false,
        input inputFactory: PrismCoreInputFactory? = nil
    ) throws -> ProbedSource {
        // The interrupt guard has to exist BEFORE the open — the blocking
        // reads check the URLContext's copy of the callback, taken at
        // creation — and this open is the one that decides whether the
        // adopting producer can ever bound a read: the remuxer usually
        // inherits this very context (see `ReadInterruptGuard`).
        let interruptGuard = ReadInterruptGuard()
        var input: UnsafeMutablePointer<AVFormatContext>? = interruptGuard.makeContext()
        // A host-supplied input wins over the coordinated HTTP reader: the
        // host asked to provide the bytes itself, and the two would otherwise
        // both claim `pb`.
        if let inputFactory, let input {
            do { try interruptGuard.installCustomInput(on: input, factory: inputFactory) }
            catch { avformat_free_context(input); throw error }
        } else if coordinatedHTTP, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let input {
            do { try interruptGuard.installHTTPInput(on: input, url: url, headers: httpHeaders) }
            catch { avformat_free_context(input); throw error }
        }

        // Armed across the whole probe, disarmed on every way out — the
        // adopting producer wants the permanent-but-disarmed resting state.
        interruptGuard.arm(budget: budget)
        defer { interruptGuard.disarm() }
        let clock = ContinuousClock()
        let probeStart = clock.now

        // Same open pattern as HLSRemuxer: the caller's headers (Plex token,
        // WebDAV authorization) travel on the probe connection too, otherwise
        // a server source would 401 here and get mis-routed as unplayable —
        // and the same read caps, because over a network this open IS the
        // wait the user sees (see `SourceOpenTuning`).
        var openOptions = SourceOpenTuning.makeOptions(httpHeaders: httpHeaders)
        defer { av_dict_free(&openOptions) }

        let sourceSpec = url.isFileURL ? url.path : url.absoluteString
        do {
            try FFmpegError.check(
                avformat_open_input(&input, sourceSpec, nil, &openOptions),
                "avformat_open_input"
            )
        } catch {
            // The host's own error, when its input is what failed: FFmpeg
            // reduces it to `-EIO` on the way out, and a host debugging a
            // mount needs to see what its own code threw.
            throw Failure.openFailed(interruptGuard.customInputFailure ?? error)
        }
        guard let input else { throw Failure.noStreams }
        let openedAt = clock.now
        // From here the context is owned by the `ProbedSource` we return; on
        // the throwing paths below it has no owner yet, so close it by hand.
        func closeAndThrow(_ failure: any Error) -> any Error {
            // The close can itself read (a tail request being torn down), and
            // the callback holds an unretained pointer — keep the guard alive
            // through it even if the optimizer thinks it is done.
            withExtendedLifetime(interruptGuard) {
                var closing: UnsafeMutablePointer<AVFormatContext>? = input
                avformat_close_input(&closing)
            }
            return failure
        }

        // Needed for pixel format, color properties and the DV side data —
        // several of them are only filled in after the codec parser has seen
        // real packets. It is also what fills the fields the MUXER later needs,
        // which is why a context that skipped it cannot be produced from.
        do {
            try FFmpegError.check(
                avformat_find_stream_info(input, nil), "avformat_find_stream_info"
            )
        } catch {
            throw closeAndThrow(interruptGuard.customInputFailure ?? error)
        }
        // `find_stream_info` swallows aborted reads: cut off mid-analysis it
        // returns success with half-filled parameters, and a half-analysed
        // context handed onward is 1.1.2's muxing failure wearing a verdict.
        // The clock is the honest witness — still-armed and expired means the
        // analysis cannot be trusted, whatever it returned.
        if interruptGuard.shouldInterrupt {
            throw closeAndThrow(Failure.openFailed(
                FFmpegError(code: swift_AVERROR_EXIT(), operation: "probe budget exhausted")
            ))
        }
        let analyzedAt = clock.now

        // The interlace verification consumes packets, which is why it was
        // only ever safe on a one-shot context. It still is: the read position
        // it leaves behind is the adopting producer's to fix (it seeks to its
        // own start anyway), and the verdict is worth far more than the rewind
        // costs.
        let info = describe(input: input, verifyingInterlace: true)
        let describedAt = clock.now

        // A budget that expired mid-verification latched AVERROR_EXIT in the
        // AVIOContext, and the adopting producer's first read would get it
        // verbatim. The verification itself degraded gracefully (an aborted
        // read just ends it early), so the verdict stands — only the latch
        // must not travel.
        if let pb = input.pointee.pb, pb.pointee.error < 0 {
            pb.pointee.error = 0
        }

        return ProbedSource(
            info: info, url: url, httpHeaders: httpHeaders, inputFactory: inputFactory,
            context: input, interruptGuard: interruptGuard,
            timing: ProbeTiming(
                open: probeStart.duration(to: openedAt),
                streamInfo: openedAt.duration(to: analyzedAt),
                describe: analyzedAt.duration(to: describedAt)
            )
        )
    }

    /// Describe an input that is **already open** (and already through
    /// `avformat_find_stream_info`).
    ///
    /// Exists so `HLSRemuxer` can reuse the probe's per-stream detection —
    /// codecs, copyability, languages, HDR/DV signaling — on the context it
    /// opened for the remux itself, instead of duplicating the reads or opening
    /// the source a second time (a second open on a network source costs a real
    /// round trip and can even hand back different stream indices).
    /// - Parameter verifyingInterlace: when true, a declared-interlaced H.264
    ///   stream is checked against a handful of *decoded* frames before it is
    ///   reported interlaced — the read consumes packets from `input`, so only
    ///   a one-shot probe context may ask for it. The remuxer's `describe`
    ///   call must not: its context's read position is the remux.
    static func describe(
        input: UnsafeMutablePointer<AVFormatContext>,
        verifyingInterlace: Bool = false
    ) -> SourceInfo {
        let formatName = input.pointee.iformat.flatMap { $0.pointee.name }
            .map { String(cString: $0) } ?? "unknown"
        let duration = input.pointee.duration == swift_AV_NOPTS_VALUE()
            ? nil
            : Double(input.pointee.duration) / Double(AV_TIME_BASE)

        var video: VideoTrackInfo?
        var audio: [AudioTrackInfo] = []
        var subtitles: [SubtitleTrackInfo] = []

        // The video track we report is the one the remuxer would select, so
        // routing and remuxing agree on which stream is "the" video.
        let bestVideoIndex = av_find_best_stream(input, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)

        for index in 0..<Int(input.pointee.nb_streams) {
            guard let stream = input.pointee.streams[index] else { continue }
            let par = stream.pointee.codecpar.pointee
            switch par.codec_type {
            case AVMEDIA_TYPE_VIDEO where Int32(index) == bestVideoIndex:
                var verifiedFieldOrder: VideoTrackInfo.FieldOrder?
                if verifyingInterlace,
                   par.codec_id == AV_CODEC_ID_H264,
                   fieldOrder(from: par.field_order).isInterlaced {
                    // Trust the declaration only when decoded frames agree —
                    // "progressive in interlaced carriage" is the broadcast
                    // norm, and evicting those from the native path would
                    // trade hardware decode and Atmos passthrough for
                    // deinterlacing nothing.
                    verifiedFieldOrder = decodedFramesLookInterlaced(
                        input: input, streamIndex: Int32(index), stream: stream
                    ) ? fieldOrder(from: par.field_order) : .progressive
                }
                video = makeVideoInfo(
                    streamIndex: index, stream: stream,
                    verifiedFieldOrder: verifiedFieldOrder
                )
            case AVMEDIA_TYPE_AUDIO:
                audio.append(makeAudioInfo(streamIndex: index, stream: stream))
            case AVMEDIA_TYPE_SUBTITLE:
                subtitles.append(makeSubtitleInfo(streamIndex: index, stream: stream))
            default:
                continue
            }
        }

        return SourceInfo(
            formatName: formatName,
            duration: duration,
            video: video,
            audioTracks: audio,
            subtitleTracks: subtitles,
            chapters: readChapters(input: input)
        )
    }

    /// The container's chapter list — `AVChapter`s, which the matroska and mov
    /// demuxers fill from Matroska `Chapters` and MP4 chapter tracks
    /// respectively. Each chapter carries its own `time_base`.
    private static func readChapters(
        input: UnsafeMutablePointer<AVFormatContext>
    ) -> [ChapterInfo] {
        guard input.pointee.nb_chapters > 0, let list = input.pointee.chapters else { return [] }
        var chapters: [ChapterInfo] = []
        for index in 0..<Int(input.pointee.nb_chapters) {
            guard let chapter = list[index] else { continue }
            let timeBase = av_q2d(chapter.pointee.time_base)
            // A negative start exists in the wild (an edition offset); the
            // playable timeline starts at zero, so clamp rather than report a
            // position no seek can reach.
            let start = max(0, Double(chapter.pointee.start) * timeBase)
            let end: Double? = {
                guard chapter.pointee.end != swift_AV_NOPTS_VALUE() else { return nil }
                let end = Double(chapter.pointee.end) * timeBase
                return end > start ? end : nil
            }()
            chapters.append(ChapterInfo(
                title: avMetadataValue(chapter.pointee.metadata, "title"),
                start: start,
                end: end
            ))
        }
        return chapters.sorted { $0.start < $1.start }
    }

    // MARK: - Per-stream reads

    /// Map libavformat's field order onto the reported enum.
    private static func fieldOrder(from order: AVFieldOrder) -> VideoTrackInfo.FieldOrder {
        switch order {
        case AV_FIELD_PROGRESSIVE: return .progressive
        // TT/TB: top field coded first; BB/BT: bottom first. The coded order
        // is what a deinterlacer's parity wants, display order is its business.
        case AV_FIELD_TT, AV_FIELD_TB: return .topFieldFirst
        case AV_FIELD_BB, AV_FIELD_BT: return .bottomFieldFirst
        default: return .unknown
        }
    }

    /// Decode a handful of frames and report whether the pictures themselves
    /// are interlaced. Consumes packets from `input` — one-shot contexts only.
    private static func decodedFramesLookInterlaced(
        input: UnsafeMutablePointer<AVFormatContext>,
        streamIndex: Int32,
        stream: UnsafeMutablePointer<AVStream>
    ) -> Bool {
        guard let decoder = avcodec_find_decoder(stream.pointee.codecpar.pointee.codec_id),
              let context = avcodec_alloc_context3(decoder)
        else { return true }  // can't verify → believe the declaration
        var contextRef: UnsafeMutablePointer<AVCodecContext>? = context
        defer { avcodec_free_context(&contextRef) }
        guard avcodec_parameters_to_context(context, stream.pointee.codecpar) >= 0,
              avcodec_open2(context, decoder, nil) >= 0
        else { return true }

        guard let packet = av_packet_alloc(), let frame = av_frame_alloc() else { return true }
        var packetRef: UnsafeMutablePointer<AVPacket>? = packet
        var frameRef: UnsafeMutablePointer<AVFrame>? = frame
        defer {
            av_packet_free(&packetRef)
            av_frame_free(&frameRef)
        }

        // AV_FRAME_FLAG_INTERLACED — the macro doesn't import into Swift.
        // frame.h: CORRUPT=1<<0, KEY=1<<1, DISCARD=1<<2, INTERLACED=1<<3.
        let interlacedFlag: Int32 = 1 << 3
        var decoded = 0
        var interlaced = 0
        var packetsRead = 0
        while decoded < 12, packetsRead < 120, av_read_frame(input, packet) >= 0 {
            defer { av_packet_unref(packet) }
            packetsRead += 1
            guard packet.pointee.stream_index == streamIndex else { continue }
            guard avcodec_send_packet(context, packet) >= 0 else { break }
            while avcodec_receive_frame(context, frame) >= 0 {
                decoded += 1
                if frame.pointee.flags & interlacedFlag != 0 { interlaced += 1 }
                av_frame_unref(frame)
            }
        }
        // A lone flagged frame in a dozen is carriage noise; real interlaced
        // content flags them all. No decoded frames at all → believe the flag.
        return decoded == 0 || interlaced >= 2
    }

    private static func makeVideoInfo(
        streamIndex: Int,
        stream: UnsafeMutablePointer<AVStream>,
        verifiedFieldOrder: VideoTrackInfo.FieldOrder? = nil
    ) -> VideoTrackInfo {
        let par = stream.pointee.codecpar.pointee

        let hevcConfiguration: HEVCConfigurationRecord? = {
            guard par.codec_id == AV_CODEC_ID_HEVC,
                  let extradata = par.extradata, par.extradata_size > 0
            else { return nil }
            let data = Data(bytes: extradata, count: Int(par.extradata_size))
            return HEVCConfigurationRecord.parse(hvcC: data)
        }()

        let avcConfiguration: AVCConfigurationRecord? = {
            guard par.codec_id == AV_CODEC_ID_H264,
                  let extradata = par.extradata, par.extradata_size > 0
            else { return nil }
            let data = Data(bytes: extradata, count: Int(par.extradata_size))
            return AVCConfigurationRecord.parse(avcC: data)
        }()

        let av1Configuration: AV1ConfigurationRecord? = {
            guard par.codec_id == AV_CODEC_ID_AV1,
                  let extradata = par.extradata, par.extradata_size > 0
            else { return nil }
            return AV1ConfigurationRecord.parse(
                av1C: Data(bytes: extradata, count: Int(par.extradata_size))
            )
        }()

        // Both configuration records put `lengthSizeMinusOne` in their last two
        // bits, at different offsets: byte 21 of an `hvcC`, byte 4 of an `avcC`.
        let nalUnitLengthSize: Int? = {
            guard let extradata = par.extradata, par.extradata_size > 0 else { return nil }
            let data = Data(bytes: extradata, count: Int(par.extradata_size))
            switch par.codec_id {
            case AV_CODEC_ID_HEVC:
                guard hevcConfiguration != nil else { return nil }
                return HEVCNALUnits.lengthSize(fromHVCC: data)
            case AV_CODEC_ID_H264:
                guard avcConfiguration != nil, data.count > 4 else { return nil }
                return Int(data[4] & 0x03) + 1
            default:
                return nil
            }
        }()

        let dolbyVision = readDolbyVisionConfiguration(stream.pointee.codecpar)

        // Frame rate: avg_frame_rate is the honest average over the whole
        // file; r_frame_rate is the "base" rate the demuxer guessed and only
        // stands in when the average is unset. An HDR master with no
        // FRAME-RATE attribute is filtered out by AVPlayer at master-parse
        // time, so a nil here has to be treated as "do not serve a master".
        let average = stream.pointee.avg_frame_rate
        let real = stream.pointee.r_frame_rate
        let frameRate: Double?
        let frameRateSource: VideoTrackInfo.FrameRateSource
        if average.num > 0, average.den > 0 {
            frameRate = av_q2d(average)
            frameRateSource = .averageFrameRate
        } else if real.num > 0, real.den > 0 {
            frameRate = av_q2d(real)
            frameRateSource = .realFrameRate
        } else {
            frameRate = nil
            frameRateSource = .unknown
        }

        let bitDepth: Int? = {
            guard par.format >= 0,
                  let descriptor = av_pix_fmt_desc_get(AVPixelFormat(rawValue: par.format))
            else { return nil }
            return Int(descriptor.pointee.comp.0.depth)
        }()

        let transfer = par.color_trc
        let dynamicRange: DynamicRange = {
            if let dolbyVision {
                // A Profile 5 stream's container colour tags are routinely
                // unset (its base is IPT-PQ, not a signalable BT.2020
                // transfer), so the profile decides the range, not the tags.
                if dolbyVision.isSingleLayerDVOnly { return .pq }
                if dolbyVision.baseLayerSignalCompatibilityID == 4 { return .hlg }
                if dolbyVision.hasSDRCompatibleBase { return .sdr }
                if dolbyVision.baseLayerSignalCompatibilityID == 1
                    || dolbyVision.baseLayerSignalCompatibilityID == 6 { return .pq }
            }
            if transfer == AVCOL_TRC_SMPTE2084 { return .pq }
            if transfer == AVCOL_TRC_ARIB_STD_B67 { return .hlg }
            return .sdr
        }()

        // Verified interlace evicts from the native path: AVPlayer does not
        // deinterlace, so a stream-copy would play with combing, and the
        // software path has a real deinterlacer. Only a *verified* verdict
        // does this — a declared-but-unverified flag (the remuxer's own
        // `describe`, which must not consume packets) keeps the copyability
        // the codec earns, because routing always works from the verified
        // probe and the broadcast norm is progressive in interlaced carriage.
        let reportedFieldOrder = verifiedFieldOrder ?? fieldOrder(from: par.field_order)
        let interlacedVerdict = verifiedFieldOrder?.isInterlaced == true

        return VideoTrackInfo(
            streamIndex: streamIndex,
            codecName: codecName(par.codec_id),
            profileName: profileName(par.codec_id, par.profile),
            profile: par.profile,
            level: par.level,
            width: Int(par.width),
            height: Int(par.height),
            sampleAspectRatio: {
                // Same precedence the remuxer (and ffmpeg's streamcopy) uses.
                let streamSAR = stream.pointee.sample_aspect_ratio
                let sar = streamSAR.num != 0 ? streamSAR : par.sample_aspect_ratio
                guard sar.num > 0, sar.den > 0 else { return nil }
                return .init(numerator: Int(sar.num), denominator: Int(sar.den))
            }(),
            bitDepth: bitDepth,
            colorPrimariesName: cString(av_color_primaries_name(par.color_primaries)),
            colorTransferName: cString(av_color_transfer_name(transfer)),
            colorSpaceName: cString(av_color_space_name(par.color_space)),
            isBT2020: par.color_primaries == AVCOL_PRI_BT2020,
            frameRate: frameRate,
            frameRateSource: frameRateSource,
            bitRate: par.bit_rate > 0 ? par.bit_rate : nil,
            fieldOrder: reportedFieldOrder,
            hevcConfiguration: hevcConfiguration,
            avcConfiguration: avcConfiguration,
            av1Configuration: av1Configuration,
            nalUnitLengthSize: nalUnitLengthSize,
            dolbyVision: dolbyVision,
            dynamicRange: dynamicRange,
            copyability: isVideoStreamCopyable(par.codec_id) && !interlacedVerdict
                ? .streamCopy : .unsupported
        )
    }

    private static func makeAudioInfo(
        streamIndex: Int,
        stream: UnsafeMutablePointer<AVStream>
    ) -> AudioTrackInfo {
        let par = stream.pointee.codecpar.pointee

        let layout: String? = {
            var mutableLayout = par.ch_layout
            var buffer = [CChar](repeating: 0, count: 128)
            let written = av_channel_layout_describe(&mutableLayout, &buffer, buffer.count)
            return written > 0 ? String(cString: buffer) : nil
        }()

        // Object audio, by codec. The two constants happen to share the value 30
        // — they are different codecs' profile enums, so they are matched
        // separately rather than compared against one number.
        let isObjectAudio: Bool = {
            switch par.codec_id {
            case AV_CODEC_ID_EAC3:
                return par.profile == AV_PROFILE_EAC3_DDP_ATMOS
            case AV_CODEC_ID_TRUEHD, AV_CODEC_ID_MLP:
                return par.profile == AV_PROFILE_TRUEHD_ATMOS
            case AV_CODEC_ID_DTS:
                return par.profile == AV_PROFILE_DTS_HD_MA_X
                    || par.profile == AV_PROFILE_DTS_HD_MA_X_IMAX
            default:
                return false
            }
        }()

        let copyability: StreamCopyability
        if copyableAudio.contains(par.codec_id) {
            copyability = .streamCopy
        } else if isBridgeable(par.codec_id) {
            copyability = .requiresAudioBridge
        } else {
            copyability = .unsupported
        }

        return AudioTrackInfo(
            streamIndex: streamIndex,
            codecName: codecName(par.codec_id),
            profileName: profileName(par.codec_id, par.profile),
            channelCount: Int(par.ch_layout.nb_channels),
            channelLayoutDescription: layout,
            sampleRate: Int(par.sample_rate),
            bitRate: par.bit_rate > 0 ? par.bit_rate : nil,
            language: avMetadataValue(stream.pointee.metadata, "language"),
            title: avMetadataValue(stream.pointee.metadata, "title"),
            isObjectAudio: isObjectAudio,
            copyability: copyability
        )
    }

    /// Classification comes from `SubtitleRenditionSet`'s own codec sets — the
    /// remuxer decides what it converts, the probe only reports that decision,
    /// so the two can't drift.
    private static func makeSubtitleInfo(
        streamIndex: Int,
        stream: UnsafeMutablePointer<AVStream>
    ) -> SubtitleTrackInfo {
        let par = stream.pointee.codecpar.pointee
        let disposition = stream.pointee.disposition

        let kind: SubtitleTrackInfo.Kind
        if SubtitleRenditionSet.textCodecs.contains(par.codec_id) {
            kind = .textRendition
        } else if SubtitleRenditionSet.bitmapCodecs.contains(par.codec_id) {
            kind = .bitmapHostOnly
        } else {
            kind = .unsupported
        }

        return SubtitleTrackInfo(
            streamIndex: streamIndex,
            codecName: codecName(par.codec_id),
            language: avMetadataValue(stream.pointee.metadata, "language"),
            title: avMetadataValue(stream.pointee.metadata, "title"),
            kind: kind,
            isDefault: disposition & AV_DISPOSITION_DEFAULT != 0,
            isForced: disposition & AV_DISPOSITION_FORCED != 0,
            isHearingImpaired: disposition & AV_DISPOSITION_HEARING_IMPAIRED != 0
        )
    }

    /// Reads `AV_PKT_DATA_DOVI_CONF` off the stream's codec parameters.
    ///
    /// Modern libavformat attaches container side data to
    /// `AVCodecParameters.coded_side_data` (it used to hang off `AVStream`),
    /// and the payload is a straight `AVDOVIDecoderConfigurationRecord` — the
    /// `dvcC`/`dvvC` box the mov/matroska demuxers parse for us.
    private static func readDolbyVisionConfiguration(
        _ codecpar: UnsafeMutablePointer<AVCodecParameters>?
    ) -> DolbyVisionConfiguration? {
        guard let codecpar else { return nil }
        let par = codecpar.pointee
        guard let sideData = av_packet_side_data_get(
            par.coded_side_data, par.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF
        ) else { return nil }
        guard let raw = sideData.pointee.data,
              sideData.pointee.size >= MemoryLayout<AVDOVIDecoderConfigurationRecord>.size
        else { return nil }

        let record = raw.withMemoryRebound(
            to: AVDOVIDecoderConfigurationRecord.self, capacity: 1
        ) { $0.pointee }

        return DolbyVisionConfiguration(
            versionMajor: record.dv_version_major,
            versionMinor: record.dv_version_minor,
            profile: record.dv_profile,
            level: record.dv_level,
            rpuPresent: record.rpu_present_flag != 0,
            enhancementLayerPresent: record.el_present_flag != 0,
            baseLayerPresent: record.bl_present_flag != 0,
            baseLayerSignalCompatibilityID: record.dv_bl_signal_compatibility_id
        )
    }

    // MARK: - Small C bridges

    /// The demuxer's own name for a codec. Internal so the remuxer can check
    /// a stream's identity against a probe result without re-describing it.
    static func codecName(_ id: AVCodecID) -> String {
        cString(avcodec_get_name(id)) ?? "unknown"
    }

    private static func profileName(_ id: AVCodecID, _ profile: Int32) -> String? {
        guard profile != swift_AV_PROFILE_UNKNOWN else { return nil }
        return cString(avcodec_profile_name(id, profile))
    }

    private static func cString(_ pointer: UnsafePointer<CChar>?) -> String? {
        pointer.map { String(cString: $0) }
    }

}
