import Foundation

/// Where a container keeps its seek index, in the published resource's own
/// byte coordinates.
///
/// `none` requires **positive evidence** that the container declares no index.
/// An empty index table at open is not that evidence — a Matroska's Cues live
/// at the tail and the demuxer has not read them yet — so the honest answer
/// for "we did not look, or we looked and could not tell" is `unknown`. The
/// distinction exists because a client that read `none` would skip the tail
/// reads entirely, and skipping them on a file that *has* Cues costs a
/// keyframe-basis plan, silently.
public enum IndexLocation: String, Sendable, Equatable, Codable, CaseIterable {
    /// The index precedes the first media element (an MP4 `moov` before `mdat`,
    /// a Matroska whose Cues sit before the first Cluster).
    case head
    /// The index follows the media (the Matroska norm, a non-faststart MP4).
    case tail
    /// The container positively declares no index.
    case none
    /// Not determined. The default, and the only answer a scan that did not
    /// run may give.
    case unknown
}

/// How much of a source a keyframe map actually describes.
///
/// Exists because of a specific defect this repository owns: an index-load
/// seek that runs out of budget leaves a head *prefix* in the demuxer's table,
/// and a consumer that cannot tell a prefix from a whole file plans the unseen
/// remainder as though it had been measured. `unknown` is the default for
/// anything that was not explicitly verified — never `complete`.
public enum IndexCompleteness: String, Sendable, Equatable, Codable, CaseIterable {
    /// The index provably reaches the end of the container.
    case complete
    /// A contiguous run from the head, ending at `coveredThroughPTS`. Past it
    /// the map says nothing.
    case partial
    /// The container positively has no index.
    case absent
    /// Not verified.
    case unknown
}

/// Where the timestamps in an `IndexSummary` came from.
///
/// One case today, spelled out rather than implied: a consumer must be able to
/// tell a container's own index from anything else that might later fill this
/// member, and a field that only ever has one value is cheaper to add now than
/// a meaning change is later.
public enum IndexSource: String, Sendable, Equatable, Codable, CaseIterable {
    /// The demuxer's index table — Matroska Cues, MP4 `stss`/`stts`.
    case containerIndex
}

/// A container's seek index, described in the **demuxer's own terms**: a
/// stream, the rational time base its timestamps live on, and timestamps in
/// that base.
///
/// Deliberately not seconds and deliberately not bytes. Seconds would mean a
/// conversion at both ends of the wire, and every conversion is a place to
/// lose a frame; bytes would be a demuxer-level artifact whose validation
/// nothing here specifies.
public struct IndexSummary: Sendable, Equatable, Codable {
    /// The stream the timestamps belong to — the video stream the planner
    /// would use, which is the one `SourceProbe` reports as `info.video`.
    public let streamIndex: Int32
    public let timeBaseNum: Int32
    public let timeBaseDen: Int32
    /// How many keyframe entries the index held when it was read.
    public let entryCount: Int
    public let completeness: IndexCompleteness
    public let source: IndexSource
    /// The last timestamp of the contiguous run, for a `partial` map. Absent
    /// for anything else.
    public let coveredThroughPTS: Int64?
    /// The timestamps themselves — `nil` unless the caller explicitly asked
    /// for them, and `nil` again when there are more than
    /// ``SourceStructure/maxExportedKeyframes`` of them (see there).
    public let keyframePTS: [Int64]?

    public init(
        streamIndex: Int32,
        timeBaseNum: Int32,
        timeBaseDen: Int32,
        entryCount: Int,
        completeness: IndexCompleteness,
        source: IndexSource = .containerIndex,
        coveredThroughPTS: Int64? = nil,
        keyframePTS: [Int64]? = nil
    ) {
        self.streamIndex = streamIndex
        self.timeBaseNum = timeBaseNum
        self.timeBaseDen = timeBaseDen
        self.entryCount = entryCount
        self.completeness = completeness
        self.source = source
        self.coveredThroughPTS = coveredThroughPTS
        self.keyframePTS = keyframePTS
    }
}

/// What a probe can say about a container's **layout and index** — the half of
/// an open that `SourceInfo` has never described.
///
/// `SourceInfo` answers "what streams are in here"; this answers "where does
/// the header end, where does the media start, and is there an index". A
/// server that has already analysed a file can hand these two scalars to a
/// client about to read the same bytes over a network, which turns the
/// client's first open-ended request into a bounded one.
///
/// **Every field is optional or has an `unknown` case, and nothing here is
/// ever inferred.** A value that was not measured is absent; a question that
/// was not asked is `unknown`. The cost of a wrong scalar is paid by the host
/// that trusts it, at a distance, on a file this process will never see again
/// — so the export refuses to guess in the one direction that would be
/// convenient.
public struct SourceStructure: Sendable, Equatable, Codable {

    /// The length of the initial metadata region, from byte 0 of the source.
    ///
    /// A *sizing* hint and nothing more: a consumer reads these bytes and
    /// parses them exactly as it does today, so a wrong value costs an extra
    /// read, never a wrong parse.
    public let headerBytes: Int?

    /// The offset of the first top-level media element — for Matroska the
    /// first byte of the first `Cluster` element's ID, for ISO-BMFF the first
    /// byte of the `mdat` box. Same coordinates as `headerBytes`.
    public let firstClusterOffset: Int64?

    public let indexLocation: IndexLocation

    /// The index, when one was actually read. `nil` when no index load was
    /// requested, or when it was requested and did not fit its budget.
    public let index: IndexSummary?

    /// The source's own length as the transport reports it, when it knows.
    /// Here because every offset above is only interpretable against it, and a
    /// consumer's bounds check (`offset < byteSize`) should not have to ask a
    /// second layer for the denominator.
    public let byteSize: Int64?

    /// Nothing measured. The resting state of a probe that was not asked for a
    /// structure export, and the only shape that costs no I/O at all.
    public static let unknown = SourceStructure(
        headerBytes: nil, firstClusterOffset: nil,
        indexLocation: .unknown, index: nil, byteSize: nil
    )

    /// The ceiling on how many timestamps an export will carry.
    ///
    /// The consumer of this export is a helper with a 1 MiB output limit, and
    /// a timestamp costs roughly eight bytes as JSON text. Twenty thousand
    /// entries is a three-hour film at a half-second keyframe cadence — well
    /// past any real VOD encode — and still leaves the rest of the document
    /// room. Past the cap `entryCount` and `completeness` are still reported:
    /// a poorer document, on time, rather than a complete one that overruns.
    public static let maxExportedKeyframes = 20_000

    public init(
        headerBytes: Int?,
        firstClusterOffset: Int64?,
        indexLocation: IndexLocation,
        index: IndexSummary?,
        byteSize: Int64?
    ) {
        self.headerBytes = headerBytes
        self.firstClusterOffset = firstClusterOffset
        self.indexLocation = indexLocation
        self.index = index
        self.byteSize = byteSize
    }
}

/// How much of a structure export a caller is willing to pay for.
///
/// Opt-in, and `.none` by default, because the two paying steps are real I/O
/// against the source: the layout scan re-reads the head, and the index load
/// is the same nudge seek `SegmentPlan` pays (two Range requests on a
/// tail-Cues Matroska). The intended caller is an out-of-process probe reading
/// a **local descriptor**, where both are free; a host probing over a network
/// to decide how to route must not pay them, and with the default it does not.
public enum SourceStructureExport: Sendable, Equatable {
    /// No extra reads. `SourceStructure.unknown`.
    case none
    /// Walk the container's top-level elements to find the header/media
    /// boundary and, where the container says so, where its index lives.
    case layout
    /// `layout`, plus a bounded index load and the keyframe timestamps it
    /// produced (subject to ``SourceStructure/maxExportedKeyframes``).
    ///
    /// This one moves the read position: the load is a seek to the tail and a
    /// seek back to the head, exactly as `SegmentPlan.build` does it. Harmless
    /// for a context nobody adopts, and a context that *is* adopted seeks to
    /// its own start anyway — but it is the reason this is not the default.
    case full

    var wantsLayout: Bool { self != .none }
    var wantsIndex: Bool { self == .full }
}
