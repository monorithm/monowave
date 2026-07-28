import 'dart:math' as math;
import 'dart:typed_data';

import 'package:monowave/monowave.dart';
import 'package:test/test.dart';

const _spp = 128;
const _total = 44100; // one second

WaveformPeaks _source() => WaveformPeaks.fromSamples(
  Int16List.fromList([
    for (var i = 0; i < _total; i++)
      (math.sin(2 * math.pi * 440 * i / 44100) * 20000).round(),
  ]),
  sampleRate: 44100,
  baseSamplesPerPixel: _spp,
);

void main() {
  late WaveformPeaks source;
  late WaveformDocument document;

  setUp(() {
    source = _source();
    document = WaveformDocument.of(source);
  });

  test('the unedited document is the whole source in one region', () {
    expect(document.regions, hasLength(1));
    expect(document.lengthInSamples, _total);
    expect(document.sourceOf(0), 0);
    expect(document.sourceOf(_total - 1), _total - 1);
    expect(document.sourceOf(_total), isNull);
  });

  group('trim', () {
    test('keeps only the selection', () {
      final trimmed = document.applying(
        TrimEdit(WaveformSelection(10000, 20000)),
      );

      expect(trimmed.lengthInSamples, 10000);
      expect(trimmed.regions.single.sourceStart, 10000);
      // The output timeline restarts at zero while the source does not.
      expect(trimmed.sourceOf(0), 10000);
    });

    test('leaves the original untouched', () {
      document.applying(TrimEdit(WaveformSelection(0, 100)));

      expect(document.lengthInSamples, _total);
    });
  });

  group('delete', () {
    test('closes the gap, so the output is shorter than the source', () {
      final cut = document.applying(
        DeleteEdit(WaveformSelection(10000, 20000)),
      );

      expect(cut.lengthInSamples, _total - 10000);
      expect(cut.regions, hasLength(2));
      // Output sample 10000 is now what used to be at 20000.
      expect(cut.sourceOf(10000), 20000);
      expect(cut.sourceOf(9999), 9999);
    });

    test('removing from the head leaves one region', () {
      final cut = document.applying(DeleteEdit(WaveformSelection(0, 5000)));

      expect(cut.regions, hasLength(1));
      expect(cut.sourceOf(0), 5000);
    });

    test('two deletes compose', () {
      final cut = document
          .applying(DeleteEdit(WaveformSelection(10000, 20000)))
          .applying(DeleteEdit(WaveformSelection(0, 1000)));

      expect(cut.lengthInSamples, _total - 11000);
    });

    test('deleting everything leaves an empty document', () {
      final cut = document.applying(DeleteEdit(WaveformSelection(0, _total)));

      expect(cut.isEmpty, isTrue);
      expect(cut.sourceOf(0), isNull);
    });
  });

  test('split changes the region count but not the audio', () {
    final split = document.applying(const SplitEdit(20000));

    expect(split.regions, hasLength(2));
    expect(split.lengthInSamples, _total);
    expect(split.sourceOf(25000), 25000);
  });

  group('gain', () {
    test('applies only to the selected range', () {
      final adjusted = document.applying(
        GainEdit(WaveformSelection(10000, 20000), 0.5),
      );

      final scaled = adjusted.regions.where((r) => r.gain != 1.0).toList();
      expect(scaled, hasLength(1));
      expect(scaled.single.sourceStart, 10000);
      expect(scaled.single.sourceEnd, 20000);
      expect(
        adjusted.lengthInSamples,
        _total,
        reason: 'gain does not change length',
      );
    });

    test('compounds when applied twice', () {
      final quiet = document
          .applying(GainEdit(WaveformSelection(0, _total), 0.5))
          .applying(GainEdit(WaveformSelection(0, _total), 0.5));

      expect(quiet.regions.single.gain, closeTo(0.25, 1e-9));
    });
  });

  test('fade records its lengths on the selected region', () {
    final faded = document.applying(
      FadeEdit(WaveformSelection(0, 10000), fadeIn: 441, fadeOut: 441),
    );

    final region = faded.regions.first;
    expect(region.fadeIn, 441);
    expect(region.fadeOut, 441);
  });

  group('preview peaks', () {
    test('shorten with the edit and need no decoder', () {
      final trimmed = document.applying(
        TrimEdit(WaveformSelection(0, _total ~/ 2)),
      );

      final preview = trimmed.previewPeaks(source);

      expect(preview.lengthInSamples, _total ~/ 2);
      expect(preview.pairCount(0), lessThan(source.pairCount(0)));
      expect(preview.sampleRate, source.sampleRate);
    });

    test('reflect gain', () {
      final quiet = document.applying(
        GainEdit(WaveformSelection(0, _total), 0.25),
      );

      final loudest = source.view(source.levels - 1)[1];
      final preview = quiet.previewPeaks(source);
      final quieted = preview.view(preview.levels - 1)[1];

      expect(quieted, lessThan(loudest));
      expect(quieted, closeTo(loudest * 0.25, loudest * 0.05));
    });

    test('an empty document previews as silence rather than throwing', () {
      final cut = document.applying(DeleteEdit(WaveformSelection(0, _total)));

      expect(cut.previewPeaks(source).lengthInSamples, 0);
    });
  });

  group('history', () {
    test('undo and redo walk the stack', () {
      final history = EditHistory(document);

      history.apply(TrimEdit(WaveformSelection(0, 10000)));
      expect(history.current.lengthInSamples, 10000);
      expect(history.canUndo, isTrue);
      expect(history.canRedo, isFalse);

      history.undo();
      expect(history.current.lengthInSamples, _total);
      expect(history.canRedo, isTrue);

      history.redo();
      expect(history.current.lengthInSamples, 10000);
    });

    test('undoing past the start is a no-op, not a crash', () {
      final history = EditHistory(document)
        ..undo()
        ..undo();

      expect(history.current.lengthInSamples, _total);
      expect(history.canUndo, isFalse);
    });

    test('a new edit after an undo discards the redo branch', () {
      final history = EditHistory(document)
        ..apply(TrimEdit(WaveformSelection(0, 10000)))
        ..undo();

      expect(history.canRedo, isTrue);
      history.apply(TrimEdit(WaveformSelection(0, 20000)));

      expect(history.canRedo, isFalse);
      expect(history.current.lengthInSamples, 20000);
    });

    test('labels name what undo would reverse', () {
      final history = EditHistory(document)
        ..apply(TrimEdit(WaveformSelection(0, 10000)))
        ..apply(GainEdit(WaveformSelection(0, 5000), 0.5));

      expect(history.undoLabel, 'Gain');
      history.undo();
      expect(history.undoLabel, 'Trim');
      expect(history.redoLabel, 'Gain');
    });

    test('depth is bounded so long sessions do not grow forever', () {
      final history = EditHistory(document);

      for (var i = 0; i < EditHistory.maxDepth + 20; i++) {
        history.apply(GainEdit(WaveformSelection(0, _total), 0.999));
      }

      expect(history.depth, lessThanOrEqualTo(EditHistory.maxDepth));
      expect(history.canUndo, isTrue);
    });

    test('reset keeps the document and drops the history', () {
      final history = EditHistory(document)
        ..apply(TrimEdit(WaveformSelection(0, 10000)))
        ..reset();

      expect(history.current.lengthInSamples, 10000);
      expect(history.canUndo, isFalse);
    });
  });
}
