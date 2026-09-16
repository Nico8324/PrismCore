import Foundation

/// The fuzzable surface of every hand-written bitstream parser in this module,
/// as uniform `bytes in → invariants checked` entry points.
///
/// ## Why this exists
///
/// The parsers below read **untrusted media** — a downloaded MKV's `hvcC`, an
/// E-AC-3 packet off any server, a sidecar `.srt` someone found on the internet
/// — and none of them is FFmpeg's code, so none of them is covered by FFmpeg's
/// fuzzing. Each has unit tests pinning the *rules*; what a fixture cannot pin
/// is the absence of a crash, hang, or corrupt-output path on inputs nobody
/// thought to write down. That is a fuzzer's job.
///
/// ## Why it lives inside the module
///
/// Two consumers share this table — the deterministic smoke test that runs in
/// every CI build (`FuzzSmokeTests`), and the coverage-guided libFuzzer
/// executable (`prismcore-fuzz`) — and an executable target cannot
/// `@testable import` in a release build. `package` access gives both of them
/// the same symbols without making anything public, and a host app never pays
/// for it: nothing in the library references this type, so it dead-strips.
///
/// ## The contract of a target
///
/// A target takes arbitrary bytes, calls its parser, and checks the invariants
/// that make a *wrong* answer visible, not just a crashing one. A violated
/// invariant calls `fatalError` — under libFuzzer that is a saved crash input,
/// in the smoke test it is a failed run with the seed printed. Targets must be
/// deterministic and free of I/O: a fuzzer that touches the filesystem
/// measures the filesystem.
package enum FuzzTargets {

    /// Every target, by the name the fuzzer selects it with.
    package static let all: [String: @Sendable ([UInt8]) -> Void] = [
        "eac3-syncframe": { @Sendable in eac3Syncframe($0) },
        "dec3": { @Sendable in dec3($0) },
        "hevc-nalunits": { @Sendable in hevcNALUnits($0) },
        "hvcc-normalize": { @Sendable in hvccNormalize($0) },
        "isobmff-patch": { @Sendable in isobmffPatch($0) },
        "text-subtitles": { @Sendable in textSubtitles($0) },
        "a53-captions": { @Sendable in a53Captions($0) },
    ]

    // MARK: - Targets

    /// The JOC walk over an arbitrary packet. The walk is best-effort by
    /// design, so the only strong claims are "no crash" and "a returned
    /// complexity index is a byte" — `read(8)` can produce nothing else, but
    /// the assertion stays as the tripwire for a future refactor.
    package static func eac3Syncframe(_ bytes: [UInt8]) {
        guard let index = EAC3Syncframe.atmosComplexityIndex(in: bytes) else { return }
        guard (0...255).contains(index) else {
            fatalError("complexity_index_type_a out of byte range: \(index)")
        }
    }

    /// `dec3` payload parse, then the init-segment patch over the same bytes
    /// read as a box tree. The patch invariant is structural: the patched tree
    /// must still locate the box, its payload must be the old payload plus the
    /// two extension bytes, and every ancestor size must have grown by exactly
    /// that delta — a stale length is how a spliced tree stops parsing.
    package static func dec3(_ bytes: [UInt8]) {
        if let config = EAC3Configuration.parse(dec3: bytes) {
            guard (0...6).contains(config.channelCount) else {
                fatalError("channel count out of range: \(config.channelCount)")
            }
            if let index = config.atmosComplexityIndex, !(0...255).contains(index) {
                fatalError("parsed complexity index out of byte range: \(index)")
            }
        }

        let data = Data(bytes)
        guard let before = ISOBMFFPatch.locate("dec3", in: data),
              let patched = EAC3Configuration.patch(initSegment: data, atmosComplexityIndex: 12)
        else { return }
        guard let after = ISOBMFFPatch.locate("dec3", in: patched) else {
            fatalError("dec3 patch produced a tree that no longer locates dec3")
        }
        guard after.payload.count == before.payload.count + 2,
              patched.subdata(in: after.payload).prefix(before.payload.count)
                  == data.subdata(in: before.payload)
        else {
            fatalError("dec3 patch changed bytes other than the appended extension tail")
        }
    }

    /// NAL framing and the rewrite round-trip, at every prefix width. The
    /// keep-all rewrite must report "nothing changed" (`nil`), and a rewrite
    /// that did change something must produce a packet the same walk can frame
    /// again — a rewrite whose own output doesn't parse has spliced garbage.
    package static func hevcNALUnits(_ bytes: [UInt8]) {
        for lengthSize in 1...4 {
            guard let units = HEVCNALUnits.units(in: bytes, lengthSize: lengthSize) else {
                continue
            }
            guard !units.isEmpty else {
                fatalError("units(in:) returned an empty array instead of nil")
            }
            if HEVCNALUnits.rewrite(bytes, lengthSize: lengthSize, transform: { _ in .keep }) != nil {
                fatalError("keep-all rewrite claimed a change (lengthSize \(lengthSize))")
            }

            // The Dolby Vision converter's exact shape: drop enhancement-layer
            // NALs, replace the RPU type.
            //
            // Through the converter's own predicate, deliberately. This used to
            // inline `layerID != 0`, which is not what the converter does and
            // not how a P7 stream carries its enhancement layer (`unspec63` on
            // layer 0) — so the fuzzer claimed to model the converter while
            // never once exercising the drop path that mattered.
            let replacement: [UInt8] = [0x7C, 0x01, 0xAA]
            guard let rewritten = HEVCNALUnits.rewrite(bytes, lengthSize: lengthSize, transform: {
                unit in
                if DolbyVisionRPUConverter.isEnhancementLayer(
                    type: unit.type, layerID: unit.layerID
                ) { return .drop }
                if unit.type == 62 { return .replace(replacement) }
                return .keep
            }) else { continue }
            if !rewritten.isEmpty, HEVCNALUnits.units(in: rewritten, lengthSize: lengthSize) == nil {
                fatalError("rewrite output no longer frames (lengthSize \(lengthSize))")
            }
        }
    }

    /// The closed-caption path end to end: SEI walk, T.35 message loop, and the
    /// 608 terminal that the extracted bytes drive.
    ///
    /// The inputs here are the least trustworthy bytes in the whole engine — a
    /// broadcast recording's video packets, arbitrary and unvalidated, walked
    /// by a parser whose message loop reads its own lengths. The invariants are
    /// about the *cues*, not just survival: a cue that inverts, outstays its
    /// cap, or carries a `-->` is a wrong answer the decoder must not be able
    /// to produce however malformed the bitstream was.
    package static func a53Captions(_ bytes: [UInt8]) {
        let carriages: [(HEVCNALUnits.Framing, HEVCNALUnits.Codec)] = [
            (.annexB, .h264), (.annexB, .hevc), (.lengthPrefixed(4), .h264), (.lengthPrefixed(2), .hevc),
        ]
        for (framing, codec) in carriages {
            let triplets = bytes.withUnsafeBufferPointer {
                A53CaptionData.triplets(in: $0, framing: framing, codec: codec)
            }
            for triplet in triplets where triplet.type > 3 {
                fatalError("cc_type is two bits and cannot exceed 3: \(triplet.type)")
            }

            let reader = ClosedCaptionReader(framing: framing, codec: codec)
            let start = 1.0
            bytes.withUnsafeBufferPointer { reader.ingest($0, presentationSeconds: start) }
            let end = start + 1_000
            for entry in reader.flush(at: end) {
                guard (1...4).contains(entry.channel) else {
                    fatalError("cue attributed to a service that does not exist: CC\(entry.channel)")
                }
                let cue = entry.cue
                guard !cue.text.isEmpty else { fatalError("empty cue emitted") }
                guard cue.end > cue.start else {
                    fatalError("cue does not advance: \(cue.start) → \(cue.end)")
                }
                guard cue.start >= start, cue.end <= end else {
                    fatalError("cue outside the times it was fed: \(cue.start) → \(cue.end)")
                }
                // The open-cue cap is what keeps a caption whose erase never
                // comes from standing for the rest of the film.
                guard cue.end - cue.start <= CEA608ChannelDecoder.maximumCueSeconds + 0.001 else {
                    fatalError("cue outlived the cap: \(cue.end - cue.start)s")
                }
                guard !cue.text.contains("-->"), !cue.text.contains("\n\n") else {
                    fatalError("cue text would break the WebVTT it is written into")
                }
            }
        }
    }

    /// `hvcC` normalization, whose invariant is idempotence: a record the
    /// normalizer rewrote is by definition in form, so normalizing it again
    /// must report "nothing to change". A second pass that finds work means
    /// the first pass's output was not what it claimed. The init-segment patch
    /// must never change the segment's length — a length change would move
    /// every following box, which is exactly what its size guard refuses.
    package static func hvccNormalize(_ bytes: [UInt8]) {
        let data = Data(bytes)
        if let normalized = HVCCNormalizer.normalize(hvcC: data) {
            if HVCCNormalizer.normalize(hvcC: normalized) != nil {
                fatalError("normalize is not idempotent")
            }
        }
        _ = HVCCNormalizer.carriesNoParameterSets(hvcC: data)
        if let patched = HVCCNormalizer.patch(initSegment: data), patched.count != data.count {
            fatalError("patch(initSegment:) changed the segment length")
        }
    }

    /// The box-tree walk and the growing splice. Replacing a located box's
    /// payload must leave a tree in which the same box is found again carrying
    /// exactly the new payload — the walk checks every size field on the way
    /// down, so a stale ancestor length surfaces as a failed re-locate.
    package static func isobmffPatch(_ bytes: [UInt8]) {
        let data = Data(bytes)
        for type in ["hvcC", "dec3"] {
            guard let location = ISOBMFFPatch.locate(type, in: data) else { continue }
            // Grow, shrink, and same-size splices all have to keep the tree honest.
            for newCount in [0, location.payload.count, location.payload.count + 7] {
                let payload = Data(repeating: 0x5A, count: newCount)
                let patched = ISOBMFFPatch.replacePayload(at: location, in: data, with: payload)
                guard let relocated = ISOBMFFPatch.locate(type, in: patched),
                      patched.subdata(in: relocated.payload) == payload
                else {
                    fatalError("\(type) not relocatable after a \(newCount)-byte splice")
                }
            }
        }
    }

    /// The text-subtitle pipeline. The output-side invariant is WebVTT safety
    /// by construction: no `-->` and no blank line may survive `sanitize`,
    /// because either terminates the cue early inside a rendition — the
    /// converter's whole reason to exist.
    package static func textSubtitles(_ bytes: [UInt8]) {
        let data = Data(bytes)
        let playResolution = TextSubtitleConverter.PlayResolution(width: 1920, height: 1080)
        for kind: TextSubtitleConverter.Kind in [.subrip, .ass, .webvtt, .movText] {
            guard let converted = TextSubtitleConverter.convert(data, kind: kind, playResolution: playResolution)
            else { continue }
            assertWebVTTSafe(converted.text, from: "convert(\(kind))")
            assertBalancedTags(converted.text, from: "convert(\(kind))")
            assertPlacementSane(converted.placement, from: "convert(\(kind))")
        }
        _ = TextSubtitleConverter.playResolution(fromASSHeader: data)

        guard let text = String(data: data, encoding: .utf8) else { return }
        assertWebVTTSafe(TextSubtitleConverter.sanitize(text), from: "sanitize")
        for cue in TextSubtitleConverter.cues(fromSRT: text)
            + TextSubtitleConverter.cues(fromWebVTT: text) {
            guard cue.end > cue.start else {
                fatalError("cue with non-positive duration: \(cue.start)…\(cue.end)")
            }
            assertWebVTTSafe(cue.text, from: "cues(from…)")
            assertBalancedTags(cue.text, from: "cues(from…)")
            if let settings = cue.settings { assertSettingsSafe(settings, from: "cues(from…)") }
            assertPlacementSane(cue.placement, from: "cues(from…)")
        }
        // Raw side-data settings take this path in production; the string
        // here stands in for whatever a demuxer attached.
        if let settings = TextCuePlacement.sanitizedWebVTTSettings(text) {
            assertSettingsSafe(settings, from: "sanitizedWebVTTSettings")
            assertPlacementSane(TextCuePlacement(webVTTSettings: settings), from: "sanitizedWebVTTSettings")
        }
        _ = TextCuePlacement(webVTTSettings: text)
        _ = TextSubtitleConverter.parseTimingLineWithSettings(text)
        _ = TextSubtitleConverter.parseTimestamp(text)
    }

    /// A settings string shares the cue's timing line, where a newline ends
    /// the (still payload-less) cue and `-->` starts a second timing.
    private static func assertSettingsSafe(_ settings: String, from source: String) {
        if settings.contains("\n") || settings.contains("\r") || settings.contains("-->") || settings.isEmpty {
            fatalError("\(source) produced unsafe cue settings: \(settings.debugDescription)")
        }
    }

    /// A placement is either absent or a numpad alignment with finite anchor.
    private static func assertPlacementSane(_ placement: TextCuePlacement?, from source: String) {
        guard let placement else { return }
        if !(1...9).contains(placement.alignment) {
            fatalError("\(source) produced alignment \(placement.alignment)")
        }
        if let anchor = placement.anchor, !anchor.x.isFinite || !anchor.y.isFinite {
            fatalError("\(source) produced a non-finite anchor")
        }
        if let settings = placement.webVTTSettings { assertSettingsSafe(settings, from: source) }
    }

    /// The `<b>`/`<i>`/`<u>` tags the override translation emits must nest
    /// and close — an overlapping or open tag is what makes a renderer
    /// style the rest of the cue, or the next one, by mistake.
    private static func assertBalancedTags(_ text: String, from source: String) {
        var stack: [Substring] = []
        var rest = text[...]
        while let open = rest.firstIndex(of: "<") {
            rest = rest[open...]
            guard let close = rest.firstIndex(of: ">") else { return }
            let inner = rest[rest.index(after: open)..<close]
            rest = rest[rest.index(after: close)...]
            // Only the tags the translation writes are checked; a source's
            // own `<i>` (SRT) may legitimately be unbalanced and is passed
            // through as before.
            guard ["b", "i", "u", "/b", "/i", "/u"].contains(String(inner)) else { continue }
            if inner.hasPrefix("/") {
                guard stack.popLast() == inner.dropFirst() else { return } // source-authored tag
            } else {
                stack.append(inner)
            }
        }
    }

    /// Empty output is legal (the caller drops the cue); unsafe output is not.
    private static func assertWebVTTSafe(_ text: String, from source: String) {
        if text.contains("-->") {
            fatalError("\(source) let '-->' through: \(text.debugDescription)")
        }
        if text.contains("\n\n") || text.hasPrefix("\n") || text.hasSuffix("\n") {
            fatalError("\(source) produced a cue-terminating blank line: \(text.debugDescription)")
        }
    }
}
