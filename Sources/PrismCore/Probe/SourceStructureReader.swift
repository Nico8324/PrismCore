import Foundation
import Libavformat
import Libavutil

/// Produces a `SourceStructure` from an **already open** context.
///
/// Separated from `SourceProbe` because the two answer different questions
/// with different costs. `describe` reads what the open already paid for;
/// this pays extra — a re-read of the head, and at `.full` the same index-load
/// seek `SegmentPlan` pays — which is why it runs only when a caller asks and
/// why the asking is a parameter rather than a default.
enum SourceStructureReader {

    /// The largest single read the layout walk will make. The walk only ever
    /// wants element framing (at most a 4-byte ID and an 8-byte length, or an
    /// ISO-BMFF 16-byte box header), so anything past a few hundred bytes is a
    /// caller that has lost the plot rather than a container that needs it.
    private static let maxWalkRead = 4096

    static func read(
        input: UnsafeMutablePointer<AVFormatContext>,
        formatName: String,
        videoStreamIndex: Int32?,
        export: SourceStructureExport,
        interruptGuard: ReadInterruptGuard?,
        indexLoadBudget: Duration = SegmentPlan.indexLoadBudget
    ) -> SourceStructure {
        guard export.wantsLayout, let pb = input.pointee.pb else { return .unknown }

        let byteSize: Int64? = {
            let size = avio_size(pb)
            return size > 0 ? size : nil
        }()

        // The walk seeks; the demuxer's position is not ours to move. Restored
        // before returning, so an adopting producer sees the context exactly
        // where `describe` left it — which is a promise `ProbedSource` already
        // makes and this must not quietly break.
        let originalPosition = avio_tell(pb)
        let layout = ContainerLayoutScanner.scan(formatName: formatName, byteSize: byteSize) {
            offset, count in
            guard count > 0, count <= maxWalkRead, offset >= 0 else { return nil }
            guard avio_seek(pb, offset, SEEK_SET) >= 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: count)
            let read = buffer.withUnsafeMutableBufferPointer {
                avio_read(pb, $0.baseAddress, Int32(count))
            }
            // A short read is nil, not a truncation: every field the walk asks
            // for is needed whole, and half a length is how a walk invents an
            // offset it then seeks to.
            guard read == Int32(count) else { return nil }
            return Data(buffer)
        }
        if avio_seek(pb, originalPosition, SEEK_SET) < 0 || pb.pointee.error < 0 {
            // A walk that could not put the position back has damaged nothing
            // it can repair, but it must not also hand back a latched error
            // the adopting producer would meet on its first read.
            pb.pointee.error = 0
            _ = avio_seek(pb, originalPosition, SEEK_SET)
        }

        var index: IndexSummary?
        if export.wantsIndex, let videoStreamIndex {
            index = readIndex(
                input: input, videoStreamIndex: videoStreamIndex,
                interruptGuard: interruptGuard, indexLoadBudget: indexLoadBudget
            )
        }

        return SourceStructure(
            headerBytes: layout.headerBytes,
            firstClusterOffset: layout.firstMediaOffset,
            indexLocation: layout.indexLocation,
            index: index,
            byteSize: byteSize
        )
    }

    /// Load the container's index if it is not already loaded, and describe
    /// what came back.
    ///
    /// The seek shape is `SegmentPlan.build`'s, deliberately — same nudge,
    /// same budget, same error clearing, same rewind — because a second way of
    /// loading an index is a second way of getting the interrupt guard wrong
    /// (issue #39 cost 1.1.1 a bounded seek that bounded nothing).
    private static func readIndex(
        input: UnsafeMutablePointer<AVFormatContext>,
        videoStreamIndex: Int32,
        interruptGuard: ReadInterruptGuard?,
        indexLoadBudget: Duration
    ) -> IndexSummary? {
        guard videoStreamIndex >= 0, videoStreamIndex < Int32(input.pointee.nb_streams),
              let stream = input.pointee.streams[Int(videoStreamIndex)] else { return nil }
        let timeBase = stream.pointee.time_base
        let tick = av_q2d(timeBase)
        guard tick > 0 else { return nil }
        let durationSeconds = input.pointee.duration > 0
            ? Double(input.pointee.duration) / Double(AV_TIME_BASE)
            : 0

        func summary(_ completeness: IndexCompleteness,
                     _ keyframes: [Int64],
                     coveredThrough: Int64?,
                     carryTimestamps: Bool) -> IndexSummary {
            IndexSummary(
                streamIndex: videoStreamIndex,
                timeBaseNum: timeBase.num,
                timeBaseDen: timeBase.den,
                entryCount: keyframes.count,
                completeness: completeness,
                coveredThroughPTS: coveredThrough,
                // Past the cap the document keeps its count and its verdict
                // and drops the array: poorer, and inside the helper's output
                // limit, rather than complete and over it.
                keyframePTS: carryTimestamps && keyframes.count <= SourceStructure.maxExportedKeyframes
                    ? keyframes : nil
            )
        }

        // `targetSeconds: 0` is the strictest reading of "already loaded":
        // only an index whose last entry is at-or-past the duration skips the
        // nudge. Deliberately stricter than the planner's, which may accept a
        // target-length shortfall because it is about to cut segments anyway.
        // This is about to publish a `completeness` verdict across a network,
        // and paying one bounded seek on a local descriptor is cheaper than
        // being wrong about it.
        let alreadyLoaded = durationSeconds > 0 && SegmentPlan.indexIsLoadedAtOpen(
            input: input, stream: stream, tickSeconds: tick,
            durationSeconds: durationSeconds, targetSeconds: 0
        )
        var interrupted = false
        if !alreadyLoaded {
            interruptGuard?.arm(budget: indexLoadBudget)
            let target = stream.pointee.duration > 0
                ? stream.pointee.duration
                : Int64(durationSeconds / tick)
            _ = av_seek_frame(input, videoStreamIndex, target, AVSEEK_FLAG_BACKWARD)
            // Read the verdict BEFORE disarming: once disarmed the guard has
            // nothing left to say, and whether the budget expired is the one
            // fact that decides `unknown` from a real answer here.
            interrupted = interruptGuard?.shouldInterrupt ?? false
            interruptGuard?.disarm()
            if interruptGuard != nil, let pb = input.pointee.pb, pb.pointee.error < 0 {
                pb.pointee.error = 0
            }
            _ = av_seek_frame(input, videoStreamIndex, 0, AVSEEK_FLAG_BACKWARD)
        }

        let keyframes = SegmentPlan.indexedKeyframes(of: stream).sorted()

        if interrupted {
            // A scan the budget cut short leaves entries in the table with no
            // claim that they are contiguous, so they are not a `partial` map
            // — `partial` means a run from the head, which is a thing the
            // producing side has to have watched to know. Count reported,
            // verdict withheld, timestamps withheld.
            return summary(.unknown, keyframes, coveredThrough: nil, carryTimestamps: false)
        }
        // An empty table after a completed load is still not evidence that the
        // file declares no index: plenty of demuxers reach a nudge target
        // without materialising entries. `absent` needs the container to say
        // so, which nothing here has heard it do.
        guard let last = keyframes.last, keyframes.count >= 2, durationSeconds > 0 else {
            return summary(.unknown, keyframes, coveredThrough: nil, carryTimestamps: false)
        }

        // Before any verdict: does this index even have a *cadence*? A real
        // keyframe index has gaps of roughly one size. What an MPEG-TS leaves
        // behind after a nudge seek does not — the `h264_ac3_30s.ts` fixture
        // produces entries at 1.4 s and then seven bunched around 30 s, two
        // islands with nothing between them. Calibrating a tolerance on that
        // index's largest gap (28.5 s) makes "within one gap of the end"
        // trivially true and reports two sampled points as a description of
        // the whole file — which is exactly the defect
        // ([Astra `NEEDS_FIX`](https://github.com/Wenzlik/PrismCore/pull/97))
        // this member exists to contain, reproduced on the export side.
        //
        // So the cadence is the MEDIAN gap, and an index whose largest gap is
        // many times its median has no cadence this can calibrate against:
        // `unknown`, timestamps withheld. The multiple is generous because
        // scene-cut keyframes make gaps *shorter* than the nominal cadence and
        // pull the median down — a 10 s GOP with cuts is a real file, two
        // islands 28 s apart is not.
        let gaps = zip(keyframes, keyframes.dropFirst()).map { $1 - $0 }.sorted()
        let medianGap = gaps[gaps.count / 2]
        guard medianGap > 0, let largest = gaps.last,
              Double(largest) <= Double(medianGap) * 8
        else {
            return summary(.unknown, keyframes, coveredThrough: nil, carryTimestamps: false)
        }

        // "Reaches the end" needs a tolerance, and the honest one is the file's
        // own cadence rather than a number picked here: an index whose last
        // entry is within a keyframe gap of the duration has nothing missing
        // that it could have carried. A fixed tolerance would be either too
        // tight for a 10 s GOP (a whole index reported partial) or too loose
        // for a 0.5 s one (a prefix reported complete).
        //
        // The extra second is not slop. A file's last GOP is a *partial* one —
        // 30.023 s of content at a 2 s cadence puts the final keyframe 2.023 s
        // from the end — so a tolerance of exactly one cadence reports
        // `partial` for essentially every whole index, and a verdict that is
        // almost never `complete` tells a consumer nothing. The residual risk
        // is an index missing exactly its last entry read as complete, whose
        // cost is a final boundary one GOP early. That is strictly tighter
        // than what this repository already trusts locally: `HLSRemuxer` makes
        // the same call with the session's segment target before writing the
        // sidecar.
        let toleranceSeconds = min(max(Double(medianGap) * tick, 1) + 1, 30)
        let reachesEnd = SegmentPlan.indexCoversThroughEnd(
            lastKeyframePTS: last, tickSeconds: tick,
            durationSeconds: durationSeconds, targetSeconds: Int(toleranceSeconds.rounded(.up))
        )
        return reachesEnd
            ? summary(.complete, keyframes, coveredThrough: nil, carryTimestamps: true)
            : summary(.partial, keyframes, coveredThrough: last, carryTimestamps: true)
    }
}
