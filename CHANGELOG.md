# Changelog

All notable changes to monowave are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
follows [semantic versioning](https://semver.org/spec/v2.0.0.html).

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
  no microphone, no permission prompt and exact timing — 17 tests drive it with
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
  to be wrong twice over; see docs/architecture.md for what replaced it.
- miniaudio must be compiled as Objective-C on Apple platforms, and
  `Language.objectiveC` only adds `-framework` flags — clang picks the language
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
