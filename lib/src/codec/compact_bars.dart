import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../model/waveform_peaks.dart';

/// How bar heights are derived from sample amplitude.
enum BarScale {
  /// Amplitude straight through. Technically honest, and almost always the
  /// wrong picture: normal speech peaks well below full scale, so a linear
  /// waveform of a voice note looks nearly flat.
  linear,

  /// Decibels relative to full scale, floored. Matches how loudness is
  /// perceived and is what makes a voice note legible. The default.
  dbfs,
}

/// A fixed-width bar summary, small enough to store beside a message.
///
/// This is the whole voice-note strategy in one class. The sender computes bars
/// at record time and uploads roughly 64 bytes of metadata with the audio; the
/// receiver draws directly from those bytes with no decoder, no native code and
/// no waiting. It is what WhatsApp, Telegram and Signal do, and it removes the
/// entire decode path from the common case.
///
/// Bars are `uint8`, so one bar is one byte and a 64-bar summary base64s to 88
/// characters.
abstract final class CompactBars {
  /// Bars in a default summary. Enough detail for a chat bubble at any width.
  static const defaultBars = 64;

  /// Default silence floor for [BarScale.dbfs], in decibels.
  ///
  /// -45 dB suits speech. Music wants a lower floor; a noisy room wants higher.
  static const defaultFloorDb = -45.0;

  static const _fullScale = 32768.0;
  static final _ln10 = math.log(10);

  /// Summarizes [peaks] into [bars] bytes.
  ///
  /// With [normalize] set, the loudest bar becomes full height, so a quietly
  /// recorded note still reads clearly. Turn it off when several waveforms are
  /// shown together and their relative loudness carries meaning.
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
  /// This is the live-capture path: a recorder emits one amplitude per hop, and
  /// this folds however many arrived into a fixed-width summary at the end.
  /// Values outside 0 to 1 are clamped.
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

  /// Base64 for storing bars in a JSON document beside a message.
  static String toBase64(Uint8List bars) => base64Encode(bars);

  /// Reads bars back out of [encoded].
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
