#include <stdio.h>

#include "kws_fan_control.h"

static int failures;

#define CHECK(cond, label) do { \
  if (!(cond)) { \
    (void)fprintf(stderr, "FAIL: %s\n", label); \
    failures++; \
  } \
} while (0)

static kws_estop_step_t event(uint8_t class_id)
{
  kws_estop_step_t st = {0};
  st.event = 1u;
  st.event_class = class_id;
  return st;
}

int main(void)
{
  kws_fan_control_t ctx;
  kws_estop_step_t yes = event(KWS_ESTOP_CLASS_YES);
  kws_estop_step_t no = event(KWS_ESTOP_CLASS_NO);
  kws_estop_step_t unknown = event(1u);

  kws_fan_control_init(&ctx);
  CHECK((kws_fan_control_gpio_word(&ctx) & KWS_FAN_GPIO_ENABLE) == 0u,
        "fan defaults off");

  kws_fan_control_step(&ctx, 0u, 0u, &yes);
  CHECK((kws_fan_control_gpio_word(&ctx) & KWS_FAN_GPIO_ENABLE) != 0u,
        "confirmed Yes turns fan on");
  CHECK((kws_fan_control_gpio_word(&ctx) & ~KWS_FAN_GPIO_ENABLE) == KWS_FAN_MARK_YES,
        "Yes debug marker remains in GPIO low bits");

  kws_fan_control_step(&ctx, 0u, 0u, 0);
  kws_fan_control_step(&ctx, 0u, 0u, &unknown);
  CHECK((kws_fan_control_gpio_word(&ctx) & KWS_FAN_GPIO_ENABLE) != 0u,
        "silence/unknown hold the current fan state");

  kws_fan_control_step(&ctx, 0u, 0u, &no);
  CHECK((kws_fan_control_gpio_word(&ctx) & KWS_FAN_GPIO_ENABLE) == 0u,
        "confirmed No turns fan off");
  CHECK((kws_fan_control_gpio_word(&ctx) & ~KWS_FAN_GPIO_ENABLE) == KWS_FAN_MARK_NO,
        "No debug marker remains in GPIO low bits");

  kws_fan_control_step(&ctx, 0u, 0u, &yes);
  kws_fan_control_step(&ctx, 1u, 0u, 0);
  CHECK(ctx.trip_latched != 0u &&
        (kws_fan_control_gpio_word(&ctx) & KWS_FAN_GPIO_ENABLE) == 0u,
        "hardware trip forces software request off and latches");
  kws_fan_control_step(&ctx, 0u, 0u, &yes);
  CHECK((kws_fan_control_gpio_word(&ctx) & KWS_FAN_GPIO_ENABLE) == 0u,
        "voice cannot restart fan after trip");

  kws_fan_control_init(&ctx); /* CPU restart; hardware trip is still sticky. */
  kws_fan_control_step(&ctx, 1u, 0u, &yes);
  CHECK((kws_fan_control_gpio_word(&ctx) & KWS_FAN_GPIO_ENABLE) == 0u,
        "CPU reset with sticky trip stays safe");

  kws_fan_control_init(&ctx);
  kws_fan_control_step(&ctx, 0u, 0u, &yes);
  kws_fan_control_step(&ctx, 0u, 1u, 0);
  CHECK((kws_fan_control_gpio_word(&ctx) & KWS_FAN_GPIO_ENABLE) == 0u &&
        (kws_fan_control_gpio_word(&ctx) & ~KWS_FAN_GPIO_ENABLE) == KWS_FAN_MARK_FAULT,
        "audio overrun/fault clears fan request and records low-bit marker");

  if (failures != 0) {
    (void)fprintf(stderr, "%d KWS fan control checks failed\n", failures);
    return 1;
  }
  (void)puts("PASS: fan defaults off, Yes/No state changes, hold, trip latch, audio fault");
  return 0;
}
