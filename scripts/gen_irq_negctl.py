#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 **机器中断接入路径**（批 (c)）的负向对照突变体。

与 `gen_csr_access_negctl.py`（批 (a) CSR 读写 / 批 (b) 同步异常）分开：
本脚本针对"中断如何接入 EX/MEM 采样判定"这一层（cpu_core_stage1.sv）。

批 (c)：机器中断（D12/D13/D14，ADR-CSR-ACCESS.md §6）
  1) cpu_core_stage1_negctl_irqnogie.sv
     去掉 mstatus.MIE 全局门控（csr_irq_cause 本身不含全局使能项，直接以
     |csr_irq_cause 作判据；cause 编码仍由 mie 门控，此处 pending 非零即 cause
     非零，违规可显现）→ 全局使能关闭时仍响应中断。
     预期被测：tb_cpu_core_irq 的 I2（MIE=0 场景必须捕获）。
  2) cpu_core_stage1_negctl_irqnomtie.sv
     去掉 mie.MTIE 位门控：**在 cause 通路**直通 mip.MTIP（MIE 门控与异常
     优先项保留，违规严格限定为"未使能源进中断"）。
     注意：不能只改 xm_irq_take 的 pending 项——csr_irq_cause 的编码仍被 mie
     门控（I3 场景 mie_q=0 → irq_cause=0 → cause32=0 永不进陷阱），突变体会
     行为惰性、负控假阴性（2026-09-29 首版实测 42/43 漏检的根因）。
     预期被测：tb_cpu_core_irq 的 I3（MTIE=0 场景必须捕获）。
  3) cpu_core_stage1_negctl_irqexcprior.sv
     中断抢在同步异常之前（优先级反转）：采样判据丢掉
     (xm_trap_cause == 4'd0) 项 → 同拍两者成立时选中中断源。
     预期被测：tb_cpu_core_irq 的 I4（ECALL+MTIP 同拍场景必须捕获）。

所有锚点必须**恰好命中一次**：源文件重构后立刻报错并不写出文件
（绝不静默失效，也不留下与源不匹配的旧突变体）。
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "rtl/core/cpu_core_stage1.sv"
OUT = ROOT / "verification/negctl/rtl"

IRQ_TAKE_ANCHOR = (
    "    assign xm_irq_take = xm_valid && !xm_memop && csr_irq_pending &&\n"
    "                         (xm_trap_cause == 4'd0) && !sys_hold_q;\n"
)
CAUSE32_ANCHOR = (
    "    assign xm_trap_cause32 = xm_irq_take ? csr_irq_cause : {28'b0, xm_trap_cause};\n"
)

MUTANTS = [
    ("cpu_core_stage1_negctl_irqnogie.sv",
     IRQ_TAKE_ANCHOR,
     "    // NEGCTL：去掉 mstatus.MIE 全局门控（irq_cause 本身不含全局使能项）——\n"
     "    // 全局使能关闭时仍响应中断，tb_cpu_core_irq 的 I2 必须捕获\n"
     "    assign xm_irq_take = xm_valid && !xm_memop && (|csr_irq_cause) &&\n"
     "                         (xm_trap_cause == 4'd0) && !sys_hold_q;\n"),

    ("cpu_core_stage1_negctl_irqnomtie.sv",
     CAUSE32_ANCHOR,
     "    // NEGCTL：去掉 mie.MTIE 位门控——未使能源的 cause 在采样判定处直通\n"
     "    // mip.MTIP（MIE 门控与异常优先项保留），tb_cpu_core_irq 的 I3 必须捕获。\n"
     "    // 注意：不能只改 xm_irq_take 的 pending 项——csr_irq_cause 的编码仍被\n"
     "    // mie 门控，突变体会行为惰性（见 gen_irq_negctl.py 头注）\n"
     "    assign xm_trap_cause32 = (xm_valid && !xm_memop && u_csr.mstatus_mie_q &&\n"
     "                              u_csr.mip[7] && (xm_trap_cause == 4'd0) &&\n"
     "                              !sys_hold_q) ? 32'h80000007\n"
     "                             : (xm_irq_take ? csr_irq_cause : {28'b0, xm_trap_cause});\n"),

    ("cpu_core_stage1_negctl_irqexcprior.sv",
     IRQ_TAKE_ANCHOR,
     "    // NEGCTL：中断抢在同步异常之前（优先级反转）——采样判据丢掉\n"
     "    // (xm_trap_cause == 4'd0) 项，同拍两者成立时选错源，I4 必须捕获\n"
     "    assign xm_irq_take = xm_valid && !xm_memop && csr_irq_pending && !sys_hold_q;\n"),
]


def main() -> int:
    src = CORE.read_text(encoding="utf-8")
    # 先**全量**校验锚点：任一失配即整体退出且不写任何文件（与 gen_ifstage_negctl.py
    # 同语义）。若按"失配跳过该条、继续写其余"，文件系统会留下部分再生的混合状态
    # ——漂移的旧突变体与新突变体共存，旧的可能行为惰性甚至造成负控误判。
    for name, anchor, _repl in MUTANTS:
        hits = src.count(anchor)
        if hits != 1:
            print("ERROR: %s 锚点在 cpu_core_stage1.sv 命中 %d 次（要求 1）；未写出任何文件"
                  % (name, hits))
            return 1
    OUT.mkdir(parents=True, exist_ok=True)
    for name, anchor, repl in MUTANTS:
        (OUT / name).write_text(src.replace(anchor, repl, 1), encoding="utf-8")
        print("生成 verification/negctl/rtl/" + name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
