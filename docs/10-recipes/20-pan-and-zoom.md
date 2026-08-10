# Pan and zoom a waveform

Every gesture produces a new `WaveformViewport` and repaints.
There is no state to change, and there is nothing to keep in sync.

```dart
// Positive dx moves content left.
viewport = viewport.pannedBy(details.delta.dx).clampedTo(peaks);

// factor above 1 zooms in; the sample under focusX stays put.
viewport = viewport.zoomedAt(focalX, details.scale).clampedTo(peaks);

// On a resize, keep the left edge and the zoom.
viewport = viewport.resized(newWidth);
```

When you anchor a zoom on the focal point, the pinch feels attached to the audio and not to the widget.

## Always clamp

**`clampedTo` is not optional.**
The method does three things:

- It bounds the pan, so the audio cannot go off-screen.
- It refuses a zoom out past the whole file.
- It refuses a zoom in past `finestSamplesPerPixel`.

Memory holds no data that is finer than `finestSamplesPerPixel`.
A zoom past that limit gives only a stretched version of the same bars.

## Use a scale recognizer, not a pan recognizer

A pan recognizer never reports a second finger.
Thus a pinch is invisible to a pan recognizer.
A `ScaleGestureRecognizer` with a single pointer reports a drag, so one recognizer covers both gestures:

```dart
ScaleGestureRecognizer()
  ..onUpdate = (details) {
    setState(() {
      viewport = (details.scale == 1.0
              ? viewport.pannedBy(-details.focalPointDelta.dx)
              : viewport.zoomedAt(details.localFocalPoint.dx, details.scale))
          .clampedTo(peaks);
    });
  };
```

## Survive a resize

`resized` keeps the left edge and the zoom.
Thus a rotation or a split-screen change does not move the user back to the start of the file:

```dart
@override
void didUpdateWidget(covariant WaveView old) {
  super.didUpdateWidget(old);
  if (widget.width != old.width) {
    viewport = viewport.resized(widget.width).clampedTo(peaks);
  }
}
```
