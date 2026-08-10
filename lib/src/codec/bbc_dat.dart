import 'dart:typed_data';

import '../model/waveform_peaks.dart';

/// Reader and writer for the BBC `audiowaveform` binary peak format.
///
/// Wire compatibility with the standard tool is the point. A server can
/// precompute peaks on upload and send them to a client that owns no decoder at
/// all. It also means that monowave interoperates with the peaks.js ecosystem
/// at no cost.
///
/// The layout is little-endian throughout:
///
/// | Offset | Type   | Field                            |
/// |--------|--------|----------------------------------|
/// | 0      | int32  | version (1 or 2)                 |
/// | 4      | uint32 | flags                            |
/// | 8      | int32  | sample rate                      |
/// | 12     | int32  | samples per pixel                |
/// | 16     | uint32 | length, in min/max pairs         |
/// | 20     | int32  | channels (version 2 only)        |
///
/// followed by `length * channels` interleaved min/max values. In the flags
/// field, bit 0 set means 8-bit data.
abstract final class WaveformDat {
  static const _headerV1 = 20;
  static const _headerV2 = 24;
  static const _flag8Bit = 0x1;

  /// Parses a `.dat` buffer into a peak pyramid.
  ///
  /// This method mixes a multi-channel file to mono: the min of the channel
  /// minima and the max of the channel maxima. That preserves the true extremes
  /// of the moment, which is what a single-lane waveform must show. A waveform
  /// with two lanes needs the channels apart, and monowave defers it until
  /// something asks for it.
  static WaveformPeaks decode(Uint8List bytes, {int? maxLevels}) {
    if (bytes.lengthInBytes < _headerV1) {
      throw const FormatException(
        'Not a .dat file: buffer is shorter than a header',
      );
    }

    final data = ByteData.sublistView(bytes);
    final version = data.getInt32(0, Endian.little);
    if (version != 1 && version != 2) {
      throw FormatException('Unsupported .dat version: $version');
    }

    final flags = data.getUint32(4, Endian.little);
    final is8Bit = flags & _flag8Bit != 0;
    final sampleRate = data.getInt32(8, Endian.little);
    final samplesPerPixel = data.getInt32(12, Endian.little);
    final length = data.getUint32(16, Endian.little);

    final headerSize = version == 1 ? _headerV1 : _headerV2;
    final channels = version == 1 ? 1 : data.getInt32(20, Endian.little);

    if (samplesPerPixel < 1) {
      throw FormatException('Invalid samples per pixel: $samplesPerPixel');
    }
    if (channels < 1) {
      throw FormatException('Invalid channel count: $channels');
    }

    final values = length * channels * 2;
    final bytesPerValue = is8Bit ? 1 : 2;
    final needed = headerSize + values * bytesPerValue;
    if (bytes.lengthInBytes < needed) {
      throw FormatException(
        'Truncated .dat: header declares $length pairs across $channels '
        'channel(s) ($needed bytes), buffer holds ${bytes.lengthInBytes}',
      );
    }

    final peaks = Int16List(length * 2);
    for (var pair = 0; pair < length; pair++) {
      var lo = 32767;
      var hi = -32768;

      for (var channel = 0; channel < channels; channel++) {
        final index = (pair * channels + channel) * 2;
        final offset = headerSize + index * bytesPerValue;

        final int channelMin;
        final int channelMax;
        if (is8Bit) {
          // 8-bit files store the top byte, so restore the scale rather than
          // handing a painter values 256x too quiet.
          channelMin = data.getInt8(offset) * 256;
          channelMax = data.getInt8(offset + 1) * 256;
        } else {
          channelMin = data.getInt16(offset, Endian.little);
          channelMax = data.getInt16(offset + 2, Endian.little);
        }

        if (channelMin < lo) lo = channelMin;
        if (channelMax > hi) hi = channelMax;
      }

      peaks[pair * 2] = lo;
      peaks[pair * 2 + 1] = hi;
    }

    return WaveformPeaks.fromInterleaved(
      peaks,
      sampleRate: sampleRate,
      baseSamplesPerPixel: samplesPerPixel,
      channels: channels,
      maxLevels: maxLevels,
    );
  }

  /// Serializes one [level] of [peaks] to a `.dat` buffer.
  ///
  /// A [bits] value of 8 halves the size at the cost of the low byte. That loss
  /// is imperceptible in a waveform on screen, and it is what makes peaks cheap
  /// enough to store next to a message.
  static Uint8List encode(
    WaveformPeaks peaks, {
    int version = 2,
    int bits = 16,
    int level = 0,
  }) {
    if (version != 1 && version != 2) {
      throw ArgumentError.value(version, 'version', 'must be 1 or 2');
    }
    if (bits != 8 && bits != 16) {
      throw ArgumentError.value(bits, 'bits', 'must be 8 or 16');
    }

    final source = peaks.view(level);
    final pairs = source.length ~/ 2;
    final headerSize = version == 1 ? _headerV1 : _headerV2;
    final bytesPerValue = bits == 8 ? 1 : 2;

    final out = Uint8List(headerSize + pairs * 2 * bytesPerValue);
    final data = ByteData.sublistView(out);

    data
      ..setInt32(0, version, Endian.little)
      ..setUint32(4, bits == 8 ? _flag8Bit : 0, Endian.little)
      ..setInt32(8, peaks.sampleRate, Endian.little)
      ..setInt32(12, peaks.samplesPerPixel(level), Endian.little)
      ..setUint32(16, pairs, Endian.little);
    if (version == 2) {
      // Always 1: monowave's pyramid is mono-mixed, whatever the source had.
      data.setInt32(20, 1, Endian.little);
    }

    for (var i = 0; i < pairs * 2; i++) {
      final offset = headerSize + i * bytesPerValue;
      if (bits == 8) {
        data.setInt8(offset, source[i] ~/ 256);
      } else {
        data.setInt16(offset, source[i], Endian.little);
      }
    }

    return out;
  }
}
