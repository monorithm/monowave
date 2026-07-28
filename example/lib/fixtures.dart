import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:monowave/monowave.dart';

/// Synthesized audio, so the repo carries no binaries.
///
/// A plain sine would make a rectangle and prove nothing about the reduction.
/// This is shaped like speech instead: bursts of energy with gaps between them,
/// varying in loudness, so the waveform has something to say.
abstract final class Fixtures {
  static const sampleRate = 44100;
  static const _seconds = 6;

  /// Roughly speech-shaped mono audio.
  static Int16List speech() {
    final random = math.Random(1312);
    final total = sampleRate * _seconds;
    final samples = Int16List(total);

    // Syllable-rate envelope: bursts of 90-260 ms with short gaps, at varying
    // levels, so normalization and the dBFS curve both have something to do.
    var i = 0;
    while (i < total) {
      final burst = (sampleRate * (0.09 + random.nextDouble() * 0.17)).round();
      final gap = (sampleRate * (0.03 + random.nextDouble() * 0.12)).round();
      final level = 0.15 + random.nextDouble() * 0.75;

      final end = math.min(i + burst, total);
      for (var j = i; j < end; j++) {
        final t = (j - i) / burst;
        // Raised-cosine envelope: no clicks at the edges of a burst.
        final envelope = 0.5 - 0.5 * math.cos(2 * math.pi * t);
        // Two partials plus noise, so buckets are not all identical.
        final tone =
            math.sin(2 * math.pi * 140 * j / sampleRate) * 0.7 +
            math.sin(2 * math.pi * 320 * j / sampleRate) * 0.3 +
            (random.nextDouble() - 0.5) * 0.15;

        samples[j] = (tone * envelope * level * 32767)
            .clamp(-32768, 32767)
            .round();
      }

      i = end + gap;
    }

    return samples;
  }

  /// The full pyramid — what the zoomable painter draws from.
  static final WaveformPeaks peaks = WaveformPeaks.fromSamples(
    speech(),
    sampleRate: sampleRate,
    baseSamplesPerPixel: 128,
  );

  static final WaveformTimeline timeline = WaveformTimeline.of(peaks);

  /// The 64-byte summary a sender would upload beside a voice note.
  static final Uint8List bars = CompactBars.encode(peaks);

  /// What actually travels in a message document.
  static final String barsBase64 = CompactBars.toBase64(bars);

  /// The fixture written to a real file, so exporting has something to read.
  ///
  /// Written on demand rather than committed: the repo carries no binaries, and
  /// the export path needs a source on disk because that is what a real edit
  /// session has.
  static Future<String> sourceFile() async {
    final file = File('${Directory.systemTemp.path}/monowave-fixture.wav');
    if (!file.existsSync()) {
      await file.writeAsBytes(_wav(speech(), sampleRate));
    }
    return file.path;
  }

  /// A canonical 44-byte PCM WAV header around [samples].
  static Uint8List _wav(Int16List samples, int rate) {
    final dataBytes = samples.length * 2;
    final out = Uint8List(44 + dataBytes);
    final data = ByteData.sublistView(out);

    void ascii(int offset, String tag) {
      for (var i = 0; i < tag.length; i++) {
        out[offset + i] = tag.codeUnitAt(i);
      }
    }

    ascii(0, 'RIFF');
    data.setUint32(4, 36 + dataBytes, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    data
      ..setUint32(16, 16, Endian.little)
      ..setUint16(20, 1, Endian.little)
      ..setUint16(22, 1, Endian.little)
      ..setUint32(24, rate, Endian.little)
      ..setUint32(28, rate * 2, Endian.little)
      ..setUint16(32, 2, Endian.little)
      ..setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    data.setUint32(40, dataBytes, Endian.little);

    for (var i = 0; i < samples.length; i++) {
      data.setInt16(44 + i * 2, samples[i], Endian.little);
    }

    return out;
  }
}
