import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../capture/capture_session.dart';
import '../edit/waveform_document.dart';
import '../capture/ffi_capture_session.dart';
import '../playback/ffi_playback_session.dart';
import '../playback/playback_session.dart';
import '../model/waveform_peaks.dart';
import '../native/monowave_bindings.dart' as bindings;
import 'monowave_platform.dart';

/// The default [MonowavePlatform] on the five native targets.
MonowavePlatform defaultPlatform() => const FfiMonowavePlatform();

/// Keeps a native pyramid alive, and frees it when nothing references it.
///
/// [WaveformPeaks] hands out views straight into this allocation, so it must
/// outlive them. The peaks object captures this holder in its dispose closure,
/// which is what keeps it reachable - drop the peaks and the finalizer runs.
final class _PeaksHandle implements Finalizable {
  _PeaksHandle(this.pointer) {
    _finalizer.attach(this, pointer.cast(), detach: this);
  }

  static final _finalizer = NativeFinalizer(bindings.wfPeaksFreeAddress);

  final Pointer<bindings.WfPeaks> pointer;
  bool _freed = false;

  void free() {
    if (_freed) return;
    _freed = true;
    _finalizer.detach(this);
    bindings.wfPeaksFree(pointer);
  }
}

/// Calls the C core directly over `dart:ffi`.
///
/// The code asset is built by `hook/build.dart`, so there is no plugin
/// registration, no method channel, and no per-platform scaffolding here.
class FfiMonowavePlatform implements MonowavePlatform {
  const FfiMonowavePlatform();

  /// A no-op. The code asset is resolved by the VM at startup; there is nothing
  /// to load. Present only so hosts can write one initialization path that
  /// works on all six targets.
  @override
  Future<void> ensureInitialized() async {}

  @override
  int abiVersion() => bindings.wfAbiVersion();

  @override
  MinMax reduceMinMax(Int16List samples) {
    // Copies into native memory, unlike the decode path below. That is fine for
    // a single window; peaks from a real decode are never copied.
    final buffer = calloc<Int16>(samples.length);
    final outMin = calloc<Int16>();
    final outMax = calloc<Int16>();
    try {
      buffer.asTypedList(samples.length).setAll(0, samples);
      bindings.wfReduceMinMax(buffer, samples.length, outMin, outMax);
      return (min: outMin.value, max: outMax.value);
    } finally {
      calloc
        ..free(buffer)
        ..free(outMin)
        ..free(outMax);
    }
  }

  @override
  Future<WaveformPeaks> decodeFile(
    String path, {
    int baseSamplesPerPixel = 128,
  }) async {
    // Off the UI isolate: decoding an hour of audio is seconds of work, and a
    // dropped frame budget is 16 milliseconds. The pyramid stays in native
    // memory, so only its address crosses back - nothing is copied or
    // serialized between isolates.
    final address = await Isolate.run(
      () => _decodeFileToAddress(path, baseSamplesPerPixel),
    );
    return _wrap(address, baseSamplesPerPixel);
  }

  @override
  Future<WaveformPeaks> decodeBytes(
    Uint8List bytes, {
    int baseSamplesPerPixel = 128,
  }) async {
    final address = await Isolate.run(
      () => _decodeBytesToAddress(bytes, baseSamplesPerPixel),
    );
    return _wrap(address, baseSamplesPerPixel);
  }

  @override
  Future<void> exportWav({
    required String sourcePath,
    required String outputPath,
    required WaveformDocument document,
  }) async {
    if (document.isEmpty) {
      throw const MonowaveDecodeException(
        DecodeFailure.empty,
        'There is nothing to export: the document has no regions.',
      );
    }

    // Off the UI isolate, like decoding: exporting an hour of audio is seconds
    // of work, and it reads through the same decoders.
    final regions = [
      for (final region in document.regions)
        (
          region.sourceStart,
          region.sourceEnd,
          region.gain,
          region.fadeIn,
          region.fadeOut,
        ),
    ];

    // Off the UI isolate, like decoding: exporting an hour of audio reads the
    // whole file through the decoder.
    final code = await Isolate.run(
      () => _exportToPath(sourcePath, outputPath, regions),
    );
    if (code != 0) {
      throw MonowaveDecodeException(switch (code) {
        1 => DecodeFailure.unreadable,
        3 => DecodeFailure.corrupt,
        _ => DecodeFailure.internal,
      }, 'Export to \$outputPath failed (code \$code)');
    }
  }

  @override
  Future<Int16List> renderPcm({
    required String sourcePath,
    required WaveformDocument document,
  }) async {
    if (document.isEmpty) {
      throw const MonowaveDecodeException(
        DecodeFailure.empty,
        'There is nothing to render: the document has no regions.',
      );
    }

    final regions = [
      for (final region in document.regions)
        (
          region.sourceStart,
          region.sourceEnd,
          region.gain,
          region.fadeIn,
          region.fadeOut,
        ),
    ];

    // Off the UI isolate, like decoding and exporting: rendering reads the
    // source through the same decoders and is seconds of work for a long take.
    return Isolate.run(() => _renderToPcm(sourcePath, regions));
  }

  @override
  Future<Int16List> renderPcmBytes({
    required Uint8List bytes,
    required WaveformDocument document,
  }) async {
    if (document.isEmpty) {
      throw const MonowaveDecodeException(
        DecodeFailure.empty,
        'There is nothing to render: the document has no regions.',
      );
    }

    final regions = [
      for (final region in document.regions)
        (
          region.sourceStart,
          region.sourceEnd,
          region.gain,
          region.fadeIn,
          region.fadeOut,
        ),
    ];

    return Isolate.run(() => _renderBytesToPcm(bytes, regions));
  }

  @override
  Future<PlaybackSession> openPlayback({
    required String sourcePath,
    required WaveformDocument document,
  }) => FfiPlaybackSession.open(sourcePath: sourcePath, document: document);

  @override
  Future<PlaybackSession> openPlaybackBytes({
    required Uint8List bytes,
    required WaveformDocument document,
  }) => FfiPlaybackSession.openBytes(bytes: bytes, document: document);

  @override
  Future<CaptureSession> openCapture([
    CaptureConfig config = const CaptureConfig(),
  ]) => FfiCaptureSession.open(config);

  /// Builds the Dart-side pyramid as views over the native allocation.
  static WaveformPeaks _wrap(int address, int baseSamplesPerPixel) {
    final pointer = Pointer<bindings.WfPeaks>.fromAddress(address);
    final handle = _PeaksHandle(pointer);

    try {
      final levels = <Int16List>[
        for (var level = 0; level < bindings.wfPeaksLevels(pointer); level++)
          bindings
              .wfPeaksData(pointer, level)
              .asTypedList(bindings.wfPeaksPairCount(pointer, level) * 2),
      ];

      final rms = <Int16List>[
        for (var level = 0; level < bindings.wfPeaksLevels(pointer); level++)
          bindings
              .wfPeaksRms(pointer, level)
              .asTypedList(bindings.wfPeaksPairCount(pointer, level)),
      ];

      return WaveformPeaks.fromLevels(
        levels,
        rms: rms,
        sampleRate: bindings.wfPeaksSampleRate(pointer),
        channels: bindings.wfPeaksChannels(pointer),
        lengthInSamples: bindings.wfPeaksLength(pointer).toInt(),
        baseSamplesPerPixel: bindings.wfPeaksBaseSamplesPerPixel(pointer),
        onDispose: handle.free,
      );
    } catch (_) {
      handle.free();
      rethrow;
    }
  }
}

/// Runs in a helper isolate. Returns the pyramid's address, or throws.
int _decodeFileToAddress(String path, int baseSamplesPerPixel) {
  final nativePath = path.toNativeUtf8();
  final error = calloc<Int32>();
  try {
    final peaks = bindings.wfDecodeFile(
      nativePath.cast(),
      baseSamplesPerPixel,
      error,
    );
    if (peaks == nullptr) throw _failure(error.value, path);
    return peaks.address;
  } finally {
    calloc
      ..free(nativePath)
      ..free(error);
  }
}

int _decodeBytesToAddress(Uint8List bytes, int baseSamplesPerPixel) {
  final buffer = calloc<Uint8>(bytes.length);
  final error = calloc<Int32>();
  try {
    buffer.asTypedList(bytes.length).setAll(0, bytes);
    final peaks = bindings.wfDecodeMemory(
      buffer.cast(),
      bytes.length,
      baseSamplesPerPixel,
      error,
    );
    if (peaks == nullptr) throw _failure(error.value, '${bytes.length} bytes');
    return peaks.address;
  } finally {
    // The decoder has finished with the input by the time it returns; the
    // pyramid it produced is a separate allocation.
    calloc
      ..free(buffer)
      ..free(error);
  }
}

/// Runs in a helper isolate. Returns the C status code.
int _exportToPath(
  String sourcePath,
  String outputPath,
  List<(int, int, double, int, int)> regions,
) {
  final source = sourcePath.toNativeUtf8();
  final output = outputPath.toNativeUtf8();
  final buffer = calloc<bindings.WfRegion>(regions.length);
  try {
    for (var i = 0; i < regions.length; i++) {
      final (start, end, gain, fadeIn, fadeOut) = regions[i];
      buffer[i]
        ..sourceStart = start.toDouble()
        ..sourceEnd = end.toDouble()
        ..gain = gain
        ..fadeIn = fadeIn
        ..fadeOut = fadeOut;
    }

    return bindings.wfExportWav(
      source.cast(),
      output.cast(),
      buffer,
      regions.length,
    );
  } finally {
    calloc
      ..free(source)
      ..free(output)
      ..free(buffer);
  }
}

/// Runs in a helper isolate. Returns interleaved 16-bit PCM, or throws.
///
/// The block size is deliberately not the exporter's 4096. The two have to
/// agree sample for sample, and they only can because the envelope depends on
/// the position inside a region rather than on where a block happens to fall -
/// so rendering at a different size is the cheapest way to keep proving it.
Int16List _renderToPcm(
  String sourcePath,
  List<(int, int, double, int, int)> regions,
) {
  const blockFrames = 1000;

  final path = sourcePath.toNativeUtf8();
  final buffer = calloc<bindings.WfRegion>(regions.length);
  final error = calloc<Int32>();
  Pointer<bindings.WfRender> render = nullptr;
  Pointer<Int16> block = nullptr;

  try {
    for (var i = 0; i < regions.length; i++) {
      final (start, end, gain, fadeIn, fadeOut) = regions[i];
      buffer[i]
        ..sourceStart = start.toDouble()
        ..sourceEnd = end.toDouble()
        ..gain = gain
        ..fadeIn = fadeIn
        ..fadeOut = fadeOut;
    }

    render = bindings.wfRenderOpen(path.cast(), buffer, regions.length, error);
    if (render == nullptr) throw _failure(error.value, sourcePath);

    final channels = bindings.wfRenderChannels(render);
    final total = bindings.wfRenderLengthFrames(render).toInt() * channels;
    final out = Int16List(total);

    block = calloc<Int16>(blockFrames * channels);
    var written = 0;
    while (written < total) {
      final got = bindings.wfRenderRead(render, block, blockFrames);
      if (got < 0) {
        throw const MonowaveDecodeException(
          DecodeFailure.corrupt,
          'The source could not be read all the way through.',
        );
      }
      if (got == 0) break;

      final samples = got * channels;
      out.setRange(written, written + samples, block.asTypedList(samples));
      written += samples;
    }

    // A source that ends early is not an error, so the render can be shorter
    // than the region list asked for. Hand back what exists.
    return written == total ? out : Int16List.sublistView(out, 0, written);
  } finally {
    if (render != nullptr) bindings.wfRenderClose(render);
    if (block != nullptr) calloc.free(block);
    calloc
      ..free(path)
      ..free(buffer)
      ..free(error);
  }
}

/// Runs in a helper isolate. The memory twin of [_renderToPcm].
Int16List _renderBytesToPcm(
  Uint8List bytes,
  List<(int, int, double, int, int)> regions,
) {
  const blockFrames = 1000;

  final input = calloc<Uint8>(bytes.length);
  final buffer = calloc<bindings.WfRegion>(regions.length);
  final error = calloc<Int32>();
  Pointer<bindings.WfRender> render = nullptr;
  Pointer<Int16> block = nullptr;

  try {
    input.asTypedList(bytes.length).setAll(0, bytes);
    for (var i = 0; i < regions.length; i++) {
      final (start, end, gain, fadeIn, fadeOut) = regions[i];
      buffer[i]
        ..sourceStart = start.toDouble()
        ..sourceEnd = end.toDouble()
        ..gain = gain
        ..fadeIn = fadeIn
        ..fadeOut = fadeOut;
    }

    render = bindings.wfRenderOpenMemory(
      input.cast(),
      bytes.length,
      buffer,
      regions.length,
      error,
    );
    if (render == nullptr) {
      throw _failure(error.value, '${bytes.length} bytes');
    }

    final channels = bindings.wfRenderChannels(render);
    final total = bindings.wfRenderLengthFrames(render).toInt() * channels;
    final out = Int16List(total);

    block = calloc<Int16>(blockFrames * channels);
    var written = 0;
    while (written < total) {
      final got = bindings.wfRenderRead(render, block, blockFrames);
      if (got < 0) {
        throw const MonowaveDecodeException(
          DecodeFailure.corrupt,
          'The source could not be read all the way through.',
        );
      }
      if (got == 0) break;

      final samples = got * channels;
      out.setRange(written, written + samples, block.asTypedList(samples));
      written += samples;
    }

    return written == total ? out : Int16List.sublistView(out, 0, written);
  } finally {
    if (render != nullptr) bindings.wfRenderClose(render);
    if (block != nullptr) calloc.free(block);
    calloc
      ..free(input)
      ..free(buffer)
      ..free(error);
  }
}

/// Maps the C error codes in `monowave.h` onto [DecodeFailure].
MonowaveDecodeException _failure(int code, String source) {
  final failure = switch (code) {
    1 => DecodeFailure.unreadable,
    2 => DecodeFailure.unsupportedFormat,
    3 => DecodeFailure.corrupt,
    6 => DecodeFailure.empty,
    _ => DecodeFailure.internal,
  };
  return MonowaveDecodeException(failure, 'Could not decode $source');
}
