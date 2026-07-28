# Architecture

Monowave is a headless Flutter package for microphone capture, waveform peaks, and non-destructive audio editing.
Headless is the organizing constraint, not a detail, and it is inherited deliberately from [monolens](https://github.com/monorithm/monolens): the package exports no widget, and every boundary it draws follows from that.
A capture hands back reduced frames. A decode hands back a zero-copy view over min/max peaks plus the viewport math to place them.
What the listener sees is the host's to build.

This document is the shape and the reasoning.
The task-level API is in the [README](../README.md); this is why it looks the way it does.

## Why headless

An audio package that ships widgets asks every consumer to accept its design language, or to fight it.
It also asks them to accept its idea of what a waveform is, which is worse, because a voice note, a podcast scrubber and a trim editor want three different pictures out of the same data.

The rule this leaves is checkable, and CI checks it.
Nothing under `lib/` imports `package:flutter/widgets.dart`, `material.dart` or `cupertino.dart`.
A grep returning nothing is the invariant.

The cost lands in exactly one place: the host writes the `CustomPainter`.
Monowave's job is to make that a few lines rather than a research project, which is what `WaveformViewport` and the zero-copy peak views are for.
The example app is the reference implementation of that painter, and it is the only place in the repo where one exists.

## Layers

```mermaid
flowchart TD
  Host[host app] --> API
  subgraph API[public API]
    Capture[CaptureSession]
    Peaks[WaveformPeaks / WaveformViewport]
    Edit[WaveformDocument]
  end
  Capture --> Seam
  Peaks --> Seam
  Edit --> Seam
  Seam[MonowavePlatform] --> Ffi[FfiMonowavePlatform]
  Seam --> Wasm[WasmMonowavePlatform]
  Ffi --> C[C core: src/]
  Wasm --> C
```

Dependency direction is one-way: `host -> api -> seam -> binding -> C core`.
The two bindings are alternatives, never both in one build, and both reach the same C.

| Directory | Role |
|---|---|
| `src/` | The C core. Decode and peak reduction; capture arrives in M3. The only place audio is actually processed. |
| `src/vendor/` | dr_wav, dr_mp3, dr_flac. Vendored, never edited. |
| `hook/build.dart` | Compiles `src/` into a code asset for the five native targets. |
| `tool/build_wasm.sh` | Compiles the same `src/` to WASM for web, into `assets/`. |
| `lib/src/platform/` | `MonowavePlatform`, the mockable seam, and its two real implementations. |
| `lib/src/native/` | ffigen output. Never edited by hand. |
| `lib/src/model/` | Peaks, viewport, timeline, selection - pure Dart, pure math. |
| `lib/src/capture/` | The session, the rolling scope, and the FFI drain loop. |
| `lib/src/edit/` | Documents, edits as values, and undo. |
| `lib/src/codec/` | BBC `.dat` and the compact bar summary. |
| `lib/testing.dart` | Fakes. Deliberately not exported from `monowave.dart`. |

## Why FFI, and not pigeon

Monolens routes all platform traffic through [Pigeon](https://pub.dev/packages/pigeon), and argues for it well: the payloads are structured, three languages have to agree, and a schema change should break the build rather than a device.
Monowave breaks with that, and the divergence is a decision rather than an oversight.

**Pigeon cannot carry the realtime path.**
A capture callback fires roughly 86 times a second on the audio thread, where it must not allocate, take a lock, or call into a message channel.
The transport has to be a lock-free ring buffer in shared memory.
That is not a payload-shape problem, which is what pigeon solves.

**Maximizing platform coverage inverts the cost.**
Pigeon means one native implementation per platform.
For camera work across two platforms that is correct.
For audio across six it is six decoders that will drift, and drift in a waveform is visible: the same file renders differently on Android and web.
One C core - [miniaudio](https://miniaud.io) plus the dr_libs decoders - compiled via FFI on the five native targets and to WASM for web is one implementation, and it lets CI *assert* that peaks come out byte-identical everywhere.

**What is kept unchanged is the seam.**
`MonowavePlatform` is an interface in front of the bindings rather than direct calls into them, exactly as `MonolensPlatform` sits in front of the generated pigeon API.
That indirection buys the same two things it buys monolens.
The whole engine - peaks, mipmaps, viewport, selection, undo - is testable against `FakeMonowavePlatform` with no native code and no device.
And it is the line a federated split would cut along, if per-platform versioning is ever needed.
The package is not federated today because one package is simpler and nothing needs it yet.

## How the native side is built

`hook/build.dart` is a Dart build hook: `package:hooks` drives it, `package:native_toolchain_c` compiles `src/`, and the result is a `CodeAsset` the Dart VM resolves at the `@DefaultAsset` id.
This replaces the per-platform CMake, podspec and Gradle scaffolding a classic FFI plugin template would carry, and it is why `pubspec.yaml` has no `flutter: plugin:` block at all.
There are no plugin classes to register, because nothing crosses a method channel.

Consumers must opt in:

```bash
flutter config --enable-native-assets
```

That flag is the main cost of this approach, and it is why M0 tested the mechanism before anything was built on it.

### M0 findings

Verified on Flutter 3.44.8 / Dart 3.12.2, macOS arm64 host:

| Target | Result |
|---|---|
| macOS host (`dart test`) | Build hook runs, symbols resolve, pointer arguments round-trip. |
| macOS app | `monowave.framework` in `Contents/Frameworks/`. |
| iOS simulator | Built, launched, and verified **at runtime**: `abi=1 min=-32768 max=32767`. |
| Android APK | `libmonowave.so` present for `arm64-v8a`, `armeabi-v7a` and `x86_64`. |
| Web | Built, served, and verified **at runtime in a browser**: the same `abi=1 min=-32768 max=32767`, via the js_interop binding loading `assets/monowave.wasm`. |
| Linux, Windows | Not checkable from a Mac. Covered by the CI matrix. |

The web result is the one that matters most, because it is the claim the whole design rests on: the same C source, reached two completely different ways, answering identically.

**Decision: build hooks, not the classic FFI plugin template.**
The mechanism works on every target reachable from this machine, including the cross-compiled ones, which is where it historically broke.

Two constraints fell out of the spike and are load-bearing:

- **Tests are `package:test`, not `flutter_test`.**
  A headless package has no widget tree to bind, so this is the right shape anyway - but it is also forced.
  `flutter_test` pins `meta 1.18.0` from the SDK, which the hook packages cannot satisfy.
  The upside is that the engine suite runs under `dart test` in seconds.
- **The hook packages are held one patch below latest.**
  `hooks 2.1.0` and `native_toolchain_c 0.19.3` moved to `meta ^1.19.0`; Flutter stable pins `meta 1.18.0`, so those versions cannot resolve alongside `flutter` at all.
  The upper bounds in `pubspec.yaml` are explicit rather than left to backtracking, which takes minutes against a graph this size.
  Raise them when Flutter's pinned `meta` catches up.

## The web path

`dart:ffi` does not exist on web, so web gets the second binding: the same `src/` compiled to WASM by `tool/build_wasm.sh`, reached over `dart:js_interop`.

**The WASM artifact is committed, and shipped as a Flutter asset (`assets/monowave.wasm`).**
Committing it avoids requiring emscripten in every consumer's build, which would make a `flutter build web` of any app depending on monowave fail unless that app's CI installed a C toolchain.
CI compensates by rebuilding the artifact from source and asserting it matches what is committed, so the binary can never silently drift from `src/`.

Shipping it through the asset bundle rather than the web root means `rootBundle` finds it with no assumptions about how the app is served.
The cost is that the asset is bundled on all six targets even though only web reads it.
Flutter cannot scope an asset to one platform, and a few hundred kilobytes is the cheaper side of that trade.

`WasmMonowavePlatform` never answers from a pure-Dart shim; if the module is missing it throws.
A shim would pass CI and hide the fact that web is not running the same code as the other five targets, which is the single property this architecture exists to guarantee.

Three details of the WASM contract are load-bearing and easy to get wrong:

- `-sALLOW_MEMORY_GROWTH` makes the module **import** `env.emscripten_notify_memory_growth`.
  Instantiating with an empty import object throws.
  Monowave supplies a no-op, because it re-reads the heap on every call rather than caching views.
- `-sSTANDALONE_WASM` builds the reactor model, so `_initialize()` must be called after instantiation or static initializers never run.
- The exports are reached through extension types rather than `dart:js_interop_unsafe`, so a rename in `src/` is a compile error rather than a runtime `undefined is not a function`.

### Why web forced an initialization step into the API

`MonowavePlatform.ensureInitialized()` exists entirely because of web.
Native targets resolve their code asset at startup and have nothing to wait for, but instantiating a WASM module is inherently asynchronous.
The alternative -- making every method return a `Future` -- would put an event-loop turn in front of `reduceMinMax`, which is called once per frame while scrubbing and once per hop while capturing.
One await up front is the cheaper shape, and it is a no-op on five of the six targets.

### Web capture will not go through miniaudio

M0 assumed web capture would need `SharedArrayBuffer` and therefore COOP/COEP headers on the host page.
Investigating it in M3 changed the answer twice over.

miniaudio does have a Web Audio backend, and by default it uses a `ScriptProcessorNode` rather than an AudioWorklet, so **`SharedArrayBuffer` is not required** after all.
AudioWorklets are opt-in behind `MA_ENABLE_AUDIO_WORKLETS`, and *those* need `-sAUDIO_WORKLET=1 -sWASM_WORKERS=1 -sASYNCIFY`, which is where the shared-memory requirement actually lives.

But the blocking problem is a different one.
Either way, miniaudio's web backend needs emscripten's JavaScript runtime, and monowave's artifact is deliberately `-sSTANDALONE_WASM --no-entry` with no JS glue at all.
Adopting it would mean a second, differently-built WASM module, `ASYNCIFY` overhead, and a larger artifact - one that ships on all six targets even though only web reads it.

**Decision: web capture will be a small AudioWorklet written directly against the browser's own APIs, not miniaudio.**
The browser already provides `getUserMedia` and `AudioWorklet`; miniaudio's value on native is that it abstracts five different backends, and on web there is only one.
The reduction it would be doing is a min and a max over int16 values - integer comparisons, perhaps fifteen lines of JavaScript.

This is the one place monowave does not run the same C on every target, so it is worth being precise about what that costs.
For decoding, identical peaks matter enormously: a stored waveform has to look the same on every client, which is what the determinism job polices.
For capture, the reduction is `min` and `max` over integers, which is exact in both languages by construction rather than by luck - there is no floating point in the path where a last bit could differ.
The claim is testable, and when web capture lands it should be tested the same way `tool/verify_wasm.mjs` tests decoding.

**Status: not implemented.** Decode and rendering work on web today; capture does not, and `WasmMonowavePlatform.openCapture` throws rather than pretending otherwise.

## What the host gets instead of a widget

The example is the reference renderer, and it demonstrates the split monowave is
built around rather than one blessed way to draw.

monokit v2.0.0 already ships `MonoWaveform` and `MonoVoiceNote`, and already
defines `MonoPlaybackController`.
That is the right division and monowave does not compete with it: the design
system owns presentation, monowave owns data, and the host implements the
controller.
`CompactBars.heights()` feeds `MonoWaveform` directly, so the fixed-bar voice
note needs no painter from anyone.

What a design-system waveform cannot do is min/max asymmetry and a viewport that
zooms, because both need more than one number per bar.
That is what `PeakWindow` and `WaveformViewport` are for, and the gallery's
`PeakWaveform` is the reference painter over them - about a hundred lines,
written to be copied.
It splits the body and the playhead into separate painters behind a
`RepaintBoundary`: the body's `shouldRepaint` ignores progress entirely, so
scrubbing repaints a clipped overlay rather than every bar.

## Editing is non-destructive, and undo is a snapshot

A document is a list of regions: a range in the source, a gain, two fade lengths.
Nothing in the edit layer decodes, copies or mutates audio.
The source is read exactly once, at export.

That buys two things that would otherwise be awkward.

`previewPeaks` derives the edited waveform by concatenating slices of the source's finest level and scaling by gain, so the display updates the instant an edit lands rather than after a decode.
And undo stores whole documents rather than inverse operations, which is the same call [monolens](https://github.com/monorithm/monolens)'s `EditHistory` makes and for the same reason: undo is cheap precisely because an edit is a value, there is nothing to invert, and some edits have no inverse at all - a fade destroys the samples it fades.
A document is a handful of regions, so a hundred steps of history on a heavily cut file is still a few kilobytes.

Export writes 16-bit PCM WAV and only WAV.
An edit list is meant to reproduce the source exactly where it did not change it, and re-encoding through a lossy codec would quietly break that.
Fades are linear rather than equal-power, because they exist to take the click off an edit point rather than to crossfade two takes, and linear is what makes the endpoints exactly 0 and 1.

## Why the pyramid is worth its memory

The pyramid doubles the memory of the base level, and the thing it buys is that preparing a frame costs the same whether the recording is thirty seconds or three hours.

Measured on a three-hour pyramid - 476 million samples, 3.7 million pairs at the 128-sample base, 23 levels - a full zoom sweep resolves the viewport and reads every visible pair in **5.6 microseconds per frame**.
A 60fps budget is 16,667 microseconds.
`test/three_hour_test.dart` asserts a ceiling rather than the exact figure, because the number will vary by machine and the property being protected is that it stays bounded by screen pixels rather than by file length.

If that test ever fails, zooming a long file has started scanning data instead of picking a level, and the pyramid has stopped earning its keep.

### Snapping is bucket-accurate, not sample-accurate

`WaveformSnap` works from peaks, so it resolves to the finest level - about 3 ms at a 128-sample base and 44.1 kHz.
That is inaudible for a trim point, and it is stated plainly because "snap to zero crossing" normally implies exactness.
Sample-exact snapping would mean re-reading the source audio on every gesture, which is a decode per drag; it can be added as a C entry point if something ever needs it.

`toQuietest` is usually the better default for speech: the silence between words is a more forgiving edit point than a zero crossing mid-syllable.

## Codec coverage, and the gap

WAV, MP3 and FLAC, via the dr_libs single-header decoders.
miniaudio is deliberately not vendored yet: decoding needs only dr_libs, and miniaudio arrives in M3 when capture does.

**AAC/M4A is not supported.**
It needs either a platform decoder - which would mean six implementations and the drift this architecture exists to avoid - or a much heavier dependency.
That is a real gap, because it is what `record` produces by default on iOS.
It is tolerable for one reason: the voice-note path never decodes at all.
The sender computes peaks at record time and ships them as metadata, so the common case never meets a decoder.
Revisit if imported-audio support turns out to matter more than expected.

## Peaks memory model

Peaks are allocated by C and Dart holds a typed-data view over that memory.
Nothing is copied, so a three-hour file never touches the Dart heap and never pressures the GC.

Reduction is always min/max, never an average.
Averaging destroys transients and renders speech as a flat sausage; RMS is available as an optional second series to overlay, not as a replacement.

There is one hazard specific to web, and it is why the two bindings differ here.
Growing the WASM heap detaches every outstanding view over it, so a long-lived view stays correct only until the next allocation anywhere in the module.
Rather than try to police that, the web binding **copies** the pyramid out of the heap and frees the native allocation immediately; the native binding keeps the zero-copy view.
Web pays a few hundred kilobytes for a normal recording, and native keeps the property an audiobook needs.
Inside a single call, views are still re-acquired after every allocation rather than cached.

### Two rings, not one

Capture keeps the reduction and the audio in separate lock-free rings.

They have completely different rates - 86 frames a second against 44,100 samples
- and completely different consequences when they overflow.
A dropped visualizer frame is cosmetic; a dropped audio sample is a hole in the
recording.
Sharing one ring would let a slow file write starve the visualizer, or a
paused visualizer stall the writer.

Neither ring ever blocks the producer.
The audio thread copies into both and moves on; `CaptureSession` drains them on
its timer and writes the WAV, because file I/O on an audio callback is precisely
the unbounded operation the whole design exists to avoid.

### The determinism check

This is the assertion the whole design answers to, and it runs two ways.

`dart test` decodes six synthesized fixtures and hashes each pyramid, on ubuntu, macOS and Windows.
`tool/verify_wasm.mjs` decodes the same fixtures through the WASM module and asserts the same digests.
Between them, one C source reached over two entirely different bindings on four host platforms has to agree exactly.

The hash is FNV-1a, and two details of it were bugs first.
It hashes int16 *values* in explicit little-endian order rather than a byte view, so it does not depend on host endianness.
And it is 32-bit with a shift-decomposed multiply rather than 64-bit, because Dart integers are 64-bit on the VM but doubles on web - a 64-bit FNV silently produces different numbers under `dart2js`, which would have made the check meaningless on the one target it exists to police.
