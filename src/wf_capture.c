// Microphone capture, and the one place in monowave with hard realtime rules.
//
// Everything reachable from `wf_capture_feed` runs on the audio thread, where
// three things are forbidden: allocating, taking a lock, and calling out to a
// higher layer. A missed deadline there is an audible glitch, not a dropped
// frame, so the transport is a lock-free single-producer/single-consumer ring
// of already-reduced frames and nothing else.
//
// The device callback is a one-line wrapper around `wf_capture_feed`, which is
// public precisely so the realtime path can be driven synthetically in tests on
// every platform, with no microphone and no permissions.

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include "monowave.h"

#ifndef WF_NO_DEVICE
#include "vendor/miniaudio.h"
#endif

struct wf_capture {
  int32_t sample_rate;
  int32_t channels;
  int32_t hop;

  // Hop accumulator. Touched only by the audio thread, so it needs no atomics
  // and it persists across callbacks - a callback rarely delivers a whole
  // number of hops.
  int32_t acc_frames;
  int16_t acc_min;
  int16_t acc_max;
  int64_t acc_squares;
  int64_t acc_samples;

  // The ring. Capacity is a power of two so the wrap is a mask.
  wf_frame *ring;
  int32_t ring_mask;
  _Atomic int32_t head;  // written by the producer only
  _Atomic int32_t tail;  // written by the consumer only
  _Atomic long long dropped;
  _Atomic long long produced;

  // Raw audio, in its own ring. Kept separately from the reduction because the
  // two have completely different rates and the visualizer must not be starved
  // by a slow file write.
  int16_t *pcm;
  int32_t pcm_mask;
  _Atomic int32_t pcm_head;
  _Atomic int32_t pcm_tail;
  _Atomic long long pcm_dropped;

  // Preallocated history, so stop() can answer even if the consumer never
  // drained. Growing this from the audio thread is not an option.
  int16_t *take;      // interleaved min, max
  int16_t *take_rms;  // one per pair
  int32_t take_capacity;
  _Atomic int32_t take_count;
  _Atomic int32_t overflowed;

  // Consumer-side scratch for the two drain calls. Owned here rather than by
  // the caller so that destroying a session releases every allocation it needs,
  // in one call - see wf_capture_scratch in monowave.h for why that matters.
  wf_frame *scratch;
  int16_t *pcm_scratch;

#ifndef WF_NO_DEVICE
  ma_device device;
  int has_device;
  int started;
#endif
};

/// Live sessions, for wf_capture_live. Atomic because sessions on two isolates
/// are two threads, even though nothing else here is shared between them.
static _Atomic int32_t wf_live_sessions;

static int32_t wf_round_up_pow2(int32_t value) {
  int32_t result = 1;
  while (result < value && result < (1 << 20)) result <<= 1;
  return result;
}

static void wf_acc_reset(wf_capture *capture) {
  capture->acc_frames = 0;
  capture->acc_min = 32767;
  capture->acc_max = -32768;
  capture->acc_squares = 0;
  capture->acc_samples = 0;
}

/// Producer side of the ring. Never blocks: a full ring drops the frame and
/// counts it, because stalling here would stall the audio device.
static void wf_ring_push(wf_capture *capture, wf_frame frame) {
  const int32_t head = atomic_load_explicit(&capture->head, memory_order_relaxed);
  const int32_t next = (head + 1) & capture->ring_mask;

  if (next == atomic_load_explicit(&capture->tail, memory_order_acquire)) {
    atomic_fetch_add_explicit(&capture->dropped, 1, memory_order_relaxed);
    return;
  }

  capture->ring[head] = frame;
  atomic_store_explicit(&capture->head, next, memory_order_release);
}

/// Closes out one hop: reduce, publish to the ring, append to history.
static void wf_emit(wf_capture *capture) {
  const int16_t lo = capture->acc_min;
  const int16_t hi = capture->acc_max;

  int16_t rms = 0;
  if (capture->acc_samples > 0) {
    // sqrt is a single instruction and allocates nothing, so it is allowed
    // here. Anything that touched the heap would not be.
    const double mean =
        (double)capture->acc_squares / (double)capture->acc_samples;
    const double root = sqrt(mean);
    rms = root > 32767.0 ? 32767 : (int16_t)root;
  }

  wf_frame frame;
  frame.min = lo;
  frame.max = hi;
  frame.rms = rms;
  wf_ring_push(capture, frame);

  const int32_t taken =
      atomic_load_explicit(&capture->take_count, memory_order_relaxed);
  if (taken < capture->take_capacity) {
    capture->take[taken * 2] = lo;
    capture->take[taken * 2 + 1] = hi;
    capture->take_rms[taken] = rms;
    atomic_store_explicit(&capture->take_count, taken + 1, memory_order_release);
  } else {
    atomic_store_explicit(&capture->overflowed, 1, memory_order_relaxed);
  }

  atomic_fetch_add_explicit(&capture->produced, 1, memory_order_relaxed);
  wf_acc_reset(capture);
}

/// Copies raw samples into the PCM ring. One-by-one rather than two memcpys
/// because the branch is predictable and the wrap logic stays obvious; this is
/// still just a copy, with no allocation and no lock.
static void wf_pcm_push(wf_capture *capture, const int16_t *samples,
                        int32_t count) {
  if (capture->pcm == NULL) return;

  int32_t head = atomic_load_explicit(&capture->pcm_head, memory_order_relaxed);
  const int32_t tail =
      atomic_load_explicit(&capture->pcm_tail, memory_order_acquire);

  for (int32_t i = 0; i < count; i++) {
    const int32_t next = (head + 1) & capture->pcm_mask;
    if (next == tail) {
      atomic_fetch_add_explicit(&capture->pcm_dropped, count - i,
                                memory_order_relaxed);
      break;
    }
    capture->pcm[head] = samples[i];
    head = next;
  }

  atomic_store_explicit(&capture->pcm_head, head, memory_order_release);
}

void wf_capture_feed(wf_capture *capture, const int16_t *interleaved,
                     int32_t frames) {
  if (capture == NULL || interleaved == NULL || frames <= 0) return;

  const int32_t channels = capture->channels;
  wf_pcm_push(capture, interleaved, frames * channels);
  for (int32_t frame = 0; frame < frames; frame++) {
    for (int32_t channel = 0; channel < channels; channel++) {
      // Extremes across channels, matching how the decoder mixes down: a
      // single-lane waveform shows the true excursion of the moment.
      const int16_t sample = interleaved[frame * channels + channel];
      if (sample < capture->acc_min) capture->acc_min = sample;
      if (sample > capture->acc_max) capture->acc_max = sample;
      capture->acc_squares += (int64_t)sample * (int64_t)sample;
      capture->acc_samples++;
    }

    capture->acc_frames++;
    if (capture->acc_frames >= capture->hop) wf_emit(capture);
  }
}

#ifndef WF_NO_DEVICE
static void wf_device_callback(ma_device *device, void *output,
                               const void *input, ma_uint32 frames) {
  (void)output;
  wf_capture_feed((wf_capture *)device->pUserData, (const int16_t *)input,
                  (int32_t)frames);
}
#endif

wf_capture *wf_capture_create(int32_t sample_rate, int32_t channels,
                              int32_t hop, int32_t ring_capacity,
                              int32_t take_capacity, int32_t pcm_capacity,
                              int32_t *out_error) {
  int32_t ignored = 0;
  if (out_error == NULL) out_error = &ignored;

  if (sample_rate <= 0 || channels <= 0 || hop <= 0 || ring_capacity <= 0 ||
      take_capacity <= 0) {
    *out_error = WF_ERR_ARGUMENT;
    return NULL;
  }

  wf_capture *capture = (wf_capture *)calloc(1, sizeof(wf_capture));
  if (capture == NULL) {
    *out_error = WF_ERR_MEMORY;
    return NULL;
  }
  // Counted from here rather than on the way out, so the failure paths below -
  // which all destroy the half-built session - stay balanced.
  atomic_fetch_add_explicit(&wf_live_sessions, 1, memory_order_relaxed);

  capture->sample_rate = sample_rate;
  capture->channels = channels;
  capture->hop = hop;
  capture->take_capacity = take_capacity;

  const int32_t ring_size = wf_round_up_pow2(ring_capacity);
  capture->ring = (wf_frame *)calloc((size_t)ring_size, sizeof(wf_frame));
  capture->take = (int16_t *)calloc((size_t)take_capacity * 2, sizeof(int16_t));
  capture->take_rms =
      (int16_t *)calloc((size_t)take_capacity, sizeof(int16_t));
  capture->scratch =
      (wf_frame *)calloc((size_t)WF_SCRATCH_FRAMES, sizeof(wf_frame));
  if (capture->ring == NULL || capture->take == NULL ||
      capture->take_rms == NULL || capture->scratch == NULL) {
    wf_capture_destroy(capture);
    *out_error = WF_ERR_MEMORY;
    return NULL;
  }
  capture->ring_mask = ring_size - 1;

  if (pcm_capacity > 0) {
    const int32_t pcm_size = wf_round_up_pow2(pcm_capacity);
    capture->pcm = (int16_t *)calloc((size_t)pcm_size, sizeof(int16_t));
    capture->pcm_scratch =
        (int16_t *)calloc((size_t)WF_SCRATCH_SAMPLES, sizeof(int16_t));
    if (capture->pcm == NULL || capture->pcm_scratch == NULL) {
      wf_capture_destroy(capture);
      *out_error = WF_ERR_MEMORY;
      return NULL;
    }
    capture->pcm_mask = pcm_size - 1;
  }

  wf_acc_reset(capture);
  *out_error = WF_OK;
  return capture;
}

int32_t wf_capture_start(wf_capture *capture) {
  if (capture == NULL) return WF_ERR_ARGUMENT;

#ifdef WF_NO_DEVICE
  // Built without a device layer: `wf_capture_feed` still works, which is what
  // tests and the WASM build use.
  return WF_ERR_DEVICE;
#else
  if (capture->started) return WF_ERR_STATE;

  ma_device_config config = ma_device_config_init(ma_device_type_capture);
  config.capture.format = ma_format_s16;
  config.capture.channels = (ma_uint32)capture->channels;
  config.sampleRate = (ma_uint32)capture->sample_rate;
  config.dataCallback = wf_device_callback;
  config.pUserData = capture;

  if (ma_device_init(NULL, &config, &capture->device) != MA_SUCCESS) {
    return WF_ERR_DEVICE;
  }
  capture->has_device = 1;

  if (ma_device_start(&capture->device) != MA_SUCCESS) {
    ma_device_uninit(&capture->device);
    capture->has_device = 0;
    return WF_ERR_DEVICE;
  }

  capture->started = 1;
  return WF_OK;
#endif
}

int32_t wf_capture_pause(wf_capture *capture) {
  if (capture == NULL) return WF_ERR_ARGUMENT;
#ifdef WF_NO_DEVICE
  return WF_ERR_DEVICE;
#else
  if (!capture->started) return WF_ERR_STATE;
  // Only the device stops. Everything that holds the take stays exactly as it
  // is, so resuming appends rather than restarting.
  if (ma_device_stop(&capture->device) != MA_SUCCESS) return WF_ERR_DEVICE;
  capture->started = 0;
  return WF_OK;
#endif
}

int32_t wf_capture_resume(wf_capture *capture) {
  if (capture == NULL) return WF_ERR_ARGUMENT;
#ifdef WF_NO_DEVICE
  return WF_ERR_DEVICE;
#else
  if (capture->started || !capture->has_device) return WF_ERR_STATE;
  if (ma_device_start(&capture->device) != MA_SUCCESS) return WF_ERR_DEVICE;
  capture->started = 1;
  return WF_OK;
#endif
}

int32_t wf_capture_stop(wf_capture *capture) {
  if (capture == NULL) return WF_ERR_ARGUMENT;

#ifndef WF_NO_DEVICE
  if (capture->started) {
    ma_device_stop(&capture->device);
    capture->started = 0;
  }
  if (capture->has_device) {
    ma_device_uninit(&capture->device);
    capture->has_device = 0;
  }
#endif

  return WF_OK;
}

int32_t wf_capture_drain(wf_capture *capture, wf_frame *out, int32_t max) {
  if (capture == NULL || out == NULL || max <= 0) return 0;

  int32_t count = 0;
  int32_t tail = atomic_load_explicit(&capture->tail, memory_order_relaxed);

  while (count < max) {
    if (tail == atomic_load_explicit(&capture->head, memory_order_acquire)) {
      break;
    }
    out[count++] = capture->ring[tail];
    tail = (tail + 1) & capture->ring_mask;
  }

  atomic_store_explicit(&capture->tail, tail, memory_order_release);
  return count;
}

int32_t wf_capture_drain_pcm(wf_capture *capture, int16_t *out,
                             int32_t max_samples) {
  if (capture == NULL || capture->pcm == NULL || out == NULL ||
      max_samples <= 0) {
    return 0;
  }

  int32_t count = 0;
  int32_t tail =
      atomic_load_explicit(&capture->pcm_tail, memory_order_relaxed);

  while (count < max_samples) {
    if (tail == atomic_load_explicit(&capture->pcm_head, memory_order_acquire)) {
      break;
    }
    out[count++] = capture->pcm[tail];
    tail = (tail + 1) & capture->pcm_mask;
  }

  atomic_store_explicit(&capture->pcm_tail, tail, memory_order_release);
  return count;
}

wf_frame *wf_capture_scratch(wf_capture *capture) {
  if (capture == NULL) return NULL;
  return capture->scratch;
}

int32_t wf_capture_scratch_frames(const wf_capture *capture) {
  if (capture == NULL || capture->scratch == NULL) return 0;
  return WF_SCRATCH_FRAMES;
}

int16_t *wf_capture_pcm_scratch(wf_capture *capture) {
  if (capture == NULL) return NULL;
  return capture->pcm_scratch;
}

int32_t wf_capture_pcm_scratch_samples(const wf_capture *capture) {
  if (capture == NULL || capture->pcm_scratch == NULL) return 0;
  return WF_SCRATCH_SAMPLES;
}

int32_t wf_capture_live(void) {
  return atomic_load_explicit(&wf_live_sessions, memory_order_relaxed);
}

double wf_capture_pcm_dropped(const wf_capture *capture) {
  if (capture == NULL) return 0.0;
  return (double)atomic_load_explicit(&capture->pcm_dropped,
                                      memory_order_relaxed);
}

double wf_capture_produced(const wf_capture *capture) {
  if (capture == NULL) return 0.0;
  return (double)atomic_load_explicit(&capture->produced, memory_order_relaxed);
}

double wf_capture_dropped(const wf_capture *capture) {
  if (capture == NULL) return 0.0;
  return (double)atomic_load_explicit(&capture->dropped, memory_order_relaxed);
}

int32_t wf_capture_overflowed(const wf_capture *capture) {
  if (capture == NULL) return 0;
  return atomic_load_explicit(&capture->overflowed, memory_order_relaxed);
}

wf_peaks *wf_capture_take_peaks(wf_capture *capture, int32_t *out_error) {
  int32_t ignored = 0;
  if (out_error == NULL) out_error = &ignored;

  if (capture == NULL) {
    *out_error = WF_ERR_ARGUMENT;
    return NULL;
  }

  const int32_t taken =
      atomic_load_explicit(&capture->take_count, memory_order_acquire);
  if (taken <= 0) {
    *out_error = WF_ERR_EMPTY;
    return NULL;
  }

  // Copied into a builder rather than handed over directly: the take buffer is
  // still live if capture is running, and the pyramid owns its base level.
  wf_pair_builder builder;
  wf_pair_builder_init(&builder);
  for (int32_t pair = 0; pair < taken; pair++) {
    wf_pair_builder_push(&builder, capture->take[pair * 2],
                         capture->take[pair * 2 + 1],
                         capture->take_rms[pair]);
  }
  if (builder.failed) {
    wf_pair_builder_dispose(&builder);
    *out_error = WF_ERR_MEMORY;
    return NULL;
  }

  wf_peaks *peaks =
      wf_peaks_from_base(&builder, capture->sample_rate, capture->channels,
                         (int64_t)taken * capture->hop, capture->hop);
  if (peaks == NULL) {
    wf_pair_builder_dispose(&builder);
    *out_error = WF_ERR_MEMORY;
    return NULL;
  }

  *out_error = WF_OK;
  return peaks;
}

void wf_capture_destroy(wf_capture *capture) {
  if (capture == NULL) return;
  // Closes the device first. This is the part that matters when a binding's
  // finalizer calls it rather than the binding itself: the microphone stops
  // when the session is collected, not when the process exits.
  wf_capture_stop(capture);
  free(capture->ring);
  free(capture->pcm);
  free(capture->take);
  free(capture->take_rms);
  free(capture->scratch);
  free(capture->pcm_scratch);
  free(capture);
  atomic_fetch_sub_explicit(&wf_live_sessions, 1, memory_order_relaxed);
}
