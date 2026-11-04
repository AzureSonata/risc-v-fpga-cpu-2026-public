# -*- coding: utf-8 -*-
"""生成 **CSR / 同步异常接入路径** 的负向对照突变体。

与 `gen_csr_negctl.py`（只针对 csr_file 内部语义）分开：本脚本针对
"CPU 如何把 CSR 与同步异常接进流水线"这一层（cpu_core_stage1.sv / id_stage.sv）。

批 (a)：CSR 读写路径
  1) cpu_core_stage1_negctl_csrnostall.sv
     去掉 load-use 互锁里的 CSR 项。CSR 结果与 load 一样要到 WB 才存在，
     去掉互锁后 ID 期消费者不会推迟，EX 期拿不到 mw→EX 转发 →
     消费到**陈旧的寄存器值**。预期被测：tb_cpu_core_csr 的 T6（x12 = 5）。
  2) cpu_core_stage1_negctl_csrnowbdata.sv
     WB 回写与 mw→EX 转发退回 mw_data（不取 csr_rdata）→ CSR 读结果整条丢失。
     预期被测：tb_cpu_core_csr 的 T1 退休序列（CSR 结果的 rd_data）。
  3) id_stage_negctl_csrwealways.sv
     译码期把 CSR 写意图恒置 1（丢失 RV32I「CSRRS/C(SI/CI) 且 rs1/uimm=0
     时不写」的规则）。预期被测：tb_id_stage 的 Test 17 / Test 18。

批 (b)：同步异常精确陷阱
  4) cpu_core_stage1_negctl_csrwritableblind.sv
     EX/MEM 边界的非法判定漏掉"对只读 CSR 的写意图"（只留"未实现"）→
     写只读 CSR 被当成合法、不进入陷阱。预期被测：tb_cpu_core_trap 的 T5。
  5) cpu_core_stage1_negctl_trapnoredir.sv
     陷阱/mret 不再产生重定向 → 更年轻指令不被冲刷（**丧失精确性**）。
     预期被测：tb_cpu_core_trap 的"younger never retired"类断言。
  6) cpu_core_stage1_negctl_trapcauseswap.sv
     非对齐（cause 4/6）与访问故障（cause 5/7）互换。
     预期被测：tb_cpu_core_trap 的 T6–T9。
  7) cpu_core_stage1_negctl_trapnomret.sv
     mret 不再重定向到 mepc → 处理器无法返回。
     预期被测：tb_cpu_core_trap 的 T1（mret 往返）。

所有锚点必须**恰好命中一次**：源文件重构后立刻报错，绝不静默失效。
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "rtl/core/cpu_core_stage1.sv"
IDSTAGE = ROOT / "rtl/core/id_stage.sv"
OUT = ROOT / "verification/negctl/rtl"

MUTANTS = [
    (CORE, "cpu_core_stage1_negctl_csrnostall.sv",
     "        .ex_is_load((idex_instr[6:0] == 7'h03) || (idex_instr[6:0] == 7'h73)),\n",
     "        // NEGCTL：CSR 不再复用 load-use 互锁（消费者会拿到陈旧值）\n"
     "        .ex_is_load(idex_instr[6:0] == 7'h03),\n"),

    (CORE, "cpu_core_stage1_negctl_csrwritableblind.sv",
     "    assign xm_csr_bad = xm_csr_is_q && (!csr_chk_impl || (xm_csr_we_q && !csr_chk_wr));\n",
     "    // NEGCTL：漏掉「对只读 CSR 的写意图」，写只读 CSR 被静默接受\n"
     "    assign xm_csr_bad = xm_csr_is_q && !csr_chk_impl;\n"),

    (CORE, "cpu_core_stage1_negctl_trapnoredir.sv",
     "    assign redirect_valid  = ex_mispredict || sys_redir || sys_hold_q;\n",
     "    // NEGCTL：陷阱/mret 不再重定向 → 更年轻指令不被冲刷（丧失精确性）\n"
     "    assign redirect_valid  = ex_mispredict;\n"),

    (CORE, "cpu_core_stage1_negctl_trapcauseswap.sv",
     "            if (lsu_fault_misaligned)\n"
     "                xm_trap_cause = xm_mem_read ? 4'd4 : 4'd6;     // load/store address misaligned\n"
     "            else\n"
     "                xm_trap_cause = xm_mem_read ? 4'd5 : 4'd7;     // load/store access fault\n",
     "            // NEGCTL：非对齐与访问错误的 cause 互换\n"
     "            if (lsu_fault_misaligned)\n"
     "                xm_trap_cause = xm_mem_read ? 4'd5 : 4'd7;\n"
     "            else\n"
     "                xm_trap_cause = xm_mem_read ? 4'd4 : 4'd6;\n"),

    (CORE, "cpu_core_stage1_negctl_trapnomret.sv",
     "    assign sys_redir   = xm_trap_det || (xm_valid && xm_is_mret && !sys_hold_q);\n",
     "    // NEGCTL：mret 不再重定向到 mepc（处理器无法返回）\n"
     "    assign sys_redir   = xm_trap_det;\n"),

    (CORE, "cpu_core_stage1_negctl_csrnowbdata.sv",
     "    assign      mw_fwd_data = mw_csr_is_q ? csr_rdata : mw_data;\n",
     "    // NEGCTL：WB 回写/转发不用 csr_rdata，CSR 读结果被丢弃\n"
     "    assign      mw_fwd_data = mw_data;\n"),

    (IDSTAGE, "id_stage_negctl_csrwealways.sv",
     "    wire        csr_write_intent = csr_is_rw || (rs1 != 5'b0);\n",
     "    // NEGCTL：CSR 写意图恒为 1（丢失 rs1/uimm=x0/0 时 CSRRS/C 不写的规则）\n"
     "    wire        csr_write_intent = 1'b1;\n"),
]


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    rc = 0
    for src, name, anchor, repl in MUTANTS:
        text = src.read_text(encoding="utf-8")
        hits = text.count(anchor)
        if hits != 1:
            print("ERROR: %s 锚点在 %s 命中 %d 次（要求 1）" % (name, src.name, hits))
            rc = 1
            continue
        (OUT / name).write_text(text.replace(anchor, repl, 1), encoding="utf-8")
        print("生成 verification/negctl/rtl/" + name)
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
