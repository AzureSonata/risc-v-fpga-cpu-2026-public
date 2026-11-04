// ============================================================================
//        CPU Core Dual Stage (prototype SoC-facing wrapper)
//
//        This is the first CPU-top wrapper for the dual-issue vertical slice.
//        It intentionally has the same broad port shape as cpu_core_stage1,
//        with one structural difference: the I-side response is 64-bit because
//        the mini core's 64-bit fetch is what sustains two instructions/cycle.
//
//        Supported now:
//          - 64-bit instruction fetch/queue, dual decode, dual ALU,
//            dual commit and dual retirement trace.
//        Not supported yet:
//          - D-side load/store, CSR, traps, interrupts, branch/JAL redirect.
//        The D-side ports are tied off, and the extra trace1 channel is exposed
//        so the SoC integration can observe both retirement events.
// ============================================================================
`include "defines.sv"

module cpu_core_dual_stage (
    input  wire        clk,
    input  wire        rst,

    // Instruction port (64-bit response)
    output wire        i_req_valid,
    input  wire        i_req_ready,
    output wire [31:0] i_req_addr,
    input  wire        i_rsp_valid,
    output wire        i_rsp_ready,
    input  wire [63:0] i_rsp_data,
    input  wire        i_rsp_error,

    // Data port: tied off in this prototype.
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

    // Retirement trace channel 0 (drop-in-compatible names)
    output wire        trace_valid,
    output wire [63:0] trace_order,
    output wire [31:0] trace_pc,
    output wire [31:0] trace_instr,
    output wire [4:0]  trace_rd,
    output wire [31:0] trace_rd_data,
    output wire        trace_rd_we,
    output wire        trace_trap,
    output wire [31:0] trace_cause,

    // Retirement trace channel 1 (extra evidence channel)
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

    assign d_req_valid = 1'b0;
    assign d_req_addr  = 32'h0;
    assign d_req_write = 1'b0;
    assign d_req_wdata = 32'h0;
    assign d_req_wstrb = 4'h0;
    assign d_rsp_ready = 1'b0;

    // Interrupt and I-error inputs are intentionally unused until the full SoC
    // integration round wires them into CSR/memory handling.
    wire unused_inputs = i_rsp_error | timer_irq_i | ext_irq_i |
                         d_rsp_valid | d_rsp_error | (|d_rsp_rdata) | d_req_ready;

    dual_issue_mini_core #(.DUAL_ISSUE_EN(1'b1)) u_core (
        .clk(clk), .rst(rst),
        .i_req_valid(i_req_valid), .i_req_ready(i_req_ready),
        .i_req_addr(i_req_addr), .i_rsp_valid(i_rsp_valid),
        .i_rsp_ready(i_rsp_ready), .i_rsp_data(i_rsp_data),
        .issue0(), .issue1(), .retire0_valid(), .retire1_valid(),
        .trace0_valid(trace_valid), .trace0_order(trace_order),
        .trace0_pc(trace_pc), .trace0_instr(trace_instr),
        .trace0_rd(trace_rd), .trace0_rd_data(trace_rd_data),
        .trace0_rd_we(trace_rd_we), .trace0_trap(trace_trap),
        .trace0_cause(trace_cause),
        .trace1_valid(trace1_valid), .trace1_order(trace1_order),
        .trace1_pc(trace1_pc), .trace1_instr(trace1_instr),
        .trace1_rd(trace1_rd), .trace1_rd_data(trace1_rd_data),
        .trace1_rd_we(trace1_rd_we), .trace1_trap(trace1_trap),
        .trace1_cause(trace1_cause),
        .pc_debug(pc_debug)
    );

endmodule
