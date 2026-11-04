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
//          DEPTH=8 uses banked storage/head-tail pointers and occupancy-only credit;
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
    parameter integer DEPTH = 4,
    parameter integer M_MODE = 2,
    parameter integer SIDECAR_ENABLE = 0
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
    output wire [1:0]   raw_credit,      // occupancy credit without flush gating

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
    // Narrow pre-decoded fields, valid with out0_valid (see entry layout).
    output wire [4:0]   out0_rs1,
    output wire [4:0]   out0_rs2,
    output wire [4:0]   out0_rd,
    output wire         out0_reg_write,
    output wire         out0_is_alu,
    output wire         out0_is_mem,
    output wire [10:0]  out0_sidecar,

    output wire         out1_valid,
    output wire [31:0]  out1_pc,
    output wire [31:0]  out1_inst,
    output wire         out1_fault,
    output wire         out1_pred_valid,
    output wire         out1_pred_taken,
    output wire [31:0]  out1_pred_target,
    output wire [4:0]   out1_rs1,
    output wire [4:0]   out1_rs2,
    output wire [4:0]   out1_rd,
    output wire         out1_reg_write,
    output wire         out1_is_alu,
    output wire         out1_is_mem,
    output wire [10:0]  out1_sidecar,

    input  wire         out0_consume,
    input  wire         out1_consume,

    input  wire         flush
);

    localparam integer BASE_P_W = 32 + 32 + 1 + 1 + 1 + 32 + 5 + 5 + 5 + 1 + 1 + 1;
    localparam integer P_W = BASE_P_W + 11;

    // Entry layout (the original 117-bit payload remains at the bottom;
    // the 11-bit decode sidecar occupies [127:117]):
    //   [31:0]   pc
    //   [63:32]  inst
    //   [64]     fault
    //   [65]     pred_valid
    //   [66]     pred_taken
    //   [98:67]  pred_target
    //   [103:99] rs1        (inst[19:15])
    //   [108:104] rs2       (inst[24:20])
    //   [113:109] rd        (inst[11:7])
    //   [114]    reg_write
    //   [115]    is_alu
    //   [116]    is_mem
    //   [117]    bad (fault/illegal/ecall/ebreak)
    //   [118]    reg_we
    //   [119]    uses_rs1
    //   [120]    uses_rs2
    //   [121]    branch
    //   [122]    control (branch/jal/jalr)
    //   [123]    mem
    //   [124]    mdu
    //   [125]    serial (csr/mret/fence)
    //   [126]    copy (addi rd,rs1,0)
    //   [127]    literal (lui or addi from x0)
    //
    // The narrow fields are decoded once on the push side and travel with the
    // entry, so consumers (hazard compares, register-file write enables, LSU
    // dispatch) read 5-bit operands instead of single bits of the raw 32-bit
    // instruction. In the mapped design every one of head0_q[49..55] /
    // head1_q[49..55] (inst[17:23]) carried 277-284 LUT inputs; the same
    // consumers on the narrow fields spread over ten much smaller nets.
    wire [6:0] in0_opcode = in0_inst[6:0];
    wire [6:0] in1_opcode = in1_inst[6:0];
    wire       in0_reg_write;
    wire       in1_reg_write;
    wire       in0_is_alu = (in0_opcode == 7'b0010011) || (in0_opcode == 7'b0110011);
    wire       in1_is_alu = (in1_opcode == 7'b0010011) || (in1_opcode == 7'b0110011);
    wire       in0_is_mem;
    wire       in1_is_mem;
    wire [10:0] in0_sidecar, in1_sidecar;

    generate
        if (SIDECAR_ENABLE != 0) begin : gen_decode_sidecar
            wire [4:0] s0_rs1, s0_rs2, s0_rd, s1_rs1, s1_rs2, s1_rd;
            wire s0_uses1, s0_uses2, s0_regwe, s0_branch, s0_jal, s0_jalr;
            wire s0_mem, s0_mdu, s0_csr, s0_ecall, s0_ebreak, s0_mret, s0_fence, s0_illegal;
            wire s1_uses1, s1_uses2, s1_regwe, s1_branch, s1_jal, s1_jalr;
            wire s1_mem, s1_mdu, s1_csr, s1_ecall, s1_ebreak, s1_mret, s1_fence, s1_illegal;
            wire [31:0] s0_imm, s1_imm;
            wire [2:0] s0_funct3, s1_funct3;
            wire [3:0] s0_alu, s1_alu;
            wire s0_pc, s0_zero, s0_bimm, s1_pc, s1_zero, s1_bimm;
            dual_pipeline_decode #(.M_MODE(M_MODE)) u_decode0 (
                .inst_i(in0_inst), .pc_i(in0_pc), .fault_i(in0_fault),
                .rs1_o(s0_rs1), .rs2_o(s0_rs2), .rd_o(s0_rd),
                .uses_rs1_o(s0_uses1), .uses_rs2_o(s0_uses2), .reg_we_o(s0_regwe),
                .imm_o(s0_imm), .alu_func_o(s0_alu), .src_a_pc_o(s0_pc),
                .src_a_zero_o(s0_zero), .src_b_imm_o(s0_bimm),
                .branch_o(s0_branch), .jal_o(s0_jal), .jalr_o(s0_jalr),
                .mem_o(s0_mem), .funct3_o(s0_funct3), .mdu_o(s0_mdu),
                .csr_o(s0_csr), .csr_addr_o(), .csr_we_o(), .csr_op_o(),
                .csr_imm_o(), .csr_uimm_o(), .ecall_o(s0_ecall),
                .ebreak_o(s0_ebreak), .mret_o(s0_mret), .fence_o(s0_fence),
                .illegal_o(s0_illegal)
            );
            dual_pipeline_decode #(.M_MODE(M_MODE)) u_decode1 (
                .inst_i(in1_inst), .pc_i(in1_pc), .fault_i(in1_fault),
                .rs1_o(s1_rs1), .rs2_o(s1_rs2), .rd_o(s1_rd),
                .uses_rs1_o(s1_uses1), .uses_rs2_o(s1_uses2), .reg_we_o(s1_regwe),
                .imm_o(s1_imm), .alu_func_o(s1_alu), .src_a_pc_o(s1_pc),
                .src_a_zero_o(s1_zero), .src_b_imm_o(s1_bimm),
                .branch_o(s1_branch), .jal_o(s1_jal), .jalr_o(s1_jalr),
                .mem_o(s1_mem), .funct3_o(s1_funct3), .mdu_o(s1_mdu),
                .csr_o(s1_csr), .csr_addr_o(), .csr_we_o(), .csr_op_o(),
                .csr_imm_o(), .csr_uimm_o(), .ecall_o(s1_ecall),
                .ebreak_o(s1_ebreak), .mret_o(s1_mret), .fence_o(s1_fence),
                .illegal_o(s1_illegal)
            );
            wire s0_bad = in0_fault || s0_illegal || s0_ecall || s0_ebreak;
            wire s1_bad = in1_fault || s1_illegal || s1_ecall || s1_ebreak;
            wire s0_copy = !s0_bad && in0_opcode == 7'h13 && s0_funct3 == 0 && s0_imm == 0;
            wire s1_copy = !s1_bad && in1_opcode == 7'h13 && s1_funct3 == 0 && s1_imm == 0;
            wire s0_literal = !s0_bad && (in0_opcode == 7'h37 ||
                (in0_opcode == 7'h13 && s0_funct3 == 0 && s0_rs1 == 0));
            wire s1_literal = !s1_bad && (in1_opcode == 7'h37 ||
                (in1_opcode == 7'h13 && s1_funct3 == 0 && s1_rs1 == 0));
            assign in0_reg_write = s0_regwe;
            assign in1_reg_write = s1_regwe;
            assign in0_is_mem = s0_mem;
            assign in1_is_mem = s1_mem;
            assign in0_sidecar = {s0_literal, s0_copy, (s0_csr || s0_mret || s0_fence),
                s0_mdu, s0_mem, (s0_branch || s0_jal || s0_jalr), s0_branch,
                s0_uses2, s0_uses1, s0_regwe, s0_bad};
            assign in1_sidecar = {s1_literal, s1_copy, (s1_csr || s1_mret || s1_fence),
                s1_mdu, s1_mem, (s1_branch || s1_jal || s1_jalr), s1_branch,
                s1_uses2, s1_uses1, s1_regwe, s1_bad};
        end else begin : gen_no_decode_sidecar
            assign in0_reg_write = (in0_opcode == 7'b0110111) || (in0_opcode == 7'b0010111) ||
                (in0_opcode == 7'b1101111) || (in0_opcode == 7'b1100111) ||
                (in0_opcode == 7'b0000011) || (in0_opcode == 7'b0010011) ||
                (in0_opcode == 7'b0110011);
            assign in1_reg_write = (in1_opcode == 7'b0110111) || (in1_opcode == 7'b0010111) ||
                (in1_opcode == 7'b1101111) || (in1_opcode == 7'b1100111) ||
                (in1_opcode == 7'b0000011) || (in1_opcode == 7'b0010011) ||
                (in1_opcode == 7'b0110011);
            assign in0_is_mem = (in0_opcode == 7'b0000011) || (in0_opcode == 7'b0100011);
            assign in1_is_mem = (in1_opcode == 7'b0000011) || (in1_opcode == 7'b0100011);
            assign in0_sidecar = 11'b0;
            assign in1_sidecar = 11'b0;
        end
    endgenerate

    wire [P_W-1:0] in0_entry = {in0_sidecar, in0_is_mem, in0_is_alu, in0_reg_write,
                                in0_inst[11:7], in0_inst[24:20], in0_inst[19:15],
                                in0_pred_target, in0_pred_taken,
                                in0_pred_valid, in0_fault, in0_inst, in0_pc};
    wire [P_W-1:0] in1_entry = {in1_sidecar, in1_is_mem, in1_is_alu, in1_reg_write,
                                in1_inst[11:7], in1_inst[24:20], in1_inst[19:15],
                                in1_pred_target, in1_pred_taken,
                                in1_pred_valid, in1_fault, in1_inst, in1_pc};

    reg [P_W-1:0] entry_q [0:DEPTH-1];
    reg [3:0]     count_q;

    wire [P_W-1:0] out0_entry;
    wire [P_W-1:0] out1_entry;

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
        if (DEPTH == 8) begin : gen_depth8_ready_decode
            // Current occupancy only: no consumer/issue path feeds fetch credit.
            assign raw_credit = (count_q >= 4'd8) ? 2'd0 :
                                (count_q == 4'd7) ? 2'd1 : 2'd2;
            assign in_ready = flush ? 2'd0 : raw_credit;
        end else if (DEPTH == 4) begin : gen_depth4_ready_decode
            reg [1:0] ready_decode;
            always @* begin
                case (count_q)
                    4'd0, 4'd1, 4'd2: ready_decode = 2'd2;
                    4'd3: ready_decode = 2'd1;
                    4'd4: ready_decode = 2'd0;
                    default: ready_decode = 2'd0;
                endcase
            end
            assign raw_credit = ready_decode;
            assign in_ready = flush ? 2'd0 : raw_credit;
        end else begin : gen_generic_ready_decode
            assign raw_credit = (free_slots >= 4'd2) ? 2'd2 :
                                free_slots[1:0];
            assign in_ready = flush ? 2'd0 : raw_credit;
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
    assign out0_rs1        = out0_entry[103:99];
    assign out0_rs2        = out0_entry[108:104];
    assign out0_rd         = out0_entry[113:109];
    assign out0_reg_write  = out0_entry[114];
    assign out0_is_alu     = out0_entry[115];
    assign out0_is_mem     = out0_entry[116];
    assign out0_sidecar    = out0_entry[P_W-1 -: 11];

    assign out1_valid      = (flush == `False) && decode1_valid;
    assign out1_pc         = out1_entry[31:0];
    assign out1_inst       = out1_entry[63:32];
    assign out1_fault      = out1_entry[64];
    assign out1_pred_valid = out1_entry[65];
    assign out1_pred_taken = out1_entry[66];
    assign out1_pred_target= out1_entry[98:67];
    assign out1_rs1        = out1_entry[103:99];
    assign out1_rs2        = out1_entry[108:104];
    assign out1_rd         = out1_entry[113:109];
    assign out1_reg_write  = out1_entry[114];
    assign out1_is_alu     = out1_entry[115];
    assign out1_is_mem     = out1_entry[116];
    assign out1_sidecar    = out1_entry[P_W-1 -: 11];

    // The production dual-issue core uses DEPTH=4.  Keep that hot path's
    // source and destination indices constant so pop_count does not select a
    // dynamically indexed array read/write mux.  Preserve the generic
    // implementation for other parameter values.
    generate
        if (DEPTH == 8) begin : gen_banked_heads
            // Even/odd banks each receive at most one write per cycle. Entries
            // never shift on pop; head_q selects both visible entries directly.
            reg [P_W-1:0] even_q [0:3];
            reg [P_W-1:0] odd_q [0:3];
            reg [2:0] head_q, head1_q, tail_q;
            wire [2:0] tail1 = tail_q + 3'd1;
            wire [2:0] head_next = head_q + pop_count[2:0];
            wire [2:0] head1_next = head1_q + pop_count[2:0];
            // Read the two visible entries directly from the ring banks.
            // Only the narrow head pointer advances on pop, so issue/decode
            // no longer feeds a wide payload-register D mux.
            assign out0_entry = head_q[0] ? odd_q[head_q[2:1]] : even_q[head_q[2:1]];
            // Keep the second-entry pointer registered so the predecoded
            // out1 sidecar does not wait on head_q's incrementer.
            assign out1_entry = head1_q[0] ? odd_q[head1_q[2:1]] :
                                             even_q[head1_q[2:1]];
            always @(posedge clk) begin
                if (rst) begin
                    head_q <= 3'd0;
                    head1_q <= 3'd1;
                    tail_q <= 3'd0;
                end else if (flush) begin
                    head_q <= 3'd0;
                    head1_q <= 3'd1;
                    tail_q <= 3'd0;
                end else if (push_count != 0 || pop_count != 0) begin
                    head_q <= head_next;
                    head1_q <= head1_next;
                    tail_q <= tail_q + push_count[2:0];
                end
                if (!rst && !flush) begin
                    if (push0 && !tail_q[0]) even_q[tail_q[2:1]] <= in0_entry;
                    else if (push1 && tail_q[0]) even_q[tail1[2:1]] <= in1_entry;
                    if (push0 && tail_q[0]) odd_q[tail_q[2:1]] <= in0_entry;
                    else if (push1 && !tail_q[0]) odd_q[tail1[2:1]] <= in1_entry;
                end
            end
        end else if (DEPTH == 4) begin : gen_depth4_steering
            assign out0_entry = entry_q[0];
            assign out1_entry = entry_q[1];
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
            assign out0_entry = entry_q[0];
            assign out1_entry = entry_q[1];
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
        if (rst == `RstEnable || flush == `True)
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
