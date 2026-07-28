import 'dart:math' as math;
import 'dart:typed_data';

import 'package:monowave/monowave.dart';
import 'package:test/test.dart';

WaveformPeaks _sine({
  int samples = 44100,
  int sampleRate = 44100,
  double amplitude = 1.0,
}) => WaveformPeaks.fromSamples(
  Int16List.fromList([
    for (var i = 0; i < samples; i++)
      (math.sin(2 * math.pi * 440 * i / sampleRate) * 32767 * amplitude)
          .round(),
  ]),
  sampleRate: sampleRate,
  baseSamplesPerPixel: 128,
);

void main() {
  group('BBC .dat', () {
    test('round-trips version 2 at 16 bits', () {
      final original = _sine();
      final restored = WaveformDat.decode(WaveformDat.encode(original));

      expect(restored.sampleRate, original.sampleRate);
      expect(restored.samplesPerPixel(0), original.samplesPerPixel(0));
      expect(restored.view(0), original.view(0));
    });

    test('round-trips version 1, which has no channel field', () {
      final original = _sine();
      final bytes = WaveformDat.encode(original, version: 1);
      final restored = WaveformDat.decode(bytes);

      expect(restored.view(0), original.view(0));
      // 20-byte header rather than 24.
      expect(bytes.length, 20 + original.pairCount(0) * 4);
    });

    test('8-bit loses the low byte and nothing more', () {
      final original = _sine();
      final bytes = WaveformDat.encode(original, bits: 8);
      final restored = WaveformDat.decode(bytes);

      expect(bytes.length, 24 + original.pairCount(0) * 2);
      for (var i = 0; i < original.pairCount(0) * 2; i++) {
        expect(
          (restored.view(0)[i] - original.view(0)[i]).abs(),
          lessThan(256),
          reason: 'value $i drifted by more than one 8-bit step',
        );
      }
    });

    test('mixes multi-channel down to the true extremes', () {
      // Hand-built version 2, two channels, one pair: L=(-100, 50), R=(-20, 900).
      final bytes = Uint8List(24 + 8);
      final data = ByteData.sublistView(bytes)
        ..setInt32(0, 2, Endian.little)
        ..setUint32(4, 0, Endian.little)
        ..setInt32(8, 44100, Endian.little)
        ..setInt32(12, 256, Endian.little)
        ..setUint32(16, 1, Endian.little)
        ..setInt32(20, 2, Endian.little)
        ..setInt16(24, -100, Endian.little)
        ..setInt16(26, 50, Endian.little)
        ..setInt16(28, -20, Endian.little)
        ..setInt16(30, 900, Endian.little);

      final peaks = WaveformDat.decode(
        Uint8List.sublistView(data.buffer.asUint8List()),
      );

      expect(peaks.view(0), [-100, 900]);
    });

    test('rejects a truncated buffer rather than reading past the end', () {
      final bytes = WaveformDat.encode(_sine());

      expect(
        () => WaveformDat.decode(Uint8List.sublistView(bytes, 0, 40)),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects an unknown version and a too-short buffer', () {
      final bogus = Uint8List(24);
      ByteData.sublistView(bogus).setInt32(0, 99, Endian.little);

      expect(() => WaveformDat.decode(bogus), throwsA(isA<FormatException>()));
      expect(
        () => WaveformDat.decode(Uint8List(4)),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('compact bars', () {
    test('produces exactly the requested number of bytes', () {
      expect(CompactBars.encode(_sine()).length, 64);
      expect(CompactBars.encode(_sine(), bars: 32).length, 32);
    });

    test('base64 round-trips, and a voice note is tiny', () {
      final bars = CompactBars.encode(_sine());
      final encoded = CompactBars.toBase64(bars);

      expect(CompactBars.fromBase64(encoded), bars);
      expect(encoded.length, lessThan(100));
    });

    test('normalization makes a quiet recording legible', () {
      // The failure this guards: a note recorded at 5% of full scale renders as
      // a flat line without it.
      final quiet = _sine(amplitude: 0.05);

      final raw = CompactBars.encode(quiet, normalize: false);
      final normalized = CompactBars.encode(quiet, normalize: true);

      expect(raw.reduce(math.max), lessThan(normalized.reduce(math.max)));
      expect(normalized.reduce(math.max), 255);
    });

    test('dBFS lifts quiet content above where linear leaves it', () {
      final quiet = _sine(amplitude: 0.05);

      final linear = CompactBars.encode(
        quiet,
        scale: BarScale.linear,
        normalize: false,
      );
      final dbfs = CompactBars.encode(
        quiet,
        scale: BarScale.dbfs,
        normalize: false,
      );

      expect(dbfs.reduce(math.max), greaterThan(linear.reduce(math.max)));
    });

    test('silence stays silent instead of being amplified into noise', () {
      final silence = WaveformPeaks.fromSamples(
        Int16List(4096),
        sampleRate: 44100,
        baseSamplesPerPixel: 128,
      );

      expect(CompactBars.encode(silence), everyElement(0));
    });

    test('heights land between 0 and 1', () {
      final heights = CompactBars.heights(CompactBars.encode(_sine()));

      expect(heights, everyElement(inInclusiveRange(0.0, 1.0)));
      expect(heights.reduce(math.max), 1.0);
    });

    group('fromAmplitudes — the live capture path', () {
      test('folds an arbitrary number of hops into fixed bars', () {
        final amplitudes = [for (var i = 0; i < 500; i++) i / 500];

        final bars = CompactBars.fromAmplitudes(amplitudes, bars: 64);

        expect(bars.length, 64);
        expect(bars.first, lessThan(bars.last));
        expect(bars.last, 255);
      });

      test('handles fewer hops than bars without dropping any', () {
        final bars = CompactBars.fromAmplitudes([1.0, 0.0, 1.0], bars: 64);

        expect(bars.length, 64);
        expect(bars.reduce(math.max), 255);
      });

      test('an empty recording is all silence, not a crash', () {
        expect(CompactBars.fromAmplitudes([]), everyElement(0));
      });
    });

    test('rejects a non-negative floor', () {
      expect(
        () => CompactBars.encode(_sine(), floorDb: 0),
        throwsArgumentError,
      );
    });
  });
}
