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
    private let blockSize = 1 << 20
    private var position: Int64 = 0
    private var length: Int64?
    private var validator: String?
    private var buffer = Data()
    private var bufferStart: Int64 = 0
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

    init(url: URL, headers: [String: String], interrupted: @escaping () -> Bool) {
        self.url = url
        self.headers = headers
        self.interrupted = interrupted
    }

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
            if position < bufferStart || position >= bufferStart + Int64(buffer.count) { try fill() }
            let offset = Int(position - bufferStart)
            guard offset >= 0, offset < buffer.count else { return swift_AVERROR_EOF() }
            let copied = min(Int(count), buffer.count - offset)
            buffer.copyBytes(to: destination, from: offset..<(offset + copied))
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
            let response: RangeResponse
            do {
                var requestHeaders = headers
                if let validator { requestHeaders["If-Range"] = validator }
                response = try RangeResponse.fetch(url: url, headers: requestHeaders, start: position,
                    size: blockSize, cancelled: cancelled)
            } catch { HTTPOriginCoordinator.shared.release(origin); throw error }
            let status = response.response?.statusCode ?? 0
            if response.error != nil && (status == 0 || status == 206) {
                latch(.originUnreachable(status: status == 0 ? nil : status, url: url,
                    underlying: response.error))
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
                  response.data.count <= blockSize else { throw Failure.request }
            if let length, length != range.total { throw Failure.request }
            let tag = response.response?.value(forHTTPHeaderField: "ETag")
            let currentValidator = tag.flatMap { $0.hasPrefix("W/") ? nil : $0 }
                ?? response.response?.value(forHTTPHeaderField: "Last-Modified")
            if let validator, let currentValidator, validator != currentValidator { throw Failure.request }
            if validator == nil { validator = currentValidator }
            length = range.total
            bufferStart = position
            buffer = response.data
            // A refusal the retry loop rode out must not outlive it: a session
            // that was throttled at minute one and dies of something else at
            // minute forty would otherwise be reported as rate-limited.
            latch(nil)
            return
        }
        throw Failure.request
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
