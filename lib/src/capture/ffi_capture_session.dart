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
///
/// **Call [dispose] when finished.** A [NativeFinalizer] destroys a session that
/// is collected without one, so dropping a session cannot leave the microphone
/// open indefinitely - but that is a backstop, not a substitute. It runs
/// whenever the collector happens to get to the object, which may be long after
/// the recording ended and is not guaranteed to happen at all before the process
/// exits. Nothing else releases the device promptly.
class FfiCaptureSession implements CaptureSession, Finalizable {
  FfiCaptureSession._(
    Pointer<bindings.WfCapture> capture,
    this.config,
    this._sink,
  ) : _capture = capture,
      scope = CaptureScope(capacity: config.scopeCapacity),
      // Scratch the C side owns, sized there too. A `calloc` here would have to
      // be freed here, and a session that is collected rather than disposed
      // never gets the chance - which is the one case the finalizer exists for.
      _drainBuffer = bindings.wfCaptureScratch(capture),
      _drainBatch = bindings.wfCaptureScratchFrames(capture),
      _pcmBuffer = bindings.wfCapturePcmScratch(capture),
      _pcmBatch = bindings.wfCapturePcmScratchSamples(capture) {
    _finalizer.attach(this, capture.cast(), detach: this);
  }

  /// Destroys a session that was dropped without [dispose].
  ///
  /// `wf_capture_destroy` stops the device before freeing anything, so this
  /// reclaims the input device as well as the struct, both rings, the take
  /// history and the two drain buffers. Everything a session owns hangs off
  /// that one pointer, which is why the drain buffers live in C.
  static final _finalizer = NativeFinalizer(bindings.wfCaptureDestroyAddress);

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
        try {
          sink = await File(path).open(mode: FileMode.write);
          // A placeholder header, rewritten with real sizes at stop. Writing it
          // up front keeps the audio at a fixed offset, so the file is
          // streamable rather than assembled in memory.
          await sink.writeFrom(_wavHeader(config, 0));
        } catch (_) {
          // An unwritable path would otherwise leak the session outright: no
          // Dart object exists yet for the finalizer to be attached to, so
          // nothing at all owns the pointer if this escapes.
          await sink?.close();
          bindings.wfCaptureDestroy(capture);
          rethrow;
        }
      }

      return FfiCaptureSession._(capture, config, sink);
    } finally {
      calloc.free(error);
    }
  }

  final Pointer<bindings.WfCapture> _capture;

  /// Frames moved per wake-up, and where they land. At the default hop, 16 ms
  /// produces one or two, so the buffer is headroom for a stalled consumer.
  final Pointer<bindings.WfFrame> _drainBuffer;
  final int _drainBatch;

  /// The same for raw audio, or `nullptr` and zero when none is kept.
  final Pointer<Int16> _pcmBuffer;
  final int _pcmBatch;

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
    _timer = Timer.periodic(
      config.drainInterval,
      _drainWeakly(WeakReference(this)),
    );
  }

  /// A periodic tick that does not keep the session alive.
  ///
  /// `(_) => drain()` would capture `this`, and a pending timer is a GC root, so
  /// a session dropped mid-recording would stay reachable for as long as it kept
  /// ticking - forever - and the finalizer would never run. That is precisely
  /// the case where a leak matters most, because the device is still open.
  /// Holding the session weakly instead means a dropped one is collected, the
  /// next tick finds nothing and cancels itself, and `wf_capture_destroy` closes
  /// the microphone.
  ///
  /// Static, and taking the reference already made, so that no strong reference
  /// to the session is ever in scope for the closure to capture by accident.
  static void Function(Timer) _drainWeakly(
    WeakReference<FfiCaptureSession> reference,
  ) => (timer) {
    final session = reference.target;
    if (session == null) {
      timer.cancel();
      return;
    }
    session.drain();
  };

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
  /// the real reduction, the real ring and the real history buffer - just
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

    // Detach first, so the finalizer cannot come back later and destroy a
    // pointer this call has already freed. `_disposed` guards the same thing
    // against a second dispose: a double destroy would corrupt the heap.
    //
    // Both before the await, so nothing native is left to run in a continuation
    // - and the scratch buffers need no separate free, because destroying the
    // session releases them along with everything else it owns.
    _finalizer.detach(this);
    bindings.wfCaptureDestroy(_capture);

    await _frames.close();
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
