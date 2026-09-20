import Foundation
import Libavformat
import Libavutil

/// The upfront map of a VOD source's segments — the piece that turns "play
/// from the head" into "seek anywhere" (phase 5).
///
/// v0 grew an EVENT playlist as it produced, so AVPlayer only knew about
/// segments that already existed and a seek past the produced window had
/// nowhere to go. A plan enumerates EVERY segment before playback: the
/// playlist can be published complete (real VOD, ENDLIST and all), AVPlayer
/// seeks by simply fetching the segment at the target, and the producer's job
/// becomes "make the requested segment exist" instead of "run to EOF".
///
/// Boundaries follow the same shape v0 cut live: segment N ends at the first
/// video keyframe at-or-after `(N+1) × targetSeconds`, so every segment opens
/// decodable on its own. The keyframe positions come from the demuxer's index
/// (Matroska Cues / MP4 `stss`+`stts`, loaded by a bounded seek); an index is
/// only trusted past two witnesses, because index quality varies wildly:
///
/// - **gap**: the largest distance between consecutive keyframes must stay
///   under a cap. A clustered MPEG-TS index can gap by thousands of seconds,
///   and trusting it would plan a single monstrous segment.
/// - **coverage**: the indexed keyframes must span at least one target
///   duration. A remote MKV whose Cues tail read failed leaves only the
///   open-time keyframes, bunched at the head — tiny gaps (witness 1 passes)
///   but nothing reaches even the first boundary.
///
/// An untrusted index degrades to a **uniform plan**: fixed-duration entries
/// whose positions are timestamps, not keyframes. The producer then seeks by
/// time and cuts at whatever keyframe the demuxer lands on — less precise,
/// never wrong (a landed keyframe is still a keyframe).
struct SegmentPlan: Equatable {

    struct Entry: Equatable {
        /// Segment start on the video stream's time base.
        let startPTS: Int64
        /// Planned duration in seconds (the playlist's EXTINF).
        let duration: Double
    }

    enum Basis: Equatable {
        /// Boundaries sit on indexed keyframes — seeks land exactly.
        case keyframeIndex
        /// Uniform stride fallback — boundaries are time targets.
        case uniform
    }

    let entries: [Entry]
    let basis: Basis
    /// The video stream's time base the entries' PTS live on.
    let timeBaseNum: Int32
    let timeBaseDen: Int32

    /// Largest tolerated keyframe gap before the index is declared junk.
    /// Generous: open-GOP 10 s intervals are real; 60 s is not a VOD cadence.
    static let maxTrustedGapSeconds = 60.0

    /// How long the FIRST segment aims to be, in seconds. Only the first: it
    /// is the one `start()` has to wait for, and under `delay_moov` the init
    /// segment does not exist until it is cut — so every second planned into
    /// it is a second of source demuxed and muxed (video AND every audio
    /// rendition) before AVPlayer can be handed a URL at all. Two seconds is
    /// the common keyframe cadence, so on most sources this cut lands on the
    /// very next keyframe; the rest of the plan keeps `targetSeconds`, and
    /// TARGETDURATION is the ceiling of the longest entry, so the mixed
    /// durations are legal HLS.
    static let defaultFirstSegmentSeconds = 2

    // MARK: - Building

    /// How long the index-load seek may spend before it is abandoned.
    ///
    /// The seek is only "bounded" when an index EXISTS: a Matroska with no
    /// Cues turns any timestamp seek into a linear scan of the whole file,
    /// and over a slow transport (an SMB mount was the field case — 5.4 GB,
    /// 66 s for one seek) that eats the session's entire startup budget
    /// before the master playlist is ever written. Files with an index load
    /// it in a fraction of a second, so a generous cap costs them nothing.
    static let indexLoadBudget: Duration = .seconds(3)

    /// Build a plan from an OPENED input whose stream info has been read.
    /// `duration` comes from the container; sources that don't know theirs
    /// (live) have no plan — the caller stays on the v0 event path.
    ///
    /// `indexLoadBudget` bounds the index-load seek by wall clock, **through
    /// `interruptGuard`** — which must be the guard the context was *opened*
    /// with. The blocking reads check the URLContext's copy of the callback,
    /// taken at open; a callback installed here, on the format context, never
    /// reaches them, which is the 1.1.1 mistake this signature exists to make
    /// unrepeatable (issue #39). On expiry the seek aborts, the read position
    /// returns to the head, and the plan degrades to `.uniform` exactly like
    /// an untrusted index — the caller then skips demand mode rather than the
    /// whole session timing out. A `nil` guard means an unbounded seek.
    ///
    /// `cachedKeyframes` short-circuits the demuxer's index entirely: the
    /// keyframe map a previous play's producer harvested
    /// (`KeyframeIndexCache`) stands in for it, and neither seek runs — the
    /// read position stays at the head, where the caller put it. The map
    /// still faces the same two witnesses as a demuxer index; a stale or
    /// sparse one degrades to uniform exactly like a junk index would.
    static func build(
        input: UnsafeMutablePointer<AVFormatContext>,
        videoStreamIndex: Int32,
        targetSeconds: Int,
        firstSegmentSeconds: Int = SegmentPlan.defaultFirstSegmentSeconds,
        indexLoadBudget: Duration = SegmentPlan.indexLoadBudget,
        interruptGuard: ReadInterruptGuard? = nil,
        cachedKeyframes: [Int64]? = nil,
        cachedCoveredThroughPTS: Int64? = nil
    ) -> SegmentPlan? {
        buildReportingPosition(
            input: input, videoStreamIndex: videoStreamIndex, targetSeconds: targetSeconds,
            firstSegmentSeconds: firstSegmentSeconds, indexLoadBudget: indexLoadBudget,
            interruptGuard: interruptGuard, cachedKeyframes: cachedKeyframes,
            cachedCoveredThroughPTS: cachedCoveredThroughPTS
        ).plan
    }

    /// `build`, also reporting whether it left the read position at the
    /// head. The index-load path ends with a seek to 0, so a caller that
    /// adopted a context positioned mid-file (the probe's) can skip its own
    /// rewind — over HTTP that rewind is a Range request of its own. `false`
    /// when no seek ran: cached map, an index already loaded at open, or an
    /// early exit — the caller then rewinds itself.
    ///
    /// `cachedCoveredThroughPTS` marks a PARTIAL cached map (a play cancelled
    /// before EOF): keyframes are trusted only up to it, and the plan
    /// continues past it on the uniform stride (see `keyframePlan`).
    static func buildReportingPosition(
        input: UnsafeMutablePointer<AVFormatContext>,
        videoStreamIndex: Int32,
        targetSeconds: Int,
        firstSegmentSeconds: Int = SegmentPlan.defaultFirstSegmentSeconds,
        indexLoadBudget: Duration = SegmentPlan.indexLoadBudget,
        interruptGuard: ReadInterruptGuard? = nil,
        cachedKeyframes: [Int64]? = nil,
        cachedCoveredThroughPTS: Int64? = nil
    ) -> (plan: SegmentPlan?, rewoundToHead: Bool) {
        var rewound = false
        let stream = input.pointee.streams[Int(videoStreamIndex)]!
        let timeBase = stream.pointee.time_base
        let tick = av_q2d(timeBase)

        // Container duration (AV_TIME_BASE) → seconds. No duration, no plan.
        let rawDuration = input.pointee.duration
        guard rawDuration > 0 else { return (nil, false) }
        let durationSeconds = Double(rawDuration) / Double(AV_TIME_BASE)
        guard durationSeconds.isFinite, durationSeconds > 0 else { return (nil, false) }

        let keyframes: [Int64]
        if let cachedKeyframes {
            keyframes = cachedKeyframes
        } else if indexIsLoadedAtOpen(
            input: input, stream: stream, tickSeconds: tick,
            durationSeconds: durationSeconds, targetSeconds: targetSeconds
        ) {
            // Nothing to nudge: the index is already in the stream. Two Range
            // requests saved on every plain MP4 (stss lives in the moov the
            // open read) and on any Matroska whose Cues the demuxer already
            // fetched while executing the SeekHead.
            keyframes = indexedKeyframes(of: stream)
        } else {
            // Nudge the demuxer to load its index (Matroska Cues arrive with a
            // bounded seek) — under a deadline, because "bounded" is a
            // property of the index existing: without one the demuxer scans
            // the file linearly and this call IS the stall. The armed guard
            // aborts the underlying reads (AVERROR_EXIT) once the budget is
            // gone; a partial scan leaves the demuxer consistent, just
            // positioned mid-file.
            interruptGuard?.arm(budget: indexLoadBudget)
            _ = av_seek_frame(input, videoStreamIndex, stream.pointee.duration > 0 ? stream.pointee.duration : Int64(durationSeconds / tick), AVSEEK_FLAG_BACKWARD)
            // The guard must not outlive the nudge: the seek back to the head is
            // what restores the position the producer starts from, and aborting
            // THAT would leave the read position wherever the scan died. To
            // timestamp 0 it is cheap regardless of an index — the first
            // cluster's position is known from the header.
            interruptGuard?.disarm()
            if interruptGuard != nil, let pb = input.pointee.pb, pb.pointee.error < 0 {
                // An aborted read latches its error (AVERROR_EXIT) in the
                // AVIOContext, and every later read would return it verbatim —
                // clearing it is what lets the producer carry on with the uniform
                // plan instead of dying on its first real read. Only touched when
                // a guard could have fired: an error on an unguarded context is a
                // genuine I/O failure and stays.
                pb.pointee.error = 0
            }
            _ = av_seek_frame(input, videoStreamIndex, 0, AVSEEK_FLAG_BACKWARD)
            rewound = true
            keyframes = indexedKeyframes(of: stream)
        }

        if let planned = keyframePlan(
            keyframes: keyframes,
            durationSeconds: durationSeconds,
            tickSeconds: tick,
            targetSeconds: targetSeconds,
            firstSegmentSeconds: firstSegmentSeconds,
            coveredThroughPTS: cachedKeyframes != nil ? cachedCoveredThroughPTS : nil
        ) {
            return (SegmentPlan(
                entries: planned,
                basis: .keyframeIndex,
                timeBaseNum: timeBase.num,
                timeBaseDen: timeBase.den
            ), rewound)
        }

        return (SegmentPlan(
            entries: uniformPlan(
                durationSeconds: durationSeconds, tickSeconds: tick,
                targetSeconds: targetSeconds, firstSegmentSeconds: firstSegmentSeconds
            ),
            basis: .uniform,
            timeBaseNum: timeBase.num,
            timeBaseDen: timeBase.den
        ), rewound)
    }

    /// The keyframe timestamps in the stream's index right now.
    static func indexedKeyframes(of stream: UnsafeMutablePointer<AVStream>) -> [Int64] {
        var indexed: [Int64] = []
        let count = avformat_index_get_entries_count(stream)
        indexed.reserveCapacity(Int(count))
        for i in 0..<count {
            guard let entry = avformat_index_get_entry(stream, i) else { continue }
            if entry.pointee.flags & Int32(AVINDEX_KEYFRAME) != 0 {
                indexed.append(entry.pointee.timestamp)
            }
        }
        return indexed
    }

    /// Whether the demuxer's index is already complete without a nudge seek:
    /// its keyframe entries reach into the last target-length of the file.
    ///
    /// True for a plain MP4/MOV, whose index comes from `stss`/`stts` in the
    /// `moov` the open already read — the nudge there costs two Range
    /// requests and loads nothing. Deliberately NOT decided by the demuxer's
    /// name (review finding): a fragmented MP4's `moov` describes only the
    /// first fragment, and the rest needs `sidx`/`mfra`/a tail read the
    /// nudge provides. Coverage is the honest criterion for every container:
    /// open-time entries from a Cues-less Matroska or an fMP4 head cover the
    /// first cluster/fragment only, which this cannot mistake for the tail.
    static func indexIsLoadedAtOpen(
        input: UnsafeMutablePointer<AVFormatContext>,
        stream: UnsafeMutablePointer<AVStream>,
        tickSeconds: Double,
        durationSeconds: Double,
        targetSeconds: Int
    ) -> Bool {
        guard let last = indexedKeyframes(of: stream).last else { return false }
        return indexCoversThroughEnd(
            lastKeyframePTS: last, tickSeconds: tickSeconds,
            durationSeconds: durationSeconds, targetSeconds: targetSeconds
        )
    }

    /// Whether a keyframe set reaches the end of the source: its last entry
    /// falls inside the final target-length of the container's duration.
    ///
    /// This is the only proof of END coverage available without reading the
    /// file. The plan's own witnesses do NOT give it — they ask for a gap no
    /// wider than the cap and a span of at least one target, both of which a
    /// head prefix satisfies — so anything that must distinguish "the whole
    /// file" from "as far as we got" asks here (review finding: an index-load
    /// seek that ran out of budget leaves exactly such a prefix, and the plan
    /// accepts it).
    static func indexCoversThroughEnd(
        lastKeyframePTS: Int64,
        tickSeconds: Double,
        durationSeconds: Double,
        targetSeconds: Int
    ) -> Bool {
        Double(lastKeyframePTS) * tickSeconds >= durationSeconds - Double(targetSeconds)
    }

    /// The keyframe-aligned plan, or nil when the index fails its witnesses.
    /// Pure — unit-tested against synthetic keyframe sets.
    ///
    /// `firstSegmentSeconds` is the first entry's target; `nil` gives the
    /// first entry the same target as the rest (the pre-1.11 shape, kept so
    /// the arithmetic can still be tested without the head special case).
    /// A first target longer than `targetSeconds` is clamped: the point of
    /// the knob is a SHORTER head, never a longer one.
    ///
    /// `coveredThroughPTS` marks a PARTIAL map — a harvest persisted when
    /// the play was cancelled before EOF (`KeyframeIndexCache.Entry`). The
    /// keyframes are trusted as a contiguous prefix up to it (keyframes past
    /// it are ignored) and planned exactly; past the last boundary keyframe
    /// the plan continues on the uniform stride to the container's end.
    /// Those tail boundaries are time targets the producer cuts at the next
    /// keyframe at-or-after, so a seek INTO the tail lands up to one GOP
    /// late — the trade for a seekable VOD over the prefix that was actually
    /// watched, on a source whose first play could not be planned at all.
    /// The witnesses are unchanged: a gap over the cap or a prefix shorter
    /// than one target still distrusts the map.
    static func keyframePlan(
        keyframes: [Int64],
        durationSeconds: Double,
        tickSeconds: Double,
        targetSeconds: Int,
        firstSegmentSeconds: Int? = nil,
        coveredThroughPTS: Int64? = nil
    ) -> [Entry]? {
        let trusted = coveredThroughPTS.map { limit in keyframes.filter { $0 <= limit } } ?? keyframes
        guard trusted.count >= 2 else { return nil }
        let sorted = trusted.sorted()

        // Witness 1: no gap over the cap.
        var previous = sorted[0]
        for keyframe in sorted.dropFirst() {
            if Double(keyframe - previous) * tickSeconds > maxTrustedGapSeconds { return nil }
            previous = keyframe
        }
        // Witness 2: coverage spans at least one target duration.
        let span = Double(sorted.last! - sorted.first!) * tickSeconds
        guard span >= Double(targetSeconds) else { return nil }

        // Segment N ends at the first keyframe at-or-after its start plus its
        // target: the head's short one, then `targetSeconds` for every other.
        var entries: [Entry] = []
        var startPTS = sorted.first!
        let step = Double(targetSeconds) / tickSeconds
        let firstStep = Double(min(firstSegmentSeconds ?? targetSeconds, targetSeconds)) / tickSeconds
        var boundary = Double(startPTS) + firstStep
        for keyframe in sorted.dropFirst() where Double(keyframe) >= boundary {
            entries.append(Entry(
                startPTS: startPTS,
                duration: Double(keyframe - startPTS) * tickSeconds
            ))
            startPTS = keyframe
            boundary = Double(keyframe) + step
        }
        // The tail: from the last boundary keyframe to the container's end —
        // one entry for a complete map; for a partial one the uniform stride
        // takes over where the trusted keyframes end.
        let endPTS = Int64(durationSeconds / tickSeconds)
        if coveredThroughPTS != nil {
            // The tail stride is at least the largest keyframe gap the prefix
            // showed. Boundaries here are time targets the producer cuts at
            // the next keyframe at-or-after, and with a stride SHORTER than
            // the GOP two targets resolve to the same keyframe: every entry
            // then swallows a whole GOP while the playlist promises 6 s, and
            // the timeline drifts cumulatively (10 s GOPs advertised as 6 s
            // entries — review finding). A stride no shorter than the gap
            // gives every target its own GOP, so the error stays one GOP per
            // entry and never accumulates — PROVIDED the tail's cadence is no
            // coarser than the prefix's. The tail is unobserved by definition,
            // so this is an inference, not a bound: a tail whose GOPs grow
            // past the prefix's largest would drift again there. Known
            // limitation, accepted for the un-watched remainder of a source
            // that otherwise has no seekable shape at all; the harvest closes
            // it on the next contiguous play.
            var largestGap: Int64 = 0
            for (earlier, later) in zip(sorted, sorted.dropFirst()) {
                largestGap = max(largestGap, later - earlier)
            }
            let tailStep = max(step, (Double(largestGap) * tickSeconds).rounded(.up) / tickSeconds)
            var start = Double(startPTS)
            while Double(endPTS) - start > 0.01 / tickSeconds {
                let length = min(tailStep, Double(endPTS) - start)
                entries.append(Entry(startPTS: Int64(start), duration: length * tickSeconds))
                start += tailStep
            }
        } else {
            let tail = Double(max(endPTS - startPTS, 0)) * tickSeconds
            if tail > 0.01 {
                entries.append(Entry(startPTS: startPTS, duration: tail))
            }
        }
        return entries.isEmpty ? nil : entries
    }

    /// Fixed-stride fallback. Anchored at 0 — a late-starting title is rare
    /// enough that v1 doesn't special-case it (anchoring segment 0 at the
    /// real content start is noted for the hardening pass).
    ///
    /// The first stride is `firstSegmentSeconds` (clamped to the target) for
    /// the same reason the keyframe plan's is: the head segment is the one
    /// startup waits for.
    static func uniformPlan(
        durationSeconds: Double,
        tickSeconds: Double,
        targetSeconds: Int,
        firstSegmentSeconds: Int? = nil
    ) -> [Entry] {
        var entries: [Entry] = []
        var start = 0.0
        var stride = Double(min(firstSegmentSeconds ?? targetSeconds, targetSeconds))
        while start < durationSeconds {
            let length = min(stride, durationSeconds - start)
            entries.append(Entry(
                startPTS: Int64(start / tickSeconds),
                duration: length
            ))
            start += stride
            stride = Double(targetSeconds)
        }
        return entries
    }

    // MARK: - Lookup

    /// The segment index whose span contains `pts` (video time base).
    func segmentIndex(containing pts: Int64) -> Int {
        var candidate = 0
        for (index, entry) in entries.enumerated() where entry.startPTS <= pts {
            candidate = index
        }
        return candidate
    }
}
