// Container sniffing and streaming decode, on top of the dr_libs decoders.
//
// Streaming rather than decode-then-reduce: frames are pulled a bucket at a
// time and collapsed to a min/max pair immediately, so peak memory is one
// bucket regardless of whether the input is a voice note or an audiobook.
//
// Codec coverage is WAV, MP3 and FLAC. **AAC/M4A is not supported** and cannot
// be without either a platform decoder or a much heavier dependency. That is a
// real gap for iOS recordings, and the reason it is tolerable is that the
// voice-note path never decodes at all: the sender computes peaks at record
// time and ships them as metadata.

#include <stdlib.h>
#include <string.h>

#include "monowave.h"

#define DR_WAV_IMPLEMENTATION
#define DR_MP3_IMPLEMENTATION
#define DR_FLAC_IMPLEMENTATION

#ifdef WF_NO_STDIO
// The WASM build has no filesystem worth reading, so the file-backed halves of
// the decoders are dead weight in the artifact every platform ships.
#define DR_WAV_NO_STDIO
#define DR_MP3_NO_STDIO
#define DR_FLAC_NO_STDIO
#endif

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
  int64_t length;
} wf_reader;

/// Identifies the container from its first bytes.
///
/// MP3 is the fallback rather than a positive match: it has no reliable magic,
/// only a frame sync that arbitrary data can imitate, so it is what we try when
/// nothing else claims the input.
static int wf_sniff(const unsigned char *head, size_t size) {
  if (size >= 12 && memcmp(head, "RIFF", 4) == 0 &&
      memcmp(head + 8, "WAVE", 4) == 0) {
    return WF_KIND_WAV;
  }
  if (size >= 4 && memcmp(head, "fLaC", 4) == 0) return WF_KIND_FLAC;
  return WF_KIND_MP3;
}

static int64_t wf_reader_read(wf_reader *reader, int16_t *out, int64_t frames) {
  switch (reader->kind) {
    case WF_KIND_WAV:
      return (int64_t)drwav_read_pcm_frames_s16(&reader->wav,
                                                (drwav_uint64)frames, out);
    case WF_KIND_MP3:
      return (int64_t)drmp3_read_pcm_frames_s16(&reader->mp3,
                                                (drmp3_uint64)frames, out);
    case WF_KIND_FLAC:
      return (int64_t)drflac_read_pcm_frames_s16(reader->flac,
                                                 (drflac_uint64)frames, out);
    default:
      return 0;
  }
}

static void wf_reader_close(wf_reader *reader) {
  switch (reader->kind) {
    case WF_KIND_WAV:
      drwav_uninit(&reader->wav);
      break;
    case WF_KIND_MP3:
      drmp3_uninit(&reader->mp3);
      break;
    case WF_KIND_FLAC:
      if (reader->flac != NULL) drflac_close(reader->flac);
      break;
    default:
      break;
  }
}

static int wf_reader_open_memory(wf_reader *reader, const void *data,
                                 size_t size) {
  reader->kind = wf_sniff((const unsigned char *)data, size);
  reader->flac = NULL;

  switch (reader->kind) {
    case WF_KIND_WAV:
      if (!drwav_init_memory(&reader->wav, data, size, NULL)) return 0;
      reader->sample_rate = (int32_t)reader->wav.sampleRate;
      reader->channels = (int32_t)reader->wav.channels;
      reader->length = (int64_t)reader->wav.totalPCMFrameCount;
      return 1;
    case WF_KIND_FLAC:
      reader->flac = drflac_open_memory(data, size, NULL);
      if (reader->flac == NULL) return 0;
      reader->sample_rate = (int32_t)reader->flac->sampleRate;
      reader->channels = (int32_t)reader->flac->channels;
      reader->length = (int64_t)reader->flac->totalPCMFrameCount;
      return 1;
    default:
      if (!drmp3_init_memory(&reader->mp3, data, size, NULL)) return 0;
      reader->sample_rate = (int32_t)reader->mp3.sampleRate;
      reader->channels = (int32_t)reader->mp3.channels;
      // MP3 has no cheap length: getting one means scanning the whole file, so
      // it is counted while decoding instead.
      reader->length = 0;
      return 1;
  }
}

#ifndef WF_NO_STDIO
static int wf_reader_open_file(wf_reader *reader, const char *path) {
  unsigned char head[12];
  memset(head, 0, sizeof(head));

  FILE *probe = fopen(path, "rb");
  if (probe == NULL) return 0;
  const size_t read = fread(head, 1, sizeof(head), probe);
  fclose(probe);

  reader->kind = wf_sniff(head, read);
  reader->flac = NULL;

  switch (reader->kind) {
    case WF_KIND_WAV:
      if (!drwav_init_file(&reader->wav, path, NULL)) return 0;
      reader->sample_rate = (int32_t)reader->wav.sampleRate;
      reader->channels = (int32_t)reader->wav.channels;
      reader->length = (int64_t)reader->wav.totalPCMFrameCount;
      return 1;
    case WF_KIND_FLAC:
      reader->flac = drflac_open_file(path, NULL);
      if (reader->flac == NULL) return 0;
      reader->sample_rate = (int32_t)reader->flac->sampleRate;
      reader->channels = (int32_t)reader->flac->channels;
      reader->length = (int64_t)reader->flac->totalPCMFrameCount;
      return 1;
    default:
      if (!drmp3_init_file(&reader->mp3, path, NULL)) return 0;
      reader->sample_rate = (int32_t)reader->mp3.sampleRate;
      reader->channels = (int32_t)reader->mp3.channels;
      reader->length = 0;
      return 1;
  }
}
#endif

/// Pulls the reader dry one bucket at a time, reducing as it goes.
static wf_peaks *wf_build(wf_reader *reader, int32_t base_spp,
                          int32_t *out_error) {
  if (reader->channels <= 0 || reader->sample_rate <= 0) {
    *out_error = WF_ERR_FORMAT;
    return NULL;
  }

  const size_t chunk_samples = (size_t)base_spp * (size_t)reader->channels;
  int16_t *chunk = (int16_t *)malloc(chunk_samples * sizeof(int16_t));
  if (chunk == NULL) {
    *out_error = WF_ERR_MEMORY;
    return NULL;
  }

  wf_pair_builder builder;
  wf_pair_builder_init(&builder);
  int64_t frames_seen = 0;

  for (;;) {
    const int64_t frames = wf_reader_read(reader, chunk, base_spp);
    if (frames <= 0) break;
    frames_seen += frames;

    // Extremes across every sample in the bucket, channels included. A
    // single-lane waveform should show the true excursion of the moment, not
    // one channel's version of it.
    int16_t lo = 32767;
    int16_t hi = -32768;
    const int64_t samples = frames * reader->channels;
    for (int64_t i = 0; i < samples; i++) {
      const int16_t s = chunk[i];
      if (s < lo) lo = s;
      if (s > hi) hi = s;
    }

    wf_pair_builder_push(&builder, lo, hi);
    if (builder.failed) break;
  }

  free(chunk);

  if (builder.failed) {
    wf_pair_builder_dispose(&builder);
    *out_error = WF_ERR_MEMORY;
    return NULL;
  }
  if (frames_seen == 0) {
    wf_pair_builder_dispose(&builder);
    *out_error = WF_ERR_EMPTY;
    return NULL;
  }

  const int64_t length = reader->length > 0 ? reader->length : frames_seen;
  wf_peaks *peaks = wf_peaks_from_base(&builder, reader->sample_rate,
                                       reader->channels, length, base_spp);
  if (peaks == NULL) {
    wf_pair_builder_dispose(&builder);
    *out_error = WF_ERR_MEMORY;
    return NULL;
  }

  *out_error = WF_OK;
  return peaks;
}

wf_peaks *wf_decode_memory(const void *data, size_t size, int32_t base_spp,
                           int32_t *out_error) {
  int32_t ignored = 0;
  if (out_error == NULL) out_error = &ignored;

  if (data == NULL || size == 0 || base_spp < 1) {
    *out_error = WF_ERR_ARGUMENT;
    return NULL;
  }

  wf_reader reader;
  memset(&reader, 0, sizeof(reader));
  if (!wf_reader_open_memory(&reader, data, size)) {
    *out_error = WF_ERR_FORMAT;
    return NULL;
  }

  wf_peaks *peaks = wf_build(&reader, base_spp, out_error);
  wf_reader_close(&reader);
  return peaks;
}

wf_peaks *wf_decode_file(const char *path, int32_t base_spp,
                         int32_t *out_error) {
  int32_t ignored = 0;
  if (out_error == NULL) out_error = &ignored;

  if (path == NULL || base_spp < 1) {
    *out_error = WF_ERR_ARGUMENT;
    return NULL;
  }

#ifdef WF_NO_STDIO
  (void)path;
  *out_error = WF_ERR_OPEN;
  return NULL;
#else
  wf_reader reader;
  memset(&reader, 0, sizeof(reader));
  if (!wf_reader_open_file(&reader, path)) {
    *out_error = WF_ERR_OPEN;
    return NULL;
  }

  wf_peaks *peaks = wf_build(&reader, base_spp, out_error);
  wf_reader_close(&reader);
  return peaks;
#endif
}
