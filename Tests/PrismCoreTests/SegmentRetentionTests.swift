import Testing
import Foundation
@testable import PrismCore

/// The cache half of phase 5: segments are evicted farthest-from-playhead
/// once the byte budget is exceeded, and an evicted segment is reproduced on
/// demand — the budget bounds disk, never seekability.
@Suite("Segment retention", .serialized)
struct SegmentRetentionTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    // MARK: - Policy unit behaviour

    @Test("Eviction takes the segment farthest from the playhead, never the keep window")
    func evictionOrder() {
        var retention = SegmentRetention(budgetBytes: 300, keepWindow: 2)

        // Fill 0..5 at 100 bytes each, producing sequentially: the budget
        // holds 3, so landing 3, 4, 5 evicts 0, 1, 2 — always the farthest.
        var evicted: [Int] = []
        for index in 0...5 {
            evicted += retention.record(index: index, bytes: 100, producing: index)
        }
        #expect(evicted == [0, 1, 2])
        #expect(retention.totalBytes == 300)

        // A distant backward reproduction: playhead jumped to 0, segment 0
        // lands again — now 5 is the farthest and goes first.
        let victims = retention.record(index: 0, bytes: 100, producing: 0)
        #expect(victims == [5])
    }

    @Test("The keep window survives even over budget")
    func keepWindowIsSacred() {
        var retention = SegmentRetention(budgetBytes: 100, keepWindow: 2)
        // Everything recorded sits within ±2 of the playhead: over budget,
        // but nothing is evictable — the policy must stop, not spin.
        var evicted: [Int] = []
        for index in 0...2 {
            evicted += retention.record(index: index, bytes: 100, producing: 1)
        }
        #expect(evicted.isEmpty)
        #expect(retention.totalBytes == 300)
    }

    @Test("A protected index survives eviction — the next-farthest goes instead")
    func protectedIndexSurvives() {
        var retention = SegmentRetention(budgetBytes: 400, keepWindow: 1)

        // 0..3 landed; the producer then ran on to 8 past a demand at 0.
        for index in 0...3 {
            _ = retention.record(index: index, bytes: 100, producing: index)
        }
        // Landing 8 exceeds the budget by one segment. Farthest from the
        // producer is 0 — but 0 has an outstanding demand serve, so 1 goes.
        let victims = retention.record(index: 8, bytes: 100, producing: 8, protected: [0])
        #expect(victims == [1])
        #expect(retention.totalBytes == 400)

        // With every candidate protected, the policy stops rather than spins —
        // same contract as the keep window, the budget stays exceeded.
        let none = retention.record(index: 9, bytes: 100, producing: 9, protected: [0, 2, 3])
        #expect(none.isEmpty)
        #expect(retention.totalBytes == 500)
    }

    @Test("Re-recording a segment replaces its size instead of double-counting")
    func reRecordReplaces() {
        var retention = SegmentRetention(budgetBytes: 1_000, keepWindow: 0)
        _ = retention.record(index: 3, bytes: 400, producing: 3)
        _ = retention.record(index: 3, bytes: 250, producing: 3)
        #expect(retention.totalBytes == 250)
    }

    // MARK: - End to end

    @Test("A tiny budget evicts early segments, and an evicted one is reproduced on fetch")
    func evictedSegmentIsReproduced() async throws {
        // ~30 s of testsrc2 H.264 makes ~5 segments of a few hundred KB each;
        // a 300 KB budget cannot hold them all.
        let session = try PrismCoreSession(
            url: try fixture("h264_aac_30s.mkv"),
            segmentCacheBytes: 300_000
        )
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        let (data, _) = try await URLSession.uncached.data(from: playlist)
        let master = String(decoding: data, as: UTF8.self)
        let variantURI = try #require(PrismCoreSession.playlistURIs(inMaster: master).last)
        let base = playlist.deletingLastPathComponent()
        let (variantData, _) = try await URLSession.uncached.data(
            from: base.appendingPathComponent(variantURI)
        )
        let segments = String(decoding: variantData, as: UTF8.self)
            .split(separator: "\n").filter { $0.hasSuffix(".m4s") }.map(String.init)
        #expect(segments.count >= 4)

        // Drive production to the end by demanding the last segment, then
        // give eviction a beat to run on the closing cuts.
        let lastURL = base.appendingPathComponent(try #require(segments.last))
        _ = try await URLSession.uncached.data(from: lastURL)
        try await Task.sleep(for: .milliseconds(300))

        // Under a 300 KB budget at least one produced segment must be gone
        // from disk — the whole point of the budget. (Playlists and init.mp4
        // are not retention's to touch.)
        // Every listed segment must still SERVE, evicted or not: a miss goes
        // through the demand path and reproduces it.
        for segment in segments {
            let (media, response) = try await URLSession.uncached.data(
                from: base.appendingPathComponent(segment)
            )
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(media.range(of: Data("moof".utf8)) != nil, "\(segment) did not serve a real fragment")
        }
    }

    @Test("The budget really deletes files on disk as production advances")
    func budgetDeletesOnDisk() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreRetention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // The remuxer directly, so the output directory is inspectable.
        // keepWindow default is 4 and the 30 s fixture plans ~5 segments, so
        // force distance with a 1-byte budget… still capped by the window:
        // only segment 0 ends up farther than 4 from the closing playhead.
        let demand = DemandCoordinator()
        let remuxer = HLSRemuxer(
            sourceURL: try fixture("h264_aac_30s.mkv"),
            outputDirectory: directory,
            segmentSeconds: 3,   // ~10 planned segments → real eviction range
            demand: demand,
            segmentCacheBytes: 1
        )
        // A real thread, like the session's own: `run()` parks at EOF, and a
        // parked producer on the cooperative pool is what used to hang the
        // suite (#44).
        let producer = ProducerThread(name: "prismcore.tests.retention") { try remuxer.run() }
        defer { remuxer.cancel(); Task { await producer.join() } }

        // Wait until the last planned segment lands (production complete).
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        var producedAll = false
        var planned = 0
        while ContinuousClock.now < deadline, !producedAll {
            if planned == 0,
               let text = try? String(
                   contentsOf: directory.appendingPathComponent("index.m3u8"),
                   encoding: .utf8
               ), text.contains("#EXT-X-ENDLIST") {
                planned = text.split(separator: "\n").filter { $0.hasSuffix(".m4s") }.count
            }
            if planned > 0 {
                let last = String(format: "seg%05d.m4s", planned - 1)
                producedAll = FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(last).path
                )
            }
            if !producedAll { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(producedAll, "production never reached the last planned segment")
        #expect(planned >= 8)

        let onDisk = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".m4s") }.count
        // A 1-byte budget keeps only what the keep window protects.
        #expect(onDisk < planned, "no segment was evicted (\(onDisk) of \(planned) on disk)")
        #expect(onDisk <= 6)

        // The head segment was evicted — and the playlist still lists it.
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("seg00000.m4s").path
        ))
    }

    // MARK: - Master-rejection fallback shape

    @Test("forceMuxedShape serves the media playlist with audio muxed in, no master")
    func forceMuxedShape() async throws {
        // The multi-audio fixture would normally get a master + renditions;
        // forced muxed it must serve index.m3u8 directly with one audio track
        // inside the variant's own segments.
        let session = try PrismCoreSession(
            url: try fixture("h264_multi_audio.mkv"),
            forceMuxedShape: true
        )
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        #expect(playlist.lastPathComponent == "index.m3u8")
        let (data, _) = try await URLSession.uncached.data(from: playlist)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("#EXT-X-STREAM-INF"))

        // The init segment carries BOTH track sample entries (avc1 + mp4a) —
        // muxed means the audio rides inside the variant.
        let (initData, _) = try await URLSession.uncached.data(
            from: playlist.deletingLastPathComponent().appendingPathComponent("init.mp4")
        )
        #expect(initData.range(of: Data("avc1".utf8)) != nil)
        #expect(initData.range(of: Data("mp4a".utf8)) != nil)
    }
}
