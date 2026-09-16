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
    func cancel() { lock.withLock { cancelled = true } }
    private var httpInput: HTTPRangeInput?
    var usesCoordinatedHTTP: Bool { httpInput != nil }
    /// The host-supplied input this context reads through, when there is one.
    /// Held here for the same reason `httpInput` is: the avio callbacks carry
    /// an unretained pointer, so the adapter must live exactly as long as the
    /// context — and the guard already has that lifetime by contract.
    private var customInput: CustomInput?

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
        customInput = adapter
    }

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
        lock.withLock { deadline = .now + budget }
    }

    /// Stop enforcing. Reads that already aborted stay aborted — the latched
    /// `AVIOContext.error` is the arming caller's to clear (see
    /// `SegmentPlan.build`).
    func disarm() {
        lock.withLock { deadline = nil }
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
