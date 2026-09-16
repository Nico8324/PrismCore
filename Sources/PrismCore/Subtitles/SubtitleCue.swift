import Foundation

/// One timed text cue on the **presentation timeline**, in seconds.
///
/// Deliberately container- and codec-agnostic: everything upstream (a Matroska
/// `subrip` packet, an ASS event, a whole `.srt` sidecar) converges here, and
/// everything downstream (the segmented WebVTT writer) only ever sees this.
/// That is what lets the conversion rules be unit-tested without a demuxer.
struct SubtitleCue: Equatable {
    /// Seconds from the presentation origin (see `SubtitleRenditionSet` for
    /// what the origin is and why the WebVTT timestamp map carries it).
    var start: Double
    var end: Double
    /// Cue payload, already WebVTT-safe (no `-->`, no blank lines).
    var text: String
    /// WebVTT cue settings printed after the timing (`line:5% align:start`),
    /// already reduced to the safe subset — a settings string shares the
    /// timing line, so it has the payload's hazards without its escaping.
    /// `nil` for the renderer's default placement, which is nearly every cue.
    var settings: String? = nil
    /// The placement the source asked for, for hosts that draw text
    /// themselves; `settings` is its WebVTT rendering (or the source's own).
    var placement: TextCuePlacement? = nil

    /// Clamped copy for a segment that only partially contains this cue.
    func clamped(to range: ClosedRange<Double>) -> SubtitleCue {
        var copy = self
        copy.start = Swift.max(start, range.lowerBound)
        copy.end = Swift.min(end, range.upperBound)
        return copy
    }

    /// Copy with a (usually earlier) known end — how an open-ended bitmap
    /// cue gets closed by the event that displaces it.
    func ending(at seconds: Double) -> SubtitleCue {
        var copy = self
        copy.end = Swift.min(end, seconds)
        return copy
    }

    var overlapsNothing: Bool { end <= start }
}

/// `HH:MM:SS.mmm` — the only timestamp form WebVTT cue timings take (the
/// `MM:SS.mmm` short form is legal but we always print hours, which is what
/// every reference manifest does and what keeps the widths fixed).
func webVTTTimestamp(_ seconds: Double) -> String {
    let clamped = max(0, seconds)
    // Round to whole milliseconds FIRST: formatting the components separately
    // from a Double would print 59.9996 s as "00:00:60.000".
    let totalMilliseconds = Int64((clamped * 1000).rounded())
    let milliseconds = totalMilliseconds % 1000
    let totalSeconds = totalMilliseconds / 1000
    return String(
        format: "%02lld:%02lld:%02lld.%03lld",
        totalSeconds / 3600,
        (totalSeconds % 3600) / 60,
        totalSeconds % 60,
        milliseconds
    )
}
