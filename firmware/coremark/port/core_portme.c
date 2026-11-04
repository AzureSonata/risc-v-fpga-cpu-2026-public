/* Project port using the pinned upstream barebones API.
 * Timing/seed API reference: EEMBC/coremark 1f483d5, Apache-2.0.
 * Timer source: implemented machine mcycle/mcycleh CSRs; board run NOT_RUN.
 */
#include "coremark.h"

#define REG32(address) (*(volatile uint32_t *)(uintptr_t)(address))
#define UART_DATA 0x10000000u
#define UART_STATUS 0x10000004u
#define TIMER_COMPARE 0x10000024u

#if defined(VALIDATION_RUN)
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
#else
volatile ee_s32 seed1_volatile = 0;
volatile ee_s32 seed2_volatile = 0;
#endif
volatile ee_s32 seed3_volatile = 0x66;
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;
ee_u32 default_num_contexts = 1;
static uint64_t timer_start, timer_stop;

/* RV32 cannot read a 64-bit CSR atomically. Retry the standard high-low-high
 * sequence if mcycle crosses its low-word boundary during the read.
 */
static uint64_t read_mcycle(void) {
    uint32_t high_before, low, high_after;
    do {
        __asm__ volatile (
            "csrr %0, mcycleh\n\t"
            "csrr %1, mcycle\n\t"
            "csrr %2, mcycleh"
            : "=&r" (high_before), "=&r" (low), "=&r" (high_after)
            :
            : "memory");
    } while (high_before != high_after);
    return ((uint64_t)high_after << 32) | low;
}

void port_putc(char c) {
    /* UART bit0=ready, not busy. MMIO stays volatile and bypasses caches. */
    while ((REG32(UART_STATUS) & 1u) == 0u) { }
    REG32(UART_DATA) = (uint8_t)c;
}

void start_time(void) { timer_start = read_mcycle(); }
void stop_time(void) { timer_stop = read_mcycle(); }
CORE_TICKS get_time(void) { return timer_stop - timer_start; }
secs_ret time_in_secs(CORE_TICKS ticks) { return (secs_ret)(ticks / (uint32_t)TIMER_HZ); }

void portable_init(core_portable *p, int *argc, char *argv[]) {
    (void)argc;
    (void)argv;
    /* Reset mstatus/mie disables interrupts in the pinned CPU. This candidate
     * does not enable them; an interrupt-using application needs a reviewed
     * mode-switch/handler contract before sharing this port.
     */
    REG32(TIMER_COMPARE) = UINT32_MAX;
    p->portable_id = 1;
}
void portable_fini(core_portable *p) {
    ee_printf("PORT-RAW timer_start=%llu timer_stop=%llu ticks=%llu timer_hz=%lu timer_bits=64\n",
              (unsigned long long)timer_start, (unsigned long long)timer_stop,
              (unsigned long long)get_time(), (unsigned long)TIMER_HZ);
    /* Raw values are supplementary: CRC, known-seed validity, elapsed>=10s,
     * an independently bounded run duration and real clock proof remain required.
     */
    p->portable_id = 0;
}
