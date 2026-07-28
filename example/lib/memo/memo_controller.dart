import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:monowave/monowave.dart';
import 'package:permission_handler/permission_handler.dart';

import '../fixtures.dart';

/// What the screen is doing.
enum MemoStage {
  /// Nothing recorded yet.
  idle,

  /// The microphone was refused. The only state with no way forward inside the
  /// app.
  denied,

  /// Capturing.
  recording,

  /// Something was captured or loaded, and can be played, trimmed, exported.
  review,
}

/// The whole app's state, in one place.
///
/// A [ChangeNotifier] rather than anything larger: this is an example, and the
/// point is to show what a host has to hold, which is not much. monowave itself
/// holds none of it.
class MemoController extends ChangeNotifier {
  MemoStage stage = MemoStage.idle;
  String? error;

  CaptureSession? _session;
  Timer? _clock;
  String? _takePath;

  /// The peaks currently on screen — captured, or the bundled sample.
  WaveformPeaks? peaks;
  WaveformTimeline? timeline;

  /// Where the source lives, so an export has something to read.
  String? sourcePath;

  EditHistory? history;
  WaveformSelection? selection;

  /// Playback position. Driven by a clock, since the example plays no audio.
  Duration position = Duration.zero;
  bool isPlaying = false;
  Timer? _playback;

  String? exportedTo;

  CaptureScope? get scope => _session?.scope;
  Duration get elapsed =>
      Duration(milliseconds: (_session?.produced ?? 0) * 512 * 1000 ~/ 44100);
  int get dropped => _session?.dropped ?? 0;
  int get pcmDropped => _session?.pcmDropped ?? 0;

  WaveformDocument? get document => history?.current;

  /// Peaks reflecting the current edit, without decoding anything.
  WaveformPeaks? get visiblePeaks {
    final source = peaks;
    final document = history?.current;
    if (source == null) return null;
    if (document == null ||
        document.regions.length == 1 &&
            document.regions.first.sourceStart == 0 &&
            document.regions.first.sourceEnd == source.lengthInSamples) {
      return source;
    }
    return document.previewPeaks(source);
  }

  Duration get duration {
    final visible = visiblePeaks;
    if (visible == null) return Duration.zero;
    return WaveformTimeline.of(visible).duration;
  }

  Future<void> start() async {
    error = null;
    exportedTo = null;

    // monowave never asks for this: a headless package has no UI to explain
    // why it is asking. The host does, so the host asks.
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      stage = MemoStage.denied;
      notifyListeners();
      return;
    }

    try {
      // Recording to a file is what makes a take trimmable and exportable.
      // The audio thread never touches the filesystem; it fills a second ring
      // and this side drains it.
      _takePath =
          '${Directory.systemTemp.path}/monowave-take-${DateTime.now().millisecondsSinceEpoch}.wav';
      final session = await MonowavePlatform.instance.openCapture(
        CaptureConfig(recordTo: _takePath),
      );
      await session.start();
      _session = session;
      stage = MemoStage.recording;

      // The scope mutates in place, so something has to drive repaints.
      _clock = Timer.periodic(
        const Duration(milliseconds: 33),
        (_) => notifyListeners(),
      );
    } on CaptureUnavailable catch (failure) {
      error = failure.message;
      stage = MemoStage.idle;
    }

    notifyListeners();
  }

  Future<void> stop() async {
    final session = _session;
    if (session == null) return;

    _clock?.cancel();
    _clock = null;

    try {
      final captured = await session.stop();
      _adopt(captured, _takePath);
    } on CaptureUnavailable catch (failure) {
      error = failure.message;
      stage = MemoStage.idle;
    } finally {
      await session.dispose();
      _session = null;
    }

    notifyListeners();
  }

  /// Loads the bundled sample, so playback and trimming can be tried without
  /// recording anything first.
  Future<void> loadSample() async {
    error = null;
    _adopt(Fixtures.peaks, await Fixtures.sourceFile());
    notifyListeners();
  }

  void _adopt(WaveformPeaks captured, String? path) {
    peaks = captured;
    timeline = WaveformTimeline.of(captured);
    history = EditHistory(WaveformDocument.of(captured));
    selection = null;
    position = Duration.zero;
    sourcePath = path;
    stage = MemoStage.review;
  }

  void applyEdit(WaveformEdit edit) {
    history?.apply(edit);
    selection = null;
    position = Duration.zero;
    exportedTo = null;
    notifyListeners();
  }

  void undo() {
    history?.undo();
    selection = null;
    exportedTo = null;
    notifyListeners();
  }

  void select(WaveformSelection? next) {
    selection = next;
    notifyListeners();
  }

  void seek(Duration to) {
    final total = duration;
    position = to < Duration.zero ? Duration.zero : (to > total ? total : to);
    notifyListeners();
  }

  void togglePlay() {
    if (isPlaying) {
      _playback?.cancel();
      _playback = null;
      isPlaying = false;
    } else {
      if (position >= duration) position = Duration.zero;
      isPlaying = true;
      _playback = Timer.periodic(const Duration(milliseconds: 16), (_) {
        position += const Duration(milliseconds: 16);
        if (position >= duration) {
          position = duration;
          togglePlay();
        }
        notifyListeners();
      });
    }
    notifyListeners();
  }

  Future<void> export() async {
    final source = sourcePath;
    final document = history?.current;
    if (source == null || document == null || document.isEmpty) {
      error = 'Nothing to export.';
      notifyListeners();
      return;
    }

    try {
      final out =
          '${Directory.systemTemp.path}/monowave-export-${document.regions.length}.wav';
      await MonowavePlatform.instance.exportWav(
        sourcePath: source,
        outputPath: out,
        document: document,
      );
      exportedTo = out;
      error = null;
    } on Object catch (failure) {
      error = failure.toString();
    }
    notifyListeners();
  }

  void reset() {
    _clock?.cancel();
    _playback?.cancel();
    _session?.dispose();
    _session = null;
    peaks = null;
    history = null;
    selection = null;
    sourcePath = null;
    exportedTo = null;
    error = null;
    isPlaying = false;
    position = Duration.zero;
    stage = MemoStage.idle;
    notifyListeners();
  }

  @override
  void dispose() {
    _clock?.cancel();
    _playback?.cancel();
    _session?.dispose();
    super.dispose();
  }
}
