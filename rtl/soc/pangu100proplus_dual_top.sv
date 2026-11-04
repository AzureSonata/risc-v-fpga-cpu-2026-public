// ============================================================================
//        Pangu 100Pro+ dual-issue prototype top
//
//        Board-facing prototype for the 64-bit-I dual-issue core.  It uses a
//        64-bit on-chip instruction ROM generated from a 64-instruction ALU
//        program, ties the D-side off, and exposes both retirement-trace
//        channels for simulation evidence.
//
//        This is not yet a full SoC: no D-side, CSR, trap, interrupt or branch
//        support.  It is the first board-pin-level integration of the dual
//        issue vertical slice.
// ============================================================================
`timescale 1ns/1ps

module pangu100proplus_dual_top #(
    parameter [1023:0] INIT_FILE = "verification/unit/dual_alu_program.hex"
)(
    input  wire        clk,
    input  wire        rstn,
    output wire [7:0]  led,

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
    reg [1:0] reset_pipe;
    always @(posedge clk or negedge rstn) begin
        if (!rstn)
            reset_pipe <= 2'b11;
        else
            reset_pipe <= {reset_pipe[0], 1'b0};
    end
    wire rst = reset_pipe[1];

    wire        i_req_valid, i_req_ready, i_rsp_valid, i_rsp_ready, i_rsp_error;
    wire [31:0] i_req_addr;
    wire [63:0] i_rsp_data;

    wide_rom #(
        .DEPTH(128), .AW(7), .INIT_FILE(INIT_FILE)
    ) u_rom (
        .clk(clk), .rst(rst),
        .req_valid(i_req_valid), .req_ready(i_req_ready), .req_addr(i_req_addr),
        .rsp_valid(i_rsp_valid), .rsp_ready(i_rsp_ready),
        .rsp_data(i_rsp_data), .error(i_rsp_error)
    );

    wire        d_req_valid, d_req_ready, d_req_write, d_rsp_valid, d_rsp_ready;
    wire [31:0] d_req_addr, d_req_wdata, d_rsp_rdata;
    wire [3:0]  d_req_wstrb;

    assign d_req_ready = 1'b0;
    assign d_rsp_valid = 1'b0;
    assign d_rsp_rdata = 32'h0;

    cpu_core_dual_stage u_cpu (
        .clk(clk), .rst(rst),
        .i_req_valid(i_req_valid), .i_req_ready(i_req_ready),
        .i_req_addr(i_req_addr), .i_rsp_valid(i_rsp_valid),
        .i_rsp_ready(i_rsp_ready), .i_rsp_data(i_rsp_data),
        .i_rsp_error(i_rsp_error),
        .d_req_valid(d_req_valid), .d_req_ready(d_req_ready),
        .d_req_addr(d_req_addr), .d_req_write(d_req_write),
        .d_req_wdata(d_req_wdata), .d_req_wstrb(d_req_wstrb),
        .d_rsp_valid(d_rsp_valid), .d_rsp_ready(d_rsp_ready),
        .d_rsp_rdata(d_rsp_rdata), .d_rsp_error(1'b0),
        .timer_irq_i(1'b0), .ext_irq_i(1'b0),
        .trace_valid(trace0_valid), .trace_order(trace0_order),
        .trace_pc(trace0_pc), .trace_instr(trace0_instr),
        .trace_rd(trace0_rd), .trace_rd_data(trace0_rd_data),
        .trace_rd_we(trace0_rd_we), .trace_trap(trace0_trap),
        .trace_cause(trace0_cause),
        .trace1_valid(trace1_valid), .trace1_order(trace1_order),
        .trace1_pc(trace1_pc), .trace1_instr(trace1_instr),
        .trace1_rd(trace1_rd), .trace1_rd_data(trace1_rd_data),
        .trace1_rd_we(trace1_rd_we), .trace1_trap(trace1_trap),
        .trace1_cause(trace1_cause),
        .pc_debug(pc_debug)
    );

    reg [7:0] led_value;
    always @(posedge clk) begin
        if (rst)
            led_value <= 8'h0;
        else begin
            if (trace0_valid && trace0_rd_we)
                led_value <= trace0_rd_data[7:0];
            if (trace1_valid && trace1_rd_we)
                led_value <= trace1_rd_data[7:0];   // younger event wins
        end
    end
    assign led = led_value;

endmodule
