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

module wide_fetch #(
    parameter PREDICT_ENABLE = 1'b0,
    parameter integer PRED_MODE = 0,
    parameter integer BTB_ENTRIES = 64
)(
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
    input  wire [1:0] i_rsp_error,

    input  wire [1:0]  push_ready,
    output wire        q0_valid,
    output wire [31:0] q0_pc,
    output wire [31:0] q0_inst,
    output wire q0_fault,
    output wire        q1_valid,
    output wire [31:0] q1_pc,
    output wire [31:0] q1_inst,
    output wire q1_fault,
    output wire q0_pred_valid,
    output wire q0_pred_taken,
    output wire [31:0] q0_pred_target,
    output wire q1_pred_valid,
    output wire q1_pred_taken,
    output wire [31:0] q1_pred_target,

    input wire         update_valid,
    input wire [31:0]  update_pc,
    input wire         update_taken,
    input wire [31:0]  update_target,
    input wire         update_pred_taken,
    input wire [31:0]  update_pred_target,
    input wire         update_exception,
    input wire         update_is_call,
    input wire         update_is_ret,

    output wire [31:0] pc_debug
);

    reg        req_outstanding_q;
    reg        req_stale_q;
    // Hold a presented request across backpressure. Redirects may invalidate
    // its response, but cannot retract or retarget a valid, unaccepted request.
    reg        req_hold_q;
    reg        req_hold_stale_q;
    reg [31:0] req_hold_pc_q;
    reg        req_hi_q;
    reg [31:0] req_pc_q;
    reg [31:0] pc_q;
    reg        block_valid_q;
    reg        block_hi_q;
    reg [31:0] block_pc_q;
    reg [63:0] block_data_q;
    reg [1:0] block_error_q;
    reg block_drop_high_q;
    reg req_pred0_valid_q, req_pred0_taken_q;
    reg [31:0] req_pred0_target_q;
    reg req_pred1_valid_q, req_pred1_taken_q;
    reg [31:0] req_pred1_target_q;
    reg block_pred0_valid_q, block_pred0_taken_q;
    reg [31:0] block_pred0_target_q;
    reg block_pred1_valid_q, block_pred1_taken_q;
    reg [31:0] block_pred1_target_q;

    wire bp_q0_hit, bp_q0_taken;
    wire [31:0] bp_q0_target;
    wire bp_q1_hit, bp_q1_taken;
    wire [31:0] bp_q1_target;
    wire req_fire;
    wire [31:0] issue_pc = req_hold_q ? req_hold_pc_q : pc_q;
    wire req_fire_stale = redirect_valid || (req_hold_q && req_hold_stale_q);
    generate
        if (PREDICT_ENABLE) begin : g_predictor
            branch_predictor #(.ENTRIES(BTB_ENTRIES), .IDX_BITS($clog2(BTB_ENTRIES)),
                               .DUAL_QUERY(1'b1), .PRED_MODE(PRED_MODE),
                               .RAS_ENABLE(1'b1), .RAS_DEPTH(8)) u_predictor (
                .clk(clk), .rst(rst),
                .q_valid(req_fire && !req_fire_stale), .q_pc(issue_pc),
                .q_hit(bp_q0_hit), .q_taken(bp_q0_taken), .q_target(bp_q0_target),
                .q1_valid(req_fire && !req_fire_stale && !issue_pc[2] && !bp_q0_taken), .q1_pc(issue_pc + 32'd4),
                .q1_hit(bp_q1_hit), .q1_taken(bp_q1_taken), .q1_target(bp_q1_target),
                .u_valid(update_valid), .u_pc(update_pc), .u_taken(update_taken),
                .u_target(update_target), .u_pred_taken(update_pred_taken),
                .u_pred_target(update_pred_target), .u_exception(update_exception),
                .u_is_call(update_is_call), .u_is_ret(update_is_ret),
                .stat_clr(1'b0), .stat_query(), .stat_hit(), .stat_mispredict()
            );
            assign q0_pred_valid = block_hi_q ? block_pred1_valid_q : block_pred0_valid_q;
            assign q0_pred_taken = block_hi_q ? block_pred1_taken_q : block_pred0_taken_q;
            assign q0_pred_target = block_hi_q ? block_pred1_target_q : block_pred0_target_q;
            assign q1_pred_valid = !block_hi_q && !block_drop_high_q && block_pred1_valid_q;
            assign q1_pred_taken = !block_hi_q && !block_drop_high_q && block_pred1_taken_q;
            assign q1_pred_target = block_pred1_target_q;
        end else begin : g_no_predictor
            assign bp_q0_hit = 1'b0;
            assign bp_q0_taken = 1'b0;
            assign bp_q0_target = 32'h0;
            assign bp_q1_hit = 1'b0;
            assign bp_q1_taken = 1'b0;
            assign bp_q1_target = 32'h0;
            assign q0_pred_valid = 1'b0;
            assign q0_pred_taken = 1'b0;
            assign q0_pred_target = 32'h0;
            assign q1_pred_valid = 1'b0;
            assign q1_pred_taken = 1'b0;
            assign q1_pred_target = 32'h0;
        end
    endgenerate

    wire push_low = block_valid_q && !block_hi_q && (push_ready >= 2'd1);
    wire push_both = block_valid_q && !block_hi_q && !block_drop_high_q &&
                     (push_ready >= 2'd2);
    wire push_high = block_valid_q && block_hi_q && (push_ready >= 2'd1);
    wire block_consumed_full = push_both || push_high || (push_low && block_drop_high_q);
    wire room = !block_valid_q || block_consumed_full;

    // ⚠️ 坑位：redirect不能取消已接受事务；旧响应必须握手后丢弃。
    // 用单在途sticky stale标志，连续redirect也不会发生epoch回绕误收（PR66 R3）。
    assign i_rsp_ready = req_outstanding_q && (req_stale_q || room);
    wire rsp_fire = i_rsp_valid && i_rsp_ready;
    // Redirect is intentionally absent from this request-valid path. If a
    // request is stalled, req_hold_q preserves its address until handshake;
    // a redirect marks that request stale and redirects the following fetch.
    assign i_req_valid = req_hold_q || (room &&
                         (!req_outstanding_q || rsp_fire));
    assign i_req_addr = {issue_pc[31:3], 3'b000};
    assign req_fire = i_req_valid && i_req_ready;

    assign q0_valid = block_valid_q && (push_ready >= 2'd1);
    assign q0_pc = block_hi_q ? block_pc_q + 32'd4 : block_pc_q;
    assign q0_fault = block_hi_q ? block_error_q[1] : block_error_q[0];
    assign q1_fault = block_error_q[1];
    assign q0_inst = block_hi_q ? block_data_q[63:32] : block_data_q[31:0];
    assign q1_valid = block_valid_q && !block_hi_q && !block_drop_high_q &&
                      (push_ready >= 2'd2);
    assign q1_pc = block_pc_q + 32'd4;
    assign q1_inst = block_data_q[63:32];
    assign pc_debug = pc_q;

    wire [31:0] sequential_next_pc = {pc_q[31:3], 3'b000} + 32'd8;
    wire [31:0] predicted_next_pc = bp_q0_taken ? bp_q0_target :
                                    ((!pc_q[2] && bp_q1_taken) ? bp_q1_target : sequential_next_pc);

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            req_outstanding_q <= 1'b0;
            req_stale_q <= 1'b0;
            req_hold_q <= 1'b0;
            req_hold_stale_q <= 1'b0;
            req_hold_pc_q <= 32'h0;
            req_hi_q <= 1'b0;
            req_pc_q <= 32'h0;
            pc_q <= 32'h0;
            block_valid_q <= 1'b0;
            block_hi_q <= 1'b0;
            block_pc_q <= 32'h0;
            block_data_q <= 64'h0;
            block_error_q <= 2'b0;
            block_drop_high_q <= 1'b0;
            req_pred0_valid_q <= 1'b0;
            req_pred0_taken_q <= 1'b0;
            req_pred0_target_q <= 32'h0;
            req_pred1_valid_q <= 1'b0;
            req_pred1_taken_q <= 1'b0;
            req_pred1_target_q <= 32'h0;
            block_pred0_valid_q <= 1'b0;
            block_pred0_taken_q <= 1'b0;
            block_pred0_target_q <= 32'h0;
            block_pred1_valid_q <= 1'b0;
            block_pred1_taken_q <= 1'b0;
            block_pred1_target_q <= 32'h0;
        end else begin
            if (block_consumed_full) begin
                block_valid_q <= 1'b0;
                block_drop_high_q <= 1'b0;
            end else if (push_low) begin
                block_hi_q <= 1'b1;
            end

            if (rsp_fire) begin
                if (!req_stale_q && !redirect_valid) begin
                    block_valid_q <= 1'b1;
                    // ⚠️ 坑位：总线按8B取块，但目标PC[2]必须保留；
                    // 高word目标不允许执行块内低word（PR66 R2）。
                    block_hi_q <= req_hi_q;
                    block_pc_q <= req_pc_q;
                    block_data_q <= i_rsp_data;
                    block_error_q <= i_rsp_error;
                    block_drop_high_q <= !req_hi_q && req_pred0_taken_q;
                    block_pred0_valid_q <= req_pred0_valid_q;
                    block_pred0_taken_q <= req_pred0_taken_q;
                    block_pred0_target_q <= req_pred0_target_q;
                    // When the request starts at the high word, q0 is that
                    // request's first instruction. Populate the selected high
                    // word metadata from pred0; for low-word requests pred1
                    // remains the metadata for the following word after q0 is consumed.
                    block_pred1_valid_q <= req_hi_q ? req_pred0_valid_q : req_pred1_valid_q;
                    block_pred1_taken_q <= req_hi_q ? req_pred0_taken_q : req_pred1_taken_q;
                    block_pred1_target_q <= req_hi_q ? req_pred0_target_q : req_pred1_target_q;
                end
            end
            if (req_fire) begin
                req_outstanding_q <= 1'b1;
                req_stale_q <= req_fire_stale;
                req_hold_q <= 1'b0;
                req_hold_stale_q <= 1'b0;
                req_hi_q <= issue_pc[2];
                req_pc_q <= {issue_pc[31:3], 3'b000};
                req_pred0_valid_q <= (PREDICT_ENABLE && !req_fire_stale) ? bp_q0_hit : 1'b0;
                req_pred0_taken_q <= (PREDICT_ENABLE && !req_fire_stale) ? bp_q0_taken : 1'b0;
                req_pred0_target_q <= (PREDICT_ENABLE && !req_fire_stale) ? bp_q0_target : 32'h0;
                req_pred1_valid_q <= (PREDICT_ENABLE && !req_fire_stale && !issue_pc[2]) ? bp_q1_hit : 1'b0;
                req_pred1_taken_q <= (PREDICT_ENABLE && !req_fire_stale && !issue_pc[2]) ? bp_q1_taken : 1'b0;
                req_pred1_target_q <= (PREDICT_ENABLE && !req_fire_stale && !issue_pc[2]) ? bp_q1_target : 32'h0;
                if (!req_fire_stale)
                    pc_q <= PREDICT_ENABLE ? predicted_next_pc :
                            ({issue_pc[31:3], 3'b000} + 32'd8);
            end else if (i_req_valid && !i_req_ready && !req_hold_q) begin
                req_hold_q <= 1'b1;
                req_hold_pc_q <= pc_q;
                req_hold_stale_q <= redirect_valid;
            end
            if (rsp_fire && !req_fire) begin
                req_outstanding_q <= 1'b0;
                req_stale_q <= 1'b0;
            end
            if (redirect_valid) begin
                pc_q <= {redirect_target[31:2], 2'b00};
                block_valid_q <= 1'b0;
                block_hi_q <= 1'b0;
                block_drop_high_q <= 1'b0;
                req_outstanding_q <= req_fire || (req_outstanding_q && !rsp_fire);
                req_stale_q <= req_fire || (req_outstanding_q && !rsp_fire);
                if (req_hold_q || (i_req_valid && !i_req_ready))
                    req_hold_stale_q <= 1'b1;
            end
        end
    end
endmodule
