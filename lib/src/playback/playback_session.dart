import '../edit/waveform_document.dart';

/// A document being played back.
///
/// The mirror of `CaptureSession`. Capture reduces audio on the way in and
/// publishes frames; playback renders a [WaveformDocument] on the way out and
/// feeds an audio device. Both keep the realtime work in C and hand Dart a
/// handle to it.
///
/// What you hear is what `MonowavePlatform.exportWav` would write for the same
/// document, sample for sample. That is the reason this exists: a preview of an
/// edit is only worth having when it is not a different rendering of it.
///
/// Deliberately not a `MonoPlaybackController`. That interface lives in
/// monokit, and a headless package must not depend on the design system - so
/// the adapter is the few lines a host writes over [position], [isPlaying] and
/// the three methods.
abstract interface class PlaybackSession {
  /// The document being played.
  WaveformDocument get document;

  /// How long the whole document is, at the source's sample rate.
  Duration get duration;

  /// Where the playhead is.
  ///
  /// Read from the frames the device has actually consumed, never from a timer
  /// on this side. A timer drifts against the audio clock immediately, and the
  /// playhead ends up where the sound is not.
  ///
  /// Sampled rather than streamed: a host reads this when it paints. It is
  /// accurate to within one device buffer, which is the best any consumer of an
  /// audio callback can claim.
  Duration get position;

  bool get isPlaying;

  /// Whether the playhead reached the end of the document.
  bool get isFinished;

  /// Frames of silence the device was handed because the feeder fell behind.
  ///
  /// Surfaced rather than hidden, like `CaptureSession.dropped`. A non-zero
  /// value is the first thing to look at when playback stutters. Silence past
  /// the end of the document is the end rather than a fault, and does not count
  /// here.
  int get underruns;

  Future<void> play();
  Future<void> pause();

  /// Moves the playhead. Accurate to the sample on WAV, and to about 26 ms on
  /// MP3, which seeks to a frame boundary and then decodes forward.
  ///
  /// Whatever the ring had queued ahead of the playhead is thrown away, so the
  /// device hears a few milliseconds of silence rather than a few milliseconds
  /// of the old position.
  Future<void> seek(Duration position);

  /// Swaps the document underneath a running session.
  ///
  /// This is the point of the whole playback path: drag a trim handle, change a
  /// gain, and hear the result without playback stopping.
  ///
  /// The playhead keeps its position in the output timeline, so the sound
  /// carries on from where it was rather than jumping. A change that shortens
  /// the document below the playhead clamps to the new end. A host that wants
  /// different behaviour can [seek] straight afterwards.
  ///
  /// One call rather than two, because both kinds of change cost the same
  /// thing. Whatever was queued ahead of the playhead was rendered through the
  /// old document and has to go, and that is as true of a gain change as of a
  /// trim.
  Future<void> setDocument(WaveformDocument document);

  Future<void> dispose();
}

/// Thrown when a playback device cannot be opened or started.
class PlaybackUnavailable implements Exception {
  const PlaybackUnavailable(this.message);

  final String message;

  @override
  String toString() => 'PlaybackUnavailable: $message';
}
