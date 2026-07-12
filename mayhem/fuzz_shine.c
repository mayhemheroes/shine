/* fuzz_shine.c — in-process libFuzzer harness for the libshine fixed-point MP3 encoder.
 *
 * WHY IN-PROCESS: the original maymemheroes/shine target was the `shineenc` CLI driven as a raw
 * file-input black box (`/shine @@ out`). Built with a plain gcc, it was UNINSTRUMENTED, so Mayhem
 * recorded 0 edges — unfuzzable. Per the porting policy an unfuzzable raw-file CLI is converted to
 * an in-process libFuzzer harness over the SAME code path. The CLI's job is: read PCM, then push it
 * through libshine's streaming encoder (`shine_encode_buffer_interleaved` + `shine_flush`) — exactly
 * the library pipeline (l3loop / l3mdct / l3subband / huffman / bitstream / reservoir) this harness
 * drives directly, now compiled with ASan+UBSan so the encoder itself is instrumented.
 *
 * The harness derives a VALID encoder configuration (samplerate / bitrate / channels / mode) from a
 * small fixed-size prefix of the fuzz input so shine_initialise() succeeds and the fuzzer spends its
 * budget exploring the encoder, then feeds the remaining bytes as interleaved 16-bit PCM frames.
 */
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "layer3.h"

/* The nine samplerates the encoder accepts (layer3.c `samplerates[]`), by index. */
static const int kSampleRates[9] = {
    44100, 48000, 32000, /* MPEG-I  */
    22050, 24000, 16000, /* MPEG-II */
    11025, 12000, 8000   /* MPEG-2.5 */
};

/* Candidate bitrates spanning every column of the encoder's bitrate table. We validate the pick
 * with shine_check_config() and fall back to the first valid one for the chosen samplerate. */
static const int kBitrates[18] = {8,  16,  24,  32,  40,  48,  56,  64, 80,
                                   96, 112, 128, 144, 160, 192, 224, 256, 320};

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  /* Reserve a 4-byte header to steer the configuration. */
  if (size < 4)
    return 0;

  const int samplerate = kSampleRates[data[0] % 9];
  const int channels = (data[1] & 1) ? 2 : 1;

  /* Choose the first valid bitrate for this samplerate, starting from an input-controlled offset. */
  int bitr = -1;
  int start = data[3] % 18;
  for (int k = 0; k < 18; k++) {
    int cand = kBitrates[(start + k) % 18];
    if (shine_check_config(samplerate, cand) >= 0) {
      bitr = cand;
      break;
    }
  }
  if (bitr < 0)
    return 0; /* no supported bitrate for this samplerate (should not happen) */

  shine_config_t config;
  memset(&config, 0, sizeof(config));
  shine_set_config_mpeg_defaults(&config.mpeg);
  config.wave.samplerate = samplerate;
  config.wave.channels = channels;
  config.mpeg.bitr = bitr;
  /* Stereo data can be STEREO / JOINT_STEREO / DUAL_CHANNEL; mono must be MONO. */
  config.mpeg.mode = (channels > 1) ? (int)(data[2] % 3) : MONO;

  shine_t s = shine_initialise(&config);
  if (!s)
    return 0;

  const int spp = shine_samples_per_pass(s); /* samples per channel per pass */
  if (spp <= 0 || spp > SHINE_MAX_SAMPLES) {
    shine_close(s);
    return 0;
  }

  const size_t frame_samples = (size_t)spp * (size_t)channels;
  const size_t frame_bytes = frame_samples * sizeof(int16_t);
  int16_t *buffer = (int16_t *)malloc(frame_bytes);
  if (!buffer) {
    shine_close(s);
    return 0;
  }

  const uint8_t *pcm = data + 4;
  size_t rem = size - 4;
  size_t off = 0;
  int written = 0;

  /* Feed whole frames straight from the fuzz input. */
  while (off + frame_bytes <= rem) {
    memcpy(buffer, pcm + off, frame_bytes);
    shine_encode_buffer_interleaved(s, buffer, &written);
    off += frame_bytes;
  }

  /* Zero-pad and encode the trailing partial frame, mirroring the CLI's read_samples() padding. */
  if (off < rem) {
    memset(buffer, 0, frame_bytes);
    memcpy(buffer, pcm + off, rem - off);
    shine_encode_buffer_interleaved(s, buffer, &written);
  }

  shine_flush(s, &written);

  free(buffer);
  shine_close(s);
  return 0;
}
