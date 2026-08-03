# Your first waveform

Monowave is headless: it decodes, reduces, records and edits, and it ships no widgets.

Follow this once, in order, and you will have an app that draws a real waveform from a real file and records a new one to disk.
It stays on the shortest path on purpose -- no alternatives, no configuration you do not need yet.
When you want to do something specific afterwards, the [recipes](../10-recipes/00-decode-a-file.md) are task by task, and [concepts](../20-concepts/00-what-is-monowave.md) is where the reasoning lives.

## Install

```bash
flutter pub add monowave
```

Monowave compiles its native code with a Dart build hook, so native assets have to be enabled once, per machine:

```bash
flutter config --enable-native-assets
```

There is no CocoaPods pod, no Gradle plugin and no per-ABI binary in the package.
The C in `src/` is built from source as part of your build, for whatever you are targeting.
See [platform notes](../30-reference/10-platforms.md) for what each target needs.

## Initialize the core

Every call into the C core crosses `MonowavePlatform`.
Initialize it once, before anything else:

```dart
final monowave = MonowavePlatform.instance;
await monowave.ensureInitialized();
```

This is asynchronous entirely because of web: native targets resolve their code asset at startup and have nothing to wait for, but instantiating a WASM module is inherently async.
One await up front is cheaper than putting a `Future` in front of `reduceMinMax`, which runs once per frame while scrubbing.
On the five native targets it is a no-op.

Every other method throws `MonowaveUnavailable` until it completes.

## Decode a file

```dart
final peaks = await monowave.decodeFile(path);   // WAV, MP3 or FLAC
```

`WaveformPeaks` is a mipmap pyramid, not a flat array.
The decoder streams the file a bucket at a time, so an audiobook is never resident in memory, and the peaks themselves are a view over memory the C core owns -- a three-hour file never reaches the Dart heap.

On web there is no filesystem; use `decodeBytes` there.
More in [decode a file](../10-recipes/00-decode-a-file.md).

Call `dispose()` when the waveform leaves the screen.
Any view handed out beforehand dangles afterwards, so drop those first.

## Draw it

`WaveformViewport` is pure maths: which part of the audio is on screen, and at what zoom.
`resolve` picks the mipmap level for you and returns the slice to draw, already in painter coordinates.

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

That is a complete waveform.
[Pan and zoom](../10-recipes/20-pan-and-zoom.md) and [place a playhead](../10-recipes/30-place-a-playhead.md) take it from here.

## Record

Capture needs a microphone permission, which monowave deliberately does **not** request -- a headless package has no UI to explain why it is asking, and you do.
Declare the usage strings and ask with whatever permission plugin you already have.

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

`openCapture` throws `CaptureUnavailable` if the permission has not already been granted.
The peaks from `stop()` come from the audio thread's own history rather than from whatever the visualizer collected, so they are complete even if the app was backgrounded.
[Record audio](../10-recipes/40-record-audio.md) covers pause and resume, dropped frames, and keeping the take.

## Where to go next

You now have the whole shape of the package in one file. Pick by what you need:

**To do a specific job**, the [recipes](../10-recipes/00-decode-a-file.md) are one task each -- [pan and zoom](../10-recipes/20-pan-and-zoom.md), [draw a live meter](../10-recipes/50-draw-a-live-meter.md), [edit without touching the audio](../10-recipes/60-edit-non-destructively.md), [send a voice note](../10-recipes/80-send-a-voice-note.md), [test with no hardware](../10-recipes/90-test-without-hardware.md).

**To understand why it is shaped this way**, [what is monowave](../20-concepts/00-what-is-monowave.md) and [architecture](../20-concepts/90-architecture.md).

**To look something up**, the [API map](../30-reference/00-api-map.md) and [platform notes](../30-reference/10-platforms.md).
