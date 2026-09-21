import Testing
import Foundation
@testable import PrismCore

private struct FixedProvider: SegmentProvider {
    let payload: Data
    func data(forPath path: String) async -> ProviderResult {
        path == "index.m3u8" ? .data(payload, contentType: "application/vnd.apple.mpegurl") : .notFound
    }
}

/// No cache between the tests and the server: the media responses are
/// deliberately `immutable`, and a cached 200 would make a later "is this
/// refused?" assertion pass for the wrong reason.
private func fetch(_ url: URL, token: String? = nil) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
    if let token { request.setValue(token, forHTTPHeaderField: SessionAccessToken.headerName) }
    let session = URLSession(configuration: .ephemeral)
    defer { session.finishTasksAndInvalidate() }
    let (data, response) = try await session.data(for: request)
    return (data, response as! HTTPURLResponse)
}

@Suite("LAN reachability")
struct LANReachabilityTests {

    private static let payload = Data("#EXTM3U\n#EXT-X-VERSION:7\n".utf8)

    /// Starts a LAN-mode server, or returns `nil` when this machine has no
    /// interface to bind (radio off, loopback-only CI box) — the honest
    /// outcome, and not a failure of the code under test.
    private func startLANServer() async throws -> (server: LoopbackHTTPServer, base: URL)? {
        let server = LoopbackHTTPServer(
            provider: FixedProvider(payload: Self.payload),
            reachability: .localNetworkUnencryptedForAirPlay
        )
        do {
            return (server, try await server.start())
        } catch is LoopbackHTTPServer.NoLocalNetworkInterface {
            return nil
        }
    }

    // MARK: - The default is untouched

    @Test("Default reachability stays on 127.0.0.1 with no token")
    func defaultIsLoopbackOnly() async throws {
        let server = LoopbackHTTPServer(provider: FixedProvider(payload: Self.payload))
        let base = try await server.start()
        defer { Task { await server.stop() } }

        #expect(base.host() == "127.0.0.1")
        // No token component: the served playlist's relative references are
        // the same strings they have always been.
        #expect(base.path == "/")
        #expect(await server.accessToken == nil)
        #expect(await server.serviceAddress == .loopback)

        let (data, response) = try await fetch(base.appendingPathComponent("index.m3u8"))
        #expect(response.statusCode == 200)
        #expect(data == Self.payload)
    }

    // MARK: - The enabled mode

    @Test("Enabled mode publishes a routable address and a token prefix")
    func lanModePublishesRoutableURL() async throws {
        guard let (server, base) = try await startLANServer() else { return }
        defer { Task { await server.stop() } }

        let host = try #require(base.host())
        #expect(host != "127.0.0.1")
        #expect(!host.hasPrefix("127."))
        // A self-assigned address is not a route; the interface picker is
        // supposed to have refused it before we ever got here.
        #expect(!host.hasPrefix("169.254."))
        #expect(await server.serviceAddress == .localNetwork(host))

        let token = try #require(await server.accessToken)
        // `URL.path` drops the trailing slash; the string on the wire is what
        // decides whether relative references inherit the token.
        #expect(base.absoluteString.hasSuffix("/\(token.value)/"))
        // The token is the first path component, so a playlist's own relative
        // references inherit it without the playlist writer knowing it exists.
        let playlist = base.appendingPathComponent("index.m3u8")
        #expect(playlist.path == "/\(token.value)/index.m3u8")

        let (data, response) = try await fetch(playlist)
        #expect(response.statusCode == 200)
        #expect(data == Self.payload)
    }

    @Test("A request without the token is refused")
    func tokenlessRequestIsRefused() async throws {
        guard let (server, base) = try await startLANServer() else { return }
        defer { Task { await server.stop() } }

        let bare = URL(string: "http://\(base.host()!):\(await server.port)/index.m3u8")!
        let (data, response) = try await fetch(bare)
        // 404, not 403: a wrong token must look exactly like a wrong path.
        #expect(response.statusCode == 404)
        #expect(data.isEmpty)
    }

    @Test("A request with the wrong token is refused")
    func wrongTokenIsRefused() async throws {
        guard let (server, base) = try await startLANServer() else { return }
        defer { Task { await server.stop() } }

        let token = try #require(await server.accessToken)
        // Same length, one character different — the shape a guess would have.
        let wrong = "A" + token.value.dropFirst()
        let url = URL(string: "http://\(base.host()!):\(await server.port)/\(wrong)/index.m3u8")!
        #expect(try await fetch(url).1.statusCode == 404)
    }

    @Test("The token is accepted as a header as well as a path prefix")
    func headerTokenIsAccepted() async throws {
        guard let (server, base) = try await startLANServer() else { return }
        defer { Task { await server.stop() } }

        let token = try #require(await server.accessToken)
        let bare = URL(string: "http://\(base.host()!):\(await server.port)/index.m3u8")!
        let (data, response) = try await fetch(bare, token: token.value)
        #expect(response.statusCode == 200)
        #expect(data == Self.payload)
    }

    @Test("A token buys the namespace, not a way out of it")
    func tokenDoesNotUnlockTraversal() async throws {
        guard let (server, base) = try await startLANServer() else { return }
        defer { Task { await server.stop() } }

        let token = try #require(await server.accessToken)
        let escape = URL(string: "http://\(base.host()!):\(await server.port)/\(token.value)/../secret")!
        #expect(try await fetch(escape).1.statusCode == 404)
    }

    // MARK: - The address moving under the session

    @Test("Losing the bound address fails honestly instead of serving")
    func addressLossIsRefusedLoudly() async throws {
        guard let (server, base) = try await startLANServer() else { return }
        defer { Task { await server.stop() } }

        let host = try #require(base.host())
        // The address the machine still has is not the one we bound: what a
        // Wi-Fi-to-Ethernet swap looks like from inside the server.
        await server.overrideAssignedAddresses { ["127.0.0.1", "10.99.99.99"] }
        await server.revalidateServiceAddress()
        #expect(await server.serviceAddress == .addressLost(host))
        #expect(try await fetch(base.appendingPathComponent("index.m3u8")).1.statusCode == 503)

        // And a blip that comes back with the same address resumes, rather
        // than leaving the session dead for a fault that healed.
        await server.overrideAssignedAddresses { [host] }
        await server.revalidateServiceAddress()
        #expect(await server.serviceAddress == .localNetwork(host))
        #expect(try await fetch(base.appendingPathComponent("index.m3u8")).1.statusCode == 200)
    }

    @Test("Revalidation never disturbs a loopback server")
    func loopbackIgnoresAddressChanges() async throws {
        let server = LoopbackHTTPServer(provider: FixedProvider(payload: Self.payload))
        let base = try await server.start()
        defer { Task { await server.stop() } }

        await server.overrideAssignedAddresses { [] }
        await server.revalidateServiceAddress()
        #expect(await server.serviceAddress == .loopback)
        #expect(try await fetch(base.appendingPathComponent("index.m3u8")).1.statusCode == 200)
    }
}

@Suite("LAN interface selection")
struct LocalNetworkInterfaceTests {

    @Test("Tunnels and peer-to-peer radios are never served from")
    func excludedInterfaces() {
        for name in ["utun0", "utun11", "awdl0", "llw0", "ipsec1", "ppp0", "anpi2", "gif0", "stf0", "vmenet0", "nan0"] {
            #expect(LocalNetworkInterface.rank(forInterfaceNamed: name) == nil, "\(name) must not be servable")
        }
    }

    @Test("A real en interface outranks a bridge and anything unknown")
    func rankOrder() throws {
        let ethernet = try #require(LocalNetworkInterface.rank(forInterfaceNamed: "en0"))
        let unknown = try #require(LocalNetworkInterface.rank(forInterfaceNamed: "xyz0"))
        let bridge = try #require(LocalNetworkInterface.rank(forInterfaceNamed: "bridge100"))
        #expect(ethernet < unknown)
        #expect(unknown < bridge)
    }

    @Test("Candidates are ordered deterministically, best first")
    func candidatesAreOrdered() {
        let candidates = LocalNetworkInterface.candidates()
        // A machine with nothing up is a valid state, not a failure.
        guard let best = candidates.first else { return }
        #expect(LocalNetworkInterface.preferredIPv4Address() == best.address)
        for candidate in candidates {
            #expect(!candidate.address.hasPrefix("127."))
            #expect(!candidate.address.hasPrefix("169.254."))
            #expect(LocalNetworkInterface.rank(forInterfaceNamed: candidate.name) != nil)
        }
        // Whatever we would serve from is, by definition, an address we hold.
        #expect(LocalNetworkInterface.assignedIPv4Addresses().contains(best.address))
        let keys = candidates.map { ($0.rank, $0.ordinal, $0.name) }
        #expect(keys.elementsEqual(keys.sorted { $0 < $1 }, by: ==))
    }
}

@Suite("Session access token")
struct SessionAccessTokenTests {

    @Test("Tokens are URL-path-safe, long, and never repeat")
    func tokenShape() {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var seen: Set<String> = []
        for _ in 0..<64 {
            let token = SessionAccessToken.random()
            // 24 bytes of CSPRNG, base64url, unpadded.
            #expect(token.value.count == 32)
            #expect(token.value.allSatisfy { allowed.contains($0) })
            seen.insert(token.value)
        }
        #expect(seen.count == 64)
    }

    @Test("Comparison accepts only the exact token")
    func comparison() {
        let token = SessionAccessToken(value: "abcdef")
        #expect(token.matches("abcdef"))
        #expect(!token.matches("abcdeg"))
        #expect(!token.matches("ABCDEF"))
        #expect(!token.matches("abcde"))
        #expect(!token.matches("abcdefg"))
        #expect(!token.matches(""))
    }

    @Test("The gate strips the prefix, honors the header, and refuses the rest")
    func gate() throws {
        let token = SessionAccessToken(value: "tok123")
        func request(_ line: String, header: String? = nil) throws -> LoopbackHTTPServer.Request {
            let headers = header.map { "\(SessionAccessToken.headerName): \($0)\r\n" } ?? ""
            return try #require(LoopbackHTTPServer.Request(head: "\(line)\r\nHost: h\r\n\(headers)"))
        }

        #expect(LoopbackHTTPServer.path(
            of: try request("GET /tok123/video/seg00001.m4s HTTP/1.1"), behind: token
        ) == "video/seg00001.m4s")
        #expect(LoopbackHTTPServer.path(
            of: try request("GET /video/seg00001.m4s HTTP/1.1", header: "tok123"), behind: token
        ) == "video/seg00001.m4s")
        #expect(LoopbackHTTPServer.path(
            of: try request("GET /video/seg00001.m4s HTTP/1.1"), behind: token
        ) == nil)
        #expect(LoopbackHTTPServer.path(
            of: try request("GET /nope/seg00001.m4s HTTP/1.1"), behind: token
        ) == nil)
        // The token alone names no resource.
        #expect(LoopbackHTTPServer.path(of: try request("GET /tok123/ HTTP/1.1"), behind: token) == nil)
        // Normalization runs first, so this never reaches the provider.
        #expect(LoopbackHTTPServer.path(of: try request("GET /tok123/../etc HTTP/1.1"), behind: token) == nil)
    }
}
