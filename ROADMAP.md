# Roadmap

Milestones M0 to M5 are shipped. They cover capture, peaks, the viewport,
non-destructive editing, export, and the web binding. This page covers what
comes next.

Every milestone has an **exit criterion written as a test**. That is the only
form of "done" that stays true afterwards. `test/probe_test.dart` still opens
with the words "M0 exit criteria, as a test", and the reason to keep the shape
is simple. A milestone that resists a plain assertion is usually a milestone
that nobody thought through.

## M6 to M10: playing an edit

Monowave can capture, draw, edit and export a document. It cannot play one.

The only way to hear an edit today is `exportWav`, which decodes the whole
source and writes a file. A user hears a trim after the commitment, never during
the drag of a handle. The example ships a `DemoPlayer` that advances a
`Duration` on a timer, and a comment in that file admits there is no decoder and
no audio output behind it.

[Architecture](docs/20-concepts/90-architecture.md) records why this work lives
here rather than in a sibling package. This page is the order and the design.

### The sequencing decision

The riskiest part is not the audio device. It is the claim that a preview sounds
exactly like the export. So **M6 renders with no device at all**. It is a pure
function from a document to a buffer, it needs no speaker, and CI can assert it
on three operating systems.

That is the opposite of the tempting order, which is to get sound out of a
speaker first and worry about exactness later. Sound out of a speaker is a demo.
The exactness is the product.

---

## M6 - Render an edit without a file: done

`wf_export_wav` already contained the render loop. It opened a source, walked
the regions, applied gain and the fade envelope per sample, and wrote the
result. M6 extracted that loop so the exporter and a future player call the same
code.

- Extracted the per-region loop into `wf_render_*`. `wf_export_wav` is a file
  sink over it.
- `MonowavePlatform.renderPcm` returns a document as PCM, with no file.
- `wf_envelope` is exported rather than `static`, and tested.
- `wf_render_length_frames()` reports the output length.

Status: 22 tests in `test/render_test.dart`, and the full suite is at 170. The
determinism digests did not move on either binding, which was the other half of
the criterion.

**Exit criteria**, two of them:

- **The refactor changes nothing.** The existing export tests pass, and the
  determinism digests in `test/decode_test.dart` and `tool/verify_wasm.mjs` do
  not move. A shared loop that alters one byte of an export is a regression, not
  a refactor.
- **A render matches an export.** For a corpus of documents over WAV, MP3 and
  FLAC fixtures, render into a buffer and export the same document to a file.
  Assert the PCM is identical. Byte for byte.

The two paths differ in block size, so this stays a real test rather than a
tautology. The corpus must include the shapes that break a naive extraction:

- a zero-length region
- fades longer than the region that holds them
- a gain that lands on exactly 1.0
- a region that runs past the end of the source
- a block size that does not divide the region length

The envelope also gets the property tests it never had: exactly 0 and exactly 1
at the endpoints, linear in between, overlapping fades that multiply, and never
a negative multiplier.

### The six details that make a render exact

A shared loop makes these structural rather than a matter of discipline. They
are recorded because any future second implementation, such as the web one in
M10, must reproduce all six.

1. **Truncation, not rounding.** The conversion back to int16 is
   `(int16_t)scaled`, a C cast, which truncates toward zero. An implementation
   that rounds is off by one on about half of all scaled samples.
2. **Clamp before the cast**, at `+32767` and `-32768`, in float.
3. **The envelope offset is absolute within the region.** It is
   `written + frame`, not an offset inside the block. This is what lets an
   exporter using 4096-frame chunks and a player using device-sized blocks agree.
4. **Gain multiplies the envelope**, and the product is compared against exactly
   `1.0f` to skip the scaling loop. Every int16 is exactly representable in
   float32, so the skip is an optimization rather than a semantic.
5. **Regions of zero or negative length are skipped**, which changes the total
   output length.
6. **A source that ends early is not an error.** The reader writes what exists
   and moves to the next region.

---

## M7 - Sound: done

The device layer, and nothing about correctness.

- `wf_playback` opens a miniaudio playback device. The library was already
  vendored and already compiled for capture.
- A lock-free SPSC ring of int16 samples, mirroring the capture PCM ring.
- The feeder runs on a C thread, filling ahead of the playhead.
- An underrun counter, surfaced the way `CaptureSession.dropped` is.

**Exit criterion.** Drive a 30-second document through the ring and assert the
frames the consumer received match the frames M6 renders offline. Assert the
underrun count is zero.

Status: 6 tests in `test/playback_test.dart`, and the full suite is at 176.

**The exit criterion changed shape, and the reason is worth recording.** It said
"play through the miniaudio null backend, which runs headless in CI". The null
backend does run headless, but it also paces itself against a simulated clock,
so a 30-second document costs 30 seconds of CI wall time.

`wf_playback_pull` is public instead, and a test drives it directly. That is the
same decision `wf_capture_feed` already embodies: the audio-thread entry point
is exported so the realtime path is testable on every platform with no device
attached, and it is the same code a real speaker drives. The consumer in the
test waits for a full block before taking one, exactly as a well-provisioned
device does, which is what keeps the underrun assertion meaningful rather than
tautological. The device path itself gets a smoke test: it either opens or
returns `WF_ERR_DEVICE`, and what it must not do is block.

### The one piece of per-platform code in the package

miniaudio has a thread abstraction and keeps it private: `ma_thread_create` is
`static`, while only the mutex, event and semaphore primitives carry `MA_API`.
Rather than vendor a second threading library for three functions,
`wf_playback.c` carries a thread, a join and a sleep behind `#if defined(_WIN32)`.

That is a real departure for a package with no per-platform code anywhere else,
so it is written down rather than left to be discovered. The alternative was a
feeder driven from Dart, which the architecture doc rules out: one garbage
collection becomes an audible dropout.

The feeder polls rather than waiting on an event. It wakes every 2 ms, tops up
the ring, and sleeps again. With a ring measured in seconds it only has to keep
up on average, so a condition variable would buy nothing and cost another two
platform paths.

### Transport and threading

Playback is the capture pipeline pointed the other way, and the symmetry is
worth the reuse. In capture, the audio thread produces reduced frames into a
lock-free ring and Dart drains it on a timer. In playback, a feeder fills a
lock-free ring with rendered frames and the audio thread consumes them. In both,
the audio callback must not allocate, take a lock, or call into Dart.

**The feeder is a C thread, not a Dart timer.** This is the one place where
playback departs from the capture shape. Capture tolerates a late drain, because
the ring holds about six seconds and a stalled consumer loses nothing. Playback
tolerates nothing of the kind. An empty ring means the device emits silence, and
one garbage collection or one janky frame becomes an audible dropout. Dart stays
out of the audio path.

---

## M8 - Transport: done

`PlaybackSession`, opened by `MonowavePlatform.openPlayback`, mirroring
`CaptureSession` and `openCapture`.

- `play`, `pause`, `seek`, `position`, `duration`, `isPlaying`, `isFinished`
  and `underruns`.
- Position comes from the consumed-frame counter of the device.
- `FakePlaybackSession` in `lib/testing.dart`.

Status: 18 tests in `test/transport_test.dart`, and the full suite is at 194.

**The seek mechanism is a handshake, not a per-frame generation tag.** This page
sketched a generation counter that the audio callback compares against each
frame it is about to emit. Doing that literally means storing a generation
beside every slot in the ring, which is a lot of memory and bookkeeping for a
rare event.

Instead the party that can afford to wait does the waiting. `wf_playback_seek`
raises a `seeking` flag, then blocks its own caller until the consumer has left
the audio callback and the feeder has parked. At that point nobody is touching
the ring and it can be reset outright. The audio callback emits silence while
the flag is up, which is the same audible result. If the other two sides do not
stand down within five seconds the seek fails rather than resetting a ring
somebody is still inside.

`PlaybackSession` does **not** implement `MonoPlaybackController`. That
interface lives in monokit, and a headless package must not depend on the design
system. The adapter is the few lines a host writes.

**Exit criteria**, three of them:

- **A seek lands where it says.** Seek to a time, read one frame, and assert it
  matches the frame M6 renders at that offset. WAV is sample-exact. MP3 is
  within one frame, asserted as a bound rather than hidden.
- **The clock does not drift.** Across 30 seconds of null-backend playback,
  `position` tracks consumed frames within one device buffer and never moves
  backwards.
- **The fake matches.** `FakePlaybackSession` in `lib/testing.dart` passes the
  same conformance suite as the real one.

### The position clock

The temptation is to advance `position` on a Dart timer. `DemoPlayer` does
exactly that, which is correct for a fake and wrong here. A timer drifts against
the audio clock immediately, and the playhead then sits where the sound is not.

Position comes from the frames the device actually consumed. An atomic counter
in C holds that number, minus the buffering latency the device reports. Dart
polls the counter on a ticker and republishes it. The device is the clock.

### Seeking without a glitch

A seek must move the decoder and discard everything rendered ahead of the
playhead, without the audio callback ever reading a half-written ring.

The mechanism is a generation counter. Dart raises it. The feeder sees the
change, seeks again, and refills from the new position. The audio callback
compares the generation on the frames it is about to emit, and emits silence for
any stale frame. A few milliseconds of silence is the correct failure mode for a
seek.

Seek accuracy depends on the decoder. WAV is sample-exact. MP3 seeks to a frame
boundary of about 1152 samples, which is 26 ms at 44.1 kHz. A seek into an MP3
region lands on that boundary and then decodes forward to the exact frame.

### Who owns the region walk

The C core owns it, and Dart asks it questions. The alternative is one walk in
Dart to map a seek and a second walk in C to render. Two implementations of one
traversal disagree eventually, over an edge case such as a zero-length region.
That disagreement shows up as a playhead that is correct until a document takes
an unusual shape.

`WaveformTimeline` keeps its job, which is the conversion between time and
samples. That is pure maths over a sample rate and needs no walk.

---

## M9 - Live document updates

The feature that justifies the work: drag a trim handle, hear the result, and
never stop playback.

- Support a document swap during playback.
- Separate two kinds of change. A feeder swap changes gain or fades. A timeline
  change is a trim, a delete or a split, and it is a seek in disguise.

**Exit criterion.** Change a document mid-playback. Assert that the output after
the change matches a fresh render of the new document from that offset. Assert
that the underrun count is still zero.

Whether the two kinds of change share one API call is an open question, and it
belongs to this milestone rather than before it.

---

## M10 - Web playback

A WebAudio graph, not a second WASM entry point.

Decoding to peaks is a pure function, so web runs the same C. Playback is a
device concern, and the browser already provides the graph. This is the same
call M5 already made for web capture, for the same reason: the miniaudio web
backend needs the emscripten JavaScript runtime, and `assets/monowave.wasm` is
`-sSTANDALONE_WASM --no-entry` with no JS glue at all.

- Decode through the browser and apply the envelope in an AudioWorklet.
- Reimplement the region walk once, in Dart or in JavaScript, against the six
  details above.

**Exit criterion.** The browser test decodes a WAV document through the web
binding and asserts a byte-for-byte match against the native render. **MP3 is
asserted for shape rather than for equality.**

That asymmetry is a real hole. The browser MP3 decoder is not `dr_mp3`, and the
last bit of a floating-point decode legitimately differs between
implementations. For WAV there is no decoder to disagree about, so the guarantee
survives there. It is written down so that it stays a known limit rather than a
later discovery.

The browser test is a gate rather than an informational step, so this milestone
inherits a check that can fail the build.

---

## What playback will not do

| | Why |
|---|---|
| Video | Wrong architecture. Preview belongs in monolens, whose native side already carries the Core Image and Media3 effect chains. |
| Replace `just_audio` or `media_kit` | They play files well. The gap is a preview of an edit before it renders. |
| Implement `MonoPlaybackController` | That interface lives in monokit. Monowave must not depend on the design system. The adapter is the few lines a host writes, and `DemoPlayer` is already that shape. |
| Effects beyond gain and fades | The document defines the edit. A document that cannot express an effect cannot preview it either. |
| AAC / M4A | Playback inherits the decoder set, so it plays what the pyramid can draw and nothing else. |

## Open questions

- **Whether a document swap can avoid a seek.** A change of gain is inaudible
  mid-playback. A change to a trim point moves everything after it. One API call
  for both is probably the wrong shape.
- **Whether the underrun counter can fail a test.** It is the right signal, but
  its value depends on the scheduling of the CI machine. A threshold is flaky,
  and a strict zero can be flaky too.
- **What happens when the source file changes underneath a session.** A document
  references a path, not a handle.
