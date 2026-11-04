/* Integer softmax implementation (see kws_softmax.h for the contract).
 *
 * No floating point, no libm, no 64-bit math: every intermediate stays in
 * uint32_t so the same code runs on the host (tests) and on RV32I firmware.
 *
 * Numerical path for one class:
 *   diff  = max - x_i                    (0..255, int8 domain)
 *   y_q10 = diff * s * 1024              (s = step_q16 / 65536)
 *   f_q10 = y_q10 * log2(e)              (log2: because 2^-f is cheap)
 *   r     = 2^(-f_q10/1024) in Q15       (0 when f >= 15, i.e. p underflow)
 *   p     = r / sum(r) in Q15
 *   out   = round(p * 256) - 128         (clamped to the int8 range)
 *
 * KWS_NEGCTL_* macros inject the classic defects so the test-suite can prove
 * its checks actually discriminate (see run_softmax_tests.py).
 */
#include "kws_softmax.h"

/* 2^(-2^-k) in Q15, k = 1..10. Verified against double precision in
 * tools/kws/softmax_reference.py (max abs error 1.2e-5). */
static const uint32_t k_pow2_coeff[10] = {
    23170u, 27554u, 30048u, 31379u, 32066u,
    32415u, 32591u, 32679u, 32724u, 32746u,
};

/* 2^(-f/1024) in Q15 for f in [0, 1024). Ten conditional multiplies. */
static uint32_t pow2_neg_q15(uint32_t f10) {
  uint32_t r = 32768u;                     /* Q15 1.0 */
  int k;
  for (k = 1; k <= 10; ++k) {
    if ((f10 >> (10 - k)) & 1u) r = (r * k_pow2_coeff[k - 1]) >> 15;
  }
  return r;
}

/* log2(e) in Q10 = round(1.442695 * 1024) = 1477. */
#define KWS_LOG2E_Q10 1477u

int kws_softmax_int8(const int8_t *logits, int n, uint32_t step_q16, int8_t out[]) {
  int8_t maxv;
  uint32_t r[KWS_SOFTMAX_MAX_CLASSES];
  uint32_t u[KWS_SOFTMAX_MAX_CLASSES];
  uint32_t sum = 0;
  int i;

  if (logits == 0 || out == 0) return -1;
  if (n <= 0 || n > KWS_SOFTMAX_MAX_CLASSES) return -1;

#ifdef KWS_NEGCTL_IGNORE_SCALE
  step_q16 = KWS_SOFTMAX_SCALE_ONE;   /* negctl: ignore the caller's input scale */
#endif

  maxv = logits[0];
  for (i = 1; i < n; ++i) {
    if (logits[i] > maxv) maxv = logits[i];
  }

  for (i = 0; i < n; ++i) {
    uint32_t diff, y_q10, f_q10, n_int, frac;
#ifdef KWS_NEGCTL_NO_MAX_SUB
    /* negctl: skip the max subtraction. Positive logits then saturate to 0
     * weight and the distribution collapses to uniform. */
    diff = (uint32_t)(logits[i] < 0 ? 0 : logits[i]);
#else
    diff = (uint32_t)((int)maxv - (int)logits[i]);
#endif
    y_q10 = (diff * step_q16) >> 6;               /* diff * s * 1024 */
    f_q10 = (y_q10 * KWS_LOG2E_Q10 + 512u) >> 10; /* e-units -> 2^-f exponent */
    n_int = f_q10 >> 10;
    frac  = f_q10 & 1023u;
    if (n_int >= 15u) {
      r[i] = 0u;                                  /* exp underflow, p -> 0 */
    } else {
      r[i] = pow2_neg_q15(frac) >> n_int;
    }
    sum += r[i];
  }

  if (sum == 0u) {
    /* All classes underflowed (or step_q16 == 0 with extreme diffs). A uniform
     * distribution is the only bounded answer; report it instead of dividing
     * by zero. */
    uint32_t base = 256u / (uint32_t)n;
    for (i = 0; i < n; ++i) u[i] = base;
  } else {
    for (i = 0; i < n; ++i) {
      uint32_t p_q15 = (r[i] << 15) / sum;        /* <= 32768, no overflow */
#ifdef KWS_NEGCTL_UNIFORM_DENOM
      /* negctl: normalise by the class count instead of the sum */
      u[i] = (r[i] * 256u) / ((uint32_t)n * 32768u);
#else
      u[i] = (p_q15 * 256u + 16384u) >> 15;       /* round(p * 256) in 0..256 */
#endif
    }
  }

  for (i = 0; i < n; ++i) {
#ifndef KWS_NEGCTL_NO_CLAMP
    if (u[i] > 255u) u[i] = 255u;                 /* 256 would wrap int8 */
#endif
    out[i] = (int8_t)((int)u[i] - 128);
  }
  return 0;
}

int kws_argmax_int8(const int8_t *v, int n) {
  int i, best = 0;
  if (v == 0 || n <= 0) return -1;
  for (i = 1; i < n; ++i) {
    if (v[i] > v[best]) best = i;                 /* strict: lowest index wins */
  }
  return best;
}
