# monowave

Headless audio for Flutter -- microphone capture, waveform peaks and non-destructive editing, from one C core across all six targets.

Capture, peaks and non-destructive editing that hand back data instead of widgets.
One C core, six Flutter targets, byte-identical output on every one.

```bash
flutter pub add monowave
flutter config --enable-native-assets
```

```dart
final monowave = MonowavePlatform.instance;
await monowave.ensureInitialized();

final peaks = await monowave.decodeFile(path);
final viewport = WaveformViewport.fitted(peaks, width);

// The painter is a loop over the window; no arithmetic of its own.
final window = viewport.resolve(peaks);
for (var i = 0; i < window.pairCount; i++) {
  final x = window.xOfFirstPair + i * window.pixelsPerPair;
  // window.minAt(i) .. window.maxAt(i)
}
```

## Start here

- [What is monowave?](00-start/00-what-is-monowave.md) -- what the package does, what headless means here, and why one C core rather than six platform implementations.
- [Getting started](00-start/10-getting-started.md) -- from an empty project to a waveform drawn on screen and a recording on disk.

## What the shape buys you

**Headless.** No widgets.
A decode hands back a zero-copy view over min/max peaks plus the viewport maths to place them.
The host writes the painter.

**Six targets, one core.** Android, iOS, macOS, Windows, Linux and web run the same C, over `dart:ffi` natively and WASM on web.
CI asserts the peaks come out byte-identical.

**Bounded by pixels.** Peaks are a mipmap pyramid, so zooming picks a level instead of re-reading.
A three-hour recording resolves a frame in about 6 microseconds.

**Player-agnostic.** `WaveformTimeline` maps `Duration` to samples and back and never sees a player.
`just_audio`, `media_kit` or your own engine are a few lines each.

## Guides

- [Decoding](10-guides/00-decoding.md) -- turning an audio file into a peak pyramid, and what the pyramid buys.
- [Drawing a waveform](10-guides/10-drawing.md) -- viewport maths, the peak window, and a `CustomPainter` that is a loop with no arithmetic of its own.
- [Capture](10-guides/20-capture.md) -- microphone capture, the two rings, the live meter, and keeping the audio.
- [Editing](10-guides/30-editing.md) -- non-destructive documents, the sealed edit set, preview peaks, undo and export.
- [Voice notes](10-guides/40-voice-notes.md) -- the path that skips the decoder entirely: bars computed at record time.
- [Testing](10-guides/50-testing.md) -- driving a host's tests with no microphone, no audio file and no native core.

## Reference

- [API reference](20-reference/00-api.md) -- the whole public surface of `package:monowave/monowave.dart`, grouped by what it is for.
- [Platform notes](20-reference/10-platforms.md) -- what each of the six targets supports, what web cannot do, and the native-assets requirement.
- [Architecture](20-reference/20-architecture.md) -- why headless, why FFI rather than pigeon, how the WASM half is built, and what the pyramid costs.

---

monowave is on [pub.dev](https://pub.dev/packages/monowave).
