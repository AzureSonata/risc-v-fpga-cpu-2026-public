#!/usr/bin/env python3
"""Independent reference for the FIRST few (oy,ox,c) of the DW layer.

Purpose: when the RTL disagrees with golden, we need to know whether the
RTL is wrong or the golden pipeline (reference) is wrong.  This script
re-implements accumulate_conv + requant exactly as tools/kws/compile_openeye.py
does, using the SAME params_rom slice and the SAME input plane, and prints
per-(oy,ox,c) accumulator + requantised byte for comparison with RTL probes.
"""
import argparse
import os
import struct
import sys

import numpy as np

ACT_MIN, ACT_MAX = -128, 127
PARAM_LAYOUT = {"conv_w_base": 0, "conv_b_base": 640, "fc_w_base": 672, "fc_b_base": 16672}


def srdhm(a, b):
    ab = a.astype(np.int64) * b.astype(np.int64)
    nudge = np.where(ab >= 0, 1 << 30, 1 - (1 << 30)).astype(np.int64)
    num = ab + nudge
    d = np.int64(1 << 31)
    q = np.where(num >= 0, num // d, -((-num) // d)).astype(np.int64)
    return np.clip(q, -(1 << 31), (1 << 31) - 1)


def rdbp(x, e):
    x = x.astype(np.int64)
    if e == 0:
        return x
    mask = (1 << int(e)) - 1
    rem = x & mask
    thr = (mask >> 1) + (x < 0).astype(np.int64)
    return (x >> int(e)) + (rem > thr).astype(np.int64)


def requant(acc, mult, shift, out_zp):
    left = np.maximum(shift, 0).astype(np.int64)
    right = np.maximum(-shift, 0).astype(np.int64)
    x1 = acc * np.left_shift(np.int64(1), left)
    x2 = srdhm(x1, mult)
    x3 = rdbp(x2, right)
    out = x3 + out_zp
    return np.clip(out, ACT_MIN, ACT_MAX)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--fixture", default="no_30ms_x49")
    ap.add_argument("--probe", type=int, default=8, help="how many (oy,ox,c) to print")
    a = ap.parse_args()
    repo = a.repo

    vec = os.path.join(repo, "verification", "kws", "k2", "vectors", a.fixture)
    gen = os.path.join(repo, "fpga", "kws", "generated", "micro_speech-230c9")

    x = np.frombuffer(open(os.path.join(vec, "layer_00_RESHAPE_out_04.bin"), "rb").read(),
                      dtype=np.int8).reshape(49, 40).astype(np.int64)
    graw = open(os.path.join(vec, "layer_01_DEPTHWISE_CONV_2D_out_02.bin"), "rb").read()
    if len(graw) != 4000:
        print("WARNING: golden DW is %d B (expected 4000); extra tail %s"
              % (len(graw), list(graw[4000:])[:8]))
        graw = graw[:4000]
    gold = np.frombuffer(graw, dtype=np.int8).reshape(25, 20, 8)

    rom = open(os.path.join(gen, "params_rom.bin"), "rb").read()
    w = np.frombuffer(rom[PARAM_LAYOUT["conv_w_base"]:PARAM_LAYOUT["conv_w_base"] + 640],
                      dtype=np.int8).reshape(8, 10, 8, 1).astype(np.int64)      # [Cout,Kh,Kw,Cin]
    bias = np.frombuffer(rom[PARAM_LAYOUT["conv_b_base"]:PARAM_LAYOUT["conv_b_base"] + 32],
                         dtype="<i4").astype(np.int64)
    q = np.frombuffer(open(os.path.join(gen, "quant.mem"), "rb").read(), dtype="<i4")
    mult = q[0::2][:8].astype(np.int64)
    shift = q[1::2][:8].astype(np.int64)

    KH, KW, SH, SW, PT, PL = 10, 8, 2, 2, 4, 3
    IN_ZP, OUT_ZP = -128, -128

    # reference accumulate (verbatim structure of compile_openeye.py)
    xp = np.full((49 + PT + 5, 40 + PL + 3), IN_ZP, dtype=np.int64)
    xp[PT:PT + 49, PL:PL + 40] = x
    acc = np.zeros((25, 20, 8), dtype=np.int64)
    for c in range(8):
        wc = w[c, :, :, 0]
        for dy in range(KH):
            for dx in range(KW):
                acc[:, :, c] += xp[dy:dy + SH * 24 + 1:SH, dx:dx + SW * 19 + 1:SW] * wc[dy, dx]
        acc[:, :, c] += int(bias[c])

    out = np.zeros((25, 20, 8), dtype=np.int64)
    for c in range(8):
        out[:, :, c] = requant(acc[:, :, c], mult[c], shift[c], OUT_ZP)

    match = int((out.astype(np.int8) == gold).sum())
    print("reference vs golden: %d / %d bytes match" % (match, 4000))
    print()
    print("idx  oy ox c   acc            mult         shift  requant  golden")
    for idx in range(a.probe):
        c = idx % 8
        ox = (idx // 8) % 20
        oy = idx // 160
        ac = acc[oy, ox, c]
        rq = out[oy, ox, c]
        print("%4d %2d %2d %d  %14d  %12d  %5d  %7d  %6d" %
              (idx, oy, ox, c, ac, mult[c], shift[c], rq, gold[oy, ox, c]))


if __name__ == "__main__":
    main()
