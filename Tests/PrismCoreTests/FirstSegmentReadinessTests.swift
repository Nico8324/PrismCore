import Testing
import Foundation
@testable import PrismCore

/// Package A of the 2026-08 performance audit (#65): the first segment is
/// short, readiness waits for the video variant only, and the waits are
/// wakes rather than polls.
@Suite("First segment & readiness", .serialized)
struct FirstSegmentReadinessTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    private func makeDirectory(_ tag: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCore\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Readiness gate

    private let master = """
    #EXTM3U
    #EXT-X-VERSION:7
    #EXT-X-INDEPENDENT-SEGMENTS
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="eng",DEFAULT=YES,URI="audio0/index.m3u8"
    #EXT-X-STREAM-INF:BANDWIDTH=1,CODECS="avc1.64001f,mp4a.40.2",AUDIO="aud"
    index.m3u8

    """

    private func plannedVOD(segments: Int) -> String {
        var text = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:6\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        text += "#EXT-X-MAP:URI=\"init.mp4\"\n"
        for index in 0..<segments {
            text += String(format: "#EXTINF:6.00000,\nseg%05d.m4s\n", index)
        }
        return text + "#EXT-X-ENDLIST\n"
    }

    @Test("The gate opens on the video variant's EXTINF while the audio rendition has only an init")
    func gateWaitsForVideoOnly() throws {
        let root = try makeDirectory("Gate")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(master.utf8).write(to: root.appendingPathComponent("master.m3u8"))
        try Data(plannedVOD(segments: 5).utf8).write(to: root.appendingPathComponent("index.m3u8"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("audio0"), withIntermediateDirectories: true
        )

        // Master + variant playlist, no init anywhere: not ready — the
        // variant's EXT-X-MAP points at a file that does not exist.
        #expect(PrismCoreSession.readyPlaylistName(in: root) == nil)

        // Variant playable, rendition playlist absent: still not ready — a
        // playlist AVPlayer would 404 on is the one thing the gate must hold
        // for (it fails an item over a 404 rather than retrying).
        try Data("moov".utf8).write(to: root.appendingPathComponent("init.mp4"))
        #expect(PrismCoreSession.readyPlaylistName(in: root) == nil)

        // Rendition playlist on disk with NO segment listed and no init: not
        // ready — a declared track that never delivers a packet never mints
        // an init, and that failure belongs in start(), not in AVPlayer.
        let headerOnly = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:6\n#EXT-X-MAP:URI=\"init.mp4\"\n"
        try Data(headerOnly.utf8).write(to: root.appendingPathComponent("audio0/index.m3u8"))
        #expect(PrismCoreSession.readyPlaylistName(in: root) == nil)

        // Init present, still no EXTINF: ready. The rendition's segments are
        // served through the demand seam (`.pending` until the producer
        // lands them), so waiting for a listed segment here would only delay
        // the URL.
        try Data("moov".utf8).write(to: root.appendingPathComponent("audio0/init.mp4"))
        #expect(PrismCoreSession.readyPlaylistName(in: root) == "master.m3u8")
    }

    @Test("A planned rendition slot production declared empty is a fast 404, not a pending wait")
    func unproducibleSlotIsNotFound() async throws {
        let root = try makeDirectory("Unproducible")
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DemandCoordinator()
        coordinator.publish(plan: SegmentPlan(
            entries: (0..<5).map { .init(startPTS: Int64($0) * 6000, duration: 6.0) },
            basis: .keyframeIndex, timeBaseNum: 1, timeBaseDen: 1000
        ))
        coordinator.setProducing(index: 3)
        let provider = PlanSegmentProvider(root: root, coordinator: coordinator)
        // The head boundary carried no audio for this rendition: the writer
        // kept the slot (index alignment with the video) and declared it.
        coordinator.markUnproducible(path: "audio0/seg00000.m4s")
        guard case .notFound = await provider.data(forPath: "audio0/seg00000.m4s") else {
            Issue.record("an unproducible slot must 404 immediately"); return
        }
        // And it did not re-anchor the producer back to the head for it.
        #expect(coordinator.takeAnchorRequest() == nil)
        // The video's own slot 0 is untouched: still a real demand.
        guard case .pending = await provider.data(forPath: "seg00000.m4s") else {
            Issue.record("the variant's head must still be demandable"); return
        }
    }

    @Test("An unproduced rendition init or segment is served as pending, resolved by the producer's broadcast")
    func pendingRenditionServeResolvesOnBroadcast() async throws {
        let root = try makeDirectory("PendingRendition")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("audio0"), withIntermediateDirectories: true
        )
        let coordinator = DemandCoordinator()
        coordinator.publish(plan: SegmentPlan(
            entries: (0..<5).map { .init(startPTS: Int64($0) * 6000, duration: 6.0) },
            basis: .keyframeIndex, timeBaseNum: 1, timeBaseDen: 1000
        ))
        coordinator.setProducing(index: 0)
        let landed = ProductionSignal()
        let provider = PlanSegmentProvider(root: root, coordinator: coordinator, landed: landed)

        // Both shapes of the rendition's first fetch miss → pending, not 404.
        guard case .pending(let initPending) = await provider.data(forPath: "audio0/init.mp4") else {
            Issue.record("rendition init miss must be pending"); return
        }
        guard case .pending(let segPending) = await provider.data(forPath: "audio0/seg00000.m4s") else {
            Issue.record("rendition segment miss must be pending"); return
        }
        // Index 0 is inside the forward-wait window of a producer at 0: no
        // re-anchor was requested, the producer is about to cut it anyway.
        #expect(coordinator.takeAnchorRequest() == nil)

        // The producer lands both files ~300 ms later and broadcasts; the
        // serves must resolve on the WAKE, well inside the 200 ms backstop
        // they would otherwise sleep out.
        let landing = Task {
            try await Task.sleep(for: .milliseconds(300))
            try Data("moov".utf8).write(to: root.appendingPathComponent("audio0/init.mp4"))
            try Data("moof".utf8).write(to: root.appendingPathComponent("audio0/seg00000.m4s"))
            landed.broadcast()
            return ContinuousClock.now
        }
        let initResult = await initPending.resolve()
        let segResult = await segPending.resolve()
        let servedAt = ContinuousClock.now
        let landedAt = try await landing.value
        guard case .data(let initBytes, _) = initResult, case .data(let segBytes, _) = segResult else {
            Issue.record("pending serves did not resolve to data"); return
        }
        #expect(initBytes == Data("moov".utf8))
        #expect(segBytes == Data("moof".utf8))
        // Generous bound (the backstop is 200 ms); a woken serve answers in
        // single-digit milliseconds.
        #expect(servedAt - landedAt < .milliseconds(150), "serve trailed the landing by \(servedAt - landedAt)")
    }

    // MARK: - Signal semantics

    @Test("A broadcast between the disk check and the wait is not lost")
    func broadcastBeforeWaitReturnsImmediately() async {
        let signal = ProductionSignal()
        let generation = signal.currentGeneration
        signal.broadcast()
        let start = ContinuousClock.now
        // Would sleep out the whole backstop if the generation check were
        // missing — the exact hazard the wake-before-wait rule names.
        await signal.wait(after: generation, backstop: .seconds(5))
        #expect(ContinuousClock.now - start < .milliseconds(500))
    }

    @Test("A waiter with no broadcast returns on the backstop")
    func backstopReturnsWithoutBroadcast() async {
        let signal = ProductionSignal()
        let start = ContinuousClock.now
        await signal.wait(after: signal.currentGeneration, backstop: .milliseconds(50))
        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= .milliseconds(40) && elapsed < .seconds(2))
    }

    // MARK: - End to end

    @Test("A session's first segment is the short head, then full-length segments")
    func sessionFirstSegmentIsShort() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac_30s.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        let (data, _) = try await URLSession.uncached.data(from: playlist)
        let masterText = String(decoding: data, as: UTF8.self)
        let variant = try #require(PrismCoreSession.playlistURIs(inMaster: masterText).last)
        let (variantData, _) = try await URLSession.uncached.data(
            from: playlist.deletingLastPathComponent().appendingPathComponent(variant)
        )
        let durations = String(decoding: variantData, as: UTF8.self).split(separator: "\n")
            .filter { $0.hasPrefix("#EXTINF:") }
            .compactMap { Double($0.dropFirst(8).dropLast()) }
        // 2 s keyframe grid: [2, 6, 6, 6, 6, 4].
        #expect(durations.count == 6, "\(durations)")
        #expect(abs((durations.first ?? 0) - 2) < 0.5, "\(durations)")
        #expect(durations.dropFirst().dropLast().allSatisfy { abs($0 - 6) < 0.5 }, "\(durations)")
        #expect(abs(durations.reduce(0, +) - 30) < 1)

        // The URL came back with the head segment playable — and the audio
        // rendition's head fetch succeeds too, produced or pending.
        let base = playlist.deletingLastPathComponent()
        let (audioSeg, response) = try await URLSession.uncached.data(
            from: base.appendingPathComponent("audio0/seg00000.m4s")
        )
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(audioSeg.range(of: Data("moof".utf8)) != nil)
    }
}
