import 'dart:async';

import '../model/waveform_peaks.dart';
import 'capture_scope.dart';

/// How a capture session is configured. Every field is a realtime trade-off.
class CaptureConfig {
  const CaptureConfig({
    this.sampleRate = 44100,
    this.channels = 1,
    this.hop = 512,
    this.ringCapacity = 512,
    this.scopeCapacity = 256,
    this.maxDuration = const Duration(minutes: 30),
    this.drainInterval = const Duration(milliseconds: 16),
  });

  final int sampleRate;
  final int channels;

  /// Samples per reduced frame. 512 at 44.1 kHz is about 86 frames a second —
  /// comfortably above a 60 Hz display and small enough that the ring stays
  /// tiny.
  final int hop;

  /// Frames the ring holds before the producer starts dropping.
  ///
  /// 512 at the default hop is roughly six seconds of slack, so an app that
  /// stalls briefly loses nothing. The producer never blocks waiting for room;
  /// stalling the audio thread would be an audible glitch, not a dropped frame.
  final int ringCapacity;

  /// Frames the rolling visualizer window retains.
  final int scopeCapacity;

  /// How much history [CaptureSession.stop] can return.
  ///
  /// The buffer behind it is allocated up front, because growing it would mean
  /// allocating on the audio thread. Past this, capture keeps running and
  /// [CaptureSession.truncated] reports that the peaks are partial.
  final Duration maxDuration;

  /// How often the consumer moves frames out of the ring.
  final Duration drainInterval;

  /// Hops the take buffer must hold to cover [maxDuration].
  int get takeCapacity =>
      (maxDuration.inMicroseconds *
              sampleRate /
              Duration.microsecondsPerSecond /
              hop)
          .ceil()
          .clamp(1, 1 << 24);
}

/// A running microphone capture.
///
/// The audio thread reduces each hop to a [CaptureFrame] and publishes it
/// through a lock-free ring; this drains that ring on a timer. No PCM crosses
/// into Dart, and nothing in the path allocates on the audio thread.
abstract interface class CaptureSession {
  CaptureConfig get config;

  /// Reduced frames, in order. Broadcast, so a visualizer and a meter can both
  /// listen.
  Stream<CaptureFrame> get frames;

  /// A rolling window of recent frames, for drawing.
  CaptureScope get scope;

  /// Hops the audio thread produced.
  int get produced;

  /// Hops the consumer was too slow to collect.
  ///
  /// Surfaced rather than hidden: a non-zero value means the visualizer is
  /// missing data, and it is the first thing to look at if bars stutter.
  int get dropped;

  /// Whether history exceeded [CaptureConfig.maxDuration], making the peaks
  /// from [stop] partial.
  bool get truncated;

  bool get isRecording;

  Future<void> start();

  /// Stops the device and returns peaks for everything captured.
  ///
  /// These come from the audio thread's own history, not from what the
  /// visualizer happened to collect, so they are complete even if the app was
  /// backgrounded and missed drains. Caller owns the result and should dispose
  /// it.
  Future<WaveformPeaks> stop();

  Future<void> dispose();
}

/// Thrown when a capture device cannot be opened or started.
///
/// The usual cause is a missing microphone permission, which monowave
/// deliberately does not request: a headless package has no UI to explain why
/// it is asking, and the host does.
class CaptureUnavailable implements Exception {
  const CaptureUnavailable(this.message);

  final String message;

  @override
  String toString() => 'CaptureUnavailable: $message';
}
