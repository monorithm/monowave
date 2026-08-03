# Draw a waveform

Monowave ships no widget, so you write the painter.
This is the whole of it: resolve a window, loop over its pairs, place a rectangle.

## Point a viewport at the audio

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

## Resolve a window

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

`xOfFirstPair` is usually slightly negative, which is not a bug: the window snaps outward to whole pairs so panning stays smooth instead of stepping a bar at a time.

## Write the painter

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

## What that gets you

The specimen below is the same shape in JavaScript -- a real pyramid, a viewport
that resolves a level, and a loop over pairs. Drag to pan, scroll to zoom, and
watch the level change while the number of pairs drawn stays bounded by the
width of the canvas rather than by the length of the audio.

<!-- monokit-demo: waveform-zoom -->

That bound is the entire reason the pyramid exists. Note also that the hull is
asymmetric -- the min and the max are different distances from the centre -- which
is what an average would erase.

Next: [pan and zoom it](./20-pan-and-zoom.md), then [place a playhead](./30-place-a-playhead.md).
If a fixed-bar summary is all you need, you do not need a painter at all -- see [voice notes](./80-send-a-voice-note.md).
