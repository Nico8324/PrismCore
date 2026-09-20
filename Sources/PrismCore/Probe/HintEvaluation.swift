import Foundation
import Libavformat
import Libavutil

/// Judges a caller's hints against the source that was actually opened.
///
/// Runs **after** the open, on purpose. The sizing half has already had its
/// effect by then (it bounded a read), and the map half cannot be judged any
/// earlier: the checks are all against the stream's real time base, the real
/// stream list and the validator the transport really reported, none of which
/// exist before the bytes arrive.
///
/// Nothing here can fail an open. Every outcome is either "used" or "not
/// used", and "not used" is the unhinted path, which is the path every other
/// source in the world takes anyway.
enum HintEvaluation {

    static func evaluate(
        hints: SourceOpenHints?,
        input: UnsafeMutablePointer<AVFormatContext>,
        interruptGuard: ReadInterruptGuard
    ) -> HintOutcome {
        guard let hints else { return .unhinted }

        var rejections: [HintRejection] = []
        let observation = interruptGuard.validatorObservation
        let reportedValidator: String? = {
            switch observation {
            case .satisfied(let value), .mismatched(let value), .unchecked(let value): return value
            case .unavailable, .notObserved, .none: return nil
            }
        }()

        // The transport binding, judged only when a caller asked for one. A
        // caller that stated no expectation is not failing a check it never
        // made — its sizing hints stand, and only a supplied map is refused
        // below for the absence.
        var transportBound = false
        if hints.expectedValidator != nil {
            switch observation {
            case .satisfied:
                transportBound = true
            case .mismatched(let reported):
                rejections.append(.validatorMismatch(
                    expected: hints.expectedValidator ?? "", reported: reported
                ))
            case .unavailable, .notObserved, .unchecked, .none:
                // `.none` is FFmpeg's own I/O or a host-supplied input: a
                // transport that reports no validator at all, which is exactly
                // what "unavailable" means to a caller that needed one.
                rejections.append(.validatorUnavailable)
            }
        }

        var accepted: SuppliedKeyframeMap?
        if let map = hints.keyframes {
            if hints.expectedValidator == nil {
                rejections.append(.validatorNotRequested)
            } else if transportBound {
                if let rejection = map.validate(against: streamFacts(input: input, map: map)) {
                    rejections.append(rejection)
                } else {
                    accepted = map
                }
            }
            // A map whose validator check already failed is not also
            // structurally judged: the whole map is rejected either way, and a
            // second reason in the log is noise, not information.
        }

        return HintOutcome(
            wereSupplied: true,
            firstReadBytes: interruptGuard.hintedFirstReadBytes,
            reportedValidator: reportedValidator,
            rejections: rejections,
            acceptedKeyframes: accepted
        )
    }

    /// The facts a map is checked against, read from the opened context.
    ///
    /// `streamIndex` is the video stream the *planner* would use — the same
    /// `av_find_best_stream` answer `describe` reports as `info.video`. A map
    /// for some other video stream in the file is refused rather than
    /// remapped: which stream a plan is cut on is not a thing to infer from a
    /// hint.
    private static func streamFacts(
        input: UnsafeMutablePointer<AVFormatContext>,
        map: SuppliedKeyframeMap
    ) -> SuppliedKeyframeMap.StreamFacts {
        var videoIndexes: Set<Int32> = []
        for index in 0..<Int32(input.pointee.nb_streams) {
            guard let stream = input.pointee.streams[Int(index)] else { continue }
            if stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
                videoIndexes.insert(index)
            }
        }
        let best = av_find_best_stream(input, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard best >= 0, best < Int32(input.pointee.nb_streams),
              let stream = input.pointee.streams[Int(best)] else {
            return .init(
                videoStreamIndexes: videoIndexes, streamIndex: -1,
                timeBaseNum: 0, timeBaseDen: 0, startPTS: nil, durationPTS: nil
            )
        }
        let timeBase = stream.pointee.time_base
        let tick = av_q2d(timeBase)
        let startPTS = stream.pointee.start_time == swift_AV_NOPTS_VALUE()
            ? nil : stream.pointee.start_time
        let durationPTS: Int64? = {
            if stream.pointee.duration > 0 { return stream.pointee.duration }
            guard input.pointee.duration > 0, tick > 0 else { return nil }
            return Int64(Double(input.pointee.duration) / Double(AV_TIME_BASE) / tick)
        }()
        return .init(
            videoStreamIndexes: videoIndexes,
            streamIndex: best,
            timeBaseNum: timeBase.num,
            timeBaseDen: timeBase.den,
            startPTS: startPTS,
            durationPTS: durationPTS
        )
    }
}
