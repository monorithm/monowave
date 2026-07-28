/// Test doubles for hosts that build on monowave.
///
/// A host's tests should not need a microphone, an audio file, or a native
/// core, so every seam monowave exposes has a fake here. Import this from
/// `test/` only - it is deliberately not part of
/// `package:monowave/monowave.dart`.
library;

import 'dart:typed_data';

import 'dart:async';

import 'monowave.dart';

/// An in-memory [MonowavePlatform].
///
/// Records what it was asked to do and answers from canned values, so a test
/// asserts on the *request* rather than on bytes it would have to decode.
class FakeMonowavePlatform implements MonowavePlatform {
  FakeMonowavePlatform({this.abi = 1});

  /// What [abiVersion] reports.
  int abi;

  /// Every window passed to [reduceMinMax], in order.
  final List<Int16List> reductions = [];

  /// When set, [reduceMinMax] returns this instead of reducing.
  MinMax? nextResult;

  /// How many times [ensureInitialized] was awaited. A host that loads on every
  /// build rather than once will show up here.
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

  /// Peaks handed back by the decode methods, keyed by path or by byte length.
  /// Unregistered inputs get [defaultPeaks].
  final Map<Object, WaveformPeaks> decoded = {};

  /// What an unregistered decode returns: two seconds of silence at 44.1 kHz.
  WaveformPeaks Function() defaultPeaks = () =>
      WaveformPeaks.fromSamples(Int16List(88200), sampleRate: 44100);

  /// Every path passed to [decodeFile], and every byte length passed to
  /// [decodeBytes], in order.
  final List<Object> decodeRequests = [];

  /// When set, the next decode of either kind throws this instead.
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

  /// When set, the next export throws this instead.
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

  /// Sessions handed back by [openCapture], newest last.
  final List<FakeCaptureSession> sessions = [];

  /// When set, [openCapture] throws this instead of opening.
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

  /// Installs this as the platform. Call [uninstall] in `tearDown`.
  void install() => MonowavePlatform.instance = this;

  static void uninstall() => MonowavePlatform.instance = null;
}

/// A [CaptureSession] that never touches a microphone.
///
/// Drives the same state a real session does - recording flag, frame stream,
/// rolling scope, drop counters - so a host's visualizer can be exercised in a
/// widget test. Frames arrive when a test calls [emit] or [emitTone] rather
/// than when an audio thread produces them, which makes the timing exact
/// instead of merely likely.
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

  /// What [stop] returns. Defaults to peaks built from whatever was emitted.
  WaveformPeaks? stopResult;

  /// When set, [start] throws this.
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

  /// Publishes one frame, exactly as a drain would.
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

  /// Simulates the consumer falling behind.
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
    await _frames.close();
  }
}
