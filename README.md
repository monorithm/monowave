# Monowave

Monowave is headless audio for Flutter: microphone capture, waveform peaks, and
non-destructive editing, on all six Flutter targets from one C core.

**Headless.** The package exports no widget. A decode hands back a zero-copy
view over min/max peaks plus the viewport math to place them; capture hands back
reduced frames. What the waveform *looks* like is entirely yours - nothing under
`lib/` imports `package:flutter/widgets.dart`, `material.dart` or
`cupertino.dart`, and CI enforces it with a grep.

**Player-agnostic.** `WaveformTimeline` maps `Duration` to samples and back, and
that is the whole of monowave's relationship with playback. It never sees a
player, so `just_audio`, `media_kit` or your own engine are each a few lines of
adapter in the host and none of them are a dependency here.

**Six targets, one implementation.** Android, iOS, macOS, Windows, Linux and web
all run the same C - reached over `dart:ffi` natively and over WASM on web. CI
asserts the peaks come out byte-identical on every one, which is the only reason
"one core" is a claim rather than a hope.

**Bounded by pixels, not by file length.** Peaks are a mipmap pyramid, so zooming
picks a level instead of re-reading data. A three-hour recording resolves a frame
in about 6 microseconds against a 16,667 microsecond budget, and never reaches
the Dart heap.

## Install

```bash
flutter pub add monowave
```

Monowave compiles its native code with a Dart build hook, so consumers need
native assets enabled once, per machine:

```bash
flutter config --enable-native-assets
```

There is no CocoaPods pod, no Gradle plugin and no per-ABI binary in the
package - the C is built from source in `src/` as part of your build, for
whatever you are targeting.

Capture needs a microphone permission, which monowave deliberately does **not**
request: a headless package has no UI to explain why it is asking, and you do.
Declare the usage strings and ask with whatever permission plugin you already
have. iOS `Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key><string>...</string>
```

Android `AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
```

## Decode

Every call into the C core crosses `MonowavePlatform`. Initialize once - on
native that resolves the code asset, on web it instantiates the WASM module,
which is the reason this is asynchronous at all:

```dart
final monowave = MonowavePlatform.instance;
await monowave.ensureInitialized();

final peaks = await monowave.decodeFile(path);   // WAV, MP3 or FLAC
```

The decoder streams the file a bucket at a time, so an audiobook is never
resident in memory. On web there is no filesystem - use `decodeBytes` there.

`WaveformPeaks` is a pyramid: level 0 is the finest resolution held, and each
level above it covers twice as many samples per min/max pair. Reduction is
always min/max, never an average - averaging collapses transients and renders
speech as a flat sausage. `peaks.rms(level)` carries loudness as a second series
to overlay, not as a replacement.

Peaks the C core produced are backed by memory it owns. Call `dispose()` when
the waveform leaves the screen; any view handed out beforehand dangles
afterwards, so drop those first.

## Draw

`WaveformViewport` is pure math: which part of the audio is on screen and at
what zoom. `resolve` picks the mipmap level for you and returns the slice to
draw, already in painter coordinates - so a `CustomPainter` is a loop with no
arithmetic of its own:

```dart
class WavePainter extends CustomPainter {
  WavePainter(this.peaks, this.viewport);

  final WaveformPeaks peaks;
  final WaveformViewport viewport;

  @override
  void paint(Canvas canvas, Size size) {
    final window = viewport.resolve(peaks);
    final mid = size.height / 2;
    final scale = size.height / 2 / 32768;
    final paint = Paint()..color = const Color(0xFF3B82F6);

    for (var i = 0; i < window.pairCount; i++) {
      final x = window.xOfFirstPair + i * window.pixelsPerPair;
      canvas.drawRect(
        Rect.fromLTRB(
          x,
          mid - window.maxAt(i) * scale,     // max is the top...
          x + window.pixelsPerPair,
          mid - window.minAt(i) * scale,     // ...and min is negative
        ),
        paint,
      );
    }
  }

  // WaveformViewport is immutable but carries no `==`, so compare the fields.
  @override
  bool shouldRepaint(WavePainter old) =>
      !identical(old.peaks, peaks) ||
      old.viewport.startSample != viewport.startSample ||
      old.viewport.samplesPerPixel != viewport.samplesPerPixel ||
      old.viewport.widthPx != viewport.widthPx;
}
```

`window.xOfFirstPair` is usually slightly negative. That is deliberate: the
window snaps outward to whole pairs so panning stays smooth instead of stepping
a bar at a time.

Gestures produce new viewports rather than mutating one, so this binds to any
state management:

```dart
var viewport = WaveformViewport.fitted(peaks, width);

viewport = viewport.pannedBy(details.delta.dx).clampedTo(peaks);
viewport = viewport.zoomedAt(focalX, details.scale).clampedTo(peaks);
```

`clampedTo` is what stops the audio being lost off-screen - it bounds scroll,
refuses to zoom out past the whole file, and refuses to zoom in past the finest
level, since there is no finer data in memory and the result would just be
stretched.

A playhead and a seek are the timeline composed with the viewport:

```dart
final timeline = WaveformTimeline.of(peaks);

final x = viewport.xForSample(timeline.sampleAt(player.position));
player.seek(timeline.timeAt(viewport.sampleAtX(localX)));
```

## Capture

The audio thread reduces each hop and publishes it through a lock-free ring; the
Dart side drains that ring on a timer. No PCM crosses into Dart, and nothing in
the path allocates on the audio thread.

```dart
final session = await monowave.openCapture(
  const CaptureConfig(
    maxDuration: Duration(minutes: 5),
    recordTo: '/path/to/take.wav',   // omit to keep only the reduction
  ),
);

await session.start();
session.frames.listen((frame) => setState(() {}));   // ~86/sec at defaults

final peaks = await session.stop();   // caller owns these - dispose them
```

`recordTo` streams raw PCM to a 16-bit WAV through a *second* ring, separate
from the reduced frames, because the two run at 44,100/sec against 86/sec and a
dropped visualizer frame is cosmetic where a dropped sample is a hole. That is
why `pcmDropped` is reported apart from `dropped`.

`pause()` and `resume()` stop the device without touching the rings, the
accumulator or the history, so a take continues rather than restarting. The
peaks from `stop()` come from the audio thread's own history rather than from
what the visualizer happened to collect, so they are complete even if the app
was backgrounded and missed drains.

For a live meter, draw from `session.scope` - a fixed-capacity rolling window
that allocates nothing per frame:

```dart
for (var i = 0; i < scope.length; i++) {
  final height = scope.amplitudeAt(i) * trackHeight;   // 0..1, either direction
}
```

**Repaint on `scope.revision`, not on `scope.length`.** The scope is a ring that
mutates in place, so once it is full the length never changes again and a
`shouldRepaint` keyed on it silently stops repainting.

`openCapture` throws `CaptureUnavailable` when the microphone permission has not
already been granted - see [Install](#install).

## Edit

An edit is a **value**, not a command against a buffer. A `WaveformDocument` is a
list of regions, each one a range in the source plus a gain and two fade lengths;
nothing decodes, copies or mutates audio, and the source is untouched until an
export reads it.

```dart
var doc = WaveformDocument.of(peaks);

doc = doc.applying(DeleteEdit(selection));
doc = doc.applying(GainEdit(selection, 1.5));
doc = doc.applying(FadeEdit(selection, fadeIn: 2048, fadeOut: 2048));
```

`TrimEdit`, `DeleteEdit`, `SplitEdit`, `GainEdit` and `FadeEdit` form a sealed
set, so a renderer or an exporter can switch over them exhaustively and the
compiler catches a kind that was not handled.

The waveform updates without a round trip through the decoder:

```dart
final preview = doc.previewPeaks(peaks);   // concatenates slices, scales by gain
```

Undo is snapshots rather than inverse operations - cheap precisely because an
edit is a value, and correct for edits that have no inverse anyway (a fade
destroys the samples it fades):

```dart
final history = EditHistory(WaveformDocument.of(peaks));

history.apply(DeleteEdit(selection));
if (history.canUndo) history.undo();

history.current;          // the document as it stands
history.undoLabel;        // 'Delete' - for a menu item
```

Selections live in **source samples**, so they survive a zoom, a resize and a
rotation without drifting:

```dart
var selection = WaveformSelection.at(viewport.sampleAtX(down.localPosition.dx));
selection = selection.extendedTo(sample).clampedTo(peaks);

// Cut on a sign change and avoid the click that cutting mid-swing produces.
final cut = WaveformSnap.toZeroCrossing(peaks, selection.start);
```

`WaveformSnap` resolves to the finest level's resolution - about 3 ms with a
128-sample base at 44.1 kHz - not to an exact sample, which is worth stating
plainly because "zero crossing" usually implies exactness. Sample-exact snapping
would mean a decode per gesture.

Export writes 16-bit PCM WAV. Always WAV: an edit list is meant to reproduce the
source exactly where it did not change it, and re-encoding to a lossy format
would quietly break that.

```dart
await monowave.exportWav(
  sourcePath: path,
  outputPath: out,
  document: doc,
);
```

## Peaks without a decoder

Two codecs cover the cases where decoding is the wrong move.

**Voice notes.** `CompactBars` summarizes peaks into a fixed-width byte array -
64 bars is 64 bytes, and base64s to 88 characters. The sender computes bars at
record time and uploads them beside the audio; the receiver draws from those
bytes with no decoder, no native code and no waiting. That removes the entire
decode path from the common case, which is what the messaging apps do.

```dart
final bars = CompactBars.encode(peaks);            // dBFS-scaled by default
await upload(audio, CompactBars.toBase64(bars));

// Receiver:
final heights = CompactBars.heights(CompactBars.fromBase64(encoded));
```

Scaling defaults to `BarScale.dbfs` rather than linear because normal speech
peaks well below full scale, and a linear waveform of a voice note looks nearly
flat.

**Precomputed peaks.** `WaveformDat` reads and writes the BBC `audiowaveform`
binary format, so peaks can be generated server-side on upload and shipped to a
client that owns no decoder - and monowave interoperates with the peaks.js
ecosystem for free.

```dart
final peaks = WaveformDat.decode(bytes);
```

## Testing

```dart
import 'package:monowave/testing.dart';

final platform = FakeMonowavePlatform();
platform.install();
addTearDown(FakeMonowavePlatform.uninstall);

platform.decoded[path] = somePeaks;

// ...drive your controller, then assert on the request rather than on bytes:
expect(platform.decodeRequests, [path]);
expect(platform.exports.single.$3.regions, hasLength(2));
```

A host's tests should not need a microphone, an audio file or a native core, so
every seam has a fake. `FakeCaptureSession` drives the same state a real session
does - recording flag, frame stream, scope - with no device, and
`nextDecodeError` / `nextCaptureError` make the failure paths reachable.

## Platform support

| | Decode | Draw | Capture | Export |
|---|---|---|---|---|
| Android, iOS, macOS, Windows, Linux | yes | yes | yes | yes |
| Web | `decodeBytes` only | yes | no | no |

Web has no filesystem, so `decodeFile` and `exportWav` are native-only; feed
`decodeBytes` instead. Capture on web needs a WebAudio path that does not exist
yet - [`docs/20-reference/20-architecture.md`](docs/20-reference/20-architecture.md)
has the reasoning.

Decoding covers WAV, MP3 and FLAC. AAC/M4A needs a platform decoder monowave
does not carry, and reports `DecodeFailure.unsupportedFormat`; the voice-note
path avoids the question entirely by computing peaks at record time.

## Architecture

```
lib/
  monowave.dart              public surface - no widgets
  testing.dart               test doubles (never imported by lib/src)
  src/
    capture/                 CaptureSession, CaptureScope, CaptureConfig
    codec/                   CompactBars, WaveformDat
    edit/                    WaveformDocument, WaveformEdit, EditHistory
    model/                   WaveformPeaks, WaveformViewport, WaveformTimeline,
                             WaveformSelection
    platform/                MonowavePlatform - ffi / wasm behind one seam
    native/                  generated ffigen bindings
src/                         the C core: peaks, decode, capture, export
hook/build.dart              builds src/ as a code asset during your build
assets/monowave.wasm         the same core for web, built by tool/build_wasm.sh
```

`MonowavePlatform` is an interface rather than the bindings directly, so tests
run against an in-memory fake with no native code and no device - and so the
package could be federated later without touching callers. The web/native split
is a conditional import on `dart.library.js_interop`, which is what keeps
`dart:ffi` out of a web build.

There is no `flutter: plugin:` block in the pubspec, and that is not an
oversight: monowave has no platform plugin classes. The native side is a code
asset reached over FFI, not a registered plugin reached over a method channel.

The full reasoning - why min/max, why a pyramid, why two rings in capture, what
the six-target determinism check actually asserts - is in
[`docs/20-reference/20-architecture.md`](docs/20-reference/20-architecture.md).

## Contributing

```bash
bun install && bun run hooks:install
flutter pub get
dart test
```

Tests are `package:test`, not `flutter_test` - there is no widget tree to bind,
and the engine suite runs in seconds as a result. It is also forced:
`flutter_test` pins `meta 1.18.0` from the SDK, which the hook packages cannot
satisfy.

`hooks` and `native_toolchain_c` are held one patch below latest for the same
reason - `hooks 2.1.0` and `native_toolchain_c 0.19.3` moved to `meta ^1.19.0`,
which cannot resolve alongside `flutter` at all. The upper bounds in
`pubspec.yaml` are explicit rather than left to backtracking, which takes
minutes against a graph this size. Raise them when Flutter's pinned `meta`
catches up.

The example gallery is the reference renderer. Monowave ships no widget, so
every painter and gesture a host would write lives there:

```bash
cd example && flutter run
```

Rebuilding the WASM core after changing `src/` (needs emscripten 6.0.4, pinned
to match the committed artifact byte-for-byte):

```bash
./tool/build_wasm.sh
```

## License

MIT. See [LICENSE](LICENSE).
