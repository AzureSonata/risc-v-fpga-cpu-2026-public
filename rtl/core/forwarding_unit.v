`timescale 1ns/1ps

// Draft K1 EX operand forwarding selector.
//
// Encoding:
//   2'b00: use the operand already carried by ID/EX
//   2'b01: use MEM/WB writeback data
//   2'b10: use EX/MEM result (newest writer, therefore highest priority)
//
// This unit only chooses a source.  The EX datapath remains responsible for
// multiplexing the corresponding values.  A load whose result is not ready
// must be withheld by hazard control rather than advertised as writes_rd.
module forwarding_unit (
    input  wire [4:0] ex_rs1,
    input  wire [4:0] ex_rs2,
    input  wire       ex_uses_rs1,
    input  wire       ex_uses_rs2,

    input  wire       ex_mem_valid,
    input  wire       ex_mem_writes_rd,
    input  wire [4:0] ex_mem_rd,

    input  wire       mem_wb_valid,
    input  wire       mem_wb_writes_rd,
    input  wire [4:0] mem_wb_rd,

    output reg  [1:0] forward_rs1,
    output reg  [1:0] forward_rs2
);
    always @* begin
        forward_rs1 = 2'b00;
        forward_rs2 = 2'b00;

        if (ex_uses_rs1 && (ex_rs1 != 5'd0)) begin
            if (ex_mem_valid && ex_mem_writes_rd &&
                (ex_mem_rd != 5'd0) && (ex_mem_rd == ex_rs1)) begin
                forward_rs1 = 2'b10;
            end else if (mem_wb_valid && mem_wb_writes_rd &&
                         (mem_wb_rd != 5'd0) && (mem_wb_rd == ex_rs1)) begin
                forward_rs1 = 2'b01;
            end
        end

        if (ex_uses_rs2 && (ex_rs2 != 5'd0)) begin
            if (ex_mem_valid && ex_mem_writes_rd &&
                (ex_mem_rd != 5'd0) && (ex_mem_rd == ex_rs2)) begin
                forward_rs2 = 2'b10;
            end else if (mem_wb_valid && mem_wb_writes_rd &&
                         (mem_wb_rd != 5'd0) && (mem_wb_rd == ex_rs2)) begin
                forward_rs2 = 2'b01;
            end
        end
    end
endmodule
