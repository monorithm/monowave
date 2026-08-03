# Record audio

Capture reduces each hop of audio to a frame on the audio thread and publishes it through a lock-free ring, which the Dart side drains on a timer.
Optionally it writes the raw PCM to a WAV at the same time.

## Ask for the permission first

Monowave deliberately does **not** request the microphone permission.
A headless package has no UI to explain why it is asking, and you do -- and two requesters produce two prompts.

Declare the usage strings ([platform notes](../30-reference/10-platforms.md) has them), ask with whatever permission plugin you already use, and only then open a session.
`openCapture` throws `CaptureUnavailable` if the permission has not already been granted.

## Open a session

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

## Listen to frames

```dart
session.frames.listen((frame) => setState(() {}));
```

`frames` is a broadcast stream, so a visualizer and a level meter can both listen.
Each `CaptureFrame` is one hop, already reduced by the audio thread.

## Tell a cosmetic drop from a real one

Two counters, because the visualizer ring and the audio ring are separate and fail differently:

```dart
session.dropped;      // hops the consumer was too slow to collect -- cosmetic
session.pcmDropped;   // samples the audio ring lost -- a hole in the file
```

A non-zero `dropped` is the first thing to look at if bars stutter.
A non-zero `pcmDropped` is a real defect in the recording.
[Architecture](../20-concepts/90-architecture.md) explains why the two rings are separate.

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
**The caller owns them**: call `dispose()` on the peaks when you are done, separately from disposing the session.

The output is 16-bit PCM WAV, which is also what the exporter reads, so a recording can be trimmed and exported without a second format in play.

## Not on web

`WasmMonowavePlatform.openCapture` throws rather than pretending otherwise.
Decoding and drawing work there; see [architecture](../20-concepts/90-architecture.md) for what capture on web would cost and why it is not miniaudio.

To drive all of this in a test with no microphone, see [testing](./90-test-without-hardware.md).
