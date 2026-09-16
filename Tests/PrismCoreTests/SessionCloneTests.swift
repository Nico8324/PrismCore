import Testing
import Foundation
@testable import PrismCore

/// `makeSession(changing:)` — the one door for "same title, one option moved".
///
/// The three things a clone has to get right are covered here: the changed
/// option really reaches the remux (observable in the served shape), everything
/// the host registered on the predecessor is replayed rather than silently
/// dropped, and the lifecycle rules that keep two live sessions from fighting
/// over one work directory are enforced, not merely documented.
@Suite("Session clone", .serialized)
struct SessionCloneTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    /// A master never gains `EXT-X-ENDLIST`; follow it to its variant and poll
    /// that, exactly as the remux and subtitle suites do.
    private func waitForFinishedPlaylist(_ playlistURL: URL, timeout: Duration = .seconds(30)) async throws {
        var mediaURL = playlistURL
        let (firstData, _) = try await URLSession.shared.data(from: playlistURL)
        let first = String(decoding: firstData, as: UTF8.self)
        if first.contains("#EXT-X-STREAM-INF") {
            let variant = try #require(
                PrismCoreSession.playlistURIs(inMaster: first).last,
                "a master must reference a variant playlist"
            )
            mediaURL = playlistURL.deletingLastPathComponent().appendingPathComponent(variant)
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let (data, _) = try await URLSession.shared.data(from: mediaURL)
            if String(decoding: data, as: UTF8.self).contains("#EXT-X-ENDLIST") { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw PrismCoreSession.SessionError.startupTimedOut(underlying: nil)
    }

    /// Collects `TimedTextCue`s across the remux thread and the test task.
    private final class CueCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [TimedTextCue] = []
        func append(_ cue: TimedTextCue) { lock.withLock { stored.append(cue) } }
        var cues: [TimedTextCue] { lock.withLock { stored } }
    }

    // MARK: - The changed option reaches the remux

    @Test("A clone that flips forceMuxedShape serves the muxed shape")
    func changedOptionChangesTheServedShape() async throws {
        // An SDR source with a stream-copyable audio track serves a master.
        let session = try PrismCoreSession(url: try fixture("hevc_eac3.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }
        #expect(playlist.lastPathComponent == HLSRemuxer.masterPlaylistFileName)

        let clone = try await session.makeSession { $0.forceMuxedShape = true }
        #expect(await clone.options.forceMuxedShape)
        let clonePlaylist = try await clone.start()
        defer { Task { await clone.stop() } }
        // The one moved option, visible where it has to be: no master on disk,
        // the media playlist served directly.
        #expect(clonePlaylist.lastPathComponent == HLSRemuxer.mediaPlaylistFileName)
    }

    @Test("Untouched options — the audio delay included — are carried verbatim")
    func untouchedOptionsAreCarried() async throws {
        let source = try fixture("h264_aac.mkv")
        let cache = URL(fileURLWithPath: "/tmp/prismcore-clone-test-index", isDirectory: true)
        let session = try PrismCoreSession(
            url: source,
            httpHeaders: ["Authorization": "Bearer t"],
            display: DisplayCapabilities(isHDRReady: true, isDolbyVisionCapable: true),
            segmentCacheBytes: 64 << 20,
            keyframeIndexCacheDirectory: cache,
            dialogueBoost: [.medium],
            audioDelaySeconds: 0.25
        )
        let clone = try await session.makeSession { $0.segmentCacheBytes = 8 << 20 }

        let before = await session.options
        let after = await clone.options
        #expect(after.segmentCacheBytes == 8 << 20)
        #expect(before.segmentCacheBytes == 64 << 20)  // the predecessor is untouched
        // Everything else identical — the whole point of cloning rather than
        // asking the host to restate what it already said once.
        var expected = before
        expected.segmentCacheBytes = 8 << 20
        #expect(after == expected)
        // The audio delay is called out separately because it is the value a
        // runtime setter will ride on: it must survive as the live value, not
        // just as a field of a struct nobody consults.
        #expect(await clone.audioDelaySeconds == 0.25)
        #expect(after.sourceURL == source)
        #expect(after.httpHeaders == ["Authorization": "Bearer t"])
    }

    @Test("A clamped audio delay clones as the value in force, not the value asked for")
    func audioDelayIsClampedOnTheClone() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac.mkv"))
        let clone = try await session.makeSession { $0.audioDelaySeconds = 99 }
        #expect(await clone.audioDelaySeconds == 2)
        #expect(await clone.options.audioDelaySeconds == 2)
    }

    // MARK: - What the host registered survives

    @Test("External subtitle registrations are replayed onto the clone")
    func externalSubtitlesSurviveTheClone() async throws {
        let sidecar = FileManager.default.temporaryDirectory
            .appendingPathComponent("prismcore-clone-\(UUID().uuidString).srt")
        try Data("""
        1
        00:00:00,500 --> 00:00:02,000
        Guten Tag

        """.utf8).write(to: sidecar)
        defer { try? FileManager.default.removeItem(at: sidecar) }

        // A source with no embedded subtitle stream, so the only rendition the
        // clone can serve is the replayed one.
        let session = try PrismCoreSession(url: try fixture("h264_aac.mkv"))
        try await session.addExternalSubtitle(url: sidecar, language: "de", name: "Deutsch")

        // Registered but never started: a host may change a setting before it
        // ever plays, and the registration has to survive that too.
        let clone = try await session.makeSession { $0.audioDelaySeconds = 0.1 }
        let playlist = try await clone.start()
        defer { Task { await clone.stop() } }
        try await waitForFinishedPlaylist(playlist)

        let renditions = await clone.subtitleRenditions
        #expect(renditions.count == 1)
        #expect(renditions.first?.language == "de")
        #expect(renditions.first?.name == "Deutsch")
    }

    @Test("The timed-text cue handler is replayed onto the clone")
    func cueHandlerSurvivesTheClone() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac_srt.mkv"))
        let collector = CueCollector()
        await session.setTimedTextCueHandler { collector.append($0) }

        // The clone is the only session started here: every cue collected can
        // only have come through the replayed handler.
        let clone = try await session.makeSession { $0.segmentCacheBytes = nil }
        let playlist = try await clone.start()
        defer { Task { await clone.stop() } }
        try await waitForFinishedPlaylist(playlist)

        let cues = collector.cues
        #expect(cues.count == 3)
        #expect(cues.first?.text.contains("Ahoj") == true)
    }

    // MARK: - Lifecycle

    @Test("A clone never inherits its predecessor's work directory")
    func cloneGetsItsOwnWorkDirectory() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac.mkv"))
        let clone = try await session.makeSession { $0.forceMuxedShape = true }
        let sessionDirectory = await session.workDirectory
        let cloneDirectory = await clone.workDirectory
        #expect(cloneDirectory != sessionDirectory)
        // Both exist and are independent: stopping the predecessor removes its
        // directory, and the successor's has to still be there afterwards —
        // that shared-directory version of this is a mid-title stall.
        await session.stop()
        #expect(!FileManager.default.fileExists(atPath: sessionDirectory.path))
        #expect(FileManager.default.fileExists(atPath: cloneDirectory.path))
        await clone.stop()
    }

    @Test("A session mints one successor; the second is refused")
    func secondSuccessorIsRefused() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac.mkv"))
        let first = try await session.makeSession { $0.audioDelaySeconds = 0.1 }
        await #expect(throws: PrismCoreSession.SessionError.self) {
            _ = try await session.makeSession { $0.audioDelaySeconds = 0.2 }
        }
        // The chain is the supported shape: clone the session you are playing.
        let second = try await first.makeSession { $0.audioDelaySeconds = 0.2 }
        #expect(await second.audioDelaySeconds == 0.2)
        await session.stop()
        await first.stop()
        await second.stop()
    }

    @Test("The rejection fallbacks count as that session's one successor")
    func fallbacksGoThroughTheSameDoor() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac.mkv"))
        let fallback = try await session.makeMuxedFallbackSession()
        #expect(await fallback.options.forceMuxedShape)
        await #expect(throws: PrismCoreSession.SessionError.self) {
            _ = try await session.makeSession { $0.forceMuxedShape = false }
        }
        await session.stop()
        await fallback.stop()
    }
}
