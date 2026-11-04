#ifndef KWS_FAN_CONTROL_H
#define KWS_FAN_CONTROL_H

#include <stdint.h>
#include "kws_estop.h"

#define KWS_FAN_GPIO_ENABLE (1u << 31)

#define KWS_FAN_MARK_BOOT     0x45537900u
#define KWS_FAN_MARK_YES      0x45537901u
#define KWS_FAN_MARK_NO       0x45537902u
#define KWS_FAN_MARK_TRIP     0x45537903u
#define KWS_FAN_MARK_FAULT    0x45537904u

typedef struct {
  uint32_t debug_event;
  uint8_t fan_enabled;
  uint8_t trip_latched;
} kws_fan_control_t;

void kws_fan_control_init(kws_fan_control_t *ctx);
void kws_fan_control_step(kws_fan_control_t *ctx, uint8_t estop_trip,
                          uint8_t safe_fault,
                          const kws_estop_step_t *decision);
uint32_t kws_fan_control_gpio_word(const kws_fan_control_t *ctx);

#endif
