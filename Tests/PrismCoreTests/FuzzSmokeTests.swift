import Testing
import Foundation
@testable import PrismCore

/// The always-on half of the fuzz harness: every `FuzzTargets` entry, driven
/// with deterministic pseudo-random inputs on every test run.
///
/// This is not coverage-guided fuzzing — deep runs are the `prismcore-fuzz`
/// executable's job, run deliberately and for minutes-to-hours (AGENTS.md
/// "Fuzzing"). What this buys is cheaper and runs in CI: no parser regression
/// can ship that crashes or violates its invariants on the first few thousand
/// inputs a mutator derives from known-valid seeds. Deterministic by
/// construction — a failure names the exact `(target, seed)` and reproduces
/// forever, which a seeded-by-time fuzz test does not.
@Suite("Fuzz smoke")
struct FuzzSmokeTests {

    /// Iterations per target per shape (random / mutated). The whole suite has
    /// to stay a sub-second line item of the test run; depth is the
    /// executable's business.
    private static let iterations = 3_000

    /// Per-name seed from the UTF-8 sum, not `hashValue` — that one is
    /// process-seeded, and this suite's value is that a failure reproduces.
    private static func seed(_ base: UInt64, _ name: String) -> UInt64 {
        base &+ UInt64(name.utf8.reduce(0) { $0 + Int($1) })
    }

    @Test("Every target survives raw random bytes", arguments: FuzzTargets.all.keys.sorted())
    func randomBytes(targetName: String) {
        let target = FuzzTargets.all[targetName]!
        var rng = SplitMix64(seed: Self.seed(0x5EED_0000, targetName))
        for _ in 0..<Self.iterations {
            target(rng.bytes(count: Int(rng.next() % 512)))
        }
    }

    @Test(
        "Every target survives mutations of valid seeds",
        arguments: FuzzTargets.all.keys.sorted()
    )
    func mutatedSeeds(targetName: String) {
        let target = FuzzTargets.all[targetName]!
        let seeds = FuzzSeeds.corpus[targetName] ?? []
        #expect(!seeds.isEmpty, "target \(targetName) has no seed corpus")
        var rng = SplitMix64(seed: Self.seed(0xC0FFEE, targetName))
        for iteration in 0..<Self.iterations {
            target(rng.mutate(seeds[iteration % seeds.count]))
        }
    }

    /// The seeds must be *accepted* by their parsers — a corpus of inputs the
    /// parser rejects at the first field exercises nothing. This is the
    /// assertion that keeps the corpus honest as parsers evolve.
    @Test("Seed corpus reaches the deep paths")
    func seedsAreAccepted() throws {
        #expect(EAC3Configuration.parse(dec3: FuzzSeeds.dec3Payload)?.declaresAtmos == true)
        #expect(
            EAC3Syncframe.atmosComplexityIndex(in: FuzzSeeds.eac3LikeFrame) == 16,
            "the syncframe seed must walk all the way to its addbsi"
        )
        #expect(ISOBMFFPatch.locate("dec3", in: Data(FuzzSeeds.audioInitSegment)) != nil)
        #expect(ISOBMFFPatch.locate("hvcC", in: Data(FuzzSeeds.videoInitSegment)) != nil)
        #expect(HEVCNALUnits.units(in: FuzzSeeds.hevcPacket, lengthSize: 4)?.count == 3)
        // The hvcC seed needs normalizing (array_completeness = 0, SEI array,
        // PPS before SPS), so the idempotence invariant's interesting branch
        // actually runs.
        #expect(HVCCNormalizer.normalize(hvcC: Data(FuzzSeeds.hvcCRecord)) != nil)
        #expect(!TextSubtitleConverter.cues(fromSRT: FuzzSeeds.srtText).isEmpty)
        // The VTT seed's `line:85%` must survive to the settings, or the
        // settings-safety invariant never runs on a mutation of it.
        #expect(TextSubtitleConverter.cues(fromWebVTT: FuzzSeeds.vttText).first?.settings == "line:85%")
        // The ASS seed must reach the override translation: tag, alignment
        // and a normalized anchor all present.
        let ass = TextSubtitleConverter.convert(
            Data(FuzzSeeds.assEvent.utf8), kind: .ass,
            playResolution: .init(width: 8, height: 10)
        )
        #expect(ass?.text == "<i>Hi</i>\nthere")
        #expect(ass?.placement == TextCuePlacement(alignment: 8, anchor: .init(x: 0.5, y: 0.5)))
        #expect(
            TextSubtitleConverter.cueText(from: Data(FuzzSeeds.tx3gSample), kind: .movText)
                == "Sample"
        )
    }
}
