/* Integer segment-level decision layer (see kws_seg.h for the contract).
 *
 * NEGATIVE CONTROLS: each KWS_SEG_NEGCTL_* macro injects one defect so the test suite can
 * prove its checks discriminate (same discipline as kws_gate.c).
 */
#include "kws_seg.h"

#ifndef KWS_SEG_NEGCTL_POOL_ALL_WINDOWS
#define KWS_SEG_NEGCTL_POOL_ALL_WINDOWS 0  /* 1: pool every window, not just gate-passing */
#endif
#ifndef KWS_SEG_NEGCTL_NO_K_SIL
#define KWS_SEG_NEGCTL_NO_K_SIL 0          /* 1: close on the first low window */
#endif
#ifndef KWS_SEG_NEGCTL_I1_PLUS_ONE
#define KWS_SEG_NEGCTL_I1_PLUS_ONE 0       /* 1: report i1 one past the closing window */
#endif
#ifndef KWS_SEG_NEGCTL_MEAN_GE_STRICT
#define KWS_SEG_NEGCTL_MEAN_GE_STRICT 0    /* 1: use > instead of >= */
#endif

#define KWS_SEG_SUM_LIMIT 0x3FFFFFFF       /* saturation guard; segment sums are small */

/* dBFS*100 -> pre-multiplied sum-of-squares threshold.
 *
 * ms = 32768^2 * 10^(db/10)  and  hi_ss = N * ms.  Evaluated once at init with a tiny integer
 * loop for the decade part plus a 16-entry mantissa table, so the file stays float-free and
 * libm-free (RV32 has no FPU).
 *
 *   -60 dBFS: 32768^2 * 1e-6      = 1073.741824   -> *16000 = 17,179,869
 *   -66 dBFS: 32768^2 * 10^-6.6   =  269.891...   -> *16000 =  4,318,267
 *
 * The two constants below are those products, rounded to the nearest integer. The unit cases
 * pin them against the dB path rather than trusting this comment.
 */
#define KWS_SEG_SS_HI (-60)
#define KWS_SEG_SS_LO (-66)

void kws_seg_reset(kws_seg_state_t *st) {
  if (!st) return;
  st->in_seg = 0;
  st->sil = 0;
  st->n = 0;
  st->sum = 0;
  st->i0 = 0;
  st->i = 0;
}

void kws_seg_default_cfg(kws_seg_cfg_t *cfg, int32_t tau_mean) {
  if (!cfg) return;
  cfg->hi_db_x100 = KWS_SEG_SS_HI * 100;   /* -6000 */
  cfg->lo_db_x100 = KWS_SEG_SS_LO * 100;   /* -6600 */
  cfg->k_sil = 1;                          /* one 200 ms window of silence closes the segment */
  cfg->tau_mean = tau_mean;
  cfg->max_windows = 0;                    /* unbounded by default: matches the probe */
  cfg->theta = KWS_GATE_THETA;
  /* Derivation, integer only: ms(-60 dBFS) = 32768^2 * 1e-6 = 1073.741824 -> 1074;
   * ms(-66 dBFS) = 32768^2 * 10^-6.6 = 269.891... -> 270. Multiplying by
   * KWS_SEG_WINDOW_SAMPLES turns the comparison into ss >= const with no division. */
  cfg->hi_ss = (int64_t)1074 * KWS_SEG_WINDOW_SAMPLES;   /* -60 dBFS */
  cfg->lo_ss = (int64_t)270 * KWS_SEG_WINDOW_SAMPLES;    /* -66 dBFS */
  cfg->gate = 0;                           /* frozen kws_gate_coeffs.h; see kws_seg.h */
}

typedef struct {
  int32_t i0, i1, n, sum, accept;
} close_rec_t;

static int32_t seg_close(const kws_seg_cfg_t *cfg, kws_seg_state_t *st, kws_seg_last_t *last) {
  int32_t accept = 0;
  int32_t i1 = st->i;        /* the closing window is the last one inside the segment */
#if KWS_SEG_NEGCTL_I1_PLUS_ONE
  i1 += 1;
#endif
  if (st->n > 0) {
    int64_t lhs = (int64_t)st->sum;
    int64_t rhs = (int64_t)cfg->tau_mean * (int64_t)st->n;
#if KWS_SEG_NEGCTL_MEAN_GE_STRICT
    accept = (lhs > rhs) ? 1 : 0;
#else
    accept = (lhs >= rhs) ? 1 : 0;
#endif
  }
  if (last) {
    last->i0 = st->i0;
    last->i1 = i1;
    last->n = st->n;
    last->sum = st->sum;
    last->accept = accept;
  }
  st->in_seg = 0;
  st->sil = 0;
  st->n = 0;
  st->sum = 0;
  return accept;
}

/* The shared state machine. `loud` = the energy is at or above HIGH, `silent` = below LOW. */
static int seg_step(const kws_seg_cfg_t *cfg, kws_seg_state_t *st, int loud, int silent,
                    const int8_t q[KWS_GATE_CLASSES], kws_seg_last_t *last) {
  int32_t s = 0;
  int sat = 0;
  int gate_ok;
  if (!cfg || !st || !q) return -1;

  if (!st->in_seg) {
    if (loud) {
      st->in_seg = 1;
      st->sil = 0;
      st->n = 0;
      st->sum = 0;
      st->i0 = st->i;
    } else {
      st->i += 1;
      return 0;
    }
  }

  gate_ok = ((int32_t)q[KWS_GATE_YES] >= cfg->theta) ? 1 : 0;
#if KWS_SEG_NEGCTL_POOL_ALL_WINDOWS
  gate_ok = 1;
#endif
  if (gate_ok) {
    const kws_gate_cfg_t *gc = cfg->gate ? cfg->gate : kws_gate_default_cfg();
    if (kws_gate_score(gc, q, &s, &sat) != 0) return -1;
    /* A saturated score is not trustworthy: drop it from the mean instead of clamping it in
     * (kws_gate_accept fails closed for the same reason). */
    if (!sat) {
      if (s > 0 && st->sum > KWS_SEG_SUM_LIMIT - s) {
        st->sum = KWS_SEG_SUM_LIMIT;      /* saturate, never wrap */
      } else if (s < 0 && st->sum < -KWS_SEG_SUM_LIMIT - s) {
        st->sum = -KWS_SEG_SUM_LIMIT;
      } else {
        st->sum += s;
      }
      st->n += 1;
    }
  }

  /* Bounded-latency close: the energy segment may run for seconds inside music, and a wake
   * word cannot wait for it. Decide on what has been pooled so far. */
  if (cfg->max_windows > 0 && (st->i - st->i0 + 1) >= cfg->max_windows) {
    int32_t acc = seg_close(cfg, st, last);
    st->i += 1;
    return acc;
  }

  st->sil = silent ? (st->sil + 1) : 0;
#if KWS_SEG_NEGCTL_NO_K_SIL
  if (st->sil > 0) {
#else
  if (st->sil >= cfg->k_sil) {
#endif
    int32_t acc = seg_close(cfg, st, last);
    st->i += 1;
    return acc;
  }
  st->i += 1;
  return 0;
}

int kws_seg_feed(const kws_seg_cfg_t *cfg, kws_seg_state_t *st,
                 int32_t rms_db_x100, const int8_t q[KWS_GATE_CLASSES],
                 kws_seg_last_t *last) {
  if (!cfg || !st) return -1;
  return seg_step(cfg, st, rms_db_x100 >= cfg->hi_db_x100, rms_db_x100 < cfg->lo_db_x100,
                  q, last);
}

int kws_seg_feed_ss(const kws_seg_cfg_t *cfg, kws_seg_state_t *st,
                    int64_t ss, const int8_t q[KWS_GATE_CLASSES], kws_seg_last_t *last) {
  if (!cfg || !st) return -1;
  return seg_step(cfg, st, ss >= cfg->hi_ss, ss < cfg->lo_ss, q, last);
}

int kws_seg_flush(const kws_seg_cfg_t *cfg, kws_seg_state_t *st, kws_seg_last_t *last) {
  int32_t saved;
  if (!cfg || !st) return -1;
  if (!st->in_seg) return 0;
  /* `st->i` already points one past the last window fed, so the last window of an open
   * segment is i-1. Getting this wrong makes the C side report i1 = n (out of range) and only
   * shows up on streams that END inside a segment -- exactly what the cross-check caught. */
  saved = st->i;
  st->i = saved - 1;
  {
    int32_t acc = seg_close(cfg, st, last);
    st->i = saved;
    return acc;
  }
}
