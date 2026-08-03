# Place a playhead and seek

`WaveformTimeline` is the whole of monowave's relationship with playback.
It takes a sample rate and a length, not a player, so `just_audio`, `media_kit` or your own engine are each a few lines of adapter in your code and none of them are a dependency here.

```dart
final timeline = WaveformTimeline.of(peaks);

// Place the playhead.
final x = viewport.xForSample(timeline.sampleAt(player.position));

// Turn a tap into a seek.
player.seek(timeline.timeAt(viewport.sampleAtX(localX)));

// For a fixed-bar voice note, whose x axis *is* progress.
final t = timeline.timeAtProgress(0.35);
```

## Split the playhead out of the body

This one will bite otherwise.
Put the waveform and the playhead in separate painters behind a `RepaintBoundary`, and let the body's `shouldRepaint` ignore progress entirely:

```dart
Stack(
  children: [
    RepaintBoundary(
      child: CustomPaint(painter: WavePainter(peaks, viewport)),
    ),
    CustomPaint(painter: PlayheadPainter(x)),
  ],
)
```

Scrubbing then repaints a clipped overlay rather than every bar in the file.
At sixty frames a second over a three-hour recording, that is the difference between a smooth scrub and a stalled one.

## For a live meter, key on `revision`

A meter driven by [capture](./40-record-audio.md) is the other repaint trap, and it fails in the opposite direction -- silently, by never repainting at all.
`CaptureScope` is a ring that mutates in place, so once it is full its length never changes again and a `shouldRepaint` keyed on `length` stops firing:

```dart
@override
bool shouldRepaint(MeterPainter old) => old.revision != revision;
```
