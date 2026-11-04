// ============================================================================
//        Dual-Issue Full Core (M1 lane0 full path)
//
//        Extends dual_issue_mini_core with lane0 D-side load/store, CSR
//        read/write, precise trap, MRET and machine timer/external interrupts.
//        Lane1 remains ALU-only.  A lane0 aligned SRAM load may pair with an
//        independent lane1 ALU; other lane0 non-ALU instructions serialize.
// ============================================================================
`include "defines.sv"

module dual_issue_full_core #(
    parameter bit DUAL_ISSUE_EN = 1'b1,
    parameter integer M_MODE = 2,
    parameter [31:0] CACHEABLE_BASE = 32'h8000_0000,
    parameter [31:0] CACHEABLE_SIZE = 32'h0001_0000
)(
    input  wire        clk,
    input  wire        rst,

    // 64-bit instruction port
    output wire        i_req_valid,
    input  wire        i_req_ready,
    output wire [31:0] i_req_addr,
    input  wire        i_rsp_valid,
    output wire        i_rsp_ready,
    input  wire [63:0] i_rsp_data,
    input  wire [1:0] i_rsp_error,

    // 32-bit D-side port
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

    input  wire        timer_irq_i,
    input  wire        ext_irq_i,

    output wire        issue0,
    output wire        issue1,
    output wire        retire0_valid,
    output wire        retire1_valid,

    output wire        trace0_valid,
    output wire [63:0] trace0_order,
    output wire [31:0] trace0_pc,
    output wire [31:0] trace0_instr,
    output wire [4:0]  trace0_rd,
    output wire [31:0] trace0_rd_data,
    output wire        trace0_rd_we,
    output wire        trace0_trap,
    output wire [31:0] trace0_cause,

    output wire        trace1_valid,
    output wire [63:0] trace1_order,
    output wire [31:0] trace1_pc,
    output wire [31:0] trace1_instr,
    output wire [4:0]  trace1_rd,
    output wire [31:0] trace1_rd_data,
    output wire        trace1_rd_we,
    output wire        trace1_trap,
    output wire [31:0] trace1_cause,

    output wire [31:0] pc_debug
);

    wire [31:0] wide_pc;
    wire [1:0]  fq_in_ready;
    wire        wf_q0_valid, wf_q1_valid, wf_q0_fault, wf_q1_fault;
    wire [31:0] wf_q0_pc, wf_q0_inst, wf_q1_pc, wf_q1_inst;

    wire        branch_redirect, trap_redirect, mret_redirect, redirect_any;
    wire [31:0] redirect_target;
    wire        commit_trap_fire, commit_flush_young, commit_hold_s1;
    wire [31:0] commit_trap_cause, commit_trap_pc;
    wire        commit0_fire, commit1_fire;

    wide_fetch u_fetch (
        .clk(clk), .rst(rst),
        .i_req_valid(i_req_valid), .i_req_ready(i_req_ready),
        .i_req_addr(i_req_addr), .i_rsp_valid(i_rsp_valid),
        .i_rsp_ready(i_rsp_ready), .i_rsp_data(i_rsp_data), .i_rsp_error(i_rsp_error),
        .redirect_valid(redirect_any), .redirect_target(redirect_target),
        .push_ready(fq_in_ready),
        .q0_valid(wf_q0_valid), .q0_pc(wf_q0_pc), .q0_inst(wf_q0_inst), .q0_fault(wf_q0_fault),
        .q1_valid(wf_q1_valid), .q1_pc(wf_q1_pc), .q1_inst(wf_q1_inst), .q1_fault(wf_q1_fault),
        .pc_debug(pc_debug)
    );

    wire        fq_decode0_valid, fq_decode1_valid;
    wire        fq_out0_valid, fq_out1_valid;
    wire [31:0] fq_out0_pc, fq_out0_inst, fq_out1_pc, fq_out1_inst;
    wire        fq_out0_fault, fq_out1_fault;

    fetch_queue #(.DEPTH(4)) u_fq (
        .clk(clk), .rst(rst),
        .in0_valid(wf_q0_valid), .in0_pc(wf_q0_pc), .in0_inst(wf_q0_inst),
        .in0_fault(wf_q0_fault), .in0_pred_valid(1'b0), .in0_pred_taken(1'b0),
        .in0_pred_target(32'h0),
        .in1_valid(wf_q1_valid), .in1_pc(wf_q1_pc), .in1_inst(wf_q1_inst),
        .in1_fault(wf_q1_fault), .in1_pred_valid(1'b0), .in1_pred_taken(1'b0),
        .in1_pred_target(32'h0),
        .in_ready(fq_in_ready),
        .decode0_valid(fq_decode0_valid), .decode1_valid(fq_decode1_valid),
        .out0_valid(fq_out0_valid), .out0_pc(fq_out0_pc), .out0_inst(fq_out0_inst),
        .out0_fault(fq_out0_fault), .out0_pred_valid(), .out0_pred_taken(),
        .out0_pred_target(),
        .out1_valid(fq_out1_valid), .out1_pc(fq_out1_pc), .out1_inst(fq_out1_inst),
        .out1_fault(fq_out1_fault), .out1_pred_valid(), .out1_pred_taken(),
        .out1_pred_target(),
        .out0_consume(issue0), .out1_consume(issue1), .flush(redirect_any)
    );

    // ----------------------------------------------------------------
    // Lane 0 decode
    // ----------------------------------------------------------------
    wire [4:0]  d0_rs1, d0_rs2, d0_rd;
    wire [31:0] d0_imm;
    wire        d0_reg_we, d0_mem_req, d0_mem_we;
    wire [3:0]  d0_mem_wstrb;
    wire        d0_branch, d0_jal, d0_jalr, d0_lui, d0_auipc;
    wire        d0_uses_rs1, d0_uses_rs2, d0_illegal;
    wire        d0_ecall, d0_ebreak, d0_mret;
    wire [6:0]  d0_opcode, d0_funct7;
    wire [11:0] d0_csr_addr;
    wire        d0_csr_we, d0_csr_imm;
    wire [1:0]  d0_csr_op;
    wire [31:0] d0_csr_uimm;

    id_stage #(.SUPPORT_M(M_MODE == 2), .SUPPORT_ZMMUL(M_MODE == 1)) u_dec0 (
        .rst(rst), .inst_i(fq_out0_inst), .pc_i(fq_out0_pc),
        .inst_valid_i(fq_decode0_valid), .fault_i(fq_out0_fault),
        .pred_valid_i(1'b0), .pred_taken_i(1'b0), .pred_target_i(32'h0),
        .ex_jump_flag_i(1'b0), .rs1_addr_o(d0_rs1), .rs2_addr_o(d0_rs2),
        .imm_o(d0_imm), .reg_we_o(d0_reg_we), .rd_addr_o(d0_rd),
        .mem_req_o(d0_mem_req), .mem_we_o(d0_mem_we), .mem_wstrb_o(d0_mem_wstrb),
        .branch_o(d0_branch), .jal_o(d0_jal), .jalr_o(d0_jalr),
        .lui_o(d0_lui), .auipc_o(d0_auipc),
        .uses_rs1_o(d0_uses_rs1), .uses_rs2_o(d0_uses_rs2),
        .opcode_o(d0_opcode), .funct3_o(), .funct7_o(d0_funct7), .rd_o(),
        .pred_valid_o(), .pred_taken_o(), .pred_target_o(),
        .illegal_instr_o(d0_illegal),
        .csr_addr_o(d0_csr_addr), .csr_we_o(d0_csr_we), .csr_op_o(d0_csr_op),
        .csr_imm_o(d0_csr_imm), .csr_uimm_o(d0_csr_uimm),
        .sys_ecall_o(d0_ecall), .sys_ebreak_o(d0_ebreak), .sys_mret_o(d0_mret)
    );

    // ----------------------------------------------------------------
    // Lane 1 decode (ALU only)
    // ----------------------------------------------------------------
    wire [4:0]  d1_rs1, d1_rs2, d1_rd;
    wire        d1_reg_we, d1_mem_req, d1_branch, d1_jal, d1_jalr, d1_lui, d1_auipc;
    wire        d1_uses_rs1, d1_uses_rs2, d1_illegal, d1_ecall, d1_ebreak, d1_mret;
    wire [6:0]  d1_opcode, d1_funct7;

    id_stage #(.SUPPORT_M(M_MODE == 2), .SUPPORT_ZMMUL(M_MODE == 1)) u_dec1 (
        .rst(rst), .inst_i(fq_out1_inst), .pc_i(fq_out1_pc),
        .inst_valid_i(fq_decode1_valid), .fault_i(fq_out1_fault),
        .pred_valid_i(1'b0), .pred_taken_i(1'b0), .pred_target_i(32'h0),
        .ex_jump_flag_i(1'b0), .rs1_addr_o(d1_rs1), .rs2_addr_o(d1_rs2),
        .imm_o(), .reg_we_o(d1_reg_we), .rd_addr_o(d1_rd),
        .mem_req_o(d1_mem_req), .mem_we_o(), .mem_wstrb_o(),
        .branch_o(d1_branch), .jal_o(d1_jal), .jalr_o(d1_jalr),
        .lui_o(d1_lui), .auipc_o(d1_auipc),
        .uses_rs1_o(d1_uses_rs1), .uses_rs2_o(d1_uses_rs2),
        .opcode_o(d1_opcode), .funct3_o(), .funct7_o(d1_funct7), .rd_o(),
        .pred_valid_o(), .pred_taken_o(), .pred_target_o(),
        .illegal_instr_o(d1_illegal),
        .csr_addr_o(), .csr_we_o(), .csr_op_o(), .csr_imm_o(), .csr_uimm_o(),
        .sys_ecall_o(d1_ecall), .sys_ebreak_o(d1_ebreak), .sys_mret_o(d1_mret)
    );

    function automatic is_alu;
        input [6:0] op;
        input [6:0] f7;
        input branch, jal, jalr, mem_req, lui, auipc;
        input ecall, ebreak, mret, illegal, fault;
        begin
            is_alu = !fault && !illegal && !branch && !jal && !jalr && !mem_req &&
                     !ecall && !ebreak && !mret &&
                     ((op == 7'h13) || ((op == 7'h33) && (f7 != 7'h01)) ||
                      lui || auipc);
        end
    endfunction

    wire d0_is_alu = is_alu(d0_opcode, d0_funct7, d0_branch, d0_jal, d0_jalr,
                            d0_mem_req, d0_lui, d0_auipc, d0_ecall, d0_ebreak,
                            d0_mret, d0_illegal, fq_out0_fault);
    wire d1_is_alu = is_alu(d1_opcode, d1_funct7, d1_branch, d1_jal, d1_jalr,
                            d1_mem_req, d1_lui, d1_auipc, d1_ecall, d1_ebreak,
                            d1_mret, d1_illegal, fq_out1_fault);

    wire d0_is_mdu = !fq_out0_fault && !d0_illegal &&
                     (d0_opcode == 7'h33) && (d0_funct7 == 7'h01);

    wire d0_is_ctl = !fq_out0_fault && !d0_illegal &&
                     (d0_branch || d0_jal || d0_jalr);
    wire d0_is_mem = !fq_out0_fault && !d0_illegal && d0_mem_req;
    wire d0_is_csr = !fq_out0_fault && !d0_illegal && (d0_opcode == 7'h73) &&
                     !d0_ecall && !d0_ebreak && !d0_mret;
    wire d0_is_sys = !fq_out0_fault && !d0_illegal &&
                     (d0_ecall || d0_ebreak || d0_mret);

    // ----------------------------------------------------------------
    // Register file (4R2W)
    // ----------------------------------------------------------------
    wire [31:0] d0_ra, d0_rb, d1_ra, d1_rb;
    wire [31:0] d0_ra_mux, d0_rb_mux, d1_ra_mux, d1_rb_mux;
    reg  [4:0]  r0a_addr, r0b_addr, r1a_addr, r1b_addr;
    always @* begin
        r0a_addr = d0_rs1;
        r0b_addr = d0_rs2;
        r1a_addr = d1_rs1;
        r1b_addr = d1_rs2;
    end

    assign d0_ra = d0_ra_mux;
    assign d0_rb = d0_rb_mux;
    assign d1_ra = d1_ra_mux;
    assign d1_rb = d1_rb_mux;

    wire [31:0] d0_mem_effective_addr = d0_ra + d0_imm;
    wire d0_load_aligned =
        ((fq_out0_inst[14:12] == 3'b000 || fq_out0_inst[14:12] == 3'b100) ||
         ((fq_out0_inst[14:12] == 3'b001 || fq_out0_inst[14:12] == 3'b101) &&
          !d0_mem_effective_addr[0]) ||
         (fq_out0_inst[14:12] == 3'b010 && d0_mem_effective_addr[1:0] == 2'b00));
    // Only pair an aligned ordinary load whose start is inside the configured
    // power-of-two SRAM window. Alignment guarantees byte/half/word accesses
    // cannot cross its upper edge, so avoid a second 32-bit end-address adder.
    // ROM, MMIO, unmapped, misaligned and stores remain lane0-only.
    wire d0_load_pairable = d0_is_mem && !d0_mem_we && d0_load_aligned &&
        ((d0_mem_effective_addr & ~(CACHEABLE_SIZE - 32'd1)) == CACHEABLE_BASE);

    wire [31:0] cw0_data, cw1_data;
    wire        cw0_we, cw1_we;
    wire [4:0]  cw0_rd, cw1_rd;

    regfile_4r2w u_rf (
        .clk(clk), .rst(rst),
        .r0a_addr(r0a_addr), .r0a_data(d0_ra_mux),
        .r0b_addr(r0b_addr), .r0b_data(d0_rb_mux),
        .r1a_addr(r1a_addr), .r1a_data(d1_ra_mux),
        .r1b_addr(r1b_addr), .r1b_data(d1_rb_mux),
        .w0_we(cw0_we), .w0_bypass_we(cw0_we),
        .w0_rd(cw0_rd), .w0_bypass_rd(cw0_rd),
        .w0_data(cw0_data), .w0_bypass_data(cw0_data),
        .w1_we(cw1_we), .w1_bypass_we(cw1_we),
        .w1_rd(cw1_rd), .w1_bypass_rd(cw1_rd),
        .w1_data(cw1_data), .w1_bypass_data(cw1_data)
    );

    // ----------------------------------------------------------------
    // Issue / ALU path
    // ----------------------------------------------------------------
    // ⚠️ 坑位：仅发射合法分类会使illegal永远卡队首；所有有效队首
    // 都进入lane0，已有r0_trap_q负责抑制副作用并精确陷入（PR66 R1）。
    wire s0_valid = fq_out0_valid && !d0_illegal; // NEGCTL: filter illegal head
    wire s1_valid = DUAL_ISSUE_EN && fq_out1_valid && d1_is_alu;

    wire backend_stall, slot1_stall;
    wire alu_issue0, alu_issue1;
    wire alu_w0_valid, alu_w0_we;
    wire [4:0]  alu_w0_rd;
    wire [31:0] alu_w0_data;
    wire alu_w1_valid, alu_w1_we;
    wire [4:0]  alu_w1_rd;
    wire [31:0] alu_w1_data;
    wire ex0_branch_request, ex0_branch_taken;
    wire [31:0] ex0_branch_pc, ex0_branch_source;

    // issue_arb's legacy s0_is_alu name is a pair-eligibility input here:
    // selected SRAM loads share the one LSU and may admit an independent ALU.
    dual_alu_path u_alu (
        .clk(clk), .rst(rst),
        .s0_valid(s0_valid), .s0_illegal(d0_illegal),
        .s0_is_alu(d0_is_alu || d0_load_pairable),
        .s0_reg_write(d0_reg_we), .s0_rs1(d0_rs1), .s0_rs2(d0_rs2),
        .s0_uses_rs1(d0_uses_rs1), .s0_uses_rs2(d0_uses_rs2), .s0_rd(d0_rd),
        .s0_pc(fq_out0_pc), .s0_instr(fq_out0_inst), .s0_ra(d0_ra), .s0_rb(d0_rb),
        .s1_valid(s1_valid), .s1_illegal(d1_illegal), .s1_is_alu(d1_is_alu),
        .s1_reg_write(d1_reg_we), .s1_rs1(d1_rs1), .s1_rs2(d1_rs2),
        .s1_uses_rs1(d1_uses_rs1), .s1_uses_rs2(d1_uses_rs2), .s1_rd(d1_rd),
        .s1_pc(fq_out1_pc), .s1_instr(fq_out1_inst), .s1_ra(d1_ra), .s1_rb(d1_rb),
        .backend_stall(backend_stall),
        .issue0(alu_issue0), .issue1(alu_issue1), .slot1_stall(slot1_stall),
        .w0_valid(alu_w0_valid), .w0_we(alu_w0_we), .w0_rd(alu_w0_rd),
        .w0_data(alu_w0_data),
        .ex0_branch_request(ex0_branch_request),
        .ex0_branch_taken(ex0_branch_taken),
        .ex0_branch_pc(ex0_branch_pc),
        .ex0_branch_source(ex0_branch_source),
        .w1_valid(alu_w1_valid), .w1_we(alu_w1_we), .w1_rd(alu_w1_rd),
        .w1_data(alu_w1_data)
    );

    assign issue0 = alu_issue0;
    assign issue1 = alu_issue1;

    // ----------------------------------------------------------------
    // D-side LSU (lane0)
    // ----------------------------------------------------------------
    wire        lsu_req_valid, lsu_req_write;
    wire [31:0] lsu_req_addr, lsu_req_wdata;
    wire [3:0]  lsu_req_wstrb;
    wire        lsu_wb_valid;
    wire [31:0] lsu_result;
    wire        lsu_fault_valid, lsu_fault_misaligned;
    wire [31:0] lsu_fault_addr;
    wire        lsu_stall;
    wire        mem_fault_ack;

    riscv_lsu u_lsu (
        .clk_i(clk), .rst_i(rst),
        .valid_i(issue0 && d0_is_mem),
        .opcode_i(fq_out0_inst),
        .pc_i(fq_out0_pc),
        .ra_operand_i(d0_ra),
        .rb_operand_i(d0_rb),
        .hold_i(1'b0),
        .req_valid_o(lsu_req_valid),
        .req_ready_i(d_req_ready),
        .req_addr_o(lsu_req_addr),
        .req_write_o(lsu_req_write),
        .req_wdata_o(lsu_req_wdata),
        .req_wstrb_o(lsu_req_wstrb),
        .rsp_valid_i(d_rsp_valid),
        .rsp_ready_o(d_rsp_ready),
        .rsp_rdata_i(d_rsp_rdata),
        .rsp_error_i(d_rsp_error),
        .fault_valid_o(lsu_fault_valid),
        .fault_ready_i(mem_fault_ack),
        .valid_o(lsu_wb_valid),
        .result_o(lsu_result),
        .fault_o(),
        .fault_pc_o(),
        .fault_rd_o(),
        .fault_misaligned_o(lsu_fault_misaligned),
        .fault_addr_o(lsu_fault_addr),
        .stall_o(lsu_stall),
        .rd_idx_o(),
        .load_not_ready_o(),
        .mem_advanceable_o()
    );

    assign d_req_valid = lsu_req_valid;
    assign d_req_addr  = lsu_req_addr;
    assign d_req_write = lsu_req_write;
    assign d_req_wdata = lsu_req_wdata;
    assign d_req_wstrb = lsu_req_wstrb;

    // Reuse exactly the single-issue rv32im_unit (same bytes as board source
    // 8718956). M instructions issue alone; keep their retirement shadow until
    // done, so younger ALUs cannot overwrite the destination/result metadata.
    reg mdu_pending_q;
    wire mdu_ready, mdu_done;
    wire [31:0] mdu_result;
    rv32im_unit #(.DIV_ENABLE(M_MODE == 2)) u_mdu (
        .clk_i(clk), .rst_i(rst || trap_redirect),
        .start_i(issue0 && d0_is_mdu), .funct3_i(fq_out0_inst[14:12]),
        .operand_a_i(d0_ra), .operand_b_i(d0_rb),
        .ready_o(mdu_ready), .done_o(mdu_done), .result_o(mdu_result)
    );
    always @(posedge clk) begin
        if (rst || trap_redirect) mdu_pending_q <= 1'b0;
        else begin
            if (commit0_fire && mdu_pending_q) mdu_pending_q <= 1'b0;
            if (issue0 && d0_is_mdu) mdu_pending_q <= 1'b1;
        end
    end

    // ----------------------------------------------------------------
    // CSR file (reused from Stage1, machine mode only)
    // ----------------------------------------------------------------
    wire [11:0] csr_addr_port;
    wire [31:0] csr_rdata;
    wire        csr_impl, csr_writable;
    wire        csr_chk_impl, csr_chk_writable;
    wire        csr_irq_pending;
    wire [31:0] csr_irq_cause;
    wire [31:0] csr_mtvec, csr_mepc;
    wire        csr_we_fire;
    wire        mret_commit;

    // Shadow/pipeline state declarations are hoisted before their first use
    // (Icarus elaboration requires declaration-before-use for module ports).
    reg [31:0] r0_pc_q, r0_instr_q, r0_csr_wdata_q, r0_csr_rdata_q;
    reg [31:0] r0_cause_q, r0_tval_q;
    reg [4:0]  r0_rd_q;
    reg [11:0] r0_csr_addr_q;
    reg [1:0]  r0_csr_op_q;
    reg        r0_writes_rd_q, r0_is_alu_q, r0_mem_we_q, r0_is_csr_q;
    reg        r0_csr_we_q, r0_mret_q, r0_trap_q;
    reg        r0_mem_pending_q, r0_csr_pending_q;
    reg [31:0] r1_pc_q, r1_instr_q;
    reg [4:0]  r1_rd_q;
    reg        r1_writes_rd_q;
    reg        r1_load_pair_pending_q;
    reg [31:0] r1_load_pair_result_q;
    reg [31:0] s0_cause_final;
    reg [31:0] trap_tval_final;

    csr_file u_csr (
        .clk(clk), .rst(rst),
        .csr_addr(csr_addr_port),
        .csr_rdata(csr_rdata),
        .csr_implemented(csr_impl),
        .csr_writable(csr_writable),
        .csr_chk_addr(d0_csr_addr),
        .csr_chk_implemented(csr_chk_impl),
        .csr_chk_writable(csr_chk_writable),
        .csr_we(csr_we_fire),
        .csr_op(r0_csr_op_q),
        .csr_wdata(r0_csr_wdata_q),
        .trap_enter(commit_trap_fire),
        .trap_pc(commit_trap_pc),
        .trap_cause(commit_trap_cause),
        .trap_tval(trap_tval_final),
        .mret(mret_commit),
        .timer_irq(timer_irq_i),
        .ext_irq(ext_irq_i),
        .mip(), .mie(),
        .irq_pending(csr_irq_pending),
        .irq_cause(csr_irq_cause),
        .mstatus(), .mtvec(csr_mtvec), .mepc(csr_mepc),
        .mcause(), .mtval()
    );

    wire d0_csr_bad = d0_is_csr &&
                      (!csr_chk_impl || (d0_csr_we && !csr_chk_writable));
    wire d0_decode_trap = fq_out0_fault || d0_illegal || d0_csr_bad ||
                          d0_ecall || d0_ebreak;

    // ----------------------------------------------------------------
    // Retirement payload shadows
    // ----------------------------------------------------------------
    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            r0_pc_q <= 32'h0; r0_instr_q <= 32'h0;
            r0_csr_wdata_q <= 32'h0; r0_csr_rdata_q <= 32'h0;
            r0_cause_q <= 32'h0; r0_tval_q <= 32'h0;
            r0_rd_q <= 5'h0; r0_csr_addr_q <= 12'h0; r0_csr_op_q <= 2'b0;
            r0_writes_rd_q <= 1'b0; r0_is_alu_q <= 1'b0;
            r0_mem_we_q <= 1'b0; r0_is_csr_q <= 1'b0;
            r0_csr_we_q <= 1'b0; r0_mret_q <= 1'b0; r0_trap_q <= 1'b0;
            r1_pc_q <= 32'h0; r1_instr_q <= 32'h0;
            r1_rd_q <= 5'h0; r1_writes_rd_q <= 1'b0;
        end else begin
            if (issue0) begin
                r0_pc_q        <= fq_out0_pc;
                r0_instr_q     <= fq_out0_inst;
                r0_rd_q        <= d0_rd;
                r0_writes_rd_q <= d0_reg_we;
                r0_is_alu_q    <= d0_is_alu;
                r0_mem_we_q    <= d0_mem_we;
                r0_is_csr_q    <= d0_is_csr;
                r0_csr_addr_q  <= d0_csr_addr;
                r0_csr_op_q    <= d0_csr_op;
                r0_csr_we_q    <= d0_csr_we;
                r0_csr_wdata_q <= d0_csr_imm ? d0_csr_uimm : d0_ra;
                r0_csr_rdata_q <= csr_rdata;
                r0_mret_q      <= d0_mret;
                r0_trap_q      <= d0_decode_trap;
                r0_cause_q     <= fq_out0_fault  ? 32'd1  :
                                  d0_illegal      ? 32'd2  :
                                  d0_csr_bad      ? 32'd2  :
                                  d0_ecall        ? 32'd11 :
                                  d0_ebreak       ? 32'd3  : 32'd0;
                r0_tval_q      <= fq_out0_fault  ? fq_out0_pc :
                                  (d0_illegal || d0_csr_bad) ? fq_out0_inst : 32'd0;
            end else begin
                if (commit0_fire) begin
                    r0_mret_q <= 1'b0;
                    r0_trap_q <= 1'b0;
                    r0_is_alu_q <= 1'b0;
                    r0_is_csr_q <= 1'b0;
                    r0_csr_we_q <= 1'b0;
                end
            end

            if (issue1) begin
                r1_pc_q        <= fq_out1_pc;
                r1_instr_q     <= fq_out1_inst;
                r1_rd_q        <= d1_rd;
                r1_writes_rd_q <= d1_reg_we;
            end
        end
    end

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            r0_mem_pending_q <= 1'b0;
            r0_csr_pending_q <= 1'b0;
            r1_load_pair_pending_q <= 1'b0;
            r1_load_pair_result_q <= 32'h0;
        end else begin
            if (trap_redirect) begin
                r0_mem_pending_q <= 1'b0;
                r0_csr_pending_q <= 1'b0;
                r1_load_pair_pending_q <= 1'b0;
            end else begin
                if (commit0_fire && r0_mem_pending_q)
                    r0_mem_pending_q <= 1'b0;
                if (commit0_fire && r0_csr_pending_q)
                    r0_csr_pending_q <= 1'b0;
                if (commit1_fire && r1_load_pair_pending_q)
                    r1_load_pair_pending_q <= 1'b0;
            end
            if (issue0 && d0_is_mem)
                r0_mem_pending_q <= 1'b1;
            if (issue0 && d0_is_csr)
                r0_csr_pending_q <= 1'b1;
            if (issue1 && d0_load_pairable)
                r1_load_pair_pending_q <= 1'b1;
            if (r1_load_pair_pending_q && alu_w1_valid)
                r1_load_pair_result_q <= alu_w1_data;
        end
    end

    // ----------------------------------------------------------------
    // Lane0 final writeback / trap muxes
    // ----------------------------------------------------------------
    wire        w0_valid_final;
    wire [4:0]  w0_rd_final;
    wire [31:0] w0_data_final;
    wire        mem_wb_valid = r0_mem_pending_q && (lsu_wb_valid || lsu_fault_valid);
    wire branch_misaligned = alu_w0_valid && ex0_branch_request &&
                             !r0_trap_q && (|ex0_branch_pc[1:0]);
    wire        irq_take = w0_valid_final && !r0_trap_q && !branch_misaligned &&
                           !r0_mem_pending_q && csr_irq_pending;

    assign w0_valid_final = r0_mem_pending_q ? mem_wb_valid :
                            (mdu_pending_q ? mdu_done : alu_w0_valid);
    assign w0_rd_final    = r0_rd_q;
    assign w0_data_final  = r0_mem_pending_q ? lsu_result :
                            mdu_pending_q ? mdu_result :
                            (r0_is_csr_q ? r0_csr_rdata_q : alu_w0_data);

    wire s0_trap_final = r0_mem_pending_q ? lsu_fault_valid
                                          : (r0_trap_q || branch_misaligned || irq_take);

    always @* begin
        if (r0_mem_pending_q && lsu_fault_valid) begin
            if (lsu_fault_misaligned)
                s0_cause_final = r0_mem_we_q ? 32'd6 : 32'd4;
            else
                s0_cause_final = r0_mem_we_q ? 32'd7 : 32'd5;
            trap_tval_final = lsu_fault_addr;
        end else if (branch_misaligned) begin
            s0_cause_final = 32'd0;
            trap_tval_final = ex0_branch_pc;
        end else if (irq_take) begin
            s0_cause_final = csr_irq_cause;
            trap_tval_final = 32'd0;
        end else begin
            s0_cause_final = r0_cause_q;
            trap_tval_final = r0_tval_q;
        end
    end

    assign csr_addr_port = r0_csr_pending_q ? r0_csr_addr_q : d0_csr_addr;
    assign mem_fault_ack = commit_trap_fire && r0_mem_pending_q;

    // ----------------------------------------------------------------
    // Dual commit
    // ----------------------------------------------------------------
    wire s1_retire_valid = alu_w1_valid || r1_load_pair_pending_q;
    wire [31:0] s1_retire_data = alu_w1_valid ? alu_w1_data : r1_load_pair_result_q;

    dual_commit u_commit (
        .s0_valid(w0_valid_final), .s0_trap(s0_trap_final),
        .s0_writes_rd(r0_writes_rd_q), .s0_rd(w0_rd_final),
        .s0_data(w0_data_final), .s0_cause(s0_cause_final), .s0_pc(r0_pc_q),
        .s1_valid(s1_retire_valid), .s1_trap(1'b0),
        .s1_writes_rd(r1_writes_rd_q), .s1_rd(r1_rd_q),
        .s1_data(s1_retire_data), .s1_cause(32'h0), .s1_pc(r1_pc_q),
        .commit0_fire(commit0_fire), .commit1_fire(commit1_fire),
        .trap_fire(commit_trap_fire), .trap_cause(commit_trap_cause),
        .trap_pc(commit_trap_pc), .flush_young(commit_flush_young),
        .hold_s1(commit_hold_s1),
        .w0_we(cw0_we), .w0_rd(cw0_rd), .w0_data(cw0_data),
        .w1_we(cw1_we), .w1_rd(cw1_rd), .w1_data(cw1_data)
    );

    assign retire0_valid = commit0_fire;
    assign retire1_valid = commit1_fire;

    // ----------------------------------------------------------------
    // Redirect / stall / commit pulses
    // ----------------------------------------------------------------
    assign branch_redirect = alu_w0_valid && ex0_branch_request && !s0_trap_final;
    assign trap_redirect   = commit_trap_fire;
    assign mret_redirect   = commit0_fire && r0_mret_q && !s0_trap_final;
    assign redirect_any    = branch_redirect | trap_redirect | mret_redirect;
    assign redirect_target = trap_redirect ? csr_mtvec :
                             mret_redirect ? csr_mepc : ex0_branch_pc;

    assign backend_stall = redirect_any | r0_mem_pending_q | r0_csr_pending_q |
                           mdu_pending_q;

    assign csr_we_fire = commit0_fire && r0_is_csr_q && r0_csr_we_q &&
                         !s0_trap_final;
    assign mret_commit = commit0_fire && r0_mret_q && !s0_trap_final;

    // ----------------------------------------------------------------
    // Retirement trace
    // ----------------------------------------------------------------
    dual_retire_trace u_trace (
        .clk(clk), .rst(rst),
        .commit0_valid(commit0_fire), .commit0_pc(r0_pc_q),
        .commit0_instr(r0_instr_q), .commit0_rd(cw0_rd),
        .commit0_rd_data(cw0_data), .commit0_rd_we(cw0_we),
        .commit0_trap(commit_trap_fire), .commit0_cause(commit_trap_cause),
        .commit1_valid(commit1_fire), .commit1_pc(r1_pc_q),
        .commit1_instr(r1_instr_q), .commit1_rd(cw1_rd),
        .commit1_rd_data(cw1_data), .commit1_rd_we(cw1_we),
        .commit1_trap(1'b0), .commit1_cause(32'h0),
        .trace0_valid(trace0_valid), .trace0_order(trace0_order),
        .trace0_pc(trace0_pc), .trace0_instr(trace0_instr),
        .trace0_rd(trace0_rd), .trace0_rd_data(trace0_rd_data),
        .trace0_rd_we(trace0_rd_we), .trace0_trap(trace0_trap),
        .trace0_cause(trace0_cause),
        .trace1_valid(trace1_valid), .trace1_order(trace1_order),
        .trace1_pc(trace1_pc), .trace1_instr(trace1_instr),
        .trace1_rd(trace1_rd), .trace1_rd_data(trace1_rd_data),
        .trace1_rd_we(trace1_rd_we), .trace1_trap(trace1_trap),
        .trace1_cause(trace1_cause)
    );

endmodule
