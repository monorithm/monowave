# Send a voice note without a decoder

The common case for a waveform in a messaging app is a fixed-width bar summary next to a message bubble.
The sender computes the bars at record time and uploads roughly 64 bytes of metadata beside the audio; the receiver draws straight from those bytes.

No decoder, no native code, no waiting, and no round trip to fetch the audio just to know what it looks like.
It is what WhatsApp, Telegram and Signal do, and it is the reason monowave's missing AAC decoder is survivable.

## Send

```dart
// After a capture, or from any peaks you already have.
final bars = CompactBars.encode(peaks);
final encoded = CompactBars.toBase64(bars);

await api.sendVoiceNote(audioPath, waveform: encoded);
```

Bars are `uint8`, so one bar is one byte.
A 64-bar summary base64s to 88 characters -- small enough to sit in a JSON document beside the message.

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

If you are driving a live meter and never built a pyramid, `fromAmplitudes` takes the amplitudes directly:

```dart
final bars = CompactBars.fromAmplitudes(scope.amplitudes());
```

## Receive

```dart
final bars = CompactBars.fromBase64(encoded);
final heights = CompactBars.heights(bars);   // Float32List, each 0..1
```

`heights` is ready to multiply by a track height.
It feeds a design-system component -- monokit's `MonoWaveform`, for instance -- directly, so a fixed-bar voice note needs no painter from anyone.

## Pick a scale and a floor

```dart
enum BarScale { linear, dbfs }
```

`dbfs` is the default, and it matters more than it sounds.
Normal speech peaks well below full scale, so a **linear** waveform of a voice note looks nearly flat -- technically honest and almost always the wrong picture.
Decibels relative to full scale, floored at `floorDb`, match how loudness is perceived and are what make a voice note legible.

The default floor of -45 dB suits speech.
Music wants a lower floor; a noisy room wants a higher one.

## Turn off normalization when comparing notes

`normalize` makes the loudest bar full height, so a quietly recorded note still reads clearly.
Turn it off when several waveforms are shown together and their relative loudness carries meaning -- otherwise every note looks equally loud.

## When a bar array is not enough

A fixed bar array is one number per bar.
That is enough for a voice note and not enough for anything that zooms, because zooming needs a pyramid and min/max asymmetry needs two numbers per bar.

When you need those you are in [drawing a waveform](./10-draw-a-waveform.md) territory.

## Precompute peaks on a server instead

The other way to avoid a decoder on the client is to compute peaks server-side on upload and ship them.
`WaveformDat` reads and writes the BBC `audiowaveform` binary format:

```dart
final peaks = WaveformDat.decode(bytes);
final dat = WaveformDat.encode(peaks, level: 0, bits: 8);
```

Being wire-compatible with the standard tool means monowave interoperates with the peaks.js ecosystem for free, and that a client which owns no decoder at all can still show a real, zoomable waveform.
`bits: 8` halves the size at the cost of the low byte, which is imperceptible once rendered.
