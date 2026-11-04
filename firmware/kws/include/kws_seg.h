/* KWS SEG -- segment-level decision layer: one decision per energy segment.
 *
 * Status: REFERENCE IMPLEMENTATION, integer only (no float, no libm, no division, no log).
 *
 * Why this file exists
 * --------------------
 * `kws_gate.c` decides once per 200 ms WINDOW: theta, then the 9-term rejector, then N-of-M +
 * hysteresis. K3-2 measured what that costs on real background music: the rejector's
 * single-window verdict throws away events the model did detect (800-clip keyword beds:
 * 110/200 gate-only -> 67/200 with the rejector on the music +5 dB bed).
 *
 * The R-A probe (tools/kws/k3_segpool_probe.py) tested pooling the rejector score over the
 * whole segment instead of one window, on the same archived score tracks:
 *
 *     baseline (per window, N/M=3)  0.92 /h -> 41.0 % of 800 clips
 *     seg max                       3.36 /h -> 56.1 %     (falsified: one stray peak dominates)
 *     seg top2                      1.53 /h -> 42.1 %
 *     seg MEAN (gate-passing only)  0.82 /h -> 62.6 %     <-- this file
 *     seg MEAN + max_w=3            0.92 /h -> 70.2 %, decision latency p90 0.4 s
 *
 * The mean works because a keyword over music is confident for the whole segment while a music
 * false alarm is one or two isolated peaks -- the mean punishes the latter and keeps the former.
 *
 * Decision rule (division-free, so C and Python cannot disagree on rounding):
 *
 *     sum / n >= tau_mean     <=>     sum >= tau_mean * n
 *
 * `sum` accumulates the rejector score of the windows whose q_yes clears theta; a window that
 * fails theta contributes nothing. A segment with n == 0 is dropped without a decision.
 *
 * Energy: two entry points, same state machine.
 *   kws_seg_feed     takes dBFS*100 (what the offline tracks store; needs 10*log10 on device)
 *   kws_seg_feed_ss  takes the raw int64 SUM OF SQUARES over the window (no log, no division)
 * They are equivalent by monotonicity: dBFS = 10*log10(ss/N/32768^2), so `ss >= hi_ss` with
 * hi_ss = N*32768^2*10^(hi/10) is exactly `db >= hi`. firmware/kws/tests/test_kws_seg.c has a
 * case that walks both paths over the same synthetic energy sequence and demands identical
 * segment boundaries.
 */
#ifndef KWS_SEG_H
#define KWS_SEG_H

#include <stdint.h>

#include "kws_gate.h"

/* One decision window = 49 frames = 16000 int16 samples; keep in sync with
 * k2_oov_stream_eval.SAMPLES (changing it changes every FA/h ever published). */
#define KWS_SEG_WINDOW_SAMPLES 16000

typedef struct {
  int32_t hi_db_x100;   /* enter a segment when rms_db_x100 >= this (dB path) */
  int32_t lo_db_x100;   /* count a silence window when rms_db_x100 < this (dB path) */
  int32_t k_sil;        /* consecutive silence windows that close the segment */
  int32_t tau_mean;     /* accept when sum >= tau_mean * n */
  int32_t max_windows;  /* 0 = wait for the energy close; >0 = decide at most this many
                         * windows after the segment opened (bounds the alarm delay) */
  int32_t theta;        /* gate on q_yes; copied so the layer can stand alone */

  /* Linear-energy thresholds for kws_seg_feed_ss, pre-multiplied by KWS_SEG_WINDOW_SAMPLES
   * so the comparison is `ss >= hi_ss` with no division either. */
  int64_t hi_ss;
  int64_t lo_ss;

  /* Rejector coefficients used to score gate-passing windows. NULL = the frozen set compiled
   * into kws_gate_coeffs.h, which is what firmware always uses. The override exists ONLY for
   * the replay driver: k3_seg_crosscheck.py has to replay a CANDIDATE pick (refit at a different
   * FA target) against Python, and without this hook the two sides silently score with different
   * coefficients -- the cross-check then "fails" on a coefficient mismatch and looks like a state
   * machine bug. Ship NULL. */
  const kws_gate_cfg_t *gate;
} kws_seg_cfg_t;

typedef struct {
  int32_t in_seg;
  int32_t sil;          /* consecutive low-energy windows inside the segment */
  int32_t n;            /* gate-passing windows in the segment */
  int32_t sum;          /* their rejector scores, summed */
  int32_t i0;           /* first window index of the segment */
  int32_t i;            /* window counter (monotone) */
} kws_seg_state_t;

/* Bookkeeping for the most recently closed segment; for cross-checking, not for logic. */
typedef struct {
  int32_t i0, i1;       /* inclusive window indices */
  int32_t n, sum;
  int32_t accept;       /* 1 = segment accepted */
} kws_seg_last_t;

void kws_seg_reset(kws_seg_state_t *st);

/* Default segmenter: HIGH -60 dB, LOW -66 dB, k_sil 1 window (= 200 ms at hop 0.2 s).
 * These are the values the offline probe used; changing them changes the FA/h baseline. */
void kws_seg_default_cfg(kws_seg_cfg_t *cfg, int32_t tau_mean);

/* Feed one window given dBFS*100. Returns 1 when this window CLOSES an accepted segment,
 * 0 otherwise, -1 on bad args. `last` (may be NULL) receives the closed segment either way. */
int kws_seg_feed(const kws_seg_cfg_t *cfg, kws_seg_state_t *st,
                 int32_t rms_db_x100, const int8_t q[KWS_GATE_CLASSES],
                 kws_seg_last_t *last);

/* Same state machine, energy given as the raw SUM OF SQUARES of the window's 16000 samples
 * (int64: <= 16000 * 32768^2 = 1.7e13). No log, no division -- this is the form firmware
 * should use; the dB entry point exists so the offline tracks can drive the same code. */
int kws_seg_feed_ss(const kws_seg_cfg_t *cfg, kws_seg_state_t *st,
                    int64_t ss, const int8_t q[KWS_GATE_CLASSES], kws_seg_last_t *last);

/* Close any open segment at end of stream. Returns 1/0 like kws_seg_feed. */
int kws_seg_flush(const kws_seg_cfg_t *cfg, kws_seg_state_t *st, kws_seg_last_t *last);

#endif /* KWS_SEG_H */
