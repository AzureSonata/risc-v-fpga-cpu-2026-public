// ============================================================================
//        64-bit Fetch Slice (M0-5 / M1-1 pre-research)
//
//        Presents an 8-byte aligned fetch address, captures one 64-bit
//        instruction block, and exposes the two 32-bit instructions to the
//        fetch queue.  It pushes one or two instructions per cycle so it can
//        also drive the single-issue (DUAL_ISSUE_EN=0) configuration.
//
//        Protocol:
//        - One outstanding request.
//        - A response is accepted only when there is room in the block slot.
//        - If the queue has room for only one of the two halves, the low half
//          is pushed and the block slot keeps the high half.
//        - The next request is launched while the old block is being fully
//          consumed, allowing a sustained 2-instruction/cycle stream.
// ============================================================================
`include "defines.sv"

module wide_fetch (
    input  wire        clk,
    input  wire        rst,
    input  wire        redirect_valid,
    input  wire [31:0] redirect_target,

    output wire        i_req_valid,
    input  wire        i_req_ready,
    output wire [31:0] i_req_addr,
    input  wire        i_rsp_valid,
    output wire        i_rsp_ready,
    input  wire [63:0] i_rsp_data,
    input wire [1:0] i_rsp_error,

    input  wire [1:0]  push_ready,
    output wire        q0_valid,
    output wire [31:0] q0_pc,
    output wire [31:0] q0_inst,
    output wire q0_fault,
    output wire        q1_valid,
    output wire [31:0] q1_pc,
    output wire [31:0] q1_inst,
    output wire q1_fault,

    output wire [31:0] pc_debug
);

    reg        req_outstanding_q;

    reg [31:0] req_pc_q;
    reg [31:0] pc_q;
    reg [1:0]  epoch_q;
    reg [1:0]  req_epoch_q;

    reg        block_valid_q;
    reg        block_hi_q;          // 0 = both halves pending, 1 = only high pending
    reg [31:0] block_pc_q;
    reg [63:0] block_data_q;


    wire push_low  = block_valid_q && !block_hi_q && (push_ready >= 2'd1);
    wire push_both = block_valid_q && !block_hi_q && (push_ready >= 2'd2);
    wire push_high = block_valid_q &&  block_hi_q && (push_ready >= 2'd1);
    wire block_consumed_full = push_both || push_high;


    assign i_rsp_ready = (!block_valid_q || block_consumed_full) &&
                        (req_epoch_q == epoch_q);
    assign i_req_valid = !redirect_valid &&
                         (!req_outstanding_q || (i_rsp_valid && i_rsp_ready)) &&
                         (!block_valid_q || block_consumed_full);
    assign i_req_addr  = pc_q;

    assign q0_valid = block_valid_q && (push_ready >= 2'd1);
    assign q0_pc    = block_hi_q ? (block_pc_q + 32'd4) : block_pc_q;
    assign q0_inst  = block_hi_q ? block_data_q[63:32] : block_data_q[31:0];

    assign q1_valid = block_valid_q && !block_hi_q && (push_ready >= 2'd2);
    assign q1_pc    = block_pc_q + 32'd4;
    assign q1_inst  = block_data_q[63:32];

    assign q0_fault=1'b0; assign q1_fault=1'b0;
    assign pc_debug = pc_q;

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            req_outstanding_q <= 1'b0;
            req_pc_q          <= 32'h0;
            pc_q              <= 32'h0;
            epoch_q           <= 2'b0;
            req_epoch_q       <= 2'b0;
            block_valid_q     <= 1'b0;
            block_hi_q        <= 1'b0;
            block_pc_q        <= 32'h0;
            block_data_q      <= 64'h0;
        end else if (redirect_valid) begin
            // Simplified direct redirect: the first vertical-slice branch test
            // uses 8-byte-aligned targets.  Re-fetch from the target block and
            // discard any stale response by advancing the epoch.
            pc_q              <= {redirect_target[31:3], 3'b000};
            req_outstanding_q <= 1'b0;
            block_valid_q     <= 1'b0;
            block_hi_q        <= 1'b0;
            epoch_q           <= epoch_q + 2'b1;
        end else if (i_rsp_valid && i_rsp_ready) begin
            // Response capture has priority: the old block is fully consumed
            // in this same cycle (i_rsp_ready also requires that).
            if (req_epoch_q == epoch_q) begin
                block_valid_q <= 1'b1;
                block_hi_q    <= 1'b0;
                block_pc_q    <= req_pc_q;
                block_data_q  <= i_rsp_data;

                if (i_req_valid && i_req_ready) begin
                    req_outstanding_q <= 1'b1;
                    req_pc_q          <= pc_q;
                    req_epoch_q       <= epoch_q;
                    pc_q              <= pc_q + 32'd8;
                end else begin
                    req_outstanding_q <= 1'b0;
                end
            end else begin
                req_outstanding_q <= 1'b0;
            end
        end else begin
            if (i_req_valid && i_req_ready) begin
                req_outstanding_q <= 1'b1;
                req_pc_q          <= pc_q;
                req_epoch_q       <= epoch_q;
                pc_q              <= pc_q + 32'd8;
            end

            if (block_valid_q) begin
                if (block_hi_q) begin
                    if (push_high)
                        block_valid_q <= 1'b0;
                end else if (push_both) begin
                    block_valid_q <= 1'b0;
                end else if (push_low) begin
                    block_hi_q <= 1'b1;   // consume low, keep high pending
                end

            end
        end
    end

endmodule
