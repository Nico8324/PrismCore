import Testing
import Foundation
import AVFoundation
@testable import PrismCore

/// Phase 5 end to end: a plannable VOD source gets its COMPLETE playlist
/// upfront, and fetching a segment the producer hasn't reached yet re-anchors
/// it there instead of waiting for sequential production to arrive.
///
/// The fixture (`h264_aac_30s.mkv`) is synthetic — 30 s of testsrc2 + sine
/// with a fixed 2 s keyframe cadence (`g=48` at 24 fps), so the Matroska Cues
/// pass both plan witnesses and the planned boundaries sit on real keyframes.
@Suite("Demand-driven production", .serialized)
struct DemandDrivenTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    private func fetch(_ url: URL) async throws -> (data: Data, status: Int) {
        let (data, response) = try await URLSession.uncached.data(from: url)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// The variant playlist behind whatever `start()` returned (master or not).
    private func variantURL(playlist: URL) async throws -> URL {
        let (data, _) = try await fetch(playlist)
        let text = String(decoding: data, as: UTF8.self)
        guard text.contains("#EXT-X-STREAM-INF") else { return playlist }
        let variant = try #require(PrismCoreSession.playlistURIs(inMaster: text).last)
        return playlist.deletingLastPathComponent().appendingPathComponent(variant)
    }

    // MARK: - Coordinator unit behaviour

    @Test("Requests inside the forward-wait window do not re-anchor; outside, last one wins")
    func coordinatorWindow() {
        let coordinator = DemandCoordinator()
        coordinator.publish(plan: SegmentPlan(
            entries: (0..<10).map { .init(startPTS: Int64($0) * 6000, duration: 6.0) },
            basis: .keyframeIndex,
            timeBaseNum: 1,
            timeBaseDen: 1000
        ))
        coordinator.setProducing(index: 2)

        // Within [2, 2+window]: the producer gets there on its own.
        coordinator.requestProduction(of: 3)
        #expect(coordinator.takeAnchorRequest() == nil)

        // Beyond it: a real seek.
        coordinator.requestProduction(of: 8)
        coordinator.requestProduction(of: 5)   // playhead moved again — last wins
        #expect(coordinator.takeAnchorRequest() == 5)
        #expect(coordinator.takeAnchorRequest() == nil)   // consumed

        // Backwards is always a re-anchor.
        // The re-anchor to 5 landed its first segment (production moved on),
        // so the next request is not debounced as part of a scrub burst.
        coordinator.setProducing(index: 6)
        coordinator.requestProduction(of: 0)
        #expect(coordinator.takeAnchorRequest() == 0)
    }

    @Test("A demand miss protects its index from the moment of the miss until the serve exits")
    func demandProtectionLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreDemand-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let coordinator = DemandCoordinator()
        coordinator.publish(plan: SegmentPlan(
            entries: (0..<10).map { .init(startPTS: Int64($0) * 6000, duration: 6.0) },
            basis: .keyframeIndex,
            timeBaseNum: 1,
            timeBaseDen: 1000
        ))
        let provider = PlanSegmentProvider(root: root, coordinator: coordinator)

        // The miss itself must install the protection — before the pending's
        // closure ever runs, or eviction can strike in the queue gap.
        let result = await provider.data(forPath: "seg00007.m4s")
        guard case .pending(let pending) = result else {
            Issue.record("expected a pending serve for a planned miss")
            return
        }
        #expect(coordinator.demandProtectedIndexes == [7])

        // Refcounted: the audio rendition's fetch of the same index stacks.
        let audioResult = await provider.data(forPath: "audio0/seg00007.m4s")
        guard case .pending(let audioPending) = audioResult else {
            Issue.record("expected a pending serve for the rendition miss")
            return
        }
        #expect(coordinator.demandProtectedIndexes == [7])

        // Production lands the file; both serves resolve and the protection
        // drops only when the LAST one exits.
        let payload = Data("moof-payload".utf8)
        try payload.write(to: root.appendingPathComponent("seg00007.m4s"))
        guard case .data(let served, _) = await pending.resolve() else {
            Issue.record("the landed file did not serve")
            return
        }
        #expect(served == payload)
        #expect(coordinator.demandProtectedIndexes == [7])

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("audio0"), withIntermediateDirectories: true
        )
        try payload.write(to: root.appendingPathComponent("audio0/seg00007.m4s"))
        _ = await audioPending.resolve()
        #expect(coordinator.demandProtectedIndexes.isEmpty)
    }

    @Test("Planned segment paths parse to indices; everything else does not")
    func segmentPathParsing() {
        #expect(PlanSegmentProvider.segmentIndex(inPath: "seg00004.m4s") == 4)
        #expect(PlanSegmentProvider.segmentIndex(inPath: "audio0/seg00012.m4s") == 12)
        #expect(PlanSegmentProvider.segmentIndex(inPath: "init.mp4") == nil)
        #expect(PlanSegmentProvider.segmentIndex(inPath: "subs0/seg00001.vtt") == nil)
        #expect(PlanSegmentProvider.segmentIndex(inPath: "index.m3u8") == nil)
    }

    // MARK: - End to end

    @Test("A plannable source publishes complete VOD playlists before production finishes")
    func plannedVODPlaylistUpfront() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac_30s.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        // Immediately after readiness — long before a 30 s remux completes —
        // the variant playlist is already a finished VOD listing every
        // planned segment.
        let variant = try await variantURL(playlist: playlist)
        let (data, _) = try await fetch(variant)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        #expect(text.contains("#EXT-X-ENDLIST"))

        let segments = text.split(separator: "\n").filter { $0.hasSuffix(".m4s") }
        // 30 s at 6 s targets on a 2 s keyframe grid → 5 segments.
        #expect(segments.count >= 4 && segments.count <= 6)

        // EXTINF durations must sum to (roughly) the container duration —
        // the promise a seek relies on.
        let total = text.split(separator: "\n")
            .filter { $0.hasPrefix("#EXTINF:") }
            .compactMap { Double($0.dropFirst(8).dropLast()) }
            .reduce(0, +)
        #expect(abs(total - 30.0) < 2.0)

        // The audio rendition's planned playlist agrees segment for segment.
        let base = variant.deletingLastPathComponent()
        let (audioData, _) = try await fetch(base.appendingPathComponent("audio0/index.m3u8"))
        let audioText = String(decoding: audioData, as: UTF8.self)
        #expect(audioText.contains("#EXT-X-ENDLIST"))
        let audioSegments = audioText.split(separator: "\n").filter { $0.hasSuffix(".m4s") }
        #expect(audioSegments.count == segments.count)
    }

    @Test("Fetching a not-yet-produced segment re-anchors the producer and serves it")
    func seekAheadProducesOnDemand() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac_30s.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        let variant = try await variantURL(playlist: playlist)
        let base = variant.deletingLastPathComponent()
        let (data, _) = try await fetch(variant)
        let text = String(decoding: data, as: UTF8.self)
        let segments = text.split(separator: "\n").filter { $0.hasSuffix(".m4s") }
        let last = try #require(segments.last.map(String.init))

        // The LAST planned segment, demanded right after startup: sequential
        // production can't be there yet, so this serve only succeeds if the
        // provider re-anchored the producer to it (a pending serve that waits
        // for the file). moof+mdat proves it's a real fragment, not filler.
        let (media, status) = try await fetch(base.appendingPathComponent(last))
        #expect(status == 200)
        #expect(media.count > 1_000)
        #expect(media.range(of: Data("moof".utf8)) != nil)
        #expect(media.range(of: Data("mdat".utf8)) != nil)

        // The matching audio rendition segment comes off the same re-anchored
        // producer run.
        let audioLast = last   // same numbering across renditions by design
        let (audio, audioStatus) = try await fetch(base.appendingPathComponent("audio0/\(audioLast)"))
        #expect(audioStatus == 200)
        #expect(audio.range(of: Data("mdat".utf8)) != nil)

        // And a jump BACK still works — the head segment may or may not have
        // been produced before the re-anchor; either way it must serve.
        let first = try #require(segments.first.map(String.init))
        let (headMedia, headStatus) = try await fetch(base.appendingPathComponent(first))
        #expect(headStatus == 200)
        #expect(headMedia.range(of: Data("moof".utf8)) != nil)
    }

    @Test("A segment skipped by a re-anchor is produced even after the producer hit EOF")
    func postEOFBackwardDemand() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac_30s.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        let variant = try await variantURL(playlist: playlist)
        let base = variant.deletingLastPathComponent()
        let (data, _) = try await fetch(variant)
        let segments = String(decoding: data, as: UTF8.self)
            .split(separator: "\n").filter { $0.hasSuffix(".m4s") }.map(String.init)

        // Jump straight to the end: the re-anchor skips the middle, and the
        // producer then runs off the EOF cliff…
        _ = try await fetch(base.appendingPathComponent(try #require(segments.last)))
        try await Task.sleep(for: .milliseconds(500))

        // …where it must be PARKED, not gone: a seek back into the skipped
        // middle still has to produce a real fragment.
        let middle = segments[segments.count / 2]
        let (media, status) = try await fetch(base.appendingPathComponent(middle))
        #expect(status == 200)
        #expect(media.range(of: Data("moof".utf8)) != nil)
        #expect(media.range(of: Data("mdat".utf8)) != nil)
    }

    @Test("AVPlayer seeks into unproduced territory and keeps playing there")
    func avPlayerSeek() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac_30s.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        let item = AVPlayerItem(url: playlist)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true

        let readyDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        while item.status != .readyToPlay {
            if item.status == .failed || ContinuousClock.now >= readyDeadline {
                Issue.record("item never became ready (error: \(String(describing: item.error)))")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        player.play()
        // Deep into the plan — far past anything sequential production could
        // have reached at readiness. The fetches this triggers only succeed
        // through the demand path.
        await player.seek(to: CMTime(seconds: 24, preferredTimescale: 600))

        var reached = false
        let playDeadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < playDeadline {
            if item.status == .failed { break }
            if player.currentTime().seconds >= 24.5 { reached = true; break }
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(reached, "playhead never crossed the seek target (error: \(String(describing: item.error)))")
    }

    @Test("A short source (no plan needed) still finishes exactly as before")
    func shortSourceStillSequential() async throws {
        // The 8 s fixture also plans fine — what this really guards is that
        // the planned path's EOF tail produces the final segment and the
        // playlist arithmetic stays coherent end to end.
        let session = try PrismCoreSession(url: try fixture("h264_aac.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        let variant = try await variantURL(playlist: playlist)
        // Poll until every listed segment actually exists and serves.
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var served = false
        while ContinuousClock.now < deadline, !served {
            let (data, _) = try await fetch(variant)
            let text = String(decoding: data, as: UTF8.self)
            let segments = text.split(separator: "\n").filter { $0.hasSuffix(".m4s") }
            guard text.contains("#EXT-X-ENDLIST"), !segments.isEmpty else {
                try await Task.sleep(for: .milliseconds(200))
                continue
            }
            served = true
            for segment in segments {
                let (media, status) = try await fetch(
                    variant.deletingLastPathComponent().appendingPathComponent(String(segment))
                )
                #expect(status == 200)
                #expect(!media.isEmpty)
            }
        }
        #expect(served)
    }
}

// MARK: - Subtitle segments for unproduced ranges

@Suite("Planned subtitle serves")
struct PlannedSubtitleServeTests {

    private func plannedCoordinator() -> DemandCoordinator {
        let coordinator = DemandCoordinator()
        coordinator.publish(plan: SegmentPlan(
            entries: (0..<10).map { .init(startPTS: Int64($0) * 6000, duration: 6.0) },
            basis: .keyframeIndex,
            timeBaseNum: 1,
            timeBaseDen: 1000
        ))
        return coordinator
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("a subtitle segment that lands while we wait is served with its cues")
    func waitsForCuesRatherThanAnsweringEmpty() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("subs0"), withIntermediateDirectories: true
        )
        let provider = PlanSegmentProvider(root: root, coordinator: plannedCoordinator())

        // The producer cuts the segment shortly after the fetch arrives — which
        // is the ordinary case on a seek, since the media fetch for the same
        // index is what re-anchored it.
        let cued = "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n\n00:00:01.000 --> 00:00:02.000\nAhoj\n"
        let writer = Task {
            try? await Task.sleep(for: .milliseconds(300))
            try? Data(cued.utf8).write(
                to: root.appendingPathComponent("subs0/seg00004.vtt"), options: .atomic
            )
        }
        defer { writer.cancel() }

        let result = await provider.data(forPath: "subs0/seg00004.vtt")
        guard case .pending(let pending) = result else {
            Issue.record("an unproduced subtitle segment must wait, not answer immediately")
            return
        }
        guard case .data(let data, let contentType) = await pending.resolve() else {
            Issue.record("the produced segment should have been served")
            return
        }
        #expect(String(decoding: data, as: UTF8.self).contains("Ahoj"))
        #expect(contentType == "text/vtt")
    }

    @Test("a subtitle segment that never lands degrades to empty cues, not a failure")
    func degradesToEmptySegment() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var provider = PlanSegmentProvider(root: root, coordinator: plannedCoordinator())
        // The real window is 8 s; shortening it keeps the suite quick without
        // changing which branch is taken.
        provider.subtitleProductionTimeout = .milliseconds(200)

        let result = await provider.data(forPath: "subs0/seg00004.vtt")
        guard case .pending(let pending) = result else {
            Issue.record("expected a pending serve")
            return
        }
        // Empty is the only acceptable degradation: aborting the connection
        // (.notFound) would fail the whole subtitle rendition.
        guard case .data(let data, let contentType) = await pending.resolve() else {
            Issue.record("a timed-out subtitle serve must still answer with a valid segment")
            return
        }
        #expect(String(decoding: data, as: UTF8.self) == "WEBVTT\n\n")
        #expect(contentType == "text/vtt")
    }

    @Test("without a published plan nothing is invented — a missing .vtt is a miss")
    func noPlanNoFabrication() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = PlanSegmentProvider(root: root, coordinator: DemandCoordinator())
        guard case .notFound = await provider.data(forPath: "subs0/seg00004.vtt") else {
            Issue.record("a sequential session has no planned segments to stand in for")
            return
        }
    }
}

/// The producer's park: a thread that is asleep on the coordinator rather than
/// polling, and gets woken by the fetch that needs it (#44).
@Suite("Parked producer")
struct ParkedProducerTests {

    /// Long enough that a wake can only have come from a signal — the
    /// coordinator's own backstop is a full second.
    ///
    /// A computed property, not a `let`: a `DispatchTime` is an **absolute**
    /// instant, and a stored one is evaluated once when the type is first
    /// touched. That deadline then ages — in a full-suite run these tests may
    /// start seconds later, by which point every `wait(timeout:)` on it
    /// returns `.timedOut` before the park has had a chance to do anything,
    /// and the failure reads as a lost signal rather than as a stopwatch that
    /// was started in another test.
    private static var signalWindow: DispatchTime { .now() + .milliseconds(500) }

    /// Parks a thread on `coordinator` and hands back a semaphore that is
    /// signalled when the park returns.
    private func park(
        on coordinator: DemandCoordinator,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> DispatchSemaphore {
        let returned = DispatchSemaphore(value: 0)
        let thread = Thread {
            coordinator.waitForAnchorRequest(isCancelled: isCancelled)
            returned.signal()
        }
        thread.start()
        return returned
    }

    @Test("A demand fetch wakes the parked producer immediately")
    func requestWakesThePark() throws {
        let coordinator = DemandCoordinator()
        let returned = park(on: coordinator)

        // No handshake needed before requesting: the park re-checks the pending
        // request under the same lock the request is set behind, so a request
        // that arrives before the wait is entered is seen, not missed.
        coordinator.requestProduction(of: 7)

        #expect(returned.wait(timeout: Self.signalWindow) == .success)
        #expect(coordinator.takeAnchorRequest() == 7)
    }

    @Test("Cancellation releases the park with no anchor to offer")
    func cancellationReleasesThePark() throws {
        let coordinator = DemandCoordinator()
        let cancelled = LockedFlag()
        let returned = park(on: coordinator, isCancelled: { cancelled.isSet })

        // The order `HLSRemuxer.cancel()` uses, and the order that makes this
        // race-free: the flag first, the wake second. A park that hasn't
        // reached the wait yet sees the flag and never sleeps; one already
        // asleep is woken. A `wake()` on its own guarantees neither — a
        // condition signal with no state change behind it can be lost, which
        // is why nothing calls it that way.
        cancelled.set()
        coordinator.wake()

        #expect(returned.wait(timeout: Self.signalWindow) == .success)
        #expect(coordinator.takeAnchorRequest() == nil)
    }

    @Test("A producer already told to stop never parks at all")
    func cancelledProducerDoesNotPark() throws {
        let coordinator = DemandCoordinator()
        let returned = park(on: coordinator, isCancelled: { true })
        #expect(returned.wait(timeout: Self.signalWindow) == .success)
    }

    @Test("A producer thread carries its failure out and releases every joiner")
    func producerThreadReportsFailure() async throws {
        struct Boom: Error {}
        let producer = ProducerThread(name: "prismcore.tests.producer") { throw Boom() }
        await producer.join()
        #expect(producer.isFinished)
        #expect(producer.failureIfAny is Boom)
        // A join after the fact resumes rather than hanging — the session's
        // stop() takes exactly this path when the remux already ended.
        await producer.join()
    }
}

/// The producer's lead cap: production pauses when it has run
/// `producerLeadSegments` past the last fetched segment, so retention's
/// "farthest from the producer" policy keeps meaning "farthest from the
/// playhead". Without it a fast source lets the producer sprint to EOF and
/// eviction deletes the segments AVPlayer is about to ask for.
@Suite("Producer lead cap")
struct ProducerLeadCapTests {

    /// Long enough that a return can only have come from a signal — the
    /// coordinator's own backstop is a full second.
    private var signalWindow: DispatchTime { .now() + .milliseconds(500) }
    /// Long enough to prove the park is holding, short enough not to drag the
    /// suite: a wrongly-released park signals within microseconds.
    private var stillParkedWindow: DispatchTime { .now() + .milliseconds(150) }

    /// Parks a thread on the lead cap and hands back a semaphore that is
    /// signalled when the park returns.
    private func park(
        on coordinator: DemandCoordinator,
        producing: Int,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> DispatchSemaphore {
        let returned = DispatchSemaphore(value: 0)
        let thread = Thread {
            coordinator.parkWhileAhead(producing: producing, isCancelled: isCancelled)
            returned.signal()
        }
        thread.start()
        return returned
    }

    /// The lead cap in segments, at the nominal 6 s stride a plan-less
    /// coordinator paces on (the cap itself is expressed in seconds).
    private var leadSegments: Int { Int(DemandCoordinator.producerLeadSeconds / 6) }

    @Test("Before the first fetch the producer never parks — startup must produce")
    func startupDoesNotPark() {
        let coordinator = DemandCoordinator()
        let returned = park(on: coordinator, producing: 100)
        #expect(returned.wait(timeout: signalWindow) == .success)
    }

    @Test("Within the lead window the producer sails through")
    func withinWindowDoesNotPark() {
        let coordinator = DemandCoordinator()
        coordinator.noteFetch(of: 5)
        let returned = park(
            on: coordinator,
            producing: 5 + leadSegments
        )
        #expect(returned.wait(timeout: signalWindow) == .success)
    }

    @Test("Past the window the producer parks, and a catching-up fetch releases it")
    func fetchReleasesThePark() {
        let coordinator = DemandCoordinator()
        coordinator.noteFetch(of: 0)
        let producing = leadSegments + 5
        let returned = park(on: coordinator, producing: producing)

        // A fetch that does NOT close the gap keeps the park holding.
        coordinator.noteFetch(of: 2)
        #expect(returned.wait(timeout: stillParkedWindow) == .timedOut)

        coordinator.noteFetch(of: 5)
        #expect(returned.wait(timeout: signalWindow) == .success)
    }

    @Test("An anchor request releases the lead-cap park for the per-packet check")
    func anchorRequestReleasesThePark() {
        let coordinator = DemandCoordinator()
        coordinator.noteFetch(of: 0)
        let returned = park(
            on: coordinator,
            producing: leadSegments + 5
        )
        coordinator.requestProduction(of: 40)
        #expect(returned.wait(timeout: signalWindow) == .success)
        #expect(coordinator.takeAnchorRequest() == 40)
    }

    @Test("Cancellation releases the lead-cap park")
    func cancellationReleasesThePark() {
        let coordinator = DemandCoordinator()
        coordinator.noteFetch(of: 0)
        let cancelled = LockedFlag()
        let returned = park(
            on: coordinator,
            producing: leadSegments + 5,
            isCancelled: { cancelled.isSet }
        )
        cancelled.set()
        coordinator.wake()
        #expect(returned.wait(timeout: signalWindow) == .success)
    }
}
