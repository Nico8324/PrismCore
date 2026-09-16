import Foundation

/// The meeting point of the demand-driven session (phase 5): the loopback's
/// provider reports which planned segment AVPlayer just asked for, and the
/// producer polls for anchor requests it should jump to.
///
/// Deliberately dumb and lock-based — both sides touch it from tight loops
/// (the producer once per packet, the provider once per request), so it holds
/// no async machinery of its own. The FILE SYSTEM stays the single source of
/// truth for "does segment N exist"; this type only carries intent.
///
/// The lock is an `NSCondition` because the producer has one state where it has
/// nothing to poll for: parked at EOF, waiting for a seek to ask for a segment
/// it skipped. It sleeps on this condition and a `requestProduction` wakes it —
/// no interval, so the first hop of a cold seek's latency is gone rather than
/// merely short (#44).
final class DemandCoordinator: @unchecked Sendable {

    private let lock = NSCondition()
    private var plan: SegmentPlan?
    private var requestedAnchor: Int?
    /// Set with `requestedAnchor` when the request must be honoured even at
    /// the index production is already on: a lazy rendition was just armed,
    /// and the muxers have to be rebuilt at a boundary for it to join with a
    /// whole first segment. Consumed together with the anchor.
    private var anchorIsForced = false
    /// When the current `requestedAnchor` was made, for the scrub debounce.
    private var requestedAt: ContinuousClock.Instant?
    /// A re-anchor the producer took whose first segment has not landed yet
    /// (cleared by `setProducing` moving on). While one is in flight, a
    /// request younger than `anchorDebounce` is held back: a scrub bar
    /// drags out a burst of fetches, and honouring each one tore the muxers
    /// down several times to produce nothing. The newest still wins — it is
    /// what the burst settles on.
    private var reanchorInFlight: Int?
    static let anchorDebounce: Duration = .milliseconds(150)
    /// The producer's current position: the segment it is producing now.
    /// `-1` until production starts.
    private var producingIndex = -1
    /// Segment indexes with an outstanding demand serve, refcounted — the
    /// variant and each rendition of the same index arrive as separate
    /// fetches. Retention consults this set so it never evicts a segment the
    /// provider is still waiting to read off disk (issue #43): production can
    /// run several segments past a just-reproduced one before the provider's
    /// poll notices the file, and "farthest from the producer" is then exactly
    /// the segment that was demanded.
    private var outstandingServes: [Int: Int] = [:]
    /// Root-relative paths production has declared it will never write — a
    /// rendition boundary that carried no audio. Consulted only on a MISS,
    /// so a later re-anchor that does produce the file is served normally.
    private var unproduciblePaths: Set<String> = []

    /// How far ahead of the producer a request may point and still be worth
    /// WAITING for instead of re-anchoring. Two segments ≈ 12 s of content —
    /// AVPlayer's normal read-ahead lands inside it. A request inside the
    /// window still re-anchors when it is DISCONTINUOUS with the fetch
    /// history (see `requestProduction`): a short forward seek used to wait
    /// out two whole segments of serial production because it happened to
    /// be numerically close.
    static let forwardWaitWindow = 2

    /// The newest segment index the provider has served or been asked for —
    /// the closest thing to a playhead the engine can see. `-1` until the
    /// first media fetch, which is also what lets startup produce freely.
    private var lastDemandedIndex = -1
    /// The one before it — what a new request is judged continuous against.
    /// `noteFetch` runs before the miss handling, so by the time a request
    /// is made `lastDemandedIndex` already IS the request.
    private var previousDemandedIndex = -1

    /// How far past the last demanded segment the producer may run before it
    /// parks, in seconds of content. Thirty seconds: comfortably more than
    /// AVPlayer's forward read-ahead, comfortably less than the retention
    /// budget — which is the point. An uncapped producer sprints to EOF on a
    /// fast source, and retention's "farthest from the producer" then evicts
    /// the segments *nearest the playhead*: every ~20 s AVPlayer asks for a
    /// file that was just deleted, re-anchors the producer back, and playback
    /// hitches for the length of a demuxer seek. The cap keeps the producer
    /// trailing the playhead, which is the assumption retention was written
    /// against. Seconds rather than a segment count (it was ten segments)
    /// because segments vary — a 2 s head, keyframe-stretched entries — and
    /// the buffer AVPlayer cares about is time.
    static let producerLeadSeconds = 30.0
    /// The sequential shape has no plan to read durations from; its
    /// `segmentSeconds` stands in (set by the producer).
    var nominalSegmentSeconds = 6.0

    // MARK: - Producer side

    /// Publish the plan once the producer has built it. Until this, requests
    /// are served from disk only (no pending, no re-anchoring).
    func publish(plan: SegmentPlan) {
        lock.withLock { self.plan = plan }
    }

    func setProducing(index: Int) {
        lock.withLock {
            // Moving past the re-anchored index means its first segment
            // landed: the debounce no longer holds requests back.
            if let inFlight = reanchorInFlight, index != inFlight { reanchorInFlight = nil }
            producingIndex = index
        }
    }

    /// The pending anchor request, consumed. The producer calls this once per
    /// packet; a nil answer is the hot path.
    func takeAnchorRequest() -> Int? {
        takeAnchorRequestDetailed()?.index
    }

    /// Whether the pending request may be handed out now: always, unless a
    /// re-anchor is in flight (its first segment not landed) and this request
    /// is younger than the debounce — the shape of a scrub burst, where the
    /// next request is about to replace this one anyway. A forced request is
    /// never held (a lazy rendition joining has nothing to coalesce with).
    private func anchorIsDue(now: ContinuousClock.Instant) -> Bool {
        guard let requestedAt, reanchorInFlight != nil, !anchorIsForced else { return true }
        return now - requestedAt >= Self.anchorDebounce
    }

    /// The pending anchor request with its force flag, consumed — the copy
    /// loop's variant of `takeAnchorRequest`, which ignores a request for the
    /// index it is already producing unless `forced` says the muxers must be
    /// rebuilt anyway (a lazy rendition joining).
    func takeAnchorRequestDetailed() -> (index: Int, forced: Bool)? {
        lock.withLock {
            guard let anchor = requestedAnchor, anchorIsDue(now: .now) else { return nil }
            defer { requestedAnchor = nil; anchorIsForced = false; requestedAt = nil }
            reanchorInFlight = anchor
            return (anchor, anchorIsForced)
        }
    }

    /// Park the calling thread until an anchor request is pending or
    /// `isCancelled` turns true. **Blocks a real thread** — only the producer's
    /// own thread may call it, never a cooperative-pool one.
    ///
    /// The timed wait is a backstop, not the mechanism: `requestProduction` and
    /// `wake` both signal, so an ordinary seek returns immediately. It exists so
    /// that no missed signal can strand a producer forever — the cost of being
    /// wrong is one wasted loop per second, and the cost of not having it is a
    /// session that never tears down.
    func waitForAnchorRequest(isCancelled: () -> Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard requestedAnchor == nil || !anchorIsDue(now: .now), !isCancelled() else { return }
        // A held-back request (debounce) is re-checked when it comes due, not
        // after the whole backstop.
        let wait = requestedAnchor == nil ? Self.parkBackstopSeconds : Self.anchorDebounce / .seconds(1)
        lock.wait(until: Date(timeIntervalSinceNow: wait))
    }

    /// Where a lazy rendition's arming re-anchors to when the fetch that
    /// armed it named no segment (an `init.mp4` fetch): the newest demanded
    /// index — the closest thing to the playhead, and where the rendition's
    /// own segment fetches are about to start — else the segment being
    /// produced; `nil` before production started. The rebuilt muxers restart
    /// that segment from its boundary, so the new rendition's first file is
    /// whole and the abandoned partial fragment was never on disk anyway.
    var armAnchorIndex: Int? {
        lock.withLock {
            if lastDemandedIndex >= 0 { return lastDemandedIndex }
            return producingIndex >= 0 ? producingIndex : nil
        }
    }

    /// Park the calling thread while the producer is more than
    /// `producerLeadSegments` ahead of the last demanded segment. Same
    /// contract as `waitForAnchorRequest`: **blocks a real thread**, producer's
    /// own thread only. Returns as soon as demand catches up, an anchor
    /// request lands (the copy loop's per-packet check will take it), or the
    /// session is cancelled; the timed wait is only the missed-signal backstop.
    ///
    /// A `lastDemandedIndex` of `-1` (nothing fetched yet) never parks:
    /// startup must produce the first segments before AVPlayer has anything
    /// to ask for. A demand *behind* the producer — a backward seek being
    /// replayed from disk — parks too: the files are already there, and the
    /// right move is to wait for the playhead to catch up, not to produce on.
    func parkWhileAhead(producing: Int, isCancelled: () -> Bool) {
        lock.lock()
        defer { lock.unlock() }
        while requestedAnchor == nil, !isCancelled(), lastDemandedIndex >= 0,
              leadSeconds(from: lastDemandedIndex, to: producing) > Self.producerLeadSeconds {
            lock.wait(until: Date(timeIntervalSinceNow: Self.parkBackstopSeconds))
        }
    }

    /// Content seconds between the start of segment `from` and the start of
    /// segment `to` — from the plan when there is one, else the nominal
    /// stride. Under the lock.
    private func leadSeconds(from: Int, to: Int) -> Double {
        guard to > from else { return 0 }
        if let plan, plan.entries.indices.contains(from), plan.timeBaseDen > 0 {
            let toPTS = plan.entries.indices.contains(to)
                ? plan.entries[to].startPTS
                : plan.entries[plan.entries.count - 1].startPTS
            return Double(toPTS - plan.entries[from].startPTS) * Double(plan.timeBaseNum) / Double(plan.timeBaseDen)
        }
        return Double(to - from) * nominalSegmentSeconds
    }

    /// `parkWhileAhead` for the sequential shape, whose provider serves hits
    /// (and reports them) but has no plan: the same cap, on the nominal
    /// stride, so a fast source no longer demuxes and writes the whole film
    /// while the viewer is on minute two. Same contract — producer's thread
    /// only. Never parks before the first fetch.
    func parkWhileAheadSequential(producing: Int, isCancelled: () -> Bool) {
        parkWhileAhead(producing: producing, isCancelled: isCancelled)
    }

    /// The newest demanded index, or `nil` before the first fetch — what
    /// sequential retention must never evict ahead of.
    var playheadIndex: Int? {
        lock.withLock { lastDemandedIndex >= 0 ? lastDemandedIndex : nil }
    }

    /// Wake every parked producer without offering it an anchor — what
    /// cancellation uses to get its thread back promptly.
    ///
    /// Only meaningful **after** the state the park re-checks has changed
    /// (`HLSRemuxer.cancel()` sets its flag first, then calls this). A condition
    /// signal with nothing behind it can be lost to a producer that has not yet
    /// reached its wait, and would then be waited out by the backstop instead.
    func wake() {
        lock.withLock { lock.broadcast() }
    }

    private static let parkBackstopSeconds: TimeInterval = 1

    /// The indexes retention must not evict right now. Snapshotted once per
    /// `record` call on the producer's thread — a Set copy under the same lock
    /// both sides already take, so the cost sits with eviction, not the
    /// per-packet hot path.
    var demandProtectedIndexes: Set<Int> {
        lock.withLock { Set(outstandingServes.keys) }
    }

    /// Production skipped `path` for good (planned rendition slot with no
    /// audio). A fetch of it answers 404 at once instead of waiting out the
    /// pending window for a file that is not coming.
    func markUnproducible(path: String) {
        lock.withLock { _ = unproduciblePaths.insert(path) }
    }

    /// Forget every "never coming" mark at once: the producer changed
    /// something that decides which slots carry audio at all (the audio
    /// offset), so each one has to be answered by production again.
    func clearUnproducible() {
        lock.withLock { unproduciblePaths.removeAll() }
    }

    func isUnproducible(path: String) -> Bool {
        lock.withLock { unproduciblePaths.contains(path) }
    }

    /// Production DID write `path` after all (a re-anchor landed on audio the
    /// first pass missed). Cleared so that, once retention evicts the file,
    /// the next miss re-anchors instead of answering a stale 404.
    func clearUnproducible(path: String) {
        lock.withLock { _ = unproduciblePaths.remove(path) }
    }

    // MARK: - Provider side

    /// The plan, if published.
    var publishedPlan: SegmentPlan? {
        lock.withLock { plan }
    }

    /// A media-segment fetch arrived — hit or miss. The newest fetch is where
    /// AVPlayer's read-ahead front is, so it moves `lastDemandedIndex` and
    /// wakes a producer parked on its lead cap.
    func noteFetch(of index: Int) {
        lock.withLock {
            if index != lastDemandedIndex {
                previousDemandedIndex = lastDemandedIndex
                lastDemandedIndex = index
            }
            lock.broadcast()
        }
    }

    /// A request for planned segment `index` arrived and its file doesn't
    /// exist. Decide whether the producer should jump: anything outside the
    /// forward-wait window re-anchors; inside it, the producer is about to
    /// make the segment anyway and a jump would only tear down its muxers.
    ///
    /// `force` skips the window AND the producer's "already there" check:
    /// used when a lazy rendition has just been armed, because its bridge
    /// can only join at a muxer rebuild, and the segment AVPlayer is asking
    /// for has to come out whole — even if production is on that very index.
    ///
    /// Inside the window the request still re-anchors when it is
    /// discontinuous with the fetch history: AVPlayer's read-ahead asks for
    /// N after N-1 (the variant and each rendition of one index arrive
    /// together, so ±1 of the previous fetch counts as continuous); a request
    /// that jumps further is a seek, however close it lands, and waiting for
    /// serial production to reach it was up to two segments of silence.
    func requestProduction(of index: Int, force: Bool = false) {
        lock.withLock {
            let current = producingIndex
            let continuous = previousDemandedIndex < 0 || abs(index - previousDemandedIndex) <= 1
            if !force, continuous, current >= 0, index >= current, index <= current + Self.forwardWaitWindow {
                return
            }
            // Last request wins: AVPlayer's newest fetch is where the
            // playhead actually is.
            requestedAnchor = index
            requestedAt = .now
            anchorIsForced = force || anchorIsForced
            // Signalled under the lock, so a producer that is between its
            // `requestedAnchor == nil` check and its `wait` cannot miss this.
            lock.broadcast()
        }
    }

    /// A demand serve of segment `index` starts waiting for its file. Must be
    /// balanced with `endServing` — the protection lasts exactly as long as
    /// the wait, and an unbalanced begin would pin the segment (and its bytes)
    /// against the budget forever.
    func beginServing(index: Int) {
        lock.withLock { outstandingServes[index, default: 0] += 1 }
    }

    /// The serve of segment `index` finished — served, timed out, or the
    /// connection died; every exit counts, only the refcount matters.
    func endServing(index: Int) {
        lock.withLock {
            guard let count = outstandingServes[index] else { return }
            if count > 1 {
                outstandingServes[index] = count - 1
            } else {
                outstandingServes.removeValue(forKey: index)
            }
        }
    }
}
