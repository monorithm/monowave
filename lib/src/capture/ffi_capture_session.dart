import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../model/waveform_peaks.dart';
import '../native/monowave_bindings.dart' as bindings;
import 'capture_scope.dart';
import 'capture_session.dart';

/// A capture session on miniaudio, which this side drains over FFI.
///
/// No code here runs on the audio thread. The whole job of the audio thread is
/// in C. That code accumulates a hop, reduces it, and publishes it to a
/// lock-free ring. This side wakes on a timer and moves the accumulated frames
/// into Dart.
///
/// **Call [dispose] when you are finished.** A [NativeFinalizer] runs
/// `wf_capture_destroy` on a session that the garbage collector collects
/// without a call to [dispose]. Therefore, an abandoned session cannot keep
/// the microphone open indefinitely. The finalizer is a backstop and not a
/// substitute.
///
/// When the collector reaches the object, the finalizer runs. That moment can
/// be long after the recording ended. Nothing guarantees that the finalizer
/// runs at all before the process exits. No other mechanism releases the
/// device promptly.
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

  /// Runs `wf_capture_destroy` on a session that the garbage collector
  /// collects without a call to [dispose].
  ///
  /// `wf_capture_destroy` stops the device before it frees memory. Therefore,
  /// this finalizer reclaims the input device, the struct, both rings, the
  /// take history and the two drain buffers. One pointer owns all the
  /// resources of a session. That is the reason why the drain buffers are in
  /// C.
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

  /// Frames that each wake-up moves, and the buffer that receives them.
  ///
  /// At the default hop, 16 ms produces one or two frames. Therefore, the
  /// buffer is headroom for a consumer that stalls.
  final Pointer<bindings.WfFrame> _drainBuffer;
  final int _drainBatch;

  /// The same two values for raw audio. If the session keeps no audio, they
  /// are `nullptr` and zero.
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
  bool _sinkClosed = false;

  @override
  Stream<CaptureFrame> get frames => _frames.stream;

  @override
  bool get isRecording => _recording;

  @override
  bool get isPaused => _paused;

  /// The counters as they stood at [dispose], or null while the session is
  /// still alive.
  ///
  /// The four getters that follow read directly from the C struct, and
  /// [dispose] frees that struct. Without this field, those getters read freed
  /// memory and do not throw. This member freezes its value and does not
  /// throw, unlike every other member here. A counter is a query with a
  /// correct answer after disposal. `start` or `stop` have no useful work left
  /// after disposal.
  ///
  /// This behavior also keeps the class in step with `FakeCaptureSession`,
  /// which answers the same four getters after disposal. Therefore, a UI that
  /// reads a counter during teardown behaves the same in a widget test as in
  /// production.
  ({int produced, int dropped, int pcmDropped, bool truncated})? _finalCounts;

  @override
  int get produced =>
      _finalCounts?.produced ?? bindings.wfCaptureProduced(_capture).toInt();

  @override
  int get dropped =>
      _finalCounts?.dropped ?? bindings.wfCaptureDropped(_capture).toInt();

  @override
  int get pcmDropped =>
      _finalCounts?.pcmDropped ??
      bindings.wfCapturePcmDropped(_capture).toInt();

  @override
  bool get truncated =>
      _finalCounts?.truncated ?? bindings.wfCaptureOverflowed(_capture) != 0;

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
  /// A closure of the form `(_) => drain()` captures `this`, and a pending
  /// timer is a GC root. The caller can release its last reference to a
  /// session in the middle of a recording. That session then stays reachable
  /// for as long as the timer ticks. The timer ticks forever, and the
  /// finalizer never runs. A leak matters most in this case, because the
  /// device is still open.
  ///
  /// A weak hold on the session gives a different result. The garbage
  /// collector collects a session with no other references. The next tick
  /// finds nothing and cancels itself. Then `wf_capture_destroy` closes the
  /// microphone.
  ///
  /// This method is static, and it takes a reference that the caller already
  /// made. Therefore, no strong reference to the session is ever in scope, and
  /// the closure cannot capture one by accident.
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

  /// Moves the frames that the audio thread published into [scope] and
  /// [frames].
  ///
  /// This method is public. A host with its own ticker can drive this method
  /// from that ticker. A second timer next to the built-in one is then not
  /// necessary.
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

  /// If the caller asked for a file, this method moves the accumulated audio
  /// into that file.
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

    await _closeSink();

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

  /// Writes the real sizes into the WAV header and closes the file, one time.
  ///
  /// Both [stop] and [dispose] need this method. [stop] uses it to finish a
  /// take. [dispose] uses it so that an abandoned take leaves a file that a
  /// player can open. Without this method, the take leaves an open handle and
  /// a header that still claims zero length. In both cases the audio was
  /// already on disk, and only the header was wrong.
  ///
  /// This method is idempotent for two reasons. A second close of a
  /// [RandomAccessFile] throws. A call to `stop()` and then `dispose()` is the
  /// ordinary way to end a recording.
  ///
  /// This method deliberately does not drain. The frames that the audio thread
  /// published since the last pass stay in the ring, and they are lost. To
  /// finish a take is the job of [stop], and a caller that wants those samples
  /// calls [stop] instead. This method only keeps an abandoned file from
  /// corruption.
  Future<void> _closeSink() async {
    final sink = _sink;
    if (sink == null || _sinkClosed) return;
    _sinkClosed = true;

    // Now that the length is known, go back and write the real header.
    await sink.setPosition(0);
    await sink.writeFrom(_wavHeader(config, _samplesWritten));
    await sink.flush();
    await sink.close();
  }

  /// Drives the audio-thread path with synthetic interleaved PCM.
  ///
  /// This method is the same entry point that the device callback uses.
  /// Therefore, a test exercises the real reduction, the real ring and the
  /// real history buffer, with no microphone and no permission prompt. This
  /// method is the reason why CI can run tests for the realtime path on every
  /// platform.
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
    _recording = false;
    _paused = false;

    // Read the counters out while there is still something to read them from.
    // After the destroy below the struct is gone, and the getters would be
    // reading freed memory rather than reporting the final tally.
    _finalCounts = (
      produced: produced,
      dropped: dropped,
      pcmDropped: pcmDropped,
      truncated: truncated,
    );

    // Detach first, so the finalizer cannot come back later and destroy a
    // pointer this call has already freed. `_disposed` guards the same thing
    // against a second dispose: a double destroy would corrupt the heap.
    //
    // Both before the await, so nothing native is left to run in a continuation
    // - and the scratch buffers need no separate free, because destroying the
    // session releases them along with everything else it owns.
    _finalizer.detach(this);
    bindings.wfCaptureDestroy(_capture);

    // A no-op when stop() already did it. Without it, disposing a recording
    // session that was never stopped leaks the handle and leaves a WAV whose
    // header still says the audio after it is zero bytes long.
    await _closeSink();
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
/// The session writes this header two times. The first write gives a zero
/// length, so that the audio starts at a fixed offset. The second write, at
/// stop, gives the real sizes.
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

/// Wraps a native pyramid as views, in the same way as a decode.
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
