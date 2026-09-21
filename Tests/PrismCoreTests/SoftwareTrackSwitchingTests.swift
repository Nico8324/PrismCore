import Testing
import Foundation
import AVFoundation
import CoreMedia
@testable import PrismCore

/// Issue #35, the audio half: the software pipeline enumerates its source's
/// audio tracks and switches between them mid-playback, leaving the clock and
/// the video renderer untouched.
///
/// The fixture (`h264_multi_audio.mkv`) carries two audio tracks the switch
/// can be *observed* across, not just believed: AAC stereo (eng, stream 1) and
/// AC-3 5.1 (ces, stream 2). The decoder preserves channel count, so the
/// renderer-side proof of the switch is the buffers going from 2 to 6
/// channels.
@Suite("Software audio track switching", .serialized)
struct SoftwareTrackSwitchingTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    private func makePipeline() -> (SoftwarePlaybackPipeline, RecordingVideoSink, RecordingAudioSink, RecordingTimeline) {
        let video = RecordingVideoSink()
        let audio = RecordingAudioSink()
        let timeline = RecordingTimeline()
        let pipeline = SoftwarePlaybackPipeline(
            videoSink: video,
            audioSink: audio,
            timeline: timeline,
            allowHardwareDecode: false
        )
        return (pipeline, video, audio, timeline)
    }

    private func channelCount(of sampleBuffer: CMSampleBuffer) -> Int? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)
        else { return nil }
        return Int(asbd.pointee.mChannelsPerFrame)
    }

    /// Run the switch and wait for its completion flag — the callback fires on
    /// the feed queue, so it has always run once the queue drains.
    private func select(
        _ pipeline: SoftwarePlaybackPipeline, streamIndex: Int
    ) -> Bool {
        let box = LockedResult()
        pipeline.selectAudioTrack(streamIndex: streamIndex) { box.set($0) }
        pipeline.waitForFeedQueue()
        return box.get() ?? false
    }

    final class LockedResult: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool?
        func set(_ newValue: Bool) { lock.withLock { value = newValue } }
        func get() -> Bool? { lock.withLock { value } }
    }

    // MARK: - Enumeration

    @Test("The pipeline enumerates selectable audio tracks with their metadata")
    func enumeratesAudioTracks() throws {
        let (pipeline, _, _, _) = makePipeline()
        try pipeline.load(url: try fixture("h264_multi_audio.mkv"))
        defer { pipeline.stop() }

        let tracks = pipeline.selectableAudioTracks
        try #require(tracks.count == 2)
        #expect(tracks[0].streamIndex == 1)
        #expect(tracks[0].language == "eng")
        #expect(tracks[0].title == "English")
        #expect(tracks[0].channelCount == 2)
        #expect(tracks[1].streamIndex == 2)
        #expect(tracks[1].language == "ces")
        #expect(tracks[1].channelCount == 6)

        // The probe's whole description rides along — the same facts routing
        // reads, now on the live pipeline (chapters included, once a source
        // has them).
        let info = try #require(pipeline.sourceInfo)
        #expect(info.audioTracks.count == 2)
        #expect(info.chapters.isEmpty)
    }

    @Test("The initial selection is published")
    func publishesInitialSelection() throws {
        let (pipeline, _, _, _) = makePipeline()
        try pipeline.load(url: try fixture("h264_multi_audio.mkv"))
        defer { pipeline.stop() }

        #expect(pipeline.selectedAudioStreamIndex == 1)
    }

    // MARK: - Switching

    @Test("Switching tracks feeds the renderer the new track and leaves video monotonic")
    func switchesToTheOtherTrack() throws {
        let (pipeline, video, audio, timeline) = makePipeline()
        try pipeline.load(url: try fixture("h264_multi_audio.mkv"))
        defer { pipeline.stop() }
        pipeline.play()
        pipeline.waitForFeedQueue()

        // Let some of both streams through before switching.
        for _ in 0..<4 {
            video.playOut()
            audio.playOut()
        }
        let audioBefore = audio.enqueued.count
        #expect(audioBefore > 0)
        #expect(channelCount(of: audio.enqueued[0]) == 2, "starts on the AAC stereo track")
        let rateChangesBeforeSwitch = timeline.rateChanges.count

        #expect(select(pipeline, streamIndex: 2))
        #expect(pipeline.selectedAudioStreamIndex == 2)
        #expect(pipeline.routeDescription.contains("ac3"))

        // The switch flushed the audio renderer and re-fed it from the new
        // track — 6-channel buffers now.
        #expect(audio.flushCount == 1)
        for _ in 0..<4 {
            video.playOut()
            audio.playOut()
        }
        let afterSwitch = audio.enqueued
        try #require(!afterSwitch.isEmpty, "the new track must flow after the switch")
        #expect(afterSwitch.allSatisfy { channelCount(of: $0) == 6 })

        // The clock was never touched: no rate change beyond what transport
        // already did, and the video renderer saw no flush and no timestamp
        // regression across the switch.
        #expect(timeline.rateChanges.count == rateChangesBeforeSwitch)
        #expect(video.flushes.isEmpty)
        var previous: CMTime?
        for frame in video.enqueued {
            let pts = CMSampleBufferGetPresentationTimeStamp(frame)
            if let previous { #expect(pts > previous, "video must not replay across a switch") }
            previous = pts
        }
    }

    @Test("Switching while paused primes the new track without starting the clock")
    func switchesWhilePaused() throws {
        let (pipeline, _, audio, timeline) = makePipeline()
        try pipeline.load(url: try fixture("h264_multi_audio.mkv"))
        defer { pipeline.stop() }

        #expect(select(pipeline, streamIndex: 2))
        #expect(pipeline.state == .paused)
        #expect(timeline.rate == 0)
        #expect(pipeline.selectedAudioStreamIndex == 2)
        audio.playOut()
        pipeline.waitForFeedQueue()
        let afterSwitch = audio.enqueued.filter { channelCount(of: $0) == 6 }
        #expect(!afterSwitch.isEmpty, "the new track is primed while paused")
    }

    // MARK: - Refusals

    @Test("Selecting the playing track is a no-op that reports success")
    func selectingCurrentTrackSucceedsQuietly() throws {
        let (pipeline, _, audio, _) = makePipeline()
        try pipeline.load(url: try fixture("h264_multi_audio.mkv"))
        defer { pipeline.stop() }

        #expect(select(pipeline, streamIndex: 1))
        #expect(audio.flushCount == 0, "no teardown for a selection that changes nothing")
    }

    @Test("A stream index that is not audio is refused, and playback keeps its track")
    func refusesNonAudioStream() throws {
        let (pipeline, _, _, _) = makePipeline()
        try pipeline.load(url: try fixture("h264_multi_audio.mkv"))
        defer { pipeline.stop() }

        #expect(!select(pipeline, streamIndex: 0), "stream 0 is the video track")
        #expect(!select(pipeline, streamIndex: 7), "out of range")
        #expect(!select(pipeline, streamIndex: Int.max))
        #expect(!select(pipeline, streamIndex: Int.min))
        #expect(!select(pipeline, streamIndex: -1))
        #expect(pipeline.selectedAudioStreamIndex == 1)
    }

    @Test("A switch at a nonzero playhead preserves output delay and supports switching back",
          arguments: [-0.5, 0.0, 0.5])
    func switchesAtPresentationTime(delay: Double) throws {
        let video = RecordingVideoSink()
        let audio = RecordingAudioSink()
        let timeline = RecordingTimeline()
        let pipeline = SoftwarePlaybackPipeline(videoSink: video, audioSink: audio,
            timeline: timeline, allowHardwareDecode: false, audioDelaySeconds: delay)
        try pipeline.load(url: try fixture("h264_multi_audio.mkv"))
        defer { pipeline.stop() }
        pipeline.waitForFeedQueue()
        for _ in 0..<4 { video.playOut(); audio.playOut() }
        timeline.setRate(0, time: CMTime(seconds: 2, preferredTimescale: 1_000))
        let changes = timeline.rateChanges.count
        for index in [2, 1, 2] {
            #expect(select(pipeline, streamIndex: index))
            for _ in 0..<3 { video.playOut(); audio.playOut() }
            try #require(!audio.enqueued.isEmpty)
            #expect(audio.enqueued.allSatisfy {
                CMSampleBufferGetPresentationTimeStamp($0) + CMSampleBufferGetDuration($0)
                    > timeline.currentTime
            })
            let firstPTS = CMSampleBufferGetPresentationTimeStamp(audio.enqueued[0])
            // AAC/AC-3 frame rounding may straddle the playhead, but a positive
            // delay must not introduce an extra half-second hole after switching.
            #expect(firstPTS <= timeline.currentTime + CMTime(seconds: 0.04, preferredTimescale: 1_000))
            #expect(audio.enqueued.allSatisfy { channelCount(of: $0) == (index == 2 ? 6 : 2) })
        }
        #expect(timeline.rateChanges.count == changes)
        #expect(video.flushes.isEmpty)
    }

    @Test("Switching cancels an EOF boundary, including a callback already queued")
    func switchInvalidatesOldEndBoundary() throws {
        let (pipeline, video, audio, timeline) = makePipeline()
        try pipeline.load(url: try fixture("h264_multi_audio.mkv"))
        defer { pipeline.stop() }
        pipeline.waitForFeedQueue()
        for _ in 0..<100 { video.playOut(); audio.playOut() }
        let oldBoundary = try #require(timeline.pendingBoundary)
        timeline.setRate(0, time: CMTime(seconds: 2, preferredTimescale: 1_000))
        let gate = DispatchSemaphore(value: 0)
        pipeline.blockFeedQueueForTesting(until: gate)
        pipeline.selectAudioTrack(streamIndex: 2)
        oldBoundary.fire()
        gate.signal()
        pipeline.waitForFeedQueue()
        #expect(pipeline.state == .paused)
        #expect(pipeline.selectedAudioStreamIndex == 2)
        #expect(timeline.cancelledBoundaries > 0)
        #expect(CMTimeGetSeconds(pipeline.currentTime) == 2)
    }

    @Test("A refused audio rewind at EOF preserves the audio-only end boundary")
    func refusedRewindPreservesAudioOnlyEndBoundary() throws {
        let audio = RecordingAudioSink()
        let timeline = RecordingTimeline()
        let seekRefused = LockedResult()
        let pipeline = SoftwarePlaybackPipeline(
            videoSink: RecordingVideoSink(), audioSink: audio, timeline: timeline,
            allowHardwareDecode: false, demuxSeek: { _, _ in
                seekRefused.set(true)
                return -1
            })
        try pipeline.load(url: fixture("audio_only_multi.mka"))
        defer { pipeline.stop() }
        pipeline.waitForFeedQueue()
        for _ in 0..<100 where timeline.pendingBoundary == nil { audio.playOut() }
        let oldBoundary = try #require(timeline.pendingBoundary)
        #expect(oldBoundary.time > timeline.currentTime)
        #expect(!audio.queued.isEmpty)
        seekRefused.set(false)

        let gate = DispatchSemaphore(value: 0)
        pipeline.blockFeedQueueForTesting(until: gate)
        pipeline.selectAudioTrack(streamIndex: 1)
        oldBoundary.fire()
        gate.signal()
        pipeline.waitForFeedQueue()

        #expect(seekRefused.get() == true)
        #expect(pipeline.selectedAudioStreamIndex == 1)
        #expect(pipeline.state == .paused)
        let replacementBoundary = try #require(timeline.pendingBoundary)
        #expect(replacementBoundary.time == oldBoundary.time)
        timeline.reachBoundary()
        pipeline.waitForFeedQueue()
        #expect(pipeline.state == .ended)
        #expect(timeline.currentTime == oldBoundary.time)
    }

    @Test("Selection is refused before load and after stop")
    func refusesSelectionOutsidePlayback() throws {
        let (pipeline, _, _, _) = makePipeline()
        #expect(!select(pipeline, streamIndex: 1))
        try pipeline.load(url: try fixture("h264_multi_audio.mkv"))
        pipeline.stop()
        #expect(!select(pipeline, streamIndex: 2))
        #expect(pipeline.selectedAudioStreamIndex == nil)
    }

    @Test("Stopping an adopted pipeline permanently cancels its seek/read guard")
    func stopPermanentlyCancelsAdoptedReadGuard() throws {
        let probed = try SourceProbe.open(url: fixture("h264_multi_audio.mkv"))
        let (pipeline, _, _, _) = makePipeline()
        try pipeline.load(probed: probed)
        pipeline.stop()
        let guardBox = probed.interruptGuard
        guardBox.disarm()
        guardBox.arm(budget: .seconds(60))
        #expect(guardBox.shouldInterrupt)
    }
}
