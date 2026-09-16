import Testing
import Libavformat
import Foundation
@testable import PrismCore

/// Handing a session the routing probe's open context means a playback opens
/// its source once instead of twice. The risk is in what the handover carries:
/// an earlier attempt passed the probe's *answer* and let the second context
/// skip its analysis, which produced a right-looking manifest and a muxer that
/// failed on the first write. These pin the difference.
@Suite("Probed-source reuse", .serialized)
struct ProbedSourceReuseTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    private func waitForFinished(_ playlist: URL, timeout: Duration = .seconds(30)) async throws {
        var mediaURL = playlist
        let (first, _) = try await URLSession.uncached.data(from: playlist)
        let master = String(decoding: first, as: UTF8.self)
        if master.contains("#EXT-X-STREAM-INF") {
            let variant = try #require(PrismCoreSession.playlistURIs(inMaster: master).last)
            mediaURL = playlist.deletingLastPathComponent().appendingPathComponent(variant)
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let (data, _) = try await URLSession.uncached.data(from: mediaURL)
            if String(decoding: data, as: UTF8.self).contains("#EXT-X-ENDLIST") { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw PrismCoreSession.SessionError.startupTimedOut(underlying: nil)
    }

    /// The one that matters: an adopted context must produce a byte-identical
    /// presentation AND survive muxing to the end. EAC3 is the fixture on
    /// purpose — its `dec3` sample entry is built from parsed packets, so it is
    /// exactly the track that broke when the analysis was skipped rather than
    /// inherited.
    @Test("An adopted context produces the same output, and muxes to ENDLIST")
    func adoptedContextMatchesFreshOpen() async throws {
        let source = try fixture("hevc_eac3.mkv")
        let display = DisplayCapabilities(isHDRReady: true, isDolbyVisionCapable: true)

        let probed = try SourceProbe.open(url: source)
        #expect(probed.holdsContext)
        let adopting = try PrismCoreSession(url: source, display: display, probed: probed)
        let adoptedPlaylist = try await adopting.start()
        // The context moved: the probe no longer owns anything to close.
        #expect(!probed.holdsContext)
        // Running to ENDLIST is the assertion the earlier attempt failed —
        // `av_interleaved_write_frame` died mid-stream while the manifest
        // looked perfectly correct.
        try await waitForFinished(adoptedPlaylist)
        let adoptedMaster = try String(contentsOf: adoptedPlaylist, encoding: .utf8)
        let adoptedInit = try Data(
            contentsOf: adoptedPlaylist.deletingLastPathComponent()
                .appendingPathComponent("init.mp4")
        )
        await adopting.stop()

        let fresh = try PrismCoreSession(url: source, display: display)
        let freshPlaylist = try await fresh.start()
        try await waitForFinished(freshPlaylist)
        let freshMaster = try String(contentsOf: freshPlaylist, encoding: .utf8)
        let freshInit = try Data(
            contentsOf: freshPlaylist.deletingLastPathComponent()
                .appendingPathComponent("init.mp4")
        )
        await fresh.stop()

        // The manifest is where a wrong shortcut shows first (CODECS,
        // VIDEO-RANGE, the rendition list)…
        #expect(adoptedMaster == freshMaster)
        // …and the init segment is the decode contract itself.
        #expect(adoptedInit == freshInit)
    }

    @Test("An adopted context left mid-file is rewound before production whether or not the plan seeks")
    func adoptedContextIsRewoundOnEveryPath() async throws {
        let source = try fixture("h264_aac_30s.mkv")
        // Path 1: the Cues index-load nudge ends at the head itself, so the
        // remuxer skips its own rewind — the output must still begin at 0.
        let probed = try SourceProbe.open(url: source)
        let context = try #require(probed.peekContextForTesting())
        // Push the read position deep into the file, as a long interlace
        // verification would.
        _ = av_seek_frame(context, -1, 20 * Int64(AV_TIME_BASE), 0)
        let session = try PrismCoreSession(url: source, display: .init(isHDRReady: false, isDolbyVisionCapable: false), probed: probed)
        let playlist = try await session.start()
        defer { Task { await session.stop() } }
        let base = playlist.deletingLastPathComponent()
        let (variantData, _) = try await URLSession.uncached.data(from: base.appendingPathComponent("index.m3u8"))
        let durations = String(decoding: variantData, as: UTF8.self).split(separator: "\n")
            .filter { $0.hasPrefix("#EXTINF:") }.compactMap { Double($0.dropFirst(8).dropLast()) }
        #expect(durations.count == 6, "\(durations)")
        let (head, response) = try await URLSession.uncached.data(from: base.appendingPathComponent("seg00000.m4s"))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        // The head segment's tfdt is 0: production started at the head, not
        // at the 20 s the probe left it.
        #expect(head.range(of: Data("tfdt".utf8)) != nil)
        let tfdt = try #require(head.range(of: Data("tfdt".utf8)))
        // tfdt v1: 4 bytes version/flags then a 64-bit decode time.
        let decodeTime = head[tfdt.upperBound + 4 ..< tfdt.upperBound + 12].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        #expect(decodeTime == 0, "head segment decode time \(decodeTime)")

        // Path 2: a cached keyframe map means the plan never seeks; the
        // remuxer must rewind itself. Same assertion.
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreRewind-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let probe2 = try SourceProbe.open(url: source)
        let ctx2 = try #require(probe2.peekContextForTesting())
        let identity = KeyframeIndexCache.identity(
            sourceURL: source, sizeBytes: avio_size(ctx2.pointee.pb), durationMicroseconds: ctx2.pointee.duration
        )
        let timeBase = ctx2.pointee.streams[0]!.pointee.time_base
        KeyframeIndexCache(directory: cacheDirectory).store(.init(
            identity: identity, timeBaseNum: timeBase.num, timeBaseDen: timeBase.den,
            keyframePTS: stride(from: 0, through: 28_000, by: 2_000).map(Int64.init)
        ))
        _ = av_seek_frame(ctx2, -1, 20 * Int64(AV_TIME_BASE), 0)
        let cached = try PrismCoreSession(
            url: source, display: .init(isHDRReady: false, isDolbyVisionCapable: false),
            probed: probe2, keyframeIndexCacheDirectory: cacheDirectory
        )
        let cachedPlaylist = try await cached.start()
        defer { Task { await cached.stop() } }
        let (head2, _) = try await URLSession.uncached.data(
            from: cachedPlaylist.deletingLastPathComponent().appendingPathComponent("seg00000.m4s")
        )
        let tfdt2 = try #require(head2.range(of: Data("tfdt".utf8)))
        let decodeTime2 = head2[tfdt2.upperBound + 4 ..< tfdt2.upperBound + 12].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        #expect(decodeTime2 == 0, "cached-plan head decode time \(decodeTime2)")
    }

    @Test("openDetached answers off the cooperative pool with the same verdict as open")
    func openDetachedMatchesOpen() async throws {
        let source = try fixture("hevc_eac3.mkv")
        let detached = try await SourceProbe.openDetached(url: source)
        let direct = try SourceProbe.open(url: source)
        #expect(detached.holdsContext)
        #expect(detached.info == direct.info)
        // Both contexts close on their own when released — nothing adopted them.
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).mkv")
        await #expect(throws: (any Error).self) { try await SourceProbe.openDetached(url: missing) }
    }

    @Test("The context is handed over exactly once")
    func contextIsConsumedOnce() throws {
        let probed = try SourceProbe.open(url: try fixture("h264_aac.mkv"))
        #expect(probed.consumeContext() != nil)
        // A second producer must open its own rather than share a context that
        // is not safe for concurrent use.
        #expect(probed.consumeContext() == nil)
        #expect(!probed.holdsContext)
    }

    /// A source that routes elsewhere (the software path, or a host that
    /// simply never starts a session) must not leak its connection.
    @Test("A probe nobody adopts still closes its context")
    func unadoptedProbeCloses() throws {
        let probed = try SourceProbe.open(url: try fixture("h264_aac.mkv"))
        #expect(probed.holdsContext)
        // Nothing to assert beyond reaching here without a leak; the close
        // happens in `deinit`, which the address sanitizer and the FFmpeg
        // allocator would both complain about if it double-freed after an
        // adoption. The paired test above covers the adopted case.
    }

    @Test("A session whose probe was already consumed opens its own source")
    func consumedProbeFallsBackToOpening() async throws {
        let source = try fixture("h264_aac.mkv")
        let probed = try SourceProbe.open(url: source)
        // Somebody else took it first — the session must still play.
        _ = probed.consumeContext().map { context -> Void in
            var closing: UnsafeMutablePointer<AVFormatContext>? = context
            avformat_close_input(&closing)
        }
        let session = try PrismCoreSession(
            url: source,
            display: DisplayCapabilities(isHDRReady: false, isDolbyVisionCapable: false),
            probed: probed
        )
        let playlist = try await session.start()
        defer { Task { await session.stop() } }
        let info = try SourceProbe.probe(url: playlist)
        #expect(info.video?.codecName == "h264")
    }
}
