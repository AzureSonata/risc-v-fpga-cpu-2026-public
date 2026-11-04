#include "kws_fan_control.h"

void kws_fan_control_init(kws_fan_control_t *ctx)
{
  if (ctx == 0) return;
  ctx->debug_event = KWS_FAN_MARK_BOOT;
  ctx->fan_enabled = 0u;
  ctx->trip_latched = 0u;
}

void kws_fan_control_step(kws_fan_control_t *ctx, uint8_t estop_trip,
                          uint8_t safe_fault,
                          const kws_estop_step_t *decision)
{
  if (ctx == 0) return;

  if (estop_trip != 0u) {
    ctx->trip_latched = 1u;
    ctx->fan_enabled = 0u;
    ctx->debug_event = KWS_FAN_MARK_TRIP;
    return;
  }

  if (ctx->trip_latched != 0u) {
    ctx->fan_enabled = 0u;
    return;
  }

  if (safe_fault != 0u) {
    ctx->fan_enabled = 0u;
    ctx->debug_event = KWS_FAN_MARK_FAULT;
    return;
  }

  if (decision == 0 || decision->event == 0u) return;

  if (decision->event_class == KWS_ESTOP_CLASS_YES) {
    ctx->fan_enabled = 1u;
    ctx->debug_event = KWS_FAN_MARK_YES;
  } else if (decision->event_class == KWS_ESTOP_CLASS_NO) {
    ctx->fan_enabled = 0u;
    ctx->debug_event = KWS_FAN_MARK_NO;
  }
}

uint32_t kws_fan_control_gpio_word(const kws_fan_control_t *ctx)
{
  uint32_t word;
  if (ctx == 0) return 0u;
  word = ctx->debug_event & ~KWS_FAN_GPIO_ENABLE;
  if (ctx->fan_enabled != 0u && ctx->trip_latched == 0u)
    word |= KWS_FAN_GPIO_ENABLE;
  return word;
}
