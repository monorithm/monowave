# Roadmap

Milestones M0 to M5 are shipped. They cover capture, peaks, the viewport,
non-destructive editing, export, and the web binding. This page covers what
comes next.

Every milestone has an **exit criterion written as a test**. That is the only
form of "done" that stays true afterwards. `test/probe_test.dart` still opens
with the words "M0 exit criteria, as a test". The reason to keep this shape is
simple. Usually, a milestone that resists a plain assertion is a milestone that
no one examined with care.

## M6 to M10: playing an edit

monowave can capture, draw, edit and export a document. It cannot play one.

Today the only way to hear an edit is `exportWav`, which decodes the whole
source and writes a file. A user hears a trim after the commitment, never during
the drag of a handle. The example includes a `DemoPlayer` that advances a
`Duration` on a timer. A comment in that file admits that there is no decoder
and no audio output behind it.

[Architecture](docs/20-concepts/90-architecture.md) records why this work lives
here rather than in a sibling package. This page gives the order and the design.

### The sequencing decision

The riskiest part is not the audio device. It is the claim that a preview sounds
exactly like the export. Therefore **M6 renders with no device at all**. M6 is a
pure function from a document to a buffer. It needs no speaker, and CI can
assert it on three operating systems.

That order is the opposite of the tempting one. The tempting order is to get
sound from a speaker first and to leave exactness for later. Sound from a
speaker is a demo. The exactness is the product.

---

## M6 - Render an edit without a file: done

`wf_export_wav` already contained the render loop. It opened a source, walked
the regions, applied gain and the fade envelope per sample, and wrote the
result. M6 extracted that loop, so the exporter and a future player call the
same code.

- M6 extracted the per-region loop into `wf_render_*`. `wf_export_wav` is a file
  sink over it.
- `MonowavePlatform.renderPcm` returns a document as PCM, with no file.
- `wf_envelope` is an exported function rather than a `static` one, and it has
  tests.
- `wf_render_length_frames()` reports the output length.

Status: 22 tests in `test/render_test.dart`. The full suite is at 170 tests. The
determinism digests did not move on either binding, which was the other half of
the criterion.

There are two **exit criteria**:

- **The refactor changes nothing.** The existing export tests pass, and the
  determinism digests in `test/decode_test.dart` and `tool/verify_wasm.mjs` do
  not move. A shared loop that alters one byte of an export is a regression, not
  a refactor.
- **A render matches an export.** For a corpus of documents over WAV, MP3 and
  FLAC fixtures, render each document into a buffer. Then export the same
  document to a file. Assert that the PCM is identical, byte for byte.

The two paths differ in block size, so this stays a real test rather than a
tautology. The corpus must include the shapes that break a naive extraction:

- a zero-length region
- fades longer than the region that holds them
- a gain that lands on exactly 1.0
- a region that runs past the end of the source
- a block size that does not divide the region length

The envelope also gets the property tests that it never had:

- exactly 0 and exactly 1 at the endpoints
- linear values between the endpoints
- fades that overlap and multiply
- no negative multiplier

### The six details that make a render exact

A shared loop makes these details structural rather than a matter of discipline.
This page records them because any future second implementation, for example the
web one in M10, must reproduce all six.

1. **Truncation, not rounding.** The conversion back to int16 is
   `(int16_t)scaled`, a C cast, which truncates toward zero. An implementation
   that rounds differs by one on approximately half of all scaled samples.
2. **The clamp comes before the cast.** The clamp is at `+32767` and `-32768`,
   in float.
3. **The envelope offset is absolute within the region.** The offset is
   `written + frame`, not an offset inside the block. This is why an exporter
   with 4096-frame chunks and a player with device-sized blocks agree.
4. **Gain multiplies the envelope.** The render loop compares the product
   against exactly `1.0f` to skip the scaling loop. Every int16 is exactly
   representable in float32, so the skip is an optimization rather than a
   semantic.
5. **The render loop skips regions of zero or negative length.** This changes
   the total output length.
6. **A source that ends early is not an error.** The source reader writes what
   exists and moves to the next region.

---

## M7 - Sound: done

M7 adds the device layer. It changes nothing about correctness.

- `wf_playback` opens a miniaudio playback device. The package already vendored
  the library and already compiled it for capture.
- A lock-free SPSC ring of int16 samples mirrors the capture PCM ring.
- The feeder runs on a C thread and fills ahead of the playhead.
- The API shows an underrun counter, in the same way as
  `CaptureSession.dropped`.

**Exit criterion.** Drive a 30-second document through the ring. Then assert
that the frames that the consumer received match the frames that M6 renders
offline. Assert that the underrun count is zero.

Status: 6 tests in `test/playback_test.dart`. The full suite is at 176 tests.

**The exit criterion changed shape, and this page records the reason.** It said
"play through the miniaudio null backend, which runs headless in CI". The null
backend does run headless. It also paces itself against a simulated clock, so a
30-second document costs 30 seconds of CI wall time.

`wf_playback_pull` is public instead, and a test drives it directly.
`wf_capture_feed` already shows the same decision. The package exports the
audio-thread entry point, so a test can drive the realtime path on every
platform with no device attached. It is also the same code that a real speaker
drives. The consumer in the test waits for a full block before it takes one,
exactly as a well-provisioned device does. This behavior keeps the underrun
assertion meaningful rather than tautological.

The device path itself gets a smoke test. The device either opens or returns
`WF_ERR_DEVICE`. It must not block.

### The one piece of per-platform code in the package

miniaudio has a thread abstraction and keeps it private. `ma_thread_create` is
`static`, and only the mutex, event and semaphore primitives carry `MA_API`.
Rather than vendor a second threading library for three functions,
`wf_playback.c` carries a thread, a join and a sleep behind `#if defined(_WIN32)`.

That is a real departure for a package with no per-platform code anywhere else.
Therefore this page records it rather than leaves it for a reader to discover.
The alternative was a feeder that Dart drives. The architecture page rejects
that alternative, because one garbage collection becomes an audible dropout.

The feeder polls and does not wait on an event. It wakes every 2 ms, fills the
ring, and sleeps again. The ring is measured in seconds, so the feeder only has
to match the device rate on average. A condition variable gives nothing and
costs another two platform paths.

### Transport and threading

Playback is the capture pipeline pointed the other way, and the symmetry is
worth the reuse. In capture, the audio thread produces reduced frames into a
lock-free ring, and Dart drains the ring on a timer. In playback, a feeder fills
a lock-free ring with rendered frames, and the audio thread consumes them. In
both, the audio callback must not allocate, take a lock, or call into Dart.

**The feeder is a C thread, not a Dart timer.** This is the one place where
playback departs from the capture shape. Capture tolerates a late drain, because
the ring holds approximately six seconds and a stalled consumer loses nothing.
Playback tolerates nothing of the kind. An empty ring means that the device
emits silence, and one garbage collection or one late UI frame becomes an
audible dropout. Dart must not enter the audio path.

---

## M8 - Transport: done

`MonowavePlatform.openPlayback` opens a `PlaybackSession`. This mirrors
`CaptureSession` and `openCapture`.

- `PlaybackSession` has `play`, `pause`, `seek`, `position`, `duration`,
  `isPlaying`, `isFinished` and `underruns`.
- Position comes from the consumed-frame counter of the device.
- `lib/testing.dart` has `FakePlaybackSession`.

Status: 18 tests in `test/transport_test.dart`. The full suite is at 194 tests.

**The seek mechanism is a handshake, not a per-frame generation tag.** This page
sketched a generation counter that the audio callback compares against each
frame it is about to emit. A literal implementation of that sketch stores a
generation beside every slot in the ring. That is a lot of memory and
bookkeeping for a rare event.

Instead, the party that can afford to wait is the party that waits.
`wf_playback_seek` raises a `seeking` flag. Then it blocks its own caller until
the consumer leaves the audio callback and the feeder parks. At that point no
thread touches the ring, and the seek can reset it outright. The audio callback
emits silence while the flag is up, and the audible result is the same.

If the other two sides do not stop within five seconds, the seek fails. It does
not reset a ring that a thread is still inside.

`PlaybackSession` does **not** implement `MonoPlaybackController`. That
interface lives in monokit, and a headless package must not depend on the design
system. The adapter is the few lines that a host writes.

There are three **exit criteria**:

- **A seek lands where it says.** Seek to a time. Then read one frame. Assert
  that the frame matches the frame that M6 renders at that offset. WAV is
  sample-exact. MP3 is within one frame, and the test asserts that bound rather
  than hides it.
- **The clock does not drift.** Across 30 seconds of null-backend playback,
  `position` tracks consumed frames within one device buffer and never moves
  backward.
- **The fake matches.** `FakePlaybackSession` in `lib/testing.dart` passes the
  same conformance suite as the real one.

### The position clock

The temptation is to advance `position` on a Dart timer. `DemoPlayer` does
exactly that, which is correct for a fake and wrong here. A timer drifts against
the audio clock immediately, and then the playhead is not where the sound is.

Position comes from the frames that the device consumed. An atomic counter in C
holds that number, minus the buffering latency that the device reports. Dart
polls the counter on a ticker and republishes it. The device is the clock.

### Seeking without a glitch

A seek must move the decoder and erase all frames that are already rendered
ahead of the playhead. The audio callback must never read a half-written ring.

The mechanism is a generation counter. Dart raises it. The feeder sees the
change, seeks again, and refills from the new position. The audio callback
compares the generation on the frames that it is about to emit, and emits
silence for any stale frame. A few milliseconds of silence is the correct
failure mode for a seek.

Seek accuracy depends on the decoder. WAV is sample-exact. MP3 seeks to a frame
boundary of approximately 1152 samples, which is 26 ms at 44.1 kHz. A seek into
an MP3 region lands on that boundary and then decodes forward to the exact
frame.

### Who owns the region walk

The C core owns the region walk, and Dart asks the C core questions. The
alternative is one walk in Dart to map a seek and a second walk in C to render.
Two implementations of one traversal disagree eventually, over an edge case such
as a zero-length region. That disagreement appears as a playhead that is correct
until a document takes an unusual shape.

`WaveformTimeline` keeps its job, which is the conversion between time and
samples. That is pure mathematics over a sample rate and needs no walk.

---

## M9 - Live document updates: done

M9 is the feature that justifies the work. A user drags a trim handle and hears
the result, and playback never stops.

- `PlaybackSession.setDocument` swaps the region list while the session plays.
- The playhead keeps its output position and clamps to the new end.

Status: 7 more tests in `test/transport_test.dart`. The full suite is at 201
tests.

**Exit criterion.** Change a document mid-playback. Assert that the output after
the change matches a fresh render of the new document from that offset. Assert
that the underrun count is still zero.

### The open question, answered: one call, not two

This page asked a question. Must a feeder swap (gain, fades) and a timeline
change (a trim, a delete, a split) be separate calls? The theory was that the
first is cheaper.

A feeder swap is not cheaper. Both kinds erase all the frames in the ring,
because a render through the old document produced those frames. The ring holds
approximately one second. A change of gain alone is exactly as expensive as a
trim. Therefore a second entry point gives a host nothing but one more decision
to get wrong.

The two kinds do differ in the meaning of the playhead after the change. The API
cannot decide that meaning. After a gain change, output frame N still points at
the same audio. A trim that moves a region start does not keep that property.
Therefore `setDocument` keeps the playhead where it is, which is what a user
who drags a handle expects. A host that wants another behavior calls `seek`
immediately after.

Mechanically, the swap is a seek with a new region list, so it reuses the M8
handshake unchanged. That is also why `wf_playback_seek` and
`wf_playback_set_regions` now share `wf_playback_acquire` and
`wf_playback_release`.

---

## M10 - Web renders through the same C loop: done

A WebAudio graph was the plan. It is not what web needed.

- `wf_render_open_memory` renders from bytes rather than from a path.
- `MonowavePlatform.renderPcmBytes` is the render path on every target, and the
  only render path on web.
- The WASM build exports the renderer, so web runs the same loop as the
  exporter.

Status: 6 more tests in `test/render_test.dart`, three in the browser parity
test, and a render check in `tool/verify_wasm.mjs`. The full suite is at 207
tests.

**Exit criterion.** Assert a byte-for-byte match between the web render and the
native one. The plan was to assert MP3 for shape rather than for equality.

### The premise was wrong, and the guarantee is better for it

This page said that web must decode through the browser and apply the envelope
in an AudioWorklet. It also said that MP3 can only be approximate on web,
because the decoder in Chrome is not `dr_mp3`. That hole went into the
architecture page as a cost to accept.

The premise was not real. `DR_WAV_NO_STDIO` and its siblings remove only the
*file* entry points. The WASM build already carried all three decoders with
their memory APIs, because `wf_decode_memory` always used them. No code needed
to decode through the browser, and no second implementation of the render was
necessary.

So the split moved. Only `wf_source_open` and `wf_export_wav` sit behind the
stdio guard now. All targets share the source layer, the region walk, the
envelope and the render loop. Web reaches them through `wf_render_open_memory`.

**A rendered document is byte-identical on all six targets, for every format.**
The equality claim has no exception, and this page withdraws the concession
rather than lives with it. `tool/verify_wasm.mjs` renders through the WASM
module and compares every sample against a native render. A change of the int16
conversion from truncation to rounding makes the check fail at sample 1.

### Web plays, through a WebAudio graph

`openPlaybackBytes` returns a `PlaybackSession` on web as well as natively.

The graph is deliberately plain. The whole render goes into an `AudioBuffer`
before playback starts, and an `AudioBufferSourceNode` plays it. There is no
ring and no feeder, because the browser owns the audio thread and there is
nothing for a feeder to race. That is the right shape for a preview of an edit
and the wrong shape for an audiobook. A long document costs its whole length in
memory, at four bytes per frame per channel. This page states the limit rather
than lets a reader discover it.

`underruns` is always zero there, and that is a fact rather than a stub. A
feeder that loses a race with a device causes an underrun. The render is
resident before playback starts, so that race does not exist. The cost moves to
memory instead.

The playhead still comes from the audio clock. `AudioContext.currentTime`
advances with the hardware. The native session obeys the same rule and counts
the frames that the device consumed.

**One thing a host must know:** browsers refuse to start an `AudioContext`
without a user gesture. They report this refusal as a context stuck in
`suspended` rather than as an error. `play()` detects that state and throws
`PlaybackUnavailable`. The message says to call `play()` from a tap.

A driven test has no gesture. Therefore the browser test asserts `play` in the
same way as the native test asserts a missing device. The call either works or
reports the reason. It must not hang.

`openPlayback` with a path still throws on web, because web has no filesystem.

### What did not port, and why that is right

The M7 to M9 transport - the ring, the feeder thread, the seek handshake - is
native-only by design. A browser has its own scheduler and its own audio thread.
A second implementation of a feeder against them invents a problem. Only the
necessary part crosses: the samples, from the same C loop.

## What playback will not do

| | Why |
|---|---|
| Video | Wrong architecture. Preview belongs in monolens. The native side of monolens already carries the Core Image and Media3 effect chains. |
| Replace `just_audio` or `media_kit` | They play files well. The gap is a preview of an edit before it renders. |
| Implement `MonoPlaybackController` | That interface lives in monokit. monowave must not depend on the design system. The adapter is the few lines that a host writes, and `DemoPlayer` is already that shape. |
| Effects beyond gain and fades | The document defines the edit. A document that cannot express an effect cannot preview it either. |
| AAC / M4A | Playback inherits the decoder set, so it plays what the pyramid can draw and nothing else. |

## Open questions

- **Whether a document swap can avoid a seek.** A change of gain is inaudible
  mid-playback. A change to a trim point moves everything after it. One API call
  for both is probably the wrong shape.
- **Whether the underrun counter can fail a test.** The counter is the right
  signal, but its value depends on the scheduling of the CI machine. A threshold
  makes the test fail at random, and a strict zero can do the same.
- **What happens when the source file changes underneath a session.** A document
  references a path, not a handle.
