import Testing
import Libavutil
import Libavcodec
import Libavformat
import Foundation
import AVFoundation
@testable import PrismCore

/// Phase 6 end to end: a subtitled MKV becomes WebVTT renditions served over
/// the loopback and declared in a master playlist, and an external `.srt`
/// registered before `start()` becomes one too.
///
/// The fixture (`h264_aac_srt.mkv`) is synthetic — testsrc2 + sine + a
/// three-cue Czech SRT, one cue deliberately straddling the 6 s segment
/// boundary so the repeat-with-clamped-times rule is exercised by real
/// segmentation and not only by the unit test.
@Suite("Subtitle renditions", .serialized)
struct SubtitleRenditionTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    /// Since the multi-audio merge, `start()` returns a MASTER for sources
    /// with audio renditions — and masters never gain `EXT-X-ENDLIST`. Follow
    /// the master to its variant and poll THAT for the finish, same as the
    /// remux integration suite.
    private func waitForFinishedPlaylist(_ playlistURL: URL, timeout: Duration = .seconds(30)) async throws {
        var mediaURL = playlistURL
        let (firstData, _) = try await URLSession.shared.data(from: playlistURL)
        let first = String(decoding: firstData, as: UTF8.self)
        if first.contains("#EXT-X-STREAM-INF") {
            let variant = try #require(
                PrismCoreSession.playlistURIs(inMaster: first).last,
                "a master must reference a variant playlist"
            )
            mediaURL = playlistURL.deletingLastPathComponent().appendingPathComponent(variant)
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let (data, _) = try await URLSession.shared.data(from: mediaURL)
            if String(decoding: data, as: UTF8.self).contains("#EXT-X-ENDLIST") { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw PrismCoreSession.SessionError.startupTimedOut(underlying: nil)
    }

    /// Fetch over the loopback, returning body and `Content-Type`.
    private func fetch(_ url: URL) async throws -> (text: String, contentType: String?) {
        let (data, response) = try await URLSession.shared.data(from: url)
        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
        return (String(decoding: data, as: UTF8.self), contentType)
    }

    // MARK: - Embedded text track

    @Test("Embedded SubRip track becomes a served WebVTT rendition the master declares")
    func embeddedSubRipRendition() async throws {
        let source = try fixture("h264_aac_srt.mkv")

        // The probe reports it before any remux decision is made.
        let info = try SourceProbe.probe(url: source)
        let subtitle = try #require(info.subtitleTracks.first)
        #expect(subtitle.codecName == "subrip")
        #expect(subtitle.kind == .textRendition)
        #expect(subtitle.language == "ces")
        #expect(info.bitmapSubtitleTracks.isEmpty)

        let session = try PrismCoreSession(url: source)
        let playlist = try await session.start()
        defer { Task { await session.stop() } }
        try await waitForFinishedPlaylist(playlist)

        let renditions = await session.subtitleRenditions
        let rendition = try #require(renditions.first)
        #expect(renditions.count == 1)
        #expect(rendition.uri == "subs0/index.m3u8")
        #expect(rendition.language == "ces")
        // The language in its own name, as Apple's playlists do; the container's title ("Czech")
        // is dropped because it only repeats the language — see `renditionName`.
        #expect(rendition.name == "Čeština")

        // The SERVED master — the one AVPlayer actually reads — carries the
        // rendition and points the variant at its group. Asserted against the
        // loopback, not a hand-built VariantDescription: the renditions were
        // once produced but never declared, and a manual build can't regress.
        let (master, _) = try await fetch(playlist)
        #expect(master.contains("#EXT-X-MEDIA:TYPE=SUBTITLES"))
        #expect(master.contains("LANGUAGE=\"ces\""))
        #expect(master.contains("URI=\"subs0/index.m3u8\""))
        #expect(master.contains("SUBTITLES=\"subs\""))

        // The rendition playlist and its segments come off the same loopback.
        let base = playlist.deletingLastPathComponent()
        let (subPlaylist, playlistType) = try await fetch(base.appendingPathComponent("subs0/index.m3u8"))
        #expect(playlistType?.contains("mpegurl") == true)
        #expect(subPlaylist.contains("seg00000.vtt"))
        #expect(subPlaylist.contains("#EXT-X-ENDLIST"))
        #expect(!subPlaylist.contains("#EXT-X-MAP"))

        let (first, vttType) = try await fetch(base.appendingPathComponent("subs0/seg00000.vtt"))
        #expect(vttType == "text/vtt")
        #expect(first.hasPrefix("WEBVTT\n"))
        // The fixture's first video PTS is 0, so the media axis and the cue
        // axis coincide and the map is the neutral one.
        #expect(first.contains("X-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000"))
        // The first cut is the short head (2 s), so the 1–3 s cue straddles
        // it: clamped into this segment…
        #expect(first.contains("00:00:01.000 --> 00:00:02.000"))
        #expect(first.contains("Ahoj <i>světe</i>"))

        // …and repeated in the next one, which runs 2–8 s and so carries
        // the rest of the fixture's cues whole.
        let (second, _) = try await fetch(base.appendingPathComponent("subs0/seg00001.vtt"))
        #expect(second.contains("00:00:02.000 --> 00:00:03.000"))
        #expect(second.contains("00:00:05.500 --> 00:00:06.500"))
        #expect(second.contains("Přes hranici segmentu"))
        #expect(second.contains("Konec"))

        // One rendition segment per media segment — counted off the VARIANT
        // playlist (`playlist` is the master since the multi-audio merge, and
        // a master lists no segments).
        let (media, _) = try await fetch(base.appendingPathComponent("index.m3u8"))
        let mediaSegments = media.split(separator: "\n").filter { $0.hasSuffix(".m4s") }.count
        let subSegments = subPlaylist.split(separator: "\n").filter { $0.hasSuffix(".vtt") }.count
        #expect(mediaSegments == subSegments)
    }

    // MARK: - External file

    @Test("An external .srt registered before start() becomes its own rendition")
    func externalSubtitleFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreExternalSubs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sidecar = directory.appendingPathComponent("german.srt")
        try Data("""
        1
        00:00:00,500 --> 00:00:02,000
        Guten Tag

        2
        00:00:07,000 --> 00:00:07,500
        Ende

        """.utf8).write(to: sidecar)

        // A source with NO embedded subtitle stream, so the only rendition can
        // be the external one.
        let session = try PrismCoreSession(url: try fixture("h264_aac.mkv"))
        try await session.addExternalSubtitle(url: sidecar, language: "de", name: "Deutsch")
        let playlist = try await session.start()
        defer { Task { await session.stop() } }
        try await waitForFinishedPlaylist(playlist)

        let renditions = await session.subtitleRenditions
        #expect(renditions.count == 1)
        #expect(renditions.first?.name == "Deutsch")
        #expect(renditions.first?.language == "de")
        #expect(renditions.first?.uri == "subs0/index.m3u8")

        // Externals get declared in the served master exactly like embedded
        // tracks — same production path, same publication path.
        let (master, _) = try await fetch(playlist)
        #expect(master.contains("NAME=\"Deutsch\""))
        #expect(master.contains("URI=\"subs0/index.m3u8\""))

        let base = playlist.deletingLastPathComponent()
        let (first, _) = try await fetch(base.appendingPathComponent("subs0/seg00000.vtt"))
        #expect(first.hasPrefix("WEBVTT\n"))
        #expect(first.contains("00:00:00.500 --> 00:00:02.000"))
        #expect(first.contains("Guten Tag"))

        // The sidecar is segmented on the video's boundaries like any embedded
        // track, so its later cue lands in a later segment.
        let (second, _) = try await fetch(base.appendingPathComponent("subs0/seg00001.vtt"))
        #expect(second.contains("Ende"))
    }

    @Test("Registering an external subtitle after start() is refused, not ignored")
    func registrationAfterStartRefused() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac.mkv"))
        _ = try await session.start()
        defer { Task { await session.stop() } }

        await #expect(throws: PrismCoreSession.SessionError.self) {
            try await session.addExternalSubtitle(url: URL(fileURLWithPath: "/tmp/none.srt"))
        }
    }

    // MARK: - Host cue tap

    /// Collects `TimedTextCue`s across the remux thread and the test task.
    private final class CueCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [TimedTextCue] = []
        func append(_ cue: TimedTextCue) { lock.withLock { stored.append(cue) } }
        var cues: [TimedTextCue] { lock.withLock { stored } }
    }

    @Test("A registered handler receives every embedded cue, on the played timeline")
    func cueTapDeliversEmbeddedCues() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac_srt.mkv"))
        let collector = CueCollector()
        await session.setTimedTextCueHandler { collector.append($0) }
        let playlist = try await session.start()
        defer { Task { await session.stop() } }
        try await waitForFinishedPlaylist(playlist)

        // The fixture's SRT: three cues, one straddling the 6 s segment cut.
        // The tap must deliver each source cue exactly once — unsplit, unlike
        // the segmented rendition — and dedup any re-demuxed region.
        let cues = collector.cues
        #expect(cues.count == 3)
        let first = try #require(cues.first)
        // First video PTS is 0, so the played timeline and the source timeline
        // coincide here.
        #expect(first.start == 1.0)
        #expect(first.end == 3.0)
        #expect(first.text.contains("Ahoj"))
        #expect(cues.allSatisfy { $0.streamIndex == cues[0].streamIndex })
        let straddling = try #require(cues.dropFirst().first)
        #expect(straddling.start < 6.0 && straddling.end > 6.0)
    }

    @Test("A handler registered after production is replayed everything so far")
    func cueTapReplaysOnLateRegistration() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac_srt.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }
        try await waitForFinishedPlaylist(playlist)

        // Nothing was registered while the remux ran; the late handler must
        // still see the complete cue list, in production order.
        let collector = CueCollector()
        await session.setTimedTextCueHandler { collector.append($0) }
        let cues = collector.cues
        #expect(cues.count == 3)
        #expect(cues.map(\.start) == cues.map(\.start).sorted())
        #expect(cues.last?.text.contains("Konec") == true)
    }

    // MARK: - Master playlist rules

    @Test("Renditions are never DEFAULT or AUTOSELECT — the host selects them")
    func renditionsAreNeverSelfEngaging() throws {
        let master = try MasterPlaylistBuilder.build(
            MasterPlaylistBuilder.VariantDescription(
                bandwidth: 1_000_000,
                videoCodec: .explicit("avc1.64001f"),
                subtitles: [
                    .init(name: "English", language: "en", uri: "subs0/index.m3u8"),
                    .init(name: "Signs", language: "en", uri: "subs1/index.m3u8", isForced: true),
                ]
            )
        )
        let mediaLines = master.split(separator: "\n").filter { $0.hasPrefix("#EXT-X-MEDIA:TYPE=SUBTITLES") }
        #expect(mediaLines.count == 2)
        for line in mediaLines {
            #expect(line.contains("DEFAULT=NO"))
            #expect(line.contains("AUTOSELECT=NO"))
            #expect(line.contains("GROUP-ID=\"subs\""))
        }
        #expect(mediaLines.last?.contains("FORCED=YES") == true)
        #expect(mediaLines.first?.contains("FORCED") == false)
        // A `.vtt` rendition contributes nothing to CODECS (`wvtt` is for
        // fMP4-packaged timed text, and claiming it filters the variant).
        let streamInf = try #require(master.split(separator: "\n").first { $0.hasPrefix("#EXT-X-STREAM-INF:") })
        #expect(!streamInf.contains("wvtt"))
        #expect(streamInf.contains("SUBTITLES=\"subs\""))
    }

    @Test("No subtitles means no SUBTITLES attribute at all")
    func noSubtitlesNoAttribute() throws {
        let master = try MasterPlaylistBuilder.build(
            MasterPlaylistBuilder.VariantDescription(
                bandwidth: 1_000_000,
                videoCodec: .explicit("avc1.64001f")
            )
        )
        #expect(!master.contains("SUBTITLES"))
    }
}

/// Two subtitle tracks that share a name are two renditions AVFoundation
/// refuses to keep both of.
///
/// The shape is the ordinary one, not a corner case: a disc rip carries an
/// `eng` full track and an `eng` forced track, neither of them titled, so both
/// renditions fall back to the language tag for their `NAME`. HLS forbids that
/// (RFC 8216 §4.3.4.1) and AVFoundation enforces it by keeping the first and
/// dropping the rest — silently, which is why the served playlist looked
/// correct while the forced track was missing from the picker.
///
/// The AVFoundation assertion is the point of this suite. A string test over
/// the master would have passed before the fix: both `EXT-X-MEDIA` lines were
/// present, `FORCED=YES` and all. Only asking AVFoundation what it actually
/// parsed shows the loss.
@Suite("Forced subtitle renditions", .serialized)
struct ForcedSubtitleRenditionTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    @Test("Colliding names are disambiguated by ordinal, in stream order")
    func namesAreMadeUnique() {
        let renditions = [
            MasterPlaylistBuilder.SubtitleRendition(name: "eng", uri: "subs0/index.m3u8"),
            MasterPlaylistBuilder.SubtitleRendition(name: "eng", uri: "subs1/index.m3u8", isForced: true),
            MasterPlaylistBuilder.SubtitleRendition(name: "ENG", uri: "subs2/index.m3u8"),
            MasterPlaylistBuilder.SubtitleRendition(name: "Čeština", uri: "subs3/index.m3u8"),
        ]
        let unique = SubtitleRenditionSet.withUniqueNames(renditions)
        #expect(unique.map(\.name) == ["eng", "eng 2", "ENG 3", "Čeština"])
        // Everything else about a rendition survives the rename.
        #expect(unique[1].isForced)
        #expect(unique.map(\.uri) == renditions.map(\.uri))
    }

    @Test("A source with a full and a forced track declares two distinct renditions")
    func forcedTrackGetsItsOwnName() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac_forced_subs.mkv"))
        let playlistURL = try await session.start()
        defer { Task { await session.stop() } }

        let renditions = await session.subtitleRenditions
        try #require(renditions.count == 2)
        #expect(Set(renditions.map(\.name)).count == 2, "two renditions, two names")
        #expect(renditions.filter(\.isForced).count == 1)

        let (data, _) = try await URLSession.shared.data(from: playlistURL)
        let master = String(decoding: data, as: UTF8.self)
        #expect(master.contains("FORCED=YES"))
        for rendition in renditions {
            #expect(master.contains("NAME=\"\(rendition.name)\""))
        }
    }

    /// The release's only text track, flagged default+forced the way YTS muxes every SRT. Passed
    /// through as FORCED=YES it vanishes from AVKit's menu (seen on a Vision Pro, 2026-09-06).
    @Test("A lone default+forced track is offered as a normal rendition")
    func loneForcedTrackStaysReachable() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac_lone_forced_srt.mkv"))
        let playlistURL = try await session.start()
        defer { Task { await session.stop() } }

        let renditions = await session.subtitleRenditions
        try #require(renditions.count == 1)
        #expect(!renditions[0].isForced)

        let (data, _) = try await URLSession.shared.data(from: playlistURL)
        #expect(!String(decoding: data, as: UTF8.self).contains("FORCED=YES"))
    }

    @Test("Forced is honoured only beside a same-language full track")
    func forcedNeedsASibling() {
        let forced = AV_DISPOSITION_FORCED | AV_DISPOSITION_DEFAULT
        #expect(SubtitleRenditionSet.isForcedRendition(disposition: forced, sameLanguageTracks: 2))
        #expect(!SubtitleRenditionSet.isForcedRendition(disposition: forced, sameLanguageTracks: 1))
        #expect(!SubtitleRenditionSet.isForcedRendition(disposition: AV_DISPOSITION_DEFAULT, sameLanguageTracks: 2))
    }

    @Test("A rendition is named by its language, and a muxer title is noise unless it says the kind")
    func renditionNames() {
        #expect(SubtitleRenditionSet.renditionName(language: "eng", title: "English-SRT", ordinal: 0) == "English")
        #expect(SubtitleRenditionSet.renditionName(language: "fra", title: nil, ordinal: 0) == "Français")
        #expect(SubtitleRenditionSet.renditionName(language: "eng", title: "Signs & Songs", ordinal: 0) == "English (Signs & Songs)")
        #expect(SubtitleRenditionSet.renditionName(language: nil, title: "Commentary", ordinal: 3) == "Commentary")
        #expect(SubtitleRenditionSet.renditionName(language: nil, title: nil, ordinal: 3) == "Subtitles 4")
    }

    @Test("AVFoundation keeps both options, and knows which one is forced")
    func avFoundationSeesBothOptions() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac_forced_subs.mkv"))
        let playlistURL = try await session.start()
        defer { Task { await session.stop() } }

        let asset = AVURLAsset(url: playlistURL)
        let group = try #require(
            try await asset.loadMediaSelectionGroup(for: .legible),
            "no legible group — the master declared no SUBTITLES"
        )
        #expect(group.options.count == 2, "AVFoundation dropped a rendition: \(group.options.map(\.displayName))")

        let forced = group.options.filter { $0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
        #expect(forced.count == 1, "exactly one option should carry FORCED=YES")
        // The host's menu is built by filtering the forced option out, which
        // only works if it is distinguishable — the whole point of the fix.
        let selectable = AVMediaSelectionGroup.mediaSelectionOptions(
            from: group.options, withoutMediaCharacteristics: [.containsOnlyForcedSubtitles]
        )
        #expect(selectable.count == 1)
    }
}
