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
#define WF_ABI_VERSION 14

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

/// The linear gain multiplier for one frame of a region.
///
/// `offset` is the position inside the region and `length` is the whole region
/// length, both in frames. The result is in [0, 1].
///
/// Linear rather than equal-power: a fade here takes the click off an edit
/// point rather than crossfading two takes, and linear is what puts the
/// endpoints on exactly 0 and exactly 1. Overlapping fades multiply, so a
/// region shorter than its two fades combined still reaches silence at both
/// ends.
///
/// Exported rather than internal because the exporter, the renderer and any
/// later web implementation must apply the same curve. One shared symbol is
/// what stops that from being a matter of discipline.
WF_EXPORT float wf_envelope(int64_t offset, int64_t length, int32_t fade_in,
                            int32_t fade_out);

/// A render in progress over a source and a region list.
typedef struct wf_render wf_render;

/// Opens a render of `regions` over the audio at `src_path`.
///
/// This is the path `wf_export_wav` takes with the file sink removed, so a
/// caller that wants samples gets exactly the bytes an export would write.
/// That equality is the point: it is what lets a preview be trusted.
///
/// Not available without stdio (the WASM build), where it reports WF_ERR_OPEN.
WF_EXPORT wf_render *wf_render_open(const char *src_path,
                                    const wf_region *regions,
                                    int32_t region_count, int32_t *out_error);

/// `sizeof(wf_region)`, including any tail padding.
///
/// A binding that lays the array out by hand - the web one has to, since it
/// writes into the WASM heap - should ask rather than guess. The field offsets
/// follow from declaration order and natural alignment; only the stride is
/// non-obvious.
WF_EXPORT int32_t wf_region_stride(void);

/// The same render, over bytes already in memory.
///
/// This is how web renders. The WASM build has no filesystem, but it does carry
/// the same dr_libs decoders - `wf_decode_memory` already runs them - so web
/// goes through this loop rather than through a second implementation of it.
/// That is what keeps a rendered document byte-identical on all six targets
/// instead of on five.
///
/// The bytes are copied. dr_libs reference a caller's buffer rather than
/// copying it, and a render outlives this call.
WF_EXPORT wf_render *wf_render_open_memory(const void *data, size_t size,
                                           const wf_region *regions,
                                           int32_t region_count,
                                           int32_t *out_error);
WF_EXPORT void wf_render_close(wf_render *render);

WF_EXPORT int32_t wf_render_sample_rate(const wf_render *render);
WF_EXPORT int32_t wf_render_channels(const wf_render *render);

/// Frames the whole region list produces. A double rather than an int64, for
/// the same reason wf_peaks_length returns one.
WF_EXPORT double wf_render_length_frames(const wf_render *render);

/// Pulls up to `max_frames` interleaved frames into `out`.
///
/// Returns the frames written, 0 past the last region, or a negative value if
/// the source could not be read. `out` must hold `max_frames * channels`
/// samples.
///
/// The block size does not change a single output sample. The envelope is a
/// pure function of the position inside its region, which is what lets a
/// 4096-frame exporter and a device-sized player agree byte for byte.
WF_EXPORT int32_t wf_render_read(wf_render *render, int16_t *out,
                                 int32_t max_frames);

/// Moves the read position to `output_frame` in the rendered timeline.
///
/// Walks the region list rather than dividing, because regions have different
/// lengths and a zero-length one must not shift the mapping. Accuracy is the
/// decoder's: WAV is sample-exact, and MP3 lands on a frame boundary of about
/// 1152 samples and then decodes forward.
WF_EXPORT int32_t wf_render_seek(wf_render *render, double output_frame);

/// Replaces the region list, keeping the source open.
///
/// The new list is copied before the old one is released, so a failed
/// allocation leaves the render playing exactly what it was playing. The read
/// position is rewound, because a position measured against one list means
/// nothing against another - the caller seeks afterwards.
WF_EXPORT int32_t wf_render_set_regions(wf_render *render,
                                        const wf_region *regions,
                                        int32_t region_count);

// --- Playback ---------------------------------------------------------------

/// A render being fed through a lock-free ring to an audio device.
typedef struct wf_playback wf_playback;

/// Opens a playback of `regions` over `src_path` and starts the feeder.
///
/// `ring_frames` is the cushion between the feeder and the device, rounded up
/// to a power of two. Seconds rather than milliseconds: the feeder only has to
/// keep up on average, and a deep ring is what absorbs a slow disk.
///
/// The feeder runs from here rather than from `wf_playback_start`, so the ring
/// is warm before a device opens onto it. Starting a device onto an empty ring
/// is an underrun by construction.
WF_EXPORT wf_playback *wf_playback_create(const char *src_path,
                                          const wf_region *regions,
                                          int32_t region_count,
                                          int32_t ring_frames,
                                          int32_t *out_error);
/// The same, over bytes already in memory. Not used by the web binding, which
/// has its own output device - but it keeps the two entry points symmetric with
/// `wf_render_open` and `wf_render_open_memory`, and a host holding audio in
/// memory on native should not have to write a temporary file to play it.
WF_EXPORT wf_playback *wf_playback_create_memory(const void *data, size_t size,
                                                 const wf_region *regions,
                                                 int32_t region_count,
                                                 int32_t ring_frames,
                                                 int32_t *out_error);

WF_EXPORT void wf_playback_destroy(wf_playback *playback);

/// Moves up to `frames` interleaved frames out of the ring into `out`.
///
/// This is the audio-thread entry point, and the device callback is a one-line
/// wrapper around it. Exposing it directly is what makes the realtime path
/// testable with no device attached, exactly as `wf_capture_feed` does for
/// capture - and it is the same code a real speaker drives.
///
/// `out` always comes back fully written: any shortfall is silence. The return
/// value is the frames that were real audio. Must not allocate, lock, or call
/// into Dart, and nothing it calls does.
WF_EXPORT int32_t wf_playback_pull(wf_playback *playback, int16_t *out,
                                   int32_t frames);

/// Frames the ring is holding, ready to be pulled.
WF_EXPORT int32_t wf_playback_available(const wf_playback *playback);

/// Whether the feeder reached the end of the render. The ring can still hold
/// frames, so this leads `wf_playback_finished` by the depth of the cushion.
///
/// A consumer waiting for a full block needs this to know the difference
/// between "the feeder is behind" and "there is no more audio".
WF_EXPORT int32_t wf_playback_drained(const wf_playback *playback);

/// Whether the render ended and the ring has been emptied.
WF_EXPORT int32_t wf_playback_finished(const wf_playback *playback);

/// Whether the feeder hit a read error rather than the end of the render.
WF_EXPORT int32_t wf_playback_failed(const wf_playback *playback);

/// Frames handed to the consumer, and frames of silence the ring could not
/// cover. Doubles rather than int64 for the reason wf_peaks_length gives.
///
/// A non-zero underrun count is the first thing to look at when playback
/// stutters, the same way `wf_capture_dropped` is for a stuttering visualizer.
/// Silence past the end of the render is the end, not an underrun.
WF_EXPORT double wf_playback_consumed(const wf_playback *playback);
WF_EXPORT double wf_playback_underruns(const wf_playback *playback);

WF_EXPORT int32_t wf_playback_sample_rate(const wf_playback *playback);
WF_EXPORT int32_t wf_playback_channels(const wf_playback *playback);
WF_EXPORT double wf_playback_length_frames(const wf_playback *playback);

/// Moves the playhead to `output_frame` and throws away everything the ring
/// had queued ahead of it.
///
/// Blocks the calling thread for a few milliseconds while the consumer leaves
/// the audio callback and the feeder parks. Never call it from the audio
/// thread. The consumer emits silence for the duration, which is the correct
/// sound for a seek.
///
/// WF_ERR_STATE if the other two sides do not stand down, in which case nothing
/// moves and playback carries on where it was.
WF_EXPORT int32_t wf_playback_seek(wf_playback *playback, double output_frame);

/// Swaps the region list underneath a running playback.
///
/// This is what lets a listener drag a trim handle and hear the result without
/// playback stopping. Mechanically it is a seek with a new list: the same
/// handshake takes the ring, the list is replaced, and the playhead keeps its
/// output frame so the sound carries on from where it was rather than jumping.
/// A change that shortens the document below the playhead clamps to the new end.
///
/// Whatever the ring had queued is discarded, because it was rendered through
/// the old list. That is true even for a change of gain alone, which is why
/// there is one call here rather than two.
WF_EXPORT int32_t wf_playback_set_regions(wf_playback *playback,
                                          const wf_region *regions,
                                          int32_t region_count);

/// Opens an output device and starts pulling. WF_ERR_DEVICE when there is no
/// device, which is the normal answer in CI.
WF_EXPORT int32_t wf_playback_start(wf_playback *playback);
WF_EXPORT int32_t wf_playback_stop(wf_playback *playback);

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
