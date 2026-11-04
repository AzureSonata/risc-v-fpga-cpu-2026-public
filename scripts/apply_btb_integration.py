# -*- coding: utf-8 -*-
"""BTB 集成补丁（一次性、幂等、带锚点唯一性校验）。

依据 docs/architecture/ADR-BTB-INTEGRATION.md §2：
  1. if_stage：把"取指时对该 PC 的预测"随在途请求一起锁存，并透出给 IF/ID。
  2. cpu_core_stage1：例化 branch_predictor，接线：取指侧选预测目标、EX 侧训练与双向恢复。
     恢复用「实际下一条 PC」与「预测导致的下一条 PC」直接比较（统一覆盖 ADR §2.4 的 5 种情形）。
  3. 其余 if_stage 例化统一补 `.pred_hit_i/taken/target = 0`（工具不支持端口默认值）。

用法：python scripts/apply_btb_integration.py [--check]
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IF_STAGE = ROOT / "rtl/core/if_stage.sv"
CORE = ROOT / "rtl/core/cpu_core_stage1.sv"

# ---------------------------------------------------------------------------
# 1) if_stage.sv
# ---------------------------------------------------------------------------
IF_EDITS = [
    # 端口：查询结果输入
    (
        "    input  wire         i_rsp_error,\n    output reg          if_out_valid,\n",
        "    input  wire         i_rsp_error,\n"
        "\n"
        "    // BTB 查询结果（对**本拍正在取指的 pc**）。必须随在途请求锁存，\n"
        "    // 不能用\"响应到达时按 if_pc 重查 BTB\"代替：表项可能在取指与交付之间被训练改写，\n"
        "    // 重查结果与实际取指决策不一致会让恢复逻辑漏掉必需的 redirect。\n"
        "    // 见 docs/architecture/ADR-BTB-INTEGRATION.md §2.2\n"
        "    input  wire         pred_hit_i,\n"
        "    input  wire         pred_taken_i,      // = pred_hit_i && q_taken\n"
        "    input  wire [31:0]  pred_target_i,\n"
        "\n"
        "    output reg          if_out_valid,\n",
    ),
    # 端口：随指令透出的预测
    (
        "    output reg          if_out_fault\n);\n",
        "    output reg          if_out_fault,\n"
        "    output reg          if_out_pred_valid,\n"
        "    output reg          if_out_pred_taken,\n"
        "    output reg  [31:0]  if_out_pred_target\n);\n",
    ),
    # 寄存器
    (
        "    reg        buf_fault;\n",
        "    reg        buf_fault;\n"
        "    // 在途请求携带的预测（与 req_pc/req_epoch 同级）\n"
        "    reg        req_pred_valid, req_pred_taken;\n"
        "    reg [31:0] req_pred_target;\n"
        "    // skid 缓冲携带的预测\n"
        "    reg        buf_pred_valid, buf_pred_taken;\n"
        "    reg [31:0] buf_pred_target;\n",
    ),
    # 复位
    (
        "            buf_fault    <= 1'b0;\n        end else begin\n",
        "            buf_fault    <= 1'b0;\n"
        "            if_out_pred_valid  <= 1'b0;\n"
        "            if_out_pred_taken  <= 1'b0;\n"
        "            if_out_pred_target <= `ZeroWord;\n"
        "            buf_pred_valid     <= 1'b0;\n"
        "            buf_pred_taken     <= 1'b0;\n"
        "            buf_pred_target    <= `ZeroWord;\n"
        "        end else begin\n",
    ),
    # redirect / flush：连预测 valid 一起清
    (
        "                if_out_valid <= 1'b0;\n                buf_valid   <= 1'b0;\n",
        "                if_out_valid      <= 1'b0;\n"
        "                buf_valid         <= 1'b0;\n"
        "                if_out_pred_valid <= 1'b0;\n"
        "                buf_pred_valid    <= 1'b0;\n",
    ),
    # 输出握手：buf -> if_out 时预测同步搬运
    (
        "            if (if_out_valid && if_out_ready) begin\n"
        "                if (buf_valid) begin\n"
        "                    if_out_valid <= 1'b1;\n"
        "                    if_out_pc    <= buf_pc;\n"
        "                    if_out_inst  <= buf_inst;\n"
        "                    if_out_fault <= buf_fault;\n"
        "                    buf_valid    <= 1'b0;\n"
        "                end else begin\n"
        "                    if_out_valid <= 1'b0;\n"
        "                end\n"
        "            end\n",
        "            if (if_out_valid && if_out_ready) begin\n"
        "                if (buf_valid) begin\n"
        "                    if_out_valid       <= 1'b1;\n"
        "                    if_out_pc          <= buf_pc;\n"
        "                    if_out_inst        <= buf_inst;\n"
        "                    if_out_fault       <= buf_fault;\n"
        "                    if_out_pred_valid  <= buf_pred_valid;\n"
        "                    if_out_pred_taken  <= buf_pred_taken;\n"
        "                    if_out_pred_target <= buf_pred_target;\n"
        "                    buf_valid          <= 1'b0;\n"
        "                    buf_pred_valid     <= 1'b0;\n"
        "                end else begin\n"
        "                    if_out_valid      <= 1'b0;\n"
        "                    if_out_pred_valid <= 1'b0;\n"
        "                end\n"
        "            end\n",
    ),
    # IDLE -> REQ：锁存在途标签时同时锁存预测
    (
        "                            // 请求由组合逻辑在进入 REQ 后呈现；此处只锁存在途标签\n"
        "                            req_pc      <= pc;\n"
        "                            req_epoch   <= epoch;\n",
        "                            // 请求由组合逻辑在进入 REQ 后呈现；此处只锁存在途标签\n"
        "                            req_pc         <= pc;\n"
        "                            req_epoch      <= epoch;\n"
        "                            req_pred_valid <= pred_hit_i;\n"
        "                            req_pred_taken <= pred_taken_i;\n"
        "                            req_pred_target<= pred_target_i;\n",
    ),
    # WAIT：响应装载到 if_out / buf 时预测一起装载
    (
        "                                if (out_slot_free) begin\n"
        "                                    if_out_valid <= 1'b1;\n"
        "                                    if_out_pc    <= req_pc;\n"
        "                                    if_out_inst  <= i_rsp_data;\n"
        "                                    if_out_fault <= i_rsp_error;\n"
        "                                end else begin\n"
        "                                    buf_valid <= 1'b1;\n"
        "                                    buf_pc    <= req_pc;\n"
        "                                    buf_inst  <= i_rsp_data;\n"
        "                                    buf_fault <= i_rsp_error;\n"
        "                                end\n",
        "                                if (out_slot_free) begin\n"
        "                                    if_out_valid       <= 1'b1;\n"
        "                                    if_out_pc          <= req_pc;\n"
        "                                    if_out_inst        <= i_rsp_data;\n"
        "                                    if_out_fault       <= i_rsp_error;\n"
        "                                    if_out_pred_valid  <= req_pred_valid;\n"
        "                                    if_out_pred_taken  <= req_pred_taken;\n"
        "                                    if_out_pred_target <= req_pred_target;\n"
        "                                end else begin\n"
        "                                    buf_valid       <= 1'b1;\n"
        "                                    buf_pc          <= req_pc;\n"
        "                                    buf_inst        <= i_rsp_data;\n"
        "                                    buf_fault       <= i_rsp_error;\n"
        "                                    buf_pred_valid  <= req_pred_valid;\n"
        "                                    buf_pred_taken  <= req_pred_taken;\n"
        "                                    buf_pred_target <= req_pred_target;\n"
        "                                end\n",
    ),
    # WAIT：续发新事务时同时锁存其预测
    (
        "                                req_pc    <= pc;\n                                req_epoch <= epoch;\n",
        "                                req_pc         <= pc;\n"
        "                                req_epoch      <= epoch;\n"
        "                                req_pred_valid <= pred_hit_i;\n"
        "                                req_pred_taken <= pred_taken_i;\n"
        "                                req_pred_target<= pred_target_i;\n",
    ),
]

# ---------------------------------------------------------------------------
# 2) cpu_core_stage1.sv
# ---------------------------------------------------------------------------
CORE_EDITS = [
    # 参数 + 声明
    (
        "    wire id_pred_valid, id_pred_taken;\n    wire [31:0] id_pred_target;\n",
        "    wire id_pred_valid, id_pred_taken;\n"
        "    wire [31:0] id_pred_target;\n"
        "\n"
        "    // ---- BTB 集成新增信号（ADR-BTB-INTEGRATION.md）----\n"
        "    wire        if_pred_valid, if_pred_taken;\n"
        "    wire [31:0] if_pred_target;\n"
        "    wire        idex_pred_valid, idex_pred_taken;\n"
        "    wire [31:0] idex_pred_target;\n"
        "    wire        btb_q_hit, btb_q_taken;\n"
        "    wire [31:0] btb_q_target;\n"
        "    wire        btb_pred_valid = BTB_ENABLE && btb_q_hit && btb_q_taken;\n"
        "    wire [31:0] btb_stat_query, btb_stat_hit, btb_stat_mispredict;\n"
        "    // riscv_exec 的 branch_source_o 在集成前是**未连接**的（悬空 z）。恢复逻辑用它\n"
        "    // 作为\"实际下一条 PC\"的基准，必须接出——否则 ex_pred_next = z+4 = x，\n"
        "    // 会让 redirect_valid 变 x 并直接挂死流水线（2026-09-28 实测踩坑）。\n"
        "    wire [31:0] ex_branch_source;\n",
    ),
    # 接出 branch_source_o（原来写的是空连接）
    (
        ".branch_source_o(), .branch_call_o(),",
        ".branch_source_o(ex_branch_source), .branch_call_o(),",
    ),
    # pc_reg：预测目标进入 PC 选择
    (
        ".pred_valid(1'b0), .pred_target(32'b0),",
        ".pred_valid(btb_pred_valid), .pred_target(btb_q_target),",
    ),
    # if_stage：查询结果输入 + 预测透出
    (
        "        .if_out_valid(if_valid), .if_out_ready(if_ready), .if_out_pc(if_pc),\n"
        "        .if_out_inst(if_instr), .if_out_fault(if_fault)\n"
        "    );\n",
        "        .pred_hit_i(btb_q_hit), .pred_taken_i(btb_pred_valid),\n"
        "        .pred_target_i(btb_q_target),\n"
        "        .if_out_valid(if_valid), .if_out_ready(if_ready), .if_out_pc(if_pc),\n"
        "        .if_out_inst(if_instr), .if_out_fault(if_fault),\n"
        "        .if_out_pred_valid(if_pred_valid), .if_out_pred_taken(if_pred_taken),\n"
        "        .if_out_pred_target(if_pred_target)\n"
        "    );\n",
    ),
    # if_id：预测字段由常量改为真实信号
    (
        "        .if_pred_valid_i(1'b0), .if_pred_taken_i(1'b0),\n"
        "        .if_pred_target_i(32'b0), .hold_if_id(if_id_hold),\n",
        "        .if_pred_valid_i(if_pred_valid), .if_pred_taken_i(if_pred_taken),\n"
        "        .if_pred_target_i(if_pred_target), .hold_if_id(if_id_hold),\n",
    ),
    # id_ex_reg：接出预测字段
    (
        "        .out_illegal(idex_illegal), .out_pred_valid(), .out_pred_taken(),\n        .out_pred_target()\n",
        "        .out_illegal(idex_illegal), .out_pred_valid(idex_pred_valid),\n"
        "        .out_pred_taken(idex_pred_taken), .out_pred_target(idex_pred_target)\n",
    ),
    # 恢复逻辑：统一比较「实际下一条 PC」与「预测导致的下一条 PC」
    (
        "    assign redirect_valid = ex_branch_request && ex_branch_taken && ex_valid &&\n"
        "                            !xm_fault_q && !xm_illegal_q;\n"
        "    assign redirect_target = ex_branch_pc;\n",
        "    // ------------------------------------------------------------------\n"
        "    // BTB 集成的误预测恢复（ADR-BTB-INTEGRATION.md §2.3/§2.4）\n"
        "    // ------------------------------------------------------------------\n"
        "    // riscv_exec 的全部输出都是寄存器，且其输入为 (idex_* 上一拍)。\n"
        "    // 而 xm_fault_q/xm_illegal_q 同样寄存自 idex_*（cpu_core_stage1.sv 内），\n"
        "    // xm_valid 是 ex_valid 的组合别名 —— 因此它们与 ex_* **同拍对位**，\n"
        "    // 既有护栏可以原样保留。\n"
        "    //\n"
        "    // ex_branch_pc 的语义（见 riscv_exec.sv: branch_taken ? target : pc_i+4）\n"
        "    // 正是\"实际下一条 PC\"，因此只需与\"预测导致的下一条 PC\"直接比较，\n"
        "    // 即可统一覆盖全部 5 种情形（含\"预测 taken 但实际不跳\"这一旧代码没有的情形）：\n"
        "    //   1 预测 taken & 目标一致 & 实际 taken -> 相等 -> 不 redirect（收益来源）\n"
        "    //   2 预测 taken & 目标不同   & 实际 taken -> 不等 -> redirect 到实际目标\n"
        "    //   3 预测 taken & 实际 not taken           -> 不等 -> redirect 到 pc+4\n"
        "    //   4 未预测 taken & 实际 taken             -> 不等 -> redirect 到实际目标\n"
        "    //   5 未预测 taken & 实际 not taken         -> 相等 -> 不 redirect\n"
        "    wire [31:0] ex_pred_next = ex_pred_taken_q ? ex_pred_target_q\n"
        "                                              : (ex_branch_source + 32'd4);\n"
        "    wire [31:0] ex_next_pc   = ex_branch_pc;\n"
        "\n"
        "    wire ex_mispredict = ex_valid && ex_branch_request && !xm_fault_q &&\n"
        "                         !xm_illegal_q && (ex_next_pc != ex_pred_next);\n"
        "\n"
        "    assign redirect_valid  = ex_mispredict;\n"
        "    assign redirect_target = ex_next_pc;\n"
        "\n"
        "    // 预测元数据影子：必须与 riscv_exec 的寄存块逐条件对齐\n"
        "    // （复位清 0 / valid_i && ~hold 装载 / ~hold 清 0；hold 时保持不变）。\n"
        "    // 失步会让上面的比较错位一条指令，从而可能漏掉必需的 redirect。\n"
        "    reg ex_pred_valid_q, ex_pred_taken_q;\n"
        "    reg [31:0] ex_pred_target_q;\n"
        "    always @(posedge clk) begin\n"
        "        if (rst) begin\n"
        "            ex_pred_valid_q  <= 1'b0;\n"
        "            ex_pred_taken_q  <= 1'b0;\n"
        "            ex_pred_target_q <= 32'b0;\n"
        "        end else if (!backend_hold) begin\n"
        "            ex_pred_valid_q  <= idex_valid && !redirect_valid && idex_pred_valid;\n"
        "            ex_pred_taken_q  <= idex_pred_taken;\n"
        "            ex_pred_target_q <= idex_pred_target;\n"
        "        end\n"
        "    end\n",
    ),
    # 预测器例化
    (
        "    // IF/ID is a valid-holding register, while this draft front end does not\n",
        "    // ------------------------------------------------------------------\n"
        "    // 分支预测器（64 项直接映射 BTB + 每项 2-bit 饱和计数器；默认参数即基线规格）\n"
        "    // ------------------------------------------------------------------\n"
        "    // 取指侧查询用**当前 pc**，与 if_stage 内锁存的标签同源；\n"
        "    // 训练用 EX 已解析的结果，且与影子寄存器同拍对位。\n"
        "    // u_is_call/u_is_ret 暂接 0：RAS 默认关闭（RAS_ENABLE=0），\n"
        "    // 待启用 RAS 时再接 ex_branch_call / ex_branch_ret（见 ADR §2.4 备注）。\n"
        "    branch_predictor u_btb (\n"
        "        .clk(clk), .rst(rst),\n"
        "        .q_valid(advance_valid), .q_pc(pc),\n"
        "        .q_hit(btb_q_hit), .q_taken(btb_q_taken), .q_target(btb_q_target),\n"
        "        .u_valid(ex_valid && ex_branch_request),\n"
        "        .u_pc(ex_branch_source),\n"
        "        .u_taken(ex_branch_taken),\n"
        "        .u_target(ex_branch_pc),\n"
        "        .u_pred_taken(ex_pred_taken_q),\n"
        "        .u_pred_target(ex_pred_target_q),\n"
        "        .u_exception(xm_fault_q || xm_illegal_q),\n"
        "        .u_is_call(1'b0), .u_is_ret(1'b0),\n"
        "        .stat_clr(1'b0),\n"
        "        .stat_query(btb_stat_query), .stat_hit(btb_stat_hit),\n"
        "        .stat_mispredict(btb_stat_mispredict)\n"
        "    );\n"
        "\n"
        "    // IF/ID is a valid-holding register, while this draft front end does not\n",
    ),
]


def apply(path: Path, edits, check_only: bool) -> int:
    t = path.read_text(encoding="utf-8")
    n = 0
    for old, new in edits:
        c = t.count(old)
        assert c == 1, "%s: 锚点出现 %d 次（要求 1 次）:\n%r" % (path.name, c, old[:120])
        t = t.replace(old, new, 1)
        n += 1
    if not check_only:
        path.write_text(t, encoding="utf-8")
    return n


def add_param(path: Path, check_only: bool) -> int:
    """给 cpu_core_stage1 增加 BTB_ENABLE 参数（便于 A/B 对照实测收益）。"""
    t = path.read_text(encoding="utf-8")
    if "BTB_ENABLE" in t:
        return 0
    # 注意：cpu_core_stage1 是 ANSI 端口列表，参数必须放进 #( )，
    # 直接塞进端口列表会导致 "Errors in port declarations"（2026-09-28 实测踩坑）。
    old = "module cpu_core_stage1 ("
    new = ("module cpu_core_stage1 #(\n"
           "    // BTB_ENABLE=1 启用分支预测取指；=0 用于实测对照（同程序、同 TB 编译两次）。\n"
           "    parameter BTB_ENABLE = 1'b1\n"
           ")(")
    assert t.count(old) == 1, "模块头锚点命中 %d 次（要求 1）" % t.count(old)
    t = t.replace(old, new, 1)
    if not check_only:
        path.write_text(t, encoding="utf-8")
    return 1


INST_RE = re.compile(r"\bif_stage\s+(\w+)\s*\(")


def patch_instantiations(check_only: bool) -> list[tuple[str, int]]:
    """给除 cpu_core_stage1 外的全部 if_stage 例化补 pred 输入常量。"""
    out = []
    files = []
    for root in (ROOT / "rtl", ROOT / "verification"):
        files += list(root.rglob("*.sv")) + list(root.rglob("*.v"))
    for f in sorted(set(files)):
        if f.name in ("if_stage.sv", "cpu_core_stage1.sv"):
            continue
        try:
            t = f.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        n = 0
        while True:
            m = INST_RE.search(t)
            if not m:
                break
            # 该例化块是否已补过
            end = t.find(");", m.end())
            if end < 0:
                break
            if ".pred_hit_i" in t[m.start():end]:
                break
            line_start = t.rfind("\n", 0, m.start()) + 1
            indent = re.match(r"[ \t]*", t[line_start:]).group(0)
            inj = ("\n" + indent + "    .pred_hit_i(1'b0), .pred_taken_i(1'b0), "
                   ".pred_target_i(32'b0),")
            t = t[:m.end()] + inj + t[m.end():]
            n += 1
        if n and not check_only:
            f.write_text(t, encoding="utf-8")
        if n or f.name in ("tb_frontend.sv",):
            out.append((f.name, n))
    return out


def main() -> int:
    check_only = "--check" in sys.argv
    a = apply(IF_STAGE, IF_EDITS, check_only)
    b = apply(CORE, CORE_EDITS, check_only)
    c = add_param(CORE, check_only)
    insts = patch_instantiations(check_only)
    print("if_stage.sv 补丁 %d 处" % a)
    print("cpu_core_stage1.sv 补丁 %d 处 + BTB_ENABLE 参数 %d 处" % (b, c))
    tot = sum(n for _, n in insts)
    print("其余 if_stage 例化补丁 %d 处（%d 个文件）" % (tot, len(insts)))
    for name, n in insts:
        if n:
            print("   %-40s %d" % (name, n))
    return 0


if __name__ == "__main__":
    sys.exit(main())
