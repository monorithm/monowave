import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../model/waveform_peaks.dart';
import '../native/monowave_bindings.dart' as bindings;
import 'capture_scope.dart';
import 'capture_session.dart';

/// A capture session backed by miniaudio, drained over FFI.
///
/// Nothing here runs on the audio thread. The audio thread's whole job is in C:
/// accumulate a hop, reduce it, publish it to a lock-free ring. This side wakes
/// on a timer and moves whatever accumulated into Dart.
class FfiCaptureSession implements CaptureSession {
  FfiCaptureSession._(this._capture, this.config)
    : scope = CaptureScope(capacity: config.scopeCapacity),
      _drainBuffer = calloc<bindings.WfFrame>(_drainBatch);

  /// Frames moved per wake-up. At the default hop, 16 ms produces one or two
  /// frames, so this is generous headroom for a stalled consumer catching up.
  static const _drainBatch = 256;

  static Future<FfiCaptureSession> open(CaptureConfig config) async {
    final error = calloc<Int32>();
    try {
      final capture = bindings.wfCaptureCreate(
        config.sampleRate,
        config.channels,
        config.hop,
        config.ringCapacity,
        config.takeCapacity,
        error,
      );
      if (capture == nullptr) {
        throw CaptureUnavailable(
          'Could not allocate a capture session (code ${error.value})',
        );
      }
      return FfiCaptureSession._(capture, config);
    } finally {
      calloc.free(error);
    }
  }

  final Pointer<bindings.WfCapture> _capture;
  final Pointer<bindings.WfFrame> _drainBuffer;

  @override
  final CaptureConfig config;

  @override
  final CaptureScope scope;

  final StreamController<CaptureFrame> _frames =
      StreamController<CaptureFrame>.broadcast();

  Timer? _timer;
  bool _recording = false;
  bool _disposed = false;

  @override
  Stream<CaptureFrame> get frames => _frames.stream;

  @override
  bool get isRecording => _recording;

  @override
  int get produced => bindings.wfCaptureProduced(_capture).toInt();

  @override
  int get dropped => bindings.wfCaptureDropped(_capture).toInt();

  @override
  bool get truncated => bindings.wfCaptureOverflowed(_capture) != 0;

  @override
  Future<void> start() async {
    _assertUsable();
    if (_recording) return;

    final code = bindings.wfCaptureStart(_capture);
    if (code != 0) {
      throw CaptureUnavailable(
        'The capture device would not start (code $code). On most platforms '
        'this means the microphone permission has not been granted.',
      );
    }

    _recording = true;
    _timer = Timer.periodic(config.drainInterval, (_) => drain());
  }

  /// Moves whatever the audio thread has published into [scope] and [frames].
  ///
  /// Public because a host driving its own ticker should drive this rather than
  /// run a second timer alongside the built-in one.
  int drain() {
    if (_disposed) return 0;

    final moved = bindings.wfCaptureDrain(_capture, _drainBuffer, _drainBatch);
    for (var i = 0; i < moved; i++) {
      final native = _drainBuffer[i];
      final frame = (min: native.min, max: native.max, rms: native.rms);
      scope.add(frame);
      if (_frames.hasListener) _frames.add(frame);
    }
    return moved;
  }

  @override
  Future<WaveformPeaks> stop() async {
    _assertUsable();

    _timer?.cancel();
    _timer = null;
    bindings.wfCaptureStop(_capture);
    _recording = false;

    // One last pass, so the visualizer ends on what was actually captured
    // rather than a frame or two short.
    drain();

    final error = calloc<Int32>();
    try {
      final peaks = bindings.wfCaptureTakePeaks(_capture, error);
      if (peaks == nullptr) {
        throw CaptureUnavailable(
          error.value == 6
              ? 'Nothing was captured.'
              : 'Could not build peaks for the take (code ${error.value})',
        );
      }
      return _wrapPeaks(peaks);
    } finally {
      calloc.free(error);
    }
  }

  /// Drives the audio-thread path with synthetic interleaved PCM.
  ///
  /// This is the same entry point the device callback uses, so a test exercises
  /// the real reduction, the real ring and the real history buffer — just
  /// without a microphone or a permission prompt. It is why the realtime path
  /// is testable in CI on every platform.
  void feedSynthetic(Int16List interleaved) {
    _assertUsable();

    final frames = interleaved.length ~/ config.channels;
    final buffer = calloc<Int16>(interleaved.length);
    try {
      buffer.asTypedList(interleaved.length).setAll(0, interleaved);
      bindings.wfCaptureFeed(_capture, buffer, frames);
    } finally {
      calloc.free(buffer);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    _timer?.cancel();
    _timer = null;
    await _frames.close();
    bindings.wfCaptureDestroy(_capture);
    calloc.free(_drainBuffer);
  }

  void _assertUsable() {
    if (_disposed) {
      throw StateError('This capture session was disposed.');
    }
  }
}

/// Wraps a native pyramid as views, the same way a decode does.
WaveformPeaks _wrapPeaks(Pointer<bindings.WfPeaks> pointer) {
  final levels = <Int16List>[
    for (var level = 0; level < bindings.wfPeaksLevels(pointer); level++)
      bindings
          .wfPeaksData(pointer, level)
          .asTypedList(bindings.wfPeaksPairCount(pointer, level) * 2),
  ];

  return WaveformPeaks.fromLevels(
    levels,
    sampleRate: bindings.wfPeaksSampleRate(pointer),
    channels: bindings.wfPeaksChannels(pointer),
    lengthInSamples: bindings.wfPeaksLength(pointer).toInt(),
    baseSamplesPerPixel: bindings.wfPeaksBaseSamplesPerPixel(pointer),
    onDispose: () => bindings.wfPeaksFree(pointer),
  );
}
