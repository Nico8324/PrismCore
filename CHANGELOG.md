# Changelog

All notable changes to PrismCore. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org). (Releases before 1.0.0 carried the
usual pre-1.0 caveat: **minor** bumps could break API, **patch** bumps stayed
source-compatible.)

## [Unreleased]

## [2.1.1] — 2026-09-07

Subtitle fixes from #82 and #83.

### Fixed

- **PGS captions end at the clear, not 49 days after they start.** FFmpeg's
  PGS decoder reports every composition with `end_display_time` of
  `UINT32_MAX` — a sentinel for "the clear will say", not a real end.
  Treating it as an end made every cue ~49 days long; the segment writer
  clamped and repeated it, and the clear found nothing pending. The sentinel
  now means open-until-clear. DVD subtitles keep real ends (#82).
- **A lone forced subtitle track stays reachable from the menu.** AVKit never
  lists a `FORCED=YES` rendition; that is correct beside a full same-language
  track, but wrong when the only text track is flagged default+forced (common
  on YTS muxes). Forced is honoured only when a same-language sibling exists
  (#83).

## [2.1.0] — 2026-09-05

Playback observability for hosts: what is resident on disk, how each audio
track is actually delivered, a fixed audio delay, and an opt-in coordinated
HTTP transport — plus the Dolby Vision record rule from #77.

### Added

- `PrismCoreSession.residentRanges` reports completed video intervals on the
  source timestamp axis. `cachedThumbnail(at:maxDimension:)` decodes a local
  snapshot of a resident segment without opening the source or requesting
  production. Images are bounded to 16 MiB / 32 entries; fragments above
  64 MiB return no preview. Publication and retirement share a lock so delayed
  eviction cannot delete a newly reproduced video segment.
- `audioDelivery` and per-track `audioTrackDeliveries` distinguish missing
  audio from unavailable routes and expose bridge packet/frame/sample counts.
  Counts reset on re-anchor. A fully drained bridge that received packets but
  emitted nothing throws `AudioBridgeFailure.producedNoAudio`; priming is not
  diagnosed as failure merely because its input packet count is large.
- `audioDelaySeconds` on session/engine and software-pipeline construction:
  positive delays audio, negative advances it, clamped to +/-2 s (non-finite
  values become zero). Applied at the muxer or renderer boundary; video,
  subtitles and source clocks are unchanged. Fixed for the session: changing
  already-buffered media requires the host to replace its session. Fallback
  sessions preserve the value.
- Opt-in `coordinatedHTTP` for finite HTTP(S) files with Range support. Probe,
  playback and standalone-preview readers share a two-request per-origin
  limit. HTTP 429/503/509 impose a shared quiet period (`Retry-After` or
  exponential backoff), then paced admission; dropped transfers retry within
  a bounded read budget. Buffers are 1 MiB per reader. Redirects are admitted
  at their destination, caller headers do not cross origins, and HTTPS never
  downgrades to HTTP. Size and available entity validators must stay stable.
  Native FFmpeg I/O remains the default. Live streams, servers ignoring Range,
  and nested HLS resources are outside this optional file transport's contract.
- A reproducible binary-frame-clock fixture and Range origin with shared
  bandwidth/first-byte delay. `PRISMCORE_RENDERED_SEEK=1` enables an AVPlayer
  test comparing decoded picture timestamps after forward/backward seeks
  against the item's presentation time, with a two-frame tolerance.

### Fixed (review pass before release)

- A negative `audioDelaySeconds` never writes a packet below the timeline's
  origin: `avoid_negative_ts` is disabled so tfdt can carry absolute time on
  restart, and movenc writes tfdt as an unsigned field — a negative dts would
  wrap. Packets the shift takes below zero (a priming packet included) are
  dropped; a zero or positive delay leaves a source's own timestamps alone.
- `cachedThumbnail` reads the resident segment OUTSIDE the publication lock
  (only the lookup and the opens are serialized with retirement — an open
  descriptor survives an unlink), so a 64 MiB preview no longer stalls the
  producer's next segment write.
- `HLSRemuxer.run` no longer opens an extra probe just to get coordinated HTTP
  when no `ProbedSource` was handed over; its own open installs the reader.

### Fixed

- **A Dolby Vision record no longer survives onto a sample entry the manifest
  doesn't claim as DV.** `shouldStripDolbyVisionRecord` let a DV-capable
  display keep whatever record `avcodec_parameters_copy` brought across,
  unconditionally. For a Profile 7 source that is **not** being converted — no
  libdovi in the host's build, an `hvcC` we couldn't read, no RPUs — that meant
  serving an `hvc1` entry carrying a `dvcC` that announces a dual-layer stream
  Apple has no decoder for, while the master printed no DV claim at all
  (`dolbyVisionBrand` returns nil for 7). A sample entry that claims what the
  manifest doesn't is the exact mismatch the DV-less fallback tier was built to
  avoid, and the failure it produces is the bad kind: the item goes
  `.readyToPlay` and then shows a black picture with the audio running.

  The rule is now named once, on the configuration itself
  (`DolbyVisionConfiguration.isPresentableAsDolbyVision`): profile 5, and
  profile 8 with an HDR10 or HLG base. Everything else — dual-layer 7, 8.2's
  Rec.709 base, any profile we don't recognise — is stripped on **any** display,
  so the entry and the manifest agree. A converted P7 is declared 8.1 by the
  time it reaches this rule and keeps its record, so the conversion is
  untouched.

### Validation scope

Synthetic macOS tests cover output MP4 timestamps (muxed and alternate audio),
software enqueue timestamps, cache retirement, offline previews, HTTP refusal
and interruption, and rendered seeks. These are not device measurements of
Atmos, Dolby Vision, CDN throughput, or HDMI lip-sync.

## [2.0.2] — 2026-09-02

Follow-up to 2.0.1, from a review pass 2.0.1 itself did not get.

### Dolby Vision

- **The conversion stats can no longer claim work that was thrown away.**
  `dispose` counted converted RPUs and dropped enhancement-layer NALs during
  the disposition walk — which finishes *before* `HEVCNALUnits.rewrite` asks for
  an output buffer. If the packet did not frame, or the allocation failed, the
  rewrite was abandoned and the demuxer's ORIGINAL bytes were emitted: an
  enhancement layer and an unconverted Profile 7 RPU, inside a stream declared
  single-layer 8.1 — the same mismatch that made a P7 title play black, on a
  rarer path. The tallies said otherwise. They are now committed only once the
  rewrite has landed, and a new `staleUnconvertedPackets` counts the packets
  that went out stale; anything there makes `isClean` false.
- `failedRPUs`'s documentation still said refused RPUs are "left in the stream
  unconverted". They have been dropped since 2.0.1.
- **The fuzz target claimed to model the converter and did not.** It inlined
  `layerID != 0`, so it never exercised the drop path that actually matters —
  which is part of why the `unspec63` bug survived a fuzzer. It goes through
  `DolbyVisionRPUConverter.isEnhancementLayer` now, as does the pointer-rewrite
  test, which built a layer-1 unit and called it "the P7 shape".

### Known limitation

A refused RPU is dropped, which degrades that frame to its clean HDR10 base —
but the published `dvvC` still says `rpu_present = 1` and the master still
advertises Dolby Vision, so the declaration outlives the metadata it describes.
Making a refusal fatal (and re-serving with DV signalling removed) is the
correct answer and is a behavioural change, so it is not in a patch release.
`failedRPUs` and `isClean` are how a host sees it in the meantime.

## [2.0.1] — 2026-09-02

### Dolby Vision

- **A Profile 7 title no longer plays as a black picture with sound.** The
  enhancement layer is `unspec63` — NAL **type** 63 — and it shares
  `nuh_layer_id == 0` with the base layer and with the RPU. The converter
  dropped it by `layerID != 0`, a test that therefore never matched: every NAL
  in a real Profile 7 stream is layer 0. So the enhancement layer rode straight
  through into an fMP4 whose `dvvC` declares `el_present = 0`, and AVPlayer was
  handed a stream *declared* single-layer 8.1 that still *contained* the
  enhancement layer. The base layer decoded — which is why the audio played and
  why no decode error was ever reported — and the Dolby Vision path did not.
  With Dolby Vision switched off nothing claims DV, AVPlayer ignores an unknown
  NAL type, and the same file played: exactly the shape the report had.

  `droppedEnhancementLayerNALs` reading zero on a real disc was the symptom, not
  the expected result. It had been explained away in `RealMediaVerificationTests`
  as Matroska keeping the EL in block additions the demuxer never hands over;
  that note was wrong and is now an assertion, so the drop path cannot quietly
  stop matching again. The predicate moved to
  `DolbyVisionRPUConverter.isEnhancementLayer(type:layerID:)` — pure, and
  provable without libdovi or a disc, because the whole bug lived in it.

## [2.0.0] — 2026-08-27

A major bump, not a minor one, because the host-visible contract moved: `start()` returns on video-only readiness (renditions may still be pending), dialogue-boost renditions are produced lazily on first fetch, retention and producer lead now apply in the sequential shape too, and the software pipeline gained `load(probed:)` / `openSoftware(probed:)`. Everything below landed in PRs #68, #69, #71, #73, #75 (umbrella #65).

### Software path

- **One open per software playback, not three.** `SoftwarePlaybackPipeline.load(probed:)`
  adopts the context `SourceProbe.open` already holds — the same handover
  `PrismCoreSession(probed:)` does, for the same reason (the *context* carries
  state the decoders need, not just the probe's conclusions). The probe leaves
  the read position mid-file, so the adopting load rewinds and flushes before
  the first packet. `PrismCoreEngine.open(url:)` now routes the software case
  through it, and `PrismCoreEngine.openSoftware(probed:)` is the entry for a
  host that probed and decided itself. `load(url:)` stays.
- **A starving server can no longer hang `load()`.** The URL open goes through
  `ReadInterruptGuard.makeContext()` under `SourceOpenTuning` (probesize /
  analyzeduration / reconnect) and is armed for the probe budget, like every
  other open site since 1.8.2; `stop()` trips the guard *before* queueing
  behind the feed loop, so a `stop()` against a blocked read returns.
- **Start-up and seek latency.** `thread_count = 1` when the VideoToolbox
  hwaccel is attached (frame threads only add their count in latency there;
  the CPU reopen keeps 0). `load(url:/probed:, startAt:)` seeks *before* the
  priming decode instead of decoding the head and throwing it away. `load`
  returns as soon as the first frame is anchored and enqueued; the rest of the
  queue depth fills on the renderers' own pull.
- **Seeks land on the target.** After the keyframe seek the pipeline decodes
  and discards video before the target and audio ending at or before it, up
  to `Pacing.maxSeekDiscardSeconds` (2 s) of content — beyond that it shows
  from the keyframe as before. Seeks queued together coalesce: superseded
  ones bail before flushing. `avformat_seek_file` throughout (AGENTS.md).
- **Renderer failure recovery.** The display layer's `status`/`error` and
  `requiresFlushToResumeDecoding`, and the audio renderer's `status`, are
  observed; on failure the pipeline flushes, flushes the decoders, re-seeks to
  the clock and re-primes (three tries in ten seconds, then `.failed` with
  `Failure.rendererFailed`). Fixes the black-after-background shape.
- **Memory.** The pending video queue is capped in *bytes*
  (`Pacing.maxPendingVideoBytes`, 64 MB) — a frame count let 4K P010 chase
  audio into hundreds of megabytes. A `DispatchSource` memory-pressure handler
  shrinks the depth and flushes the CPU path's pixel pool. swscale runs
  slice-threaded (`sws_alloc_context` + `threads`); the audio resampler writes
  straight into the `CMBlockBuffer` instead of scratch + malloc + copy.
- **`.ended` means played out.** It fires from a synchronizer boundary
  observer at the last presentation end (PTS + duration), not on the last
  enqueue — which cut off roughly the renderer's queue of audio for hosts that
  tear down on `.ended`.

  Not measured: these are latency/memory claims from the audit (#65) verified
  by tests on synthetic fixtures, not yet by a device run over HTTP.
### Changed

- **`start()` returns after a ~2 s first segment instead of a ~6 s one.**
  The first cut is where everything a player needs is minted: under
  `delay_moov` the init segment does not exist until it, and the readiness
  gate waits for it. With a 6 s target that meant demuxing and muxing six
  seconds of source (plus the GOP overshoot to the next keyframe) — for the
  video AND every audio rendition — before the host got a URL at all. The
  first planned entry now targets `SegmentPlan.defaultFirstSegmentSeconds`
  (2 s; on the common 2 s keyframe cadence the cut lands on the very next
  keyframe), every later entry keeps the 6 s target, and the sequential
  EVENT path uses the same shorter first stride. Mixed durations are legal:
  `TARGETDURATION` was already the ceiling of the longest entry. Segment
  names, URLs and the plan-index ↔ segment-index mapping are unchanged; only
  the head's duration moved. A tunable (`firstSegmentSeconds` on
  `HLSRemuxer`), clamped so it can only shorten the head.

  Measured (`start()` wall time, 7 runs each, same 3-minute 1080p 12 Mbps
  H.264+AAC MKV with a 2 s keyframe cadence served over a Range-capable
  loopback HTTP server, plan basis `keyframeIndex` on both): main @1.10.1
  42–62 ms (median 55); this branch 40–47 ms (median 41). Loopback makes the
  source read nearly free, so the absolute gap is small there; what changed
  is the amount of source demuxed before the URL comes back — one 2 s GOP
  (~3 MB at this bitrate) instead of three (~9 MB), and over a real network
  that difference scales with bandwidth, which is why the number that
  matters is the host's own TTFF log on a device rather than this one.

- **Readiness no longer waits for a segment from every rendition.** The gate
  used to require an `EXTINF` and an init segment from every playlist the
  master references. It now requires the video variant playable, and from
  each rendition only its playlist and the init its `EXT-X-MAP` names: an
  unproduced rendition *segment* goes through the loopback's demand seam
  (`PlanSegmentProvider.handleMiss` answers `.pending` and serves it when
  the producer lands it — covered by a test now). The init stays required
  (review finding): a declared track that never delivers a packet never
  mints one, and handing out a master whose default rendition can never
  play would move that failure from `start()` to AVPlayer. Honest note: in
  the planned shape the renditions cut at the same boundary as the video,
  microseconds later, so the win here is small; most of it is the shorter
  first segment.

- **A planned rendition boundary with no audio keeps its index.** Found by
  review of the shorter head: a rendition whose audio starts after a
  boundary (a late-starting track, or an interleave lagging a 2 s head) had
  its empty cut folded into the next one — in the planned shape that wrote
  the first real audio as `seg00000.m4s` and shifted every later rendition
  segment against the video, silently. The slot now stays empty and the
  writer declares it to the demand coordinator, so a fetch of it is an
  immediate 404 (AVPlayer skips a failed media segment) instead of a 15 s
  pending wait for a file that is not coming. The sequential EVENT shape is
  unchanged (its playlist is appended as segments land, so folding is
  correct there).

- **Startup and demand waits are wakes, not polls.** The session's readiness
  gate and every pending serve in `PlanSegmentProvider` slept 10 ms between
  disk checks. They now sleep on `ProductionSignal`, which the producer
  broadcasts after each write (and on thread exit, so a producer that dies
  in its first millisecond wakes the gate instead of being waited out). A
  generation counter enforces the wake-before-wait rule: snapshot, check the
  disk, wait only if nothing has landed since — so a broadcast racing the
  check cannot be lost. A coarse 200–250 ms poll stays as the backstop for a
  landing nobody announced; it is no longer the mechanism.

- **The producer thread starts before the loopback listener binds.** The
  remux's first act is a source open (a network round trip on a remote
  server); the bind needs nothing from it and now overlaps it. A listener
  that fails to bind cancels the producer and joins it before `start()`
  rethrows, so no orphan keeps writing into a work directory nobody serves.

### Tests

- `SegmentPlanTests`: short head then full-target entries, clamping, uniform
  fallback; the real-fixture expectation follows the new head.
- `FirstSegmentReadinessTests` (new): the gate opens on the video variant
  with the audio rendition still pending; a pending rendition init/segment
  resolves on the broadcast (well inside the backstop); the signal's
  lost-wake and backstop semantics; a session end to end serving
  `[2, 6, 6, 6, 6, 4]` and the rendition's head segment.
- `SubtitleRenditionTests`: the straddling-cue assertions moved from the 6 s
  cut to the 2 s one — same behaviour, new boundary.

### Changed — lazy dialogue-boost renditions (#65 package B)

- **Dialogue-boost renditions are produced on demand, not from the first
  packet.** The host requests `[.medium, .high]` on every eligible session,
  and each level was a full `AudioBridge` — decoder, `pan` filter,
  resampler, EAC3 encoder, FIFO — opened before the first segment and fed
  a clone of every default-track packet for the length of the film, whether
  or not anyone ever opened Enhance Dialogue. They are now declared exactly
  as before (same `EXT-X-MEDIA` lines, `CHANNELS` from a bridge that is
  built once for the negotiated layout and released again, complete
  planned VOD playlists) but nothing else exists — no bridge, no muxer, no
  init — until an init or segment fetch lands under the rendition's
  directory. That fetch arms it (`HLSRemuxer.noteAudioDemand`, through
  `PlanSegmentProvider.audioDemand` — the same seam OCR subtitles use) and
  **forces** a re-anchor at the demanded segment even inside the
  forward-wait window (`DemandCoordinator.requestProduction(force:)`), so
  the rendition joins at a plan boundary with a whole first segment and its
  init is minted by that cut. Playlist fetches never arm: AVPlayer prefetches
  rendition playlists it never plays.

  Found by review while adding the forced re-anchor, and fixed for every
  re-anchor: the packet already in hand when the copy loop re-anchors was
  read at the OLD position and was still processed afterwards. A keyframe
  past the anchor (a backward seek from further on) satisfied the
  "anchor keyframe arrived" check and opened the segment on a picture from
  the wrong place, followed by lower timestamps from the seek target. The
  loop now discards it and reads on from the anchor.

  Two consequences worth knowing. The readiness gate no longer waits for a
  lazy rendition's init (`readyPlaylistName(in:lazyRenditions:)`) — it is
  not coming until someone selects the rendition, and AVPlayer fetches an
  init only for the selection. And a dormant boundary does NOT mark its
  slot unproducible: the arming fetch is what reproduces exactly those
  slots, and a 404 mark would race its pending wait.

  Lazy only in the planned (demand-driven) shape. The sequential EVENT
  shape's provider has no demand seam (a miss there is a 404) and no seek to
  offer, so it keeps producing boost renditions eagerly — today's cost and
  today's behaviour, on the sources that already could not be planned.

  Not measured: the stock MPVKit build on this machine has no EAC3 encoder,
  so no bridge can be built here at all. What is removed is structural — two
  decode→filter→encode chains per session, from before the first segment to
  EOF — and the host's own CPU sampling on a device with its encoder-capable
  build is the number that will say how much that was.

### Tests — package B

- `LazyDialogueBoostTests` (new): forced anchor requests bypass the window
  and the "already there" check; the gate skips a lazy rendition's init but
  still requires its playlist; a lazy `AudioRenditionWriter` opens nothing,
  drops packets and passes boundaries unmarked until armed, then joins at a
  re-anchor with init + whole segment; the provider seam arms on
  init/segment fetches only and forces the re-anchor (init fetch → newest
  demanded index); a session with `[.medium, .high]` over a 5.1 default
  track (`h264_ac3_51_20s.mkv`, new synthetic fixture) produces the whole
  default rendition and NOTHING under the boost directories until a fetch,
  then serves the boost segment with an EAC3 init and the default rendition
  untouched — on a build with the encoder; on stock MPVKit it pins the
  graceful skip.

### Changed — fewer source round trips (#65 package C)

- **An adopted probe context is rewound once, not twice.** The remuxer used
  to seek an adopted context back to 0 (and flush) immediately, then hand it
  to `SegmentPlan.build`, whose Cues-loading nudge ends with its own seek to
  0. Over HTTP every seek is a Range request. The rewind is now deferred:
  `SegmentPlan.buildReportingPosition` says whether it passed through the
  head, and the remuxer rewinds itself only when it did not (cached map,
  index already loaded, no plan). Measured against a Range-capable loopback
  server (one `SourceProbe.open` + `start()` over `h264_aac_30s.mkv`, 3 runs
  each, identical every run): **5 requests → 4**.

- **No index-load nudge when the index is already loaded.** A plain MP4's
  index comes from `stss`/`stts` in the `moov` the open already read, so the
  tail seek loaded nothing and cost two Range requests.
  `SegmentPlan.indexIsLoadedAtOpen` skips the nudge when the stream's
  keyframe entries already reach into the last target-length of the file —
  by coverage, not by demuxer name (review finding: a fragmented MP4's
  `moov` describes its first fragment only, and open-time entries from a
  Cues-less Matroska cover the first cluster only; neither can pass). Not
  measured (no MP4 fixture; the MKV fixture's Cues are not parsed at open,
  so it still nudges).

- **A cancelled play persists its keyframe harvest as a PARTIAL map.** The
  harvest of a source that could not be planned (no usable index) was stored
  only at EOF — a film stopped at minute 40 learned nothing, and the next
  play paid the sequential shape again. `KeyframeIndexCache.Entry` now
  carries `complete` and `coveredThroughPTS`; a cancelled run stores what it
  saw, and `SegmentPlan.keyframePlan(coveredThroughPTS:)` trusts the map as
  a contiguous prefix — planned exactly on keyframes up to the covered end,
  then continued on the 6 s uniform stride to the container's end. Tail
  boundaries are time targets the producer cuts at the next keyframe
  at-or-after, with a stride no shorter than the largest gap the prefix
  showed (review finding: a 6 s stride over 10 s GOPs would resolve two
  targets to one keyframe and drift the timeline cumulatively), so a seek
  INTO the un-watched tail lands up to one GOP late and the error does not
  accumulate as long as the tail's cadence is no coarser than the prefix's
  (an inference about an unobserved tail, not a bound — known limitation,
  closed by the harvest on the next contiguous play);
  in exchange the watched prefix (where the resume point is) gets a
  seekable VOD on a source that had none. A session planned on a partial
  map keeps harvesting to extend the prefix — only while its run started
  inside the covered end (a seek past it would leave a hole the gap witness
  must never see) — and flips the entry complete when such a run reaches
  EOF. A partial entry never replaces a complete or longer one; pre-1.11
  sidecars decode as complete.

- **`SourceProbe.openDetached`** — `open` on a one-shot dedicated thread,
  handed back through a continuation. `open` blocks on the transport for up
  to its 10 s budget, and a host calling it from `async` code parks a
  cooperative-pool thread for that long; several at once (a row of episodes,
  a fallback racing a transcode) can stall every other `await` in the
  process. Aether's call site adopts it in its own PR.

- **Tried and not shipped: `multiple_requests=1` (HTTP keep-alive).**
  Measured on the same setup: 4 requests on 4 connections without it;
  5–6 requests on 2–3 connections with it — the socket was reused, but a
  duplicated Range request appeared in two runs of three, so the round trips
  did not go down, and keep-alive semantics against Plex/Jellyfin/Emby were
  an untested risk for no measured gain. Recorded in `SourceOpenTuning`.

### Tests — package C

- `KeyframeIndexCacheTests`: a run cancelled before any keyframe still
  persists nothing; a run cancelled after segment 1 (deterministic through
  the new `HLSRemuxer.onSegmentLanded` seam) stores a partial map that the
  next play plans on, tail segment producible on demand; partial-store rules
  and legacy-sidecar decoding.
- `SegmentPlanTests`: partial map → keyframe prefix + uniform tail, stray
  keyframes past the covered end ignored, coverage witness still applies.
- `ProbedSourceReuseTests`: an adopted context pushed to 20 s produces a
  head segment with `tfdt` 0 on both paths (plan seeks / cached map, no
  seek); `openDetached` matches `open`'s verdict and throws for a missing
  file.

### Changed — seek & steady state (#65 package F)

- **A re-anchor keeps the audio bridge.** Every demand-driven seek tore down
  each bridged rendition's `AudioBridge` — decoder, encoder, resampler,
  filter graph, FIFO, frame allocations — and opened a new one, per
  rendition, per seek. `AudioBridge.reset()` now flushes the decoder,
  resets the FIFO and chunker, drops the resampler's delay line and the
  boost graph (both rebuild on the next frame, as for a format change) and
  re-anchors the clock; the contexts live on. The muxer is still rebuilt
  (`frag_discont` needs a fresh one for the tfdt), the directory is created
  once. The encoder is not flushed: every `send_frame` is drained on the
  spot, so it holds nothing. The one bridge that IS rebuilt is a drained
  one — after EOF both codec contexts are in their terminal state, and an
  EAC3 encoder cannot be revived from it (review finding: a re-anchor after
  EOF would otherwise reproduce silent segments).

- **Scrub bursts coalesce.** While a re-anchor is in flight (its first
  segment not yet landed), an anchor request younger than 150 ms
  (`DemandCoordinator.anchorDebounce`) is held rather than acted on — the
  newest still wins, it is what the burst settles on; a scrub bar used to
  tear the muxers down once per fetch it emitted. A forced request (a lazy
  rendition joining) is never held, and a parked producer re-checks when
  the debounce comes due, not after its 1 s backstop.

- **A discontinuous request re-anchors even inside the forward-wait
  window.** AVPlayer's read-ahead asks for N after N-1 (the variant and each
  rendition of one index arrive together, so ±1 of the previous fetch is
  continuous); a request that jumps further is a seek however close it
  lands, and waiting for serial production to reach it cost up to two
  segments of silence.

- **Producer lead is 30 s of content, not ten segments**
  (`producerLeadSeconds`, from the plan's start times; the nominal stride
  where there is no plan). Segments vary — a 2 s head, keyframe-stretched
  entries — and the buffer AVPlayer cares about is time. **The sequential
  shape now parks on the same cap and keeps a retention budget too**: a
  fast source demuxed and wrote the whole film to the device while the
  viewer was on minute two. Eviction there never reaches the playhead or
  anything ahead of it; behind it, an evicted EVENT segment is NOT
  reproducible (no plan to re-anchor on), so a backward seek to one is a
  404 AVPlayer treats as a failed segment — accepted against a 50 GB work
  directory, and documented in `HLSRemuxer`. The cost of the cap: a
  sequential keyframe harvest completes only when the viewer reaches the
  end (the partial harvest from package C covers the rest).

- **Retention accounts what the cuts report, not what `stat` says.**
  `AudioRenditionWriter.cut` returns the bytes it wrote; a
  `attributesOfItem` per rendition per cut is gone from the cut path, and
  the unlinks moved to a serial utility-QoS queue (the window in which a
  stale unlink could hit a re-produced file is the queue's latency against
  a demuxer seek — a fetch that finds the stale file serves the same bytes).

- **Serve path.** Header and body go out as two `send`s (NWConnection
  serialises them; the multi-megabyte append of the body into the header
  `Data` is gone). Providers read with `.mappedIfSafe` — the pages come in
  as the send touches them, and a mapping outlives eviction's unlink.
  `FMP4SegmentWriter`'s sink reserves the previous segment's size at each
  cut. `Cache-Control: max-age=86400, immutable` on init, media and WebVTT
  segments (all immutable for the life of their URL — the init is
  first-write-wins, a re-produced segment is the same bytes); playlists
  stay `no-store`. Partial-segment streaming is NOT attempted: it needs the
  `.part` contract (LL-HLS) and is a follow-up.

- **Hot loop.** `HEVCNALUnits.units(in:)`/`rewrite` walk an
  `UnsafeBufferPointer<UInt8>` — the packet's own buffer — with `[UInt8]`
  overloads kept for tests and the fuzzer; a changed P7 packet is written
  ONCE into an `av_buffer_alloc`ed buffer (padded) that replaces the
  packet's `AVBufferRef` (`rewritePayload`), instead of copy-in +
  `make_writable` + grow + memcpy. The parameter-set harvest is gated on
  `AV_PKT_FLAG_KEY` (a non-keyframe cost the walk to find nothing).
  `EAC3Syncframe.atmosComplexityIndex` reads a pointer. Output bytes are
  unchanged: the pointer and array shapes are asserted byte-identical, and
  the real-media P7→8.1 verification (`RealMediaVerificationTests`,
  `PRISMCORE_MEDIA`) is the standing check.

- **EVENT playlist text is append-only**: the entries block is appended
  per segment and only the header (a running TARGETDURATION maximum) is
  recomputed per write; the file is still rewritten atomically — serving
  from memory would need the provider to know about it and was not worth
  the seam for a per-segment write of a few KB.

  Measured (cold seek to an unproduced segment 25, `audio0/` then variant
  fetch, over a Range-capable loopback HTTP server, 3-minute 300 kbps
  H.264 + stereo AC3 MKV, 7 runs): before F 6–11 ms (median 7), after F
  6–13 ms (median 9) — **no change, as expected**: that fixture's rendition
  is stream-copied, and the bridge keep-alive that F1 is about cannot run
  on this machine's stock MPVKit build (no EAC3 encoder). The number that
  will show it is a scrub on a TrueHD/DTS title on a device with Aether's
  build.

### Tests — package F

- `SeekSteadyStateTests` (new): scrub burst coalesces (held under the
  debounce, newest wins, forced never held, released once the first segment
  lands); a discontinuous request inside the window re-anchors while
  read-ahead waits; the lead cap is seconds from the plan (24 s of 2 s
  segments sails, 36 s of 12 s segments parks); cache headers per type and
  byte/length-identical two-send responses (GET and HEAD); the pointer NAL
  rewrite is byte-identical to the array shape and allocates nothing when
  nothing changes; `BridgeClock`/`FrameChunker` reset; the append-only
  EVENT playlist text is what a rebuild wrote.
- `DemandDrivenTests`: lead-cap cases expressed through the seconds cap;
  the last-wins case lands its first segment before the next request (the
  debounce would otherwise hold it — which is the point).

## [1.10.1] — 2026-08-22

### Fixed

- **A forced subtitle track no longer disappears from the picker.** Two
  renditions in one group may not share a `NAME` (RFC 8216 §4.3.4.1), and
  AVFoundation enforces that by keeping the first and **silently discarding**
  the rest: no error, no log, the option simply is not in the legible
  `AVMediaSelectionGroup`. A rendition's name falls back to the container's
  title, then the language tag, and a forced track is usually untitled — so
  the ordinary disc-rip shape (`eng` full plus `eng` forced) produced two
  renditions both named `eng`, and the forced one lost. Reported from the
  field as "only the full SRT shows up".

  Nothing looked wrong from the playlist: both `EXT-X-MEDIA` lines were
  emitted, `FORCED=YES` and all. Names are now made unique within the group,
  in stream order, so the loss cannot recur — and the regression test asks
  *AVFoundation* what it parsed rather than asserting over the text, because
  a text assertion passes on the broken master.

  The disambiguator is a bare ordinal (`eng`, `eng 2`) rather than something
  descriptive: AVFoundation already appends "Forced" to the display name of a
  `FORCED=YES` rendition, so naming one "English (Forced)" reads back in the
  menu as "English (Forced) Forced".

## [1.10.0] — 2026-08-22

### Added

- **`FFmpegBuild` — which FFmpeg answered, and whether it is the one we
  compiled against.** Two questions that have both cost time, and neither of
  which the engine could answer for a host until now.

  The first is identity. Half of what this engine decides is a question about
  the *build* rather than the media — whether `eac3` was compiled in decides
  whether a TrueHD track bridges or evicts the source to the software path, and
  stock MPVKit ships the E-AC-3 decoders only — so "the audio track is missing"
  is unreproducible until you know which build was asked. `FFmpegBuild.summary`
  is one paste-able block: FFmpeg's own version string, every linked library,
  and the capability answers that change what the engine does with a source
  (`eac3` encoder, AV1 decoder and this device's AV1 hardware, dialogue boost,
  the GPU deinterlacer). Capabilities are asked of libav* rather than read out
  of the configure line, because a `--enable-encoder=eac3` that failed to take
  is precisely the case worth catching; `FFmpegBuild.configuration` carries the
  configure line itself for the bug report.

  The second is ABI. PrismCore compiles against MPVKit's headers, but a host
  may override the package with its own fork of the same identity, so the
  libraries that answer are not necessarily the ones the headers described.
  A **major** apart is not cosmetic: libav* bumps major exactly when a public
  struct's layout changes, and `AVStream`, `AVCodecParameters` and `AVFrame`
  are read field by field on every packet here — a silent drift is wrong pixels
  and wrong timestamps with no error to point at. `isABIMatched` compares each
  library's runtime version against the headers this build saw; minor and micro
  drift is expected and ignored. Loud, not fatal: the engine cannot know whether
  the drift touches anything this source needs, so it reports and continues.
## [1.9.0] — 2026-08-22

### Added

- **Dialogue Boost renditions** — `PrismCoreSession(url:…, dialogueBoost:
  [.medium, .high])` derives extra audio renditions from the default track:
  decoded, centre channel favoured (the bed attenuated −6 dB / −12 dB — never
  the centre lifted, which would clip on the loud dialogue the feature exists
  to rescue), re-encoded to EAC3 through the existing bridge chain with a
  `pan` filter graph in the middle (`DialogueBoostFilter`). The base track
  stays bit-for-bit untouched, Atmos included.

  Why in the engine at all: Aether's tap-based Enhance Dialogue
  (Aether #1985/#1986) is silent on the PrismCore route, and not fixably so —
  AVFoundation ignores `AVAudioMix`, and with it every
  `MTAudioProcessingTap`, on HLS items, which is exactly what this engine
  serves. The only place the dialogue can be lifted is before the mux.

  The renditions are declared with
  `CHARACTERISTICS="public.accessibility.enhances-speech-intelligibility"`,
  so a host finds them with
  `option.hasMediaCharacteristic(.enhancesSpeechIntelligibility)` and flips
  levels via `AVMediaSelection` — no name parsing;
  `session.dialogueBoostRenditions` reports the levels and exact `NAME`s the
  served master actually declares. Best-effort by design: levels are skipped
  (never fail the session) when the build lacks the `eac3` encoder or the
  `pan` filter (`PrismCoreSession.isDialogueBoostAvailable`), or when the
  default track has no centre channel — plain stereo has no channel that *is*
  the dialogue; separating speech there needs FFmpeg's `dialoguenhance`,
  which no current MPVKit build compiles (verified by symbol, not configure
  output). Derived from the default track only, one decode→filter→encode
  chain per level, opt-in for exactly that cost.

## [1.8.4] — 2026-08-17

### Fixed

- **A mangled tag can no longer smuggle `-->` into a WebVTT cue.** The
  sanitizer's tag scanner validated only the *name prefix* of a candidate tag
  and emitted the rest verbatim — so `<i-->` (a typo'd italic close, the kind
  of thing real SRT files carry) passed as a legal `<i…>` tag whose inner `--`
  composed `-->` with the closing bracket. `-->` may never appear in a cue
  payload: it reads as a timing arrow and ends the cue early. A tag whose
  inner ends in `--` is now rejected, which routes the `<` to `&lt;` and the
  arrow to the existing `--&gt;` neutralizer. Found by the new fuzz harness
  within its first minute of mutation (`hunt text-subtitles`).

### Added

- **A fuzz harness for the hand-written bitstream parsers** — the JOC
  syncframe walk, `dec3` parse + patch, HEVC NAL framing/rewrite, `hvcC`
  normalization, the ISO-BMFF box splice, and the text-subtitle pipeline. All
  of them read untrusted media, and none of them is FFmpeg's code, so none is
  covered by FFmpeg's fuzzing. Three layers, one target table
  (`FuzzTargets`, with invariants beyond "no crash": rewrite round-trips,
  normalize idempotence, splice re-locatability, WebVTT safety):
  - `FuzzSmokeTests` runs in every CI build — a few thousand deterministic
    mutations of known-valid seeds per parser, sub-second total, every
    failure reproducible by construction;
  - `prismcore-fuzz hunt` mutates for as long as you give it (found the
    `-->` escape above in under a minute);
  - `prismcore-fuzz run` replays saved crash inputs, and a libFuzzer build
    shape exists for coverage-guided runs on a swift.org toolchain — Xcode's
    toolchain ships no fuzzer runtime (see AGENTS.md "Fuzzing").

- **#52's file-URL question is measured, and the answer is no.** An
  `AVPlayerItem` pointed at a *completed* session's `file://` master — or at
  the media playlist directly — never leaves `.unknown`: no `.failed`, no
  `error`, no error log, evaluation simply never starts (macOS 26 beta). The
  hoped-for no-listener mode for sandboxed hosts is therefore not designable
  today, and `LoopbackHTTPServer` stays load-bearing even for fully produced
  output. `FileHLSPlaybackTests` pins the fact and is written to fail loudly
  the day an OS starts evaluating file-URL HLS — that failure would mean
  reopening #52, not a regression.

## [1.8.3] — 2026-08-14

### Fixed

- **The software path's `durationSeconds` is knowledge, not a constant**
  (#58). It was read once, right after `avformat_find_stream_info`, and a
  container that withheld its duration at that moment — a Matroska written to
  a pipe carries none, and libavformat does not estimate one for it — left
  the host without a timeline for the whole session. While the answer is
  still `nil`, the demuxer now re-checks the context's duration as packets go
  by, and at EOF settles it from the furthest packet end it has seen — the
  one moment "no duration" stops being an honest answer for a finite file.
  Live ingests keep their `nil`.

  The property's doc comment used to promise the opposite ("wants this once,
  not a stream to observe"); it now says to re-read alongside the position,
  which Aether's software route already does. The other two shapes in #58
  were deliberately not taken: a bitrate-derived estimate can be *wrong*,
  which is worse for a seek bar than absent, and a change callback adds host
  API that no host currently needs.

## [1.8.2] — 2026-08-14

### Fixed

- **A probe answers within a budget, or it answers with an error.** A server
  that accepts the connection and then starves the reads (busy transcoding, a
  sleeping disk) left the host with neither a verdict nor an error — an
  Apple TV field log from 2026-08-14 shows five play attempts over four
  minutes with no line from the engine at all, every one blocked inside
  `avformat_open_input`. The probe's `ReadInterruptGuard` (installed at open
  since 1.3.1, but resting disarmed) is now armed across the whole probe —
  open, stream analysis, interlace verification — with a 10 s budget
  (`SourceOpenTuning.probeBudget`, overridable per call). On expiry the probe
  throws, which is what lets the host fall back to the server stream instead
  of silence. The remuxer's fallback open is bounded the same way.

  Two traps the implementation records: `avformat_find_stream_info`
  *swallows* aborted reads and returns success with half-filled parameters
  (the expiry has to be checked on the clock, not the return code — a
  half-analysed context handed onward is 1.1.2's muxing failure wearing a
  verdict), and a budget that expires during the interlace verification
  degrades gracefully but latches `AVERROR_EXIT` in the `AVIOContext`, which
  is cleared so the adopting producer's first read isn't the one that pays.

### Added

- **`ProbedSource.timing`** — where the probe's time went (`open`,
  `streamInfo`, `describe`), for the host's log line or telemetry. Exists
  because a 5.7 s probe on a device and a 135 ms probe on the bench were the
  same code, and without the phases there is nothing to argue about but
  intuition.

## [1.8.1] — 2026-08-14

### Fixed

- **The master-rejection fallback's DV-less tier can now actually win.**
  Dropping the manifest's Dolby Vision claim was only half of dropping Dolby
  Vision: `avcodec_parameters_copy` carries the source's
  `AV_PKT_DATA_DOVI_CONF` across, movenc writes it into the sample entry as a
  `dvvC` box, and a `hvc1` entry carrying a `dvvC` is refused by AVPlayer's
  compatibility gate **on its own** — no `SUPPLEMENTAL-CODECS` attribute
  required. So the tier that exists to retry without the claim re-served the
  exact byte that caused the refusal, and could never succeed for a Dolby
  Vision source. It was not merely useless: a tier is a whole new session, and
  over a network that means reopening the source, reprobing it and producing
  its first segments again. In a host's field log (2026-08-14, HEVC/DV episode
  over a WAN Plex server) the doomed tier cost 6.4 s of a 21 s time-to-picture,
  and every play of that title paid it before the muxed tier played.

  A display that cannot present Dolby Vision is now served no DV record at all.
  Profile 5 is exempt on purpose and keeps its record on any display: there the
  record is not an upgrade over a base layer but the *description* of an
  IPT-PQc2 picture, and an entry without it has that picture read as YCbCr —
  the green-and-purple misread. P5 on a non-DV display is refused a master a
  level up instead, which is unchanged.

  The rule is pinned by unit tests (`HLSRemuxer.shouldStripDolbyVisionRecord`);
  the byte-level effect is asserted in `RealMediaVerification`, which needs a
  real DV source because ffmpeg cannot synthesize an RPU.

## [1.8.0] — 2026-08-13

### Added

- **The software pipeline switches audio tracks mid-playback** (#35, the
  audio half). `SoftwarePlaybackPipeline.selectAudioTrack(streamIndex:)` swaps
  the audio decoder while the clock and the video renderer stay untouched —
  the most visible gap between the software path and the remux path, which
  gets track selection for free from AVPlayer's media selection.

  The order of operations is the design: the new track's decoder is built
  *before* the old one is torn down, so a track whose decoder can't open
  leaves the current track playing rather than leaving silence. The demuxer
  is then rewound to the clock's present — the read cursor runs ahead of the
  playhead by the queue's look-ahead, and joining the new track there would
  skip what the listener hasn't heard yet. The rewind re-reads video the
  renderer already holds; those frames are dropped by timestamp instead of
  re-enqueued (the renderer sees no flush, no duplicate, no timestamp
  regression), and the new track's audio from before the playhead is dropped
  the same way — late while playing, and a stale burst on resume while
  paused. A source that refuses the rewind (no index) joins at the read
  position instead: a gap of the look-ahead beats a refused switch.

  Enumeration and publication come with it: `selectableAudioTracks` lists
  what this build can actually decode (language, title, channel count — the
  same `AudioTrackInfo` the probe reports), `selectedAudioStreamIndex` is the
  settled selection for a host's menu checkmark, and `sourceInfo` carries the
  probe's whole description of the loaded source — subtitle tracks and
  chapters included — read off the pipeline's own context at `load`. Subtitle
  track *selection* waits for subtitle rendering to exist in this path at
  all; the enumeration half is already here.

- **Container chapters surface as API.** A Matroska `Chapters` edition or an
  MP4 chapter track — how films and rips mark their scenes — was read by
  libavformat all along and then dropped on the floor. Now
  `SourceInfo.chapters` reports each mark (`ChapterInfo`: title, start, end in
  seconds, sorted by start), and `PrismCoreSession.chapters` exposes the same
  list the moment `start()` returns, on the same lifecycle as
  `displayCriteria`.

  Chapters are navigation metadata, not media: HLS has no way to carry them,
  so nothing about the served playlist changes and AVPlayer never sees them.
  They exist for the host's own chrome — timeline markers, a chapter-skip
  button — which is also why the probe is the right place to read them: both
  playback paths start from `SourceInfo`, so the software path gets them for
  free. A declared end that doesn't follow its start reports as `nil` (no
  end) rather than as a fact, and a negative start (an edition offset) clamps
  to zero — the playable timeline has no position before it.

## [1.7.0] — 2026-08-12

### Fixed

- **The JOC declaration no longer depends on the container admitting to it.**
  The syncframe walk that finds `complexity_index_type_a` — the number the
  `dec3` box needs, and the difference between Atmos and plain DD+ at the
  speaker — only ran on tracks the probe had already flagged as object audio.
  That flag is `AVCodecParameters.profile`, which libavformat fills in **only
  when `avformat_find_stream_info` happened to decode an E-AC-3 frame while
  sampling**. Nothing guarantees it did, and this engine makes it less likely
  than most: since 1.2.0 the open is capped at a 4 MB probe and 2 s of
  analysis (`SourceOpenTuning`), so a UHD remux whose audio is sparsely
  interleaved can finish analysis without an audio frame ever being decoded.
  A real Atmos track then reached the muxer unasked, its `dec3` shipped
  without the extension, and it played as DD+ — silently, since every other
  part of the pipeline was working as designed.

  The walk now runs on **every stream-copied E-AC-3 track**, whatever the
  metadata claims, in both output shapes. It is bytes, not decode, and it is
  bounded: 24 frames (under a second of audio) after which "no JOC" is the
  answer. Previously an unanswered sniff stayed open for the length of the
  file. A bridged track is still never asked — the encoder's output carries no
  JOC and declaring it there would promise Atmos the bridge destroyed.

### Added

- **`PrismCoreSession.objectAudio`** — `[ObjectAudioFinding]`, what the
  bitstream said, one settled finding per stream-copied E-AC-3 track:
  `complexityIndex` (nil = asked and answered no), `claimedByMetadata`, and
  `wasMissedByMetadata` for the disagreement that matters. A host that shows a
  Dolby Atmos badge can now state a fact rather than repeat
  `AudioTrackInfo.isObjectAudio`, which remains the container's claim.

## [1.6.2] — 2026-08-12

### Changed

- **The remux runs on a thread of its own, not on the cooperative pool** (#44).
  `HLSRemuxer.run()` is synchronous by design: it blocks in FFmpeg reads for as
  long as production takes and then parks at EOF for the rest of the session.
  Started with `Task.detached`, it therefore held one thread of the global
  cooperative pool permanently — on an Apple TV, a quarter of the pool for the
  length of a film — which is a standing violation of the pool's
  don't-block contract even though the field case is bounded to one session.

  In the test suite it was worse than a violation: enough concurrent sessions
  park enough producers to saturate the pool, and then the async work that
  would release them (`stop()`, a demand fetch) can never run. That was a full
  suite hang, seen once in four runs on 2026-08-10.

  `ProducerThread` gives the producer a real thread and an `async` `join()` —
  a continuation, not a poll — so `stop()` still waits for the exit exactly as
  awaiting the task's value did. The suite ran twelve consecutive times clean
  on this change (was 3 of 4).

  The park loop also stops polling: it blocks on the coordinator's condition
  and the demand fetch that needs it signals. Worth ~5 ms on the average cold
  seek — the old interval was 10 ms — so the point is the thread, not the
  latency. `HLSRemuxer.cancel()` now wakes a parked producer (flag first, then
  the wake: a condition signal with no state change behind it can be lost).

## [1.6.1] — 2026-08-12

### Fixed

- **A cue-less subtitle segment no longer parses as a broken cue.** Every
  segment ends its header block with a blank line now, whether or not a cue
  follows. A segment with cues got one for free — each cue was written with a
  leading newline — but an empty one ended on the `X-TIMESTAMP-MAP` line with
  the header still open, and AVFoundation then read that line as a cue with no
  timings: `kFigWebVTTSampleBufferError_CueParseError`, "Couldn't find --> in
  cue", once per empty segment. Since a rendition is cut on the *video's*
  boundaries, most of a film's segments carry no dialogue at all, so the error
  repeated through the whole playback. Reported from a device run on a 3-track
  MKV.

  The last cue now ends with a blank line too — a cue block closed by EOF is
  the same hazard in a different place — and a test walks each segment shape as
  the parser does (split on blank lines; the first block is the header, every
  other must open with a timing line).

## [1.6.0] — 2026-08-11

### Added

- **`setTimedTextCueHandler` — embedded subtitle cues streamed to the host.**
  A public tap on the demux's subtitle conversion: every cue an embedded text
  stream produces (and every OCR'd bitmap cue) is handed to the host as a
  `TimedTextCue` — stream index, start/end **rebased onto the played
  timeline** (presentation origin already subtracted), and the converted
  text. The WebVTT renditions keep working unchanged; this is the other
  delivery, for a host that draws captions itself on the player's own clock
  instead of AVPlayer's rendition schedule. A handler registered late is
  replayed everything produced so far in production order; a re-demuxed
  region (demand-driven seeks) is deduplicated inside the engine; cues
  produced before the presentation origin is known are held and flushed with
  it. Fallback sessions (master rejection, muxed shape) inherit the handler
  the same way they inherit external subtitle registrations. External files
  registered via `addExternalSubtitle` are not streamed — the host handed
  those in and already owns their text.

  Why: the server-side text routes keep failing hosts — Plex's subtitle-only
  transcode answers empty documents for embedded tracks (Aether#1533), and
  rendition timing is where the late-cue drift class of bugs lives. The
  demux this engine already runs is the one honest source of embedded cues.

## [1.5.0] — 2026-08-10

### Added

- **`SeekPreviewService` — scrub-bar thumbnails for anything libavformat can
  open.** `thumbnail(at:)` returns a `CGImage` of the keyframe covering the
  position: the floating frame a player HUD shows while the user drags the
  seek bar, for the sources that have no server-generated trick-play (SMB,
  WebDAV, local files, servers that never built previews). Deliberately its
  own small pipeline, independent of which engine is playing the title — it
  opens its own context (a thumbnail must never stall playback), decodes on
  the CPU only (one keyframe at ~300 px doesn't earn a VideoToolbox
  session), and `sws_scale` does the decode-to-delivery in one step.

  Containers land differently after a timestamp seek, and the service knows:
  an indexed seek (Matroska Cues, MP4) puts the first packet on the covering
  keyframe — one decode answers; MPEG-TS's binary search lands *past* it (the
  search runs on DTS, a keyframe's DTS trails its PTS), so the landing is
  re-seeked a second early and walked forward, scaling only the candidates.
  Results are cached by the keyframe they show (LRU, 32 entries), with a
  learned-coverage map — a request at T that decoded keyframe P proves no
  keyframe exists in (P, T], so everything in [P, T] hits the cache; forward
  of proven ground the next keyframe may lurk anywhere, and guessing would
  pin a wrong picture. A harvested keyframe map (1.4.0's sidecar, same
  `keyframeIndexCacheDirectory`) resolves positions exactly and makes
  GOP-wide hits immediate. Thumbnail seeks run under a 3 s interrupt bound —
  a cue-less Matroska over a slow transport turns them into linear scans
  (the 1.1.1 shape), and a missing floating frame beats a frozen scrub bar.

  Known v1 caveats: HDR (PQ/HLG) converts by matrix, not tone-map — previews
  look flatter than the picture; Dolby Vision Profile 5 (IPT-PQc2) has no
  honest RGB conversion here, hosts should not offer engine previews for P5.

## [1.4.0] — 2026-08-10

### Added

- **The remux harvests the keyframe index and the next play reuses it**
  (#34). A container with no usable seek index — a Matroska without Cues,
  any MPEG-TS — could never get a keyframe-basis plan: the map is not in the
  file, and 1.1.1/1.3.1 only made *not having it* survivable (bounded seek →
  uniform plan → sequential playback, every play again). The information is
  free, though: the sequential producer reads the whole file and sees every
  keyframe go past. With `keyframeIndexCacheDirectory` set on
  `PrismCoreSession` (opt-in; a host cache directory is right — entries are
  a few KB of JSON, bounded LRU), it now collects those keyframes as a pure
  by-product — no extra I/O, and only a run that reached EOF persists, since
  a partial map that passes the plan's witnesses would promise segments
  whose keyframes nobody saw. The next play of the same source plans on the
  map from its first second: full demand-driven seeking, as if the file had
  an index. A cache hit also skips the index-load nudge seek entirely.

  Entries are keyed by URL (query stripped — a rotated Plex token is the
  same media), byte size, whole-second duration and, for local files, mtime;
  the full identity is stored inside the entry, so the filename hash needs
  no collision guarantees, and a mismatch is simply a miss. A cached map is
  only used on a seekable transport — a plan is a promise to re-anchor, and
  a re-anchor is a seek. The reference engine does not do this (checked
  2026-08-08, approach only): it recomputes its keyframe list every session.

### Fixed

- **Retention can no longer evict a demanded segment before its serve reads
  it** (#43). Under a tight `segmentCacheBytes` budget, a demand fetch of an
  evicted segment could fail outright: the producer re-anchors, re-produces
  the segment, runs on past it — and `recordAndEvict`, seeing the budget
  exceeded, evicts the farthest-from-producer segment, which by then is
  exactly the one just re-produced. The provider's poll finds nothing, times
  out at 15 s, and AVPlayer reports a lost connection (`-1005`). The 1.3.1
  cadence change made the race hard to lose (19–34 ms serve vs. a 100 ms
  poll); it never removed it.

  Now the provider tells the coordinator when a demand serve begins and ends
  (`beginServing`/`endServing`, refcounted — the variant and each rendition of
  an index fetch separately), and eviction skips any index with a serve
  outstanding, exactly like the keep window: the budget may stay exceeded for
  the serve's duration rather than answer a promise the playlist made with a
  404. Protection is installed at the moment of the miss, not when the queued
  serve first runs, so there is no gap for production to land the file and
  eviction to take it back.

## [1.3.1] — 2026-08-10

### Changed

- **The polling cadences stopped being the latency.** Three waits in the
  session's hot paths polled at 100 ms (readiness gate, the provider's
  wait-for-file) and 50 ms (the parked producer's wake), and on a warm source
  the polls cost more than the work they were waiting for. All three now run
  at 10 ms. Measured over local HTTP (3 min H.264/AC3 MKV, planned mode,
  three runs): `session.start()` 103–109 ms → **13–25 ms**; a parked cold
  seek of an evicted segment (re-anchor → produce → serve) 114 ms →
  **19–34 ms**. The checks are a couple of small file reads each — at 10 ms
  they are still noise.

### Fixed

- **The bounded index-load seek works now.** 1.1.1 shipped it and its own
  correction: the wall-clock guard was installed on the `AVFormatContext`
  *after* `avformat_open_input`, but the blocking reads check the
  `URLContext`'s copy of the callback, taken when that context is created
  during the open — so the guard never reached the reads and a cue-less
  source still stalled the whole startup (#39).

  The guard (`ReadInterruptGuard`) now exists **before** the open, on every
  open site — `SourceProbe.open`, the remuxer's fallback open, and the plan
  probe — permanently installed and disarmed, armed only around the
  index-load seek. Both sites matter: since 1.2.0 the remuxer usually adopts
  the probe's context, so the probe's open is the one that decides whether a
  bound is possible at all, and the guard travels with the context inside
  `ProbedSource`. An aborted read latches `AVERROR_EXIT` in the
  `AVIOContext`; the planner clears it after disarming, so the session
  carries on with the uniform plan instead of dying on its first real read.

  Verified the way the correction asked: against a transport that actually
  blocks. The test serves a fixture's head over local HTTP and then holds
  every read open forever — with a 0.5 s budget the plan comes back in
  ~0.5 s on the uniform basis, covering the full source from the head.
  Before the fix that test hangs, which is precisely what the field case
  (5.4 GB cue-less MKV, 20 s session timeout) looked like.

## [1.3.0] — 2026-08-09

### Changed

- **Deinterlacing no longer costs the hardware decode.** `bwdif` reads planar
  YUV, so asking for it forced the whole decode onto the CPU — on an Apple TV,
  for interlaced broadcast content, the worst combination available. When the
  FFmpeg build carries `yadif_videotoolbox`, the filter now runs on the
  VideoToolbox frames the decoder already produced and the zero-copy route
  survives deinterlacing.

  The choice is made per frame, from what the frame *is*: a hardware frame
  carries a `hw_frames_ctx` and gets the GPU filter (handed to the graph via
  `av_buffersrc_parameters_set`, without which configuration fails with "No
  hardware frames context provided"); a planar frame gets `bwdif` exactly as
  before.

### Added

- `SoftwareVideoDecoder.gpuDeinterlaceName` — the GPU deinterlacer this build
  carries, or `nil`. Resolved at runtime because it is a property of the
  **build**, not the code: the filter needs Metal, which is a separate Xcode
  component, and a host on an FFmpeg without it still deinterlaces correctly on
  the CPU route. `routeDescription` names whichever one is in use.

### Notes

- The GPU path needs an FFmpeg built with `--enable-filter=yadif_videotoolbox`
  — [aether-ffmpeg `n8.0.1-eac3-vt.1`](https://github.com/Wenzlik/aether-ffmpeg/releases/tag/n8.0.1-eac3-vt.1)
  or later. PrismCore's own dependency is upstream MPVKit, which does not carry
  it, so this repository's tests exercise the fallback branch; the GPU graph is
  verified by a host on that build, or on a device.

## [1.2.0] — 2026-08-09

### Added

- **`SourceProbe.open(url:httpHeaders:)` → `ProbedSource`, and
  `PrismCoreSession(url:display:probed:)`.** A playback used to open its
  source twice — once for the host's routing decision, once for production —
  and over a network the second open is a real round trip inside the wait the
  user is watching. The probe can now keep its context, and a session over the
  same source adopts it.

  Measured against a 5.4 GB HEVC/EAC3 remux over HTTP, warm, three runs:
  probe + `start()` goes from **~522 ms to ~135 ms** (probe 21–24 ms,
  start 109–115 ms). `SourceProbe.probe` is unchanged for callers that only
  want the answer.

  The context **moves**: `ProbedSource` hands it over exactly once, the
  adopting session owns closing it, and a probe nobody adopts (the source
  routed elsewhere) closes its own. An `AVFormatContext` is not safe for
  concurrent use and this does not pretend otherwise — consuming it once is
  what makes the handover a move rather than a share.

  This is the shape 1.1.2 explicitly did *not* ship. Passing the probe's
  conclusions and skipping the second `find_stream_info` breaks muxing,
  because that call also fills fields the muxer needs; passing the context
  carries the analysis with it, which is the whole difference. The test that
  caught the earlier attempt now guards this one: an adopted context must
  produce a byte-identical master and init segment **and** mux through to
  `EXT-X-ENDLIST` on an EAC3 source.

## [1.1.2] — 2026-08-09

### Fixed

- **Opening a source no longer reads more of it than it has to.** Every open
  now carries explicit read caps (4 MB probe, 2 s of analysis) instead of
  libavformat's defaults, which are sized for containers that hide their
  structure — Matroska and MP4 describe themselves in their header. Measured
  against a 5.4 GB HEVC/EAC3 remux served over HTTP, warm, five runs: the open
  drops from a median of 126 ms to 54 ms, and the spikes (168 ms) disappear
  along with the analysis that produced them. A playback pays this twice — the
  routing probe and the remuxer each open the source — so it is the part of a
  host's "Preparing…" that PrismCore actually controls. The caps are a
  ceiling, not a target: a well-formed file stops well short of both.

### Notes

- The companion idea — hand the remuxer the routing probe's answer so it can
  skip its own `find_stream_info` — was implemented, caught by a new test, and
  reverted. That call is also what fills fields the *muxer* needs (an EAC3
  track's frame size), and a context that never ran it produces a correct-
  looking manifest with a failing `av_interleaved_write_frame`. Making the
  second open cheap has to mean sharing the first one's **context**, not
  trusting its conclusions; that is a 1.2 change, not a patch.
- `StartupCostBenchmark` (opt-in via `PRISMCORE_BENCH`, a path or an http URL)
  measures the phases end to end, so the next change to this area starts from
  numbers rather than intuition.

## [1.1.1] — 2026-08-08

### Fixed

- **A source with no seek index can't eat the startup budget.** The nudge seek
  that makes a demuxer load its index is only *bounded* when an index exists:
  a Matroska without Cues turns it into a linear scan of the whole file, and
  over a slow transport that is the entire session startup (field case: a
  5.4 GB webrip on an SMB mount — one seek took 66 s, and `start()` timed out
  before the master playlist was ever written, so the host fell back to its
  other engine). The seek now runs under a 3 s wall-clock guard
  (`interrupt_callback`); on expiry the plan degrades to the uniform basis —
  the same path an untrusted index already took — and the session starts.
  Sources with an index load it in a fraction of a second and are unaffected.

  > **Correction (2026-08-09): this fix does not work.** Re-measured against
  > the same file, the session still times out at 20 s. The guard is installed
  > on the `AVFormatContext` *after* `avformat_open_input`, but the read path
  > checks `URLContext.interrupt_callback` (`libavformat/avio.c:515`), which is
  > populated when the context is created (`avio.c:189`) — so it never reaches
  > the blocking reads. The callback has to be set before the open — which is
  > what [1.3.1] does; the capping in 1.1.2 and the single open in 1.2.0 are
  > unaffected.

## [1.1.0] — 2026-08-08

### Changed

- **An HDR settle no longer trusts the ambiguous clear.** On an HDR target,
  the display-switch in-progress flag clearing is not a "done": a panel that
  finished quietly and one that ABORTED the switch (staying SDR) look
  identical at that moment, and returning on the clear is exactly how a
  slow-but-willing panel's master got validated against the old SDR mode
  (`-11868`). The wait now notes the clear and spends the rest of the settle
  cap watching for a real HDR signal (mode-switch-end, raised headroom).
  Rate-only writes keep the clear as their exit. Found on a panel that takes
  HDR10 fine when parked there, yet cleared its runtime switch at ~2.9 s with
  the mode never engaging.

### Added

- `SettleReport.Outcome.clearedWithoutHDRSignal` + `clearedAfterMilliseconds`
  — the report line that says the panel probably stayed SDR and a master
  rejection may follow: "switch cleared at 2913ms but HDR never signalled;
  watched to 6000ms".

## [1.0.0] — 2026-08-07

Identical in content to 0.1.13 — the bump is the declaration. The engine has
been shipping in a real app across the 0.1.x line: remux with multi-audio,
Atmos carriage, Dolby Vision (including 7 → 8.1 conversion), text and OCR
bitmap subtitle renditions, the tvOS display-criteria contract, demand-driven
production with seek re-anchoring, deinterlace verification and the software
pipeline. From here the public API is stable: breaking changes mean a major
bump, features a minor, fixes a patch.

## [0.1.13] — 2026-08-07

### Added

- `VideoTrackInfo.sampleAspectRatio` — the pixel aspect ratio a display should
  honor, kept rational, container-level over bitstream. What a host needs to
  size a surface for anamorphic content.

### Fixed

- **Anamorphic SD plays at its intended shape.** The container-level aspect
  ratio (an MKV's DisplayWidth/Height — how anamorphic DVD rips are usually
  tagged) lives on the stream, not in codecpar, and the codecpar-only copy
  dropped it: 720×576/16:9 sources played distorted. The remux now propagates
  it into the `pasp` box AVPlayer honors. (Found and pinned byte-level because
  FFmpeg's own hls demuxer has the same codecpar-only bug and a playlist
  re-probe can never see the value.)

### Changed

- **OCR arms on demand.** Bitmap renditions used to decode and OCR every track
  from the first packet; a Blu-ray-class remux can carry dozens of PGS tracks
  of which the player selects at most one. A track now does nothing — decode
  included — until a fetch of one of its own `.vtt` segments arms it, and
  segments cut while unarmed are re-produced on that fetch through the same
  re-anchor machinery a seek uses, so subtitles enabled mid-film still get
  their cues. Text renditions stay always-on — they are cheap.

## [0.1.12] — 2026-08-07

### Added

- **Application Store Exception** on the licence. LGPL section 6 asks that users
  be able to relink a work against a modified PrismCore, which a signed `.ipa`
  cannot allow — so plain LGPL and the App Store were in tension, which is a poor
  reason for a library like this to be unusable by the apps it was written for.
  The exception releases an adopter from that requirement for store distribution
  only; modifications to PrismCore itself stay LGPL and still have to be
  published. FFmpeg's own terms are untouched and unchanged.
- `CHANGELOG.md` — this file. Releases up to 0.1.11 are reconstructed from their
  tags.

### Changed

- **README rewritten for adopters.** It described a v0 scaffold whose Aether
  integration was "parked on two build-level prerequisites"; both were solved
  weeks ago and the engine has been shipping since. It now leads with what the
  engine handles, how to call it, and what integrating it asks of you, with the
  hard-won findings (the `dec3` box, `hvc1` parameter sets, the three Dolby Vision
  claims that must agree, WebVTT timing, lying interlace flags) kept as design
  notes rather than buried in a phase list.

## [0.1.11] — 2026-08-07

### Added

- `SoftwarePlaybackPipeline.durationSeconds` and `.volume` — the two numbers a
  host transport needs and the pipeline was keeping to itself. Duration is `nil`
  for sources whose container honestly doesn't know, rather than a fabricated
  zero.

## [0.1.10] — 2026-08-07

### Fixed

- **OCR speaks Vision's language.** Containers carry ISO 639 (Matroska metadata
  uses the three-letter 639-2 form — `cze`, `ger`), Vision wants BCP-47 (`cs-CZ`).
  The raw pass-through matched nothing, so exactly the tracks that most needed
  recognition got the default language instead of their own.
- The OCR text corrector is allowed to work where it helps, instead of being
  disabled wholesale.

## [0.1.9] — 2026-08-07

### Added

- **Bitmap subtitles become renditions through on-device OCR.** PGS / DVB / DVD
  tracks — the forced-subtitle and SDH form every Blu-ray remux carries — used to
  be reported and dropped, because a rendition needs text and a bitmap track has
  pictures. Vision reads them into the same WebVTT rendition machinery, which is
  the only form that rides PiP, AirPlay and the system subtitle menu at all.
  Lossy by design: typography dies, text survives, and the raw tracks stay
  surfaced for a host that wants to draw them pixel-accurately.
  Verified against a real Blu-ray remux.

## [0.1.8] — 2026-08-07

### Added

- **Deinterlacing.** AVPlayer never deinterlaces, so a stream-copied interlaced
  source — IPTV and DVB captures are where they live — played with combing on the
  native path. Verified-interlaced H.264 now routes to the software path and CPU
  `bwdif` at field rate.

### Fixed

- A *declared* interlaced stream is verified against a dozen decoded frames before
  it is believed. Broadcast H.264 is routinely flagged interlaced around
  progressive frames, and evicting those from the native path would trade hardware
  decode and Atmos passthrough for deinterlacing nothing.

## [0.1.7] — 2026-08-07

### Fixed

- **Same-format skip across sessions.** Hosts build a `DisplayCriteriaController`
  per playback and the redundancy baseline was per-instance, so replaying a title
  re-wrote identical criteria. That is not a no-op: it starts a redundant HDMI
  negotiation, and on panels whose switch is unobservable it made every settle run
  to its cap. The baseline is now class-wide, which is honest — there is one HDMI
  output to describe.
- Settle logs report the time actually spent rather than the budget, so switch
  latency can be measured instead of guessed at.

## [0.1.6] — 2026-08-07

### Fixed

- **A dynamic-range switch gets room for a real handshake.** The flat bounds (1 s
  start grace, 2 s settle cap) lost the race on living-room chains: a DV / HDR10
  renegotiation — HDCP re-auth, mode engage, often through an AVR — routinely
  takes over a second to visibly start and 2–5 s to end. When the wait gave up
  early the master loaded against the panel's old mode, tvOS refused the DV claim
  (`-11868`), and the tiered fallback silently replayed the title as HDR10.

## [0.1.5] — 2026-08-06

### Added

- **The rejection fallback learns tiers.** `makeMasterRejectionFallbackSession()`
  — a refused master that claimed Dolby Vision retries once *without* the claim
  (same renditions, same subtitles, same `VIDEO-RANGE`, playing as plain HDR10)
  before falling to the muxed shape. That middle tier exists for the one panel
  state no read can prove: Match Content off with the output parked in HDR10. The
  muxed shape stays the safe floor.

## [0.1.4] — 2026-08-06

### Fixed

- **Subtitles reach the master playlist.** The WebVTT renditions were produced but
  never published — the master write set the audio renditions and left the
  subtitle list empty, so AVPlayer's legible group only ever held the video
  stream's own CEA captions. The served master now declares every rendition
  (embedded text tracks and registered externals) and `start()` waits for the
  subtitle playlists it references.

## [0.1.3] — 2026-08-06

### Added

- **The tvOS playback contract.** `DisplayCriteriaController` programs
  `preferredDisplayCriteria` and waits the HDMI handshake out *before* the host
  loads the playlist, which is the only ordering tvOS accepts for HDR HLS — AVKit's
  automatic criteria derive from a format description that only exists after the
  variant passes the validation the switch has to precede. The `dvh1` fourcc is
  what negotiates Dolby Vision; SDR writes codec + rate only, which is what makes
  **Match Frame Rate** engage on SDR content.
- `PrismCoreSession.displayCriteria` publishes the per-source choice, clamped to
  the display it was built for.
- `DisplayCapabilities.panelIsCurrentlyHDR` — a panel already out of SDR takes an
  HDR master even when `availableHDRModes` came back empty.

### Fixed

- Dolby Vision Profile 5 on a non-DV display routes media-direct proactively. A
  bare `dvh1.05` master has no fallback variant for the filter to pick, so serving
  one bought a guaranteed `-11868`. Profile 8.x keeps its master: the `hvc1`
  primary *is* the fallback.

## [0.1.2] — 2026-08-05

### Fixed

- `BridgeClock`'s initializer is reachable on Xcode 26.6 / Swift 6.1, which is
  what Xcode Cloud builds with.

## [0.1.1] — 2026-08-05

### Fixed

- Authorship and copyright lines (0.1.0 shipped without them), and this package's
  own `Package.resolved` restored after a host-app resolve had overwritten it.

## [0.1.0] — 2026-08-05

First public release. Stream-copyable A/V (HEVC / H.264 / AV1 with hardware +
AAC / AC3 / EAC3 / FLAC / ALAC) remuxed to HLS-fMP4 and served from a loopback
HTTP server, with:

- **Multi-audio** — every viable track as an HLS alternate rendition, so the host
  gets a real `AVMediaSelectionGroup`;
- **Dolby Atmos** — EAC3+JOC stream-copied, with the `dec3` box's TS 103 420
  type-A extension re-applied to the init segment;
- **Dolby Vision** — honest `CODECS` / `SUPPLEMENTAL-CODECS`, the `dvh1` sample
  entry for Profile 5, Profile 7 → 8.1 RPU conversion through libdovi;
- **Subtitles** — text tracks and external files as segmented WebVTT renditions;
- **Seek & cache** — keyframe-aligned plan, demand-driven production with
  re-anchoring, byte-budgeted retention;
- **Software path** — libavcodec into `AVSampleBufferDisplayLayer` for the video
  AVPlayer cannot decode at all.

[Unreleased]: https://github.com/Wenzlik/PrismCore/compare/2.0.2...main
[2.0.2]: https://github.com/Wenzlik/PrismCore/compare/2.0.1...2.0.2
[2.0.1]: https://github.com/Wenzlik/PrismCore/compare/2.0.0...2.0.1
[2.0.0]: https://github.com/Wenzlik/PrismCore/releases/tag/2.0.0
[1.10.1]: https://github.com/Wenzlik/PrismCore/releases/tag/1.10.1
[1.10.0]: https://github.com/Wenzlik/PrismCore/releases/tag/1.10.0
[1.9.0]: https://github.com/Wenzlik/PrismCore/releases/tag/1.9.0
[1.8.4]: https://github.com/Wenzlik/PrismCore/releases/tag/1.8.4
[1.8.3]: https://github.com/Wenzlik/PrismCore/releases/tag/1.8.3
[1.8.2]: https://github.com/Wenzlik/PrismCore/releases/tag/1.8.2
[1.8.1]: https://github.com/Wenzlik/PrismCore/releases/tag/1.8.1
[1.8.0]: https://github.com/Wenzlik/PrismCore/releases/tag/1.8.0
[1.7.0]: https://github.com/Wenzlik/PrismCore/releases/tag/1.7.0
[1.6.2]: https://github.com/Wenzlik/PrismCore/releases/tag/1.6.2
[1.6.1]: https://github.com/Wenzlik/PrismCore/releases/tag/1.6.1
[1.6.0]: https://github.com/Wenzlik/PrismCore/releases/tag/1.6.0
[1.5.0]: https://github.com/Wenzlik/PrismCore/releases/tag/1.5.0
[1.4.0]: https://github.com/Wenzlik/PrismCore/releases/tag/1.4.0
[1.3.1]: https://github.com/Wenzlik/PrismCore/releases/tag/1.3.1
[1.3.0]: https://github.com/Wenzlik/PrismCore/releases/tag/1.3.0
[1.2.0]: https://github.com/Wenzlik/PrismCore/releases/tag/1.2.0
[1.1.2]: https://github.com/Wenzlik/PrismCore/releases/tag/1.1.2
[1.1.1]: https://github.com/Wenzlik/PrismCore/releases/tag/1.1.1
[1.1.0]: https://github.com/Wenzlik/PrismCore/releases/tag/1.1.0
[1.0.0]: https://github.com/Wenzlik/PrismCore/releases/tag/1.0.0
[0.1.13]: https://github.com/Wenzlik/PrismCore/releases/tag/0.1.13
[0.1.12]: https://github.com/Wenzlik/PrismCore/releases/tag/0.1.12
[0.1.11]: https://github.com/Wenzlik/PrismCore/releases/tag/0.1.11
[0.1.10]: https://github.com/Wenzlik/PrismCore/releases/tag/0.1.10
[0.1.9]: https://github.com/Wenzlik/PrismCore/releases/tag/0.1.9
[0.1.8]: https://github.com/Wenzlik/PrismCore/releases/tag/0.1.8
[0.1.7]: https://github.com/Wenzlik/PrismCore/releases/tag/0.1.7
[0.1.6]: https://github.com/Wenzlik/PrismCore/releases/tag/0.1.6
[0.1.5]: https://github.com/Wenzlik/PrismCore/releases/tag/0.1.5
[0.1.4]: https://github.com/Wenzlik/PrismCore/releases/tag/0.1.4
[0.1.3]: https://github.com/Wenzlik/PrismCore/releases/tag/0.1.3
[0.1.2]: https://github.com/Wenzlik/PrismCore/releases/tag/0.1.2
[0.1.1]: https://github.com/Wenzlik/PrismCore/releases/tag/0.1.1
[0.1.0]: https://github.com/Wenzlik/PrismCore/releases/tag/0.1.0
