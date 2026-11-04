/* Minimal freestanding runtime for the KWS firmware image. */
#include <stdint.h>

typedef unsigned int kws_size_t;

void *memcpy(void *dst, const void *src, kws_size_t count)
{
  unsigned char *d = (unsigned char *)dst;
  const unsigned char *s = (const unsigned char *)src;
  while (count-- != 0u) *d++ = *s++;
  return dst;
}

void *memmove(void *dst, const void *src, kws_size_t count)
{
  unsigned char *d = (unsigned char *)dst;
  const unsigned char *s = (const unsigned char *)src;
  if ((uintptr_t)d < (uintptr_t)s) {
    while (count-- != 0u) *d++ = *s++;
  } else if ((uintptr_t)d > (uintptr_t)s) {
    d += count;
    s += count;
    while (count-- != 0u) *--d = *--s;
  }
  return dst;
}

void *memset(void *dst, int value, kws_size_t count)
{
  unsigned char *d = (unsigned char *)dst;
  while (count-- != 0u) *d++ = (unsigned char)value;
  return dst;
}

int memcmp(const void *lhs, const void *rhs, kws_size_t count)
{
  const unsigned char *a = (const unsigned char *)lhs;
  const unsigned char *b = (const unsigned char *)rhs;
  while (count-- != 0u) {
    if (*a != *b) return (int)*a - (int)*b;
    ++a;
    ++b;
  }
  return 0;
}

/* KissFFT prints only allocation/configuration diagnostics through these names.
 * The SoC image has no stdio device; numerical output and app status use MMIO. */
void *stderr;
int fprintf(void *stream, const char *format, ...)
{
  (void)stream;
  (void)format;
  return 0;
}

void abort(void)
{
  for (;;) { }
}

void exit(int status)
{
  (void)status;
  for (;;) { }
}
