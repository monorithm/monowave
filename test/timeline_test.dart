import 'package:monowave/monowave.dart';
import 'package:test/test.dart';

void main() {
  const timeline = WaveformTimeline(sampleRate: 44100, lengthInSamples: 441000);

  test('reports the duration the sample count implies', () {
    expect(timeline.duration, const Duration(seconds: 10));
  });

  test('time and sample invert each other', () {
    for (final seconds in [0, 1, 5, 9]) {
      final time = Duration(seconds: seconds);
      expect(timeline.timeAt(timeline.sampleAt(time)), time);
    }
  });

  test('clamps rather than running off either end', () {
    expect(timeline.sampleAt(const Duration(seconds: -5)), 0);
    expect(timeline.sampleAt(const Duration(seconds: 60)), 441000);
    expect(timeline.timeAt(-100), Duration.zero);
    expect(timeline.timeAt(1e9), const Duration(seconds: 10));
  });

  test('progress runs 0 to 1 across the audio', () {
    expect(timeline.progressAt(Duration.zero), 0);
    expect(timeline.progressAt(const Duration(seconds: 5)), closeTo(0.5, 1e-9));
    expect(timeline.progressAt(const Duration(seconds: 10)), 1);
  });

  test('progress maps back to time — the fixed-bar voice note case', () {
    expect(timeline.timeAtProgress(0.25), const Duration(milliseconds: 2500));
    expect(timeline.timeAtProgress(-1), Duration.zero);
    expect(timeline.timeAtProgress(2), const Duration(seconds: 10));
  });

  test('a zero sample rate degrades quietly instead of dividing by zero', () {
    const broken = WaveformTimeline(sampleRate: 0, lengthInSamples: 100);

    expect(broken.duration, Duration.zero);
    expect(broken.sampleAt(const Duration(seconds: 1)), 0);
    expect(broken.timeAt(50), Duration.zero);
  });
}
