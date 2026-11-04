#include <stdio.h>
#include <string.h>

#include "kws_estop.h"

static int failures;

#define CHECK(cond, label) do { \
  if (!(cond)) { \
    (void)fprintf(stderr, "FAIL: %s\n", label); \
    failures++; \
  } \
} while (0)

static const int8_t yes_logits[4] = {-50, -4, 121, -4};
static const int8_t no_logits[4] = {-50, -4, -4, 121};
static const int8_t unknown_logits[4] = {-50, 80, -4, -4};
static const int8_t silence_logits[4] = {80, -50, -4, -4};

static kws_estop_step_t step(kws_estop_ctx_t *ctx, const int8_t q[4])
{
  return kws_estop_step(ctx, q);
}

static void test_mixed_classes_do_not_confirm(void)
{
  kws_estop_ctx_t ctx;
  kws_estop_step_t st;

  kws_estop_init_default(&ctx);
  st = step(&ctx, yes_logits);
  CHECK(st.accept && !st.event, "first Yes is accepted without event");
  st = step(&ctx, no_logits);
  CHECK(st.accept && !st.event, "Yes then No does not confirm");
  st = step(&ctx, unknown_logits);
  CHECK(!st.accept && !st.event, "Yes, No, Unknown does not confirm");
  CHECK(ctx.events == 0u, "mixed Yes/No/Unknown event count stays zero");

  st = step(&ctx, yes_logits);
  CHECK(st.accept && !st.event, "No, Unknown, Yes still has only one Yes");
  st = step(&ctx, yes_logits);
  CHECK(st.event && st.event_class == KWS_ESTOP_CLASS_YES,
        "two Yes decisions in the sliding three confirm Yes");
}

static void test_no_requires_two_no_decisions(void)
{
  kws_estop_ctx_t ctx;
  kws_estop_step_t st;

  kws_estop_init_default(&ctx);
  (void)step(&ctx, no_logits);
  (void)step(&ctx, yes_logits);
  st = step(&ctx, no_logits);
  CHECK(st.event && st.event_class == KWS_ESTOP_CLASS_NO,
        "No, Yes, No confirms No within a same-class 2-of-3");
  st = step(&ctx, silence_logits);
  CHECK(!st.accept && !st.event, "silence does not create a decision event");
  st = step(&ctx, no_logits);
  CHECK(st.accept && !st.event, "one No after silence is insufficient");
  st = step(&ctx, no_logits);
  CHECK(st.event && st.event_class == KWS_ESTOP_CLASS_NO,
        "two No decisions in the sliding three confirm No");
}

static void test_threshold_and_margin_are_unchanged(void)
{
  kws_estop_ctx_t ctx;
  int8_t at_boundary[4] = {-32, -32, 16, -32};
  int8_t below_theta[4] = {-33, -33, 15, -33};
  int8_t below_margin[4] = {0, -32, 16, -32};
  kws_estop_step_t st;

  kws_estop_init_default(&ctx);
  CHECK(ctx.theta == 16 && ctx.margin_th == 48,
        "default theta and margin remain T7 values");
  CHECK(ctx.margin_no_th == 48,
        "default No margin remains equal to the established threshold");
  st = step(&ctx, at_boundary);
  CHECK(st.gate && st.accept, "theta=16 and margin=48 remain inclusive");
  st = step(&ctx, below_theta);
  CHECK(!st.gate && !st.accept, "score below theta is rejected");
  st = step(&ctx, below_margin);
  CHECK(st.gate && !st.accept, "margin below 48 is rejected");
}

int main(void)
{
  test_mixed_classes_do_not_confirm();
  test_no_requires_two_no_decisions();
  test_threshold_and_margin_are_unchanged();

  if (failures != 0) {
    (void)fprintf(stderr, "%d KWS estop checks failed\n", failures);
    return 1;
  }
  (void)puts("PASS: KWS same-class 2-of-3, silence/unknown hold, T7 thresholds");
  return 0;
}
