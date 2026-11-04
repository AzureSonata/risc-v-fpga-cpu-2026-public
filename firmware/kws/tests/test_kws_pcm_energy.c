#include <stdio.h>
#include <stdlib.h>

#include "kws_pcm_energy.h"

static int read_pcm(const char *path, int16_t **samples, size_t *count)
{
  FILE *file = fopen(path, "rb");
  long bytes;
  uint8_t *raw;
  size_t i;
  if (file == 0) return -1;
  if (fseek(file, 0, SEEK_END) != 0 || (bytes = ftell(file)) < 0 ||
      (bytes & 1L) != 0L || fseek(file, 0, SEEK_SET) != 0) {
    fclose(file);
    return -1;
  }
  raw = (uint8_t *)malloc((size_t)bytes);
  if (raw == 0 || fread(raw, 1u, (size_t)bytes, file) != (size_t)bytes) {
    free(raw);
    fclose(file);
    return -1;
  }
  fclose(file);
  *count = (size_t)bytes / 2u;
  *samples = (int16_t *)malloc(*count * sizeof(**samples));
  if (*samples == 0) {
    free(raw);
    return -1;
  }
  for (i = 0u; i < *count; ++i) {
    uint16_t word = (uint16_t)raw[2u * i] |
                    ((uint16_t)raw[2u * i + 1u] << 8);
    (*samples)[i] = (int16_t)word;
  }
  free(raw);
  return 0;
}

int main(int argc, char **argv)
{
  kws_pcm_energy_t energy;
  int16_t *all = 0;
  size_t total = 0u, f, i, checks = 0u;

  if (argc != 4) {
    (void)fprintf(stderr, "usage: test_kws_pcm_energy yes.s16le no.s16le silence.s16le\n");
    return 2;
  }
  for (f = 1u; f < 4u; ++f) {
    int16_t *part = 0;
    size_t count = 0u;
    int16_t *grown;
    if (read_pcm(argv[f], &part, &count) != 0) {
      (void)fprintf(stderr, "FAIL: cannot read PCM fixture %s\n", argv[f]);
      free(all);
      return 2;
    }
    grown = (int16_t *)realloc(all, (total + count) * sizeof(*all));
    if (grown == 0) {
      free(part);
      free(all);
      return 2;
    }
    all = grown;
    for (i = 0u; i < count; ++i) all[total + i] = part[i];
    total += count;
    free(part);
  }

  kws_pcm_energy_reset(&energy);
  for (i = 0u; i < total; ++i) {
    kws_pcm_energy_push(&energy, all[i]);
    if (kws_pcm_energy_ready(&energy) &&
        ((i + 1u) % 3200u) == 0u) {
      size_t j;
      uint64_t expected = 0u;
      for (j = i + 1u - KWS_PCM_ENERGY_WINDOW_SAMPLES; j <= i; ++j) {
        int64_t sample = all[j];
        expected += (uint64_t)(sample * sample);
      }
      if (kws_pcm_energy_sum(&energy) != expected) {
        (void)fprintf(stderr, "FAIL: sample=%zu rolling sum differs from direct PCM sum\n", i + 1u);
        free(all);
        return 1;
      }
      checks++;
    }
  }
  kws_pcm_energy_reset(&energy);
  if (kws_pcm_energy_ready(&energy) || kws_pcm_energy_sum(&energy) != 0u) {
    (void)fprintf(stderr, "FAIL: reset did not clear the rolling energy window\n");
    free(all);
    return 1;
  }
  free(all);
  if (checks == 0u) {
    (void)fprintf(stderr, "FAIL: fixture stream contained no complete 200 ms checkpoint\n");
    return 1;
  }
  (void)printf("PASS: %zu windows from concatenated Yes/No/silence PCM match direct 16000-sample energy\n",
               checks);
  return 0;
}
