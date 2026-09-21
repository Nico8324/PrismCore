import Foundation
import Libavformat
import Libavutil

/// Optional seekable HTTP file input. A bounded range buffer lets all seeks,
/// probe reads and playback reads use the same per-origin admission policy.
/// This is for finite files, not nested HLS playlists or unbounded live feeds.
final class HTTPRangeInput {
    private var url: URL
    private var headers: [String: String]
    private let interrupted: () -> Bool
    private static let blockSize = 1 << 20
    private var position: Int64 = 0
    private var length: Int64?
    private var validator: String?

    /// How large the FIRST fill may be, when a caller's sizing hint says the
    /// metadata region is bigger than one block.
    ///
    /// Only ever **upward**, and only for the first fill. A header of three
    /// megabytes costs three requests at the fixed block size, and against a
    /// proxy that fetches each forwarded window whole before writing a byte
    /// those are three full waits; asking for the region in one request is the
    /// entire sizing win the hint exists for. Downward it is deliberately
    /// inert: this reader's first read is already a bounded
    /// `bytes=0-1048575`, not the open-ended request the design's first
    /// measurement is about, and shrinking it below a block would only turn
    /// one round trip into several on any file whose analysis reads past its
    /// header — which is most of them.
    private var firstFillSize: Int?

    /// The validator a caller stated it expects, and what the origin actually
    /// reported on the first response. Compared once, before any byte has been
    /// delivered, and never fatal: a hint that cannot be bound to the
    /// representation is a hint that is not used, not a play that fails.
    private let expectedValidator: String?
    private var firstResponseSeen = false
    private var observation: ValidatorObservation = .notObserved

    enum ValidatorObservation: Equatable {
        /// No response has arrived yet.
        case notObserved
        /// The origin reported none — no `ETag`, no `Last-Modified`.
        case unavailable
        case satisfied(String)
        case mismatched(reported: String)
        /// A validator was reported and the caller stated no expectation.
        case unchecked(String)
    }

    /// What the first response said, once it has arrived. Locked for the same
    /// reason `lastOriginFailure` is: the open site reads it from the thread
    /// that ran the blocking open, and nothing guarantees the reader thread is
    /// finished with it.
    var validatorObservation: ValidatorObservation {
        failureLock.withLock { observation }
    }

    /// Recently fetched blocks, least-recently-used first.
    ///
    /// More than one on purpose. Startup's read pattern is head → tail → head:
    /// the demuxer opens at the header, the segment plan nudges it to the
    /// container's index at the tail (a Matroska's Cues take two reads there),
    /// and the producer then starts at byte zero. With a single block that
    /// last step refetches bytes this reader already had, and it is not a
    /// cheap refetch — measured against a model of Aether's localhost range
    /// proxy, which fetches each forwarded window whole before it writes a
    /// byte: 1.35 s of a 3.0 s startup on a 60 min Matroska.
    ///
    /// Bounded by BYTES rather than by block count, because the blocks are
    /// not the same size: the two tail reads are tens of kilobytes, and
    /// counting them as equals to the 1 MB head is what evicts the head they
    /// were fetched around. The bound is per reader, and a session has more
    /// than one (the producer, a scrub preview), so it is deliberately close
    /// to the read pattern's own size rather than a cache anyone would tune.
    private static let retainedBytes = 4 << 20
    private var blocks: [(start: Int64, data: Data)] = []
    private var io: UnsafeMutablePointer<AVIOContext>?
    /// What the origin last said, kept because the only thing this reader can
    /// hand libavformat is an errno: `read` returns `-EIO` and every status —
    /// 403, 429, the connection that died — arrives at the open site as
    /// "Input/output error". The open sites ask for this instead, which is the
    /// whole reason a host can tell an expired token from a full disk.
    ///
    /// Locked because the open site reads it from the thread that ran the
    /// blocking open while nothing guarantees the reader thread is done.
    private let failureLock = NSLock()
    private var latchedFailure: PrismCoreError?
    var lastOriginFailure: PrismCoreError? { failureLock.withLock { latchedFailure } }
    private func latch(_ failure: PrismCoreError?) { failureLock.withLock { latchedFailure = failure } }

    init(
        url: URL,
        headers: [String: String],
        hints: SourceOpenHints? = nil,
        interrupted: @escaping () -> Bool
    ) {
        self.url = url
        self.headers = headers
        self.interrupted = interrupted
        self.expectedValidator = hints?.expectedValidator
        // Clamped to what this reader is willing to retain: a first fill it
        // would evict on its own next fill has bought nothing.
        self.firstFillSize = hints?.firstReadSizeHint.map {
            min(max($0, Self.blockSize), Self.retainedBytes)
        }
    }

    /// The size the first fill was actually bounded to, for the host's log
    /// line. `nil` until that fill has happened.
    private(set) var firstFillBytes: Int?

    func install(on context: UnsafeMutablePointer<AVFormatContext>) throws {
        guard let allocation = av_malloc(32768) else { throw Failure.allocation }
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        io = avio_alloc_context(allocation.assumingMemoryBound(to: UInt8.self), 32768, 0, opaque,
            { opaque, bytes, count in
                guard let opaque, let bytes else { return swift_AVERROR(EIO) }
                return Unmanaged<HTTPRangeInput>.fromOpaque(opaque).takeUnretainedValue().read(into: bytes, count: count)
            }, nil,
            { opaque, offset, whence in
                guard let opaque else { return -1 }
                return Unmanaged<HTTPRangeInput>.fromOpaque(opaque).takeUnretainedValue().seek(offset: offset, whence: whence)
            })
        guard let io else { av_free(allocation); throw Failure.allocation }
        io.pointee.seekable = 1
        context.pointee.pb = io
        context.pointee.flags |= 0x0080 // AVFMT_FLAG_CUSTOM_IO: this owner frees AVIO.
    }

    deinit {
        if let io { av_free(io.pointee.buffer); avio_context_free(&self.io) }
    }

    private func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence & 0x10000 != 0 { // AVSEEK_SIZE
            if length == nil { do { try fill() } catch { return -1 } }
            return length ?? -1
        }
        let base: Int64
        switch whence & ~0x20000 {
        case SEEK_SET: base = 0
        case SEEK_CUR: base = position
        case SEEK_END: guard let length else { return -1 }; base = length
        default: return -1
        }
        let (target, overflow) = base.addingReportingOverflow(offset)
        guard !overflow, target >= 0 else { return -1 }
        position = target
        return target
    }

    private func read(into destination: UnsafeMutablePointer<UInt8>, count: Int32) -> Int32 {
        guard count > 0 else { return 0 }
        if interrupted() { return swift_AVERROR_EXIT() }
        if let length, position >= length { return swift_AVERROR_EOF() }
        do {
            if blockIndex(containing: position) == nil { try fill() }
            guard let index = blockIndex(containing: position) else { return swift_AVERROR_EOF() }
            // Touched blocks become the most recent, so a reader alternating
            // between two regions keeps both rather than thrashing one out.
            let block = blocks.remove(at: index)
            blocks.append(block)
            let offset = Int(position - block.start)
            let copied = min(Int(count), block.data.count - offset)
            block.data.copyBytes(to: destination, from: offset..<(offset + copied))
            position += Int64(copied)
            return Int32(copied)
        } catch { return interrupted() ? swift_AVERROR_EXIT() : swift_AVERROR(EIO) }
    }

    private func fill() throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        let cancelled = { [self] in interrupted() || ProcessInfo.processInfo.systemUptime >= deadline }
        for _ in 0..<8 {
            guard !cancelled() else { throw Failure.request }
            let origin = HTTPOriginCoordinator.origin(url)
            guard HTTPOriginCoordinator.shared.acquire(origin, cancelled: cancelled) else { throw Failure.request }
            let requestSize = firstFillSize ?? Self.blockSize
            let response: RangeResponse
            do {
                var requestHeaders = headers
                if let validator { requestHeaders["If-Range"] = validator }
                response = try RangeResponse.fetch(url: url, headers: requestHeaders, start: position,
                    size: requestSize, cancelled: cancelled)
            } catch { HTTPOriginCoordinator.shared.release(origin); throw error }
            let status = response.response?.statusCode ?? 0
            if response.error != nil && (status == 0 || status == 206) {
                // No status, even when the origin answered 206 first. The two
                // are about different things: the status describes a *response*
                // that succeeded, the error describes a *transfer* that did
                // not, and only the second one failed. Carrying the 206 here
                // made `retryability` read "non-nil status below 500" as
                // `.permanent` and tell hosts not to retry a dropped socket on
                // a healthy origin. Fixed at the recording site rather than by
                // teaching `retryability` about success codes, because a
                // failure carrying a success status is a state that should not
                // exist — the transfer error is the whole evidence, and it
                // rides along in `underlying`.
                latch(.originUnreachable(status: nil, url: url, underlying: response.error))
                HTTPOriginCoordinator.shared.refuse(origin, retryAfter: "0.25")
                HTTPOriginCoordinator.shared.release(origin)
                continue
            }
            if [429, 503, 509].contains(status) {
                let retryAfter = response.response?.value(forHTTPHeaderField: "Retry-After")
                latch(.originRateLimited(status: status,
                    retryAfter: HTTPOriginCoordinator.retryDelay(retryAfter), url: url))
                HTTPOriginCoordinator.shared.refuse(origin, retryAfter: retryAfter)
                HTTPOriginCoordinator.shared.release(origin)
                continue
            }
            HTTPOriginCoordinator.shared.release(origin)
            if [301, 302, 303, 307, 308].contains(status),
               let location = response.response?.value(forHTTPHeaderField: "Location"),
               let next = URL(string: location, relativeTo: url)?.absoluteURL,
               ["http", "https"].contains(next.scheme?.lowercased() ?? "") {
                guard !(url.scheme == "https" && next.scheme == "http") else { throw Failure.request }
                if HTTPOriginCoordinator.origin(next) != origin {
                    // Custom authentication header names are unknowable: no
                    // caller headers cross an origin boundary automatically.
                    headers.removeAll()
                }
                url = next
                continue
            }
            // Only 4xx/5xx: a bare 200 here means a server that ignored the
            // Range header and had its body cancelled, which is a capability
            // problem, not a refusal — naming it one would send a host off
            // re-authenticating against an origin that is answering fine.
            if status >= 400 {
                latch([401, 403, 407].contains(status)
                    ? .originRefused(status: status, url: url)
                    : .originUnreachable(status: status, url: url, underlying: nil))
            }
            guard status == 206, response.error == nil,
                  let raw = response.response?.value(forHTTPHeaderField: "Content-Range"),
                  let range = Self.contentRange(raw), range.start == position,
                  range.end - range.start + 1 == Int64(response.data.count),
                  response.data.count <= requestSize else { throw Failure.request }
            if let length, length != range.total { throw Failure.request }
            let tag = response.response?.value(forHTTPHeaderField: "ETag")
            let currentValidator = tag.flatMap { $0.hasPrefix("W/") ? nil : $0 }
                ?? response.response?.value(forHTTPHeaderField: "Last-Modified")
            if let validator, let currentValidator, validator != currentValidator { throw Failure.request }
            if validator == nil { validator = currentValidator }
            // The caller's expectation, judged once and only on the FIRST real
            // response — before a byte of it has been delivered anywhere.
            // Deliberately not a throw: a representation that is not the one
            // the hints describe is a reason to stop trusting the hints, and
            // the bytes arriving here are a perfectly good current version to
            // open unhinted. The mid-session case is the line above, which
            // does throw, because there the old version's headers, blocks and
            // plan are already built and mixing versions fails invisibly.
            if !firstResponseSeen {
                firstResponseSeen = true
                let verdict: ValidatorObservation
                switch (expectedValidator, currentValidator) {
                case (nil, let reported?): verdict = .unchecked(reported)
                case (nil, nil): verdict = .unavailable
                case (_?, nil): verdict = .unavailable
                case (let expected?, let reported?):
                    verdict = expected == reported ? .satisfied(reported) : .mismatched(reported: reported)
                }
                failureLock.withLock { observation = verdict }
            }
            // One fill only: every later read is an ordinary block.
            if firstFillSize != nil {
                firstFillBytes = requestSize
                firstFillSize = nil
            }
            length = range.total
            blocks.append((start: position, data: response.data))
            // Never drops the block just fetched: it is the one the read that
            // triggered this fill is about to use.
            var retained = blocks.reduce(0) { $0 + $1.data.count }
            while blocks.count > 1, retained > Self.retainedBytes {
                retained -= blocks.removeFirst().data.count
            }
            // A refusal the retry loop rode out must not outlive it: a session
            // that was throttled at minute one and dies of something else at
            // minute forty would otherwise be reported as rate-limited.
            latch(nil)
            return
        }
        throw Failure.request
    }

    private func blockIndex(containing offset: Int64) -> Int? {
        blocks.lastIndex { offset >= $0.start && offset < $0.start + Int64($0.data.count) }
    }

    static func contentRange(_ value: String) -> (start: Int64, end: Int64, total: Int64)? {
        guard value.hasPrefix("bytes ") else { return nil }
        let components = value.dropFirst(6).split(omittingEmptySubsequences: false, whereSeparator: { $0 == "-" || $0 == "/" })
        guard components.count == 3, let start = Int64(components[0]), let end = Int64(components[1]),
              let total = Int64(components[2]), start >= 0, end >= start, total > end else { return nil }
        return (start, end, total)
    }

    enum Failure: Error { case allocation, request }
}

private final class RangeResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    var response: HTTPURLResponse?
    var data = Data()
    var error: Error?
    let limit: Int
    private let completed = DispatchSemaphore(value: 0)

    init(limit: Int) { self.limit = limit }

    static func fetch(url: URL, headers: [String: String], start: Int64, size: Int,
                      cancelled: () -> Bool) throws -> RangeResponse {
        let result = RangeResponse(limit: size)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: result, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (end, overflow) = start.addingReportingOverflow(Int64(size) - 1)
        request.setValue("bytes=\(start)-\(overflow ? Int64.max : end)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.dataTask(with: request)
        task.resume()
        while result.completed.wait(timeout: .now() + 0.05) == .timedOut {
            if cancelled() { task.cancel(); throw HTTPRangeInput.Failure.request }
        }
        return result
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        // A server ignoring Range must not download a movie into this buffer.
        completionHandler(self.response?.statusCode == 206 && response.expectedContentLength <= Int64(limit) ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard self.data.count + data.count <= limit else { dataTask.cancel(); return }
        self.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        self.error = error
        completed.signal()
    }
}
