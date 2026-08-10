# monowave

monowave is headless audio for Flutter: microphone capture, waveform peaks, and
non-destructive editing, on all six Flutter targets from one C core.

**Headless.** The package exports no widget. A decode returns a zero-copy view
over min/max peaks, and also the viewport math that puts the peaks in position.
A capture returns reduced frames. You decide what the waveform looks like. No
file under `lib/` imports `package:flutter/widgets.dart`, `material.dart` or
`cupertino.dart`. A CI grep asserts that this rule holds.

**Player-agnostic.** `WaveformTimeline` maps `Duration` to samples and back.
This map is the full relationship between monowave and playback. monowave never
sees a player. `just_audio`, `media_kit` or your own engine each need a few
lines of adapter in the host. monowave depends on none of them.

**Six targets, one implementation.** Android, iOS, macOS, Windows, Linux and web
all run the same C code. Native targets reach the code over `dart:ffi`. Web
reaches the code over WASM. CI asserts that the peaks are byte-identical on
every target. This test is the only reason that "one core" is a claim and not a
hope.

**Bounded by pixels, not by file length.** Peaks are a mipmap pyramid. A zoom
picks a level and does not read the data again. For a three-hour recording,
monowave resolves a frame in approximately 6 microseconds against a
16,667 microsecond budget. The recording never reaches the Dart heap.

## Install

```bash
flutter pub add monowave
```

monowave compiles its native code with a Dart build hook. Therefore each machine
must enable native assets one time:

```bash
flutter config --enable-native-assets
```

The package contains no CocoaPods pod, no Gradle plugin and no per-ABI binary.
Your build compiles the C from the source in `src/`, for each target that you
select.

Capture needs a microphone permission. monowave deliberately does **not** request this
permission. A headless package has no UI that gives the reason for the request,
but your application has one. Declare the usage strings. Then request the
permission with the permission plugin that you already use.

For iOS, in `Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key><string>...</string>
```

For Android, in `AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
```

## Decode

Every call into the C core crosses `MonowavePlatform`. You must initialize the
platform one time. On native, this step resolves the code asset. On web, this
step instantiates the WASM module. The web step is the reason that the method is
asynchronous.

```dart
final monowave = MonowavePlatform.instance;
await monowave.ensureInitialized();

final peaks = await monowave.decodeFile(path);   // WAV, MP3 or FLAC
```

The decoder streams the file one bucket at a time. As a result, an audiobook is
never resident in memory. Web has no filesystem. On web, use `decodeBytes`.

`WaveformPeaks` is a pyramid. Level 0 is the finest resolution that the pyramid
holds. Each level covers two times as many samples for each min/max pair as the
level below it. The reduction is always min/max and never an average. An average
collapses transients and shows speech as a flat sausage. `peaks.rms(level)`
carries loudness as a second series for an overlay, not as a replacement.

The peaks stay in memory that the C core owns. When the waveform leaves the
screen, call `dispose()`. Any view that monowave returned before that call
dangles after it. Remove those views first.

## Draw

`WaveformViewport` is pure math. It holds which part of the audio is on screen,
and at what zoom. `resolve` picks the mipmap level for you and returns the slice
to draw. The slice is already in painter coordinates. Therefore a
`CustomPainter` is a loop with no arithmetic of its own:

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

`window.xOfFirstPair` is usually a small negative number. This behavior is
deliberate. The window snaps outward to whole pairs. As a result, a pan stays
smooth and does not step one bar at a time.

A gesture produces a new viewport and does not change the old one. Therefore
this design binds to any state management:

```dart
var viewport = WaveformViewport.fitted(peaks, width);

viewport = viewport.pannedBy(details.delta.dx).clampedTo(peaks);
viewport = viewport.zoomedAt(focalX, details.scale).clampedTo(peaks);
```

`clampedTo` stops the loss of the audio off the screen. It bounds the scroll. It
refuses a zoom out past the whole file. It also refuses a zoom in past the
finest level, because memory holds no finer data. Such a zoom in only stretches
the data.

A playhead and a seek are the timeline together with the viewport:

```dart
final timeline = WaveformTimeline.of(peaks);

final x = viewport.xForSample(timeline.sampleAt(player.position));
player.seek(timeline.timeAt(viewport.sampleAtX(localX)));
```

## Capture

The audio thread reduces each hop and publishes it through a lock-free ring. The
Dart side drains that ring on a timer. No PCM crosses into Dart. Nothing in the
path allocates memory on the audio thread.

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

`recordTo` streams raw PCM to a 16-bit WAV through a *second* ring. This ring is
separate from the ring for the reduced frames. The two rings are separate for
two reasons. The first is their rates: 44,100 samples each second against 86
frames each second. The second is their consequences: a dropped visualizer frame
is cosmetic, where a dropped sample is a hole. For the same reasons, monowave
reports `pcmDropped` apart from `dropped`.

`pause()` stops the device and `resume()` starts it again. Neither call touches
the rings, the accumulator or the history. As a result, a take continues and
does not restart.

The peaks from `stop()` come from the history of the audio thread, not from the
data that the visualizer collected. If the application went to the background
and missed drains, the peaks are still complete.

The scope is a rolling window with a fixed capacity, and it allocates no memory
for each frame. For a live meter, draw from `session.scope`:

```dart
for (var i = 0; i < scope.length; i++) {
  final height = scope.amplitudeAt(i) * trackHeight;   // 0..1, either direction
}
```

**Repaint on `scope.revision`, not on `scope.length`.** The scope is a ring that
changes in place. After the ring becomes full, the length never changes again. A
`shouldRepaint` that keys on the length then stops the repaints and gives no
message.

If the user did not already grant the microphone permission, `openCapture`
throws `CaptureUnavailable`. Read [Install](#install).

## Edit

An edit is a **value**, not a command against a buffer. A `WaveformDocument` is
a list of regions. Each region is a range in the source, plus a gain and two
fade lengths. Nothing decodes, copies or changes audio. The source stays
unchanged until an export reads it.

```dart
var doc = WaveformDocument.of(peaks);

doc = doc.applying(DeleteEdit(selection));
doc = doc.applying(GainEdit(selection, 1.5));
doc = doc.applying(FadeEdit(selection, fadeIn: 2048, fadeOut: 2048));
```

`TrimEdit`, `DeleteEdit`, `SplitEdit`, `GainEdit` and `FadeEdit` form a sealed
set. Therefore a renderer or an exporter can switch over them exhaustively, and the
compiler catches a kind that the code does not handle.

The waveform updates without a round trip through the decoder:

```dart
final preview = doc.previewPeaks(peaks);   // concatenates slices, scales by gain
```

Undo uses snapshots and not inverse operations. Snapshots are cheap because an
edit is a value. Snapshots are also correct for edits that have no inverse (a
fade erases the samples that it fades):

```dart
final history = EditHistory(WaveformDocument.of(peaks));

history.apply(DeleteEdit(selection));
if (history.canUndo) history.undo();

history.current;          // the document as it stands
history.undoLabel;        // 'Delete' - for a menu item
```

A selection lives in **source samples**. Therefore a selection survives a zoom,
a resize and a rotation with no drift:

```dart
var selection = WaveformSelection.at(viewport.sampleAtX(down.localPosition.dx));
selection = selection.extendedTo(sample).clampedTo(peaks);

// Cut on a sign change and avoid the click that cutting mid-swing produces.
final cut = WaveformSnap.toZeroCrossing(peaks, selection.start);
```

`WaveformSnap` resolves to the resolution of the finest level, not to an exact
sample. With a 128-sample base at 44.1 kHz, this resolution is approximately
3 ms. The term "zero crossing" usually implies exactness, and for this reason
the limit needs a plain statement. A snap to an exact sample needs a decode for
each gesture.

Export writes 16-bit PCM WAV. The format is always WAV. An edit list must
reproduce the source exactly where the edit list did not change it. A re-encode
to a lossy format breaks this rule, and the break is not visible.

```dart
await monowave.exportWav(
  sourcePath: path,
  outputPath: out,
  document: doc,
);
```

## Peaks without a decoder

Two codecs cover the cases where a decode is the wrong choice.

**Voice notes.** `CompactBars` summarizes peaks into a byte array of fixed
width. 64 bars is 64 bytes, and base64 makes 88 characters from them. The sender
computes the bars at record time and uploads them beside the audio. The receiver
draws from those bytes with no decoder, no native code and no delay. This method
removes the full decode path from the common case. The messaging applications
use this same method.

```dart
final bars = CompactBars.encode(peaks);            // dBFS-scaled by default
await upload(audio, CompactBars.toBase64(bars));

// Receiver:
final heights = CompactBars.heights(CompactBars.fromBase64(encoded));
```

The default scale is `BarScale.dbfs` and not linear. The reason is the peak
amplitude of normal speech, which stays far below full scale. A linear waveform
of a voice note then looks almost flat.

**Precomputed peaks.** `WaveformDat` reads and writes the BBC `audiowaveform`
binary format. Therefore a server can make the peaks at upload time and send
them to a client that owns no decoder. monowave also interoperates with the
peaks.js ecosystem, with no extra work.

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

The tests of a host must not need a microphone, an audio file or the C core.
For this reason, every seam has a fake. `FakeCaptureSession` drives the same
state as a real session, with no device. This state is the recording flag, the
frame stream and the scope. `nextDecodeError` and `nextCaptureError` make the
failure paths reachable.

## Platform support

| | Decode | Draw | Capture | Export |
|---|---|---|---|---|
| Android, iOS, macOS, Windows, Linux | yes | yes | yes | yes |
| Web | `decodeBytes` only | yes | no | no |

Web has no filesystem. Therefore `decodeFile` and `exportWav` are native-only.
On web, use `decodeBytes` instead. Capture on web needs a WebAudio path that
does not exist yet.
[`docs/20-concepts/90-architecture.md`](docs/20-concepts/90-architecture.md)
gives the reasons.

The decoder covers WAV, MP3 and FLAC. AAC/M4A needs a platform decoder that
monowave does not carry. A decode of AAC/M4A reports
`DecodeFailure.unsupportedFormat`. The voice-note path computes the peaks at
record time, and thus avoids the question completely.

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

`MonowavePlatform` is an interface and not the bindings directly. Therefore
tests run against an in-memory fake, with no native code and no device. The
package can also become federated later, with no change to callers. The
web/native split is a conditional import on `dart.library.js_interop`. This
import keeps `dart:ffi` out of a web build.

The pubspec contains no `flutter: plugin:` block, and this absence is not an
oversight. monowave has no platform plugin classes. The native side is a code
asset that Dart reaches over FFI. It is not a registered plugin that Dart
reaches over a method channel.

[`docs/20-concepts/90-architecture.md`](docs/20-concepts/90-architecture.md)
gives all the reasons:

- why the reduction is min/max
- why the peaks are a pyramid
- why capture uses two rings
- what the six-target determinism check asserts

## Contributing

```bash
bun install && bun run hooks:install
flutter pub get
dart test
```

The tests use `package:test` and not `flutter_test`. There is no widget tree to
bind. As a result, the engine suite runs in seconds. This choice is also forced.
`flutter_test` pins `meta 1.18.0` from the SDK, and the hook packages cannot
satisfy that pin.

`hooks` and `native_toolchain_c` stay one patch below the latest release for the
same reason. `hooks 2.1.0` and `native_toolchain_c 0.19.3` moved to
`meta ^1.19.0`, which cannot resolve together with `flutter` at all. The upper
bounds in `pubspec.yaml` are explicit. If the resolver must backtrack instead,
it takes minutes against a graph of this size. When Flutter pins `meta 1.19.0`
or later, raise these bounds.

The example gallery is the reference for the drawing work. monowave ships no
widget. Therefore the gallery holds every painter and every gesture that a host
writes:

```bash
cd example && flutter run
```

After a change to `src/`, rebuild the WASM core. The rebuild needs emscripten
6.0.4, which is pinned to match the committed artifact byte-for-byte.

```bash
./tool/build_wasm.sh
```

## License

MIT. Read [LICENSE](LICENSE).
