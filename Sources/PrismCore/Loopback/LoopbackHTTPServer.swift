import Foundation
import Network

/// A minimal HTTP/1.1 server bound to `127.0.0.1` on an ephemeral port — the
/// loopback half of the remux pipeline. It serves exactly one namespace (the
/// remux session's segment dir by default): the growing playlist, the init
/// segment, and the media segments.
///
/// Still deliberately small, but no longer naive about what AVPlayer does to a
/// server at scale:
///
/// - **`GET` and `HEAD`**; anything else is `405`.
/// - **Whole-payload responses** with `Content-Length` (`Range` is ignored —
///   HLS clients fetch whole segments).
/// - **Keep-alive** per HTTP/1.1 default: after a response the connection loops
///   back to reading the next request, bounded by `Limits.maxRequestsPerConnection`
///   and `Limits.idleTimeout` so abandoned sockets can't pile up. `Connection:
///   close` (and HTTP/1.0 without an explicit keep-alive) is honored.
/// - **A provider seam** (`SegmentProvider`) instead of direct file reads, so a
///   payload that is still being produced can say so.
///
/// The reason the seam exists is an expensive AVPlayer lesson:
/// AVPlayer's media watchdog logs `-12889 "No response for media file"` after
/// roughly 3.5 s without response HEADERS — holding the socket open silently
/// buys nothing — and a few of those in a row fail the item outright. So when a
/// provider hasn't answered within `Limits.slowServeThreshold` (2 s, comfortably
/// inside the window), the server commits to an early `200` with
/// `Transfer-Encoding: chunked` and sends the payload as a single chunk when it
/// lands. If the serve ultimately misses, the connection is aborted mid-body:
/// a truncated transfer is something AVPlayer retries, whereas a well-framed
/// empty `200` is something it caches as the truth about that segment.
///
/// Fast serves keep the byte-identical `Content-Length` shape — the chunked
/// path is the exception, not the norm.
///
/// ## Reachability
///
/// The default (`Reachability.loopbackOnly`) is the whole story above: bound to
/// `127.0.0.1`, unreachable from anywhere else, no token, byte-identical to
/// what shipped before this mode existed.
///
/// `.localNetworkUnencryptedForAirPlay` is the opt-in exception, and it exists
/// for exactly one reason: when the host AirPlays to an external receiver, the
/// receiver fetches the playlist and every segment *itself*, and `127.0.0.1`
/// resolves to the receiver. See that case's documentation for what it costs.
public actor LoopbackHTTPServer {

    public struct FailedToStart: Error {}

    /// No interface to serve from: Wi-Fi off, cable out, or nothing left after
    /// the tunnels and peer-to-peer radios are excluded. Thrown from `start()`
    /// in LAN mode, because the alternative is publishing a URL nobody can
    /// reach and letting the host find out from a playback timeout.
    public struct NoLocalNetworkInterface: Error {}

    /// Who can reach this server. Opt in with care; the default is the safe one.
    public enum Reachability: Sendable, Equatable {
        /// Bound to `127.0.0.1`. Nothing off-device can connect, and no token
        /// is issued or required.
        case loopbackOnly

        /// **Opt-in, and named at length on purpose.** Binds the preferred LAN
        /// IPv4 interface so an AirPlay receiver can fetch the playlist, and
        /// gates every request on a per-session token (see
        /// `SessionAccessToken`).
        ///
        /// The residual risk, stated plainly: this is **cleartext HTTP on the
        /// local network**. Anyone on that LAN who can observe the traffic sees
        /// the token, the playlist and the media bytes — and anyone who holds
        /// the token can fetch the session's segments for as long as it runs.
        /// The token makes the server unguessable, not private. Enable it for
        /// the duration of an AirPlay route on a network the user trusts, and
        /// stop the session when the route ends.
        case localNetworkUnencryptedForAirPlay
    }

    /// Where the server is currently reachable.
    public enum ServiceAddress: Sendable, Equatable {
        case loopback
        /// Bound to this LAN address and still holding it.
        case localNetwork(String)
        /// Bound to this LAN address and the machine no longer has it — a
        /// Wi-Fi-to-Ethernet swap, a DHCP change, the radio going down.
        ///
        /// The server does not re-bind: the URL AVPlayer and the receiver were
        /// handed is baked into the item and every segment reference, so a new
        /// address would need a new session anyway. It refuses every request
        /// with `503` instead, so the failure is an honest error rather than a
        /// URL that hangs, and the host can see it on `serviceAddress`.
        case addressLost(String)
    }

    /// Resource bounds. Defaults are tuned for one AVPlayer talking to one
    /// remux session; tests dial them down.
    public struct Limits: Sendable {
        /// Requests served on one connection before the server says
        /// `Connection: close`. Bounds per-connection state growth without
        /// costing AVPlayer anything — it just opens a new socket.
        public var maxRequestsPerConnection: Int
        /// How long a connection may sit between requests before it's dropped.
        public var idleTimeout: Duration
        /// How long a provider may take before the server switches to early
        /// headers + chunked. Must stay well under AVPlayer's ~3.5 s watchdog.
        public var slowServeThreshold: Duration
        /// Cap on the request line (method + target + version).
        public var maxRequestLineBytes: Int
        /// Cap on the whole request head.
        public var maxHeaderBytes: Int

        public init(
            maxRequestsPerConnection: Int = 100,
            idleTimeout: Duration = .seconds(10),
            slowServeThreshold: Duration = .seconds(2),
            maxRequestLineBytes: Int = 8 * 1024,
            maxHeaderBytes: Int = 64 * 1024
        ) {
            self.maxRequestsPerConnection = maxRequestsPerConnection
            self.idleTimeout = idleTimeout
            self.slowServeThreshold = slowServeThreshold
            self.maxRequestLineBytes = maxRequestLineBytes
            self.maxHeaderBytes = maxHeaderBytes
        }
    }

    private let provider: SegmentProvider
    private let limits: Limits
    private let reachability: Reachability
    private var listener: NWListener?
    private var pathMonitor: NWPathMonitor?
    private var connections: [ObjectIdentifier: (connection: NWConnection, task: Task<Void, Never>)] = [:]
    private var isStopped = false
    /// The bound port, available after `start()`.
    public private(set) var port: UInt16 = 0
    /// The host in the published base URL, available after `start()`.
    public private(set) var host: String = "127.0.0.1"
    /// Where this server is reachable, and whether it still is.
    public private(set) var serviceAddress: ServiceAddress = .loopback
    /// The gate on every request in LAN mode; `nil` on loopback, where there
    /// is nobody to gate against.
    public private(set) var accessToken: SessionAccessToken?
    /// How the server learns which addresses this machine currently holds.
    private var assignedAddresses: @Sendable () -> Set<String> = {
        LocalNetworkInterface.assignedIPv4Addresses()
    }

    /// Serve a directory from disk — the v0 shape, unchanged in behavior.
    public init(root: URL, limits: Limits = Limits(), reachability: Reachability = .loopbackOnly) {
        self.init(
            provider: DirectorySegmentProvider(root: root),
            limits: limits,
            reachability: reachability
        )
    }

    public init(
        provider: SegmentProvider,
        limits: Limits = Limits(),
        reachability: Reachability = .loopbackOnly
    ) {
        self.provider = provider
        self.limits = limits
        self.reachability = reachability
    }

    /// Bind and listen. Returns the base URL — `http://127.0.0.1:<port>/` by
    /// default, and `http://<lan-ip>:<port>/<token>/` in LAN mode, where every
    /// relative reference inside the served playlists inherits the token
    /// prefix for free.
    @discardableResult
    public func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        var lanAddress: String?
        switch reachability {
        case .loopbackOnly:
            // Loopback only — never reachable off-device.
            parameters.requiredInterfaceType = .loopback
        case .localNetworkUnencryptedForAirPlay:
            guard let address = LocalNetworkInterface.preferredIPv4Address(),
                  let ipv4 = IPv4Address(address) else {
                throw NoLocalNetworkInterface()
            }
            lanAddress = address
            // Bound to the one address, not to `.any`: a server that also
            // answered on a VPN's `utun` or on Internet Sharing's bridge would
            // be exposed on networks the user never had in mind. A local
            // AVPlayer reaches this address too, so one bind serves both the
            // on-device player and the receiver.
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(ipv4), port: .any)
            accessToken = .random()
        }

        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.adopt(connection) }
        }

        let bound: UInt16 = try await withCheckedThrowingContinuation { continuation in
            // Resume-once guard, lock-protected: the state handler runs on
            // the listener queue and a `.failed` can chase a `.ready`.
            let once = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    once.run { continuation.resume(throwing: error) }
                case .cancelled:
                    once.run { continuation.resume(throwing: FailedToStart()) }
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
        listener.stateUpdateHandler = nil
        guard bound != 0 else { throw FailedToStart() }
        port = bound

        guard let lanAddress, let token = accessToken else {
            return URL(string: "http://127.0.0.1:\(bound)/")!
        }
        host = lanAddress
        serviceAddress = .localNetwork(lanAddress)
        startWatchingForAddressLoss()
        // The trailing slash matters: the token is a directory in the served
        // namespace, so `master.m3u8`'s own relative references
        // (`video/index.m3u8`, `seg00001.m4s`) resolve under it without the
        // playlist writer knowing the token exists.
        return URL(string: "http://\(lanAddress):\(bound)/\(token.value)/")!
    }

    /// A path change is the only cheap signal that the address we published
    /// may be gone; the enumeration is the check that says whether it is.
    private func startWatchingForAddressLoss() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { await self?.revalidateServiceAddress() }
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
    }

    /// Re-check whether the machine still holds the address this server
    /// published, and flip `serviceAddress` accordingly. Self-healing on
    /// purpose: a Wi-Fi blip that comes back with the same address goes back
    /// to serving instead of staying broken.
    public func revalidateServiceAddress() {
        let assigned = assignedAddresses()
        switch serviceAddress {
        case .loopback:
            break
        case .localNetwork(let address), .addressLost(let address):
            serviceAddress = assigned.contains(address)
                ? .localNetwork(address)
                : .addressLost(address)
        }
    }

    /// Point the check above at something other than this machine. The only
    /// way to exercise the address-loss path without unplugging a cable
    /// mid-run — and it has to be a seam rather than a one-shot state poke,
    /// because the path monitor re-checks against reality on its own schedule
    /// and would undo a poked state within milliseconds.
    func overrideAssignedAddresses(_ source: @escaping @Sendable () -> Set<String>) {
        assignedAddresses = source
    }

    /// Stop listening and tear down every connection, including ones with a
    /// response in flight.
    ///
    /// Cancelling the per-connection task alone would not be enough: a task
    /// parked in a `receive` continuation only wakes when Network tells it
    /// something, so the connection is cancelled too — that delivers an error
    /// to the pending callback and the task unwinds.
    public func stop() {
        isStopped = true
        listener?.cancel()
        listener = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        for entry in connections.values {
            entry.task.cancel()
            entry.connection.cancel()
        }
        connections.removeAll()
    }

    // MARK: - Connections

    private func adopt(_ connection: NWConnection) {
        guard !isStopped else {
            connection.cancel()
            return
        }
        connection.start(queue: .global(qos: .userInitiated))
        let task = Task { [weak self] in
            await self?.serve(connection)
            await self?.close(connection)
        }
        connections[ObjectIdentifier(connection)] = (connection, task)
    }

    private func close(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
        connection.cancel()
    }

    /// The keep-alive loop: read a request head, answer it, and go around
    /// again unless somebody said stop.
    private func serve(_ connection: NWConnection) async {
        // Bytes read past the current request's head. AVPlayer happily puts
        // two requests in one TCP segment, so what's left over is the start of
        // the next request, not garbage to drop.
        var buffered = Data()
        var served = 0

        while !Task.isCancelled, !isStopped {
            switch await readHead(on: connection, buffered: &buffered) {
            case .overlongRequestLine:
                _ = await send(Self.errorResponse(status: "414 URI Too Long"), on: connection)
                return
            case .overlongHead:
                _ = await send(Self.errorResponse(status: "431 Request Header Fields Too Large"), on: connection)
                return
            case .closed:
                return
            case .request(let raw):
                served += 1
                guard let request = Request(head: raw) else {
                    _ = await send(Self.errorResponse(status: "400 Bad Request"), on: connection)
                    return
                }
                // A request with a body would leave its bytes in the stream to
                // be misread as the next request line. We don't serve any
                // method that takes one, so answer and hang up rather than
                // guess where the body ends.
                let mustClose = request.wantsClose
                    || request.hasBody
                    || served >= limits.maxRequestsPerConnection
                let outcome = await respond(to: request, on: connection, keepAlive: !mustClose)
                switch outcome {
                case .aborted:
                    // Truncated on purpose — see the type doc.
                    return
                case .completed:
                    if mustClose { return }
                }
            }
        }
    }

    private enum Head {
        case request(String)
        case overlongRequestLine
        case overlongHead
        case closed
    }

    /// Read until the blank line that ends a request head, consuming it from
    /// `buffered` and leaving any pipelined remainder behind.
    private func readHead(on connection: NWConnection, buffered: inout Data) async -> Head {
        let terminator = Data("\r\n\r\n".utf8)
        while true {
            // Caps first, and on the partial buffer too: a whole head can
            // arrive in one segment, and a client that never sends the
            // terminator must not be able to grow the buffer without bound.
            if let lineEnd = buffered.range(of: Data("\r\n".utf8)) {
                if lineEnd.lowerBound - buffered.startIndex > limits.maxRequestLineBytes {
                    return .overlongRequestLine
                }
            } else if buffered.count > limits.maxRequestLineBytes {
                return .overlongRequestLine
            }
            if buffered.count > limits.maxHeaderBytes { return .overlongHead }

            if let end = buffered.range(of: terminator) {
                let head = String(decoding: buffered[..<end.lowerBound], as: UTF8.self)
                // Rebase so the remainder (a pipelined next request) starts at
                // index 0 for the following pass.
                buffered = Data(buffered[end.upperBound...])
                return .request(head)
            }

            // The idle timeout only covers the gap *between* requests. Once the
            // first bytes of a head have landed we're mid-request and simply
            // wait: a client that stalls there is dropped by `stop()` or by TCP.
            let chunk: (data: Data?, isComplete: Bool, failed: Bool)?
            if buffered.isEmpty {
                chunk = await withTimeout(limits.idleTimeout) { await self.receiveChunk(on: connection) }
                guard chunk != nil else { return .closed }  // idle too long
            } else {
                chunk = await receiveChunk(on: connection)
            }
            guard let chunk, !chunk.failed else { return .closed }
            if let data = chunk.data { buffered.append(data) }
            // Peer half-closed: whatever is buffered is all we'll ever get.
            if chunk.isComplete, buffered.range(of: terminator) == nil { return .closed }
        }
    }

    // MARK: - Requests

    /// Internal rather than private so the token gate can be unit-tested
    /// without a socket.
    struct Request {
        let method: String
        let path: String
        let wantsClose: Bool
        let hasBody: Bool
        /// `X-PrismCore-Token`, for clients that can set headers. AirPlay
        /// receivers cannot, which is why the path prefix is the primary form.
        let token: String?

        init?(head: String) {
            let lines = head.split(separator: "\r\n", omittingEmptySubsequences: true)
            let parts = lines.first?.split(separator: " ").map(String.init) ?? []
            guard parts.count >= 2 else { return nil }
            method = parts[0]
            path = parts[1]
            let version = parts.count >= 3 ? parts[2].uppercased() : "HTTP/1.1"

            var connectionHeader: String?
            var contentLength = 0
            var tokenHeader: String?
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].lowercased()
                // Kept verbatim: the token is case-sensitive base64url, and
                // lowercasing it — as the other headers are — would reject
                // every correct token that happens to contain a capital.
                let raw = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                let value = raw.lowercased()
                switch name {
                case "connection": connectionHeader = value
                case "content-length": contentLength = Int(value) ?? 0
                case "transfer-encoding": contentLength = value.isEmpty ? 0 : 1
                case SessionAccessToken.headerName.lowercased(): tokenHeader = raw
                default: break
                }
            }
            token = tokenHeader
            // HTTP/1.1 keeps the connection alive unless told otherwise; 1.0 is
            // the other way round.
            if version == "HTTP/1.0" {
                wantsClose = connectionHeader?.contains("keep-alive") != true
            } else {
                wantsClose = connectionHeader?.contains("close") == true
            }
            hasBody = contentLength > 0
        }

        /// Root-relative, query-stripped, percent-decoded path — or `nil` if it
        /// tries to escape the root or names nothing.
        var normalizedPath: String? {
            let raw = String(path.split(separator: "?").first ?? "/")
            let decoded = raw.removingPercentEncoding ?? raw
            let relative = decoded.hasPrefix("/") ? String(decoded.dropFirst()) : decoded
            guard !relative.isEmpty, !relative.contains("..") else { return nil }
            return relative
        }
    }

    /// The resource this request is asking for, once the token has been
    /// accounted for — or `nil` if it never presented one.
    ///
    /// Normalization runs FIRST, so `/<token>/../secret` is refused by the
    /// same traversal guard as ever: a token buys access to the namespace,
    /// never a way out of it.
    static func path(of request: Request, behind token: SessionAccessToken) -> String? {
        guard let normalized = request.normalizedPath else { return nil }
        if let separator = normalized.firstIndex(of: "/"),
           token.matches(normalized[..<separator]) {
            let rest = String(normalized[normalized.index(after: separator)...])
            return rest.isEmpty ? nil : rest
        }
        if let header = request.token, token.matches(header) { return normalized }
        return nil
    }

    private enum Outcome {
        case completed
        /// The connection was deliberately killed mid-response.
        case aborted
    }

    private func respond(to request: Request, on connection: NWConnection, keepAlive: Bool) async -> Outcome {
        // The address under the server moved. Everything below would answer
        // correctly and reach nobody, so say so instead.
        if case .addressLost = serviceAddress {
            _ = await send(Self.errorResponse(status: "503 Service Unavailable"), on: connection)
            return .completed
        }
        // In LAN mode the token gates everything, ahead of the method check:
        // a caller without it must not learn even which methods this server
        // implements. On loopback `accessToken` is nil and the order below is
        // exactly what it always was.
        var authorizedPath: String?
        if let token = accessToken {
            guard let path = Self.path(of: request, behind: token) else {
                // 404, not 403: a wrong token has to be indistinguishable from
                // a wrong path, or the server becomes an oracle that confirms
                // "something is here, keep guessing".
                _ = await send(Self.errorResponse(status: "404 Not Found", keepAlive: keepAlive), on: connection)
                return .completed
            }
            authorizedPath = path
        }
        guard request.method == "GET" || request.method == "HEAD" else {
            _ = await send(Self.errorResponse(status: "405 Method Not Allowed"), on: connection)
            return .completed
        }
        let headOnly = request.method == "HEAD"
        guard let path = authorizedPath ?? request.normalizedPath else {
            _ = await send(Self.errorResponse(status: "404 Not Found", keepAlive: keepAlive), on: connection)
            return .completed
        }

        switch await provider.data(forPath: path) {
        case .notFound:
            _ = await send(Self.errorResponse(status: "404 Not Found", keepAlive: keepAlive), on: connection)
            return .completed
        case .data(let body, let contentType):
            _ = await sendResponse(
                body: body, contentType: contentType, keepAlive: keepAlive, headOnly: headOnly, on: connection
            )
            return .completed
        case .pending(let pending):
            return await respondToPending(
                pending,
                path: path,
                on: connection,
                keepAlive: keepAlive,
                headOnly: headOnly
            )
        }
    }

    private func respondToPending(
        _ pending: PendingResult,
        path: String,
        on connection: NWConnection,
        keepAlive: Bool,
        headOnly: Bool
    ) async -> Outcome {
        // The resolution runs in its own task so the slow-serve race can give
        // up on *waiting* without giving up on the *work* — the payload is
        // still wanted, it just gets a different framing.
        let resolution = Task { await pending.resolve() }
        let quick = await withTimeout(limits.slowServeThreshold) { await resolution.value }

        if let quick {
            switch quick {
            case .data(let body, let contentType):
                _ = await sendResponse(
                    body: body, contentType: contentType, keepAlive: keepAlive, headOnly: headOnly, on: connection
                )
            default:
                _ = await send(Self.errorResponse(status: "404 Not Found", keepAlive: keepAlive), on: connection)
            }
            return .completed
        }

        // Slow serve. Headers go out now, before the watchdog notices the
        // silence. The content type has to be guessed from the path because the
        // provider hasn't spoken yet — fine here, where the extension is the
        // authority anyway (`.m4s` / `.mp4` / `.m3u8`).
        let contentType = Self.contentType(for: URL(fileURLWithPath: path))
        guard await send(Self.chunkedHeader(contentType: contentType, keepAlive: keepAlive), on: connection) else {
            resolution.cancel()
            return .aborted
        }
        // A HEAD response carries no body, so there is nothing left to stream;
        // the honest answer for an unknown length is the chunked framing with
        // an immediate terminator.
        if headOnly {
            _ = await send(Self.chunkTerminator, on: connection)
            return .completed
        }

        // `stop()` cancels this task; hand that through to the provider so a
        // teardown doesn't leave production running for a socket that's gone.
        let landed = await withTaskCancellationHandler {
            await resolution.value
        } onCancel: {
            resolution.cancel()
        }
        guard !Task.isCancelled else { return .aborted }

        switch landed {
        case .data(let body, _):
            guard await send(Self.chunk(body), on: connection),
                  await send(Self.chunkTerminator, on: connection)
            else { return .aborted }
            return .completed
        default:
            // Committed to a 200 and then missed. Abort the transfer instead of
            // terminating the chunk stream: a truncated body is a retry, a
            // clean empty 200 is a cached lie.
            connection.forceCancel()
            return .aborted
        }
    }

    // MARK: - Response framing

    /// Playlists grow (EVENT) or are the truth of the moment — never cached.
    /// Init segments, media segments and WebVTT segments are immutable for
    /// the life of their URL: the init is written once ("first write wins",
    /// see `HLSRemuxer.writeInitSegmentIfAbsent`), a re-produced media
    /// segment is the same bytes at the same time span, and the session's
    /// port dies with it — so AVPlayer may keep them rather than re-read and
    /// re-copy them across a seek.
    private static func commonHeaders(keepAlive: Bool, contentType: String? = nil) -> String {
        let immutable = contentType.map { $0 != "application/vnd.apple.mpegurl" } ?? false
        var headers = immutable
            ? "Cache-Control: max-age=86400, immutable\r\n"
            : "Cache-Control: no-store\r\n"
        if keepAlive {
            headers += "Connection: keep-alive\r\n"
        } else {
            headers += "Connection: close\r\n"
        }
        return headers
    }

    /// The header block for a whole-body 200. The body is sent as its own
    /// `send` (see `sendResponse`) — appending a multi-megabyte segment to a
    /// header `Data` was a full copy of the segment per request.
    static func responseHeader(bodyCount: Int, contentType: String, keepAlive: Bool) -> Data {
        var response = "HTTP/1.1 200 OK\r\n"
        response += "Content-Type: \(contentType)\r\n"
        response += "Content-Length: \(bodyCount)\r\n"
        response += "Accept-Ranges: none\r\n"
        response += commonHeaders(keepAlive: keepAlive, contentType: contentType)
        response += "\r\n"
        return Data(response.utf8)
    }

    /// Header and body as they go on the wire, for tests and for callers that
    /// want one buffer.
    static func response(body: Data, contentType: String, keepAlive: Bool, headOnly: Bool) -> Data {
        var payload = responseHeader(bodyCount: body.count, contentType: contentType, keepAlive: keepAlive)
        if !headOnly { payload.append(body) }
        return payload
    }

    /// Header, then body, as two sends on the connection. NWConnection
    /// serialises sends in order, so the wire is identical to one buffer —
    /// minus the copy of the body into it.
    private nonisolated func sendResponse(
        body: Data, contentType: String, keepAlive: Bool, headOnly: Bool, on connection: NWConnection
    ) async -> Bool {
        guard await send(
            Self.responseHeader(bodyCount: body.count, contentType: contentType, keepAlive: keepAlive),
            on: connection
        ) else { return false }
        if headOnly || body.isEmpty { return true }
        return await send(body, on: connection)
    }

    static func errorResponse(status: String, keepAlive: Bool = false) -> Data {
        var response = "HTTP/1.1 \(status)\r\n"
        response += "Content-Type: text/plain\r\n"
        response += "Content-Length: 0\r\n"
        response += commonHeaders(keepAlive: keepAlive)
        response += "\r\n"
        return Data(response.utf8)
    }

    static func chunkedHeader(contentType: String, keepAlive: Bool) -> Data {
        var response = "HTTP/1.1 200 OK\r\n"
        response += "Content-Type: \(contentType)\r\n"
        response += "Transfer-Encoding: chunked\r\n"
        response += commonHeaders(keepAlive: keepAlive, contentType: contentType)
        response += "\r\n"
        return Data(response.utf8)
    }

    static func chunk(_ body: Data) -> Data {
        var payload = Data(String(format: "%llx\r\n", UInt64(body.count)).utf8)
        payload.append(body)
        payload.append(Data("\r\n".utf8))
        return payload
    }

    static let chunkTerminator = Data("0\r\n\r\n".utf8)

    static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "mp4", "m4s": return "video/mp4"
        case "vtt": return "text/vtt"
        default: return "application/octet-stream"
        }
    }

    // MARK: - Network bridging

    private nonisolated func receiveChunk(
        on connection: NWConnection
    ) async -> (data: Data?, isComplete: Bool, failed: Bool) {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, isComplete, error in
                once.run { continuation.resume(returning: (data, isComplete, error != nil)) }
            }
        }
    }

    @discardableResult
    private nonisolated func send(_ payload: Data, on connection: NWConnection) async -> Bool {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            connection.send(content: payload, completion: .contentProcessed { error in
                once.run { continuation.resume(returning: error == nil) }
            })
        }
    }
}

/// Runs `work` but stops waiting after `timeout`, returning `nil` — the work
/// itself keeps running.
///
/// Deliberately not a task group: a group awaits all of its children before it
/// returns, which is exactly what a "give up on waiting" helper must not do.
func withTimeout<T: Sendable>(
    _ timeout: Duration,
    _ work: @escaping @Sendable () async -> T
) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let once = ResumeOnce()
        let timer = Task {
            try? await Task.sleep(for: timeout)
            once.run { continuation.resume(returning: nil) }
        }
        Task {
            let value = await work()
            timer.cancel()
            once.run { continuation.resume(returning: value) }
        }
    }
}

/// Runs its block at most once, under a lock — the resume-once guard for
/// continuation-bridged callbacks (the `ASWebAuthenticationSession.cancel()`
/// lesson: never trust a callback to fire exactly once).
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ block: () -> Void) {
        let shouldRun: Bool = lock.withLock {
            guard !done else { return false }
            done = true
            return true
        }
        if shouldRun { block() }
    }
}
