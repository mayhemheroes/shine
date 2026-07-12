/* shine_kat.c — functional known-answer oracle for the libshine MP3 encoder.
 *
 * Upstream ships NO C unit/functional test suite (only a JS/emscripten node test for the wasm build
 * and a build-only CI job), so this is an AUTHORED behavioral oracle over the same library pipeline
 * the encoder exposes. It encodes a DETERMINISTIC PCM signal at a fixed configuration and writes the
 * resulting MP3 bitstream to the path given in argv[1]. mayhem/test.sh then parses that bitstream and
 * asserts real structural properties (frame sync, MPEG version/layer, bitrate/samplerate/mode header
 * fields, exact frame count, full-stream consumption) — so a no-op / exit(0) "fix" produces no or
 * wrong output and FAILS the oracle. This file is built with the project's NORMAL flags (no
 * sanitizers) so it stays an honest functional oracle.
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "layer3.h"

/* Fixed, documented configuration — these exact values are re-derived and checked by test.sh. */
#define KAT_SAMPLERATE 44100
#define KAT_BITRATE 128
#define KAT_CHANNELS 1 /* mono */
#define KAT_PASSES 64  /* number of full encoder passes (one MP3 frame each) */

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s <out.mp3>\n", argv[0]);
    return 2;
  }

  FILE *out = fopen(argv[1], "wb");
  if (!out) {
    fprintf(stderr, "cannot open %s\n", argv[1]);
    return 2;
  }

  shine_config_t config;
  shine_set_config_mpeg_defaults(&config.mpeg);
  config.wave.samplerate = KAT_SAMPLERATE;
  config.wave.channels = KAT_CHANNELS;
  config.mpeg.bitr = KAT_BITRATE;
  config.mpeg.mode = MONO;

  if (shine_check_config(KAT_SAMPLERATE, KAT_BITRATE) < 0) {
    fprintf(stderr, "config rejected\n");
    return 2;
  }

  shine_t s = shine_initialise(&config);
  if (!s) {
    fprintf(stderr, "shine_initialise failed\n");
    return 2;
  }

  int spp = shine_samples_per_pass(s);
  int16_t *buffer = (int16_t *)malloc((size_t)spp * sizeof(int16_t));
  if (!buffer) {
    shine_close(s);
    return 2;
  }

  int written = 0;
  unsigned char *data = NULL;
  double phase = 0.0;
  /* 440 Hz sine at KAT_SAMPLERATE. */
  const double step = 2.0 * M_PI * 440.0 / (double)KAT_SAMPLERATE;

  for (int pass = 0; pass < KAT_PASSES; pass++) {
    for (int i = 0; i < spp; i++) {
      buffer[i] = (int16_t)(sin(phase) * 20000.0);
      phase += step;
    }
    data = shine_encode_buffer_interleaved(s, buffer, &written);
    if (written > 0 && data)
      fwrite(data, 1, (size_t)written, out);
  }

  data = shine_flush(s, &written);
  if (written > 0 && data)
    fwrite(data, 1, (size_t)written, out);

  free(buffer);
  shine_close(s);
  fclose(out);
  return 0;
}
