# Getting started

Monowave is headless: it decodes, reduces, records and edits, and it ships no
widgets. This page gets you from an empty project to a waveform drawn on screen,
and then to a recording on disk.

## Install

```bash
flutter pub add monowave
```

Monowave compiles its native code with a Dart build hook, so native assets have
to be enabled once, per machine:

```bash
flutter config --enable-native-assets
```

There is no CocoaPods pod, no Gradle plugin and no per-ABI binary in the
package. The C in `src/` is built from source as part of your build, for
whatever you are targeting. See [platform notes](../20-reference/10-platforms.md) for
what each target needs.

## Initialize the core

Every call into the C core crosses `MonowavePlatform`. Initialize it once,
before anything else:

```dart
final monowave = MonowavePlatform.instance;
await monowave.ensureInitialized();
```

This is asynchronous entirely because of web: native targets resolve their code
asset at startup and have nothing to wait for, but instantiating a WASM module
is inherently async. One await up front is cheaper than putting a `Future` in
front of `reduceMinMax`, which runs once per frame while scrubbing. On the five
native targets it is a no-op.

Every other method throws `MonowaveUnavailable` until it completes.

## Decode a file

```dart
final peaks = await monowave.decodeFile(path);   // WAV, MP3 or FLAC
```

`WaveformPeaks` is a mipmap pyramid, not a flat array. The decoder streams the
file a bucket at a time, so an audiobook is never resident in memory, and the
peaks themselves are a view over memory the C core owns -- a three-hour file
never reaches the Dart heap.

On web there is no filesystem; use `decodeBytes` there. More in
[decoding](../10-guides/00-decoding.md).

Call `dispose()` when the waveform leaves the screen. Any view handed out
beforehand dangles afterwards, so drop those first.

## Draw it

`WaveformViewport` is pure maths: which part of the audio is on screen, and at
what zoom. `resolve` picks the mipmap level for you and returns the slice to
draw, already in painter coordinates.

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
    final paint = Paint()..color = const Color(0xFFE0972F);

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

Then hand it a viewport that fits the whole file:

```dart
CustomPaint(
  painter: WavePainter(peaks, WaveformViewport.fitted(peaks, width)),
  size: Size(width, 96),
)
```

That is a complete waveform. [Drawing](../10-guides/10-drawing.md) covers zoom, pan,
the playhead and the repaint traps.

## Record

Capture needs a microphone permission, which monowave deliberately does **not**
request -- a headless package has no UI to explain why it is asking, and you do.
Declare the usage strings and ask with whatever permission plugin you already
have.

iOS `Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key><string>...</string>
```

Android `AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
```

Then open a session:

```dart
final session = await monowave.openCapture(
  const CaptureConfig(
    maxDuration: Duration(minutes: 5),
    recordTo: '/path/to/take.wav',   // omit to keep only the reduction
  ),
);

await session.start();
session.frames.listen((frame) => setState(() {}));   // about 86/sec

final peaks = await session.stop();   // caller owns these -- dispose them
```

`openCapture` throws `CaptureUnavailable` if the permission has not already been
granted. The peaks from `stop()` come from the audio thread's own history rather
than from whatever the visualizer collected, so they are complete even if the
app was backgrounded. [Capture](../10-guides/20-capture.md) covers the live meter,
pause and resume, and why there are two rings.

## Where to go next

- [Decoding](../10-guides/00-decoding.md) -- the pyramid, formats, and failures.
- [Drawing a waveform](../10-guides/10-drawing.md) -- zoom, pan, playhead, repaints.
- [Capture](../10-guides/20-capture.md) -- the meter, the rings, keeping the audio.
- [Editing](../10-guides/30-editing.md) -- documents, undo, export.
- [Voice notes](../10-guides/40-voice-notes.md) -- the path that skips the decoder.
- [Testing](../10-guides/50-testing.md) -- driving all of it with no hardware.
