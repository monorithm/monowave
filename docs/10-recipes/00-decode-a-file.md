# Decode an audio file into peaks

A decode turns an audio file into a `WaveformPeaks`.
This object is a pyramid of min/max pairs.
The object also holds the sample rate and the length.
You need these two values to place the pairs on a timeline.

```dart
final monowave = MonowavePlatform.instance;
await monowave.ensureInitialized();

// Native: streams the file a bucket at a time.
final peaks = await monowave.decodeFile(path);

// Web, or bytes you already hold.
final peaks = await monowave.decodeBytes(bytes);
```

`decodeFile` is the better entry point on native.
The decoder never holds the whole file.
Thus `decodeFile` can decode an audiobook, and the full file never enters memory.
On web, `decodeBytes` is the only path, because web has no filesystem.

## Choose a base resolution

Both entry points take `baseSamplesPerPixel`, which sets the finest resolution that the pyramid holds.

The default value is 128.
At 44.1 kHz, this value is approximately 3 ms.
This resolution is fine enough that no sensible zoom goes past it.
This resolution is also coarse enough to keep the pyramid small.

A lower value is necessary only for a zoom that goes finer than this resolution.
A lower value costs memory linearly.

## Read the data

```dart
final Int16List view = peaks.view(level);   // [min0, max0, min1, max1, ...]
final Int16List? rms = peaks.rms(level);    // one value per pair, or null
```

`view` is **zero-copy and not defensively copied**.
On native, `view` is a direct view into the memory that the C core owns.
This behavior keeps a three-hour recording off the Dart heap.

You must not write to the view.
A write to the view corrupts every level built above it.

`rms` is a second series that is aligned pair-for-pair with the peaks.
`rms` is null for a pyramid that Dart builds from raw samples.
A pyramid from the C core always has an `rms`.

You rarely pick a level yourself.
The recipe [drawing a waveform](./10-draw-a-waveform.md) shows how `WaveformViewport` picks the level for you.
The [architecture](../20-concepts/90-architecture.md) page explains why the reduction uses min/max and not an average.
That page also explains the benefit of the pyramid.

## Overlay an RMS core inside the peak hull

Peaks show how far the audio went.
RMS shows how much audio there was.
If you draw both series, the waveform shows a shape and not only its outliers.

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

Native memory holds the peaks that the C core allocated.
`dispose` releases this memory.

Before you call `dispose`, remove your references to every view from that pyramid.
After the call, those views are no longer valid.
A read of a disposed pyramid throws a `StateError`.
The read does not touch freed memory.

On web, the behavior from your side is the same.
Each growth of the WASM heap detaches every outstanding view.
Thus the web binding copies the pyramid out, and frees the native allocation immediately.
When you profile the application, this mechanism is useful to know.
On both platforms, a call to `dispose` is correct.

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

The failure codes mirror the codes of the C core.
Thus the reason for a failed decode crosses the boundary, and does not collapse into one message.

**AAC and M4A report `unsupportedFormat`.**
This gap is real, because `record` produces this format by default on iOS.
The [platform notes](../30-reference/10-platforms.md) page lists the supported formats.
The [voice notes](./80-send-a-voice-note.md) recipe shows the path that never decodes.

## Load peaks you did not decode

The BBC `audiowaveform` binary format produces a `WaveformPeaks`.
This path does not touch an audio file.

```dart
final peaks = WaveformDat.decode(bytes);
```

This format makes monowave wire-compatible with the standard tool.
This compatibility gives two results:

- Your server can precompute the peaks and send them to a client that owns no decoder.
- monowave interoperates with the peaks.js ecosystem at no cost.
