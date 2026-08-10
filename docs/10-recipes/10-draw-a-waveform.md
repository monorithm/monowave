# Draw a waveform

monowave ships no widget, so you write the painter.
The painter does three things: it resolves a window, it loops over the pairs, and it places a rectangle.

## Point a viewport at the audio

`WaveformViewport` defines which part of the audio is on screen, and the zoom level.
`WaveformViewport` is pure math, and it is immutable.
Every gesture produces a new viewport and does not change the old one.
Thus the class binds to any state management.

```dart
final viewport = WaveformViewport(
  startSample: 0,            // may be fractional, for subpixel-smooth panning
  samplesPerPixel: 512,      // smaller is more zoomed in
  widthPx: 360,
);

// Or just fit the whole file:
final viewport = WaveformViewport.fitted(peaks, width);
```

`startSample` is deliberately a `double`.
With an integer, a pan steps one sample at a time.
This step is visible at high zoom.

## Resolve a window

`resolve` picks the mipmap level for the current zoom.
`resolve` returns the slice to draw, already in painter coordinates:

```dart
final window = viewport.resolve(peaks);
```

`PeakWindow` carries everything that the loop needs:

| Field | What it is |
|---|---|
| `pairCount` | The number of pairs to draw. |
| `xOfFirstPair` | The start of the first pair, in viewport pixels. |
| `pixelsPerPair` | The width of one pair on screen. |
| `minAt(i)` / `maxAt(i)` | The extremes of pair `i`, 0-based in the window. |
| `rmsAt(i)` | The RMS of pair `i`. If the pyramid carries no RMS, this value is null. |
| `level` | The mipmap level of this window. This field is useful for a debug overlay. |

`xOfFirstPair` is usually a small negative number.
This value is not an error.
The window snaps outward to whole pairs.
As a result, a pan stays smooth and does not step one bar at a time.

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

The loop does no arithmetic, except the arithmetic that places a rectangle.
`resolve` already selected the level, clamped the window, and converted the coordinates.

## What that gets you

The specimen below is the same shape in JavaScript.
The specimen has a real pyramid, a viewport that resolves a level, and a loop over pairs.

- Drag to pan.
- Scroll to zoom.
- Watch the level change.

The width of the canvas bounds the number of pairs on screen.
The length of the audio does not bound that number.

<!-- monokit-demo: waveform-zoom -->

That bound is the whole reason that the pyramid exists.
The hull is also asymmetric, because the min and the max are different distances from the center.
An average erases this difference.

Next, read [pan and zoom it](./20-pan-and-zoom.md).
Then read [place a playhead](./30-place-a-playhead.md).
If you need only a fixed-bar summary, you do not need a painter.
The [voice notes](./80-send-a-voice-note.md) recipe shows that path.
