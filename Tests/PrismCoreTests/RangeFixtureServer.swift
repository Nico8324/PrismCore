import Foundation
import Network

/// A test-only origin with real Range replies and one bandwidth schedule
/// shared by every connection. Playback and probe traffic compete for it.
final class RangeFixtureServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "prismcore.tests.origin")
    private let listener: NWListener
    private let media: Data
    private let bytesPerSecond: Double
    private let firstByteDelay: Double
    private var nextWrite: TimeInterval = 0
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var refusals: Int
    private var drops: Int
    /// Answers the range normally — 206, Content-Range, a Content-Length it
    /// means — and then cuts the socket partway through the body. `drops` dies
    /// before the origin says anything; this one dies after it has already
    /// succeeded, which is the only way to reach the "successful status on a
    /// transport failure" path in `HTTPRangeInput`.
    private var truncations: Int
    /// Answered to every request, forever. `refusals` is a transient origin
    /// (it relents); this is one that never will — an expired token, a revoked
    /// share — which is the difference the taxonomy has to survive.
    private let deniedStatus: Int?
    private let retryAfter: String
    private var requestTimes: [TimeInterval] = []
    private var resumed = false

    init(media: Data, bytesPerSecond: Double = 4_000_000, firstByteDelay: Double = 0.02, refusals: Int = 0,
         drops: Int = 0, truncations: Int = 0, deniedStatus: Int? = nil, retryAfter: String = "1") throws {
        self.truncations = truncations
        self.deniedStatus = deniedStatus
        self.retryAfter = retryAfter
        self.media = media
        self.bytesPerSecond = bytesPerSecond
        self.firstByteDelay = firstByteDelay
        self.refusals = refusals
        self.drops = drops
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    var requests: [TimeInterval] { queue.sync { requestTimes } }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/fixture.mkv")!)
                case .failed(let error): resumed = true; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [self] connection in
                connections[ObjectIdentifier(connection)] = connection
                connection.start(queue: queue)
                receive(connection, accumulated: Data())
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            listener.newConnectionHandler = nil
            listener.stateUpdateHandler = nil
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
        }
    }

    private func close(_ connection: NWConnection) {
        connection.cancel()
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, done, error in
            let buffer = accumulated + (data ?? Data())
            guard buffer.count <= 16384, error == nil else { close(connection); return }
            guard let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") else {
                if done { close(connection) } else { receive(connection, accumulated: buffer) }
                return
            }
            requestTimes.append(ProcessInfo.processInfo.systemUptime)
            if drops > 0 { drops -= 1; close(connection); return }
            if let deniedStatus {
                let retryHeader = [429, 503, 509].contains(deniedStatus) ? "Retry-After: \(retryAfter)\r\n" : ""
                connection.send(content: Data("HTTP/1.1 \(deniedStatus) Denied\r\n\(retryHeader)Content-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                    completion: .contentProcessed { _ in self.close(connection) })
                return
            }
            if refusals > 0 {
                refusals -= 1
                connection.send(content: Data("HTTP/1.1 429 Too Many Requests\r\nRetry-After: \(retryAfter)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                    completion: .contentProcessed { _ in self.close(connection) })
                return
            }
            let range = text.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range: bytes=") }
            let bounds = range?.components(separatedBy: "=").last?.split(separator: "-", omittingEmptySubsequences: false)
            let start = bounds?.first.flatMap { Int($0) } ?? 0
            let requestedEnd = bounds.flatMap { $0.count > 1 ? Int($0[1]) : nil } ?? (media.count - 1)
            guard start >= 0, start < media.count else { close(connection); return }
            let end = min(media.count - 1, requestedEnd)
            guard end >= start else { close(connection); return }
            let status = range == nil ? "200 OK" : "206 Partial Content"
            let header = "HTTP/1.1 \(status)\r\nContent-Length: \(end - start + 1)\r\nContent-Range: bytes \(start)-\(end)/\(media.count)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n"
            let truncate = truncations > 0
            if truncate { truncations -= 1 }
            queue.asyncAfter(deadline: .now() + firstByteDelay) {
                connection.send(content: Data(header.utf8), completion: .contentProcessed { error in
                    if error != nil { self.close(connection) }
                    else if truncate {
                        // Short of the Content-Length just promised, then gone:
                        // URLSession reports a transport error on a response it
                        // has already handed back as 206.
                        let cut = min(end, start + 1024) // always at least one byte short
                        connection.send(content: self.media.subdata(in: start..<cut),
                            completion: .contentProcessed { _ in self.close(connection) })
                    }
                    else { self.sendBody(connection, offset: start, end: end + 1) }
                })
            }
        }
    }

    private func sendBody(_ connection: NWConnection, offset: Int, end: Int) {
        guard connections[ObjectIdentifier(connection)] != nil else { return }
        guard offset < end else { close(connection); return }
        let count = min(16384, end - offset)
        let now = ProcessInfo.processInfo.systemUptime
        let admission = max(now, nextWrite)
        nextWrite = admission + Double(count) / bytesPerSecond
        queue.asyncAfter(deadline: .now() + max(0, admission - now)) { [self] in
            connection.send(content: media.subdata(in: offset..<(offset + count)), completion: .contentProcessed { error in
                if error != nil { self.close(connection) }
                else { self.sendBody(connection, offset: offset + count, end: end) }
            })
        }
    }
}
