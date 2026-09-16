import Foundation

extension URLSession {

    /// The session every test fetches through — `URLSession.shared` is not
    /// safe here.
    ///
    /// These tests ask what the loopback SERVER answers, and the server marks
    /// init, media and WebVTT segments `max-age=86400, immutable` on purpose.
    /// `URLSession.shared` carries a process-wide `URLCache` that keys on the
    /// URL and will happily answer a **HEAD** out of a cached **GET** — body
    /// included. Measured on this server: a HEAD issued straight after the GET
    /// came back with the full 300 000-byte body 15 times out of 15, and with
    /// three unrelated fetches in between (the shape of
    /// `SeekSteadyStateTests.cacheHeadersAndTwoSends`) 0 to 2 times out of 15.
    /// That timing dependence is what made the suite flaky under parallel
    /// load: the assertion was about the server and the answer came from
    /// CFNetwork.
    ///
    /// The same trap is latent in every test that fetches one URL twice, which
    /// is why the whole target goes through this session rather than the one
    /// suite that was caught. (Ports are not the extra hazard they look like:
    /// 120 servers alive at once never shared a port, and 200 sequential
    /// start/stop cycles never reused one, so a cached entry cannot be
    /// inherited by a later session's server.)
    static let uncached: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }()
}
