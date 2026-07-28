// Synthesized audio, so the repo carries no binaries.
//
// Each fixture targets a specific way a reduction can be wrong: a sweep catches
// resampling artefacts, silence catches sentinel leakage, clipping catches
// saturation handling, DC offset catches centre-line assumptions, and a
// single-sample click catches averaging masquerading as min/max.

import 'dart:math' as math;
import 'dart:typed_data';

/// Writes 16-bit PCM samples into a canonical 44-byte WAV container.
Uint8List wav(Int16List samples, {int sampleRate = 44100, int channels = 1}) {
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
    ..setUint32(16, 16, Endian.little) // PCM header size
    ..setUint16(20, 1, Endian.little) // format: PCM
    ..setUint16(22, channels, Endian.little)
    ..setUint32(24, sampleRate, Endian.little)
    ..setUint32(28, sampleRate * channels * 2, Endian.little) // byte rate
    ..setUint16(32, channels * 2, Endian.little) // block align
    ..setUint16(34, 16, Endian.little); // bits per sample
  ascii(36, 'data');
  data.setUint32(40, dataBytes, Endian.little);

  for (var i = 0; i < samples.length; i++) {
    data.setInt16(44 + i * 2, samples[i], Endian.little);
  }

  return out;
}

/// A logarithmic sweep from 40 Hz to 8 kHz.
Int16List sineSweep({int sampleRate = 44100, double seconds = 2}) {
  final total = (sampleRate * seconds).round();
  final samples = Int16List(total);

  const startHz = 40.0;
  const endHz = 8000.0;
  final ratio = math.log(endHz / startHz);

  var phase = 0.0;
  for (var i = 0; i < total; i++) {
    final t = i / total;
    final hz = startHz * math.exp(ratio * t);
    phase += 2 * math.pi * hz / sampleRate;
    samples[i] = (math.sin(phase) * 30000).round();
  }

  return samples;
}

Int16List silence({int sampleRate = 44100, double seconds = 1}) =>
    Int16List((sampleRate * seconds).round());

/// A tone driven well past full scale, so it saturates at both rails.
Int16List clipping({int sampleRate = 44100, double seconds = 1}) {
  final total = (sampleRate * seconds).round();
  return Int16List.fromList([
    for (var i = 0; i < total; i++)
      (math.sin(2 * math.pi * 220 * i / sampleRate) * 60000).round().clamp(
        -32768,
        32767,
      ),
  ]);
}

/// A quiet tone riding a large positive offset.
///
/// The centre line is at zero, not at the signal's mean, so this should render
/// entirely above it. A reducer that recentres would hide a real defect.
Int16List dcOffset({int sampleRate = 44100, double seconds = 1}) {
  final total = (sampleRate * seconds).round();
  return Int16List.fromList([
    for (var i = 0; i < total; i++)
      (12000 + math.sin(2 * math.pi * 100 * i / sampleRate) * 2000).round(),
  ]);
}

/// Silence with one full-scale sample in the middle.
///
/// The strongest test that reduction is min/max: an average over a 128-sample
/// bucket would render this as 256, which is indistinguishable from silence.
Int16List click({int sampleRate = 44100, double seconds = 1}) {
  final total = (sampleRate * seconds).round();
  return Int16List(total)..[total ~/ 2] = 32767;
}

/// Left near-silent, right loud — the channels must not be averaged together.
Int16List stereo({int sampleRate = 44100, double seconds = 1}) {
  final frames = (sampleRate * seconds).round();
  final samples = Int16List(frames * 2);
  for (var i = 0; i < frames; i++) {
    samples[i * 2] = (math.sin(2 * math.pi * 200 * i / sampleRate) * 500)
        .round();
    samples[i * 2 + 1] = (math.sin(2 * math.pi * 200 * i / sampleRate) * 25000)
        .round();
  }
  return samples;
}

/// Every fixture, by name.
Map<String, Uint8List> all() => {
  'sine-sweep': wav(sineSweep()),
  'silence': wav(silence()),
  'clipping': wav(clipping()),
  'dc-offset': wav(dcOffset()),
  'click': wav(click()),
  'stereo': wav(stereo(), channels: 2),
};

/// FNV-1a (32-bit) over the pyramid's values.
///
/// Two details matter, and both were bugs first.
///
/// It hashes the int16 *values* in explicit little-endian order rather than a
/// byte view of the list, so the result does not depend on the host's
/// endianness.
///
/// And it is 32-bit with a shift-decomposed multiply rather than 64-bit,
/// because Dart integers are 64-bit on the VM but doubles on web. A 64-bit FNV
/// silently produces different numbers under `dart2js`, which would make this
/// check meaningless on the one target it exists to police.
String digest(List<Int16List> levels) {
  var hash = 0x811c9dc5;

  void mix(int byte) {
    hash ^= byte;
    hash =
        (hash +
            ((hash << 1) +
                (hash << 4) +
                (hash << 7) +
                (hash << 8) +
                (hash << 24))) &
        0xFFFFFFFF;
  }

  for (final level in levels) {
    for (final value in level) {
      final unsigned = value & 0xFFFF;
      mix(unsigned & 0xFF);
      mix((unsigned >> 8) & 0xFF);
    }
  }

  return hash.toRadixString(16).padLeft(8, '0');
}
