import Foundation
import Libavformat

/// The wall-clock guard a context's blocking reads run under — installed at
/// open time, armed only around the operations that deserve a deadline.
///
/// The placement is the entire point. FFmpeg's read path checks
/// `URLContext.interrupt_callback` (`libavformat/avio.c:515`), which is copied
/// from the format context **when the URLContext is created during
/// `avformat_open_input`** (`avio.c:189`). A callback set on the
/// `AVFormatContext` afterwards reaches only the few call sites that consult
/// `s->interrupt_callback` directly — not the blocking reads, which is where a
/// stall actually sits. 1.1.1 made exactly that mistake: its bounded
/// index-load seek installed the guard post-open and never bounded anything
/// (issue #39). So the guard now exists *before* the open, permanently, and
/// stays disarmed until someone has a deadline to enforce.
///
/// Disarmed is the resting state on purpose: the callback runs on every
/// blocking read for the context's whole life, including hours of normal
/// production reads, and must never abort those.
///
/// **Lifetime**: the callback holds an *unretained* pointer to this object, so
/// whoever owns the context must keep its guard alive until the context is
/// closed — `ProbedSource` stores it next to the context and the remuxer keeps
/// it for the span of `run()`.
final class ReadInterruptGuard: @unchecked Sendable {

    private let lock = NSLock()
    private var deadline: ContinuousClock.Instant?
    private var cancelled = false
    private var httpInput: HTTPRangeInput?
    var usesCoordinatedHTTP: Bool { httpInput != nil }
    /// The host-supplied input this context reads through, when there is one.
    /// Held here for the same reason `httpInput` is: the avio callbacks carry
    /// an unretained pointer, so the adapter must live exactly as long as the
    /// context — and the guard already has that lifetime by contract.
    private var customInput: CustomInput?
    /// The same input again, when it can be released from another thread.
    ///
    /// Kept apart from `customInput` on purpose: this one is the *capability*,
    /// and the engine has to be able to tell the difference. A host read that
    /// FFmpeg cannot poll its way out of is only reachable through here, so an
    /// input that is absent from this slot is an input the guard can bound on
    /// paper and not in fact — which is worth knowing at install time rather
    /// than an hour later, when a thread is already wedged.
    private var interruptibleInput: (any CancellablePrismCoreInput)?
    /// The pending "your deadline just passed" call, so a disarm or a re-arm
    /// can take it back.
    private var expiryNotice: DispatchWorkItem?

    /// Whether this guard's host input can be released mid-read. `false` also
    /// when there is no host input at all — FFmpeg's own I/O is interruptible
    /// by the callback and needs nothing from here.
    var inputIsInterruptible: Bool { lock.withLock { interruptibleInput != nil } }

    /// Where the deadline notices fire. One queue for the whole process: the
    /// work item is a single call into the host and there is at most one live
    /// per guard, so a serial queue costs nothing and keeps the ordering
    /// obvious.
    private static let expiryQueue = DispatchQueue(
        label: "cz.zmrhal.prismcore.read-deadline", qos: .userInitiated
    )

    /// Stop everything this guard bounds, now.
    ///
    /// Two things happen, and the second is the one that matters for a host
    /// input: the flag makes every subsequent poll answer "abort", and the
    /// host is told to let go of the read it is *currently* inside. Without
    /// that second half the flag reaches nobody until the host's own transport
    /// times out — which on an SMB share that went away is minutes, and on a
    /// stalled debrid session is never (see `CancellablePrismCoreInput`).
    func cancel() {
        let input: (any CancellablePrismCoreInput)? = lock.withLock {
            cancelled = true
            return interruptibleInput
        }
        // Outside the lock: the host's hook is not ours to hold a lock across,
        // and it may well run on the same object its reader is using.
        input?.cancelInFlightOperation()
    }

    /// The host's own error behind the last negative avio return code, when a
    /// custom input produced one. Callers use it to re-throw something typed
    /// instead of handing on FFmpeg's `-EIO`.
    var customInputFailure: (any Error)? { customInput?.failure }

    /// Install a host-supplied input on `context`, taking ONE instance from
    /// `factory` for this open (see `PrismCoreInputFactory` on why the
    /// factory, not an instance).
    ///
    /// Throws `PrismCoreInputError.notSeekable` before touching the context
    /// when the input has no length: every engine path that reaches here needs
    /// to seek, and what a length-less one produces instead is a session that
    /// publishes a plan it cannot serve — see `CustomInput` for the measured
    /// shape of that failure.
    func installCustomInput(
        on context: UnsafeMutablePointer<AVFormatContext>,
        factory: PrismCoreInputFactory
    ) throws {
        let input = try factory()
        guard input.length != nil else { throw PrismCoreInputError.notSeekable }
        let adapter = CustomInput(input: input, interrupted: { [weak self] in
            self?.shouldInterrupt ?? true
        })
        try adapter.install(on: context)
        let cancellable = input as? any CancellablePrismCoreInput
        let liveDeadline: ContinuousClock.Instant? = lock.withLock {
            customInput = adapter
            interruptibleInput = cancellable
            return deadline
        }
        if cancellable == nil {
            // Said once, at the only moment the engine can still tell the
            // difference cheaply. A wedge is silent by nature — a thread that
            // never comes back raises nothing — so this line is the whole
            // difference between "the host's input cannot be interrupted" and
            // an unexplained hang in a field report.
            PrismCoreLog.notice(
                "host input does not conform to CancellablePrismCoreInput: "
                + "a blocked read cannot be interrupted, so a read budget bounds "
                + "only the gaps between reads and stop() may have to detach its producer"
            )
        } else if let liveDeadline {
            // Armed before the input was installed. Nothing does that today,
            // but a budget that silently bounds nothing is exactly the bug
            // this guard exists to prevent, so the ordering is not left to
            // luck.
            scheduleExpiryNotice(at: liveDeadline)
        }
    }

    /// What the origin last said, when this context reads over the coordinated
    /// HTTP input — the classification an FFmpeg code cannot carry (the reader
    /// can only answer libavformat in errno). A failing open or read asks for
    /// this *first*: it outranks the libav* code, because when both exist the
    /// code is the consequence (`-EIO`, or the `AVERROR_EXIT` of a budget that
    /// expired while the origin was busy throttling us) and this is the cause.
    var originFailure: PrismCoreError? { httpInput?.lastOriginFailure }

    func installHTTPInput(on context: UnsafeMutablePointer<AVFormatContext>, url: URL,
                          headers: [String: String]) throws {
        let input = HTTPRangeInput(url: url, headers: headers, interrupted: { [weak self] in
            self?.shouldInterrupt ?? true
        })
        try input.install(on: context)
        httpInput = input
    }

    /// Start enforcing: reads abort (`AVERROR_EXIT`) once `budget` has passed.
    func arm(budget: Duration) {
        let expiry = ContinuousClock.now + budget
        let stale: DispatchWorkItem? = lock.withLock {
            deadline = expiry
            defer { expiryNotice = nil }
            return expiryNotice
        }
        stale?.cancel()
        scheduleExpiryNotice(at: expiry)
    }

    /// Stop enforcing. Reads that already aborted stay aborted — the latched
    /// `AVIOContext.error` is the arming caller's to clear (see
    /// `SegmentPlan.build`).
    func disarm() {
        let stale: DispatchWorkItem? = lock.withLock {
            deadline = nil
            defer { expiryNotice = nil }
            return expiryNotice
        }
        stale?.cancel()
    }

    /// A deadline that merely passes wakes nobody.
    ///
    /// `shouldInterrupt` is a poll, and the only thing that polls it is FFmpeg
    /// — between reads. For libavformat's own I/O that is enough, and nothing
    /// about it changes here. For a host input it is not: the thread is inside
    /// `read(into:)` and will not ask again until it comes back, which is the
    /// very thing the budget was supposed to bound. So an armed guard with an
    /// interruptible host input also schedules a timer, and the timer is what
    /// actually delivers the expiry.
    ///
    /// Scheduled only when there is a host that can listen — FFmpeg's own
    /// reads gain nothing from a timer and every arm is on a hot path (a
    /// thumbnail seek arms per scrub).
    private func scheduleExpiryNotice(at expiry: ContinuousClock.Instant) {
        guard inputIsInterruptible else { return }
        let notice = DispatchWorkItem { [weak self] in self?.announceExpiry(of: expiry) }
        lock.withLock { expiryNotice = notice }
        let remaining = max(0, ContinuousClock.now.duration(to: expiry).seconds)
        Self.expiryQueue.asyncAfter(deadline: .now() + remaining, execute: notice)
    }

    private func announceExpiry(of expiry: ContinuousClock.Instant) {
        let input: (any CancellablePrismCoreInput)? = lock.withLock {
            // Only if THIS deadline is still the live one. A disarm or a
            // re-arm in between means the bounded operation finished (or was
            // re-bounded), and interrupting a host read on a budget nobody is
            // enforcing any more would abort healthy production.
            guard deadline == expiry else { return nil }
            expiryNotice = nil
            return interruptibleInput
        }
        input?.cancelInFlightOperation()
    }

    var shouldInterrupt: Bool {
        lock.withLock { cancelled || (deadline.map { ContinuousClock.now >= $0 } ?? false) }
    }

    /// The C-visible callback. Static so its address is stable; it reaches the
    /// guard through the opaque pointer, on whatever thread is doing the read.
    private static let cCallback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { opaque in
        guard let opaque else { return 0 }
        let guardBox = Unmanaged<ReadInterruptGuard>.fromOpaque(opaque).takeUnretainedValue()
        return guardBox.shouldInterrupt ? 1 : 0
    }

    /// An allocated `AVFormatContext` with this guard already installed —
    /// the only shape `avformat_open_input` can be handed that gets the
    /// callback onto the URLContext. `nil` only on allocation failure, which
    /// the caller treats exactly like a failed open.
    func makeContext() -> UnsafeMutablePointer<AVFormatContext>? {
        guard let context = avformat_alloc_context() else { return nil }
        context.pointee.interrupt_callback = AVIOInterruptCB(
            callback: Self.cCallback,
            opaque: Unmanaged.passUnretained(self).toOpaque()
        )
        return context
    }
}

extension Duration {
    /// `Duration` as seconds, for the two places that have to hand a deadline
    /// to GCD — which speaks `DispatchTimeInterval` and knows nothing about
    /// `Duration`. Lossy past nanoseconds, which no timeout here cares about.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
