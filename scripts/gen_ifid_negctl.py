# -*- coding: utf-8 -*-
"""生成 D-8 负向对照突变体：把 if_id 的 ready 改回恒 1（旧缺陷行为）。"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
src = (ROOT / "rtl/core/if_id.sv").read_text(encoding="utf-8")

anchor = "assign if_ready_o = (rst != `RstEnable) && !hold_if_id && !flush_if_id;"
assert src.count(anchor) == 1, "锚点不唯一，无法生成突变体"

mutant = src.replace(anchor, "assign if_ready_o = `True;  // NEGCTL D-8: 恒 1，hold 期间丢弃上游载荷")

out = ROOT / "verification/negctl/rtl/if_id_negctl_readyalways.sv"
out.write_text(mutant, encoding="utf-8")
print("生成", out.relative_to(ROOT), "行数 =", len(mutant.splitlines()))
