#include <stdint.h>
#include "kws_live_decision.h"
#include "kws_fan_control.h"
#include "kws_frontend.h"
#include "kws_pcm_energy.h"

#define KWS_CTRL_BASE       0x40000000u
#define KWS_BUF_BASE        0x40001000u
#define KWS_ID              0x000u
#define KWS_START           0x004u
#define KWS_STATUS          0x008u
#define KWS_CYCLE_CNT       0x01Cu
#define KWS_ERROR           0x014u
#define KWS_INPUT_SIZE      0x018u
#define KWS_RESULT          0x800u
#define KWS_ESTOP_HB        0x04Cu
#define KWS_ESTOP_TRIP      0x054u
#define KWS_STATUS_DONE     (1u << 1)
#define KWS_STATUS_ERROR    (1u << 2)
#define KWS_ESTOP_ARMED     (1u << 8)

#define AUDIO_BASE          0x40002000u
#define AUDIO_DATA          0x00u
#define AUDIO_LEVEL         0x04u
#define AUDIO_STATUS        0x08u
#define AUDIO_OVERRUN       0x0Cu
#define AUDIO_STATUS_NONEMPTY (1u << 0)
#define AUDIO_STATUS_OVERRUN  (1u << 2)

#define GPIO_OUT_ADDR       0x10000010u
#define MTIME_ADDR          0x10000020u
/* Lead banner build: direct MMIO UART (0x1000_0000 data, +4 status bit0=ready). */
#define UART_DATA_ADDR      0x10000000u
#define UART_STATUS_ADDR    0x10000004u
#define W3_CLOCK_HZ         27000000u
#define HEARTBEAT_PERIOD_CYCLES (W3_CLOCK_HZ / 100u) /* 10 ms at 27 MHz */

#define PCM_FRAME_SAMPLES   480u
#define PCM_HOP_SAMPLES     320u
#define FEATURE_ROWS        49u
#define FEATURE_COLUMNS     40u
#define FEATURE_BYTES       (FEATURE_ROWS * FEATURE_COLUMNS)
#define INFER_EVERY_ROWS    10u
#define AUDIO_DRAIN_BUDGET  128u
static volatile uint32_t *const kws_ctrl = (volatile uint32_t *)KWS_CTRL_BASE;
static volatile uint8_t *const kws_input = (volatile uint8_t *)KWS_BUF_BASE;
static volatile uint32_t *const kws_result =
    (volatile uint32_t *)(KWS_BUF_BASE + KWS_RESULT);
static volatile uint32_t *const audio_regs = (volatile uint32_t *)AUDIO_BASE;
static volatile uint32_t *const gpio_out = (volatile uint32_t *)GPIO_OUT_ADDR;
static volatile uint32_t *const mtime = (volatile uint32_t *)MTIME_ADDR;

static int16_t pcm_frame[PCM_FRAME_SAMPLES];
static uint8_t feature_ring[FEATURE_ROWS][FEATURE_COLUMNS];
static uint8_t feature_count;
static uint8_t feature_write;
static uint16_t rows_after_submit;
static uint8_t have_submitted;
static uint8_t inference_pending;
static uint8_t inference_active;
static uint8_t discard_inference_result;
static uint8_t app_fault;
static uint8_t audovr_reported;
static uint16_t pcm_used;
static uint32_t hb_last;
static uint8_t hb_started;
static uint32_t gpio_last;
static uint8_t gpio_written;
static kws_pcm_energy_t pcm_energy;
static uint64_t submitted_window_ss;

static kws_live_decision_t decision_ctx;
static kws_fan_control_t fan_ctx;

/* Lead banner: minimal polling UART so the board can prove the CPU is alive. */
static void uart_putc(char c)
{
  volatile uint32_t *status = (volatile uint32_t *)UART_STATUS_ADDR;
  volatile uint8_t *data = (volatile uint8_t *)UART_DATA_ADDR;
  while ((*status & 1u) == 0u) { }
  *data = (uint8_t)c;
}

static void uart_puts(const char *s)
{
  while (*s != '\0') uart_putc(*s++);
}

static void uart_put_u32(uint32_t value)
{
  char digits[11];
  int count = 0;
  if (value == 0u) { uart_putc('0'); return; }
  while (value != 0u && count < 10) { digits[count++] = (char)('0' + (value % 10u)); value /= 10u; }
  while (count > 0) uart_putc(digits[--count]);
}

static void uart_put_hex32(uint32_t value)
{
  static const char hex[] = "0123456789abcdef";
  int shift;
  for (shift = 28; shift >= 0; shift -= 4)
    uart_putc(hex[(value >> shift) & 0xfu]);
}

static void publish_gpio(void)
{
  uint32_t word = kws_fan_control_gpio_word(&fan_ctx);
  if (!gpio_written || gpio_last != word) {
    *gpio_out = word;
    gpio_last = word;
    gpio_written = 1u;
  }
}

static uint8_t estop_is_tripped(void)
{
  return (uint8_t)((kws_ctrl[KWS_ESTOP_TRIP / 4u] & 1u) != 0u);
}

static void heartbeat_service(void)
{
  uint32_t now = *mtime;
  if (!hb_started || (uint32_t)(now - hb_last) >= HEARTBEAT_PERIOD_CYCLES) {
    kws_ctrl[KWS_ESTOP_HB / 4u] = 1u;
    hb_last = now;
    hb_started = 1u;
  }
}

static void reset_pcm_energy(void)
{
  kws_pcm_energy_reset(&pcm_energy);
  submitted_window_ss = 0u;
}

static void accept_energy_sample(int16_t sample)
{
  kws_pcm_energy_push(&pcm_energy, sample);
}

static void reset_audio_window(void)
{
  uint32_t i;
  pcm_used = 0u;
  feature_count = 0u;
  feature_write = 0u;
  rows_after_submit = 0u;
  have_submitted = 0u;
  inference_pending = 0u;
  for (i = 0u; i < FEATURE_ROWS * FEATURE_COLUMNS; i++)
    ((uint8_t *)feature_ring)[i] = 0u;
  kws_live_decision_reset(&decision_ctx);
  reset_pcm_energy();
  kws_frontend_reset();
}

static void audio_fault_recover(void)
{
  uint32_t level;
  uint32_t discarded = 0u;

  /* Clear the sticky source, discard any samples spanning the lost interval,
   * and restart both frontend and same-class confirmation history. */
  audio_regs[AUDIO_OVERRUN / 4u] = 1u;
  if (inference_active != 0u) discard_inference_result = 1u;
  do {
    level = audio_regs[AUDIO_LEVEL / 4u] & 0x3ffu;
    if (level == 0u) break;
    (void)audio_regs[AUDIO_DATA / 4u];
    discarded++;
  } while (discarded < 1024u);

  reset_audio_window();
  if (!audovr_reported) {
    audovr_reported = 1u;
    uart_puts("INTAUDOVR");
    uart_puts("\n");
  }
  kws_fan_control_step(&fan_ctx, estop_is_tripped(), 1u, 0);
  publish_gpio();
}

static void accept_feature_row(const int8_t feature[FEATURE_COLUMNS])
{
  uint8_t i;
  for (i = 0u; i < FEATURE_COLUMNS; i++)
    feature_ring[feature_write][i] = (uint8_t)feature[i];

  feature_write++;
  if (feature_write == FEATURE_ROWS) feature_write = 0u;
  if (feature_count < FEATURE_ROWS) feature_count++;

  if (have_submitted) rows_after_submit++;
  if (feature_count == FEATURE_ROWS &&
      (!have_submitted || rows_after_submit >= INFER_EVERY_ROWS))
    inference_pending = 1u;
}

static void accept_pcm_sample(int16_t sample)
{
  int8_t feature[FEATURE_COLUMNS];
  uint16_t i;

  pcm_frame[pcm_used++] = sample;
  accept_energy_sample(sample);
  if (pcm_used != PCM_FRAME_SAMPLES) return;

  if (kws_frontend_process_frame(pcm_frame, feature) != 0) {
    audio_fault_recover();
    return;
  }
  accept_feature_row(feature);

  for (i = 0u; i < PCM_FRAME_SAMPLES - PCM_HOP_SAMPLES; i++)
    pcm_frame[i] = pcm_frame[i + PCM_HOP_SAMPLES];
  pcm_used = PCM_FRAME_SAMPLES - PCM_HOP_SAMPLES;
}

static void audio_service(void)
{
  uint32_t consumed = 0u;

  if (app_fault != 0u) return;
  if ((audio_regs[AUDIO_STATUS / 4u] & AUDIO_STATUS_OVERRUN) != 0u) {
    audio_fault_recover();
    return;
  }

  while (consumed < AUDIO_DRAIN_BUDGET) {
    uint32_t level = audio_regs[AUDIO_LEVEL / 4u] & 0x3ffu;
    int16_t sample;
    if (level == 0u) break;
    sample = (int16_t)(uint16_t)audio_regs[AUDIO_DATA / 4u];
    accept_pcm_sample(sample);
    consumed++;
    if (app_fault != 0u) return;
  }

  if ((audio_regs[AUDIO_STATUS / 4u] & AUDIO_STATUS_OVERRUN) != 0u)
    audio_fault_recover();
}

static void submit_latest_window(void)
{
  uint8_t row, col;
  uint8_t oldest = feature_write;
  uint32_t dst = 0u;
  /* v11full: fill the KWS input buffer with 32-bit word stores (the path the
   * validated v8/v9 builds use), then verify every byte lane by reading the
   * four byte addresses of each word back through the byte window. Earlier
   * mismatches were window access-width artefacts: a 32-bit read returns only
   * one zero-extended byte, and byte stores only land in lane 0. */
  volatile uint32_t *win32 = (volatile uint32_t *)kws_input;
  volatile uint8_t *win8 = (volatile uint8_t *)kws_input;
  uint32_t i;
  uint32_t w;
  uint32_t exp_sum = 0u;
  uint32_t got_sum = 0u;
  uint32_t bad_idx = 0xFFFFFFFFu;
  uint8_t bad_exp = 0u;
  uint8_t bad_got = 0u;
  uint8_t want_byte;

  for (w = 0u; w < (FEATURE_BYTES / 4u); w++) {
    uint32_t word = 0u;
    uint32_t k;
    for (k = 0u; k < 4u; k++) {
      uint32_t idx = w * 4u + k;
      uint32_t src_row = (uint32_t)oldest + (idx / FEATURE_COLUMNS);
      uint32_t src_col = idx % FEATURE_COLUMNS;
      uint8_t v;
      if (src_row >= FEATURE_ROWS) src_row -= FEATURE_ROWS;
      v = feature_ring[src_row][src_col];
      word |= ((uint32_t)v) << (8u * k);
    }
    win32[w] = word;
    exp_sum += word;
  }
  for (i = 0u; i < FEATURE_BYTES; i++) {
    uint32_t src_row = (uint32_t)oldest + (i / FEATURE_COLUMNS);
    uint32_t src_col = i % FEATURE_COLUMNS;
    uint8_t got = win8[i];
    if (src_row >= FEATURE_ROWS) src_row -= FEATURE_ROWS;
    want_byte = feature_ring[src_row][src_col];
    got_sum += (uint32_t)got;
    if (got != want_byte && bad_idx == 0xFFFFFFFFu) {
      bad_idx = i;
      bad_exp = want_byte;
      bad_got = got;
    }
  }
  uart_puts("INTBUF ok=");
  uart_put_u32((bad_idx == 0xFFFFFFFFu) ? 1u : 0u);
  uart_puts(" i=");
  uart_put_u32((bad_idx == 0xFFFFFFFFu) ? 0u : bad_idx);
  uart_puts(" e=");
  uart_put_hex32(bad_exp);
  uart_puts(" g=");
  uart_put_hex32(bad_got);
  uart_puts(" sumexp=");
  uart_put_hex32(exp_sum);
  uart_puts(" sumgot=");
  uart_put_hex32(got_sum);
  uart_puts("\n");

  /* v8demo: the MMIO watchdog register has no usable reset value on this board
   * (it reads 0 until written), so write it before START. */
  kws_ctrl[0x048u / 4u] = 2000000u;
  kws_ctrl[KWS_START / 4u] = 1u;
  submitted_window_ss = kws_pcm_energy_sum(&pcm_energy);
  inference_active = 1u;
  inference_pending = 0u;
  have_submitted = 1u;
  rows_after_submit = 0u;
}

static void finish_inference(uint32_t status)
{
  uint32_t packed;
  int8_t logits[4];
  kws_estop_step_t decision;

  /* Catch a FIFO gap that arose after the last audio_service() observation;
   * a pre-gap in-flight result must never issue a fan command. */
  if ((audio_regs[AUDIO_STATUS / 4u] & AUDIO_STATUS_OVERRUN) != 0u)
    audio_fault_recover();

  if ((status & KWS_STATUS_ERROR) != 0u ||
      (status & KWS_STATUS_DONE) == 0u) {
    uint32_t err = kws_ctrl[KWS_ERROR / 4u];
    app_fault = 1u;
    inference_active = 0u;
    kws_fan_control_step(&fan_ctx, estop_is_tripped(), 1u, 0);
    publish_gpio();
    uart_puts("INTINFLT st=");
    uart_put_hex32(status);
    uart_puts(" err=");
    uart_put_hex32(err);
    uart_puts(" cyc=");
    uart_put_u32(kws_ctrl[KWS_CYCLE_CNT / 4u]);
    uart_puts(" code=");
    uart_put_hex32(kws_ctrl[0x014u / 4u]);
    uart_puts(" tmo=");
    uart_put_u32(kws_ctrl[0x048u / 4u]);
    uart_puts("\n");
    return;
  }

  if (discard_inference_result != 0u) {
    discard_inference_result = 0u;
    inference_active = 0u;
    return;
  }

  packed = *kws_result;
  logits[0] = (int8_t)(packed >> 0);
  logits[1] = (int8_t)(packed >> 8);
  logits[2] = (int8_t)(packed >> 16);
  logits[3] = (int8_t)(packed >> 24);
  decision = kws_live_decision_step(&decision_ctx, logits,
                                    (int64_t)submitted_window_ss);
  inference_active = 0u;
  uart_puts("W l=");
  uart_put_hex32(packed);
  uart_puts(" am=");
  uart_put_u32((uint32_t)decision.argmax);
  uart_puts(" g=");
  uart_put_u32((uint32_t)decision.gate);
  uart_puts(" a=");
  uart_put_u32((uint32_t)decision.accept);
  uart_puts(" e=");
  uart_put_u32((uint32_t)decision.event);
  uart_puts(" c=");
  uart_put_u32((uint32_t)decision.event_class);
  uart_puts(" s=");
  uart_put_u32((uint32_t)((uint16_t)decision.score));
  uart_puts("\n");

  kws_fan_control_step(&fan_ctx, estop_is_tripped(), 0u, &decision);
  publish_gpio();
  if (decision.event != 0u) {
    uart_puts("EVENT c=");
    uart_put_u32((uint32_t)decision.event_class);
    uart_puts(" gpiow=");
    uart_put_hex32(kws_fan_control_gpio_word(&fan_ctx));
    uart_puts("\n");
  }
}

static void inference_service(void)
{
  uint32_t status;
  if (app_fault != 0u) return;

  if (!inference_active && inference_pending && feature_count == FEATURE_ROWS &&
      kws_pcm_energy_ready(&pcm_energy) &&
      !estop_is_tripped())
    submit_latest_window();

  if (!inference_active) return;
  status = kws_ctrl[KWS_STATUS / 4u];
  if ((status & (KWS_STATUS_DONE | KWS_STATUS_ERROR)) != 0u)
    finish_inference(status);
}

void w3_kws_live_main(void)
{
  uint32_t alive_last;
  uint32_t alive_count = 0u;
  uint32_t infer_poll_count = 0u;

  uart_puts("INTBOOT v=20261103-v12demo top=int27mhz\n");

  kws_fan_control_init(&fan_ctx);
  kws_live_decision_init(&decision_ctx);
  reset_pcm_energy();
  publish_gpio(); /* bit31=0 before initialization or any voice decision */

  {
    uint32_t id_value = kws_ctrl[KWS_ID / 4u];
    uint32_t size_value = kws_ctrl[KWS_INPUT_SIZE / 4u];
    int frontend_rc;

    uart_puts("INTID id=");
    uart_put_hex32(id_value);
    uart_puts(" size=");
    uart_put_u32(size_value);
    uart_puts(" expect_id=");
    uart_put_hex32(0x3153574Bu);
    uart_puts(" expect_size=");
    uart_put_u32(FEATURE_BYTES);
    uart_puts("\n");

    heartbeat_service();
    frontend_rc = kws_frontend_init();
    uart_puts("INTFRONT rc=");
    uart_put_u32((uint32_t)(frontend_rc < 0 ? (0x80000000u | (uint32_t)(-frontend_rc)) : frontend_rc));
    uart_puts("\n");

    if (id_value != 0x3153574Bu ||
        size_value != FEATURE_BYTES ||
        frontend_rc != 0) {
      app_fault = 1u;
      kws_fan_control_step(&fan_ctx, estop_is_tripped(), 1u, 0);
      publish_gpio();
      uart_puts("INTFAULT frontend_or_id\n");
    } else {
      uart_puts("INTINIT ok\n");
    }
  }


  /* Boot-time UART printing lasts tens of milliseconds; the 16 kHz I2S
   * receiver keeps pushing samples meanwhile, so the 512-entry FIFO can
   * overflow and latch the sticky overrun bit before the loop starts.
   * Clear that boot-time artifact and drain the queue once, so the run-time
   * fault path still catches genuine overruns after the loop begins. */
  audio_regs[AUDIO_OVERRUN / 4u] = 1u;
  {
    uint32_t flush_guard = 0u;
    while (((audio_regs[AUDIO_LEVEL / 4u] & 0x3ffu) != 0u) && flush_guard < 1024u) {
      (void)audio_regs[AUDIO_DATA / 4u];
      flush_guard++;
    }
  }
  if ((audio_regs[AUDIO_OVERRUN / 4u] & 1u) != 0u) {
    audio_regs[AUDIO_OVERRUN / 4u] = 1u;
  }
  reset_audio_window();

  alive_last = *mtime;
  for (;;) {
    uint8_t trip;
    uint32_t now;
    heartbeat_service();
    trip = estop_is_tripped();
    if (trip != 0u) {
      kws_fan_control_step(&fan_ctx, 1u, 0u, 0);
      publish_gpio();
    }

    audio_service();
    inference_service();

    if (inference_active != 0u) {
      ++infer_poll_count;
      if (0u) {
        uart_puts("INTPROG c=");
        uart_put_u32(kws_ctrl[0x01Cu / 4u]);
        uart_puts(" st=");
        uart_put_hex32(kws_ctrl[0x008u / 4u]);
        uart_puts("\n");
      }
    } else {
      infer_poll_count = 0u;
    }

    now = *mtime;
    if ((uint32_t)(now - alive_last) >= W3_CLOCK_HZ) {
      alive_last = now;
      ++alive_count;
      uart_puts("INTALIVE n=");
      uart_put_u32(alive_count);
      uart_puts(" gpio=");
      uart_put_u32(*gpio_out);
      uart_puts(" audio=");
      uart_put_u32(audio_regs[AUDIO_LEVEL / 4u]);
      uart_puts("\n");
    }
  }
}
