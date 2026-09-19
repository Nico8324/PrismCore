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
    /// Four megabytes, fetched on block boundaries and kept a few at a time.
    ///
    /// It was one block of one megabyte starting wherever the read happened to
    /// be. An MP4 whose audio sits a couple of megabytes behind its video makes
    /// the demuxer hop between the two several times a second; each hop threw
    /// the block away and fetched another, so a 25 Mbit/s film pulled 2.5 times
    /// its size over eight fresh connections a second and an Apple TV on
    /// Ethernet could not fill a buffer from a Mac on the same network
    /// (2026-09-19). Aligned blocks make both sides of the hop the same cached
    /// blocks, and a larger block spends fewer round trips per second of film.
    private let blockSize = 4 << 20
    private let blocksKept = 6
    private var position: Int64 = 0
    private var length: Int64?
    private var validator: String?
    /// Most recently used last.
    private var blocks: [(start: Int64, data: Data)] = []
    /// One session for the life of the input, so every block after the first
    /// rides a connection that is already open and already up to speed.
    private let session = RangeSession()
    private var io: UnsafeMutablePointer<AVIOContext>?

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
        // The session holds its delegate until it is invalidated; nothing else would let go.
        session.invalidate()
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
            let buffer = try block(holding: position)
            let offset = Int(position - buffer.start)
            guard offset >= 0, offset < buffer.data.count else { return swift_AVERROR_EOF() }
            let copied = min(Int(count), buffer.data.count - offset)
            buffer.data.copyBytes(to: destination, from: offset..<(offset + copied))
            position += Int64(copied)
            return Int32(copied)
        } catch { return interrupted() ? swift_AVERROR_EXIT() : swift_AVERROR(EIO) }
    }

    private func block(holding position: Int64) throws -> (start: Int64, data: Data) {
        let start = position - position % Int64(blockSize)
        if let index = blocks.firstIndex(where: { $0.start == start }) {
            blocks.append(blocks.remove(at: index))
        } else {
            try fill(from: start)
        }
        return blocks[blocks.count - 1]
    }

    private func fill() throws { try fill(from: position - position % Int64(blockSize)) }

    private func fill(from start: Int64) throws {
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
                response = try session.fetch(url: url, headers: requestHeaders, start: start,
                    size: blockSize, cancelled: cancelled)
            } catch { HTTPOriginCoordinator.shared.release(origin); throw error }
            let status = response.response?.statusCode ?? 0
            if response.error != nil && (status == 0 || status == 206) {
                HTTPOriginCoordinator.shared.refuse(origin, retryAfter: "0.25")
                HTTPOriginCoordinator.shared.release(origin)
                continue
            }
            if [429, 503, 509].contains(status) {
                HTTPOriginCoordinator.shared.refuse(origin,
                    retryAfter: response.response?.value(forHTTPHeaderField: "Retry-After"))
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
            guard status == 206, response.error == nil,
                  let raw = response.response?.value(forHTTPHeaderField: "Content-Range"),
                  let range = Self.contentRange(raw), range.start == start,
                  range.end - range.start + 1 == Int64(response.data.count),
                  response.data.count <= blockSize else { throw Failure.request }
            if let length, length != range.total { throw Failure.request }
            let tag = response.response?.value(forHTTPHeaderField: "ETag")
            let currentValidator = tag.flatMap { $0.hasPrefix("W/") ? nil : $0 }
                ?? response.response?.value(forHTTPHeaderField: "Last-Modified")
            if let validator, let currentValidator, validator != currentValidator { throw Failure.request }
            if validator == nil { validator = currentValidator }
            length = range.total
            blocks.removeAll { $0.start == start }
            blocks.append((start, response.data))
            if blocks.count > blocksKept { blocks.removeFirst() }
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

private final class RangeResponse: @unchecked Sendable {
    var response: HTTPURLResponse?
    var data = Data()
    var error: Error?
    let limit: Int
    let completed = DispatchSemaphore(value: 0)

    init(limit: Int) { self.limit = limit }
}

private final class RangeSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Int: RangeResponse] = [:]
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func invalidate() { session.invalidateAndCancel() }

    func fetch(url: URL, headers: [String: String], start: Int64, size: Int,
               cancelled: () -> Bool) throws -> RangeResponse {
        let result = RangeResponse(limit: size)
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (end, overflow) = start.addingReportingOverflow(Int64(size) - 1)
        request.setValue("bytes=\(start)-\(overflow ? Int64.max : end)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.dataTask(with: request)
        lock.withLock { results[task.taskIdentifier] = result }
        defer { lock.withLock { results[task.taskIdentifier] = nil } }
        task.resume()
        while result.completed.wait(timeout: .now() + 0.05) == .timedOut {
            if cancelled() { task.cancel(); throw HTTPRangeInput.Failure.request }
        }
        return result
    }

    private func result(for task: URLSessionTask) -> RangeResponse? {
        lock.withLock { results[task.taskIdentifier] }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let result = result(for: dataTask) else { completionHandler(.cancel); return }
        result.response = response as? HTTPURLResponse
        // A server ignoring Range must not download a movie into this buffer.
        completionHandler(result.response?.statusCode == 206 && response.expectedContentLength <= Int64(result.limit) ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let result = result(for: dataTask) else { return }
        guard result.data.count + data.count <= result.limit else { dataTask.cancel(); return }
        result.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let result = result(for: task) else { return }
        result.error = error
        result.completed.signal()
    }
}
