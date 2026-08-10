/// Test doubles for hosts that build on monowave.
///
/// The tests of a host must not need a microphone, an audio file, or the C
/// core. For this reason, every seam that monowave exposes has a fake here.
/// Import this library from `test/` only. It is deliberately not part of
/// `package:monowave/monowave.dart`.
library;

import 'dart:typed_data';

import 'dart:async';

import 'monowave.dart';

/// An in-memory [MonowavePlatform].
///
/// This fake records each request and answers with canned values. As a result,
/// a test asserts on the *request* and not on bytes that the test must decode.
class FakeMonowavePlatform implements MonowavePlatform {
  FakeMonowavePlatform({this.abi = 1});

  /// What [abiVersion] reports.
  int abi;

  /// Every window passed to [reduceMinMax], in order.
  final List<Int16List> reductions = [];

  /// If a test sets this field, [reduceMinMax] returns it and does not reduce
  /// the samples.
  MinMax? nextResult;

  /// How many times a caller awaited [ensureInitialized]. This count shows a
  /// host that loads the C core on every build instead of one time only.
  int initializeCount = 0;

  @override
  Future<void> ensureInitialized() async => initializeCount++;

  @override
  int abiVersion() => abi;

  @override
  MinMax reduceMinMax(Int16List samples) {
    reductions.add(samples);

    final canned = nextResult;
    if (canned != null) {
      nextResult = null;
      return canned;
    }
    if (samples.isEmpty) return (min: 0, max: 0);

    // Mirrors the C kernel so a host testing against the fake sees the same
    // shape of answer the real core gives.
    var lo = samples.first;
    var hi = samples.first;
    for (final s in samples) {
      if (s < lo) lo = s;
      if (s > hi) hi = s;
    }
    return (min: lo, max: hi);
  }

  /// The peaks that the decode methods return, keyed by path or by byte length.
  /// An input that is not in this map gets [defaultPeaks].
  final Map<Object, WaveformPeaks> decoded = {};

  /// If the input is not in [decoded], the decode returns this value. The
  /// default is two seconds of silence at 44.1 kHz.
  WaveformPeaks Function() defaultPeaks = () =>
      WaveformPeaks.fromSamples(Int16List(88200), sampleRate: 44100);

  /// Every path passed to [decodeFile], and every byte length passed to
  /// [decodeBytes], in order.
  final List<Object> decodeRequests = [];

  /// If a test sets this field, the next decode of either kind throws it.
  Object? nextDecodeError;

  @override
  Future<WaveformPeaks> decodeFile(
    String path, {
    int baseSamplesPerPixel = 128,
  }) async => _decode(path);

  @override
  Future<WaveformPeaks> decodeBytes(
    Uint8List bytes, {
    int baseSamplesPerPixel = 128,
  }) async => _decode(bytes.length);

  WaveformPeaks _decode(Object key) {
    decodeRequests.add(key);

    final error = nextDecodeError;
    if (error != null) {
      nextDecodeError = null;
      throw error;
    }

    return decoded[key] ?? defaultPeaks();
  }

  /// Every export requested, as (sourcePath, outputPath, document).
  final List<(String, String, WaveformDocument)> exports = [];

  /// If a test sets this field, the next export throws it.
  Object? nextExportError;

  @override
  Future<void> exportWav({
    required String sourcePath,
    required String outputPath,
    required WaveformDocument document,
  }) async {
    exports.add((sourcePath, outputPath, document));

    final error = nextExportError;
    if (error != null) {
      nextExportError = null;
      throw error;
    }
  }

  /// Every render requested, as (sourcePath, document).
  final List<(String, WaveformDocument)> renders = [];

  /// What [renderPcm] returns. The default is silence with one frame for each
  /// source frame that the document describes. As a result, a host can assert
  /// on the *length* with no need to synthesize audio.
  Int16List? nextRender;

  /// If a test sets this field, the next render throws it.
  Object? nextRenderError;

  @override
  Future<Int16List> renderPcm({
    required String sourcePath,
    required WaveformDocument document,
  }) async {
    renders.add((sourcePath, document));

    final error = nextRenderError;
    if (error != null) {
      nextRenderError = null;
      throw error;
    }

    final canned = nextRender;
    if (canned != null) {
      nextRender = null;
      return canned;
    }

    var frames = 0;
    for (final region in document.regions) {
      final length = region.sourceEnd - region.sourceStart;
      if (length > 0) frames += length;
    }
    return Int16List(frames);
  }

  /// Every byte-render requested, as (byteLength, document).
  final List<(int, WaveformDocument)> byteRenders = [];

  @override
  Future<Int16List> renderPcmBytes({
    required Uint8List bytes,
    required WaveformDocument document,
  }) async {
    byteRenders.add((bytes.length, document));
    return renderPcm(sourcePath: '${bytes.length} bytes', document: document);
  }

  /// The sessions that [openCapture] returns, newest last.
  final List<FakeCaptureSession> sessions = [];

  /// If a test sets this field, [openCapture] throws it and opens no session.
  Object? nextCaptureError;

  @override
  Future<CaptureSession> openCapture([
    CaptureConfig config = const CaptureConfig(),
  ]) async {
    final error = nextCaptureError;
    if (error != null) {
      nextCaptureError = null;
      throw error;
    }

    final session = FakeCaptureSession(config: config);
    sessions.add(session);
    return session;
  }

  /// The sessions that [openPlayback] returns, newest last.
  final List<FakePlaybackSession> playbacks = [];

  /// If a test sets this field, [openPlayback] throws it and opens no session.
  Object? nextPlaybackError;

  @override
  Future<PlaybackSession> openPlayback({
    required String sourcePath,
    required WaveformDocument document,
  }) async {
    final error = nextPlaybackError;
    if (error != null) {
      nextPlaybackError = null;
      throw error;
    }

    final session = FakePlaybackSession(document: document, sampleRate: 44100);
    playbacks.add(session);
    return session;
  }

  /// Every byte-playback requested, as (byteLength, document).
  final List<(int, WaveformDocument)> bytePlaybacks = [];

  @override
  Future<PlaybackSession> openPlaybackBytes({
    required Uint8List bytes,
    required WaveformDocument document,
  }) async {
    bytePlaybacks.add((bytes.length, document));
    return openPlayback(
      sourcePath: '${bytes.length} bytes',
      document: document,
    );
  }

  /// Installs this fake as the platform. Call [uninstall] in `tearDown`.
  void install() => MonowavePlatform.instance = this;

  static void uninstall() => MonowavePlatform.instance = null;
}

/// A [CaptureSession] that never touches a microphone.
///
/// This fake drives the same state as a real session: the recording flag, the
/// frame stream, the rolling scope and the drop counters. As a result, a widget
/// test can exercise the visualizer of a host. Frames arrive when a test calls
/// [emit] or [emitTone], and not when an audio thread produces them. This makes
/// the timing exact instead of merely likely.
///
/// [dispose] leaves the same values readable as the real session. [produced],
/// [dropped], [pcmDropped] and [truncated] answer after [dispose] and do not
/// throw. As a result, a UI that reads a counter during teardown behaves the
/// same here as it does against a microphone. The real session freezes its
/// counters at [dispose] to manage this, because the C struct that supplied
/// them is gone by then.
class FakeCaptureSession implements CaptureSession {
  FakeCaptureSession({this.config = const CaptureConfig()})
    : scope = CaptureScope(capacity: config.scopeCapacity);

  @override
  final CaptureConfig config;

  @override
  final CaptureScope scope;

  final StreamController<CaptureFrame> _frames =
      StreamController<CaptureFrame>.broadcast();

  /// Every frame emitted since construction.
  final List<CaptureFrame> emitted = [];

  /// What [stop] returns. The default is peaks from the frames that this fake
  /// emitted.
  WaveformPeaks? stopResult;

  /// If a test sets this field, [start] throws it.
  Object? nextStartError;

  int _dropped = 0;
  bool _recording = false;
  bool _disposed = false;

  @override
  Stream<CaptureFrame> get frames => _frames.stream;

  @override
  bool get isRecording => _recording;

  @override
  int get produced => emitted.length;

  @override
  int get dropped => _dropped;

  @override
  int get pcmDropped => 0;

  bool _paused = false;

  @override
  bool get isPaused => _paused;

  @override
  Future<void> pause() async => _paused = true;

  @override
  Future<void> resume() async => _paused = false;

  @override
  bool get truncated => false;

  int startCount = 0;
  int stopCount = 0;

  @override
  Future<void> start() async {
    if (_disposed) throw StateError('This capture session was disposed.');

    final error = nextStartError;
    if (error != null) {
      nextStartError = null;
      throw error;
    }

    startCount++;
    _recording = true;
  }

  /// Publishes one frame, exactly as a drain does.
  void emit(CaptureFrame frame) {
    emitted.add(frame);
    scope.add(frame);
    if (_frames.hasListener) _frames.add(frame);
  }

  /// Publishes [count] frames at a steady [amplitude] from 0 to 1.
  ///
  /// The usual way to make a fake visualizer show something.
  void emitTone(int count, {double amplitude = 0.5}) {
    final peak = (amplitude.clamp(0.0, 1.0) * 32767).round();
    for (var i = 0; i < count; i++) {
      emit((min: -peak, max: peak, rms: (peak * 0.707).round()));
    }
  }

  /// Simulates a consumer that falls behind.
  void dropFrames(int count) => _dropped += count;

  @override
  Future<WaveformPeaks> stop() async {
    stopCount++;
    _recording = false;

    final canned = stopResult;
    if (canned != null) return canned;

    if (emitted.isEmpty) {
      throw const CaptureUnavailable('Nothing was captured.');
    }

    final base = Int16List(emitted.length * 2);
    for (var i = 0; i < emitted.length; i++) {
      base[i * 2] = emitted[i].min;
      base[i * 2 + 1] = emitted[i].max;
    }

    return WaveformPeaks.fromInterleaved(
      base,
      sampleRate: config.sampleRate,
      baseSamplesPerPixel: config.hop,
      channels: config.channels,
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _recording = false;
    _paused = false;
    await _frames.close();
  }
}

/// A [PlaybackSession] that never opens an audio device.
///
/// The playhead moves when a test calls [advance], and not when a device
/// consumes frames. This makes the timing exact instead of merely likely.
/// [FakeCaptureSession] makes the same bargain for the frame stream.
///
/// This fake answers the same way as the real session at each point where a
/// host can see the difference. [position] never goes past [duration]. It never
/// moves backward, except on a [seek]. It answers after [dispose] and does not
/// throw.
class FakePlaybackSession implements PlaybackSession {
  FakePlaybackSession({required this.document, this.sampleRate = 44100});

  /// The rate that [duration] and [position] use.
  final int sampleRate;

  /// This field is mutable, like the rest of this fake. [setDocument] assigns
  /// it, and a test can also set it directly to stage an initial state.
  @override
  WaveformDocument document;

  /// Every seek requested, in order.
  final List<Duration> seeks = [];

  /// Every document that [setDocument] received, in order.
  final List<WaveformDocument> documents = [];

  int playCount = 0;
  int pauseCount = 0;

  /// If a test sets this field, [play] throws it.
  Object? nextPlayError;

  /// What [underruns] reports.
  int underrunCount = 0;

  Duration _position = Duration.zero;
  bool _playing = false;
  bool _disposed = false;

  @override
  Duration get duration => Duration(
    microseconds:
        (document.lengthInSamples * Duration.microsecondsPerSecond / sampleRate)
            .round(),
  );

  @override
  Duration get position => _position;

  @override
  bool get isPlaying => _playing;

  @override
  bool get isFinished => _position >= duration;

  @override
  int get underruns => underrunCount;

  @override
  Future<void> play() async {
    if (_disposed) throw StateError('This playback session was disposed.');

    final error = nextPlayError;
    if (error != null) {
      nextPlayError = null;
      throw error;
    }

    playCount++;
    _playing = true;
  }

  @override
  Future<void> pause() async {
    if (_disposed) throw StateError('This playback session was disposed.');
    pauseCount++;
    _playing = false;
  }

  @override
  Future<void> seek(Duration position) async {
    if (_disposed) throw StateError('This playback session was disposed.');

    seeks.add(position);
    _position = position < Duration.zero
        ? Duration.zero
        : (position > duration ? duration : position);
  }

  @override
  Future<void> setDocument(WaveformDocument document) async {
    if (_disposed) throw StateError('This playback session was disposed.');

    documents.add(document);
    this.document = document;

    // The playhead keeps its output position and clamps to the new end, which
    // is what the real session does.
    if (_position > duration) _position = duration;
  }

  /// Moves the playhead, as a device that consumes frames does. The playhead
  /// stops at the end.
  void advance(Duration by) {
    final next = _position + by;
    _position = next > duration ? duration : next;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _playing = false;
  }
}
