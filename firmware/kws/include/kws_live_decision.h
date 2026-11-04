#ifndef KWS_LIVE_DECISION_H
#define KWS_LIVE_DECISION_H

#include <stdint.h>

#include "kws_estop.h"
#include "kws_seg.h"

/* The published coefficients do not include a verifiable model hash and the
 * release handoff marks their new-model calibration OPEN_P0. Keep them inactive
 * in the normal live build until that exact binding is supplied and reviewed. */
#ifndef KWS_LIVE_GATE_PARAMS_VERIFIED
#define KWS_LIVE_GATE_PARAMS_VERIFIED 0
#endif

/* Experimental, W3-live-only NO margin override. The default preserves the
 * established ESTOP threshold; candidate builds may set this independently of
 * the YES margin and gate (e.g. KWS_LIVE_NO_MARGIN_OVERRIDE=8 for trace study). */
#ifndef KWS_LIVE_NO_MARGIN_OVERRIDE
#define KWS_LIVE_NO_MARGIN_OVERRIDE KWS_ESTOP_MARGIN
#endif

typedef struct {
  kws_estop_ctx_t estop;
  kws_seg_cfg_t seg_cfg;
  kws_seg_state_t seg_state;
} kws_live_decision_t;

void kws_live_decision_init(kws_live_decision_t *ctx);
void kws_live_decision_reset(kws_live_decision_t *ctx);

/* One model result per rolling W3 window. `window_ss` is the sum of squares for
 * the matching 16000-sample PCM window. No events continue through the existing
 * same-class ESTOP path; Yes events require both the model's Yes argmax and an
 * accepted energy segment. */
kws_estop_step_t kws_live_decision_step(kws_live_decision_t *ctx,
                                         const int8_t q[KWS_GATE_CLASSES],
                                         int64_t window_ss);

#endif
