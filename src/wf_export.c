// Encode-on-export: turns a region list back into a file.
//
// Reads through the same decoders `wf_decode.c` uses, seeks to each region in
// turn, applies gain and fades, and writes 16-bit PCM WAV. Output is always
// WAV: an edit list is meant to reproduce the source exactly where it did not
// change it, and re-encoding to a lossy format would quietly break that.
//
// Not available in the WASM build, which has no filesystem to write to.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "monowave.h"

#ifndef WF_NO_STDIO

// The implementations live in wf_decode.c; these are declarations only.
#include "vendor/dr_flac.h"
#include "vendor/dr_mp3.h"
#include "vendor/dr_wav.h"

enum { WF_KIND_WAV = 0, WF_KIND_MP3 = 1, WF_KIND_FLAC = 2 };

typedef struct {
  int kind;
  drwav wav;
  drmp3 mp3;
  drflac *flac;
  int32_t sample_rate;
  int32_t channels;
} wf_source;

static int wf_source_open(wf_source *source, const char *path) {
  unsigned char head[12];
  memset(head, 0, sizeof(head));

  FILE *probe = fopen(path, "rb");
  if (probe == NULL) return 0;
  const size_t read = fread(head, 1, sizeof(head), probe);
  fclose(probe);

  source->flac = NULL;
  if (read >= 12 && memcmp(head, "RIFF", 4) == 0 &&
      memcmp(head + 8, "WAVE", 4) == 0) {
    source->kind = WF_KIND_WAV;
  } else if (read >= 4 && memcmp(head, "fLaC", 4) == 0) {
    source->kind = WF_KIND_FLAC;
  } else {
    source->kind = WF_KIND_MP3;
  }

  switch (source->kind) {
    case WF_KIND_WAV:
      if (!drwav_init_file(&source->wav, path, NULL)) return 0;
      source->sample_rate = (int32_t)source->wav.sampleRate;
      source->channels = (int32_t)source->wav.channels;
      return 1;
    case WF_KIND_FLAC:
      source->flac = drflac_open_file(path, NULL);
      if (source->flac == NULL) return 0;
      source->sample_rate = (int32_t)source->flac->sampleRate;
      source->channels = (int32_t)source->flac->channels;
      return 1;
    default:
      if (!drmp3_init_file(&source->mp3, path, NULL)) return 0;
      source->sample_rate = (int32_t)source->mp3.sampleRate;
      source->channels = (int32_t)source->mp3.channels;
      return 1;
  }
}

static int wf_source_seek(wf_source *source, int64_t frame) {
  switch (source->kind) {
    case WF_KIND_WAV:
      return drwav_seek_to_pcm_frame(&source->wav, (drwav_uint64)frame);
    case WF_KIND_FLAC:
      return drflac_seek_to_pcm_frame(source->flac, (drflac_uint64)frame);
    default:
      return drmp3_seek_to_pcm_frame(&source->mp3, (drmp3_uint64)frame);
  }
}

static int64_t wf_source_read(wf_source *source, int16_t *out, int64_t frames) {
  switch (source->kind) {
    case WF_KIND_WAV:
      return (int64_t)drwav_read_pcm_frames_s16(&source->wav,
                                                (drwav_uint64)frames, out);
    case WF_KIND_FLAC:
      return (int64_t)drflac_read_pcm_frames_s16(source->flac,
                                                 (drflac_uint64)frames, out);
    default:
      return (int64_t)drmp3_read_pcm_frames_s16(&source->mp3,
                                                (drmp3_uint64)frames, out);
  }
}

static void wf_source_close(wf_source *source) {
  switch (source->kind) {
    case WF_KIND_WAV:
      drwav_uninit(&source->wav);
      break;
    case WF_KIND_FLAC:
      if (source->flac != NULL) drflac_close(source->flac);
      break;
    default:
      drmp3_uninit(&source->mp3);
      break;
  }
}

/// Linear gain envelope for one frame of a region.
///
/// Linear rather than equal-power: a fade here is for trimming clicks off an
/// edit point, not for crossfading two takes, and linear is what makes the
/// endpoints exactly 0 and 1.
static float wf_envelope(int64_t offset, int64_t length, int32_t fade_in,
                         int32_t fade_out) {
  float envelope = 1.0f;

  if (fade_in > 0 && offset < fade_in) {
    envelope *= (float)offset / (float)fade_in;
  }
  if (fade_out > 0) {
    const int64_t from_end = length - 1 - offset;
    if (from_end < fade_out) {
      envelope *= (float)from_end / (float)fade_out;
    }
  }

  return envelope < 0.0f ? 0.0f : envelope;
}

int32_t wf_export_wav(const char *src_path, const char *out_path,
                      const wf_region *regions, int32_t region_count) {
  if (src_path == NULL || out_path == NULL || regions == NULL ||
      region_count <= 0) {
    return WF_ERR_ARGUMENT;
  }

  wf_source source;
  memset(&source, 0, sizeof(source));
  if (!wf_source_open(&source, src_path)) return WF_ERR_OPEN;

  drwav_data_format format;
  format.container = drwav_container_riff;
  format.format = DR_WAVE_FORMAT_PCM;
  format.channels = (drwav_uint32)source.channels;
  format.sampleRate = (drwav_uint32)source.sample_rate;
  format.bitsPerSample = 16;

  drwav out;
  if (!drwav_init_file_write(&out, out_path, &format, NULL)) {
    wf_source_close(&source);
    return WF_ERR_OPEN;
  }

  const int64_t chunk_frames = 4096;
  int16_t *chunk =
      (int16_t *)malloc((size_t)chunk_frames * source.channels *
                        sizeof(int16_t));
  if (chunk == NULL) {
    drwav_uninit(&out);
    wf_source_close(&source);
    return WF_ERR_MEMORY;
  }

  int32_t status = WF_OK;

  for (int32_t index = 0; index < region_count && status == WF_OK; index++) {
    const wf_region region = regions[index];
    const int64_t start = (int64_t)region.source_start;
    const int64_t end = (int64_t)region.source_end;
    const int64_t length = end - start;
    if (length <= 0) continue;

    if (!wf_source_seek(&source, start)) {
      status = WF_ERR_DECODE;
      break;
    }

    int64_t written = 0;
    while (written < length) {
      const int64_t want =
          (length - written) < chunk_frames ? (length - written) : chunk_frames;
      const int64_t got = wf_source_read(&source, chunk, want);
      if (got <= 0) break;  // source ended early; write what exists

      // Gain and fades are applied per sample, in place, before writing.
      for (int64_t frame = 0; frame < got; frame++) {
        const float envelope =
            region.gain * wf_envelope(written + frame, length, region.fade_in,
                                      region.fade_out);
        if (envelope == 1.0f) continue;

        for (int32_t channel = 0; channel < source.channels; channel++) {
          const int64_t at = frame * source.channels + channel;
          float scaled = (float)chunk[at] * envelope;
          if (scaled > 32767.0f) scaled = 32767.0f;
          if (scaled < -32768.0f) scaled = -32768.0f;
          chunk[at] = (int16_t)scaled;
        }
      }

      if (drwav_write_pcm_frames(&out, (drwav_uint64)got, chunk) !=
          (drwav_uint64)got) {
        status = WF_ERR_OPEN;
        break;
      }
      written += got;
    }
  }

  free(chunk);
  drwav_uninit(&out);
  wf_source_close(&source);
  return status;
}

#else  // WF_NO_STDIO

int32_t wf_export_wav(const char *src_path, const char *out_path,
                      const wf_region *regions, int32_t region_count) {
  (void)src_path;
  (void)out_path;
  (void)regions;
  (void)region_count;
  // Web has no filesystem to write to. An in-memory variant would be the way
  // to support it, if something ever needs one.
  return WF_ERR_OPEN;
}

#endif  // WF_NO_STDIO
