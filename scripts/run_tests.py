#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
成员 A Stage1 前端模块回归测试脚本
自动编译并运行全部单元测试，汇总 PASS/FAIL 与断言数。

用法（任一）：
    python scripts/run_tests.py
    python scripts/run_tests.py --verbose
    python scripts/run_tests.py --negative-controls
环境要求：iverilog 与 vvp 在 PATH 中。
退出码：0 = 全部通过；1 = 编译/仿真/断言失败或缺少工具。
    --negative-controls 模式：注入历史缺陷，预期每个对照都 FAIL；
    全部被捕获则退出 0，任一漏检则退出 1。
"""
from pathlib import Path
import argparse
import os
import re
import shutil
import subprocess
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

REPO = Path(__file__).resolve().parents[1]
BUILD = REPO / "build"
RTL = REPO / "rtl"
RTL_CORE = REPO / "rtl" / "core"
VERIF = REPO / "verification"
VERIF_UNIT = REPO / "verification" / "unit"
NEGCTL_RTL = REPO / "verification" / "negctl" / "rtl"

# 内联锚点突变：不落盘突变体源码文件，而是在编译前按"唯一锚点"就地改写，
# 因此源文件一旦重构会立刻报 FAIL（锚点不唯一/找不到），不会静默失效。
# 机制来源：TASK-012（origin/task/TASK-012-stage1-pangu-integration），
# 于 2026-09-28 两线集成时并入本线。
INLINE_MUTATIONS = {
    # 名称: (锚点, 替换)
    "skiddrop": ("if (out_slot_free) begin",
                 "if (if_out_ready || !if_out_valid) begin"),
    "resetpol": (r"if (rst == `RstEnable) begin",
                 r"if (rst == `RstDisable) begin"),
    "hold_rsp": ("if (req_epoch == epoch) begin",
                 "if (req_epoch == epoch && !hold_if) begin"),
}

# (名称, RTL 文件列表, testbench 文件)
DCACHE_STORE_PATH_RTL = [
    "soc/addr_decode.sv", "soc/mem_map_adapter.sv", "soc/cpu_mem_subsystem.sv",
    "memory/rom.sv", "memory/sram.sv",
    "memory/icache.sv", "memory/dcache.sv",
    "memory/mem_burst_bridge.sv", "memory/cache_path.sv",
    "periph/gpio.sv", "periph/timer.sv", "periph/uart.sv",
]
DUAL_5STAGE_RTL = [
    "wide_fetch.sv", "branch_predictor.sv", "fetch_queue.sv", "id_stage.sv",
    "riscv_alu.sv", "regfile_4r2w.sv", "dual_commit.sv", "dual_retire_trace.sv",
    "csr_file.sv", "rv32im_unit.sv", "dual_pipeline_decode.sv",
    "dual_pipeline_execute.sv", "dual_issue_5stage_core.sv",
]
TESTS = [
    ("pc_reg",   ["pc_reg.sv"],                                     "tb_pc_reg.sv"),
    ("if_stage", ["if_stage.sv"],                                   "tb_if_stage.sv"),
    ("if_id",    ["if_id.sv"],                                      "tb_if_id.sv"),
    ("id_stage", ["id_stage.sv"],                                   "tb_id_stage.sv"),
    ("frontend", ["pc_reg.sv", "if_stage.sv", "if_id.sv", "id_stage.sv"], "tb_frontend.sv"),
    ("branch_predictor", ["branch_predictor.sv"], "tb_branch_predictor.sv"),
    ("branch_predictor_dual", ["branch_predictor.sv"], "tb_branch_predictor_dual.sv"),
    ("predictor_flow", ["branch_predictor.sv"], "tb_predictor_flow.sv"),
    ("random_delay", ["pc_reg.sv", "if_stage.sv", "if_id.sv"], "tb_random_delay.sv"),
    ("redirect_race", ["pc_reg.sv", "if_stage.sv"], "tb_redirect_race.sv"),
    ("payload_hold", ["pc_reg.sv", "if_stage.sv", "if_id.sv", "branch_predictor.sv"], "tb_payload_hold.sv"),
    ("reset_polarity", ["pc_reg.sv", "if_stage.sv", "if_id.sv"], "tb_reset_polarity.sv"),
    ("decode_matrix", ["id_stage.sv"], "tb_decode_matrix.sv"),
    ("predictor_gshare", ["branch_predictor.sv"], "tb_predictor_gshare.sv"),
    ("frontend_perf", ["id_stage.sv", "frontend_perf.sv"], "tb_frontend_perf.sv"),
    ("if_throughput", ["if_stage.sv", "frontend_perf.sv"], "tb_if_throughput.sv"),
    ("predictor_ras", ["branch_predictor.sv"], "tb_predictor_ras.sv"),
    # wb_trace：WB 副作用门（wb_stage）+ 退休 trace（retire_trace）。
    # Issue #15 第 5 项：retire/commit 此前**没有任何专用负向对照**（8 条 IF 负控全在前端），
    # 本套件此前也**未登记进主回归**（只能手工 iverilog）。登记后由
    # wb_stage_negctl_fireblind/x0write/trapwrite 与 retire_trace_negctl_validblind/dropx0
    # 五条负控证明"重复提交 / 漏提交 / valid=0 伪提交 / trap-x0 写门控"确实会被抓到。
    ("wb_trace", ["wb_stage.v", "retire_trace.v"], "tb_wb_trace.v"),
    # id_ex_reg：ID/EX 载荷寄存器。Issue #15 第 2 项后，ID 的 uses_rs1/uses_rs2 语义源
    # 随载荷寄存到这里；本套件守护其 capture / hold / flush / bubble 全生命周期
    # （新增字段若在 flush/hold/bubble 漏清或漏保持，会立刻变红）。
    ("id_ex_reg", ["id_ex_reg.v"], "tb_id_ex_reg.v"),
    # --- 以下三套随 2026-09-28 两线集成并入 ---
    # if_buffer_contract：TASK-012 的 IF 缓冲契约测试（响应与 hold 同拍等边界）
    ("if_buffer_contract", ["if_stage.sv"], "tb_if_buffer_contract.sv"),
    # if_id_hold_contract：D-8 回归 —— 用**真实 if_id** 驱动 if_out_ready，
    # 补上"级间握手信号必须在真实对端相连条件下验证"这一缺失环节
    ("if_id_hold_contract", ["pc_reg.sv", "if_stage.sv", "if_id.sv"],
     "tb_if_id_hold_contract.sv"),
    # periph：Stage2 外围 MMIO 从端（含窗口内偏移/只读拒写/未映射报错三项强制检查）
    ("periph", ["periph/uart.sv", "periph/gpio.sv", "periph/timer.sv"], "tb_periph.sv"),
    # csr：CSR 状态 + 精确 machine trap 状态迁移 + 中断判定（Stage2 CSR/异常/中断）
    ("csr", ["csr_file.sv"], "tb_csr.sv"),
    ("csr_counters", ["csr_file.sv"], "tb_csr_counters.sv"),
    # icache：I-Cache（2 KiB / 2 路 / 64 组 / 16 B 行 / 4 beat 突发填充）
    ("icache", ["memory/icache.sv"], "tb_icache.sv"),
    ("icache_wide", ["memory/icache.sv"], "tb_icache_wide.sv"),
    # sram：同步单端口 SRAM，覆盖全字、独立/混合字节掩码和零 strobe。
    ("sram", ["memory/sram.sv"], "tb_sram.sv"),
    # dcache：D-Cache（写穿 / 不写分配）
    ("dcache", ["memory/dcache.sv"], "tb_dcache.sv"),
    # cpu_mem_subsystem：CPU 单字端口 → memory-map adapter → ROM/SRAM 的接入验证
    ("cpu_mem_subsystem",
     ["pc_reg.sv", "branch_predictor.sv", "if_stage.sv", "if_id.sv", "id_stage.sv",
      "csr_file.sv",
      "id_ex_reg.v", "pipeline_control.v", "forwarding_unit.v", "hazard_detection.v",
      "riscv_alu.sv", "riscv_exec.sv", "rv32im_unit.sv", "riscv_lsu.sv", "regfile.v", "wb_stage.v",
      "retire_trace.v", "cpu_core_stage1.sv",
      "soc/addr_decode.sv", "soc/mem_map_adapter.sv", "soc/cpu_mem_subsystem.sv",
      "memory/rom.sv", "memory/sram.sv",
      "memory/icache.sv", "memory/dcache.sv",
      "memory/mem_burst_bridge.sv", "memory/cache_path.sv",
      "periph/gpio.sv", "periph/timer.sv",
      "periph/uart.sv"],
     "system/tb_cpu_mem_subsystem.sv"),
    # dcache_cpu_path：CPU 可见 D-Cache 路径（batch d-2 出口租约修订）。
    # 程序：冷 load → store → warm reload，要求 store 经 D-Cache 写穿并命中更新行。
    ("dcache_cpu_path",
     ["pc_reg.sv", "branch_predictor.sv", "if_stage.sv", "if_id.sv", "id_stage.sv",
      "csr_file.sv",
      "id_ex_reg.v", "pipeline_control.v", "forwarding_unit.v", "hazard_detection.v",
      "riscv_alu.sv", "riscv_exec.sv", "rv32im_unit.sv", "riscv_lsu.sv", "regfile.v", "wb_stage.v",
      "retire_trace.v", "cpu_core_stage1.sv",
      "soc/addr_decode.sv", "soc/mem_map_adapter.sv", "soc/cpu_mem_subsystem.sv",
      "memory/rom.sv", "memory/sram.sv",
      "memory/icache.sv", "memory/dcache.sv",
      "memory/mem_burst_bridge.sv", "memory/cache_path.sv",
      "periph/gpio.sv", "periph/timer.sv",
      "periph/uart.sv"],
     "system/tb_dcache_cpu_path.sv"),
    # dcache_store_path：D-Cache store/write-through 直达 D 接口回归。
    # 覆盖 store-hit、store-miss/no-write-allocate、部分 strobe、写 ROM error、
    # MMIO bypass、CPU response 背压；不实例化 CPU 核。
    ("dcache_store_path", DCACHE_STORE_PATH_RTL,
     "system/tb_dcache_store_path.sv"),
    # Posted-mode integration reuses the same scenarios with SRAM queue ACK enabled.
    ("dcache_store_path_posted", DCACHE_STORE_PATH_RTL,
     "system/tb_dcache_store_path.sv"),


    # dcache：D-Cache（写穿 / 不写分配）
    # mem_map：memory-map adapter + 真实 ROM/SRAM/外设构成的存储子系统
    ("mem_map", ["soc/addr_decode.sv", "soc/mem_map_adapter.sv",
                 "memory/rom.sv", "memory/sram.sv",
                 "periph/uart.sv", "periph/gpio.sv", "periph/timer.sv"],
     "tb_mem_map.sv"),
    # cpu_core_btb：完整 CPU + 分支预测器（系统级，覆盖 ADR §2.4 情形 1/3/4/5）
    ("cpu_core_btb", ["pc_reg.sv", "branch_predictor.sv", "if_stage.sv",
                      "if_id.sv", "id_stage.sv", "csr_file.sv", "id_ex_reg.v",
                      "pipeline_control.v", "forwarding_unit.v",
                      "hazard_detection.v", "riscv_alu.sv", "riscv_exec.sv",
                      "rv32im_unit.sv", "riscv_lsu.sv", "regfile.v", "wb_stage.v",
                      "retire_trace.v", "cpu_core_stage1.sv"],
     "system/tb_cpu_core_btb.sv"),
    # cpu_core_csr：完整 CPU + CSR 读写路径（批 (a)：译码 + 提交点读写，无陷阱）。
    # 逐条核对 18 条退休（程序不含陷阱指令 → 全程 trap=0）、CSR 写入恰好 6 次、
    # 错路 CSR 被冲刷不写、load→CSR 转发链、WARL(mtvec direct)。
    ("cpu_core_csr", ["pc_reg.sv", "branch_predictor.sv", "if_stage.sv",
                      "if_id.sv", "id_stage.sv", "csr_file.sv", "id_ex_reg.v",
                      "pipeline_control.v", "forwarding_unit.v",
                      "hazard_detection.v", "riscv_alu.sv", "riscv_exec.sv",
                      "rv32im_unit.sv", "riscv_lsu.sv", "regfile.v", "wb_stage.v",
                      "retire_trace.v", "cpu_core_stage1.sv"],
     "system/tb_cpu_core_csr.sv"),
    # cpu_core_trap：同步异常精确陷阱（批 (b)）。ECALL/EBREAK/非法指令/非法 CSR/
    # 非对齐 load,store/访存故障 load,store → cause/mepc/mtval；最老 fault 优先；
    # 更年轻指令无架构效果；处理器 + mret 往返；trap_enter 恰好一次。
    ("cpu_core_trap", ["pc_reg.sv", "branch_predictor.sv", "if_stage.sv",
                       "if_id.sv", "id_stage.sv", "csr_file.sv", "id_ex_reg.v",
                       "pipeline_control.v", "forwarding_unit.v",
                       "hazard_detection.v", "riscv_alu.sv", "riscv_exec.sv",
                       "rv32im_unit.sv", "riscv_lsu.sv", "regfile.v", "wb_stage.v",
                       "retire_trace.v", "cpu_core_stage1.sv"],
     "system/tb_cpu_core_trap.sv"),
    # cpu_core_irq：机器中断接入（批 (c)，ADR D12/D13/D14）。MTIP 真实路径：
    # 进入+mret 重试往返（退休序证明恰好一次）、mstatus.MIE/mie.MTIE 双层门控、
    # 异常优先于同拍中断（trap 拍采 mip 电平为证）、MTIP 随 timer_irq 电平撤销；
    # 中断退役事件在 trace_cause 上承载 bit31=1。
    ("cpu_core_irq", ["pc_reg.sv", "branch_predictor.sv", "if_stage.sv",
                      "if_id.sv", "id_stage.sv", "csr_file.sv", "id_ex_reg.v",
                      "pipeline_control.v", "forwarding_unit.v",
                      "hazard_detection.v", "riscv_alu.sv", "riscv_exec.sv",
                      "rv32im_unit.sv", "riscv_lsu.sv", "regfile.v", "wb_stage.v",
                      "retire_trace.v", "cpu_core_stage1.sv"],
     "system/tb_cpu_core_irq.sv"),
    # cpu_rv32im_irq_cancel：长延迟 DIV 遇到机器中断时取消并由 mret 重试；
    # 将 PR #49 独有的中断/MDU 交互测试纳入持续回归，避免只测 M 指令算术值。
    ("cpu_rv32im_irq_cancel", ["pc_reg.sv", "branch_predictor.sv", "if_stage.sv", "if_id.sv",
                               "id_stage.sv", "csr_file.sv", "id_ex_reg.v",
                               "pipeline_control.v", "forwarding_unit.v",
                               "hazard_detection.v", "riscv_alu.sv", "riscv_exec.sv",
                               "rv32im_unit.sv", "riscv_lsu.sv", "regfile.v", "wb_stage.v",
                               "retire_trace.v", "cpu_core_stage1.sv"],
     "system/tb_cpu_rv32im_irq_cancel.sv"),
    ("rv32im_unit", ["rv32im_unit.sv"], "unit/tb_rv32im_unit.sv"),
    ("dual_5stage_core", DUAL_5STAGE_RTL, "unit/tb_dual_5stage_core.sv"),
    ("dual_5stage_mdu_pair", DUAL_5STAGE_RTL, "unit/tb_dual_5stage_mdu_pair.sv"),
    ("dual_5stage_branch_pair", DUAL_5STAGE_RTL, "unit/tb_dual_5stage_branch_pair.sv"),
    ("dual_5stage_alias", DUAL_5STAGE_RTL, "unit/tb_dual_5stage_alias.sv"),
    ("dual_5stage_waw", DUAL_5STAGE_RTL, "unit/tb_dual_5stage_waw.sv"),
    # lsu：LSU 定向测试（原仅由 run_cpu_core_stage1.py 执行；批 (b) 起纳入主回归，
    # 以便新增的故障归因输出 fault_misaligned_o/fault_addr_o 被持续守护）
    ("lsu", ["riscv_lsu.sv"], "tb_lsu.sv"),
    ("lsu_registered_turnover", ["riscv_lsu.sv"], "tb_lsu_registered_turnover.sv"),
    # mem_burst_bridge：burst⇄单字转换桥（批 (d-0)，ADR-CACHE-INTEGRATION D-C4）。
    # 读方向 4 笔单字读→beat 流（顺序/last/逐 beat error 透传），写方向写穿透传
    # （恰好 1 笔请求、error 随接受沿回传）、双向背压、方向切换。
    ("mem_burst_bridge", ["memory/mem_burst_bridge.sv"], "tb_mem_burst_bridge.sv"),
    # Posted writes are isolated to the validated cacheable-SRAM integration;
    # this suite covers enqueue acknowledgement, FIFO order, backpressure and refill ordering.
    ("mem_burst_bridge_posted", ["memory/mem_burst_bridge.sv"], "tb_mem_burst_bridge_posted.sv"),
    # cache_path_exit：内存出口"登记式响应 + 独占保持"契约（ADR-MEM-EXIT-001，批 (d-2) 真根因）。
    # 下游（IF buf_full / 流水 hold / 重定向 drain）卡住时，adapter 响应仍必须被登记进 skid，
    # 不得被下游 ready 反压 —— 旧实现（adapter_rsp_ready 含 up_rsp_ready）在此永久死锁。
    ("cache_path_exit", ["memory/cache_path.sv"], "tb_cache_path_exit.sv"),
    # icache_off：`ICACHE_ENABLE=0`（纯 bypass）整链路守卫 —— AGENTS.md §7.8 的制度化。
    # ⚠️ 存在的理由：该"回退开关"在 2026-10-01 之前**从未被任何 TB 执行过**，
    #    实际是挂死的（I 侧的 `i_cv_req_ready` 取错源，被 `ICACHE_ENABLE=1` 的默认配置完全掩盖）。
    #    本套件把 IC=0/DC=0 固定下来跑同一段程序（结果须为 x1=252、inst=87），
    #    一旦该路径再退化就会立刻变红。
    #    派生自 tb_perf_quadrant.sv（改源文件后跑 scripts/regen_icache_off_tb.py 同步）。
    ("icache_off", [
        "core/pc_reg.sv", "core/branch_predictor.sv", "core/if_stage.sv", "core/if_id.sv",
        "core/id_stage.sv", "core/csr_file.sv", "core/id_ex_reg.v", "core/pipeline_control.v",
        "core/forwarding_unit.v", "core/hazard_detection.v", "core/riscv_alu.sv",
        "core/riscv_exec.sv", "core/rv32im_unit.sv", "core/riscv_lsu.sv", "core/regfile.v", "core/wb_stage.v",
        "core/retire_trace.v", "core/cpu_core_stage1.sv",
        "soc/addr_decode.sv", "soc/mem_map_adapter.sv", "soc/cpu_mem_subsystem.sv",
        "memory/rom.sv", "memory/sram.sv", "memory/icache.sv", "memory/dcache.sv",
        "memory/mem_burst_bridge.sv", "memory/cache_path.sv",
        "periph/gpio.sv", "periph/timer.sv", "periph/uart.sv",
    ], "system/tb_icache_off_quadrant.sv"),
    # ⚠️ pred_payload_stream：Gate #3（预测元数据随载荷）的**守卫**，2026-10-01 第 15 轮**已收口并登记**。
    # 正向：**8 PASS / 0 FAIL**；判据非空跑（元数据判据执行 64 次、其中"期望=1" **64 次**）；
    #   载荷流身份 `issued = delivered + 在库 − 窗口起点在库`（实测 902 = 900 + 2 − 0，在库取自 DUT）。
    # 鉴别力（§7.15，**相对基线**判定）：基线全绿下 4 个写点突变**全部捕获 4/4**
    #   （ifout_meta_lost / buf_meta_lost / ifout_taken_lost / ifout_target_lost）
    #   ⇒ 与"正向全绿"在**同一次构建**上同时成立 ⇒ 满足 §7.15 的守卫口径（此前两次分别只满足其一）。
    # 判据要点：**每 pc 的期望元数据三元组（valid/taken/target）取自 DUT 自己的
    #   `u_if.req_pc` + `u_if.req_pred_*` 寄存器对**（§7.1/§7.12）；只在 valid 一个字段上比对会
    #   漏掉 taken/target 的写点（实测：仅比 valid 时 2/4，补上 taken/target 后 4/4）。
    # 独立复跑：`python scripts/check_ifstage_mutants.py`（基线相对判定，退出码 0 = 至少一条被捕获）。
    ("pred_payload_stream", [
        "core/pc_reg.sv", "core/if_stage.sv", "core/if_id.sv", "core/branch_predictor.sv",
    ], "tb_pred_payload_stream.sv"),
    # --- M1 dual-issue building blocks (standalone unit tests) ---
    ("fetch_queue", ["fetch_queue.sv"], "tb_fetch_queue.sv"),
    ("fetch_queue_banked", ["fetch_queue.sv"], "tb_fetch_queue_banked.sv"),
    ("issue_arb", ["id_stage.sv", "issue_arb.sv"], "tb_issue_arb.sv"),
    ("regfile_4r2w", ["regfile_4r2w.sv"], "tb_regfile_4r2w.sv"),
    ("dual_alu_path",
     ["issue_arb.sv", "riscv_exec.sv", "riscv_alu.sv", "regfile_4r2w.sv", "dual_alu_path.sv"],
     "tb_dual_alu_path.sv"),
    ("dual_issue_mini_core",
     ["wide_fetch.sv", "fetch_queue.sv", "id_stage.sv", "issue_arb.sv",
      "riscv_exec.sv", "riscv_alu.sv", "regfile_4r2w.sv", "dual_alu_path.sv",
      "dual_commit.sv", "dual_retire_trace.sv", "dual_issue_mini_core.sv"],
     "tb_dual_issue_mini_core.sv"),
    ("dual_issue_mini_raw",
     ["wide_fetch.sv", "fetch_queue.sv", "id_stage.sv", "issue_arb.sv",
      "riscv_exec.sv", "riscv_alu.sv", "regfile_4r2w.sv", "dual_alu_path.sv",
      "dual_commit.sv", "dual_retire_trace.sv", "dual_issue_mini_core.sv"],
     "tb_dual_issue_mini_raw.sv"),
    ("dual_issue_mini_branch",
     ["wide_fetch.sv", "fetch_queue.sv", "id_stage.sv", "issue_arb.sv",
      "riscv_exec.sv", "riscv_alu.sv", "regfile_4r2w.sv", "dual_alu_path.sv",
      "dual_commit.sv", "dual_retire_trace.sv", "dual_issue_mini_core.sv"],
     "tb_dual_issue_mini_branch.sv"),
    ("dual_issue_mini_trap",
     ["wide_fetch.sv", "fetch_queue.sv", "id_stage.sv", "issue_arb.sv",
      "riscv_exec.sv", "riscv_alu.sv", "regfile_4r2w.sv", "dual_alu_path.sv",
      "dual_commit.sv", "dual_retire_trace.sv", "dual_issue_mini_core.sv"],
     "tb_dual_issue_mini_trap.sv"),
    ("dual_full_illegal",
     ["wide_fetch.sv", "branch_predictor.sv", "fetch_queue.sv", "id_stage.sv", "issue_arb.sv",
      "riscv_exec.sv", "riscv_alu.sv", "regfile_4r2w.sv", "dual_alu_path.sv",
      "dual_commit.sv", "dual_retire_trace.sv", "riscv_lsu.sv", "csr_file.sv",
      "dual_issue_full_core.sv", "rv32im_unit.sv"],
     "tb_dual_full_illegal.sv"),
    ("dual_full_redirect_pc4",
     ["wide_fetch.sv", "branch_predictor.sv", "fetch_queue.sv", "id_stage.sv", "issue_arb.sv",
      "riscv_exec.sv", "riscv_alu.sv", "regfile_4r2w.sv", "dual_alu_path.sv",
      "dual_commit.sv", "dual_retire_trace.sv", "riscv_lsu.sv", "csr_file.sv",
      "dual_issue_full_core.sv", "rv32im_unit.sv"],
     "tb_dual_full_redirect_pc4.sv"),
    ("dual_full_predictor_recovery",
     ["wide_fetch.sv", "branch_predictor.sv", "fetch_queue.sv", "id_stage.sv", "issue_arb.sv",
      "riscv_exec.sv", "riscv_alu.sv", "regfile_4r2w.sv", "dual_alu_path.sv",
      "dual_commit.sv", "dual_retire_trace.sv", "riscv_lsu.sv", "csr_file.sv",
      "dual_issue_full_core.sv", "rv32im_unit.sv"],
     "tb_dual_full_predictor_recovery.sv"),
    ("dual_full_lsu_branch_pair",
     ["wide_fetch.sv", "branch_predictor.sv", "fetch_queue.sv", "id_stage.sv", "issue_arb.sv",
      "riscv_exec.sv", "riscv_alu.sv", "regfile_4r2w.sv", "dual_alu_path.sv",
      "dual_commit.sv", "dual_retire_trace.sv", "riscv_lsu.sv", "csr_file.sv",
      "dual_issue_full_core.sv", "rv32im_unit.sv"],
     "tb_dual_full_lsu_branch_pair.sv"),
    ("dual_full_lsu_mem_turnover",
     ["wide_fetch.sv", "branch_predictor.sv", "fetch_queue.sv", "id_stage.sv", "issue_arb.sv",
      "riscv_exec.sv", "riscv_alu.sv", "regfile_4r2w.sv", "dual_alu_path.sv",
      "dual_commit.sv", "dual_retire_trace.sv", "riscv_lsu.sv", "csr_file.sv",
      "dual_issue_full_core.sv", "rv32im_unit.sv"],
     "tb_dual_full_lsu_mem_turnover.sv"),
    ("wide_fetch_protocol", ["wide_fetch.sv"], "tb_wide_fetch_protocol.sv"),
    ("wide_fetch_predict", ["wide_fetch.sv", "branch_predictor.sv"], "tb_wide_fetch_predict.sv"),
    # wide_fetch + 32-bit memory adapter 的端到端重定向/旧响应 drain 契约。
    ("wide_fetch_adapter_redirect_e2e",
     ["wide_fetch.sv", "memory/wide_imem_adapter.sv"],
     "tb_wide_fetch_adapter_redirect_e2e.sv"),
    ("dual_ifault_matrix",
     ["wide_fetch.sv", "branch_predictor.sv", "fetch_queue.sv", "id_stage.sv", "issue_arb.sv",
      "riscv_exec.sv", "riscv_alu.sv", "regfile_4r2w.sv", "dual_alu_path.sv",
      "dual_commit.sv", "dual_retire_trace.sv", "riscv_lsu.sv", "csr_file.sv",
      "dual_issue_full_core.sv", "rv32im_unit.sv"],
     "tb_dual_ifault_matrix.sv"),
    ("dual_mdu_recovery",
     ["wide_fetch.sv", "branch_predictor.sv", "fetch_queue.sv", "id_stage.sv", "issue_arb.sv",
      "riscv_exec.sv", "riscv_alu.sv", "regfile_4r2w.sv", "dual_alu_path.sv",
      "dual_commit.sv", "dual_retire_trace.sv", "riscv_lsu.sv", "csr_file.sv",
      "dual_issue_full_core.sv", "rv32im_unit.sv"],
     "tb_dual_mdu_recovery.sv"),
    ("dual_mdu_matrix",
     ["wide_fetch.sv", "branch_predictor.sv", "fetch_queue.sv", "id_stage.sv", "issue_arb.sv",
      "riscv_exec.sv", "riscv_alu.sv", "regfile_4r2w.sv", "dual_alu_path.sv",
      "dual_commit.sv", "dual_retire_trace.sv", "riscv_lsu.sv", "csr_file.sv",
      "dual_issue_full_core.sv", "rv32im_unit.sv"],
     "tb_dual_mdu_matrix.sv"),
    ("dual_issue_full_mem",
     ["wide_fetch.sv", "branch_predictor.sv", "fetch_queue.sv", "id_stage.sv", "issue_arb.sv",
      "riscv_exec.sv", "riscv_alu.sv", "regfile_4r2w.sv", "dual_alu_path.sv",
      "dual_commit.sv", "dual_retire_trace.sv", "riscv_lsu.sv", "csr_file.sv",
      "dual_issue_full_core.sv", "rv32im_unit.sv"],
     "tb_dual_full_mem.sv"),
    ("dual_issue_full_load_alu",
     ["wide_fetch.sv", "branch_predictor.sv", "fetch_queue.sv", "id_stage.sv", "issue_arb.sv",
      "riscv_exec.sv", "riscv_alu.sv", "regfile_4r2w.sv", "dual_alu_path.sv",
      "dual_commit.sv", "dual_retire_trace.sv", "riscv_lsu.sv", "csr_file.sv",
      "dual_issue_full_core.sv", "rv32im_unit.sv"],
     "tb_dual_full_load_alu.sv"),
    ("dual_issue_full_csr",
     ["wide_fetch.sv", "branch_predictor.sv", "fetch_queue.sv", "id_stage.sv", "issue_arb.sv",
      "riscv_exec.sv", "riscv_alu.sv", "regfile_4r2w.sv", "dual_alu_path.sv",
      "dual_commit.sv", "dual_retire_trace.sv", "riscv_lsu.sv", "csr_file.sv",
      "dual_issue_full_core.sv", "rv32im_unit.sv"],
     "tb_dual_full_csr.sv"),
    ("dual_issue_full_irq",
     ["wide_fetch.sv", "branch_predictor.sv", "fetch_queue.sv", "id_stage.sv", "issue_arb.sv",
      "riscv_exec.sv", "riscv_alu.sv", "regfile_4r2w.sv", "dual_alu_path.sv",
      "dual_commit.sv", "dual_retire_trace.sv", "riscv_lsu.sv", "csr_file.sv",
      "dual_issue_full_core.sv", "rv32im_unit.sv"],
     "tb_dual_full_irq.sv"),
     ("dual_full_load_irq_boundary",
      ["wide_fetch.sv", "branch_predictor.sv", "fetch_queue.sv", "id_stage.sv", "issue_arb.sv",
       "riscv_exec.sv", "riscv_alu.sv", "regfile_4r2w.sv", "dual_alu_path.sv",
       "dual_commit.sv", "dual_retire_trace.sv", "riscv_lsu.sv", "csr_file.sv",
       "dual_issue_full_core.sv", "rv32im_unit.sv"],
      "tb_dual_full_load_irq_boundary.sv"),
    ("dual_commit", ["dual_commit.sv"], "tb_dual_commit.sv"),
    ("dual_retire_trace", ["dual_retire_trace.sv"], "tb_dual_retire_trace.sv"),
    ("cpu_core_dual_stage",
     ["wide_fetch.sv", "fetch_queue.sv", "id_stage.sv", "issue_arb.sv",
      "riscv_exec.sv", "riscv_alu.sv", "regfile_4r2w.sv", "dual_alu_path.sv",
      "dual_commit.sv", "dual_retire_trace.sv", "dual_issue_mini_core.sv",
      "cpu_core_dual_stage.sv"],
     "tb_cpu_core_dual_stage.sv"),
    ("pangu100proplus_dual_top",
     ["wide_fetch.sv", "fetch_queue.sv", "id_stage.sv", "issue_arb.sv",
      "riscv_exec.sv", "riscv_alu.sv", "regfile_4r2w.sv", "dual_alu_path.sv",
      "dual_commit.sv", "dual_retire_trace.sv", "dual_issue_mini_core.sv",
      "cpu_core_dual_stage.sv", "memory/rom.sv", "memory/wide_rom.sv",
      "soc/pangu100proplus_dual_top.sv"],
     "tb_pangu100proplus_dual_top.sv"),
    ("pangu100proplus_dual_full_top",
     ["wide_fetch.sv", "branch_predictor.sv", "fetch_queue.sv", "id_stage.sv", "issue_arb.sv",
      "riscv_exec.sv", "riscv_alu.sv", "regfile_4r2w.sv", "dual_alu_path.sv",
      "dual_commit.sv", "dual_retire_trace.sv", "riscv_lsu.sv", "csr_file.sv",
      "dual_issue_full_core.sv", "rv32im_unit.sv", "memory/wide_imem_adapter.sv",
      "soc/addr_decode.sv", "soc/mem_map_adapter.sv", "soc/cpu_mem_subsystem.sv",
      "memory/rom.sv", "memory/sram.sv", "memory/icache.sv", "memory/dcache.sv",
      "memory/mem_burst_bridge.sv", "memory/cache_path.sv",
      "periph/gpio.sv", "periph/timer.sv", "periph/uart.sv",
      "soc/pangu100proplus_dual_full_top.sv"],
     "system/tb_pangu100proplus_dual_full_top.sv"),
    ("wide_rom", ["memory/rom.sv", "memory/wide_rom.sv"], "tb_wide_rom.sv"),
    ("wide_imem_adapter", ["memory/wide_imem_adapter.sv"], "tb_wide_imem_adapter.sv"),
]

# Icarus elaboration-time parameters for the one shared integration scenario.
IVERILOG_PARAMETER_OVERRIDES = {
    "dcache_store_path_posted": ["-Ptb_dcache_store_path.POSTED_SRAM_WRITE_ACK=1"],
}

# ── 独立套件（EXTRA_SUITES）：**不进默认回归**，必须用 `--only <名字>` 显式点名 ──
# 与 TESTS 的区别只有一条：它们的正向运行**当前不是绿的**（已知缺陷 / 待裁决），
# 因此不能混进默认回归去掩盖其它回归；但它们仍必须可被**一条命令**复现（§8：能脚本化就脚本化）。
# ⚠️ 坑位：本文件此前**没有** `--only` 开关，而日志/注释里却写了 `--only ...` 的跑法
#    ⇒ 照抄命令会拿到 `unrecognized arguments`，白烧一轮（§7 类"文档写了不存在的命令"）。
#    故此处同时**补齐开关**：`--only` 在 TESTS + EXTRA_SUITES 里按名字查找。
EXTRA_SUITES = [
    # 2026-10-01 第 15 轮：`pred_payload_stream` 收口后**已移入 TESTS**（守卫），此处暂时为空。
    # 保留本机制给"已知非绿/待裁决"的套件用（绿树不允许把已知 RED 混进默认回归掩盖其它回归）。
]

# 负向对照：(说明, 测试名, 突变体, vvp 附加参数)
# 每条对照向被测注入一种历史违规，预期该测试 FAIL（证明检查器能捕获它）。
# 突变为 str 时替换 if_stage.sv；为 dict 时形如 {原文件名: 突变体文件名}，
# 用于替换非 if_stage 的 RTL（如 id_stage.sv）。
NEGATIVE_CONTROLS = [
    ("零请求：存储器永不 ready（+negctl_zero_req）",
     "random_delay", None, ["+negctl_zero_req"]),
    ("孤立响应：无在途请求时完成握手（IDLE-ready 突变体 + 注入窗口）",
     "random_delay", "if_stage_negctl_orphan.sv", ["+negctl_orphan_rsp"]),
    ("outstanding>1：REQ 态 fire 同拍 redirect 回 IDLE 再发请求（随机回归 Phase 5）",
     "random_delay", "if_stage_negctl_double_req.sv", []),
    ("outstanding>1：同上突变体，确定化 redirect_race Test 2",
     "redirect_race", "if_stage_negctl_double_req.sv", []),
    ("响应同拍 redirect 搁浅：WAIT 态响应被消费后仍停 WAIT（30c8190 缺陷复现）",
     "redirect_race", "if_stage_negctl_strand.sv", []),
    ("载荷丢失：ready 恢复同拍新响应直写覆盖 buf 提升值（skid 突变体，Gate #3）",
     "payload_hold", "if_stage_negctl_skiddrop.sv", []),
    ("复位极性：低有效突变体，同步高有效契约被破坏必须 FAIL（Gate #4）",
     "reset_polarity", "if_stage_negctl_rstpol.sv", []),
    ("译码锁存：移除 illegal_instr_o 默认赋值，合法指令后输出保持陈旧值（D-1）",
     "id_stage", {"id_stage.sv": "id_stage_negctl_illegallatch.sv"}, []),
    ("译码空判据：还原 R 型 funct7=0100000 的恒假 funct3 检查，保留编码被误受（D-3）",
     "id_stage", {"id_stage.sv": "id_stage_negctl_funct3blind.sv"}, []),
    ("译码空判据（矩阵捕获）：同上突变体，由穷尽矩阵测试独立检出（D-3）",
     "decode_matrix", {"id_stage.sv": "id_stage_negctl_funct3blind.sv"}, []),
    ("移位立即数：仅比较 funct7[6:5] 两位，低 5 位非零的保留编码被误受（D-7）",
     "decode_matrix", {"id_stage.sv": "id_stage_negctl_shiftf7.sv"}, []),
    ("gshare 历史：GHR 永不更新，退化为纯 PC 索引（预测器阶段 D）",
     "predictor_gshare", {"branch_predictor.sv": "branch_predictor_negctl_noghr.sv"}, []),
    ("gshare 索引：预测索引不含 GHR，训练与预测索引不一致（预测器阶段 D）",
     "predictor_gshare", {"branch_predictor.sv": "branch_predictor_negctl_nogshareidx.sv"}, []),
    ("性能计数：分支计数未用 id_valid 门控，空泡被计入统计（阶段 E）",
     "frontend_perf", {"frontend_perf.sv": "frontend_perf_negctl_nogate.sv"}, []),
    ("性能计数：条件分支计数未区分指令类型，分类统计失真（阶段 E）",
     "frontend_perf", {"frontend_perf.sv": "frontend_perf_negctl_misclass.sv"}, []),
    ("RAS：压入的返回地址漏加 4，返回预测整体偏 4 字节（阶段 D4）",
     "predictor_ras", {"branch_predictor.sv": "branch_predictor_negctl_rasaddr.sv"}, []),
    # --- 以下四条随 2026-09-28 两线集成并入 ---
    ("IF/ID 握手（D-8）：ready 恒 1，hold 期间上游误判已取走并丢弃载荷",
     "if_id_hold_contract", {"if_id.sv": "if_id_negctl_readyalways.sv"}, []),
    ("IF 缓冲：缓冲指令提升与新响应同拍覆盖（TASK-012 锚点突变体）",
     "if_buffer_contract", "skiddrop", []),
    ("IF 缓冲：复位极性反转（TASK-012 锚点突变体）",
     "if_buffer_contract", "resetpol", []),
    ("IF 缓冲：响应与 hold 同拍丢载荷，已握手的响应未进入 IF 输出（TASK-012 锚点突变体）",
     "if_buffer_contract", "hold_rsp", []),
    # --- 以下两条为 memory-map adapter 的负向对照（2026-09-28） ---
    ("只读语义：移除 sel_rom&write 判定，写 ROM 被静默接受而非报 error",
     "mem_map", {"soc/mem_map_adapter.sv": "mem_map_adapter_negctl_romwriteok.sv"}, []),
    ("响应契约：error 待决期间 req_ready 仍为 1，后续请求被吞掉",
     "mem_map", {"soc/mem_map_adapter.sv": "mem_map_adapter_negctl_errswallow.sv"}, []),
    # --- BTB 恢复逻辑（2026-09-28）---
    ("BTB 情形3：只在实际 taken 时重定向，预测 taken 但实际不跳时错路指令得以提交",
     "cpu_core_btb",
     {"cpu_core_stage1.sv": "cpu_core_stage1_negctl_nontrecover.sv"}, []),
    # --- CSR 负向对照（2026-09-28）---
    ("CSR：mip 变成可写（MTIP/MEIP 应由外部输入驱动、只读）",
     "csr", {"csr_file.sv": "csr_file_negctl_mipwritable.sv"}, []),
    ("CSR：irq_pending 去掉 mstatus.MIE 门控，全局使能关闭时仍响应中断",
     "csr", {"csr_file.sv": "csr_file_negctl_irqungated.sv"}, []),
    ("CSR：mtvec 不再强制 direct，MODE 位原样保存（违反冻结规格）",
     "csr", {"csr_file.sv": "csr_file_negctl_mtvecdirect.sv"}, []),
    ("CSR counter: lose two-instruction retirement increment",
     "csr_counters", {"csr_file.sv": "csr_file_negctl_losedualretire.sv"}, []),
    ("CSR counter: explicit minstret write incorrectly increments again",
     "csr_counters", {"csr_file.sv": "csr_file_negctl_countwrite.sv"}, []),
    # --- I-Cache 负向对照（2026-09-28）---
    ("I-Cache：命中不更新 LRU，被命中的路仍可能被逐出（抖动）",
     "icache", {"memory/icache.sv": "icache_negctl_lruonhit.sv"}, []),
    ("I-Cache：突发出错仍分配行，后续访问命中垃圾行且 error=0（静默掩盖错误）",
     "icache", {"memory/icache.sv": "icache_negctl_alloconerr.sv"}, []),
    # --- D-Cache 负向对照（2026-09-28）---
    ("D-Cache：写穿错误被忽略、不上报给 CPU",
     "dcache", {"memory/dcache.sv": "dcache_negctl_wronerr.sv"}, []),
    ("D-Cache：更新行时忽略字节使能，整字覆盖（破坏未写字节）",
     "dcache", {"memory/dcache.sv": "dcache_negctl_bytemask.sv"}, []),
    # --- 接入层负向对照（2026-09-28）---
    ("地址图：SRAM 不再被译码，CPU 的 store/load 全部落到未映射 error",
     "cpu_mem_subsystem",
     {"soc/addr_decode.sv": "addr_decode_negctl_nosram.sv"}, []),
    # --- UART 接入负向对照（2026-09-28，步骤 27）---
    ("UART 接入：D 侧 UART 回退为 tie-off（TX 恒高），T8 必须捕获「无帧」",
     "cpu_mem_subsystem",
     {"soc/cpu_mem_subsystem.sv": "cpu_mem_subsystem_negctl_uarttie.sv"}, []),
    ("UART 接入：写数据恒 0（帧结构合法但内容错），T8 必须捕获「字节错」",
     "cpu_mem_subsystem",
     {"soc/cpu_mem_subsystem.sv": "cpu_mem_subsystem_negctl_wdata.sv"}, []),
    # --- CSR 接入负向对照（2026-09-28 步骤 28 批 (a)：译码 + CSR 读写路径）---
    ("CSR 接入：去掉 load-use 互锁里的 CSR 项，CSR 结果消费者拿到陈旧寄存器值",
     "cpu_core_csr",
     {"cpu_core_stage1.sv": "cpu_core_stage1_negctl_csrnostall.sv"}, []),
    ("CSR 接入：WB 回写/转发退回 mw_data（不取 csr_rdata），CSR 结果丢失",
     "cpu_core_csr",
     {"cpu_core_stage1.sv": "cpu_core_stage1_negctl_csrnowbdata.sv"}, []),
    ("译码：CSR 写意图恒为 1（丢失 CSRRS/C 且 rs1=uimm=0 时不写的规则）",
     "id_stage", {"id_stage.sv": "id_stage_negctl_csrwealways.sv"}, []),
    # --- 同步异常精确陷阱负向对照（2026-09-28 步骤 29 批 (b)）---
    ("精确陷阱：陷阱/mret 不产生重定向，更年轻指令不被冲刷（丧失精确性）",
     "cpu_core_trap",
     {"cpu_core_stage1.sv": "cpu_core_stage1_negctl_trapnoredir.sv"}, []),
    ("精确陷阱：漏掉「对只读 CSR 的写意图」，非法写被当成合法不进入陷阱",
     "cpu_core_trap",
     {"cpu_core_stage1.sv": "cpu_core_stage1_negctl_csrwritableblind.sv"}, []),
    ("精确陷阱：非对齐(4/6) 与 访问故障(5/7) 的 cause 互换",
     "cpu_core_trap",
     {"cpu_core_stage1.sv": "cpu_core_stage1_negctl_trapcauseswap.sv"}, []),
    ("精确陷阱：mret 不重定向到 mepc，处理器无法返回",
     "cpu_core_trap",
     {"cpu_core_stage1.sv": "cpu_core_stage1_negctl_trapnomret.sv"}, []),
    # --- 机器中断接入负向对照（2026-09-29 批 (c)，突变体由 scripts/gen_irq_negctl.py 生成）---
    ("中断接入：去掉 mstatus.MIE 全局门控，全局使能关闭仍响应中断（I2 捕获）",
     "cpu_core_irq",
     {"cpu_core_stage1.sv": "cpu_core_stage1_negctl_irqnogie.sv"}, []),
    ("中断接入：去掉 mie.MTIE 位门控，未使能的源也进中断（I3 捕获）",
     "cpu_core_irq",
     {"cpu_core_stage1.sv": "cpu_core_stage1_negctl_irqnomtie.sv"}, []),
    ("中断接入：中断抢在同步异常之前（优先级反转，同拍选错源）（I4 捕获）",
     "cpu_core_irq",
     {"cpu_core_stage1.sv": "cpu_core_stage1_negctl_irqexcprior.sv"}, []),
    # --- mem_burst_bridge 负向对照（批 (d-0)，突变体由 scripts/gen_bridge_negctl.py 生成）---
    ("桥：读 beat 的 error 被吞（恒 0），cache 拿到 error=0 的残行（T2 捕获）",
     "mem_burst_bridge",
     {"memory/mem_burst_bridge.sv": "mem_burst_bridge_negctl_errswallow.sv"}, []),
    ("桥：beat 计数错位，4 笔读请求全部命中 word0（填充行内容错位无 error）（T1 捕获）",
     "mem_burst_bridge",
     {"memory/mem_burst_bridge.sv": "mem_burst_bridge_negctl_beatfreeze.sv"}, []),
    # --- cache_path 负向对照（批 (d-1)，突变体由 scripts/gen_cachepath_negctl.py 生成）---
    # (d-1) 的承载模块：选错路径 ⇒ I-Cache 零命中；T9/T10 必须捕获
    ("接入失效：Cache 路径永不选中（I-Cache 命中数恒 0，T9 捕获）",
     "cpu_mem_subsystem",
     {"memory/cache_path.sv": "cache_path_negctl_nocache.sv"}, []),
    ("判据翻转：可缓存地址反而走 bypass（T9/T10 捕获）",
     "cpu_mem_subsystem",
     {"memory/cache_path.sv": "cache_path_negctl_bypassall.sv"}, []),
    # ADR-MEM-EXIT-001 E1：把出口响应消费恢复成"依赖下游 ready"的旧式实现
    # （= 批 (d-2) 死锁根因）。cache_path_exit 必须挂死 ⇒ 运行器判 sim timeout。
    ("出口反压：adapter 响应消费依赖下游 up_rsp_ready（旧式闭环，必须挂死）",
     "cache_path_exit",
     {"memory/cache_path.sv": "cache_path_negctl_rspbackpressure.sv"}, []),
    ("A2b 端口租用：后台 fill 未完成时 bypass 抢走 adapter 口（B4/B5 捕获）",
     "cache_path_exit",
     {"memory/cache_path.sv": "cache_path_negctl_busyignore.sv"}, []),
    # --- retire/commit 负向对照（Issue #15 第 5 项，2026-10-06）---
    # 被测套件 wb_trace（= wb_stage + retire_trace 单元 TB）。此前主回归的 8 条负控
    # 全在 IF/前端，"重复提交 / 漏提交 / valid=0 伪提交 / trap-x0 写门控"零覆盖。
    # 突变体由 regenerate_negctl.py 锚点表管理（唯一锚点 + 替换，禁止手工拷贝）。
    ("退休：忽略 commit_fire，保持中的载荷被重复提交（重复写寄存器）",
     "wb_trace", {"wb_stage.v": "wb_stage_negctl_fireblind.sv"}, []),
    ("退休：移除 x0 写门控，x0 被真正写入（架构状态被破坏）",
     "wb_trace", {"wb_stage.v": "wb_stage_negctl_x0write.sv"}, []),
    ("退休：移除 trap 写门控，陷阱指令仍写寄存器",
     "wb_trace", {"wb_stage.v": "wb_stage_negctl_trapwrite.sv"}, []),
    ("退休：忽略 retire_valid，valid=0 也产生 trace 事件与 order 递增（伪提交）",
     "wb_trace", {"retire_trace.v": "retire_trace_negctl_validblind.sv"}, []),
    ("退休：丢弃 rd=x0 的退休事件，合法指令漏提交、order 少递增一次",
     "wb_trace", {"retire_trace.v": "retire_trace_negctl_dropx0.sv"}, []),
    # --- Issue #15 第 4 项：backend_hold + redirect 整机联合契约 ---
    # 被测：cpu_core_trap 的 T13 判据（实测联合场景 2 拍，要求同拍 flush_id_ex）。
    ("联合场景：backend_hold 吞掉 redirect 的年轻冲刷（hold 赢 flush），T13 必须捕获",
     "cpu_core_trap",
     {"pipeline_control.v": "pipeline_control_negctl_holdwins.sv"}, []),
    # --- 双发射 M1 构件负向对照（2026-10-16）---
    ("取指队列：忽略 flush，陈旧指令仍可出队",
     "fetch_queue",
     {"fetch_queue.sv": "fetch_queue_negctl_noflush.sv"}, []),
    ("发射仲裁：组内 RAW/WAW 判据失效，依赖指令被同拍发射",
     "issue_arb",
     {"issue_arb.sv": "@inline:issue_arb_rawblind"}, []),
    ("发射仲裁：lane1 可在 lane0 未接受时单独发射",
     "issue_arb",
     {"issue_arb.sv": "@inline:issue_arb_lane1only"}, []),
    ("双退休：slot0 trap 不再优先，年轻 slot1 仍被提交",
     "dual_commit",
     {"dual_commit.sv": "dual_commit_negctl_trappriority.sv"}, []),
    ("双 trace：order 不递增，退休顺序不可追溯",
     "dual_retire_trace",
     {"dual_retire_trace.sv": "dual_retire_trace_negctl_noorder.sv"}, []),
    ("双发射非法队首：旧分类过滤令异常不可达",
     "dual_full_illegal", {"dual_issue_full_core.sv": "dual_full_negctl_dropillegal.sv"}, []),
    ("双发射跳转：旧实现丢弃目标PC[2]",
     "dual_full_redirect_pc4", {"wide_fetch.sv": "@inline:wide_fetch_drop_pc2"}, []),
    ("双发射缓存 store：独立 ALU 配对资格失效",
     "dual_issue_full_load_alu",
     {"dual_issue_full_core.sv": "@inline:dual_full_store_no_pair"}, []),
    ("双发射取指：旧实现拒收陈旧响应，严格从设备死锁",
     "wide_fetch_protocol", {"wide_fetch.sv": "wide_fetch_negctl_redirect.sv"}, []),
    # --- 双发射完整化负向对照（2026-10-17）---
    ("DCache refill：上游请求握手后撤回地址，填充仍必须读取原 cache line",
     "pangu100proplus_dual_full_top",
     {"memory/dcache.sv": "@inline:dcache_live_fill_addr"}, []),
    ("64/32 取指桥：新请求取消尚未握手的旧响应，违反背压保持",
     "wide_imem_adapter",
     {"memory/wide_imem_adapter.sv": "wide_imem_adapter_negctl_nostaleflush.sv"}, []),
]

# These mutants are derived from the current RTL text so interface evolution
# cannot leave a stale, uncompilable copy that is mistakenly counted as a hit.
INLINE_FILE_MUTATIONS = {
    "issue_arb_rawblind": (
        "core/issue_arb.sv",
        "!raw_rs1 && !raw_rs2 && !waw",
        "1'b1",
    ),
    "issue_arb_lane1only": (
        "core/issue_arb.sv",
        "assign issue1 = issue0 && s1_valid && pair_allowed;",
        "assign issue1 = s1_valid && pair_allowed;",
    ),
    "wide_fetch_drop_pc2": (
        "core/wide_fetch.sv",
        "pc_q <= {redirect_target[31:2], 2'b00};",
        "pc_q <= {redirect_target[31:3], 3'b000};",
    ),
    "dual_full_store_no_pair": (
        "core/dual_issue_full_core.sv",
        "wire d0_store_pairable = d0_is_mem && d0_mem_we && d0_load_aligned &&\n        d0_addr_in_cacheable_window;",
        "wire d0_store_pairable = 1'b0;",
    ),
    "dcache_live_fill_addr": (
        "memory/dcache.sv",
        "assign line_addr     = (state == S_FILL) ? fill_line_addr_q : {addr[31:4], 4'b0};",
        "assign line_addr     = {addr[31:4], 4'b0};",
    ),
}

PASS_RE = re.compile(r"^\s*PASS\b")
FAIL_RE = re.compile(r"^\s*FAIL\b")


def check_tools():
    ok = True
    for tool in ("iverilog", "vvp"):
        loc = shutil.which(tool)
        if loc:
            print(f"✅ {tool}: {loc}")
        else:
            print(f"❌ {tool} 未找到：请把 Icarus Verilog 的 bin 目录加入 PATH")
            ok = False
    return ok


def make_inline_mutant(name):
    """按 INLINE_MUTATIONS 的唯一锚点就地生成 if_stage 突变体。

    返回突变体路径；锚点出现次数 != 1 时返回 None（视为对照失效，必须显式报错，
    不得静默跳过——否则源文件重构后负向对照会悄悄失去意义）。
    """
    anchor, replacement = INLINE_MUTATIONS[name]
    source = (RTL_CORE / "if_stage.sv").read_text(encoding="utf-8")
    if source.count(anchor) != 1:
        print(f"  ❌ 锚点出现 {source.count(anchor)} 次（要求恰好 1 次）: {anchor!r}")
        return None
    mutant = BUILD / f"if_stage_negctl_{name}.sv"
    BUILD.mkdir(exist_ok=True)
    mutant.write_text(source.replace(anchor, replacement, 1), encoding="utf-8")
    return mutant


def make_inline_file_mutant(name):
    """Create a current-source mutation; an edited anchor invalidates the control."""
    relative, anchor, replacement = INLINE_FILE_MUTATIONS[name]
    source = (RTL / relative).read_text(encoding="utf-8")
    count = source.count(anchor)
    if count != 1:
        print(f"  ❌ inline mutation anchor appears {count} times (expected 1): {anchor!r}")
        return None
    mutant = BUILD / f"{Path(relative).stem}_negctl_{name}.sv"
    BUILD.mkdir(exist_ok=True)
    mutant.write_text(source.replace(anchor, replacement, 1), encoding="utf-8")
    return mutant


def run_test(name, rtl_files, tb_file, verbose=False, if_stage_override=None,
             extra_vvp_args=None, artifact_prefix="", negctl_rtl=None):
    print(f"\n{'='*50}\n  TEST: {name}\n{'='*50}")
    srcs = []
    for f in rtl_files:
        if negctl_rtl and f in negctl_rtl:
            mutant_source = negctl_rtl[f]
            if mutant_source.startswith("@inline:"):
                mutant = make_inline_file_mutant(mutant_source[len("@inline:"):])
                if mutant is None:
                    return {"name": name, "status": "FAIL", "pass": 0, "fail": 1,
                            "reason": "mutation anchor mismatch"}
                srcs.append(mutant)
            else:
                srcs.append(NEGCTL_RTL / mutant_source)
        elif if_stage_override and f == "if_stage.sv":
            if if_stage_override in INLINE_MUTATIONS:
                mutant = make_inline_mutant(if_stage_override)
                if mutant is None:
                    print(f"  ❌ 突变锚点不唯一或未找到：{if_stage_override}")
                    return {"name": name, "status": "FAIL", "pass": 0, "fail": 1,
                            "reason": "mutation anchor mismatch"}
                srcs.append(mutant)
            else:
                srcs.append(NEGCTL_RTL / if_stage_override)
        elif "/" in f:
            # 含子目录的源路径（如 "periph/uart.sv"）相对 rtl/ 解析
            srcs.append(RTL / f)
        else:
            srcs.append(RTL_CORE / f)
    # tb_file 含 "/" 时相对 verification/ 解析（如 "system/tb_cpu_core_btb.sv"）
    tb = (VERIF / tb_file) if "/" in tb_file else (VERIF_UNIT / tb_file)
    vvp_out = BUILD / f"{artifact_prefix}tb_{name}.svvp"

    cmd = ["iverilog", "-g2012", "-Wall",
           "-I", str(RTL_CORE), "-I", str(VERIF_UNIT),
           "-s", Path(tb_file).stem, "-o", str(vvp_out)] + \
          IVERILOG_PARAMETER_OVERRIDES.get(name, []) + \
          [str(s) for s in srcs] + [str(tb)]
    # ⚠️ 坑位：新增/改写任何 .sv 若带 UTF-8 BOM，Icarus 会**静默跳过整个文件**
    #    （症状：Unable to find the root module "tb_xxx"，且没有语法错误）
    #    ⇒ 根因：PowerShell 的 Set-Content -Encoding UTF8 会写 BOM
    #    ⇒ 正确做法：仓库文件只用编辑工具改，不用 PowerShell 重写；
    #       可用 `Get-Content <f> -Encoding Byte -TotalCount 3` 检查是否 EF BB BF
    #    （见 lessons/LESSON-001 附录 T3）
    print("  $ " + " ".join(cmd))

    try:
        r = subprocess.run(cmd, capture_output=True, text=True,
                           encoding="utf-8", errors="replace", timeout=60)
    except subprocess.TimeoutExpired:
        print("  ❌ COMPILE TIMEOUT")
        return {"name": name, "status": "FAIL", "pass": 0, "fail": 0, "reason": "compile timeout"}

    if r.returncode != 0:
        print(f"  ❌ COMPILE FAILED (exit={r.returncode})")
        for line in (r.stderr or "").splitlines()[-15:]:
            print("     " + line)
        return {"name": name, "status": "FAIL", "pass": 0, "fail": 0, "reason": "compile error"}

    vvp_cmd = ["vvp", str(vvp_out)] + list(extra_vvp_args or [])
    print("  $ " + " ".join(vvp_cmd))
    try:
        r2 = subprocess.run(vvp_cmd, capture_output=True, text=True,
                            encoding="utf-8", errors="replace", timeout=120)
    except subprocess.TimeoutExpired:
        print("  ❌ SIM TIMEOUT")
        return {"name": name, "status": "FAIL", "pass": 0, "fail": 0, "reason": "sim timeout"}

    output = (r2.stdout or "") + "\n" + (r2.stderr or "")
    lines = output.splitlines()
    n_pass = sum(1 for ln in lines if PASS_RE.match(ln))
    n_fail = sum(1 for ln in lines if FAIL_RE.match(ln))
    has_summary = ("ALL TESTS PASSED" in output) or ("ALL INTEGRATION TESTS PASSED" in output) \
        or ("ALL RANDOM DELAY TESTS PASSED" in output) or ("ALL REDIRECT RACE TESTS PASSED" in output) \
        or ("ALL PAYLOAD HOLD TESTS PASSED" in output) or ("ALL RESET POLARITY TESTS PASSED" in output) \
        or ("ALL IF BUFFER CONTRACT TESTS PASSED" in output) \
        or ("ALL WB TRACE TESTS PASSED" in output) \
        or ("ALL ID_EX_REG TESTS PASSED" in output) \
        or ("ALL TESTS PASS" in output)   # tb_lsu 的完成标记为 "ALL TESTS PASS (n passed)"
    timed_out = "TIMEOUT" in output and "TESTS PASSED" not in output

    if n_fail == 0 and n_pass > 0 and has_summary and not timed_out:
        status, reason = "PASS", ""
    else:
        status = "FAIL"
        if timed_out:
            reason = "simulation timeout"
        elif n_fail:
            reason = f"{n_fail} assertion(s) failed"
        elif not has_summary:
            reason = "no completion marker"
        else:
            reason = "no assertions observed"

    icon = "✅" if status == "PASS" else "❌"
    print(f"  → {icon} {status}  ({n_pass} PASS / {n_fail} FAIL)"
          + (f"  [{reason}]" if reason else ""))

    if verbose or status != "PASS":
        for line in lines[-25:]:
            if line.strip():
                print("    " + line)

    return {"name": name, "status": status, "pass": n_pass, "fail": n_fail, "reason": reason}


def run_negative_controls(verbose=False):
    """逐条注入历史违规，验证回归能捕获（测试必须 FAIL）。

    全部被捕获 => 返回 0；任一漏检（测试 PASS）=> 返回 1。
    这证明"违规 => run_tests.py 报 FAIL / 退出非零"这一性质本身成立。
    """
    print(f"\n{'#'*50}\n  NEGATIVE CONTROLS（负向对照：每个注入都必须被捕获）\n{'#'*50}")
    caught = 0
    missed = []
    for desc, name, mutant, extra_args in NEGATIVE_CONTROLS:
        print(f"\n--- 对照: {desc}")
        test = next(t for t in TESTS if t[0] == name)
        if isinstance(mutant, dict):
            overrides, if_ov = mutant, None
        else:
            overrides, if_ov = None, mutant
        r = run_test(name, test[1], test[2], verbose=verbose,
                     if_stage_override=if_ov, extra_vvp_args=extra_args,
                     artifact_prefix="negctl_", negctl_rtl=overrides)
        if r["status"] == "FAIL" and r["reason"] == "compile error":
            # 编译失败**不是捕获**：多半是突变体没随源再生（例如源文件被重构后
            # 锚点失配、或模块端口已变），此时"违规"根本没被注入到可运行的 RTL 里。
            # 必须显式报错，否则对照会变成假阳性（2026-09-28 批 (b) 实测踩到）。
            print("  ❌ 对照失效：突变体无法编译（多半未随源再生），不计入捕获")
            missed.append(desc + "（突变体编译失败，非断言捕获）")
        elif r["status"] == "FAIL":
            print(f"  ✅ 已捕获（测试按预期 FAIL：{r['reason'] or 'assertion(s) failed'}）")
            caught += 1
        else:
            print(f"  ❌ 漏检：注入违规后测试仍 PASS —— 检查器失效！")
            missed.append(desc)
    print(f"\n{'='*50}\n  NEGATIVE CONTROL SUMMARY\n{'='*50}")
    print(f"  捕获 {caught}/{len(NEGATIVE_CONTROLS)} 条注入违规")
    for m in missed:
        print(f"  ❌ 漏检: {m}")
    if not missed:
        print("  🎉 所有负向对照均被捕获：违规必然导致 FAIL / 退出非零")
    print("=" * 50)
    return 0 if not missed else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--verbose", action="store_true", help="打印每个测试的完整尾段输出")
    ap.add_argument("--negative-controls", action="store_true",
                    help="运行负向对照：注入历史缺陷，验证每个都使测试 FAIL（退出非零路径）")
    ap.add_argument("--only", metavar="NAME", default=None,
                    help="只跑指定套件（在 TESTS + EXTRA_SUITES 中按名字查找）。"
                         "用于跑未注册进默认回归的质量门，如 --only pred_payload_stream")
    args = ap.parse_args()

    print("🔧 成员 A Stage1 前端回归测试")
    print(f"   仓库: {REPO}")
    print(f"   构建: {BUILD}")

    if not check_tools():
        sys.exit(1)

    BUILD.mkdir(exist_ok=True)
    os.chdir(REPO)  # 相对 VCD dumpfile 路径依赖

    if args.negative_controls:
        sys.exit(run_negative_controls(args.verbose))

    if args.only:
        pool = TESTS + EXTRA_SUITES
        picked = [t for t in pool if t[0] == args.only]
        if not picked:
            print(f"  ❌ 找不到套件 '{args.only}'；可用名字："
                  + ", ".join(t[0] for t in pool))
            sys.exit(2)
        # ⚠️ 坑位：EXTRA_SUITES 是**已知非绿**的质量门，故这里**不**把"跑完"当成通过；
        #   退出码仍忠实反映该套件的 PASS/FAIL 计数（红就是红），供脚本/CI 判读。
        print(f"  [--only {args.only}] 单套件模式（EXTRA_SUITES 成员当前预期为 RED）")
        results = [run_test(n, rtl, tb, args.verbose) for n, rtl, tb in picked]
    else:
        results = [run_test(n, rtl, tb, args.verbose) for n, rtl, tb in TESTS]

    print(f"\n{'='*50}\n  REGRESSION SUMMARY\n{'='*50}")
    total_p = sum(r["pass"] for r in results)
    total_f = sum(r["fail"] for r in results)
    all_pass = True
    for r in results:
        icon = "✅" if r["status"] == "PASS" else "❌"
        print(f"  {icon} {r['name']:<9} {r['pass']:>3} PASS / {r['fail']} FAIL"
              + (f"  [{r['reason']}]" if r["reason"] else ""))
        if r["status"] != "PASS":
            all_pass = False
    print(f"  {'-'*46}")
    print(f"  合计: {total_p} PASS / {total_f} FAIL")
    print()
    print("  🎉 ALL TESTS PASSED" if all_pass else "  ⚠️  SOME TESTS FAILED")
    print("=" * 50)
    sys.exit(0 if all_pass else 1)


if __name__ == "__main__":
    main()
