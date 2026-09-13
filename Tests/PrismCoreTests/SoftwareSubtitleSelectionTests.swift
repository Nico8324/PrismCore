import Testing
import Foundation
import CoreMedia
@testable import PrismCore

@Suite("Software text subtitle selection", .serialized)
struct SoftwareSubtitleSelectionTests {
    private func select(_ pipeline: SoftwarePlaybackPipeline, _ index: Int?) -> Bool {
        let result = SoftwareTrackSwitchingTests.LockedResult()
        pipeline.selectSubtitleTrack(streamIndex: index) { result.set($0) }
        pipeline.waitForFeedQueue()
        return result.get() ?? false
    }

    @Test("Text selection and Off use cached cues without disturbing paused A/V")
    func switchesTextAtPausedPresentationTime() throws {
        let video = RecordingVideoSink()
        let audio = RecordingAudioSink()
        let timeline = RecordingTimeline()
        let pipeline = SoftwarePlaybackPipeline(videoSink: video, audioSink: audio,
            timeline: timeline, allowHardwareDecode: false)
        #expect(pipeline.selectableSubtitleTracks.isEmpty)
        #expect(!select(pipeline, 2))
        let url = try #require(Bundle.module.url(forResource: "h264_aac_forced_subs",
            withExtension: "mkv", subdirectory: "Fixtures"))
        try pipeline.load(probed: SourceProbe.open(url: url))
        defer { pipeline.stop() }
        pipeline.waitForFeedQueue()
        #expect(pipeline.selectableSubtitleTracks.map(\.streamIndex) == [2, 3])
        #expect(pipeline.selectableSubtitleTracks.allSatisfy { $0.language == "eng" })
        #expect(pipeline.selectableSubtitleTracks[1].isForced)
        #expect(pipeline.selectedSubtitleStreamIndex == nil)
        #expect(pipeline.activeSubtitleCues.isEmpty)

        for _ in 0..<6 { video.playOut(); audio.playOut() }
        timeline.setRate(0, time: CMTime(seconds: 2.5, preferredTimescale: 1_000))
        let changes = timeline.rateChanges.count
        #expect(select(pipeline, 2))
        #expect(pipeline.activeSubtitleCues.map(\.text) == ["The full dialogue track."])
        #expect(select(pipeline, 3))
        #expect(pipeline.selectedSubtitleStreamIndex == 3)
        #expect(pipeline.activeSubtitleCues.map(\.text) == ["[in Klingon] Greetings, traveller."])
        #expect(!select(pipeline, 0))
        #expect(!select(pipeline, Int.max))
        #expect(!select(pipeline, -1))
        #expect(pipeline.selectedSubtitleStreamIndex == 3)
        #expect(select(pipeline, nil))
        #expect(pipeline.activeSubtitleCues.isEmpty)
        #expect(select(pipeline, 2))
        #expect(!pipeline.activeSubtitleCues.isEmpty)
        #expect(timeline.rateChanges.count == changes)
        #expect(video.flushes.isEmpty)
        #expect(audio.flushCount == 0)
        #expect(pipeline.state == .paused)

        pipeline.play()
        pipeline.waitForFeedQueue()
        #expect(select(pipeline, 3))
        #expect(pipeline.state == .playing)
        #expect(pipeline.activeSubtitleCues.map(\.text) == ["[in Klingon] Greetings, traveller."])
        #expect(select(pipeline, 2))

        // No new packet is needed to clear the overlay at the cue's end.
        timeline.setRate(1, time: CMTime(seconds: 4, preferredTimescale: 1_000))
        #expect(pipeline.activeSubtitleCues.isEmpty)
        let beforeAnchor = DispatchSemaphore(value: 0)
        let resumeAnchor = DispatchSemaphore(value: 0)
        timeline.beforeSetRate = { _, time in
            guard CMTimeGetSeconds(time) < 4 else { return }
            timeline.beforeSetRate = nil
            // Hold the old playhead after the landing GOP has been decoded,
            // so host polling cannot accidentally miss the vulnerable window.
            beforeAnchor.signal()
            #expect(resumeAnchor.wait(timeout: .now() + 5) == .success)
        }
        pipeline.seek(to: CMTime(seconds: 1, preferredTimescale: 1_000))
        let reachedAnchor = beforeAnchor.wait(timeout: .now() + 5)
        #expect(reachedAnchor == .success)
        if reachedAnchor == .success {
            #expect(CMTimeGetSeconds(pipeline.currentTime) == 4)
            #expect(pipeline.activeSubtitleCues.isEmpty)
        }
        resumeAnchor.signal()
        pipeline.waitForFeedQueue()
        for _ in 0..<3 { video.playOut(); audio.playOut() }
        #expect(pipeline.selectedSubtitleStreamIndex == 2)
        timeline.setRate(0, time: CMTime(seconds: 2, preferredTimescale: 1_000))
        #expect(pipeline.activeSubtitleCues.map(\.text) == ["The full dialogue track."])
        pipeline.stop()
        #expect(pipeline.activeSubtitleCues.isEmpty)
        #expect(pipeline.selectedSubtitleStreamIndex == nil)
        #expect(!select(pipeline, 2))
    }

    @Test("Cue cache preserves source timestamps and overlapping cues, deduplicates rewinds and bounds memory")
    func subtitleCacheBoundsAndTimeline() {
        let store = SoftwareSubtitleCueStore(maximumCues: 3, maximumBytes: 12)
        let first = TimedTextCue(streamIndex: 2, start: 100, end: 103, text: "first")
        store.insert(first, currentTime: 100)
        store.insert(first, currentTime: 100)
        store.insert(TimedTextCue(streamIndex: 2, start: 101, end: 104, text: "two"), currentTime: 100)
        store.insert(TimedTextCue(streamIndex: 3, start: 100, end: 104, text: "last"), currentTime: 100)
        store.insert(TimedTextCue(streamIndex: 2, start: 100, end: 104, text: "overflow"), currentTime: 100)
        #expect(store.active(streamIndex: 2, at: 101).map(\.text) == ["first", "two"])
        #expect(store.active(streamIndex: 3, at: 101).map(\.text) == ["last"])
        #expect(store.active(streamIndex: 2, at: 103).map(\.text) == ["two"])
        store.insert(TimedTextCue(streamIndex: 2, start: 104, end: 105, text: "new"), currentTime: 104)
        #expect(store.active(streamIndex: 2, at: 104).map(\.text) == ["new"])
        store.reset()
        #expect(store.active(streamIndex: 2, at: 104).isEmpty)
    }
}
