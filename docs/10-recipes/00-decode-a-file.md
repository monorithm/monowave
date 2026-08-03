# Decode an audio file into peaks

A decode turns an audio file into a `WaveformPeaks`: a pyramid of min/max pairs, plus the sample rate and length needed to place them on a timeline.

```dart
final monowave = MonowavePlatform.instance;
await monowave.ensureInitialized();

// Native: streams the file a bucket at a time.
final peaks = await monowave.decodeFile(path);

// Web, or bytes you already hold.
final peaks = await monowave.decodeBytes(bytes);
```

Prefer `decodeFile` on native.
The decoder never holds the whole file, so an audiobook is decoded without ever being resident in memory.
`decodeBytes` is the only path on web, which has no filesystem.

## Choose a base resolution

Both entry points take `baseSamplesPerPixel`, which sets the finest resolution the pyramid holds.

The default of 128 is about 3 ms at 44.1 kHz -- fine enough that no sensible zoom outruns it, coarse enough that the pyramid stays small.
Lower it only if you need to zoom past that, and know that it costs memory linearly.

## Read the data

```dart
final Int16List view = peaks.view(level);   // [min0, max0, min1, max1, ...]
final Int16List? rms = peaks.rms(level);    // one value per pair, or null
```

`view` is **zero-copy and not defensively copied**.
On native it is a view straight into memory the C core owns, which is what keeps a three-hour recording off the Dart heap.
Treat it as read-only: writing to it corrupts every level built above it.

`rms` is a second series, aligned pair-for-pair with the peaks.
It is null for pyramids built in Dart from raw samples; the C core always provides it.

You rarely pick a level yourself -- [drawing a waveform](./10-draw-a-waveform.md) shows `WaveformViewport` doing it for you.
For why the reduction is min/max rather than an average, and what the pyramid buys, see [architecture](../20-concepts/90-architecture.md).

## Overlay an RMS core inside the peak hull

Peaks say how far the audio went; RMS says how much of it there was.
Drawing both is what makes a waveform read as a shape rather than as its outliers:

```dart
final view = peaks.view(level);
final rms = peaks.rms(level);
if (rms != null) {
  // Draw the hull from view[i * 2] .. view[i * 2 + 1] first,
  // then the core from -rms[i] .. rms[i] on top.
}
```

## Dispose when the waveform leaves the screen

```dart
peaks.dispose();   // idempotent; a no-op for Dart-built pyramids
```

Peaks the C core allocated are backed by native memory, and `dispose` releases it.
Any view handed out beforehand dangles afterwards, so drop those first -- reading a disposed pyramid throws a `StateError` rather than reading freed memory.

Web behaves the same from your side, for a reason worth knowing if you profile it: growing the WASM heap detaches every outstanding view, so the web binding copies the pyramid out and frees the native allocation immediately.
Either way `dispose` is the correct thing to call.

## Handle each failure distinctly

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

The failure codes mirror the C core's, so the reason a decode failed survives the trip across the boundary rather than collapsing into one message.

**AAC and M4A report `unsupportedFormat`.**
That is a real gap -- it is what `record` produces by default on iOS.
See [platform notes](../30-reference/10-platforms.md) for what is supported, and [voice notes](./80-send-a-voice-note.md) for the path that never decodes at all.

## Load peaks you did not decode

The BBC `audiowaveform` binary format produces a `WaveformPeaks` without touching an audio file:

```dart
final peaks = WaveformDat.decode(bytes);
```

Being wire-compatible with the standard tool means peaks can be precomputed on your server and shipped to a client that owns no decoder, and that monowave interoperates with the peaks.js ecosystem for free.
