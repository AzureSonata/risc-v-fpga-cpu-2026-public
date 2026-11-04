// ============================================================================
//        Dual-Issue Mini Core (M1 vertical slice, ALU-only, 64-bit fetch)
//
//        Vertical integration:
//          wide_fetch(64b) -> fetch_queue -> dual id_stage
//                          -> dual_alu_path -> regfile_4r2w (2 writes)
//
//        Scope: ordinary integer ALU only.  No branches, JAL/JALR, LSU, MDU,
//        CSR, traps or interrupts.  No cross-group forwarding yet; the test
//        program uses independent instructions.
//
//        DUAL_ISSUE_EN=0 forces lane1 off for a same-source single/dual
//        comparison.  This module is a vertical slice, not a replacement for
//        cpu_core_stage1.
// ============================================================================
`include "defines.sv"

module dual_issue_mini_core #(
    parameter bit DUAL_ISSUE_EN = 1'b1
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
    wire        branch_redirect;
    wire        trap_redirect;
    wire        redirect_any;
    wire [31:0] redirect_target;
    wire        commit_trap_fire, commit_flush_young, commit_hold_s1;
    wire [31:0] commit_trap_cause, commit_trap_pc;
    wire [1:0]  fq_in_ready;
    wire        wf_q0_valid, wf_q1_valid;
    wire [31:0] wf_q0_pc, wf_q0_inst, wf_q1_pc, wf_q1_inst;

    wide_fetch u_fetch (
        .clk(clk), .rst(rst),
        .i_req_valid(i_req_valid), .i_req_ready(i_req_ready),
        .i_req_addr(i_req_addr), .i_rsp_valid(i_rsp_valid),
        .i_rsp_ready(i_rsp_ready), .i_rsp_data(i_rsp_data), .i_rsp_error(2'b00),
        .redirect_valid(redirect_any), .redirect_target(redirect_target),
        .push_ready(fq_in_ready),
        .q0_valid(wf_q0_valid), .q0_pc(wf_q0_pc), .q0_inst(wf_q0_inst),
        .q1_valid(wf_q1_valid), .q1_pc(wf_q1_pc), .q1_inst(wf_q1_inst),
        .pc_debug(wide_pc)
    );

    wire fq_out0_valid, fq_out1_valid;
    wire [31:0] fq_out0_pc, fq_out0_inst, fq_out1_pc, fq_out1_inst;
    wire fq_out0_fault, fq_out1_fault;

    fetch_queue #(.DEPTH(4)) u_fq (
        .clk(clk), .rst(rst),
        .in0_valid(wf_q0_valid), .in0_pc(wf_q0_pc), .in0_inst(wf_q0_inst),
        .in0_fault(1'b0), .in0_pred_valid(1'b0), .in0_pred_taken(1'b0),
        .in0_pred_target(32'h0),
        .in1_valid(wf_q1_valid), .in1_pc(wf_q1_pc), .in1_inst(wf_q1_inst),
        .in1_fault(1'b0), .in1_pred_valid(1'b0), .in1_pred_taken(1'b0),
        .in1_pred_target(32'h0),
        .in_ready(fq_in_ready),
        .out0_valid(fq_out0_valid), .out0_pc(fq_out0_pc), .out0_inst(fq_out0_inst),
        .out0_fault(fq_out0_fault), .out0_pred_valid(), .out0_pred_taken(),
        .out0_pred_target(),
        .out1_valid(fq_out1_valid), .out1_pc(fq_out1_pc), .out1_inst(fq_out1_inst),
        .out1_fault(fq_out1_fault), .out1_pred_valid(), .out1_pred_taken(),
        .out1_pred_target(),
        .out0_consume(issue0), .out1_consume(issue1), .flush(redirect_any)
    );

    // ---- Lane 0 decode ----
    wire [4:0] d0_rs1, d0_rs2, d0_rd;
    wire d0_reg_we, d0_mem_req, d0_branch, d0_jal, d0_jalr, d0_lui, d0_auipc;
    wire d0_uses_rs1, d0_uses_rs2, d0_illegal, d0_ecall, d0_ebreak, d0_mret;
    wire [6:0] d0_opcode, d0_funct7;

    id_stage #(.SUPPORT_M(1'b0), .SUPPORT_ZMMUL(1'b0)) u_dec0 (
        .rst(rst), .inst_i(fq_out0_inst), .pc_i(fq_out0_pc),
        .inst_valid_i(fq_out0_valid), .fault_i(fq_out0_fault),
        .pred_valid_i(1'b0), .pred_taken_i(1'b0), .pred_target_i(32'h0),
        .ex_jump_flag_i(1'b0), .rs1_addr_o(d0_rs1), .rs2_addr_o(d0_rs2),
        .imm_o(), .reg_we_o(d0_reg_we), .rd_addr_o(d0_rd),
        .mem_req_o(d0_mem_req), .mem_we_o(), .mem_wstrb_o(),
        .branch_o(d0_branch), .jal_o(d0_jal), .jalr_o(d0_jalr),
        .lui_o(d0_lui), .auipc_o(d0_auipc),
        .uses_rs1_o(d0_uses_rs1), .uses_rs2_o(d0_uses_rs2),
        .opcode_o(d0_opcode), .funct3_o(), .funct7_o(d0_funct7), .rd_o(),
        .pred_valid_o(), .pred_taken_o(), .pred_target_o(),
        .illegal_instr_o(d0_illegal),
        .csr_addr_o(), .csr_we_o(), .csr_op_o(), .csr_imm_o(), .csr_uimm_o(),
        .sys_ecall_o(d0_ecall), .sys_ebreak_o(d0_ebreak), .sys_mret_o(d0_mret)
    );

    // ---- Lane 1 decode ----
    wire [4:0] d1_rs1, d1_rs2, d1_rd;
    wire d1_reg_we, d1_mem_req, d1_branch, d1_jal, d1_jalr, d1_lui, d1_auipc;
    wire d1_uses_rs1, d1_uses_rs2, d1_illegal, d1_ecall, d1_ebreak, d1_mret;
    wire [6:0] d1_opcode, d1_funct7;

    id_stage #(.SUPPORT_M(1'b0), .SUPPORT_ZMMUL(1'b0)) u_dec1 (
        .rst(rst), .inst_i(fq_out1_inst), .pc_i(fq_out1_pc),
        .inst_valid_i(fq_out1_valid), .fault_i(fq_out1_fault),
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
    // Lane0 may execute control flow; lane1 remains ALU-only in this slice.
    wire d0_is_ctl = !fq_out0_fault && !d0_illegal &&
                     (d0_branch || d0_jal || d0_jalr);
    wire d0_is_trap = fq_out0_valid && (fq_out0_fault || d0_illegal);

    wire [31:0] d0_ra, d0_rb, d1_ra, d1_rb;
    reg  [4:0] r0a_addr, r0b_addr, r1a_addr, r1b_addr;
    always @* begin
        r0a_addr = d0_rs1;
        r0b_addr = d0_rs2;
        r1a_addr = d1_rs1;
        r1b_addr = d1_rs2;
    end

    wire [31:0] w0_data, w1_data;
    wire        w0_we, w1_we, w0_valid, w1_valid;
    wire [4:0]  w0_rd, w1_rd;
    wire        cw0_we, cw1_we;
    wire [4:0]  cw0_rd, cw1_rd;
    wire [31:0] cw0_data, cw1_data;

    regfile_4r2w u_rf (
        .clk(clk), .rst(rst),
        .r0a_addr(r0a_addr), .r0a_data(d0_ra),
        .r0b_addr(r0b_addr), .r0b_data(d0_rb),
        .r1a_addr(r1a_addr), .r1a_data(d1_ra),
        .r1b_addr(r1b_addr), .r1b_data(d1_rb),
        .w0_we(cw0_we), .w0_bypass_we(cw0_we),
        .w0_rd(cw0_rd), .w0_bypass_rd(cw0_rd),
        .w0_data(cw0_data), .w0_bypass_data(cw0_data),
        .w1_we(cw1_we), .w1_bypass_we(cw1_we),
        .w1_rd(cw1_rd), .w1_bypass_rd(cw1_rd),
        .w1_data(cw1_data), .w1_bypass_data(cw1_data)
    );

    wire s0_valid = fq_out0_valid && (d0_is_alu || d0_is_ctl || d0_is_trap);
    wire s1_valid = DUAL_ISSUE_EN && fq_out1_valid && d1_is_alu;

    wire ex0_branch_request, ex0_branch_taken;
    wire [31:0] ex0_branch_pc, ex0_branch_source;

    dual_alu_path u_alu (
        .clk(clk), .rst(rst),
        .s0_valid(s0_valid), .s0_illegal(d0_illegal), .s0_is_alu(d0_is_alu),
        .s0_reg_write(d0_reg_we), .s0_rs1(d0_rs1), .s0_rs2(d0_rs2),
        .s0_uses_rs1(d0_uses_rs1), .s0_uses_rs2(d0_uses_rs2), .s0_rd(d0_rd),
        .s0_pc(fq_out0_pc), .s0_instr(fq_out0_inst), .s0_ra(d0_ra), .s0_rb(d0_rb),
        .s1_valid(s1_valid), .s1_illegal(d1_illegal), .s1_is_alu(d1_is_alu),
        .s1_reg_write(d1_reg_we), .s1_rs1(d1_rs1), .s1_rs2(d1_rs2),
        .s1_uses_rs1(d1_uses_rs1), .s1_uses_rs2(d1_uses_rs2), .s1_rd(d1_rd),
        .s1_pc(fq_out1_pc), .s1_instr(fq_out1_inst), .s1_ra(d1_ra), .s1_rb(d1_rb),
        .backend_stall(redirect_any),
        .issue0(issue0), .issue1(issue1), .slot1_stall(),
        .w0_valid(w0_valid), .w0_we(w0_we), .w0_rd(w0_rd), .w0_data(w0_data),
        .w1_valid(w1_valid), .w1_we(w1_we), .w1_rd(w1_rd), .w1_data(w1_data),
        .ex0_branch_request(ex0_branch_request),
        .ex0_branch_taken(ex0_branch_taken),
        .ex0_branch_pc(ex0_branch_pc),
        .ex0_branch_source(ex0_branch_source)
    );

    assign branch_redirect = w0_valid && ex0_branch_request;
    assign trap_redirect   = commit_trap_fire;
    assign redirect_any    = branch_redirect | trap_redirect;
    assign redirect_target = trap_redirect ? 32'h0000_0100 : ex0_branch_pc;

    // Retirement payload shadows: captured at issue, consumed one cycle later
    // when riscv_exec's registered writeback appears.
    reg [31:0] r0_pc_q, r0_instr_q, r1_pc_q, r1_instr_q;
    reg        r0_writes_rd_q, r1_writes_rd_q;
    reg        r0_trap_q, r1_trap_q;
    reg [31:0] r0_cause_q, r1_cause_q;
    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            r0_pc_q <= 32'h0; r0_instr_q <= 32'h0; r0_writes_rd_q <= 1'b0;
            r1_pc_q <= 32'h0; r1_instr_q <= 32'h0; r1_writes_rd_q <= 1'b0;
            r0_trap_q <= 1'b0; r1_trap_q <= 1'b0;
            r0_cause_q <= 32'h0; r1_cause_q <= 32'h0;
        end else begin
            if (issue0) begin
                r0_pc_q        <= fq_out0_pc;
                r0_instr_q     <= fq_out0_inst;
                r0_writes_rd_q <= d0_reg_we;
                r0_trap_q      <= d0_is_trap;
                r0_cause_q     <= fq_out0_fault ? 32'd1 :
                                  (d0_illegal ? 32'd2 : 32'h0);
            end
            if (issue1) begin
                r1_pc_q        <= fq_out1_pc;
                r1_instr_q     <= fq_out1_inst;
                r1_writes_rd_q <= d1_reg_we;
            end
        end
    end

    dual_commit u_commit (
        .s0_valid(w0_valid), .s0_trap(r0_trap_q), .s0_writes_rd(r0_writes_rd_q),
        .s0_rd(w0_rd), .s0_data(w0_data), .s0_cause(r0_cause_q), .s0_pc(r0_pc_q),
        .s1_valid(w1_valid), .s1_trap(r1_trap_q), .s1_writes_rd(r1_writes_rd_q),
        .s1_rd(w1_rd), .s1_data(w1_data), .s1_cause(r1_cause_q), .s1_pc(r1_pc_q),
        .commit0_fire(retire0_valid), .commit1_fire(retire1_valid),
        .trap_fire(commit_trap_fire), .trap_cause(commit_trap_cause),
        .trap_pc(commit_trap_pc), .flush_young(commit_flush_young),
        .hold_s1(commit_hold_s1),
        .w0_we(cw0_we), .w0_rd(cw0_rd), .w0_data(cw0_data),
        .w1_we(cw1_we), .w1_rd(cw1_rd), .w1_data(cw1_data)
    );

    dual_retire_trace u_trace (
        .clk(clk), .rst(rst),
        .commit0_valid(retire0_valid), .commit0_pc(r0_pc_q),
        .commit0_instr(r0_instr_q), .commit0_rd(cw0_rd),
        .commit0_rd_data(cw0_data), .commit0_rd_we(cw0_we),
        .commit0_trap(commit_trap_fire), .commit0_cause(commit_trap_cause),
        .commit1_valid(retire1_valid), .commit1_pc(r1_pc_q),
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

    assign pc_debug = wide_pc;

endmodule
