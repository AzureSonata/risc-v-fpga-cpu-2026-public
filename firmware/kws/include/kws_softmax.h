/* KWS SOFTMAX -- integer-only (no float), fixed-point, bounded work.
 *
 * ABI status: PROPOSED. Nothing here is approved by the producer or the owner.
 *   - class count, output scale (1/256) and zero point (-128) follow the TFLM
 *     int8 convention used by the model's tensor6; the input scale
 *     (KWS_SOFTMAX_SCALE_ONE == 1.0) is a PLACEHOLDER until the model's real
 *     quant parameter is frozen (see docs/architecture/KWS_SOC_TOP_INTERFACE_DRAFT.md
 *     and verification/kws/kws_decision_register.json).
 *
 * Why fixed point: the target core is RV32I (id_stage SUPPORT_M=0, no FPU, no
 * libm), so exp() must be integer. The approximation is
 *     2^(-f) with f in Q10, evaluated by 10 conditional multiplies
 *     (successive-squaring constants), error < 0.1 % => <= 1 LSB of the int8
 *     output. Work is O(n * 10) multiply/shift, independent of the logit range.
 *
 * Contract:
 *   p_i        = exp(s * (x_i - max(x))) / sum_j exp(s * (x_j - max(x)))
 *   out_i      = round(p_i * 256) - 128, clamped to [-128, 127]
 *   sum_i(out_i + 128) is within +-2 of 256 (rounding, not force-fixed).
 *   s          = step_q16 / 65536  (input scale, real units per logit LSB)
 *
 * Ties: argmax returns the lowest index. This is a documented choice, not an
 * accident -- the label decision must be deterministic for a given logit vector.
 */
#ifndef KWS_SOFTMAX_H
#define KWS_SOFTMAX_H

#include <stdint.h>

#define KWS_SOFTMAX_CLASSES      4      /* tensor6 = 4 logits */
#define KWS_SOFTMAX_MAX_CLASSES  16     /* implementation bound, not an ABI claim */
#define KWS_SOFTMAX_SCALE_ONE    65536u /* Q16 1.0: PLACEHOLDER input scale */

/* Integer softmax over `n` int8 logits.
 * logits/out must be non-null, 1 <= n <= KWS_SOFTMAX_MAX_CLASSES.
 * step_q16 is the input scale in Q16 (65536 == 1.0); 0 is legal and means
 * "all classes equal" (every exp() term is 1).
 * Returns 0 on success, -1 on bad arguments. Never divides by zero. */
int kws_softmax_int8(const int8_t *logits, int n, uint32_t step_q16, int8_t out[]);

/* Argmax with lowest-index tie-break. Returns -1 on bad arguments. */
int kws_argmax_int8(const int8_t *v, int n);

#endif /* KWS_SOFTMAX_H */
