import Testing
import Foundation
@testable import PrismCore

/// `ProbedSource.structure` — the read-only container layout and index export
/// a server-side probe hands to a client that is about to read the same bytes
/// over a network.
///
/// The invariant every test here defends is the same one: **the export never
/// invents.** A field it did not measure is absent, a question it did not ask
/// is `unknown`, and `complete` is a claim that has to be earned. A consumer
/// on the far side of an HTTP request cannot audit any of this, so the audit
/// lives here.
@Suite("Probe structure export")
struct ProbeStructureExportTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    @Test("A probe that was not asked for a structure reports nothing, not a guess")
    func exportIsOptIn() throws {
        let probed = try SourceProbe.open(url: try fixture("h264_aac_30s.mkv"))
        #expect(probed.structure == .unknown)
        #expect(probed.structure.headerBytes == nil)
        #expect(probed.structure.firstClusterOffset == nil)
        #expect(probed.structure.indexLocation == .unknown)
        #expect(probed.structure.index == nil)
    }

    @Test("The layout export lands on a real Cluster, checked against the file's own bytes")
    func layoutPointsAtTheFirstCluster() throws {
        let source = try fixture("h264_aac_30s.mkv")
        let probed = try SourceProbe.open(url: source, structure: .layout)
        let offset = try #require(probed.structure.firstClusterOffset,
                                  "no first-cluster offset for a Matroska the walk should handle")

        // The claim is verified the only way that means anything: read the
        // file at the offset the export published and check the four bytes of
        // the Matroska `Cluster` element ID are there. A plausible-looking
        // number that is a few bytes out would pass any bounds check and cost
        // a consumer a wrong-sized read; it cannot pass this.
        let data = try Data(contentsOf: source)
        let start = try #require(Int(exactly: offset))
        #expect(start + 4 <= data.count)
        #expect(Array(data[start..<(start + 4)]) == [0x1F, 0x43, 0xB6, 0x75])

        #expect(probed.structure.headerBytes == start)
        #expect(probed.structure.byteSize == Int64(data.count))
        // The layout export was asked for a layout. It does not also pay for
        // an index load, and it does not report one it did not do.
        #expect(probed.structure.index == nil)
    }

    @Test("The index export reports a count, a time base and an earned verdict")
    func indexExportIsHonest() throws {
        let source = try fixture("h264_aac_30s.mkv")
        let probed = try SourceProbe.open(url: source, structure: .full)
        let index = try #require(probed.structure.index, "a Matroska with Cues exported no index")
        let video = try #require(probed.info.video)

        #expect(index.streamIndex == Int32(video.streamIndex))
        #expect(index.source == .containerIndex)
        #expect(index.timeBaseDen > 0)
        #expect(index.entryCount >= 2)
        // Never `absent`: nothing in this path can produce the positive
        // evidence that case requires, and reporting it from silence is the
        // exact mistake the enum exists to prevent.
        #expect(index.completeness != .absent)

        let keyframes = try #require(index.keyframePTS, "a 30 s fixture is far inside the cap")
        #expect(keyframes.count == index.entryCount)
        #expect(keyframes == keyframes.sorted())
        #expect(Set(keyframes).count == keyframes.count, "timestamps must be strictly increasing")

        // `complete` is a claim about reaching the end of the file, so check
        // it against the duration rather than taking the verdict's word.
        if index.completeness == .complete {
            let duration = try #require(probed.info.duration)
            let tick = Double(index.timeBaseNum) / Double(index.timeBaseDen)
            let last = Double(try #require(keyframes.last)) * tick
            #expect(last >= duration - 30, "reported complete with its last entry \(duration - last) s from the end")
            #expect(index.coveredThroughPTS == nil, "a complete map has no covered-through marker")
        } else {
            #expect(index.completeness == .partial || index.completeness == .unknown)
        }
    }

    @Test("An index that is two islands rather than a cadence is `unknown`, not `complete`")
    func mpegTSIndexStaysHonest() throws {
        // MPEG-TS has no index to load. What a nudge seek leaves behind on
        // this fixture is an entry at 1.4 s and seven bunched around 30 s —
        // two isolated samples of a 30 s file, with nothing in between.
        //
        // It is the sharpest case in the suite because it *looks* answerable:
        // the entries do span the duration, so any rule shaped like "the last
        // entry is near the end" calls it complete and publishes two sampled
        // points as a description of the whole file — the #97 defect,
        // reproduced on the export side and sent across a network. The
        // cadence check is what refuses it.
        let probed = try SourceProbe.open(url: try fixture("h264_ac3_30s.ts"), structure: .full)
        let index = try #require(probed.structure.index)
        #expect(index.completeness == .unknown)
        #expect(index.keyframePTS == nil, "an index with no established cadence carries no timestamps")
        #expect(index.coveredThroughPTS == nil)
        // `absent` is never reachable from here either: nothing in this path
        // can produce the positive evidence that case requires.
        #expect(index.completeness != .absent)
        // And the layout walk knows nothing about TS, which is `unknown`, not
        // a Matroska answer applied to the wrong container.
        #expect(probed.structure.firstClusterOffset == nil)
        #expect(probed.structure.indexLocation == .unknown)
    }

    @Test("Exporting a structure does not change what the probe concluded")
    func exportDoesNotDisturbTheVerdict() throws {
        let source = try fixture("h264_aac_30s.mkv")
        let plain = try SourceProbe.open(url: source)
        let exported = try SourceProbe.open(url: source, structure: .full)
        // The export moves the read position (the index load is a seek to the
        // tail and back) and re-reads the head. None of that may reach the
        // answer the router acts on.
        #expect(plain.info.formatName == exported.info.formatName)
        #expect(plain.info.duration == exported.info.duration)
        #expect(plain.info.nativeReadiness == exported.info.nativeReadiness)
        #expect(plain.info.video?.codecName == exported.info.video?.codecName)
        #expect(plain.info.audioTracks.count == exported.info.audioTracks.count)
        #expect(plain.info.subtitleTracks.count == exported.info.subtitleTracks.count)
    }

    @Test("The encoded shape is the wire contract's, field for field")
    func wireShapeIsPinned() throws {
        // `PrismProbeReport` lives in the server's repository and cannot
        // import this one — that separation is deliberate (the server links
        // neither PrismCore nor FFmpeg). So the two sides cannot share a type,
        // and the only thing that can keep them in lockstep is an executable
        // statement of the shape. This is it: the names below are the ones
        // `docs/prismcore-probe-hints.md` §3 prints, and a change here is a
        // change the server's report must match.
        let structure = SourceStructure(
            headerBytes: 4312,
            firstClusterOffset: 5184,
            indexLocation: .tail,
            index: IndexSummary(
                streamIndex: 0, timeBaseNum: 1, timeBaseDen: 1000,
                entryCount: 3, completeness: .partial,
                coveredThroughPTS: 24040, keyframePTS: [0, 12000, 24040]
            ),
            byteSize: 24_117_248_512
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try #require(String(data: try encoder.encode(structure), encoding: .utf8))

        for key in ["headerBytes", "firstClusterOffset", "indexLocation", "byteSize",
                    "streamIndex", "timeBaseNum", "timeBaseDen", "entryCount",
                    "completeness", "source", "coveredThroughPTS", "keyframePTS"] {
            #expect(json.contains("\"\(key)\""), "the wire contract lost \(key)")
        }
        #expect(json.contains("\"indexLocation\":\"tail\""))
        #expect(json.contains("\"completeness\":\"partial\""))
        #expect(json.contains("\"source\":\"containerIndex\""))

        // And it round-trips, because the server's decode is the other half of
        // the same contract.
        #expect(try JSONDecoder().decode(
            SourceStructure.self, from: try encoder.encode(structure)
        ) == structure)
    }

    @Test("Every enum spells itself the way the wire does")
    func enumSpellings() {
        #expect(IndexLocation.allCases.map(\.rawValue) == ["head", "tail", "none", "unknown"])
        #expect(IndexCompleteness.allCases.map(\.rawValue)
                == ["complete", "partial", "absent", "unknown"])
        #expect(IndexSource.allCases.map(\.rawValue) == ["containerIndex"])
    }
}
