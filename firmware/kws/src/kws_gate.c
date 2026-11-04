/* Integer KWS decision layer (see kws_gate.h for the contract).
 *
 * Everything is int32. The three differences are formed in int32 (not int8: 127 - (-128)
 * = 255 wraps to -1 in int8 and would invert exactly the most confident windows), shifted
 * right by KWS_GATE_TERM_SHIFT with an arithmetic shift (floor), squared, and combined.
 *
 * NEGATIVE CONTROLS: the KWS_GATE_NEGCTL_* macros each inject one defect so the test suite
 * can prove its checks discriminate. Without them "all cases pass" would only mean the
 * test agrees with the implementation, not with the specification.
 */
#include "kws_gate.h"

#ifndef KWS_GATE_NEGCTL_NO_SHIFT
#define KWS_GATE_NEGCTL_NO_SHIFT 0     /* 1: skip the >>> KWS_GATE_TERM_SHIFT */
#endif
#ifndef KWS_GATE_NEGCTL_NO_HYSTERESIS
#define KWS_GATE_NEGCTL_NO_HYSTERESIS 0 /* 1: re-arm immediately after every alarm */
#endif
#ifndef KWS_GATE_NEGCTL_NO_REJECTOR
#define KWS_GATE_NEGCTL_NO_REJECTOR 0   /* 1: ignore the quadratic (theta only) */
#endif
#ifndef KWS_GATE_NEGCTL_NO_N_OF_M
#define KWS_GATE_NEGCTL_NO_N_OF_M 0     /* 1: fire on the first accepted window */
#endif

static int32_t sar32(int32_t v, int32_t s) {
  /* Arithmetic shift with defined behaviour for negative v (`v >> s` on a signed type is
   * implementation-defined before C++20 / C23); floor semantics, matching numpy's //. */
  if (s <= 0) return v;
  if (v >= 0) return v >> s;
  return -(((-v) + ((int32_t)1 << s) - 1) >> s);
}

void kws_gate_reset(kws_gate_state_t *st) {
  if (!st) return;
  st->run = 0;
  st->armed = 1;
}

const kws_gate_cfg_t *kws_gate_default_cfg(void) {
  static const kws_gate_cfg_t cfg = {
      {KWS_GATE_C0, KWS_GATE_C1, KWS_GATE_C2, KWS_GATE_C3, KWS_GATE_C4,
       KWS_GATE_C5, KWS_GATE_C6, KWS_GATE_C7, KWS_GATE_C8, KWS_GATE_C9},
      KWS_GATE_Q_SHIFT, KWS_GATE_TAU, KWS_GATE_THETA, KWS_GATE_RELEASE,
      KWS_GATE_N_OF_M_VALUE};
  return &cfg;
}

int kws_gate_score(const kws_gate_cfg_t *cfg, const int8_t q[KWS_GATE_CLASSES],
                   int32_t *out, int *sat) {
  int32_t d0, d1, d2, t0, t1, t2;
  int32_t term[KWS_GATE_N_TERMS];
  int64_t acc;                     /* host-only widening to DETECT overflow, see below */
  int32_t lim = (int32_t)0x7FFFFFFF;
  int i;
  if (!cfg || !q || !out) return -1;

  d0 = (int32_t)q[KWS_GATE_YES] - (int32_t)q[KWS_GATE_SILENCE];
  d1 = (int32_t)q[KWS_GATE_YES] - (int32_t)q[KWS_GATE_UNKNOWN];
  d2 = (int32_t)q[KWS_GATE_YES] - (int32_t)q[KWS_GATE_NO];

#if KWS_GATE_NEGCTL_NO_SHIFT
  t0 = d0; t1 = d1; t2 = d2;
#else
  t0 = sar32(d0, KWS_GATE_TERM_SHIFT);
  t1 = sar32(d1, KWS_GATE_TERM_SHIFT);
  t2 = sar32(d2, KWS_GATE_TERM_SHIFT);
#endif

  term[0] = t0;
  term[1] = t1;
  term[2] = t2;
  term[3] = t0 * t0;
  term[4] = t1 * t1;
  term[5] = t2 * t2;
  term[6] = t0 * t1;
  term[7] = t0 * t2;
  term[8] = t1 * t2;

  acc = (int64_t)cfg->c[0];
  for (i = 0; i < KWS_GATE_N_TERMS; ++i) {
    acc += (int64_t)cfg->c[i + 1] * (int64_t)term[i];
  }
  if (sat) *sat = 0;
  if (acc > (int64_t)lim || acc < -(int64_t)lim - 1) {
    if (sat) *sat = 1;
    acc = acc > 0 ? (int64_t)lim : -(int64_t)lim - 1;
  }
  *out = sar32((int32_t)acc, cfg->q_shift);
  return 0;
}

int kws_gate_accept(const kws_gate_cfg_t *cfg, const int8_t q[KWS_GATE_CLASSES]) {
  int32_t s = 0;
  int sat = 0;
  if (!cfg || !q) return -1;
  if ((int32_t)q[KWS_GATE_YES] < cfg->theta) return 0;
#if KWS_GATE_NEGCTL_NO_REJECTOR
  return 1;
#else
  if (kws_gate_score(cfg, q, &s, &sat) != 0) return -1;
  if (sat) return 0;               /* saturated score is not trustworthy: fail closed */
  return (s >= cfg->tau) ? 1 : 0;
#endif
}

int kws_gate_feed(const kws_gate_cfg_t *cfg, kws_gate_state_t *st,
                  const int8_t q[KWS_GATE_CLASSES]) {
  int accept;
  if (!cfg || !st || !q) return -1;
  accept = kws_gate_accept(cfg, q);
  if (accept < 0) return -1;

  if (st->armed) {
    if (accept) {
      st->run += 1;
#if KWS_GATE_NEGCTL_NO_N_OF_M
      st->run = cfg->n_of_m;
#endif
      if (st->run >= cfg->n_of_m) {
        st->armed = 0;
        st->run = 0;
        return 1;
      }
    } else {
      st->run = 0;
    }
  } else {
    /* Re-arm condition is on q_yes, NOT on the rejector's output: a window that the
     * rejector threw away but whose q_yes is still high must not re-arm, otherwise two
     * rejected windows around a low spike merge into an extra alarm (measured: 52 vs 51
     * alarms on the smoke stream when the rejected window was written as -128). */
#if KWS_GATE_NEGCTL_NO_HYSTERESIS
    st->armed = 1;
    st->run = 0;
#else
    if ((int32_t)q[KWS_GATE_YES] < cfg->release) {
      st->armed = 1;
      st->run = 0;
    }
#endif
  }
  return 0;
}
