import Foundation

/// One thing that really happened during `PrismCoreSession.start()`, with the
/// time it happened at.
///
/// `start()` can legitimately take twenty seconds on a slow origin, and until
/// these existed a host could only show a spinner: it could not tell "still
/// opening the file over SMB" from "probed fine, muxing the first segment",
/// and so could not tell the user anything, or decide that *this* one is
/// hopeless while a slower but progressing one is not.
public struct StartupCheckpoint: Sendable, Equatable {
    public let phase: StartupPhase
    /// Time from the `start()` call to this checkpoint, stamped at the moment
    /// the event happened rather than when the host got around to reading it.
    ///
    /// This is the diagnostic payoff: a host that logs the five checkpoints
    /// knows which of them ate the twenty seconds, which is the difference
    /// between "the server is slow" and "our planner is slow" — a distinction
    /// no amount of staring at a timeout tells you.
    public let elapsed: Duration

    public init(phase: StartupPhase, elapsed: Duration) {
        self.phase = phase
        self.elapsed = elapsed
    }
}

/// The stages a session passes through on its way to a playable playlist, in
/// the order they occur.
///
/// Deliberately **not** a percentage. Nobody — not the engine, not the host —
/// knows in advance how long a probe over a slow origin takes, so a fraction
/// would be a number invented to fill a progress bar. Stages with timestamps
/// are things that happened; a fraction would be a claim the engine cannot
/// measure, and this engine does not make those.
public enum StartupPhase: Sendable, Equatable {
    /// The source is open and `avformat_find_stream_info` has returned: the
    /// demuxer is usable. On a remote origin this is usually the long one.
    ///
    /// A session handed a `ProbedSource` reaches this almost immediately —
    /// the context was opened by the routing probe and is adopted, not
    /// reopened.
    case sourceOpened

    /// What the source turned out to be: tracks, codecs, languages, chapters,
    /// the video's dynamic range and its declared Dolby Vision configuration.
    ///
    /// The container's own claims. The bitstream answers that outrank them —
    /// whether an E-AC-3 track really carries JOC most of all — come later,
    /// from `PrismCoreSession.objectAudio`, because they need produced
    /// packets to read (see AGENTS.md on `AVCodecParameters.profile`).
    case streamInfoResolved(SourceInfo)

    /// The segmentation is decided. `origin` is worth surfacing rather than
    /// hiding: the three cases cost wildly different amounts of time and
    /// produce differently seekable sessions, and a host that wants to say
    /// "first play of this file is sequential" can only know it from here.
    case segmentPlanReady(origin: SegmentPlanOrigin, segments: Int)

    /// A video segment is on disk — under `delay_moov` this is also the cut
    /// that mints the init segment, so it is the first moment anything is
    /// fetchable at all. `index` is its position in the playlist; during
    /// startup that is 0, and it is reported rather than assumed.
    case firstVideoSegmentWritten(index: Int)

    /// Everything the playlist references exists and `start()` is about to
    /// return this URL. The last checkpoint of a successful startup.
    case playlistServable(URL)
}

/// Where a session's segment boundaries came from.
public enum SegmentPlanOrigin: String, Sendable, Equatable {
    /// A keyframe map harvested by an earlier play of the same source
    /// (`keyframeIndexCacheDirectory`). The cheapest of the three: it also
    /// skips the index-load seek, so this can beat a well-indexed first play.
    case keyframeIndexCache
    /// Built from the source itself this time — the container's seek index,
    /// loaded within the index-load budget. Costs a seek, and over HTTP a
    /// seek is a Range request against the tail of the file.
    case builtFromSource
    /// No trustworthy plan: the session runs sequentially (an EVENT playlist
    /// that grows as the producer reads). `segments` is 0 — the count is not
    /// known in advance, which is exactly what makes this case what it is.
    case sequential
}
