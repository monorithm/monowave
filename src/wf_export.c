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

// Outside the stdio guard on purpose. The envelope is pure arithmetic with no
// filesystem in it, and the WASM build needs the same curve when web playback
// arrives -- see ROADMAP.md, M10.
float wf_envelope(int64_t offset, int64_t length, int32_t fade_in,
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

// The implementations live in wf_decode.c; these are declarations only.
//
// Outside the stdio guard, along with everything below that does not touch a
// file. The WASM build has no filesystem, but it does have these decoders -
// wf_decode_memory already runs them - so web renders through the same loop the
// exporter uses rather than through a second implementation of it. Only the
// file entry points are gated. See ROADMAP.md, M10.
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

  /// A copy of the input, for a memory source. NULL when reading a file.
  ///
  /// dr_libs reference the caller's buffer rather than copying it, and a render
  /// outlives the call that made it - the feeder thread reads from it on
  /// another thread entirely. So the bytes are copied and owned here.
  void *owned;
} wf_source;

/// Sniffs the container from the first bytes. WAV and FLAC announce
/// themselves; anything else is tried as MP3, which has no reliable magic.
static int wf_source_kind(const unsigned char *head, size_t read) {
  if (read >= 12 && memcmp(head, "RIFF", 4) == 0 &&
      memcmp(head + 8, "WAVE", 4) == 0) {
    return WF_KIND_WAV;
  }
  if (read >= 4 && memcmp(head, "fLaC", 4) == 0) return WF_KIND_FLAC;
  return WF_KIND_MP3;
}

static int wf_source_open_memory(wf_source *source, const void *data,
                                 size_t size) {
  source->owned = malloc(size);
  if (source->owned == NULL) return 0;
  memcpy(source->owned, data, size);

  source->flac = NULL;
  source->kind =
      wf_source_kind((const unsigned char *)source->owned, size < 12 ? size : 12);

  switch (source->kind) {
    case WF_KIND_WAV:
      if (!drwav_init_memory(&source->wav, source->owned, size, NULL)) break;
      source->sample_rate = (int32_t)source->wav.sampleRate;
      source->channels = (int32_t)source->wav.channels;
      return 1;
    case WF_KIND_FLAC:
      source->flac = drflac_open_memory(source->owned, size, NULL);
      if (source->flac == NULL) break;
      source->sample_rate = (int32_t)source->flac->sampleRate;
      source->channels = (int32_t)source->flac->channels;
      return 1;
    default:
      if (!drmp3_init_memory(&source->mp3, source->owned, size, NULL)) break;
      source->sample_rate = (int32_t)source->mp3.sampleRate;
      source->channels = (int32_t)source->mp3.channels;
      return 1;
  }

  free(source->owned);
  source->owned = NULL;
  return 0;
}

#ifndef WF_NO_STDIO

static int wf_source_open(wf_source *source, const char *path) {
  unsigned char head[12];
  memset(head, 0, sizeof(head));

  FILE *probe = fopen(path, "rb");
  if (probe == NULL) return 0;
  const size_t read = fread(head, 1, sizeof(head), probe);
  fclose(probe);

  source->owned = NULL;
  source->flac = NULL;
  source->kind = wf_source_kind(head, read);

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

#endif  // WF_NO_STDIO

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
  free(source->owned);
  source->owned = NULL;
}

/// A render in progress: a source, a copy of the region list, and a position.
///
/// The exporter is a thin file sink over this. Keeping one loop is what makes
/// "a preview sounds like the export" structural rather than a property some
/// test has to keep policing.
struct wf_render {
  wf_source source;
  wf_region *regions;
  int32_t region_count;
  int64_t length;

  int32_t index;   // the region being read
  int64_t offset;  // frames already emitted from that region
  int seek_pending;
  int failed;
};

/// Frames a region contributes. Zero and negative lengths collapse to zero,
/// which is what drops them from the output entirely.
static int64_t wf_region_frames(const wf_region *region) {
  const int64_t length =
      (int64_t)region->source_end - (int64_t)region->source_start;
  return length > 0 ? length : 0;
}

int32_t wf_region_stride(void) { return (int32_t)sizeof(wf_region); }

/// Attaches a region list to a render whose source is already open.
///
/// Shared by the file and memory entry points, so the two cannot answer
/// differently about anything but where the bytes came from.
static wf_render *wf_render_finish(wf_render *render, const wf_region *regions,
                                   int32_t region_count, int32_t *out_error) {
  // Copied rather than referenced: a render outlives the caller's array once
  // playback drives it from another thread.
  render->regions =
      (wf_region *)calloc((size_t)region_count, sizeof(wf_region));
  if (render->regions == NULL) {
    wf_source_close(&render->source);
    free(render);
    *out_error = WF_ERR_MEMORY;
    return NULL;
  }

  memcpy(render->regions, regions, (size_t)region_count * sizeof(wf_region));
  render->region_count = region_count;
  render->seek_pending = 1;
  for (int32_t index = 0; index < region_count; index++) {
    render->length += wf_region_frames(&regions[index]);
  }

  *out_error = WF_OK;
  return render;
}

wf_render *wf_render_open_memory(const void *data, size_t size,
                                 const wf_region *regions,
                                 int32_t region_count, int32_t *out_error) {
  int32_t ignored = 0;
  if (out_error == NULL) out_error = &ignored;

  if (data == NULL || size == 0 || regions == NULL || region_count <= 0) {
    *out_error = WF_ERR_ARGUMENT;
    return NULL;
  }

  wf_render *render = (wf_render *)calloc(1, sizeof(wf_render));
  if (render == NULL) {
    *out_error = WF_ERR_MEMORY;
    return NULL;
  }

  if (!wf_source_open_memory(&render->source, data, size)) {
    free(render);
    *out_error = WF_ERR_OPEN;
    return NULL;
  }

  return wf_render_finish(render, regions, region_count, out_error);
}

#ifndef WF_NO_STDIO

wf_render *wf_render_open(const char *src_path, const wf_region *regions,
                          int32_t region_count, int32_t *out_error) {
  int32_t ignored = 0;
  if (out_error == NULL) out_error = &ignored;

  if (src_path == NULL || regions == NULL || region_count <= 0) {
    *out_error = WF_ERR_ARGUMENT;
    return NULL;
  }

  wf_render *render = (wf_render *)calloc(1, sizeof(wf_render));
  if (render == NULL) {
    *out_error = WF_ERR_MEMORY;
    return NULL;
  }

  if (!wf_source_open(&render->source, src_path)) {
    free(render);
    *out_error = WF_ERR_OPEN;
    return NULL;
  }

  return wf_render_finish(render, regions, region_count, out_error);
}

#endif  // WF_NO_STDIO

void wf_render_close(wf_render *render) {
  if (render == NULL) return;
  wf_source_close(&render->source);
  free(render->regions);
  free(render);
}

int32_t wf_render_sample_rate(const wf_render *render) {
  return render == NULL ? 0 : render->source.sample_rate;
}

int32_t wf_render_channels(const wf_render *render) {
  return render == NULL ? 0 : render->source.channels;
}

double wf_render_length_frames(const wf_render *render) {
  return render == NULL ? 0.0 : (double)render->length;
}

int32_t wf_render_set_regions(wf_render *render, const wf_region *regions,
                              int32_t region_count) {
  if (render == NULL || regions == NULL || region_count <= 0) {
    return WF_ERR_ARGUMENT;
  }

  wf_region *copy =
      (wf_region *)calloc((size_t)region_count, sizeof(wf_region));
  if (copy == NULL) return WF_ERR_MEMORY;
  memcpy(copy, regions, (size_t)region_count * sizeof(wf_region));

  // Swapped in only once the new list exists, so a failed allocation leaves the
  // render playing exactly what it was playing.
  free(render->regions);
  render->regions = copy;
  render->region_count = region_count;

  render->length = 0;
  for (int32_t index = 0; index < region_count; index++) {
    render->length += wf_region_frames(&regions[index]);
  }

  // A position means nothing against a list it was not measured on, so this
  // rewinds and leaves the caller to seek where it wants to be.
  render->index = 0;
  render->offset = 0;
  render->seek_pending = 1;
  render->failed = 0;
  return WF_OK;
}

int32_t wf_render_seek(wf_render *render, double output_frame) {
  if (render == NULL) return WF_ERR_ARGUMENT;

  int64_t target = (int64_t)output_frame;
  if (target < 0) target = 0;
  if (target > render->length) target = render->length;

  // Walk the regions rather than dividing. They have different lengths, and a
  // zero-length one contributes nothing but must not shift the mapping.
  int64_t seen = 0;
  for (int32_t index = 0; index < render->region_count; index++) {
    const int64_t length = wf_region_frames(&render->regions[index]);
    if (length == 0) continue;

    if (target < seen + length) {
      render->index = index;
      render->offset = target - seen;
      render->seek_pending = 1;
      render->failed = 0;
      return WF_OK;
    }
    seen += length;
  }

  // At or past the end. The next read returns nothing.
  render->index = render->region_count;
  render->offset = 0;
  render->seek_pending = 1;
  render->failed = 0;
  return WF_OK;
}

int32_t wf_render_read(wf_render *render, int16_t *out, int32_t max_frames) {
  if (render == NULL || out == NULL || max_frames <= 0) return 0;
  if (render->failed) return -1;

  const int32_t channels = render->source.channels;
  int32_t written = 0;

  while (written < max_frames && render->index < render->region_count) {
    const wf_region region = render->regions[render->index];
    const int64_t length = wf_region_frames(&region);
    if (length == 0) {
      render->index++;
      render->offset = 0;
      render->seek_pending = 1;
      continue;
    }

    if (render->seek_pending) {
      const int64_t at = (int64_t)region.source_start + render->offset;
      if (!wf_source_seek(&render->source, at)) {
        render->failed = 1;
        return written > 0 ? written : -1;
      }
      render->seek_pending = 0;
    }

    int64_t want = (int64_t)max_frames - written;
    if (want > length - render->offset) want = length - render->offset;

    int16_t *block = out + (int64_t)written * channels;
    const int64_t got = wf_source_read(&render->source, block, want);
    if (got <= 0) {
      // The source ended inside this region. Keep what exists and move to the
      // next one, which is what the exporter has always done.
      render->index++;
      render->offset = 0;
      render->seek_pending = 1;
      continue;
    }

    // Gain and fades are applied per sample, in place, before the caller sees
    // them. The envelope offset is absolute within the region, so the size of
    // this block cannot change a single output sample.
    for (int64_t frame = 0; frame < got; frame++) {
      const float envelope =
          region.gain * wf_envelope(render->offset + frame, length,
                                    region.fade_in, region.fade_out);
      if (envelope == 1.0f) continue;

      for (int32_t channel = 0; channel < channels; channel++) {
        const int64_t at = frame * channels + channel;
        float scaled = (float)block[at] * envelope;
        if (scaled > 32767.0f) scaled = 32767.0f;
        if (scaled < -32768.0f) scaled = -32768.0f;
        block[at] = (int16_t)scaled;
      }
    }

    written += (int32_t)got;
    render->offset += got;
    if (render->offset >= length) {
      render->index++;
      render->offset = 0;
      render->seek_pending = 1;
    }
  }

  return written;
}

#ifndef WF_NO_STDIO

int32_t wf_export_wav(const char *src_path, const char *out_path,
                      const wf_region *regions, int32_t region_count) {
  if (out_path == NULL) return WF_ERR_ARGUMENT;

  // The exporter is now a file sink over wf_render. Every decision about what
  // the samples are lives in wf_render_read, so an export and a preview cannot
  // drift apart.
  int32_t error = WF_OK;
  wf_render *render = wf_render_open(src_path, regions, region_count, &error);
  if (render == NULL) return error;

  const int32_t channels = wf_render_channels(render);

  drwav_data_format format;
  format.container = drwav_container_riff;
  format.format = DR_WAVE_FORMAT_PCM;
  format.channels = (drwav_uint32)channels;
  format.sampleRate = (drwav_uint32)wf_render_sample_rate(render);
  format.bitsPerSample = 16;

  drwav out;
  if (!drwav_init_file_write(&out, out_path, &format, NULL)) {
    wf_render_close(render);
    return WF_ERR_OPEN;
  }

  // Unchanged at 4096. The renderer applies the same envelope whatever the
  // block size, so this number is a memory choice and nothing more.
  const int32_t chunk_frames = 4096;
  int16_t *chunk = (int16_t *)malloc((size_t)chunk_frames * (size_t)channels *
                                     sizeof(int16_t));
  if (chunk == NULL) {
    drwav_uninit(&out);
    wf_render_close(render);
    return WF_ERR_MEMORY;
  }

  int32_t status = WF_OK;

  for (;;) {
    const int32_t got = wf_render_read(render, chunk, chunk_frames);
    if (got < 0) {
      status = WF_ERR_DECODE;
      break;
    }
    if (got == 0) break;

    if (drwav_write_pcm_frames(&out, (drwav_uint64)got, chunk) !=
        (drwav_uint64)got) {
      status = WF_ERR_OPEN;
      break;
    }
  }

  free(chunk);
  drwav_uninit(&out);
  wf_render_close(render);
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

/// The path-based render. Web reaches wf_render_open_memory instead, which is
/// the same renderer over the same decoders - only the input differs.
wf_render *wf_render_open(const char *src_path, const wf_region *regions,
                          int32_t region_count, int32_t *out_error) {
  (void)src_path;
  (void)regions;
  (void)region_count;
  if (out_error != NULL) *out_error = WF_ERR_OPEN;
  return NULL;
}

#endif  // WF_NO_STDIO
