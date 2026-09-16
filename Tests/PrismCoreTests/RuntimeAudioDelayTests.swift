import Testing
import Foundation
import CoreMedia
import AVFoundation
import Libavformat
import Libavcodec
import Libavutil
@testable import PrismCore

/// The audio offset is a lip-sync control: a viewer turns it with the picture
/// in front of them, so it has to be changeable mid-title. The two paths answer
/// that differently, and these tests pin BOTH the behaviour and the report:
///
/// - software: applied at the renderer boundary, in force when the call returns;
/// - remux: fMP4 segments are already on disk with the old offset, so the change
///   waits for a producer re-anchor and `audioDelaySeconds` keeps naming what is
///   actually being served until then.
@Suite("Runtime audio delay", .serialized)
struct RuntimeAudioDelayTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    /// Run the change and wait for its completion flag — the callback fires on
    /// the feed queue, so it has always run once the queue drains.
    @discardableResult
    private func setDelay(_ pipeline: SoftwarePlaybackPipeline, _ seconds: Double) -> Bool {
        let box = SoftwareTrackSwitchingTests.LockedResult()
        pipeline.setAudioDelaySeconds(seconds) { box.set($0) }
        pipeline.waitForFeedQueue()
        return box.get() ?? false
    }

    // MARK: - Software path

    @Test("A delay changed mid-playback lands on the enqueued timestamps",
          arguments: [-0.5, 0.25, 0.5])
    func softwareChangeMovesEnqueuedAudioToThePlayhead(delay: Double) throws {
        let video = RecordingVideoSink()
        let audio = RecordingAudioSink()
        let timeline = RecordingTimeline()
        let pipeline = SoftwarePlaybackPipeline(videoSink: video, audioSink: audio,
            timeline: timeline, allowHardwareDecode: false)
        try pipeline.load(url: try fixture("h264_aac.mkv"))
        defer { pipeline.stop() }
        pipeline.waitForFeedQueue()
        for _ in 0..<4 { video.playOut(); audio.playOut() }
        timeline.setRate(0, time: CMTime(seconds: 2, preferredTimescale: 1_000))
        let rateChanges = timeline.rateChanges.count

        #expect(setDelay(pipeline, delay))
        #expect(pipeline.audioDelaySeconds == delay)
        for _ in 0..<3 { video.playOut(); audio.playOut() }

        try #require(!audio.enqueued.isEmpty)
        let firstPTS = CMSampleBufferGetPresentationTimeStamp(audio.enqueued[0])
        // The whole claim in one number. The refill reads the source at
        // `playhead - delay` and the enqueue shifts it by `+delay`, so the
        // first buffer presents AT the playhead whatever the offset is.
        // Miss either half and this is out by the delay itself — 0.5 s against
        // a frame's worth of tolerance.
        #expect(firstPTS <= timeline.currentTime + CMTime(seconds: 0.04, preferredTimescale: 1_000))
        #expect(audio.enqueued.allSatisfy {
            CMSampleBufferGetPresentationTimeStamp($0) + CMSampleBufferGetDuration($0)
                > timeline.currentTime
        })
        // Video, subtitles and the clock are not part of this change.
        #expect(video.flushes.isEmpty)
        #expect(timeline.rateChanges.count == rateChanges)
    }

    @Test("Setting the delay it already has costs nothing")
    func softwareUnchangedDelayDoesNotFlush() throws {
        let audio = RecordingAudioSink()
        let pipeline = SoftwarePlaybackPipeline(videoSink: RecordingVideoSink(),
            audioSink: audio, timeline: RecordingTimeline(),
            allowHardwareDecode: false, audioDelaySeconds: 0.2)
        try pipeline.load(url: try fixture("h264_aac.mkv"))
        defer { pipeline.stop() }

        #expect(setDelay(pipeline, 0.2))
        #expect(audio.flushCount == 0, "no refeed for a change that changes nothing")
        #expect(pipeline.audioDelaySeconds == 0.2)
    }

    @Test("The clamp still holds for a delay set at runtime")
    func softwareRuntimeDelayIsClamped() throws {
        let pipeline = SoftwarePlaybackPipeline(videoSink: RecordingVideoSink(),
            audioSink: RecordingAudioSink(), timeline: RecordingTimeline(),
            allowHardwareDecode: false)
        try pipeline.load(url: try fixture("h264_aac.mkv"))
        defer { pipeline.stop() }

        for (asked, expected) in [(9.0, 2.0), (-9.0, -2.0), (Double.infinity, 0.0),
                                  (Double.nan, 0.0), (0.25, 0.25)] {
            setDelay(pipeline, asked)
            #expect(pipeline.audioDelaySeconds == expected, "asked for \(asked)")
        }
    }

    @Test("A stopped pipeline refuses the change and keeps reporting the old value")
    func softwareDelayRefusedAfterStop() throws {
        let pipeline = SoftwarePlaybackPipeline(videoSink: RecordingVideoSink(),
            audioSink: RecordingAudioSink(), timeline: RecordingTimeline(),
            allowHardwareDecode: false, audioDelaySeconds: 0.3)
        try pipeline.load(url: try fixture("h264_aac.mkv"))
        pipeline.stop()
        #expect(!setDelay(pipeline, 1.0))
        #expect(pipeline.audioDelaySeconds == 0.3)
    }

    // MARK: - Remux path

    /// Which segments are on disk right now, by index.
    private func segmentIndexes(root: URL) -> [Int] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0.hasPrefix("seg") && $0.hasSuffix(".m4s") }
            .compactMap { Int($0.dropFirst(3).dropLast(4)) }.sorted()
    }

    /// Every packet timestamp in one produced segment, per media type — the
    /// same read as the fixed-delay coverage, so the two assert against
    /// comparable numbers.
    private func segmentTimestamps(root: URL, index: Int) throws -> [Libavutil.AVMediaType: [Double]] {
        let name = String(format: "seg%05d.m4s", index)
        let data = try Data(contentsOf: root.appendingPathComponent("init.mp4"))
            + Data(contentsOf: root.appendingPathComponent(name))
        let file = root.appendingPathComponent("runtime-delay-read.mp4")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var input: UnsafeMutablePointer<AVFormatContext>?
        try FFmpegError.check(avformat_open_input(&input, file.path, nil, nil), "runtime-delay open")
        defer { avformat_close_input(&input) }
        let context = try #require(input)
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        let pkt = try #require(packet)
        var result: [Libavutil.AVMediaType: [Double]] = [:]
        while av_read_frame(context, pkt) >= 0 {
            let stream = context.pointee.streams[Int(pkt.pointee.stream_index)]!
            result[stream.pointee.codecpar.pointee.codec_type, default: []]
                .append(Double(pkt.pointee.pts) * av_q2d(stream.pointee.time_base))
            av_packet_unref(pkt)
        }
        return result
    }

    /// Poll `body` until it answers true or the deadline passes. The remux
    /// contract is eventual by construction — the producer adopts the new
    /// offset on its own thread, at its next re-anchor — so the test waits for
    /// the engine's own report rather than guessing a sleep.
    private func waitUntil(_ seconds: Double = 10, _ body: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if await body() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await body()
    }

    /// One AAC frame at 44.1 kHz. The tolerance every comparison below needs:
    /// a re-anchored muxer restarts its interleave, so the segment's first
    /// audio frame can be one frame either side of where the sequential run
    /// put it. The offset under test is twenty times that.
    private let audioFrameSeconds = 1024.0 / 44_100.0

    @Test("A delay set while serving is reported pending, then takes effect at the re-anchor")
    func remuxDelayTakesEffectAtTheReanchor() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac_30s.mkv"), forceMuxedShape: true)
        do {
            let playlist = try await session.start()
            let root = await session.workDirectory
            // Fetch segment 0 off the loopback so the engine has a playhead:
            // with no client asking for anything, the offset change re-anchors
            // wherever production happens to be, and this test wants the one
            // segment whose audio starts below the timeline's origin.
            let segment0 = playlist.deletingLastPathComponent().appendingPathComponent("seg00000.m4s")
            _ = try await URLSession.shared.data(from: segment0)
            let baseline = try segmentTimestamps(root: root, index: 0)
            let baselineAudio = try #require(baseline[AVMEDIA_TYPE_AUDIO])
            // The fixture's audio starts BEFORE zero (an AAC priming packet),
            // which is what makes a negative delay exercise the origin rule.
            #expect(baselineAudio.first! < 0)

            let delay = -0.5
            let outcome = await session.setAudioDelaySeconds(delay)
            try #require(outcome == .pendingReanchor,
                         "the fixture must plan, or there is no re-anchor to carry the change")
            // The honest half of the contract: until the producer adopts it,
            // `audioDelaySeconds` still names what is being served.
            #expect(await session.audioDelaySeconds == 0)
            #expect(await session.pendingAudioDelaySeconds == delay)

            let adopted = await waitUntil { await session.pendingAudioDelaySeconds == nil }
            #expect(adopted, "the producer never took the request up")
            #expect(await session.audioDelaySeconds == delay)

            // …and the bytes on disk agree with the report. Polled: the
            // re-anchored producer has to rewrite the segment it discarded.
            let expectedEnd = baselineAudio.last! + delay
            let rewritten = await waitUntil {
                guard let audio = try? segmentTimestamps(root: root, index: 0)[AVMEDIA_TYPE_AUDIO],
                      let last = audio.last else { return false }
                return abs(last - expectedEnd) <= audioFrameSeconds
            }
            #expect(rewritten, "the re-anchored segment never carried the new offset")

            let shifted = try segmentTimestamps(root: root, index: 0)
            let shiftedAudio = try #require(shifted[AVMEDIA_TYPE_AUDIO])
            // A negative delay may never write a packet below the timeline's
            // origin: `avoid_negative_ts` is off so tfdt can carry absolute
            // time across the restart, and movenc writes tfdt UNSIGNED — a
            // negative dts wraps into the billions. The frames the shift takes
            // below zero are dropped instead.
            //
            // "Zero" is read here as the source's own first timestamp: this
            // read hands the re-anchored segment to the demuxer together with
            // the init segment, whose edit list moves every reported time down
            // by the AAC priming frame the baseline's first packet sits on.
            #expect(shiftedAudio.allSatisfy { $0 >= baselineAudio.first! })
            #expect(shiftedAudio.first! < baselineAudio.first! + 2 * audioFrameSeconds,
                    "the survivors start AT the origin, so nothing above it was dropped too")
            #expect(shiftedAudio.allSatisfy { $0 < 60 }, "an unsigned tfdt wrap reads as astronomical")
            #expect(shiftedAudio.count < baselineAudio.count, "the below-origin frames went")
            // Video is not part of this change: same packets, and the segment
            // still starts where the plan put it.
            let shiftedVideo = try #require(shifted[AVMEDIA_TYPE_VIDEO])
            let baselineVideo = try #require(baseline[AVMEDIA_TYPE_VIDEO])
            #expect(shiftedVideo.count == baselineVideo.count)
            #expect(zip(shiftedVideo, baselineVideo).allSatisfy { abs($0 - $1) < 0.002 })
            await session.stop()
        } catch { await session.stop(); throw error }
    }

    @Test("Discarding the segments written with the old offset leaves nothing to serve")
    func retireAllRemovesEverySegmentFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreRuntimeDelay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResidentSegmentStore()
        for index in 0..<3 {
            try store.publish(index: index, start: Double(index) * 6, end: Double(index + 1) * 6,
                              data: Data([UInt8(index)]), root: root)
        }
        let retired = store.retireAll().sorted()
        #expect(retired == [0, 1, 2])
        #expect(store.ranges.isEmpty)
        for index in retired { store.unlinkRetired(index: index, directories: [root]) }
        #expect(segmentIndexes(root: root).isEmpty)
    }

    @Test("Before start() the change is in force at once; after stop() it is refused")
    func remuxDelayBeforeStartAndAfterStop() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac.mkv"), audioDelaySeconds: 0.4)
        #expect(await session.audioDelaySeconds == 0.4)
        // Nothing is on disk yet, so there is nothing to invalidate.
        #expect(await session.setAudioDelaySeconds(9) == .inForce)
        #expect(await session.audioDelaySeconds == 2)
        #expect(await session.setAudioDelaySeconds(.nan) == .inForce)
        #expect(await session.audioDelaySeconds == 0)
        #expect(await session.pendingAudioDelaySeconds == nil)

        await session.stop()
        #expect(await session.setAudioDelaySeconds(1) == .sessionStopped)
        #expect(await session.audioDelaySeconds == 0)
    }

    @Test("A fallback session carries the offset the host last asked for")
    func fallbackCarriesTheRequestedOffset() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac.mkv"))
        #expect(await session.setAudioDelaySeconds(-0.25) == .inForce)
        let fallback = try await session.makeMuxedFallbackSession()
        #expect(await fallback.audioDelaySeconds == -0.25)
        await session.stop()
        await fallback.stop()
    }
}
