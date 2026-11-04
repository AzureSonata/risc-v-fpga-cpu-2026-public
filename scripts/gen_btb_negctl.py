# -*- coding: utf-8 -*-
"""生成 BTB 恢复逻辑的负向对照突变体。

对照 nontrecover：在误预测判定里加上 `ex_branch_taken` 前置条件 ——
  即"只有实际 taken 才重定向"，这正是集成前的旧行为。
  它使 ADR §2.4 的**情形 3**（预测 taken 但实际 not taken）失去恢复：
  分支之后沿预测目标取入的错路指令不会被冲刷，会一路提交。
  预期被测：tb_cpu_core_btb 的 retire 序列（T3/T3b/T4）。
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "rtl/core/cpu_core_stage1.sv"
OUT = ROOT / "verification/negctl/rtl"

ANCHOR = ("    wire ex_mispredict = ex_valid && ex_branch_request && !xm_fault_q &&\n"
          "                         !xm_illegal_q && !sys_redir && !sys_hold_q &&\n"
          "                         (ex_next_pc != ex_pred_next);\n")
REPL = ("    // NEGCTL：移除情形 3 的恢复（只在实际 taken 时重定向，等于集成前的旧行为）\n"
        "    wire ex_mispredict = ex_valid && ex_branch_request && !xm_fault_q &&\n"
        "                         !xm_illegal_q && !sys_redir && !sys_hold_q &&\n"
        "                         ex_branch_taken && (ex_next_pc != ex_pred_next);\n")

src = SRC.read_text(encoding="utf-8")
assert src.count(ANCHOR) == 1, "锚点命中 %d 次（要求 1）" % src.count(ANCHOR)

OUT.mkdir(parents=True, exist_ok=True)
name = "cpu_core_stage1_negctl_nontrecover.sv"
(OUT / name).write_text(src.replace(ANCHOR, REPL, 1), encoding="utf-8")
print("生成 verification/negctl/rtl/" + name)
