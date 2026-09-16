import Testing
import Foundation
import Network
@testable import PrismCore

/// A raw HTTP client. `URLSession` hides exactly what these tests are about —
/// connection reuse, when headers arrive relative to the body, and whether a
/// transfer was truncated — so the socket is driven by hand.
private final class RawClient {

    private let connection: NWConnection

    init(host: String, port: UInt16) {
        let parameters = NWParameters.tcp
        // Only pinned for the loopback case: in LAN mode the server is bound
        // to an `en` address, and requiring the loopback interface there would
        // fail the connect rather than test the server.
        if host == "127.0.0.1" { parameters.requiredInterfaceType = .loopback }
        connection = NWConnection(
            to: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!),
            using: parameters
        )
        connection.start(queue: .global(qos: .userInitiated))
    }

    func send(_ text: String) async {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in
                once.run { continuation.resume() }
            })
        }
    }

    /// Reads until `isSatisfied` accepts what's accumulated so far, the peer
    /// closes, or `timeout` elapses.
    func read(
        timeout: Duration = .seconds(10),
        until isSatisfied: @escaping @Sendable (String) -> Bool
    ) async -> (text: String, closed: Bool) {
        let box = Accumulator()
        let result = await withTimeout(timeout) { [connection] in
            while true {
                let chunk: (Data?, Bool, Bool) = await withCheckedContinuation { continuation in
                    let once = ResumeOnce()
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                        once.run { continuation.resume(returning: (data, complete, error != nil)) }
                    }
                }
                if let data = chunk.0 { box.append(data) }
                if isSatisfied(box.text) { return (box.text, false) }
                if chunk.1 || chunk.2 { return (box.text, true) }
            }
        }
        return result ?? (box.text, false)
    }

    func close() {
        connection.forceCancel()
    }

    private final class Accumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ more: Data) { lock.withLock { data.append(more) } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }
}

/// Answers `.pending` and takes `delay` to resolve — the stand-in for the
/// demand-driven producer cutting a segment that doesn't exist yet.
private struct SlowProvider: SegmentProvider {
    let delay: Duration
    let outcome: Outcome

    enum Outcome: Sendable {
        case data(Data)
        case failure
    }

    func data(forPath path: String) async -> ProviderResult {
        let delay = delay
        let outcome = outcome
        return .pending(PendingResult {
            try? await Task.sleep(for: delay)
            switch outcome {
            case .data(let payload): return .data(payload, contentType: "video/mp4")
            case .failure: return .notFound
            }
        })
    }
}

private struct InstantProvider: SegmentProvider {
    let payload: Data
    func data(forPath path: String) async -> ProviderResult {
        .data(payload, contentType: "video/mp4")
    }
}

/// A started server plus the socket to wherever it bound. Both differ between
/// the two reachability modes — the host, and the token every request path has
/// to carry — so a test that must behave identically in both talks through
/// this instead of hardcoding `127.0.0.1` and a bare path.
private struct Harness {
    let client: RawClient
    let host: String
    /// Empty on loopback; `/<token>` in LAN mode.
    let prefix: String

    func get(_ path: String) -> String { request("GET", path) }

    func request(_ method: String, _ path: String, extraHeaders: String = "") -> String {
        "\(method) \(prefix)\(path) HTTP/1.1\r\nHost: \(host)\r\n\(extraHeaders)\r\n"
    }
}

@Suite("LoopbackHTTPServer hardening")
struct LoopbackHardeningTests {

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("prismcore-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    fileprivate static func reachability(_ overLAN: Bool) -> LoopbackHTTPServer.Reachability {
        overLAN ? .localNetworkUnencryptedForAirPlay : .loopbackOnly
    }

    /// Start the server and open a raw socket to it. `nil` when LAN mode had
    /// no interface to bind — the only honest outcome on a machine with the
    /// radio off, and not a test failure.
    fileprivate static func connect(to server: LoopbackHTTPServer) async throws -> Harness? {
        do {
            _ = try await server.start()
        } catch is LoopbackHTTPServer.NoLocalNetworkInterface {
            return nil
        }
        let host = await server.host
        let prefix = await server.accessToken.map { "/\($0.value)" } ?? ""
        return Harness(
            client: RawClient(host: host, port: await server.port),
            host: host,
            prefix: prefix
        )
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    @Test("Keep-alive: two GETs share one connection", arguments: [false, true])
    func keepAliveReuse(overLAN: Bool) async throws {
        let server = LoopbackHTTPServer(
            provider: InstantProvider(payload: Data("abcd".utf8)),
            reachability: Self.reachability(overLAN)
        )
        defer { Task { await server.stop() } }

        // `nil` means this machine has no interface the LAN mode could bind
        // (Wi-Fi off, or a CI box with nothing but loopback). The loopback
        // pass of the same test still covers the behavior.
        guard let harness = try await Self.connect(to: server) else { return }
        defer { harness.client.close() }

        await harness.client.send(harness.get("/seg1.m4s"))
        let first = await harness.client.read { $0.contains("abcd") }
        #expect(first.text.hasPrefix("HTTP/1.1 200 OK"))
        #expect(first.text.contains("Connection: keep-alive"))
        #expect(!first.closed)

        // Same socket, second request. If keep-alive were not honored this read
        // would come back closed with nothing in it.
        await harness.client.send(harness.get("/seg2.m4s"))
        let second = await harness.client.read(timeout: .seconds(3)) { $0.contains("abcd") }
        #expect(second.text.hasPrefix("HTTP/1.1 200 OK"))
        #expect(!second.closed)
    }

    @Test("Pipelined requests in one write both get answered", arguments: [false, true])
    func pipelined(overLAN: Bool) async throws {
        let server = LoopbackHTTPServer(
            provider: InstantProvider(payload: Data("xy".utf8)),
            reachability: Self.reachability(overLAN)
        )
        defer { Task { await server.stop() } }

        // `nil` means this machine has no interface the LAN mode could bind
        // (Wi-Fi off, or a CI box with nothing but loopback). The loopback
        // pass of the same test still covers the behavior.
        guard let harness = try await Self.connect(to: server) else { return }
        defer { harness.client.close() }

        // Both requests in a single TCP write — AVPlayer does this.
        await harness.client.send(harness.get("/a.m4s") + harness.get("/b.m4s"))
        let result = await harness.client.read { self.occurrences(of: "HTTP/1.1 200 OK", in: $0) == 2 }
        #expect(occurrences(of: "HTTP/1.1 200 OK", in: result.text) == 2)
    }

    @Test("Slow serve: early chunked headers land before the body", arguments: [false, true])
    func slowServeSendsEarlyHeaders(overLAN: Bool) async throws {
        let payload = Data(repeating: 0x42, count: 4096)
        let server = LoopbackHTTPServer(
            provider: SlowProvider(delay: .seconds(3), outcome: .data(payload)),
            limits: .init(slowServeThreshold: .seconds(1)),
            reachability: Self.reachability(overLAN)
        )
        defer { Task { await server.stop() } }

        // `nil` means this machine has no interface the LAN mode could bind
        // (Wi-Fi off, or a CI box with nothing but loopback). The loopback
        // pass of the same test still covers the behavior.
        guard let harness = try await Self.connect(to: server) else { return }
        defer { harness.client.close() }

        let started = ContinuousClock.now
        await harness.client.send(harness.get("/late.m4s"))

        let headers = await harness.client.read { $0.contains("\r\n\r\n") }
        let headerElapsed = started.duration(to: .now)
        #expect(headers.text.hasPrefix("HTTP/1.1 200 OK"))
        #expect(headers.text.contains("Transfer-Encoding: chunked"))
        #expect(!headers.text.contains("Content-Length"))
        // Headers must be out well before the provider lands (and far inside
        // AVPlayer's ~3.5 s watchdog window).
        #expect(headerElapsed < .seconds(2.5))

        let body = await harness.client.read { $0.contains("0\r\n\r\n") }
        #expect(started.duration(to: .now) > .seconds(2.5))
        // One chunk carrying the whole payload, then the terminator.
        #expect(body.text.contains("1000\r\n"))
        #expect(occurrences(of: String(repeating: "B", count: 4096), in: body.text) == 1)
        #expect(body.text.hasSuffix("0\r\n\r\n"))
    }

    @Test("Fast serve keeps the Content-Length shape", arguments: [false, true])
    func fastServeStaysFramed(overLAN: Bool) async throws {
        let server = LoopbackHTTPServer(
            provider: SlowProvider(delay: .milliseconds(50), outcome: .data(Data("hi".utf8))),
            limits: .init(slowServeThreshold: .seconds(2)),
            reachability: Self.reachability(overLAN)
        )
        defer { Task { await server.stop() } }

        // `nil` means this machine has no interface the LAN mode could bind
        // (Wi-Fi off, or a CI box with nothing but loopback). The loopback
        // pass of the same test still covers the behavior.
        guard let harness = try await Self.connect(to: server) else { return }
        defer { harness.client.close() }

        await harness.client.send(harness.get("/soon.m4s"))
        let result = await harness.client.read { $0.contains("hi") }
        #expect(result.text.contains("Content-Length: 2"))
        #expect(!result.text.contains("chunked"))
    }

    @Test("A serve that ultimately fails aborts the transfer", arguments: [false, true])
    func abortsOnFailure(overLAN: Bool) async throws {
        let server = LoopbackHTTPServer(
            provider: SlowProvider(delay: .seconds(2), outcome: .failure),
            limits: .init(slowServeThreshold: .milliseconds(500)),
            reachability: Self.reachability(overLAN)
        )
        defer { Task { await server.stop() } }

        // `nil` means this machine has no interface the LAN mode could bind
        // (Wi-Fi off, or a CI box with nothing but loopback). The loopback
        // pass of the same test still covers the behavior.
        guard let harness = try await Self.connect(to: server) else { return }
        defer { harness.client.close() }

        await harness.client.send(harness.get("/never.m4s"))
        // Read to the end of the connection: the server committed to a 200 and
        // then had nothing, so it must hang up mid-body rather than frame an
        // empty (cacheable) response.
        let result = await harness.client.read { _ in false }
        #expect(result.closed)
        #expect(result.text.contains("Transfer-Encoding: chunked"))
        #expect(!result.text.contains("0\r\n\r\n"))
    }

    @Test("HEAD answers with headers only", arguments: [false, true])
    func headRequest(overLAN: Bool) async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("#EXTM3U\n".utf8)
        try payload.write(to: root.appendingPathComponent("index.m3u8"))

        let server = LoopbackHTTPServer(root: root, reachability: Self.reachability(overLAN))
        defer { Task { await server.stop() } }

        // `nil` means this machine has no interface the LAN mode could bind
        // (Wi-Fi off, or a CI box with nothing but loopback). The loopback
        // pass of the same test still covers the behavior.
        guard let harness = try await Self.connect(to: server) else { return }
        defer { harness.client.close() }

        await harness.client.send(harness.request("HEAD", "/index.m3u8"))
        let result = await harness.client.read { $0.contains("\r\n\r\n") }
        #expect(result.text.hasPrefix("HTTP/1.1 200 OK"))
        #expect(result.text.contains("Content-Length: \(payload.count)"))
        #expect(result.text.contains("application/vnd.apple.mpegurl"))
        // Headers and nothing else.
        #expect(result.text.hasSuffix("\r\n\r\n"))
        #expect(!result.text.contains("#EXTM3U"))
    }

    @Test("An idle connection is dropped", arguments: [false, true])
    func idleTimeout(overLAN: Bool) async throws {
        let server = LoopbackHTTPServer(
            provider: InstantProvider(payload: Data("z".utf8)),
            limits: .init(idleTimeout: .milliseconds(400)),
            reachability: Self.reachability(overLAN)
        )
        defer { Task { await server.stop() } }

        // `nil` means this machine has no interface the LAN mode could bind
        // (Wi-Fi off, or a CI box with nothing but loopback). The loopback
        // pass of the same test still covers the behavior.
        guard let harness = try await Self.connect(to: server) else { return }
        defer { harness.client.close() }

        await harness.client.send(harness.get("/one.m4s"))
        _ = await harness.client.read { $0.contains("\r\n\r\n") }

        // Nothing more is sent — the server should hang up on its own.
        let after = await harness.client.read(timeout: .seconds(4)) { _ in false }
        #expect(after.closed)
    }

    @Test("Connection: close is honored", arguments: [false, true])
    func connectionClose(overLAN: Bool) async throws {
        let server = LoopbackHTTPServer(
            provider: InstantProvider(payload: Data("q".utf8)),
            reachability: Self.reachability(overLAN)
        )
        defer { Task { await server.stop() } }

        // `nil` means this machine has no interface the LAN mode could bind
        // (Wi-Fi off, or a CI box with nothing but loopback). The loopback
        // pass of the same test still covers the behavior.
        guard let harness = try await Self.connect(to: server) else { return }
        defer { harness.client.close() }

        await harness.client.send(harness.request("GET", "/x.m4s", extraHeaders: "Connection: close\r\n"))
        let result = await harness.client.read { _ in false }
        #expect(result.text.contains("Connection: close"))
        #expect(result.closed)
    }

    @Test("The per-connection request budget ends the connection", arguments: [false, true])
    func requestBudget(overLAN: Bool) async throws {
        let server = LoopbackHTTPServer(
            provider: InstantProvider(payload: Data("k".utf8)),
            limits: .init(maxRequestsPerConnection: 1),
            reachability: Self.reachability(overLAN)
        )
        defer { Task { await server.stop() } }

        // `nil` means this machine has no interface the LAN mode could bind
        // (Wi-Fi off, or a CI box with nothing but loopback). The loopback
        // pass of the same test still covers the behavior.
        guard let harness = try await Self.connect(to: server) else { return }
        defer { harness.client.close() }

        await harness.client.send(harness.get("/only.m4s"))
        let result = await harness.client.read { _ in false }
        #expect(result.text.contains("Connection: close"))
        #expect(result.closed)
    }

    @Test("An overlong request line is refused", arguments: [false, true])
    func requestLineCap(overLAN: Bool) async throws {
        let server = LoopbackHTTPServer(
            provider: InstantProvider(payload: Data("v".utf8)),
            limits: .init(maxRequestLineBytes: 128),
            reachability: Self.reachability(overLAN)
        )
        defer { Task { await server.stop() } }

        // `nil` means this machine has no interface the LAN mode could bind
        // (Wi-Fi off, or a CI box with nothing but loopback). The loopback
        // pass of the same test still covers the behavior.
        guard let harness = try await Self.connect(to: server) else { return }
        defer { harness.client.close() }

        await harness.client.send(harness.get("/" + String(repeating: "a", count: 400) + ".m4s"))
        let result = await harness.client.read { $0.contains("\r\n\r\n") }
        #expect(result.text.hasPrefix("HTTP/1.1 414"))
    }

    @Test("stop() tears down a connection with a response in flight", arguments: [false, true])
    func stopTearsDownMidFlight(overLAN: Bool) async throws {
        let server = LoopbackHTTPServer(
            provider: SlowProvider(delay: .seconds(30), outcome: .data(Data("never".utf8))),
            limits: .init(slowServeThreshold: .milliseconds(300)),
            reachability: Self.reachability(overLAN)
        )
        guard let harness = try await Self.connect(to: server) else { return }
        defer { harness.client.close() }

        await harness.client.send(harness.get("/pending.m4s"))
        _ = await harness.client.read { $0.contains("chunked") }

        await server.stop()
        let after = await harness.client.read(timeout: .seconds(4)) { _ in false }
        #expect(after.closed)
    }
}
