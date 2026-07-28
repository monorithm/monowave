import 'dart:async';
import 'dart:ffi';
import 'dart:io';
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
  FfiCaptureSession._(this._capture, this.config, this._sink)
    : scope = CaptureScope(capacity: config.scopeCapacity),
      _drainBuffer = calloc<bindings.WfFrame>(_drainBatch),
      _pcmBuffer = config.recordTo == null ? nullptr : calloc<Int16>(_pcmBatch);

  /// Frames moved per wake-up. At the default hop, 16 ms produces one or two
  /// frames, so this is generous headroom for a stalled consumer catching up.
  static const _drainBatch = 256;

  /// Samples moved per wake-up. 16 ms at 44.1 kHz is 706, so this is about a
  /// quarter second of slack.
  static const _pcmBatch = 16384;

  static Future<FfiCaptureSession> open(CaptureConfig config) async {
    final error = calloc<Int32>();
    try {
      final capture = bindings.wfCaptureCreate(
        config.sampleRate,
        config.channels,
        config.hop,
        config.ringCapacity,
        config.takeCapacity,
        // A second of audio of slack in the PCM ring: the writer only has to
        // keep up on average, not on every wake-up.
        config.recordTo == null ? 0 : config.sampleRate * config.channels,
        error,
      );
      if (capture == nullptr) {
        throw CaptureUnavailable(
          'Could not allocate a capture session (code ${error.value})',
        );
      }

      RandomAccessFile? sink;
      final path = config.recordTo;
      if (path != null) {
        sink = await File(path).open(mode: FileMode.write);
        // A placeholder header, rewritten with real sizes at stop. Writing it
        // up front keeps the audio at a fixed offset, so the file is streamable
        // rather than assembled in memory.
        await sink.writeFrom(_wavHeader(config, 0));
      }

      return FfiCaptureSession._(capture, config, sink);
    } finally {
      calloc.free(error);
    }
  }

  final Pointer<bindings.WfCapture> _capture;
  final Pointer<bindings.WfFrame> _drainBuffer;
  final Pointer<Int16> _pcmBuffer;
  final RandomAccessFile? _sink;
  int _samplesWritten = 0;

  @override
  final CaptureConfig config;

  @override
  final CaptureScope scope;

  final StreamController<CaptureFrame> _frames =
      StreamController<CaptureFrame>.broadcast();

  Timer? _timer;
  bool _recording = false;
  bool _paused = false;
  bool _disposed = false;

  @override
  Stream<CaptureFrame> get frames => _frames.stream;

  @override
  bool get isRecording => _recording;

  @override
  bool get isPaused => _paused;

  @override
  int get produced => bindings.wfCaptureProduced(_capture).toInt();

  @override
  int get dropped => bindings.wfCaptureDropped(_capture).toInt();

  @override
  int get pcmDropped => bindings.wfCapturePcmDropped(_capture).toInt();

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
    _paused = false;
    _timer = Timer.periodic(config.drainInterval, (_) => drain());
  }

  @override
  Future<void> pause() async {
    _assertUsable();
    if (!_recording || _paused) return;

    final code = bindings.wfCapturePause(_capture);
    if (code != 0) throw CaptureUnavailable('Could not pause (code $code)');

    // Keep draining: the rings still hold whatever arrived before the device
    // stopped, and the file writer must not be left holding it.
    drain();
    _paused = true;
  }

  @override
  Future<void> resume() async {
    _assertUsable();
    if (!_recording || !_paused) return;

    final code = bindings.wfCaptureResume(_capture);
    if (code != 0) throw CaptureUnavailable('Could not resume (code $code)');
    _paused = false;
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

    _drainPcm();
    return moved;
  }

  /// Moves whatever audio accumulated into the file, if one was requested.
  void _drainPcm() {
    final sink = _sink;
    if (sink == null || _pcmBuffer == nullptr) return;

    while (true) {
      final moved = bindings.wfCaptureDrainPcm(_capture, _pcmBuffer, _pcmBatch);
      if (moved <= 0) break;

      // A view, not a copy: the bytes go straight from the ring to the file.
      sink.writeFromSync(Uint8List.sublistView(_pcmBuffer.asTypedList(moved)));
      _samplesWritten += moved;
      if (moved < _pcmBatch) break;
    }
  }

  @override
  Future<WaveformPeaks> stop() async {
    _assertUsable();

    _timer?.cancel();
    _timer = null;
    bindings.wfCaptureStop(_capture);
    _recording = false;
    _paused = false;

    // One last pass, so the visualizer ends on what was actually captured
    // rather than a frame or two short.
    drain();

    final sink = _sink;
    if (sink != null) {
      // Now that the length is known, go back and write the real header.
      await sink.setPosition(0);
      await sink.writeFrom(_wavHeader(config, _samplesWritten));
      await sink.flush();
      await sink.close();
    }

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
    if (_pcmBuffer != nullptr) calloc.free(_pcmBuffer);
  }

  void _assertUsable() {
    if (_disposed) {
      throw StateError('This capture session was disposed.');
    }
  }
}

/// A canonical 44-byte PCM WAV header.
///
/// Written twice: once with zero length so the audio starts at a fixed offset,
/// and once at stop with the real sizes.
Uint8List _wavHeader(CaptureConfig config, int samples) {
  final dataBytes = samples * 2;
  final out = Uint8List(44);
  final data = ByteData.sublistView(out);

  void ascii(int offset, String tag) {
    for (var i = 0; i < tag.length; i++) {
      out[offset + i] = tag.codeUnitAt(i);
    }
  }

  final byteRate = config.sampleRate * config.channels * 2;
  ascii(0, 'RIFF');
  data.setUint32(4, 36 + dataBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, config.channels, Endian.little)
    ..setUint32(24, config.sampleRate, Endian.little)
    ..setUint32(28, byteRate, Endian.little)
    ..setUint16(32, config.channels * 2, Endian.little)
    ..setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, dataBytes, Endian.little);

  return out;
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
