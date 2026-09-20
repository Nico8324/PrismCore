import Testing
import Foundation
@testable import PrismCore

@Suite("SegmentPlan")
struct SegmentPlanTests {

    // 1 ms ticks make the arithmetic readable: 1000 ticks = 1 s.
    private let tick = 0.001

    @Test("Keyframes every 2 s, 6 s target → boundaries on the 6 s keyframes")
    func regularCadence() throws {
        let keyframes: [Int64] = stride(from: 0, through: 20_000, by: 2_000).map(Int64.init)
        let entries = try #require(SegmentPlan.keyframePlan(
            keyframes: keyframes, durationSeconds: 20, tickSeconds: tick, targetSeconds: 6
        ))
        #expect(entries.map(\.startPTS) == [0, 6_000, 12_000, 18_000])
        #expect(entries.map(\.duration) == [6, 6, 6, 2])
    }

    @Test("A plan proves nothing about END coverage — a head prefix plans just as happily")
    func planningIsNotProofOfCoverage() throws {
        // The shape an index load leaves behind when its budget runs out on a
        // one-hour source: keyframes every 2 s through 14 s and nothing after.
        let prefix: [Int64] = stride(from: 0, through: 14_000, by: 2_000).map(Int64.init)
        // The witnesses pass — no gap over the cap, more than one target of
        // span — so the planner accepts it and plans the other 3586 s as a
        // single entry.
        let entries = try #require(SegmentPlan.keyframePlan(
            keyframes: prefix, durationSeconds: 3600, tickSeconds: tick, targetSeconds: 6,
            firstSegmentSeconds: 2
        ))
        #expect(entries.map(\.startPTS) == [0, 2_000, 8_000, 14_000])
        #expect(entries.last?.duration == 3586)

        // Which is why the keyframe cache asks a different question before it
        // calls a map complete, and gets a different answer.
        #expect(!SegmentPlan.indexCoversThroughEnd(
            lastKeyframePTS: 14_000, tickSeconds: tick,
            durationSeconds: 3600, targetSeconds: 6
        ))
        // A real whole-file index ends inside the last target length.
        #expect(SegmentPlan.indexCoversThroughEnd(
            lastKeyframePTS: 3_598_000, tickSeconds: tick,
            durationSeconds: 3600, targetSeconds: 6
        ))
    }

    @Test("A partial map plans its prefix on keyframes and the tail on the stride")
    func partialMapMixedPlan() throws {
        // Keyframes every 2 s up to 14 s (the covered prefix), 60 s file.
        let keyframes: [Int64] = stride(from: 0, through: 14_000, by: 2_000).map(Int64.init)
        let entries = try #require(SegmentPlan.keyframePlan(
            keyframes: keyframes, durationSeconds: 60, tickSeconds: tick, targetSeconds: 6,
            coveredThroughPTS: 14_000
        ))
        // Prefix: 6 s boundaries on keyframes 6000 and 12000; from 12000 the
        // stride continues in 6 s time targets to the end.
        #expect(entries.map(\.startPTS) == [0, 6_000, 12_000, 18_000, 24_000, 30_000, 36_000, 42_000, 48_000, 54_000])
        #expect(entries.map(\.duration) == Array(repeating: 6, count: 10))
        #expect(abs(entries.map(\.duration).reduce(0, +) - 60) < 0.001)
        // Keyframes PAST the covered end are not trusted (a hole may precede them).
        let withStray = try #require(SegmentPlan.keyframePlan(
            keyframes: keyframes + [40_000], durationSeconds: 60, tickSeconds: tick, targetSeconds: 6,
            coveredThroughPTS: 14_000
        ))
        #expect(withStray == entries)
        // The same map with no covered end is complete: one tail entry.
        let complete = try #require(SegmentPlan.keyframePlan(
            keyframes: keyframes, durationSeconds: 60, tickSeconds: tick, targetSeconds: 6
        ))
        #expect(complete.map(\.startPTS) == [0, 6_000, 12_000])
        #expect(complete.last?.duration == 48)
        // A prefix with 10 s GOPs strides the tail at 10 s, never 6: two
        // 6 s targets would otherwise resolve to the same keyframe and the
        // playlist timeline would drift cumulatively.
        let longGOP = try #require(SegmentPlan.keyframePlan(
            keyframes: [0, 10_000, 20_000, 30_000], durationSeconds: 60, tickSeconds: tick, targetSeconds: 6,
            coveredThroughPTS: 30_000
        ))
        #expect(longGOP.map(\.startPTS) == [0, 10_000, 20_000, 30_000, 40_000, 50_000])
        #expect(longGOP.map(\.duration) == Array(repeating: 10, count: 6))
        // A prefix too short for one target fails the coverage witness.
        #expect(SegmentPlan.keyframePlan(
            keyframes: [0, 2_000, 4_000], durationSeconds: 60, tickSeconds: tick, targetSeconds: 6,
            coveredThroughPTS: 4_000
        ) == nil)
    }

    @Test("A boundary between keyframes waits for the NEXT keyframe")
    func irregularCadence() throws {
        // Keyframes at 0, 5 s, 9 s: the 6 s boundary falls between 5 and 9 —
        // the segment runs long to 9 s rather than cutting mid-GOP.
        let entries = try #require(SegmentPlan.keyframePlan(
            keyframes: [0, 5_000, 9_000], durationSeconds: 12, tickSeconds: tick, targetSeconds: 6
        ))
        #expect(entries[0].startPTS == 0)
        #expect(entries[0].duration == 9)
        #expect(entries[1].startPTS == 9_000)
        #expect(entries[1].duration == 3)
    }

    @Test("Witness 1: a monster gap distrusts the whole index")
    func gapWitness() {
        // 0, 1 s, then 200 s — a clustered TS-style index.
        let plan = SegmentPlan.keyframePlan(
            keyframes: [0, 1_000, 200_000], durationSeconds: 200, tickSeconds: tick, targetSeconds: 6
        )
        #expect(plan == nil)
    }

    @Test("Witness 2: head-bunched keyframes with no coverage distrust the index")
    func coverageWitness() {
        // All keyframes inside the first second (failed Cues tail read):
        // gaps are tiny, coverage is nowhere near one target duration.
        let plan = SegmentPlan.keyframePlan(
            keyframes: [0, 200, 400, 900], durationSeconds: 3_600, tickSeconds: tick, targetSeconds: 6
        )
        #expect(plan == nil)
    }

    @Test("Uniform fallback covers the whole duration with a short tail")
    func uniformFallback() {
        let entries = SegmentPlan.uniformPlan(durationSeconds: 20, tickSeconds: tick, targetSeconds: 6)
        #expect(entries.count == 4)
        #expect(entries.map(\.duration) == [6, 6, 6, 2])
        #expect(entries[2].startPTS == 12_000)
    }

    @Test("segmentIndex(containing:) picks the entry whose span holds the pts")
    func lookup() {
        let plan = SegmentPlan(
            entries: [
                .init(startPTS: 0, duration: 6),
                .init(startPTS: 6_000, duration: 6),
                .init(startPTS: 12_000, duration: 2),
            ],
            basis: .keyframeIndex, timeBaseNum: 1, timeBaseDen: 1_000
        )
        #expect(plan.segmentIndex(containing: 0) == 0)
        #expect(plan.segmentIndex(containing: 5_999) == 0)
        #expect(plan.segmentIndex(containing: 6_000) == 1)
        #expect(plan.segmentIndex(containing: 13_500) == 2)
    }

    @Test("A real MKV's Cues produce a keyframe-basis plan")
    func realFixture() throws {
        let fixture = try #require(Bundle.module.url(
            forResource: "h264_aac", withExtension: "mkv", subdirectory: "Fixtures"
        ))
        let plan = try #require(SegmentPlanProbe.plan(url: fixture, targetSeconds: 6))
        // 8 s file, keyframes every 2 s (g=48 @ 24 fps): the short head
        // (default 2 s target) cuts on the 2 s keyframe, then the 6 s target
        // runs to the container's end.
        #expect(plan.basis == .keyframeIndex)
        #expect(plan.entries.count == 2)
        #expect(abs(plan.entries[0].duration - 2) < 0.5)
        #expect(abs(plan.entries[1].duration - 6) < 0.5)
    }

    @Test("The first entry is short, every later one is the full target")
    func shortFirstSegment() throws {
        // 2 s keyframe grid, 30 s: head cut on the first keyframe ≥ 2 s, then
        // 6 s strides — the shape startup waits the least for.
        let keyframes: [Int64] = stride(from: 0, through: 28_000, by: 2_000).map(Int64.init)
        let entries = try #require(SegmentPlan.keyframePlan(
            keyframes: keyframes, durationSeconds: 30, tickSeconds: tick,
            targetSeconds: 6, firstSegmentSeconds: 2
        ))
        #expect(entries.map(\.startPTS) == [0, 2_000, 8_000, 14_000, 20_000, 26_000])
        #expect(entries.map(\.duration) == [2, 6, 6, 6, 6, 4])
        // Every later entry honours the full target — the head is the only
        // exception, or the plan would just be a 2 s plan.
        #expect(entries.dropFirst().dropLast().allSatisfy { $0.duration == 6 })
    }

    @Test("A first target longer than the target is clamped, and a boundary between keyframes waits")
    func shortFirstSegmentClampsAndWaits() throws {
        // Head target 3 s on a 2 s grid: no keyframe at 3, so the head runs to
        // the 4 s keyframe — same rule as any other boundary.
        let keyframes: [Int64] = stride(from: 0, through: 20_000, by: 2_000).map(Int64.init)
        let waited = try #require(SegmentPlan.keyframePlan(
            keyframes: keyframes, durationSeconds: 20, tickSeconds: tick,
            targetSeconds: 6, firstSegmentSeconds: 3
        ))
        #expect(waited[0].duration == 4)
        // A head "target" of 60 s must not lengthen the head past the target.
        let clamped = try #require(SegmentPlan.keyframePlan(
            keyframes: keyframes, durationSeconds: 20, tickSeconds: tick,
            targetSeconds: 6, firstSegmentSeconds: 60
        ))
        #expect(clamped[0].duration == 6)
    }

    @Test("The uniform fallback shortens its head the same way")
    func uniformShortFirstSegment() {
        let entries = SegmentPlan.uniformPlan(
            durationSeconds: 20, tickSeconds: tick, targetSeconds: 6, firstSegmentSeconds: 2
        )
        #expect(entries.map(\.duration) == [2, 6, 6, 6])
        #expect(entries.map(\.startPTS) == [0, 2_000, 8_000, 14_000])
    }

    @Test("An exhausted index-load budget still yields a usable plan")
    func exhaustedIndexBudgetStillPlans() throws {
        let fixture = try #require(Bundle.module.url(
            forResource: "h264_aac", withExtension: "mkv", subdirectory: "Fixtures"
        ))
        // A zero budget is the worst case the guard exists for. What it must
        // never do is lose the plan or the read position: whether the index
        // survives depends on where the demuxer had to READ (the interrupt is
        // only consulted on I/O, so a small already-buffered file loads its
        // Cues regardless — which is why this asserts a usable plan rather
        // than a basis).
        let plan = try #require(SegmentPlanProbe.plan(
            url: fixture, targetSeconds: 6, indexLoadBudget: .zero
        ))
        #expect(!plan.entries.isEmpty)
        // Whatever the basis, the plan must still cover the source: a
        // truncated plan would promise AVPlayer segments that stop early.
        let covered = plan.entries.reduce(0) { $0 + $1.duration }
        #expect(covered > 7, "an 8 s source planned as \(covered)s on \(plan.basis)")
    }

    @Test("The nudge seek leaves the read position at the head, budget or not")
    func indexLoadRestoresPosition() throws {
        // The guard is lifted before the seek back to zero precisely so an
        // expired budget cannot strand the producer mid-file. Proven through
        // the served output: a session whose producer started mid-file would
        // serve a first segment that doesn't begin at the presentation
        // origin.
        let fixture = try #require(Bundle.module.url(
            forResource: "h264_aac", withExtension: "mkv", subdirectory: "Fixtures"
        ))
        let plan = try #require(SegmentPlanProbe.plan(
            url: fixture, targetSeconds: 6, indexLoadBudget: .zero
        ))
        #expect(plan.entries.first?.startPTS == 0)
    }
}
