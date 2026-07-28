import 'dart:math' as math;
import 'dart:typed_data';

import 'package:monowave/monowave.dart';
import 'package:test/test.dart';

const _spp = 128;

WaveformPeaks _peaks(Int16List samples) => WaveformPeaks.fromSamples(
  samples,
  sampleRate: 44100,
  baseSamplesPerPixel: _spp,
);

void main() {
  group('selection', () {
    test('normalizes a backwards range', () {
      expect(WaveformSelection(900, 100), WaveformSelection(100, 900));
      expect(WaveformSelection(900, 100).start, 100);
    });

    test('a collapsed selection is empty', () {
      expect(WaveformSelection.at(500).isEmpty, isTrue);
      expect(WaveformSelection.at(500).length, 0);
      expect(WaveformSelection.empty.isEmpty, isTrue);
    });

    test('extending keeps the anchor and survives crossing it', () {
      final selection = WaveformSelection.at(1000);

      expect(selection.extendedTo(1500), WaveformSelection(1000, 1500));
      // Dragging left past the anchor must not invert the range.
      expect(selection.extendedTo(200), WaveformSelection(200, 1000));
    });

    test('a handle drag moves the nearer edge', () {
      final range = WaveformSelection(1000, 2000);

      expect(range.withNearestEdgeAt(1100), WaveformSelection(1100, 2000));
      expect(range.withNearestEdgeAt(1900), WaveformSelection(1000, 1900));
    });

    test('shifting preserves length', () {
      final shifted = WaveformSelection(100, 400).shiftedBy(50);

      expect(shifted, WaveformSelection(150, 450));
      expect(shifted.length, 300);
    });

    test('clamping keeps a selection inside the audio', () {
      final peaks = _peaks(Int16List(4096));

      expect(
        WaveformSelection(-500, 999999).clampedTo(peaks),
        WaveformSelection(0, 4096),
      );
    });

    test('reports its duration against a timeline', () {
      const timeline = WaveformTimeline(
        sampleRate: 44100,
        lengthInSamples: 441000,
      );

      expect(
        WaveformSelection(0, 44100).durationIn(timeline),
        const Duration(seconds: 1),
      );
    });

    test('contains is half-open, so adjacent selections do not overlap', () {
      final selection = WaveformSelection(100, 200);

      expect(selection.contains(100), isTrue);
      expect(selection.contains(199), isTrue);
      expect(selection.contains(200), isFalse);
    });
  });

  group('snapping', () {
    test('finds a bucket whose extremes straddle zero', () {
      final samples = Int16List.fromList([
        for (var i = 0; i < 4096; i++)
          (math.sin(2 * math.pi * i / 32) * 20000).round(),
      ]);

      final snapped = WaveformSnap.toZeroCrossing(_peaks(samples), 1000);

      expect(snapped % _spp, 0, reason: 'snaps to a bucket boundary');
      expect((snapped - 1000).abs(), lessThanOrEqualTo(_spp));
    });

    test('skips buckets that sit entirely on one side of zero', () {
      // A large DC offset never crosses zero, so there is nothing to snap to
      // and the input must come back unchanged.
      final samples = Int16List.fromList(List.filled(4096, 12000));

      expect(WaveformSnap.toZeroCrossing(_peaks(samples), 1000), 1000);
    });

    test('quietest finds the silence between bursts', () {
      final samples = Int16List(4096);
      for (var i = 0; i < 4096; i++) {
        final inGap = i >= 1536 && i < 2048;
        samples[i] = inGap ? 0 : (math.sin(i / 4) * 25000).round();
      }

      final snapped = WaveformSnap.toQuietest(_peaks(samples), 1300);

      expect(snapped, greaterThanOrEqualTo(1536));
      expect(snapped, lessThan(2048));
    });

    test('ties go to the nearer bucket', () {
      final snapped = WaveformSnap.toQuietest(_peaks(Int16List(4096)), 1000);

      expect((snapped - 1000).abs(), lessThanOrEqualTo(_spp));
    });

    test('respects the search radius instead of scanning the file', () {
      final samples = Int16List(44100 * 10);
      for (var i = 0; i < samples.length; i++) {
        samples[i] = 12000; // never quiet
      }
      samples.setRange(
        0,
        256,
        List.filled(256, 0),
      ); // one quiet patch, far away

      final snapped = WaveformSnap.toQuietest(
        _peaks(samples),
        400000,
        searchRadius: 2048,
      );

      expect((snapped - 400000).abs(), lessThanOrEqualTo(2048 + _spp));
    });
  });
}
