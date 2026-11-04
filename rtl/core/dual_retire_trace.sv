// ============================================================================
//        Dual Registered Retirement Trace (M1-8 observability)
//
//        Two trace channels per cycle.  Channel 0 is always the older event;
//        channel 1, when valid, is the younger event.  Order values are
//        contiguous over committed events.
//
//        Payload fields intentionally match retire_trace.v so integration can
//        replace one channel with two without redefining the trace schema.
// ============================================================================
`include "defines.sv"

module dual_retire_trace (
    input  wire        clk,
    input  wire        rst,

    input  wire        commit0_valid,
    input  wire [31:0] commit0_pc,
    input  wire [31:0] commit0_instr,
    input  wire [4:0]  commit0_rd,
    input  wire [31:0] commit0_rd_data,
    input  wire        commit0_rd_we,
    input  wire        commit0_trap,
    input  wire [31:0] commit0_cause,

    input  wire        commit1_valid,
    input  wire [31:0] commit1_pc,
    input  wire [31:0] commit1_instr,
    input  wire [4:0]  commit1_rd,
    input  wire [31:0] commit1_rd_data,
    input  wire        commit1_rd_we,
    input  wire        commit1_trap,
    input  wire [31:0] commit1_cause,

    output reg         trace0_valid,
    output reg  [63:0] trace0_order,
    output reg  [31:0] trace0_pc,
    output reg  [31:0] trace0_instr,
    output reg  [4:0]  trace0_rd,
    output reg  [31:0] trace0_rd_data,
    output reg         trace0_rd_we,
    output reg         trace0_trap,
    output reg  [31:0] trace0_cause,

    output reg         trace1_valid,
    output reg  [63:0] trace1_order,
    output reg  [31:0] trace1_pc,
    output reg  [31:0] trace1_instr,
    output reg  [4:0]  trace1_rd,
    output reg  [31:0] trace1_rd_data,
    output reg         trace1_rd_we,
    output reg         trace1_trap,
    output reg  [31:0] trace1_cause
);

    reg [63:0] next_order;
    wire [63:0] trace1_order_w = next_order + {63'd0, commit0_valid};

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            trace0_valid   <= 1'b0;
            trace0_order   <= 64'd0;
            trace0_pc      <= 32'd0;
            trace0_instr   <= 32'd0;
            trace0_rd      <= 5'd0;
            trace0_rd_data <= 32'd0;
            trace0_rd_we   <= 1'b0;
            trace0_trap    <= 1'b0;
            trace0_cause   <= 32'd0;
            trace1_valid   <= 1'b0;
            trace1_order   <= 64'd0;
            trace1_pc      <= 32'd0;
            trace1_instr   <= 32'd0;
            trace1_rd      <= 5'd0;
            trace1_rd_data <= 32'd0;
            trace1_rd_we   <= 1'b0;
            trace1_trap    <= 1'b0;
            trace1_cause   <= 32'd0;
            next_order     <= 64'd0;
        end else begin
            trace0_valid   <= commit0_valid;
            trace0_order   <= next_order;
            trace0_pc      <= commit0_pc;
            trace0_instr   <= commit0_instr;
            trace0_rd      <= commit0_rd;
            trace0_rd_data <= commit0_rd_data;
            trace0_rd_we   <= commit0_rd_we;
            trace0_trap    <= commit0_trap;
            trace0_cause   <= commit0_cause;

            trace1_valid   <= commit1_valid;
            trace1_order   <= trace1_order_w;
            trace1_pc      <= commit1_pc;
            trace1_instr   <= commit1_instr;
            trace1_rd      <= commit1_rd;
            trace1_rd_data <= commit1_rd_data;
            trace1_rd_we   <= commit1_rd_we;
            trace1_trap    <= commit1_trap;
            trace1_cause   <= commit1_cause;

            next_order <= next_order + {63'd0, commit0_valid} + {63'd0, commit1_valid};
        end
    end

endmodule
