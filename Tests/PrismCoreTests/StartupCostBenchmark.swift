import Testing
import Foundation
import Libavformat
import Libavcodec
import Libavutil
@testable import PrismCore

/// Where a session's startup time actually goes, measured rather than
/// reasoned about — the prerequisite for deciding which of the suspected
/// costs is worth engineering away.
///
/// Opt-in: point `PRISMCORE_BENCH` at real media. A fixture is useless here;
/// every cost this measures is dominated by the transport and the file's
/// size, which is exactly what a two-second synthetic clip doesn't have.
@Suite(
    "Startup cost",
    .enabled(if: ProcessInfo.processInfo.environment["PRISMCORE_BENCH"] != nil),
    .serialized
)
struct StartupCostBenchmark {

    /// First-sighting timestamps, shared between the polling task and the
    /// test body.
    private final class Marks: @unchecked Sendable {
        private let lock = NSLock()
        private var masterMs: Int?
        private var videoVariantMs: Int?

        func noteMaster(_ ms: Int) {
            lock.withLock { if masterMs == nil { masterMs = ms } }
        }
        func noteVideoVariant(_ ms: Int) {
            lock.withLock { if videoVariantMs == nil { videoVariantMs = ms } }
        }
        var master: Int? { lock.withLock { masterMs } }
        var videoVariant: Int? { lock.withLock { videoVariantMs } }
    }

    private var mediaURL: URL {
        // A path or an http(s) URL: the transport is the whole point here, and
        // a local mount hides exactly the cost a network one exposes.
        let raw = ProcessInfo.processInfo.environment["PRISMCORE_BENCH"]!
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return URL(string: raw)!
        }
        return URL(fileURLWithPath: raw)
    }

    private func ms(_ body: () throws -> Void) rethrows -> Int {
        let start = ContinuousClock.now
        try body()
        return Int((ContinuousClock.now - start) / .milliseconds(1))
    }

    private func ms(_ body: () async throws -> Void) async rethrows -> Int {
        let start = ContinuousClock.now
        try await body()
        return Int((ContinuousClock.now - start) / .milliseconds(1))
    }

    /// One open + `find_stream_info`, with optional probe limits — the unit of
    /// work `SourceProbe` and `HLSRemuxer` each pay separately today.
    private func openCost(probesize: Int?, analyzeDurationMicroseconds: Int?) -> Int {
        var input: UnsafeMutablePointer<AVFormatContext>?
        var options: OpaquePointer?
        defer { av_dict_free(&options) }
        if let probesize {
            av_dict_set(&options, "probesize", String(probesize), 0)
        }
        if let analyzeDurationMicroseconds {
            av_dict_set(&options, "analyzeduration", String(analyzeDurationMicroseconds), 0)
        }
        let spec = mediaURL.isFileURL ? mediaURL.path : mediaURL.absoluteString
        return ms {
            guard avformat_open_input(&input, spec, nil, &options) >= 0, input != nil else { return }
            defer { avformat_close_input(&input) }
            _ = avformat_find_stream_info(input, nil)
        }
    }

    @Test("phase breakdown")
    func breakdown() async throws {
        var lines: [String] = ["source: \(mediaURL.lastPathComponent)"]
        if mediaURL.isFileURL,
           let size = try? FileManager.default.attributesOfItem(atPath: mediaURL.path)[.size] as? Int64 {
            lines.append(String(format: "size: %.2f GB", Double(size) / 1_073_741_824))
        }

        // 1. The routing probe the host runs before deciding anything.
        let probeMs = try ms { _ = try SourceProbe.probe(url: mediaURL) }
        lines.append("probe (SourceProbe): \(probeMs) ms")

        // 2. The SECOND open — HLSRemuxer.run repeats the same work on its own
        // context. Timed as its own open so the redundancy has a number.
        let secondOpenMs = openCost(probesize: nil, analyzeDurationMicroseconds: nil)
        lines.append("redundant open (HLSRemuxer repeats this): \(secondOpenMs) ms")

        // 3. What capping the probe limits would buy on that same work.
        let cappedMs = openCost(probesize: 2 << 20, analyzeDurationMicroseconds: 1_000_000)
        lines.append("open with probesize=2MB analyzeduration=1s: \(cappedMs) ms")

        // 4. Session startup end to end, and the shape it produced. Probed
        // first and handed over, which is the routing shape a host uses: the
        // number below is therefore "probe + start", one open in total.
        var probeAndAdoptMs = 0
        var probedSource: ProbedSource?
        probeAndAdoptMs = try ms { probedSource = try SourceProbe.open(url: mediaURL) }
        lines.append("probe keeping the context (SourceProbe.open): \(probeAndAdoptMs) ms")
        let session = try PrismCoreSession(
            url: mediaURL,
            display: DisplayCapabilities(isHDRReady: true, isDolbyVisionCapable: true),
            probed: probedSource
        )
        var playlist: URL?
        var startFailure: String?
        // A timeout is a measurement, not a reason to lose the numbers above.
        let startMs = await ms {
            do { playlist = try await session.start() }
            catch { startFailure = "\(error)" }
        }
        defer { Task { await session.stop() } }
        lines.append(
            "session.start(): \(startMs) ms"
                + (startFailure.map { " — FAILED: \($0)" } ?? " → playlist")
        )
        if let playlist {
            lines.append("playlist: \(playlist.lastPathComponent)")
            let master = try? String(contentsOf: playlist, encoding: .utf8)
            let referenced = master.map { PrismCoreSession.playlistURIs(inMaster: $0) } ?? []
            lines.append("renditions the readiness gate waited for: \(referenced.count)")
        }

        // 5. First bytes AVPlayer would actually fetch.
        if let playlist {
            let base = playlist.deletingLastPathComponent()
            let initMs = try await ms {
                _ = try await URLSession.uncached.data(from: base.appendingPathComponent("init.mp4"))
            }
            lines.append("fetch init.mp4: \(initMs) ms")
            let segMs = try await ms {
                _ = try await URLSession.uncached.data(from: base.appendingPathComponent("seg00000.m4s"))
            }
            lines.append("fetch seg00000.m4s: \(segMs) ms")

            // 6. A cold SEEK: fetch a segment far past the produced window,
            // which walks the whole demand path — the parked producer notices
            // the anchor, re-anchors, produces, and the provider notices the
            // file. Every hop of that chain is a poll; this is their sum.
            if let variant = try? String(
                contentsOf: base.appendingPathComponent("index.m3u8")
            ) {
                let segments = variant.split(separator: "\n")
                    .filter { $0.hasSuffix(".m4s") && $0.hasPrefix("seg") }
                if segments.count > 4 {
                    let target = String(segments[(segments.count * 2) / 3])
                    let seekMs = try await ms {
                        _ = try await URLSession.uncached.data(from: base.appendingPathComponent(target))
                    }
                    lines.append("cold seek (\(target), demand path): \(seekMs) ms")
                }
            }
        }

        // 7. A PARKED cold seek — the shape a user's seek actually has ten
        // minutes into playback: the producer sits in its park loop, the
        // target segment was evicted, and the fetch has to cross every poll
        // in the chain (park wake → re-anchor → produce → provider notices
        // the file). A tight cache budget forces the eviction; the wait
        // before the fetch lets production finish and the producer park.
        do {
            let parked = try PrismCoreSession(
                url: mediaURL,
                display: DisplayCapabilities(isHDRReady: true, isDolbyVisionCapable: true),
                segmentCacheBytes: 8 << 20
            )
            let playlist2 = try await parked.start()
            defer { Task { await parked.stop() } }
            let work = await parked.workDirectory
            // Wait for EOF + park: production stops growing the directory.
            var lastCount = -1
            for _ in 0..<100 {
                let count = (try? FileManager.default.contentsOfDirectory(atPath: work.path).count) ?? 0
                if count == lastCount { break }
                lastCount = count
                try await Task.sleep(for: .milliseconds(200))
            }
            let base2 = playlist2.deletingLastPathComponent()
            if let victim = (0..<25).first(where: { index in
                !FileManager.default.fileExists(
                    atPath: work.appendingPathComponent(String(format: "seg%05d.m4s", index)).path
                )
            }) {
                let name = String(format: "seg%05d.m4s", victim)
                let parkedSeekMs = try await ms {
                    _ = try await URLSession.uncached.data(from: base2.appendingPathComponent(name))
                }
                lines.append("parked cold seek (\(name), evicted → re-anchor): \(parkedSeekMs) ms")
            } else {
                lines.append("parked cold seek: nothing evicted, skipped")
            }
        }

        lines.append("--- totals ---")
        lines.append("probe + start = \(probeMs + startMs) ms before AVPlayer sees anything")
        lines.append("of which redundant re-open ≈ \(secondOpenMs) ms")
        lines.append("capped probe would save ≈ \(max(0, secondOpenMs - cappedMs)) ms per open")
        print("\n" + lines.joined(separator: "\n") + "\n")
    }

    /// How much of `start()` is the readiness gate waiting for subtitle
    /// renditions rather than for anything AVPlayer needs to begin.
    @Test("readiness gate: video+audio vs every rendition")
    func readinessBreakdown() async throws {
        let session = try PrismCoreSession(
            url: mediaURL,
            display: DisplayCapabilities(isHDRReady: true, isDolbyVisionCapable: true)
        )
        let workDirectory = await session.workDirectory
        let start = ContinuousClock.now
        let marks = Marks()

        // Poll the work directory alongside start(), so the moment the master
        // and the video variant land is visible independently of the moment
        // every subtitle rendition does.
        let watcher = Task {
            while !Task.isCancelled {
                let elapsed = Int((ContinuousClock.now - start) / .milliseconds(1))
                let master = workDirectory.appendingPathComponent("master.m3u8")
                if FileManager.default.fileExists(atPath: master.path) {
                    marks.noteMaster(elapsed)
                }
                let variant = workDirectory.appendingPathComponent("index.m3u8")
                if let text = try? String(contentsOf: variant, encoding: .utf8),
                   text.contains("#EXTINF") {
                    marks.noteVideoVariant(elapsed)
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        _ = try await session.start()
        let readyAt = Int((ContinuousClock.now - start) / .milliseconds(1))
        watcher.cancel()
        defer { Task { await session.stop() } }

        let masterAt = marks.master
        let videoVariantAt = marks.videoVariant
        print("""

        master written: \(masterAt.map(String.init) ?? "?") ms
        video variant playable: \(videoVariantAt.map(String.init) ?? "?") ms
        ALL renditions ready (start returns): \(readyAt) ms
        gate cost beyond the video variant: \(videoVariantAt.map { readyAt - $0 }.map(String.init) ?? "?") ms

        """)
    }
}
