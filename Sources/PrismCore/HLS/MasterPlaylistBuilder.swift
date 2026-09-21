import Foundation

/// Builds the HLS **master** playlist that wraps the remux's media playlist.
///
/// A bare media playlist is enough to play, but it says nothing about the
/// stream: no `CODECS`, no `VIDEO-RANGE`, no `SUPPLEMENTAL-CODECS`, and — the
/// reason the session serves a master at all today — no way to offer more than
/// one audio track. Those attributes are the only way to ask Apple's stack for
/// HDR and to make AVKit engage Dolby Vision, and an `EXT-X-MEDIA` group is the
/// only way an `AVMediaSelectionGroup` of audio renditions comes into being.
///
/// Deliberately pure: values in, string out, no I/O and no libavformat. Every
/// signaling rule is therefore pinned by a unit test instead of by a device.
/// The rules themselves are unforgiving — a manifest that over-claims is worse
/// than no manifest at all, because AVPlayer rejects the whole item
/// (`-11868` no compatible alternates, `-11848` SDR-parked panel, `-1002` when
/// every variant was filtered at parse time) rather than degrading.
public enum MasterPlaylistBuilder {

    // MARK: - Input

    public struct Resolution: Sendable, Equatable {
        public let width: Int
        public let height: Int
        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    /// How the variant's video codec is declared.
    public enum VideoCodec: Sendable, Equatable {
        /// HEVC, declared from the source's own `hvcC` profile_tier_level.
        case hevc(HEVCConfigurationRecord)
        /// H.264, declared from the source's own `avcC` three PTL bytes.
        case avc(AVCConfigurationRecord)
        /// AV1, declared from the source's own `av1C`.
        case av1(AV1ConfigurationRecord)
        /// Anything else, where the caller already has the RFC 6381 string.
        case explicit(String)
    }

    /// One selectable audio rendition. The remuxer emits one per viable audio
    /// track of the source, each backed by its own media playlist.
    public struct AudioRendition: Sendable, Equatable {
        public var groupID: String
        public var name: String
        /// BCP-47 / ISO-639 tag as it came out of the container metadata.
        public var language: String?
        /// RFC 6381 tag: `mp4a.40.2`, `ac-3`, `ec-3`, `fLaC`, `alac`.
        public var codecString: String?
        /// HLS `CHANNELS` value. Plain channel count for most codecs; EAC3
        /// with object audio uses the `"16/JOC"` form, which is how Atmos is
        /// advertised — hence a String, not an Int.
        public var channels: String?
        /// `nil` means the audio is muxed into the variant's own segments
        /// (v0's shape: one fMP4 with both tracks). HLS reads a URI-less
        /// `EXT-X-MEDIA` exactly that way, so the rendition still shows up as
        /// a selectable `AVMediaSelectionOption`.
        public var uri: String?
        /// `DEFAULT=YES`. Exactly one rendition of a group may claim it, and
        /// the caller decides which — the builder prints what it is told.
        public var isDefault: Bool
        /// UTI media characteristics (`CHARACTERISTICS`), e.g.
        /// `public.accessibility.enhances-speech-intelligibility` on a
        /// dialogue-boost rendition. Empty prints nothing. This is how a host
        /// finds such renditions programmatically —
        /// `AVMediaSelectionOption.hasMediaCharacteristic(_:)` — instead of
        /// matching display names.
        public var characteristics: [String]

        public init(
            groupID: String = "aud",
            name: String,
            language: String? = nil,
            codecString: String? = nil,
            channels: String? = nil,
            uri: String? = nil,
            isDefault: Bool = true,
            characteristics: [String] = []
        ) {
            self.groupID = groupID
            self.name = name
            self.language = language
            self.codecString = codecString
            self.channels = channels
            self.uri = uri
            self.isDefault = isDefault
            self.characteristics = characteristics
        }
    }

    /// One WebVTT subtitle rendition (phase 6).
    ///
    /// `DEFAULT=NO,AUTOSELECT=NO` unless the caller says otherwise, and that
    /// default is load-bearing: with either set to `YES` AVKit engages the
    /// rendition by itself, which double-draws against a host overlay and
    /// turns subtitles on for users who never asked. The host normally selects
    /// the rendition programmatically through the legible
    /// `AVMediaSelectionGroup` instead.
    ///
    /// `isDefault` exists for the one case where "the user never asked" is
    /// false: a session built with a `preferredSubtitleLanguage`, which is the
    /// host relaying an explicit request. Nothing else may set it.
    public struct SubtitleRendition: Sendable, Equatable {
        public var groupID: String
        public var name: String
        /// BCP-47 / ISO-639 tag from the container metadata (or the caller's,
        /// for an external file).
        public var language: String?
        /// Relative URI of the rendition's media playlist. Required — a
        /// subtitle rendition is never muxed into the variant's segments.
        public var uri: String
        /// Container `FORCED` disposition: subtitles for foreign dialogue only.
        /// Emitted as `FORCED=YES` so the host can tell them apart in the
        /// selection group.
        public var isForced: Bool
        /// `DEFAULT=YES,AUTOSELECT=YES` — see the type doc. At most one
        /// rendition of a group may claim it.
        public var isDefault: Bool

        public init(
            groupID: String = "subs",
            name: String,
            language: String? = nil,
            uri: String,
            isForced: Bool = false,
            isDefault: Bool = false
        ) {
            self.groupID = groupID
            self.name = name
            self.language = language
            self.uri = uri
            self.isForced = isForced
            self.isDefault = isDefault
        }
    }

    public struct VariantDescription: Sendable, Equatable {
        /// Relative URI of the media playlist the remuxer writes.
        public var mediaPlaylistURI: String
        /// Peak bitrate estimate, in bits/s. Caller-provided: the remuxer
        /// knows the source's bit rate, the builder does not measure.
        public var bandwidth: Int
        public var averageBandwidth: Int?
        public var resolution: Resolution?
        /// Required for `VIDEO-RANGE=PQ` / `HLG` (see `build`).
        public var frameRate: Double?
        public var dynamicRange: DynamicRange
        public var videoCodec: VideoCodec
        /// The source's DV configuration, when it has one.
        public var dolbyVision: DolbyVisionConfiguration?
        /// Whether the *display this session is going to* can present Dolby
        /// Vision. Not a source property and not cacheable: the same file gets
        /// a different manifest on a DV panel and on an HDR10 one, and
        /// claiming DV to a non-DV display fails the item outright.
        public var displayIsDolbyVisionCapable: Bool
        /// Every selectable audio rendition, in the order they are offered.
        /// Empty for a silent source (no `EXT-X-MEDIA`, no `AUDIO` attribute).
        public var audioRenditions: [AudioRendition]
        /// WebVTT subtitle renditions, in declaration order. Empty means the
        /// manifest says nothing about subtitles — the pre-phase-6 shape.
        public var subtitles: [SubtitleRendition]

        public init(
            mediaPlaylistURI: String = "index.m3u8",
            bandwidth: Int,
            averageBandwidth: Int? = nil,
            resolution: Resolution? = nil,
            frameRate: Double? = nil,
            dynamicRange: DynamicRange = .sdr,
            videoCodec: VideoCodec,
            dolbyVision: DolbyVisionConfiguration? = nil,
            displayIsDolbyVisionCapable: Bool = false,
            audioRenditions: [AudioRendition] = [],
            subtitles: [SubtitleRendition] = []
        ) {
            self.mediaPlaylistURI = mediaPlaylistURI
            self.bandwidth = bandwidth
            self.averageBandwidth = averageBandwidth
            self.resolution = resolution
            self.frameRate = frameRate
            self.dynamicRange = dynamicRange
            self.videoCodec = videoCodec
            self.dolbyVision = dolbyVision
            self.displayIsDolbyVisionCapable = displayIsDolbyVisionCapable
            self.audioRenditions = audioRenditions
            self.subtitles = subtitles
        }
    }

    public enum SignalingError: Error, Equatable {
        /// AVPlayer filters a `VIDEO-RANGE=PQ`/`HLG` variant that carries no
        /// `FRAME-RATE` out of the master while parsing it, then fails the
        /// item with `-1002` without ever fetching the media playlist. A
        /// source whose frame rate the demuxer couldn't determine therefore
        /// must not be served a master at all — it plays media-direct.
        case frameRateRequiredForHDR(DynamicRange)
        /// Profile 5 has no base layer: `dvh1` is the only correct declaration
        /// (without it the IPT-PQ chroma is read as YCbCr and the picture goes
        /// green/purple), and a `dvh1` variant offered to a non-DV display is
        /// rejected with `-11868`. So P5 + non-DV display has no valid master;
        /// it plays media-direct.
        case dolbyVisionProfile5RequiresCapableDisplay
    }

    // MARK: - Output

    public static func build(_ variant: VariantDescription) throws -> String {
        if variant.dynamicRange != .sdr, variant.frameRate == nil {
            throw SignalingError.frameRateRequiredForHDR(variant.dynamicRange)
        }
        if let dv = variant.dolbyVision, dv.isSingleLayerDVOnly,
           !variant.displayIsDolbyVisionCapable {
            throw SignalingError.dolbyVisionProfile5RequiresCapableDisplay
        }

        var lines = [
            "#EXTM3U",
            // 7 is the floor for fMP4 media segments (`EXT-X-MAP`), which is
            // what every rendition below is.
            "#EXT-X-VERSION:7",
            // Every segment starts on a keyframe (the remux cuts on the
            // source's own IDRs), which lets AVPlayer start on any of them.
            "#EXT-X-INDEPENDENT-SEGMENTS",
        ]

        for audio in variant.audioRenditions {
            lines.append(mediaLine(for: audio))
        }
        for subtitle in variant.subtitles {
            lines.append(mediaLine(for: subtitle))
        }
        lines.append(try streamInfLine(for: variant))
        lines.append(variant.mediaPlaylistURI)

        return lines.joined(separator: "\n") + "\n"
    }

    private static func mediaLine(for audio: AudioRendition) -> String {
        var attributes = [
            "TYPE=AUDIO",
            "GROUP-ID=\(quoted(audio.groupID))",
            "NAME=\(quoted(audio.name))",
        ]
        if let language = audio.language, !language.isEmpty {
            attributes.append("LANGUAGE=\(quoted(language))")
        }
        attributes.append("DEFAULT=\(audio.isDefault ? "YES" : "NO")")
        // AUTOSELECT=YES on every rendition, default or not: it is what lets
        // AVFoundation honour the user's system audio-language preference (and
        // `AVPlayerItem.select(_:in:)` with a language criterion) instead of
        // locking playback to whichever track the container listed first.
        // NO would make the alternates dead weight in the selection group.
        attributes.append("AUTOSELECT=YES")
        if !audio.characteristics.isEmpty {
            attributes.append("CHARACTERISTICS=\(quoted(audio.characteristics.joined(separator: ",")))")
        }
        if let channels = audio.channels, !channels.isEmpty {
            attributes.append("CHANNELS=\(quoted(channels))")
        }
        if let uri = audio.uri, !uri.isEmpty {
            attributes.append("URI=\(quoted(uri))")
        }
        return "#EXT-X-MEDIA:" + attributes.joined(separator: ",")
    }

    /// `EXT-X-MEDIA` for a WebVTT rendition. No `CODECS` contribution: HLS
    /// declares `wvtt` only for fMP4-packaged timed text, and a `CODECS` entry
    /// for a plain `.vtt` rendition makes AVPlayer filter the variant.
    private static func mediaLine(for subtitle: SubtitleRendition) -> String {
        var attributes = [
            "TYPE=SUBTITLES",
            "GROUP-ID=\(quoted(subtitle.groupID))",
            "NAME=\(quoted(subtitle.name))",
        ]
        if let language = subtitle.language, !language.isEmpty {
            attributes.append("LANGUAGE=\(quoted(language))")
        }
        // See `SubtitleRendition`: NO unless the host explicitly asked for
        // this language. AUTOSELECT follows DEFAULT rather than being its own
        // knob — a DEFAULT=YES,AUTOSELECT=NO rendition is a rendition AVKit
        // engages but will not re-engage after the user has touched the menu.
        attributes.append("DEFAULT=\(subtitle.isDefault ? "YES" : "NO")")
        attributes.append("AUTOSELECT=\(subtitle.isDefault ? "YES" : "NO")")
        if subtitle.isForced {
            attributes.append("FORCED=YES")
        }
        attributes.append("URI=\(quoted(subtitle.uri))")
        return "#EXT-X-MEDIA:" + attributes.joined(separator: ",")
    }

    private static func streamInfLine(for variant: VariantDescription) throws -> String {
        var attributes = ["BANDWIDTH=\(variant.bandwidth)"]
        if let average = variant.averageBandwidth {
            attributes.append("AVERAGE-BANDWIDTH=\(average)")
        }

        var codecs = [primaryVideoCodecString(for: variant)]
        // Only the DEFAULT rendition's codec is declared, even when the group
        // holds renditions of other codecs. Apple's authoring rules want one
        // group (and one variant) per audio codec, which for a remux proxy
        // would mean N near-identical variants AVPlayer would treat as bitrate
        // alternatives of each other. Listing the union instead is the worse
        // trade: a single codec this platform can't decode gets the whole
        // variant filtered at master-parse time (`-1002`), so an exotic
        // secondary track would take the playable ones down with it. The
        // alternates still play when selected — `EXT-X-MEDIA` carries its own
        // media playlist and init segment.
        if let audioCodec = defaultRendition(of: variant)?.codecString, !audioCodec.isEmpty {
            codecs.append(audioCodec)
        }
        attributes.append("CODECS=\(quoted(codecs.joined(separator: ",")))")

        if let supplemental = supplementalCodecsString(for: variant) {
            attributes.append("SUPPLEMENTAL-CODECS=\(quoted(supplemental))")
        }
        if let resolution = variant.resolution {
            attributes.append("RESOLUTION=\(resolution.width)x\(resolution.height)")
        }
        // SDR variants are accepted without FRAME-RATE, so it stays optional
        // there and is simply omitted rather than guessed.
        if let frameRate = variant.frameRate {
            attributes.append("FRAME-RATE=\(format(frameRate: frameRate))")
        }
        // VIDEO-RANGE is omitted for SDR: absent means SDR in HLS, and the
        // shortest honest manifest is the one with the fewest claims.
        if variant.dynamicRange != .sdr {
            attributes.append("VIDEO-RANGE=\(variant.dynamicRange.rawValue)")
        }
        if let group = variant.audioRenditions.first?.groupID {
            attributes.append("AUDIO=\(quoted(group))")
        }
        // One group for every subtitle rendition; the first one names it.
        if let group = variant.subtitles.first?.groupID {
            attributes.append("SUBTITLES=\(quoted(group))")
        }
        return "#EXT-X-STREAM-INF:" + attributes.joined(separator: ",")
    }

    /// The rendition whose codec the variant declares: the one flagged
    /// `DEFAULT`, or the first offered when nobody claimed it.
    private static func defaultRendition(
        of variant: VariantDescription
    ) -> AudioRendition? {
        variant.audioRenditions.first(where: \.isDefault) ?? variant.audioRenditions.first
    }

    /// Whether `build(_:)` prints any Dolby Vision claim for this variant — a
    /// `dvh1` primary tag (Profile 5) or a `SUPPLEMENTAL-CODECS` entry.
    ///
    /// This is what the master-rejection fallback's first tier drops: a DV
    /// claim is validated against the panel's *current* mode, and on a panel
    /// whose true state no read can prove (Match Content off), dropping the
    /// claim — while keeping `VIDEO-RANGE`, the renditions and the subtitles —
    /// is the retry that still plays as HDR10 with everything selectable.
    public static func declaresDolbyVision(_ variant: VariantDescription) -> Bool {
        if let dv = variant.dolbyVision, dv.isSingleLayerDVOnly { return true }
        return supplementalCodecsString(for: variant) != nil
    }

    // MARK: - Codec strings

    /// The primary `CODECS` entry for the video track.
    static func primaryVideoCodecString(for variant: VariantDescription) -> String {
        if let dv = variant.dolbyVision, dv.isSingleLayerDVOnly {
            // Profile 5: a bare `dvh1` tag, no HEVC tag anywhere. There is no
            // base layer to declare, and the DV level (not the HEVC level)
            // is what follows.
            return "dvh1.\(twoDigits(dv.profile)).\(twoDigits(dv.level))"
        }
        switch variant.videoCodec {
        case .hevc(let record):
            return hevcCodecString(record)
        case .avc(let record):
            return avcCodecString(record)
        case .av1(let record):
            return av1CodecString(record)
        case .explicit(let string):
            return string
        }
    }

    /// `avc1.PPCCLL` per RFC 6381: profile_idc, profile_compatibility and
    /// level_idc as three uppercase hex bytes, straight out of the `avcC`.
    /// High profile level 4.0 is the familiar `avc1.640028`.
    static func avcCodecString(_ record: AVCConfigurationRecord) -> String {
        String(
            format: "avc1.%02X%02X%02X",
            Int(record.profileIDC),
            Int(record.profileCompatibility),
            Int(record.levelIDC)
        )
    }

    /// `SUPPLEMENTAL-CODECS`, or `nil` when this variant must not claim DV.
    ///
    /// Only the base-layer-compatible profiles can be signaled this way, and
    /// only to a display that can actually present DV: a lone `hvc1` primary
    /// plus a DV supplemental offered to a non-DV display is rejected with
    /// `-11868`, and the same source plays perfectly as its plain HDR10 / HLG
    /// base once the claim is dropped.
    static func supplementalCodecsString(for variant: VariantDescription) -> String? {
        guard let dv = variant.dolbyVision, variant.displayIsDolbyVisionCapable else { return nil }
        // Profile 5 is fully declared by the primary tag; it has no base
        // codec to supplement.
        guard !dv.isSingleLayerDVOnly else { return nil }
        guard let brand = dolbyVisionBrand(for: dv) else { return nil }
        return "dvh1.\(twoDigits(dv.profile)).\(twoDigits(dv.level))/\(brand)"
    }

    /// The ISO brand that names the *base* layer's compatibility, which is the
    /// half of the supplemental tag AVKit reads to decide what to do on a
    /// non-DV fallback.
    ///
    /// - `db1p` — 8.1, HDR10 (PQ) base.
    /// - `db4h` — 8.4, HLG base.
    ///
    /// Everything else returns `nil` on purpose:
    /// - **8.2** carries a Rec.709 base no Apple platform can present as DV;
    ///   it plays as plain SDR `hvc1`.
    /// - **7** is dual-layer and has no Apple decoder. Phase 4 groundwork only
    ///   reports it; once the RPU is converted to 8.1 during muxing the
    ///   caller passes the *converted* configuration here and gets `db1p`.
    /// - unknown profiles are never guessed at.
    private static func dolbyVisionBrand(for dv: DolbyVisionConfiguration) -> String? {
        guard dv.profile == 8 else { return nil }
        switch dv.baseLayerSignalCompatibilityID {
        case 1: return "db1p"
        case 4: return "db4h"
        default: return nil
        }
    }

    /// `hvc1.<space><profile>.<compat>.<tier><level>.<constraints>` per
    /// RFC 6381 / ISO 14496-15 Annex E.
    ///
    /// The one element everybody gets wrong is the compatibility flags: the
    /// value printed is the stored `general_profile_compatibility_flags` in
    /// **reverse bit order**. A real Main10 record stores `0x20000000`, whose
    /// reversal is `0x4` — hence the familiar `hvc1.2.4.…`. Printing the
    /// stored value instead would yield `hvc1.2.20000000`, which AVPlayer
    /// checks against the init segment and refuses.
    static func hevcCodecString(_ record: HEVCConfigurationRecord) -> String {
        var element = "hvc1."

        // profile_space 0 prints nothing; 1/2/3 print 'A'/'B'/'C'.
        if record.profileSpace > 0 {
            let scalar = UnicodeScalar(UInt8(ascii: "A") + record.profileSpace - 1)
            element.append(Character(scalar))
        }
        element += "\(record.profileIDC)."
        element += hexString(UInt64(reverseBits(record.profileCompatibilityFlags)))
        element += "."
        element += record.tierFlag == 0 ? "L" : "H"
        element += "\(record.levelIDC)"

        // The six constraint bytes, most significant first, each as two hex
        // digits (what MP4Box and Dolby's reference manifests print), with
        // trailing zero bytes omitted — a plain Main10 record ends `.B0`.
        var constraintBytes: [UInt8] = (0..<6).map { index in
            UInt8((record.constraintIndicatorFlags >> UInt64((5 - index) * 8)) & 0xFF)
        }
        while let last = constraintBytes.last, last == 0 {
            constraintBytes.removeLast()
        }
        for byte in constraintBytes {
            element += "." + String(format: "%02X", byte)
        }
        return element
    }

    /// The `CHANNELS` value for a rendition — `"16/JOC"` for Dolby Atmos, the
    /// plain channel count otherwise.
    ///
    /// `16/JOC` is not a channel count, it is HLS's *declaration* that the
    /// rendition carries joint object coding: 16 is the fixed figure Apple's
    /// authoring rules require, whatever the underlying bed is (an Atmos EAC3
    /// track's `ch_layout` reads 6). Without it the objects still reach an AVR —
    /// the stream is copied untouched, and the receiver is what decodes JOC — but
    /// AVFoundation has no way to know the rendition is Atmos, so it can't prefer
    /// it in a selection group and tvOS won't badge it.
    ///
    /// - Parameter isObjectAudio: must be true **only** for a stream-copied
    ///   EAC3+JOC track. Declaring JOC over the audio bridge's output would be a
    ///   lie: the bridge decodes to PCM and re-encodes, so the objects are gone.
    public static func channelsAttribute(channelCount: Int?, isObjectAudio: Bool) -> String? {
        if isObjectAudio { return "16/JOC" }
        guard let channelCount, channelCount > 0 else { return nil }
        return String(channelCount)
    }

    /// `av01.<profile>.<level><tier>.<bitDepth>` per the AV1 codec-string spec:
    /// profile as one digit, `seq_level_idx` as two, tier as `M`/`H`, luma bit
    /// depth as two. Level 4.0 Main tier 10-bit reads `av01.0.08M.10`.
    ///
    /// The optional tail (monochrome, chroma subsampling, colour description) is
    /// omitted deliberately — every field there has a default that matches what a
    /// remux of ordinary content carries, and a shorter honest tag is better than
    /// a longer one with a guess in it.
    static func av1CodecString(_ record: AV1ConfigurationRecord) -> String {
        String(
            format: "av01.%d.%02d%@.%02d",
            Int(record.profile),
            Int(record.levelIndex),
            record.tier == 0 ? "M" : "H",
            Int(record.bitDepth)
        )
    }

    /// RFC 6381 tags for the audio codecs the v0 remuxer stream-copies.
    /// `nil` for anything the phase-3 bridge would have to touch — by then the
    /// caller declares the *bridged* codec (`ec-3`), not the source's.
    public static func audioCodecString(forCodecName name: String, profileName: String? = nil) -> String? {
        switch name {
        case "aac":
            // HE-AAC is object type 5, HE-AACv2 is 29; everything else the
            // remuxer copies is plain AAC-LC (2).
            switch profileName {
            case "HE-AAC": return "mp4a.40.5"
            case "HE-AACv2": return "mp4a.40.29"
            default: return "mp4a.40.2"
            }
        case "ac3": return "ac-3"
        case "eac3": return "ec-3"
        case "flac": return "fLaC"
        case "alac": return "alac"
        case "opus": return "Opus"
        default: return nil
        }
    }

    // MARK: - Formatting helpers

    /// Reverses the bit order of a 32-bit value (LSB↔MSB).
    static func reverseBits(_ value: UInt32) -> UInt32 {
        var input = value
        var output: UInt32 = 0
        for _ in 0..<32 {
            output = (output << 1) | (input & 1)
            input >>= 1
        }
        return output
    }

    /// Uppercase hex, no leading zeros ("0" stays "0").
    private static func hexString(_ value: UInt64) -> String {
        String(value, radix: 16, uppercase: true)
    }

    private static func twoDigits(_ value: UInt8) -> String {
        String(format: "%02d", Int(value))
    }

    /// Three decimals is enough for every real rate (23.976, 29.97, 59.94)
    /// and trailing zeros are trimmed so integral rates print as "25" / "60".
    static func format(frameRate: Double) -> String {
        var text = String(format: "%.3f", frameRate)
        while text.contains("."), text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Quoted-string attribute values can't contain a double quote, so any in
    /// a track name (which came from container metadata) is folded to a
    /// single quote rather than emitted and breaking the parse.
    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "'") + "\""
    }
}
