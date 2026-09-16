import Foundation
import Libavformat

/// A source that has been opened and read once, holding both the answer
/// (`info`) and the **open context that produced it**.
///
/// A playback used to open its source twice: the host probes to decide how to
/// play, then the remuxer opens again to produce. Over a network that second
/// open is a real round trip and a real download — measured at a median of
/// 54 ms even capped, on a link with no latency at all — and it happens inside
/// the wait a user is watching.
///
/// The tempting shortcut is to keep the first open's *conclusions* and let the
/// second context skip its analysis. That was tried in 1.1.2 and reverted:
/// `avformat_find_stream_info` also fills fields the **muxer** needs (an EAC3
/// track's frame size, most sharply), so a context that never ran it produces
/// a correct-looking manifest and a failing `av_interleaved_write_frame`. The
/// analysis isn't redundant knowledge — it is state that lives in the context.
///
/// So the context itself moves. `consumeContext()` hands it over exactly once;
/// whoever takes it owns closing it, and a `ProbedSource` that is never
/// consumed (the host declined the source, or never started a session) closes
/// its own on the way out.
///
/// **Threading**: an `AVFormatContext` is not safe for concurrent use, and this
/// deliberately does not make it so. The handover is a *move* across threads —
/// the probing side must be finished with it, which consuming it exactly once
/// enforces structurally — not a share.
/// The probe's cost, phase by phase. Each phase blocks on the transport, so
/// on a network source these are transport numbers, not CPU numbers.
public struct ProbeTiming: Sendable, Equatable {
    /// `avformat_open_input`: connect + container header.
    public let open: Duration
    /// `avformat_find_stream_info`: the bounded stream analysis.
    public let streamInfo: Duration
    /// Per-stream description, including the interlace verification when it
    /// ran — the phase that DECODES, so a declared-interlaced H.264 source
    /// pays for real packets here.
    public let describe: Duration

    public var total: Duration { open + streamInfo + describe }
}

public final class ProbedSource: @unchecked Sendable {

    /// What the probe found. Safe to read after the context has been consumed:
    /// it is a value, copied out at probe time.
    public let info: SourceInfo

    /// The source this describes, so a consumer that needs to re-open (a
    /// fallback session, whose context was already taken) knows what to open.
    public let url: URL
    let httpHeaders: [String: String]
    /// The host-supplied byte source this was probed through, when there was
    /// one — travelling for the same reason the headers do: whoever re-opens
    /// (the remuxer whose adopted context was already consumed, a muxed
    /// fallback session) has to reach the same bytes, and only the host can
    /// produce them. It is a FACTORY, so each of those opens gets its own
    /// cursor.
    let inputFactory: PrismCoreInputFactory?

    /// The interrupt guard the context was OPENED with — the callback is
    /// baked into the URLContext at creation and cannot be added later (issue
    /// #39), so it travels with the context. Whoever adopts the context arms
    /// this to bound a read; the guard object must stay alive until the
    /// context is closed, which holding it here (and the remuxer holding the
    /// whole `ProbedSource`) guarantees.
    let interruptGuard: ReadInterruptGuard

    /// Where the probe's time went — for the host's log line or telemetry.
    /// Exists because a 5.7 s probe on a device and a 135 ms probe on the
    /// bench were the same code, and without the phases there was nothing to
    /// argue about but intuition.
    public let timing: ProbeTiming

    private let lock = NSLock()
    private var context: UnsafeMutablePointer<AVFormatContext>?

    init(
        info: SourceInfo,
        url: URL,
        httpHeaders: [String: String],
        inputFactory: PrismCoreInputFactory? = nil,
        context: UnsafeMutablePointer<AVFormatContext>,
        interruptGuard: ReadInterruptGuard,
        timing: ProbeTiming
    ) {
        self.info = info
        self.url = url
        self.httpHeaders = httpHeaders
        self.inputFactory = inputFactory
        self.context = context
        self.interruptGuard = interruptGuard
        self.timing = timing
    }

    /// Take the open context, transferring ownership. Returns `nil` on every
    /// call after the first — a context cannot be handed to two producers, and
    /// a caller that gets `nil` must open its own.
    ///
    /// The position is **not** rewound here: the probe left it wherever its
    /// reads ended (the interlace verification decodes a handful of frames),
    /// and only the new owner knows where it wants to start. Adopting code
    /// seeks.
    func consumeContext() -> UnsafeMutablePointer<AVFormatContext>? {
        lock.withLock {
            defer { context = nil }
            return context
        }
    }

    /// Whether the context is still here — a source that was probed and then
    /// declined still holds one until it is released.
    var holdsContext: Bool { lock.withLock { context != nil } }

    /// The context WITHOUT consuming it — for tests that need to move its
    /// read position before a session adopts it. Never for production code:
    /// the whole point of `consumeContext` is that the handover is a move.
    func peekContextForTesting() -> UnsafeMutablePointer<AVFormatContext>? {
        lock.withLock { context }
    }

    deinit {
        // Nobody took it: the probe was for a routing decision that went
        // elsewhere. Closing here is what keeps a declined probe from leaking
        // a connection.
        if let context {
            var closing: UnsafeMutablePointer<AVFormatContext>? = context
            avformat_close_input(&closing)
        }
    }
}
