import Testing
import Foundation
@testable import PrismCore

/// Package F of the 2026-08 performance audit (#65): seek and steady state.
@Suite("Seek & steady state", .serialized)
struct SeekSteadyStateTests {

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreSeek-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func plan(_ count: Int, stride: Int64 = 6000) -> SegmentPlan {
        SegmentPlan(
            entries: (0..<count).map { .init(startPTS: Int64($0) * stride, duration: Double(stride) / 1000) },
            basis: .keyframeIndex, timeBaseNum: 1, timeBaseDen: 1000
        )
    }

    // MARK: - F1 debounce

    @Test("A scrub burst coalesces: requests younger than the debounce are held while a re-anchor is in flight, the newest wins")
    func scrubBurstCoalesces() async throws {
        let coordinator = DemandCoordinator()
        coordinator.publish(plan: plan(40))
        coordinator.setProducing(index: 0)
        coordinator.noteFetch(of: 0)
        // First seek: nothing in flight → taken at once.
        coordinator.requestProduction(of: 20)
        #expect(coordinator.takeAnchorRequest() == 20)
        // Burst while segment 20 has not landed: held, not restarted.
        coordinator.requestProduction(of: 23)
        #expect(coordinator.takeAnchorRequest() == nil)
        coordinator.requestProduction(of: 27)
        #expect(coordinator.takeAnchorRequest() == nil)
        try await Task.sleep(for: DemandCoordinator.anchorDebounce + .milliseconds(20))
        // Settled: the newest is what production goes to.
        #expect(coordinator.takeAnchorRequest() == 27)
        // With the re-anchor's first segment landed, a fresh request is immediate.
        coordinator.setProducing(index: 28)
        coordinator.requestProduction(of: 3)
        #expect(coordinator.takeAnchorRequest() == 3)
        // A forced request (a lazy rendition joining) is never held.
        coordinator.requestProduction(of: 3, force: true)
        #expect(coordinator.takeAnchorRequestDetailed()?.forced == true)
    }

    // MARK: - F2 discontinuity

    @Test("A discontinuous request inside the forward-wait window re-anchors; continuous read-ahead still waits")
    func discontinuousRequestReanchors() {
        let coordinator = DemandCoordinator()
        coordinator.publish(plan: plan(40))
        coordinator.setProducing(index: 10)
        // Read-ahead: 9 served, then 10 and 11 miss — continuous, wait.
        coordinator.noteFetch(of: 9)
        coordinator.noteFetch(of: 10)
        coordinator.requestProduction(of: 10)
        #expect(coordinator.takeAnchorRequest() == nil)
        coordinator.noteFetch(of: 11)
        coordinator.requestProduction(of: 11)
        #expect(coordinator.takeAnchorRequest() == nil)
        // The rendition's fetch of the same index is continuous too.
        coordinator.noteFetch(of: 11)
        coordinator.requestProduction(of: 11)
        #expect(coordinator.takeAnchorRequest() == nil)
        // A short forward seek: from 11 to 12 is ±1 (continuous); from 4 to
        // 12 is a jump — inside the window (10...12) but a seek all the same.
        coordinator.noteFetch(of: 4)
        coordinator.noteFetch(of: 12)
        coordinator.requestProduction(of: 12)
        #expect(coordinator.takeAnchorRequest() == 12)
    }

    // MARK: - F3 lead in seconds

    @Test("The lead cap is seconds of content from the plan, not a segment count")
    func leadIsSeconds() {
        // 2 s segments: ten of them are 20 s — under the cap, no park.
        let short = DemandCoordinator()
        short.publish(plan: plan(60, stride: 2000))
        short.noteFetch(of: 0)
        let group = DispatchGroup()
        group.enter()
        Thread {
            short.parkWhileAhead(producing: 12, isCancelled: { false })
            group.leave()
        }.start()
        #expect(group.wait(timeout: .now() + 1) == .success, "24 s of lead must not park")
        // 12 s segments: three of them are 36 s — parks, released by demand.
        let long = DemandCoordinator()
        long.publish(plan: plan(60, stride: 12000))
        long.noteFetch(of: 0)
        let parked = DispatchGroup()
        parked.enter()
        Thread {
            long.parkWhileAhead(producing: 3, isCancelled: { false })
            parked.leave()
        }.start()
        #expect(parked.wait(timeout: .now() + 0.3) == .timedOut, "36 s of lead must park")
        long.noteFetch(of: 1)
        #expect(parked.wait(timeout: .now() + 1) == .success)
    }

    // MARK: - F4 serve path

    @Test("Init, media and vtt are immutable-cacheable; playlists never; bytes and length unchanged with the two-send response")
    func cacheHeadersAndTwoSends() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let playlist = Data("#EXTM3U\n#EXT-X-VERSION:7\n".utf8)
        let media = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try playlist.write(to: root.appendingPathComponent("index.m3u8"))
        try media.write(to: root.appendingPathComponent("seg00000.m4s"))
        try Data("moov".utf8).write(to: root.appendingPathComponent("init.mp4"))
        try Data("WEBVTT\n".utf8).write(to: root.appendingPathComponent("seg00000.vtt"))

        let server = LoopbackHTTPServer(root: root)
        let base = try await server.start()
        defer { Task { await server.stop() } }

        func fetch(_ name: String) async throws -> (Data, HTTPURLResponse) {
            let (data, response) = try await URLSession.uncached.data(from: base.appendingPathComponent(name))
            return (data, try #require(response as? HTTPURLResponse))
        }
        let (playlistData, playlistResponse) = try await fetch("index.m3u8")
        #expect(playlistData == playlist)
        #expect(playlistResponse.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        let (mediaData, mediaResponse) = try await fetch("seg00000.m4s")
        #expect(mediaData == media)
        #expect(mediaResponse.value(forHTTPHeaderField: "Content-Length") == "\(media.count)")
        #expect(mediaResponse.value(forHTTPHeaderField: "Cache-Control") == "max-age=86400, immutable")
        let (_, initResponse) = try await fetch("init.mp4")
        #expect(initResponse.value(forHTTPHeaderField: "Cache-Control") == "max-age=86400, immutable")
        let (_, vttResponse) = try await fetch("seg00000.vtt")
        #expect(vttResponse.value(forHTTPHeaderField: "Cache-Control") == "max-age=86400, immutable")
        // HEAD: header only, length of the body it would have sent.
        var head = URLRequest(url: base.appendingPathComponent("seg00000.m4s"))
        head.httpMethod = "HEAD"
        let (headBody, headResponse) = try await URLSession.uncached.data(for: head)
        #expect(headBody.isEmpty)
        #expect((headResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length") == "\(media.count)")
    }

    // MARK: - F5 hot loop

    @Test("The pointer NAL rewrite produces byte-identical output to the array shape")
    func pointerRewriteMatchesArrayShape() throws {
        // Three NALs: an SPS (33), an `unspec63` EL unit on layer 0, an RPU (62)
        // — the real P7 shape. This used to use a LAYER-1 unit and call that the
        // P7 shape, which it is not: an interleaved P7 stream puts the EL, the RPU
        // and the base layer all on layer 0.
        func nal(type: UInt8, layer: UInt8, payload: [UInt8]) -> [UInt8] {
            let header0 = (type << 1) | (layer >> 5)
            let header1 = (layer & 0x1F) << 3 | 1
            let body = [header0, header1] + payload
            let length = body.count
            return [UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)] + body
        }
        let packet = nal(type: 33, layer: 0, payload: [1, 2, 3, 4, 5])
            + nal(type: 63, layer: 0, payload: Array(repeating: 9, count: 300))
            + nal(type: 62, layer: 0, payload: [7, 7, 7])
        let transform: (HEVCNALUnits.Unit) -> HEVCNALUnits.Disposition = { unit in
            if DolbyVisionRPUConverter.isEnhancementLayer(type: unit.type, layerID: unit.layerID) {
                return .drop
            }
            if unit.type == 62 { return .replace([0x7C, 0x01, 0xAA, 0xBB, 0xCC, 0xDD]) }
            return .keep
        }
        let arrayShape = try #require(HEVCNALUnits.rewrite(packet, lengthSize: 4, transform: transform))
        // Owns its scratch for the whole call: returning
        // `pointerShape.withUnsafeMutableBufferPointer { $0.baseAddress }` hands
        // back a pointer valid only inside that closure, and the copy loop
        // writes through it afterwards — the same undefined behaviour the array
        // overload itself was carrying.
        var pointerShape: [UInt8] = []
        var scratch: UnsafeMutablePointer<UInt8>?
        var scratchCount = 0
        defer { scratch?.deallocate() }
        let written = packet.withUnsafeBufferPointer { buffer in
            HEVCNALUnits.rewrite(buffer, lengthSize: 4, transform: transform) { size in
                let allocation = UnsafeMutablePointer<UInt8>.allocate(capacity: max(size, 1))
                scratch = allocation
                scratchCount = size
                return allocation
            }
        }
        if let scratch {
            pointerShape = [UInt8](UnsafeBufferPointer(start: scratch, count: scratchCount))
        }
        #expect(written)
        #expect(pointerShape == arrayShape)
        // Expected by hand: SPS kept, EL dropped, RPU replaced by 6 bytes.
        #expect(arrayShape == nal(type: 33, layer: 0, payload: [1, 2, 3, 4, 5]) + [0, 0, 0, 6, 0x7C, 0x01, 0xAA, 0xBB, 0xCC, 0xDD])
        // Nothing to change: no allocation, no output.
        var allocated = false
        let unchanged = packet.withUnsafeBufferPointer { buffer in
            HEVCNALUnits.rewrite(buffer, lengthSize: 4, transform: { _ in .keep }) { _ in allocated = true; return nil }
        }
        #expect(!unchanged && !allocated)
        // The Atmos sniff's pointer shape agrees with the array shape on a
        // frame that is not E-AC-3 at all (nil) and on the fuzz seed corpus.
        let junk: [UInt8] = [0x0B, 0x77, 0, 0, 0, 0, 0, 0]
        #expect(EAC3Syncframe.atmosComplexityIndex(in: junk) == junk.withUnsafeBufferPointer { EAC3Syncframe.atmosComplexityIndex(in: $0) })
    }

    @Test("BridgeClock.reset re-anchors on the next frame instead of counting a gap")
    func clockReset() {
        var clock = BridgeClock(sampleRate: 48_000, gapTolerance: 4_800)
        clock.observe(framePTS: 1_000_000, frameSamples: 1536, fifoDepth: 0)
        #expect(clock.stamp(1536) == 1_000_000)
        clock.reset()
        // A seek lands 30 s earlier: the reset clock anchors there, where an
        // un-reset one would have seen a gap and re-anchored anyway — the
        // reset is what makes the "continuous" case honest after a jump.
        clock.observe(framePTS: 400_000, frameSamples: 1536, fifoDepth: 0)
        #expect(clock.stamp(1536) == 400_000)
        var chunker = FrameChunker(frameSize: 1536, padsFinalFrame: true)
        chunker.appended(2000)
        chunker.reset()
        #expect(chunker.nextFullChunk() == nil)
    }

    // MARK: - F6 playlist

    @Test("The append-only EVENT playlist writes the same text as a full rebuild")
    func appendOnlyPlaylistText() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = MediaPlaylistWriter(directory: root)
        try writer.appendSegment(duration: 2.0, file: "seg00000.m4s")
        try writer.appendSegment(duration: 6.04, file: "seg00001.m4s")
        try writer.appendSegment(duration: 7.2, file: "seg00002.m4s")
        try writer.finish()
        let text = try String(contentsOf: root.appendingPathComponent("index.m3u8"), encoding: .utf8)
        #expect(text == """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:8
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:EVENT
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:2.00000,
        seg00000.m4s
        #EXTINF:6.04000,
        seg00001.m4s
        #EXTINF:7.20000,
        seg00002.m4s
        #EXT-X-ENDLIST

        """)
    }
}
