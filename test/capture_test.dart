// The realtime path, driven with synthetic PCM through the same entry point a
// microphone drives.
//
// No device, no permission prompt, and deterministic — which is what lets the
// hardest part of monowave be tested on every platform in CI rather than only
// by hand on a phone.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:monowave/monowave.dart';
import 'package:monowave/src/capture/ffi_capture_session.dart';
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
      // blocks — a real device does both.
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
