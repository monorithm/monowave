// monowave's C core: the only place audio is actually processed.
//
// The same source is reached two ways - over `dart:ffi` on the five native
// targets, and compiled to WASM for web - so anything that behaves differently
// between the two breaks the property this architecture exists to guarantee.
// Keep it free of platform assumptions.

#ifndef MONOWAVE_H
#define MONOWAVE_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#define WF_EXPORT __declspec(dllexport)
#else
#define WF_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Bumped whenever a signature below changes. Dart asserts on it at startup.
#define WF_ABI_VERSION 8

// Cap on pyramid depth. 24 levels at a 128-sample base covers a bit over a
// billion samples per pair - far past any real recording.
#define WF_MAX_LEVELS 24

enum {
  WF_OK = 0,
  WF_ERR_OPEN = 1,      // could not open or read the input
  WF_ERR_FORMAT = 2,    // container not recognised
  WF_ERR_DECODE = 3,    // decoder failed part-way through
  WF_ERR_MEMORY = 4,    // allocation failed
  WF_ERR_ARGUMENT = 5,  // caller passed something invalid
  WF_ERR_EMPTY = 6,     // decoded to zero frames
  WF_ERR_DEVICE = 7,    // no capture device, or it refused to start
  WF_ERR_STATE = 8      // called in the wrong order
};

/// An opaque min/max pyramid, owned by the C side.
///
/// Dart holds typed-data views over `wf_peaks_data`, never a copy, so a
/// three-hour recording never touches the Dart heap.
typedef struct wf_peaks wf_peaks;

WF_EXPORT int32_t wf_abi_version(void);

/// Reduces `count` int16 samples to a single min/max pair.
WF_EXPORT void wf_reduce_minmax(const int16_t *samples, int32_t count,
                                int16_t *out_min, int16_t *out_max);

/// Decodes `path` and builds a pyramid at `base_spp` samples per pair.
///
/// Not available when built without stdio (the WASM build), where it always
/// reports WF_ERR_OPEN - web has no filesystem to read.
WF_EXPORT wf_peaks *wf_decode_file(const char *path, int32_t base_spp,
                                   int32_t *out_error);

/// Decodes an in-memory container. The web path, and the way tests avoid
/// touching a filesystem.
WF_EXPORT wf_peaks *wf_decode_memory(const void *data, size_t size,
                                     int32_t base_spp, int32_t *out_error);

WF_EXPORT int32_t wf_peaks_sample_rate(const wf_peaks *peaks);
WF_EXPORT int32_t wf_peaks_channels(const wf_peaks *peaks);
/// Frames per channel in the source audio.
///
/// A double rather than an int64: WASM would surface an i64 to JavaScript as a
/// BigInt, and 2^53 samples is over a thousand years of audio.
WF_EXPORT double wf_peaks_length(const wf_peaks *peaks);
WF_EXPORT int32_t wf_peaks_levels(const wf_peaks *peaks);
WF_EXPORT int32_t wf_peaks_base_spp(const wf_peaks *peaks);
WF_EXPORT int32_t wf_peaks_pair_count(const wf_peaks *peaks, int32_t level);
/// Interleaved `[min, max, ...]` for `level`. Valid until wf_peaks_free.
WF_EXPORT const int16_t *wf_peaks_data(const wf_peaks *peaks, int32_t level);

/// One RMS value per pair at `level`. Valid until wf_peaks_free.
///
/// Peaks say how far the audio went; RMS says how much of it there was. Drawing
/// both - a peak hull with an RMS core inside it - is what every serious
/// waveform display does, because the hull alone is dominated by outliers.
///
/// Coarser levels combine children as the root of the mean of their squares,
/// which is what keeps the value an RMS rather than an average of averages.
WF_EXPORT const int16_t *wf_peaks_rms(const wf_peaks *peaks, int32_t level);
WF_EXPORT void wf_peaks_free(wf_peaks *peaks);

// --- Capture ----------------------------------------------------------------

/// One hop of audio, already reduced. The only thing that crosses the ring.
///
/// Reducing on the audio thread is what keeps the transport tiny: at a 512
/// sample hop and 44.1 kHz this is about 86 structs per second, roughly 516
/// bytes, instead of 176 kB of PCM.
typedef struct {
  int16_t min;
  int16_t max;
  int16_t rms;
} wf_frame;

typedef struct wf_capture wf_capture;

/// Frames `wf_capture_scratch` holds. At the default hop a 16 ms drain produces
/// one or two, so this is headroom for a stalled consumer catching up.
#define WF_SCRATCH_FRAMES 256

/// Samples `wf_capture_pcm_scratch` holds. 16 ms at 44.1 kHz is 706 samples, so
/// this is about a quarter second of slack.
#define WF_SCRATCH_SAMPLES 16384

/// Allocates a session. Nothing here runs on the audio thread.
///
/// `ring_capacity` is rounded up to a power of two. `take_capacity` bounds how
/// many hops `wf_capture_take_peaks` can return; past it, capture keeps running
/// and `wf_capture_overflowed` reports the truncation rather than growing a
/// buffer from the audio callback, which is forbidden.
WF_EXPORT wf_capture *wf_capture_create(int32_t sample_rate, int32_t channels,
                                        int32_t hop, int32_t ring_capacity,
                                        int32_t take_capacity,
                                        int32_t pcm_capacity,
                                        int32_t *out_error);

WF_EXPORT int32_t wf_capture_start(wf_capture *capture);
WF_EXPORT int32_t wf_capture_stop(wf_capture *capture);

/// Stops the device without discarding anything.
///
/// The rings, the hop accumulator and the history all survive, so resuming
/// continues the same take rather than starting a new one.
WF_EXPORT int32_t wf_capture_pause(wf_capture *capture);
WF_EXPORT int32_t wf_capture_resume(wf_capture *capture);
WF_EXPORT void wf_capture_destroy(wf_capture *capture);

/// Moves up to `max` reduced frames out of the ring. Consumer side; safe to
/// call from any one thread while the audio thread produces.
WF_EXPORT int32_t wf_capture_drain(wf_capture *capture, wf_frame *out,
                                   int32_t max);

/// Scratch for `wf_capture_drain` to write into, allocated with the session and
/// freed by `wf_capture_destroy`. Holds `WF_SCRATCH_FRAMES` frames.
///
/// A caller is free to pass its own buffer instead. This exists for bindings
/// that cannot free memory deterministically: a garbage-collected session is
/// reclaimed by a finalizer over `wf_capture_destroy`, which can only release
/// what the session owns, so a drain buffer allocated on the other side of the
/// boundary would outlive the struct it belongs to.
WF_EXPORT wf_frame *wf_capture_scratch(wf_capture *capture);
WF_EXPORT int32_t wf_capture_scratch_frames(const wf_capture *capture);

/// The same, for `wf_capture_drain_pcm`. NULL, and a size of zero, when the
/// session was created with a `pcm_capacity` of 0 and keeps no audio.
WF_EXPORT int16_t *wf_capture_pcm_scratch(wf_capture *capture);
WF_EXPORT int32_t wf_capture_pcm_scratch_samples(const wf_capture *capture);

/// Sessions created and not yet destroyed, across the whole process.
///
/// Exported for the same reason `wf_capture_feed` is: it makes a binding's
/// ownership testable rather than asserted. A binding that drops a session
/// without destroying it shows up here as a count that never falls.
WF_EXPORT int32_t wf_capture_live(void);

/// Hops the audio thread produced, and hops the consumer was too slow to take.
/// Doubles rather than int64 so both bindings can read them; see
/// wf_peaks_length for why.
WF_EXPORT double wf_capture_produced(const wf_capture *capture);
WF_EXPORT double wf_capture_dropped(const wf_capture *capture);

/// Whether the take buffer filled and stopped recording history.
WF_EXPORT int32_t wf_capture_overflowed(const wf_capture *capture);

/// A pyramid for everything captured since the last start.
WF_EXPORT wf_peaks *wf_capture_take_peaks(wf_capture *capture,
                                          int32_t *out_error);

/// Moves up to `max_samples` raw interleaved samples out of the PCM ring.
///
/// Capture keeps the reduction *and* the audio, in two separate rings. The
/// audio thread only ever copies into them; writing a file is the consumer's
/// job, because file I/O on an audio callback is exactly the kind of unbounded
/// operation that produces a glitch.
///
/// Returns the number of samples moved. Pass `pcm_capacity` of 0 to
/// wf_capture_create to skip keeping audio at all.
WF_EXPORT int32_t wf_capture_drain_pcm(wf_capture *capture, int16_t *out,
                                       int32_t max_samples);

/// Samples the PCM ring dropped because the consumer was too slow.
WF_EXPORT double wf_capture_pcm_dropped(const wf_capture *capture);

/// The audio-thread entry point: accumulate, reduce on hop boundaries, publish.
///
/// The device callback is a one-line wrapper around this. Exposing it directly
/// is what makes the realtime path testable on every platform with no device
/// attached, and it is the same code a real microphone drives.
///
/// Must not allocate, lock, or call into Dart. Nothing it calls does.
WF_EXPORT void wf_capture_feed(wf_capture *capture, const int16_t *interleaved,
                               int32_t frames);

// --- Export -----------------------------------------------------------------

/// One slice of the source to write out, with what to do to it on the way.
///
/// Doubles for the sample offsets rather than int64, for the same reason
/// wf_peaks_length returns one: an i64 reaches JavaScript as a BigInt.
typedef struct {
  double source_start;
  double source_end;
  float gain;
  int32_t fade_in;
  int32_t fade_out;
} wf_region;

/// Decodes `src_path`, writes the regions in order to `out_path` as 16-bit PCM
/// WAV, and returns WF_OK or an error code.
///
/// Input may be any container the decoder supports; output is always WAV,
/// because writing a lossy format would mean carrying an encoder for a
/// round-trip that is meant to be exact.
WF_EXPORT int32_t wf_export_wav(const char *src_path, const char *out_path,
                                const wf_region *regions, int32_t region_count);

// --- Internal, shared between translation units -----------------------------

/// Accumulates min/max pairs while a decoder streams frames in.
///
/// Streaming rather than decoding to one big buffer first: a three-hour file
/// would otherwise need hundreds of megabytes before any reduction happens.
typedef struct {
  int16_t *pairs;
  int16_t *rms;
  int64_t count;
  int64_t capacity;
  int failed;
} wf_pair_builder;

void wf_pair_builder_init(wf_pair_builder *builder);
void wf_pair_builder_push(wf_pair_builder *builder, int16_t lo, int16_t hi,
                          int16_t rms);
void wf_pair_builder_dispose(wf_pair_builder *builder);

/// Takes ownership of the builder's buffer and builds the coarser levels.
wf_peaks *wf_peaks_from_base(wf_pair_builder *builder, int32_t sample_rate,
                             int32_t channels, int64_t length,
                             int32_t base_spp);

#ifdef __cplusplus
}
#endif

#endif  // MONOWAVE_H
