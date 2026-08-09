// Hand-written rather than ffigen output.
//
// The C surface is deliberately tiny - a decode entry point and a handful of
// accessors - and `@Native` declarations for it are shorter and more readable
// than generated bindings, with the same compile-time checking. Revisit if the
// surface ever grows past a screenful.
//
// The `@DefaultAsset` id must match `CBuilder.assetName` in `hook/build.dart`,
// prefixed with the package name.
@DefaultAsset('package:monowave/src/native/monowave_bindings.dart')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart' show Utf8;

/// Opaque handle to a pyramid the C side owns.
final class WfPeaks extends Opaque {}

/// The C core's ABI version. Bumped whenever a signature in `src/` changes.
@Native<Int32 Function()>(symbol: 'wf_abi_version')
external int wfAbiVersion();

/// Reduces [count] int16 samples at [samples] into the pair at [outMin]/[outMax].
@Native<Void Function(Pointer<Int16>, Int32, Pointer<Int16>, Pointer<Int16>)>(
  symbol: 'wf_reduce_minmax',
)
external void wfReduceMinMax(
  Pointer<Int16> samples,
  int count,
  Pointer<Int16> outMin,
  Pointer<Int16> outMax,
);

@Native<Pointer<WfPeaks> Function(Pointer<Utf8>, Int32, Pointer<Int32>)>(
  symbol: 'wf_decode_file',
)
external Pointer<WfPeaks> wfDecodeFile(
  Pointer<Utf8> path,
  int baseSamplesPerPixel,
  Pointer<Int32> outError,
);

@Native<Pointer<WfPeaks> Function(Pointer<Void>, Size, Int32, Pointer<Int32>)>(
  symbol: 'wf_decode_memory',
)
external Pointer<WfPeaks> wfDecodeMemory(
  Pointer<Void> data,
  int size,
  int baseSamplesPerPixel,
  Pointer<Int32> outError,
);

@Native<Int32 Function(Pointer<WfPeaks>)>(symbol: 'wf_peaks_sample_rate')
external int wfPeaksSampleRate(Pointer<WfPeaks> peaks);

@Native<Int32 Function(Pointer<WfPeaks>)>(symbol: 'wf_peaks_channels')
external int wfPeaksChannels(Pointer<WfPeaks> peaks);

@Native<Double Function(Pointer<WfPeaks>)>(symbol: 'wf_peaks_length')
external double wfPeaksLength(Pointer<WfPeaks> peaks);

@Native<Int32 Function(Pointer<WfPeaks>)>(symbol: 'wf_peaks_levels')
external int wfPeaksLevels(Pointer<WfPeaks> peaks);

@Native<Int32 Function(Pointer<WfPeaks>)>(symbol: 'wf_peaks_base_spp')
external int wfPeaksBaseSamplesPerPixel(Pointer<WfPeaks> peaks);

@Native<Int32 Function(Pointer<WfPeaks>, Int32)>(symbol: 'wf_peaks_pair_count')
external int wfPeaksPairCount(Pointer<WfPeaks> peaks, int level);

@Native<Pointer<Int16> Function(Pointer<WfPeaks>, Int32)>(
  symbol: 'wf_peaks_data',
)
external Pointer<Int16> wfPeaksData(Pointer<WfPeaks> peaks, int level);

@Native<Pointer<Int16> Function(Pointer<WfPeaks>, Int32)>(
  symbol: 'wf_peaks_rms',
)
external Pointer<Int16> wfPeaksRms(Pointer<WfPeaks> peaks, int level);

@Native<Void Function(Pointer<WfPeaks>)>(symbol: 'wf_peaks_free')
external void wfPeaksFree(Pointer<WfPeaks> peaks);

// --- Capture ----------------------------------------------------------------

/// Opaque handle to a running capture session.
final class WfCapture extends Opaque {}

/// One reduced hop: `{int16 min, int16 max, int16 rms}`.
///
/// Three int16s with alignment 2, so the struct is exactly 6 bytes with no
/// padding and a drained block can be read as a flat Int16List.
final class WfFrame extends Struct {
  @Int16()
  external int min;
  @Int16()
  external int max;
  @Int16()
  external int rms;
}

@Native<
  Pointer<WfCapture> Function(
    Int32,
    Int32,
    Int32,
    Int32,
    Int32,
    Int32,
    Pointer<Int32>,
  )
>(symbol: 'wf_capture_create')
external Pointer<WfCapture> wfCaptureCreate(
  int sampleRate,
  int channels,
  int hop,
  int ringCapacity,
  int takeCapacity,
  int pcmCapacity,
  Pointer<Int32> outError,
);

@Native<Int32 Function(Pointer<WfCapture>, Pointer<Int16>, Int32)>(
  symbol: 'wf_capture_drain_pcm',
)
external int wfCaptureDrainPcm(
  Pointer<WfCapture> capture,
  Pointer<Int16> out,
  int maxSamples,
);

@Native<Double Function(Pointer<WfCapture>)>(symbol: 'wf_capture_pcm_dropped')
external double wfCapturePcmDropped(Pointer<WfCapture> capture);

@Native<Int32 Function(Pointer<WfCapture>)>(symbol: 'wf_capture_start')
external int wfCaptureStart(Pointer<WfCapture> capture);

@Native<Int32 Function(Pointer<WfCapture>)>(symbol: 'wf_capture_stop')
external int wfCaptureStop(Pointer<WfCapture> capture);

@Native<Int32 Function(Pointer<WfCapture>)>(symbol: 'wf_capture_pause')
external int wfCapturePause(Pointer<WfCapture> capture);

@Native<Int32 Function(Pointer<WfCapture>)>(symbol: 'wf_capture_resume')
external int wfCaptureResume(Pointer<WfCapture> capture);

@Native<Void Function(Pointer<WfCapture>)>(symbol: 'wf_capture_destroy')
external void wfCaptureDestroy(Pointer<WfCapture> capture);

@Native<Int32 Function(Pointer<WfCapture>, Pointer<WfFrame>, Int32)>(
  symbol: 'wf_capture_drain',
)
external int wfCaptureDrain(
  Pointer<WfCapture> capture,
  Pointer<WfFrame> out,
  int max,
);

/// Drain scratch the session owns, rather than a buffer allocated here.
///
/// A `calloc` on this side would have to be freed on this side, and a session
/// that is dropped without `dispose()` never gets the chance - the finalizer
/// over [wfCaptureDestroy] can only release what the C struct owns. Sizes come
/// from C too, so the two cannot drift.
@Native<Pointer<WfFrame> Function(Pointer<WfCapture>)>(
  symbol: 'wf_capture_scratch',
)
external Pointer<WfFrame> wfCaptureScratch(Pointer<WfCapture> capture);

@Native<Int32 Function(Pointer<WfCapture>)>(symbol: 'wf_capture_scratch_frames')
external int wfCaptureScratchFrames(Pointer<WfCapture> capture);

/// The PCM equivalent. `nullptr`, with a size of zero, when the session keeps
/// no audio.
@Native<Pointer<Int16> Function(Pointer<WfCapture>)>(
  symbol: 'wf_capture_pcm_scratch',
)
external Pointer<Int16> wfCapturePcmScratch(Pointer<WfCapture> capture);

@Native<Int32 Function(Pointer<WfCapture>)>(
  symbol: 'wf_capture_pcm_scratch_samples',
)
external int wfCapturePcmScratchSamples(Pointer<WfCapture> capture);

/// Sessions the C core has created and not yet destroyed.
///
/// The seam the finalizer test asserts on: a session dropped without `dispose()`
/// must eventually bring this back down on its own.
@Native<Int32 Function()>(symbol: 'wf_capture_live')
external int wfCaptureLive();

@Native<Double Function(Pointer<WfCapture>)>(symbol: 'wf_capture_produced')
external double wfCaptureProduced(Pointer<WfCapture> capture);

@Native<Double Function(Pointer<WfCapture>)>(symbol: 'wf_capture_dropped')
external double wfCaptureDropped(Pointer<WfCapture> capture);

@Native<Int32 Function(Pointer<WfCapture>)>(symbol: 'wf_capture_overflowed')
external int wfCaptureOverflowed(Pointer<WfCapture> capture);

@Native<Pointer<WfPeaks> Function(Pointer<WfCapture>, Pointer<Int32>)>(
  symbol: 'wf_capture_take_peaks',
)
external Pointer<WfPeaks> wfCaptureTakePeaks(
  Pointer<WfCapture> capture,
  Pointer<Int32> outError,
);

/// The audio-thread entry point, exposed so tests can drive the realtime path
/// with synthetic PCM and no microphone.
@Native<Void Function(Pointer<WfCapture>, Pointer<Int16>, Int32)>(
  symbol: 'wf_capture_feed',
)
external void wfCaptureFeed(
  Pointer<WfCapture> capture,
  Pointer<Int16> interleaved,
  int frames,
);

// --- Export -----------------------------------------------------------------

/// One slice of the source to write out. Mirrors `wf_region` in `monowave.h`.
final class WfRegion extends Struct {
  // Doubles rather than Int64 for the offsets, for the same reason
  // wf_peaks_length returns one: an i64 reaches JavaScript as a BigInt.
  @Double()
  external double sourceStart;
  @Double()
  external double sourceEnd;
  @Float()
  external double gain;
  @Int32()
  external int fadeIn;
  @Int32()
  external int fadeOut;
}

@Native<Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<WfRegion>, Int32)>(
  symbol: 'wf_export_wav',
)
external int wfExportWav(
  Pointer<Utf8> sourcePath,
  Pointer<Utf8> outputPath,
  Pointer<WfRegion> regions,
  int regionCount,
);

/// The address of [wfPeaksFree], for attaching to a [NativeFinalizer].
final Pointer<NativeFinalizerFunction> wfPeaksFreeAddress =
    Native.addressOf<NativeFunction<Void Function(Pointer<WfPeaks>)>>(
      wfPeaksFree,
    ).cast();

/// The address of [wfCaptureDestroy], for attaching to a [NativeFinalizer].
///
/// `wf_capture_destroy` stops the device before it frees anything, so a session
/// collected without `dispose()` releases the microphone as well as the memory.
final Pointer<NativeFinalizerFunction> wfCaptureDestroyAddress =
    Native.addressOf<NativeFunction<Void Function(Pointer<WfCapture>)>>(
      wfCaptureDestroy,
    ).cast();
