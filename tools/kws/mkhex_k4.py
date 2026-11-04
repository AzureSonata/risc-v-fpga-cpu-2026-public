#!/usr/bin/env python3
"""Make $readmemh hex vectors for tb_openeye_k4 from real model artifacts.

Sources (all in-repo, no regeneration of the model itself):
  verification/kws/k2/vectors/<fixture>/layer_00_RESHAPE_out_04.bin   (1960 B int8)
  verification/kws/k2/vectors/<fixture>/layer_01_DEPTHWISE_CONV_2D_out_02.bin (4000 B)
  verification/kws/k2/vectors/<fixture>/layer_02_FULLY_CONNECTED_out_06.bin   (4 B)
  fpga/kws/generated/micro_speech-230c9/params_rom.bin  (conv_w | conv_bias | fc_w | fc_bias)
  fpga/kws/generated/micro_speech-230c9/quant.mem       (int32 x 24: {mult,shift} interleaved)

PARAM_LAYOUT (from tools/kws/compile_openeye.py):
  conv_w_base = 0, conv_b_base = 640, fc_w_base = 672, fc_b_base = 16672

Output: verification/kws/k4/vectors/*.hex  (one token per line, 2 hex digits for int8,
        8 hex digits for int32, unsigned 2's-complement bit pattern)
"""
import argparse
import os
import struct
import sys

PARAM_LAYOUT = {"conv_w_base": 0, "conv_b_base": 640, "fc_w_base": 672, "fc_b_base": 16672}
DW_COUT, FC_NOUT = 8, 4
DW_W_BYTES = 8 * 10 * 8            # Cout*Kh*Kw = 640
FC_W_BYTES = 4 * 4000              # 16000
DW_IN_BYTES = 1960
DW_OUT_BYTES = 25 * 20 * 8         # 4000


def read_bytes(path):
    with open(path, "rb") as fh:
        return fh.read()


def write_hex_i8(path, data, expect_len=None):
    """Write int8 data as hex, rejecting malformed tensor lengths."""
    if expect_len is not None and len(data) != expect_len:
        sys.exit("FAIL: %s is %d B, expected exactly %d" %
                 (path, len(data), expect_len))
    with open(path, "w", newline="\n") as fh:
        for b in data:
            fh.write("%02x\n" % b)          # 无符号位模式；TB 用 signed [7:0] 装载
    return len(data)


def write_hex_i32(path, values):
    with open(path, "w", newline="\n") as fh:
        for v in values:
            fh.write("%08x\n" % (v & 0xFFFFFFFF))
    return len(values)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--fixture", default="no_30ms_x49")
    ap.add_argument("--out", default=None)
    a = ap.parse_args()

    repo = a.repo
    vec = os.path.join(repo, "verification", "kws", "k2", "vectors", a.fixture)
    gen = os.path.join(repo, "fpga", "kws", "generated", "micro_speech-230c9")
    out = a.out or os.path.join(repo, "verification", "kws", "k4", "vectors")
    os.makedirs(out, exist_ok=True)

    # ---- golden / 输入 ----
    dw_in = read_bytes(os.path.join(vec, "layer_00_RESHAPE_out_04.bin"))
    g_dw = read_bytes(os.path.join(vec, "layer_01_DEPTHWISE_CONV_2D_out_02.bin"))
    g_fc = read_bytes(os.path.join(vec, "layer_02_FULLY_CONNECTED_out_06.bin"))

    n = write_hex_i8(os.path.join(out, "dw_in.hex"), dw_in, DW_IN_BYTES)
    print("dw_in       : %d B" % n)
    n = write_hex_i8(os.path.join(out, "golden_dw.hex"), g_dw, DW_OUT_BYTES)
    print("golden_dw   : %d B" % n)
    n = write_hex_i8(os.path.join(out, "golden_fc.hex"), g_fc, FC_NOUT)
    print("golden_fc   : %d B" % n)

    # ---- params_rom 切片 ----
    rom = read_bytes(os.path.join(gen, "params_rom.bin"))
    print("params_rom  : %d B" % len(rom))

    dw_w = rom[PARAM_LAYOUT["conv_w_base"]:PARAM_LAYOUT["conv_w_base"] + DW_W_BYTES]
    dw_b = rom[PARAM_LAYOUT["conv_b_base"]:PARAM_LAYOUT["conv_b_base"] + 4 * DW_COUT]
    fc_w = rom[PARAM_LAYOUT["fc_w_base"]:PARAM_LAYOUT["fc_w_base"] + FC_W_BYTES]
    fc_b = rom[PARAM_LAYOUT["fc_b_base"]:PARAM_LAYOUT["fc_b_base"] + 4 * FC_NOUT]

    n = write_hex_i8(os.path.join(out, "dw_w.hex"), dw_w, DW_W_BYTES)
    print("dw_w        : %d B" % n)
    n = write_hex_i8(os.path.join(out, "fc_w.hex"), fc_w, FC_W_BYTES)
    print("fc_w        : %d B" % n)

    dw_bias = list(struct.unpack("<%di" % DW_COUT, dw_b))
    fc_bias = list(struct.unpack("<%di" % FC_NOUT, fc_b))
    write_hex_i32(os.path.join(out, "dw_bias.hex"), dw_bias)
    write_hex_i32(os.path.join(out, "fc_bias.hex"), fc_bias)
    print("dw_bias     : %s" % dw_bias)
    print("fc_bias     : %s" % fc_bias)

    # ---- quant.mem: {mult,shift} 交错，共 DW_COUT+FC_NOUT 通道 ----
    q = read_bytes(os.path.join(gen, "quant.mem"))
    nch = DW_COUT + FC_NOUT
    if len(q) != 8 * nch:
        sys.exit("FAIL: quant.mem is %d B, expected %d" % (len(q), 8 * nch))
    pairs = list(struct.unpack("<%di" % (2 * nch), q))
    mults = pairs[0::2]
    shifts = pairs[1::2]
    write_hex_i32(os.path.join(out, "quant_mult.hex"), mults)
    write_hex_i32(os.path.join(out, "quant_shift.hex"), shifts)
    print("quant_mult  : %s" % mults)
    print("quant_shift : %s" % shifts)

    print("OK -> %s" % out)


if __name__ == "__main__":
    main()
