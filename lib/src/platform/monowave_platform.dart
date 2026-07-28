import 'dart:typed_data';

import '../capture/capture_session.dart';
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
/// Min/max rather than an average — averaging destroys transients and renders
/// speech as a flat sausage.
typedef MinMax = ({int min, int max});

/// The native seam every call into the C core crosses.
///
/// An interface rather than direct calls into the bindings so the engine can be
/// exercised against an in-memory fake with no native code and no device, the
/// same shape [monolens] uses for `MonolensPlatform`. It is also the line a
/// federated split would cut along, if one is ever needed.
///
/// [monolens]: https://github.com/monorithm/monolens
abstract interface class MonowavePlatform {
  /// The implementation calls run against. Assign a fake in `setUp` and restore
  /// null in `tearDown`.
  static MonowavePlatform get instance => _instance ??= impl.defaultPlatform();
  static set instance(MonowavePlatform? value) => _instance = value;
  static MonowavePlatform? _instance;

  /// Loads the native core, if it is not loaded already. Idempotent.
  ///
  /// This exists because of web. Native targets resolve their code asset at
  /// startup and have nothing to wait for, but instantiating a WASM module is
  /// inherently asynchronous. The alternative — making every method return a
  /// `Future` — would put an event-loop turn in front of [reduceMinMax], which
  /// is called once per frame while scrubbing and once per hop while capturing.
  /// One await up front is the cheaper shape.
  ///
  /// Every other method throws [MonowaveUnavailable] until this completes.
  Future<void> ensureInitialized();

  /// The C core's ABI version. Bumped whenever a signature in `src/` changes.
  int abiVersion();

  /// Reduces [samples] to the pair of extremes it spans.
  MinMax reduceMinMax(Int16List samples);

  /// Decodes the audio file at [path] into a peak pyramid.
  ///
  /// Not available on web, which has no filesystem — use [decodeBytes] there.
  /// Prefer this on native: the decoder streams the file a bucket at a time, so
  /// an audiobook never has to be resident in memory.
  ///
  /// Throws [MonowaveDecodeException] if the container cannot be read.
  Future<WaveformPeaks> decodeFile(
    String path, {
    int baseSamplesPerPixel = 128,
  });

  /// Decodes an in-memory container. The only decode path on web.
  Future<WaveformPeaks> decodeBytes(
    Uint8List bytes, {
    int baseSamplesPerPixel = 128,
  });

  /// Writes [document] to [outputPath] as 16-bit PCM WAV, reading from
  /// [sourcePath].
  ///
  /// Output is always WAV. An edit list is meant to reproduce the source
  /// exactly where it did not change it, and re-encoding to a lossy format
  /// would quietly break that.
  ///
  /// Not available on web, which has no filesystem to write to.
  Future<void> exportWav({
    required String sourcePath,
    required String outputPath,
    required WaveformDocument document,
  });

  /// Opens a microphone capture session.
  ///
  /// Does not request permission. A headless package has no UI to explain why
  /// it is asking, and the host does — so this throws [CaptureUnavailable] if
  /// the permission has not already been granted.
  Future<CaptureSession> openCapture([
    CaptureConfig config = const CaptureConfig(),
  ]);
}

/// Why a decode failed, mirroring the C core's error codes.
enum DecodeFailure {
  /// The input could not be opened or read.
  unreadable,

  /// The container was not one of WAV, MP3 or FLAC.
  ///
  /// AAC/M4A lands here: it needs a platform decoder monowave does not carry.
  /// The voice-note path avoids this entirely by computing peaks at record time.
  unsupportedFormat,

  /// The decoder failed part-way through a stream it had accepted.
  corrupt,

  /// The input decoded to no audio at all.
  empty,

  /// An allocation failed, or a caller passed something invalid.
  internal,
}

/// Thrown when a decode does not produce peaks.
class MonowaveDecodeException implements Exception {
  const MonowaveDecodeException(this.failure, this.message);

  final DecodeFailure failure;
  final String message;

  @override
  String toString() => 'MonowaveDecodeException(${failure.name}): $message';
}

/// Thrown when the platform's native core is unavailable or failed to load.
class MonowaveUnavailable implements Exception {
  const MonowaveUnavailable(this.message);

  final String message;

  @override
  String toString() => 'MonowaveUnavailable: $message';
}
