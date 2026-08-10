import 'dart:async';

import '../model/waveform_peaks.dart';
import 'capture_scope.dart';

/// The configuration of a capture session. Every field is a realtime
/// trade-off.
class CaptureConfig {
  const CaptureConfig({
    this.sampleRate = 44100,
    this.channels = 1,
    this.hop = 512,
    this.ringCapacity = 512,
    this.scopeCapacity = 256,
    this.maxDuration = const Duration(minutes: 30),
    this.drainInterval = const Duration(milliseconds: 16),
    this.recordTo,
  });

  final int sampleRate;
  final int channels;

  /// Samples in each reduced frame.
  ///
  /// A hop of 512 at 44.1 kHz gives approximately 86 frames each second. This
  /// rate is more than a 60 Hz display needs. The rate is also low enough to
  /// keep the ring small.
  final int hop;

  /// Frames that the ring holds before the producer drops frames.
  ///
  /// A capacity of 512 at the default hop gives approximately six seconds of
  /// slack. Therefore, an application that stalls for a short time loses
  /// nothing. The producer never blocks to wait for room, because a stall of
  /// the audio thread is an audible glitch and not a dropped frame.
  final int ringCapacity;

  /// Frames that the rolling visualizer window keeps.
  final int scopeCapacity;

  /// How much history [CaptureSession.stop] can return.
  ///
  /// monowave allocates the buffer behind this limit at the start, because an
  /// increase of its size needs an allocation on the audio thread. Past this
  /// limit, capture continues and [CaptureSession.truncated] reports that the
  /// peaks are partial.
  final Duration maxDuration;

  /// How often the consumer moves frames out of the ring.
  final Duration drainInterval;

  /// Where to write the captured audio, or null to keep only the reduction.
  ///
  /// Capture keeps peaks and audio in two separate rings. The audio thread
  /// only copies into these rings. This side writes the file, because file I/O
  /// on an audio callback is the unbounded operation that produces a glitch.
  ///
  /// The result is 16-bit PCM WAV, which is also the format that the exporter
  /// reads. Therefore, a host can trim and export a recording with no second
  /// format.
  final String? recordTo;

  /// Hops that the take buffer must hold to cover [maxDuration].
  int get takeCapacity =>
      (maxDuration.inMicroseconds *
              sampleRate /
              Duration.microsecondsPerSecond /
              hop)
          .ceil()
          .clamp(1, 1 << 24);
}

/// An active microphone capture.
///
/// The audio thread reduces each hop to a [CaptureFrame] and publishes it
/// through a lock-free ring. This session drains that ring on a timer. No PCM
/// crosses into Dart, and no step in the path allocates on the audio thread.
abstract interface class CaptureSession {
  CaptureConfig get config;

  /// Reduced frames, in order.
  ///
  /// This stream is a broadcast stream. Therefore, a visualizer and a meter
  /// can both listen to it.
  Stream<CaptureFrame> get frames;

  /// A rolling window of recent frames, for a painter to draw.
  CaptureScope get scope;

  /// Hops that the audio thread produced.
  int get produced;

  /// Samples that the audio ring dropped because the file writer was too slow.
  ///
  /// This count is separate from [dropped]. The loss of a visualizer frame is
  /// cosmetic. The loss of audio is not cosmetic.
  int get pcmDropped;

  /// Hops that the consumer was too slow to collect.
  ///
  /// monowave shows this count and does not hide it. A value that is more than
  /// zero means that some data did not reach the visualizer. If the bars
  /// stutter, this count is the first item to examine.
  int get dropped;

  /// Whether the history is more than [CaptureConfig.maxDuration].
  ///
  /// Past that limit, the peaks from [stop] are partial.
  bool get truncated;

  bool get isRecording;

  /// Whether the device is stopped but the take is intact.
  bool get isPaused;

  Future<void> start();

  /// Stops the device and keeps the take.
  ///
  /// The rings, the hop accumulator and the history all stay. Therefore,
  /// [resume] continues the same recording and does not start a new one.
  Future<void> pause();
  Future<void> resume();

  /// Stops the device and returns peaks for all the audio that it captured.
  ///
  /// These peaks come from the history of the audio thread, and not from the
  /// frames that the visualizer collected. Therefore, they are complete even
  /// if the application went to the background and missed drains. The caller
  /// owns the result and must dispose it.
  Future<WaveformPeaks> stop();

  Future<void> dispose();
}

/// When monowave cannot open or start a capture device, it throws this
/// exception.
///
/// The usual cause is an absent microphone permission. monowave does not
/// request that permission. This omission is deliberate, because a headless
/// package has no UI to explain the reason for the request. The host does have
/// that UI.
class CaptureUnavailable implements Exception {
  const CaptureUnavailable(this.message);

  final String message;

  @override
  String toString() => 'CaptureUnavailable: $message';
}
