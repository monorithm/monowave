import 'dart:js_interop';
import 'dart:typed_data';

import '../edit/waveform_document.dart';
import 'playback_session.dart';

/// Renders a document and reports the shape of the result.
///
/// The session needs the channel count and the rate to build a graph, and the
/// renderer is the only component that knows them. One callback, rather than
/// loose metadata, keeps these two values consistent.
typedef WebRender =
    Future<({Int16List pcm, int channels, int sampleRate})> Function(
      Uint8List bytes,
      WaveformDocument document,
    );

@JS('AudioContext')
extension type _AudioContext._(JSObject _o) implements JSObject {
  external factory _AudioContext();

  external double get currentTime;
  external String get state;
  external JSPromise<JSAny?> resume();
  external JSPromise<JSAny?> close();
  external _AudioBuffer createBuffer(int channels, int frames, num sampleRate);
  external _BufferSource createBufferSource();
  external _Destination get destination;
}

extension type _AudioBuffer._(JSObject _o) implements JSObject {
  external void copyToChannel(JSFloat32Array source, int channel);
}

extension type _Destination._(JSObject _o) implements JSObject {}

extension type _BufferSource._(JSObject _o) implements JSObject {
  external set buffer(_AudioBuffer value);
  external void connect(_Destination destination);
  external void start(num when, num offset);
  external void stop();
  external void disconnect();
  external set onended(JSFunction value);
}

/// A playback session that gives rendered samples to a WebAudio graph.
///
/// Web has no filesystem and no miniaudio. Therefore, this class shares no
/// implementation with `FfiPlaybackSession`, and it shares the samples
/// exactly. The same C loop that the exporter runs, compiled to WASM, renders
/// the document. Therefore, what a browser plays is what an export writes.
///
/// There is no ring and no feeder thread here. The browser owns the audio
/// thread, and all the rendered samples go into an `AudioBuffer` at the start.
/// That shape is correct for a preview of an edit and wrong for an audiobook.
/// This limit is better to know than to discover. A long document costs its
/// whole length in memory, at four bytes per frame per channel.
class WebPlaybackSession implements PlaybackSession {
  WebPlaybackSession._(
    this._context,
    this._buffer,
    this._frames,
    this._document,
    this._pcm,
  );

  /// Renders [document] and stages it for playback.
  ///
  /// The caller injects [render], so this file never imports the platform that
  /// owns it.
  static Future<WebPlaybackSession> open({
    required Uint8List bytes,
    required WaveformDocument document,
    required WebRender render,
  }) async {
    if (document.isEmpty) {
      throw const PlaybackUnavailable(
        'There is nothing to play: the document has no regions.',
      );
    }

    final rendered = await render(bytes, document);
    final context = _AudioContext();
    return WebPlaybackSession._(
      context,
      _bufferOf(context, rendered.pcm, rendered.channels, rendered.sampleRate),
      rendered.pcm.length ~/ rendered.channels,
      document,
      (
        bytes: bytes,
        render: render,
        channels: rendered.channels,
        rate: rendered.sampleRate,
      ),
    );
  }

  /// Deinterleaves into an `AudioBuffer` and converts to float on the way.
  ///
  /// The conversion is a concern of the device and not of the render step.
  /// miniaudio does the same thing natively on its way to the sound card. The
  /// samples that this class plays are still the bytes that an export writes.
  /// Only the form changes, because the browser requires that form.
  static _AudioBuffer _bufferOf(
    _AudioContext context,
    Int16List pcm,
    int channels,
    int sampleRate,
  ) {
    final frames = pcm.length ~/ channels;
    final buffer = context.createBuffer(
      channels,
      // An AudioBuffer of zero frames is a TypeError, and an empty document is
      // already refused - but a document whose regions all collapse is not.
      frames == 0 ? 1 : frames,
      sampleRate,
    );

    final plane = Float32List(frames == 0 ? 1 : frames);
    for (var channel = 0; channel < channels; channel++) {
      for (var frame = 0; frame < frames; frame++) {
        // 32768 rather than 32767: it is the magnitude of the most negative
        // int16, so the mapping is exact in both directions and never clips.
        plane[frame] = pcm[frame * channels + channel] / 32768.0;
      }
      buffer.copyToChannel(plane.toJS, channel);
    }
    return buffer;
  }

  final _AudioContext _context;
  _AudioBuffer _buffer;

  /// Frames that the document renders to.
  ///
  /// This class keeps the count and does not read it back from [_buffer]. If
  /// the render step produces no frames, [_buffer] has a pad of one frame.
  int _frames;

  WaveformDocument _document;

  /// The values that a new render needs. This class holds them, so
  /// [setDocument] does not need the platform.
  final ({Uint8List bytes, WebRender render, int channels, int rate}) _pcm;

  _BufferSource? _source;

  /// The position of the playhead, in seconds, at the start of the current
  /// source node.
  double _offset = 0;

  /// `AudioContext.currentTime` at that moment.
  double _startedAt = 0;

  bool _playing = false;
  bool _disposed = false;

  @override
  WaveformDocument get document => _document;

  @override
  Duration get duration => _seconds(_frames / _pcm.rate);

  @override
  Duration get position {
    if (_disposed) return _seconds(_offset);

    // The browser's audio clock, not a timer. `currentTime` advances with the
    // hardware, which is the same rule the native session follows by counting
    // frames the device consumed.
    final at = _playing
        ? _offset + (_context.currentTime - _startedAt)
        : _offset;
    final length = _frames / _pcm.rate;
    return _seconds(at < 0 ? 0 : (at > length ? length : at));
  }

  @override
  bool get isPlaying => _playing;

  @override
  bool get isFinished => _disposed || position >= duration;

  /// Always zero on web, and not a stub.
  ///
  /// An underrun is a race that the feeder loses against the device. There is
  /// no feeder here. All the rendered samples are resident before playback
  /// starts, so that race cannot happen. The cost is memory instead, at the
  /// start.
  @override
  int get underruns => 0;

  /// Awaits a WebAudio promise, but never forever.
  ///
  /// A suspended `AudioContext` keeps `resume()` pending until a user gesture
  /// arrives. A gesture does not always arrive, and in a driven test a gesture
  /// certainly does not arrive. `close()` on such a context can behave in the
  /// same way.
  ///
  /// A block on either promise makes "no audio" into "no progress", which is a
  /// hang and not a message. Therefore, this method reads the state afterwards
  /// and does not trust a promise.
  static Future<void> _settle(JSPromise<JSAny?> promise) => promise.toDart
      .timeout(const Duration(milliseconds: 500), onTimeout: () => null);

  @override
  Future<void> play() async {
    _assertUsable();
    if (_playing) return;

    // Browsers refuse to start an audio context without a user gesture, and
    // report it as a context stuck in "suspended" rather than as an error.
    if (_context.state != 'running') await _settle(_context.resume());
    if (_context.state != 'running') {
      throw const PlaybackUnavailable(
        'The browser would not start audio. An AudioContext needs a user '
        'gesture, so call play() from a tap or a click rather than on load.',
      );
    }

    _start(_offset);
  }

  @override
  Future<void> pause() async {
    _assertUsable();
    if (!_playing) return;

    // Read the playhead before tearing the node down, or it snaps back.
    _offset = position.inMicroseconds / Duration.microsecondsPerSecond;
    _stop();
  }

  @override
  Future<void> seek(Duration position) async {
    _assertUsable();

    final length = _frames / _pcm.rate;
    final at = position.inMicroseconds / Duration.microsecondsPerSecond;
    _offset = at < 0 ? 0 : (at > length ? length : at);

    if (_playing) {
      _stop();
      _start(_offset);
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

    // The playhead is read before the swap and reapplied after, so it keeps its
    // output position exactly as the native session does.
    final at = position;
    final wasPlaying = _playing;
    if (wasPlaying) _stop();

    final rendered = await _pcm.render(_pcm.bytes, document);
    _buffer = _bufferOf(
      _context,
      rendered.pcm,
      rendered.channels,
      rendered.sampleRate,
    );
    _frames = rendered.pcm.length ~/ rendered.channels;
    _document = document;

    final length = _frames / _pcm.rate;
    final seconds = at.inMicroseconds / Duration.microsecondsPerSecond;
    _offset = seconds > length ? length : seconds;
    if (wasPlaying) _start(_offset);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;

    _offset = position.inMicroseconds / Duration.microsecondsPerSecond;
    if (_playing) _stop();
    _disposed = true;

    await _settle(_context.close());
  }

  void _start(double offset) {
    final source = _context.createBufferSource()
      ..buffer = _buffer
      ..connect(_context.destination)
      ..onended = (() => _playing = false).toJS;

    source.start(0, offset);
    _source = source;
    _startedAt = _context.currentTime;
    _playing = true;
  }

  void _stop() {
    _source
      ?..stop()
      ..disconnect();
    _source = null;
    _playing = false;
  }

  Duration _seconds(double value) =>
      Duration(microseconds: (value * Duration.microsecondsPerSecond).round());

  void _assertUsable() {
    if (_disposed) {
      throw StateError('This playback session was disposed.');
    }
  }
}
