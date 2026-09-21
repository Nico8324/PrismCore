import Foundation

/// The demand-driven session's provider: serve from disk when the file
/// exists, and otherwise turn the request into production intent — ask the
/// coordinator to (re-)anchor the producer at the requested segment and hand
/// the server a `.pending` that resolves when the file lands.
///
/// The server's slow-serve machinery (early 200 + chunked past 2 s) is what
/// makes waiting safe against AVPlayer's ~3.5 s header watchdog; this type
/// only decides WHAT to wait for.
struct PlanSegmentProvider: SegmentProvider {

    let root: URL
    let coordinator: DemandCoordinator
    /// How long a pending serve may wait for the producer before aborting the
    /// connection (truncated transfer → AVPlayer retries). A re-anchor is a
    /// demuxer seek + fresh muxers — seconds, not minutes.
    var productionTimeout: Duration = .seconds(15)
    /// How long a subtitle segment may wait. Shorter than a media segment's
    /// window: the cues arrive when the segment carrying them is cut, so if that
    /// hasn't happened by now the producer went somewhere else entirely and
    /// waiting longer buys nothing.
    var subtitleProductionTimeout: Duration = .seconds(8)

    private let directory: DirectorySegmentProvider
    /// The producer's "a file landed" broadcast. A pending serve sleeps on
    /// it instead of polling the path; `nil` (tests that build the provider
    /// bare) leaves only the backstop poll, which is correct, just slower.
    private let landed: ProductionSignal?

    /// Consulted on every subtitle-segment fetch, BEFORE the disk read — this
    /// is what lazily arms OCR bitmap renditions (the fetch is the demand),
    /// and what catches a file that exists but is stale: cut while the track
    /// was unarmed, header-only, and wrong to serve because AVPlayer caches
    /// segments forever.
    var subtitleDemand: (@Sendable (String) -> SubtitleRenditionSet.DemandVerdict)?

    /// Consulted on every fetch under an `audioN/` directory, BEFORE the disk
    /// read — the seam that arms a lazy (dialogue-boost) rendition. Returns
    /// `true` when THIS fetch armed it, in which case production is
    /// re-anchored — forced, so it happens even inside the forward-wait
    /// window — at the demanded segment (or the one being produced, for an
    /// init fetch), so the rendition's first segment is a whole one. A fetch
    /// of an armed or eager rendition returns `false` and changes nothing.
    var audioDemand: (@Sendable (String) -> Bool)?

    /// Consulted before every media-segment disk read: is this index's file
    /// stale output — muxed with an audio offset the producer has since
    /// abandoned?
    ///
    /// Retirement has to reach the serving path through the store rather than
    /// through the filesystem, because the two are not in step: the producer
    /// retires the whole cache in one step at the re-anchor and the files are
    /// unlinked afterwards on a background queue. A host that does what the
    /// API documents — watch `pendingAudioDelaySeconds`, refresh the player
    /// when it clears — fetches inside exactly that gap, and used to get the
    /// old offset served as a hit (and cached by AVPlayer past the deletion).
    ///
    /// A superseded index reads as a miss, not a 404: `handleMiss` asks the
    /// producer to re-anchor there and waits for the rewritten file, so the
    /// segment stays reproducible on demand like any evicted one.
    var isSuperseded: (@Sendable (Int) -> Bool)?

    init(root: URL, coordinator: DemandCoordinator, landed: ProductionSignal? = nil) {
        self.root = root
        self.coordinator = coordinator
        self.directory = DirectorySegmentProvider(root: root)
        self.landed = landed
    }

    /// How long a pending serve sleeps between disk checks when no broadcast
    /// wakes it. A backstop, not the mechanism: every producer write is
    /// followed by a broadcast, so this only bounds the damage of a landing
    /// nobody announced. Coarse on purpose — at 10 ms it WAS the mechanism,
    /// and a poll on the seek path is latency by definition.
    static let backstopPoll: Duration = .milliseconds(200)

    func data(forPath path: String) async -> ProviderResult {
        if path.hasSuffix(".vtt"), subtitleDemand?(path) == .regenerate {
            // The stale file is already deleted (the demand call does it), so
            // the wait below resolves on the re-produced segment. The
            // re-anchor must come from THIS fetch: the media segment of the
            // same index is long cached, AVPlayer will never re-fetch it, so
            // no other request is coming to move the producer.
            if let index = Self.vttSegmentIndex(inPath: path) {
                coordinator.requestProduction(of: index)
            }
            return .pending(
                waitForFile(
                    path: path,
                    timeout: subtitleProductionTimeout,
                    onTimeout: .data(Self.emptyWebVTT, contentType: "text/vtt")
                )
            )
        }
        // Every media-segment fetch — hit or miss — is a playhead sighting:
        // it is what the producer's lead cap paces itself against. Reported
        // before the disk read so a parked producer wakes even when the serve
        // itself is instant.
        if let index = Self.segmentIndex(inPath: path) {
            coordinator.noteFetch(of: index)
        }
        // An init or segment fetch under `audioN/` is the demand that arms a
        // lazy rendition — not the playlist fetch, which AVPlayer makes for
        // renditions it never plays. Lazy renditions exist only in the
        // planned shape (see `HLSRemuxer`), so the plan is always there to
        // re-anchor against.
        if path.hasPrefix("audio"), path.hasSuffix(".m4s") || path.hasSuffix("init.mp4"),
           audioDemand?(path) == true,
           let anchor = Self.segmentIndex(inPath: path) ?? coordinator.armAnchorIndex {
            coordinator.requestProduction(of: anchor, force: true)
        }
        if let index = Self.segmentIndex(inPath: path), isSuperseded?(index) == true {
            return await handleMiss(path: path)
        }
        let direct = await directory.data(forPath: path)
        if case .notFound = direct {
            return await handleMiss(path: path)
        }
        return direct
    }

    private func handleMiss(path: String) async -> ProviderResult {
        guard coordinator.publishedPlan != nil else { return .notFound }
        // A slot production declared empty: waiting would only stall the
        // rendition for the whole pending window before the same 404.
        if coordinator.isUnproducible(path: path) { return .notFound }

        // Unproduced planned artifacts by shape:
        if let index = Self.segmentIndex(inPath: path) {
            coordinator.requestProduction(of: index)
            // Protected from HERE, not from when the wait's closure runs: a
            // queued pending leaves a gap in which production could land the
            // segment and retention evict it again (issue #43). The matching
            // `endServing` sits in the wait itself.
            coordinator.beginServing(index: index)
            return .pending(waitForFile(path: path, servingIndex: index))
        }
        if path.hasSuffix("init.mp4") {
            // The init exists after the producer's first cut wherever it is
            // anchored — no re-anchor needed, just patience.
            return .pending(waitForFile(path: path))
        }
        if path.hasSuffix(".vtt") {
            // A subtitle segment for a range nobody has demuxed yet. Serving the
            // empty segment immediately is safe but wrong in the common case: the
            // fetch that arrives with it is AVPlayer asking for the *media*
            // segment of the same index, which re-anchors the producer, and the
            // cues land the moment that segment is cut — a second or two away.
            // AVPlayer caches segments and never re-fetches, so answering empty
            // straight away is what made subtitles resume only from the segment
            // AFTER a seek.
            //
            // So wait, then degrade. Unlike a media segment, a subtitle segment
            // that never arrives must not abort the connection: empty cues are a
            // far better outcome than a failed rendition.
            return .pending(
                waitForFile(
                    path: path,
                    timeout: subtitleProductionTimeout,
                    onTimeout: .data(Self.emptyWebVTT, contentType: "text/vtt")
                )
            )
        }
        return .notFound
    }

    /// `seg%05d.m4s` anywhere under the root (variant or `audioN/`) → index.
    static func segmentIndex(inPath path: String) -> Int? {
        let name = (path as NSString).lastPathComponent
        guard name.hasPrefix("seg"), name.hasSuffix(".m4s") else { return nil }
        return Int(name.dropFirst(3).dropLast(4))
    }

    /// `seg%05d.vtt` under a rendition directory → index. Same shape as the
    /// media parser; kept separate so a `.vtt` never re-anchors through the
    /// media branch by accident.
    static func vttSegmentIndex(inPath path: String) -> Int? {
        let name = (path as NSString).lastPathComponent
        guard name.hasPrefix("seg"), name.hasSuffix(".vtt") else { return nil }
        return Int(name.dropFirst(3).dropLast(4))
    }

    /// A header-only WebVTT segment: valid, parseable, no cues.
    static let emptyWebVTT = Data("WEBVTT\n\n".utf8)

    /// - Parameters:
    ///   - onTimeout: what to answer when the file never lands.
    ///     `.notFound` aborts the connection, which is right for media (a truncated
    ///     transfer makes AVPlayer retry) and wrong for subtitles.
    ///   - servingIndex: the planned segment index this wait serves, when the
    ///     caller already told the coordinator via `beginServing` — every exit
    ///     of the wait balances it, so the eviction protection lasts exactly
    ///     as long as the file can still be needed off disk.
    private func waitForFile(
        path: String,
        timeout: Duration? = nil,
        onTimeout: ProviderResult = .notFound,
        servingIndex: Int? = nil
    ) -> PendingResult {
        let fileURL = root.appendingPathComponent(path)
        let contentType = LoopbackHTTPServer.contentType(for: fileURL)
        let timeout = timeout ?? productionTimeout
        let coordinator = self.coordinator
        let landed = self.landed
        // The file this wait is waiting for may still be the superseded one:
        // the unlink is asynchronous, so "it exists" is not "it is the right
        // bytes" until the store says the index has been rewritten.
        let isSuperseded = self.isSuperseded
        let supersededIndex = Self.segmentIndex(inPath: path)
        return PendingResult {
            defer {
                if let servingIndex { coordinator.endServing(index: servingIndex) }
            }
            // Clock starts when the SERVE runs, not when the miss was seen —
            // a queued pending must get its full window.
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while ContinuousClock.now < deadline {
                // Snapshot BEFORE the disk check: a broadcast between the
                // check and the wait then makes the wait return at once,
                // instead of being lost to a waiter that was not yet asleep.
                let generation = landed?.currentGeneration
                let stale = supersededIndex.map { isSuperseded?($0) == true } ?? false
                if !stale, let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) {
                    return .data(data, contentType: contentType)
                }
                // The slot may have been declared empty AFTER this serve went
                // pending (the cut that decides it runs later than the miss);
                // without this re-check the loop would sleep out the whole
                // window for a file production has said is not coming.
                if coordinator.isUnproducible(path: path) { return onTimeout }
                // This wait sits on the SEEK path: a demand fetch is answered
                // the moment the produced file lands, plus whatever sits
                // here. It used to be a 10 ms poll, which alone contributed
                // more to seek latency than a warm segment's production did;
                // now the producer's broadcast is the wake and the poll is
                // only the backstop.
                if let landed, let generation {
                    await landed.wait(after: generation, backstop: Self.backstopPoll)
                } else {
                    try? await Task.sleep(for: Self.backstopPoll)
                }
            }
            return onTimeout
        }
    }
}
