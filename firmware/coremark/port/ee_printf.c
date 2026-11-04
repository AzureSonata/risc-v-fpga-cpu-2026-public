/* Minimal streaming integer formatter for pinned CoreMark HAS_FLOAT=0 output.
 * Original project implementation; no 1024-byte printf buffer or libc needed.
 * Supports strings, chars, signed/unsigned decimal, hex, widths, 'l' and 'll'.
 */
#include "core_portme.h"
#include <stdarg.h>

static int emit(char c) { port_putc(c); return 1; }
static int emit_number(uint32_t value, unsigned base, unsigned width, char pad, int negative, int upper) {
    char digits[32];
    const char *alphabet = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    unsigned count = 0;
    int written = 0;
    do { digits[count++] = alphabet[value % base]; value /= base; } while (value);
    if (negative && pad == '0') { written += emit('-'); }
    while (width > count + (unsigned)negative) { written += emit(pad); --width; }
    if (negative && pad != '0') { written += emit('-'); }
    while (count) { written += emit(digits[--count]); }
    return written;
}

static int emit_number64(uint64_t value, unsigned base, unsigned width, char pad, int negative, int upper) {
    char digits[32];
    const char *alphabet = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    unsigned count = 0;
    int written = 0;
    do { digits[count++] = alphabet[value % base]; value /= base; } while (value);
    if (negative && pad == '0') { written += emit('-'); }
    while (width > count + (unsigned)negative) { written += emit(pad); --width; }
    if (negative && pad != '0') { written += emit('-'); }
    while (count) { written += emit(digits[--count]); }
    return written;
}

int ee_printf(const char *format, ...) {
    va_list arguments;
    int written = 0;
    va_start(arguments, format);
    while (*format) {
        unsigned width = 0;
        int is_long = 0;
        int is_long_long = 0;
        char padding = ' ';
        char conversion;
        if (*format != '%') { written += emit(*format++); continue; }
        ++format;
        if (*format == '0') { padding = '0'; ++format; }
        while (*format >= '0' && *format <= '9') { width = width * 10u + (unsigned)(*format++ - '0'); }
        if (*format == 'l') {
            is_long = 1;
            ++format;
            if (*format == 'l') { is_long_long = 1; ++format; }
        }
        conversion = *format;
        if (!conversion) { break; }
        ++format;
        if (conversion == 's') {
            const char *text = va_arg(arguments, const char *);
            if (!text) { text = "(null)"; }
            while (*text) { written += emit(*text++); }
        } else if (conversion == 'c') {
            written += emit((char)va_arg(arguments, int));
        } else if (conversion == '%') {
            written += emit('%');
        } else if (conversion == 'd' || conversion == 'i') {
            if (is_long_long) {
                int64_t value = va_arg(arguments, long long);
                uint64_t magnitude = value < 0 ? 0ull - (uint64_t)value : (uint64_t)value;
                written += emit_number64(magnitude, 10u, width, padding, value < 0, 0);
            } else {
                int32_t value = is_long ? (int32_t)va_arg(arguments, long) : va_arg(arguments, int);
                uint32_t magnitude = value < 0 ? 0u - (uint32_t)value : (uint32_t)value;
                written += emit_number(magnitude, 10u, width, padding, value < 0, 0);
            }
        } else if (conversion == 'u' || conversion == 'x' || conversion == 'X') {
            if (is_long_long) {
                uint64_t value = va_arg(arguments, unsigned long long);
                written += emit_number64(value, conversion == 'u' ? 10u : 16u,
                                         width, padding, 0, conversion == 'X');
            } else {
                uint32_t value = is_long ? (uint32_t)va_arg(arguments, unsigned long) : va_arg(arguments, unsigned int);
                written += emit_number(value, conversion == 'u' ? 10u : 16u, width, padding, 0, conversion == 'X');
            }
        } else {
            /* A changed upstream format must not silently corrupt validity output. */
            const char *message = "\nERROR! unsupported port output format\n";
            while (*message) { emit(*message++); }
            va_end(arguments);
            for (;;) { }
        }
    }
    va_end(arguments);
    return written;
}
