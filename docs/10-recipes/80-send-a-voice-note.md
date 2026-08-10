# Send a voice note without a decoder

The common case for a waveform in a messaging application is a fixed-width bar summary next to a message bubble.
The sender computes the bars at record time.
The sender then uploads approximately 64 bytes of metadata beside the audio.
The receiver draws directly from those bytes.

This method needs no decoder, no native code and no delay.
It also needs no round trip to fetch the audio only to see what the audio looks like.
WhatsApp, Telegram and Signal use this method.
monowave has no AAC decoder, and this method is the reason why that gap is tolerable.

## Send

```dart
// After a capture, or from any peaks you already have.
final bars = CompactBars.encode(peaks);
final encoded = CompactBars.toBase64(bars);

await api.sendVoiceNote(audioPath, waveform: encoded);
```

Bars are `uint8`, so one bar is one byte.
The base64 form of a 64-bar summary is 88 characters.
This form is small enough to put in a JSON document beside the message.

```dart
static Uint8List encode(
  WaveformPeaks peaks, {
  int bars = 64,
  BarScale scale = BarScale.dbfs,
  double floorDb = -45.0,
  bool normalize = true,
  int level = 0,
});
```

If you drive a live meter and you did not build a pyramid, `fromAmplitudes` takes the amplitudes directly:

```dart
final bars = CompactBars.fromAmplitudes(scope.amplitudes());
```

## Receive

```dart
final bars = CompactBars.fromBase64(encoded);
final heights = CompactBars.heights(bars);   // Float32List, each 0..1
```

You can multiply `heights` by a track height immediately.
`heights` also feeds a design-system component directly, for example `MonoWaveform` in monokit.
As a result, a fixed-bar voice note needs no painter at all.

## Pick a scale and a floor

```dart
enum BarScale { linear, dbfs }
```

`dbfs` is the default, and this choice is more important than it sounds.
Normal speech peaks far below full scale.
As a result, a **linear** waveform of a voice note looks almost flat.
The flat picture is technically honest, and it is almost always the wrong picture.
Decibels relative to full scale, with a floor at `floorDb`, match how a user hears loudness.
These decibels make a voice note legible.

The default floor of -45 dB suits speech.
Music needs a lower floor.
A noisy room needs a higher floor.

## Compare notes without normalization

`normalize` makes the loudest bar full height.
As a result, a quiet recording still reads clearly.
If you show several waveforms together, and their relative loudness carries a meaning, set `normalize` to `false`.
If you do not, every note looks equally loud.

## When a bar array is not enough

A fixed bar array holds one number for each bar.
This array is sufficient for a voice note, but not for a view that zooms.
A zoom needs a pyramid, and min/max asymmetry needs two numbers for each bar.

If you need a pyramid or two numbers for each bar, read [drawing a waveform](./10-draw-a-waveform.md).

## Precompute peaks on a server instead

The other way to avoid a decoder on the client is to compute the peaks on the server at upload time.
The server then sends the peaks to the client.
`WaveformDat` reads and writes the BBC `audiowaveform` binary format:

```dart
final peaks = WaveformDat.decode(bytes);
final dat = WaveformDat.encode(peaks, level: 0, bits: 8);
```

This format is wire-compatible with the standard tool.
As a result, monowave interoperates with the peaks.js ecosystem at no cost.
A client that owns no decoder at all can still show a real waveform that zooms.
`bits: 8` reduces the size by half, at the cost of the low byte.
In the waveform on screen, this loss is imperceptible.
