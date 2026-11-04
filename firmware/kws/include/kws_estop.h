/* KWS 急停判决层：纯函数，不直接读写 MMIO。
 *
 * 判序与 tools/estop/decide_ref.py 完全一致：
 *   L1 argmax ∈ {yes(2), no(3)}
 *   L2 score = max(q_yes, q_no) ≥ θ
 *   L3 margin = q[argmax] − max(其余三类) ≥ M_yes or M_no by class
 *   同类 k-of-n 确认（默认 2-of-3；silence/unknown 不计入任何类别）
 *
 * 约定：q[0]=silence, q[1]=unknown, q[2]=yes, q[3]=no；
 * 比较一律用 int16_t，避免 θ=128 时 int8 溢出回绕。
 */
#ifndef KWS_ESTOP_H
#define KWS_ESTOP_H

#include <stdint.h>

#define KWS_ESTOP_THETA      16
#define KWS_ESTOP_MARGIN     48
/* v12demo: single-window NO confirmation (was 2-of-3) so one spoken "no"
 * reliably turns the fan off on camera; the YES path is unchanged. */
#define KWS_ESTOP_CONFIRM_K  1
#define KWS_ESTOP_CONFIRM_N  3
#define KWS_ESTOP_COOLDOWN   0
#define KWS_ESTOP_MAX_N      8

#define KWS_ESTOP_CLASS_NONE 0u
#define KWS_ESTOP_CLASS_YES  2u
#define KWS_ESTOP_CLASS_NO   3u

typedef struct {
  int16_t  theta;
  int16_t  margin_th;     /* YES confirmation margin */
  int16_t  margin_no_th;  /* NO confirmation margin; defaults to margin_th */
  uint8_t  k;
  uint8_t  n;
  uint8_t  cooldown;
  uint8_t  hist[KWS_ESTOP_MAX_N]; /* accepted class: NONE, YES, or NO */
  uint8_t  hist_len;
  uint8_t  cool;
  uint32_t accepts;
  uint32_t events;
} kws_estop_ctx_t;

typedef struct {
  uint8_t  argmax;
  uint8_t  gate;      /* L1 && L2 */
  uint8_t  accept;    /* L1 && L2 && L3 */
  uint8_t  event;     /* k-of-n 确认后的事件 */
  uint8_t  event_class; /* YES or NO when event is set */
  int16_t  score;
  int16_t  margin;
} kws_estop_step_t;

void kws_estop_init(kws_estop_ctx_t *ctx, int16_t theta, int16_t margin_th,
                    uint8_t k, uint8_t n, uint8_t cooldown);
void kws_estop_init_default(kws_estop_ctx_t *ctx);
kws_estop_step_t kws_estop_step(kws_estop_ctx_t *ctx, const int8_t q[4]);

#endif /* KWS_ESTOP_H */
