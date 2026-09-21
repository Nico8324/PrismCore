import Testing
import Foundation
import Libavcodec
@testable import PrismCore

/// Tag normalization is the whole substance of the preference feature: a host
/// asks for "cs" and the container says "cze", and every one of the tests below
/// is a real spelling seen in the wild.
@Suite("Language tag matching")
struct LanguageTagMatchingTests {

    @Test("639-2/B, 639-2/T and 639-1 spellings of one language all match")
    func bibliographicAndTerminologicalCodesAreEqual() {
        for tag in ["cze", "ces", "cs", "CZE", "Ces", " cs "] {
            #expect(LanguageMatch.canonical(tag) == "cs", "\(tag)")
        }
        // Both directions: the preference may be spelled either way too.
        #expect(LanguageMatch.score(preferred: "cs", candidate: "cze") == 2)
        #expect(LanguageMatch.score(preferred: "cze", candidate: "ces") == 2)
        #expect(LanguageMatch.score(preferred: "ces", candidate: "cs") == 2)
        // The other bibliographic codes that bite, for the same reason.
        #expect(LanguageMatch.score(preferred: "de", candidate: "ger") == 2)
        #expect(LanguageMatch.score(preferred: "fr", candidate: "fre") == 2)
        #expect(LanguageMatch.score(preferred: "nl", candidate: "dut") == 2)
    }

    @Test("A region matches its bare language, and an exact region scores higher")
    func regionedTagsMatchTolerantly() {
        #expect(LanguageMatch.score(preferred: "pt", candidate: "pt-BR") == 1)
        #expect(LanguageMatch.score(preferred: "pt-BR", candidate: "pt") == 1)
        #expect(LanguageMatch.score(preferred: "pt-BR", candidate: "pt-BR") == 2)
        #expect(LanguageMatch.score(preferred: "pt-BR", candidate: "pt_br") == 2)
        // Two different regions of one language are still the same language.
        #expect(LanguageMatch.score(preferred: "pt-BR", candidate: "pt-PT") == 1)
        #expect(LanguageMatch.score(preferred: "pt", candidate: "es") == 0)
    }

    @Test("und and an empty tag name no language and never match")
    func unknownTagsNeverMatch() {
        #expect(LanguageMatch.canonical("und") == nil)
        #expect(LanguageMatch.canonical("") == nil)
        #expect(LanguageMatch.canonical("   ") == nil)
        #expect(LanguageMatch.canonical(nil) == nil)
        #expect(LanguageMatch.score(preferred: "cs", candidate: "und") == 0)
        #expect(LanguageMatch.score(preferred: "cs", candidate: nil) == 0)
        #expect(LanguageMatch.score(preferred: "und", candidate: "und") == 0)
        // An empty preference is the same as no preference at all.
        #expect(LanguageMatch.score(preferred: "", candidate: "cs") == 0)
        #expect(LanguageMatch.score(preferred: nil, candidate: "cs") == 0)
    }

    @Test("The best match is the highest-scoring one, ties going to source order")
    func bestIndexPrefersExactRegionThenSourceOrder() {
        let tracks = ["en", "pt", "pt-BR", "pt"]
        #expect(LanguageMatch.bestIndex(in: tracks, preferred: "pt-BR", language: { $0 }) == 2)
        #expect(LanguageMatch.bestIndex(in: tracks, preferred: "pt", language: { $0 }) == 1)
        #expect(LanguageMatch.bestIndex(in: tracks, preferred: "de", language: { $0 }) == nil)
        #expect(LanguageMatch.bestIndex(in: tracks, preferred: nil, language: { $0 }) == nil)
        // A bonus orders equals; it can never rescue a language that lost.
        #expect(LanguageMatch.bestIndex(
            in: tracks, preferred: "pt", language: { $0 }, bonus: { $0 == "pt-BR" ? 9 : 0 }
        ) == 1)
        #expect(LanguageMatch.bestIndex(
            in: tracks, preferred: "de", language: { $0 }, bonus: { _ in 9 }
        ) == nil)
    }
}

/// The audio half: the preference decides which rendition carries `DEFAULT`,
/// which is decided by `chooseAudio` and printed by `MasterPlaylistBuilder`.
@Suite("Preferred audio language")
struct PreferredAudioLanguageTests {

    private let bridgeEverything: (AVCodecID) -> Bool = { AudioBridge.bridgeableAudio.contains($0) }
    private let bridgeNothing: (AVCodecID) -> Bool = { _ in false }

    /// The shape this feature exists for: an English film with a Czech dub,
    /// English first in the container and flagged both original and default.
    private let dubbedFilm = [
        HLSRemuxer.AudioCandidate(
            index: 1, codecID: AV_CODEC_ID_EAC3, isOriginal: true, isDefault: true, language: "eng"
        ),
        HLSRemuxer.AudioCandidate(index: 2, codecID: AV_CODEC_ID_AC3, language: "cze"),
    ]

    @Test("A matching track beats the original-soundtrack and default flags")
    func preferenceOutranksEveryOtherSignal() {
        let route = HLSRemuxer.chooseAudio(
            candidates: dubbedFilm, best: 1, preferredLanguage: "cs", canBridge: bridgeEverything
        )
        #expect(route == HLSRemuxer.AudioRoute(index: 2, mode: .streamCopy))
    }

    @Test("No match changes nothing — the source's own default stands")
    func noMatchIsANoOp() {
        let withPreference = HLSRemuxer.chooseAudio(
            candidates: dubbedFilm, best: 1, preferredLanguage: "de", canBridge: bridgeEverything
        )
        let without = HLSRemuxer.chooseAudio(
            candidates: dubbedFilm, best: 1, canBridge: bridgeEverything
        )
        #expect(withPreference == without)
        #expect(withPreference == HLSRemuxer.AudioRoute(index: 1, mode: .streamCopy))
        // An untagged source can't match anything either, and must not throw
        // or come back empty because of it.
        let untagged = [
            HLSRemuxer.AudioCandidate(index: 1, codecID: AV_CODEC_ID_AAC, language: "und"),
            HLSRemuxer.AudioCandidate(index: 2, codecID: AV_CODEC_ID_AAC),
        ]
        #expect(HLSRemuxer.chooseAudio(
            candidates: untagged, best: 1, preferredLanguage: "cs", canBridge: bridgeEverything
        ) == HLSRemuxer.AudioRoute(index: 1, mode: .streamCopy))
    }

    @Test("A preferred track this build cannot carry is passed over, not played silent")
    func uncarriableMatchFallsThrough() {
        let candidates = [
            HLSRemuxer.AudioCandidate(index: 1, codecID: AV_CODEC_ID_AAC, language: "eng"),
            HLSRemuxer.AudioCandidate(index: 2, codecID: AV_CODEC_ID_TRUEHD, language: "cze"),
        ]
        // No encoder in this build: the Czech TrueHD track can be neither
        // copied nor bridged, so the preference finds nothing and the English
        // track plays — the alternative would be a rendition AVPlayer fails on.
        let route = HLSRemuxer.chooseAudio(
            candidates: candidates, best: 1, preferredLanguage: "cs", canBridge: bridgeNothing
        )
        #expect(route == HLSRemuxer.AudioRoute(index: 1, mode: .streamCopy))
        // With the encoder present the same preference is honoured.
        #expect(HLSRemuxer.chooseAudio(
            candidates: candidates, best: 1, preferredLanguage: "cs", canBridge: bridgeEverything
        ) == HLSRemuxer.AudioRoute(index: 2, mode: .bridge))
    }

    @Test("An exact region wins over a bare tag, inside the asked-for language")
    func regionPreferenceOrdersRenditions() {
        let candidates = [
            HLSRemuxer.AudioCandidate(index: 1, codecID: AV_CODEC_ID_AAC, language: "pt"),
            HLSRemuxer.AudioCandidate(index: 2, codecID: AV_CODEC_ID_AAC, language: "pt-BR"),
        ]
        #expect(HLSRemuxer.chooseAudio(
            candidates: candidates, best: 1, preferredLanguage: "pt-BR", canBridge: bridgeEverything
        ) == HLSRemuxer.AudioRoute(index: 2, mode: .streamCopy))
        #expect(HLSRemuxer.chooseAudio(
            candidates: candidates, best: 2, preferredLanguage: "pt", canBridge: bridgeEverything
        ) == HLSRemuxer.AudioRoute(index: 1, mode: .streamCopy))
    }

    @Test("Every track is still offered; only the order changes")
    func noTrackIsDropped() {
        let routes = HLSRemuxer.routeAll(
            candidates: dubbedFilm, best: 1, preferredLanguage: "cs", canBridge: bridgeEverything
        )
        #expect(routes.count == 2)
        #expect(routes.first?.index == 2)
        #expect(Set(routes.map(\.index)) == [1, 2])
    }

    @Test("DEFAULT lands on the preferred rendition in the generated master")
    func masterMarksThePreferredRenditionDefault() throws {
        // The remuxer declares renditions in route order and flags the first
        // (see `HLSRemuxer.prepare`), so the routing above is what the master
        // prints. This asserts the printed manifest, which is what AVPlayer
        // actually reads.
        let routes = HLSRemuxer.routeAll(
            candidates: dubbedFilm, best: 1, preferredLanguage: "cs", canBridge: bridgeEverything
        )
        let names = [Int32(1): ("English", "eng"), Int32(2): ("Czech", "cze")]
        let master = try MasterPlaylistBuilder.build(
            MasterPlaylistBuilder.VariantDescription(
                bandwidth: 8_000_000,
                videoCodec: .explicit("avc1.64001f"),
                audioRenditions: routes.enumerated().map { ordinal, route in
                    .init(
                        name: names[route.index]!.0,
                        language: names[route.index]!.1,
                        codecString: "ac-3",
                        uri: "audio\(ordinal)/index.m3u8",
                        isDefault: ordinal == 0
                    )
                }
            )
        )
        let audioLines = master.split(separator: "\n")
            .filter { $0.hasPrefix("#EXT-X-MEDIA:TYPE=AUDIO") }
        #expect(audioLines.count == 2)
        let czech = try #require(audioLines.first { $0.contains("LANGUAGE=\"cze\"") })
        let english = try #require(audioLines.first { $0.contains("LANGUAGE=\"eng\"") })
        #expect(czech.contains("DEFAULT=YES"))
        #expect(english.contains("DEFAULT=NO"))
        // AUTOSELECT stays YES on every audio rendition, default or not: it is
        // what keeps the alternates reachable from the system preference.
        #expect(audioLines.allSatisfy { $0.contains("AUTOSELECT=YES") })
    }
}

/// The subtitle half. `DEFAULT=YES` on a subtitle rendition is otherwise
/// forbidden (see `MasterPlaylistBuilder.SubtitleRendition`), so these tests
/// pin both that the preference lifts the ban for exactly one rendition and
/// that nothing else about the group moves.
@Suite("Preferred subtitle language")
struct PreferredSubtitleLanguageTests {

    private func renditions() -> [MasterPlaylistBuilder.SubtitleRendition] {
        [
            .init(name: "English", language: "eng", uri: "subs0/index.m3u8"),
            .init(name: "Signs", language: "eng", uri: "subs1/index.m3u8", isForced: true),
            .init(name: "Čeština", language: "cze", uri: "subs2/index.m3u8"),
        ]
    }

    @Test("The matching rendition is the one marked DEFAULT in the master")
    func preferredSubtitleBecomesDefault() throws {
        let master = try MasterPlaylistBuilder.build(
            MasterPlaylistBuilder.VariantDescription(
                bandwidth: 1_000_000,
                videoCodec: .explicit("avc1.64001f"),
                subtitles: SubtitleRenditionSet.applyingPreferredDefault(
                    renditions(), preferredLanguage: "cs"
                )
            )
        )
        let lines = master.split(separator: "\n")
            .filter { $0.hasPrefix("#EXT-X-MEDIA:TYPE=SUBTITLES") }
        #expect(lines.count == 3)
        let czech = try #require(lines.first { $0.contains("LANGUAGE=\"cze\"") })
        #expect(czech.contains("DEFAULT=YES"))
        #expect(czech.contains("AUTOSELECT=YES"))
        #expect(lines.filter { $0.contains("DEFAULT=YES") }.count == 1)
        #expect(lines.filter { $0.contains("AUTOSELECT=NO") }.count == 2)
    }

    @Test("Forced semantics survive untouched, and a full track wins the flag")
    func forcedRenditionsAreUnchanged() throws {
        let applied = SubtitleRenditionSet.applyingPreferredDefault(
            renditions(), preferredLanguage: "en"
        )
        // The FORCED flags are exactly what they were: the preference reads
        // them to break a tie and never writes them.
        #expect(applied.map(\.isForced) == renditions().map(\.isForced))
        // Between the full English track and the forced one, the full track
        // takes DEFAULT — a viewer who asked for English subtitles and got
        // foreign-dialogue-only would see almost nothing.
        #expect(applied[0].isDefault)
        #expect(!applied[1].isDefault)
        let master = try MasterPlaylistBuilder.build(
            MasterPlaylistBuilder.VariantDescription(
                bandwidth: 1_000_000,
                videoCodec: .explicit("avc1.64001f"),
                subtitles: applied
            )
        )
        let lines = master.split(separator: "\n")
            .filter { $0.hasPrefix("#EXT-X-MEDIA:TYPE=SUBTITLES") }
        let forced = try #require(lines.first { $0.contains("NAME=\"Signs\"") })
        #expect(forced.contains("FORCED=YES"))
        #expect(forced.contains("DEFAULT=NO"))
        #expect(lines.filter { $0.contains("FORCED=YES") }.count == 1)
    }

    @Test("A forced rendition can still be the default when it is the only match")
    func loneForcedMatchTakesTheFlag() {
        let applied = SubtitleRenditionSet.applyingPreferredDefault(
            [
                .init(name: "English", language: "eng", uri: "subs0/index.m3u8"),
                .init(name: "Signs", language: "cze", uri: "subs1/index.m3u8", isForced: true),
            ],
            preferredLanguage: "ces"
        )
        #expect(applied[1].isDefault)
        #expect(applied[1].isForced)
    }

    @Test("No match leaves every rendition exactly as it was")
    func noMatchIsANoOp() throws {
        for preference: String? in [nil, "", "de", "und"] {
            #expect(
                SubtitleRenditionSet.applyingPreferredDefault(
                    renditions(), preferredLanguage: preference
                ) == renditions(),
                "\(preference ?? "nil")"
            )
        }
        // And the served manifest is then the pre-existing one, byte for byte:
        // DEFAULT=NO, AUTOSELECT=NO, everything still declared.
        let master = try MasterPlaylistBuilder.build(
            MasterPlaylistBuilder.VariantDescription(
                bandwidth: 1_000_000,
                videoCodec: .explicit("avc1.64001f"),
                subtitles: SubtitleRenditionSet.applyingPreferredDefault(
                    renditions(), preferredLanguage: "de"
                )
            )
        )
        let lines = master.split(separator: "\n")
            .filter { $0.hasPrefix("#EXT-X-MEDIA:TYPE=SUBTITLES") }
        #expect(lines.count == 3)
        #expect(lines.allSatisfy { $0.contains("DEFAULT=NO") && $0.contains("AUTOSELECT=NO") })
    }
}
