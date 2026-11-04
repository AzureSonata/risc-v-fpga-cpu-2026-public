# -*- coding: utf-8 -*-
"""生成 csr_file 的五条负向对照突变体（锚点唯一性校验）。

对照 mipwritable ：mip 变为可写 —— 违反"MTIP/MEIP 由外部输入驱动、只读"。
                   预期被测：T7b（mip read-only）。
对照 irqungated  ：irq_pending 去掉 mstatus.MIE 门控 —— 中断在全局使能关闭时也会响应。
                   预期被测：T10 / T10e。
对照 mtvecdirect ：mtvec 不再强制 direct（MODE 原样保存）—— 违反冻结规格"mtvec direct"。
                   预期被测：T4。
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "rtl/core/csr_file.sv"
OUT = ROOT / "verification/negctl/rtl"

MUTATIONS = {
    "csr_file_negctl_mipwritable.sv": (
        "                CSR_MIP:\n"
        "                    // mip 的 MTIP/MEIP 由外部输入驱动，不可软写\n"
        "                    decode_addr = 2'b10;   // 已实现但只读\n",
        "                CSR_MIP:\n"
        "                    // NEGCTL: mip 变成可写\n"
        "                    decode_addr = 2'b11;\n",
    ),
    "csr_file_negctl_irqungated.sv": (
        "    assign irq_pending = mstatus_mie_q && (mei_en || mti_en);\n",
        "    // NEGCTL: 去掉 mstatus.MIE 门控\n"
        "    assign irq_pending = (mei_en || mti_en);\n",
    ),
    "csr_file_negctl_mtvecdirect.sv": (
        "                CSR_MTVEC:  mtvec_q <= {new_val[31:2], 2'b00};   // 只支持 direct（WARL）\n",
        "                CSR_MTVEC:  mtvec_q <= new_val;   // NEGCTL: 不强制 direct\n",
    ),
    "csr_file_negctl_losedualretire.sv": (
        "minstret_q <= minstret_q + {62'b0, retire_count};",
        "minstret_q <= minstret_q + {63'b0, retire_count[0]}; // NEGCTL: lose dual retire",
    ),
    "csr_file_negctl_countwrite.sv": (
        "minstret_q <= {minstret_q[63:32], new_val};",
        "minstret_q <= {minstret_q[63:32], new_val} + 64'd1; // NEGCTL: count CSR write again",
    ),
}

src = SRC.read_text(encoding="utf-8")
OUT.mkdir(parents=True, exist_ok=True)
for name, (anchor, repl) in MUTATIONS.items():
    n = src.count(anchor)
    assert n == 1, "%s 锚点命中 %d 次（要求 1）" % (name, n)
    (OUT / name).write_text(src.replace(anchor, repl, 1), encoding="utf-8", newline="\n")
    print("生成 verification/negctl/rtl/" + name)
