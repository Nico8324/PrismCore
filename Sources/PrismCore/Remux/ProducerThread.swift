import Foundation

/// One remux running on a thread of its own, with an `async` way to wait for it.
///
/// `HLSRemuxer.run()` is synchronous by design: it blocks in FFmpeg reads for as
/// long as production takes, and parks at EOF for the rest of the session. Run
/// on a `Task.detached` it therefore occupies one thread of the global
/// cooperative pool permanently — a quarter of an Apple TV's pool for the length
/// of a film, and, with several sessions alive at once, enough parked producers
/// to saturate the pool outright. The async work that would release them
/// (`stop()`, a demand fetch) then has nowhere to run, which is exactly the
/// deadlock the suite hit on 2026-08-10 (#44).
///
/// So the producer gets a real thread. Nothing here is a general-purpose task
/// primitive — it does what a blocking producer needs and no more: carry the
/// thrown error out, and let an actor `await` the exit without blocking.
final class ProducerThread: @unchecked Sendable {

    /// Guards `finished`, `failure` and `waiters`, and is what a `join` sleeps
    /// on when the body is still running.
    private let lock = NSLock()
    private var finished = false
    private var failure: (any Error)?
    /// Keyed, not an array, because a bounded `join` has to be able to take
    /// its OWN continuation back when its grace runs out without disturbing
    /// anybody else waiting on the same thread.
    private var waiters: [Int: CheckedContinuation<Bool, Never>] = [:]
    private var nextWaiterToken = 0

    /// Where a bounded join's grace expires. Not `Task.sleep`: the whole point
    /// of the bound is that it fires even when the caller's cooperative pool
    /// is the thing under pressure.
    private static let graceQueue = DispatchQueue(
        label: "cz.zmrhal.prismcore.producer-join", qos: .userInitiated
    )

    /// Starts `body` immediately on a new thread named `name`.
    init(name: String, body: @escaping @Sendable () throws -> Void) {
        let thread = Thread { [self] in
            var thrown: (any Error)?
            do {
                try body()
            } catch {
                thrown = error
            }
            finish(with: thrown)
        }
        thread.name = name
        // The producer feeds a playing AVPlayer; it is as user-initiated as the
        // work gets. Not `.userInteractive` — nothing here draws.
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Whether the body has returned (or thrown).
    var isFinished: Bool { lock.withLock { finished } }

    /// The error the body threw, once it has finished. `nil` while it runs and
    /// after a clean exit.
    var failureIfAny: (any Error)? { lock.withLock { failure } }

    /// Suspend until the body exits. Resumes immediately if it already has.
    ///
    /// Nothing here cancels the body — the caller is expected to have asked it
    /// to stop first (`HLSRemuxer.cancel()`), exactly as it had to with the task
    /// this replaced: a `Task.cancel()` never interrupted a blocking FFmpeg read
    /// either.
    func join() async {
        _ = await join(within: nil)
    }

    /// Suspend until the body exits, or until `grace` has passed — `false`
    /// means it is **still running** and the caller has to decide what to do
    /// about that.
    ///
    /// `nil` waits forever, which is the plain `join()`.
    ///
    /// The bound exists because "ask it to stop and then wait" is only a
    /// teardown as long as the body can hear the ask. A producer blocked
    /// inside a host's synchronous `read` cannot, unless the host conforms to
    /// `CancellablePrismCoreInput` — and a host that does not must not be able
    /// to freeze the app that is merely leaving the player.
    @discardableResult
    func join(within grace: Duration?) async -> Bool {
        await withCheckedContinuation { continuation in
            var token = 0
            let alreadyFinished: Bool = lock.withLock {
                if finished { return true }
                token = nextWaiterToken
                nextWaiterToken += 1
                waiters[token] = continuation
                return false
            }
            if alreadyFinished { continuation.resume(returning: true); return }
            guard let grace else { return }
            let expiring = token
            Self.graceQueue.asyncAfter(deadline: .now() + max(0, grace.seconds)) { [self] in
                // Whoever removes the continuation from the table owns it —
                // that is what keeps the expiry and a body finishing at the
                // same instant from resuming it twice.
                let timedOut = lock.withLock { waiters.removeValue(forKey: expiring) }
                timedOut?.resume(returning: false)
            }
        }
    }

    private func finish(with error: (any Error)?) {
        let toResume: [CheckedContinuation<Bool, Never>] = lock.withLock {
            finished = true
            failure = error
            defer { waiters = [:] }
            return Array(waiters.values)
        }
        // Resumed outside the lock: a continuation may run its awaiting code
        // synchronously, and that code is entitled to call back in here.
        for continuation in toResume { continuation.resume(returning: true) }
    }
}
