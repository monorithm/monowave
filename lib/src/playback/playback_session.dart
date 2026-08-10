import '../edit/waveform_document.dart';

/// A document in playback.
///
/// This interface is the mirror of `CaptureSession`. Capture reduces audio on
/// the way in and publishes frames. Playback renders a [WaveformDocument] on
/// the way out and feeds an audio device. Both keep the realtime work in C,
/// and both give Dart a handle to that work.
///
/// What you hear is what `MonowavePlatform.exportWav` writes for the same
/// document, sample for sample. That equality is the reason for this
/// interface. A preview of an edit that gives audio different from the export
/// has no value.
///
/// This interface is deliberately not a `MonoPlaybackController`. That
/// interface is in monokit, and a headless package must not depend on the
/// design system. Therefore, the adapter is the few lines that a host writes
/// over [position], [isPlaying] and the three methods.
abstract interface class PlaybackSession {
  /// The document that this session plays.
  WaveformDocument get document;

  /// The length of the whole document, at the sample rate of the source.
  Duration get duration;

  /// The position of the playhead.
  ///
  /// This value comes from the frames that the device consumed, and never from
  /// a timer on this side. A timer drifts against the audio clock immediately,
  /// and the playhead then reports a position where the sound is not.
  ///
  /// A host samples this value and does not listen to a stream of it. When a
  /// host paints, the host reads this value. The value is accurate to within
  /// one device buffer, which is the best accuracy that a consumer of an audio
  /// callback can claim.
  Duration get position;

  bool get isPlaying;

  /// Whether the playhead reached the end of the document.
  bool get isFinished;

  /// Frames of silence that the session gave the device because the feeder was
  /// too slow.
  ///
  /// monowave shows this count and does not hide it, as it does for
  /// `CaptureSession.dropped`. If playback stutters, this count is the first
  /// item to examine. Silence past the end of the document is the end of the
  /// document and not a fault. That silence does not count here.
  int get underruns;

  Future<void> play();
  Future<void> pause();

  /// Moves the playhead.
  ///
  /// The seek is accurate to the sample on WAV, and to approximately 26 ms on
  /// MP3. An MP3 seek goes to a frame boundary and then decodes forward.
  ///
  /// The session erases the frames that the ring queued ahead of the playhead.
  /// Therefore, the device gets a few milliseconds of silence, and not a few
  /// milliseconds of audio from the old position.
  Future<void> seek(Duration position);

  /// Swaps the document under an active session.
  ///
  /// This method is the point of the whole playback path. A host can drag a
  /// trim handle or change a gain, and the user hears the result while
  /// playback continues.
  ///
  /// The playhead keeps its position in the output timeline. Therefore, the
  /// sound continues from that position and does not jump. If a change makes
  /// the document shorter than the position of the playhead, the position
  /// clamps to the new end. A host that wants different behavior can [seek]
  /// directly afterwards.
  ///
  /// This method is one call and not two, because both kinds of change cost
  /// the same work. The session rendered the queued frames ahead of the
  /// playhead through the old document, so those frames must go. The same is
  /// true of a gain change and of a trim.
  Future<void> setDocument(WaveformDocument document);

  Future<void> dispose();
}

/// When monowave cannot open or start a playback device, it throws this
/// exception.
class PlaybackUnavailable implements Exception {
  const PlaybackUnavailable(this.message);

  final String message;

  @override
  String toString() => 'PlaybackUnavailable: $message';
}
