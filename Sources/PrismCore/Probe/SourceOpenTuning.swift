import Foundation
import Libavformat

/// How much of a source libavformat may read before it has to answer what is
/// in it — the setting that decides what "opening a file" costs over a network.
///
/// FFmpeg's defaults (5 MB probe, 5 s of analysis) are tuned for containers
/// that hide their structure. The ones PrismCore takes describe themselves in
/// their header: Matroska carries CodecPrivate, MP4 carries the whole `moov`.
/// Measured against a 5.4 GB HEVC/EAC3 remux over HTTP, one open cost
/// **1.31 MB across 3 requests** at the defaults and **0.92 MB** capped — and
/// on a living-room Wi-Fi link to a media server that difference is the
/// visible part of "Preparing…", paid twice because the routing probe and the
/// remuxer each open the source.
///
/// The caps are a *ceiling*, not a target: libavformat stops as soon as it has
/// what it needs, so a well-formed file reads far less than either number.
/// What they bound is the pathological case — sparse audio, junk streams, a
/// container that never settles — where the analysis would otherwise read
/// megabytes to learn nothing new.
public enum SourceOpenTuning {

    /// Bytes libavformat may read while probing the container. Comfortably
    /// past a Matroska header with dozens of tracks, well short of the default.
    public static let probeSizeBytes = 4 << 20

    /// Microseconds of content the analysis may consume. Two seconds covers
    /// audio sparse enough to matter (a 1 s cap loses nothing on this corpus,
    /// but a stream with a long silent lead-in is exactly the case not worth
    /// being clever about).
    public static let analyzeDurationMicroseconds = 2_000_000

    /// How long a probe may spend before it answers with an error instead.
    ///
    /// A probe with no deadline is a playback with no fallback: a server that
    /// accepts the connection and then starves the reads (busy transcoding,
    /// sleeping disk) left the host with neither a verdict nor an error — the
    /// 2026-08-14 field log shows five play attempts over four minutes with
    /// no line from the engine at all, because `avformat_open_input` was
    /// still blocked on the first. Generous on purpose: a healthy probe over
    /// LAN answers in well under a second, so the budget only ever cuts off
    /// sources that were not going to answer.
    public static let probeBudget: Duration = .seconds(10)

    /// How long one blocking read may wait for bytes before it fails and the
    /// connection is reopened — the same 15 s the coordinated reader gives a
    /// request (`HTTPRangeInput`).
    public static let readTimeoutMicroseconds = 15_000_000

    /// The options every open should carry: the caller's HTTP headers, the
    /// reconnect policy the demux side needs, and the caps above.
    ///
    /// Returns an owned dictionary — the caller frees it with `av_dict_free`.
    static func makeOptions(httpHeaders: [String: String]) -> OpaquePointer? {
        var options: OpaquePointer?
        if !httpHeaders.isEmpty {
            let headerBlob = httpHeaders.map { "\($0.key): \($0.value)\r\n" }.joined()
            av_dict_set(&options, "headers", headerBlob, 0)
        }
        // Reconnect on dropped HTTP connections — the demuxer read side.
        av_dict_set(&options, "reconnect", "1", 0)
        av_dict_set(&options, "reconnect_streamed", "1", 0)
        // A read that gets nothing for this long fails, and the reconnect
        // above takes it from there. FFmpeg's default is to wait forever, so
        // an origin that goes silent without closing the socket (a debrid CDN
        // under load does) left playback stalled with nothing to recover it.
        av_dict_set(&options, "rw_timeout", String(readTimeoutMicroseconds), 0)
        // Deliberately NOT `multiple_requests=1` (HTTP keep-alive). Measured
        // 2026-08-26 against a Range-capable loopback server, one session
        // start over a 30 s MKV: without it 4 requests on 4 connections;
        // with it 5–6 requests on 2–3 connections — the socket was reused,
        // but a duplicated Range request appeared in two runs of three, so
        // the round trips did not go down, and keep-alive semantics against
        // Plex/Jellyfin/Emby were an untested risk for no measured gain.
        av_dict_set(&options, "probesize", String(probeSizeBytes), 0)
        av_dict_set(&options, "analyzeduration", String(analyzeDurationMicroseconds), 0)
        return options
    }
}
