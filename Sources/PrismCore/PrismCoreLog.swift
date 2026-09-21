import Foundation
import os

/// The one place the engine says something out loud.
///
/// PrismCore is a library living inside someone else's app, so it does not
/// print and it does not own a log file: notices go to the unified log under
/// the host's own process, where a field report picks them up with
///
/// ```
/// log show --predicate 'subsystem == "cz.zmrhal.prismcore"' --last 10m
/// ```
///
/// Reserved for the handful of moments a host cannot otherwise see: a
/// capability the input does NOT have, and a teardown that had to give up on a
/// thread. Everything routine belongs in the return values.
enum PrismCoreLog {

    static let subsystem = "cz.zmrhal.prismcore"

    private static let logger = Logger(subsystem: subsystem, category: "engine")

    private static let observerLock = NSLock()
    nonisolated(unsafe) private static var storedObserver: (@Sendable (String) -> Void)?

    /// A second destination for notices, for tests only.
    ///
    /// The messages worth logging here mark a *path* — the engine noticing it
    /// cannot interrupt this input, `stop()` deciding to detach — and a path a
    /// test cannot observe is a path that silently stops being taken. The
    /// unified log cannot be read back in-process, so the test reads here.
    static var observer: (@Sendable (String) -> Void)? {
        get { observerLock.withLock { storedObserver } }
        set { observerLock.withLock { storedObserver = newValue } }
    }

    static func notice(_ message: String) {
        // `.public`: nothing logged through here carries user data — no paths,
        // no URLs, no tokens — and a redacted breadcrumb is not a breadcrumb.
        logger.notice("\(message, privacy: .public)")
        observer?(message)
    }
}
