# Decoding

A decode turns an audio file into a `WaveformPeaks` -- a mipmap pyramid of
min/max pairs, plus the sample rate and length needed to place them on a
timeline.

## The two entry points

```dart
final monowave = MonowavePlatform.instance;
await monowave.ensureInitialized();

// Native: streams the file a bucket at a time.
final peaks = await monowave.decodeFile(path);

// Web, or bytes you already hold.
final peaks = await monowave.decodeBytes(bytes);
```

Prefer `decodeFile` on native. The decoder never holds the whole file, so an
audiobook is decoded without ever being resident in memory. `decodeBytes` is the
only path on web, which has no filesystem.

Both take `baseSamplesPerPixel`, which sets the finest resolution the pyramid
holds. The default of 128 is about 3 ms at 44.1 kHz -- fine enough that no
sensible zoom outruns it, coarse enough that the pyramid stays small. Lower it
only if you need to zoom past that, and know that it costs memory linearly.

## What a pyramid is

Level 0 is the finest resolution held. Each level above it covers twice as many
samples per min/max pair:

| | Samples per pair | Pairs (3-hour file) |
|---|---|---|
| Level 0 | 128 | 3,720,937 |
| Level 1 | 256 | 1,860,468 |
| Level 2 | 512 | 930,234 |
| ... | ... | ... |
| Level 22 | 536,870,912 | 1 |

Zooming picks a level rather than re-reading data, which is what makes a pan
over a three-hour recording cost the same as a pan over thirty seconds. That is
the whole reason the pyramid exists, and it costs double the base level's
memory.

```dart
peaks.levelCount;                  // 23
peaks.samplesPerPixel(level);      // 128 << level
peaks.pairCount(level);
peaks.finestSamplesPerPixel;       // 128 -- zooming past this cannot be served
peaks.levelFor(samplesPerPixel);   // the level a given zoom should read
```

You rarely call these directly. [`WaveformViewport`](./10-drawing.md) picks the
level and slices the window for you.

## Reading the data

```dart
final Int16List view = peaks.view(level);   // [min0, max0, min1, max1, ...]
final Int16List? rms = peaks.rms(level);    // one value per pair, or null
```

`view` is **zero-copy and not defensively copied**. On native it is a view
straight into memory the C core owns, which is what keeps a three-hour recording
off the Dart heap. Treat it as read-only: writing to it corrupts every level
built above it.

`rms` is a second series, aligned pair-for-pair with the peaks. Peaks say how
far the audio went; RMS says how much of it there was. Drawing both -- a peak
hull with an RMS core inside it -- is what makes a waveform read as a shape
rather than as its outliers. It is null for pyramids built in Dart from raw
samples; the C core always provides it.

### Reduction is min/max, never an average

Averaging collapses transients and renders speech as a flat sausage. Every level
above the base combines its children by taking the min of the mins and the max
of the maxes, so the extremes of the moment survive all the way up. RMS combines
as the root of the mean of the squares, so a coarse level stays an RMS rather
than becoming an average of averages.

## Memory, and disposing

```dart
peaks.dispose();   // idempotent; a no-op for Dart-built pyramids
```

Peaks the C core allocated are backed by native memory, and `dispose` releases
it. Call it when the waveform leaves the screen. Any view handed out beforehand
dangles afterwards, so drop those first -- reading a disposed pyramid throws a
`StateError` rather than reading freed memory.

Web differs here on purpose. Growing the WASM heap detaches every outstanding
view over it, so the web binding **copies** the pyramid out of the heap and
frees the native allocation immediately. Web pays a few hundred kilobytes for a
normal recording; native keeps the zero-copy property an audiobook needs. Either
way `dispose` is the correct thing to call.

## Formats, and the gap

WAV, MP3 and FLAC, through the dr_libs single-header decoders.

**AAC and M4A are not supported**, and report
`DecodeFailure.unsupportedFormat`. Supporting them needs a platform decoder,
which would mean six implementations and exactly the drift this architecture
exists to avoid. It is a real gap -- it is what `record` produces by default on
iOS -- and it is tolerable because the [voice-note path](./40-voice-notes.md) never
decodes at all.

## Failures

```dart
try {
  final peaks = await monowave.decodeFile(path);
} on MonowaveDecodeException catch (error) {
  switch (error.failure) {
    case DecodeFailure.unsupportedFormat:  // not WAV, MP3 or FLAC
    case DecodeFailure.unreadable:         // could not open or read
    case DecodeFailure.corrupt:            // failed part-way through
    case DecodeFailure.empty:              // decoded to no audio
    case DecodeFailure.internal:           // allocation failed, or bad input
  }
}
```

The failure codes mirror the C core's, so the reason a decode failed survives
the trip across the boundary rather than collapsing into one message.

## Peaks you did not decode

Two codecs produce a `WaveformPeaks` without touching an audio file at all:

```dart
// The BBC audiowaveform binary format, generated server-side on upload.
final peaks = WaveformDat.decode(bytes);
```

Being wire-compatible with the standard tool means peaks can be precomputed on
your server and shipped to a client that owns no decoder -- and it means
monowave interoperates with the peaks.js ecosystem for free. See
[voice notes](./40-voice-notes.md) for the other one, and
[the API reference](../20-reference/00-api.md) for the full surface.
