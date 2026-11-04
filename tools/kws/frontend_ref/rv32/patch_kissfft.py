#!/usr/bin/env python3
"""K3/A: build-time patch that makes kissfft use verified precomputed tables.

The pinned kissfft sources stay untouched in references/kws-signal-port-230c9/.
This script copies them into a build directory and applies three anchored edits:

1. kiss_fft.c  : twiddle loop  -> copy from kws_sub_twiddles_q15
2. kiss_fftr.c : super loop    -> copy from kws_super_twiddles_q15
3. kiss_fft.c  : kf_factor()'s floor(sqrt((double)n)) -> integer sqrt

After these the frontend has no libm / soft-float dependency at init time.
Every edit is guarded by #ifdef KWS_PRECOMPUTED_TWIDDLES and every anchor is
matched exactly; if the pinned file changes this script fails loudly instead of
producing a stale patch.
"""
from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

NL = chr(10)
INCLUDE_LINE = '#include "twiddles_q15.h" /* KWS: precomputed twiddle tables */'

SUB_LOOP = NL.join([
    "#ifdef KWS_PRECOMPUTED_TWIDDLES",
    "        /* KWS: table dumped from this same kissfft v130 on the host and verified",
    "           entry-by-entry (count/order/sign/scale/int16), see precompute_twiddles.py. */",
    "        for (i = 0; i < nfft; ++i) {",
    "            st->twiddles[i].r = kws_sub_twiddles_q15[2 * i];",
    "            st->twiddles[i].i = kws_sub_twiddles_q15[2 * i + 1];",
    "        }",
    "#else",
    "@@ORIGINAL@@",
    "#endif",
])

SUPER_LOOP = NL.join([
    "#ifdef KWS_PRECOMPUTED_TWIDDLES",
    "    /* KWS: super twiddles precomputed on the host (same formula, verified). */",
    "    for (i = 0; i < nfft / 2; ++i) {",
    "        st->super_twiddles[i].r = kws_super_twiddles_q15[2 * i];",
    "        st->super_twiddles[i].i = kws_super_twiddles_q15[2 * i + 1];",
    "    }",
    "#else",
    "@@ORIGINAL@@",
    "#endif",
])

FLOOR_SQRT_OLD = "    floor_sqrt = floor( sqrt((double)n) );"
FLOOR_SQRT_NEW = NL.join([
    "#ifdef KWS_PRECOMPUTED_TWIDDLES",
    "    /* KWS: integer sqrt replaces floor(sqrt((double)n)); identical for integer n",
    "       and keeps libm/soft-float out of the target build. */",
    "    {",
    "        int r = 0;",
    "        while ((r + 1) * (r + 1) <= n) ++r;",
    "        floor_sqrt = (double)r;",
    "    }",
    "#else",
    FLOOR_SQRT_OLD,
    "#endif",
])


def wrap_loop(text: str, anchor: str, start_marker: str, replacement: str, label: str) -> str:
    pos = text.find(anchor)
    if pos < 0:
        raise SystemExit("FAIL: anchor not found for " + label)
    start = text.rfind(start_marker, 0, pos)
    if start < 0:
        raise SystemExit("FAIL: loop start not found for " + label)
    rest = text[start:]
    indent = rest[: len(rest) - len(rest.lstrip())]
    end_marker = NL + indent + "}"
    end = text.find(end_marker, pos)
    if end < 0:
        raise SystemExit("FAIL: loop end not found for " + label)
    end += len(end_marker)
    original = text[start:end]
    return text[:start] + replacement.replace("@@ORIGINAL@@", original) + text[end:]


def insert_include(text: str, marker: str, label: str) -> str:
    if INCLUDE_LINE in text:
        return text
    if marker not in text:
        raise SystemExit("FAIL: include anchor not found for " + label)
    return text.replace(marker, marker + NL + INCLUDE_LINE, 1)


def main() -> int:
    ap = argparse.ArgumentParser(description="patch pinned kissfft for precomputed twiddles")
    ap.add_argument("--src", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()
    src, out = args.src.resolve(), args.out.resolve()
    (out / "tools").mkdir(parents=True, exist_ok=True)

    fft_c = (src / "kiss_fft.c").read_text(encoding="utf-8")
    fft_c = wrap_loop(fft_c, "kf_cexp(st->twiddles+i, phase );",
                      "        for (i=0;i<nfft;++i) {", SUB_LOOP, "kiss_fft.c twiddles")
    if FLOOR_SQRT_OLD not in fft_c:
        raise SystemExit("FAIL: kf_factor float-sqrt anchor not found")
    fft_c = fft_c.replace(FLOOR_SQRT_OLD, FLOOR_SQRT_NEW, 1)
    fft_c = insert_include(fft_c, '#include "_kiss_fft_guts.h"', "kiss_fft.c")
    (out / "kiss_fft.c").write_text(fft_c, encoding="utf-8", newline=NL)

    ftr_c = (src / "tools" / "kiss_fftr.c").read_text(encoding="utf-8")
    ftr_c = wrap_loop(ftr_c, "kf_cexp (st->super_twiddles+i,phase);",
                      "    for (i = 0; i < nfft/2; ++i) {", SUPER_LOOP, "kiss_fftr.c super twiddles")
    ftr_c = insert_include(ftr_c, '#include "kiss_fftr.h"', "kiss_fftr.c")
    (out / "tools" / "kiss_fftr.c").write_text(ftr_c, encoding="utf-8", newline=NL)

    for name in ("kiss_fft.h", "_kiss_fft_guts.h"):
        shutil.copy2(src / name, out / name)
    shutil.copy2(src / "tools" / "kiss_fftr.h", out / "tools" / "kiss_fftr.h")
    print("PASS: patched kissfft written to " + str(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
