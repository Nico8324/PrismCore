import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// One HLS **alternate audio rendition**: its own fMP4 segment writer, its own
/// media playlist, its own subdirectory (`audio0/index.m3u8`, `audio0/init.mp4`,
/// `audio0/seg00000.m4s`, …).
///
/// Why a rendition per track instead of muxing several audio traks into the
/// video's own segments: in-band alternates are only reachable through a
/// URI-less `EXT-X-MEDIA`, which HLS defines as "this rendition is inside the
/// variant" — one group, one muxed track, and AVFoundation gets no honest way to
/// switch. A demuxed rendition is the shape HLS was designed for: AVPlayer
/// fetches only the audio the user selected (a five-language MKV stops costing
/// five times the audio bandwidth), and each track keeps its own init segment,
/// which is what lets an AAC track and an AC3 track coexist at all.
///
/// The remuxer drives the cuts — this type never decides a boundary, it is told
/// one (see `cut(durationSeconds:)`), so every rendition is segmented on the
/// *video's* boundaries and the presentation stays comparable across renditions.
final class AudioRenditionWriter {

    /// Where the audio bits come from.
    let route: HLSRemuxer.AudioRoute
    /// What the probe said about the source track — the metadata the master
    /// playlist's `NAME` / `LANGUAGE` / `CHANNELS` come from.
    let track: AudioTrackInfo

    /// `audio0`, `audio1`, … — both the on-disk directory and the URI prefix.
    let directoryName: String
    private let ordinal: Int
    private let directory: URL

    private var writer = FMP4SegmentWriter()
    var audioDelaySeconds: Double = 0
    /// Planned (demand-driven) mode: the playlist was written complete
    /// upfront from the segment plan — cuts write FILES only.
    private var plannedMode = false
    private let playlist: MediaPlaylistWriter
    private var bridge: AudioBridge?
    var onBridgeProgress: ((AudioBridgeProgress) -> Void)?
    private var outputIndex: Int32 = 0
    private var segmentIndex = 0
    /// Boundary time that had no audio bytes to carry (see `cut`). Rolled into
    /// the next segment's `EXTINF` so the rendition's total duration keeps
    /// matching the video's.
    private var pendingDuration: Double = 0

    /// `complexity_index_type_a` sniffed out of this track's first readable
    /// E-AC-3 syncframe, for the `dec3` box the muxer writes without it.
    ///
    /// Read from the bitstream rather than assumed from the probe's
    /// `isObjectAudio`: the probe knows the track *claims* Atmos, but the index
    /// is a number only the frame carries, and the box needs the number.
    private var atmosComplexityIndex: Int?
    /// Stop paying for the walk once the question is settled — answered, or
    /// asked of `atmosSniffPacketBudget` frames without one.
    private var atmosSniffDone = false
    /// Frames the walk may read before it accepts "no JOC here" as the answer.
    /// A partial first frame is normal, so one packet is not enough to conclude
    /// anything; ~24 E-AC-3 frames is under a second of audio and the walk is
    /// bytes, not decode.
    private static let atmosSniffPacketBudget = 24
    private var atmosSniffPacketsRead = 0
    /// Reports the settled question to the remux, once. Set by the remuxer.
    var onObjectAudioSettled: ((ObjectAudioFinding) -> Void)?

    static let initFileName = "init.mp4"

    /// Planned mode only: the outcome of a boundary for this rendition —
    /// `produced == false` means it had no audio and the slot keeps its
    /// index empty (see `cut`), which the remuxer relays to the demand seam
    /// so a fetch of it is a fast 404 rather than a 15 s pending wait;
    /// `true` clears that mark, because a re-anchor can land audio in a slot
    /// the first pass found empty.
    var onPlannedSegment: ((_ index: Int, _ produced: Bool) -> Void)?

    /// Lazy renditions (dialogue boost) are DECLARED at open but PRODUCED
    /// only once a fetch under `audioN/` says someone selected them — the
    /// same pattern as OCR subtitles (`SubtitleRenditionSet.noteSegmentDemand`).
    /// Until then the bridge (decoder + filter + encoder + resampler + FIFO)
    /// does not exist and the copy loop's `write` is a no-op, so a session
    /// that never touches Enhance Dialogue pays nothing for the two levels
    /// the host always requests. `arm()` is called from the server's thread,
    /// hence the lock; the producer applies it at the next safe point.
    let isLazy: Bool
    private let armLock = NSLock()
    private var armRequested = false
    /// Whether the muxer (and bridge) currently exist. Always true for an
    /// eager rendition after `open`; a lazy one turns it on when the
    /// producer honours the arm request.
    private(set) var isProducing = false
    /// The encoder's negotiated channel count, learned at `open` from a
    /// bridge that is built and torn down again — `CHANNELS` in the master
    /// has to be right before the first fetch, but the bridge itself need
    /// not exist for that.
    private var negotiatedChannelCount: Int?

    init(
        route: HLSRemuxer.AudioRoute, track: AudioTrackInfo, ordinal: Int, parent: URL,
        lazy: Bool = false
    ) {
        self.route = route
        self.track = track
        self.ordinal = ordinal
        self.isLazy = lazy
        self.directoryName = "audio\(ordinal)"
        self.directory = parent.appendingPathComponent(directoryName, isDirectory: true)
        self.playlist = MediaPlaylistWriter(directory: directory, initFileName: Self.initFileName)
    }

    /// A fetch under this rendition's directory: the demand that turns a
    /// lazy rendition on. Returns `true` when this call is the one that armed
    /// it (the caller then re-anchors production so the first produced
    /// segment is a complete one); `false` for an already-armed or eager
    /// rendition. Server-thread safe.
    func arm() -> Bool {
        guard isLazy else { return false }
        return armLock.withLock {
            if armRequested { return false }
            armRequested = true
            return true
        }
    }

    /// Whether a lazy rendition has been asked for (armed) — not the same as
    /// producing: the producer opens the bridge at the next safe point.
    var isArmed: Bool {
        guard isLazy else { return true }
        return armLock.withLock { armRequested }
    }

    /// Create the rendition's directory, its muxer and — for a bridged track —
    /// its encoder. Must run before the master playlist is written: a bridged
    /// rendition's declared codec and channel count come from the encoder that
    /// only exists after this call.
    func open(input: UnsafeMutablePointer<AVFormatContext>, restart: Bool = false) throws {
        // Once: a re-anchor goes through `reanchor`, which keeps the directory
        // (and the bridge) and only rebuilds the muxer.
        if !directoryCreated {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            directoryCreated = true
        }

        let index = Int32(track.streamIndex)
        if isLazy, !isArmed {
            // Declared, not produced. The bridge is built once so that the
            // eligibility checks (a stereo track has no centre to favour, a
            // build without the encoder) fail HERE — where the caller skips
            // the rendition — rather than after the master has promised it,
            // and so `CHANNELS` can be read off the negotiated layout; then
            // it is released again. Nothing else exists until `arm()`.
            if negotiatedChannelCount == nil, route.mode != .streamCopy {
                let inStream = input.pointee.streams[Int(index)]!
                let probeBridge = try AudioBridge(
                    codecpar: inStream.pointee.codecpar,
                    timeBase: inStream.pointee.time_base,
                    globalHeader: true,
                    dialogueBoost: route.mode.dialogueBoostLevel
                )
                negotiatedChannelCount = probeBridge.outputChannelCount
                probeBridge.close()
            }
            isProducing = false
            return
        }

        if route.mode != .streamCopy, bridge == nil {
            let inStream = input.pointee.streams[Int(index)]!
            bridge = try AudioBridge(
                codecpar: inStream.pointee.codecpar,
                timeBase: inStream.pointee.time_base,
                // mp4/mov is a global-header muxer: the encoder's extradata
                // belongs in codecpar, not in-band.
                globalHeader: true,
                // Nil for a plain bridge; a boost rendition's bridge carries
                // the centre-favouring filter between decode and re-encode.
                dialogueBoost: route.mode.dialogueBoostLevel
            )
            bridge?.onProgress = onBridgeProgress
        }
        try openMuxer(input: input, restart: restart)
    }

    private var directoryCreated = false

    /// The muxer alone, described from the bridge when there is one — the
    /// part of `open` a re-anchor repeats.
    private func openMuxer(input: UnsafeMutablePointer<AVFormatContext>, restart: Bool) throws {
        writer.audioDelaySeconds = audioDelaySeconds
        let index = Int32(track.streamIndex)
        let plan: FMP4SegmentWriter.StreamPlan
        if let bridge {
            plan = .init(inputIndex: index, language: sourceLanguage) { outStream in
                try bridge.configure(outputStream: outStream)
            }
        } else {
            plan = .init(inputIndex: index, language: sourceLanguage)
        }
        _ = try writer.open(input: input, plan: [plan], restart: restart)
        outputIndex = writer.streamMap[track.streamIndex] ?? 0
        isProducing = true
    }

    func close() {
        bridge?.close()
        bridge = nil
    }

    /// Planned mode: publish the complete rendition playlist upfront (same
    /// durations as the video's — the playlist arithmetic must agree across
    /// renditions) and stop appending at cuts.
    func writePlannedVOD(durations: [Double]) throws {
        plannedMode = true
        try playlist.writePlannedVOD(durations: durations) { index in
            String(format: "seg%05d.m4s", index)
        }
    }

    /// Demand-driven jump: fresh muxer (and bridge) anchored at plan segment
    /// `segmentIndex`. The old muxer's partial fragment is abandoned — that
    /// segment gets reproduced if anything ever asks for it.
    func reanchor(input: UnsafeMutablePointer<AVFormatContext>, segmentIndex: Int) throws {
        writer = FMP4SegmentWriter()
        if isProducing {
            if let bridge, bridge.isDrained {
                // Flushed at EOF: the encoder is in its terminal state and
                // cannot be revived, so this one case rebuilds the bridge.
                bridge.close()
                self.bridge = nil
                try open(input: input, restart: true)
            } else {
                // The bridge stays: its buffered state is reset, its contexts
                // live on (`AudioBridge.reset`). Only the muxer is new — tfdt
                // continuity under frag_discont needs a fresh one.
                bridge?.reset()
                try openMuxer(input: input, restart: true)
            }
        } else {
            // A lazy rendition that nobody armed stays dormant through the
            // re-anchor (`open` returns before the muxer); an armed one opens
            // here, at a plan boundary, which is what makes its first segment
            // a complete one.
            try open(input: input, restart: true)
        }
        self.segmentIndex = segmentIndex
        pendingDuration = 0
    }

    /// Push one source packet for this track through copy or bridge.
    func write(_ packet: UnsafeMutablePointer<AVPacket>, sourceTimeBase: AVRational) throws {
        // Dormant lazy rendition: the packet is nobody's. The check is the
        // whole per-packet cost of a boost level nobody selected.
        guard isProducing else { return }
        sniffAtmosIfNeeded(packet)
        if let bridge {
            // Timestamps arrive in the source stream's base (the bridge's
            // decoder is configured for it) and come back out on the encoder's.
            try bridge.feed(packet) { encoded in
                try self.emit(encoded, from: bridge.timeBase)
            }
        } else {
            try emit(packet, from: sourceTimeBase)
        }
    }

    /// Flush the bridge's encoder tail. Only meaningful on EOF — a cancelled
    /// session is being torn down and the tail would be work for nobody.
    func flushBridge() throws {
        guard let bridge else { return }
        try bridge.flush { encoded in
            try self.emit(encoded, from: bridge.timeBase)
        }
    }

    /// Write the init segment, adding the JOC declaration the muxer omits.
    ///
    /// FFmpeg writes a `dec3` without the TS 103 420 extension even for a
    /// stream-copied Atmos track, and that omission is the difference between
    /// Atmos and plain DD+ at the speaker.
    private func writeInitSegment(_ initSegment: Data) throws {
        let bytes = atmosComplexityIndex.flatMap {
            EAC3Configuration.patch(initSegment: initSegment, atmosComplexityIndex: $0)
        } ?? initSegment
        try bytes.write(
            to: directory.appendingPathComponent(Self.initFileName),
            options: .atomic
        )
    }

    /// Look for the JOC declaration in this track's first readable E-AC-3
    /// syncframes.
    ///
    /// Stream-copy only — a bridged track's output is the encoder's and carries
    /// no JOC, so declaring it there would promise Atmos the bridge destroyed.
    ///
    /// Deliberately **not** gated on the probe's `isObjectAudio`. That flag
    /// comes from `AVCodecParameters.profile`, which libavformat fills in only
    /// when `avformat_find_stream_info` happened to decode an audio frame — so
    /// gating on it meant a real Atmos track whose profile went unset was never
    /// even asked, its `dec3` shipped without the extension, and it played as
    /// plain DD+ with nothing anywhere reporting a problem. The bitstream is
    /// cheap to ask and is the only thing that actually knows.
    private func sniffAtmosIfNeeded(_ packet: UnsafeMutablePointer<AVPacket>) {
        guard !atmosSniffDone, route.mode == .streamCopy,
              track.codecName == "eac3",
              let data = packet.pointee.data, packet.pointee.size > 0
        else { return }
        atmosSniffPacketsRead += 1
        if let index = EAC3Syncframe.atmosComplexityIndex(
            in: UnsafeBufferPointer(start: data, count: Int(packet.pointee.size))
        ) {
            atmosComplexityIndex = index
            settleAtmos()
            return
        }
        // A frame that didn't answer leaves the sniff open: the first packet of a
        // stream-copied track can be a partial frame, and the next one usually
        // isn't. The budget is what turns "kept looking" into "there is none" —
        // without it, a plain DD+ track pays the walk on every packet of a film.
        if atmosSniffPacketsRead >= Self.atmosSniffPacketBudget { settleAtmos() }
    }

    /// The question is answered — publish it and stop paying for the walk.
    private func settleAtmos() {
        atmosSniffDone = true
        onObjectAudioSettled?(
            ObjectAudioFinding(
                streamIndex: track.streamIndex,
                complexityIndex: atmosComplexityIndex,
                claimedByMetadata: track.isObjectAudio
            )
        )
    }

    /// Rescale onto this rendition's single output stream and mux.
    /// `sourceTimeBase` is the packet's own base — the input stream's for
    /// copied packets, the encoder's for bridged ones.
    private func emit(
        _ packet: UnsafeMutablePointer<AVPacket>,
        from sourceTimeBase: AVRational
    ) throws {
        guard let output = writer.context else { return }
        let outStream = output.pointee.streams[Int(outputIndex)]!
        av_packet_rescale_ts(packet, sourceTimeBase, outStream.pointee.time_base)
        packet.pointee.stream_index = outputIndex
        packet.pointee.pos = -1
        try writer.write(packet)
    }

    /// Cut a segment at the boundary the *video* just chose.
    ///
    /// `durationSeconds` is the video segment's own duration rather than the
    /// audio's measured span, and deliberately so: the two differ by whatever
    /// the container's interleave and the codec's frame size make them differ by
    /// (an AAC frame is 21 ms, an EAC3 frame 32 ms — neither divides a video
    /// boundary), and it is the *playlist arithmetic* that has to agree across
    /// renditions for AVPlayer to switch between them without drifting. The
    /// real sample times ride in the segments' own `tfdt`, which is what
    /// playback follows.
    /// Returns the media bytes written for this boundary (0 for an empty or
    /// dormant one) — what retention accounts, without a `stat` per rendition
    /// per cut.
    @discardableResult
    func cut(durationSeconds: Double) throws -> Int {
        guard isProducing else {
            // Dormant: the boundary still passes. The planned slot keeps its
            // index (the playlist maps it to this time) but is NOT declared
            // unproducible — the fetch that arms this rendition re-anchors
            // production to reproduce exactly these slots, and a 404 mark
            // would race that fetch's pending wait. In the sequential shape
            // the time folds into the next entry, as for any silent boundary.
            if plannedMode {
                segmentIndex += 1
            } else {
                pendingDuration += durationSeconds
            }
            return 0
        }
        let (initSegment, media) = try writer.cutSegment()
        // The first cut mints the init segment; write it BEFORE the playlist
        // entry that references it.
        if let initSegment, !initSegment.isEmpty {
            try writeInitSegment(initSegment)
        }
        guard !media.isEmpty else {
            if plannedMode {
                // The planned playlist already maps this index to this time
                // span, so the slot must stay EMPTY rather than be reused: a
                // rendition whose audio starts after the head boundary (a
                // late-starting track, or an interleave lagging the shorter
                // 2 s head) would otherwise write its first audio as
                // segment 0 and shift every later segment against the video.
                onPlannedSegment?(segmentIndex, false)
                segmentIndex += 1
                return 0
            }
            // Sequential: nothing to carry for this boundary. Skipping the
            // entry keeps the EVENT playlist free of zero-byte segments; the
            // time it covered joins the next one.
            pendingDuration += durationSeconds
            return 0
        }
        let file = String(format: "seg%05d.m4s", segmentIndex)
        try media.write(to: directory.appendingPathComponent(file), options: .atomic)
        if plannedMode {
            onPlannedSegment?(segmentIndex, true)
        } else {
            try playlist.appendSegment(
                duration: max(0.001, pendingDuration + durationSeconds),
                file: file
            )
        }
        pendingDuration = 0
        segmentIndex += 1
        return media.count
    }

    /// Final cut: whatever is buffered plus the trailer's tail bytes.
    func finish(durationSeconds: Double, endList: Bool) throws {
        guard isProducing else {
            // Dormant to the end: an EVENT playlist still gets its ENDLIST so
            // a late selection sees a finished (empty) rendition rather than
            // one that looks live forever; planned playlists were born ended.
            if endList, !plannedMode { try playlist.finish() }
            return
        }
        let (initSegment, media) = try writer.cutSegment()
        if let initSegment, !initSegment.isEmpty {
            try writeInitSegment(initSegment)
        }
        var finalSegment = media
        finalSegment.append(try writer.finish())
        if !finalSegment.isEmpty {
            let file = String(format: "seg%05d.m4s", segmentIndex)
            try finalSegment.write(to: directory.appendingPathComponent(file), options: .atomic)
            if !plannedMode {
                try playlist.appendSegment(
                    duration: max(0.001, pendingDuration + durationSeconds),
                    file: file
                )
            }
            pendingDuration = 0
            segmentIndex += 1
        }
        if endList, !plannedMode {
            try playlist.finish()
        }
    }

    // MARK: - Master playlist description

    /// Relative URI of this rendition's media playlist, as the master refers
    /// to it.
    var playlistURI: String { "\(directoryName)/index.m3u8" }

    /// The container's language tag, or `nil` when it has none. "und" is the
    /// container's way of saying it doesn't know, which is not a language tag —
    /// omitting it says the same thing without lying to the language-preference
    /// matcher.
    private var sourceLanguage: String? {
        track.language.flatMap { $0 == "und" || $0.isEmpty ? nil : $0 }
    }

    /// How this rendition is declared in the master playlist.
    func rendition(groupID: String, isDefault: Bool) -> MasterPlaylistBuilder.AudioRendition {
        MasterPlaylistBuilder.AudioRendition(
            groupID: groupID,
            name: renditionName,
            language: sourceLanguage,
            codecString: outputCodecString,
            channels: MasterPlaylistBuilder.channelsAttribute(
                channelCount: outputChannelCount,
                isObjectAudio: outputCarriesObjectAudio
            ),
            uri: playlistURI,
            isDefault: isDefault,
            // The characteristic is what lets a host FIND the boost options
            // (`hasMediaCharacteristic(.enhancesSpeechIntelligibility)`); it
            // also keeps AVFoundation from auto-selecting them for anyone who
            // hasn't asked, AUTOSELECT=YES notwithstanding — accessibility
            // renditions engage on the user's system preference.
            characteristics: route.mode.dialogueBoostLevel != nil
                ? [dialogueBoostCharacteristic]
                : []
        )
    }

    /// This rendition's entry in the session's dialogue-boost report, or nil
    /// for the base renditions.
    var dialogueBoostInfo: DialogueBoostRendition? {
        guard let level = route.mode.dialogueBoostLevel else { return nil }
        return DialogueBoostRendition(level: level, name: renditionName)
    }

    /// `NAME` is what the user picks from, so the container's own title wins;
    /// failing that the language, spelled out in the viewer's locale ("Czech",
    /// not "ces"); failing that an ordinal, which at least distinguishes the
    /// tracks from each other. A boost rendition appends its level's suffix so
    /// the two stay tellable-apart in AVKit's own picker — and NAME must be
    /// unique within the group anyway.
    private var renditionName: String {
        if let level = route.mode.dialogueBoostLevel {
            return "\(baseRenditionName) (\(level.renditionNameSuffix))"
        }
        return baseRenditionName
    }

    private var baseRenditionName: String {
        if let title = track.title, !title.isEmpty { return title }
        if let language = track.language, language != "und", !language.isEmpty {
            if let localized = Locale.current.localizedString(forLanguageCode: language) {
                return localized
            }
            return language
        }
        return "Audio \(ordinal + 1)"
    }

    /// The RFC 6381 tag for what this rendition actually *contains* — the
    /// source's codec when copying, the bridge's when bridging (never the
    /// source's: a bridged rendition carries EAC3, whatever it started as).
    private var outputCodecString: String? {
        switch route.mode {
        case .streamCopy:
            return MasterPlaylistBuilder.audioCodecString(
                forCodecName: track.codecName,
                profileName: track.profileName
            )
        case .bridge, .boost:
            // Whichever encoder the bridge negotiated — EAC3 where the build
            // has it, AAC otherwise — never assumed.
            return MasterPlaylistBuilder.audioCodecString(
                forCodecName: bridge?.outputCodecName ?? AudioBridge.defaultTargetCodecName
            )
        }
    }

    /// `CHANNELS` — the bridge renegotiates the layout (a 7.1 source can leave
    /// as 5.1), so the encoder is the authority when one is in the path.
    private var outputChannelCount: Int? {
        switch route.mode {
        case .streamCopy:
            return track.channelCount > 0 ? track.channelCount : nil
        case .bridge, .boost:
            return bridge?.outputChannelCount ?? negotiatedChannelCount
        }
    }

    /// Whether the bits this rendition actually serves carry object audio, which
    /// is what earns `CHANNELS="16/JOC"`.
    ///
    /// True only for a **stream-copied** Atmos EAC3 track. The bridge is excluded
    /// on principle rather than by measurement: it decodes to PCM and re-encodes
    /// with an encoder that produces no JOC, so a bridged TrueHD-Atmos source
    /// comes out as plain surround. Declaring otherwise would promise an Atmos
    /// rendition that isn't one.
    private var outputCarriesObjectAudio: Bool {
        switch route.mode {
        case .streamCopy:
            return track.isObjectAudio && track.codecName == "eac3"
        case .bridge, .boost:
            return false
        }
    }
}
