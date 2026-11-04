#ifndef KWS_RV32_STDIO_H
#define KWS_RV32_STDIO_H
#include <stdint.h>
extern "C" {
extern void *stderr;
int printf(const char *, ...);
int fprintf(void *, const char *, ...);
}
#endif
