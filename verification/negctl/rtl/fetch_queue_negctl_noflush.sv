// ============================================================================
//        Fetch Queue (M0-1 / M1-1)
//        Dual-output instruction queue for the in-order dual-issue prototype.
//
//        Purpose
//        - Enter up to 2 instructions per cycle.
//        - Present the oldest instruction on out0 and the second-oldest on out1.
//        - Preserve the complete IF/ID payload: pc, inst, fault, pred_*.
//
//        Protocol
//        - in1_valid is only meaningful when in0_valid is asserted.  The queue
//          is compacted: it never stores a hole in front of a valid entry.
//        - in_ready returns the number of entries that can be accepted this
//          cycle (0, 1, or 2).  DEPTH=4 uses registered occupancy only;
//          other depths retain the legacy same-cycle pop credit.
//        - out1_consume is only honored when out0_consume is asserted.
//        - flush clears the whole queue.  The first version intentionally has
//          no partial-flush / keep_pc input: PR #64 review T4 forbids comparing
//          PC values to decide age.  Partial flush needs a dynamic sequence
//          number and is deferred.
//
//        Reference
//        - biRISC-V biriscv_frontend.v / biriscv_fetch.v (Apache-2.0)
//        - Ibex ibex_fetch_fifo.sv
//        - Project ADR-DUAL-ISSUE-M1
// ============================================================================
`include "defines.sv"

module fetch_queue #(
    parameter integer DEPTH = 4
)(
    input  wire         clk,
    input  wire         rst,

    // Push side: up to two entries, in program order.
    input  wire         in0_valid,
    input  wire [31:0]  in0_pc,
    input  wire [31:0]  in0_inst,
    input  wire         in0_fault,
    input  wire         in0_pred_valid,
    input  wire         in0_pred_taken,
    input  wire [31:0]  in0_pred_target,

    input  wire         in1_valid,
    input  wire [31:0]  in1_pc,
    input  wire [31:0]  in1_inst,
    input  wire         in1_fault,
    input  wire         in1_pred_valid,
    input  wire         in1_pred_taken,
    input  wire [31:0]  in1_pred_target,

    output wire [1:0]   in_ready,        // number of free entries, 0..2

    // Pop side: oldest at out0.
    // Raw occupancy-valid signals are independent of flush and are intended
    // for decode-only combinational preparation. Architectural issue must
    // continue to use out*_valid, which are suppressed during flush.
    output wire         decode0_valid,
    output wire         decode1_valid,
    output wire         out0_valid,
    output wire [31:0]  out0_pc,
    output wire [31:0]  out0_inst,
    output wire         out0_fault,
    output wire         out0_pred_valid,
    output wire         out0_pred_taken,
    output wire [31:0]  out0_pred_target,

    output wire         out1_valid,
    output wire [31:0]  out1_pc,
    output wire [31:0]  out1_inst,
    output wire         out1_fault,
    output wire         out1_pred_valid,
    output wire         out1_pred_taken,
    output wire [31:0]  out1_pred_target,

    input  wire         out0_consume,
    input  wire         out1_consume,

    input  wire         flush
);

    localparam integer P_W = 32 + 32 + 1 + 1 + 1 + 32;

    // Entry layout:
    //   [31:0]   pc
    //   [63:32]  inst
    //   [64]     fault
    //   [65]     pred_valid
    //   [66]     pred_taken
    //   [98:67]  pred_target
    wire [P_W-1:0] in0_entry = {in0_pred_target, in0_pred_taken,
                                in0_pred_valid, in0_fault, in0_inst, in0_pc};
    wire [P_W-1:0] in1_entry = {in1_pred_target, in1_pred_taken,
                                in1_pred_valid, in1_fault, in1_inst, in1_pc};

    reg [P_W-1:0] entry_q [0:DEPTH-1];
    reg [3:0]     count_q;

    wire [P_W-1:0] out0_entry = entry_q[0];
    wire [P_W-1:0] out1_entry = entry_q[1];

    wire pop0 = out0_consume && (count_q != 4'd0);
    wire pop1 = out0_consume && out1_consume && (count_q >= 4'd2);

    wire [3:0] pop_count = {3'b0, pop0} + {3'b0, pop1};
    wire [3:0] post_pop_count = count_q - pop_count;
    wire [3:0] free_slots = DEPTH[3:0] - post_pop_count;

    // Production depth 4 advertises current free capacity, independent of
    // issue/pop. This cuts the decode -> pop -> fetch-producer feedback path.
    // A full queue must retry inputs after the pop has been registered.
    // See docs/logs/Codex/2026-10-24-pr77-feedback-and-s1-ready.md.
    generate
        if (DEPTH == 4) begin : gen_depth4_ready_decode
            reg [1:0] ready_decode;
            always @* begin
                if (flush == `True) begin
                    ready_decode = 2'd0;
                end else begin
                    case (count_q)
                        4'd0, 4'd1, 4'd2: ready_decode = 2'd2;
                        4'd3: ready_decode = 2'd1;
                        4'd4: ready_decode = 2'd0;
                        default: ready_decode = 2'd0;
                    endcase
                end
            end
            assign in_ready = ready_decode;
        end else begin : gen_generic_ready_decode
            assign in_ready = flush ? 2'd0 :
                              (free_slots >= 4'd2) ? 2'd2 :
                              free_slots[1:0];
        end
    endgenerate

    wire push0 = in0_valid && (in_ready >= 2'd1);
    wire push1 = in0_valid && in1_valid && (in_ready >= 2'd2);
    wire [3:0] push_count = {3'b0, push0} + {3'b0, push1};
    wire [3:0] next_count = post_pop_count + push_count;

    // One-hot decode the post-pop occupancy for the production depth.  The
    // old entry steering compared every slot against the subtractor result
    // `count_q - pop_count`; that put the issue->pop decision on a shared
    // arithmetic/control cone feeding every entry D mux.  These equations
    // are the same occupancy transition, expressed directly from the current
    // count and the (already qualified) one/two pop controls.
    wire [4:0] depth4_post_pop_is;
    assign depth4_post_pop_is[0] = (count_q == 4'd0) ||
                                   ((count_q == 4'd1) && pop0) ||
                                   ((count_q == 4'd2) && pop1);
    assign depth4_post_pop_is[1] = ((count_q == 4'd1) && !pop0) ||
                                   ((count_q == 4'd2) && pop0 && !pop1) ||
                                   ((count_q == 4'd3) && pop1);
    assign depth4_post_pop_is[2] = ((count_q == 4'd2) && !pop0) ||
                                   ((count_q == 4'd3) && pop0 && !pop1) ||
                                   ((count_q == 4'd4) && pop1);
    assign depth4_post_pop_is[3] = ((count_q == 4'd3) && !pop0) ||
                                   ((count_q == 4'd4) && pop0 && !pop1);
    assign depth4_post_pop_is[4] = (count_q == 4'd4) && !pop0;

    // x0-style valid gating: flush wins combinationally so downstream sees an
    // empty queue in the flush cycle, matching the synchronous clear.
    assign decode0_valid   = (count_q != 4'd0);
    assign decode1_valid   = (count_q >= 4'd2);
    assign out0_valid      = (flush == `False) && decode0_valid;
    assign out0_pc         = out0_entry[31:0];
    assign out0_inst       = out0_entry[63:32];
    assign out0_fault      = out0_entry[64];
    assign out0_pred_valid = out0_entry[65];
    assign out0_pred_taken = out0_entry[66];
    assign out0_pred_target= out0_entry[98:67];

    assign out1_valid      = (flush == `False) && decode1_valid;
    assign out1_pc         = out1_entry[31:0];
    assign out1_inst       = out1_entry[63:32];
    assign out1_fault      = out1_entry[64];
    assign out1_pred_valid = out1_entry[65];
    assign out1_pred_taken = out1_entry[66];
    assign out1_pred_target= out1_entry[98:67];

    // The production dual-issue core uses DEPTH=4.  Keep that hot path's
    // source and destination indices constant so pop_count does not select a
    // dynamically indexed array read/write mux.  Preserve the generic
    // implementation for other parameter values.
    generate
        if (DEPTH == 4) begin : gen_depth4_steering
            genvar slot;
            for (slot = 0; slot < 4; slot = slot + 1) begin : gen_entry
                wire [P_W-1:0] survivor_entry;
                wire           survivor_valid;

                if (slot < 2) begin : gen_two_shift_sources
                    assign survivor_entry = pop1 ? entry_q[slot + 2] :
                                            pop0 ? entry_q[slot + 1] :
                                                   entry_q[slot];
                    assign survivor_valid =
                        (pop1 && (count_q > (slot + 2))) ||
                        (pop0 && !pop1 && (count_q > (slot + 1))) ||
                        (!pop0 && (count_q > slot));
                end else if (slot == 2) begin : gen_one_shift_source
                    assign survivor_entry = pop0 ? entry_q[3] : entry_q[2];
                    assign survivor_valid =
                        (!pop1 && pop0 && (count_q > 4'd3)) ||
                        (!pop0 && (count_q > 4'd2));
                end else begin : gen_no_shift_source
                    assign survivor_entry = entry_q[3];
                    assign survivor_valid = !pop0 && (count_q > 4'd3);
                end

                wire push1_to_slot;
                if (slot > 0) begin : gen_push1_destination
                    assign push1_to_slot = push1 && depth4_post_pop_is[slot - 1];
                end else begin : gen_no_push1_destination
                    assign push1_to_slot = 1'b0;
                end

                always @(posedge clk) begin
                    if (rst == `RstEnable || flush == `True) begin
                        entry_q[slot] <= {P_W{1'b0}};
                    end else if (push0 && depth4_post_pop_is[slot]) begin
                        entry_q[slot] <= in0_entry;
                    end else if (push1_to_slot) begin
                        entry_q[slot] <= in1_entry;
                    end else if (survivor_valid) begin
                        entry_q[slot] <= survivor_entry;
                    end else begin
                        entry_q[slot] <= {P_W{1'b0}};
                    end
                end
            end
        end else begin : gen_generic_steering
            integer i;
            always @(posedge clk) begin
                if (rst == `RstEnable || flush == `True) begin
                    for (i = 0; i < DEPTH; i = i + 1)
                        entry_q[i] <= {P_W{1'b0}};
                end else begin
                    // Generic parameter fallback; the default DEPTH=4 path
                    // above uses constant source/destination indices.
                    for (i = 0; i < DEPTH; i = i + 1) begin
                        if ((i < post_pop_count) && ((i + pop_count) < DEPTH))
                            entry_q[i] <= entry_q[i+pop_count];
                        else
                            entry_q[i] <= {P_W{1'b0}};
                    end

                    if (push0)
                        entry_q[post_pop_count] <= in0_entry;
                    if (push1)
                        entry_q[post_pop_count + 4'd1] <= in1_entry;
                end
            end
        end
    endgenerate

    always @(posedge clk) begin
        // NEGCTL: retain occupancy across flush; current payload clear stays intact.
        if (rst == `RstEnable)
            count_q <= 4'd0;
        else
            count_q <= next_count;
    end

    // synthesis translate_off
    always @(posedge clk) begin
        if (rst == `RstDisable && flush == `True &&
            (out0_consume == `True || out1_consume == `True)) begin
            $display("fetch_queue: flush and consume asserted together; flush wins");
        end
        if (next_count > DEPTH)
            $error("fetch_queue: next_count overflow");
    end
    // synthesis translate_on

endmodule
