import Testing
import Foundation
@testable import PrismCore

/// `start()` used to be a black box for up to twenty seconds. These cover the
/// checkpoints that opened it: the order they arrive in, what they say about
/// the plan, and — the part a host's spinner depends on — that the stream
/// always ends.
///
/// Every test that awaits the collector's value would HANG rather than fail if
/// a termination guarantee broke, so the suite carries a time limit: a wrong
/// answer must be reportable.
@Suite("Startup checkpoints", .serialized, .timeLimit(.minutes(1)))
struct StartupProgressTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreStartup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Drains the stream to completion. Awaiting the returned task's value is
    /// the termination assertion: it only ever returns once the stream has
    /// finished.
    private func collect(
        _ stream: AsyncStream<StartupCheckpoint>
    ) -> Task<[StartupCheckpoint], Never> {
        Task {
            var marks: [StartupCheckpoint] = []
            for await mark in stream { marks.append(mark) }
            return marks
        }
    }

    // MARK: - The normal sequence

    @Test("A local source reports the five stages in order, each with its elapsed time")
    func orderedSequenceForLocalSource() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac_30s.mkv"))
        let collector = collect(try await session.startupCheckpoints())
        let playlist = try await session.start()
        let marks = await collector.value
        await session.stop()

        #expect(marks.count == 5, "\(marks.map(\.phase))")
        guard marks.count == 5 else { return }
        #expect(marks[0].phase == .sourceOpened)
        guard case .streamInfoResolved(let info) = marks[1].phase else {
            Issue.record("second checkpoint was \(marks[1].phase)"); return
        }
        // The probe's verdict, not a re-derived summary: this is the same
        // SourceInfo the routing decision was made on.
        #expect(info.video?.codecName == "h264")
        #expect(info.audioTracks.count == 1)
        guard case .segmentPlanReady(let origin, let segments) = marks[2].phase else {
            Issue.record("third checkpoint was \(marks[2].phase)"); return
        }
        // No cache directory was configured, so the map cannot have come from
        // one — this plan was built from the source's own index.
        #expect(origin == .builtFromSource)
        #expect(segments == 6, "the 30 s fixture plans [2,6,6,6,6,4]")
        #expect(marks[3].phase == .firstVideoSegmentWritten(index: 0))
        #expect(marks[4].phase == .playlistServable(playlist))

        // Timestamps are the diagnostic payoff, so they have to be usable: a
        // monotonic series measured from the start() call.
        #expect(marks.map(\.elapsed) == marks.map(\.elapsed).sorted())
        #expect(marks[0].elapsed > .zero)
    }

    // MARK: - Termination

    @Test("The stream ends when start() fails")
    func streamTerminatesOnFailure() async throws {
        // VP9 cannot be stream-copied into HLS-fMP4: the remux refuses the
        // source after describing it, which is the failure shape a host is
        // most likely to meet.
        let session = try PrismCoreSession(url: try fixture("vp9.webm"))
        let collector = collect(try await session.startupCheckpoints())
        await #expect(throws: PrismCoreSession.SessionError.self) {
            _ = try await session.start(startupTimeout: .seconds(10))
        }
        let marks = await collector.value
        await session.stop()

        // It got as far as describing the source, and then stopped — the
        // stream ends, the error arrives from `start()`, and the host's
        // spinner has something to say about why.
        #expect(marks.first?.phase == .sourceOpened)
        guard case .streamInfoResolved(let info) = marks.last?.phase else {
            Issue.record("expected a stream-info checkpoint, got \(marks.map(\.phase))"); return
        }
        #expect(info.video?.codecName == "vp9")
        #expect(marks.count == 2)
    }

    @Test("The stream ends when a registered session is stopped without ever starting")
    func streamTerminatesOnStop() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac_30s.mkv"))
        let collector = collect(try await session.startupCheckpoints())
        await session.stop()
        #expect(await collector.value.isEmpty)
    }

    @Test("Registering after start() is refused rather than silently ignored")
    func registeringAfterStartThrows() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac_30s.mkv"))
        _ = try await session.start()
        defer { Task { await session.stop() } }
        await #expect(throws: PrismCoreSession.SessionError.self) {
            _ = try await session.startupCheckpoints()
        }
    }

    // MARK: - Plan origin

    @Test("A plan taken from the keyframe index cache is reported differently from one built here")
    func cachedPlanIsDistinguishableFromABuiltOne() async throws {
        let cacheDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let output = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: output) }
        let source = try fixture("h264_ac3_30s.ts")

        // Play 1 harvests the map. A zero index-load budget reproduces the
        // field shape deterministically (see `KeyframeIndexCacheTests`): the
        // scan bounds out, the plan degrades, the producer runs sequentially
        // and records every keyframe it reads.
        let harvest = HLSRemuxer(
            sourceURL: source,
            outputDirectory: output,
            demand: DemandCoordinator(),
            keyframeCacheDirectory: cacheDirectory,
            indexLoadBudget: .zero
        )
        try harvest.run()

        // Play 2 plans on that map — and says so.
        let cached = try PrismCoreSession(url: source, keyframeIndexCacheDirectory: cacheDirectory)
        let cachedCollector = collect(try await cached.startupCheckpoints())
        _ = try await cached.start()
        let cachedMarks = await cachedCollector.value
        await cached.stop()

        // The same source with no cache to consult: whatever it plans, it did
        // not get it from a previous play. The two paths cost very different
        // amounts of time, and telling them apart is the point of reporting
        // the origin at all.
        let fresh = try PrismCoreSession(url: source)
        let freshCollector = collect(try await fresh.startupCheckpoints())
        _ = try await fresh.start()
        let freshMarks = await freshCollector.value
        await fresh.stop()

        func origin(_ marks: [StartupCheckpoint]) -> SegmentPlanOrigin? {
            for mark in marks {
                if case .segmentPlanReady(let origin, _) = mark.phase { return origin }
            }
            return nil
        }
        #expect(origin(cachedMarks) == .keyframeIndexCache)
        #expect(origin(freshMarks) != .keyframeIndexCache, "\(String(describing: origin(freshMarks)))")
    }
}
