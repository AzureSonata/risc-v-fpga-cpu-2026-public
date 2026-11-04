`timescale 1ns/1ps

// Draft K1 interface. Keep this payload separate from the frozen A/B interfaces
// and reconcile it with those interfaces before connecting it to other modules.
module id_ex_reg (
    input  wire        clk,
    input  wire        rst,
    input  wire        flush,
    input  wire        hold,
    input  wire        in_valid,
    input  wire [31:0] in_pc,
    input  wire [31:0] in_instr,
    input  wire [31:0] in_rs1_value,
    input  wire [31:0] in_rs2_value,
    input  wire [31:0] in_imm,
    input  wire [4:0]  in_rs1,
    input  wire [4:0]  in_rs2,
    input  wire [4:0]  in_rd,
    // Issue #15 第 2 项：ID 是"本指令是否读 rs1/rs2"的**唯一语义源**。
    // 这两个标志由 id_stage 的 uses_rs1_o/uses_rs2_o 直接寄存，供 EX 侧
    // forwarding_unit 消费；EX 不再从 opcode 重组（旧实现见 cpu_core_stage1.sv）。
    input  wire        in_uses_rs1,
    input  wire        in_uses_rs2,
    input  wire [3:0]  in_alu_op,
    input  wire        in_alu_src_imm,
    input  wire        in_branch,
    input  wire        in_jal,
    input  wire        in_jalr,
    input  wire        in_mem_read,
    input  wire        in_mem_write,
    input  wire [1:0]  in_mem_size,
    input  wire        in_mem_unsigned,
    input  wire        in_reg_write,
    input  wire        in_fetch_fault,
    input  wire        in_illegal,
    input  wire        in_pred_valid,
    input  wire        in_pred_taken,
    input  wire [31:0] in_pred_target,
    output reg         out_valid,
    output reg  [31:0] out_pc,
    output reg  [31:0] out_instr,
    output reg  [31:0] out_rs1_value,
    output reg  [31:0] out_rs2_value,
    output reg  [31:0] out_imm,
    output reg  [4:0]  out_rs1,
    output reg  [4:0]  out_rs2,
    output reg  [4:0]  out_rd,
    output reg         out_uses_rs1,
    output reg         out_uses_rs2,
    output reg  [3:0]  out_alu_op,
    output reg         out_alu_src_imm,
    output reg         out_branch,
    output reg         out_jal,
    output reg         out_jalr,
    output reg         out_mem_read,
    output reg         out_mem_write,
    output reg  [1:0]  out_mem_size,
    output reg         out_mem_unsigned,
    output reg         out_reg_write,
    output reg         out_fetch_fault,
    output reg         out_illegal,
    output reg         out_pred_valid,
    output reg         out_pred_taken,
    output reg  [31:0] out_pred_target
);
    task automatic clear_payload;
        begin
            out_valid <= 1'b0; out_pc <= 32'b0; out_instr <= 32'b0;
            out_rs1_value <= 32'b0; out_rs2_value <= 32'b0; out_imm <= 32'b0;
            out_rs1 <= 5'b0; out_rs2 <= 5'b0; out_rd <= 5'b0; out_alu_op <= 4'b0;
            out_uses_rs1 <= 1'b0; out_uses_rs2 <= 1'b0;
            out_alu_src_imm <= 1'b0; out_branch <= 1'b0; out_jal <= 1'b0;
            out_jalr <= 1'b0; out_mem_read <= 1'b0; out_mem_write <= 1'b0;
            out_mem_size <= 2'b0; out_mem_unsigned <= 1'b0; out_reg_write <= 1'b0;
            out_fetch_fault <= 1'b0; out_illegal <= 1'b0;
            out_pred_valid <= 1'b0; out_pred_taken <= 1'b0; out_pred_target <= 32'b0;
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            clear_payload;
        end else if (flush) begin
            clear_payload;
        end else if (hold) begin
            // Retain the complete transaction while the downstream stage stalls.
        end else if (!in_valid) begin
            clear_payload;
        end else begin
            out_valid <= 1'b1; out_pc <= in_pc; out_instr <= in_instr;
            out_rs1_value <= in_rs1_value; out_rs2_value <= in_rs2_value;
            out_imm <= in_imm; out_rs1 <= in_rs1; out_rs2 <= in_rs2; out_rd <= in_rd;
            // uses_rs 直接寄存 ID 的输出（id_stage 已在 fault/illegal 分支把它们清零，
            // 因此这里**不再**叠一遍 !in_fetch_fault && !in_illegal 门控：
            // 叠加会把"ID 是唯一语义源"重新变成两处判据，正是 Issue #15 第 2 项要消除的）。
            out_uses_rs1 <= in_uses_rs1; out_uses_rs2 <= in_uses_rs2;
            out_alu_op <= in_alu_op; out_alu_src_imm <= in_alu_src_imm;
            out_branch <= in_branch && !in_fetch_fault && !in_illegal;
            out_jal <= in_jal && !in_fetch_fault && !in_illegal;
            out_jalr <= in_jalr && !in_fetch_fault && !in_illegal;
            out_mem_read <= in_mem_read && !in_fetch_fault && !in_illegal;
            out_mem_write <= in_mem_write && !in_fetch_fault && !in_illegal;
            out_mem_size <= in_mem_size; out_mem_unsigned <= in_mem_unsigned;
            out_reg_write <= in_reg_write && !in_fetch_fault && !in_illegal;
            out_fetch_fault <= in_fetch_fault; out_illegal <= in_illegal;
            out_pred_valid <= in_pred_valid; out_pred_taken <= in_pred_taken;
            out_pred_target <= in_pred_target;
        end
    end
endmodule
