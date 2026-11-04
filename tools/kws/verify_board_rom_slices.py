#!/usr/bin/env python3
"""板级 ROM 切片对账：不经 mkhex_k4.py，独立切片 params_rom.bin 去核对 board_rom/*.hex。

为什么需要它
------------
换模型时"ROM 有问题"有两种完全不同的含义，必须先分开：
  (a) **内容**错：params_rom.bin 本身就不是那个模型（源头问题）；
  (b) **解析**错：params_rom.bin 是对的，但切成 5 块 ROM 时切错/排错（工具问题）。
之前只验过 (a) 的一个侧面（sha 与 pack_record 一致）和"上游重生成==旧文件"，
后者只证明工具没改坏默认路径，**没有独立验证过中文模型的 5 块 ROM 切得对不对**。

本脚本按 PARAM_LAYOUT 自己切片，与 board_rom 里实际写出的值逐条比，
并对上游模型跑同一个脚本做正控：上游过不了，中文的结论一律不算数。

注意：它证明的是 (b)，不证明 (a)，也不证明模型能识别——那是准确率问题。

Usage
-----
  python tools/kws/verify_board_rom_slices.py \
      --label 上游 --params-rom <p> --quant <p> --board-rom <dir>
  python tools/kws/verify_board_rom_slices.py \
      --label 中文 --params-rom <p> --quant <p> --board-rom <dir> --json-out <p>
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import pathlib
import struct
import sys

LAYOUT = {"conv_w": (0, 640), "conv_b": (640, 32),
          "fc_w": (672, 16000), "fc_b": (16672, 16)}
# board_rom 各块：(行数, 位宽, 期望值数, pad 值)
BLOCKS = {"board_dw_w": (1024, 8, 640, 0),
          "board_fc_w": (16384, 8, 16000, 0),
          "board_bias": (1024, 32, 12, 0),
          "board_qmult": (1024, 32, 12, 1),
          "board_qshift": (1024, 32, 12, 0)}


def sha256(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def read_lines(p):
    return [t for t in pathlib.Path(p).read_text(encoding="ascii").split() if t]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", required=True)
    ap.add_argument("--params-rom", required=True)
    ap.add_argument("--quant", required=True)
    ap.add_argument("--board-rom", required=True)
    ap.add_argument("--json-out", default="")
    a = ap.parse_args()

    rom = pathlib.Path(a.params_rom).read_bytes()
    q = pathlib.Path(a.quant).read_bytes()
    rep = {"label": a.label,
           "params_rom": {"file": a.params_rom, "sha256": sha256(rom), "bytes": len(rom)},
           "quant": {"file": a.quant, "sha256": sha256(q), "bytes": len(q)},
           "checks": []}

    if len(rom) != 16688:
        rep["checks"].append({"id": "size", "verdict": "FAIL",
                              "detail": "params_rom 是 %d B，期望 16688" % len(rom)})
        return emit(rep, a.json_out, 2)

    # ---- 独立切片（不调用 mkhex_k4.py） ----
    # hex 文件里 int32 存的是 **2 的补码位模式**（如 -10 写成 fffffff6），
    # struct.unpack 给的是有符号值。不统一到无符号再比，每一个负数都会假报不符
    # ——上游正控第一次就是这么全红的，ROM 其实一个字节都没错。
    u32 = lambda vals: [v & 0xFFFFFFFF for v in vals]
    dw_w = list(rom[0:640])
    dw_b = u32(struct.unpack("<8i", rom[640:672]))
    fc_w = list(rom[672:16672])
    fc_b = u32(struct.unpack("<4i", rom[16672:16688]))
    allq = list(struct.unpack("<24i", q))
    mult, shift = u32(allq[0::2]), u32(allq[1::2])

    expect = {"board_dw_w": dw_w,
              "board_fc_w": fc_w,
              "board_bias": dw_b + fc_b,
              "board_qmult": mult,
              "board_qshift": shift}

    for name, (lines, width, nval, pad) in BLOCKS.items():
        p = pathlib.Path(a.board_rom) / (name + ".hex")
        if not p.is_file():
            rep["checks"].append({"id": name, "verdict": "FAIL", "detail": "文件不存在"})
            continue
        got = [int(t, 16) for t in read_lines(p)]
        exp = expect[name]
        problems = []
        if len(got) != lines:
            problems.append("行数 %d != %d" % (len(got), lines))
        # 数据段
        bad = [i for i in range(min(nval, len(got))) if got[i] != exp[i]]
        if bad:
            problems.append("数据段 %d/%d 处不符，首处 idx=%d got=%s exp=%s"
                            % (len(bad), nval, bad[0],
                               hex(got[bad[0]]), hex(exp[bad[0]])))
        # 填充段
        pads = got[nval:]
        badpad = [i for i, v in enumerate(pads) if v != pad]
        if badpad:
            problems.append("填充段 %d 处不是 %s，首处 idx=%d got=%s"
                            % (len(badpad), pad, badpad[0], hex(pads[badpad[0]])))
        ok = not problems
        rep["checks"].append({"id": name, "verdict": "PASS" if ok else "FAIL",
                              "detail": "; ".join(problems) if problems
                                        else "%d 值逐条相符 + %d 行填充=%s" % (nval, lines - nval, pad)})

    fails = [c for c in rep["checks"] if c["verdict"] == "FAIL"]
    rep["verdict"] = "PASS" if not fails else "FAIL"
    return emit(rep, a.json_out, 0 if not fails else 1)


def emit(rep, out_p, code):
    print(json.dumps(rep, ensure_ascii=False, indent=1))
    if out_p:
        with io.open(out_p, "w", encoding="utf-8", newline="\n") as f:
            json.dump(rep, f, ensure_ascii=False, indent=1)
            f.write("\n")
    print("\nverdict=%s" % rep["verdict"])
    return code


if __name__ == "__main__":
    sys.exit(main())
