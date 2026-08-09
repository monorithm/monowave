// Playback: the capture pipeline pointed the other way.
//
// Capture has the audio thread produce into a lock-free ring that a consumer
// drains. Playback has a feeder fill a lock-free ring that the audio thread
// consumes. Both obey the same rule: the audio callback must not allocate, take
// a lock, or call into a higher layer. `wf_playback_pull` is the whole of what
// runs there, and it is a copy out of a ring and nothing else.
//
// The feeder is a thread rather than a timer on the consumer side, which is
// where this departs from wf_capture.c. Capture tolerates a late drain because
// the ring holds seconds and a stalled consumer loses nothing. Playback does
// not: an empty ring is silence in the speaker. See ROADMAP.md, M7.
//
// `wf_playback_pull` is public for the same reason `wf_capture_feed` is. It is
// the audio-thread entry point, so a test drives the real ring, the real feeder
// and the real render with no device and no sound card in CI.

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include "monowave.h"

#ifndef WF_NO_DEVICE
#include "vendor/miniaudio.h"
#endif

// --- The one piece of per-platform code in the package ----------------------
//
// miniaudio has exactly what is wanted here, and keeps it to itself:
// `ma_thread_create` is `static`, while only the mutex, event and semaphore
// primitives carry MA_API. Rather than vendor a second threading library for
// three functions, this is a thread, a join and a sleep.

#if defined(_WIN32)
#include <windows.h>

typedef HANDLE wf_thread;

static int wf_thread_start(wf_thread *thread, DWORD(WINAPI *entry)(void *),
                           void *arg) {
  *thread = CreateThread(NULL, 0, entry, arg, 0, NULL);
  return *thread != NULL;
}

static void wf_thread_join(wf_thread thread) {
  WaitForSingleObject(thread, INFINITE);
  CloseHandle(thread);
}

static void wf_sleep_ms(int milliseconds) { Sleep((DWORD)milliseconds); }

#else
#include <pthread.h>
#include <time.h>

typedef pthread_t wf_thread;

static int wf_thread_start(wf_thread *thread, void *(*entry)(void *),
                           void *arg) {
  return pthread_create(thread, NULL, entry, arg) == 0;
}

static void wf_thread_join(wf_thread thread) { pthread_join(thread, NULL); }

static void wf_sleep_ms(int milliseconds) {
  struct timespec span;
  span.tv_sec = milliseconds / 1000;
  span.tv_nsec = (long)(milliseconds % 1000) * 1000000L;
  nanosleep(&span, NULL);
}
#endif

/// Frames the feeder renders per top-up. Small enough that a wake-up is cheap,
/// large enough that the decoder is not called for a handful of samples.
#define WF_FEED_BLOCK 1024

/// How long the feeder sleeps when the ring is full, in milliseconds. The ring
/// holds seconds, so this only decides how finely it is topped up.
#define WF_FEED_SLEEP_MS 2

struct wf_playback {
  wf_render *render;
  int32_t sample_rate;
  int32_t channels;

  // The ring, in interleaved samples rather than frames. Capacity is a power
  // of two so the wrap is a mask, exactly as in wf_capture.c.
  int16_t *ring;
  int32_t ring_mask;
  _Atomic int32_t head;  // written by the feeder only
  _Atomic int32_t tail;  // written by the consumer only

  _Atomic long long consumed;   // frames handed to the consumer
  _Atomic long long underruns;  // frames of silence the ring could not cover
  _Atomic int32_t drained;      // the render reached its end
  _Atomic int32_t failed;       // the render reported an error
  _Atomic int32_t stopping;

  wf_thread feeder;
  int has_feeder;

#ifndef WF_NO_DEVICE
  ma_device device;
  int has_device;
  int started;
#endif
};

static int32_t wf_round_up_pow2(int32_t value) {
  int32_t result = 1;
  while (result < value && result < (1 << 26)) result <<= 1;
  return result;
}

/// Samples waiting in the ring. Safe from either side: each loads the index the
/// other owns with acquire, and its own with relaxed.
static int32_t wf_ring_used(const wf_playback *playback) {
  const int32_t head =
      atomic_load_explicit(&playback->head, memory_order_acquire);
  const int32_t tail =
      atomic_load_explicit(&playback->tail, memory_order_acquire);
  return (head - tail) & playback->ring_mask;
}

static void wf_feed_loop(wf_playback *playback) {
  const int32_t channels = playback->channels;
  int16_t *scratch = (int16_t *)malloc((size_t)WF_FEED_BLOCK *
                                       (size_t)channels * sizeof(int16_t));
  if (scratch == NULL) {
    atomic_store_explicit(&playback->failed, 1, memory_order_relaxed);
    atomic_store_explicit(&playback->drained, 1, memory_order_release);
    return;
  }

  while (!atomic_load_explicit(&playback->stopping, memory_order_relaxed)) {
    if (atomic_load_explicit(&playback->drained, memory_order_relaxed)) {
      wf_sleep_ms(WF_FEED_SLEEP_MS);
      continue;
    }

    // One slot stays empty so a full ring is distinguishable from an empty one.
    const int32_t room =
        playback->ring_mask - wf_ring_used(playback);
    if (room < WF_FEED_BLOCK * channels) {
      wf_sleep_ms(WF_FEED_SLEEP_MS);
      continue;
    }

    // Allocation and file I/O are both fine here. This is not the audio thread,
    // which is the entire reason the feeder exists.
    const int32_t got = wf_render_read(playback->render, scratch,
                                       WF_FEED_BLOCK);
    if (got < 0) atomic_store_explicit(&playback->failed, 1,
                                       memory_order_relaxed);
    if (got <= 0) {
      atomic_store_explicit(&playback->drained, 1, memory_order_release);
      continue;
    }

    int32_t head = atomic_load_explicit(&playback->head, memory_order_relaxed);
    const int32_t samples = got * channels;
    for (int32_t i = 0; i < samples; i++) {
      playback->ring[head] = scratch[i];
      head = (head + 1) & playback->ring_mask;
    }
    atomic_store_explicit(&playback->head, head, memory_order_release);
  }

  free(scratch);
}

#if defined(_WIN32)
static DWORD WINAPI wf_feed_entry(void *data) {
  wf_feed_loop((wf_playback *)data);
  return 0;
}
#else
static void *wf_feed_entry(void *data) {
  wf_feed_loop((wf_playback *)data);
  return NULL;
}
#endif

#ifndef WF_NO_DEVICE
static void wf_playback_callback(ma_device *device, void *output,
                                 const void *input, ma_uint32 frames) {
  (void)input;
  // One call, and it copies out of a ring. Everything expensive already
  // happened on the feeder.
  wf_playback_pull((wf_playback *)device->pUserData, (int16_t *)output,
                   (int32_t)frames);
}
#endif

wf_playback *wf_playback_create(const char *src_path, const wf_region *regions,
                                int32_t region_count, int32_t ring_frames,
                                int32_t *out_error) {
  int32_t ignored = 0;
  if (out_error == NULL) out_error = &ignored;

  if (ring_frames <= 0) {
    *out_error = WF_ERR_ARGUMENT;
    return NULL;
  }

  wf_playback *playback = (wf_playback *)calloc(1, sizeof(wf_playback));
  if (playback == NULL) {
    *out_error = WF_ERR_MEMORY;
    return NULL;
  }

  playback->render =
      wf_render_open(src_path, regions, region_count, out_error);
  if (playback->render == NULL) {
    free(playback);
    return NULL;
  }

  playback->sample_rate = wf_render_sample_rate(playback->render);
  playback->channels = wf_render_channels(playback->render);
  if (playback->channels <= 0) {
    wf_render_close(playback->render);
    free(playback);
    *out_error = WF_ERR_DECODE;
    return NULL;
  }

  const int32_t samples =
      wf_round_up_pow2(ring_frames * playback->channels);
  playback->ring = (int16_t *)calloc((size_t)samples, sizeof(int16_t));
  if (playback->ring == NULL) {
    wf_render_close(playback->render);
    free(playback);
    *out_error = WF_ERR_MEMORY;
    return NULL;
  }
  playback->ring_mask = samples - 1;

  // The feeder runs from here rather than from start(), so the ring is already
  // warm when the device opens. Starting a device onto an empty ring is an
  // underrun by construction.
  if (!wf_thread_start(&playback->feeder, wf_feed_entry, playback)) {
    free(playback->ring);
    wf_render_close(playback->render);
    free(playback);
    *out_error = WF_ERR_MEMORY;
    return NULL;
  }
  playback->has_feeder = 1;

  *out_error = WF_OK;
  return playback;
}

int32_t wf_playback_pull(wf_playback *playback, int16_t *out, int32_t frames) {
  if (playback == NULL || out == NULL || frames <= 0) return 0;

  const int32_t channels = playback->channels;
  const int32_t want = frames * channels;

  int32_t tail = atomic_load_explicit(&playback->tail, memory_order_relaxed);
  const int32_t head =
      atomic_load_explicit(&playback->head, memory_order_acquire);

  int32_t available = (head - tail) & playback->ring_mask;
  if (available > want) available = want;

  for (int32_t i = 0; i < available; i++) {
    out[i] = playback->ring[tail];
    tail = (tail + 1) & playback->ring_mask;
  }
  atomic_store_explicit(&playback->tail, tail, memory_order_release);

  if (available < want) {
    // The device gets a whole buffer whatever happens. Silence is the only
    // honest thing to put in the rest of it.
    memset(out + available, 0,
           (size_t)(want - available) * sizeof(int16_t));

    // Past the end of the render this is the end, not a fault. Before it, the
    // feeder fell behind and that is worth counting.
    if (!atomic_load_explicit(&playback->drained, memory_order_acquire)) {
      atomic_fetch_add_explicit(&playback->underruns,
                                (want - available) / channels,
                                memory_order_relaxed);
    }
  }

  atomic_fetch_add_explicit(&playback->consumed, available / channels,
                            memory_order_relaxed);
  return available / channels;
}

int32_t wf_playback_available(const wf_playback *playback) {
  if (playback == NULL) return 0;
  return wf_ring_used(playback) / playback->channels;
}

int32_t wf_playback_drained(const wf_playback *playback) {
  if (playback == NULL) return 1;
  return atomic_load_explicit(&playback->drained, memory_order_acquire);
}

int32_t wf_playback_finished(const wf_playback *playback) {
  if (playback == NULL) return 1;
  const int drained =
      atomic_load_explicit(&playback->drained, memory_order_acquire);
  return drained && wf_ring_used(playback) == 0 ? 1 : 0;
}

int32_t wf_playback_failed(const wf_playback *playback) {
  if (playback == NULL) return 0;
  return atomic_load_explicit(&playback->failed, memory_order_relaxed);
}

double wf_playback_consumed(const wf_playback *playback) {
  if (playback == NULL) return 0.0;
  return (double)atomic_load_explicit(&playback->consumed,
                                      memory_order_relaxed);
}

double wf_playback_underruns(const wf_playback *playback) {
  if (playback == NULL) return 0.0;
  return (double)atomic_load_explicit(&playback->underruns,
                                      memory_order_relaxed);
}

int32_t wf_playback_sample_rate(const wf_playback *playback) {
  return playback == NULL ? 0 : playback->sample_rate;
}

int32_t wf_playback_channels(const wf_playback *playback) {
  return playback == NULL ? 0 : playback->channels;
}

double wf_playback_length_frames(const wf_playback *playback) {
  if (playback == NULL) return 0.0;
  return wf_render_length_frames(playback->render);
}

int32_t wf_playback_start(wf_playback *playback) {
  if (playback == NULL) return WF_ERR_ARGUMENT;

#ifdef WF_NO_DEVICE
  // Built without a device layer. `wf_playback_pull` still works, which is what
  // the tests drive.
  return WF_ERR_DEVICE;
#else
  if (playback->started) return WF_ERR_STATE;

  ma_device_config config = ma_device_config_init(ma_device_type_playback);
  config.playback.format = ma_format_s16;
  config.playback.channels = (ma_uint32)playback->channels;
  config.sampleRate = (ma_uint32)playback->sample_rate;
  config.dataCallback = wf_playback_callback;
  config.pUserData = playback;

  if (ma_device_init(NULL, &config, &playback->device) != MA_SUCCESS) {
    return WF_ERR_DEVICE;
  }
  playback->has_device = 1;

  if (ma_device_start(&playback->device) != MA_SUCCESS) {
    ma_device_uninit(&playback->device);
    playback->has_device = 0;
    return WF_ERR_DEVICE;
  }

  playback->started = 1;
  return WF_OK;
#endif
}

int32_t wf_playback_stop(wf_playback *playback) {
  if (playback == NULL) return WF_ERR_ARGUMENT;

#ifndef WF_NO_DEVICE
  if (playback->started) {
    ma_device_stop(&playback->device);
    playback->started = 0;
  }
  if (playback->has_device) {
    ma_device_uninit(&playback->device);
    playback->has_device = 0;
  }
#endif

  return WF_OK;
}

void wf_playback_destroy(wf_playback *playback) {
  if (playback == NULL) return;

  // The device first, so no callback can be reading the ring while the feeder
  // is being torn down underneath it.
  wf_playback_stop(playback);

  if (playback->has_feeder) {
    atomic_store_explicit(&playback->stopping, 1, memory_order_relaxed);
    wf_thread_join(playback->feeder);
    playback->has_feeder = 0;
  }

  wf_render_close(playback->render);
  free(playback->ring);
  free(playback);
}
