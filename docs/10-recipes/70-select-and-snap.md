# Turn a drag into a selection

Selections live in **source samples**, not in pixels or fractions.
As a result, a zoom, a resize or a rotation does not make a selection drift.

```dart
var selection = WaveformSelection.at(sample);        // a drag begins
selection = selection.extendedTo(sample);            // the drag continues
selection = selection.withNearestEdgeAt(sample);     // dragging a handle
selection = selection.shiftedBy(delta);              // sliding the whole range
selection = selection.clampedTo(peaks);              // never leaves the audio
```

To turn a gesture into samples, use the viewport:

```dart
final sample = viewport.sampleAtX(details.localPosition.dx).toInt();
```

`withNearestEdgeAt` moves the edge that is nearer to the pointer.
As a result, a handle drag feels correct, and your code does not have to record which handle the drag started on.

## Snap a cut to a good position

```dart
final cut = WaveformSnap.toZeroCrossing(peaks, selection.start);
final cut = WaveformSnap.toQuietest(peaks, selection.start);
```

`toZeroCrossing` finds the nearest bucket whose extremes are on opposite sides of zero.
A cut in that bucket lands on a sign change, or beside one.
A cut in the middle of a swing makes a click, and this snap prevents that click.

For speech, `toQuietest` is usually the better default.
The silence between words is a safer edit point than a zero crossing in the middle of a syllable.

Both functions are accurate to a bucket, and not to a sample.
At the default base resolution, one bucket is approximately 3 ms.
For a trim point, 3 ms is inaudible.
The [architecture](../20-concepts/90-architecture.md) page explains the cost of a snap that is exact to the sample.

To apply the cut, read [editing](./60-edit-non-destructively.md).
