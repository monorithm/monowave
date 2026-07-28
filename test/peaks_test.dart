import 'dart:math' as math;
import 'dart:typed_data';

import 'package:monowave/monowave.dart';
import 'package:test/test.dart';

Int16List _ramp(int n) => Int16List.fromList([for (var i = 0; i < n; i++) i]);

void main() {
  group('reduction', () {
    test('keeps both extremes of each bucket', () {
      final peaks = WaveformPeaks.fromSamples(
        Int16List.fromList([3, -7, 5, 0, -2, 9]),
        sampleRate: 8000,
        baseSamplesPerPixel: 3,
      );

      // [3, -7, 5] -> (-7, 5); [0, -2, 9] -> (-2, 9)
      expect(peaks.view(0), [-7, 5, -2, 9]);
    });

    test('a partial final bucket is kept, not dropped', () {
      final peaks = WaveformPeaks.fromSamples(
        Int16List.fromList([1, 2, 3, 4, 100]),
        sampleRate: 8000,
        baseSamplesPerPixel: 4,
      );

      expect(peaks.pairCount(0), 2);
      expect(peaks.view(0), [1, 4, 100, 100]);
    });

    test('does not average — a lone transient survives', () {
      // The failure this guards against: averaging would render this bucket as
      // near-silence, which is exactly how a click or a plosive disappears.
      final samples = Int16List(128)..[64] = 32000;

      final peaks = WaveformPeaks.fromSamples(
        samples,
        sampleRate: 44100,
        baseSamplesPerPixel: 128,
      );

      expect(peaks.view(0), [0, 32000]);
    });
  });

  group('mipmap', () {
    test('halves pair count per level until a single pair remains', () {
      final peaks = WaveformPeaks.fromSamples(
        _ramp(1024),
        sampleRate: 44100,
        baseSamplesPerPixel: 64,
      );

      expect(peaks.pairCount(0), 16);
      expect(
        [for (var l = 0; l < peaks.levels; l++) peaks.pairCount(l)],
        [16, 8, 4, 2, 1],
      );
      expect(peaks.samplesPerPixel(3), 64 * 8);
    });

    test('every coarse level bounds the level below it', () {
      // The invariant that makes zooming exact rather than approximate. If it
      // ever breaks, zoomed-out waveforms clip peaks that zooming in reveals.
      final random = math.Random(7);
      final samples = Int16List.fromList([
        for (var i = 0; i < 5000; i++) random.nextInt(65536) - 32768,
      ]);

      final peaks = WaveformPeaks.fromSamples(
        samples,
        sampleRate: 44100,
        baseSamplesPerPixel: 32,
      );

      for (var level = 1; level < peaks.levels; level++) {
        final fine = peaks.view(level - 1);
        final coarse = peaks.view(level);

        for (var pair = 0; pair < peaks.pairCount(level); pair++) {
          final lo = coarse[pair * 2];
          final hi = coarse[pair * 2 + 1];

          for (final child in [pair * 2, pair * 2 + 1]) {
            if (child >= peaks.pairCount(level - 1)) continue;
            expect(
              fine[child * 2],
              greaterThanOrEqualTo(lo),
              reason: 'level $level pair $pair does not bound its child min',
            );
            expect(
              fine[child * 2 + 1],
              lessThanOrEqualTo(hi),
              reason: 'level $level pair $pair does not bound its child max',
            );
          }
        }
      }
    });
  });

  group('levelFor', () {
    late WaveformPeaks peaks;

    setUp(() {
      peaks = WaveformPeaks.fromSamples(
        _ramp(4096),
        sampleRate: 44100,
        baseSamplesPerPixel: 64,
      );
    });

    test('never returns a level coarser than the target', () {
      for (final target in [64.0, 100.0, 128.0, 500.0, 1e6]) {
        expect(
          peaks.samplesPerPixel(peaks.levelFor(target)),
          lessThanOrEqualTo(target),
        );
      }
    });

    test('picks the coarsest level that still has enough detail', () {
      expect(peaks.levelFor(64), 0);
      expect(peaks.levelFor(127), 0);
      expect(peaks.levelFor(128), 1);
      expect(peaks.levelFor(256), 2);
    });

    test('clamps to the finest level when zoomed past the data', () {
      expect(peaks.levelFor(1), 0);
    });
  });

  test('rejects interleaved input with an odd length', () {
    expect(
      () => WaveformPeaks.fromInterleaved(
        Int16List.fromList([1, 2, 3]),
        sampleRate: 44100,
        baseSamplesPerPixel: 128,
      ),
      throwsArgumentError,
    );
  });
}
