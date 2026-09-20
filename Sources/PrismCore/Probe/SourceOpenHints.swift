import Foundation

/// What a caller already knows about a source, handed to the open so it can
/// read less.
///
/// The governing rule, and the reason every field below is described as
/// "sizing": **a hint may let this engine do less work; it may never let it
/// decode something it would otherwise have refused, or skip a check it would
/// otherwise have made.** A wrong sizing hint costs a read. Nothing here is
/// allowed to cost a wrong parse.
///
/// `hints: nil` is today's behaviour byte for byte — the hinted path is an
/// addition to the open, not a fork of it. Everything a hint influences is
/// behind an `if let` on a value that is absent by default.
public struct SourceOpenHints: Sendable, Equatable {

    /// The length of the source's initial metadata region, from byte 0.
    /// Used to size the first read, and for nothing else.
    public var headerBytes: Int?

    /// The offset of the first top-level media element. Same use, and it wins
    /// over `headerBytes` when both are present: it is the offset past which
    /// there is provably nothing left for the header parse to want.
    public var firstClusterOffset: Int64?

    /// Where the caller believes the container's index lives.
    ///
    /// **Carried, not acted on.** Acting on it would mean skipping the tail
    /// reads, and skipping a read is the one thing a sizing hint is not
    /// allowed to do: a stale `none` on a file that has Cues would cost a
    /// keyframe-basis plan with nothing in the logs to say why. It is here so
    /// a caller can pass the whole document through and so measurements can
    /// correlate against it; the day it earns a behaviour, that behaviour
    /// needs the transport binding, not this field.
    public var indexLocation: IndexLocation

    /// The validator (`ETag`, else `Last-Modified`) the caller expects the
    /// transport to report for the representation these hints describe.
    ///
    /// Required — and required to match — before ``keyframes`` may be used at
    /// all. A transport that reports no validator is a rejection of the hints,
    /// never of the play; so is a mismatch found before the first byte has
    /// been delivered. A mismatch found *after* reading has started is not a
    /// hint problem but a representation change underneath a live session, and
    /// `HTTPRangeInput` already refuses to append that block.
    public var expectedValidator: String?

    /// A keyframe map computed elsewhere.
    ///
    /// Provenance rides inside the value rather than in a flag beside it, so
    /// it cannot be dropped on the way to a planner — the distinction between
    /// this and a map harvested locally by a remux of these very bytes is the
    /// whole of the trust argument, and a bare `[Int64]` would erase it.
    public var keyframes: SuppliedKeyframeMap?

    public init(
        headerBytes: Int? = nil,
        firstClusterOffset: Int64? = nil,
        indexLocation: IndexLocation = .unknown,
        expectedValidator: String? = nil,
        keyframes: SuppliedKeyframeMap? = nil
    ) {
        self.headerBytes = headerBytes
        self.firstClusterOffset = firstClusterOffset
        self.indexLocation = indexLocation
        self.expectedValidator = expectedValidator
        self.keyframes = keyframes
    }

    /// The number of bytes the first read should aim to cover, or `nil` when
    /// the hints say nothing about it.
    ///
    /// `firstClusterOffset` is preferred because it is the exact boundary;
    /// `headerBytes` is a length of the same region measured the other way.
    /// A value that does not fit an `Int`, or is not positive, is no hint at
    /// all — the caller's arithmetic went wrong somewhere and this open is not
    /// the place to find out where.
    var firstReadSizeHint: Int? {
        let candidate: Int64? = firstClusterOffset ?? headerBytes.map(Int64.init)
        guard let candidate, candidate > 0, let size = Int(exactly: candidate) else { return nil }
        return size
    }
}

/// A keyframe map that arrived from somewhere other than this machine's own
/// read of the file.
///
/// Same units as `KeyframeIndexCache.Entry` — timestamps on a stream's time
/// base — and deliberately **not the same type**. That one is a local sidecar
/// keyed by URL, byte size, duration and mtime, written as a by-product of a
/// remux that read the whole file here. This one is an assertion made
/// elsewhere about an HTTP representation. Same numbers, different provenance,
/// different validation, different trust; one type for both would make the
/// difference a comment instead of a compiler error.
public struct SuppliedKeyframeMap: Sendable, Equatable {
    public var streamIndex: Int32
    public var timeBaseNum: Int32
    public var timeBaseDen: Int32
    /// Keyframe timestamps on that stream's time base, strictly increasing.
    public var keyframePTS: [Int64]
    public var completeness: IndexCompleteness
    /// The last timestamp of the contiguous run, for a `partial` map.
    public var coveredThroughPTS: Int64?

    public init(
        streamIndex: Int32,
        timeBaseNum: Int32,
        timeBaseDen: Int32,
        keyframePTS: [Int64],
        completeness: IndexCompleteness,
        coveredThroughPTS: Int64? = nil
    ) {
        self.streamIndex = streamIndex
        self.timeBaseNum = timeBaseNum
        self.timeBaseDen = timeBaseDen
        self.keyframePTS = keyframePTS
        self.completeness = completeness
        self.coveredThroughPTS = coveredThroughPTS
    }

    /// The largest map this engine will consider. The same ceiling the export
    /// side uses, for the same reason and so that a document this engine
    /// produced is never one it would refuse.
    public static let maxEntries = SourceStructure.maxExportedKeyframes
}

/// Why a hint, or a whole set of them, was not used.
///
/// A rejection is **not an error**: the open proceeds exactly as it does
/// without hints. It is reported so a host can measure how often the trust
/// rules fire — a rejection rate above the noise floor means a validator
/// policy or a producer-version policy is wrong, and that is worth knowing
/// before it is worth optimising.
public enum HintRejection: Sendable, Equatable {
    /// The transport reported no validator at all, so nothing could be bound
    /// to the representation. Sizing hints survive this; a map does not.
    case validatorUnavailable
    /// The transport's validator is not the one the caller expected. The bytes
    /// being read are some other version of the resource.
    case validatorMismatch(expected: String, reported: String)
    /// A map was supplied without `expectedValidator`. Refused by rule rather
    /// than by circumstance: a map consumed on the catalog binding alone is
    /// the one failure mode worse than making no use of hints at all.
    case validatorNotRequested
    /// `streamIndex` does not name a video stream in the opened source.
    case streamMismatch(supplied: Int32)
    /// The map's time base is not the stream's. A mismatch means the identity
    /// the map was keyed by described a different file.
    case timeBaseMismatch(supplied: String, actual: String)
    /// Fewer than two timestamps, not strictly increasing, or past the cap.
    case malformedMap(String)
    /// A timestamp falls outside the stream's start and the container's
    /// duration.
    case outOfBounds(String)
}

extension SuppliedKeyframeMap {

    /// The facts about the opened source a map is checked against. A plain
    /// value so the validation is pure, testable without a container, and
    /// callable from the two places that will eventually need it.
    struct StreamFacts: Equatable {
        let videoStreamIndexes: Set<Int32>
        let streamIndex: Int32
        let timeBaseNum: Int32
        let timeBaseDen: Int32
        /// The stream's own start timestamp on its time base, when it has one.
        let startPTS: Int64?
        /// The container's duration expressed on the same time base.
        let durationPTS: Int64?
    }

    /// The structural half of the §6.3 rules — everything checkable without
    /// the transport.
    ///
    /// Any failure rejects the **whole** map, never the offending entry: a map
    /// with one impossible timestamp is a map whose producer, identity or
    /// transport is wrong about something, and there is no reason to believe
    /// the entries that happen to look plausible.
    func validate(against facts: StreamFacts) -> HintRejection? {
        // 1. A video stream in this source, and the one the facts describe.
        guard facts.videoStreamIndexes.contains(streamIndex), streamIndex == facts.streamIndex
        else { return .streamMismatch(supplied: streamIndex) }

        // 2. The exact time base. The local cache makes the same check for the
        // same reason: the same file demuxes to the same base, so a mismatch
        // means the identity lied.
        guard timeBaseNum == facts.timeBaseNum, timeBaseDen == facts.timeBaseDen else {
            return .timeBaseMismatch(
                supplied: "\(timeBaseNum)/\(timeBaseDen)",
                actual: "\(facts.timeBaseNum)/\(facts.timeBaseDen)"
            )
        }

        // 3. Strictly increasing, and inside the cap. Two entries is the floor
        // a plan needs to cut anything at all.
        guard keyframePTS.count >= 2 else { return .malformedMap("fewer than two entries") }
        guard keyframePTS.count <= Self.maxEntries else {
            return .malformedMap("\(keyframePTS.count) entries, cap is \(Self.maxEntries)")
        }
        for (earlier, later) in zip(keyframePTS, keyframePTS.dropFirst()) where later <= earlier {
            return .malformedMap("timestamps are not strictly increasing")
        }

        // 4. Inside the stream's own span.
        if let startPTS = facts.startPTS, let first = keyframePTS.first, first < startPTS {
            return .outOfBounds("first timestamp \(first) precedes stream start \(startPTS)")
        }
        if let durationPTS = facts.durationPTS, let last = keyframePTS.last, last > durationPTS {
            return .outOfBounds("last timestamp \(last) exceeds duration \(durationPTS)")
        }

        // 5. A partial map has to say where its contiguous run ends, and that
        // marker has to be one of its own entries — a covered-through value
        // that is not in the array describes a run whose last keyframe nobody
        // recorded, which is not a prefix anything can be planned from.
        switch completeness {
        case .complete:
            break
        case .partial:
            guard let covered = coveredThroughPTS else {
                return .malformedMap("partial map without coveredThroughPTS")
            }
            guard keyframePTS.contains(covered) else {
                return .outOfBounds("coveredThroughPTS \(covered) is not one of the timestamps")
            }
        case .absent, .unknown:
            // Neither is a map a plan may be built from. `unknown` in
            // particular is the default of anything that was not verified, and
            // treating the default as a promise is the defect this whole
            // member exists to contain.
            return .malformedMap("completeness is \(completeness.rawValue)")
        }
        return nil
    }
}

/// What became of a set of hints — the honest record of an open that was
/// offered help.
///
/// Held on `ProbedSource` so a host can log one line and move on. Every field
/// is a statement about *this* open; nothing here is cached, and nothing here
/// is written anywhere.
public struct HintOutcome: Sendable, Equatable {
    /// Whether hints were supplied at all. `false` is the unhinted open, and
    /// every other field is then empty.
    public let wereSupplied: Bool
    /// The size the first read was bounded to, when a sizing hint set one.
    public let firstReadBytes: Int?
    /// The validator the transport actually reported, when it reported one.
    public let reportedValidator: String?
    /// Every reason a hint was not used. Empty on a fully accepted set.
    public let rejections: [HintRejection]
    /// The supplied map, if it survived every check that can be made before
    /// the first read.
    ///
    /// **Carried, not yet consumed.** §3.1's rule 5 makes a supplied map
    /// unusable until the transport binding of the design's P2 exists at both
    /// ends of the wire, so wiring it into `SegmentPlan.build` today would
    /// create a path that may not legally execute — and the only way it
    /// *could* execute is the bug the design warns about, a remote assertion
    /// being harvested into the local sidecar as though it were a local read.
    /// It is validated and exposed here; the seam that will consume it is
    /// `SegmentPlan.build(cachedKeyframes:)`, and nothing reaches it yet.
    public let acceptedKeyframes: SuppliedKeyframeMap?

    static let unhinted = HintOutcome(
        wereSupplied: false, firstReadBytes: nil, reportedValidator: nil,
        rejections: [], acceptedKeyframes: nil
    )

    init(
        wereSupplied: Bool,
        firstReadBytes: Int?,
        reportedValidator: String?,
        rejections: [HintRejection],
        acceptedKeyframes: SuppliedKeyframeMap?
    ) {
        self.wereSupplied = wereSupplied
        self.firstReadBytes = firstReadBytes
        self.reportedValidator = reportedValidator
        self.rejections = rejections
        self.acceptedKeyframes = acceptedKeyframes
    }
}
