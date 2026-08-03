# Capture

The audio thread reduces each hop of audio to a frame and publishes it through a lock-free ring; the Dart side drains that ring on a timer.
No PCM crosses into Dart on the visualizer path, and nothing in the audio path allocates.

## Permission first

Monowave deliberately does **not** request the microphone permission.
A headless package has no UI to explain why it is asking, and you do -- and two requesters produce two prompts.

Declare the usage strings ([platform notes](../20-reference/10-platforms.md) has them), ask with whatever permission plugin you already use, and only then open a session.
`openCapture` throws `CaptureUnavailable` if the permission has not already been granted.

## Opening a session

```dart
final session = await monowave.openCapture(
  const CaptureConfig(
    sampleRate: 44100,
    channels: 1,
    hop: 512,                        // samples per reduced frame
    maxDuration: Duration(minutes: 5),
    recordTo: '/path/to/take.wav',   // omit to keep only the reduction
  ),
);

await session.start();
```

Every field is a realtime trade-off:

| Field | Default | What it decides |
|---|---|---|
| `hop` | 512 | Samples per reduced frame. 512 at 44.1 kHz is about 86 frames a second -- comfortably above a 60 Hz display, small enough that the ring stays tiny. |
| `ringCapacity` | 512 | Frames buffered before the producer starts dropping. About six seconds of slack at the default hop. |
| `scopeCapacity` | -- | How many frames the rolling visualizer window retains. |
| `maxDuration` | -- | How much history `stop()` can return. The buffer is allocated up front, because growing it would mean allocating on the audio thread. |
| `drainInterval` | -- | How often the consumer moves frames out of the ring. |
| `recordTo` | null | Where to write the captured audio, or null to keep only the reduction. |

Past `maxDuration` capture keeps running and `session.truncated` reports that the peaks are partial.
The recording itself is unaffected.

## Two rings, not one

`recordTo` streams raw PCM to a 16-bit WAV through a **second** ring, separate from the reduced frames.
That is not incidental:

- They run at completely different rates -- 44,100 samples a second against 86 frames a second.
- They have completely different consequences when they overflow.
  A dropped visualizer frame is cosmetic; a dropped audio sample is a hole in the recording.

Sharing one ring would let a slow file write starve the visualizer, or a paused visualizer stall the writer.
Which is why the two counters are reported apart:

```dart
session.dropped;      // hops the consumer was too slow to collect -- cosmetic
session.pcmDropped;   // samples the audio ring lost -- a hole in the file
```

A non-zero `dropped` is the first thing to look at if bars stutter.
A non-zero `pcmDropped` is a real defect in the recording.

Neither ring ever blocks the producer.
The audio thread copies into both and moves on; the session drains them on its timer and writes the WAV, because file I/O on an audio callback is precisely the unbounded operation that produces an audible glitch.

The output is 16-bit PCM WAV, which is also what the exporter reads -- so a recording can be trimmed and exported without a second format in play.

## The live meter

Draw from `session.scope`, a fixed-capacity rolling window over a preallocated buffer.
It allocates nothing per frame: at 86 frames a second, a growable list would be 86 allocations a second forever, and the garbage would land in the same frame budget as the painting.

```dart
final scope = session.scope;

for (var i = 0; i < scope.length; i++) {
  final height = scope.amplitudeAt(i) * trackHeight;   // 0..1
}
```

Index 0 is the oldest frame still retained.
`amplitudeAt` gives the larger excursion of the frame, which is the usual input to a bar visualizer -- it does not care which direction the waveform went, only how far.
`minAt`, `maxAt` and `rmsAt` are there if you want the asymmetry.

:::caution[Repaint on `revision`, not `length`] The scope is a ring that mutates in place.
Once it is full, `length` never changes again -- so a `shouldRepaint` keyed on it silently stops repainting and the meter freezes while audio keeps arriving.
`scope.revision` increments on every frame added, which is what you compare. :::

## Frames

```dart
session.frames.listen((frame) => setState(() {}));
```

`frames` is a broadcast stream, so a visualizer and a level meter can both listen.
Each `CaptureFrame` is one hop, already reduced by the audio thread.

## Pause, resume, stop

```dart
await session.pause();    // stops the device; the take survives
await session.resume();   // continues the same recording
final peaks = await session.stop();
await session.dispose();
```

`pause` stops the device without touching the rings, the hop accumulator or the history, so a take continues rather than restarting.
`session.isPaused` distinguishes it from stopped.

`stop` returns peaks for everything captured, built from the audio thread's own history rather than from what the visualizer happened to collect -- so they are complete even if the app was backgrounded and missed drains.
**The caller owns them**; call `dispose()` on the peaks when you are done, separately from disposing the session.

## Web

Capture does not work on web.
`WasmMonowavePlatform.openCapture` throws rather than pretending otherwise.

Decoding and drawing work there, and the plan for capture is a small AudioWorklet written against the browser's own APIs rather than routing miniaudio's web backend through the WASM artifact.
[Architecture](../20-reference/20-architecture.md) has the reasoning and what it costs.

## Testing it

`FakeCaptureSession` drives the same state a real session does -- recording flag, frame stream, scope -- with no microphone.
See [testing](./50-testing.md).
