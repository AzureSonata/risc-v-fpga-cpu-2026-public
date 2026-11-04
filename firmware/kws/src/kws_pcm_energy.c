#include "kws_pcm_energy.h"

void kws_pcm_energy_reset(kws_pcm_energy_t *ctx)
{
  uint32_t i;
  if (ctx == 0) return;
  ctx->samples_seen = 0u;
  ctx->partial_ss = 0u;
  ctx->window_ss = 0u;
  ctx->bucket_write = 0u;
  ctx->bucket_samples = 0u;
  for (i = 0u; i < KWS_PCM_ENERGY_BUCKETS; ++i) ctx->buckets[i] = 0u;
}

void kws_pcm_energy_push(kws_pcm_energy_t *ctx, int16_t sample)
{
  int64_t wide;
  if (ctx == 0) return;
  wide = sample;
  ctx->partial_ss += (uint64_t)(wide * wide);
  ctx->samples_seen++;
  if (++ctx->bucket_samples == KWS_PCM_ENERGY_BUCKET_SAMPLES) {
    ctx->window_ss -= ctx->buckets[ctx->bucket_write];
    ctx->buckets[ctx->bucket_write] = ctx->partial_ss;
    ctx->window_ss += ctx->partial_ss;
    if (++ctx->bucket_write == KWS_PCM_ENERGY_BUCKETS) ctx->bucket_write = 0u;
    ctx->bucket_samples = 0u;
    ctx->partial_ss = 0u;
  }
}

uint8_t kws_pcm_energy_ready(const kws_pcm_energy_t *ctx)
{
  return (uint8_t)(ctx != 0 &&
                   ctx->samples_seen >= KWS_PCM_ENERGY_WINDOW_SAMPLES &&
                   ctx->bucket_samples == 0u);
}

uint64_t kws_pcm_energy_sum(const kws_pcm_energy_t *ctx)
{
  return ctx == 0 ? 0u : ctx->window_ss;
}
