`timescale 1ns/1ps

// Registered retirement trace.
//
// The integration top must generate exactly one commit_fire pulse when it
// consumes a valid MEM/WB payload.  Holding retire_valid high is harmless:
// without a new commit_fire there is no trace event and retire_order does not
// advance.  Instructions targeting x0 and trapping instructions are still
// observable retirement events; trace_rd_we reports only the real register
// side effect after WB gating.
module retire_trace (
    input  wire        clk,
    input  wire        rst,
    input  wire        retire_valid,
    input  wire        commit_fire,
    input  wire [31:0] retire_pc,
    input  wire [31:0] retire_instr,
    input  wire [4:0]  retire_rd,
    input  wire [31:0] retire_rd_data,
    input  wire        retire_rd_we,
    input  wire        retire_trap,
    // 批 (b) 扩展（**不改动任何既有字段**，只新增 cause）：
    // 该退休事件的陷阱 cause（0 = 未进入陷阱）；与 csr_file 写入 mcause 的值同源。
    // 定为 32 位以便批 (c) 直接承载中断 cause（bit31=1）。
    input  wire [31:0] retire_cause,

    output reg         trace_valid,
    output reg  [63:0] trace_order,
    output reg  [31:0] trace_pc,
    output reg  [31:0] trace_instr,
    output reg  [4:0]  trace_rd,
    output reg  [31:0] trace_rd_data,
    output reg         trace_rd_we,
    output reg         trace_trap,
    output reg  [31:0] trace_cause
);

    reg [63:0] next_order;

    always @(posedge clk) begin
        if (rst) begin
            trace_valid   <= 1'b0;
            trace_order   <= 64'd0;
            trace_pc      <= 32'd0;
            trace_instr   <= 32'd0;
            trace_rd      <= 5'd0;
            trace_rd_data <= 32'd0;
            trace_rd_we   <= 1'b0;
            trace_trap    <= 1'b0;
            trace_cause   <= 32'd0;
            next_order    <= 64'd0;
        end else begin
            trace_valid <= 1'b0;
            if (commit_fire && retire_valid) begin
                trace_valid   <= 1'b1;
                trace_order   <= next_order;
                trace_pc      <= retire_pc;
                trace_instr   <= retire_instr;
                trace_rd      <= retire_rd;
                trace_rd_data <= retire_rd_data;
                trace_rd_we   <= retire_rd_we;
                trace_trap    <= retire_trap;
                trace_cause   <= retire_cause;
                next_order    <= next_order + 64'd1;
            end
        end
    end

endmodule
