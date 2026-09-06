import Foundation
import Libavcodec
import Libavfilter
import Libavformat
import Libavutil
import Libswresample
import Libswscale

/// Which FFmpeg actually answered, and whether it is the one we compiled
/// against.
///
/// Both halves of that question have already cost us time. PrismCore compiles
/// against MPVKit's headers, but an integrating host may override the package
/// with its own fork of the same identity (see `Package.swift`) — so the
/// libraries that answer at runtime are not necessarily the ones the headers
/// described. A **major** version apart is not a cosmetic difference: libav*
/// bumps major exactly when a public struct's layout changes, and Swift reads
/// those structs field by field through the headers it saw. `AVStream`,
/// `AVCodecParameters` and `AVFrame` are read on every packet in this engine,
/// so a silent major drift is not a wrong version string, it is wrong pixels
/// and wrong timestamps — with no error anywhere to point at it.
///
/// The second half is behaviour that legitimately differs *between* correct
/// builds. Half the routing decisions in this engine are questions about the
/// build rather than the media: whether `eac3` was compiled in decides whether
/// a TrueHD track bridges or evicts the source to the software path, and stock
/// MPVKit ships the E-AC-3 *decoders* only. A bug report that says "audio is
/// missing" is unreproducible without knowing which build was asked; the same
/// report with `summary` attached usually needs no round trip at all.
///
/// Nothing here reads media or opens anything — it is four `*_version()` calls
/// and a string, cheap enough for a host to log at launch and to put behind a
/// diagnostics screen:
///
/// ```swift
/// print(FFmpegBuild.summary)
/// if !FFmpegBuild.isABIMatched { /* refuse, or at least log loudly */ }
/// ```
public enum FFmpegBuild {

    /// A libav* version triple. Kept as three numbers rather than the packed
    /// `int` the C API hands out, because the only comparison that matters —
    /// major against major — is the one the packed form hides.
    public struct Version: Sendable, Equatable, CustomStringConvertible {
        public let major: Int
        public let minor: Int
        public let micro: Int

        init(major: Int, minor: Int, micro: Int) {
            self.major = major
            self.minor = minor
            self.micro = micro
        }

        /// Unpacks `AV_VERSION_INT`'s layout: major, minor, micro at 16/8/0.
        init(packed: UInt32) {
            self.major = Int((packed >> 16) & 0xFF)
            self.minor = Int((packed >> 8) & 0xFF)
            self.micro = Int(packed & 0xFF)
        }

        public var description: String { "\(major).\(minor).\(micro)" }
    }

    /// One linked libav* library: what the headers promised, and what the
    /// runtime delivered.
    public struct Library: Sendable, Equatable, CustomStringConvertible {
        /// The library's own name (`libavcodec`, …), as FFmpeg spells it.
        public let name: String
        /// The version of the headers this build of PrismCore was compiled
        /// against.
        public let compiled: Version
        /// The version that answered `*_version()` in this process.
        public let loaded: Version

        /// Same major means the struct layouts this engine walks are the ones
        /// its headers described. Minor and micro drift is expected and fine —
        /// libav* adds fields within a major, and everything we read predates
        /// them.
        public var isABIMatched: Bool { compiled.major == loaded.major }

        public var description: String {
            isABIMatched
                ? "\(name) \(loaded)"
                : "\(name) \(loaded) ⚠︎ compiled against \(compiled)"
        }
    }

    /// Every libav* library this engine links, in FFmpeg's own dependency
    /// order. `libavfilter`, `libswresample` and `libswscale` are in the list
    /// even though only the audio bridge and the seek-preview scaler touch
    /// them — a host that overrode the package overrode all of them, and a
    /// mismatch in the one library the current session happens not to use is
    /// still the signal that the override is wrong.
    public static let libraries: [Library] = [
        Library(
            name: "libavutil",
            compiled: Version(
                major: Int(LIBAVUTIL_VERSION_MAJOR),
                minor: Int(LIBAVUTIL_VERSION_MINOR),
                micro: Int(LIBAVUTIL_VERSION_MICRO)
            ),
            loaded: Version(packed: avutil_version())
        ),
        Library(
            name: "libavcodec",
            compiled: Version(
                major: Int(LIBAVCODEC_VERSION_MAJOR),
                minor: Int(LIBAVCODEC_VERSION_MINOR),
                micro: Int(LIBAVCODEC_VERSION_MICRO)
            ),
            loaded: Version(packed: avcodec_version())
        ),
        Library(
            name: "libavformat",
            compiled: Version(
                major: Int(LIBAVFORMAT_VERSION_MAJOR),
                minor: Int(LIBAVFORMAT_VERSION_MINOR),
                micro: Int(LIBAVFORMAT_VERSION_MICRO)
            ),
            loaded: Version(packed: avformat_version())
        ),
        Library(
            name: "libavfilter",
            compiled: Version(
                major: Int(LIBAVFILTER_VERSION_MAJOR),
                minor: Int(LIBAVFILTER_VERSION_MINOR),
                micro: Int(LIBAVFILTER_VERSION_MICRO)
            ),
            loaded: Version(packed: avfilter_version())
        ),
        Library(
            name: "libswresample",
            compiled: Version(
                major: Int(LIBSWRESAMPLE_VERSION_MAJOR),
                minor: Int(LIBSWRESAMPLE_VERSION_MINOR),
                micro: Int(LIBSWRESAMPLE_VERSION_MICRO)
            ),
            loaded: Version(packed: swresample_version())
        ),
        Library(
            name: "libswscale",
            compiled: Version(
                major: Int(LIBSWSCALE_VERSION_MAJOR),
                minor: Int(LIBSWSCALE_VERSION_MINOR),
                micro: Int(LIBSWSCALE_VERSION_MICRO)
            ),
            loaded: Version(packed: swscale_version())
        ),
    ]

    /// The libraries whose major version disagrees with our headers — empty on
    /// a sane install.
    public static var mismatchedLibraries: [Library] {
        libraries.filter { !$0.isABIMatched }
    }

    /// Whether every linked library matches the headers this engine saw.
    ///
    /// A host that ships its own FFmpeg fork should assert this once at launch.
    /// PrismCore deliberately does **not** refuse to run on `false`: the engine
    /// cannot know whether the drift touches anything this particular source
    /// needs, and a hard failure would ground a host over a build detail its
    /// media may never reach. Loud, not fatal.
    public static var isABIMatched: Bool { mismatchedLibraries.isEmpty }

    /// FFmpeg's own build identity — `n8.0.1-eac3-vt.1` for the fork we ship
    /// against, a bare `8.0.1` for a stock tarball. This is the string that
    /// names *which* FFmpeg answered, where the version triples only describe
    /// its shape.
    public static var versionInfo: String { String(cString: av_version_info()) }

    /// libavcodec's `configure` line. Long (a couple of kilobytes), so it is
    /// kept out of `summary` and left for a host to attach to a bug report —
    /// it is the only place that says whether `--enable-encoder=eac3` was
    /// passed, which is the question behind most "the audio track is missing"
    /// reports.
    public static var configuration: String { String(cString: avcodec_configuration()) }

    /// The build-dependent capabilities this engine actually branches on,
    /// resolved against the libraries that answered.
    ///
    /// Deliberately asked of FFmpeg rather than derived from the configure
    /// string: a `--enable-encoder=eac3` that failed to take is exactly the
    /// case worth catching, and `avcodec_find_encoder` is the same question
    /// the audio bridge itself asks at runtime.
    public struct Capabilities: Sendable, Equatable {
        /// Whether this build carries FFmpeg's `eac3` encoder. Stock MPVKit
        /// does not; the bridge then falls back to AAC (see `audioBridgeEncoder`),
        /// so this no longer decides whether a source can remux — only whether
        /// the bridged track can be passed through to an AVR as a bitstream.
        public let hasEAC3Encoder: Bool
        /// The encoder the audio bridge will actually use — `eac3`, `aac`, or
        /// `nil` in a build with neither, where non-copyable audio routes to
        /// the software path.
        public let audioBridgeEncoder: String?
        /// Which AV1 decoder answered (`libdav1d`, `av1`, …), or `nil` in a
        /// build without one. The software path is the only way AV1 plays on a
        /// device without hardware support, so "which decoder" and "hardware
        /// or not" are one story.
        public let av1Decoder: String?
        /// Whether this *device* decodes AV1 in hardware — the other half of
        /// that story, and the reason the same source routes differently on an
        /// M2 and an M4.
        public let isAV1HardwareSupported: Bool
        /// Whether dialogue-boost renditions can be produced: the `eac3`
        /// encoder *and* libavfilter's `pan`. A separate answer from
        /// `hasEAC3Encoder` because the filter can be missing on its own.
        public let hasDialogueBoost: Bool
        /// The GPU deinterlacer's filter name, or `nil` in a build without it
        /// — `yadif_videotoolbox` needs Metal, which is a separate Xcode
        /// component and easy to build without. Its absence is not a failure
        /// (deinterlacing falls back to the CPU route) but it is the
        /// difference between zero-copy and a full CPU decode plus filter, so
        /// a "playback is slow on interlaced broadcast content" report wants
        /// this line.
        public let gpuDeinterlacer: String?
    }

    public static var capabilities: Capabilities {
        Capabilities(
            hasEAC3Encoder: avcodec_find_encoder(AV_CODEC_ID_EAC3) != nil,
            audioBridgeEncoder: AudioBridge.isEncoderAvailable ? AudioBridge.defaultTargetCodecName : nil,
            av1Decoder: avcodec_find_decoder(AV_CODEC_ID_AV1)
                .map { String(cString: $0.pointee.name) },
            isAV1HardwareSupported: HardwareDecodeSupport.isAV1Supported,
            hasDialogueBoost: PrismCoreSession.isDialogueBoostAvailable,
            gpuDeinterlacer: SoftwareVideoDecoder.gpuDeinterlaceName
        )
    }

    /// One block of text for a log line, an About screen, or the top of a bug
    /// report. Short by design — everything in it is something we have had to
    /// ask a reporter for at least once.
    public static var summary: String {
        let capabilities = capabilities
        var lines = ["FFmpeg \(versionInfo)"]
        lines += libraries.map { "  \($0)" }
        lines.append("  eac3 encoder: \(capabilities.hasEAC3Encoder ? "yes" : "no")")
        lines.append("  audio bridge: \(capabilities.audioBridgeEncoder ?? "NONE — no encoder, non-copyable audio goes to software")")
        lines.append(
            "  av1 decoder: \(capabilities.av1Decoder ?? "none")"
                + " (hardware: \(capabilities.isAV1HardwareSupported ? "yes" : "no"))"
        )
        lines.append("  dialogue boost: \(capabilities.hasDialogueBoost ? "yes" : "no")")
        lines.append("  gpu deinterlacer: \(capabilities.gpuDeinterlacer ?? "none — CPU route")")
        if !isABIMatched {
            lines.append(
                "  ⚠︎ ABI mismatch: "
                    + mismatchedLibraries.map(\.name).joined(separator: ", ")
                    + " — struct layouts may differ from the headers this build saw"
            )
        }
        return lines.joined(separator: "\n")
    }
}
