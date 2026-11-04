#!/usr/bin/env python3
"""为**任意**模型生成 K4 裸核通路需要的 DW 层 golden（4000 B），不挑上游。

为什么单独有一个
----------------
`k4_reference_probe.py` 的路径写死成 `fpga/kws/generated/micro_speech-230c9`，
换模型就没法用它。本脚本把模型路径、量化表路径、输入夹具都变成参数，
并自带一条**自验**：给它一份已知 golden，它会报逐字节匹配数。

2026-11-02 的教训：换模型后两条 RTL 通路（K4 裸核 vs 板级 SoC）对不上，
先别急着判 ROM 错——绝大多数时候是**喂进去的输入不是同一份**。
本脚本要求 --input 显式给出，就是为了不留这个口子。

范围：只做 DW 层。FC 层的 host 前向在此仓库里**尚未与 RTL 对齐**
（2026-11-02 实测：同一 ROM 同输入，host 得 [-128,-40,-33,22]、RTL 得 [-128,102,109,127]），
所以本脚本不提供 FC golden，也不声称能替代 K4 裸核。

Usage
-----
  python tools/kws/k4_dw_golden.py --params-rom <p> --quant <p> \
      --input <1960B int8> --out <golden_dw.hex> [--check <known golden_dw.hex>]
"""
from __future__ import annotations

import argparse
import hashlib
import pathlib
import struct
import sys

import numpy as np

# 与 k4_reference_probe.py / compile_openeye.py 同一份常量（10x8 kernel，非标准 3x3）
KH, KW, SH, SW, PT, PL, PB, PR = 10, 8, 2, 2, 4, 3, 5, 3
IN_ZP, OUT_ZP = -128, -128
ACT_MIN, ACT_MAX = -128, 127
DW_OUT_BYTES = 25 * 20 * 8


def srdhm(a, b):
    a = np.asarray(a, dtype=np.int64)
    b = np.asarray(b, dtype=np.int64)
    ab = a * b
    nudge = np.where(ab >= 0, 1 << 30, 1 - (1 << 30)).astype(np.int64)
    num = ab + nudge
    d = np.int64(1 << 31)
    return np.clip(np.where(num >= 0, num // d, -((-num) // d)), -(1 << 31), (1 << 31) - 1)


def rdbp(x, e):
    x = np.asarray(x, dtype=np.int64)
    e = int(e)
    if e == 0:
        return x
    out = np.zeros(x.shape, dtype=np.int64)
    for idx in np.ndindex(x.shape):
        v = int(x[idx])
        mask = (1 << e) - 1
        rem = v & mask
        thr = (mask >> 1) + (1 if v < 0 else 0)
        out[idx] = (v >> e) + (1 if rem > thr else 0)
    return out


def dw_forward(rom: bytes, quant: bytes, xb: bytes) -> np.ndarray:
    if len(rom) != 16688:
        raise SystemExit("FAIL: params_rom 是 %d B，期望 16688" % len(rom))
    if len(quant) != 96:
        raise SystemExit("FAIL: quant 是 %d B，期望 96" % len(quant))
    if len(xb) != 1960:
        raise SystemExit("FAIL: 输入是 %d B，期望 1960" % len(xb))
    w = np.frombuffer(rom[0:640], dtype=np.int8).reshape(8, KH, KW, 1).astype(np.int64)
    bias = np.frombuffer(rom[640:672], dtype="<i4").astype(np.int64)
    qq = np.frombuffer(quant, dtype="<i4")
    mult, shift = qq[0::2][:8], qq[1::2][:8]
    x = np.frombuffer(xb, dtype=np.int8).reshape(49, 40).astype(np.int64)
    xp = np.full((49 + PT + PB, 40 + PL + PR), IN_ZP, dtype=np.int64)
    xp[PT:PT + 49, PL:PL + 40] = x
    out = np.zeros((25, 20, 8), dtype=np.int64)
    for c in range(8):
        acc = np.zeros((25, 20), dtype=np.int64)
        wc = w[c, :, :, 0]
        for dy in range(KH):
            for dx in range(KW):
                acc += xp[dy:dy + SH * 24 + 1:SH, dx:dx + SW * 19 + 1:SW] * wc[dy, dx]
        acc += int(bias[c])
        sh = int(shift[c])
        out[:, :, c] = np.clip(rdbp(srdhm(acc, mult[c]), -sh if sh < 0 else 0) + OUT_ZP,
                               ACT_MIN, ACT_MAX)
    return out.reshape(-1)


def read_i8_hex(p):
    t = pathlib.Path(p).read_bytes().decode("ascii").split()
    return np.array([int(v, 16) - 256 if int(v, 16) > 127 else int(v, 16)
                     for v in t], dtype=np.int64)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--params-rom", required=True)
    ap.add_argument("--quant", required=True)
    ap.add_argument("--input", required=True, help="1960 B int8 特征（必须与板级仿真用同一份）")
    ap.add_argument("--out", required=True)
    ap.add_argument("--check", default="", help="已知 golden，用来报匹配数")
    a = ap.parse_args()

    rom = pathlib.Path(a.params_rom).read_bytes()
    quant = pathlib.Path(a.quant).read_bytes()
    xb = pathlib.Path(a.input).read_bytes()

    o = dw_forward(rom, quant, xb)
    with open(a.out, "w", encoding="ascii", newline="\n") as f:
        f.write("".join("%02x\n" % (int(v) & 0xFF) for v in o))
    print("DW golden -> %s  %d 值  min=%d max=%d" %
          (a.out, len(o), int(o.min()), int(o.max())))
    print("  params_rom sha256=%s" % hashlib.sha256(rom).hexdigest()[:16])
    print("  input      sha256=%s" % hashlib.sha256(xb).hexdigest()[:16])

    if a.check:
        g = read_i8_hex(a.check)
        m = int((o == g).sum())
        print("  对照 %s: %d / %d 字节匹配" % (a.check, m, DW_OUT_BYTES))
        if m != DW_OUT_BYTES:
            print("  ⚠ 不匹配：先查输入夹具是不是同一份，再怀疑 ROM")
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
