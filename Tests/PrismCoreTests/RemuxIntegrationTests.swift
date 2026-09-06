import Testing
import Foundation
import AVFoundation
@testable import PrismCore

/// The session's readiness gate reads back what the remuxer wrote, so the
/// parse is pinned here rather than only exercised end to end.
@Suite("Master playlist references")
struct MasterPlaylistReferenceTests {

    @Test("Every rendition URI and the variant URI come back, in that order")
    func readsBothKinds() {
        let master = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",URI="audio0/index.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Czech",URI="audio1/index.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=1,CODECS="avc1.640028",AUDIO="aud"
        index.m3u8
        """
        #expect(PrismCoreSession.playlistURIs(inMaster: master)
            == ["audio0/index.m3u8", "audio1/index.m3u8", "index.m3u8"])
    }

    @Test("A URI-less rendition contributes nothing to fetch")
    func muxedRenditionHasNoURI() {
        let master = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",DEFAULT=YES,AUTOSELECT=YES
        #EXT-X-STREAM-INF:BANDWIDTH=1,CODECS="avc1.640028",AUDIO="aud"
        index.m3u8
        """
        #expect(PrismCoreSession.playlistURIs(inMaster: master) == ["index.m3u8"])
    }
}

/// End-to-end: fixture file → `PrismCoreSession` → loopback playlist →
/// (a) HTTP round-trip, (b) libavformat re-probe of the produced HLS,
/// (c) a real `AVPlayer` reaching `.readyToPlay` on the served stream.
///
/// The fixtures are synthetic (testsrc2 + sine) — they prove the pipeline,
/// not the premium claims. Atmos (EAC3+JOC) and Dolby Vision need real
/// media and a device; see README "Status".
@Suite("Remux end-to-end", .serialized)
struct RemuxIntegrationTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    private func fetch(_ url: URL) async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: url)
        return String(decoding: data, as: UTF8.self)
    }

    /// Poll a served MEDIA playlist until it carries `EXT-X-ENDLIST` (remux
    /// done). A master playlist never gains one — it is static — so a URL that
    /// turns out to be a master is followed to its video variant first.
    private func waitForFinishedPlaylist(_ playlistURL: URL, timeout: Duration = .seconds(30)) async throws -> String {
        var mediaURL = playlistURL
        let first = try await fetch(playlistURL)
        if first.contains("#EXT-X-STREAM-INF") {
            let variant = try #require(
                PrismCoreSession.playlistURIs(inMaster: first).last,
                "a master must reference a variant playlist"
            )
            mediaURL = playlistURL.deletingLastPathComponent().appendingPathComponent(variant)
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let text = try await fetch(mediaURL)
            if text.contains("#EXT-X-ENDLIST") { return text }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw PrismCoreSession.SessionError.startupTimedOut(underlying: nil)
    }

    /// Every `EXT-X-MEDIA:TYPE=AUDIO` line of a master playlist.
    private func audioMediaLines(_ master: String) -> [String] {
        master.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("#EXT-X-MEDIA:") && $0.contains("TYPE=AUDIO") }
    }

    @Test("H.264 + AAC MKV remuxes, serves, and re-probes as the same codecs")
    func h264AACRoundTrip() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        // A source with audio is served as a master: that is the only shape an
        // alternate audio rendition can live in.
        #expect(playlist.lastPathComponent == "master.m3u8")

        let text = try await waitForFinishedPlaylist(playlist)
        #expect(text.contains("#EXT-X-MAP"))
        #expect(text.contains(".m4s"))

        // Round-trip proof: our own probe re-opens the SERVED playlist (the
        // hls demuxer follows init + segments over the loopback).
        let info = try SourceProbe.probe(url: playlist)
        #expect(info.video?.codecName == "h264")
        #expect(info.audioTracks.map(\.codecName).contains("aac"))
    }

    @Test("Anamorphic SD: the container-level aspect ratio survives the remux")
    func anamorphicSARSurvives() async throws {
        // The fixture is the shape a DVD rip actually takes: bitstream SAR
        // 1:1 (the VUI says square), container DisplayWidth/Height saying
        // 16:9 — so 720×576 must present as 64:45 pixels. The container-level
        // value lives on the AVStream, not in codecpar, which is exactly what
        // a codecpar-only copy used to drop: the remux played these distorted.
        let source = try fixture("h264_anamorphic.mkv")
        let anamorphic = VideoTrackInfo.AspectRatio(numerator: 64, denominator: 45)
        #expect(try SourceProbe.probe(url: source).video?.sampleAspectRatio == anamorphic)

        let session = try PrismCoreSession(url: source)
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        let media = try await waitForFinishedPlaylist(playlist)
        // Assert on the `pasp` box bytes of the served init segment — the
        // thing AVPlayer actually reads. (Re-probing through libavformat's
        // hls demuxer can't see it: hls.c mirrors only codecpar off its inner
        // mov streams and drops the stream-level SAR — the same class of bug
        // this test pins on our side.)
        let mapURI = try #require(
            media.split(separator: "\n").first { $0.hasPrefix("#EXT-X-MAP") }
                .flatMap { $0.split(separator: "\"").dropFirst().first.map(String.init) },
            "the media playlist must reference an init segment"
        )
        var mediaURL = playlist
        if try await fetch(playlist).contains("#EXT-X-STREAM-INF") {
            let variant = try #require(PrismCoreSession.playlistURIs(inMaster: try await fetch(playlist)).last)
            mediaURL = playlist.deletingLastPathComponent().appendingPathComponent(variant)
        }
        let initURL = mediaURL.deletingLastPathComponent().appendingPathComponent(mapURI)
        let (initSegment, _) = try await URLSession.shared.data(from: initURL)
        #expect(paspRatios(in: initSegment) == [[64, 45]])
    }

    /// Every `pasp` box's `[hSpacing, vSpacing]` found in an ISOBMFF blob, in
    /// file order. Byte-scan rather than box-walk: the fourcc + two 32-bit
    /// integers is the entire box payload, and a false positive would need
    /// those exact 4 bytes followed by a plausible ratio inside codec data.
    private func paspRatios(in data: Data) -> [[UInt32]] {
        let bytes = [UInt8](data)
        let needle = Array("pasp".utf8)
        guard bytes.count >= 12 else { return [] }
        var out: [[UInt32]] = []
        for i in 0...(bytes.count - 12) where Array(bytes[i..<i+4]) == needle {
            let num = bytes[i+4..<i+8].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let den = bytes[i+8..<i+12].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            out.append([num, den])
        }
        return out
    }

    @Test("HEVC + EAC3 MKV keeps EAC3 by stream-copy — the Atmos carrier path")
    func hevcEAC3KeepsBitstream() async throws {
        let session = try PrismCoreSession(url: try fixture("hevc_eac3.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        _ = try await waitForFinishedPlaylist(playlist)
        let info = try SourceProbe.probe(url: playlist)
        let audioCodecs = info.audioTracks.map(\.codecName)
        // Stream-copy means the codec survives untouched. A real Atmos track
        // is EAC3+JOC — same codec id, JOC rides inside — so this is the
        // closest a synthetic fixture can get to the Atmos claim.
        #expect(audioCodecs.contains("eac3"))
    }

    @Test("DTS audio: video still plays; the audio is bridged to what the build can encode")
    func dtsAudio() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_dts.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        _ = try await waitForFinishedPlaylist(playlist)
        let info = try SourceProbe.probe(url: playlist)
        let audioCodecs = info.audioTracks.map(\.codecName)
        #expect(info.video?.codecName == "h264")
        // DTS must never reach the output — AVPlayer can't decode it from
        // fMP4 — and with an encoder present (every build has aac) the sound
        // survives as the bridge's codec rather than being dropped.
        #expect(!audioCodecs.contains("dts"))
        if AudioBridge.isEncoderAvailable {
            #expect(audioCodecs == [AudioBridge.defaultTargetCodecName], "audio was \(audioCodecs)")
        }
    }

    @Test("Two audio tracks become two alternate renditions in the served master")
    func multiAudioRenditions() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_multi_audio.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        #expect(playlist.lastPathComponent == "master.m3u8")
        let master = try await fetch(playlist)
        let renditions = audioMediaLines(master)
        #expect(renditions.count == 2, "master was:\n\(master)")

        // Languages travel from the container's stream metadata, and both
        // renditions are selectable (AUTOSELECT) while exactly one is DEFAULT.
        #expect(renditions.contains { $0.contains("LANGUAGE=\"eng\"") })
        #expect(renditions.contains { $0.contains("LANGUAGE=\"ces\"") })
        #expect(renditions.allSatisfy { $0.contains("AUTOSELECT=YES") })
        #expect(renditions.filter { $0.contains("DEFAULT=YES") }.count == 1)
        // Each rendition is its own presentation, not a track inside the video.
        #expect(renditions.allSatisfy { $0.contains("URI=\"audio") })
        // The English AAC track is the demuxer's best, so it leads and the
        // variant declares its codec.
        #expect(renditions.first?.contains("NAME=\"English\"") == true)
        #expect(renditions.first?.contains("DEFAULT=YES") == true)
        #expect(master.contains("mp4a.40.2"))
        #expect(master.contains("AUDIO=\"aud\""))

        _ = try await waitForFinishedPlaylist(playlist)

        // Round-trip proof: libavformat's hls demuxer reads the master's
        // renditions too, so both audio codecs come back out of the SERVED
        // stream — stream-copied, so byte-identical codecs.
        let info = try SourceProbe.probe(url: playlist)
        #expect(info.video?.codecName == "h264")
        let audioCodecs = Set(info.audioTracks.map(\.codecName))
        #expect(audioCodecs.contains("aac"), "probed: \(audioCodecs)")
        #expect(audioCodecs.contains("ac3"), "probed: \(audioCodecs)")
        // Each rendition's own fMP4 carries its language too, so the served
        // media is self-describing and not only the manifest.
        let languages = Set(info.audioTracks.compactMap(\.language))
        #expect(languages == ["eng", "ces"], "probed: \(languages)")
    }

    @Test("Renditions are segmented on the video's boundaries, not their own")
    func renditionSegmentationIsAligned() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_multi_audio.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        let variantText = try await waitForFinishedPlaylist(playlist)
        let master = try await fetch(playlist)
        let base = playlist.deletingLastPathComponent()

        let videoDurations = extinfDurations(variantText)
        #expect(videoDurations.count > 1, "the fixture should cut more than once")

        for uri in PrismCoreSession.playlistURIs(inMaster: master).filter({ $0.hasPrefix("audio") }) {
            let text = try await fetch(base.appendingPathComponent(uri))
            let durations = extinfDurations(text)
            // Same cut count and the same durations: the renditions are cut at
            // the video's boundaries, so AVPlayer can line any of them up
            // against the picture without resyncing.
            #expect(durations == videoDurations, "\(uri) diverged: \(durations) vs \(videoDurations)")
            #expect(text.contains("#EXT-X-MAP:URI=\"init.mp4\""))
            #expect(text.contains("#EXT-X-ENDLIST"))
        }
    }

    private func extinfDurations(_ playlist: String) -> [String] {
        playlist.split(separator: "\n")
            .filter { $0.hasPrefix("#EXTINF:") }
            .map { String($0.dropFirst("#EXTINF:".count).dropLast()) }
    }

    @Test("AVPlayer reaches readyToPlay on a master with two audio renditions")
    func multiAudioPlayerReadiness() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_multi_audio.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        let item = AVPlayerItem(url: playlist)
        #expect(await isReadyToPlay(item))
    }

    @Test("VP9 refuses fast with the routing error — the 'send it to Prism' signal")
    func vp9Refuses() async throws {
        let session = try PrismCoreSession(url: try fixture("vp9.webm"))
        do {
            _ = try await session.start()
            Issue.record("VP9 must not produce a native playlist")
        } catch let error as PrismCoreSession.SessionError {
            if case .startupTimedOut(let underlying) = error {
                #expect(underlying is HLSRemuxer.Failure)
            }
        }
        await session.stop()
    }

    @Test("AVPlayer reaches readyToPlay on the served stream")
    func avPlayerReadiness() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        let item = AVPlayerItem(url: playlist)
        #expect(await isReadyToPlay(item))
    }

    /// Bounded wait on `AVPlayerItem.status`. Records the failure itself so both
    /// call sites report the item's own error.
    private func isReadyToPlay(_ item: AVPlayerItem, timeout: TimeInterval = 15) async -> Bool {
        let player = AVPlayer(playerItem: item)
        player.isMuted = true

        let ready: Bool = await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            let observation = item.observe(\.status, options: [.initial, .new]) { item, _ in
                switch item.status {
                case .readyToPlay: once.run { continuation.resume(returning: true) }
                case .failed: once.run { continuation.resume(returning: false) }
                default: break
                }
            }
            // Bound the wait; keep the observation alive inside the closure.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                _ = observation   // retained until here
                once.run { continuation.resume(returning: false) }
            }
        }
        if !ready {
            Issue.record("AVPlayerItem never reached .readyToPlay (error: \(String(describing: item.error)))")
        }
        _ = player   // keep alive through the wait
        return ready
    }
}
