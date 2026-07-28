import 'dart:typed_data';

import 'package:monowave/monowave.dart';
import 'package:test/test.dart';

WaveformPeaks _peaks({int samples = 4096, int base = 64}) =>
    WaveformPeaks.fromSamples(
      Int16List.fromList([for (var i = 0; i < samples; i++) i % 1000 - 500]),
      sampleRate: 44100,
      baseSamplesPerPixel: base,
    );

void main() {
  group('coordinates', () {
    const viewport = WaveformViewport(
      startSample: 1000,
      samplesPerPixel: 10,
      widthPx: 300,
    );

    test('xForSample and sampleAtX invert each other', () {
      for (final x in [0.0, 37.5, 150.0, 299.0]) {
        expect(viewport.xForSample(viewport.sampleAtX(x)), closeTo(x, 1e-9));
      }
    });

    test('the left edge is x=0 and the right edge is the width', () {
      expect(viewport.xForSample(1000), 0);
      expect(viewport.xForSample(viewport.endSample), closeTo(300, 1e-9));
      expect(viewport.sampleSpan, 3000);
    });

    test('fitted shows the whole file exactly once', () {
      final peaks = _peaks();
      final fitted = WaveformViewport.fitted(peaks, 500);

      expect(fitted.startSample, 0);
      expect(fitted.endSample, closeTo(peaks.lengthInSamples.toDouble(), 1e-9));
    });
  });

  group('zoom', () {
    const viewport = WaveformViewport(
      startSample: 1000,
      samplesPerPixel: 10,
      widthPx: 300,
    );

    test('keeps the sample under the focus point pinned', () {
      // What makes a pinch feel attached to the audio rather than the widget.
      for (final focus in [0.0, 75.0, 150.0, 300.0]) {
        final anchored = viewport.sampleAtX(focus);

        for (final factor in [0.25, 0.5, 2.0, 8.0]) {
          final zoomed = viewport.zoomedAt(focus, factor);
          expect(
            zoomed.sampleAtX(focus),
            closeTo(anchored, 1e-6),
            reason: 'focus $focus factor $factor drifted',
          );
        }
      }
    });

    test('a factor above 1 zooms in', () {
      expect(viewport.zoomedAt(150, 2).samplesPerPixel, 5);
      expect(viewport.zoomedAt(150, 0.5).samplesPerPixel, 20);
    });

    test('rejects a non-positive factor', () {
      expect(() => viewport.zoomedAt(0, 0), throwsArgumentError);
      expect(() => viewport.zoomedAt(0, -1), throwsArgumentError);
    });
  });

  test('panning moves by whole pixels of content', () {
    const viewport = WaveformViewport(
      startSample: 1000,
      samplesPerPixel: 10,
      widthPx: 300,
    );

    expect(viewport.pannedBy(10).startSample, 1100);
    expect(viewport.pannedBy(-10).startSample, 900);
  });

  group('clampedTo', () {
    test('cannot scroll past either end', () {
      final peaks = _peaks();

      final left = const WaveformViewport(
        startSample: -5000,
        samplesPerPixel: 4,
        widthPx: 200,
      ).clampedTo(peaks);
      expect(left.startSample, 0);

      final right = const WaveformViewport(
        startSample: 99999,
        samplesPerPixel: 4,
        widthPx: 200,
      ).clampedTo(peaks);
      expect(right.endSample, closeTo(peaks.lengthInSamples.toDouble(), 1e-9));
    });

    test('cannot zoom out past the whole file', () {
      final peaks = _peaks();

      final clamped = const WaveformViewport(
        startSample: 0,
        samplesPerPixel: 1e9,
        widthPx: 200,
      ).clampedTo(peaks);

      expect(
        clamped.sampleSpan,
        closeTo(peaks.lengthInSamples.toDouble(), 1e-6),
      );
    });

    test('cannot zoom in past the finest level held', () {
      // Long enough that fitting the file is coarser than the finest level, so
      // the finest-level bound is the one that binds.
      final peaks = _peaks(samples: 64000, base: 64);

      final clamped = const WaveformViewport(
        startSample: 0,
        samplesPerPixel: 0.01,
        widthPx: 200,
      ).clampedTo(peaks);

      expect(clamped.samplesPerPixel, 64);
    });

    test('a file shorter than one screen still fits rather than overflowing', () {
      // Both bounds cannot hold at once here; fitting the file has to win, or a
      // short voice note would be drawn partly off the right edge.
      final peaks = _peaks(samples: 256, base: 64);

      final clamped = const WaveformViewport(
        startSample: 0,
        samplesPerPixel: 1,
        widthPx: 800,
      ).clampedTo(peaks);

      expect(clamped.startSample, 0);
      expect(clamped.sampleSpan, closeTo(256, 1e-6));
    });
  });

  group('resolve', () {
    test('covers the full visible width when the audio spans it', () {
      final peaks = _peaks();
      const viewport = WaveformViewport(
        startSample: 500,
        samplesPerPixel: 10,
        widthPx: 300,
      );

      final window = viewport.resolve(peaks);
      final right =
          window.xOfFirstPair + window.pairCount * window.pixelsPerPair;

      // Snapped outward, so it starts at or left of 0 and ends at or right of
      // the width. Anything narrower would leave a gap at an edge while panning.
      expect(window.xOfFirstPair, lessThanOrEqualTo(0));
      expect(right, greaterThanOrEqualTo(300));
    });

    test('stops at the end of the audio rather than padding to the width', () {
      // A viewport zoomed out past the file is legitimate - there is simply
      // nothing to draw on the right. The painter must not assume a full width.
      final peaks = _peaks(samples: 4096, base: 64);
      const viewport = WaveformViewport(
        startSample: 0,
        samplesPerPixel: 100,
        widthPx: 300,
      );

      final window = viewport.resolve(peaks);
      final right =
          window.xOfFirstPair + window.pairCount * window.pixelsPerPair;

      expect(window.pairCount, peaks.pairCount(window.level));
      expect(right, lessThan(300));
      expect(right, closeTo(viewport.xForSample(4096), 1e-6));
    });

    test('picks a level no coarser than the requested zoom', () {
      final peaks = _peaks(base: 64);

      for (final spp in [64.0, 130.0, 700.0]) {
        final window = WaveformViewport(
          startSample: 0,
          samplesPerPixel: spp,
          widthPx: 200,
        ).resolve(peaks);

        expect(peaks.samplesPerPixel(window.level), lessThanOrEqualTo(spp));
      }
    });

    test('reads the same values the level holds', () {
      final peaks = _peaks();
      const viewport = WaveformViewport(
        startSample: 0,
        samplesPerPixel: 64,
        widthPx: 10,
      );

      final window = viewport.resolve(peaks);
      final level = peaks.view(window.level);

      for (var i = 0; i < window.pairCount; i++) {
        expect(window.minAt(i), level[(window.firstPair + i) * 2]);
        expect(window.maxAt(i), level[(window.firstPair + i) * 2 + 1]);
      }
    });

    test('is empty when scrolled entirely off the audio', () {
      final peaks = _peaks();

      final window = const WaveformViewport(
        startSample: 1e9,
        samplesPerPixel: 64,
        widthPx: 200,
      ).resolve(peaks);

      expect(window.isEmpty, isTrue);
    });
  });
}
