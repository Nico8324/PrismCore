<p align="center">
  <img src=".github/prismcore-logo.png" alt="PrismCore" width="360">
</p>

<p align="center">
  <b>A playback engine core for Apple platforms.</b><br>
  FFmpeg demuxes. Apple plays. Dolby Atmos and Dolby Vision survive the trip.<br>
  No view, no controls, no state — you keep your AVPlayer and your UI.
</p>

<p align="center">
  <a href="https://github.com/Wenzlik/PrismCore/releases/latest"><img src="https://img.shields.io/github/v/release/Wenzlik/PrismCore?label=release&color=blue" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/Swift-6.0%2B-F05138?logo=swift&logoColor=white" alt="Swift 6.0+">
  <img src="https://img.shields.io/badge/platforms-iOS%20%7C%20tvOS%20%7C%20macOS%20%7C%20visionOS-lightgrey" alt="Platforms">
  <img src="https://img.shields.io/badge/license-LGPL--2.1%2B%20%2B%20App%20Store%20Exception-lightgrey" alt="Licence">
</p>

---

## What it is

Any container libavformat can read (MKV, MPEG-TS, AVI, …) is remuxed on the fly
into **HLS-fMP4**, served from a loopback HTTP server on `127.0.0.1`, and handed
to a plain `AVPlayer` as a playlist URL. Not a single frame is re-encoded. Apple's
stack then does what only it can do on its own platforms:

- **hardware decode** (VideoToolbox),
- **Dolby Atmos passthrough** — EAC3+JOC is stream-copied, never decoded to PCM,
- **Dolby Vision** display engagement and the HDMI handshake,
- **Match Content** (frame rate + dynamic range) on tvOS,
- system-side HDR10 / HLG tone-mapping,
- and everything that rides along for free because it *is* AVPlayer: Picture in
  Picture, AirPlay, the Now Playing surface, spatial audio.

On Apple platforms the usual choice is between AVPlayer — deep OS integration,
but only Apple's containers — and an mpv- or VLC-derived engine, which plays
almost anything but renders its own frames and decodes audio to PCM, so Dolby
Vision and Atmos die at its door. PrismCore is the third option: FFmpeg's
container breadth in front of Apple's own playback stack.

For the handful of sources whose *video* AVPlayer cannot decode at all (VP9,
MPEG-2, VC-1, interlaced H.264), there is a software path — libavcodec into
`AVSampleBufferDisplayLayer` — so a host has one engine to call rather than two.

## Used by

- **[Aether](https://aetherplayer.com)** — a native media player for Apple
  platforms. PrismCore is the engine every non-Apple container routes through:
  ahead of libmpv, behind plain AVFoundation for the files it can already open.
  Routing arrived in Aether 1.1.0 behind a developer toggle and is on by
  default from 1.1.1.

Shipping something on PrismCore? Open an issue and it gets listed here.

## What it handles

| Area | Summary |
| --- | --- |
| Containers | Anything libavformat demuxes — MKV, MP4, MPEG-TS, AVI, WebM, FLV, … |
| Video (native) | H.264, HEVC (incl. Main 10), AV1 **where the device has a hardware decoder** — asked with `VTIsHardwareDecodeSupported`, not inferred from a chip name |
| Video (software) | VP9 / VP8, MPEG-2, MPEG-4 Part 2, VC-1 / WMV3, AV1 without hardware (libdav1d), interlaced H.264 with CPU `bwdif` deinterlace at field rate |
| HDR | HDR10 (PQ) and HLG, signaled honestly in the master playlist and tone-mapped by the system |
| Dolby Vision | Profile 5 (`dvh1` sample entry), 8.1 and 8.4 (`hvc1` + `SUPPLEMENTAL-CODECS`), **Profile 7 converted to single-layer 8.1** through libdovi; 8.2's Rec.709 base plays as plain SDR because that is what it is |
| Dolby Atmos | EAC3+JOC **stream-copied**, and the `dec3` box's TS 103 420 type-A extension re-applied to the init segment — without it AVFoundation plays the same bitstream as plain DD+ |
| Audio (copy) | AAC, AC3, EAC3, FLAC, ALAC — bit-for-bit |
| Audio (bridge) | TrueHD / MLP / DTS / DTS-HD MA / MP3 / MP2 / Opus / Vorbis / PCM → EAC3 5.1, 128 kbps per channel. Needs an FFmpeg build with the **`eac3` encoder**; without it those sources take the software path instead, which decodes them itself |
| Multi-audio | Every viable track becomes an HLS alternate rendition with its language, name and channel count, so AVPlayer gets a real `AVMediaSelectionGroup` to switch on. The software path switches too: `SoftwarePlaybackPipeline.selectAudioTrack(streamIndex:)` swaps the decoder mid-playback without touching the clock or the picture |
| Dialogue boost | Opt-in (`dialogueBoost:` on the session): extra "Dialogue Boost" renditions derived from the default track — decoded, centre channel favoured (bed −6 dB / −12 dB), re-encoded to EAC3 — marked `public.accessibility.enhances-speech-intelligibility` so hosts find them by characteristic. Engine-side because AVFoundation ignores `audioMix`/audio taps on HLS items. The base track stays bit-for-bit (Atmos included). Needs the `eac3` encoder and a centre-channel source; stereo would need `dialoguenhance`, which current builds don't ship |
| Subtitles (text) | SubRip / ASS / SSA / WebVTT / mov_text converted during the remux read into segmented WebVTT renditions, cut on the video's own boundaries — so text survives PiP and AirPlay instead of living in a host overlay. External `.srt` / `.vtt` register as first-class renditions |
| Subtitles (bitmap) | PGS / DVB / DVD read by on-device Vision OCR into the same rendition machinery. Lossy by design — typography dies, text survives — and the raw tracks stay surfaced for a host that wants to draw them pixel-accurately |
| Seek & cache | Keyframe-aligned segment plan published upfront, demand-driven production with re-anchoring, absolute-`tfdt` continuity across restarts, byte-budgeted retention (1 GiB default; an evicted segment is reproduced on demand, so the budget bounds disk, not seekability) |
| Chapters | Matroska `Chapters` / MP4 chapter tracks reported as `SourceInfo.chapters` and `PrismCoreSession.chapters` (title + start/end seconds) — HLS cannot carry them, so they are the host's to draw as timeline markers and skip controls |
| Display | tvOS HDMI handshake driven by the engine: `preferredDisplayCriteria` programmed and settled **before** the item is loaded, which is the only ordering tvOS accepts for HDR HLS |
| Scrub previews | `SeekPreviewService` decodes the keyframe covering any position into a `CGImage` for a custom player HUD — its own context, CPU-only, cached per keyframe, and independent of which engine is playing. The trick-play answer for sources with no server-generated previews |
| Streaming | HTTP headers ride the demux connection (a Plex token, a WebDAV authorization), reconnect on dropped connections |

## Quick start

```swift
.package(url: "https://github.com/Wenzlik/PrismCore.git", from: "1.0.0")
```

One call probes the source, picks the path and hands back something already
started:

```swift
import PrismCore

switch try await PrismCoreEngine.open(url: mkvURL) {
case .remux(let session, let playlist):
    player.replaceCurrentItem(with: AVPlayerItem(url: playlist))   // AVPlayer plays it
    …
    await session.stop()

case .software(let pipeline):
    hostView.layer.addSublayer(pipeline.displayLayer!)             // we play it
    pipeline.play()
    …
    pipeline.stop()
}
```

The remux path is the one that matters — it is what buys hardware decode, Atmos
passthrough and Dolby Vision. Drive it directly when you want the detail:

```swift
let session = try PrismCoreSession(url: mkvURL, display: .current())

// optional, before start(): a sidecar joins the WebVTT renditions
try await session.addExternalSubtitle(url: srtURL, language: "cs", name: "Čeština")

let playlistURL = try await session.start()   // .../master.m3u8 or .../index.m3u8
// hand playlistURL to your AVPlayer
…
await session.stop()
```

The URL is a **master** playlist when the source has audio (that is where the
selectable renditions live) and a media playlist when it hasn't. Treat it as
opaque: the shape is a property of the source, not of the API.

`PrismCoreEngine.decide(for:)` is exposed separately, so a host can ask which
path a source would take — and unit-test its own routing — without standing up
either engine.

### Software track menus and captions

`SoftwarePlaybackPipeline` publishes the probe's metadata on the live player.
Audio selection works while playing or paused; the decoder is opened before
replacing the current one, the audio renderer is flushed, and the clock and
video renderer stay in place. The bounded rewind uses the playhead and the
configured audio delay. A refused rewind joins at the demux read position;
network and decoder latency can leave an audible gap. No gapless claim is made.

```swift
let audioTracks = pipeline.selectableAudioTracks   // language, title, channelCount
let subtitleTracks = pipeline.selectableSubtitleTracks // embedded text only
let audioSelection = pipeline.selectedAudioStreamIndex
let subtitleSelection = pipeline.selectedSubtitleStreamIndex // nil = Off

if let track = audioTracks.first {
    pipeline.selectAudioTrack(streamIndex: track.streamIndex) { accepted in
        // Completion is on the feed queue. Dispatch UI work to the main queue.
    }
}
pipeline.selectSubtitleTrack(streamIndex: subtitleTracks.first?.streamIndex)
pipeline.selectSubtitleTrack(streamIndex: nil)     // Off

// In the host's periodic UI update, replace the overlay with this snapshot.
// An empty array means clear it; overlapping cues can produce several entries.
let captions = pipeline.activeSubtitleCues
```

Use source **stream indices**, not positions in the menu array. Read the settled
selection after completion. A same-track selection succeeds without a flush;
invalid indices and calls outside paused/playing state are refused. An audio
open failure preserves the current track. A later read/decode failure reports
`false` and `.failed`; inspect `failureError`. Do not call synchronous `stop()`
or `load()` from feed-queue callbacks.

Text starts Off, including forced tracks: the host chooses its language policy.
All supported text packets use the existing HLS text converter and are retained
in a bounded look-ahead cache, so selecting an already-read caption (or Off)
does not seek, flush A/V, or start a paused clock. `TimedTextCue` timestamps here
use the **source axis**, matching `pipeline.currentTime`; remux cue callbacks
use the origin-rebased AVPlayer axis. Cue payloads can contain WebVTT inline tags
and entities; the host supplies rendering. Polling clears expired cues even at
EOF or while the demuxer is waiting for data.

The cache holds at most 1,024 cues / 1 MiB of UTF-8 text across all tracks;
expired cues are removed and excess incoming cues are dropped. Cues need valid
PTS and positive duration. Seeking clears the cache and repopulates from the
landing keyframe: a long caption whose packet precedes that keyframe may be
missing until the next cue. Bitmap/OCR and external subtitle selection remain
outside this software surface. Original ASS positioning and advanced styling
are not preserved by the text converter.

### Host setup on tvOS

Over HDMI the panel's mode has to be programmed **before** AVPlayer sees the
playlist. tvOS validates an HDR variant's `VIDEO-RANGE` against the panel's
*current* mode synchronously, so a PQ master handed to an SDR-parked panel fails
outright (`-11848` / `-11868`) instead of switching or tone-mapping. AVKit's
`appliesPreferredDisplayCriteriaAutomatically` cannot help here: it derives
criteria from the chosen variant's format description, which only exists after
the variant passes the very validation the switch has to precede. So it must be
`false`, and the order is engine-driven:

```swift
let controller = DisplayCriteriaController(window: window)   // tvOS only
let session = try PrismCoreSession(url: source, display: .current())
let playlist = try await session.start()

if let choice = await session.displayCriteria {
    controller.apply(choice)                 // 1. program the panel
    await controller.waitForSwitch()         // 2. let the handshake settle
}
player.replaceCurrentItem(with: AVPlayerItem(url: playlist))  // 3. only then load
player.play()
// on teardown: controller.reset()
```

`session.displayCriteria` is clamped to the display the session was built for: a
non-DV panel is asked for the base layer's range, a non-HDR panel for a rate-only
switch — which is also what makes **Match Frame Rate** engage on SDR content.
After the handshake, `controller.currentPanelIsHDR()` is the value to feed back
into `DisplayCapabilities(panelIsCurrentlyHDR:)` for the next session.

Built-in panels (iPhone, iPad, Mac) engage HDR on demand and skip all of this.
`PrismCoreSession.isMasterRejection(_:)` plus `makeMuxedFallbackSession()` stays
as the backstop for the one state no API can prove: Match Content switched off on
an HDR-capable panel.

## How it works

```
                                    ┌─► video ──► fMP4 segments + index.m3u8
Source URL ──► libavformat demux ───┼─► audio 0 ─► audio0/{init.mp4,seg*.m4s,index.m3u8}
                                    ├─► audio N ─► audioN/…              │  tmp dir
                                    └─► subs  N ─► subsN/seg*.vtt        │
                                              master.m3u8 ───────────────┤
                                                                         ▼
                                                          LoopbackHTTPServer ──► AVPlayer
```

The segmentation is ours. MPVKit's libavformat is built without the `hls` muxer,
so `FMP4SegmentWriter` drives the `mp4` muxer with `frag_custom` and cuts where we
say (video keyframes at or after each 6 s boundary), and `MediaPlaylistWriter`
turns those fragments into a playlist. Two production modes exist:

- **Planned (demand-driven)** — the default for seekable VOD. `SegmentPlan` maps
  every segment upfront from the demuxer's keyframe index (trusted only past two
  witnesses: max keyframe gap 60 s, coverage ≥ one target duration), complete
  `PLAYLIST-TYPE:VOD` playlists are published before the first packet, and a fetch
  outside the producer's window re-anchors it — `av_seek_frame` to the anchor
  keyframe, fresh muxers with `frag_discont` + `avoid_negative_ts=disabled` so
  `tfdt` carries absolute time and the produced segment sits exactly where the
  playlist promised. After EOF the producer parks and keeps answering demand for
  segments a re-anchor skipped.
- **Sequential** — an EVENT playlist growing head-to-EOF. Used when no trustworthy
  plan exists (live, unknown duration, junk index) and for the muxed-with-bridge
  shape, where re-anchoring would reset an encoder mid-fragment.

A source whose container carries no usable index (a Matroska without Cues, any
MPEG-TS) is stuck sequential on its first play — but the producer reads every
packet anyway, so with `keyframeIndexCacheDirectory` set on the session it
harvests the keyframe map as a by-product and persists it (keyed by URL sans
query + size + duration; bounded LRU). The next play of the same source plans
on that map from its first second, as if the file had an index — and a cache
hit skips the index-load seek entirely.

The loopback server speaks HTTP/1.1 with keep-alive (bounded per connection and by
an idle timeout), `GET` + `HEAD`, and pipelined requests. Payloads come from a
`SegmentProvider` rather than straight off disk, and a provider that answers
`.pending` gets an early `200` + `Transfer-Encoding: chunked` once a serve passes
2 s — keeping response headers inside AVPlayer's ~3.5 s media watchdog window. A
pending serve that ultimately fails aborts the connection (a truncated transfer
makes AVPlayer retry) instead of framing a cacheable empty `200`.

### Design notes

The things that were expensive to learn, kept here so the next person doesn't pay
for them twice.

**Atmos needs a box FFmpeg drops.** The `CHANNELS="16/JOC"` playlist attribute is
necessary but it is not what engages Atmos. AVFoundation takes the Dolby/MAT route
only when the **`dec3` box** in the init segment carries the TS 103 420 type-A
extension — and FFmpeg's mp4 muxer drops that extension on a stream copy (plain
`ffmpeg -c copy` does the same). So `EAC3Syncframe` reads `complexity_index_type_a`
out of the bitstream's `addbsi` and `EAC3Configuration.patch` appends it to the
produced init segment, re-framing every enclosing box's size. Field placement
follows libavcodec's `ac3_parser.c` rather than a reading of the spec, and that
mattered three times over: the JOC signal can sit in a *dependent* substream
(Blu-ray-style DD+ puts it there, behind an AC-3 core frame), a dependent substream
carries a `chanmap` field an independent one doesn't, and both the converter-sync
bit and the whole mixing-substream block exist on independent substreams only. Each
omission shifted the walk by a bit or two — and a shifted walk does not fail, it
returns a confident wrong number.

**`hvc1` is a promise the record has to keep.** A stream-copied HEVC track is given
an `hvc1` sample entry explicitly, because FFmpeg's mp4 muxer defaults HEVC to
`hev1` and Apple's HLS rules want `hvc1`. But `hvc1` also asserts that every
parameter set lives in that entry, and Matroska `CodecPrivate` routinely says
otherwise (`array_completeness = 0`) — so `HVCCNormalizer` rewrites the record to
VPS/SPS/PPS in order with completeness asserted. It runs **twice**: once on the
input extradata, and again on the produced init segment, because movenc doesn't
copy our record into the sample entry, it rebuilds one and re-zeroes the flag while
still naming the entry `hvc1`. Sources that keep their parameter sets in band
(`numOfArrays = 0`, common in MP4 and MPEG-TS) get them harvested off the first
keyframes and filled in, since an empty `hvcC` under an `hvc1` entry promises Apple
a decoder configuration that isn't there.

**Dolby Vision is three separate claims that must agree.** The manifest's `CODECS`,
the sample entry's fourcc, and the `dvcC`/`dvvC` box all describe the same track,
and AVPlayer checks them against each other. Profile 5 gets `dvh1` as its sample
entry — its picture is IPT-PQc2, not YCbCr, and an `hvc1` entry over P5 renders the
familiar green-and-purple — while 8.x deliberately keeps `hvc1`, because its base
layer really is plain-HEVC-compatible and the `dvvC` box is what upgrades it.
Claiming `dvh1` there would deny the very fallback that makes 8.1 worth having.
The boxes themselves need `-strict unofficial`: they are Dolby's specification
rather than ISO's, movenc refuses to write them by default, and a DV source without
them is HDR10 with extra bytes.

**WebVTT timing states a fact, not a convention.** HLS bridges cue times to the
media timeline with `X-TIMESTAMP-MAP=MPEGTS:<t>,LOCAL:<local>`. Our fMP4 segments
carry the source's own stream-copied timestamps, so the media timeline starts at the
first video PTS — there is no MPEG-TS 10 s convention to honour, and assuming one is
exactly what makes fMP4 subtitles render ten seconds late in other implementations.
PrismCore writes cue times relative to the presentation origin and repeats
`MPEGTS:round(origin × 90000),LOCAL:00:00:00.000` in every segment.

**A flagged interlaced source is often lying.** Broadcast H.264 is routinely flagged
interlaced around progressive frames, so the probe decodes a handful of frames before
believing the flag. Evicting those from the native path would trade hardware decode
and Atmos passthrough for deinterlacing nothing.

## Non-goals

Deliberate omissions, so you don't have to read the source to find them:

- **No UI.** No view, no transport bar, no controls, no HUD.
- **No published playback state.** The remux path is a service: it hands you a URL
  and gets out of the way. Your `AVPlayer` remains the source of truth for time,
  rate and status.
- **No subtitle rendering.** Text becomes WebVTT renditions AVPlayer selects
  itself; bitmap tracks are surfaced for a host that wants to draw them.
- **No playlist or queue management.** Make a new session for the next title.
- **No analytics.** Nothing leaves the device, and nothing phones anywhere.
- **No re-encoding of video, ever.** If a frame would have to be touched, that
  source belongs on the software path or somewhere else entirely.

## Requirements

| | Min |
| --- | --- |
| iOS | 16.0 |
| tvOS | 17.0 |
| macOS | 14.0 |
| visionOS | 1.0 |
| Swift | 6.0 |

FFmpeg arrives through [MPVKit](https://github.com/mpvkit/MPVKit)'s **dynamic**
xcframeworks — no FFmpeg source is redistributed here and nothing needs building.
Dolby Vision RPU conversion goes through
[libdovi](https://github.com/quietvoid/dovi_tool), which MPVKit already links.

A host that already ships MPVKit adds **zero new binary dependencies**. One gotcha
if that host vendors its own MPVKit fork: SPM derives a path dependency's identity
from its *directory name*, so the fork's directory has to be called `MPVKit` for it
to override the `mpvkit` identity PrismCore asks for.

### Which FFmpeg answered

`FFmpegBuild` reports the build that is actually loaded — a line per linked
library with the header version beside it whenever the two disagree, FFmpeg's own
version string, and the capability answers that change what this engine does with
a source: the `eac3` encoder (without it the audio bridge cannot run), the AV1
decoder and whether this device has hardware for it, dialogue boost, and the GPU
deinterlacer:

```swift
print(FFmpegBuild.summary)
// FFmpeg n8.1.2
//   libavutil 60.26.102
//   libavcodec 62.28.102
//   …
//   eac3 encoder: NO — audio bridge disabled
//   av1 decoder: libdav1d (hardware: no)
//   dialogue boost: no
//   gpu deinterlacer: none — CPU route
```

Worth a line in a host's launch log and worth attaching to a bug report: half of
what this engine decides is a question about the build rather than the media, so
"audio track is missing" is often unreproducible until you know which FFmpeg was
asked. A host that vendors its own fork should also assert `FFmpegBuild.isABIMatched`
once — a **major** version apart from the headers PrismCore compiled against means
the public structs this engine walks on every packet may be laid out differently,
which surfaces as wrong pixels and wrong timestamps rather than as an error.
PrismCore logs and reports that state but does not refuse to run on it.
`FFmpegBuild.configuration` carries libavcodec's full `configure` line for the
report.

## Stability and versioning

PrismCore follows [Semantic Versioning](https://semver.org). Every `public`
declaration in `Sources/PrismCore/` is the stability contract; `internal` types are
not. Since 1.0.0 that contract is a promise: breaking changes bump the major,
features the minor, fixes the patch — so the ordinary pin is the right one:

```swift
.package(url: "https://github.com/Wenzlik/PrismCore.git", from: "1.0.0")
```

Hosts that archive through Xcode Cloud (or any CI with automatic resolution
disabled) should pin an exact version and keep their committed `Package.resolved` in
step with it. A `from:` range lets local resolution ride ahead to a newer tag while
the pinned file stays put, and then a device build and a TestFlight build are quietly
running different engines.

Every release is listed in **[CHANGELOG.md](CHANGELOG.md)**.

## Integrating it

PrismCore is **LGPL-2.1-or-later with an Application Store Exception** (see
[`LICENSE`](LICENSE) and [`NOTICE.md`](NOTICE.md)). In practice, for the two cases
that come up:

**Shipping a closed-source app, including on the App Store.** Add the package, use
it, ship it. The exception exists precisely for this: LGPL section 6 asks that your
users be able to relink your app against a modified PrismCore, which a signed `.ipa`
cannot allow, and the exception releases you from that requirement for store
distribution. Two things are asked of you in return:

1. If you **modify PrismCore itself**, those modifications stay LGPL and have to be
   published. Using it unmodified — the normal case — carries no such obligation for
   your own code.
2. Say so somewhere a user can find it (an About screen, an acknowledgements page):
   that your app includes PrismCore, under which licence, and where the source
   lives. Aether's About screen is a worked example.

**FFmpeg is a separate obligation, and it is not new.** The exception covers
PrismCore's own code only. FFmpeg reaches your app as dynamically linked frameworks
under plain LGPL-2.1-or-later, which is satisfiable for a closed-source store app —
that is what every FFmpeg-based app on the App Store already does — provided you
embed them *dynamically*, ship the licence texts, and point at the build's source.
If you already ship MPVKit, you are already doing all three.

Why LGPL rather than something permissive: `Sources/PrismCore/Remux/EAC3Syncframe.swift`
was written by reading FFmpeg's `ac3_parser.c`, because the placement of the Atmos
signal in `addbsi` cannot be derived reliably from the specification alone — three
attempts from the spec produced a confidently *wrong* answer. That makes the file
realistically a derivative of LGPL code, and [`NOTICE.md`](NOTICE.md) says so out
loud rather than hoping nobody looks.

## Status

Shipping, and pre-1.0 for the reason the version number suggests: the API is still
free to move, and two headline claims are proven by construction rather than by a lab.

The test suite is 253 tests across 44 suites, hermetic apart from an opt-in
real-media harness. It exercises the playlists, the loopback server, the subtitle
renditions and the audio bridge's decode → resample → FIFO → encode chain, plus
end-to-end remuxes of synthetic fixtures: a two-language master (AAC eng + AC3 ces)
is served over the loopback, re-probed through libavformat's `hls` demuxer with both
codecs and both languages intact, and reaches `.readyToPlay` in a real `AVPlayer`.
Bitmap-subtitle OCR is verified against a real Blu-ray remux, where the served
segments read back the film's own SDH cues.

Being precise about the two headline claims, because "implemented" and "proven" are
not the same thing. **Atmos**: EAC3+JOC stream-copies (proved on a fixture — the
codec survives the round-trip), the rendition declares `CHANNELS="16/JOC"` (the rule
is unit-tested), and the served `dec3` declares complexity index 16 on Dolby's own
demo file. Whether the objects reach a receiver over HDMI is a device question.
**Dolby Vision**: the whole signaling path exists and every rule is pinned by a unit
test, but a synthetic fixture cannot carry an RPU, so Profile 7 conversion is
established only as far as "the library links and the code runs". Both want a device
and real media, and that is what the Aether integration is currently buying.

The software path is exercised headless as far as it can be — the VP9 fixture decodes
to `CVPixelBuffer`s of the right shape on a monotonic, source-anchored timeline, and
the pipeline runs demux → decode → stamp → back-pressure → enqueue against renderer
stand-ins, including the case where a stalled video renderer must not starve audio.
Audio track switching is proven the same way: the multi-audio fixture's tracks differ
in channel count (AAC stereo vs AC-3 5.1), so the renderer-side buffers *show* which
track is playing, and the video assertions show the switch never touched the picture.
Text selection is tested against embedded full/forced subtitle tracks, including
paused switching, Off, expiry and a backward seek. What no headless test can
assert is that a frame reached a display or an audio switch was inaudible on a
device. Caption rendering belongs to the host; frame-accurate seek remains open.

## Cache, audio diagnostics and HTTP policy

```swift
let session = try PrismCoreSession(
    url: sourceURL,
    display: .current(),
    audioDelaySeconds: 0.150,       // present audio 150 ms later
    coordinatedHTTP: true          // optional; finite HTTP(S) Range files only
)
let playlist = try await session.start()
let ranges = session.residentRanges
let routes = session.audioTrackDeliveries
let preview = try await session.cachedThumbnail(at: sourceSeconds)
```

`residentRanges` and `cachedThumbnail` use **source timestamps**, including a
nonzero source origin where present. A host must map these onto its player
timeline. These are video-cache ranges, not AVPlayer's loaded ranges or a
promise that a seek has no latency. Cache misses return `nil` without asking
the source for data; previews show the segment's opening picture. Fragments
above 64 MiB also return `nil`. The image cache holds at most 16 MiB / 32 images.

`audioDelivery` summarizes available base routes, while `audioTrackDeliveries`
lists each source track, including an unavailable one. The host owns actual
AVPlayer track selection. A `.bridged` route describes its constructed pipeline;
its `bridge` counters show whether output has actually been produced. Zero
output during priming is normal. A terminal, completely drained silent bridge
raises `AudioBridgeFailure.producedNoAudio` through the session error path.
The software pipeline exposes `.decoded` only after its decoder opens.

Audio delay is fixed at construction and preserved by fallback factories.
Changing it during playback requires a replacement session and a host-managed
handover at the current position. Both positive and negative offsets are bounded
to two seconds; this does not add an AVPlayer transport controller to PrismCore.

`coordinatedHTTP` is also available on `PrismCoreEngine.open`,
`SourceProbe.open/openDetached`, `SeekPreviewService` and software `load(url:)`.
Enable it consistently for the readers that should share a server's request
budget. The default remains native FFmpeg I/O. The optional reader uses bounded
1 MiB Range requests and requires valid `206`/`Content-Range` replies; it is not
for live streams, nested HLS playlists or Range-less servers. A redirected
request gets its destination's budget, drops caller headers on a cross-origin
redirect, and refuses HTTPS-to-HTTP downgrade. Thus an authenticated redirect
requiring forwarded custom headers should use the default transport or a final
URL supplied by the host. CDN performance has not been benchmarked.

To run the picture-based seek check on a Mac with AVFoundation rendering:

```sh
PRISMCORE_RENDERED_SEEK=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter pictureMatchesPlayerClockAfterSeeks
```

The committed `seek_clock.mkv` has a reproducible generator beside it and runs
through a throttled, Range-capable test origin. The check reads actual decoded
frame numbers after seeks; it does not infer success from muxer timestamps.

## Support

Questions, integration help and bug reports:
**[GitHub Issues](https://github.com/Wenzlik/PrismCore/issues)**.

## Author

**Václav Zmrhal** — [zmrhal.cz](https://zmrhal.cz)

Written for [Aether](https://aetherplayer.com), where PrismCore is the engine that
lets an MKV keep its Dolby Atmos and Dolby Vision instead of losing both on the way
to the screen.

Built in close pair-programming with **Claude** (Anthropic); the commit log carries
the receipts.

## Licence

Copyright © 2026 Václav Zmrhal.

[LGPL-2.1-or-later with an Application Store Exception](LICENSE). See
[Integrating it](#integrating-it) for what that means in practice, and
[`NOTICE.md`](NOTICE.md) for the third-party components and their terms.
