#include "kws_live_decision.h"

#include "kws_gate.h"

#if KWS_LIVE_GATE_PARAMS_VERIFIED
#include "kws_softmax.h"

/* Default FC scale for the K3 control model. A model-specific experimental
 * build must pass KWS_LIVE_FC_SCALE_Q16 from that model's tensor metadata; the
 * hard-negative candidate uses 8284 (0.12640222907066345 in Q16). The softmax
 * is only used by the experimental gate path; the ordinary live build leaves
 * KWS_LIVE_GATE_PARAMS_VERIFIED at 0. */
#ifndef KWS_LIVE_FC_SCALE_Q16
#define KWS_LIVE_FC_SCALE_Q16 10200u
#endif
#endif

void kws_live_decision_init(kws_live_decision_t *ctx)
{
  if (ctx == 0) return;
  kws_estop_init_default(&ctx->estop);
  ctx->estop.margin_no_th = KWS_LIVE_NO_MARGIN_OVERRIDE;
  /* v9demo: live-demo margins. The released 48/48 ESTOP threshold needs a
   * large class gap that the current zh model rarely produces, so no event is
   * ever confirmed and the fan never moves. Demo uses a small gap; theta is
   * unchanged so silence/unknown still gate out. */
  ctx->estop.margin_th = 4;
  ctx->estop.margin_no_th = 2;
  kws_seg_default_cfg(&ctx->seg_cfg, KWS_GATE_TAU);
  kws_seg_reset(&ctx->seg_state);
}

void kws_live_decision_reset(kws_live_decision_t *ctx)
{
  if (ctx == 0) return;
  kws_estop_init_default(&ctx->estop);
  ctx->estop.margin_no_th = KWS_LIVE_NO_MARGIN_OVERRIDE;
  /* v9demo: live-demo margins. The released 48/48 ESTOP threshold needs a
   * large class gap that the current zh model rarely produces, so no event is
   * ever confirmed and the fan never moves. Demo uses a small gap; theta is
   * unchanged so silence/unknown still gate out. */
  ctx->estop.margin_th = 4;
  ctx->estop.margin_no_th = 2;
  kws_seg_reset(&ctx->seg_state);
}

kws_estop_step_t kws_live_decision_step(kws_live_decision_t *ctx,
                                         const int8_t q[KWS_GATE_CLASSES],
                                         int64_t window_ss)
{
  kws_estop_step_t out = {0};
  kws_estop_step_t legacy;
#if KWS_LIVE_GATE_PARAMS_VERIFIED
  int8_t softmax_q[KWS_GATE_CLASSES];
  int8_t yes_q[KWS_GATE_CLASSES];
  uint8_t i;
  int close_rc;
#endif

  if (ctx == 0 || q == 0) return out;

  /* Keep the existing class-aware No fan-off path. The legacy Yes event is
   * intentionally suppressed: Yes now must pass the segment layer below. */
  legacy = kws_estop_step(&ctx->estop, q);
  if (legacy.event != 0u && legacy.event_class == KWS_ESTOP_CLASS_NO) {
    out = legacy;
    /* A confirmed No turns the fan off immediately. Discard any still-open Yes
     * segment so its later energy-close cannot undo that No decision. */
    kws_seg_reset(&ctx->seg_state);
    return out;
  }

#if !KWS_LIVE_GATE_PARAMS_VERIFIED
  /* Preserve the current decision path while the packaged gate thresholds are
   * still unbound to the exact model ROM. Candidate tests opt in explicitly. */
  return legacy;
#else

  /* The packaged rejector was selected from TFLite's final Softmax tensor,
   * while MMIO exposes the FC tensor. Convert only the experimental Yes gate
   * input here; the existing No confirmation above continues to consume the
   * original FC values and retains its established behavior. */
  if (kws_softmax_int8(q, KWS_GATE_CLASSES, KWS_LIVE_FC_SCALE_Q16,
                       softmax_q) != 0)
    return out;

  for (i = 0u; i < KWS_GATE_CLASSES; ++i) yes_q[i] = softmax_q[i];
  if (legacy.argmax != KWS_GATE_YES)
    yes_q[KWS_GATE_YES] = (int8_t)(KWS_GATE_THETA - 1);

  close_rc = kws_seg_feed_ss(&ctx->seg_cfg, &ctx->seg_state, window_ss,
                             yes_q, 0);
  if (close_rc == 1) {
    out.argmax = KWS_GATE_YES;
    out.gate = 1u;
    out.accept = 1u;
    out.event = 1u;
    out.event_class = KWS_ESTOP_CLASS_YES;
  }
  return out;
#endif
}
