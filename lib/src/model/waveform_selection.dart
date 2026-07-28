import 'waveform_peaks.dart';
import 'waveform_timeline.dart';

/// A range of audio, in source samples.
///
/// Sample space rather than pixels or fractions, so a selection survives a
/// zoom, a resize and a rotation without drifting. Immutable: every gesture
/// produces a new value, which is also what makes undo cheap later.
class WaveformSelection {
  /// Normalizes so [start] is never after [end].
  factory WaveformSelection(int start, int end) => start <= end
      ? WaveformSelection._(start, end)
      : WaveformSelection._(end, start);

  const WaveformSelection._(this.start, this.end);

  /// A selection of nothing, at the origin.
  static const empty = WaveformSelection._(0, 0);

  /// A collapsed selection at [sample] - where a drag begins.
  factory WaveformSelection.at(int sample) =>
      WaveformSelection._(sample, sample);

  final int start;
  final int end;

  int get length => end - start;

  bool get isEmpty => length == 0;

  bool contains(int sample) => sample >= start && sample < end;

  Duration durationIn(WaveformTimeline timeline) =>
      timeline.timeAt(end) - timeline.timeAt(start);

  /// Moves [end] to [sample], keeping [start] anchored. A drag.
  WaveformSelection extendedTo(int sample) => WaveformSelection(start, sample);

  /// Moves the nearer edge to [sample]. Dragging a handle.
  WaveformSelection withNearestEdgeAt(int sample) =>
      (sample - start).abs() <= (sample - end).abs()
      ? WaveformSelection(sample, end)
      : WaveformSelection(start, sample);

  /// Slides the whole range by [samples], without changing its length.
  WaveformSelection shiftedBy(int samples) =>
      WaveformSelection._(start + samples, end + samples);

  /// Clamps to the extent of [peaks], so a selection cannot leave the audio.
  WaveformSelection clampedTo(WaveformPeaks peaks) {
    final total = peaks.lengthInSamples;
    return WaveformSelection._(start.clamp(0, total), end.clamp(0, total));
  }

  @override
  bool operator ==(Object other) =>
      other is WaveformSelection && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'WaveformSelection($start..$end)';
}

/// Where a cut should actually land, given peaks alone.
///
/// **These snap to the finest level's resolution, not to a sample.** With a
/// 128-sample base at 44.1 kHz that is about 3 ms - inaudible for a trim point,
/// and worth stating plainly because "zero crossing" usually implies exactness.
/// Sample-exact snapping would mean re-reading the source, which is a decode
/// per gesture; it can be added as a C entry point if something needs it.
abstract final class WaveformSnap {
  /// The nearest bucket whose extremes straddle zero.
  ///
  /// A bucket with `min <= 0 <= max` contains at least one sign change, so
  /// cutting inside it lands on or beside a zero crossing and avoids the click
  /// that cutting mid-swing produces.
  ///
  /// Returns [sample] unchanged if nothing within [searchRadius] qualifies.
  static int toZeroCrossing(
    WaveformPeaks peaks,
    int sample, {
    int searchRadius = 4096,
  }) =>
      _search(peaks, sample, searchRadius, (min, max) => min <= 0 && max >= 0);

  /// The quietest bucket within [searchRadius] - where a cut is least audible.
  ///
  /// Usually the better default for trimming speech: silence between words is a
  /// more forgiving edit point than a zero crossing mid-syllable.
  static int toQuietest(
    WaveformPeaks peaks,
    int sample, {
    int searchRadius = 4096,
  }) {
    final spp = peaks.finestSamplesPerPixel;
    final pairs = peaks.pairCount(0);
    if (pairs == 0) return sample;

    final view = peaks.view(0);
    final centre = (sample / spp).round().clamp(0, pairs - 1);
    final reach = (searchRadius / spp).ceil();

    var bestPair = centre;
    var bestAmplitude = 1 << 30;

    for (var offset = -reach; offset <= reach; offset++) {
      final pair = centre + offset;
      if (pair < 0 || pair >= pairs) continue;

      final low = view[pair * 2].abs();
      final high = view[pair * 2 + 1].abs();
      final amplitude = low > high ? low : high;

      // Ties go to the closer bucket, so a run of silence snaps to its near
      // edge rather than jumping across it.
      if (amplitude < bestAmplitude ||
          (amplitude == bestAmplitude &&
              (pair - centre).abs() < (bestPair - centre).abs())) {
        bestAmplitude = amplitude;
        bestPair = pair;
      }
    }

    return bestPair * spp;
  }

  static int _search(
    WaveformPeaks peaks,
    int sample,
    int searchRadius,
    bool Function(int min, int max) matches,
  ) {
    final spp = peaks.finestSamplesPerPixel;
    final pairs = peaks.pairCount(0);
    if (pairs == 0) return sample;

    final view = peaks.view(0);
    final centre = (sample / spp).round().clamp(0, pairs - 1);
    final reach = (searchRadius / spp).ceil();

    // Outward from the centre, so the first match found is the nearest.
    for (var offset = 0; offset <= reach; offset++) {
      for (final pair
          in offset == 0
              ? <int>[centre]
              : <int>[centre - offset, centre + offset]) {
        if (pair < 0 || pair >= pairs) continue;
        if (matches(view[pair * 2], view[pair * 2 + 1])) return pair * spp;
      }
    }

    return sample;
  }
}
