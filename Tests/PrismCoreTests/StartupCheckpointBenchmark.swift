import Testing
import Foundation
@testable import PrismCore

/// The field log's startup line, reproduced on the bench.
///
/// `StartupCostBenchmark` measures the pieces a host cannot see (a second
/// open, the readiness gate); this measures the line a host actually prints —
/// probe phases, then `start()`'s checkpoints — so a device report and a
/// bench run can be compared term by term instead of by intuition. The
/// 2026-09-19 report that started this work read
/// `probe 10583ms (open 10560 …) … plan 7344ms (builtFromSource, 591 seg)`,
/// and nothing in the suite produced a number of the same shape.
///
/// Opt-in: `PRISMCORE_BENCH` is a path or an `http://` URL. Use HTTP — see
/// AGENTS.md *Measuring*.
@Suite(
    "Startup checkpoints",
    .enabled(if: ProcessInfo.processInfo.environment["PRISMCORE_BENCH"] != nil),
    .serialized
)
struct StartupCheckpointBenchmark {

    private var mediaURL: URL {
        let raw = ProcessInfo.processInfo.environment["PRISMCORE_BENCH"]!
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") { return URL(string: raw)! }
        return URL(fileURLWithPath: raw)
    }

    private func ms(_ duration: Duration) -> Int { Int(duration / .milliseconds(1)) }

    @Test("probe phases then start() checkpoints")
    func checkpointLine() async throws {
        // Aether's own network budget, so a bench run fails where a device
        // would rather than where PrismCore's smaller default would.
        let budget = ProcessInfo.processInfo.environment["PRISMCORE_BENCH_PROBE_BUDGET_SECONDS"]
            .flatMap(Int.init) ?? 20
        // The transport is the variable this bench exists to compare, so it
        // is a knob rather than the default: FFmpeg's native HTTP asks for
        // `bytes=N-` and lets the origin stream, the coordinated reader asks
        // for bounded blocks.
        let coordinatedHTTP =
            ProcessInfo.processInfo.environment["PRISMCORE_BENCH_COORDINATED_HTTP"] == "1"
        let probed = try SourceProbe.open(
            url: mediaURL, budget: .seconds(budget), coordinatedHTTP: coordinatedHTTP
        )
        let timing = probed.timing
        let probeLine = "probe \(ms(timing.total))ms"
            + " (open \(ms(timing.open))"
            + " + info \(ms(timing.streamInfo))"
            + " + describe \(ms(timing.describe)))"

        let session = try PrismCoreSession(
            url: mediaURL,
            display: DisplayCapabilities(isHDRReady: true, isDolbyVisionCapable: true),
            probed: probed,
            keyframeIndexCacheDirectory: ProcessInfo.processInfo
                .environment["PRISMCORE_BENCH_KEYFRAME_CACHE"].map(URL.init(fileURLWithPath:)),
            coordinatedHTTP: coordinatedHTTP
        )
        let checkpoints = try await session.startupCheckpoints()
        let collected = Collected()
        let drain = Task {
            for await mark in checkpoints { collected.append(self.describe(mark)) }
        }
        let start = ContinuousClock.now
        var failure: String?
        do { _ = try await session.start() } catch { failure = "\(error)" }
        let total = ms(ContinuousClock.now - start)
        drain.cancel()
        await session.stop()

        print("""

        \(probeLine)
        startup \(collected.marks.joined(separator: " -> "))
        start() returned in \(total)ms\(failure.map { " — FAILED: \($0)" } ?? "")

        """)
    }

    private func describe(_ mark: StartupCheckpoint) -> String {
        let at = ms(mark.elapsed)
        switch mark.phase {
        case .sourceOpened: return "open \(at)ms"
        case .streamInfoResolved: return "probe \(at)ms"
        case .segmentPlanReady(let origin, let segments):
            return "plan \(at)ms (\(origin.rawValue), \(segments) seg)"
        case .firstVideoSegmentWritten: return "segment \(at)ms"
        case .playlistServable: return "servable \(at)ms"
        }
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func append(_ line: String) { lock.withLock { stored.append(line) } }
        var marks: [String] { lock.withLock { stored } }
    }
}
