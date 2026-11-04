/* KWS 急停判决层实现。与 tools/estop/decide_ref.py 的 DecisionLayer 对齐。 */
#include "kws_estop.h"

static int16_t max_except(const int8_t q[4], uint8_t skip)
{
  int16_t m = -32768;
  uint8_t i;
  for (i = 0; i < 4u; i++) {
    if (i == skip) continue;
    if ((int16_t)q[i] > m) m = (int16_t)q[i];
  }
  return m;
}

void kws_estop_init(kws_estop_ctx_t *ctx, int16_t theta, int16_t margin_th,
                    uint8_t k, uint8_t n, uint8_t cooldown)
{
  uint8_t i;
  if (ctx == 0) return;
  if (n == 0u || n > KWS_ESTOP_MAX_N) n = KWS_ESTOP_CONFIRM_N;
  if (k > n) k = n;
  ctx->theta = theta;
  ctx->margin_th = margin_th;
  ctx->margin_no_th = margin_th;
  ctx->k = k;
  ctx->n = n;
  ctx->cooldown = cooldown;
  ctx->hist_len = 0u;
  ctx->cool = 0u;
  ctx->accepts = 0u;
  ctx->events = 0u;
  for (i = 0; i < KWS_ESTOP_MAX_N; i++) ctx->hist[i] = 0u;
}

void kws_estop_init_default(kws_estop_ctx_t *ctx)
{
  kws_estop_init(ctx, KWS_ESTOP_THETA, KWS_ESTOP_MARGIN,
                 KWS_ESTOP_CONFIRM_K, KWS_ESTOP_CONFIRM_N, KWS_ESTOP_COOLDOWN);
}

kws_estop_step_t kws_estop_step(kws_estop_ctx_t *ctx, const int8_t q[4])
{
  kws_estop_step_t st;
  int16_t score, mg, margin_th;
  uint8_t am = 0u, i, accept, decision_class, fired = 0u;
  uint8_t yes_count, no_count;

  st.argmax = 0u;
  st.gate = 0u;
  st.accept = 0u;
  st.event = 0u;
  st.event_class = KWS_ESTOP_CLASS_NONE;
  st.score = 0;
  st.margin = 0;
  if (ctx == 0 || q == 0) return st;

  /* tie-break 与 Python max(range(4)) 一致：取第一个最大值 */
  for (i = 1u; i < 4u; i++) {
    if ((int16_t)q[i] > (int16_t)q[am]) am = i;
  }
  score = ((int16_t)q[2] > (int16_t)q[3]) ? (int16_t)q[2] : (int16_t)q[3];
  mg = (int16_t)q[am] - max_except(q, am);

  st.argmax = am;
  st.score = score;
  st.margin = mg;
  st.gate = (uint8_t)(((am == 2u) || (am == 3u)) && (score >= ctx->theta));
  margin_th = (am == KWS_ESTOP_CLASS_NO) ? ctx->margin_no_th : ctx->margin_th;
  accept = (uint8_t)(st.gate && (mg >= margin_th));
  st.accept = accept;
  decision_class = accept ? am : KWS_ESTOP_CLASS_NONE;

  ctx->accepts += (accept != 0u) ? 1u : 0u;

  if (ctx->hist_len < ctx->n) {
    ctx->hist[ctx->hist_len++] = decision_class;
  } else {
    for (i = 1u; i < ctx->n; i++) ctx->hist[i - 1u] = ctx->hist[i];
    ctx->hist[ctx->n - 1u] = decision_class;
  }

  if (ctx->hist_len == ctx->n) {
    yes_count = 0u;
    no_count = 0u;
    for (i = 0; i < ctx->n; i++) {
      if (ctx->hist[i] == KWS_ESTOP_CLASS_YES) yes_count++;
      if (ctx->hist[i] == KWS_ESTOP_CLASS_NO) no_count++;
    }
    if ((yes_count >= ctx->k) || (no_count >= ctx->k)) {
      if (ctx->cool == 0u) {
        ctx->events += 1u;
        ctx->cool = ctx->cooldown;
        ctx->hist_len = 0u;
        fired = 1u;
        st.event_class = (yes_count >= ctx->k)
                           ? KWS_ESTOP_CLASS_YES : KWS_ESTOP_CLASS_NO;
      }
    }
  }
  if (ctx->cool > 0u) ctx->cool -= 1u;

  st.event = fired;
  return st;
}
