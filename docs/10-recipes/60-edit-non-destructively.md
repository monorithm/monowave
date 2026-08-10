# Edit without touching the audio

Nothing in this layer decodes, copies or changes audio.
A document is a list of regions.
Each region is a range in the source, plus a gain and two fade lengths.
monowave reads the source exactly one time, at export.

```dart
var doc = WaveformDocument.of(peaks);   // the whole source, unedited

doc.lengthInSamples;          // length of the result
doc.sourceOf(outputSample);   // where an output sample came from, or null
```

`sourceOf` is more important than it looks.
The output timeline and the source timeline diverge the moment that you remove any audio.
If you use one timeline in place of the other, the result is the classic bug in an editor.

## Apply an edit

```dart
doc = doc.applying(TrimEdit(selection));                 // keep only this
doc = doc.applying(DeleteEdit(selection));               // remove, close the gap
doc = doc.applying(SplitEdit(sample));                   // cut, changing nothing
doc = doc.applying(GainEdit(selection, 1.5));            // scale what overlaps
doc = doc.applying(FadeEdit(selection, fadeIn: 2048, fadeOut: 2048));
```

`applying` never changes the receiver.
It returns a new document instead.

`SplitEdit` alone changes nothing that you can hear.
It is a preparation step, because it gives the next edit an edge to use.

## Switch over the edits exhaustively

The five edits are a **sealed** set.
Thus the compiler catches a kind of edit that a renderer or an exporter does not handle:

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

This call derives the edited waveform.
It concatenates the slice of each region from the finest level of the source, and scales the slice by the gain.
The waveform on screen therefore updates the moment that an edit lands, and not after a round trip through the decoder.

The preview does not show the fades.
A fade acts over samples, and the finest level is 128 samples wide.
A typical fade is therefore narrower than one bar.

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

If you apply an edit after an undo, the history erases the steps that the undo removed.
The history has the usual branch-and-forget behavior.

`EditHistory` is deliberately **not** a `ChangeNotifier`.
The code in `lib/` must not import the widget layer of Flutter.
Wrap `EditHistory` in the state management that your application already uses.
[Architecture](../20-concepts/90-architecture.md) explains why undo uses snapshots and not inverse operations.

## Export

```dart
await monowave.exportWav(
  sourcePath: path,
  outputPath: out,
  document: doc,
);
```

The output is always 16-bit PCM WAV, which is also the format that capture writes.
You can therefore record, edit and export audio with only one format.

`exportWav` refuses an empty document, and does not write a zero-length file.
Export is not available on web, because web has no filesystem to write to.
