import Testing
import Foundation
import CoreMedia
import AVFoundation
import Libavformat
import Libavcodec
import Libavutil
@testable import PrismCore

@Suite("Playback observability", .serialized)
struct PlaybackObservabilityTests {
    @Test func staleEvictionDoesNotRemoveReproducedSegment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PrismCoreResident-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResidentSegmentStore()
        try store.publish(index: 1, start: 2, end: 8, data: Data([1]), root: root)
        store.retire([1])
        try store.publish(index: 1, start: 2, end: 8, data: Data([2]), root: root)
        store.unlinkRetired(index: 1, directories: [root])
        #expect(try Data(contentsOf: root.appendingPathComponent("seg00001.m4s")) == Data([2]))
        store.retire([1])
        store.unlinkRetired(index: 1, directories: [root])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("seg00001.m4s").path))
    }
    @Test func softwareDelayPreservesVideoAndClock() throws {
        let fixture = try #require(Bundle.module.url(forResource: "h264_aac", withExtension: "mkv", subdirectory: "Fixtures"))
        func times(_ offset: Double) throws -> (audio: Double, video: Double, clock: Double) {
            let video = RecordingVideoSink()
            let audio = RecordingAudioSink()
            let clock = RecordingTimeline()
            let pipeline = SoftwarePlaybackPipeline(videoSink: video, audioSink: audio,
                timeline: clock, allowHardwareDecode: false, audioDelaySeconds: offset)
            defer { pipeline.stop() }
            try pipeline.load(url: fixture)
            let a = try #require(audio.enqueued.first)
            let v = try #require(video.enqueued.first)
            #expect(pipeline.audioDelivery == .decoded)
            return (CMSampleBufferGetPresentationTimeStamp(a).seconds,
                    CMSampleBufferGetPresentationTimeStamp(v).seconds, clock.currentTime.seconds)
        }
        let baseline = try times(0)
        for offset in [-0.15, 0.2] {
            let shifted = try times(offset)
            #expect(abs(shifted.audio - baseline.audio - offset) < 0.000001)
            #expect(shifted.video == baseline.video)
            #expect(shifted.clock == baseline.clock)
        }
    }

    /// The lowest-numbered segment the producer has landed in `directory`,
    /// waiting for the cut if it has not landed yet.
    ///
    /// `start()` returning does NOT mean segment 0 is on disk. In the
    /// demand-driven shape the whole planned playlist is written before the
    /// first packet is read, so the readiness gate's remaining condition is
    /// the init segment — and `HLSRemuxer` writes the init BEFORE the media
    /// bytes of the same cut, deliberately, so a reader of the manifest can
    /// always fetch what it references. Between those two writes the work
    /// directory holds a servable playlist and no `.m4s` at all, which is
    /// exactly what this test used to trip over under parallel load (twice in
    /// twenty full runs). A host never sees that window: its segment fetch
    /// goes through `PlanSegmentProvider`, which answers `.pending` and
    /// serves the file when the producer lands it. This test reads the
    /// directory instead of the server, so it has to do that seam's waiting
    /// itself — the wait is the missing synchronisation with an asynchronous
    /// producer, not slack added to an assertion: nothing below is relaxed,
    /// and a cut that never comes still fails the test.
    ///
    /// Segments are written `.atomic`, so a name that has appeared is a
    /// complete file.
    private static func firstLandedSegment(
        in directory: URL, timeout: Duration = .seconds(20)
    ) async -> String? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            let segments = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
                .filter { $0.hasPrefix("seg") && $0.hasSuffix(".m4s") }.sorted() ?? []
            if let first = segments.first { return first }
            guard ContinuousClock.now < deadline else { return nil }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test(arguments: [true, false]) func muxedDelaySurvivesContainerWriting(muxed: Bool) async throws {
        let fixture = try #require(Bundle.module.url(forResource: "h264_aac_30s", withExtension: "mkv", subdirectory: "Fixtures"))
        /// Every packet timestamp in the first PRODUCED segment of each output,
        /// per media type — the first segment, not `seg00000` by name: a
        /// rendition whose audio all moved past the head boundary skips that
        /// slot (see `AudioRenditionWriter.cut`).
        func timestamps(delay: Double) async throws -> [Libavutil.AVMediaType: [Double]] {
            let session = try PrismCoreSession(url: fixture, forceMuxedShape: muxed, audioDelaySeconds: delay)
            do {
                _ = try await session.start()
                let root = await session.workDirectory
                var result: [Libavutil.AVMediaType: [Double]] = [:]
                for directory in muxed ? [root] : [root, root.appendingPathComponent("audio0")] {
                    let first = try #require(
                        await Self.firstLandedSegment(in: directory),
                        "no segment landed in \(directory.lastPathComponent)"
                    )
                    let data = try Data(contentsOf: directory.appendingPathComponent("init.mp4"))
                        + Data(contentsOf: directory.appendingPathComponent(first))
                    let file = root.appendingPathComponent("delay-test.mp4")
                    try data.write(to: file)
                    var input: UnsafeMutablePointer<AVFormatContext>?
                    try FFmpegError.check(avformat_open_input(&input, file.path, nil, nil), "delay-test open")
                    defer { avformat_close_input(&input) }
                    let context = try #require(input)
                    var packet = av_packet_alloc()
                    defer { av_packet_free(&packet) }
                    let pkt = try #require(packet)
                    while av_read_frame(context, pkt) >= 0 {
                        let stream = context.pointee.streams[Int(pkt.pointee.stream_index)]!
                        let type = stream.pointee.codecpar.pointee.codec_type
                        result[type, default: []].append(Double(pkt.pointee.pts) * av_q2d(stream.pointee.time_base))
                        av_packet_unref(pkt)
                    }
                }
                await session.stop()
                return result
            } catch { await session.stop(); throw error }
        }
        let baseline = try await timestamps(delay: 0)
        let baselineAudio = try #require(baseline[AVMEDIA_TYPE_AUDIO])
        // The fixture's audio starts BEFORE zero (an AAC priming packet), so a
        // negative delay exercises the drop rule even at -0.15 s. (A delay
        // that moves the whole head segment's audio out of it cannot be read
        // off segment 0 — the muxer interleaves by SOURCE time, so that audio
        // is cut into the next segment — hence no -2 s case here.)
        #expect(baselineAudio.first! < 0)
        for delay in [-0.15, 0.2] {
            let shifted = try await timestamps(delay: delay)
            #expect(shifted[AVMEDIA_TYPE_VIDEO] == baseline[AVMEDIA_TYPE_VIDEO])
            let audio = try #require(shifted[AVMEDIA_TYPE_AUDIO])
            // The audio is the baseline moved by the delay, minus whatever the
            // move took below the origin — dropped, never wrapped or clamped.
            let expected = baselineAudio.map { $0 + delay }.filter { delay >= 0 || $0 >= 0 }
            #expect(audio.count == expected.count)
            if delay < 0 { #expect(audio.allSatisfy { $0 >= 0 }) }
            for (actual, wanted) in zip(audio, expected) {
                #expect(abs(actual - wanted) < 0.002, "delay \(delay): \(actual) vs \(wanted)")
            }
        }
    }
    @Test func residentIslandsAndRetirement() {
        let store = ResidentSegmentStore()
        store.record(index: 0, start: 10, end: 12)
        store.record(index: 1, start: 12, end: 18)
        store.record(index: 3, start: 24, end: 30)
        #expect(store.ranges == [ResidentRange(startSeconds: 10, endSeconds: 18),
                                 ResidentRange(startSeconds: 24, endSeconds: 30)])
        store.retire([1])
        #expect(store.ranges.first?.endSeconds == 12)
        store.clear()
        store.record(index: 4, start: 30, end: 36)
        #expect(store.ranges.isEmpty)
    }

    @Test func audioRoutesDistinguishMissingFromUnusable() {
        let store = AudioDeliveryStore()
        #expect(store.summary == .pending)
        store.prepare(indexes: [])
        #expect(store.summary == .noAudioInSource)
        store.prepare(indexes: [1, 2])
        #expect(store.summary == .unavailable)
        store.update(index: 2, delivery: .streamCopy)
        #expect(store.summary == .streamCopy)
        #expect(store.snapshot.first?.delivery == .unavailable)
    }

    @Test func delayMovesOnlyTimestamps() throws {
        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264, width: 16, height: 16,
            extensions: nil, formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 24),
            presentationTimeStamp: CMTime(seconds: 10, preferredTimescale: 48000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: nil,
            formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sample) == noErr)
        let original = try #require(sample)
        for offset in [-0.15, 0.2] {
            let shifted = try AudioDelay.shifted(original, seconds: offset)
            #expect(abs(CMSampleBufferGetPresentationTimeStamp(shifted).seconds - 10 - offset) < 0.000001)
            #expect(CMSampleBufferGetDuration(shifted) == CMSampleBufferGetDuration(original))
            #expect(!CMSampleBufferGetDecodeTimeStamp(shifted).isValid)
        }
        #expect(CMSampleBufferGetPresentationTimeStamp(original).seconds == 10)
        #expect(AudioDelay.normalized(.nan) == 0)
        #expect(AudioDelay.normalized(12) == 2)
    }

    @Test func cachedPreviewNeverNeedsOrigin() async throws {
        let fixture = try #require(Bundle.module.url(forResource: "h264_aac_30s", withExtension: "mkv", subdirectory: "Fixtures"))
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("PrismCoreSource-\(UUID().uuidString).mkv")
        try FileManager.default.copyItem(at: fixture, to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let session = try PrismCoreSession(url: source)
        do {
            #expect(try await session.cachedThumbnail(at: 2) == nil)
            _ = try await session.start()
            let ranges = session.residentRanges
            let first = try #require(ranges.first)
            try FileManager.default.removeItem(at: source)
            let bytesBefore = session.sourceBytesRead
            let image = try #require(try await session.cachedThumbnail(at: first.startSeconds + 0.1, maxDimension: 160))
            #expect(image.width <= 160 && image.height <= 160)
            #expect(try await session.cachedThumbnail(at: 10000) == nil)
            // A cache miss must not request a producer re-anchor.
            #expect(session.sourceBytesRead >= bytesBefore)
            #expect(session.audioDelivery == .streamCopy)
        } catch {
            await session.stop()
            throw error
        }
        await session.stop()
        #expect(session.residentRanges.isEmpty)
        #expect(try await session.cachedThumbnail(at: 0.1) == nil)
    }
}
