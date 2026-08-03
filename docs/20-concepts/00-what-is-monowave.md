# What is monowave?

Monowave is a Flutter package for microphone capture, waveform peaks, and non-destructive audio editing.
It records; it turns an audio file into a peak pyramid you can draw at any zoom; it edits that audio as a list of values and exports the result.
It does all of it on all six Flutter targets from a single C core.

It ships no widgets at all.

## Headless is the constraint, not a detail

An audio package that ships widgets asks every consumer to accept its design language, or to fight it.
Worse, it asks them to accept its idea of what a waveform *is* -- and a voice note, a podcast scrubber and a trim editor want three different pictures out of the same data.

So monowave draws nothing.
A decode hands back a zero-copy view over min/max peaks plus the viewport maths to place them.
A capture hands back reduced frames.
What the listener sees is yours.

The rule is checkable, and CI checks it: nothing under `lib/` imports Flutter's widget, Material or Cupertino libraries.
A grep returning nothing is the invariant.

The cost lands in exactly one place -- you write the `CustomPainter`.
Monowave's job is to make that a few lines rather than a research project, which is what [`WaveformViewport`](../10-recipes/10-draw-a-waveform.md) is for:

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
For six it is six decoders that will drift, and drift in a waveform is *visible*: the same file renders differently on Android and on web.

Monowave compiles one C core -- [miniaudio](https://miniaud.io) plus the dr_libs decoders -- to native code on five targets via `dart:ffi`, and to WASM for web.
CI then asserts the peaks come out byte-identical on every one of them.
That assertion is the reason "one core" is a claim rather than a hope, and it is the property the whole architecture exists to protect.

## Reduction is min/max, never an average

Peaks store the extremes of each window, not the mean.
Averaging collapses transients and renders speech as a flat sausage.
RMS is available as an optional *second* series to overlay -- a peak hull with a loudness core inside it is what makes a waveform read as a shape rather than as its outliers -- but it never replaces the peaks.

## Bounded by pixels, not by file length

Peaks are a mipmap pyramid: level 0 is the finest resolution held, and each level above covers twice as many samples per pair.
Zooming picks a level instead of re-reading data.

Measured on a three-hour pyramid -- 476 million samples, 3.7 million pairs at the 128-sample base, 23 levels -- a full zoom sweep resolves the viewport and reads every visible pair in about **5.6 microseconds per frame**, against a 60fps budget of 16,667.
The pyramid costs double the base level's memory, and that is what it buys.

## Edits are values

A `WaveformDocument` is a list of regions: a range in the source, a gain, two fade lengths.
Nothing in the edit layer decodes, copies or mutates audio -- the source is read exactly once, at export.

That buys two things.
`previewPeaks` derives the edited waveform by concatenating slices of the source's finest level, so the display updates the instant an edit lands rather than after a decode.
And undo stores whole documents rather than inverse operations, which is cheap precisely because an edit is a value -- there is nothing to invert, and some edits have no inverse anyway, since a fade destroys the samples it fades.

This is the same call monolens's `EditHistory` makes, for the same reasons.

## What it does not do

| Not here | Why |
|---|---|
| Widgets | The package is headless. You write the painter. |
| Playback | `WaveformTimeline` maps `Duration` to samples and never sees a player. Use `just_audio`, `media_kit` or your own. |
| A permissions API | Most apps already have one, and two requesters produce two prompts. |
| AAC / M4A decoding | It needs a platform decoder, which would mean six implementations and the drift this design avoids. See [platform notes](../30-reference/10-platforms.md). |
| Capture on web | Decode and drawing work there; capture needs an AudioWorklet that does not exist yet. |

The AAC gap is real, and it is tolerable for one reason: the [voice-note path](../10-recipes/80-send-a-voice-note.md) never decodes at all.
The sender computes peaks at record time and ships roughly 64 bytes of metadata beside the audio, so the common case never meets a decoder.

## Where to go next

- [Getting started](../00-start/00-tutorial.md) -- from an empty project to a waveform on screen and a recording on disk.
- [Decoding](../10-recipes/00-decode-a-file.md) and [drawing](../10-recipes/10-draw-a-waveform.md) -- the two halves of showing an existing file.
- [Architecture](./90-architecture.md) -- why FFI rather than pigeon, how the WASM half is built, and what the determinism check actually asserts.
