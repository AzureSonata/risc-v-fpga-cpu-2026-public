#!/usr/bin/env python3
"""regen_icache_off_tb.py —— 从 tb_perf_quadrant.sv 派生 IC=0/DC=0 回归 TB。

## 为什么需要

`ICACHE_ENABLE=0`（纯 bypass）这条路径在 2026-10-01 之前**从未被任何 TB 执行过**，
而它实际是**挂死的**（I 侧 `i_cv_req_ready` 取错源，被 `ICACHE_ENABLE=1` 默认配置完全掩盖）。
为把它纳入主回归守卫（`E:\\CPU\\AGENTS.md` §7.8「可配置开关必须被所有取值覆盖」），
把四象限 TB 的 parameter 默认值固定为 IC=0/DC=0，生成 `tb_icache_off_quadrant.sv`。

⚠️ 坑位：本脚本**必须用 Python 写文件**（显式 UTF-8、`newline=""`）。
  PowerShell 的 `Get-Content -Raw` 会按 cp936 猜编码毁掉中文注释并吞换行；
  `Set-Content -Encoding UTF8` 会写 BOM 让 Icarus 10.2 静默跳过整个 .sv（见 §7.7）。

用法：改完 `tb_perf_quadrant.sv` 后跑 `python scripts/regen_icache_off_tb.py`
"""
from __future__ import annotations

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SRC = REPO / "verification" / "system" / "tb_perf_quadrant.sv"
DST = REPO / "verification" / "system" / "tb_icache_off_quadrant.sv"

HEAD = """// ⚠️ 本文件由 verification/system/tb_perf_quadrant.sv **自动派生**（IC=0 / DC=0 固定），
//    目的：把 `ICACHE_ENABLE=0`（纯 bypass）这条**曾被默认配置完全掩盖**的路径
//    纳入 `run_tests.py` 的主回归守卫（AGENTS.md §7.8）。
//    改动请改源文件，然后跑：python scripts/regen_icache_off_tb.py
"""


def main() -> int:
    src = SRC.read_text(encoding="utf-8")
    a = "    parameter IC = 1'b1;"
    b = "    parameter DC = 1'b1;"
    for anchor in (a, b):
        n = src.count(anchor)
        if n != 1:
            print(f"  ❌ 锚点 {anchor!r} 出现 {n} 次（要求 1 次）—— 源文件已改，请更新本脚本")
            return 1
    t = src.replace(a, "    parameter IC = 1'b0;").replace(b, "    parameter DC = 1'b0;")
    t = t.replace("module tb_perf_quadrant;", "module tb_icache_off_quadrant;", 1)
    t = HEAD + t
    DST.write_text(t, encoding="utf-8", newline="")
    print(f"  🔧 已派生 {DST.name}（{len(t.splitlines())} 行，IC=0/DC=0）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
