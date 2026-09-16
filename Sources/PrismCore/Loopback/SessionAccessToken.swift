import Foundation
import Security

/// The unguessable per-session secret that gates a LAN-reachable server.
///
/// It is the first path component of every URL the session publishes
/// (`http://10.0.0.7:51234/<token>/master.m3u8`) because that is the only
/// channel AirPlay gives us: the receiver fetches the playlist and its segments
/// with its own HTTP client, and nothing in the HLS handoff lets us attach a
/// header to those fetches. The header form exists for hosts that drive the
/// server themselves.
///
/// 192 bits from the system CSPRNG. Sized so that guessing is not a strategy on
/// a network where an attacker can also just try every port: at one guess per
/// packet there is no rate that matters.
public struct SessionAccessToken: Sendable, Equatable {

    /// The header a non-AirPlay client may present instead of the path prefix.
    public static let headerName = "X-PrismCore-Token"

    public let value: String

    init(value: String) {
        self.value = value
    }

    static func random() -> SessionAccessToken {
        var bytes = [UInt8](repeating: 0, count: 24)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // Never observed, but a token that silently degraded to a
            // predictable source would be worse than a loud fallback:
            // `SystemRandomNumberGenerator` is the platform CSPRNG too.
            var generator = SystemRandomNumberGenerator()
            bytes = (0..<bytes.count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        // base64url: the token rides in a URL path, so `+` and `/` (which
        // would split the component) and `=` must not appear.
        let encoded = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return SessionAccessToken(value: encoded)
    }

    /// Compare without leaking where the first mismatch is. The timing signal
    /// from a byte-at-a-time comparison is tiny over a LAN and almost certainly
    /// unexploitable — but "almost certainly" is not a reason to hand it over,
    /// and the constant-time form costs nothing here.
    func matches(_ candidate: some StringProtocol) -> Bool {
        let mine = Array(value.utf8)
        let theirs = Array(candidate.utf8)
        guard mine.count == theirs.count else { return false }
        var difference: UInt8 = 0
        for index in mine.indices { difference |= mine[index] ^ theirs[index] }
        return difference == 0
    }
}
