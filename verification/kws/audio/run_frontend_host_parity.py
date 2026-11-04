#!/usr/bin/env python3
"""Build the SoC-callable frontend on host and compare it to locked K2 outputs."""
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
FIXTURES = ("yes", "no", "silence", "noise")


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
    ap.add_argument("--cxx", default=os.environ.get("CXX", "g++"))
    args = ap.parse_args()
    cxx = shutil.which(args.cxx)
    if cxx is None:
        print(f"NOT_RUN: C++ compiler not found: {args.cxx}", file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory(prefix="kws_frontend_host_") as td_raw:
        td = Path(td_raw)
        kiss = td / "kissfft"
        patcher = RV32 / "patch_kissfft.py"
        run([sys.executable, str(patcher), "--src", str(REF / "third_party/kissfft"),
             "--out", str(kiss)])

        sources = [
            str(RV32 / "kiss_fft_int16_precomputed.cc"),
            str(RV32 / "twiddles_q15.cc"),
            str(ROOT / "firmware/kws/src/kws_frontend.cpp"),
            str(ROOT / "verification/kws/audio/test_frontend_host.cpp"),
        ]
        sources.extend(str(p) for p in sorted((REF / "signal/src").glob("*.cc")))
        exe = td / "test_frontend_host.exe"
        include_dirs = [
            ROOT / "firmware/kws/include",
            RV32,
            REF,
            REF / "shims",
            kiss,
            kiss / "tools",
            REF / "third_party/kissfft",
        ]
        cmd = [cxx, "-std=c++17", "-O2", "-DKWS_PRECOMPUTED_TWIDDLES"]
        cmd.extend(f"-I{p}" for p in include_dirs)
        cmd.extend(sources)
        cmd.extend(["-o", str(exe)])
        run(cmd)

        for name in FIXTURES:
            pcm = ROOT / f"verification/kws/k2/frontend/{name}_1000ms.s16le"
            expected = ROOT / f"verification/kws/k2/frontend/{name}_1000ms_features_int8.bin"
            if not pcm.is_file() or not expected.is_file():
                print(f"FAIL: missing locked fixture for {name}", file=sys.stderr)
                return 1
            print(f"{name}: ", end="")
            run([str(exe), str(pcm), str(expected)])
    print("PASS: SoC-callable frontend matches all four 49x40 K2 feature fixtures")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
