#ifndef KWS_RV32_STDLIB_H
#define KWS_RV32_STDLIB_H
#include <stdint.h>
extern "C" {
void abort(void);
void exit(int);
void *malloc(size_t);
void free(void *);
}
#endif
