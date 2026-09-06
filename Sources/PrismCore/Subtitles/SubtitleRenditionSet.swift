import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// Every WebVTT subtitle rendition of one remux session: the embedded text
/// subtitle streams the demuxer already sees (and until phase 6 dropped) plus
/// any external files the host registered, each segmented onto the video's own
/// segment boundaries by a `WebVTTRenditionWriter`.
///
/// Owned by `HLSRemuxer` (it has the demuxer and the cut points) but reachable
/// from `PrismCoreSession`, which registers externals before `start()` and
/// reads `renditions` afterwards to sign the master playlist. The two touch it
/// from different threads, hence the lock — kept to the rendition list and the
/// registration list, the only state that crosses.
///
/// Bitmap subtitles (PGS / DVB / DVD) become renditions too, through on-device
/// OCR (`BitmapSubtitleDecoder` + `SubtitleOCR`) — lossy by design, but the
/// only form that rides PiP, AirPlay and the system menu. They stay reported
/// by `SourceProbe` as host-only so a host that wants pixel-accurate rendering
/// can still draw them itself; on a platform without Vision they are host-only
/// in practice as well.
final class SubtitleRenditionSet: @unchecked Sendable {

    /// Text subtitle codecs whose packets convert to WebVTT cues.
    /// `SourceProbe` classifies against the same set so the probe's verdict and
    /// the remuxer's behaviour can't drift.
    static let textCodecs: Set<AVCodecID> = [
        AV_CODEC_ID_SUBRIP, AV_CODEC_ID_TEXT, AV_CODEC_ID_ASS, AV_CODEC_ID_SSA,
        AV_CODEC_ID_WEBVTT, AV_CODEC_ID_MOV_TEXT,
    ]

    /// Bitmap subtitle codecs, surfaced by the probe for the host overlay.
    /// Teletext lives here too — it decodes through libzvbi, which this build
    /// has no reason to carry.
    static let bitmapCodecs: Set<AVCodecID> = [
        AV_CODEC_ID_HDMV_PGS_SUBTITLE, AV_CODEC_ID_DVB_SUBTITLE,
        AV_CODEC_ID_DVD_SUBTITLE, AV_CODEC_ID_XSUB, AV_CODEC_ID_DVB_TELETEXT,
    ]

    /// The bitmap codecs that additionally become OCR-fed renditions when the
    /// platform has Vision: the three with decoders in this build and real
    /// occurrence in libraries. XSUB is decodable but effectively extinct;
    /// teletext has no decoder here.
    static let ocrCodecs: Set<AVCodecID> = [
        AV_CODEC_ID_HDMV_PGS_SUBTITLE, AV_CODEC_ID_DVB_SUBTITLE,
        AV_CODEC_ID_DVD_SUBTITLE,
    ]

    /// An external subtitle file the host registered before `start()`.
    struct ExternalFile {
        let url: URL
        let language: String?
        let name: String?
        let isForced: Bool
    }

    /// One rendition being produced.
    private struct Track {
        enum Converter {
            /// Text packets → cue text, directly.
            case text(TextSubtitleConverter.Kind)
            /// Bitmap packets → composition → OCR → cue text. Class-typed:
            /// the pending-cue lifecycle is mutable state.
            case bitmap(BitmapRenditionTrack)
            /// External file, converted up front — `ingest` never sees it.
            case preloaded
        }

        /// Input stream index, or `nil` for an external file.
        let inputIndex: Int32?
        /// Source time base, for packet timestamps (`nil` for externals: their
        /// cues are already in seconds).
        let timeBase: AVRational?
        let converter: Converter
        let writer: WebVTTRenditionWriter
    }

    /// The pending-cue lifecycle of one OCR-fed bitmap rendition.
    ///
    /// Bitmap subtitles are *event* streams: a composition appears at its own
    /// time and stays up until the stream says otherwise — an explicit end
    /// (DVD), the next composition, or a clear event (PGS's way). A cue can
    /// therefore only be written once its end is known, so exactly one sits
    /// open here between events. Segment flushes split it at the boundary
    /// (the tail re-opens into the next segment) so a long-standing
    /// composition can't outrun the playlist, and `maximumCueSeconds` caps a
    /// stream whose clear never comes.
    final class BitmapRenditionTrack {
        static let maximumCueSeconds = 10.0

        /// `nil` only in tests, which feed `process(_:)` directly.
        private let decoder: BitmapSubtitleDecoder?
        private let language: String?
        /// Injectable so the pending-cue lifecycle is testable without Vision
        /// in the loop; production is always `SubtitleOCR.recognize`.
        private let recognize: (CGImage, String?) -> String?
        private var pending: SubtitleCue?

        /// Lazy arming (below) crosses threads: `arm`/`isStale` run on the
        /// loopback server's serve, everything else on the remux read loop.
        private let stateLock = NSLock()
        private var armed = false
        /// Segment indices flushed while unarmed — written as header-only VTT
        /// with the decode and OCR skipped. A fetch of one of these must
        /// re-produce it, not serve it: empty is a *stale* answer, and
        /// AVPlayer caches segments forever.
        private var staleSegments: Set<Int> = []

        init(
            decoder: BitmapSubtitleDecoder?,
            language: String?,
            recognize: @escaping (CGImage, String?) -> String? = SubtitleOCR.recognize
        ) {
            self.decoder = decoder
            self.language = language
            self.recognize = recognize
        }

        /// Whether anyone has ever fetched a segment of this rendition.
        /// Unarmed, `ingest` is a no-op — OCR costs tens of milliseconds per
        /// event, and a Blu-ray-class remux can carry dozens of PGS tracks of
        /// which the player selects at most one. Arming is one-way: a track
        /// someone watched once keeps producing, because AVPlayer re-fetches
        /// nothing and a de-armed gap could never be served correctly.
        var isArmed: Bool { stateLock.withLock { armed } }
        func arm() { stateLock.withLock { armed = true } }

        func recordStale(_ index: Int) {
            stateLock.withLock { _ = staleSegments.insert(index) }
        }
        func clearStale(_ index: Int) {
            stateLock.withLock { _ = staleSegments.remove(index) }
        }
        func isStale(_ index: Int) -> Bool {
            stateLock.withLock { staleSegments.contains(index) }
        }

        /// Decode one packet; returns every cue whose end became known.
        /// Skips ALL work — decode included — until the track is armed.
        func ingest(_ packet: UnsafeMutablePointer<AVPacket>) -> [SubtitleCue] {
            guard isArmed, let decoder else { return [] }
            return process(decoder.decode(packet))
        }

        /// The pending-cue lifecycle itself, decoder-independent.
        func process(_ events: [BitmapSubtitleDecoder.Event]) -> [SubtitleCue] {
            var closed: [SubtitleCue] = []
            for event in events {
                if let open = pending {
                    // Whatever this event is, it ends what was showing.
                    closed.append(open.ending(at: min(event.startSeconds, open.start + Self.maximumCueSeconds)))
                    pending = nil
                }
                guard let image = event.image else { continue }
                // Recognition happens here, on the remux read loop — tens of
                // milliseconds per event, and events are sparse (a couple per
                // segment). A track whose composition defeats the recognizer
                // simply produces no cue.
                guard let text = recognize(image, language) else { continue }
                if let end = event.endSeconds {
                    closed.append(SubtitleCue(start: event.startSeconds, end: end, text: text))
                } else {
                    pending = SubtitleCue(
                        start: event.startSeconds,
                        end: event.startSeconds + Self.maximumCueSeconds,
                        text: text
                    )
                }
            }
            return closed
        }

        /// A segment boundary: the open cue is split — its first part becomes
        /// writable, its tail re-opens at the boundary so the next segment
        /// repeats it (standard segmented-VTT behaviour for spanning cues).
        func splitPending(at boundary: Double) -> SubtitleCue? {
            guard let open = pending, open.start < boundary else { return nil }
            let cappedEnd = min(boundary, open.start + Self.maximumCueSeconds)
            let head = open.ending(at: cappedEnd)
            pending = cappedEnd < boundary ? nil : SubtitleCue(start: boundary, end: open.end, text: open.text)
            return head
        }

        /// A seek. Pre-seek state must not leak: the open cue dies unwritten
        /// and the decoder forgets its epoch (until the next epoch start the
        /// stream may honestly produce nothing).
        func reanchor() {
            pending = nil
            decoder?.flush()
        }
    }

    private let outputDirectory: URL
    private let lock = NSLock()
    private var externalFiles: [ExternalFile] = []
    private var tracks: [Track] = []
    private var storedRenditions: [MasterPlaylistBuilder.SubtitleRendition] = []
    /// Set once the presentation origin is known; guards a flush that would
    /// otherwise print cues against origin 0.
    private var originSet = false

    // MARK: Host cue tap

    /// The host's `TimedTextCue` sink, when one registered. Fired for every
    /// cue an **embedded** stream produces — external files are skipped, the
    /// host handed those in and already owns their text.
    private var cueHandler: (@Sendable (TimedTextCue) -> Void)?
    /// Everything delivered so far, so a handler registered after cues were
    /// already produced starts complete instead of mid-film. Bounded by the
    /// nature of the data: a subtitle track is a few thousand short strings.
    private var emittedCues: [TimedTextCue] = []
    /// Dedup for the demux revisiting a region (a demand-driven seek re-reads
    /// packets it already converted): the same source cue must not reach the
    /// host twice, or a replay would double every line.
    private var emittedKeys: Set<String> = []
    /// Cues converted before the presentation origin was known — they can't
    /// be rebased onto the played timeline yet, so they wait for
    /// `setTimelineOrigin`. In practice subtitle packets follow the first
    /// video keyframe, but "in practice" is not an ordering guarantee.
    private var preOriginCues: [(streamIndex: Int32, cue: SubtitleCue)] = []
    private var timelineOriginSeconds: Double = 0

    init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory
    }

    /// Renditions produced so far, in declaration order — what the caller feeds
    /// `MasterPlaylistBuilder`.
    var renditions: [MasterPlaylistBuilder.SubtitleRendition] {
        lock.withLock { storedRenditions }
    }

    /// Register an external `.srt` / `.vtt` file. Must happen before the remux
    /// starts; `PrismCoreSession` enforces that.
    func addExternalFile(_ file: ExternalFile) {
        lock.withLock { externalFiles.append(file) }
    }

    // MARK: - Setup

    /// Create a rendition per convertible source: embedded text streams first
    /// (in stream order), then registered external files. Returns the set of
    /// input stream indices whose packets `ingest` wants.
    @discardableResult
    func prepare(input: UnsafeMutablePointer<AVFormatContext>) throws -> Set<Int32> {
        var built: [Track] = []
        var descriptions: [MasterPlaylistBuilder.SubtitleRendition] = []

        // How many subtitle streams share each language — `isForcedRendition` needs to know
        // whether a forced track has a full sibling before it may be hidden as forced.
        var languageCounts: [String: Int] = [:]
        var hasTextTrack = false
        for index in 0..<Int32(input.pointee.nb_streams) {
            guard let stream = input.pointee.streams[Int(index)],
                  stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE
            else { continue }
            languageCounts[avMetadataValue(stream.pointee.metadata, "language") ?? "", default: 0] += 1
            if Self.kind(for: stream.pointee.codecpar.pointee.codec_id) != nil { hasTextTrack = true }
        }

        for index in 0..<Int32(input.pointee.nb_streams) {
            guard let stream = input.pointee.streams[Int(index)] else { continue }
            let par = stream.pointee.codecpar.pointee
            guard par.codec_type == AVMEDIA_TYPE_SUBTITLE else { continue }
            let language = avMetadataValue(stream.pointee.metadata, "language")

            let converter: Track.Converter
            if let kind = Self.kind(for: par.codec_id) {
                converter = .text(kind)
            } else if Self.ocrCodecs.contains(par.codec_id), !hasTextTrack, SubtitleOCR.isAvailable,
                      let decoder = try? BitmapSubtitleDecoder(
                        codecpar: stream.pointee.codecpar, timeBase: stream.pointee.time_base
                      ) {
                // A bitmap track becomes a rendition through on-device OCR —
                // lossy by design (typography dies, text survives), but it is
                // the only form that rides PiP, AirPlay and the system menu.
                // Only when the source has no text track at all: beside a real
                // SRT, four unlabelled OCR readings of the same dialogue are
                // menu noise that hides the one worth choosing (a Vision Pro
                // menu of "English-SRT, Subtitles 2, 3, 4, 5" — 2026-09-06).
                // A build without Vision, or a decoder this build lacks,
                // leaves the track host-only exactly as before.
                converter = .bitmap(BitmapRenditionTrack(decoder: decoder, language: language))
            } else {
                continue
            }

            let ordinal = built.count
            let writer = try WebVTTRenditionWriter(
                directory: outputDirectory.appendingPathComponent(Self.directoryName(ordinal), isDirectory: true)
            )
            built.append(
                Track(
                    inputIndex: index,
                    timeBase: stream.pointee.time_base,
                    converter: converter,
                    writer: writer
                )
            )
            descriptions.append(
                MasterPlaylistBuilder.SubtitleRendition(
                    name: Self.renditionName(
                        language: language,
                        title: avMetadataValue(stream.pointee.metadata, "title"),
                        ordinal: ordinal
                    ),
                    language: language,
                    uri: "\(Self.directoryName(ordinal))/index.m3u8",
                    isForced: Self.isForcedRendition(
                        disposition: stream.pointee.disposition,
                        sameLanguageTracks: languageCounts[language ?? ""] ?? 1
                    )
                )
            )
        }

        for file in lock.withLock({ externalFiles }) {
            // A file that can't be read or holds no cues gets no rendition at
            // all: an empty rendition in the menu is worse than a missing one.
            guard let cues = Self.loadExternalCues(file.url), !cues.isEmpty else { continue }
            let ordinal = built.count
            let writer = try WebVTTRenditionWriter(
                directory: outputDirectory.appendingPathComponent(Self.directoryName(ordinal), isDirectory: true)
            )
            // The whole file is converted up front; segmentation then follows
            // the video boundaries exactly like an embedded track's, so the
            // rendition playlist lines up 1:1 with the variant.
            for cue in cues { writer.add(cue) }
            built.append(Track(inputIndex: nil, timeBase: nil, converter: .preloaded, writer: writer))
            descriptions.append(
                MasterPlaylistBuilder.SubtitleRendition(
                    name: file.name ?? file.language ?? "Subtitles \(ordinal + 1)",
                    language: file.language,
                    uri: "\(Self.directoryName(ordinal))/index.m3u8",
                    isForced: file.isForced
                )
            )
        }

        lock.withLock {
            tracks = built
            storedRenditions = Self.withUniqueNames(descriptions)
        }
        return Set(built.compactMap(\.inputIndex))
    }

    /// Force every rendition's `NAME` to be unique within the group.
    ///
    /// HLS forbids two renditions in one group sharing a `NAME`
    /// (RFC 8216 §4.3.4.1), and AVFoundation enforces it the expensive way: it
    /// keeps the first and **silently discards** the rest. No error, no log —
    /// the option simply is not in the legible `AVMediaSelectionGroup`, and a
    /// host that builds its menu from that group shows one track where the
    /// source had two.
    ///
    /// Which is not an exotic shape. The name falls back to the container's
    /// title, then the language tag, and a forced track is usually untitled —
    /// so an MKV with `eng` full plus `eng` forced (the ordinary way a disc rip
    /// carries foreign-dialogue subtitles) produced two renditions both named
    /// `eng`, and the forced one lost. It was invisible from the playlist text,
    /// which listed both lines correctly, `FORCED=YES` and all.
    ///
    /// What the player's menu calls a rendition.
    ///
    /// The language, in its own name, the way Apple's playlists and the converted files do:
    /// "English", "Français". A muxer's title is usually noise ("English-SRT") and is dropped —
    /// unless it says what *kind* of track this is (SDH, forced, signs), which the language alone
    /// cannot, and then it rides along: "English (Signs & Songs)". No language, no title: an
    /// ordinal, and `withUniqueNames` keeps collisions apart.
    static func renditionName(language: String?, title: String?, ordinal: Int) -> String {
        let endonym = language.flatMap { code -> String? in
            let locale = Locale(identifier: code)
            return locale.localizedString(forLanguageCode: code)?.capitalized(with: locale)
        }
        let kindWords = ["sdh", "cc", "hearing", "forced", "signs", "songs", "commentary"]
        let describes = title.map { t in kindWords.contains { t.lowercased().contains($0) } } ?? false
        switch (endonym, title) {
        case (let name?, let t?) where describes: return "\(name) (\(t))"
        case (let name?, _): return name
        case (nil, let t?): return t
        case (nil, nil): return "Subtitles \(ordinal + 1)"
        }
    }

    /// Whether a subtitle stream should be declared `FORCED=YES`.
    ///
    /// AVKit never lists a forced rendition in its subtitle menu — it shows one only on its own
    /// initiative, for foreign dialogue. That is right for a disc rip's forced track, which sits
    /// beside a full track of the same language. It is wrong for the common release whose only
    /// text track is flagged both default and forced (YTS does this to every SRT it muxes): passed
    /// through, the film's one set of subtitles becomes unreachable from the player. So a forced
    /// flag is honoured only when the track has a same-language sibling to be the full version;
    /// alone, it is the full version, whatever the flag says.
    static func isForcedRendition(disposition: Int32, sameLanguageTracks: Int) -> Bool {
        guard disposition & AV_DISPOSITION_FORCED != 0 else { return false }
        return sameLanguageTracks > 1
    }

    /// The disambiguator is a bare ordinal rather than something descriptive
    /// like "Forced": AVFoundation already appends "Forced" to the *display*
    /// name of a `FORCED=YES` rendition, so naming one "English (Forced)"
    /// reads back as "English (Forced) Forced" in the menu.
    static func withUniqueNames(
        _ descriptions: [MasterPlaylistBuilder.SubtitleRendition]
    ) -> [MasterPlaylistBuilder.SubtitleRendition] {
        // Case-insensitive: "English" and "english" are two legal NAMEs by the
        // letter of the spec and one indistinguishable row in any menu.
        var used: Set<String> = []
        return descriptions.map { description in
            var name = description.name
            var ordinal = 2
            while !used.insert(name.lowercased()).inserted {
                name = "\(description.name) \(ordinal)"
                ordinal += 1
            }
            var unique = description
            unique.name = name
            return unique
        }
    }

    // MARK: - Lazy arming

    /// What the loopback provider should do with a subtitle-segment fetch.
    enum DemandVerdict {
        /// The file on disk (or its absence) is the truth — serve normally.
        case serveAsIs
        /// The file was cut while the track was unarmed: header-only, with the
        /// OCR skipped. Re-produce it instead of serving the stale empty.
        case regenerate
    }

    /// The provider reports every `.vtt` fetch here, and this is what arms a
    /// bitmap track: OCR runs only for renditions someone actually selected.
    /// Arming on the segment fetch and not the playlist deliberately —
    /// AVPlayer may prefetch rendition playlists it never plays, but it
    /// fetches segments only for the selection.
    ///
    /// Server-thread safe; the stale file is deleted here so the provider's
    /// wait-for-file resolves on the re-produced one, never the stale empty.
    func noteSegmentDemand(path: String) -> DemandVerdict {
        guard let (ordinal, index) = Self.renditionSegment(inPath: path) else { return .serveAsIs }
        let track = lock.withLock { tracks.indices.contains(ordinal) ? tracks[ordinal] : nil }
        guard let track, case .bitmap(let bitmap) = track.converter else { return .serveAsIs }

        bitmap.arm()
        guard bitmap.isStale(index) else { return .serveAsIs }
        try? FileManager.default.removeItem(
            at: outputDirectory
                .appendingPathComponent(Self.directoryName(ordinal), isDirectory: true)
                .appendingPathComponent(String(format: "seg%05d.vtt", index))
        )
        return .regenerate
    }

    /// `subs<ordinal>/seg<index>.vtt` at the end of a request path, or `nil`
    /// for anything else (playlists included).
    static func renditionSegment(inPath path: String) -> (ordinal: Int, index: Int)? {
        let parts = path.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        let directory = parts[parts.count - 2]
        let name = parts[parts.count - 1]
        guard directory.hasPrefix("subs"), let ordinal = Int(directory.dropFirst(4)),
              name.hasPrefix("seg"), name.hasSuffix(".vtt"),
              let index = Int(name.dropFirst(3).dropLast(4))
        else { return nil }
        return (ordinal, index)
    }

    /// The presentation origin (first video PTS, in seconds). Every writer needs
    /// it before the first flush; see `WebVTTRenditionWriter` for what it means
    /// for `X-TIMESTAMP-MAP`.
    func setTimelineOrigin(seconds: Double) {
        guard !originSet else { return }
        originSet = true
        for track in tracks { track.writer.setTimelineOrigin(seconds: seconds) }

        // The origin is what the host tap rebases against — flush whatever
        // arrived before it existed.
        var toDeliver: [TimedTextCue] = []
        var handler: (@Sendable (TimedTextCue) -> Void)?
        lock.withLock {
            timelineOriginSeconds = max(0, seconds)
            for pending in preOriginCues {
                if let rebased = rebasedLocked(streamIndex: pending.streamIndex, pending.cue) {
                    toDeliver.append(rebased)
                }
            }
            preOriginCues = []
            handler = cueHandler
        }
        if let handler {
            for cue in toDeliver { handler(cue) }
        }
    }

    // MARK: - Host cue tap

    /// Register (or clear) the host's cue sink. Everything already produced is
    /// replayed to a new handler first, in production order — a host that
    /// attaches after `start()` returned must not miss the opening dialogue.
    func setCueHandler(_ handler: (@Sendable (TimedTextCue) -> Void)?) {
        let replay: [TimedTextCue] = lock.withLock {
            cueHandler = handler
            return handler != nil ? emittedCues : []
        }
        guard let handler else { return }
        for cue in replay { handler(cue) }
    }

    /// Rebase one produced cue onto the played timeline and hand it to the
    /// host — or hold it until the origin exists.
    private func emitHostCue(streamIndex: Int32, _ cue: SubtitleCue) {
        var toDeliver: TimedTextCue?
        var handler: (@Sendable (TimedTextCue) -> Void)?
        lock.withLock {
            guard originSet else {
                preOriginCues.append((streamIndex, cue))
                return
            }
            toDeliver = rebasedLocked(streamIndex: streamIndex, cue)
            handler = cueHandler
        }
        if let handler, let toDeliver { handler(toDeliver) }
    }

    /// Origin-rebased, deduplicated host cue — `nil` for an empty, inverted or
    /// already-emitted one. Caller holds `lock`.
    private func rebasedLocked(streamIndex: Int32, _ cue: SubtitleCue) -> TimedTextCue? {
        guard !cue.text.isEmpty else { return nil }
        let start = Swift.max(0, cue.start - timelineOriginSeconds)
        let end = cue.end - timelineOriginSeconds
        guard end > start else { return nil }
        let key = "\(streamIndex)|\(cue.start)|\(cue.end)|\(cue.text)"
        guard emittedKeys.insert(key).inserted else { return nil }
        let rebased = TimedTextCue(streamIndex: streamIndex, start: start, end: end, text: cue.text)
        emittedCues.append(rebased)
        return rebased
    }

    // MARK: - Production

    /// Convert one subtitle packet into cues. Packets for streams that aren't
    /// tracked (a codec we neither convert nor OCR) are ignored.
    func ingest(_ packet: UnsafeMutablePointer<AVPacket>) {
        let streamIndex = Int32(packet.pointee.stream_index)
        guard let track = tracks.first(where: { $0.inputIndex == streamIndex }) else { return }

        switch track.converter {
        case .preloaded:
            return
        case .bitmap(let bitmap):
            // Bitmap events carry their own AV_TIME_BASE-derived times; the
            // decoder needs the packet even when its pts is unset (PGS spreads
            // one composition over several packets).
            for cue in bitmap.ingest(packet) {
                track.writer.add(cue)
                emitHostCue(streamIndex: streamIndex, cue)
            }
        case .text(let kind):
            guard let timeBase = track.timeBase,
                  packet.pointee.pts != swift_AV_NOPTS_VALUE(),
                  let data = packet.pointee.data, packet.pointee.size > 0
            else { return }
            let payload = Data(bytes: data, count: Int(packet.pointee.size))
            guard let text = TextSubtitleConverter.cueText(from: payload, kind: kind) else { return }

            let tick = av_q2d(timeBase)
            let start = Double(packet.pointee.pts) * tick
            let duration = packet.pointee.duration > 0
                ? Double(packet.pointee.duration) * tick
                : WebVTTRenditionWriter.fallbackCueSeconds
            let cue = SubtitleCue(start: start, end: start + duration, text: text)
            track.writer.add(cue)
            emitHostCue(streamIndex: streamIndex, cue)
        }
    }

    /// Cut every rendition on the video segment's own boundaries (source
    /// seconds), so segment N of a rendition covers segment N of the variant.
    func flushSegment(start: Double, end: Double) throws {
        for track in tracks {
            // An open bitmap cue splits at the boundary: its first part is
            // written into this segment, its tail re-opens into the next —
            // a composition standing longer than a segment must not vanish
            // from the playlist while it stands on screen.
            if case .bitmap(let bitmap) = track.converter {
                // Bookkeep what this cut is: an unarmed cut is stale (the OCR
                // was skipped; a fetch must re-produce it), an armed cut is
                // the re-production that clears it.
                let index = track.writer.nextSegmentIndex
                if bitmap.isArmed {
                    bitmap.clearStale(index)
                } else {
                    bitmap.recordStale(index)
                }
                if let head = bitmap.splitPending(at: end) {
                    track.writer.add(head)
                }
            }
            try track.writer.flushSegment(start: start, end: end)
        }
    }

    /// Planned mode on every rendition (see `WebVTTRenditionWriter`).
    func writePlannedVOD(durations: [Double]) throws {
        for track in tracks {
            try track.writer.writePlannedVOD(durations: durations)
        }
    }

    /// Demand-driven jump on every rendition.
    func reanchor(segmentIndex: Int, startSeconds: Double) {
        for track in tracks {
            if case .bitmap(let bitmap) = track.converter {
                bitmap.reanchor()
            }
            track.writer.reanchor(segmentIndex: segmentIndex, startSeconds: startSeconds)
        }
    }

    /// `EXT-X-ENDLIST` on every rendition playlist.
    func finish() throws {
        for track in tracks {
            try track.writer.finish()
        }
    }

    // MARK: - Helpers

    static func directoryName(_ ordinal: Int) -> String { "subs\(ordinal)" }

    /// Payload shape for a subtitle codec, or `nil` if it isn't text we
    /// convert.
    static func kind(for codecID: AVCodecID) -> TextSubtitleConverter.Kind? {
        switch codecID {
        case AV_CODEC_ID_SUBRIP, AV_CODEC_ID_TEXT: return .subrip
        case AV_CODEC_ID_ASS, AV_CODEC_ID_SSA: return .ass
        case AV_CODEC_ID_WEBVTT: return .webvtt
        case AV_CODEC_ID_MOV_TEXT: return .movText
        default: return nil
        }
    }

    /// Read and convert a whole sidecar file. The extension picks the parser;
    /// unknown extensions are tried as WebVTT and then SRT, because a sidecar
    /// served over HTTP often has no usable path extension at all.
    static func loadExternalCues(_ url: URL) -> [SubtitleCue]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        else { return nil }

        switch url.pathExtension.lowercased() {
        case "vtt":
            return TextSubtitleConverter.cues(fromWebVTT: text)
        case "srt":
            return TextSubtitleConverter.cues(fromSRT: text)
        default:
            let asVTT = TextSubtitleConverter.cues(fromWebVTT: text)
            return asVTT.isEmpty ? TextSubtitleConverter.cues(fromSRT: text) : asVTT
        }
    }
}
