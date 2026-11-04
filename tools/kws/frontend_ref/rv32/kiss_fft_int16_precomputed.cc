// RV32I build TU: the pinned kissfft v130 wrapped in its own namespace, but compiled
// from the *patched* copies (precomputed twiddles) produced by patch_kissfft.py.
// Same structure as signal/src/kiss_fft_wrappers/kiss_fft_int16.cc.
#include "signal/src/kiss_fft_wrappers/kiss_fft_common.h"
#define FIXED_POINT 16
namespace kiss_fft_fixed16 {
#include "kiss_fft.c"
#include "tools/kiss_fftr.c"
}
#undef FIXED_POINT
