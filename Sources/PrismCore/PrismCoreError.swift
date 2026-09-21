import Foundation

/// Why a session failed, in terms a host can branch on.
///
/// Before this existed a host got `SessionError.startupTimedOut(underlying:)`
/// wrapping an `FFmpegError` whose only distinguishing feature was an English
/// string from libavformat — so "your token expired", "the server is throttling
/// us", "this file has no video" and "the disk is full" were all one failure
/// with four different remedies. Every case here is something the engine
/// **observed**; when it did not observe enough to tell two situations apart
/// they share one case rather than getting a guess each, because a host that
/// re-authenticates against a rate limit is worse off than one that saw
/// `.unknown` and retried.
///
/// Nothing throws this type in place of an existing error: `start()` still
/// throws `PrismCoreSession.SessionError`, the probe still throws
/// `SourceProbe.Failure`. `classify(_:)` turns any of them — including the
/// `AVPlayerItem.error` the host reads back out of AVFoundation — into this.
public enum PrismCoreError: Error, CustomStringConvertible {

    /// The origin answered, and the answer was "not for you": 401, 403, 407.
    /// An expired Plex token, a share whose link was revoked, a proxy wanting
    /// credentials. `status` is `nil` when the refusal arrived as a URLError
    /// rather than as a response we could read a code off.
    case originRefused(status: Int?, url: URL?)

    /// The origin answered, and the answer was "not now": 429, 503, 509.
    /// `retryAfter` is the origin's own `Retry-After`, in seconds, already
    /// resolved from either form (delta or HTTP date); `nil` means it did not
    /// say and the caller's own backoff applies.
    case originRateLimited(status: Int, retryAfter: TimeInterval?, url: URL?)

    /// The origin did not serve the bytes, and did not refuse us either: a
    /// dropped connection, a host that stopped resolving, a 404, a 5xx.
    ///
    /// This is also what "the origin vanished mid-session" looks like — and
    /// deliberately so, because at the failure site the two are the *same
    /// observation*. A connection reset on the first read and one on the
    /// thousandth carry identical evidence. The host already knows which it
    /// is, from whether `start()` had returned: a throw out of `start()` is
    /// an origin that was never usable, a `remuxFailure` appearing afterwards
    /// is one that went away. Claiming that distinction here would mean
    /// inferring it from state the error does not carry.
    case originUnreachable(status: Int?, url: URL?, underlying: (any Error)?)

    /// The container opened and was described, and it carries no video stream.
    /// An audio-only `.mka`, a cover-art-only container.
    ///
    /// Not "the probe failed" — that is `.unknown` or an origin case. This is
    /// only thrown after `avformat_find_stream_info` returned success and the
    /// stream list was walked, so it is a fact about the source rather than a
    /// fact about how far we got.
    case noVideoStream

    /// The container is readable and the video codec is known, but it cannot
    /// be stream-copied into HLS-fMP4 for `AVPlayer` (VP9, MPEG-2, VC-1, AV1
    /// on a device with no hardware decoder for it).
    ///
    /// Not the same as unplayable: `PrismCoreEngine.decide` routes exactly
    /// these sources to the software path. A host that reached this by
    /// building a `PrismCoreSession` directly should ask the engine instead of
    /// giving up.
    case videoCodecNotRemuxable(codecName: String, streamIndex: Int)

    /// The video codec cannot ride the fMP4 pipeline *and* this FFmpeg build
    /// has no decoder for it either — nothing in this engine can play it.
    /// Only the router proves this, because only the router consults
    /// `SoftwareDecoderAvailability`.
    case videoCodecUnplayable(codecName: String)

    /// The startup budget ran out with no playable playlist, and the remux
    /// left no error of its own — the source is being read, just not fast
    /// enough (a starving origin, a Matroska without Cues on a slow share).
    ///
    /// A startup that timed out *because* of something nameable does not land
    /// here: `classify(_:)` unwraps the underlying error first, so a 403
    /// during startup is `.originRefused`.
    case startupBudgetExpired

    /// `AVPlayer` refused the master playlist we served (see
    /// `MasterRejection` for the three codes and why they are what they are).
    /// The source was never the problem; the remedy is
    /// `makeMasterRejectionFallbackSession()`, not another engine.
    case masterRejectedByPlayer(underlying: any Error)

    /// A write into the session's work directory failed for want of space.
    case workDirectoryOutOfSpace(underlying: (any Error)?)

    /// A libav* call failed with a code we have no honest mapping for. The
    /// raw code and FFmpeg's own message are kept rather than flattened into
    /// `.unknown`, because they are what a bug report needs — and because the
    /// next real mapping will be found by reading these.
    case ffmpeg(code: Int32, operation: String, message: String)

    /// Something failed and the engine cannot say what. Honest, and on
    /// purpose: a misclassification costs a host a wrong remedy, `.unknown`
    /// costs it a generic one.
    case unknown(underlying: any Error)

    /// Whether an identical attempt, later, could plausibly succeed.
    ///
    /// Three-valued rather than `Bool` because for some failures the truthful
    /// answer is that this engine does not know, and a `Bool` would have to
    /// invent one. Each verdict is justified where it is returned.
    public enum Retryability: Sendable, Equatable {
        case retryable
        case permanent
        case unknown
    }

    public var retryability: Retryability {
        switch self {
        // The origin evaluated the request and rejected it. We would send the
        // same request, with the same credentials, and get the same answer.
        // Retrying is only right after the *host* changes something.
        case .originRefused: return .permanent

        // This is precisely what the status code means, and `retryAfter` is
        // the origin telling us when. The engine's own reader already acts on
        // it (`HTTPOriginCoordinator.refuse`).
        case .originRateLimited: return .retryable

        case .originUnreachable(let status, _, _):
            guard let status else {
                // No status: a transport failure. `HTTPRangeInput` already
                // retries these up to eight times before giving up, so the
                // engine's own behaviour asserts they are transient; a host
                // retry that also fails costs one more failure, not a wrong
                // remedy.
                return .retryable
            }
            // 404/410 and the other 4xx are the origin answering about *this*
            // request, which we cannot change. 5xx is the origin answering
            // about itself, which time can.
            return status >= 500 ? .retryable : .permanent

        // Facts about the bytes. The same source read again is the same source.
        case .noVideoStream, .videoCodecNotRemuxable, .videoCodecUnplayable:
            return .permanent

        // Retrying the identical session would be refused identically; the
        // useful move is a *different* session (`makeMasterRejectionFallback‑
        // Session()`), which is not what this flag is about.
        case .masterRejectedByPlayer: return .permanent

        // Genuinely unknown: a budget expires because of a slow network (which
        // improves), a cold cache (which warms), or a source that will never
        // produce a playlist (which does not). Nothing at the failure site
        // separates them, so nothing here pretends to.
        case .startupBudgetExpired: return .unknown

        // Whether space comes back is the host's business, not ours — we
        // neither own the volume nor know what else is on it.
        case .workDirectoryOutOfSpace: return .unknown

        case .ffmpeg, .unknown: return .unknown
        }
    }

    public var description: String {
        switch self {
        case .originRefused(let status, let url):
            return "origin refused the request\(status.map { " (HTTP \($0))" } ?? "")\(url.map { " — \($0.host ?? $0.absoluteString)" } ?? "")"
        case .originRateLimited(let status, let retryAfter, _):
            return "origin rate-limited us (HTTP \(status))\(retryAfter.map { ", retry after \($0)s" } ?? "")"
        case .originUnreachable(let status, _, let underlying):
            return "origin unreachable\(status.map { " (HTTP \($0))" } ?? "")\(underlying.map { ": \($0)" } ?? "")"
        case .noVideoStream:
            return "the source carries no video stream"
        case .videoCodecNotRemuxable(let codec, let index):
            return "video codec \(codec) (stream \(index)) cannot be stream-copied into fMP4"
        case .videoCodecUnplayable(let codec):
            return "no path in this build can play video codec \(codec)"
        case .startupBudgetExpired:
            return "the startup budget expired before a playable playlist existed"
        case .masterRejectedByPlayer(let underlying):
            return "AVPlayer refused the served master: \(underlying)"
        case .workDirectoryOutOfSpace:
            return "the work directory ran out of space"
        case .ffmpeg(let code, let operation, let message):
            return "\(operation) failed: \(message) (\(code))"
        case .unknown(let underlying):
            return "unclassified failure: \(underlying)"
        }
    }
}

// MARK: - Classification

extension PrismCoreError {

    /// Classify any error this engine (or the host's `AVPlayer`) produced.
    ///
    /// Recursive, because the interesting cause is routinely two wrappers
    /// deep: `SessionError.startupTimedOut(underlying: SourceProbe.Failure
    /// .openFailed(FFmpegError(…)))` is the *common* shape, not an exotic one.
    public static func classify(_ error: any Error) -> PrismCoreError {
        if let already = error as? PrismCoreError { return already }

        // First, because it arrives from outside: the host hands us an
        // `AVPlayerItem.error`, and a master rejection wearing an
        // `NSURLErrorDomain` -1002 would otherwise be read as a transport
        // failure and retried against an origin that is perfectly healthy.
        if MasterRejection.matches(error) { return .masterRejectedByPlayer(underlying: error) }

        switch error {
        case let session as PrismCoreSession.SessionError:
            switch session {
            case .startupTimedOut(let underlying):
                return underlying.map(classify) ?? .startupBudgetExpired
            case .alreadyStarted, .alreadySuperseded:
                // Misuses of the API, not failures of a source or an origin:
                // one is a registration after `start()`, the other a second
                // successor off one session. Giving either a taxonomy case
                // would invite hosts to handle it at runtime instead of fixing
                // the call order.
                return .unknown(underlying: error)
            }

        case let probe as SourceProbe.Failure:
            switch probe {
            case .openFailed(let underlying): return classify(underlying)
            // Named for the symptom it guards (a successful open that handed
            // back no context), not for a verdict about the source — there is
            // no stream list to have found empty at that point. `.unknown` is
            // the honest answer; `.noVideoStream` would be a claim.
            case .noStreams: return .unknown(underlying: error)
            }

        case let routing as PrismCoreEngine.RoutingFailure:
            switch routing {
            case .probeFailed(let underlying): return classify(underlying)
            case .noVideoStream: return .noVideoStream
            case .noDecoderForVideo(let codecName): return .videoCodecUnplayable(codecName: codecName)
            case .startupFailed(let underlying): return classify(underlying)
            }

        case let remux as HLSRemuxer.Failure:
            switch remux {
            case .noVideoStream: return .noVideoStream
            case .videoCodecNotNativelyPlayable(let codecName, let streamIndex):
                return .videoCodecNotRemuxable(codecName: codecName, streamIndex: streamIndex)
            case .openProducedNoContext: return .unknown(underlying: error)
            }

        case let ffmpeg as FFmpegError:
            return classify(ffmpeg)

        default:
            return classifyFoundation(error)
        }
    }

    /// libav*'s negative codes, mapped only where the mapping is real.
    ///
    /// FFmpeg's HTTP codes are the one place libavformat reports a *status*
    /// rather than a symptom, so they are worth reading exactly; everything
    /// else keeps its raw code and message on `.ffmpeg` instead of being
    /// squeezed into a category it does not belong to.
    private static func classify(_ error: FFmpegError) -> PrismCoreError {
        switch error.code {
        case swift_AVERROR_HTTP_UNAUTHORIZED():
            return .originRefused(status: 401, url: nil)
        case swift_AVERROR_HTTP_FORBIDDEN():
            return .originRefused(status: 403, url: nil)
        case swift_AVERROR_HTTP_TOO_MANY_REQUESTS():
            // FFmpeg reports no `Retry-After` through this code — the header is
            // parsed and discarded inside the http protocol. `nil` says we did
            // not read one, which is true, rather than inventing a delay.
            return .originRateLimited(status: 429, retryAfter: nil, url: nil)
        case swift_AVERROR_HTTP_NOT_FOUND():
            return .originUnreachable(status: 404, url: nil, underlying: error)
        case swift_AVERROR_HTTP_BAD_REQUEST():
            return .originUnreachable(status: 400, url: nil, underlying: error)
        case swift_AVERROR_HTTP_OTHER_4XX():
            // The one HTTP code that loses its status on the way out of
            // libavformat. 4xx without a number still answers the question a
            // host asks first — is this us, or is it them.
            return .originUnreachable(status: 400, url: nil, underlying: error)
        case swift_AVERROR_HTTP_SERVER_ERROR():
            return .originUnreachable(status: 500, url: nil, underlying: error)
        case swift_AVERROR(ENOSPC):
            return .workDirectoryOutOfSpace(underlying: error)
        case swift_AVERROR_EXIT():
            // What an interrupted read latches. The guard is armed only around
            // budgeted operations and around `cancel()` — and a cancelled
            // session's error never reaches a host, because `stop()` is the
            // host's own doing. So the remaining meaning is the budget.
            return .startupBudgetExpired
        case swift_AVERROR(ECONNREFUSED), swift_AVERROR(ECONNRESET), swift_AVERROR(ECONNABORTED),
             swift_AVERROR(ETIMEDOUT), swift_AVERROR(EHOSTUNREACH), swift_AVERROR(EHOSTDOWN),
             swift_AVERROR(ENETUNREACH), swift_AVERROR(ENETDOWN), swift_AVERROR(EPIPE):
            // Socket-level errno. A local file cannot produce these; a mounted
            // share that went away can, and for a host that is the same event.
            return .originUnreachable(status: nil, url: nil, underlying: error)
        default:
            return .ffmpeg(code: error.code, operation: error.operation, message: error.message)
        }
    }

    /// Foundation-shaped failures: `URLError` from the coordinated reader, and
    /// the two ways a full volume is reported.
    private static func classifyFoundation(_ error: any Error) -> PrismCoreError {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC) {
            return .workDirectoryOutOfSpace(underlying: error)
        }
        // 640 is `NSFileWriteOutOfSpaceError`, spelled numerically because the
        // symbol lives in a Foundation enum this file would otherwise import
        // for one constant.
        if nsError.domain == NSCocoaErrorDomain && nsError.code == 640 {
            return .workDirectoryOutOfSpace(underlying: error)
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .userAuthenticationRequired:
                // Refused, with no status we can read — URLSession collapses
                // the response into the code here.
                return .originRefused(status: nil, url: urlError.failingURL)
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
                 .networkConnectionLost, .timedOut, .dnsLookupFailed,
                 .resourceUnavailable, .secureConnectionFailed:
                return .originUnreachable(status: nil, url: urlError.failingURL, underlying: error)
            default:
                return .unknown(underlying: error)
            }
        }
        return .unknown(underlying: error)
    }
}
