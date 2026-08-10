# Record audio

On the audio thread, capture reduces each hop of audio to a frame.
Capture then publishes the frame through a lock-free ring.
The Dart side drains this ring on a timer.
Capture can also write the raw PCM to a WAV file at the same time.

## Ask for the permission first

monowave deliberately does **not** request the microphone permission.
A headless package has no UI to explain the reason for the request, and your application has one.
Also, two requesters produce two prompts.

Declare the usage strings ([platform notes](../30-reference/10-platforms.md) has them).
Then ask for the permission with the permission plugin that your application already uses.
Open a session only after these two steps.
If the application does not already have the permission, `openCapture` throws `CaptureUnavailable`.

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
| `hop` | 512 | Samples per reduced frame. At 44.1 kHz, a hop of 512 gives approximately 86 frames each second. This rate is more than a 60 Hz display needs, and it keeps the ring small. |
| `ringCapacity` | 512 | The number of frames that the ring holds before the producer drops frames. At the default hop, this capacity gives approximately six seconds of slack. |
| `scopeCapacity` | -- | How many frames the rolling visualizer window keeps. |
| `maxDuration` | -- | How much history `stop()` can return. monowave allocates the buffer at the start, because growth of the buffer needs an allocation on the audio thread. |
| `drainInterval` | -- | How often the consumer moves frames out of the ring. |
| `recordTo` | null | Where to write the captured audio, or null to keep only the reduction. |

After `maxDuration`, capture continues and `session.truncated` reports that the peaks are partial.
This limit does not affect the recording.

## Listen to frames

```dart
session.frames.listen((frame) => setState(() {}));
```

`frames` is a broadcast stream, so a visualizer and a level meter can both listen.
Each `CaptureFrame` is one hop.
The audio thread already reduced it.

## Tell a cosmetic drop from a real one

There are two counters, because the visualizer ring and the audio ring are separate and fail in different ways:

```dart
session.dropped;      // hops the consumer was too slow to collect -- cosmetic
session.pcmDropped;   // samples the audio ring lost -- a hole in the file
```

If the bars stutter, a non-zero `dropped` is the first thing to examine.
A non-zero `pcmDropped` is a real defect in the recording.
[Architecture](../20-concepts/90-architecture.md) explains why the two rings are separate.

## Pause, resume, stop

```dart
await session.pause();    // stops the device; the take survives
await session.resume();   // continues the same recording
final peaks = await session.stop();
await session.dispose();
```

`pause` stops the device.
It does not change the rings, the hop accumulator or the history.
A take therefore continues, and does not restart.
`session.isPaused` shows the difference between a paused session and a stopped session.

`stop` returns peaks for all of the captured audio.
These peaks come from the history of the audio thread itself, and not from the frames that the visualizer collected.
The peaks are therefore complete.
The application can go to the background and miss drains, and the peaks stay complete.

**The caller owns these peaks.**
When you are done with the peaks, call `dispose()` on them.
This call is separate from `dispose()` on the session.

The output is 16-bit PCM WAV, which is also the format that the exporter reads.
You can therefore trim and export a recording with only one format.

## Dispose the session

`dispose()` closes the input device.
It also releases everything that the C core allocated for the session: both rings, the take history and the drain buffers.
When the recording is over, call `dispose()` immediately.
`dispose()` is idempotent.

`dispose()` is separate from `stop()`.
`stop` ends the take and gives you the peaks.
`dispose` releases the session.
You dispose the peaks separately.

If a `recordTo` file is still open, `dispose()` closes the file and writes the real sizes into its header.
Thus **canceling** a recording -- `dispose()` with no `stop()` -- leaves a WAV file that a player can open.
The file does not read as empty.

`dispose()` does not drain the ring first.
The data that the audio thread published after the last drain pass is lost, because `stop()` is the call that ends a take.

The four counters (`produced`, `dropped`, `pcmDropped`, `truncated`) continue to answer after you dispose the session.
They stay frozen at their final values.
A widget that reads a counter during teardown therefore does not need to guard the call.
`start`, `pause`, `resume` and `stop` throw a `StateError` instead.
A host that drives its own ticker finds that `drain()` returns 0, and does not throw.

If the garbage collector collects a session with no `dispose()` call, a finalizer **does** release it, with the same C call.
A forgotten `dispose()` therefore cannot leave the microphone open for the life of the process.
This finalizer is a backstop, and not a substitute for `dispose()`.

The finalizer runs at the time when the collector reaches the object.
That time can be long after the user believes that recording stopped.
The finalizer is not guaranteed to run before the process exits.
Only `dispose()` releases the device immediately.

## Not on web

`WasmMonowavePlatform.openCapture` throws, and does not pretend to capture audio.
On web, monowave can still decode and draw.
[Architecture](../20-concepts/90-architecture.md) explains the cost of capture on web, and the reason why capture on web is not miniaudio.

To drive these calls in a test with no microphone, read [testing](./90-test-without-hardware.md).
