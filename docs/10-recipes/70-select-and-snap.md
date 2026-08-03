# Turn a drag into a selection

Selections live in **source samples**, not pixels or fractions, so they survive a zoom, a resize and a rotation without drifting.

```dart
var selection = WaveformSelection.at(sample);        // a drag begins
selection = selection.extendedTo(sample);            // the drag continues
selection = selection.withNearestEdgeAt(sample);     // dragging a handle
selection = selection.shiftedBy(delta);              // sliding the whole range
selection = selection.clampedTo(peaks);              // never leaves the audio
```

Turn a gesture into samples with the viewport:

```dart
final sample = viewport.sampleAtX(details.localPosition.dx).toInt();
```

`withNearestEdgeAt` is what makes handle-dragging feel right without tracking which handle was grabbed: it moves whichever edge is closer to the pointer.

## Snap a cut to a sensible place

```dart
final cut = WaveformSnap.toZeroCrossing(peaks, selection.start);
final cut = WaveformSnap.toQuietest(peaks, selection.start);
```

`toZeroCrossing` finds the nearest bucket whose extremes straddle zero, so cutting inside it lands on or beside a sign change and avoids the click that cutting mid-swing produces.

`toQuietest` is usually the better default for speech: the silence between words is a more forgiving edit point than a zero crossing mid-syllable.

Both are bucket-accurate rather than sample-accurate -- about 3 ms at the default base resolution.
That is inaudible for a trim point, and [architecture](../20-concepts/90-architecture.md) explains what sample-exact snapping would cost.

Then apply it: see [editing](./60-edit-non-destructively.md).
