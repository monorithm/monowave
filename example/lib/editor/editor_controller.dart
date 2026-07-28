import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:monowave/monowave.dart';

/// Everything the editor screen holds.
///
/// A [ChangeNotifier] rather than anything larger: the point of the example is
/// to show how little a host has to keep. monowave holds none of it — peaks are
/// values, a document is a list of ranges, and undo is a stack of documents.
class EditorController extends ChangeNotifier {
  EditorController({required this.source, required WaveformPeaks peaks})
    : _peaks = peaks,
      history = EditHistory(WaveformDocument.of(peaks));

  /// The file the export reads from. Never modified.
  final String source;

  final WaveformPeaks _peaks;
  final EditHistory history;

  WaveformSelection? selection;
  Duration position = Duration.zero;
  String? exportedTo;
  String? error;

  WaveformDocument get document => history.current;

  /// Peaks for the current edit, derived from the source without decoding.
  ///
  /// Cached because it is rebuilt on every notification and a scrub notifies
  /// sixty times a second.
  WaveformPeaks get peaks => _preview ??= _derive();
  WaveformPeaks? _preview;

  WaveformPeaks _derive() {
    final regions = document.regions;
    final untouched =
        regions.length == 1 &&
        regions.single.sourceStart == 0 &&
        regions.single.sourceEnd == _peaks.lengthInSamples &&
        regions.single.gain == 1.0;
    return untouched ? _peaks : document.previewPeaks(_peaks);
  }

  WaveformTimeline get timeline => WaveformTimeline.of(peaks);
  Duration get duration => timeline.duration;

  bool get canUndo => history.canUndo;
  bool get hasSelection => selection != null && !selection!.isEmpty;

  void select(WaveformSelection? next) {
    selection = next;
    notifyListeners();
  }

  /// Snaps both edges to the least audible nearby point.
  ///
  /// On release rather than during the drag: edges moving under the finger
  /// make a gesture feel unreliable.
  void settleSelection() {
    final current = selection;
    if (current == null || current.isEmpty) return;

    selection = WaveformSelection(
      WaveformSnap.toQuietest(peaks, current.start),
      WaveformSnap.toQuietest(peaks, current.end),
    ).clampedTo(peaks);
    notifyListeners();
  }

  void seek(Duration to) {
    final total = duration;
    position = to < Duration.zero ? Duration.zero : (to > total ? total : to);
    notifyListeners();
  }

  void apply(WaveformEdit edit) {
    history.apply(edit);
    _invalidate();
  }

  void undo() {
    history.undo();
    _invalidate();
  }

  void _invalidate() {
    _preview = null;
    selection = null;
    position = Duration.zero;
    exportedTo = null;
    error = null;
    notifyListeners();
  }

  Future<String?> export() async {
    if (document.isEmpty) {
      error = 'Nothing to export.';
      notifyListeners();
      return null;
    }

    try {
      final out =
          '${Directory.systemTemp.path}/monowave-export-'
          '${DateTime.now().millisecondsSinceEpoch}.wav';
      await MonowavePlatform.instance.exportWav(
        sourcePath: source,
        outputPath: out,
        document: document,
      );
      exportedTo = out;
      error = null;
      notifyListeners();
      return out;
    } on Object catch (failure) {
      error = failure.toString();
      notifyListeners();
      return null;
    }
  }
}
