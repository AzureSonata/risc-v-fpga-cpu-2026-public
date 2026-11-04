// ============================================================================
//        Dual ALU Path (M1-4 / first executable slice)
//
//        Wires together the first three M1 building blocks:
//          issue_arb -> two riscv_exec instances -> two writeback ports.
//
//        Scope:
//        - s0_is_alu / s1_is_alu are provided by the caller's decoder.
//        - Only ALU+ALU is accepted by issue_arb in this version.
//        - No branch redirect, load/store, CSR, or trap side effects here; this
//          module is the executable ALU slice used by the integration step.
//        - Lane1 is gated by issue1, so a stalled/blocked second instruction
//          cannot create a writeback.
//
//        The caller may connect the two writeback ports to regfile_4r2w.
// ============================================================================
`include "defines.sv"

module dual_alu_path #(
    // Keep the legacy branch_pc contract for the mini-core. The complete
    // core selects taken/fall-through after the EX register boundary.
    parameter integer BRANCH_PC_RAW = 0
)(
    input  wire        clk,
    input  wire        rst,

    input  wire        s0_valid,
    input  wire        s0_illegal,
    input  wire        s0_is_alu,
    input  wire        s0_reg_write,
    input  wire [4:0]  s0_rs1,
    input  wire [4:0]  s0_rs2,
    input  wire        s0_uses_rs1,
    input  wire        s0_uses_rs2,
    input  wire [4:0]  s0_rd,
    input  wire [31:0] s0_pc,
    input  wire [31:0] s0_instr,
    input  wire [31:0] s0_ra,
    input  wire [31:0] s0_rb,

    input  wire        s1_valid,
    input  wire        s1_illegal,
    input  wire        s1_is_alu,
    input  wire        s1_reg_write,
    input  wire [4:0]  s1_rs1,
    input  wire [4:0]  s1_rs2,
    input  wire        s1_uses_rs1,
    input  wire        s1_uses_rs2,
    input  wire [4:0]  s1_rd,
    input  wire [31:0] s1_pc,
    input  wire [31:0] s1_instr,
    input  wire [31:0] s1_ra,
    input  wire [31:0] s1_rb,

    input  wire        backend_stall,

    output wire        issue0,
    output wire        issue1,
    output wire        slot1_stall,

    output wire        w0_valid,
    output wire        w0_we,
    output wire [4:0]  w0_rd,
    output wire [31:0] w0_data,

    // Lane0 control-flow observation for redirect/flush integration.
    output wire        ex0_branch_request,
    output wire        ex0_branch_taken,
    output wire [31:0] ex0_branch_pc,
    output wire [31:0] ex0_branch_source,

    output wire        w1_valid,
    output wire        w1_we,
    output wire [4:0]  w1_rd,
    output wire [31:0] w1_data
);

    issue_arb u_issue (
        .s0_valid(s0_valid), .s0_illegal(s0_illegal), .s0_is_alu(s0_is_alu),
        .s0_rd(s0_rd), .s0_reg_write(s0_reg_write),
        .s1_valid(s1_valid), .s1_illegal(s1_illegal), .s1_is_alu(s1_is_alu),
        .s1_rs1(s1_rs1), .s1_rs2(s1_rs2), .s1_uses_rs1(s1_uses_rs1),
        .s1_uses_rs2(s1_uses_rs2), .s1_rd(s1_rd), .s1_reg_write(s1_reg_write),
        .backend_stall(backend_stall),
        .issue0(issue0), .issue1(issue1), .slot1_stall(slot1_stall)
    );

    riscv_exec #(.BRANCH_PC_RAW(BRANCH_PC_RAW)) u_ex0 (
        .clk_i(clk), .rst_i(rst), .valid_i(issue0), .opcode_i(s0_instr),
        .pc_i(s0_pc), .ra_operand_i(s0_ra), .rb_operand_i(s0_rb),
        .hold_i(1'b0), .valid_o(w0_valid), .alu_result_o(w0_data),
        .alu_result_e1_o(), .branch_request_o(ex0_branch_request),
        .branch_taken_o(ex0_branch_taken), .branch_not_taken_o(),
        .branch_pc_o(ex0_branch_pc), .branch_source_o(ex0_branch_source),
        .branch_call_o(), .branch_ret_o(), .branch_jmp_o(),
        .rd_idx_o(w0_rd), .writes_rd_o(w0_we)
    );

    riscv_exec u_ex1 (
        .clk_i(clk), .rst_i(rst), .valid_i(issue1), .opcode_i(s1_instr),
        .pc_i(s1_pc), .ra_operand_i(s1_ra), .rb_operand_i(s1_rb),
        .hold_i(1'b0), .valid_o(w1_valid), .alu_result_o(w1_data),
        .alu_result_e1_o(), .branch_request_o(), .branch_taken_o(),
        .branch_not_taken_o(), .branch_pc_o(), .branch_source_o(),
        .branch_call_o(), .branch_ret_o(), .branch_jmp_o(),
        .rd_idx_o(w1_rd), .writes_rd_o(w1_we)
    );

endmodule
