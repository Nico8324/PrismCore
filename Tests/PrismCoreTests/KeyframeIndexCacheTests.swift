import Testing
import Foundation
@testable import PrismCore

/// The cross-session keyframe map (issue #34): a source whose container
/// carries no usable seek index plays sequentially on its first run while the
/// producer harvests every keyframe it reads anyway, and the next play plans
/// on that map — demand mode as if the file had an index.
///
/// The fixture is MPEG-TS on purpose: a TS has no index to load (its few
/// probed entries fail the plan's coverage witness), so it is the natural
/// always-uniform source, with a real container duration — unlike a Matroska
/// piped without Cues, which loses its duration too and can't plan at all.
@Suite("Keyframe index cache", .serialized)
struct KeyframeIndexCacheTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreKeyframeCache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Cache unit behaviour

    @Test("Store and look up round-trips; a different identity misses")
    func roundTrip() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = KeyframeIndexCache(directory: directory)

        let entry = KeyframeIndexCache.Entry(
            identity: "http://nas/movie.mkv|5400000000|7200000000",
            timeBaseNum: 1, timeBaseDen: 1000,
            keyframePTS: [0, 2000, 4000, 6000]
        )
        cache.store(entry)
        #expect(cache.lookup(identity: entry.identity) == entry)
        #expect(cache.lookup(identity: "http://nas/other.mkv|1|2") == nil)
    }

    @Test("The identity drops the URL query — a rotated token is the same media")
    func identityStripsQuery() {
        let tokenA = KeyframeIndexCache.identity(
            sourceURL: URL(string: "http://nas:32400/library/parts/9?X-Plex-Token=aaa")!,
            sizeBytes: 100, durationMicroseconds: 200
        )
        let tokenB = KeyframeIndexCache.identity(
            sourceURL: URL(string: "http://nas:32400/library/parts/9?X-Plex-Token=bbb")!,
            sizeBytes: 100, durationMicroseconds: 200
        )
        let otherPath = KeyframeIndexCache.identity(
            sourceURL: URL(string: "http://nas:32400/library/parts/10?X-Plex-Token=aaa")!,
            sizeBytes: 100, durationMicroseconds: 200
        )
        let otherSize = KeyframeIndexCache.identity(
            sourceURL: URL(string: "http://nas:32400/library/parts/9?X-Plex-Token=aaa")!,
            sizeBytes: 101, durationMicroseconds: 200
        )
        #expect(tokenA == tokenB)
        #expect(tokenA != otherPath)
        #expect(tokenA != otherSize)
    }

    @Test("The bound prunes least-recently-used entries, and a lookup refreshes")
    func lruPrune() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var cache = KeyframeIndexCache(directory: directory)
        cache.maxEntries = 2

        func entry(_ n: Int) -> KeyframeIndexCache.Entry {
            .init(identity: "source-\(n)", timeBaseNum: 1, timeBaseDen: 1000,
                  keyframePTS: [0, 2000])
        }
        cache.store(entry(0))
        // The prune orders by mtime; give the filesystem a distinct tick.
        Thread.sleep(forTimeInterval: 0.02)
        cache.store(entry(1))
        Thread.sleep(forTimeInterval: 0.02)
        // Touch 0 — it becomes the recent one, so storing 2 must evict 1.
        #expect(cache.lookup(identity: "source-0") != nil)
        Thread.sleep(forTimeInterval: 0.02)
        cache.store(entry(2))

        #expect(cache.lookup(identity: "source-0") != nil)
        #expect(cache.lookup(identity: "source-1") == nil)
        #expect(cache.lookup(identity: "source-2") != nil)
    }

    // MARK: - End to end over the no-index fixture

    @Test("First play harvests the keyframe map; the second plans on it")
    func harvestThenPlan() async throws {
        let cacheDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory)  }
        let output = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: output) }
        let source = try fixture("h264_ac3_30s.ts")

        // Play 1, the field shape: the index-load scan bounded out before it
        // could index anything. A zero budget forces that deterministically —
        // on a local file the linear scan the nudge seek degenerates to is
        // otherwise instant, and the demuxer would hand the planner a
        // self-built index (which is exactly what does NOT happen on the SMB
        // webrips this cache exists for). The plan degrades to uniform, the
        // producer runs sequentially, and the harvest sees every keyframe.
        let first = HLSRemuxer(
            sourceURL: source,
            outputDirectory: output,
            demand: DemandCoordinator(),
            keyframeCacheDirectory: cacheDirectory,
            indexLoadBudget: .zero
        )
        try first.run()
        let firstText = try String(
            contentsOf: output.appendingPathComponent("index.m3u8"), encoding: .utf8
        )
        #expect(firstText.contains("#EXT-X-PLAYLIST-TYPE:EVENT"),
                "the bounded-out first play unexpectedly planned — no harvest would follow")
        #expect(firstText.contains("#EXT-X-ENDLIST"))

        // The sidecar exists and carries the fixture's 2 s cadence.
        let sidecars = try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path)
            .filter { $0.hasSuffix(".json") }
        #expect(sidecars.count == 1)
        let entry = try JSONDecoder().decode(
            KeyframeIndexCache.Entry.self,
            from: Data(contentsOf: cacheDirectory.appendingPathComponent(try #require(sidecars.first)))
        )
        // 30 s at a 2 s keyframe interval → 15 keyframes.
        #expect(entry.keyframePTS.count >= 13 && entry.keyframePTS.count <= 17)

        // Play 2: the map is the index — planned VOD from the first second.
        let second = try PrismCoreSession(
            url: source, keyframeIndexCacheDirectory: cacheDirectory
        )
        let secondPlaylist = try await second.start()
        defer { Task { await second.stop() } }
        let (secondData, _) = try await URLSession.uncached.data(from: secondPlaylist)
        let secondText = String(decoding: secondData, as: UTF8.self)
        #expect(secondText.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        #expect(secondText.contains("#EXT-X-ENDLIST"))

        // And the promise holds on the source with no index: a fetch deep in
        // the file re-anchors the producer there (a TS timestamp seek) and
        // serves a real fragment.
        let segments = secondText.split(separator: "\n")
            .filter { $0.hasSuffix(".m4s") }.map(String.init)
        #expect(segments.count >= 4)
        let base = secondPlaylist.deletingLastPathComponent()
        let (media, response) = try await URLSession.uncached.data(
            from: base.appendingPathComponent(try #require(segments.last))
        )
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(media.range(of: Data("moof".utf8)) != nil, "the demanded tail segment did not serve a real fragment")
    }

    @Test("A plan built from the container's own index is kept, so the next play skips the index-load seek")
    func containerIndexIsKeptForTheNextPlay() async throws {
        let cacheDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        // A Matroska WITH Cues: the plan comes from the container's index, so
        // nothing is harvested — this is the case that used to store nothing
        // and pay the index-load seek again on every play. Over a network
        // that seek is two Range requests at the tail plus a third to get
        // back to the head, which is what the sidecar now removes.
        let source = try fixture("h264_aac_30s.mkv")

        let first = try PrismCoreSession(
            url: source, keyframeIndexCacheDirectory: cacheDirectory
        )
        let firstCheckpoints = try await first.startupCheckpoints()
        async let firstOrigin = Self.planOrigin(of: firstCheckpoints)
        _ = try await first.start()
        await first.stop()
        #expect(await firstOrigin == .builtFromSource)

        let sidecars = try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path)
            .filter { $0.hasSuffix(".json") }
        #expect(sidecars.count == 1, "a plan built from the container index stored nothing")
        let entry = try JSONDecoder().decode(
            KeyframeIndexCache.Entry.self,
            from: Data(contentsOf: cacheDirectory.appendingPathComponent(try #require(sidecars.first)))
        )
        // The file's own index, not a harvest: complete, and nothing past it.
        #expect(entry.complete)
        #expect(entry.coveredThroughPTS == nil)
        #expect(entry.keyframePTS.count >= 2)

        let second = try PrismCoreSession(
            url: source, keyframeIndexCacheDirectory: cacheDirectory
        )
        let secondCheckpoints = try await second.startupCheckpoints()
        async let secondOrigin = Self.planOrigin(of: secondCheckpoints)
        let playlist = try await second.start()
        #expect(await secondOrigin == .keyframeIndexCache)
        // Same shape as the first play, by the same keyframes: a real VOD
        // media playlist behind the master.
        let (variant, _) = try await URLSession.uncached.data(
            from: playlist.deletingLastPathComponent().appendingPathComponent("index.m3u8")
        )
        #expect(String(decoding: variant, as: UTF8.self).contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        await second.stop()
    }

    private static func planOrigin(
        of checkpoints: AsyncStream<StartupCheckpoint>
    ) async -> SegmentPlanOrigin? {
        for await mark in checkpoints {
            if case .segmentPlanReady(let origin, _) = mark.phase { return origin }
        }
        return nil
    }

    @Test("A run cancelled before any keyframe persists nothing; a cancelled prefix persists a PARTIAL map the next play plans on")
    func cancelledRunPersistsPartialMap() async throws {
        let cacheDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let output = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: output) }
        let source = try fixture("h264_ac3_30s.ts")

        // Cancelled before the first packet: fewer than two keyframes seen,
        // nothing worth storing.
        let empty = HLSRemuxer(
            sourceURL: source, outputDirectory: output,
            demand: DemandCoordinator(), keyframeCacheDirectory: cacheDirectory
        )
        empty.cancel()
        try empty.run()
        var sidecars = (try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path))?
            .filter { $0.hasSuffix(".json") } ?? []
        #expect(sidecars.isEmpty)

        // A run that saw a prefix and was cancelled: the cut of segment 1
        // (~8 s in) is where the cancel lands, so the harvest holds the
        // keyframes up to there and is stored as partial.
        let partial = HLSRemuxer(
            sourceURL: source, outputDirectory: output,
            demand: DemandCoordinator(), keyframeCacheDirectory: cacheDirectory,
            indexLoadBudget: .zero
        )
        // Deterministic: the fixture produces in milliseconds, so the cancel
        // comes from the cut path itself, right after segment 1 lands.
        partial.onSegmentLanded = { index in if index == 1 { partial.cancel() } }
        try partial.run()
        sidecars = (try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path))?
            .filter { $0.hasSuffix(".json") } ?? []
        #expect(sidecars.count == 1)
        let entry = try JSONDecoder().decode(
            KeyframeIndexCache.Entry.self,
            from: Data(contentsOf: cacheDirectory.appendingPathComponent(try #require(sidecars.first)))
        )
        #expect(!entry.complete)
        #expect(entry.coveredThroughPTS == entry.keyframePTS.max())
        #expect(entry.keyframePTS.count >= 2 && entry.keyframePTS.count < 15, "\(entry.keyframePTS.count)")

        // The next play plans on it: a VOD playlist whose entries cover the
        // whole 30 s — the prefix on keyframes, the tail on the stride.
        let second = try PrismCoreSession(url: source, keyframeIndexCacheDirectory: cacheDirectory)
        let playlist = try await second.start()
        defer { Task { await second.stop() } }
        // The TS fixture has Annex-B extradata → no CODECS → the muxed shape,
        // whose media playlist is served directly.
        let (data, _) = try await URLSession.uncached.data(from: playlist)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("#EXT-X-PLAYLIST-TYPE:VOD"), "a partial map must still plan")
        let durations = text.split(separator: "\n").filter { $0.hasPrefix("#EXTINF:") }
            .compactMap { Double($0.dropFirst(8).dropLast()) }
        // The TS starts at PTS ~1.48 s and the plan runs from its first keyframe.
        #expect(abs(durations.reduce(0, +) - 28.5) < 1, "\(durations)")
        // And a tail segment — past the covered prefix — is still producible
        // on demand (the time-target boundary cuts at the next keyframe).
        let segments = text.split(separator: "\n").filter { $0.hasSuffix(".m4s") }.map(String.init)
        let (media, response) = try await URLSession.uncached.data(
            from: playlist.deletingLastPathComponent().appendingPathComponent(try #require(segments.last))
        )
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(media.range(of: Data("moof".utf8)) != nil)
    }

    @Test("An index-load that could not reach the tail is not stored as a complete map, and the next play rebuilds it")
    func interruptedIndexLoadIsNotStoredAsComplete() throws {
        let cacheDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let output = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: output) }
        let source = try fixture("h264_aac_30s.mkv")
        let bytes = [UInt8](try Data(contentsOf: source))
        // Half the file. The Cues live at the tail, so sealing there sends the
        // Matroska demuxer down its fallback: scan clusters forward from the
        // head, adding index entries as it goes. It gets ~14 s in before the
        // first unreachable read stops it — a head-anchored PREFIX, which is
        // exactly the shape a network timeout leaves behind.
        let seal = TailSeal(sealedAt: bytes.count / 2)

        // Play 1: the tail is unreachable while the plan is built, and
        // reachable from the moment the plan exists — a network that recovered
        // right after the index load gave up. The store decision under test is
        // made from the in-memory index, so lifting the seal here changes
        // nothing about it; it only lets production run to EOF.
        let first = HLSRemuxer(
            sourceURL: source, outputDirectory: output,
            demand: DemandCoordinator(), input: { TailSealedInput(bytes: bytes, seal: seal) },
            keyframeCacheDirectory: cacheDirectory
        )
        let firstOrigin = PlanOriginBox()
        first.onStartupPhase = { phase in
            if case .segmentPlanReady(let origin, _) = phase {
                firstOrigin.value = origin
                seal.lift()
            }
        }
        try Self.runUntilPlaylistWritten(first, in: output)
        // The scenario only bites when the prefix was good enough to PLAN on
        // — a degraded play would take the harvest path instead and prove
        // nothing. A VOD playlist is that plan.
        let firstText = try String(
            contentsOf: output.appendingPathComponent("index.m3u8"), encoding: .utf8
        )
        #expect(firstText.contains("#EXT-X-PLAYLIST-TYPE:VOD"),
                "the sealed-tail play did not plan on the prefix — the regression is not being exercised")
        #expect(firstOrigin.value == .builtFromSource)

        // Nothing is kept. The prefix says nothing about the 16 s past it, and
        // stored as a complete map it would be permanent: play 2 would plan on
        // it, skip the index load that now succeeds, and never harvest the
        // difference (the plan's own witnesses cannot tell a prefix from a
        // whole file).
        let afterFirst = try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path)
            .filter { $0.hasSuffix(".json") }
        for sidecar in afterFirst {
            let entry = try JSONDecoder().decode(
                KeyframeIndexCache.Entry.self,
                from: Data(contentsOf: cacheDirectory.appendingPathComponent(sidecar))
            )
            #expect(!entry.complete, "a prefix index was persisted as a complete map")
        }
        #expect(afterFirst.isEmpty, "an unproven prefix index was persisted at all")

        // Play 2, same source with the tail reachable: the index load runs to
        // the Cues, and THAT is what gets stored — the map repairs itself
        // rather than inheriting play 1's prefix.
        let secondOutput = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: secondOutput) }
        let second = HLSRemuxer(
            sourceURL: source, outputDirectory: secondOutput,
            demand: DemandCoordinator(), input: { TailSealedInput(bytes: bytes, seal: .open) },
            keyframeCacheDirectory: cacheDirectory
        )
        let secondOrigin = PlanOriginBox()
        second.onStartupPhase = { phase in
            if case .segmentPlanReady(let origin, _) = phase { secondOrigin.value = origin }
        }
        try Self.runUntilPlaylistWritten(second, in: secondOutput)
        // Built from the source again — nothing poisoned the cache for it to
        // plan from.
        #expect(secondOrigin.value == .builtFromSource)
        let sidecars = try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path)
            .filter { $0.hasSuffix(".json") }
        #expect(sidecars.count == 1)
        let entry = try JSONDecoder().decode(
            KeyframeIndexCache.Entry.self,
            from: Data(contentsOf: cacheDirectory.appendingPathComponent(try #require(sidecars.first)))
        )
        #expect(entry.complete)
        #expect(entry.coveredThroughPTS == nil)
        // The fixture is 30.023 s at a 2 s cadence: a whole-file index ends at
        // 28 s, a play-1 prefix would end around 14 s.
        #expect((entry.keyframePTS.max() ?? 0) >= 24_000, "\(entry.keyframePTS)")
    }

    /// Runs a PLANNED remuxer far enough to have written its playlists, then
    /// stops it. A demand-mode session parks at the coordinator instead of
    /// running to EOF, so `run()` on the calling thread would never return —
    /// and everything this suite asserts (the sidecar, the playlist) is on
    /// disk by the time the media playlist is.
    private static func runUntilPlaylistWritten(
        _ remuxer: HLSRemuxer, in directory: URL
    ) throws {
        let finished = DispatchSemaphore(value: 0)
        let failure = FailureBox()
        Thread.detachNewThread {
            do { try remuxer.run() } catch { failure.value = error }
            finished.signal()
        }
        let playlist = directory.appendingPathComponent(HLSRemuxer.mediaPlaylistFileName)
        let deadline = ContinuousClock.now + .seconds(30)
        while !FileManager.default.fileExists(atPath: playlist.path), ContinuousClock.now < deadline {
            usleep(2_000)
        }
        remuxer.cancel()
        #expect(finished.wait(timeout: .now() + 30) == .success, "the producer did not stop")
        if let error = failure.value { throw error }
    }

    @Test("A partial entry never replaces a complete one, nor a longer partial; old entries decode as complete")
    func partialStoreRules() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = KeyframeIndexCache(directory: directory)
        let complete = KeyframeIndexCache.Entry(identity: "a", timeBaseNum: 1, timeBaseDen: 1000, keyframePTS: [0, 2000, 4000])
        cache.store(complete)
        cache.store(.init(identity: "a", timeBaseNum: 1, timeBaseDen: 1000, keyframePTS: [0, 2000], complete: false, coveredThroughPTS: 2000))
        #expect(cache.lookup(identity: "a") == complete)

        cache.store(.init(identity: "b", timeBaseNum: 1, timeBaseDen: 1000, keyframePTS: [0, 2000, 4000], complete: false, coveredThroughPTS: 4000))
        cache.store(.init(identity: "b", timeBaseNum: 1, timeBaseDen: 1000, keyframePTS: [0, 2000], complete: false, coveredThroughPTS: 2000))
        #expect(cache.lookup(identity: "b")?.coveredThroughPTS == 4000)
        cache.store(.init(identity: "b", timeBaseNum: 1, timeBaseDen: 1000, keyframePTS: [0, 2000, 4000, 6000], complete: false, coveredThroughPTS: 6000))
        #expect(cache.lookup(identity: "b")?.coveredThroughPTS == 6000)

        // Pre-1.11 sidecar: no flag at all.
        let legacy = Data(#"{"identity":"c","timeBaseNum":1,"timeBaseDen":1000,"keyframePTS":[0,2000]}"#.utf8)
        let decoded = try JSONDecoder().decode(KeyframeIndexCache.Entry.self, from: legacy)
        #expect(decoded.complete)
        #expect(decoded.coveredThroughPTS == nil)
    }
}

/// An error a producer thread threw, readable back on the test's thread.
private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (any Error)?
    var value: (any Error)? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// The plan origin a remuxer reported, readable back on the test's thread.
private final class PlanOriginBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SegmentPlanOrigin?
    var value: SegmentPlanOrigin? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Whether a `TailSealedInput` is still refusing its tail, shared by every
/// input the factory hands out for one play.
private final class TailSeal: @unchecked Sendable {
    private let lock = NSLock()
    private var sealedAtOrNil: Int?

    /// A transport with nothing sealed — the recovered source of play 2.
    static var `open`: TailSeal { TailSeal(sealedAt: nil) }

    init(sealedAt: Int?) { self.sealedAtOrNil = sealedAt }

    var sealedAt: Int? { lock.withLock { sealedAtOrNil } }
    func lift() { lock.withLock { sealedAtOrNil = nil } }
}

/// The fixture's bytes with everything past the seal unreadable.
///
/// A source whose tail is momentarily unreachable: the Matroska Cues cannot be
/// fetched, so the index-load seek falls back to scanning clusters forward
/// from the head and dies partway, leaving the planner a head PREFIX. Byte
/// counted rather than timed, so the same prefix comes out on every machine —
/// a local file's linear scan is otherwise far too fast for a read budget to
/// interrupt.
private final class TailSealedInput: PrismCoreInput, @unchecked Sendable {
    private let bytes: [UInt8]
    private let seal: TailSeal
    private let lock = NSLock()
    private var position = 0

    struct TailUnreachable: Error {}

    init(bytes: [UInt8], seal: TailSeal) {
        self.bytes = bytes
        self.seal = seal
    }

    var length: Int64? { Int64(bytes.count) }

    func seek(to offset: Int64) throws {
        lock.withLock { position = Int(min(offset, Int64(bytes.count))) }
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let sealedAt = seal.sealedAt
        return try lock.withLock {
            if let sealedAt, position >= sealedAt { throw TailUnreachable() }
            let count = min(buffer.count, bytes.count - position)
            guard count > 0 else { return 0 }
            bytes.withUnsafeBytes { source in
                buffer.baseAddress!.copyMemory(
                    from: source.baseAddress! + position, byteCount: count
                )
            }
            position += count
            return count
        }
    }
}
