import Testing
import Foundation
import Libavcodec
@testable import PrismCore

/// `FFmpegBuild` answers "which FFmpeg is this, and is it the one we compiled
/// against" — the question behind bug reports where the media is fine and the
/// build isn't.
///
/// The ABI assertion below is the load-bearing one. It passes trivially today
/// and is meant to: the day it fails, the package resolved to libraries a major
/// apart from our headers, and everything this engine reads out of an
/// `AVStream` or an `AVFrame` became undefined without a single error to show
/// for it.
@Suite("FFmpeg build identity")
struct FFmpegBuildTests {

    @Test("A packed libav* version unpacks to its major/minor/micro")
    func versionUnpacksFromPackedInt() {
        // AV_VERSION_INT(61, 11, 101) — major/minor/micro at 16/8/0.
        let version = FFmpegBuild.Version(packed: (61 << 16) | (11 << 8) | 101)
        #expect(version.major == 61)
        #expect(version.minor == 11)
        #expect(version.micro == 101)
        #expect(version.description == "61.11.101")
    }

    @Test("Every linked library answers, and answers a real version")
    func everyLibraryReports() {
        let names = FFmpegBuild.libraries.map(\.name)
        #expect(names == [
            "libavutil", "libavcodec", "libavformat",
            "libavfilter", "libswresample", "libswscale",
        ])
        for library in FFmpegBuild.libraries {
            #expect(library.loaded.major > 0, "\(library.name) reported no runtime version")
            #expect(library.compiled.major > 0, "\(library.name) has no header version")
        }
    }

    @Test("The libraries that answered are the ones we compiled against")
    func runtimeMatchesHeaders() {
        #expect(
            FFmpegBuild.isABIMatched,
            """
            libav* major-version drift — struct layouts may differ from the \
            headers this build saw: \
            \(FFmpegBuild.mismatchedLibraries.map(\.description).joined(separator: ", "))
            """
        )
    }

    @Test("A mismatched library says so in its description")
    func mismatchIsVisibleInDescription() {
        let matched = FFmpegBuild.Library(
            name: "libavcodec",
            compiled: FFmpegBuild.Version(major: 61, minor: 11, micro: 100),
            loaded: FFmpegBuild.Version(major: 61, minor: 19, micro: 101)
        )
        // Minor drift is normal: libav* adds fields within a major.
        #expect(matched.isABIMatched)
        #expect(matched.description == "libavcodec 61.19.101")

        let drifted = FFmpegBuild.Library(
            name: "libavcodec",
            compiled: FFmpegBuild.Version(major: 61, minor: 11, micro: 100),
            loaded: FFmpegBuild.Version(major: 62, minor: 0, micro: 100)
        )
        #expect(!drifted.isABIMatched)
        #expect(drifted.description.contains("compiled against 61.11.100"))
    }

    @Test("Capabilities are asked of FFmpeg, not inferred from the configure line")
    func capabilitiesMatchWhatFFmpegAnswers() {
        let capabilities = FFmpegBuild.capabilities
        #expect(capabilities.hasEAC3Encoder == (avcodec_find_encoder(AV_CODEC_ID_EAC3) != nil))
        #expect((capabilities.av1Decoder != nil) == (avcodec_find_decoder(AV_CODEC_ID_AV1) != nil))
        #expect(capabilities.isAV1HardwareSupported == HardwareDecodeSupport.isAV1Supported)
        #expect(capabilities.hasDialogueBoost == PrismCoreSession.isDialogueBoostAvailable)
        #expect(capabilities.gpuDeinterlacer == SoftwareVideoDecoder.gpuDeinterlaceName)
        // The bridge takes eac3 when the build has it and aac otherwise — the
        // answer is FFmpeg's, not the configure line's.
        let expectedBridge = avcodec_find_encoder(AV_CODEC_ID_EAC3) != nil ? "eac3"
            : avcodec_find_encoder(AV_CODEC_ID_AAC) != nil ? "aac" : nil
        #expect(capabilities.audioBridgeEncoder == expectedBridge)
        // Dialogue boost needs the encoder the bridge needs, and one filter
        // more — it can never be the wider answer of the two.
        #expect(!(capabilities.hasDialogueBoost && capabilities.audioBridgeEncoder == nil))
    }

    /// The summary is what a host pastes into a bug report, so its content is
    /// part of the contract: the build identity, every library, and the two
    /// capability answers that change routing.
    @Test("The summary names the build, every library, and the routing capabilities")
    func summaryCarriesWhatABugReportNeeds() {
        let summary = FFmpegBuild.summary
        #expect(summary.contains(FFmpegBuild.versionInfo))
        for library in FFmpegBuild.libraries {
            #expect(summary.contains(library.name), "summary omits \(library.name)")
            #expect(summary.contains(library.loaded.description))
        }
        #expect(summary.contains("eac3 encoder:"))
        #expect(summary.contains("av1 decoder:"))
        #expect(summary.contains("dialogue boost:"))
        #expect(summary.contains("gpu deinterlacer:"))
        // No warning when nothing drifted — the line has to mean something.
        #expect(summary.contains("ABI mismatch") == !FFmpegBuild.isABIMatched)
    }

    @Test("The configure line is available and is libavcodec's own")
    func configurationIsReadable() {
        #expect(FFmpegBuild.configuration.contains("--"))
    }
}
