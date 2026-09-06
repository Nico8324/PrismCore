import Testing
import Foundation
import Libavformat
import Libavcodec
@testable import PrismCore

/// Package B of the 2026-08 performance audit (#65): dialogue-boost
/// renditions are declared in the master but produced only once a fetch
/// under their directory arms them — the same shape as lazy OCR subtitles.
///
/// The fixture (`h264_ac3_51_20s.mkv`) is synthetic — 20 s of testsrc2 with
/// a 5.1 AC3 sine as the DEFAULT track, 2 s keyframes, Cues — so the plan
/// is keyframe-based and the boost is buildable on a build with the EAC3
/// encoder and the `pan` filter; on a build without them the routes are
/// empty and the session tests only pin that nothing broke.
@Suite("Lazy dialogue boost", .serialized)
struct LazyDialogueBoostTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    private func files(in directory: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    }

    /// Wait until `predicate` holds or `timeout` elapses.
    private func waitUntil(_ timeout: Duration = .seconds(10), _ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test("A forced request re-anchors even inside the window and at the current index")
    func forcedRequestBypassesWindow() {
        let coordinator = DemandCoordinator()
        coordinator.publish(plan: SegmentPlan(
            entries: (0..<8).map { .init(startPTS: Int64($0) * 6000, duration: 6.0) },
            basis: .keyframeIndex, timeBaseNum: 1, timeBaseDen: 1000
        ))
        coordinator.setProducing(index: 3)
        // Inside the window, unforced: swallowed (the producer gets there).
        coordinator.requestProduction(of: 4)
        #expect(coordinator.takeAnchorRequestDetailed() == nil)
        // Same index, forced: a request, and flagged so the copy loop does
        // not discard it as "already there".
        coordinator.requestProduction(of: 3, force: true)
        let request = coordinator.takeAnchorRequestDetailed()
        #expect(request?.index == 3)
        #expect(request?.forced == true)
        #expect(coordinator.takeAnchorRequestDetailed() == nil)
        // A later unforced request keeps an earlier force: the arming still
        // needs the rebuild wherever the playhead moved to.
        coordinator.requestProduction(of: 5, force: true)
        coordinator.requestProduction(of: 7)
        let combined = coordinator.takeAnchorRequestDetailed()
        #expect(combined?.index == 7)
        #expect(combined?.forced == true)
        // The plain accessor still consumes both.
        coordinator.requestProduction(of: 0, force: true)
        #expect(coordinator.takeAnchorRequest() == 0)
        #expect(coordinator.takeAnchorRequestDetailed() == nil)
    }

    @Test("The readiness gate does not wait for a lazy rendition's init")
    func gateSkipsLazyRenditionInit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreLazyGate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("audio1"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("audio0"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let master = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="eng",DEFAULT=YES,URI="audio0/index.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="eng (Dialogue Boost)",URI="audio1/index.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=1,CODECS="avc1.64001f,ac-3",AUDIO="aud"
        index.m3u8

        """
        let vod = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:2.0,\nseg00000.m4s\n#EXT-X-ENDLIST\n"
        try Data(master.utf8).write(to: root.appendingPathComponent("master.m3u8"))
        try Data(vod.utf8).write(to: root.appendingPathComponent("index.m3u8"))
        try Data("moov".utf8).write(to: root.appendingPathComponent("init.mp4"))
        try Data(vod.utf8).write(to: root.appendingPathComponent("audio0/index.m3u8"))
        try Data("moov".utf8).write(to: root.appendingPathComponent("audio0/init.mp4"))
        // Lazy rendition playlist absent: not ready (a playlist 404 fails the item).
        #expect(PrismCoreSession.readyPlaylistName(in: root, lazyRenditions: ["audio1/index.m3u8"]) == nil)
        try Data(vod.utf8).write(to: root.appendingPathComponent("audio1/index.m3u8"))
        // Without the lazy set the missing init holds the gate; with it, ready.
        #expect(PrismCoreSession.readyPlaylistName(in: root) == nil)
        #expect(PrismCoreSession.readyPlaylistName(in: root, lazyRenditions: ["audio1/index.m3u8"]) == "master.m3u8")
    }

    @Test("A lazy rendition writer opens nothing until armed, then joins at a re-anchor with a whole segment")
    func lazyWriterStateMachine() throws {
        // A stream-copy route stands in for the boost: the lazy state machine
        // is the writer's, not the bridge's, and this build has no EAC3
        // encoder to build a bridge with (see the session test below).
        let url = try fixture("h264_aac_30s.mkv")
        var input: UnsafeMutablePointer<AVFormatContext>?
        try FFmpegError.check(avformat_open_input(&input, url.path, nil, nil), "avformat_open_input")
        defer { avformat_close_input(&input) }
        let context = try #require(input)
        try FFmpegError.check(avformat_find_stream_info(context, nil), "avformat_find_stream_info")
        let audioIndex = Int(av_find_best_stream(context, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0))
        let track = AudioTrackInfo(
            streamIndex: audioIndex, codecName: "aac", profileName: nil,
            channelCount: 1, channelLayoutDescription: "mono",
            sampleRate: 48_000, language: "en", title: nil,
            isObjectAudio: false, copyability: .streamCopy
        )
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreLazyWriter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let writer = AudioRenditionWriter(
            route: .init(index: Int32(audioIndex), mode: .streamCopy),
            track: track, ordinal: 1, parent: parent, lazy: true
        )
        var planned: [Int] = []
        writer.onPlannedSegment = { index, produced in planned.append(produced ? index : -index - 1) }
        try writer.open(input: context)
        try writer.writePlannedVOD(durations: [2, 6, 6])
        #expect(!writer.isProducing)
        #expect(!writer.isArmed)
        let directory = parent.appendingPathComponent("audio1")
        #expect(files(in: directory) == ["index.m3u8"], "declared: playlist only")

        // Packets fed while dormant are dropped, and a dormant boundary
        // passes without declaring the slot unproducible (the arming fetch
        // reproduces it).
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        let pkt = try #require(packet)
        var fed = 0
        while fed < 20, av_read_frame(context, pkt) >= 0 {
            defer { av_packet_unref(pkt) }
            guard Int(pkt.pointee.stream_index) == audioIndex else { continue }
            try writer.write(pkt, sourceTimeBase: context.pointee.streams[audioIndex]!.pointee.time_base)
            fed += 1
        }
        try writer.cut(durationSeconds: 2)
        #expect(files(in: directory) == ["index.m3u8"])
        #expect(planned.isEmpty, "a dormant cut must not mark its slot")

        // Arm (the fetch), then the producer re-anchors at segment 1: the
        // muxer opens here, and the next cut writes init + seg00001.
        #expect(writer.arm() == true)
        #expect(writer.arm() == false, "arming is once")
        #expect(writer.isArmed)
        try writer.reanchor(input: context, segmentIndex: 1)
        #expect(writer.isProducing)
        fed = 0
        while fed < 40, av_read_frame(context, pkt) >= 0 {
            defer { av_packet_unref(pkt) }
            guard Int(pkt.pointee.stream_index) == audioIndex else { continue }
            try writer.write(pkt, sourceTimeBase: context.pointee.streams[audioIndex]!.pointee.time_base)
            fed += 1
        }
        try writer.cut(durationSeconds: 6)
        #expect(files(in: directory) == ["index.m3u8", "init.mp4", "seg00001.m4s"], "\(files(in: directory))")
        #expect(planned == [1])
    }

    @Test("The provider's audio seam arms on init/segment fetches only, and forces the re-anchor")
    func providerSeamArmsAndForces() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreLazySeam-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DemandCoordinator()
        coordinator.publish(plan: SegmentPlan(
            entries: (0..<8).map { .init(startPTS: Int64($0) * 6000, duration: 6.0) },
            basis: .keyframeIndex, timeBaseNum: 1, timeBaseDen: 1000
        ))
        coordinator.setProducing(index: 2)
        var provider = PlanSegmentProvider(root: root, coordinator: coordinator)
        let armed = LockedBox<[String]>([])
        provider.audioDemand = { path in
            // Arms once per directory, like the writer.
            let directory = String(path.split(separator: "/").first ?? "")
            return armed.withValue { list in
                if list.contains(directory) { return false }
                list.append(directory); return true
            }
        }
        // A playlist fetch never arms — AVPlayer prefetches those for
        // renditions it never plays.
        _ = await provider.data(forPath: "audio1/index.m3u8")
        #expect(armed.value.isEmpty)
        #expect(coordinator.takeAnchorRequestDetailed() == nil)
        // A segment fetch INSIDE the window: arms, and the request is forced
        // where an unarmed miss would have been swallowed.
        guard case .pending = await provider.data(forPath: "audio1/seg00003.m4s") else {
            Issue.record("miss must be pending"); return
        }
        #expect(armed.value == ["audio1"])
        let request = coordinator.takeAnchorRequestDetailed()
        #expect(request?.index == 3)
        #expect(request?.forced == true)
        // Already armed: the next fetch is an ordinary demand (inside the
        // window → no request).
        guard case .pending = await provider.data(forPath: "audio1/seg00004.m4s") else {
            Issue.record("miss must be pending"); return
        }
        #expect(coordinator.takeAnchorRequestDetailed() == nil)
        // An init fetch names no segment: it anchors at the newest demanded
        // index (4, from the fetch above) — the playhead's neighbourhood.
        guard case .pending = await provider.data(forPath: "audio2/init.mp4") else {
            Issue.record("init miss must be pending"); return
        }
        #expect(armed.value == ["audio1", "audio2"])
        let initRequest = coordinator.takeAnchorRequestDetailed()
        #expect(initRequest?.index == 4)
        #expect(initRequest?.forced == true)
    }

    @Test("No boost bridge runs before the first fetch under its directory; a fetch arms it and the default rendition is unaffected")
    func boostIsProducedOnDemandOnly() async throws {
        let session = try PrismCoreSession(
            url: try fixture("h264_ac3_51_20s.mkv"),
            dialogueBoost: [.medium, .high]
        )
        let playlist = try await session.start()
        defer { Task { await session.stop() } }
        let work = await session.workDirectory
        let base = playlist.deletingLastPathComponent()

        let masterText = try String(contentsOf: work.appendingPathComponent("master.m3u8"), encoding: .utf8)
        let reported = await session.dialogueBoostRenditions
        guard PrismCoreSession.isDialogueBoostAvailable else {
            #expect(reported.isEmpty)
            // Stock MPVKit has no EAC3 encoder: this pins the graceful skip,
            // and the two tests above carry the lazy mechanism on any build.
            return
        }
        #expect(reported.map(\.level) == [.medium, .high])
        // Declared with the encoder's channel count although no encoder is
        // running: CHANNELS comes from the negotiated layout at open.
        for line in masterText.split(separator: "\n") where line.contains("CHARACTERISTICS") {
            #expect(line.contains("CHANNELS=\"6\""), "\(line)")
            #expect(line.contains("URI=\"audio1/") || line.contains("URI=\"audio2/"), "\(line)")
        }

        // (1) Let production run the whole 20 s file (the lead cap never
        // parks before the first fetch): the default rendition lands every
        // segment, the boost directories hold their planned playlist and
        // NOTHING else — no init, no segment — which is only possible if no
        // bridge was ever fed.
        let audio0 = work.appendingPathComponent("audio0")
        await waitUntil { self.files(in: audio0).contains("seg00003.m4s") }
        #expect(files(in: audio0).contains("init.mp4"))
        #expect(files(in: audio0).contains("seg00000.m4s"))
        #expect(files(in: work.appendingPathComponent("audio1")) == ["index.m3u8"])
        #expect(files(in: work.appendingPathComponent("audio2")) == ["index.m3u8"])

        // (2) The first fetch under audio1/ arms it: the request re-anchors
        // production at the demanded segment and the segment is served
        // complete, with an init that carries the EAC3 sample entry.
        let (boostSeg, response) = try await URLSession.shared.data(
            from: base.appendingPathComponent("audio1/seg00001.m4s")
        )
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(boostSeg.range(of: Data("moof".utf8)) != nil)
        let (boostInit, initResponse) = try await URLSession.shared.data(
            from: base.appendingPathComponent("audio1/init.mp4")
        )
        #expect((initResponse as? HTTPURLResponse)?.statusCode == 200)
        // The sample entry's codec box follows the build's bridge encoder:
        // `dec3` for EAC3, `esds` for AAC.
        let bridgeBox = AudioBridge.defaultTargetCodecName == "eac3" ? "dec3" : "esds"
        #expect(boostInit.range(of: Data(bridgeBox.utf8)) != nil, "boost init must describe the bridge codec")
        // The other level was not asked for and stays dormant.
        #expect(files(in: work.appendingPathComponent("audio2")) == ["index.m3u8"])

        // (3) The stream-copied default rendition is what it was: its
        // segment of the same index still serves, and its init is AC3's.
        let (baseSeg, baseResponse) = try await URLSession.shared.data(
            from: base.appendingPathComponent("audio0/seg00001.m4s")
        )
        #expect((baseResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(baseSeg.range(of: Data("moof".utf8)) != nil)
        let baseInit = try Data(contentsOf: audio0.appendingPathComponent("init.mp4"))
        #expect(baseInit.range(of: Data("dac3".utf8)) != nil)
    }
}

/// A tiny lock-protected box for test bookkeeping across `@Sendable` closures.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value { lock.withLock { storage } }
    func withValue<R>(_ body: (inout Value) -> R) -> R { lock.withLock { body(&storage) } }
}
