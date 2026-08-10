# Place a playhead and seek

`WaveformTimeline` is the whole relationship between monowave and playback.
The class takes a sample rate and a length, and it does not take a player.
Thus `just_audio`, `media_kit`, or your own engine each need a few lines of adapter code.
None of them is a dependency here.

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

Put the waveform and the playhead in separate painters behind a `RepaintBoundary`.
Then make the `shouldRepaint` function of the body ignore progress.
Without these two steps, the scrub stalls.

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

A scrub then repaints a clipped overlay, and not every bar in the file.
At 60 frames each second over a three-hour recording, this split decides between a smooth scrub and a stalled scrub.

## For a live meter, key on `revision`

A meter that [capture](./40-record-audio.md) drives is the other repaint trap.
This trap fails in the opposite direction.
The meter never repaints, and it gives no error.

`CaptureScope` is a ring that changes in place.
After the ring is full, the length of the ring never changes again.
Thus a `shouldRepaint` that keys on `length` no longer triggers a repaint:

```dart
@override
bool shouldRepaint(MeterPainter old) => old.revision != revision;
```
