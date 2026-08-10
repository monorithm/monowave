# Your first waveform

monowave is headless. It decodes, reduces, records and edits. It contains no widgets.

Do these steps in order. Then you have an application that draws a real waveform from a real file. The application also records a new waveform to disk.

This tutorial deliberately keeps to the shortest path. It gives no alternatives and no configuration that you do not need yet.

After this tutorial, read the [recipes](../10-recipes/00-decode-a-file.md) for one specific job. Each recipe is one task. The [concepts](../20-concepts/00-what-is-monowave.md) pages hold the reasoning.

## Install

```bash
flutter pub add monowave
```

monowave compiles its native code with a Dart build hook. As a result, enable native assets one time on each machine:

```bash
flutter config --enable-native-assets
```

There is no CocoaPods pod, no Gradle plugin and no per-ABI binary in the package.
Your build compiles the C code in `src/` from source, for each target that you select.
Read [platform notes](../30-reference/10-platforms.md) for the requirements of each target.

## Initialize the core

Every call into the C core passes through `MonowavePlatform`.
Initialize this platform one time, before all other calls:

```dart
final monowave = MonowavePlatform.instance;
await monowave.ensureInitialized();
```

This method is asynchronous only because of web. Native targets resolve their code asset at startup, and they wait for nothing. Web must instantiate a WASM module, and that operation is asynchronous by nature.

One await at the start is cheaper than a `Future` in front of `reduceMinMax`. During a scrub, `reduceMinMax` runs one time for each frame. On the five native targets, `ensureInitialized` is a no-op.

Until `ensureInitialized` completes, every other method throws `MonowaveUnavailable`.

## Decode a file

```dart
final peaks = await monowave.decodeFile(path);   // WAV, MP3 or FLAC
```

`WaveformPeaks` is a mipmap pyramid, not a flat array.
The decoder streams the file one bucket at a time. As a result, an audiobook is never resident in memory. The peaks are a view over memory that the C core owns. Because of this, a three-hour file never reaches the Dart heap.

Web has no filesystem. On web, use `decodeBytes`.
For more information, read [decode a file](../10-recipes/00-decode-a-file.md).

When the waveform leaves the screen, call `dispose()`.
Each view that you got before `dispose()` dangles after that call. Remove those views before you call `dispose()`.

## Draw the waveform

`WaveformViewport` is pure math. It gives the part of the audio that is on screen, and the zoom level.
`resolve` selects the mipmap level for you. It returns the slice to draw, already in painter coordinates.

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

Then give the painter a viewport that fits the whole file:

```dart
CustomPaint(
  painter: WavePainter(peaks, WaveformViewport.fitted(peaks, width)),
  size: Size(width, 96),
)
```

That is a complete waveform.
[Pan and zoom](../10-recipes/20-pan-and-zoom.md) and [place a playhead](../10-recipes/30-place-a-playhead.md) continue from this point.

## Record

Capture needs a microphone permission. monowave deliberately does **not** request this permission. A headless package has no UI that explains the reason for the request. Your application has this UI.

Declare the usage strings. Then request the permission with the permission plugin that you already use.

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

If the permission is not already granted, `openCapture` throws `CaptureUnavailable`.
The peaks from `stop()` come from the history that the audio thread keeps. They do not come from the data that the visualizer collected. Even if the application was in the background, the peaks are complete.
[Record audio](../10-recipes/40-record-audio.md) covers pause and resume, dropped frames, and how to keep the take.

## What to read next

This one page gave you the whole shape of the package. Select by what you need:

**To do a specific job**, read the [recipes](../10-recipes/00-decode-a-file.md). Each recipe is one task: [pan and zoom](../10-recipes/20-pan-and-zoom.md), [draw a live meter](../10-recipes/50-draw-a-live-meter.md), [edit without touching the audio](../10-recipes/60-edit-non-destructively.md), [send a voice note](../10-recipes/80-send-a-voice-note.md), [test with no hardware](../10-recipes/90-test-without-hardware.md).

**To understand why the package has this shape**, read [what is monowave](../20-concepts/00-what-is-monowave.md) and [architecture](../20-concepts/90-architecture.md).

**To find a specific detail**, read the [API map](../30-reference/00-api-map.md) and the [platform notes](../30-reference/10-platforms.md).
