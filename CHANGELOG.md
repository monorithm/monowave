# Changelog

All notable changes to monowave are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
follows [semantic versioning](https://semver.org/spec/v2.0.0.html).

0.3.0 is the first version published to pub.dev. 0.1.0 through 0.2.0 were
development milestones, kept here because what changed in them is still the
history of this API.

## Unreleased

### Fixed: a dropped capture session kept the microphone open

`FfiCaptureSession` had no finalizer, so `wf_capture_destroy` ran only from an
explicit `dispose()`. A consumer that dropped a session without one leaked the
`wf_capture` struct, both lock-free rings, the preallocated take history and the
two drain buffers - and, worse, left the platform input device open, so the
microphone stayed live for the rest of the process. The decoded-peaks path had
had a `NativeFinalizer` since it was written; capture never got one.

It does now, over `wf_capture_destroy`, which stops the device before it frees
anything. Two things had to change for it to be able to do its job:

- **The drain buffers moved into C.** They were `calloc`ed from Dart and freed
  in `dispose()`, which is exactly the memory a finalizer cannot reach: a
  `NativeFinalizer` over `wf_capture_destroy` frees what the C struct owns and
  nothing else. `wf_capture_scratch` and `wf_capture_pcm_scratch` now hand out
  buffers allocated with the session, so everything it owns hangs off one
  pointer and one call reclaims all of it.
- **The drain timer holds the session weakly.** A pending `Timer.periodic` is a
  GC root, and its callback captured `this` - so a session dropped *while
  recording* stayed reachable forever and would never have been collected at
  all. That is the case where the leak matters most, because the device is
  still open. The timer now cancels itself on the first tick after the session
  goes away.

`dispose()` remains the contract, and the documentation still says to call it.
A finalizer runs whenever the collector gets to the object, which may be long
after the recording ended and is not guaranteed before the process exits.
Nothing but `dispose()` releases the microphone promptly.

Also fixed alongside it: an unwritable `CaptureConfig.recordTo` path leaked the
session outright, because it threw between `wf_capture_create` and the
constructor - with no Dart object in existence yet for a finalizer to attach to.

### Fixed: disposing a session left a corrupt recording and a freed pointer

Two loose ends around `CaptureSession.dispose`, both found while adding the
finalizer above, and both behaviour changes in their own right.

**It never closed the recording file.** `stop()` rewrites the WAV header with
the real sizes and closes the file; `dispose()` did neither. Opening with
`CaptureConfig.recordTo` and disposing without stopping - which is what
cancelling a recording looks like - leaked the open handle and left a WAV whose
header still claimed the audio after it was zero bytes long, so every player
opened it and showed nothing. `dispose()` now closes it the same way `stop()`
does, and an abandoned take is playable rather than corrupt. It deliberately
does not drain first: finishing a take is still `stop()`'s job, and whatever the
audio thread published since the last pass is lost. The close is idempotent, so
the ordinary `stop()` then `dispose()` sequence is unaffected.

**`produced`, `dropped`, `pcmDropped` and `truncated` read freed memory after
it.** All four read straight out of the C struct, which `dispose()` frees. They
now answer from a tally frozen at disposal. Frozen rather than throwing, unlike
`start` or `feedSynthetic`: a counter is a query with a correct answer after
disposal, and `FakeCaptureSession` already answered it - so a host whose
visualizer read one while tearing down would have passed its widget tests and
then read freed memory against a real microphone. `isRecording` and `isPaused`
are now false after disposal too, on both the real session and the fake.

### Fixed: `peaks.rms(level)` was null on web, and only on web

RMS landed in 0.3.0 and reached five of the six targets. `wf_peaks_rms` was
never added to `-sEXPORTED_FUNCTIONS` in `tool/build_wasm.sh`, the `_Core`
extension type in `lib/src/platform/wasm_platform.dart` never declared it, and
`_copyOut` built its `WaveformPeaks` without an `rms:` argument - so on web
every level answered null while the same C source, over `dart:ffi`, returned
the series. A two-layer waveform lost its core on the one target that could not
be checked against a digest, and the package's claim to be byte-identical
everywhere was, for that release, not true.

All three are fixed, and the artifact did not have to change: `WF_EXPORT` marks
the symbol `visibility("default")`, so `wf_peaks_rms` was in the committed
`assets/monowave.wasm` export table the whole time. Nothing was missing from the
binary. What was missing was anything that looked.

**The determinism check now covers it, because it did not.** The FNV-1a digest
in `test/fixtures.dart` hashed the min/max levels alone, so the one check whose
job is to prove the two bindings agree was blind to an entire series - it stayed
green through the whole of 0.3.0. It now takes a `WaveformPeaks` and folds in
both series at every level, and it throws rather than skipping when a level has
no RMS, since a binding that never read the series is exactly what it exists to
catch. `tool/verify_wasm.mjs` folds the same two series in the same order. The
pinned digests all move as a result; regenerate with
`dart run tool/print_digests.dart`.

Three checks now stand between this and a repeat, one per way it broke.
`tool/verify_wasm.mjs` asserts every function `_Core` declares is present in the
artifact, named in `-sEXPORTED_FUNCTIONS`, and actually called by the binding. A
member the extension type does not declare is a compile error, which is what
extension types are here for. And the browser test in
`example/test/web_wasm_test.dart` decodes through the real web binding and
asserts the RMS series arrives - the one leg neither of the others can see,
since a `_copyOut` that reads a series and then drops it on the floor compiles
and exports perfectly.

### Changed

- **ABI 7 → 8.** Additive: `wf_capture_scratch`, `wf_capture_scratch_frames`,
  `wf_capture_pcm_scratch`, `wf_capture_pcm_scratch_samples` and
  `wf_capture_live`. No existing signature changed. `wf_capture_live` reports
  sessions created and not yet destroyed, and exists for the same reason
  `wf_capture_feed` is public: it is what makes the binding's ownership testable
  rather than asserted.

## 0.3.0

Capture keeps the audio, the pyramid carries loudness, and the native core
actually loads on Android - which it never had.

### Added

- **RMS through the pyramid.** Peaks say how far the audio went; RMS says how
  much of it there was. `WaveformPeaks.rms(level)` and `PeakWindow.rmsAt(i)`
  expose it, and coarser levels combine children as the root of the mean of
  their squares so the value stays an RMS rather than an average of averages.
  Costs 50% more pyramid memory.
- **Capture keeps the audio.** A second lock-free ring carries raw PCM
  alongside the reduced frames, and `CaptureConfig.recordTo` streams it to a
  16-bit WAV. Separate rings because they run at 86/sec against 44,100/sec and
  a dropped frame is cosmetic where a dropped sample is a hole.
  `CaptureSession.pcmDropped` is reported separately for that reason.
- **`CaptureSession.pause` and `resume`**, which stop the device without
  touching the rings, the accumulator or the history, so a take continues
  rather than restarting.

### Fixed: the native core never loaded on Android

`libmonowave.so` was bundled correctly in every APK since M0 and failed to
`dlopen` on every one of them: `cannot locate symbol "pow"`. miniaudio and
dr_mp3 both reference it, Apple's libSystem provides the math functions
implicitly, and Android and Linux do not - so `libraries: ['m']` was missing
from the build hook.

M0 claimed Android was verified. What it actually verified was that the library
was *inside* the APK, which is not the same as it loading, and the CI check
inherited exactly that blind spot. It went unnoticed for five milestones
because every test ran on the macOS host and the example's sample path is pure
Dart. Running it on a real device is what found it.

### Fixed: quiet recordings drew as a flat line

The peaks painter scaled linearly, so a quiet room tone at about 1% of full
scale drew a two-pixel bar and read as broken. `WaveformStyle.normalize` scales
so the loudest moment fills the height, read from the coarsest mipmap level in
O(1) so it does not shift while panning. `CompactBars` already made the same
correction for the fixed-bar case.

### Capture keeps the audio, not just the reduction

Building a real voice-memo example surfaced a gap the milestones had missed:
`stop()` returned peaks, but the audio thread had only ever kept a *reduction*.
The PCM was gone, so a recording could be drawn and never trimmed or exported -
which is most of what a voice memo app does.

#### Added

- **A second lock-free ring for raw PCM**, alongside the one carrying reduced
  frames. The audio thread only ever copies into both; writing the file is the
  consumer's job, because file I/O on an audio callback is exactly the unbounded
  operation that produces a glitch.
- **`CaptureConfig.recordTo`**, which streams the take to a 16-bit PCM WAV as it
  is captured. The header is written twice - once as a placeholder so the audio
  starts at a fixed offset, once at stop with the real sizes - so the file is
  streamed rather than assembled in memory.
- **`CaptureSession.pcmDropped`**, reported separately from `dropped`. Losing a
  visualizer frame is cosmetic; losing audio is not.

The output is the same format the exporter reads, so a recording can be trimmed
and exported without a second format in play.

### The example is a voice memo app

Replaced the developer gallery with a real product flow - idle, recording,
review - with the waveform as the hero element throughout and the Android
runtime microphone permission finally requested, closing the M3 gap.

## 0.2.0

Decode, capture, render and edit, on one C core across six targets. Web has
everything but capture.

### M5 - editing and export

#### Added

- **A non-destructive document**: a list of regions referencing source ranges
  with gain and fades. Nothing decodes, copies or mutates audio; the source is
  untouched until an export reads it.
- **Edits as values** - trim, delete, split, gain, fade - in a sealed hierarchy,
  so an exporter switching over them fails to compile when a new kind is added.
- **`EditHistory`** with undo and redo over document snapshots rather than
  inverse operations, following monolens's reasoning: undo is cheap precisely
  because an edit is a value, and a fade has no inverse.
- **`previewPeaks`**, deriving the edited waveform from the source's peaks
  without decoding, so the display updates the instant an edit is applied.
- **`wf_export_wav`**: reads through the same decoders, seeks per region,
  applies gain and linear fades, writes 16-bit PCM WAV.
- The Edit tab now trims, deletes, fades, undoes and exports.

#### Verified

An unedited document round-trips to **byte-identical peaks**, a trim exports
exactly the selected range, a delete closes the gap, gain scales the output,
and a fade reaches silence at its edges - all asserted by decoding the exported
file back rather than by checking that a file appeared.

#### Notes

- Output is always WAV. An edit list is meant to reproduce the source exactly
  where it did not change it, and re-encoding to a lossy format would quietly
  break that.
- Fades are linear, not equal-power: these exist to take the click off an edit
  point, not to crossfade two takes, and linear is what makes the endpoints
  exactly 0 and 1.
- `previewPeaks` does not show fades. A fade acts over samples and the finest
  level is 128 samples wide, so a typical fade is narrower than one bar.
- Export is unavailable on web, which has no filesystem to write to.

### M4 - selection, snapping and the zoom claim

M1 already had the mipmap and the viewport maths. M4 is what you do once you
are zoomed in, plus proof of the claim the pyramid exists to support.

#### Added

- **`WaveformSelection`** in sample space, so a range survives a zoom, a resize
  and a rotation without drifting. Immutable, which is also what will make undo
  cheap in M5.
- **`WaveformSnap`** - `toZeroCrossing` finds a bucket whose extremes straddle
  zero, `toQuietest` finds the least audible cut point in a window. Both work
  from peaks alone.
- **The Edit tab**: pinch-zoom anywhere, drag to pan or to select depending on
  an explicit mode, and a selection overlay above the playhead layer.

#### Verified

A three-hour pyramid (476 million samples, 3.7 million pairs, 23 levels)
resolves and reads every visible pair in **5.6 microseconds per frame** through
a full zoom sweep. A 60fps budget is 16,667 microseconds, so this is about
0.03% of it, and the cost is bounded by screen pixels rather than by file
length. That is the entire payoff of the mipmap, and it is now a test with a
threshold rather than a claim in prose.

#### Notes

- **Snapping is bucket-accurate, not sample-accurate.** At a 128-sample base
  that is about 3 ms - inaudible for a trim point, but worth stating plainly
  because "zero crossing" usually implies exactness. Sample-exact snapping
  would mean re-reading the source on every gesture.
- A drag cannot both navigate and select, so the Edit tab makes the mode
  explicit rather than guessing from a modifier. Pinch always zooms.
- Gesture state is captured at scale-start and updates are applied relative to
  it. Accumulating per-frame deltas drifts.

### M3 - live capture

The milestone where the constraints stop being preferences. Everything
reachable from the audio callback is forbidden to allocate, take a lock, or
call into a higher layer, and a missed deadline there is an audible glitch
rather than a dropped frame.

#### Added

- **The capture core**, on vendored miniaudio. The audio thread accumulates a
  hop, reduces it to min/max/RMS, and publishes it through a lock-free
  single-producer/single-consumer ring. No PCM crosses into Dart: at a 512
  sample hop that is about 516 bytes a second instead of 176 kB.
- **`wf_capture_feed` is public**, and it is the entry point the device callback
  wraps. That is what makes the realtime path testable on every platform with
  no microphone, no permission prompt and exact timing - 17 tests drive it with
  synthetic PCM.
- **A preallocated history buffer**, so `stop()` returns peaks for the whole
  take even if the consumer never drained. Growing it from the audio thread is
  not an option, so it is sized up front and reports truncation past its cap.
- **`CaptureSession`, `CaptureScope`, `CaptureConfig`** in Dart. The scope is a
  ring over a preallocated `Int16List` and allocates nothing per frame.
- **`FakeCaptureSession`** in `package:monowave/testing.dart`, emittable frame
  by frame so a host's visualizer can be tested without audio.
- **The Record tab**, wired end to end: record, watch the bars, stop, and the
  captured peaks come back as the 64-byte summary a sender would upload.

#### Notes

- Dropped frames are surfaced rather than hidden. A full ring drops and counts;
  blocking the producer to wait for room would stall the audio device.
- **Web capture is not implemented**, and when it lands it will not use
  miniaudio. M0's assumption that it would need `SharedArrayBuffer` turned out
  to be wrong twice over; see docs/20-concepts/90-architecture.md for what
  replaced it.
- miniaudio must be compiled as Objective-C on Apple platforms, and
  `Language.objectiveC` only adds `-framework` flags - clang picks the language
  from the file extension, so there is a one-line `wf_miniaudio.m` that includes
  the `.c`.
- The example declares the microphone permission on every platform, but
  **Android also needs a runtime request** that the example does not make yet.
  monowave deliberately does not request permissions: a headless package has no
  UI to explain why it is asking, and the host does.

### M2 - the C decoder

The first milestone where the single-C-core bet actually pays: real audio in,
peaks out, over two completely different bindings.

#### Added

- **The C decode core.** `wf_decode_file` and `wf_decode_memory` over vendored
  dr_wav, dr_mp3 and dr_flac, streaming a bucket at a time so peak memory is one
  bucket whether the input is a voice note or an audiobook. The pyramid is built
  in C and owned by C.
- **`MonowavePlatform.decodeFile` / `decodeBytes`**, implemented over `dart:ffi`
  natively and WASM on web. Native decodes run in a helper isolate and hand back
  only the pyramid's address, so nothing is copied or serialized across it.
- **`WaveformPeaks.fromLevels` and `dispose()`.** On native, levels are typed-data
  views straight into native memory, kept alive by a `NativeFinalizer`, so a
  three-hour recording never touches the Dart heap.
- **Fixtures and the determinism check.** Six synthesized WAVs, each targeting a
  specific way a reduction can be wrong, hashed into digests that `dart test`
  asserts on every OS and `tool/verify_wasm.mjs` asserts against the WASM build.

#### Verified

All six fixtures decode to **byte-identical pyramids in the WASM build and the
native build**. That is the property the architecture exists to guarantee, and
it now has a test rather than an argument.

#### Notes

- **AAC/M4A is not supported**, and cannot be without a platform decoder or a
  much heavier dependency. It is tolerable because the voice-note path never
  decodes: the sender computes peaks at record time and ships them as metadata.
- Determinism is asserted on WAV and FLAC, whose paths are integer-exact. MP3
  decodes through floating point, where the last bit can legitimately differ
  between targets.
- `wf_peaks_length` returns a `double`. An `int64` would surface to JavaScript as
  a `BigInt`, and 2^53 samples is over a thousand years of audio.
- The WASM module imports three WASI file-descriptor functions that libc links
  in even with the decoders' file halves compiled out. Both bindings stub them
  with ENOSYS; they are unreachable from the decode path.

### M1 - model, codecs and the gallery

Everything here is pure Dart. There is still no decoder, and none of it needs
one: a sender computes peaks at record time, so the common path never decodes
anything.

#### Added

- **`WaveformPeaks`** - a min/max mipmap pyramid. Level 0 is the finest
  resolution held; each level above is built by min-of-mins and max-of-maxes, so
  a coarse level provably bounds the level below it and zooming is exact rather
  than approximate. Reduction is never an average.
- **`WaveformViewport`** and **`PeakWindow`** - which part of the audio is on
  screen and at what zoom, resolved to a level and handed to a painter as a
  zero-copy window. Zooming anchors on a focus point so a pinch feels attached
  to the audio rather than to the widget.
- **`WaveformTimeline`** - the whole of monowave's relationship with a player:
  `Duration` to sample and back, with no player dependency.
- **`WaveformDat`** - the BBC `audiowaveform` binary format, versions 1 and 2 at
  8 or 16 bits, so peaks can be precomputed server-side by the standard tool.
- **`CompactBars`** - a 64-byte voice-note summary with normalization and a dBFS
  curve, plus `fromAmplitudes` for the live-capture path.
- The example is now a **monokit v2.0.0 gallery**. It composes rather than
  duplicates: monokit's own `MonoWaveform` and `MonoVoiceNote` render the
  fixed-bar case from `CompactBars`, and a reference painter covers what they
  cannot - true min/max asymmetry and a viewport that zooms.

### M0 - toolchain spike

Nothing was published from this milestone; it existed to settle how the native
side is built before any of it was written.

#### Added

- Repo scaffold following the monokit/monolens house layout: lefthook and
  commitlint over conventional commits, `flutter_lints`, MIT license, generated
  (never committed) fixtures.
- `hook/build.dart` compiling `src/` into a code asset via `package:hooks` and
  `package:native_toolchain_c`, replacing the per-platform CMake, podspec and
  Gradle scaffolding a classic FFI plugin would carry.
- `src/wf_probe.c` - the M0 probe. `wf_reduce_minmax` is the real peak kernel
  in miniature, so the spike proves pointer passing and not just linking.
- `MonowavePlatform`, the mockable seam, with its two real implementations
  selected by conditional import: `dart:ffi` on the five native targets, and
  `dart:js_interop` over WASM on web.
- `tool/build_wasm.sh`, producing the committed `assets/monowave.wasm`. It
  carries workarounds for two bugs in Homebrew's emscripten 6.0.4 bottle so a
  fresh clone builds without manual setup.
- `FakeMonowavePlatform` in `package:monowave/testing.dart`.

#### Verified

The same C source, reached over FFI natively and over WASM on web, returns
identical results on every target checked: macOS (host and app), iOS simulator
at runtime, Android for all three ABIs, and web at runtime in a browser.
Linux and Windows are covered by the CI matrix rather than locally.

#### Notes

- Tests are `package:test` rather than `flutter_test`. A headless package has
  no widget tree to bind, and `flutter_test` pins `meta 1.18.0` from the SDK,
  which collides with the hook packages.
- `hooks` and `native_toolchain_c` are held one patch below latest: both moved
  to `meta ^1.19.0`, which Flutter stable's pinned `meta 1.18.0` cannot satisfy.
