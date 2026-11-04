#include <stdint.h>
#include "kws_estop.h"

#define KWS_CTRL_BASE  0x40000000u
#define KWS_BUF_BASE   0x40001000u
#define KWS_ID         0x000u
#define KWS_START      0x004u
#define KWS_STATUS     0x008u
#define KWS_ERROR      0x014u
#define KWS_INPUT_SIZE 0x018u
#define KWS_RESULT     0x800u
#define KWS_ESTOP_TRIP 0x054u
#define KWS_ESTOP_ARMED (1u << 8)
#define GPIO_OUT       (*(volatile uint32_t *)0x10000010u)
#define GPIO_EVENT     0x45537901u
#define GPIO_TRIP_SEEN 0x45537902u
#define JOB_LIMIT      3u
#define POLL_LIMIT     1500000u

extern const uint8_t w3_kws_yes_fixture[1960];

static volatile uint32_t *const ctrl = (volatile uint32_t *)KWS_CTRL_BASE;
static volatile uint8_t *const input = (volatile uint8_t *)KWS_BUF_BASE;
static volatile uint32_t *const result = (volatile uint32_t *)(KWS_BUF_BASE + KWS_RESULT);

static void fail(uint32_t code) {
  GPIO_OUT = code;
  for (;;) __asm__ volatile("nop");
}

void w3_kws_main(void) {
  uint32_t job, polls, status, packed;
  int8_t logits[4];
  kws_estop_ctx_t estop;
  kws_estop_step_t step;
  kws_estop_init_default(&estop);
  if (ctrl[KWS_ID / 4] != 0x3153574Bu || ctrl[KWS_INPUT_SIZE / 4] != 1960u)
    fail(0xE1000001u);

  for (job = 0; job < JOB_LIMIT; ++job) {
    uint32_t i;
    for (i = 0; i < 1960u; ++i) input[i] = w3_kws_yes_fixture[i];
    ctrl[KWS_START / 4] = 1u;
    for (polls = 0; polls < POLL_LIMIT; ++polls) {
      status = ctrl[KWS_STATUS / 4];
      if ((status & KWS_ESTOP_ARMED) == 0u) fail(0xE5000000u | job);
      if (status & 0x06u) break; /* DONE or ERROR */
    }
    if (polls == POLL_LIMIT) fail(0xE2000000u | job);
    if ((status & 0x02u) == 0 || (status & 0x04u) != 0)
      fail(0xE3000000u | (ctrl[KWS_ERROR / 4] & 0xffu));

    packed = *result;
    logits[0] = (int8_t)(packed >> 0);
    logits[1] = (int8_t)(packed >> 8);
    logits[2] = (int8_t)(packed >> 16);
    logits[3] = (int8_t)(packed >> 24);
    /* Golden is the tracked K2 host tensor for this exact feature fixture. */
    if (logits[0] != -50 || logits[1] != -4 || logits[2] != 121 || logits[3] != -4)
      fail(0xE4000000u | (packed & 0x00ffffffu));

    step = kws_estop_step(&estop, logits);
    if (!step.accept) fail(0xE5000100u | job);
    if (step.event) {
      if (job != 2u || estop.accepts != 3u || estop.events != 1u)
        fail(0xE5000200u | job);
      GPIO_OUT = GPIO_EVENT; /* Software decision event through the real GPIO port. */
    }
  }
  if (estop.accepts != 3u || estop.events != 1u || GPIO_OUT != GPIO_EVENT)
    fail(0xE5000300u);

  /* The approved ABI exposes arm only as an external strap. This image never
   * writes HB, ARM, or CLEAR; the watchdog must trip independently on timeout. */
  while ((ctrl[KWS_ESTOP_TRIP / 4] & 1u) == 0u) __asm__ volatile("nop");
  GPIO_OUT = GPIO_TRIP_SEEN; /* Firmware observed the independent hardware trip. */
  for (;;) __asm__ volatile("nop");
}
