import 'waveform_peaks.dart';

/// Converts between playback time and sample position.
///
/// This class is the whole relationship between monowave and a player. It takes
/// a sample rate and a length, not a player instance. As a result, each of
/// `just_audio`, `media_kit` and a custom engine is a few lines of adapter in
/// the host. None of them is a dependency here.
///
/// Compose this class with a [WaveformViewport] to place a playhead:
///
/// ```dart
/// final x = viewport.xForSample(timeline.sampleAt(position));
/// ```
///
/// This code turns a tap back into a seek:
///
/// ```dart
/// player.seek(timeline.timeAt(viewport.sampleAtX(localX)));
/// ```
class WaveformTimeline {
  const WaveformTimeline({
    required this.sampleRate,
    required this.lengthInSamples,
  });

  /// The timeline that [peaks] implies.
  WaveformTimeline.of(WaveformPeaks peaks)
    : sampleRate = peaks.sampleRate,
      lengthInSamples = peaks.lengthInSamples;

  final int sampleRate;
  final int lengthInSamples;

  /// Total duration of the audio.
  Duration get duration => timeAt(lengthInSamples);

  /// The sample that plays at [time], clamped to the audio.
  double sampleAt(Duration time) {
    if (sampleRate <= 0) return 0;
    final sample =
        time.inMicroseconds * sampleRate / Duration.microsecondsPerSecond;
    return sample.clamp(0, lengthInSamples.toDouble());
  }

  /// The time when [sample] plays, clamped to the audio.
  Duration timeAt(num sample) {
    if (sampleRate <= 0) return Duration.zero;
    final clamped = sample.clamp(0, lengthInSamples);
    return Duration(
      microseconds: (clamped * Duration.microsecondsPerSecond / sampleRate)
          .round(),
    );
  }

  /// Progress through the audio at [time], from 0 to 1.
  double progressAt(Duration time) {
    if (lengthInSamples <= 0) return 0;
    return sampleAt(time) / lengthInSamples;
  }

  /// The time at [progress] through the audio, where [progress] runs 0 to 1.
  ///
  /// The inverse of [progressAt]. A fixed-bar voice note needs this method,
  /// because it has no zoom and its x axis *is* progress.
  Duration timeAtProgress(double progress) =>
      timeAt(progress.clamp(0.0, 1.0) * lengthInSamples);
}
