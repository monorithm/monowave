import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../model/waveform_peaks.dart';

/// How this codec derives bar heights from sample amplitude.
enum BarScale {
  /// Amplitude straight through. This is technically honest, and it is almost
  /// always the wrong picture. Normal speech peaks at much less than full
  /// scale, so a linear waveform of a voice note looks nearly flat.
  linear,

  /// Decibels relative to full scale, with a floor. This matches how a user
  /// hears loudness, and it is what makes a voice note legible. This is the
  /// default.
  dbfs,
}

/// A fixed-width bar summary, small enough to store beside a message.
///
/// This class is the whole voice-note strategy. The sender computes bars at
/// record time and uploads approximately 64 bytes of metadata with the audio.
/// The receiver draws directly from those bytes, with no decoder, no native
/// code and no delay. WhatsApp, Telegram and Signal do the same, and this
/// removes the full decode path from the common case.
///
/// A bar is a `uint8`, so one bar is one byte. A 64-bar summary is 88
/// characters in base64.
abstract final class CompactBars {
  /// Bars in a default summary. Enough detail for a chat bubble at any width.
  static const defaultBars = 64;

  /// Default silence floor for [BarScale.dbfs], in decibels.
  ///
  /// -45 dB suits speech. Music needs a lower floor. A noisy room needs a
  /// higher floor.
  static const defaultFloorDb = -45.0;

  static const _fullScale = 32768.0;
  static final _ln10 = math.log(10);

  /// Summarizes [peaks] into [bars] bytes.
  ///
  /// If [normalize] is true, the loudest bar becomes full height. As a result,
  /// a quietly recorded note still reads clearly. When a host shows several
  /// waveforms together and their relative loudness carries meaning, set
  /// [normalize] to false.
  static Uint8List encode(
    WaveformPeaks peaks, {
    int bars = defaultBars,
    BarScale scale = BarScale.dbfs,
    double floorDb = defaultFloorDb,
    bool normalize = true,
    int level = 0,
  }) {
    final source = peaks.view(level);
    final pairs = source.length ~/ 2;
    if (bars < 1) {
      throw ArgumentError.value(bars, 'bars', 'must be at least 1');
    }
    if (pairs == 0) return Uint8List(bars);

    // Peak amplitude per bar: the larger excursion in either direction, so an
    // asymmetric waveform is not misrepresented by looking at one side only.
    final amplitudes = Float64List(bars);
    for (var bar = 0; bar < bars; bar++) {
      final start = (bar * pairs / bars).floor();
      final end = math.max(((bar + 1) * pairs / bars).ceil(), start + 1);

      var peak = 0;
      for (var pair = start; pair < end && pair < pairs; pair++) {
        final lo = source[pair * 2].abs();
        final hi = source[pair * 2 + 1].abs();
        if (lo > peak) peak = lo;
        if (hi > peak) peak = hi;
      }
      amplitudes[bar] = peak / _fullScale;
    }

    return _quantize(
      amplitudes,
      scale: scale,
      floorDb: floorDb,
      normalize: normalize,
    );
  }

  /// Summarizes a stream of already-normalized amplitudes into [bars] bytes.
  ///
  /// This is the live-capture path. A recorder emits one amplitude per hop. At
  /// the end, this method folds all the amplitudes that arrived into a
  /// fixed-width summary. It clamps values outside 0 to 1.
  static Uint8List fromAmplitudes(
    List<double> amplitudes, {
    int bars = defaultBars,
    BarScale scale = BarScale.linear,
    double floorDb = defaultFloorDb,
    bool normalize = true,
  }) {
    if (bars < 1) {
      throw ArgumentError.value(bars, 'bars', 'must be at least 1');
    }
    if (amplitudes.isEmpty) return Uint8List(bars);

    final folded = Float64List(bars);
    for (var bar = 0; bar < bars; bar++) {
      final start = (bar * amplitudes.length / bars).floor();
      final end = math.max(
        ((bar + 1) * amplitudes.length / bars).ceil(),
        start + 1,
      );

      var peak = 0.0;
      for (var i = start; i < end && i < amplitudes.length; i++) {
        final value = amplitudes[i].clamp(0.0, 1.0);
        if (value > peak) peak = value;
      }
      folded[bar] = peak;
    }

    return _quantize(
      folded,
      scale: scale,
      floorDb: floorDb,
      normalize: normalize,
    );
  }

  /// Bar heights from 0 to 1, ready to multiply by a track height.
  static Float32List heights(Uint8List bars) {
    final out = Float32List(bars.length);
    for (var i = 0; i < bars.length; i++) {
      out[i] = bars[i] / 255.0;
    }
    return out;
  }

  /// Base64, for storage of bars in a JSON document beside a message.
  static String toBase64(Uint8List bars) => base64Encode(bars);

  /// Reads bars back from [encoded].
  static Uint8List fromBase64(String encoded) => base64Decode(encoded);

  static Uint8List _quantize(
    List<double> amplitudes, {
    required BarScale scale,
    required double floorDb,
    required bool normalize,
  }) {
    if (floorDb >= 0) {
      throw ArgumentError.value(floorDb, 'floorDb', 'must be negative');
    }

    var gain = 1.0;
    if (normalize) {
      var loudest = 0.0;
      for (final amplitude in amplitudes) {
        if (amplitude > loudest) loudest = amplitude;
      }
      // Silence stays silence rather than being amplified into noise.
      if (loudest > 0) gain = 1 / loudest;
    }

    final out = Uint8List(amplitudes.length);
    for (var i = 0; i < amplitudes.length; i++) {
      final amplitude = (amplitudes[i] * gain).clamp(0.0, 1.0);

      final double height;
      switch (scale) {
        case BarScale.linear:
          height = amplitude;
        case BarScale.dbfs:
          if (amplitude <= 0) {
            height = 0;
          } else {
            final db = 20 * math.log(amplitude) / _ln10;
            height = ((db - floorDb) / -floorDb).clamp(0.0, 1.0);
          }
      }

      out[i] = (height * 255).round();
    }

    return out;
  }
}
