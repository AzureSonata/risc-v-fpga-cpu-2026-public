#include <stdio.h>
#include <stdlib.h>

#include "kws_fan_control.h"
#include "kws_live_decision.h"
#include "kws_pcm_energy.h"

/* The Yes fixture uses the exact augmented-ROM FC output probe. */
static const int8_t yes_q[4] = {-36, 22, 72, -38};
static const int8_t no_q[4] = {-50, -4, -4, 121};
static const int8_t silence_q[4] = {80, -50, -4, -4};

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

static int run_stream(const int16_t *pcm, size_t count,
                      size_t yes_end, size_t no_end,
                      uint8_t expect_yes, uint8_t *saw_no)
{
  kws_pcm_energy_t energy;
  kws_live_decision_t decision_ctx;
  kws_fan_control_t fan;
  uint8_t saw_fan_on = 0u;
  size_t i;

  kws_pcm_energy_reset(&energy);
  kws_live_decision_init(&decision_ctx);
  kws_fan_control_init(&fan);
  for (i = 0u; i < count; ++i) {
    uint64_t samples_now;
    const int8_t *q;
    kws_estop_step_t decision;
    kws_pcm_energy_push(&energy, pcm[i]);
    samples_now = (uint64_t)i + 1u;
    if (!kws_pcm_energy_ready(&energy) ||
        ((samples_now - KWS_PCM_ENERGY_WINDOW_SAMPLES) % 3200u) != 0u)
      continue;

    q = samples_now <= yes_end ? yes_q :
        (samples_now <= no_end ? no_q : silence_q);
    decision = kws_live_decision_step(&decision_ctx, q,
                                       (int64_t)kws_pcm_energy_sum(&energy));
    kws_fan_control_step(&fan, 0u, 0u, &decision);
    if ((kws_fan_control_gpio_word(&fan) & KWS_FAN_GPIO_ENABLE) != 0u)
      saw_fan_on = 1u;
    if (fan.debug_event == KWS_FAN_MARK_NO) *saw_no = 1u;
    if (*saw_no && (kws_fan_control_gpio_word(&fan) & KWS_FAN_GPIO_ENABLE) != 0u)
      return -1;
  }
  if (expect_yes) return saw_fan_on ? 0 : -1;
  return ((kws_fan_control_gpio_word(&fan) & KWS_FAN_GPIO_ENABLE) == 0u && *saw_no) ? 0 : -1;
}

int main(int argc, char **argv)
{
  int16_t *yes = 0, *no = 0, *silence = 0, *stream = 0;
  size_t nyes = 0u, nno = 0u, nsilence = 0u, i, nstream;
  uint8_t saw_no = 0u;
  int rc = 1;

  if (argc != 4) {
    (void)fprintf(stderr, "usage: test_kws_live_pcm_stream yes.s16le no.s16le silence.s16le\n");
    return 2;
  }
  if (read_pcm(argv[1], &yes, &nyes) != 0 ||
      read_pcm(argv[2], &no, &nno) != 0 ||
      read_pcm(argv[3], &silence, &nsilence) != 0) {
    (void)fprintf(stderr, "FAIL: cannot read PCM stream fixtures\n");
    goto done;
  }

  nstream = 3u * nyes + nsilence;
  stream = (int16_t *)malloc(nstream * sizeof(*stream));
  if (stream == 0) goto done;
  for (i = 0u; i < 3u * nyes; ++i) stream[i] = yes[i % nyes];
  for (i = 0u; i < nsilence; ++i) stream[3u * nyes + i] = silence[i];
  if (run_stream(stream, nstream, 3u * nyes, 0u, 1u, &saw_no) != 0) {
    (void)fprintf(stderr, "FAIL: repeated real Yes PCM did not open the fan after segment close\n");
    goto done;
  }

  free(stream);
  nstream = nyes + nno + nsilence;
  stream = (int16_t *)malloc(nstream * sizeof(*stream));
  if (stream == 0) goto done;
  for (i = 0u; i < nyes; ++i) stream[i] = yes[i];
  for (i = 0u; i < nno; ++i) stream[nyes + i] = no[i];
  for (i = 0u; i < nsilence; ++i) stream[nyes + nno + i] = silence[i];
  saw_no = 0u;
  if (run_stream(stream, nstream, nyes, nyes + nno, 0u, &saw_no) != 0) {
    (void)fprintf(stderr, "FAIL: real Yes/No/silence stream lost No fan-off or reopened fan\n");
    goto done;
  }

  (void)puts("PASS: concatenated real PCM Yes/No/silence streams drive segment energy and fan decisions");
  rc = 0;
done:
  free(yes);
  free(no);
  free(silence);
  free(stream);
  return rc;
}
