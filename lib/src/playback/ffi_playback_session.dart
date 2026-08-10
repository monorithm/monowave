import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../edit/waveform_document.dart';
import '../native/monowave_bindings.dart' as bindings;
import 'playback_session.dart';

/// A playback session on the C renderer, a lock-free ring and miniaudio.
///
/// No code here runs on the audio thread. The audio thread copies out of a
/// ring and does nothing else. A feeder thread in C keeps that ring ahead of
/// the audio thread. This side only opens, seeks, and reads counters.
///
/// **Call [dispose] when you are finished.** A [NativeFinalizer] runs
/// `wf_playback_destroy` on a session that the garbage collector collects
/// without a call to [dispose]. Therefore, an abandoned session cannot keep an
/// output device open indefinitely. The finalizer is a backstop and not a
/// substitute.
///
/// When the collector reaches the object, the finalizer runs. That moment can
/// be long after playback ended. The rule and the reason are the same as for
/// `FfiCaptureSession`.
class FfiPlaybackSession implements PlaybackSession, Finalizable {
  FfiPlaybackSession._(
    Pointer<bindings.WfPlayback> playback,
    WaveformDocument document,
    this._sampleRate,
  ) : _playback = playback,
      _document = document {
    _finalizer.attach(this, playback.cast(), detach: this);
  }

  /// Runs `wf_playback_destroy` on a session that the garbage collector
  /// collects without a call to [dispose].
  ///
  /// `wf_playback_destroy` stops the device and joins the feeder thread before
  /// it frees memory. Therefore, this finalizer reclaims the output device,
  /// the thread and the memory.
  static final _finalizer = NativeFinalizer(bindings.wfPlaybackDestroyAddress);

  /// The cushion between the feeder and the device.
  ///
  /// This size is approximately one second at 44.1 kHz. The feeder must match
  /// the device on average only. A deep ring absorbs a slow disk or a busy
  /// machine.
  static const _ringFrames = 65536;

  static Future<FfiPlaybackSession> open({
    required String sourcePath,
    required WaveformDocument document,
    int ringFrames = _ringFrames,
  }) async {
    if (document.isEmpty) {
      throw const PlaybackUnavailable(
        'There is nothing to play: the document has no regions.',
      );
    }

    final path = sourcePath.toNativeUtf8();
    final regions = calloc<bindings.WfRegion>(document.regions.length);
    final error = calloc<Int32>();

    try {
      _writeRegions(regions, document);

      final playback = bindings.wfPlaybackCreate(
        path.cast(),
        regions,
        document.regions.length,
        ringFrames,
        error,
      );
      if (playback == nullptr) {
        throw PlaybackUnavailable(
          'Could not open $sourcePath for playback (code ${error.value})',
        );
      }

      return FfiPlaybackSession._(
        playback,
        document,
        bindings.wfPlaybackSampleRate(playback),
      );
    } finally {
      calloc
        ..free(path)
        ..free(regions)
        ..free(error);
    }
  }

  /// The same session over bytes that are already in memory.
  ///
  /// The C side copies the bytes for two reasons. The dr_libs code references
  /// the buffer of the caller and does not copy it. The feeder reads from that
  /// buffer on another thread.
  static Future<FfiPlaybackSession> openBytes({
    required Uint8List bytes,
    required WaveformDocument document,
    int ringFrames = _ringFrames,
  }) async {
    if (document.isEmpty) {
      throw const PlaybackUnavailable(
        'There is nothing to play: the document has no regions.',
      );
    }

    final input = calloc<Uint8>(bytes.length);
    final regions = calloc<bindings.WfRegion>(document.regions.length);
    final error = calloc<Int32>();

    try {
      input.asTypedList(bytes.length).setAll(0, bytes);
      _writeRegions(regions, document);

      final playback = bindings.wfPlaybackCreateMemory(
        input.cast(),
        bytes.length,
        regions,
        document.regions.length,
        ringFrames,
        error,
      );
      if (playback == nullptr) {
        throw PlaybackUnavailable(
          'Could not open ${bytes.length} bytes for playback '
          '(code ${error.value})',
        );
      }

      return FfiPlaybackSession._(
        playback,
        document,
        bindings.wfPlaybackSampleRate(playback),
      );
    } finally {
      calloc
        ..free(input)
        ..free(regions)
        ..free(error);
    }
  }

  /// Writes a document as `wf_region` structs.
  static void _writeRegions(
    Pointer<bindings.WfRegion> into,
    WaveformDocument document,
  ) {
    for (var i = 0; i < document.regions.length; i++) {
      final region = document.regions[i];
      into[i]
        ..sourceStart = region.sourceStart.toDouble()
        ..sourceEnd = region.sourceEnd.toDouble()
        ..gain = region.gain
        ..fadeIn = region.fadeIn
        ..fadeOut = region.fadeOut;
    }
  }

  final Pointer<bindings.WfPlayback> _playback;
  final int _sampleRate;

  @override
  WaveformDocument get document => _document;
  WaveformDocument _document;

  bool _playing = false;
  bool _disposed = false;

  /// The counters as they stood at [dispose], or null while the session is
  /// alive.
  ///
  /// `FfiCaptureSession` gives its counters the same treatment, for the same
  /// reason. A read of a counter after the code frees the struct is a use
  /// after free. A query has a correct answer after disposal, and a command
  /// does not.
  ({Duration position, int underruns})? _finalCounts;

  @override
  Duration get duration =>
      _framesToDuration(bindings.wfPlaybackLengthFrames(_playback).toInt());

  @override
  Duration get position =>
      _finalCounts?.position ??
      _framesToDuration(bindings.wfPlaybackConsumed(_playback).toInt());

  @override
  bool get isPlaying => _playing;

  @override
  bool get isFinished =>
      _disposed || bindings.wfPlaybackFinished(_playback) != 0;

  @override
  int get underruns =>
      _finalCounts?.underruns ??
      bindings.wfPlaybackUnderruns(_playback).toInt();

  @override
  Future<void> play() async {
    _assertUsable();
    if (_playing) return;

    final code = bindings.wfPlaybackStart(_playback);
    if (code != 0) {
      throw PlaybackUnavailable(
        'The output device would not start (code $code).',
      );
    }
    _playing = true;
  }

  @override
  Future<void> pause() async {
    _assertUsable();
    if (!_playing) return;

    bindings.wfPlaybackStop(_playback);
    _playing = false;
  }

  @override
  Future<void> seek(Duration position) async {
    _assertUsable();

    final frame =
        position.inMicroseconds * _sampleRate / Duration.microsecondsPerSecond;
    final code = bindings.wfPlaybackSeek(
      _playback,
      frame < 0 ? 0 : frame.roundToDouble(),
    );
    if (code != 0) {
      throw PlaybackUnavailable('The seek did not complete (code $code).');
    }
  }

  @override
  Future<void> setDocument(WaveformDocument document) async {
    _assertUsable();
    if (document.isEmpty) {
      throw const PlaybackUnavailable(
        'There is nothing to play: the document has no regions.',
      );
    }

    final regions = calloc<bindings.WfRegion>(document.regions.length);
    try {
      _writeRegions(regions, document);

      final code = bindings.wfPlaybackSetRegions(
        _playback,
        regions,
        document.regions.length,
      );
      if (code != 0) {
        throw PlaybackUnavailable('The document swap failed (code $code).');
      }

      // Only after the C side accepted it, so a failed swap leaves this
      // reporting the document that is actually playing.
      _document = document;
    } finally {
      calloc.free(regions);
    }
  }

  /// Pulls frames in the same way as the device callback, and returns the
  /// frames that it got.
  ///
  /// This method is the audio-thread entry point, under manual control. A test
  /// can therefore run the realtime path on every platform with no sound card.
  /// A real speaker drives the same code. `feedSynthetic` makes the same
  /// bargain for capture.
  Int16List pullSynthetic(int frames) {
    _assertUsable();

    final channels = bindings.wfPlaybackChannels(_playback);
    final buffer = calloc<Int16>(frames * channels);
    try {
      final got = bindings.wfPlaybackPull(_playback, buffer, frames);
      return Int16List.fromList(buffer.asTypedList(got * channels));
    } finally {
      calloc.free(buffer);
    }
  }

  /// Frames that the ring holds. For test and diagnostic use.
  int get buffered => bindings.wfPlaybackAvailable(_playback);

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _playing = false;

    // Read the counters out before the struct goes, so the getters can answer
    // from a frozen tally rather than from freed memory.
    _finalCounts = (position: position, underruns: underruns);

    // Detach first, so the finalizer cannot come back for a pointer this call
    // has already freed.
    _finalizer.detach(this);
    bindings.wfPlaybackDestroy(_playback);
  }

  Duration _framesToDuration(int frames) => Duration(
    microseconds: (frames * Duration.microsecondsPerSecond / _sampleRate)
        .round(),
  );

  void _assertUsable() {
    if (_disposed) {
      throw StateError('This playback session was disposed.');
    }
  }
}
