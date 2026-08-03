# Editing

An edit is a **value**, not a command against a buffer.
Nothing in this layer decodes, copies or mutates audio; the source is read exactly once, at export.

## The document

A `WaveformDocument` is a list of regions.
A region is a range in the source plus a gain and two fade lengths -- no audio, just numbers:

```dart
var doc = WaveformDocument.of(peaks);   // the whole source, unedited

doc.lengthInSamples;          // length of the result
doc.sourceOf(outputSample);   // where an output sample came from, or null
```

`sourceOf` matters more than it looks.
The output timeline and the source timeline diverge the moment anything is deleted, and confusing the two is the classic editing bug.

## Applying edits

```dart
doc = doc.applying(TrimEdit(selection));                 // keep only this
doc = doc.applying(DeleteEdit(selection));               // remove, close the gap
doc = doc.applying(SplitEdit(sample));                   // cut, changing nothing
doc = doc.applying(GainEdit(selection, 1.5));            // scale what overlaps
doc = doc.applying(FadeEdit(selection, fadeIn: 2048, fadeOut: 2048));
```

`applying` never mutates the receiver -- it returns a new document.

The five edits form a **sealed** set, so a renderer or an exporter can switch over them exhaustively and the compiler catches a kind that was not handled:

```dart
String describe(WaveformEdit edit) => switch (edit) {
  TrimEdit() => 'Trim',
  DeleteEdit() => 'Delete',
  SplitEdit() => 'Split',
  GainEdit(:final gain) => 'Gain ${gain}x',
  FadeEdit() => 'Fade',
};
```

`SplitEdit` changes nothing audible on its own.
It is a setup move: it gives the next edit an edge to act on.

## Previewing without decoding

```dart
final preview = doc.previewPeaks(peaks);
```

This derives the edited waveform by concatenating each region's slice of the source's finest level and scaling by gain -- so the display updates the instant an edit lands rather than after a round trip through the decoder.
This is the payoff of keeping edits non-destructive.

Fades are not reflected in the preview.
They act over samples, and the finest level is 128 samples wide, so a typical fade is narrower than one bar.

## Selections

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

### Snapping

```dart
final cut = WaveformSnap.toZeroCrossing(peaks, selection.start);
final cut = WaveformSnap.toQuietest(peaks, selection.start);
```

`toZeroCrossing` finds the nearest bucket whose extremes straddle zero, so cutting inside it lands on or beside a sign change and avoids the click that cutting mid-swing produces.

`toQuietest` is usually the better default for speech: the silence between words is a more forgiving edit point than a zero crossing mid-syllable.

:::note[Snapping is bucket-accurate, not sample-accurate] Both work from peaks, so they resolve to the finest level -- about 3 ms with a 128-sample base at 44.1 kHz.
That is inaudible for a trim point, and it is worth stating plainly because "snap to zero crossing" normally implies exactness.
Sample-exact snapping would mean re-reading the source on every gesture, which is a decode per drag. :::

## Undo

```dart
final history = EditHistory(WaveformDocument.of(peaks));

history.apply(DeleteEdit(selection));
history.apply(GainEdit(other, 1.5));

if (history.canUndo) history.undo();
if (history.canRedo) history.redo();

history.current;      // the document as it stands
history.undoLabel;    // 'Delete' -- for a menu item, or null
history.redoLabel;
history.depth;        // steps taken, not counting the initial state
```

Undo is **snapshots**, not inverse operations.
That is cheap precisely because an edit is a value: there is nothing to invert, and some edits have no inverse at all -- a fade destroys the samples it fades.
A document is a handful of regions, so a hundred steps of history on a heavily cut file is still a few kilobytes.

Applying an edit after undoing discards what had been undone -- the usual branch-and-forget behaviour, because keeping a tree would need UI nobody asked for.

`EditHistory` is deliberately **not** a `ChangeNotifier`: `lib/` must not import Flutter's widget layer, so you wrap it in whatever state management you already use.

## Export

```dart
await monowave.exportWav(
  sourcePath: path,
  outputPath: out,
  document: doc,
);
```

Output is always WAV, 16-bit PCM.
An edit list is meant to reproduce the source exactly where it did not change it, and re-encoding through a lossy codec would quietly break that.
It is also what capture writes, so a recording round-trips through the editor without a second format in play.

Fades are linear rather than equal-power, because they exist to take the click off an edit point rather than to crossfade two takes -- and linear is what makes the endpoints exactly 0 and 1.

Export is not available on web, which has no filesystem to write to.

An empty document is refused rather than producing a zero-length file.
