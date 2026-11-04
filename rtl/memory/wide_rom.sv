// ============================================================================
//        64-bit Instruction ROM
//
//        Two project `rom` instances (32-bit each) read adjacent words and are
//        combined into one 64-bit instruction block.  This gives the dual
//        issue fetch path a real project ROM implementation to read from,
//        without requiring a 64-bit native memory primitive.
//
//        Both instances are initialized from the same hex file.  The low
//        instance sees the requested word, the high instance sees the next
//        word (addr+4).  They respond in the same cycle, so the 64-bit block is
//        available with the same latency as the original 32-bit ROM.
//
//        Contract:
//        - req_addr must be 8-byte aligned.
//        - rsp_valid is asserted when both bytes are available.
//        - rsp_data = {high_word, low_word}.
// ============================================================================
`include "defines.sv"

module wide_rom #(
    parameter integer DEPTH = 16384,
    parameter integer AW = 14,
    parameter [1023:0] INIT_FILE = 1024'd0
)(
    input  wire         clk,
    input  wire         rst,
    input  wire         req_valid,
    output wire         req_ready,
    input  wire [31:0]  req_addr,
    output wire         rsp_valid,
    input  wire         rsp_ready,
    output wire [63:0]  rsp_data,
    output wire         error
);

    wire        lo_req_ready, lo_rsp_valid, lo_error;
    wire [31:0] lo_rdata;
    wire        hi_req_ready, hi_rsp_valid, hi_error;
    wire [31:0] hi_rdata;

    rom #(.DEPTH(DEPTH), .AW(AW), .INIT_FILE(INIT_FILE)) u_low (
        .clk(clk), .rst(rst),
        .req_valid(req_valid), .req_ready(lo_req_ready), .addr(req_addr),
        .write(1'b0), .wdata(32'h0), .wstrb(4'h0),
        .rsp_valid(lo_rsp_valid), .rsp_ready(rsp_ready),
        .rdata(lo_rdata), .error(lo_error)
    );

    rom #(.DEPTH(DEPTH), .AW(AW), .INIT_FILE(INIT_FILE)) u_high (
        .clk(clk), .rst(rst),
        .req_valid(req_valid), .req_ready(hi_req_ready),
        .addr(req_addr + 32'd4),
        .write(1'b0), .wdata(32'h0), .wstrb(4'h0),
        .rsp_valid(hi_rsp_valid), .rsp_ready(rsp_ready),
        .rdata(hi_rdata), .error(hi_error)
    );

    assign req_ready = lo_req_ready && hi_req_ready;
    assign rsp_valid = lo_rsp_valid && hi_rsp_valid;
    assign rsp_data  = {hi_rdata, lo_rdata};
    assign error     = lo_error | hi_error;

endmodule
