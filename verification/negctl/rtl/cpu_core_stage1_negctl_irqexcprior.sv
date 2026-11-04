`timescale 1ns/1ps

// Stage1 integration candidate: five logical stages, single outstanding I/D
// transactions, EX redirect, load-use interlock, and architectural retire trace.
// riscv_exec's registered output is the EX/MEM boundary; no second EX/MEM
// register is inserted.  Public board pins and trap-vector handling are out of
// scope for this simulation-first core candidate.
module cpu_core_stage1 #(
    // BTB_ENABLE=1 启用分支预测取指；=0 用于实测对照（同程序、同 TB 编译两次）。
    parameter BTB_ENABLE = 1'b1,
    // 0=RV32I, 1=RV32I+Zmmul, 2=RV32IM. Candidate-only performance switch.
    parameter integer M_MODE = 0
)(

    input  wire        clk,
    input  wire        rst,
    output wire        i_req_valid,
    input  wire        i_req_ready,
    output wire [31:0] i_req_addr,
    input  wire        i_rsp_valid,
    output wire        i_rsp_ready,
    input  wire [31:0] i_rsp_data,
    input  wire        i_rsp_error,
    output wire        d_req_valid,
    input  wire        d_req_ready,
    output wire [31:0] d_req_addr,
    output wire        d_req_write,
    output wire [31:0] d_req_wdata,
    output wire [3:0]  d_req_wstrb,
    input  wire        d_rsp_valid,
    output wire        d_rsp_ready,
    input  wire [31:0] d_rsp_rdata,
    input  wire        d_rsp_error,
    // 批 (c)：机器中断源（电平直通 csr_file 的 mip.MTIP/MEIP）。
    // 本机 Icarus 10.2 不支持 ANSI 端口默认值：新增端口必须同步更新**全部**例化点
    // （rtl/soc/pangu100proplus_top.sv、tb_cpu_mem_subsystem、各系统 TB、
    //  以及 scripts/gen_csr_access_negctl.py / gen_irq_negctl.py 再生的突变体）。
    // D14：SoC 无外部中断源，顶层对 ext_irq_i 显式接 0；MEIP 路径"已接线、未验证"。
    input  wire        timer_irq_i,
    input  wire        ext_irq_i,
    output wire        trace_valid,
    output wire [63:0] trace_order,
    output wire [31:0] trace_pc,
    output wire [31:0] trace_instr,
    output wire [4:0]  trace_rd,
    output wire [31:0] trace_rd_data,
    output wire        trace_rd_we,
    output wire        trace_trap,
    // 批 (b) 扩展：提交 trace 新增 cause 字段（既有字段一个未改）
    output wire [31:0] trace_cause
);
    wire [31:0] pc;
    wire advance_valid;
    wire redirect_valid;
    wire [31:0] redirect_target;
    wire pc_hold, if_id_hold, id_ex_hold, ex_mem_hold, mem_wb_hold;
    wire flush_if_id, flush_id_ex, id_ex_bubble, retire_block;
    wire if_valid, if_ready, if_fault;
    wire [31:0] if_pc, if_instr;
    wire id_valid, id_fault;
    wire [31:0] id_pc, id_instr;
    wire id_pred_valid, id_pred_taken;
    wire [31:0] id_pred_target;

    // ---- BTB 集成新增信号（ADR-BTB-INTEGRATION.md）----
    wire        if_pred_valid, if_pred_taken;
    wire [31:0] if_pred_target;
    wire        idex_pred_valid, idex_pred_taken;
    wire [31:0] idex_pred_target;
    wire        btb_q_hit, btb_q_taken;
    wire [31:0] btb_q_target;
    wire        btb_pred_valid = BTB_ENABLE && btb_q_hit && btb_q_taken;
    wire [31:0] btb_stat_query, btb_stat_hit, btb_stat_mispredict;
    // riscv_exec 的 branch_source_o 原例化未连接（悬空 z）；恢复逻辑必须用它
    // 作为"实际下一条 PC"的基准，故接出。
    wire [31:0] ex_branch_source;
    reg id_issued_q;
    wire id_issue_valid = id_valid && !id_issued_q;

    pc_reg u_pc (
        .clk(clk), .rst(rst), .redirect_valid(redirect_valid),
        .redirect_target(redirect_target), .advance_valid(advance_valid),
        .pred_valid(btb_pred_valid), .pred_target(btb_q_target),
        .hold_pc(pc_hold), .pc(pc)
    );
    if_stage u_if (
        .clk(clk), .rst(rst), .pc(pc), .redirect_valid(redirect_valid),
        .hold_if(if_id_hold), .flush_if(flush_if_id),
        .i_req_valid(i_req_valid), .i_req_ready(i_req_ready),
        .i_req_addr(i_req_addr), .advance_valid(advance_valid),
        .i_rsp_valid(i_rsp_valid), .i_rsp_ready(i_rsp_ready),
        .i_rsp_data(i_rsp_data), .i_rsp_error(i_rsp_error),
        .pred_hit_i(btb_q_hit), .pred_taken_i(btb_pred_valid),
        .pred_target_i(btb_q_target),
        .if_out_valid(if_valid), .if_out_ready(if_ready), .if_out_pc(if_pc),
        .if_out_inst(if_instr), .if_out_fault(if_fault),
        .if_out_pred_valid(if_pred_valid), .if_out_pred_taken(if_pred_taken),
        .if_out_pred_target(if_pred_target)
    );
    if_id u_if_id (
        .clk(clk), .rst(rst), .if_valid_i(if_valid), .if_ready_o(if_ready),
        .if_pc_i(if_pc), .if_inst_i(if_instr), .if_fault_i(if_fault),
        .if_pred_valid_i(if_pred_valid), .if_pred_taken_i(if_pred_taken),
        .if_pred_target_i(if_pred_target), .hold_if_id(if_id_hold),
        .flush_if_id(flush_if_id), .id_valid_o(id_valid), .id_pc_o(id_pc),
        .id_inst_o(id_instr), .id_fault_o(id_fault),
        .id_pred_valid_o(id_pred_valid), .id_pred_taken_o(id_pred_taken),
        .id_pred_target_o(id_pred_target)
    );

    wire [4:0] dec_rs1, dec_rs2, dec_rd;
    wire [31:0] dec_imm, rf_rs1, rf_rs2;
    wire dec_reg_we, dec_mem_req, dec_mem_we, dec_branch, dec_jal, dec_jalr;
    wire dec_uses_rs1, dec_uses_rs2, dec_illegal;
    wire [3:0] dec_wstrb;
    wire dec_lui, dec_auipc;
    wire [6:0] dec_opcode, dec_funct7;
    wire [2:0] dec_funct3;
    wire dec_pred_valid, dec_pred_taken;
    wire [31:0] dec_pred_target;
    // ---- SYSTEM 类译码（批 (a)：CSR 读写路径 + 特权指令译码）----
    wire [11:0] dec_csr_addr;
    wire [31:0] dec_csr_uimm;
    wire [1:0]  dec_csr_op;
    wire        dec_csr_we, dec_csr_imm;
    wire        dec_ecall, dec_ebreak, dec_mret;
    // CSR 类指令（区别于 ECALL/EBREAK/MRET）：funct3 非 000/100
    wire        dec_is_csr = (dec_opcode == 7'b1110011) &&
                             (dec_funct3 != 3'b000) && (dec_funct3 != 3'b100);

    // ================= CSR 接入的级间影子寄存器（声明区） =================
    // riscv_exec / id_ex_reg 的载荷里没有 CSR 字段，而把 CSR 字段塞进这两个
    // 模块要改它们的端口（Stage1 冻结接口）。本文件已有的做法是"在集成顶里做
    // 与流水线寄存器逐条件对齐的影子"（xm_* / ex_pred_* 已如此），CSR 沿用同一
    // 手法：三条影子链分别对齐 ID/EX、EX/MEM、MEM/WB。
    wire [31:0] mw_fwd_data;   // WB 期有效写回值（CSR 结果只在 WB 这一拍存在）
    reg        idex_csr_is_q, idex_csr_imm_q, idex_csr_we_q;
    reg [1:0]  idex_csr_op_q;
    reg [11:0] idex_csr_addr_q;
    reg [31:0] idex_csr_uimm_q;
    reg        xm_csr_is_q, xm_csr_we_q;
    reg [1:0]  xm_csr_op_q;
    reg [11:0] xm_csr_addr_q;
    reg [31:0] xm_csr_wdata_q;
    reg        mw_csr_is_q, mw_csr_we_q;
    reg [1:0]  mw_csr_op_q;
    reg [11:0] mw_csr_addr_q;
    reg [31:0] mw_csr_wdata_q;

    // ================= 批 (b)：同步异常精确陷阱（信号声明区） =================
    // SYSTEM 特权指令（{mret, ebreak, ecall}）的级间影子：与 CSR 影子同条件对齐
    reg [2:0]  idex_sys_q;
    reg [2:0]  xm_sys_q;
    // EX/MEM 边界的陷阱判定
    reg [3:0]  xm_trap_cause;     // 0 = 无陷阱
    reg [31:0] xm_trap_tval;
    wire       xm_trap_det;       // 本拍新检出（未处于重定向保持窗内）
    wire       sys_redir;         // 本拍新增"陷阱或 mret"重定向
    wire       redir_to_mepc;     // 重定向目标是 mepc(1) 还是 mtvec(0)
    reg        sys_hold_q;        // 重定向保持窗：到该指令提交为止
    reg        sys_is_mret_q;     // 保持窗内记录的"是 mret"
    wire       csr_chk_impl, csr_chk_wr;
    wire       xm_csr_bad;        // EX/MEM 边界的非法 CSR（未实现 / 对只读的写意图）
    // MEM/WB 侧的陷阱上下文（mw_trap_cause_q / mw_trap_tval_q / mw_mret_q
    // 与其它 mw_* 寄存器一起声明在本文件的 MEM/WB 影子块内）
    wire       trap_commit;
    wire       mret_commit;
    // 批 (c)：机器中断接入（D12/D13/D14，见 ADR-CSR-ACCESS.md §6）
    wire       csr_irq_pending;   // csr_file 组合输出：mstatus.MIE && (mie&mip) 门控后的待决中断
    wire [31:0] csr_irq_cause;    // csr_file 组合输出：bit31=1 的中断 mcause（外部 11 > 定时器 7）
    wire       xm_irq_take;       // 本拍在 EX/MEM 边界采到中断（D12 采样条件全成立）
    wire [31:0] xm_trap_cause32;  // 统一陷阱 cause：同步异常（低 4 位）或中断（bit31=1）
    id_stage #(.SUPPORT_M(M_MODE == 2), .SUPPORT_ZMMUL(M_MODE == 1)) u_id (
        .rst(rst), .inst_i(id_instr), .pc_i(id_pc), .inst_valid_i(id_valid),
        .fault_i(id_fault), .pred_valid_i(id_pred_valid),
        .pred_taken_i(id_pred_taken), .pred_target_i(id_pred_target),
        .ex_jump_flag_i(1'b0), .rs1_addr_o(dec_rs1), .rs2_addr_o(dec_rs2),
        .imm_o(dec_imm), .reg_we_o(dec_reg_we), .rd_addr_o(dec_rd),
        .mem_req_o(dec_mem_req), .mem_we_o(dec_mem_we), .mem_wstrb_o(dec_wstrb),
        .branch_o(dec_branch), .jal_o(dec_jal), .jalr_o(dec_jalr),
        .lui_o(dec_lui), .auipc_o(dec_auipc), .uses_rs1_o(dec_uses_rs1),
        .uses_rs2_o(dec_uses_rs2), .opcode_o(dec_opcode), .funct3_o(dec_funct3),
        .funct7_o(dec_funct7), .rd_o(), .pred_valid_o(dec_pred_valid),
        .pred_taken_o(dec_pred_taken), .pred_target_o(dec_pred_target),
        .illegal_instr_o(dec_illegal),
        .csr_addr_o(dec_csr_addr), .csr_we_o(dec_csr_we), .csr_op_o(dec_csr_op),
        .csr_imm_o(dec_csr_imm), .csr_uimm_o(dec_csr_uimm),
        // 特权指令标志：本批只译码、不在本批消费（陷阱进入/mret 由批 (b)(c) 接入）
        .sys_ecall_o(dec_ecall), .sys_ebreak_o(dec_ebreak), .sys_mret_o(dec_mret)
    );

    wire mw_valid, mw_reg_write, mw_error;
    wire [4:0] mw_rd;
    wire [31:0] mw_pc, mw_instr, mw_data;
    wire wb_we;
    wire [4:0] wb_rd;
    wire [31:0] wb_data;
    regfile u_regfile (
        .clk(clk), .rst(rst), .rs1_addr(dec_rs1), .rs1_data(rf_rs1),
        .rs2_addr(dec_rs2), .rs2_data(rf_rs2), .wb_valid(mw_valid && !retire_block),
        .wb_we(wb_we), .wb_rd(wb_rd), .wb_wdata(wb_data)
    );

    wire idex_valid;
    wire [31:0] idex_pc, idex_instr, idex_rs1_value, idex_rs2_value;
    wire [4:0] idex_rs1, idex_rs2, idex_rd;
    // Issue #15 第 2 项：ID 的 uses_rs 语义源随 ID/EX 一起寄存（见 id_ex_reg.v），
    // EX 侧 forwarding 直接消费，**不再**从 idex_instr 的 opcode 重组。
    wire idex_uses_rs1, idex_uses_rs2;
    wire idex_reg_write, idex_fault, idex_illegal;
    id_ex_reg u_id_ex (
        .clk(clk), .rst(rst), .flush(flush_id_ex),
        .hold(id_ex_hold), .in_valid(id_issue_valid && !id_ex_bubble),
        .in_pc(id_pc), .in_instr(id_instr), .in_rs1_value(rf_rs1),
        .in_rs2_value(rf_rs2), .in_imm(dec_imm), .in_rs1(dec_rs1),
        .in_rs2(dec_rs2), .in_rd(dec_rd), .in_alu_op(4'b0),
        .in_uses_rs1(dec_uses_rs1), .in_uses_rs2(dec_uses_rs2),
        .in_alu_src_imm(1'b0), .in_branch(dec_branch), .in_jal(dec_jal),
        .in_jalr(dec_jalr), .in_mem_read(dec_mem_req && !dec_mem_we),
        .in_mem_write(dec_mem_req && dec_mem_we), .in_mem_size(2'b0),
        .in_mem_unsigned(id_instr[14]), .in_reg_write(dec_reg_we),
        .in_fetch_fault(id_fault), .in_illegal(dec_illegal),
        .in_pred_valid(dec_pred_valid), .in_pred_taken(dec_pred_taken),
        .in_pred_target(dec_pred_target), .out_valid(idex_valid),
        .out_pc(idex_pc), .out_instr(idex_instr),
        .out_rs1_value(idex_rs1_value), .out_rs2_value(idex_rs2_value),
        .out_imm(), .out_rs1(idex_rs1), .out_rs2(idex_rs2), .out_rd(idex_rd),
        .out_uses_rs1(idex_uses_rs1), .out_uses_rs2(idex_uses_rs2),
        .out_alu_op(), .out_alu_src_imm(), .out_branch(), .out_jal(), .out_jalr(),
        .out_mem_read(), .out_mem_write(), .out_mem_size(), .out_mem_unsigned(),
        .out_reg_write(idex_reg_write), .out_fetch_fault(idex_fault),
        .out_illegal(idex_illegal), .out_pred_valid(idex_pred_valid),
        .out_pred_taken(idex_pred_taken), .out_pred_target(idex_pred_target)
    );

    wire xm_valid, xm_reg_write, xm_mem_read, xm_mem_write;
    wire [4:0] xm_rd;
    wire [31:0] xm_pc, xm_instr, xm_alu, xm_store_data;
    reg [31:0] xm_pc_q, xm_instr_q, xm_store_q, xm_base_q;
    reg [4:0] xm_rd_q;
    reg xm_regwrite_q, xm_load_q, xm_store_enable_q, xm_fault_q, xm_illegal_q;
    wire [1:0] fwd_rs1, fwd_rs2;
    wire [31:0] ex_ra, ex_rb;
    wire load_use_stall;
    hazard_detection u_hazard (
        .id_rs1(dec_rs1), .id_rs2(dec_rs2), .id_uses_rs1(id_issue_valid && dec_uses_rs1),
        .id_uses_rs2(id_issue_valid && dec_uses_rs2), .ex_valid(idex_valid),
        // CSR 结果与 load 一样"要到 WB 才存在"（读端口接在 MEM/WB 边界，
        // 见下方 CSR 接入节），因此复用同一条 load-use 互锁：使 ID 期消费者
        // 推迟一拍进入 EX，从而在 EX 期通过 mw→EX 转发拿到 csr_rdata。
        // 负向对照 cpu_core_stage1_negctl_csrnostall 证明该条件是不可省的。
        .ex_is_load((idex_instr[6:0] == 7'h03) || (idex_instr[6:0] == 7'h73)),
        .ex_writes_rd(idex_reg_write),
        .ex_rd(idex_rd), .load_use_stall(load_use_stall)
    );
    forwarding_unit u_forward (
        .ex_rs1(idex_rs1), .ex_rs2(idex_rs2),
        // Issue #15 第 2 项：uses_rs 直接取 ID/EX 携带的标志，不再从 opcode 重组。
        // 旧实现是 7 条 opcode 的 OR 表达式（0x13/33/03/23/63/67/73），有三处语义偏差：
        //   ① CSR 立即数形式（CSRRWI/SI/CI）rs1 域是 uimm、不读寄存器，旧式却判成"用 rs1"；
        //   ② ECALL/EBREAK/MRET 同样被旧式判成"用 rs1"；
        //   ③ 将来新增指令必须再来这里补 opcode，而 ID 已是唯一语义源。
        // 行为等价性由 cpu_core_* / icache_off 系统套件 + tb_id_ex_reg 守护。
        .ex_uses_rs1(idex_uses_rs1),
        .ex_uses_rs2(idex_uses_rs2),
        // CSR 生产者（xm_csr_is_q）在 MEM 期结果还不存在（读发生在 WB），
        // 不得从这里转发 xm_alu（对 opcode 0x73 是无意义值）；消费者由上面的
        // load-use 互锁推迟到 WB 期再经 mw 路径取值。
        .ex_mem_valid(xm_valid && !xm_mem_read && !xm_csr_is_q),
        .ex_mem_writes_rd(xm_reg_write), .ex_mem_rd(xm_rd),
        .mem_wb_valid(mw_valid && !mw_error), .mem_wb_writes_rd(mw_reg_write),
        .mem_wb_rd(mw_rd), .forward_rs1(fwd_rs1), .forward_rs2(fwd_rs2)
    );
    // CSR 的结果只在 WB 这一拍存在：写回与 mw→EX 转发都必须走 mw_fwd_data
    // （非 CSR 指令时 mw_fwd_data === mw_data，行为与接入前逐位一致）。
    assign ex_ra = (fwd_rs1 == 2'b10) ? xm_alu :
                   (fwd_rs1 == 2'b01) ? mw_fwd_data : idex_rs1_value;
    assign ex_rb = (fwd_rs2 == 2'b10) ? xm_alu :
                   (fwd_rs2 == 2'b01) ? mw_fwd_data : idex_rs2_value;

    wire ex_valid, ex_writes_rd, ex_branch_request, ex_branch_taken;
    wire [31:0] ex_alu, ex_branch_pc;
    wire [4:0] ex_rd;
    wire lsu_valid, lsu_fault, lsu_fault_valid, lsu_fault_ready;
    wire lsu_stall, lsu_load_not_ready, lsu_mem_advanceable;
    wire [31:0] lsu_result, lsu_fault_pc;
    wire [4:0] lsu_fault_rd, lsu_rd;
    // 批 (b)：LSU 的故障归因（非对齐？字节地址）→ 决定 cause 4/6 与 5/7、以及 mtval
    wire        lsu_fault_misaligned;
    wire [31:0] lsu_fault_addr;
    wire lsu_req_valid, lsu_req_write;
    wire [31:0] lsu_req_addr, lsu_req_wdata;
    wire [3:0] lsu_req_wstrb;
    wire [31:0] lsu_result_or_alu = xm_mem_read ? lsu_result : xm_alu;
    // Faulted/illegal instructions retain trace context but never issue data
    // memory requests, redirect control flow, or write GPRs.
    wire xm_memop = xm_valid && !xm_fault_q && !xm_illegal_q &&
                    (xm_mem_read || xm_mem_write);
    reg mem_done;
    wire backend_mem_hold = xm_memop && !mem_done;
    wire idex_m_encoding = (idex_instr[6:0] == 7'b0110011) &&
                           (idex_instr[31:25] == 7'b0000001);
    wire idex_m_enabled = (M_MODE == 2) ||
                          ((M_MODE == 1) && !idex_instr[14]);
    wire idex_m_op = idex_valid && idex_m_encoding && idex_m_enabled &&
                     !idex_fault && !idex_illegal;
    reg mdu_active_q, mdu_result_valid_q;
    reg [31:0] mdu_result_q;
    wire mdu_ready, mdu_done;
    wire [31:0] mdu_result;
    wire mdu_start = idex_m_op && mdu_ready && !redirect_valid && !backend_mem_hold &&
                     !mdu_active_q && !mdu_result_valid_q;
    wire mdu_cancel = redirect_valid && mdu_active_q;
    wire mdu_wait = !redirect_valid && (mdu_start ||
                       (mdu_active_q && !mdu_result_valid_q));
    wire mdu_consume = idex_m_op && mdu_result_valid_q && !redirect_valid &&
                       !backend_mem_hold;
    wire backend_hold = backend_mem_hold || mdu_wait;

    rv32im_unit #(.DIV_ENABLE(M_MODE == 2)) u_rv32im (
        .clk_i(clk), .rst_i(rst || mdu_cancel), .start_i(mdu_start),
        .funct3_i(idex_instr[14:12]), .operand_a_i(ex_ra), .operand_b_i(ex_rb),
        .ready_o(mdu_ready), .done_o(mdu_done), .result_o(mdu_result)
    );

    always @(posedge clk) begin
        if (rst || mdu_cancel) begin
            mdu_active_q <= 1'b0;
            mdu_result_valid_q <= 1'b0;
            mdu_result_q <= 32'b0;
        end else begin
            if (mdu_start) mdu_active_q <= 1'b1;
            if (mdu_done && mdu_active_q) begin
                mdu_result_valid_q <= 1'b1;
                mdu_result_q <= mdu_result;
            end
            if (mdu_consume) begin
                mdu_active_q <= 1'b0;
                mdu_result_valid_q <= 1'b0;
            end
        end
    end

    riscv_exec u_ex (
        // A redirect is registered from the older EX transaction. The
        // younger ID/EX payload is flushed on this same edge, so it must not
        // be accepted by EX before that flush takes effect.
        .clk_i(clk), .rst_i(rst), .valid_i(idex_valid && !redirect_valid), .opcode_i(idex_instr),
        .pc_i(idex_pc), .ra_operand_i(ex_ra), .rb_operand_i(ex_rb),
        .hold_i(backend_hold), .valid_o(ex_valid), .alu_result_o(ex_alu),
        .alu_result_e1_o(), .branch_request_o(ex_branch_request),
        .branch_taken_o(ex_branch_taken), .branch_not_taken_o(),
        .branch_pc_o(ex_branch_pc), .branch_source_o(ex_branch_source), .branch_call_o(),
        .branch_ret_o(), .branch_jmp_o(), .rd_idx_o(ex_rd),
        .writes_rd_o(ex_writes_rd)
    );

    // Sideband for B EX's registered result, kept stable during D completion.
    always @(posedge clk) begin
        if (rst) begin
            xm_pc_q <= 0; xm_instr_q <= 0; xm_base_q <= 0;
            xm_rd_q <= 0; xm_regwrite_q <= 0; xm_load_q <= 0;
            xm_store_enable_q <= 0; xm_store_q <= 0; xm_fault_q <= 0;
            xm_illegal_q <= 0;
        end else if (!backend_hold) begin
            xm_pc_q <= idex_pc;
            xm_instr_q <= idex_instr;
            xm_base_q <= ex_ra;
            // Capture the current ID/EX payload on the same edge that B EX
            // captures it; its registered outputs become visible after edge.
            xm_rd_q <= idex_rd;
            xm_regwrite_q <= idex_reg_write && !idex_fault && !idex_illegal;
            xm_load_q <= idex_valid && !idex_fault && !idex_illegal && idex_instr[6:0] == 7'h03;
            xm_store_enable_q <= idex_valid && !idex_fault && !idex_illegal && idex_instr[6:0] == 7'h23;
            xm_store_q <= ex_rb;
            xm_fault_q <= idex_fault;
            xm_illegal_q <= idex_illegal;
        end
    end
    assign xm_valid = ex_valid;
    assign xm_pc = xm_pc_q;
    assign xm_instr = xm_instr_q;
    assign xm_rd = xm_rd_q;
    assign xm_reg_write = xm_regwrite_q;
    assign xm_mem_read = xm_load_q;
    assign xm_mem_write = xm_store_enable_q;
    assign xm_store_data = xm_store_q;
    reg xm_mdu_valid_q;
    reg [31:0] xm_mdu_result_q;
    always @(posedge clk) begin
        if (rst) begin
            xm_mdu_valid_q <= 1'b0;
            xm_mdu_result_q <= 32'b0;
        end else if (!backend_hold) begin
            xm_mdu_valid_q <= mdu_consume;
            if (mdu_consume) xm_mdu_result_q <= mdu_result_q;
        end
    end
    assign xm_alu = xm_mdu_valid_q ? xm_mdu_result_q : ex_alu;

    riscv_lsu u_lsu (
        .clk_i(clk), .rst_i(rst), .valid_i(xm_memop && !mem_done),
        .opcode_i(xm_instr), .pc_i(xm_pc), .ra_operand_i(xm_base_q),
        .rb_operand_i(xm_store_data), .hold_i(1'b0),
        .req_valid_o(lsu_req_valid), .req_ready_i(d_req_ready),
        .req_addr_o(lsu_req_addr), .req_write_o(lsu_req_write),
        .req_wdata_o(lsu_req_wdata), .req_wstrb_o(lsu_req_wstrb),
        .rsp_valid_i(d_rsp_valid), .rsp_ready_o(d_rsp_ready),
        .rsp_rdata_i(d_rsp_rdata), .rsp_error_i(d_rsp_error),
        .valid_o(lsu_valid), .result_o(lsu_result), .fault_o(lsu_fault),
        .fault_valid_o(lsu_fault_valid), .fault_ready_i(lsu_fault_ready),
        .fault_pc_o(lsu_fault_pc), .fault_rd_o(lsu_fault_rd),
        .fault_misaligned_o(lsu_fault_misaligned), .fault_addr_o(lsu_fault_addr),
        .stall_o(lsu_stall), .rd_idx_o(lsu_rd),
        .load_not_ready_o(lsu_load_not_ready),
        .mem_advanceable_o(lsu_mem_advanceable)
    );
    assign d_req_valid = lsu_req_valid;
    assign d_req_addr = lsu_req_addr;
    assign d_req_write = lsu_req_write;
    assign d_req_wdata = lsu_req_wdata;
    assign d_req_wstrb = lsu_req_wstrb;
    // Keep a fault event asserted until the corresponding MEM transaction is
    // allowed to advance into MEM/WB.  This is the LSU valid/ready handshake.
    assign lsu_fault_ready = xm_memop && mem_done;

    always @(posedge clk) begin
        if (rst) mem_done <= 1'b0;
        else if (!xm_memop) mem_done <= 1'b0;
        else if (!mem_done && ((d_rsp_valid && d_rsp_ready) || lsu_fault_valid || lsu_valid))
            mem_done <= 1'b1;
        else if (!backend_hold) mem_done <= 1'b0;
    end

    pipeline_control u_control (
        .redirect_valid(redirect_valid), .backend_hold(backend_hold),
        .load_use_stall(load_use_stall), .pc_hold(pc_hold),
        .if_id_hold(if_id_hold), .id_ex_hold(id_ex_hold),
        .ex_mem_hold(ex_mem_hold), .mem_wb_hold(mem_wb_hold),
        .if_id_flush(flush_if_id), .id_ex_flush(flush_id_ex),
        .id_ex_bubble(id_ex_bubble), .retire_block(retire_block)
    );
    // ------------------------------------------------------------------
    // BTB 集成的误预测恢复（ADR-BTB-INTEGRATION.md §2.3/§2.4）
    // ------------------------------------------------------------------
    // riscv_exec 的全部输出都是寄存器，且其输入为 (idex_* 上一拍)。
    // 而 xm_fault_q/xm_illegal_q 同样寄存自 idex_*（cpu_core_stage1.sv 内），
    // xm_valid 是 ex_valid 的组合别名 —— 因此它们与 ex_* **同拍对位**，
    // 既有护栏可以原样保留。
    //
    // ex_branch_pc 的语义（见 riscv_exec.sv: branch_taken ? target : pc_i+4）
    // 正是"实际下一条 PC"，因此只需与"预测导致的下一条 PC"直接比较，
    // 即可统一覆盖全部 5 种情形（含"预测 taken 但实际不跳"这一旧代码没有的情形）：
    //   1 预测 taken & 目标一致 & 实际 taken -> 相等 -> 不 redirect（收益来源）
    //   2 预测 taken & 目标不同   & 实际 taken -> 不等 -> redirect 到实际目标
    //   3 预测 taken & 实际 not taken           -> 不等 -> redirect 到 pc+4
    //   4 未预测 taken & 实际 taken             -> 不等 -> redirect 到实际目标
    //   5 未预测 taken & 实际 not taken         -> 相等 -> 不 redirect
    // ⚠️⚠️ 坑位（**跨仿真器不可移植，2026-10-01 峥榕在 Icarus 13.0 复现**）：
    //   `ex_pred_valid_q / ex_pred_taken_q / ex_pred_target_q` 原声明在本段**之后**（旧 L419-420），
    //   而下面 L398 的 `wire ... = ex_pred_taken_q ? ex_pred_target_q : ...` 就已经在用它们
    //   ⇒ **先用后声明**。Icarus **10.2 容忍**（会自动把后置声明与该名字合并，实测 `-Wall` 无告警、
    //   位宽不丢：`y=12345678` 完整 32 位），但 **Icarus 13.0 直接编译失败**；
    //   它还与 §7.3 的隐式 net 是同一族风险（若某版本选择造隐式网而非合并，就会**静默截断**）。
    //   ⇒ 正确做法：**声明一律先于使用**，不依赖工具的宽容。诊断脚本：`scripts/check_decl_order.py`。
    //   （同类前向引用本文件另有两处：`csr_mtvec/csr_mepc`（L413 用、旧 L702 声明）、
    //     `xm_is_mret`（L496 用、旧 L628 声明），同轮一并上提。）
    reg ex_pred_valid_q, ex_pred_taken_q;
    reg [31:0] ex_pred_target_q;

    wire [31:0] ex_pred_next = ex_pred_taken_q ? ex_pred_target_q
                                              : (ex_branch_source + 32'd4);
    wire [31:0] ex_next_pc   = ex_branch_pc;

    // 陷阱/mret 重定向（sys_redir / sys_hold_q）**优先于**误预测恢复：
    //   sys_redir  ：本拍在 EX/MEM 边界检出同步异常或 mret；
    //   sys_hold_q ：重定向保持窗（到该指令提交），既保证被 backend_hold 挡住的
    //                重定向在解除阻塞后仍然生效，也保证 mtvec/mepc 在更老的
    //                CSR 写生效之后被重新取样（→ 最终 PC 取到的是新值）。
    wire ex_mispredict = ex_valid && ex_branch_request && !xm_fault_q &&
                         !xm_illegal_q && !sys_redir && !sys_hold_q &&
                         (ex_next_pc != ex_pred_next);

    // ⚠️ 坑位：`csr_mtvec/csr_mepc` 声明必须在本 assign **之前**（旧位置在 L702，
    //   而 L425 已在用 ⇒ 先用后声明；Icarus 10.2 容忍、13.0 编译失败。详见 L398 前坑位注释）。
    wire [31:0] csr_mtvec, csr_mepc;

    assign redirect_valid  = ex_mispredict || sys_redir || sys_hold_q;
    assign redirect_target = (sys_redir || sys_hold_q)
                             ? (redir_to_mepc ? csr_mepc : csr_mtvec)
                             : ex_next_pc;

    // 预测元数据影子：必须与 riscv_exec 的寄存块逐条件对齐
    // （复位清 0 / valid_i && ~hold 装载 / ~hold 清 0；hold 时保持不变）。
    // 失步会让上面的比较错位一条指令，从而可能漏掉必需的 redirect。
    // ⚠️ 声明已上提到 L398 之前（先用后声明在 Icarus 13.0 编译失败，见该处坑位注释）。
    always @(posedge clk) begin
        if (rst) begin
            ex_pred_valid_q  <= 1'b0;
            ex_pred_taken_q  <= 1'b0;
            ex_pred_target_q <= 32'b0;
        end else if (!backend_hold) begin
            ex_pred_valid_q  <= idex_valid && !redirect_valid && idex_pred_valid;
            ex_pred_taken_q  <= idex_pred_taken;
            ex_pred_target_q <= idex_pred_target;
        end
    end

    // ------------------------------------------------------------------
    // 分支预测器（64 项直接映射 BTB + 每项 2-bit 饱和计数器；默认参数即基线规格）
    // ------------------------------------------------------------------
    // 取指侧查询用**当前 pc**，与 if_stage 内锁存的标签同源；
    // 训练用 EX 已解析的结果，且与影子寄存器同拍对位。
    // u_is_call/u_is_ret 暂接 0：RAS 默认关闭（RAS_ENABLE=0），
    // 待启用 RAS 时再接 ex_branch_call / ex_branch_ret（见 ADR §2.4 备注）。
    branch_predictor u_btb (
        .clk(clk), .rst(rst),
        .q_valid(advance_valid), .q_pc(pc),
        .q_hit(btb_q_hit), .q_taken(btb_q_taken), .q_target(btb_q_target),
        .u_valid(ex_valid && ex_branch_request),
        .u_pc(ex_branch_source),
        .u_taken(ex_branch_taken),
        .u_target(ex_branch_pc),
        .u_pred_taken(ex_pred_taken_q),
        .u_pred_target(ex_pred_target_q),
        // 陷指令不训练预测器：批 (b) 起为"完整陷阱判定"（含 ECALL/EBREAK/非法 CSR/
        // 非对齐/访存故障/取指故障）；批 (c) 起含中断（被中断指令被冲刷重试，同样不训练）
        .u_exception(xm_trap_cause32 != 32'd0),
        .u_is_call(1'b0), .u_is_ret(1'b0),
        .stat_clr(1'b0),
        .stat_query(btb_stat_query), .stat_hit(btb_stat_hit),
        .stat_mispredict(btb_stat_mispredict)
    );

    // IF/ID is a valid-holding register, while this draft front end does not
    // expose a separate ID consume signal.  Remember an accepted ID payload
    // until IF/ID is replaced, so a slow I response cannot replay one opcode.
    always @(posedge clk) begin
        if (rst || flush_if_id)
            id_issued_q <= 1'b0;
        else if (backend_hold)
            id_issued_q <= id_issued_q;
        else if (if_valid && if_ready && if_pc != id_pc)
            id_issued_q <= 1'b0;
        else if (id_issue_valid && !load_use_stall && !id_ex_bubble)
            id_issued_q <= 1'b1;
    end

    // ⚠️ 坑位：`xm_ecall/xm_ebreak/xm_is_mret` 声明必须在本段之前——`xm_is_mret` 在
    //   L511（`mw_mret_q <= xm_valid && xm_is_mret;`）已被使用，而旧声明在 L643
    //   ⇒ 先用后声明（Icarus 10.2 容忍、13.0 编译失败，见 L398 前坑位注释）。
    wire xm_ecall   = xm_sys_q[0];
    wire xm_ebreak  = xm_sys_q[1];
    wire xm_is_mret = xm_sys_q[2];

    reg mw_valid_q, mw_regwrite_q, mw_error_q, mw_trap_q, mw_mret_q;
    reg [31:0] mw_trap_cause_q;   // 批 (c) 起 32 位：中断 cause 需承载 bit31（D10 预留位宽启用）
    reg [31:0] mw_trap_tval_q;
    reg [31:0] mw_pc_q, mw_instr_q, mw_data_q;
    reg [4:0] mw_rd_q;
    always @(posedge clk) begin
        if (rst) begin
            mw_valid_q <= 1'b0; mw_regwrite_q <= 1'b0; mw_error_q <= 1'b0;
            mw_trap_q <= 1'b0; mw_pc_q <= 0; mw_instr_q <= 0;
            mw_data_q <= 0; mw_rd_q <= 0;
            mw_trap_cause_q <= 32'd0; mw_trap_tval_q <= 32'd0; mw_mret_q <= 1'b0;
        end else if (!mem_wb_hold) begin
            mw_valid_q <= xm_valid;
            mw_pc_q <= xm_pc; mw_instr_q <= xm_instr; mw_rd_q <= xm_rd;
            mw_data_q <= lsu_result_or_alu;
            mw_error_q <= xm_memop && lsu_fault_valid;
            // 批 (b)：陷阱上下文由 EX/MEM 边界的判定提供（含 ECALL/EBREAK/非法 CSR/
            // 非对齐/访存故障/取指故障），在提交拍一次性写入 csr_file。
            // 批 (c)：cause 统一为 32 位 —— 同步异常走低 4 位，中断走 bit31=1 的
            // csr_irq_cause（D13：被中断指令以 trap 事件退役，mepc 记其 PC，mret 后重试）。
            mw_trap_q       <= (xm_trap_cause32 != 32'd0);
            mw_trap_cause_q <= xm_trap_cause32;
            mw_trap_tval_q  <= xm_trap_tval;
            mw_mret_q       <= xm_valid && xm_is_mret;
            mw_regwrite_q <= xm_reg_write && (!xm_mem_read || (mem_done && !lsu_fault_valid)) &&
                             !(xm_memop && lsu_fault_valid);
        end
    end
    assign mw_valid = mw_valid_q;
    assign mw_pc = mw_pc_q;
    assign mw_instr = mw_instr_q;
    assign mw_rd = mw_rd_q;
    assign mw_data = mw_data_q;
    assign mw_reg_write = mw_regwrite_q;
    assign mw_error = mw_error_q;

    // ==================================================================
    //  CSR / 系统指令接入（批 (a)：译码 + CSR 读写路径；**不含**陷阱进入与中断）
    //
    //  为什么把 csr_file 的地址端口接在 MEM/WB 边界（而不是 ID 或 EX）：
    //    csr_file 的 csr_addr 同时服务"组合读"与"提交点写"，只有一个地址端口。
    //    把它接在 MEM/WB 的 CSR 指令上，同一条指令在同一拍完成"读旧值 + 写新值"
    //    （组合读先于边沿写）→ CSRRW 的 rd 得到旧值，CSRRS/CSRRC 的置位/清零
    //    基于旧值，语义正确。由此还得到两个性质：
    //      1) 读值不可能是陈旧值：WB 是唯一提交点，更老指令早已提交完毕，
    //         故 **CSR-CSR 之间不需要任何冒险互锁**（背靠背 CSR 序列天然正确）；
    //      2) 被冲刷（redirect / 误预测）的 CSR 指令不产生任何架构效果——
    //         读是组合的、无副作用，写只发生在提交点。
    //    代价：CSR 结果与 load 一样"要到 WB 才存在" → 复用 load-use 互锁与
    //    mw→EX 转发（见上面 hazard_detection / forwarding_unit 的接线）。
    //
    //  非法性判定同样放在提交点，直接使用 csr_file 自己的译码结果：
    //    未实现 CSR（csr_implemented=0）                     → 非法
    //    对只读 CSR（csr_writable=0）存在**写意图**          → 非法
    //      （CSRRS/C(SI/CI) 且 rs1/uimm=x0/0 无写意图，读只读 CSR 合法）
    //    这样避免在 ID 期重复实现一份 CSR 地址图（两处漂移无法自证一致）。
    //  批 (a) 中被判非法的 CSR 指令：不写 rd（由 wb_trap 抑制）、不写 CSR，
    //  并在 retire trace 上作为 trap 事件出现；**不进入 mtvec**（批 (b) 接入）。
    // ==================================================================
    always @(posedge clk) begin
        if (rst || flush_id_ex) begin
            idex_csr_is_q <= 1'b0; idex_csr_imm_q <= 1'b0; idex_csr_we_q <= 1'b0;
            idex_csr_op_q <= 2'b0; idex_csr_addr_q <= 12'b0; idex_csr_uimm_q <= 32'b0;
        end else if (id_ex_hold) begin
            // 与 id_ex_reg 同条件保持
        end else if (!(id_issue_valid && !id_ex_bubble)) begin
            idex_csr_is_q <= 1'b0; idex_csr_imm_q <= 1'b0; idex_csr_we_q <= 1'b0;
            idex_csr_op_q <= 2'b0; idex_csr_addr_q <= 12'b0; idex_csr_uimm_q <= 32'b0;
        end else begin
            // 与 id_ex_reg 的 out_reg_write 同口径：fault/illegal 指令不得写 CSR
            idex_csr_is_q   <= dec_is_csr && !id_fault && !dec_illegal;
            idex_csr_imm_q  <= dec_csr_imm;
            idex_csr_we_q   <= dec_csr_we && !id_fault && !dec_illegal;
            idex_csr_op_q   <= dec_csr_op;
            idex_csr_addr_q <= dec_csr_addr;
            idex_csr_uimm_q <= dec_csr_uimm;
        end
    end

    // EX/MEM 影子：与上面 xm_* 影子同为 "!backend_hold 装载"，故与 ex_* 同拍对位；
    // 有效性再按 riscv_exec 的 valid_i 口径（idex_valid && !redirect_valid）掩码，
    // 使"被 redirect 杀掉的 EX 载荷"不会在这里残留。
    // CSR 写数据在此成形：立即数形式取 uimm，否则取**已转发**的 rs1（ex_ra）。
    always @(posedge clk) begin
        if (rst) begin
            xm_csr_is_q <= 1'b0; xm_csr_we_q <= 1'b0; xm_csr_op_q <= 2'b0;
            xm_csr_addr_q <= 12'b0; xm_csr_wdata_q <= 32'b0;
        end else if (!backend_hold) begin
            xm_csr_is_q    <= idex_csr_is_q && idex_valid && !redirect_valid;
            xm_csr_we_q    <= idex_csr_we_q && idex_valid && !redirect_valid;
            xm_csr_op_q    <= idex_csr_op_q;
            xm_csr_addr_q  <= idex_csr_addr_q;
            xm_csr_wdata_q <= idex_csr_imm_q ? idex_csr_uimm_q : ex_ra;
        end
    end

    // MEM/WB 影子：与上面 mw_* 寄存器同条件（!mem_wb_hold）
    always @(posedge clk) begin
        if (rst) begin
            mw_csr_is_q <= 1'b0; mw_csr_we_q <= 1'b0; mw_csr_op_q <= 2'b0;
            mw_csr_addr_q <= 12'b0; mw_csr_wdata_q <= 32'b0;
        end else if (!mem_wb_hold) begin
            mw_csr_is_q    <= xm_csr_is_q;
            mw_csr_we_q    <= xm_csr_we_q;
            mw_csr_op_q    <= xm_csr_op_q;
            mw_csr_addr_q  <= xm_csr_addr_q;
            mw_csr_wdata_q <= xm_csr_wdata_q;
        end
    end

    // SYSTEM 特权指令影子：与 CSR 影子同条件（fault/illegal 的指令不得带出特权标志）
    always @(posedge clk) begin
        if (rst || flush_id_ex) begin
            idex_sys_q <= 3'b0;
        end else if (id_ex_hold) begin
            // 与 id_ex_reg 同条件保持
        end else if (!(id_issue_valid && !id_ex_bubble)) begin
            idex_sys_q <= 3'b0;
        end else begin
            idex_sys_q <= (id_fault || dec_illegal) ? 3'b0
                                                    : {dec_mret, dec_ebreak, dec_ecall};
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            xm_sys_q <= 3'b0;
        end else if (!backend_hold) begin
            xm_sys_q <= (idex_valid && !redirect_valid) ? idex_sys_q : 3'b0;
        end
    end

    // ==================================================================
    //  批 (b)：同步异常精确陷阱 —— 检测点 = EX/MEM 边界
    //
    //  为什么检测点必须在 EX/MEM 边界（而不是提交点 MEM/WB）：
    //    检出陷阱的当拍，更年轻指令还在 EX（idex）与 ID：EX 那条由
    //    riscv_exec 的 valid_i = idex_valid && !redirect_valid 精确丢弃，
    //    ID 那条由 pipeline_control 的 id_ex_flush / if_id_flush 丢弃，
    //    IF 那条由 if_id_flush 丢弃 —— 都不产生架构效果。
    //    若改在提交点检出，MEM 中那条更年轻指令**无法撤回**：store 的副作用
    //    不可逆（这正是"精确陷阱"的硬要求）。
    //    ⇒ xm（最老未提交指令）即"最老 fault"的判定点：更年轻的故障指令被冲刷，
    //      天然满足"最老 fault 优先提交"。
    //  重定向保持窗：从检出起把 redirect 保持到该指令**提交**，这样
    //    (1) mtvec / mepc 的取值发生在更老的 CSR 写**已生效之后**
    //        （tb_cpu_core_trap 的 mret 场景专门验证：紧邻的 csrrw mepc 必须先落地）；
    //    (2) 与 backend_hold 同拍时（访存故障），保持窗保证后端解除阻塞后
    //        重定向依然生效（pc_reg 的优先级为 redirect > hold_pc）。
    //  陷阱状态（mepc/mcause/mtval）在**提交拍**一次性写入 csr_file：此刻更老指令
    //    已全部提交，故不会覆盖它们的效果；同一拍内 csr_file 内部优先级为
    //    trap > mret > CSR 写。
    // ==================================================================
    // ⚠️ 坑位：`xm_ecall/xm_ebreak/xm_is_mret` 已**上提到 L488 之前**
    //   （`xm_is_mret` 在 L511 就被使用，旧声明在此处 ⇒ 先用后声明；
    //    Icarus 10.2 容忍、13.0 编译失败，见 L398 前坑位注释）。
    // 非法 CSR：未实现地址，或对只读 CSR 存在写意图（只读的**读**仍合法）
    assign xm_csr_bad = xm_csr_is_q && (!csr_chk_impl || (xm_csr_we_q && !csr_chk_wr));

    always @(*) begin
        xm_trap_cause = 4'd0;
        xm_trap_tval  = 32'd0;
        if (xm_valid && xm_fault_q) begin
            // 取指出错：IF 每拍只按指令 PC 发一个取指请求 → 出错地址即该指令 PC
            xm_trap_cause = 4'd1;                              // instruction access fault
            xm_trap_tval  = xm_pc;
        end else if (xm_valid && xm_illegal_q) begin
            xm_trap_cause = 4'd2;                              // illegal instruction
            xm_trap_tval  = xm_instr;
        end else if (xm_valid && xm_csr_bad) begin
            xm_trap_cause = 4'd2;                              // 非法 CSR（未实现 / 写只读）
            xm_trap_tval  = xm_instr;
        end else if (xm_valid && xm_memop && lsu_fault_valid) begin
            if (lsu_fault_misaligned)
                xm_trap_cause = xm_mem_read ? 4'd4 : 4'd6;     // load/store address misaligned
            else
                xm_trap_cause = xm_mem_read ? 4'd5 : 4'd7;     // load/store access fault
            xm_trap_tval  = lsu_fault_addr;
        end else if (xm_valid && xm_ecall) begin
            xm_trap_cause = 4'd11;                             // environment call from M-mode
            xm_trap_tval  = 32'd0;
        end else if (xm_valid && xm_ebreak) begin
            xm_trap_cause = 4'd3;                              // breakpoint
            xm_trap_tval  = 32'd0;
        end
    end

    // ==================================================================
    //  批 (c)：中断采样（D12）—— 与同步异常共用 EX/MEM 边界判定点
    //
    //  采样条件（全部成立才采，缺一不可）：
    //    xm_valid         EX/MEM 处有最老未提交指令（D13 的 mepc 目标必须存在；
    //                     流水线全空时中断等待下一条指令到达，mip 电平保持不丢失）
    //    !xm_memop        该指令不带访存事务。重试语义下 store 不可重放
    //                     （请求一旦发出副作用不可逆），load 虽幂等但请求在途时的
    //                     握手无法安全作废 ⇒ 中断对访存指令推迟：等它提交后
    //                     采下一条最老指令（定时器为电平源，不丢失）
    //    csr_irq_pending  mstatus.MIE && (mie&mip) 门控通过（csr_file 组合输出）
    //    xm_trap_cause==0 同拍无同步异常 —— **异常优先于中断**（D12 验收面）
    //    !sys_hold_q      不在既有重定向保持窗内（不与批 (b) 的陷阱/mret 竞争）
    //  被采样指令以 trap 事件退役（trace_cause 承载 bit31），mepc 记其 PC；
    //  其在 mret 后被重新取指执行、恰好再正常退役一次（重试语义，D13）。
    // ==================================================================
    // NEGCTL：中断抢在同步异常之前（优先级反转）——采样判据丢掉
    // (xm_trap_cause == 4'd0) 项，同拍两者成立时选错源，I4 必须捕获
    assign xm_irq_take = xm_valid && !xm_memop && csr_irq_pending && !sys_hold_q;

    // 统一陷阱 cause：中断优先级反转负控（gen_irq_negctl）会动这里的优先顺序
    assign xm_trap_cause32 = xm_irq_take ? csr_irq_cause : {28'b0, xm_trap_cause};

    assign xm_trap_det = (xm_trap_cause32 != 32'd0) && !sys_hold_q;
    assign sys_redir   = xm_trap_det || (xm_valid && xm_is_mret && !sys_hold_q);
    assign redir_to_mepc = sys_redir ? !xm_trap_det : sys_is_mret_q;

    always @(posedge clk) begin
        if (rst) begin
            sys_hold_q    <= 1'b0;
            sys_is_mret_q <= 1'b0;
        end else if (sys_redir) begin
            sys_hold_q    <= 1'b1;
            sys_is_mret_q <= !xm_trap_det;      // 1 = mret（目标 mepc）
        end else if (mw_valid && !retire_block && (mw_trap_q || mw_mret_q)) begin
            sys_hold_q    <= 1'b0;              // 该指令已提交 → 释放重定向
        end
    end

    wire [31:0] csr_rdata;
    wire        csr_implemented, csr_writable;
    // 陷阱/mret 的重定向目标来自 csr_file 状态（必须接出，不能悬空：
    // 悬空输出在 cpu_core_stage1 内无法作为右值使用）
    // ⚠️ 坑位：`csr_mtvec/csr_mepc` 的声明已**上提到 L425 之前**（那里已作为右值使用；
    //   旧声明在此处 ⇒ 先用后声明，Icarus 13.0 编译失败）。
    // 提交脉冲：与 regfile / retire_trace 的 commit_fire 同源 → 恰好一次
    wire        csr_commit = mw_valid && !retire_block;
    wire        csr_write_intent = mw_csr_is_q && mw_csr_we_q;
    assign      mw_fwd_data = mw_csr_is_q ? csr_rdata : mw_data;
    // csr_file 内部还会再查一次 implemented/writable（双保险）
    wire        csr_write_fire = csr_commit && csr_write_intent &&
                                 csr_implemented && csr_writable;
    // 精确陷阱进入 / mret：都在提交拍脉冲
    assign      trap_commit = csr_commit && mw_trap_q;
    assign      mret_commit = csr_commit && mw_mret_q;

    csr_file u_csr (
        .clk(clk), .rst(rst),
        // 读/写同址：MEM/WB 级 CSR 指令（非 CSR 指令时该影子已被清零 → 地址 0）
        .csr_addr(mw_csr_addr_q),
        .csr_rdata(csr_rdata), .csr_implemented(csr_implemented),
        .csr_writable(csr_writable),
        // 地址合法性查询：接 EX/MEM 级影子（与读端口共用同一份译码函数）
        .csr_chk_addr(xm_csr_addr_q),
        .csr_chk_implemented(csr_chk_impl), .csr_chk_writable(csr_chk_wr),
        .csr_we(csr_write_fire), .csr_op(mw_csr_op_q), .csr_wdata(mw_csr_wdata_q),
        // 批 (b)：精确陷阱进入与 mret（提交拍脉冲，恰好一次）
        // 批 (c)：trap_cause 直连 32 位 mw_trap_cause_q —— 中断时 bit31=1 到达 mcause
        .trap_enter(trap_commit), .trap_pc(mw_pc),
        .trap_cause(mw_trap_cause_q), .trap_tval(mw_trap_tval_q),
        .mret(mret_commit),
        // 批 (c)：中断源真实接入（D14）。timer_irq_i 由 SoC 顶层从定时器外设引回；
        // ext_irq_i 顶层显式接 0（无外部中断源）—— MEIP 路径"已接线、未验证"。
        .timer_irq(timer_irq_i), .ext_irq(ext_irq_i),
        // 状态输出供 TB 层次化观测（mstatus/mtvec/mepc/mcause/mtval/irq_*）；
        // irq_pending/irq_cause 为批 (c) 的采样判定输入（见上方 xm_irq_take）
        .mip(), .mie(), .irq_pending(csr_irq_pending), .irq_cause(csr_irq_cause),
        .mstatus(), .mtvec(csr_mtvec), .mepc(csr_mepc), .mcause(), .mtval()
    );

    wb_stage u_wb (
        .wb_valid(mw_valid), .commit_fire(mw_valid && !retire_block),
        .wb_writes_rd(mw_reg_write), .wb_rd(mw_rd), .wb_data(mw_fwd_data),
        .wb_trap(mw_trap_q), .rd_we(wb_we), .rd_addr(wb_rd), .rd_data(wb_data)
    );
    retire_trace u_trace (
        .clk(clk), .rst(rst), .retire_valid(mw_valid),
        .commit_fire(mw_valid && !retire_block), .retire_pc(mw_pc),
        .retire_instr(mw_instr), .retire_rd(mw_rd), .retire_rd_data(mw_fwd_data),
        .retire_rd_we(wb_we), .retire_trap(mw_trap_q),
        // 批 (c)：直接连 32 位 cause —— 中断退役事件在 trace 上承载 bit31=1
        .retire_cause(mw_trap_cause_q),
        .trace_valid(trace_valid), .trace_order(trace_order), .trace_pc(trace_pc),
        .trace_instr(trace_instr), .trace_rd(trace_rd), .trace_rd_data(trace_rd_data),
        .trace_rd_we(trace_rd_we), .trace_trap(trace_trap),
        .trace_cause(trace_cause)
    );
endmodule
