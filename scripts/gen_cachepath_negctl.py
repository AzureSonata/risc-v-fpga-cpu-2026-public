#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 cache_path 的负向对照突变体（批 (d-1)，ADR-CACHE-INTEGRATION D-C2/D-C3）。

`cache_path` 是 (d-1)/(d-2) 接入的**路径选择与保持**承载模块：它单独不产生数据，
但它一旦选错路径或锁不住路径，(d-1)/(d-2) 的"绿"就建立在未验证的选择逻辑上。
故必须有独立的"违规必被抓"证明。两条对照（配合 tb_cpu_mem_subsystem 运行）：

  1) cache_path_negctl_nocache.sv
     `sel_cache_now` 恒 0（Cache 路径永不选中）⇒ 所有取指走 bypass。
     预期被测：T9（I-Cache 命中数 > 0）必须捕获 —— 否则"接入"只是摆设。

  2) cache_path_negctl_bypassall.sv
     路径判据被翻转：**可缓存地址反而走 bypass**（!cacheable 才进 Cache）。
     预期被测：T9/T10 必须捕获（命中数归零或缺失异常）。

语义：先**全量**校验所有锚点，任一命中数 != 1 即整体退出且**不写任何文件**
（与 gen_bridge_negctl.py / gen_ifstage_negctl.py / gen_irq_negctl.py 同模板）。
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "rtl/memory/cache_path.sv"
OUT = ROOT / "verification/negctl/rtl"

SEL_ANCHOR = "    wire sel_cache_now = cache_en && !up_write && cacheable;\n"

MUTANTS = [
    ("cache_path_negctl_nocache.sv",
     SEL_ANCHOR,
     "    // NEGCTL：Cache 路径永不选中（全部走 bypass）——\n"
     "    // I-Cache 命中数恒 0，T9 必须捕获\n"
     "    wire sel_cache_now = 1'b0;\n"),
    ("cache_path_negctl_bypassall.sv",
     SEL_ANCHOR,
     "    // NEGCTL：路径判据翻转（可缓存地址反而走 bypass）——\n"
     "    // 命中数归零/缺失异常，T9/T10 必须捕获\n"
     "    wire sel_cache_now = cache_en && !up_write && !cacheable;\n"),
]


def main() -> int:
    src = SRC.read_text(encoding="utf-8")
    # 全量预校验：任一锚点失配即整体退出、不写任何文件（防"部分再生"混合状态）
    for name, anchor, _repl in MUTANTS:
        hits = src.count(anchor)
        if hits != 1:
            print("ERROR: %s 锚点在 cache_path.sv 命中 %d 次（要求 1）；未写出任何文件"
                  % (name, hits))
            return 1
    OUT.mkdir(parents=True, exist_ok=True)
    for name, anchor, repl in MUTANTS:
        (OUT / name).write_text(src.replace(anchor, repl, 1), encoding="utf-8")
        print("生成 verification/negctl/rtl/" + name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
