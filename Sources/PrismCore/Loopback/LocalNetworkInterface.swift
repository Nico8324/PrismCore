import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Which of this machine's addresses an AirPlay receiver could dial.
///
/// Only IPv4 is enumerated, deliberately. An IPv6 literal in an HLS URL has to
/// be bracketed, a link-local one also needs a `%zone` suffix that receivers
/// handle inconsistently, and Apple platforms rotate temporary privacy
/// addresses on their own schedule — which would turn "the address changed
/// mid-session" from an edge case into the normal case. Every AirPlay receiver
/// on a home network is reachable over IPv4, so the extra surface buys nothing.
enum LocalNetworkInterface {

    /// One candidate address, with the fields that decide ties.
    struct Candidate: Sendable, Equatable {
        let name: String
        let address: String
        /// Lower is better. See `rank(forInterfaceNamed:)`.
        let rank: Int
        /// The trailing digits of the interface name (`en0` → 0), so `en0`
        /// beats `en5` deterministically instead of by `getifaddrs` order —
        /// which is stable in practice but promised nowhere.
        let ordinal: Int
    }

    /// Interfaces that carry an IPv4 address but are never the route to an
    /// AirPlay receiver.
    ///
    /// `awdl`/`llw`/`nan` are Apple's peer-to-peer radios, `utun`/`ipsec`/`ppp`
    /// are tunnels (a VPN's address is routable only inside the tunnel, and
    /// handing a receiver one is a URL that can only time out), `anpi` is the
    /// internal link to Apple silicon's co-processors, `gif`/`stf` are v6
    /// transition stubs, and `vmenet` is a virtual-machine link.
    private static let excludedPrefixes = [
        "awdl", "llw", "nan", "utun", "ipsec", "ppp", "anpi", "gif", "stf", "vmenet",
    ]

    /// `nil` means "never serve from this interface".
    static func rank(forInterfaceNamed name: String) -> Int? {
        for prefix in excludedPrefixes where name.hasPrefix(prefix) { return nil }
        if name.hasPrefix("en") { return 0 }
        // Internet Sharing and VM bridges are real and up, but usually a
        // private subnet nothing else lives on — last resort, never a
        // preference over a real `en`.
        if name.hasPrefix("bridge") { return 20 }
        return 10
    }

    /// Every up-and-running IPv4 interface that could plausibly reach a
    /// receiver, best first.
    static func candidates() -> [Candidate] {
        #if canImport(Darwin)
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var found: [Candidate] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sockaddr = entry.pointee.ifa_addr,
                  sockaddr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(entry.pointee.ifa_flags)
            // RUNNING as well as UP, and no point-to-point links: a tunnel is
            // UP with a perfectly real address that only its own peer can
            // reach, and a radio that is up but not running has a stale
            // address that binds fine — both failures would surface only as a
            // receiver that never connects.
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  flags & IFF_LOOPBACK == 0, flags & IFF_POINTOPOINT == 0 else { continue }

            let name = String(cString: entry.pointee.ifa_name)
            guard let rank = rank(forInterfaceNamed: name) else { continue }

            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                sockaddr, socklen_t(sockaddr.pointee.sa_len),
                &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            let address = String(cString: buffer)
            // 169.254/16 is what an interface self-assigns when DHCP failed:
            // an address, but not one anybody can route to.
            guard !address.hasPrefix("169.254."), address != "0.0.0.0" else { continue }

            found.append(Candidate(
                name: name,
                address: address,
                rank: rank,
                ordinal: Int(name.drop(while: { !$0.isNumber })) ?? Int.max
            ))
        }
        return found.sorted {
            ($0.rank, $0.ordinal, $0.name) < ($1.rank, $1.ordinal, $1.name)
        }
        #else
        return []
        #endif
    }

    /// The address to bind and to publish, or `nil` when this machine has no
    /// LAN footing at all (Wi-Fi off, cable out).
    static func preferredIPv4Address() -> String? {
        candidates().first?.address
    }

    /// Every IPv4 address currently assigned to this machine, including ones
    /// `candidates()` would refuse to serve from — this answers "is the
    /// address I bound still mine?", which is a different question from "which
    /// address should I bind?".
    static func assignedIPv4Addresses() -> Set<String> {
        #if canImport(Darwin)
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var addresses: Set<String> = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sockaddr = entry.pointee.ifa_addr,
                  sockaddr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                sockaddr, socklen_t(sockaddr.pointee.sa_len),
                &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            addresses.insert(String(cString: buffer))
        }
        return addresses
        #else
        return []
        #endif
    }
}
