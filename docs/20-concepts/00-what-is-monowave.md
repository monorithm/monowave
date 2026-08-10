# What is monowave?

monowave is a Flutter package for microphone capture, waveform peaks, and non-destructive audio editing.
It records audio.
It turns an audio file into a peak pyramid that you can draw at any zoom.
It edits that audio as a list of values, and it exports the result.
It does all of this work on all six Flutter targets from a single C core.

It ships no widgets at all.

## Headless is the constraint, not a detail

An audio package that ships widgets asks every host to accept its design language, or to fight it.
Worse, it asks them to accept its idea of what a waveform *is*.
A voice note, a podcast scrubber and a trim editor want three different pictures out of the same data.

So monowave draws nothing.
A decode hands back a zero-copy view over min/max peaks, plus the viewport math to place them.
A capture hands back reduced frames.
What the user sees is yours.

CI asserts that this rule holds: nothing under `lib/` imports the widget, Material or Cupertino libraries of Flutter.
A grep that returns nothing is the invariant.

The cost lands in exactly one place -- you write the `CustomPainter`.
The job of monowave is to make that painter a few lines of code, and not a research project.
[`WaveformViewport`](../10-recipes/10-draw-a-waveform.md) is the type for this job:

```dart
final window = viewport.resolve(peaks);
for (var i = 0; i < window.pairCount; i++) {
  final x = window.xOfFirstPair + i * window.pixelsPerPair;
  // window.minAt(i) .. window.maxAt(i)
}
```

That loop is the whole of it.
No arithmetic, no level selection, no clamping -- `resolve` did all of it.

## One core, six targets

Most waveform packages ship one native implementation per platform.
For two platforms that is reasonable.
For six platforms it is six decoders that will drift.
Drift in a waveform is *visible*: the same file looks different on Android and on web.

monowave compiles one C core -- [miniaudio](https://miniaud.io) plus the dr_libs decoders -- to native code on five targets via `dart:ffi`, and to WASM for web.
CI then asserts that the peaks come out byte-identical on every one of them.
That assertion is the reason that "one core" is a claim and not a hope.
The whole architecture exists to protect this property.

## Reduction is min/max, never an average

Peaks store the extremes of each window, not the mean.
An average collapses transients and shows speech as a flat sausage.
RMS is available as an optional *second* series to overlay.
A peak hull with a loudness core inside it makes a waveform read as a shape, and not as its outliers.
RMS never replaces the peaks.

## Bounded by pixels, not by file length

Peaks are a mipmap pyramid.
Level 0 is the finest resolution that the pyramid holds.
Each higher level covers two times as many samples for each pair.
A zoom picks a level, and it does not read the data again.

The test pyramid is three hours long: 476 million samples, 3.7 million pairs at the 128-sample base, and 23 levels.
On this pyramid, a full zoom sweep resolves the viewport and reads every visible pair in approximately **5.6 microseconds per frame**.
The budget for one frame at 60fps is 16,667 microseconds.
The pyramid costs two times the memory of the base level.
That memory buys this speed.

## Edits are values

A `WaveformDocument` is a list of regions.
Each region is a range in the source, a gain, and two fade lengths.
Nothing in the edit layer decodes, copies or changes audio.
The export reads the source exactly one time.

This design buys two things.
`previewPeaks` joins slices of the finest level of the source to derive the edited waveform.
Thus the waveform on screen updates the moment that an edit lands, and not after a decode.
Undo stores whole documents and not inverse operations.
This approach is cheap because an edit is a value, and there is nothing to invert.
Some edits have no inverse anyway, because a fade erases the samples that it fades.

The `EditHistory` of monolens makes the same decision, for the same reasons.

## What it does not do

| Not here | Why |
|---|---|
| Widgets | The package is headless. You write the painter. |
| Playback | `WaveformTimeline` maps `Duration` to samples and never sees a player. You can use `just_audio`, `media_kit` or your own engine. |
| A permissions API | Most applications already have one, and two requesters produce two prompts. |
| AAC / M4A decoding | It needs a platform decoder. A platform decoder means six implementations and the drift that this design avoids. More information is in the [platform notes](../30-reference/10-platforms.md). |
| Capture on web | Decode and drawing work there. Capture needs an AudioWorklet that does not exist yet. |

The AAC gap is real, and it is tolerable for one reason: the [voice-note path](../10-recipes/80-send-a-voice-note.md) never decodes at all.
The sender computes peaks at record time and ships approximately 64 bytes of metadata beside the audio.
Thus the common case never meets a decoder.

## Where to go next

- [Your first waveform](../00-start/00-tutorial.md) -- from an empty project to a waveform on screen and a recording on disk.
- [Decoding](../10-recipes/00-decode-a-file.md) and [drawing](../10-recipes/10-draw-a-waveform.md) -- the two halves that show an existing file.
- [Architecture](./90-architecture.md) -- why FFI rather than Pigeon, how the WASM half is built, and what the determinism check asserts.
