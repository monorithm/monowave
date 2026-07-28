import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
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
  String? exportedTo;
  String? error;

  /// Playback lives entirely in the host.
  ///
  /// monowave never sees the player — `WaveformTimeline` maps a `Duration` to a
  /// sample and back, and that is the whole of its relationship with playback.
  /// Swapping `just_audio` for `media_kit` would touch this file and nothing
  /// else.
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<Duration>? _positions;
  StreamSubscription<PlayerState>? _states;

  Duration position = Duration.zero;
  bool get isPlaying => _player.playing;

  /// What the player currently has loaded, so an unchanged edit does not
  /// re-export on every play.
  String? _loaded;
  bool _preparing = false;
  bool get isPreparing => _preparing;

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
  bool get canRedo => history.canRedo;
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
    _player.seek(position);
    notifyListeners();
  }

  /// Plays what the document currently describes.
  ///
  /// An edited document has no file behind it — the edit list is the only
  /// record of it — so previewing one means rendering it first. That is the
  /// same exporter the Export button uses, which is what makes the preview
  /// trustworthy rather than an approximation.
  Future<void> togglePlay() async {
    if (_player.playing) {
      await _player.pause();
      notifyListeners();
      return;
    }

    final wanted =
        document.regions.length == 1 &&
            document.regions.single.sourceStart == 0 &&
            document.regions.single.gain == 1.0 &&
            document.regions.single.fadeIn == 0
        ? source
        : await _render();
    if (wanted == null) return;

    try {
      if (_loaded != wanted) {
        await _player.setFilePath(wanted);
        _loaded = wanted;
        _listen();
      }
      if (position >= duration) position = Duration.zero;
      await _player.seek(position);
      await _player.play();
    } on Object catch (failure) {
      error = 'Could not play it back: $failure';
    }
    notifyListeners();
  }

  /// Renders the current document to a temporary file for preview.
  Future<String?> _render() async {
    _preparing = true;
    notifyListeners();
    try {
      final out =
          '${Directory.systemTemp.path}/monowave-preview-'
          '${document.hashCode}-${document.lengthInSamples}.wav';
      if (!File(out).existsSync()) {
        await MonowavePlatform.instance.exportWav(
          sourcePath: source,
          outputPath: out,
          document: document,
        );
      }
      return out;
    } on Object catch (failure) {
      error = failure.toString();
      return null;
    } finally {
      _preparing = false;
    }
  }

  void _listen() {
    _positions?.cancel();
    _states?.cancel();
    _positions = _player.positionStream.listen((at) {
      position = at;
      notifyListeners();
    });
    _states = _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        _player.pause();
        _player.seek(Duration.zero);
        position = Duration.zero;
      }
      notifyListeners();
    });
  }

  void apply(WaveformEdit edit) {
    history.apply(edit);
    _invalidate();
  }

  void undo() {
    history.undo();
    _invalidate();
  }

  void redo() {
    history.redo();
    _invalidate();
  }

  void _invalidate() {
    _preview = null;
    selection = null;
    position = Duration.zero;
    exportedTo = null;
    error = null;
    // The document changed, so whatever the player holds is now stale.
    _player.pause();
    _loaded = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _positions?.cancel();
    _states?.cancel();
    _player.dispose();
    super.dispose();
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
