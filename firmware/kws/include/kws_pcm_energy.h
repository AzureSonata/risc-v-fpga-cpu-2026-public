#ifndef KWS_PCM_ENERGY_H
#define KWS_PCM_ENERGY_H

#include <stdint.h>

#define KWS_PCM_ENERGY_WINDOW_SAMPLES 16000u
#define KWS_PCM_ENERGY_BUCKET_SAMPLES 80u
#define KWS_PCM_ENERGY_BUCKETS \
  (KWS_PCM_ENERGY_WINDOW_SAMPLES / KWS_PCM_ENERGY_BUCKET_SAMPLES)

typedef struct {
  uint64_t buckets[KWS_PCM_ENERGY_BUCKETS];
  uint64_t samples_seen;
  uint64_t partial_ss;
  uint64_t window_ss;
  uint16_t bucket_write;
  uint16_t bucket_samples;
} kws_pcm_energy_t;

void kws_pcm_energy_reset(kws_pcm_energy_t *ctx);
void kws_pcm_energy_push(kws_pcm_energy_t *ctx, int16_t sample);
uint8_t kws_pcm_energy_ready(const kws_pcm_energy_t *ctx);
uint64_t kws_pcm_energy_sum(const kws_pcm_energy_t *ctx);

#endif
