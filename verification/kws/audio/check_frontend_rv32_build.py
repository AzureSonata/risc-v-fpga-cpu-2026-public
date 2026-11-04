#!/usr/bin/env python3
"""Compile the SoC-callable TFLM frontend and dependencies for RV32IM."""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
REF = ROOT / "references/kws-signal-port-230c9"
RV32 = ROOT / "tools/kws/frontend_ref/rv32"


def run(argv: list[str]) -> None:
    p = subprocess.run(argv, cwd=ROOT, text=True, capture_output=True)
    if p.stdout:
        print(p.stdout, end="")
    if p.stderr:
        print(p.stderr, end="", file=sys.stderr)
    if p.returncode:
        raise SystemExit(p.returncode)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--cxx", default=os.environ.get("RISCV_CXX", "riscv32-unknown-elf-g++"))
    args = ap.parse_args()
    cxx = shutil.which(args.cxx)
    if cxx is None:
        print(f"NOT_RUN: RV32 C++ compiler not found: {args.cxx}", file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory(prefix="kws_frontend_rv32_") as td_raw:
        td = Path(td_raw)
        kiss = td / "kissfft"
        obj_dir = td / "obj"
        obj_dir.mkdir()
        run([sys.executable, str(RV32 / "patch_kissfft.py"),
             "--src", str(REF / "third_party/kissfft"), "--out", str(kiss)])

        include_dirs = [
            RV32 / "include",
            ROOT / "firmware/kws/include",
            REF,
            REF / "shims",
            kiss,
            kiss / "tools",
            REF / "third_party/kissfft",
            RV32,
        ]
        flags = ["-std=c++17", "-O2", "-march=rv32im", "-mabi=ilp32",
                 "-ffreestanding", "-fno-exceptions", "-fno-rtti",
                 "-fno-threadsafe-statics", "-DKWS_PRECOMPUTED_TWIDDLES"]
        flags.extend(f"-I{p}" for p in include_dirs)
        sources = [
            ROOT / "firmware/kws/src/kws_frontend.cpp",
            RV32 / "kiss_fft_int16_precomputed.cc",
            RV32 / "twiddles_q15.cc",
        ]
        sources.extend(sorted((REF / "signal/src").glob("*.cc")))
        for index, src in enumerate(sources):
            obj = obj_dir / f"{index:02d}_{src.stem}.o"
            run([cxx, *flags, "-c", str(src), "-o", str(obj)])
        print(f"PASS: compiled {len(sources)} SoC frontend objects for RV32IM")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
