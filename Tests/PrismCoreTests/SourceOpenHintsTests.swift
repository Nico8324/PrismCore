import Testing
import Foundation
@testable import PrismCore

/// `SourceProbe.open(_:hints:)` — the open that can be told what a caller
/// already knows.
///
/// Two properties carry this whole surface, and both are load-bearing rather
/// than tidy:
///
/// 1. **`hints: nil` is today's open.** Not "equivalent to", not "as good as":
///    the same code with everything behind an absent optional.
/// 2. **A hint that cannot be bound to these bytes is dropped, and dropping it
///    leaves nothing behind.** In particular, a supplied keyframe map never
///    reaches the local sidecar — persisting a remote assertion there would
///    let a later play treat it as this machine's own harvest, and the
///    sidecar's identity key (local size, mtime) does not even record where it
///    came from.
@Suite("Source open hints")
struct SourceOpenHintsTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreHints-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - hints: nil is the unhinted path

    @Test("`hints: nil` reaches exactly the verdict the plain open does")
    func nilHintsAreTheOldPath() throws {
        let source = try fixture("h264_aac_30s.mkv")
        let plain = try SourceProbe.open(url: source)
        let nilHinted = try SourceProbe.open(source, hints: nil)

        #expect(plain.info.formatName == nilHinted.info.formatName)
        #expect(plain.info.duration == nilHinted.info.duration)
        #expect(plain.info.nativeReadiness == nilHinted.info.nativeReadiness)
        #expect(plain.info.video?.streamIndex == nilHinted.info.video?.streamIndex)
        #expect(plain.info.audioTracks.count == nilHinted.info.audioTracks.count)
        // Nothing was supplied, so there is nothing to report — and in
        // particular no empty-but-present hint record for a host to misread as
        // "hints were tried and failed".
        #expect(plain.hints == .unhinted)
        #expect(nilHinted.hints == .unhinted)
        #expect(nilHinted.hints.wereSupplied == false)
        #expect(nilHinted.hints.rejections.isEmpty)
        #expect(nilHinted.hints.acceptedKeyframes == nil)
        // And an unhinted open still exports nothing it was not asked for.
        #expect(nilHinted.structure == .unknown)
    }

    @Test("Sizing hints change what is read, never what is concluded")
    func sizingHintsDoNotChangeTheVerdict() throws {
        let source = try fixture("h264_aac_30s.mkv")
        let plain = try SourceProbe.open(url: source)
        let hinted = try SourceProbe.open(source, hints: SourceOpenHints(
            headerBytes: 4312, firstClusterOffset: 5184, indexLocation: .tail
        ))
        #expect(plain.info.formatName == hinted.info.formatName)
        #expect(plain.info.duration == hinted.info.duration)
        #expect(plain.info.video?.streamIndex == hinted.info.video?.streamIndex)
        #expect(hinted.hints.wereSupplied)
        // No validator was asked for, so no check fired and nothing was
        // refused: a caller that makes no claim fails none.
        #expect(hinted.hints.rejections.isEmpty)
    }

    @Test("A deliberately wrong sizing hint costs a read, not a verdict")
    func wrongSizingHintIsHarmless() throws {
        let source = try fixture("h264_aac_30s.mkv")
        let plain = try SourceProbe.open(url: source)
        // Nonsense: a header far larger than the whole fixture. The contract's
        // promise is that this costs at most a read — the parse is unchanged
        // because the bytes are parsed exactly as they were.
        let hinted = try SourceProbe.open(source, hints: SourceOpenHints(
            headerBytes: 900_000_000, indexLocation: .head
        ))
        #expect(plain.info.formatName == hinted.info.formatName)
        #expect(plain.info.duration == hinted.info.duration)
        #expect(plain.info.nativeReadiness == hinted.info.nativeReadiness)
    }

    // MARK: - The validator gate

    @Test("A map offered without a stated validator is refused by rule")
    func mapWithoutValidatorIsRefused() throws {
        let source = try fixture("h264_aac_30s.mkv")
        let probed = try SourceProbe.open(source, hints: SourceOpenHints(
            keyframes: SuppliedKeyframeMap(
                streamIndex: 0, timeBaseNum: 1, timeBaseDen: 1000,
                keyframePTS: [0, 2000, 4000], completeness: .complete
            )
        ))
        // Not "we looked and it did not fit" — it was never eligible. A map
        // consumed on the catalog binding alone is the one failure mode the
        // design calls worse than the status quo.
        #expect(probed.hints.rejections == [.validatorNotRequested])
        #expect(probed.hints.acceptedKeyframes == nil)
    }

    @Test("A transport that reports no validator cannot carry a map")
    func mapOverATransportWithNoValidator() throws {
        // A local file: there is no ETag, no Last-Modified, nothing for the
        // expectation to be checked against. That is a rejection of the hints
        // and not of the play, which is why `info` below is still whole.
        let source = try fixture("h264_aac_30s.mkv")
        let probed = try SourceProbe.open(source, hints: SourceOpenHints(
            expectedValidator: "\"16777234-8394021\"",
            keyframes: SuppliedKeyframeMap(
                streamIndex: 0, timeBaseNum: 1, timeBaseDen: 1000,
                keyframePTS: [0, 2000, 4000], completeness: .complete
            )
        ))
        #expect(probed.hints.rejections == [.validatorUnavailable])
        #expect(probed.hints.acceptedKeyframes == nil)
        #expect(probed.hints.reportedValidator == nil)
        #expect(probed.info.video != nil, "a rejected hint must not cost the play")
    }

    @Test("Over a real origin the validator is observed, and a mismatch drops the map")
    func validatorObservedOverHTTP() async throws {
        let media = try Data(contentsOf: try fixture("h264_aac_30s.mkv"))
        let server = try RangeFixtureServer(media: media, etag: "\"v1-abc\"")
        let url = try await server.start()
        defer { server.stop() }

        let map = SuppliedKeyframeMap(
            streamIndex: 0, timeBaseNum: 1, timeBaseDen: 1000,
            keyframePTS: [0, 2000, 4000], completeness: .complete
        )
        // The version the caller thought it was reading is gone; the origin is
        // serving another one. Before the first byte reaches a parser, so this
        // is a hint problem and not a poisoned session — the open carries on
        // unhinted.
        let stale = try await SourceProbe.openDetached(
            url: url, coordinatedHTTP: true,
            hints: SourceOpenHints(expectedValidator: "\"v0-stale\"", keyframes: map)
        )
        #expect(stale.hints.reportedValidator == "\"v1-abc\"")
        #expect(stale.hints.rejections == [
            .validatorMismatch(expected: "\"v0-stale\"", reported: "\"v1-abc\"")
        ])
        #expect(stale.hints.acceptedKeyframes == nil)
        #expect(stale.info.video != nil, "the open proceeded unhinted, as it must")

        let bound = try await SourceProbe.openDetached(
            url: url, coordinatedHTTP: true,
            hints: SourceOpenHints(expectedValidator: "\"v1-abc\"", keyframes: map)
        )
        #expect(bound.hints.reportedValidator == "\"v1-abc\"")
        #expect(bound.hints.rejections.isEmpty)
        #expect(bound.hints.acceptedKeyframes == map)
    }

    @Test("A sizing hint larger than a block widens the first read; a smaller one does not shrink it")
    func firstReadSizing() async throws {
        let media = try Data(contentsOf: try fixture("h264_aac_30s.mkv"))
        let server = try RangeFixtureServer(media: media, etag: "\"v1\"")
        let url = try await server.start()
        defer { server.stop() }

        let wide = try await SourceProbe.openDetached(
            url: url, coordinatedHTTP: true,
            hints: SourceOpenHints(firstClusterOffset: 3 << 20)
        )
        #expect(wide.hints.firstReadBytes == 3 << 20)

        // Downward is deliberately inert: this reader's first read is already
        // a bounded `bytes=0-1048575`, and shrinking it below a block would
        // turn one round trip into several on any file whose analysis reads
        // past its header.
        let narrow = try await SourceProbe.openDetached(
            url: url, coordinatedHTTP: true,
            hints: SourceOpenHints(firstClusterOffset: 4312)
        )
        #expect(narrow.hints.firstReadBytes == 1 << 20)
    }

    // MARK: - §6.3, structurally

    private func facts(
        streamIndex: Int32 = 0, timeBaseNum: Int32 = 1, timeBaseDen: Int32 = 1000,
        startPTS: Int64? = 0, durationPTS: Int64? = 30_000
    ) -> SuppliedKeyframeMap.StreamFacts {
        .init(videoStreamIndexes: [0, 3], streamIndex: streamIndex,
              timeBaseNum: timeBaseNum, timeBaseDen: timeBaseDen,
              startPTS: startPTS, durationPTS: durationPTS)
    }

    private func map(
        streamIndex: Int32 = 0, timeBaseNum: Int32 = 1, timeBaseDen: Int32 = 1000,
        keyframePTS: [Int64] = [0, 2000, 4000],
        completeness: IndexCompleteness = .complete,
        coveredThroughPTS: Int64? = nil
    ) -> SuppliedKeyframeMap {
        .init(streamIndex: streamIndex, timeBaseNum: timeBaseNum, timeBaseDen: timeBaseDen,
              keyframePTS: keyframePTS, completeness: completeness,
              coveredThroughPTS: coveredThroughPTS)
    }

    @Test("A well-formed map against the stream it names passes")
    func validMapPasses() {
        #expect(map().validate(against: facts()) == nil)
        #expect(map(keyframePTS: [0, 2000, 4000], completeness: .partial, coveredThroughPTS: 4000)
            .validate(against: facts()) == nil)
    }

    @Test("A map for another stream is refused rather than remapped")
    func streamMismatch() {
        // Stream 3 IS a video stream in this source — and still refused,
        // because which stream a plan is cut on is not a thing to infer from
        // a hint.
        #expect(map(streamIndex: 3).validate(against: facts()) == .streamMismatch(supplied: 3))
        #expect(map(streamIndex: 1).validate(against: facts()) == .streamMismatch(supplied: 1))
    }

    @Test("A time base that is not the stream's means the identity lied")
    func timeBaseMismatch() {
        #expect(map(timeBaseDen: 90_000).validate(against: facts())
                == .timeBaseMismatch(supplied: "1/90000", actual: "1/1000"))
    }

    @Test("Timestamps must be plural, strictly increasing and inside the cap")
    func malformedTimestamps() {
        #expect(map(keyframePTS: [0]).validate(against: facts()) != nil)
        #expect(map(keyframePTS: [0, 2000, 2000]).validate(against: facts()) != nil)
        #expect(map(keyframePTS: [0, 4000, 2000]).validate(against: facts()) != nil)
        let overCap = (0...SuppliedKeyframeMap.maxEntries).map(Int64.init)
        #expect(map(keyframePTS: overCap).validate(
            against: facts(durationPTS: Int64(overCap.count))
        ) != nil)
    }

    @Test("Timestamps outside the stream's own span reject the whole map")
    func outOfBounds() {
        #expect(map(keyframePTS: [-500, 2000]).validate(against: facts()) != nil)
        #expect(map(keyframePTS: [0, 2000, 99_999]).validate(against: facts()) != nil)
        // One bad entry rejects everything, not just itself: a map with an
        // impossible timestamp is a map whose producer, identity or transport
        // is wrong about something, and the plausible-looking entries have
        // earned no more trust than the impossible one.
        #expect(map(keyframePTS: [0, 2000, 4000, 99_999]).validate(against: facts()) != nil)
    }

    @Test("Only `complete` and a well-marked `partial` may be planned from")
    func completenessGate() {
        #expect(map(completeness: .unknown).validate(against: facts()) != nil)
        #expect(map(completeness: .absent).validate(against: facts()) != nil)
        // A partial map has to say where its run ends…
        #expect(map(completeness: .partial).validate(against: facts()) != nil)
        // …and the marker has to be one of its own entries: a covered-through
        // value nobody recorded describes a prefix nothing can be planned to.
        #expect(map(completeness: .partial, coveredThroughPTS: 3000)
            .validate(against: facts()) != nil)
        #expect(map(completeness: .partial, coveredThroughPTS: 2000)
            .validate(against: facts()) == nil)
    }

    // MARK: - The sidecar stays clean

    @Test("A supplied map never reaches the local keyframe sidecar")
    func suppliedMapNeverReachesTheSidecar() async throws {
        let cacheDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let source = try fixture("h264_aac_30s.mkv")

        // Sentinel timestamps no real 30 s fixture could produce. If any of
        // them ever appears in the sidecar, a remote assertion has been
        // persisted as this machine's own harvest — which a later play would
        // trust without ever revalidating it, because the sidecar's identity
        // key records size and mtime and says nothing about provenance.
        let sentinel: [Int64] = [111_111_111, 222_222_222, 333_333_333]
        let probed = try SourceProbe.open(source, hints: SourceOpenHints(
            expectedValidator: "\"whatever\"",
            keyframes: SuppliedKeyframeMap(
                streamIndex: 0, timeBaseNum: 1, timeBaseDen: 1000,
                keyframePTS: sentinel, completeness: .complete
            )
        ))
        #expect(probed.hints.acceptedKeyframes == nil, "a file URL reports no validator")

        let session = try PrismCoreSession(
            url: source,
            display: DisplayCapabilities(isHDRReady: false, isDolbyVisionCapable: false),
            probed: probed,
            keyframeIndexCacheDirectory: cacheDirectory
        )
        _ = try await session.start()
        await session.stop()

        // Whatever the session chose to store — a Matroska with Cues stores
        // the index it built from the file — none of it may be the map that
        // arrived from outside.
        let sidecars = try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path)
            .filter { $0.hasSuffix(".json") }
        for name in sidecars {
            let entry = try JSONDecoder().decode(
                KeyframeIndexCache.Entry.self,
                from: Data(contentsOf: cacheDirectory.appendingPathComponent(name))
            )
            for timestamp in sentinel {
                #expect(!entry.keyframePTS.contains(timestamp),
                        "a supplied map was persisted into the local sidecar")
            }
        }
    }
}
