import Foundation

/// One subtitle rendition on disk: `subs<N>/seg%05d.vtt` segments plus
/// `subs<N>/index.m3u8`, cut on the **same wall-time boundaries as the video
/// segments** so the two playlists line up 1:1 (what AVPlayer expects of a
/// `SUBTITLES` rendition, and what keeps its segment fetches predictable).
///
/// ### Timeline and `X-TIMESTAMP-MAP`
///
/// WebVTT cue times are local to the file, so HLS bridges them to the media
/// timeline with `X-TIMESTAMP-MAP=MPEGTS:<t>,LOCAL:<local>`: the player reads it
/// as "local time `LOCAL` is media timestamp `t`", where `t` is on a **90 kHz**
/// axis regardless of what timescale the media segments use (RFC 8216 §3.5).
///
/// Our media segments are fMP4 carrying the source's own stream-copied
/// timestamps, so the media timeline starts at the source's first video PTS —
/// there is no MPEG-TS 10 s convention to honour here, and assuming one is
/// exactly the bug that makes fMP4 subtitle tracks render ~10 s late elsewhere.
/// So:
///
/// - cue times are written **relative to the presentation origin** (the first
///   video PTS), i.e. a cue one second into playback prints `00:00:01.000`;
/// - every segment repeats `MPEGTS:round(origin × 90000),LOCAL:00:00:00.000`,
///   which is the offset that carries the origin back onto the media axis.
///
/// For the ordinary source whose first PTS is 0 that reduces to `MPEGTS:0`, and
/// for a mid-stream capture starting at 10 s it prints `MPEGTS:900000` because
/// the video really does start there — the map states a fact about the output
/// rather than a convention.
final class WebVTTRenditionWriter {

    /// Cue whose packet duration was missing or non-positive. Matroska text
    /// blocks carry a real duration; a `tx3g` sample or a damaged block may
    /// not, and a zero-length cue is invisible.
    static let fallbackCueSeconds = 3.0

    private let directory: URL
    private let playlist: MediaPlaylistWriter
    /// Presentation origin in source seconds. Cues and boundaries arrive on the
    /// source's own axis and are printed relative to this.
    private var originSeconds: Double = 0
    /// Cues not yet fully written out, ordered by start time. A cue that
    /// extends past the current boundary stays here so the next segment can
    /// repeat it (standard segmented-VTT practice).
    private var pending: [SubtitleCue] = []
    private var segmentIndex = 0
    /// Planned mode: playlist published upfront; flushes write files only.
    private var plannedMode = false

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // No EXT-X-MAP: a WebVTT rendition has no init segment.
        self.playlist = MediaPlaylistWriter(directory: directory, initFileName: nil)
    }

    /// Presentation origin in seconds on the source's own timeline — the value
    /// the timestamp map carries. Set before the first flush.
    func setTimelineOrigin(seconds: Double) {
        originSeconds = max(0, seconds)
    }

    /// `MPEGTS` value paired with `LOCAL:00:00:00.000`, on the 90 kHz axis.
    var mpegtsOffset: Int64 {
        Int64((originSeconds * 90_000).rounded())
    }

    func add(_ cue: SubtitleCue) {
        guard !cue.overlapsNothing, !cue.text.isEmpty else { return }
        pending.append(cue)
    }

    /// Write the segment covering `[start, end)` — **source seconds**, the same
    /// axis the cues arrive on. Always writes a file, even with no cues in
    /// range: the rendition must have as many segments as the video, and an
    /// empty segment is a header-only `.vtt`.
    /// Planned mode: complete playlist upfront, files as ranges get produced.
    /// Segments never produced are the provider's to answer (header-only VTT).
    func writePlannedVOD(durations: [Double]) throws {
        plannedMode = true
        try playlist.writePlannedVOD(durations: durations) { index in
            String(format: "seg%05d.vtt", index)
        }
    }

    /// The index the NEXT `flushSegment` will write — what a caller needs to
    /// bookkeep per-segment state alongside the write it is about to trigger.
    var nextSegmentIndex: Int { segmentIndex }

    /// Demand-driven jump: continue numbering at the anchor and forget cues
    /// wholly before it (a later backward jump reproduces them from the
    /// demuxer's own re-read).
    func reanchor(segmentIndex: Int, startSeconds: Double) {
        self.segmentIndex = segmentIndex
        pending.removeAll { $0.end <= startSeconds }
    }

    func flushSegment(start: Double, end: Double) throws {
        let range = start...max(start, end)
        let inRange = pending
            .filter { $0.start < range.upperBound && $0.end > range.lowerBound }
            .map { $0.clamped(to: range) }
            .filter { !$0.overlapsNothing }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
            // Printed relative to the origin; the timestamp map carries the
            // origin itself back onto the media axis.
            .map { cue in
                var rebased = cue
                rebased.start -= originSeconds
                rebased.end -= originSeconds
                return rebased
            }

        let file = String(format: "seg%05d.vtt", segmentIndex)
        try Data(Self.render(cues: inRange, mpegtsOffset: mpegtsOffset).utf8)
            .write(to: directory.appendingPathComponent(file), options: .atomic)
        if !plannedMode {
            try playlist.appendSegment(duration: max(0.001, end - start), file: file)
        }
        segmentIndex += 1

        // Keep only what a later segment still has to repeat.
        pending.removeAll { $0.end <= range.upperBound }
    }

    /// `EXT-X-ENDLIST` on the rendition playlist (no-op in planned mode —
    /// the upfront playlist already ended).
    func finish() throws {
        guard !plannedMode else { return }
        try playlist.finish()
    }

    /// The WebVTT body for one segment.
    ///
    /// The blank line after the timestamp map is **not** cosmetic: it is what
    /// ends the header block. A segment with cues used to get one for free
    /// (each cue was written with a leading newline), but a cue-less segment —
    /// the common case, since a rendition is cut on the video's boundaries and
    /// most of a film's segments carry no dialogue — ended on the map line with
    /// the header still open, and the parser then read that line as a cue
    /// without timings (`kFigWebVTTSampleBufferError_CueParseError`, "Couldn't
    /// find --> in cue", once per empty segment for the whole playback).
    /// So the header is terminated here, once, whether or not a cue follows.
    static func render(cues: [SubtitleCue], mpegtsOffset: Int64) -> String {
        var text = "WEBVTT\n"
        text += "X-TIMESTAMP-MAP=MPEGTS:\(mpegtsOffset),LOCAL:00:00:00.000\n\n"
        for cue in cues {
            text += "\(webVTTTimestamp(cue.start)) --> \(webVTTTimestamp(cue.end))"
            // Settings share the timing line, separated by a single space.
            // They arrive pre-sanitized (`TextCuePlacement`): a newline here
            // would end the cue before its payload.
            if let settings = cue.settings, !settings.isEmpty { text += " " + settings }
            text += "\n"
            // Every cue ends with its own blank line, so the last one leaves the
            // file terminated too — a cue block cut off by EOF is the same
            // parse hazard in a different place.
            text += cue.text + "\n\n"
        }
        return text
    }
}
