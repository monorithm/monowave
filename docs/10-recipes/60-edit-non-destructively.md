# Edit without touching the audio

Nothing in this layer decodes, copies or mutates audio.
A document is a list of regions -- a range in the source plus a gain and two fade lengths -- and the source is read exactly once, at export.

```dart
var doc = WaveformDocument.of(peaks);   // the whole source, unedited

doc.lengthInSamples;          // length of the result
doc.sourceOf(outputSample);   // where an output sample came from, or null
```

`sourceOf` matters more than it looks.
The output timeline and the source timeline diverge the moment anything is deleted, and confusing the two is the classic editing bug.

## Apply an edit

```dart
doc = doc.applying(TrimEdit(selection));                 // keep only this
doc = doc.applying(DeleteEdit(selection));               // remove, close the gap
doc = doc.applying(SplitEdit(sample));                   // cut, changing nothing
doc = doc.applying(GainEdit(selection, 1.5));            // scale what overlaps
doc = doc.applying(FadeEdit(selection, fadeIn: 2048, fadeOut: 2048));
```

`applying` never mutates the receiver -- it returns a new document.

`SplitEdit` changes nothing audible on its own.
It is a setup move: it gives the next edit an edge to act on.

## Switch over the edits exhaustively

The five edits are a **sealed** set, so the compiler catches a kind a renderer or exporter did not handle:

```dart
String describe(WaveformEdit edit) => switch (edit) {
  TrimEdit() => 'Trim',
  DeleteEdit() => 'Delete',
  SplitEdit() => 'Split',
  GainEdit(:final gain) => 'Gain ${gain}x',
  FadeEdit() => 'Fade',
};
```

## Preview without re-decoding

```dart
final preview = doc.previewPeaks(peaks);
```

This derives the edited waveform by concatenating each region's slice of the source's finest level and scaling by gain, so the display updates the instant an edit lands rather than after a round trip through the decoder.

Fades are not reflected in the preview.
They act over samples, and the finest level is 128 samples wide, so a typical fade is narrower than one bar.

## Wire undo and redo

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

Applying an edit after undoing discards what had been undone -- the usual branch-and-forget behaviour.

`EditHistory` is deliberately **not** a `ChangeNotifier`: `lib/` must not import Flutter's widget layer, so wrap it in whatever state management you already use.
[Architecture](../20-concepts/90-architecture.md) explains why undo is snapshots rather than inverse operations.

## Export

```dart
await monowave.exportWav(
  sourcePath: path,
  outputPath: out,
  document: doc,
);
```

Output is always WAV, 16-bit PCM, which is also what capture writes -- so a recording round-trips through the editor without a second format in play.

An empty document is refused rather than producing a zero-length file, and export is not available on web, which has no filesystem to write to.
