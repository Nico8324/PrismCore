import Testing
import Foundation
@testable import PrismCore

// MARK: - Fixtures

/// A real HEVC Main10 `hvcC`: profile_idc 2, Main tier, level 5.1 (idc 153),
/// stored compatibility flags `0x20000000`, constraint byte `0xB0`.
private func main10HVCC(
    profileSpace: UInt8 = 0,
    tierFlag: UInt8 = 0,
    profileIDC: UInt8 = 2,
    compatibilityFlags: UInt32 = 0x2000_0000,
    levelIDC: UInt8 = 153,
    constraintFirstByte: UInt8 = 0xB0
) -> Data {
    var bytes = [UInt8](repeating: 0, count: 23)
    bytes[0] = 1  // configurationVersion
    bytes[1] = (profileSpace << 6) | (tierFlag << 5) | profileIDC
    bytes[2] = UInt8((compatibilityFlags >> 24) & 0xFF)
    bytes[3] = UInt8((compatibilityFlags >> 16) & 0xFF)
    bytes[4] = UInt8((compatibilityFlags >> 8) & 0xFF)
    bytes[5] = UInt8(compatibilityFlags & 0xFF)
    bytes[6] = constraintFirstByte
    bytes[12] = levelIDC
    return Data(bytes)
}

private func record(from data: Data) throws -> HEVCConfigurationRecord {
    try #require(HEVCConfigurationRecord.parse(hvcC: data))
}

private func dolbyVision(
    profile: UInt8,
    level: UInt8 = 6,
    compatibilityID: UInt8
) -> DolbyVisionConfiguration {
    DolbyVisionConfiguration(
        versionMajor: 1,
        versionMinor: 0,
        profile: profile,
        level: level,
        rpuPresent: true,
        enhancementLayerPresent: profile == 7,
        baseLayerPresent: profile != 5,
        baseLayerSignalCompatibilityID: compatibilityID
    )
}

private let atmosRendition = MasterPlaylistBuilder.AudioRendition(
    name: "English",
    language: "en",
    codecString: "ec-3",
    channels: "16/JOC"
)

private func variant(
    hvcC: Data = main10HVCC(),
    range: DynamicRange,
    frameRate: Double? = 23.976,
    dolbyVision dv: DolbyVisionConfiguration? = nil,
    dvCapableDisplay: Bool = false,
    audio: [MasterPlaylistBuilder.AudioRendition] = [atmosRendition]
) throws -> MasterPlaylistBuilder.VariantDescription {
    MasterPlaylistBuilder.VariantDescription(
        bandwidth: 24_000_000,
        averageBandwidth: 18_500_000,
        resolution: .init(width: 3840, height: 2160),
        frameRate: frameRate,
        dynamicRange: range,
        videoCodec: .hevc(try record(from: hvcC)),
        dolbyVision: dv,
        displayIsDolbyVisionCapable: dvCapableDisplay,
        audioRenditions: audio
    )
}

private func streamInf(_ playlist: String) throws -> String {
    try #require(playlist.split(separator: "\n").first { $0.hasPrefix("#EXT-X-STREAM-INF:") })
        .description
}

// MARK: - hvcC parsing

@Suite("HEVCConfigurationRecord")
struct HEVCConfigurationRecordTests {

    @Test("Parses profile_tier_level out of an hvcC")
    func parsesPTL() throws {
        let parsed = try record(from: main10HVCC())
        #expect(parsed.profileSpace == 0)
        #expect(parsed.tierFlag == 0)
        #expect(parsed.profileIDC == 2)
        #expect(parsed.profileCompatibilityFlags == 0x2000_0000)
        #expect(parsed.levelIDC == 153)
        #expect(parsed.constraintIndicatorFlags == 0xB000_0000_0000)
    }

    @Test("Rejects extradata that is not an hvcC")
    func rejectsNonHVCC() {
        // Annex-B start code: MPEG-TS style in-band parameter sets.
        #expect(HEVCConfigurationRecord.parse(hvcC: Data([0, 0, 0, 1, 0x40])) == nil)
        // Right length, wrong configurationVersion.
        var wrongVersion = [UInt8](repeating: 0, count: 23)
        wrongVersion[0] = 2
        #expect(HEVCConfigurationRecord.parse(hvcC: Data(wrongVersion)) == nil)
        // Truncated record.
        #expect(HEVCConfigurationRecord.parse(hvcC: Data(repeating: 1, count: 12)) == nil)
    }
}

// MARK: - Codec strings

@Suite("HEVC CODECS string")
struct HEVCCodecStringTests {

    @Test("Main10 prints the compatibility flags in reverse bit order")
    func main10CompatibilityFlagsAreReversed() throws {
        let string = MasterPlaylistBuilder.hevcCodecString(try record(from: main10HVCC()))
        #expect(string == "hvc1.2.4.L153.B0")
        // The stored value must never leak into the manifest.
        #expect(!string.contains("20000000"))
    }

    @Test("Reverse-bit helper matches the known Annex E values")
    func reverseBits() {
        #expect(MasterPlaylistBuilder.reverseBits(0x2000_0000) == 0x4)      // Main10
        #expect(MasterPlaylistBuilder.reverseBits(0x6000_0000) == 0x6)      // Main + Main10
        #expect(MasterPlaylistBuilder.reverseBits(0x4000_0000) == 0x2)      // Main
        #expect(MasterPlaylistBuilder.reverseBits(0x0000_0001) == 0x8000_0000)
    }

    @Test("8-bit Main is not declared as Main10")
    func mainProfile() throws {
        let data = main10HVCC(profileIDC: 1, compatibilityFlags: 0x6000_0000, levelIDC: 120)
        #expect(MasterPlaylistBuilder.hevcCodecString(try record(from: data)) == "hvc1.1.6.L120.B0")
    }

    @Test("High tier prints H, Main tier prints L")
    func tierFlag() throws {
        let high = main10HVCC(tierFlag: 1)
        #expect(MasterPlaylistBuilder.hevcCodecString(try record(from: high)) == "hvc1.2.4.H153.B0")
    }

    @Test("profile_space 1 prefixes the profile with A")
    func profileSpace() throws {
        let data = main10HVCC(profileSpace: 1)
        #expect(MasterPlaylistBuilder.hevcCodecString(try record(from: data)) == "hvc1.A2.4.L153.B0")
    }

    @Test("Trailing zero constraint bytes are omitted, interior zeros are kept")
    func constraintBytes() throws {
        let noConstraints = main10HVCC(constraintFirstByte: 0)
        #expect(
            MasterPlaylistBuilder.hevcCodecString(try record(from: noConstraints))
                == "hvc1.2.4.L153"
        )

        var bytes = [UInt8](main10HVCC())
        bytes[6] = 0xB0
        bytes[8] = 0x0C  // byte index 2 of the six → a real interior gap
        #expect(
            MasterPlaylistBuilder.hevcCodecString(try record(from: Data(bytes)))
                == "hvc1.2.4.L153.B0.00.0C"
        )
    }

    @Test("H.264 prints the three avcC bytes as hex")
    func avcCodecString() throws {
        // High profile, no constraint flags, level 4.0 — the familiar tag.
        let record = try #require(
            AVCConfigurationRecord.parse(avcC: Data([1, 100, 0, 40, 0xFF]))
        )
        #expect(record.profileIDC == 100)
        #expect(record.profileCompatibility == 0)
        #expect(record.levelIDC == 40)
        #expect(MasterPlaylistBuilder.avcCodecString(record) == "avc1.640028")

        // Constrained Baseline 3.1, where the compatibility byte matters.
        let constrained = try #require(
            AVCConfigurationRecord.parse(avcC: Data([1, 66, 0xE0, 31, 0xFF]))
        )
        #expect(MasterPlaylistBuilder.avcCodecString(constrained) == "avc1.42E01F")
    }

    @Test("Extradata that is not an avcC yields no declaration")
    func rejectsNonAVCC() {
        // Annex-B start code: MPEG-TS style in-band parameter sets.
        #expect(AVCConfigurationRecord.parse(avcC: Data([0, 0, 0, 1, 0x67])) == nil)
        // Truncated record.
        #expect(AVCConfigurationRecord.parse(avcC: Data([1, 100, 0])) == nil)
    }

    @Test("Audio codec tags")
    func audioTags() {
        #expect(MasterPlaylistBuilder.audioCodecString(forCodecName: "eac3") == "ec-3")
        #expect(MasterPlaylistBuilder.audioCodecString(forCodecName: "ac3") == "ac-3")
        #expect(MasterPlaylistBuilder.audioCodecString(forCodecName: "flac") == "fLaC")
        #expect(MasterPlaylistBuilder.audioCodecString(forCodecName: "alac") == "alac")
        #expect(MasterPlaylistBuilder.audioCodecString(forCodecName: "aac") == "mp4a.40.2")
        #expect(
            MasterPlaylistBuilder.audioCodecString(forCodecName: "aac", profileName: "HE-AAC")
                == "mp4a.40.5"
        )
        // TrueHD has no tag: after the phase-3 bridge the caller declares ec-3.
        #expect(MasterPlaylistBuilder.audioCodecString(forCodecName: "truehd") == nil)
    }

    @Test("Frame rates print without trailing zeros")
    func frameRateFormatting() {
        #expect(MasterPlaylistBuilder.format(frameRate: 24.0 * 1000.0 / 1001.0) == "23.976")
        #expect(MasterPlaylistBuilder.format(frameRate: 25) == "25")
        #expect(MasterPlaylistBuilder.format(frameRate: 60.0 * 1000.0 / 1001.0) == "59.94")
        #expect(MasterPlaylistBuilder.format(frameRate: 30) == "30")
    }
}

// MARK: - Master playlist

@Suite("MasterPlaylistBuilder")
struct MasterPlaylistBuilderTests {

    @Test("HDR10 (no DV): plain hvc1 primary, PQ, frame rate present")
    func hdr10() throws {
        let playlist = try MasterPlaylistBuilder.build(try variant(range: .pq))
        #expect(playlist == """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="en",DEFAULT=YES,\
        AUTOSELECT=YES,CHANNELS="16/JOC"
        #EXT-X-STREAM-INF:BANDWIDTH=24000000,AVERAGE-BANDWIDTH=18500000,\
        CODECS="hvc1.2.4.L153.B0,ec-3",RESOLUTION=3840x2160,FRAME-RATE=23.976,VIDEO-RANGE=PQ,\
        AUDIO="aud"
        index.m3u8

        """)
        #expect(!playlist.contains("SUPPLEMENTAL-CODECS"))
    }

    @Test("Dolby Vision Profile 5: bare dvh1 primary, no supplemental")
    func profile5() throws {
        let playlist = try MasterPlaylistBuilder.build(
            try variant(
                range: .pq,
                dolbyVision: dolbyVision(profile: 5, compatibilityID: 0),
                dvCapableDisplay: true
            )
        )
        let line = try streamInf(playlist)
        #expect(line.contains("CODECS=\"dvh1.05.06,ec-3\""))
        #expect(!line.contains("hvc1"))
        #expect(!line.contains("SUPPLEMENTAL-CODECS"))
        #expect(line.contains("VIDEO-RANGE=PQ"))
    }

    @Test("Dolby Vision Profile 5 has no valid master for a non-DV display")
    func profile5NonDVDisplay() throws {
        let description = try variant(
            range: .pq,
            dolbyVision: dolbyVision(profile: 5, compatibilityID: 0),
            dvCapableDisplay: false
        )
        #expect(throws: MasterPlaylistBuilder.SignalingError
            .dolbyVisionProfile5RequiresCapableDisplay) {
            _ = try MasterPlaylistBuilder.build(description)
        }
    }

    @Test("Dolby Vision Profile 8.1 on a DV display: hvc1 primary + db1p supplemental")
    func profile81DVDisplay() throws {
        let playlist = try MasterPlaylistBuilder.build(
            try variant(
                range: .pq,
                dolbyVision: dolbyVision(profile: 8, compatibilityID: 1),
                dvCapableDisplay: true
            )
        )
        let line = try streamInf(playlist)
        #expect(line.contains("CODECS=\"hvc1.2.4.L153.B0,ec-3\""))
        #expect(line.contains("SUPPLEMENTAL-CODECS=\"dvh1.08.06/db1p\""))
        #expect(line.contains("VIDEO-RANGE=PQ"))
        // Attribute order: SUPPLEMENTAL-CODECS immediately follows CODECS.
        let codecsIndex = try #require(line.range(of: "CODECS=\"hvc1")).lowerBound
        let supplementalIndex = try #require(line.range(of: "SUPPLEMENTAL-CODECS")).lowerBound
        #expect(codecsIndex < supplementalIndex)
    }

    @Test("Dolby Vision Profile 8.1 on a non-DV display: HDR10 base only")
    func profile81NonDVDisplay() throws {
        let playlist = try MasterPlaylistBuilder.build(
            try variant(
                range: .pq,
                dolbyVision: dolbyVision(profile: 8, compatibilityID: 1),
                dvCapableDisplay: false
            )
        )
        let line = try streamInf(playlist)
        #expect(line.contains("CODECS=\"hvc1.2.4.L153.B0,ec-3\""))
        #expect(!line.contains("SUPPLEMENTAL-CODECS"))
        #expect(!line.contains("dvh1"))
        // Still HDR: the base layer is HDR10 whether or not DV is engaged.
        #expect(line.contains("VIDEO-RANGE=PQ"))
    }

    @Test("Dolby Vision Profile 8.4 on a DV display: db4h supplemental over an HLG base")
    func profile84DVDisplay() throws {
        let playlist = try MasterPlaylistBuilder.build(
            try variant(
                range: .hlg,
                dolbyVision: dolbyVision(profile: 8, level: 9, compatibilityID: 4),
                dvCapableDisplay: true
            )
        )
        let line = try streamInf(playlist)
        #expect(line.contains("CODECS=\"hvc1.2.4.L153.B0,ec-3\""))
        #expect(line.contains("SUPPLEMENTAL-CODECS=\"dvh1.08.09/db4h\""))
        #expect(line.contains("VIDEO-RANGE=HLG"))
    }

    @Test("Dolby Vision Profile 8.2 is never signaled as DV — its base is Rec.709")
    func profile82() throws {
        let playlist = try MasterPlaylistBuilder.build(
            try variant(
                range: .sdr,
                dolbyVision: dolbyVision(profile: 8, compatibilityID: 2),
                dvCapableDisplay: true
            )
        )
        let line = try streamInf(playlist)
        #expect(line.contains("CODECS=\"hvc1.2.4.L153.B0,ec-3\""))
        #expect(!line.contains("SUPPLEMENTAL-CODECS"))
        #expect(!line.contains("VIDEO-RANGE"))
    }

    @Test("Dolby Vision Profile 7 gets no supplemental until the RPU is converted")
    func profile7() throws {
        let playlist = try MasterPlaylistBuilder.build(
            try variant(
                range: .pq,
                dolbyVision: dolbyVision(profile: 7, compatibilityID: 6),
                dvCapableDisplay: true
            )
        )
        let line = try streamInf(playlist)
        #expect(!line.contains("SUPPLEMENTAL-CODECS"))
        #expect(line.contains("VIDEO-RANGE=PQ"))

        // …and once it has been converted to 8.1, the same call signals DV.
        let converted = try MasterPlaylistBuilder.build(
            try variant(
                range: .pq,
                dolbyVision: dolbyVision(profile: 8, compatibilityID: 1),
                dvCapableDisplay: true
            )
        )
        #expect(try streamInf(converted).contains("SUPPLEMENTAL-CODECS=\"dvh1.08.06/db1p\""))
    }

    @Test("PQ without a frame rate is refused rather than served")
    func pqRequiresFrameRate() throws {
        let description = try variant(range: .pq, frameRate: nil)
        #expect(throws: MasterPlaylistBuilder.SignalingError.frameRateRequiredForHDR(.pq)) {
            _ = try MasterPlaylistBuilder.build(description)
        }
    }

    @Test("HLG without a frame rate is refused too")
    func hlgRequiresFrameRate() throws {
        let description = try variant(range: .hlg, frameRate: nil)
        #expect(throws: MasterPlaylistBuilder.SignalingError.frameRateRequiredForHDR(.hlg)) {
            _ = try MasterPlaylistBuilder.build(description)
        }
    }

    @Test("HLG (no DV): VIDEO-RANGE=HLG, no DV claims")
    func hlg() throws {
        let line = try streamInf(MasterPlaylistBuilder.build(try variant(range: .hlg)))
        #expect(line.contains("VIDEO-RANGE=HLG"))
        #expect(!line.contains("dvh1"))
        #expect(line.contains("FRAME-RATE=23.976"))
    }

    @Test("SDR: no VIDEO-RANGE at all, and the frame rate is optional")
    func sdr() throws {
        let withRate = try streamInf(MasterPlaylistBuilder.build(try variant(range: .sdr)))
        #expect(!withRate.contains("VIDEO-RANGE"))
        #expect(withRate.contains("FRAME-RATE=23.976"))

        let withoutRate = try streamInf(
            MasterPlaylistBuilder.build(try variant(range: .sdr, frameRate: nil))
        )
        #expect(!withoutRate.contains("FRAME-RATE"))
        #expect(!withoutRate.contains("VIDEO-RANGE"))
    }

    @Test("H.264 passes its codec string through untouched")
    func explicitCodec() throws {
        let description = MasterPlaylistBuilder.VariantDescription(
            bandwidth: 8_000_000,
            resolution: .init(width: 1920, height: 1080),
            frameRate: 25,
            videoCodec: .explicit("avc1.640028"),
            audioRenditions: [
                .init(name: "English", language: "en", codecString: "mp4a.40.2", channels: "2"),
            ]
        )
        let line = try streamInf(MasterPlaylistBuilder.build(description))
        #expect(line.contains("CODECS=\"avc1.640028,mp4a.40.2\""))
        #expect(line.contains("RESOLUTION=1920x1080"))
        #expect(line.contains("FRAME-RATE=25"))
    }

    @Test("A separate audio playlist carries a URI; muxed audio omits it")
    func audioRenditionURI() throws {
        var description = try variant(range: .sdr)
        description.audioRenditions[0].uri = "audio0/index.m3u8"
        description.audioRenditions[0].isDefault = true
        let demuxed = try MasterPlaylistBuilder.build(description)
        #expect(demuxed.contains("URI=\"audio0/index.m3u8\""))

        // v0 muxes audio into the video segments: a URI-less EXT-X-MEDIA is
        // how HLS says "this rendition is inside the variant".
        let muxed = try MasterPlaylistBuilder.build(try variant(range: .sdr))
        #expect(!muxed.contains("URI="))
        #expect(muxed.contains("DEFAULT=YES,AUTOSELECT=YES"))
    }

    @Test("No audio track: no EXT-X-MEDIA line and no AUDIO attribute")
    func noAudio() throws {
        let playlist = try MasterPlaylistBuilder.build(try variant(range: .sdr, audio: []))
        #expect(!playlist.contains("#EXT-X-MEDIA"))
        let line = try streamInf(playlist)
        #expect(!line.contains("AUDIO="))
        #expect(line.contains("CODECS=\"hvc1.2.4.L153.B0\""))
    }

    @Test("LANGUAGE is an RFC 5646 tag, not the container's ISO 639-2/B code")
    func languageTagsAreCanonical() throws {
        let playlist = try MasterPlaylistBuilder.build(try variant(range: .sdr, audio: [
            .init(name: "Français", language: "fre", codecString: "mp4a.40.2",
                  channels: "2", uri: "audio0/index.m3u8", isDefault: true),
            .init(name: "Unknown", language: "und", codecString: "mp4a.40.2",
                  channels: "2", uri: "audio1/index.m3u8", isDefault: false),
        ]))
        let media = playlist.split(separator: "\n").filter { $0.hasPrefix("#EXT-X-MEDIA:") }
        #expect(media[0].contains("LANGUAGE=\"fr\""))
        #expect(!media[1].contains("LANGUAGE="))
    }

    @Test("N audio tracks become N renditions of one group, one of them DEFAULT")
    func multipleRenditions() throws {
        let playlist = try MasterPlaylistBuilder.build(try variant(range: .sdr, audio: [
            .init(name: "English", language: "eng", codecString: "mp4a.40.2",
                  channels: "2", uri: "audio0/index.m3u8", isDefault: true),
            .init(name: "Czech", language: "ces", codecString: "ac-3",
                  channels: "6", uri: "audio1/index.m3u8", isDefault: false),
            .init(name: "Commentary", language: "eng", codecString: "mp4a.40.2",
                  channels: "2", uri: "audio2/index.m3u8", isDefault: false),
        ]))
        let media = playlist.split(separator: "\n").filter { $0.hasPrefix("#EXT-X-MEDIA:") }
        #expect(media.count == 3)
        // One group, so one AUDIO reference on the variant and a switchable set.
        #expect(media.allSatisfy { $0.contains("GROUP-ID=\"aud\"") })
        #expect(try streamInf(playlist).contains("AUDIO=\"aud\""))
        #expect(media.filter { $0.contains("DEFAULT=YES") }.count == 1)
        // Every rendition is selectable, default or not — otherwise the
        // alternates can't be reached by a language preference.
        #expect(media.allSatisfy { $0.contains("AUTOSELECT=YES") })
        #expect(media[1].contains("LANGUAGE=\"cs\""))

        // CODECS names the DEFAULT rendition's codec only: an over-claim gets
        // the whole variant filtered at parse time.
        let line = try streamInf(playlist)
        #expect(line.contains("CODECS=\"hvc1.2.4.L153.B0,mp4a.40.2\""))
        #expect(!line.contains("ac-3"))
    }

    @Test("Renditions in a different order still declare the DEFAULT one's codec")
    func codecFollowsTheDefaultRendition() throws {
        let playlist = try MasterPlaylistBuilder.build(try variant(range: .sdr, audio: [
            .init(name: "Czech", language: "ces", codecString: "ac-3",
                  uri: "audio0/index.m3u8", isDefault: false),
            .init(name: "English", language: "eng", codecString: "ec-3",
                  uri: "audio1/index.m3u8", isDefault: true),
        ]))
        #expect(try streamInf(playlist).contains("CODECS=\"hvc1.2.4.L153.B0,ec-3\""))
    }

    @Test("A quote in a container-supplied track name can't break the attribute list")
    func quotesInNames() throws {
        var description = try variant(range: .sdr)
        description.audioRenditions[0].name = "Director\"s commentary"
        let playlist = try MasterPlaylistBuilder.build(description)
        #expect(playlist.contains("NAME=\"Director's commentary\""))
    }
}

// MARK: - Routing verdicts

@Suite("SourceInfo routing")
struct SourceInfoRoutingTests {

    private func video(_ copyability: StreamCopyability) -> VideoTrackInfo {
        VideoTrackInfo(
            streamIndex: 0,
            codecName: "hevc",
            profileName: "Main 10",
            profile: 2,
            level: 153,
            width: 3840,
            height: 2160,
            sampleAspectRatio: nil,
            bitDepth: 10,
            colorPrimariesName: "bt2020",
            colorTransferName: "smpte2084",
            colorSpaceName: "bt2020nc",
            isBT2020: true,
            frameRate: 23.976,
            frameRateSource: .averageFrameRate,
            fieldOrder: .progressive,
            hevcConfiguration: nil,
            avcConfiguration: nil,
            av1Configuration: nil,
            nalUnitLengthSize: nil,
            dolbyVision: nil,
            dynamicRange: .pq,
            copyability: copyability
        )
    }

    private func audio(_ name: String, _ copyability: StreamCopyability) -> AudioTrackInfo {
        AudioTrackInfo(
            streamIndex: 1,
            codecName: name,
            profileName: nil,
            channelCount: 6,
            channelLayoutDescription: "5.1",
            sampleRate: 48_000,
            language: "eng",
            title: nil,
            isObjectAudio: false,
            copyability: copyability
        )
    }

    private func info(video: VideoTrackInfo?, audio: [AudioTrackInfo]) -> SourceInfo {
        SourceInfo(formatName: "matroska,webm", duration: 7200, video: video, audioTracks: audio)
    }

    @Test("Copyable video plus copyable audio is native-ready")
    func streamCopy() {
        let source = info(video: video(.streamCopy), audio: [audio("eac3", .streamCopy)])
        #expect(source.nativeReadiness == .streamCopy)
        #expect(source.preferredCopyableAudioTrack?.codecName == "eac3")
    }

    @Test("An AC3 compat track wins over a TrueHD main track")
    func prefersCopyableAudio() {
        let source = info(
            video: video(.streamCopy),
            audio: [audio("truehd", .requiresAudioBridge), audio("ac3", .streamCopy)]
        )
        #expect(source.nativeReadiness == .streamCopy)
        #expect(source.preferredCopyableAudioTrack?.codecName == "ac3")
    }

    @Test("TrueHD-only audio needs the bridge")
    func bridge() {
        let source = info(video: video(.streamCopy), audio: [audio("truehd", .requiresAudioBridge)])
        #expect(source.nativeReadiness == .requiresAudioBridge)
        #expect(source.preferredCopyableAudioTrack == nil)
    }

    @Test("Unsupported video keeps the source on Prism regardless of its audio")
    func unsupportedVideo() {
        let source = info(video: video(.unsupported), audio: [audio("aac", .streamCopy)])
        #expect(source.nativeReadiness == .unsupported)
        #expect(info(video: nil, audio: []).nativeReadiness == .unsupported)
    }

    @Test("A silent film is still native-ready")
    func noAudioTracks() {
        #expect(info(video: video(.streamCopy), audio: []).nativeReadiness == .streamCopy)
    }
}
