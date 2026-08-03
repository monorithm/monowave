# Pan and zoom a waveform

Every gesture produces a new `WaveformViewport` and repaints.
There is no state to mutate and nothing to keep in sync.

```dart
// Positive dx moves content left.
viewport = viewport.pannedBy(details.delta.dx).clampedTo(peaks);

// factor above 1 zooms in; the sample under focusX stays put.
viewport = viewport.zoomedAt(focalX, details.scale).clampedTo(peaks);

// On a resize, keep the left edge and the zoom.
viewport = viewport.resized(newWidth);
```

Anchoring a zoom on the focal point is what makes a pinch feel attached to the audio rather than to the widget.

## Always clamp

**`clampedTo` is not optional.**
It bounds scroll so the audio cannot be lost off-screen, refuses to zoom out past the whole file, and refuses to zoom in past `finestSamplesPerPixel` -- there is no finer data in memory, so the result would just be a stretched version of the same bars.

## Use a scale recognizer, not a pan recognizer

A pan recognizer never reports a second finger, so a pinch is invisible to it.
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

`resized` keeps the left edge and the zoom, so a rotation or a split-screen change does not throw the reader back to the start of the file:

```dart
@override
void didUpdateWidget(covariant WaveView old) {
  super.didUpdateWidget(old);
  if (widget.width != old.width) {
    viewport = viewport.resized(widget.width).clampedTo(peaks);
  }
}
```
