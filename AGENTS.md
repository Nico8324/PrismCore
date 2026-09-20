# AGENTS.md — guide for AI contributors

This file is the contract between PrismCore and any AI coding agent working on
it — **Claude Code**, **Codex**, **Gemini**, **Copilot**, **Cursor**, or
whatever opens this repository next. Read it in full before changing anything.
Humans: it works as onboarding too.

---

## Fast read order

1. [`README.md`](README.md) — what the engine handles and how to call it
2. `AGENTS.md` *(this file)* — how we work, and what has already bitten us
3. [`CHANGELOG.md`](CHANGELOG.md) — what actually landed, newest first

Then open Swift files, starting from `PrismCoreSession` (the front door).

### The engine in one paragraph

PrismCore turns media `AVPlayer` cannot open into media it can. The **remux
path** (the main one) demuxes with libavformat, stream-copies video and audio
into HLS-fMP4 on disk, and serves it from a loopback HTTP server — so the host
plays a plain `AVPlayer` and keeps hardware decode, PiP, AirPlay, native track
selection and the tvOS display handshake. Nothing is re-encoded, so Atmos stays
object audio and Dolby Vision stays Dolby Vision (Profile 7 is converted to 8.1
in flight). The **software path** is a real player for what AVPlayer cannot
decode at all (VP9, MPEG-2, VC-1, verified-interlaced H.264): libavcodec into an
`AVSampleBufferDisplayLayer` with its own clock. `PrismCoreEngine.decide` picks
between them; a host that has no surface for the software path can decline it
and route elsewhere.

---

## House rules

- **Never copy code from AetherEngine.** It is prior art we study for
  *approach* only (LGPL-3.0 vs our LGPL-2.1+, and it is someone else's work).
  Read it, describe the mechanism in your own words, then design ours. Saying
  "convergent with AetherEngine" in a PR is good; lifting a function is not.
- **Comments explain *why*, never *what*.** A comment that restates the line
  above it is noise. A comment that records the failure a line prevents is the
  most valuable thing in this repo — most of the notes below started as one.
- **Claims need evidence.** "This is faster" means a measurement in the PR body.
  "This works" means a test or a named device run. See *Measuring* below for the
  trap that already caught us once.
- **Every release gets a CHANGELOG entry**, and every changed behaviour gets its
  reasoning recorded — including the things we tried and reverted, which are
  often more useful than what shipped.

---

## Field notes — the things that cost hours

These are all real. Each one was found the hard way; none is obvious from the
API surface.

### FFmpeg / libavformat

- **`AVCodecParameters.profile` is a claim, not a fact — never gate behaviour
  on it.** `AV_PROFILE_EAC3_DDP_ATMOS` appears only when
  `avformat_find_stream_info` happened to decode an E-AC-3 frame while
  sampling, and `SourceOpenTuning` caps that sampling at 4 MB / 2 s, so a
  sparsely interleaved UHD remux can analyse clean with the flag unset. The
  JOC declaration used to be gated on it and silently downgraded real Atmos to
  DD+; `EAC3Syncframe` reads the bitstream instead, on every stream-copied
  E-AC-3 track, and `ObjectAudioFinding` publishes what it found. The same
  caution applies to any other profile-derived verdict.
- **`avformat_find_stream_info` is not optional, and not just knowledge.** It
  also fills fields the *muxer* needs — an EAC3 track's frame size most
  sharply. A context that skipped it produces a perfectly correct-looking
  manifest and then fails on `av_interleaved_write_frame` (`-22`). This is why
  the probe hands over its **context** (`ProbedSource`), never merely its
  conclusions. Tried the other way in 1.1.2; reverted the same day.
- **`interrupt_callback` must be set BEFORE `avformat_open_input`.** The read
  path checks `URLContext.interrupt_callback` (`libavformat/avio.c:515`), which
  is populated when the context is created (`avio.c:189`). Setting it on the
  `AVFormatContext` afterwards reaches only the few places that read
  `s->interrupt_callback` directly — *not* the blocking reads. 1.1.1's bounded
  index-load seek made exactly this mistake and bounded nothing; since 1.3.1
  every open site installs a permanent, disarmed `ReadInterruptGuard` at
  `avformat_alloc_context` time, armed around the bounded operations — the
  index-load seek, thumbnail seeks, and (since 1.8.2) the whole probe and the
  remuxer's fallback open, because a server that accepts and then starves the
  reads had left the host with neither a verdict nor an error for minutes.
  Three corollaries: the guard must travel with an adopted context
  (`ProbedSource` carries it); an aborted read latches `AVERROR_EXIT` in
  `AVIOContext.error`, which has to be cleared before the context can read
  again; and `avformat_find_stream_info` SWALLOWS aborted reads — cut off
  mid-analysis it returns success with half-filled parameters, so an expired
  budget has to be checked on the clock, not inferred from the return code.
- **Container-level aspect ratio lives on `AVStream.sample_aspect_ratio`**, not
  in codecpar. An MKV's `DisplayWidth`/`Height` — how anamorphic DVD rips are
  tagged — is dropped by a codecpar-only copy. FFmpeg's *own* hls demuxer has
  the same bug (`hls.c:2040`), which is why the SAR test asserts on the `pasp`
  box bytes of the served init segment rather than re-probing the playlist.
- **A Matroska without Cues turns any timestamp seek into a linear scan** of
  the whole container. On a 5.4 GB file over SMB that is 66 s for one seek. Do
  not assume a seek is bounded because the file is "local".
- **`AV_FRAME_FLAG_INTERLACED` is `1 << 3`.** `1 << 2` is `DISCARD`. Using the
  wrong one makes every stream look progressive and the mistake is invisible
  without a test.
- **A subtitle codec context needs `pkt_timebase` set before `avcodec_open2`**,
  or `AVSubtitle.pts` stays `NOPTS` and every decoded event is silently
  dropped. Cost: 2000 PGS packets, 0 cues, no error anywhere.
- **`av_seek_frame` trips assertions in `matroskadec.c`** with nested elements;
  prefer `avformat_seek_file`, and flush after seeking.
- **There is no libavformat API for a container's byte layout.** Where a
  header ends and where the first media element starts are not derivable from
  an `AVFormatContext`: `avio_tell` after the open is the *probe buffer's*
  position, not the header's length, and a first packet's `pos` is a
  per-demuxer convention (the cluster for one format, the block for another).
  `ContainerLayoutScanner` walks the top-level element framing by hand for
  exactly this reason — IDs and declared lengths only, never a payload — and
  the numbers it produces cross a network to a process that cannot check
  them, which is why the export says `unknown` for everything it did not
  measure. `IndexLocation.none` and `IndexCompleteness.absent` need positive
  evidence that a container declares no index; **an empty index table at open
  is not that evidence** (a Matroska's Cues are at the tail and nothing has
  read them yet), and reporting `none` from silence sends a consumer straight
  past a real index.

### Building the FFmpeg xcframeworks

- **A build can succeed and silently ship without the feature you built it
  for.** FFmpeg's configure does not fail on an unmet filter dependency — it
  logs `WARNING: Disabled <x> because not all dependencies are satisfied: …`
  and carries on. Check `config_components.h` for the `CONFIG_*` define (filter
  and codec defines live there, not in `config.h`) **before** publishing
  anything. Two full builds were published-ready and useless before this rule
  existed.
- **The Metal toolchain is registered to one Xcode.** `yadif_videotoolbox`
  needs Metal, which in Xcode 26 is a separate download
  (`xcodebuild -downloadComponent MetalToolchain`) installed as a *cryptex
  mount* tied to a single Xcode installation. Point `DEVELOPER_DIR` at a
  different one and `xcrun metal` fails — which is easy to do, because
  `DEVELOPER_DIR` also has to be set for an unrelated reason (below). Check
  with `xcrun -sdk macosx metal --version` **under the same `DEVELOPER_DIR` the
  build will use**.
- **MPVKit's build scripts sanitize their subprocess environment**, dropping
  `DEVELOPER_DIR` — so every `xcrun --sdk …` resolves against `xcode-select`,
  which on a machine with Command Line Tools installed means no tvOS/xrOS SDK
  and a build that dies partway through. Patch `Utility.launch` to propagate it.

### Muxing to fMP4 (`FMP4SegmentWriter`, `HLSRemuxer`)

- **movenc defaults HEVC to `hev1`, not `hvc1`.** Apple's HLS rules want
  `hvc1`, and `HVCCNormalizer` asserts `array_completeness = 1`, which
  contradicts `hev1` — movenc resolves that by writing **no `hvcC` box at
  all**. Set the fourcc explicitly.
- **The `hvcC` is normalized twice on purpose**: on the input extradata, and
  again on the produced init segment, because the muxer rebuilds the record
  when it writes the sample entry.
- **`delay_moov` is mandatory for EAC3.** movenc builds the `dec3` sample entry
  from parsed packets and refuses an up-front moov.
- Dolby Vision Profile 5 needs the `dvh1` fourcc — an `hvc1` entry over P5
  decodes to green-and-purple. Profile 8.x deliberately keeps `hvc1`, because
  its base layer *is* the fallback.

### Threading

- **The producer owns a thread; never put it back on the pool.**
  `HLSRemuxer.run()` blocks in FFmpeg reads and then parks at EOF for the whole
  session, so it runs on a `ProducerThread`, not a `Task.detached`. On the
  cooperative pool it holds a thread for the length of a film, and several
  sessions at once park enough producers to saturate the pool — at which point
  the async work that would release them (`stop()`, a demand fetch) cannot run
  and everything deadlocks. That was a suite hang, once in four runs (#44).
  Tests that drive `HLSRemuxer` directly use `ProducerThread` for the same
  reason.
- **A condition signal needs a state change behind it.** `DemandCoordinator`'s
  park is woken by `requestProduction` (which sets `requestedAnchor` under the
  lock) or by `cancel()` — which sets its flag *first* and then calls `wake()`.
  A bare `wake()` can be lost to a producer that has not yet reached its wait,
  which is what the one-second backstop in `waitForAnchorRequest` is for: a
  safety net, not the mechanism.

### tvOS display handshake (`DisplayCriteriaController`)

- Criteria must be programmed and settled **before** the host loads the
  playlist. tvOS validates an HDR variant's `VIDEO-RANGE` against the panel's
  *current* mode, synchronously — a PQ master handed to an SDR-parked panel
  fails outright (`-11868`), it does not switch or tone-map.
- **The in-progress flag clearing is ambiguous on an HDR target.** A panel that
  finished quietly and one that aborted the switch look identical at that
  moment. Since 1.1.0 the settle keeps watching for a real HDR signal and
  reports `clearedWithoutHDRSignal` if none comes.
- Panels advertise HDR they cannot usefully *display*. One 1080p set in the
  field accepts HDR10 and shows it washed out; the honest answer there is SDR,
  and the rejection fallback already produces it.

---

## Measuring

There is an opt-in harness: `StartupCostBenchmark`, enabled by pointing
`PRISMCORE_BENCH` at real media (a path **or an `http://` URL`**). It breaks
startup into probe / second open / `start()` / first fetch.

**Measure over HTTP, not a mounted share.** This already caught us out: an
SMB-mounted file reads locally and cached, so the double-open measured as 21 ms
of noise and the conclusion ("not worth fixing") was wrong. The same work over
HTTP was hundreds of milliseconds, twice per playback. Hosts reach media over
the network; benchmark the transport they actually use.

Byte-counting through a toy HTTP server is unreliable for the same class of
reason: an open-ended range means the server keeps writing until the client
hangs up, so "bytes served" includes socket slack and varies run to run. Prefer
repeated timings with a warm cache, and report the spread, not one number.

**Model the host's proxy, not just the origin.** Aether does not hand this
engine a server URL — it hands it a localhost range proxy, and that proxy
fetches each forwarded window *whole* before it writes a byte (8 MB bites).
FFmpeg's HTTP asks for `bytes=N-`, so every open and every backward seek waits
for a full bite: on the 2026-09-19 field log, 10.5 s for the open and another
for the plan's rewind, from a source whose header is a few kilobytes. A
Range-capable server that answers immediately hides this completely.
`Scripts/proxy-model-server.py` is that origin, and
`StartupCheckpointBenchmark` prints the host's own log line against it; the
number that matters is **requests × bite**, not bytes.

**The benchmark server must support Range requests.** `python3 -m http.server`
does not — it answers every Range with a 200 and the whole file, libavformat
concludes the stream cannot seek, the Matroska Cues at the tail never load, and
every plan silently degrades to the uniform basis (no demand mode at all). The
same file over a Range-capable server plans on the keyframe index. If a
benchmark shows `basis=uniform` on a file that has Cues, suspect the server
before the planner.

---

## Testing

- Swift Testing. `swift test --filter` matches **function names**, not the
  display strings in `@Test("…")`. Filtering on a suite title silently runs
  nothing ("No matching test cases were run").
- Some tests need Xcode's toolchain rather than the Command Line Tools —
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. A
  missing `Testing.framework` at *runtime* is this, not a broken test.
- **Opt-in harnesses for what a fixture cannot carry**, gated on an environment
  variable so CI stays hermetic:
  - `PRISMCORE_MEDIA` — real-media probe/DV verification
  - `PRISMCORE_PGS_MEDIA` — the OCR subtitle pipeline (no FFmpeg build can
    *encode* PGS, so there is no committable fixture)
  - `PRISMCORE_BENCH` — startup cost
- Fixtures are synthetic (`testsrc2` + `sine`), generated with system `ffmpeg`
  and committed under `Tests/PrismCoreTests/Fixtures/`. They prove the
  pipeline, never the premium claims — Atmos and Dolby Vision need real media
  and a device.

### Fuzzing

Every hand-written bitstream parser (JOC walk, `dec3`, HEVC NAL framing,
`hvcC` normalization, ISO-BMFF splice, text subtitles) is wired into
`FuzzTargets` (`Sources/PrismCore/Fuzz/`) — uniform `bytes in → invariants
checked` entry points, `package` access so the test target and the fuzzer
executable share them. A target checks *wrong-answer* invariants, not just
crashes: rewrite round-trips, normalize idempotence, splice re-locatability,
WebVTT safety. New parser → new target + seed in `FuzzSeeds.corpus`, and the
`seedsAreAccepted` test must prove the seed reaches the deep path.

Three ways to run it:

- `FuzzSmokeTests` — always on, deterministic, sub-second. CI-grade floor.
- `swift run prismcore-fuzz hunt <target|all> [seconds] [rng-seed]` — blind
  mutation of the seed corpus, bounded by time. Prints its rng-seed so any
  crash reproduces. This found the `<i-->` cue escape in under a minute.
- `swift run prismcore-fuzz run <target> <files…>` — replay saved inputs
  (crash artifacts, corpus files).

**Xcode's Swift toolchain cannot build the coverage-guided shape** — it ships
no fuzzer runtime, and `-sanitize=fuzzer` is rejected outright ("unsupported
option"), which is why `hunt` exists. On a swift.org toolchain the libFuzzer
entry point builds with:

```
swift build --product prismcore-fuzz \
  -Xswiftc -DLIBFUZZER -Xswiftc -parse-as-library \
  -Xswiftc -sanitize=fuzzer,address
PRISMCORE_FUZZ_TARGET=<target> .build/debug/prismcore-fuzz corpus/
```

(The `LIBFUZZER` define swaps out the CLI `main` — libFuzzer brings its own.)

---

## Releasing

1. Land the change with a CHANGELOG entry under a new version heading, plus the
   link at the bottom of the file.
2. `git tag X.Y.Z` — **always three components**. SPM only resolves full semver
   tags; a `1.2` tag is invisible to consumers. (Release *titles* may drop a
   trailing zero if you like; tags may not.)
3. `gh release create X.Y.Z` with notes that say what changed and why. Since
   1.0.0 this project follows full semver: breaking → major, feature → minor,
   fix → patch.
4. **Bump the host pin in two places or not at all.** Aether pins PrismCore
   exactly, in `project.yml` (`exactVersion:`) *and*
   `ci_scripts/Package.resolved.pinned`. Bumping one silently gives devices and
   TestFlight different engines — that happened (local 0.1.11, cloud 0.1.6) and
   is why the pin is exact.

---

## Repository shape

```
Sources/PrismCore/
  PrismCoreSession.swift     the front door: start() → playlist URL, stop()
  PrismCoreEngine.swift      decide(for:) — remux vs software vs decline
  Probe/                     SourceProbe, ProbedSource, DisplayCapabilities,
                             SourceOpenTuning (read caps)
  Remux/                     HLSRemuxer (the producer), FMP4SegmentWriter,
                             AudioBridge, SegmentPlan, DemandCoordinator
  Loopback/                  LoopbackHTTPServer + segment providers
  Subtitles/                 WebVTT renditions, bitmap decode + OCR
  Display/                   tvOS criteria + settle
  Software/                  the decode-and-render path
Tests/PrismCoreTests/        Swift Testing, fixtures, opt-in harnesses
```

The host contract is deliberately small: build a session, `start()`, play the
URL, `stop()`. Everything else is the engine's business.
