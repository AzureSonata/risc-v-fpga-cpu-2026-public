/* Project port candidate; upstream algorithm files remain unchanged.
 * API reference: EEMBC/coremark 1f483d5, barebones/core_portme.h (Apache-2.0).
 */
#ifndef CORE_PORTME_H
#define CORE_PORTME_H
#include <stddef.h>
#include <stdint.h>

#define HAS_FLOAT 0
#define HAS_TIME_H 0
#define USE_CLOCK 0
#define HAS_STDIO 0
#define HAS_PRINTF 0
#define MAIN_HAS_NOARGC 1
#define MAIN_HAS_NORETURN 0
#define MULTITHREAD 1
#define USE_PTHREAD 0
#define USE_FORK 0
#define USE_SOCKET 0
#define SEED_METHOD SEED_VOLATILE
#define MEM_METHOD MEM_STATIC
#define MEM_LOCATION "STATIC / D SRAM; capacity and image loading must be reviewed"
#define COMPILER_VERSION "GCC " __VERSION__
#define COMPILER_FLAGS FLAGS_STR

typedef int16_t ee_s16;
typedef uint16_t ee_u16;
typedef int32_t ee_s32;
typedef uint32_t ee_u32;
typedef uint8_t ee_u8;
typedef double ee_f32;
typedef uintptr_t ee_ptr_int;
typedef size_t ee_size_t;
typedef uint64_t CORE_TICKS;
#define CORETIMETYPE CORE_TICKS
#define align_mem(x) ((void *)(((ee_ptr_int)(x) + 3u) & ~(ee_ptr_int)3u))

_Static_assert(sizeof(void *) == 4, "This port requires a 32-bit target");
_Static_assert(sizeof(ee_u32) == 4, "CoreMark requires 32-bit ee_u32");
_Static_assert(sizeof(ee_ptr_int) == sizeof(void *), "Pointer type mismatch");

#if !defined(PERFORMANCE_RUN) && !defined(VALIDATION_RUN)
#error "Choose PERFORMANCE_RUN or VALIDATION_RUN explicitly"
#endif
#if defined(PERFORMANCE_RUN) && defined(VALIDATION_RUN)
#error "Choose exactly one seed configuration"
#endif
#if !defined(TIMER_HZ) || TIMER_HZ <= 0
#error "Supply the actual reviewed timer clock; there is no assumed board frequency"
#endif
#if !defined(ITERATIONS) || ITERATIONS <= 0
#error "Supply positive ITERATIONS; automatic calibration is not enabled in this candidate"
#endif

typedef struct { ee_u8 portable_id; } core_portable;
extern ee_u32 default_num_contexts;
void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);
int ee_printf(const char *fmt, ...);
void port_putc(char c);
#endif
