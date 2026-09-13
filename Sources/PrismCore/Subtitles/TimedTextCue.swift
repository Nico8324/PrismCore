import Foundation

/// One timed text cue of an embedded subtitle stream, handed to the host as
/// the demux produces it — the host-facing twin of the internal `SubtitleCue`.
///
/// Exists because the WebVTT renditions are not always the right delivery for
/// text: AVPlayer times a `SUBTITLES` rendition on its own segment schedule,
/// which is where the late-cue drift class of bugs lives, while a host that
/// draws captions itself wants the cue list on the player's own clock. Plex's
/// subtitle-only transcode turned out to answer empty documents for embedded
/// tracks (Aether#1533), so "ask the server for the text" is not a route — the
/// demux this engine already runs is the one honest source of embedded cues.
///
/// Times are **seconds on the producer's playback clock**. Remux callbacks
/// subtract the source's presentation origin for comparison with
/// `AVPlayerItem.currentTime()`. `SoftwarePlaybackPipeline.activeSubtitleCues`
/// keeps source timestamps, matching that pipeline's `currentTime`.
public struct TimedTextCue: Sendable, Equatable {
    /// The source stream this cue came from — the same index
    /// `SubtitleTrackInfo.streamIndex` reports, so a host can route cues to
    /// the track the viewer selected.
    public let streamIndex: Int32
    /// Seconds on the producing pipeline's playback clock (see above).
    public let start: Double
    public let end: Double
    /// Cue payload as the converter produced it — WebVTT-safe plain text,
    /// possibly carrying simple inline tags (`<i>`, `<b>`) the source had.
    public let text: String

    public init(streamIndex: Int32, start: Double, end: Double, text: String) {
        self.streamIndex = streamIndex
        self.start = start
        self.end = end
        self.text = text
    }
}
