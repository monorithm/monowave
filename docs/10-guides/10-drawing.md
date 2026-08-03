# Drawing a waveform

Monowave ships no widget, so you write the painter.
Everything on this page exists to make that a few lines rather than a research project.

## The viewport

`WaveformViewport` is which part of the audio is on screen and at what zoom.
It is pure maths and immutable -- every gesture produces a new one rather than mutating one, so it binds to any state management.

```dart
final viewport = WaveformViewport(
  startSample: 0,            // may be fractional, for subpixel-smooth panning
  samplesPerPixel: 512,      // smaller is more zoomed in
  widthPx: 360,
);

// Or just fit the whole file:
final viewport = WaveformViewport.fitted(peaks, width);
```

`startSample` is a `double` on purpose.
An integer would make panning step a sample at a time, which is visible at high zoom.

## Resolving a window

`resolve` picks the mipmap level for the current zoom and returns the slice to draw, already converted to painter coordinates:

```dart
final window = viewport.resolve(peaks);
```

`PeakWindow` carries everything the loop needs:

| Field | What it is |
|---|---|
| `pairCount` | How many pairs to draw. |
| `xOfFirstPair` | Where the first pair starts, in viewport pixels. |
| `pixelsPerPair` | Width of one pair on screen. |
| `minAt(i)` / `maxAt(i)` | The extremes of pair `i`, 0-based within the window. |
| `rmsAt(i)` | The RMS of pair `i`, or null if the pyramid carries none. |
| `level` | Which mipmap level this came from. Useful for a debug overlay. |

`xOfFirstPair` is usually slightly negative.
That is deliberate: the window snaps outward to whole pairs, so panning stays smooth instead of stepping a bar at a time.
Clipping to the pair boundary instead would make a pan visibly judder.

## The painter

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

    final hull = Paint()..color = const Color(0xFFE0972F);
    final core = Paint()..color = const Color(0xFF34D399);

    for (var i = 0; i < window.pairCount; i++) {
      final x = window.xOfFirstPair + i * window.pixelsPerPair;
      final w = window.pixelsPerPair;

      // The peak hull: max is the top, min is negative so it falls below.
      canvas.drawRect(
        Rect.fromLTRB(x, mid - window.maxAt(i) * scale,
                      x + w, mid - window.minAt(i) * scale),
        hull,
      );

      // The RMS core, drawn inside it.
      final rms = window.rmsAt(i);
      if (rms != null) {
        canvas.drawRect(
          Rect.fromLTRB(x, mid - rms * scale, x + w, mid + rms * scale),
          core,
        );
      }
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

There is no arithmetic in that loop beyond placing a rectangle.
`resolve` did the level selection, the clamping and the coordinate conversion.

## Zoom and pan

```dart
// Positive dx moves content left.
viewport = viewport.pannedBy(details.delta.dx).clampedTo(peaks);

// factor above 1 zooms in; the sample under focusX stays put.
viewport = viewport.zoomedAt(focalX, details.scale).clampedTo(peaks);

// On a resize, keep the left edge and the zoom.
viewport = viewport.resized(newWidth);
```

Anchoring a zoom on the focal point is what makes a pinch feel attached to the audio rather than to the widget.

**Always `clampedTo`.**
It bounds scroll so the audio cannot be lost off-screen, refuses to zoom out past the whole file, and refuses to zoom in past `finestSamplesPerPixel` -- there is no finer data in memory, so the result would just be a stretched version of the same bars.

Use a `ScaleGestureRecognizer` rather than a pan recognizer.
A pan recognizer never reports a second finger, so a pinch is invisible to it; a scale recognizer with a single pointer reports a drag.

## Playhead and seeking

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

## Repaint traps

Two of these will bite, so they are worth stating plainly.

**Split the playhead out of the body.**
Put the two in separate painters behind a `RepaintBoundary` and let the body's `shouldRepaint` ignore progress entirely.
Scrubbing then repaints a clipped overlay rather than every bar in the file.

**For a live meter, key on `revision`, not `length`.**
`CaptureScope` is a ring that mutates in place, so once it is full its length never changes again -- a `shouldRepaint` keyed on length silently stops repainting.
See [capture](./20-capture.md).

## What a design-system waveform cannot do

If you only need a fixed-bar voice note, you do not need a painter at all: `CompactBars.heights()` produces heights ready to feed a component like monokit's `MonoWaveform`.
See [voice notes](./40-voice-notes.md).

What that shape cannot do is min/max asymmetry and a viewport that zooms, both of which need more than one number per bar.
That is what `PeakWindow` and `WaveformViewport` are for.
