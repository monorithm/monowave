import 'dart:typed_data';

import '../capture/capture_session.dart';
import '../playback/playback_session.dart';
import '../edit/waveform_document.dart';
import '../model/waveform_peaks.dart';

// The web/native split. `dart.library.js_interop` is only true when compiling
// for web, so native builds never see the WASM implementation and web builds
// never see `dart:ffi`.
import 'ffi_platform.dart'
    if (dart.library.js_interop) 'wasm_platform.dart'
    as impl;

/// A single reduced window of audio: the extremes of the samples it covers.
///
/// This is a min/max pair and not an average. An average collapses transients
/// and shows speech as a flat sausage.
typedef MinMax = ({int min, int max});

/// The native seam every call into the C core crosses.
///
/// This is an interface and not a set of direct calls into the bindings.
/// Therefore a test can run the engine against an in-memory fake, with no
/// native code and no device. [monolens] uses the same shape for
/// `MonolensPlatform`. If a federated split is ever necessary, this is also
/// the line that the split cuts along.
///
/// [monolens]: https://github.com/monorithm/monolens
abstract interface class MonowavePlatform {
  /// The implementation that calls run against.
  ///
  /// To use a fake, assign the fake in `setUp`. Then restore null in
  /// `tearDown`.
  static MonowavePlatform get instance => _instance ??= impl.defaultPlatform();
  static set instance(MonowavePlatform? value) => _instance = value;
  static MonowavePlatform? _instance;

  /// If the C core is not loaded already, this method loads it. A second
  /// call does nothing.
  ///
  /// This method exists because of web. Native targets resolve their code
  /// asset at startup and have nothing to wait for. On web, the module must
  /// instantiate first, and that operation is asynchronous by nature.
  ///
  /// The alternative is to make every method return a `Future`. That
  /// alternative puts an event-loop turn in front of [reduceMinMax]. A scrub
  /// calls [reduceMinMax] one time for each frame. A capture calls it one time
  /// for each hop. One await at the start is the cheaper shape.
  ///
  /// Until this method completes, every other method throws
  /// [MonowaveUnavailable].
  Future<void> ensureInitialized();

  /// The ABI version of the C core. Each time a signature in `src/` changes,
  /// this version increases.
  int abiVersion();

  /// This method reduces [samples] to the pair of extremes that the samples
  /// span.
  MinMax reduceMinMax(Int16List samples);

  /// This method decodes the audio file at [path] into a peak pyramid.
  ///
  /// Web has no filesystem, so this method is not available there. On web,
  /// [decodeBytes] does this work instead. On native, this method is the
  /// better choice, because the decoder streams the file one bucket at a time.
  /// Therefore an audiobook never has to be resident in memory.
  ///
  /// If the container cannot be read, this method throws
  /// [MonowaveDecodeException].
  Future<WaveformPeaks> decodeFile(
    String path, {
    int baseSamplesPerPixel = 128,
  });

  /// This method decodes a container that is already in memory. On web, this
  /// method is the only decode path.
  Future<WaveformPeaks> decodeBytes(
    Uint8List bytes, {
    int baseSamplesPerPixel = 128,
  });

  /// This method reads from [sourcePath] and writes [document] to
  /// [outputPath] as 16-bit PCM WAV.
  ///
  /// The output is always WAV. An edit list must reproduce the source exactly
  /// where the list does not change the source. monowave does not encode the
  /// output to a lossy format, because a lossy encoder breaks that property
  /// and gives no warning.
  ///
  /// Web has no filesystem to write to, so this method is not available there.
  Future<void> exportWav({
    required String sourcePath,
    required String outputPath,
    required WaveformDocument document,
  });

  /// This method renders [document] to 16-bit PCM and writes no file.
  ///
  /// The samples are byte-identical to the samples that [exportWav] writes for
  /// the same document, because both methods run the same C loop. That
  /// equality is the whole point. It is the reason that you can trust a
  /// preview before you commit an edit.
  ///
  /// This method returns interleaved frames at the sample rate and the channel
  /// count that the source itself uses. The whole render stays resident in
  /// memory. Therefore this method is for previews and tests, and not for an
  /// audiobook. For streaming playback, [openPlayback] opens a
  /// `PlaybackSession`. ROADMAP.md has more information.
  ///
  /// Web has no filesystem to read, so this method is not available there.
  Future<Int16List> renderPcm({
    required String sourcePath,
    required WaveformDocument document,
  });

  /// This method renders [document] to 16-bit PCM from bytes that are already
  /// in memory.
  ///
  /// Web has no filesystem, so this method is the only render path there. This
  /// method runs the same C loop as the exporter, over the same decoders.
  /// Therefore the output is byte-identical on all six targets, and not on
  /// five.
  ///
  /// On native, when the audio is a file, [renderPcm] is the better choice.
  /// [renderPcm] streams the source. This method holds a copy of the container
  /// in memory as well.
  Future<Int16List> renderPcmBytes({
    required Uint8List bytes,
    required WaveformDocument document,
  });

  /// This method reads from [sourcePath] and opens a playback session over
  /// [document].
  ///
  /// The audio that the session plays is byte-identical to the audio that
  /// [exportWav] writes, because both run the same C loop. You listen to an
  /// edit before you commit to it. That is useful only when what you hear is
  /// what you get.
  ///
  /// Web has no filesystem to read a source from, so this method is not
  /// available there.
  Future<PlaybackSession> openPlayback({
    required String sourcePath,
    required WaveformDocument document,
  });

  /// This method opens a playback session over bytes that are already in
  /// memory.
  ///
  /// Web has no filesystem, so this method is the only playback path there. On
  /// native, this method uses the same engine as [openPlayback]. It reads from
  /// a copy of the bytes, and it does not stream a file.
  ///
  /// The audio that plays is byte-identical to the audio that [exportWav]
  /// writes on every target, because every target renders through the same C
  /// loop. Only the device is different. Native targets use miniaudio. Web
  /// uses a WebAudio graph.
  Future<PlaybackSession> openPlaybackBytes({
    required Uint8List bytes,
    required WaveformDocument document,
  });

  /// This method opens a microphone capture session.
  ///
  /// This method does not request permission. A headless package has no UI to
  /// give the reason for the request, and the host has one. If the permission
  /// is not already granted, this method throws [CaptureUnavailable].
  Future<CaptureSession> openCapture([
    CaptureConfig config = const CaptureConfig(),
  ]);
}

/// The reason that a decode failed. These values mirror the error codes of the
/// C core.
enum DecodeFailure {
  /// The decoder cannot open the input or read it.
  unreadable,

  /// The container is not WAV, MP3 or FLAC.
  ///
  /// AAC/M4A gets this failure, because it needs a platform decoder that
  /// monowave does not carry. The voice-note path computes peaks at record
  /// time, so it avoids this failure completely.
  unsupportedFormat,

  /// The decoder accepted a stream, then it failed part-way through that
  /// stream.
  corrupt,

  /// The input decoded to no audio at all.
  empty,

  /// An allocation failed, or a caller passed an invalid value.
  internal,
}

/// This exception shows that a decode did not produce peaks.
class MonowaveDecodeException implements Exception {
  const MonowaveDecodeException(this.failure, this.message);

  final DecodeFailure failure;
  final String message;

  @override
  String toString() => 'MonowaveDecodeException(${failure.name}): $message';
}

/// This exception shows that the C core of the platform is not available, or
/// that the C core did not load.
class MonowaveUnavailable implements Exception {
  const MonowaveUnavailable(this.message);

  final String message;

  @override
  String toString() => 'MonowaveUnavailable: $message';
}
