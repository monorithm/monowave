// The realtime path, driven with synthetic PCM through the same entry point a
// microphone drives.
//
// No device, no permission prompt, and deterministic - which is what lets the
// hardest part of monowave be tested on every platform in CI rather than only
// by hand on a phone.

import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:monowave/monowave.dart';
import 'package:monowave/src/capture/ffi_capture_session.dart';
import 'package:monowave/src/native/monowave_bindings.dart' as bindings;
import 'package:test/test.dart';

const _hop = 512;

Int16List _tone(int frames, {int amplitude = 20000, int channels = 1}) {
  final samples = Int16List(frames * channels);
  for (var frame = 0; frame < frames; frame++) {
    final value = (math.sin(2 * math.pi * frame / 64) * amplitude).round();
    for (var channel = 0; channel < channels; channel++) {
      samples[frame * channels + channel] = value;
    }
  }
  return samples;
}

/// A short take, so a batch of these is kilobytes rather than megabytes.
const _dropped = CaptureConfig(hop: _hop, maxDuration: Duration(seconds: 1));

/// Opens [count] sessions in a helper isolate, disposes none of them, and
/// reports how many the C core had live before the isolate went away.
///
/// The helper isolate is what makes this deterministic. Dropping the sessions on
/// the test's own stack does not: the VM scans the machine stack
/// conservatively, so a dead slot pointing at the last session opened keeps it
/// alive across collections, indefinitely and unpredictably. That is a test
/// artifact rather than a leak, but it makes the assertion unwritable. An
/// isolate that has exited has no stack to hold anything.
Future<int> _openAndDrop(int count) => Isolate.run(() async {
  for (var i = 0; i < count; i++) {
    await FfiCaptureSession.open(_dropped);
  }
  // Read from inside, while the sessions are unambiguously still live. Read
  // from the test after the isolate is gone and there is nothing left to see.
  return bindings.wfCaptureLive();
});

/// The same, disposing each session properly first.
Future<int> _openDisposeAndDrop(int count) => Isolate.run(() async {
  for (var i = 0; i < count; i++) {
    await (await FfiCaptureSession.open(_dropped)).dispose();
  }
  return bindings.wfCaptureLive();
});

/// Waits for [until] to hold, allocating to hurry a collection along.
///
/// Reclaiming a dropped isolate's objects normally needs nothing more than the
/// isolate exiting, so this usually returns on the first check. The pressure is
/// for the case where it does not: there is no way to ask the VM to collect, so
/// churning new space and holding each round's allocation across the next one -
/// which grows old space too - is the only lever, and yielding in between is
/// what lets the finalizer callbacks run. Returns whether [until] ever held.
Future<bool> _pressGc(bool Function() until) async {
  var ballast = <List<int>>[];

  for (var round = 0; round < 100; round++) {
    if (until()) return true;

    final held = <List<int>>[];
    for (var block = 0; block < 64; block++) {
      held.add(List<int>.filled(1 << 12, round + ballast.length));
    }
    ballast = held;

    await Future<void>.delayed(Duration.zero);
  }

  return until();
}

Future<FfiCaptureSession> _session({
  int channels = 1,
  int ringCapacity = 512,
  Duration maxDuration = const Duration(minutes: 30),
}) async {
  final session = await FfiCaptureSession.open(
    CaptureConfig(
      hop: _hop,
      channels: channels,
      ringCapacity: ringCapacity,
      maxDuration: maxDuration,
    ),
  );
  addTearDown(session.dispose);
  return session;
}

void main() {
  group('hop reduction', () {
    test('publishes one frame per hop, not one per callback', () async {
      final session = await _session();

      // Three hops delivered as one block, then a fourth as three ragged
      // blocks - a real device does both.
      session.feedSynthetic(_tone(_hop * 3));
      session.feedSynthetic(_tone(200));
      session.feedSynthetic(_tone(200));
      session.feedSynthetic(_tone(112));

      expect(session.produced, 4);
      expect(session.drain(), 4);
      expect(session.scope.length, 4);
    });

    test(
      'holds a partial hop across calls instead of flushing early',
      () async {
        final session = await _session();

        session.feedSynthetic(_tone(_hop - 1));
        expect(
          session.produced,
          0,
          reason: 'a partial hop must not be emitted',
        );

        session.feedSynthetic(_tone(1));
        expect(session.produced, 1);
      },
    );

    test('reduces to the extremes and an RMS between them', () async {
      final session = await _session();

      session.feedSynthetic(_tone(_hop, amplitude: 20000));
      session.drain();

      expect(session.scope.maxAt(0), closeTo(20000, 200));
      expect(session.scope.minAt(0), closeTo(-20000, 200));
      // A sine's RMS is its peak over root two.
      expect(session.scope.rmsAt(0), closeTo(20000 / math.sqrt2, 400));
    });

    test('takes the extremes across channels, not their average', () async {
      final session = await _session(channels: 2);

      final samples = Int16List(_hop * 2);
      for (var frame = 0; frame < _hop; frame++) {
        samples[frame * 2] = 500; // quiet left
        samples[frame * 2 + 1] = 25000; // loud right
      }
      session
        ..feedSynthetic(samples)
        ..drain();

      expect(session.scope.maxAt(0), 25000);
    });

    test('silence reduces to silence', () async {
      final session = await _session();

      session
        ..feedSynthetic(Int16List(_hop))
        ..drain();

      expect(session.scope.minAt(0), 0);
      expect(session.scope.maxAt(0), 0);
      expect(session.scope.rmsAt(0), 0);
    });
  });

  group('the ring', () {
    test('drains in order and empties', () async {
      final session = await _session();

      session.feedSynthetic(_tone(_hop * 5));

      expect(session.drain(), 5);
      expect(session.drain(), 0, reason: 'a drained ring must be empty');
    });

    test('drops rather than blocking when the consumer never drains', () async {
      // The producer is an audio callback. Stalling it to wait for room would
      // be an audible glitch, so a full ring drops and counts instead.
      final session = await _session(ringCapacity: 8);

      session.feedSynthetic(_tone(_hop * 64));

      expect(session.produced, 64);
      expect(session.dropped, greaterThan(0));
      expect(session.produced - session.dropped, lessThanOrEqualTo(8));
    });

    test('recovers once the consumer catches up', () async {
      final session = await _session(ringCapacity: 8);

      session.feedSynthetic(_tone(_hop * 64));
      session.drain();
      final droppedSoFar = session.dropped;

      session.feedSynthetic(_tone(_hop * 4));

      expect(
        session.dropped,
        droppedSoFar,
        reason: 'no new drops after a drain',
      );
      expect(session.drain(), 4);
    });
  });

  group('the rolling scope', () {
    test('retains the newest frames and forgets the oldest', () async {
      final session = await FfiCaptureSession.open(
        const CaptureConfig(hop: _hop, scopeCapacity: 4),
      );
      addTearDown(session.dispose);

      for (var i = 0; i < 10; i++) {
        session.feedSynthetic(_tone(_hop, amplitude: 1000 * (i + 1)));
      }
      session.drain();

      expect(session.scope.length, 4);
      // Frames 7..10, so the oldest retained is the seventh.
      expect(session.scope.maxAt(0), closeTo(7000, 200));
      expect(session.scope.maxAt(3), closeTo(10000, 200));
    });

    test('amplitude is the larger excursion, normalized', () async {
      final session = await _session();

      session
        ..feedSynthetic(_tone(_hop, amplitude: 32767))
        ..drain();

      expect(session.scope.amplitudeAt(0), closeTo(1.0, 0.02));
    });
  });

  group('stop', () {
    test('returns peaks for the whole take, at the hop resolution', () async {
      final session = await _session();

      session.feedSynthetic(_tone(_hop * 40));
      final peaks = await session.stop();
      addTearDown(peaks.dispose);

      expect(peaks.finestSamplesPerPixel, _hop);
      expect(peaks.pairCount(0), 40);
      expect(peaks.sampleRate, 44100);
      expect(peaks.lengthInSamples, 40 * _hop);
      expect(peaks.levels, greaterThan(1));
    });

    test('is complete even when the consumer never drained', () async {
      // History comes from the audio thread's own buffer, not from what the
      // visualizer happened to collect, so a backgrounded app still gets a
      // whole waveform.
      final session = await _session(ringCapacity: 8);

      session.feedSynthetic(_tone(_hop * 200));
      expect(session.dropped, greaterThan(0));

      final peaks = await session.stop();
      addTearDown(peaks.dispose);

      expect(
        peaks.pairCount(0),
        200,
        reason:
            'dropped frames are a display '
            'concern; the take must still be whole',
      );
    });

    test('feeds straight into a compact bar summary', () async {
      // The whole sender-side voice-note path: capture, stop, quantize, upload.
      final session = await _session();

      session.feedSynthetic(_tone(_hop * 100));
      final peaks = await session.stop();
      addTearDown(peaks.dispose);

      final bars = CompactBars.encode(peaks);
      expect(bars, hasLength(64));
      expect(CompactBars.toBase64(bars).length, lessThan(100));
      expect(bars.reduce(math.max), greaterThan(0));
    });

    test('reports an empty take rather than inventing one', () async {
      final session = await _session();

      await expectLater(session.stop(), throwsA(isA<CaptureUnavailable>()));
    });

    test('truncates rather than growing the history buffer', () async {
      // Growing it would mean allocating on the audio thread. Past the cap,
      // capture keeps running and says so.
      final session = await _session(
        maxDuration: const Duration(milliseconds: 200),
      );

      expect(session.truncated, isFalse);
      session.feedSynthetic(_tone(_hop * 100));
      expect(session.truncated, isTrue);

      final peaks = await session.stop();
      addTearDown(peaks.dispose);
      expect(peaks.pairCount(0), lessThan(100));
    });
  });

  test('a disposed session refuses further use', () async {
    final session = await FfiCaptureSession.open(const CaptureConfig());
    await session.dispose();

    expect(() => session.feedSynthetic(Int16List(512)), throwsStateError);
    // Idempotent: a double destroy would corrupt the heap.
    await session.dispose();
  });

  group('disposing', () {
    test('freezes the counters rather than reading freed memory', () async {
      // The four counters read straight out of the C struct, and dispose frees
      // it. They answer from a frozen tally afterwards instead of throwing,
      // because a UI reading one while it tears down has a right to an answer -
      // and because FakeCaptureSession answers too.
      final session = await _session(ringCapacity: 8);
      session.feedSynthetic(_tone(_hop * 64));

      final before = (
        produced: session.produced,
        dropped: session.dropped,
        pcmDropped: session.pcmDropped,
        truncated: session.truncated,
      );
      expect(before.produced, 64);
      expect(before.dropped, greaterThan(0));

      await session.dispose();

      // Churn the allocator so the freed struct is actually written over.
      // Reading freed memory usually finds the old bytes still sitting there,
      // so a test that only disposed and then read would pass about a third of
      // the time with the bug still in place.
      for (var i = 0; i < 8; i++) {
        (await _session(ringCapacity: 8)).feedSynthetic(_tone(_hop * (i + 1)));
      }

      expect(session.produced, before.produced);
      expect(session.dropped, before.dropped);
      expect(session.pcmDropped, before.pcmDropped);
      expect(session.truncated, before.truncated);
      expect(session.isRecording, isFalse);
      expect(session.isPaused, isFalse);
    });

    test('leaves a playable WAV when a take is abandoned', () async {
      // dispose() without stop(). The audio is already on disk; only the
      // header still claims the file ends at byte 44, so without the rewrite
      // every player opens this and shows nothing.
      final directory = Directory.systemTemp.createTempSync('monowave-drop');
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = '${directory.path}/abandoned.wav';

      final session = await FfiCaptureSession.open(
        CaptureConfig(hop: _hop, recordTo: path),
      );
      session
        ..feedSynthetic(_tone(_hop * 40, amplitude: 20000))
        ..drain();

      await session.dispose();

      final decoded = await MonowavePlatform.instance.decodeBytes(
        File(path).readAsBytesSync(),
      );
      addTearDown(decoded.dispose);

      expect(decoded.lengthInSamples, _hop * 40);
      expect(decoded.sampleRate, 44100);
      expect(decoded.view(decoded.levels - 1)[1], closeTo(20000, 500));
    });

    test('does not close the recording file twice after a stop', () async {
      // The ordinary way to end a recording is stop() then dispose(), and
      // closing a RandomAccessFile twice throws.
      final directory = Directory.systemTemp.createTempSync('monowave-close');
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = '${directory.path}/take.wav';

      final session = await FfiCaptureSession.open(
        CaptureConfig(hop: _hop, recordTo: path),
      );
      session
        ..feedSynthetic(_tone(_hop * 10))
        ..drain();

      final peaks = await session.stop();
      addTearDown(peaks.dispose);

      await expectLater(session.dispose(), completes);
      final written = File(path).lengthSync();

      await session.dispose();
      expect(
        File(path).lengthSync(),
        written,
        reason: 'a second dispose must not rewrite or truncate the file',
      );
    });
  });

  group('a session dropped without dispose', () {
    // dispose() is still the contract. This is the backstop under it: a session
    // holds the C struct, two lock-free rings, the take history, the two drain
    // buffers *and* an open input device, so a consumer that forgets would
    // otherwise leave the microphone live for the life of the process.
    test('is destroyed by the finalizer rather than leaked', () async {
      final before = bindings.wfCaptureLive();

      final live = await _openAndDrop(4);
      expect(
        live,
        before + 4,
        reason: 'four undisposed sessions should have been live in there',
      );

      final reclaimed = await _pressGc(
        () => bindings.wfCaptureLive() == before,
      );

      expect(
        reclaimed,
        isTrue,
        reason:
            'dropping a session must eventually destroy it: '
            '${bindings.wfCaptureLive() - before} still live',
      );
    });

    test('is not destroyed twice when it was disposed first', () async {
      // dispose() detaches. Without that the finalizer comes back for a pointer
      // already freed, and a double destroy is a corrupt heap rather than a
      // failed expectation - so the count dropping *below* baseline is the
      // gentlest way this can fail, and an abort is the likelier one.
      final before = bindings.wfCaptureLive();

      expect(
        await _openDisposeAndDrop(4),
        before,
        reason: 'dispose() should have destroyed each one already',
      );

      await _pressGc(() => false);
      expect(bindings.wfCaptureLive(), before);
    });
  });

  group('recording to a file', () {
    test('writes a WAV that decodes back to what was captured', () async {
      final directory = Directory.systemTemp.createTempSync('monowave-rec');
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = '${directory.path}/take.wav';

      final session = await FfiCaptureSession.open(
        CaptureConfig(hop: _hop, recordTo: path),
      );
      addTearDown(session.dispose);

      session
        ..feedSynthetic(_tone(_hop * 40, amplitude: 20000))
        ..drain();
      final peaks = await session.stop();
      addTearDown(peaks.dispose);

      // The audio itself, not just the reduction: this is what a trim and an
      // export need, and the audio thread never touched the filesystem to
      // produce it.
      final decoded = await MonowavePlatform.instance.decodeBytes(
        File(path).readAsBytesSync(),
      );
      addTearDown(decoded.dispose);

      expect(decoded.sampleRate, 44100);
      expect(decoded.lengthInSamples, _hop * 40);
      expect(decoded.view(decoded.levels - 1)[1], closeTo(20000, 500));
      expect(session.pcmDropped, 0);
    });

    test('keeps only the reduction when no path is given', () async {
      final session = await _session();

      session.feedSynthetic(_tone(_hop * 10));

      expect(session.pcmDropped, 0);
      final peaks = await session.stop();
      addTearDown(peaks.dispose);
      expect(peaks.pairCount(0), 10);
    });
  });

  test('starting without a device reports it rather than hanging', () async {
    // CI has no microphone. Either it opens or it fails cleanly; what it must
    // not do is block.
    final session = await _session();

    try {
      await session.start();
      expect(session.isRecording, isTrue);
      await session.stop().then((p) => p.dispose()).catchError((_) {});
    } on CaptureUnavailable {
      expect(session.isRecording, isFalse);
    }
  });
}
