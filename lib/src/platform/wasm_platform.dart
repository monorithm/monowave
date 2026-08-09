import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

import '../capture/capture_session.dart';
import '../edit/waveform_document.dart';
import '../model/waveform_peaks.dart';
import 'monowave_platform.dart';

/// The default [MonowavePlatform] on web.
MonowavePlatform defaultPlatform() => WasmMonowavePlatform();

/// WASI's ENOSYS. Returned by the file-descriptor stubs below.
const _enosys = 52;

@JS('WebAssembly.instantiate')
external JSPromise<_Instantiated> _instantiate(
  JSUint8Array bytes,
  _Imports imports,
);

extension type _Instantiated._(JSObject _o) implements JSObject {
  external _Instance get instance;
}

extension type _Imports._(JSObject _o) implements JSObject {
  external factory _Imports({_Env env, _Wasi wasi_snapshot_preview1});
}

/// libc drags three file-descriptor imports in even though the decoders' file
/// halves are compiled out, and they are unreachable from `wf_decode_memory`.
/// ENOSYS stubs satisfy the linker without pretending web has a filesystem.
extension type _Wasi._(JSObject _o) implements JSObject {
  // Wire names, not Dart ones.
  // ignore_for_file: non_constant_identifier_names
  external factory _Wasi({
    JSFunction fd_close,
    JSFunction fd_write,
    JSFunction fd_seek,
  });
}

/// `-sALLOW_MEMORY_GROWTH` makes the module import this so JS can refresh its
/// cached heap views. Monowave re-reads the buffer on every call instead, so the
/// callback does nothing - but the import must still be satisfied or
/// instantiation throws.
extension type _Env._(JSObject _o) implements JSObject {
  external factory _Env({JSFunction emscripten_notify_memory_growth});
}

extension type _Instance._(JSObject _o) implements JSObject {
  external _Core get exports;
}

/// The module's exports, typed.
///
/// Extension types rather than `dart:js_interop_unsafe` so a rename in `src/`
/// is a compile error here instead of a runtime `undefined is not a function`.
extension type _Core._(JSObject _o) implements JSObject {
  @JS('wf_abi_version')
  external int abiVersion();

  @JS('wf_reduce_minmax')
  external void reduceMinMax(int samples, int count, int outMin, int outMax);

  @JS('wf_decode_memory')
  external int decodeMemory(int data, int size, int baseSpp, int outError);

  @JS('wf_peaks_sample_rate')
  external int peaksSampleRate(int peaks);

  @JS('wf_peaks_channels')
  external int peaksChannels(int peaks);

  // A double, not an i64: an i64 would arrive in JavaScript as a BigInt.
  @JS('wf_peaks_length')
  external double peaksLength(int peaks);

  @JS('wf_peaks_levels')
  external int peaksLevels(int peaks);

  @JS('wf_peaks_base_spp')
  external int peaksBaseSpp(int peaks);

  @JS('wf_peaks_pair_count')
  external int peaksPairCount(int peaks, int level);

  @JS('wf_peaks_data')
  external int peaksData(int peaks, int level);

  @JS('wf_peaks_rms')
  external int peaksRms(int peaks, int level);

  @JS('wf_peaks_free')
  external void peaksFree(int peaks);

  external int malloc(int bytes);
  external void free(int ptr);
  external _Memory get memory;

  /// STANDALONE_WASM builds the reactor model, so static initializers do not
  /// run until this is called.
  @JS('_initialize')
  external void initialize();
}

extension type _Memory._(JSObject _o) implements JSObject {
  external JSArrayBuffer get buffer;
}

/// Calls the same C core the native targets do, compiled to WASM by
/// `tool/build_wasm.sh` and shipped as `assets/monowave.wasm`.
///
/// Running the same source everywhere is the property this whole architecture
/// exists to guarantee, so there is deliberately no pure-Dart fallback here: a
/// shim would pass CI while quietly making web the one target that answers
/// differently.
class WasmMonowavePlatform implements MonowavePlatform {
  _Core? _exports;
  Future<void>? _loading;

  @override
  Future<void> ensureInitialized() => _loading ??= _load();

  Future<void> _load() async {
    final data = await rootBundle.load(
      'packages/monowave/assets/monowave.wasm',
    );
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );

    final result = await _instantiate(
      bytes.toJS,
      _Imports(
        env: _Env(emscripten_notify_memory_growth: ((int _) {}).toJS),
        wasi_snapshot_preview1: _Wasi(
          fd_close: (() => _enosys).toJS,
          fd_write: (() => _enosys).toJS,
          fd_seek: (() => _enosys).toJS,
        ),
      ),
    ).toDart;

    final core = result.instance.exports..initialize();
    _exports = core;
  }

  _Core get _core =>
      _exports ??
      (throw const MonowaveUnavailable(
        'Call MonowavePlatform.instance.ensureInitialized() before using the '
        'core on web.',
      ));

  /// The module's linear memory, re-read on every call rather than cached.
  ///
  /// Growing the WASM heap detaches every outstanding view over it, so a cached
  /// buffer survives right up until an allocation makes it silently wrong. The
  /// symptom is corrupt peaks that look like a decoder bug.
  ByteBuffer _heapOf(_Core core) => core.memory.buffer.toDart;

  @override
  int abiVersion() => _core.abiVersion();

  @override
  MinMax reduceMinMax(Int16List samples) {
    if (samples.isEmpty) return (min: 0, max: 0);

    final core = _core;
    final ptr = core.malloc(samples.length * 2);
    final outMin = core.malloc(2);
    final outMax = core.malloc(2);

    try {
      // After the allocations, never before.
      _heapOf(core).asInt16List(ptr, samples.length).setAll(0, samples);

      core.reduceMinMax(ptr, samples.length, outMin, outMax);

      final heap = _heapOf(core);
      return (
        min: heap.asInt16List(outMin, 1).first,
        max: heap.asInt16List(outMax, 1).first,
      );
    } finally {
      core
        ..free(ptr)
        ..free(outMin)
        ..free(outMax);
    }
  }

  @override
  Future<WaveformPeaks> decodeFile(
    String path, {
    int baseSamplesPerPixel = 128,
  }) async => throw const MonowaveDecodeException(
    DecodeFailure.unreadable,
    'Web has no filesystem. Fetch the audio and use decodeBytes instead.',
  );

  @override
  Future<WaveformPeaks> decodeBytes(
    Uint8List bytes, {
    int baseSamplesPerPixel = 128,
  }) async {
    final core = _core;

    final input = core.malloc(bytes.length);
    final error = core.malloc(4);
    if (input == 0 || error == 0) {
      throw const MonowaveDecodeException(
        DecodeFailure.internal,
        'The WASM heap could not grow to hold the input.',
      );
    }

    int peaks = 0;
    try {
      // Re-acquired after the allocations, never cached across them.
      _heapOf(core).asUint8List(input, bytes.length).setAll(0, bytes);

      peaks = core.decodeMemory(
        input,
        bytes.length,
        baseSamplesPerPixel,
        error,
      );
      if (peaks == 0) {
        throw _failure(_heapOf(core).asInt32List(error, 1).first, bytes.length);
      }

      return _copyOut(core, peaks, baseSamplesPerPixel);
    } finally {
      if (peaks != 0) core.peaksFree(peaks);
      core
        ..free(input)
        ..free(error);
    }
  }

  @override
  Future<void> exportWav({
    required String sourcePath,
    required String outputPath,
    required WaveformDocument document,
  }) async => throw const MonowaveDecodeException(
    DecodeFailure.unreadable,
    'Web has no filesystem to write to. An in-memory export would be the way '
    'to support this if something needs it.',
  );

  @override
  Future<CaptureSession> openCapture([
    CaptureConfig config = const CaptureConfig(),
  ]) async => throw const CaptureUnavailable(
    'Capture is not implemented on web yet. It will not go through miniaudio '
    'when it is: the browser already provides getUserMedia and AudioWorklet, '
    'and miniaudio would drag emscripten\'s JS runtime into an artifact that '
    'is deliberately standalone. See '
    'https://monorithm.github.io/opensource/monowave/latest/20-concepts/90-architecture/'
    '. Decode and rendering work on web today.',
  );

  /// Copies both series of the pyramid out of the WASM heap, unlike the FFI
  /// path which views them in place.
  ///
  /// This is deliberate and it is the one place web pays more than native.
  /// Growing the heap detaches every view over it, so a long-lived view would
  /// stay correct only until the next allocation anywhere in the module - an
  /// aliasing bug that would surface as corrupt peaks much later. Copying costs
  /// a few hundred kilobytes for a normal recording; native keeps the zero-copy
  /// path, which is what an audiobook needs.
  WaveformPeaks _copyOut(_Core core, int peaks, int baseSamplesPerPixel) {
    final levelCount = core.peaksLevels(peaks);
    final levels = <Int16List>[];
    final rms = <Int16List>[];

    for (var level = 0; level < levelCount; level++) {
      final pairs = core.peaksPairCount(peaks, level);

      final data = core.peaksData(peaks, level);
      levels.add(
        Int16List.fromList(_heapOf(core).asInt16List(data, pairs * 2)),
      );

      // One value per pair rather than two: RMS is a single series running
      // alongside the interleaved min/max, not a third and fourth column of it.
      final loudness = core.peaksRms(peaks, level);
      rms.add(Int16List.fromList(_heapOf(core).asInt16List(loudness, pairs)));
    }

    return WaveformPeaks.fromLevels(
      levels,
      rms: rms,
      sampleRate: core.peaksSampleRate(peaks),
      channels: core.peaksChannels(peaks),
      lengthInSamples: core.peaksLength(peaks).toInt(),
      baseSamplesPerPixel: core.peaksBaseSpp(peaks),
    );
  }
}

/// Maps the C error codes in `monowave.h` onto [DecodeFailure].
MonowaveDecodeException _failure(int code, int size) {
  final failure = switch (code) {
    1 => DecodeFailure.unreadable,
    2 => DecodeFailure.unsupportedFormat,
    3 => DecodeFailure.corrupt,
    6 => DecodeFailure.empty,
    _ => DecodeFailure.internal,
  };
  return MonowaveDecodeException(failure, 'Could not decode $size bytes');
}
