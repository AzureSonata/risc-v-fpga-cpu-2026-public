#include <stdio.h>

#include "kws_fan_control.h"
#include "kws_live_decision.h"
#include "kws_softmax.h"

#define TEST_FC_SCALE_Q16 10200u
#define TEST_ZH_NEG_FC_SCALE_Q16 8284u

static int failures;

#define CHECK(cond, label) do { \
  if (!(cond)) { \
    (void)fprintf(stderr, "FAIL: %s\n", label); \
    failures++; \
  } \
} while (0)

/* Captured FC-domain outputs from the exact augmented ROM probes. */
static const int8_t model_no_probe[4] = {-17, 2, -8, 42};
static const int8_t strong_yes[4] = {-36, 22, 72, -38};
static const int8_t strong_no[4] = {-50, -4, -4, 121};
static const int8_t silence[4] = {80, -50, -4, -4};
#if KWS_LIVE_NO_MARGIN_OVERRIDE < KWS_ESTOP_MARGIN
static const int8_t trace_no_10[4] = {-15, 23, -40, 33};
static const int8_t trace_no_4[4] = {-15, 24, -50, 28};
static const int8_t trace_no_6[4] = {-1, 17, -33, 23};
static const int8_t trace_no_8[4] = {-2, 21, -29, 29};
static const int8_t boundary_no_7[4] = {-3, -1, 9, 16};
static const int8_t trace_no_40[4] = {-9, 6, -1, 46};
static const int8_t trace_yes_50[4] = {-36, 22, 72, -38};
static const int8_t trace_yes_62[4] = {-31, 7, 69, -24};
static const int8_t trace_yes_25[4] = {-25, 33, 58, -42};
static const int8_t trace_silence_margin6[4] = {15, 4, 0, 21};
#endif

static void test_fc_to_softmax_probe_vectors(void)
{
  /* Independent double-precision Softmax at the packed model FC scale, quantized
   * to the model's 1/256 output scale and -128 zero point. */
  const int8_t yes_expected[4] = {-128, -128, 127, -128};
  const int8_t no_expected[4] = {-128, -127, -128, 127};
  int8_t yes_q[4], no_q[4];
  int i;

  CHECK(kws_softmax_int8(strong_yes, 4, TEST_FC_SCALE_Q16, yes_q) == 0,
        "FC Yes probe converts to final tensor codes");
  CHECK(kws_softmax_int8(model_no_probe, 4, TEST_FC_SCALE_Q16, no_q) == 0,
        "FC No probe converts to final tensor codes");
  for (i = 0; i < 4; ++i) {
    CHECK(yes_q[i] >= yes_expected[i] - 1 && yes_q[i] <= yes_expected[i] + 1,
          "FC Yes probe within one output code of Softmax reference");
    CHECK(no_q[i] >= no_expected[i] - 1 && no_q[i] <= no_expected[i] + 1,
          "FC No probe within one output code of Softmax reference");
  }
  CHECK(kws_argmax_int8(yes_q, 4) == 2 && kws_argmax_int8(no_q, 4) == 3,
        "Softmax preserves Yes and No argmax");
}

static void test_zh_neg_fc_to_softmax_matches_litert(void)
{
  /* Four K2 feature fixtures from m4ops.tflite
   * (SHA-256 3540b8b9fcfa1513abb9d2aae9f6e6ee68fe48adfb6cc2bd8ae9d0d3029eb43f).
   * LiteRT tensor 10 scale is 0.12640222907066345 and tensor 11 is 1/256, zp=-128.
   * These vectors check numeric conversion only; notably the silence fixture's
   * correct model argmax is Yes and is a known acceptance failure, not a pass.
   */
  static const int8_t logits[4][4] = {
    {-57, 12, 114, -20},  /* yes */
    {-37, 15, 1, 54},     /* no */
    {-2, -2, 17, 14},     /* silence: model argmax is yes */
    {28, -18, -7, 21}     /* noise: model argmax is silence */
  };
  static const int8_t expected[4][4] = {
    {-128, -128, 127, -128},
    {-128, -126, -128, 126},
    {-116, -116, 9, -34},
    {51, -127, -126, -54}
  };
  static const int expected_argmax[4] = {2, 3, 2, 0};
  int8_t actual[4];
  int fixture, lane;

  for (fixture = 0; fixture < 4; ++fixture) {
    CHECK(kws_softmax_int8(logits[fixture], 4,
                           TEST_ZH_NEG_FC_SCALE_Q16, actual) == 0,
          "hard-negative FC vector converts to final tensor codes");
    for (lane = 0; lane < 4; ++lane) {
      CHECK(actual[lane] >= expected[fixture][lane] - 1 &&
            actual[lane] <= expected[fixture][lane] + 1,
            "hard-negative fixed-point softmax matches LiteRT within one code");
    }
    CHECK(kws_argmax_int8(actual, 4) == expected_argmax[fixture],
          "hard-negative quantized softmax preserves the LiteRT class result");
  }
}

static void test_argmax_no_never_opens_yes_segment(void)
{
  kws_live_decision_t ctx;
  kws_estop_step_t st;
  int i;

  kws_live_decision_init(&ctx);
  for (i = 0; i < 6; ++i) {
    st = kws_live_decision_step(&ctx, model_no_probe, 20000000);
    CHECK(!(st.event && st.event_class == KWS_ESTOP_CLASS_YES),
        "FC-domain argmax=No probe is not accepted as a Yes segment event");
  }
  st = kws_live_decision_step(&ctx, silence, 0);
  CHECK(!(st.event && st.event_class == KWS_ESTOP_CLASS_YES),
        "closing the No-class energy segment does not emit Yes");
}

static void test_segment_yes_and_watchdog_priority(void)
{
  kws_live_decision_t ctx;
  kws_fan_control_t fan;
  kws_estop_step_t st;
  int i;

  kws_live_decision_init(&ctx);
  kws_fan_control_init(&fan);
  for (i = 0; i < 5; ++i)
    (void)kws_live_decision_step(&ctx, strong_yes, 20000000);
  st = kws_live_decision_step(&ctx, silence, 0);
  CHECK(st.event && st.event_class == KWS_ESTOP_CLASS_YES,
        "a loud Yes segment closes as one Yes event");
  kws_fan_control_step(&fan, 1u, 0u, &st);
  CHECK(kws_fan_control_gpio_word(&fan) == KWS_FAN_MARK_TRIP,
        "watchdog trip overrides a simultaneous accepted Yes event");
}

static void test_existing_no_fan_off_path(void)
{
  kws_live_decision_t ctx;
  kws_fan_control_t fan;
  kws_estop_step_t yes = {0};
  kws_estop_step_t st;
  int i;

  kws_live_decision_init(&ctx);
  kws_fan_control_init(&fan);
  yes.event = 1u;
  yes.event_class = KWS_ESTOP_CLASS_YES;
  kws_fan_control_step(&fan, 0u, 0u, &yes);
  CHECK((kws_fan_control_gpio_word(&fan) & KWS_FAN_GPIO_ENABLE) != 0u,
        "fan is on before a confirmed No");

  st = kws_live_decision_step(&ctx, strong_yes, 20000000);
  kws_fan_control_step(&fan, 0u, 0u, &st);

  for (i = 0; i < 3; ++i) {
    st = kws_live_decision_step(&ctx, strong_no, 20000000);
    kws_fan_control_step(&fan, 0u, 0u, &st);
  }
  CHECK((kws_fan_control_gpio_word(&fan) & KWS_FAN_GPIO_ENABLE) == 0u,
        "existing same-class No confirmation still turns the fan off");
  CHECK(fan.debug_event == KWS_FAN_MARK_NO,
        "No fan-off keeps the existing event marker");
  st = kws_live_decision_step(&ctx, silence, 0);
  kws_fan_control_step(&fan, 0u, 0u, &st);
  CHECK((kws_fan_control_gpio_word(&fan) & KWS_FAN_GPIO_ENABLE) == 0u,
        "a delayed energy close cannot reopen the fan after confirmed No");
}

static void test_candidate_no_margin_2_of_3(void)
{
#if KWS_LIVE_NO_MARGIN_OVERRIDE < KWS_ESTOP_MARGIN
  kws_live_decision_t ctx;
  kws_estop_step_t st;

  kws_live_decision_init(&ctx);
  CHECK(ctx.estop.margin_th == KWS_ESTOP_MARGIN,
        "candidate No override leaves Yes margin unchanged");
  CHECK(ctx.estop.margin_no_th == KWS_LIVE_NO_MARGIN_OVERRIDE,
        "candidate No margin override is installed");

  st = kws_live_decision_step(&ctx, trace_no_10, 20000000);
  CHECK(!st.event && ctx.estop.hist_len == 1u &&
        ctx.estop.hist[0] == KWS_ESTOP_CLASS_NO,
        "first trace No is accepted but not confirmed");
  st = kws_live_decision_step(&ctx, trace_no_4, 20000000);
  CHECK(!st.event && ctx.estop.hist_len == 2u &&
        ctx.estop.hist[1] == KWS_ESTOP_CLASS_NONE,
        "below-threshold No does not count");
  st = kws_live_decision_step(&ctx, trace_no_6, 20000000);
  CHECK(!st.event && ctx.estop.hist[2] == KWS_ESTOP_CLASS_NONE,
        "2-of-3 still requires two accepted No windows");
  st = kws_live_decision_step(&ctx, trace_no_8, 20000000);
  CHECK(!st.event && ctx.estop.hist[2] == KWS_ESTOP_CLASS_NO,
        "inclusive No margin threshold is applied");
  st = kws_live_decision_step(&ctx, boundary_no_7, 20000000);
  CHECK(!st.event && ctx.estop.hist[1] == KWS_ESTOP_CLASS_NO &&
        ctx.estop.hist[2] == KWS_ESTOP_CLASS_NONE,
        "No margin 7 fails the inclusive threshold of 8");
  st = kws_live_decision_step(&ctx, trace_no_40, 20000000);
  CHECK(st.accept && st.event && st.event_class == KWS_ESTOP_CLASS_NO,
        "trace-tail sequence produces a confirmed No on its final input");
#endif
}

static void test_candidate_no_margin_false_off_controls(void)
{
#if KWS_LIVE_NO_MARGIN_OVERRIDE < KWS_ESTOP_MARGIN
  const int8_t *yes_windows[3] = {
    trace_yes_50, trace_yes_62, trace_yes_25
  };
  kws_live_decision_t ctx;
  kws_estop_step_t st;
  int i;

  kws_live_decision_init(&ctx);
  CHECK(ctx.estop.margin_th == KWS_ESTOP_MARGIN &&
        ctx.estop.margin_no_th == KWS_LIVE_NO_MARGIN_OVERRIDE,
        "No margin candidate leaves the Yes margin at 48");
  for (i = 0; i < 3; ++i) {
    st = kws_estop_step(&ctx.estop, yes_windows[i]);
    CHECK(st.argmax == KWS_ESTOP_CLASS_YES && st.margin ==
          (i == 0 ? 50 : (i == 1 ? 62 : 25)) &&
          (st.accept == (uint8_t)(i < 2)) &&
          !(st.event && st.event_class == KWS_ESTOP_CLASS_NO),
          "recorded Yes windows keep the original margin 48 decision");
  }

  kws_estop_init_default(&ctx.estop);
  ctx.estop.margin_no_th = KWS_LIVE_NO_MARGIN_OVERRIDE;
  for (i = 0; i < 3; ++i) {
    st = kws_estop_step(&ctx.estop, trace_silence_margin6);
    CHECK(st.argmax == KWS_ESTOP_CLASS_NO && st.score == KWS_ESTOP_THETA + 5 &&
          st.margin == 6 && !st.accept &&
          !(st.event && st.event_class == KWS_ESTOP_CLASS_NO),
          "low-margin silence MMIO vector is rejected by No margin 8");
  }
  CHECK(ctx.estop.hist_len == 3u &&
        ctx.estop.hist[0] == KWS_ESTOP_CLASS_NONE &&
        ctx.estop.hist[1] == KWS_ESTOP_CLASS_NONE &&
        ctx.estop.hist[2] == KWS_ESTOP_CLASS_NONE,
        "repeated low-margin silence vector never enters No confirmation history");
#endif
}

int main(void)
{
  test_fc_to_softmax_probe_vectors();
  test_zh_neg_fc_to_softmax_matches_litert();
  test_argmax_no_never_opens_yes_segment();
  test_segment_yes_and_watchdog_priority();
  test_existing_no_fan_off_path();
  test_candidate_no_margin_2_of_3();
  test_candidate_no_margin_false_off_controls();
  if (failures != 0) {
    (void)fprintf(stderr, "%d KWS live decision checks failed\n", failures);
    return 1;
  }
  (void)puts("PASS: live Yes segmentation, No fan-off, watchdog priority");
  return 0;
}
