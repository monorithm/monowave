// The claim the mipmap exists to support, as a test rather than an assertion in
// prose: the cost of preparing a frame is bounded by screen pixels, not by how
// long the recording is.
//
// If this ever fails, zooming a long file has started re-reading data instead
// of picking a level, and the whole pyramid is pointless.

import 'dart:typed_data';

import 'package:monowave/monowave.dart';
import 'package:test/test.dart';

const _sampleRate = 44100;
const _base = 128;
const _hours = 3;
const _totalSamples = _sampleRate * 60 * 60 * _hours; // 476,280,000

/// A realistic three-hour pyramid, built without a 952 MB sample buffer.
///
/// The base level is synthesized directly - 3.7 million min/max pairs, about
/// 15 MB - because reducing half a billion samples in Dart would measure the
/// test harness rather than the thing under test.
WaveformPeaks _threeHours() {
  final pairs = _totalSamples ~/ _base;
  final base = Int16List(pairs * 2);

  for (var pair = 0; pair < pairs; pair++) {
    // A slow amplitude sweep, so different levels hold genuinely different
    // values and a broken level lookup would show up as wrong output, not just
    // slow output.
    final envelope = (pair % 100000) / 100000;
    final amplitude = (envelope * 30000).round();
    base[pair * 2] = -amplitude;
    base[pair * 2 + 1] = amplitude;
  }

  return WaveformPeaks.fromInterleaved(
    base,
    sampleRate: _sampleRate,
    baseSamplesPerPixel: _base,
    // Three hours is not a whole number of 128-sample buckets, so the true
    // length has to be stated rather than inferred from the pair count. A real
    // file has the same partial final bucket.
    lengthInSamples: _totalSamples,
  );
}

void main() {
  late WaveformPeaks peaks;

  setUpAll(() => peaks = _threeHours());
  tearDownAll(() => peaks.dispose());

  test('a three-hour pyramid is built and is deep', () {
    expect(peaks.lengthInSamples, _totalSamples);
    expect(peaks.pairCount(0), _totalSamples ~/ _base);
    expect(peaks.pairCount(0) * _base, lessThan(_totalSamples));
    // Halving 3.7M pairs down to one takes about 22 levels.
    expect(peaks.levels, greaterThan(20));
    expect(WaveformTimeline.of(peaks).duration.inMinutes, 180);
  });

  test('resolve is bounded by pixels, not by file length', () {
    const width = 1200.0;

    // The whole file on screen, down to one screen of samples.
    final zooms = <double>[
      _totalSamples / width, // fully zoomed out
      100000,
      10000,
      1000,
      _base.toDouble(), // fully zoomed in
    ];

    for (final spp in zooms) {
      final viewport = WaveformViewport(
        startSample: _totalSamples / 3,
        samplesPerPixel: spp,
        widthPx: width,
      ).clampedTo(peaks);

      final window = viewport.resolve(peaks);

      // The point of the mipmap: never more pairs than there are pixels to
      // draw them in, whatever the zoom. Two per pixel is the snapping slack.
      expect(
        window.pairCount,
        lessThanOrEqualTo(width.toInt() * 2),
        reason:
            'at $spp samples/pixel the window held ${window.pairCount} '
            'pairs for $width pixels - the level lookup is not working',
      );
    }
  });

  test('a full zoom sweep stays inside a frame budget', () {
    const width = 1200.0;
    const frames = 600; // ten seconds at 60fps

    var viewport = WaveformViewport.fitted(peaks, width).clampedTo(peaks);
    var totalPairs = 0;

    final stopwatch = Stopwatch()..start();
    for (var frame = 0; frame < frames; frame++) {
      // Zoom in steadily, as a pinch would, and read every pair the painter
      // would read.
      viewport = viewport.zoomedAt(width / 2, 1.02).clampedTo(peaks);

      final window = viewport.resolve(peaks);
      for (var i = 0; i < window.pairCount; i++) {
        // The peak-to-peak span, not the sum: the fixture is symmetric, so
        // min + max is exactly zero and would defeat the guard below.
        totalPairs += window.maxAt(i) - window.minAt(i);
      }
    }
    stopwatch.stop();

    final perFrame = stopwatch.elapsedMicroseconds / frames;

    // A 60fps frame is 16,667 microseconds, and this is only the data half of
    // it. 2,000 is a deliberately loose ceiling: it is well inside budget while
    // leaving room for slower CI hardware, and it would still catch a
    // regression to scanning the base level (which would be ~1000x worse).
    expect(
      perFrame,
      lessThan(2000),
      reason:
          '${perFrame.toStringAsFixed(1)}us per frame resolving a '
          'three-hour pyramid; a 60fps budget is 16667us',
    );
    expect(
      totalPairs,
      isNot(0),
      reason:
          'guards against the loop being '
          'optimized away',
    );
  });

  test('panning a long file allocates no new peak data', () {
    const width = 1200.0;
    final viewport = WaveformViewport(
      startSample: 0,
      samplesPerPixel: 5000,
      widthPx: width,
    );

    // Every window at a given zoom views the same underlying level buffer;
    // panning changes an offset, not the data.
    final first = viewport.resolve(peaks);
    final later = viewport.pannedBy(100000).resolve(peaks);

    expect(identical(first.peaks, later.peaks), isTrue);
    expect(first.level, later.level);
    expect(first.firstPair, isNot(later.firstPair));
  });

  test('snapping near the end of a long file is still fast', () {
    // Snapping searches the finest level, so it must not degrade with length.
    final stopwatch = Stopwatch()..start();
    final snapped = WaveformSnap.toQuietest(peaks, _totalSamples - 100000);
    stopwatch.stop();

    expect(stopwatch.elapsedMilliseconds, lessThan(50));
    expect(snapped, greaterThan(0));
  });
}
