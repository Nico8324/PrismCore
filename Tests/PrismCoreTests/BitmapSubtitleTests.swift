import Testing
import Foundation
import CoreGraphics
import CoreText
@testable import PrismCore

/// The OCR-rendition half of bitmap subtitles: composition → recognized text,
/// and the pending-cue lifecycle that turns display/clear *events* into cues
/// with known ends. Packet-level PGS decoding is exercised by the opt-in
/// real-media harness — no FFmpeg build can encode PGS, so no fixture can
/// carry it.
@Suite("Bitmap subtitle renditions")
struct BitmapSubtitleTests {

    // MARK: - Helpers

    /// White text on black, the shape a decoded subtitle composition has.
    private func renderedComposition(_ text: String, pointSize: CGFloat = 48) throws -> CGImage {
        let width = 900
        let height = 140
        let context = try #require(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica" as CFString, pointSize, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ]
        let attributed = CFAttributedStringCreate(
            kCFAllocatorDefault, text as CFString, attributes as CFDictionary
        )!
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 24, y: 48)
        CTLineDraw(line, context)
        return try #require(context.makeImage())
    }

    private func tinyImage() throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 2, height: 2,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try #require(context.makeImage())
    }

    private func show(_ seconds: Double, _ image: CGImage, end: Double? = nil) -> BitmapSubtitleDecoder.Event {
        .init(startSeconds: seconds, endSeconds: end, image: image)
    }

    private func clear(_ seconds: Double) -> BitmapSubtitleDecoder.Event {
        .init(startSeconds: seconds, endSeconds: nil, image: nil)
    }

    // MARK: - OCR

    /// FFmpeg's PGS decoder ends every composition at `UINT32_MAX` ms — "until the clear", not
    /// a time. Believed, that made each caption a 49-day cue repeated into every later segment.
    @Test("The PGS until-the-clear sentinel is not an end time")
    func pgsSentinelIsNotAnEnd() {
        #expect(BitmapSubtitleDecoder.explicitEndMilliseconds(start: 0, end: UInt32.max) == nil)
        #expect(BitmapSubtitleDecoder.explicitEndMilliseconds(start: 0, end: 0) == nil)
        #expect(BitmapSubtitleDecoder.explicitEndMilliseconds(start: 0, end: 2500) == 2500)
    }

    @Test("Vision reads a clean subtitle composition back")
    func ocrReadsRenderedText() throws {
        let image = try renderedComposition("Hello there, subtitle")
        let recognized = try #require(SubtitleOCR.recognize(image, language: "en"))
        #expect(recognized.lowercased().contains("hello there"))
        #expect(recognized.lowercased().contains("subtitle"))
    }

    @Test("An empty composition produces no cue text")
    func ocrRefusesEmptyImage() throws {
        let image = try renderedComposition(" ")
        #expect(SubtitleOCR.recognize(image, language: nil) == nil)
    }

    // MARK: - Pending-cue lifecycle

    @Test("A PGS-style show/clear pair becomes one cue with the clear as its end")
    func showClearMakesOneCue() throws {
        let track = SubtitleRenditionSet.BitmapRenditionTrack(
            decoder: nil, language: nil, recognize: { _, _ in "AHOJ" }
        )
        let image = try tinyImage()
        #expect(track.process([show(10.0, image)]).isEmpty, "no end known yet — nothing to write")
        let cues = track.process([clear(12.5)])
        #expect(cues == [SubtitleCue(start: 10.0, end: 12.5, text: "AHOJ")])
    }

    @Test("A new composition displaces the standing one")
    func nextCompositionClosesPrevious() throws {
        let track = SubtitleRenditionSet.BitmapRenditionTrack(
            decoder: nil, language: nil, recognize: { _, _ in "LINE" }
        )
        let image = try tinyImage()
        _ = track.process([show(1.0, image)])
        let cues = track.process([show(3.0, image)])
        #expect(cues == [SubtitleCue(start: 1.0, end: 3.0, text: "LINE")])
    }

    @Test("An explicit end (DVD-style) writes immediately, nothing stays pending")
    func explicitEndWritesImmediately() throws {
        let track = SubtitleRenditionSet.BitmapRenditionTrack(
            decoder: nil, language: nil, recognize: { _, _ in "DVD" }
        )
        let cues = track.process([show(5.0, try tinyImage(), end: 7.25)])
        #expect(cues == [SubtitleCue(start: 5.0, end: 7.25, text: "DVD")])
        #expect(track.splitPending(at: 100) == nil)
    }

    @Test("A clear that never comes is capped, not eternal")
    func missingClearIsCapped() throws {
        let track = SubtitleRenditionSet.BitmapRenditionTrack(
            decoder: nil, language: nil, recognize: { _, _ in "STUCK" }
        )
        let image = try tinyImage()
        _ = track.process([show(0.0, image)])
        let cues = track.process([clear(60.0)])
        let cap = SubtitleRenditionSet.BitmapRenditionTrack.maximumCueSeconds
        #expect(cues == [SubtitleCue(start: 0.0, end: cap, text: "STUCK")])
    }

    @Test("A segment boundary splits the open cue: head written, tail re-opens")
    func segmentBoundarySplitsPending() throws {
        let track = SubtitleRenditionSet.BitmapRenditionTrack(
            decoder: nil, language: nil, recognize: { _, _ in "SPAN" }
        )
        _ = track.process([show(4.0, try tinyImage())])
        let head = try #require(track.splitPending(at: 6.0))
        #expect(head == SubtitleCue(start: 4.0, end: 6.0, text: "SPAN"))
        // The tail re-opened at the boundary; the clear closes it there.
        let tail = track.process([clear(8.0)])
        #expect(tail == [SubtitleCue(start: 6.0, end: 8.0, text: "SPAN")])
    }

    @Test("A reanchor drops the open cue — pre-seek state must not leak")
    func reanchorDropsPending() throws {
        let track = SubtitleRenditionSet.BitmapRenditionTrack(
            decoder: nil, language: nil, recognize: { _, _ in "GONE" }
        )
        _ = track.process([show(2.0, try tinyImage())])
        track.reanchor()
        #expect(track.process([clear(4.0)]).isEmpty)
        #expect(track.splitPending(at: 100) == nil)
    }

    @Test("A composition the recognizer can't read produces no cue at all")
    func unreadableCompositionIsSilent() throws {
        let track = SubtitleRenditionSet.BitmapRenditionTrack(
            decoder: nil, language: nil, recognize: { _, _ in nil }
        )
        _ = track.process([show(1.0, try tinyImage())])
        #expect(track.process([clear(3.0)]).isEmpty)
    }
}

#if canImport(Vision)
import Vision

@Suite("OCR language mapping")
struct SubtitleOCRLanguageTests {

    @Test("Container 639-2 tags resolve to a supported Vision identifier")
    func iso6392Resolves() {
        let request = VNRecognizeTextRequest()
        // "cze" is what a Czech Matroska track actually carries; a raw
        // pass-through matched nothing and silently lost the language hint.
        if let czech = SubtitleOCR.visionLanguage(for: "cze", in: request) {
            #expect(czech.lowercased().hasPrefix("cs"))
        }
        let english = SubtitleOCR.visionLanguage(for: "eng", in: request)
        #expect(english?.lowercased().hasPrefix("en") == true)
    }

    @Test("An unknown tag skips the hint instead of poisoning the request")
    func unknownTagIsDropped() {
        let request = VNRecognizeTextRequest()
        #expect(SubtitleOCR.visionLanguage(for: "xxx", in: request) == nil)
        #expect(SubtitleOCR.visionLanguage(for: nil, in: request) == nil)
        #expect(SubtitleOCR.visionLanguage(for: "", in: request) == nil)
    }
}

/// Lazy OCR arming: a bitmap rendition does no work — decode included — until
/// a `.vtt` fetch of its own directory arms it, and segments cut while
/// unarmed are bookkept stale so that fetch re-produces them instead of
/// serving the header-only empty AVPlayer would cache forever. The full
/// fetch→arm→re-produce loop runs in the opt-in real-media harness; these pin
/// the pure pieces.
@Suite("Lazy OCR arming")
struct LazyOCRArmingTests {

    @Test("A track starts unarmed and arming is one-way")
    func armingIsOneWay() {
        let track = SubtitleRenditionSet.BitmapRenditionTrack(
            decoder: nil, language: nil, recognize: { _, _ in nil }
        )
        #expect(!track.isArmed)
        track.arm()
        #expect(track.isArmed)
        track.arm()
        #expect(track.isArmed, "re-arming is idempotent, never a toggle")
    }

    @Test("Stale bookkeeping: recorded while unarmed, cleared by the armed re-cut")
    func staleLifecycle() {
        let track = SubtitleRenditionSet.BitmapRenditionTrack(
            decoder: nil, language: nil, recognize: { _, _ in nil }
        )
        track.recordStale(3)
        track.recordStale(4)
        #expect(track.isStale(3))
        #expect(!track.isStale(5))
        track.clearStale(3)
        #expect(!track.isStale(3))
        #expect(track.isStale(4), "clearing one index must not clear its neighbours")
    }

    @Test("Request paths parse to (ordinal, index) only for rendition segments")
    func renditionSegmentParsing() {
        typealias Renditions = SubtitleRenditionSet
        #expect(Renditions.renditionSegment(inPath: "subs0/seg00012.vtt")! == (0, 12))
        #expect(Renditions.renditionSegment(inPath: "/subs17/seg00000.vtt")! == (17, 0))
        // Everything that is not a rendition segment: playlists, media
        // segments, other directories, malformed ordinals.
        #expect(Renditions.renditionSegment(inPath: "subs0/index.m3u8") == nil)
        #expect(Renditions.renditionSegment(inPath: "seg00012.m4s") == nil)
        #expect(Renditions.renditionSegment(inPath: "audio0/seg00012.vtt") == nil)
        #expect(Renditions.renditionSegment(inPath: "subsX/seg00012.vtt") == nil)
        #expect(Renditions.renditionSegment(inPath: "seg00012.vtt") == nil)
    }

    @Test("The provider's vtt index parser mirrors the media one, per extension")
    func vttIndexParsing() {
        #expect(PlanSegmentProvider.vttSegmentIndex(inPath: "subs2/seg00034.vtt") == 34)
        #expect(PlanSegmentProvider.vttSegmentIndex(inPath: "subs2/seg00034.m4s") == nil)
        #expect(PlanSegmentProvider.segmentIndex(inPath: "subs2/seg00034.vtt") == nil)
    }
}
#endif
