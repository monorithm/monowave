// The min/max pyramid, and the memory it lives in.

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "monowave.h"

struct wf_peaks {
  int32_t sample_rate;
  int32_t channels;
  int64_t length;
  int32_t base_spp;
  int32_t levels;
  int64_t pair_counts[WF_MAX_LEVELS];
  int16_t *data[WF_MAX_LEVELS];
  int16_t *rms[WF_MAX_LEVELS];
};

int32_t wf_abi_version(void) { return WF_ABI_VERSION; }

void wf_reduce_minmax(const int16_t *samples, int32_t count, int16_t *out_min,
                      int16_t *out_max) {
  if (count <= 0 || samples == NULL) {
    *out_min = 0;
    *out_max = 0;
    return;
  }

  int16_t lo = samples[0];
  int16_t hi = samples[0];
  for (int32_t i = 1; i < count; i++) {
    const int16_t s = samples[i];
    if (s < lo) lo = s;
    if (s > hi) hi = s;
  }

  *out_min = lo;
  *out_max = hi;
}

void wf_pair_builder_init(wf_pair_builder *builder) {
  builder->pairs = NULL;
  builder->rms = NULL;
  builder->count = 0;
  builder->capacity = 0;
  builder->failed = 0;
}

void wf_pair_builder_push(wf_pair_builder *builder, int16_t lo, int16_t hi,
                          int16_t rms) {
  if (builder->failed) return;

  if (builder->count == builder->capacity) {
    // Doubling, starting at 4096 pairs - about twelve seconds of audio at a
    // 128-sample base, so short files never reallocate at all.
    int64_t next = builder->capacity == 0 ? 4096 : builder->capacity * 2;
    int16_t *grown =
        (int16_t *)realloc(builder->pairs, (size_t)next * 2 * sizeof(int16_t));
    if (grown == NULL) {
      builder->failed = 1;
      return;
    }
    builder->pairs = grown;

    int16_t *grown_rms =
        (int16_t *)realloc(builder->rms, (size_t)next * sizeof(int16_t));
    if (grown_rms == NULL) {
      builder->failed = 1;
      return;
    }
    builder->rms = grown_rms;

    builder->capacity = next;
  }

  builder->pairs[builder->count * 2] = lo;
  builder->pairs[builder->count * 2 + 1] = hi;
  builder->rms[builder->count] = rms;
  builder->count++;
}

void wf_pair_builder_dispose(wf_pair_builder *builder) {
  free(builder->pairs);
  free(builder->rms);
  wf_pair_builder_init(builder);
}

wf_peaks *wf_peaks_from_base(wf_pair_builder *builder, int32_t sample_rate,
                             int32_t channels, int64_t length,
                             int32_t base_spp) {
  if (builder->failed || builder->count <= 0) return NULL;

  wf_peaks *peaks = (wf_peaks *)calloc(1, sizeof(wf_peaks));
  if (peaks == NULL) return NULL;

  peaks->sample_rate = sample_rate;
  peaks->channels = channels;
  peaks->length = length;
  peaks->base_spp = base_spp;

  // Level 0 takes over the builder's buffer rather than copying it.
  peaks->data[0] = builder->pairs;
  peaks->rms[0] = builder->rms;
  peaks->pair_counts[0] = builder->count;
  peaks->levels = 1;
  builder->pairs = NULL;
  builder->rms = NULL;
  builder->count = 0;
  builder->capacity = 0;

  // Each level above is min-of-mins and max-of-maxes over pairs of the level
  // below. Because that is exact rather than resampled, a coarse level always
  // bounds the fine level under it, which is what makes zooming exact.
  while (peaks->pair_counts[peaks->levels - 1] > 1 &&
         peaks->levels < WF_MAX_LEVELS) {
    const int32_t level = peaks->levels;
    const int16_t *fine = peaks->data[level - 1];
    const int64_t fine_pairs = peaks->pair_counts[level - 1];
    const int64_t coarse_pairs = (fine_pairs + 1) / 2;

    const int16_t *fine_rms = peaks->rms[level - 1];

    int16_t *coarse =
        (int16_t *)malloc((size_t)coarse_pairs * 2 * sizeof(int16_t));
    int16_t *coarse_rms =
        (int16_t *)malloc((size_t)coarse_pairs * sizeof(int16_t));
    if (coarse == NULL || coarse_rms == NULL) {
      free(coarse);
      free(coarse_rms);
      wf_peaks_free(peaks);
      return NULL;
    }

    for (int64_t pair = 0; pair < coarse_pairs; pair++) {
      const int64_t a_index = pair * 2;
      const int64_t b_index = a_index + 1;

      int16_t lo = fine[a_index * 2];
      int16_t hi = fine[a_index * 2 + 1];
      if (b_index < fine_pairs) {
        if (fine[b_index * 2] < lo) lo = fine[b_index * 2];
        if (fine[b_index * 2 + 1] > hi) hi = fine[b_index * 2 + 1];
      }

      coarse[pair * 2] = lo;
      coarse[pair * 2 + 1] = hi;

      // Root of the mean of the squares, so the result is still an RMS rather
      // than an average of averages.
      const double a = (double)fine_rms[a_index];
      const double b =
          b_index < fine_pairs ? (double)fine_rms[b_index] : a;
      coarse_rms[pair] = (int16_t)sqrt((a * a + b * b) / 2.0);
    }

    peaks->data[level] = coarse;
    peaks->rms[level] = coarse_rms;
    peaks->pair_counts[level] = coarse_pairs;
    peaks->levels++;
  }

  return peaks;
}

int32_t wf_peaks_sample_rate(const wf_peaks *peaks) {
  return peaks == NULL ? 0 : peaks->sample_rate;
}

int32_t wf_peaks_channels(const wf_peaks *peaks) {
  return peaks == NULL ? 0 : peaks->channels;
}

double wf_peaks_length(const wf_peaks *peaks) {
  return peaks == NULL ? 0.0 : (double)peaks->length;
}

int32_t wf_peaks_levels(const wf_peaks *peaks) {
  return peaks == NULL ? 0 : peaks->levels;
}

int32_t wf_peaks_base_spp(const wf_peaks *peaks) {
  return peaks == NULL ? 0 : peaks->base_spp;
}

int32_t wf_peaks_pair_count(const wf_peaks *peaks, int32_t level) {
  if (peaks == NULL || level < 0 || level >= peaks->levels) return 0;
  return (int32_t)peaks->pair_counts[level];
}

const int16_t *wf_peaks_data(const wf_peaks *peaks, int32_t level) {
  if (peaks == NULL || level < 0 || level >= peaks->levels) return NULL;
  return peaks->data[level];
}

const int16_t *wf_peaks_rms(const wf_peaks *peaks, int32_t level) {
  if (peaks == NULL || level < 0 || level >= peaks->levels) return NULL;
  return peaks->rms[level];
}

void wf_peaks_free(wf_peaks *peaks) {
  if (peaks == NULL) return;
  for (int32_t level = 0; level < WF_MAX_LEVELS; level++) {
    free(peaks->data[level]);
    free(peaks->rms[level]);
  }
  free(peaks);
}
