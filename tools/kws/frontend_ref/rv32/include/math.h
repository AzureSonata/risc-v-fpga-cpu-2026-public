#ifndef KWS_RV32_MATH_H
#define KWS_RV32_MATH_H
/* Declarations only. The RV32I link probe leaves these undefined on purpose so the
   report can name every libm helper the pinned sources still need at init time. */
extern "C" {
double cos(double);
double sin(double);
double floor(double);
double sqrt(double);
}
#endif
