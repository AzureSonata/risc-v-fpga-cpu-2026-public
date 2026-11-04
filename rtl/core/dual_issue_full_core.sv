// ============================================================================
//        Dual-Issue Full Core (M1 lane0 full path)
//
//        Extends dual_issue_mini_core with lane0 D-side load/store, CSR
//        read/write, precise trap, MRET and machine timer/external interrupts.
//        Lane1 remains ALU-only.  A lane0 aligned SRAM load or store may pair
//        with an independent lane1 ALU; other lane0 non-ALU instructions serialize.
// ============================================================================
`include "defines.sv"

module dual_issue_full_core #(
    parameter bit DUAL_ISSUE_EN = 1'b1,
    parameter integer M_MODE = 2,
    parameter [31:0] CACHEABLE_BASE = 32'h8000_0000,
    parameter [31:0] CACHEABLE_SIZE = 32'h0001_0000,
    parameter integer FETCH_QUEUE_DEPTH = 8,
    parameter bit PREDICT_ENABLE = 1'b1,
    parameter integer PRED_MODE = 0,
    parameter integer BTB_ENTRIES = 64
)(
    input  wire        clk,
    input  wire        rst,

    // 64-bit instruction port
    output wire        i_req_valid,
    input  wire        i_req_ready,
    output wire [31:0] i_req_addr,
    input  wire        i_rsp_valid,
    output wire        i_rsp_ready,
    input  wire [63:0] i_rsp_data,
    input  wire [1:0] i_rsp_error,

    // 32-bit D-side port
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

    output wire        issue0,
    output wire        issue1,
    output wire        retire0_valid,
    output wire        retire1_valid,

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

    wire [31:0] wide_pc;
    wire [1:0]  fq_in_ready;
    wire        wf_q0_valid, wf_q1_valid, wf_q0_fault, wf_q1_fault;
    wire [31:0] wf_q0_pc, wf_q0_inst, wf_q1_pc, wf_q1_inst;
    wire wf_q0_pred_valid, wf_q0_pred_taken, wf_q1_pred_valid, wf_q1_pred_taken;
    wire [31:0] wf_q0_pred_target, wf_q1_pred_target;
    wire bp_update_valid, bp_update_taken, bp_update_exception, bp_update_is_call, bp_update_is_ret;
    wire [31:0] bp_update_pc, bp_update_target, bp_update_pred_target;
    wire bp_update_pred_taken;

    wire        branch_redirect, trap_redirect, mret_redirect, redirect_any;
    wire [31:0] redirect_target;
    wire        commit_trap_fire, commit_flush_young, commit_hold_s1;
    wire [31:0] commit_trap_cause, commit_trap_pc;
    wire        commit0_fire, commit1_fire;

    // ----------------------------------------------------------------
    // CSR reset domain.
    // ----------------------------------------------------------------
    // In the 125 MHz mapped design the single `rst` net still carries ~1,075
    // sinks after the board-level split (FANOUT-RESET-REPORT.md §1), of which
    // ~223 are csr_file flops. csr_file is quiescent while this copy is still
    // asserted (release skew = 1 cycle, long before any CSR write can commit),
    // and the copy uses an inverted next-state so the flow cannot merge it
    // back into `rst` (measured: functionally identical copies are merged).
    wire rst_hi = (rst == `RstEnable);
    reg  nrst_csr_q;
    reg  rst_csr_q;
    always @(posedge clk) begin
        if (rst_hi) begin
            nrst_csr_q <= 1'b0;
            rst_csr_q  <= `RstEnable;
        end else begin
            nrst_csr_q <= 1'b1;
            rst_csr_q  <= ~nrst_csr_q;
        end
    end
    wire rst_csr = rst_csr_q;

    wide_fetch #(.PREDICT_ENABLE(PREDICT_ENABLE), .PRED_MODE(PRED_MODE),
                 .BTB_ENTRIES(BTB_ENTRIES)) u_fetch (
        .clk(clk), .rst(rst),
        .i_req_valid(i_req_valid), .i_req_ready(i_req_ready),
        .i_req_addr(i_req_addr), .i_rsp_valid(i_rsp_valid),
        .i_rsp_ready(i_rsp_ready), .i_rsp_data(i_rsp_data), .i_rsp_error(i_rsp_error),
        .redirect_valid(redirect_any), .redirect_target(redirect_target),
        .push_ready(fq_in_ready),
        .q0_valid(wf_q0_valid), .q0_pc(wf_q0_pc), .q0_inst(wf_q0_inst), .q0_fault(wf_q0_fault),
        .q1_valid(wf_q1_valid), .q1_pc(wf_q1_pc), .q1_inst(wf_q1_inst), .q1_fault(wf_q1_fault),
        .q0_pred_valid(wf_q0_pred_valid), .q0_pred_taken(wf_q0_pred_taken),
        .q0_pred_target(wf_q0_pred_target),
        .q1_pred_valid(wf_q1_pred_valid), .q1_pred_taken(wf_q1_pred_taken),
        .q1_pred_target(wf_q1_pred_target),
        .update_valid(bp_update_valid), .update_pc(bp_update_pc),
        .update_taken(bp_update_taken), .update_target(bp_update_target),
        .update_pred_taken(bp_update_pred_taken), .update_pred_target(bp_update_pred_target),
        .update_exception(bp_update_exception), .update_is_call(bp_update_is_call),
        .update_is_ret(bp_update_is_ret),
        .pc_debug(pc_debug)
    );

    wire        fq_decode0_valid, fq_decode1_valid;
    wire        fq_out0_valid, fq_out1_valid;
    wire [31:0] fq_out0_pc, fq_out0_inst, fq_out1_pc, fq_out1_inst;
    wire        fq_out0_fault, fq_out1_fault;
    wire fq_out0_pred_valid, fq_out0_pred_taken, fq_out1_pred_valid, fq_out1_pred_taken;
    wire [31:0] fq_out0_pred_target, fq_out1_pred_target;

    fetch_queue #(.DEPTH(FETCH_QUEUE_DEPTH)) u_fq (
        .clk(clk), .rst(rst),
        .in0_valid(wf_q0_valid), .in0_pc(wf_q0_pc), .in0_inst(wf_q0_inst),
        .in0_fault(wf_q0_fault), .in0_pred_valid(wf_q0_pred_valid),
        .in0_pred_taken(wf_q0_pred_taken), .in0_pred_target(wf_q0_pred_target),
        .in1_valid(wf_q1_valid), .in1_pc(wf_q1_pc), .in1_inst(wf_q1_inst),
        .in1_fault(wf_q1_fault), .in1_pred_valid(wf_q1_pred_valid),
        .in1_pred_taken(wf_q1_pred_taken), .in1_pred_target(wf_q1_pred_target),
        .in_ready(fq_in_ready),
        .decode0_valid(fq_decode0_valid), .decode1_valid(fq_decode1_valid),
        .out0_valid(fq_out0_valid), .out0_pc(fq_out0_pc), .out0_inst(fq_out0_inst),
        .out0_fault(fq_out0_fault), .out0_pred_valid(fq_out0_pred_valid),
        .out0_pred_taken(fq_out0_pred_taken), .out0_pred_target(fq_out0_pred_target),
        .out1_valid(fq_out1_valid), .out1_pc(fq_out1_pc), .out1_inst(fq_out1_inst),
        .out1_fault(fq_out1_fault), .out1_pred_valid(fq_out1_pred_valid),
        .out1_pred_taken(fq_out1_pred_taken), .out1_pred_target(fq_out1_pred_target),
        .out0_consume(issue0), .out1_consume(issue1), .flush(redirect_any)
    );

    // ----------------------------------------------------------------
    // Lane 0 decode
    // ----------------------------------------------------------------
    wire [4:0]  d0_rs1, d0_rs2, d0_rd;
    wire [31:0] d0_imm;
    wire        d0_reg_we, d0_mem_req, d0_mem_we;
    wire [3:0]  d0_mem_wstrb;
    wire        d0_branch, d0_jal, d0_jalr, d0_lui, d0_auipc;
    wire        d0_uses_rs1, d0_uses_rs2, d0_illegal;
    wire        d0_ecall, d0_ebreak, d0_mret;
    wire [6:0]  d0_opcode, d0_funct7;
    wire [11:0] d0_csr_addr;
    wire        d0_csr_we, d0_csr_imm;
    wire [1:0]  d0_csr_op;
    wire [31:0] d0_csr_uimm;

    id_stage #(.SUPPORT_M(M_MODE == 2), .SUPPORT_ZMMUL(M_MODE == 1)) u_dec0 (
        .rst(rst), .inst_i(fq_out0_inst), .pc_i(fq_out0_pc),
        .inst_valid_i(fq_decode0_valid), .fault_i(fq_out0_fault),
        .pred_valid_i(1'b0), .pred_taken_i(1'b0), .pred_target_i(32'h0),
        .ex_jump_flag_i(1'b0), .rs1_addr_o(d0_rs1), .rs2_addr_o(d0_rs2),
        .imm_o(d0_imm), .reg_we_o(d0_reg_we), .rd_addr_o(d0_rd),
        .mem_req_o(d0_mem_req), .mem_we_o(d0_mem_we), .mem_wstrb_o(d0_mem_wstrb),
        .branch_o(d0_branch), .jal_o(d0_jal), .jalr_o(d0_jalr),
        .lui_o(d0_lui), .auipc_o(d0_auipc),
        .uses_rs1_o(d0_uses_rs1), .uses_rs2_o(d0_uses_rs2),
        .opcode_o(d0_opcode), .funct3_o(), .funct7_o(d0_funct7), .rd_o(),
        .pred_valid_o(), .pred_taken_o(), .pred_target_o(),
        .illegal_instr_o(d0_illegal),
        .csr_addr_o(d0_csr_addr), .csr_we_o(d0_csr_we), .csr_op_o(d0_csr_op),
        .csr_imm_o(d0_csr_imm), .csr_uimm_o(d0_csr_uimm),
        .sys_ecall_o(d0_ecall), .sys_ebreak_o(d0_ebreak), .sys_mret_o(d0_mret)
    );

    // ----------------------------------------------------------------
    // Lane 1 decode (ALU only)
    // ----------------------------------------------------------------
    wire [4:0]  d1_rs1, d1_rs2, d1_rd;
    wire        d1_reg_we, d1_uses_rs1, d1_uses_rs2, d1_is_alu;
    dual_issue_alu_predecode u_predecode1 (
        .inst_i(fq_out1_inst), .fault_i(fq_out1_fault),
        .eligible_o(d1_is_alu), .rs1_o(d1_rs1), .rs2_o(d1_rs2),
        .uses_rs1_o(d1_uses_rs1), .uses_rs2_o(d1_uses_rs2),
        .rd_o(d1_rd), .reg_write_o(d1_reg_we)
    );

    // A memory instruction in FQ slot 1 cannot issue in this core, but its
    // operands can be prepared while slot 0 advances.  This gives the LSU a
    // registered request packet by the time that instruction reaches the
    // head, avoiding a new bubble on the common ALU -> memory sequence.
    wire d1_prep_load = (fq_out1_inst[6:0] == 7'h03) &&
        ((fq_out1_inst[14:12] == 3'b000) || (fq_out1_inst[14:12] == 3'b001) ||
         (fq_out1_inst[14:12] == 3'b010) || (fq_out1_inst[14:12] == 3'b100) ||
         (fq_out1_inst[14:12] == 3'b101) || (fq_out1_inst[14:12] == 3'b110));
    wire d1_prep_store = (fq_out1_inst[6:0] == 7'h23) &&
        ((fq_out1_inst[14:12] == 3'b000) || (fq_out1_inst[14:12] == 3'b001) ||
         (fq_out1_inst[14:12] == 3'b010));
    wire d1_prep_mem = fq_out1_valid && !fq_out1_fault &&
                       (d1_prep_load || d1_prep_store);
    wire [31:0] d1_prep_imm = d1_prep_store
        ? {{20{fq_out1_inst[31]}}, fq_out1_inst[31:25], fq_out1_inst[11:7]}
        : {{20{fq_out1_inst[31]}}, fq_out1_inst[31:20]};

    // The architectural lane0 decoder below remains authoritative for
    // execution/retirement.  This parallel classifier supplies only the
    // narrow ordinary-ALU pair eligibility and destination metadata used by
    // issue hazard checks, avoiding the full ID decode cone on queue pop.
    wire        d0_pair_alu;
    wire [4:0]  d0_pair_rd;
    wire        d0_pair_reg_we;
    dual_issue_alu_predecode u_predecode0_pair (
        .inst_i(fq_out0_inst), .fault_i(fq_out0_fault),
        .eligible_o(d0_pair_alu), .rs1_o(), .rs2_o(),
        .uses_rs1_o(), .uses_rs2_o(),
        .rd_o(d0_pair_rd), .reg_write_o(d0_pair_reg_we)
    );

    function automatic is_alu;
        input [6:0] op;
        input [6:0] f7;
        input branch, jal, jalr, mem_req, lui, auipc;
        input ecall, ebreak, mret, illegal, fault;
        begin
            is_alu = !fault && !illegal && !branch && !jal && !jalr && !mem_req &&
                     !ecall && !ebreak && !mret &&
                     ((op == 7'h13) || ((op == 7'h33) && (f7 != 7'h01)) ||
                      lui || auipc);
        end
    endfunction

    wire d0_is_alu = is_alu(d0_opcode, d0_funct7, d0_branch, d0_jal, d0_jalr,
                            d0_mem_req, d0_lui, d0_auipc, d0_ecall, d0_ebreak,
                            d0_mret, d0_illegal, fq_out0_fault);

    wire d0_is_mdu = !fq_out0_fault && !d0_illegal &&
                     (d0_opcode == 7'h33) && (d0_funct7 == 7'h01);

    wire d0_is_ctl = !fq_out0_fault && !d0_illegal &&
                     (d0_branch || d0_jal || d0_jalr);
    wire d0_is_mem = !fq_out0_fault && !d0_illegal && d0_mem_req;
    wire d0_is_csr = !fq_out0_fault && !d0_illegal && (d0_opcode == 7'h73) &&
                     !d0_ecall && !d0_ebreak && !d0_mret;
    wire d0_is_sys = !fq_out0_fault && !d0_illegal &&
                     (d0_ecall || d0_ebreak || d0_mret);

    // ----------------------------------------------------------------
    // Register file (4R2W)
    // ----------------------------------------------------------------
    wire [31:0] d0_ra, d0_rb, d1_ra, d1_rb;
    wire [31:0] d0_ra_mux, d0_rb_mux, d1_ra_mux, d1_rb_mux;
    reg  [4:0]  r0a_addr, r0b_addr, r1a_addr, r1b_addr;
    always @* begin
        // Read the instruction register fields directly. The decoded source
        // addresses are cleared on illegal instructions, so using them here
        // puts the full funct3/illegal decode on the register-file-to-ALU
        // timing path. Source-use controls still gate hazards and side effects;
        // unused fields are architecturally don't-care.
        r0a_addr = fq_out0_inst[19:15];
        r0b_addr = fq_out0_inst[24:20];
        r1a_addr = fq_out1_inst[19:15];
        r1b_addr = fq_out1_inst[24:20];
    end

    // A memory instruction can issue only with the young-result queue and its
    // in-flight entries empty. Its operands therefore come from the RF ports,
    // including the retiring lane1 bypass, without the eight-entry young mux.
    wire [31:0] d0_mem_ra = d0_ra_mux;
    wire [31:0] d0_mem_rb = d0_rb_mux;
    wire [31:0] d1_prep_addr = d1_ra_mux + d1_prep_imm;
    wire [1:0] d0_mem_effective_addr_lo = d0_mem_ra[1:0] + d0_imm[1:0];
    wire d0_addr_in_cacheable_window;
    generate
        if ((CACHEABLE_BASE == 32'h8000_0000) &&
            (CACHEABLE_SIZE == 32'h0001_0000)) begin : g_fast_cacheable_window
            // A load address uses a sign-extended 12-bit I-immediate. For the
            // default 64 KiB window, only the carry out of the low 16 bits and
            // the adjacent high-word value decide whether the result is in
            // SRAM. This avoids a full 32-bit adder on the issue-pair path.
            wire d0_imm_negative = d0_imm[11];
            wire d0_low16_carry = d0_imm_negative
                ? ((|d0_mem_ra[15:12]) || (d0_mem_ra[11:0] > ~d0_imm[11:0]))
                : ((&d0_mem_ra[15:12]) && (d0_mem_ra[11:0] > ~d0_imm[11:0]));

            assign d0_addr_in_cacheable_window = d0_imm_negative
                ? ((d0_mem_ra[31:16] == 16'h8001 && !d0_low16_carry) ||
                   (d0_mem_ra[31:16] == 16'h8000 &&  d0_low16_carry))
                : ((d0_mem_ra[31:16] == 16'h8000 && !d0_low16_carry) ||
                   (d0_mem_ra[31:16] == 16'h7fff &&  d0_low16_carry));
        end else begin : g_generic_cacheable_window
            wire [31:0] d0_mem_effective_addr = d0_mem_ra + d0_imm;
            assign d0_addr_in_cacheable_window =
                ((d0_mem_effective_addr & ~(CACHEABLE_SIZE - 32'd1)) == CACHEABLE_BASE);
        end
    endgenerate
    wire d0_load_aligned =
        ((fq_out0_inst[14:12] == 3'b000 || fq_out0_inst[14:12] == 3'b100) ||
         ((fq_out0_inst[14:12] == 3'b001 || fq_out0_inst[14:12] == 3'b101) &&
          !d0_mem_effective_addr_lo[0]) ||
         (fq_out0_inst[14:12] == 3'b010 && d0_mem_effective_addr_lo == 2'b00));
    // Only pair aligned ordinary loads/stores whose start is inside the
    // configured power-of-two SRAM window. Alignment guarantees byte/half/word
    // accesses cannot cross its upper edge, so avoid a second 32-bit
    // end-address adder. ROM, MMIO, unmapped and misaligned accesses stay
    // lane0-only because their completion or side effects are not cacheable.
    wire d0_load_pairable = d0_is_mem && !d0_mem_we && d0_load_aligned &&
        d0_addr_in_cacheable_window;
    wire d0_store_pairable = d0_is_mem && d0_mem_we && d0_load_aligned &&
        d0_addr_in_cacheable_window;
    wire d0_mem_alu_pairable = d0_load_pairable || d0_store_pairable;
    // A conditional branch may pair only with the sequential instruction
    // already present in the queue and only when fetch predicted fall-through.
    // If the branch resolves taken, the younger ALU is squashed at commit.
    wire d0_branch_alu_pairable = d0_branch && !fq_out0_fault && !d0_illegal &&
        !fq_out0_pred_taken && (fq_out1_pc == (fq_out0_pc + 32'd4));
    wire d0_control_completion_replaceable = !fq_out0_fault && !d0_illegal &&
        (d0_branch || d0_jal || d0_jalr);
    wire d0_pair_eligible = d0_pair_alu || d0_mem_alu_pairable ||
                            d0_branch_alu_pairable;
    wire backend_stall, slot1_stall;

    // The in-order head shadows remain reserved for long-latency operations.
    // Independent plain ALUs issued behind an LSU/MDU are held separately
    // until the older operation commits, then drained in program order.
    reg [31:0] r0_pc_q, r0_pc_plus4_q, r0_instr_q, r0_csr_wdata_q, r0_csr_rdata_q;
    reg        r0_pred_valid_q, r0_pred_taken_q, r0_pred_pending_q;
    reg [31:0] r0_pred_target_q;
    reg [31:0] r0_cause_q, r0_tval_q;
    reg [4:0]  r0_rd_q;
    reg [11:0] r0_csr_addr_q;
    reg [1:0]  r0_csr_op_q;
    reg        r0_writes_rd_q, r0_is_alu_q, r0_mem_we_q, r0_is_csr_q;
    reg        r0_csr_we_q, r0_mret_q, r0_trap_q;
    reg        r0_mem_pending_q, r0_csr_pending_q;
    reg [31:0] r1_pc_q, r1_instr_q;
    reg [4:0]  r1_rd_q;
    reg        r1_writes_rd_q;
    reg        r1_mem_pair_pending_q;
    reg        r1_mem_pair_result_valid_q;
    reg [31:0] r1_mem_pair_result_q;
    reg        mdu_pending_q;
    // A completed memory instruction retires before an interrupt. The IRQ is
    // then injected as its own precise trap at the following instruction PC.
    reg        irq_after_mem_q;
    reg [31:0] irq_after_mem_pc_q, irq_after_mem_cause_q;
    wire       csr_irq_pending;
    wire [31:0] csr_irq_cause;

    localparam integer YOUNG_DEPTH = 8;
    reg [2:0] young_head_q, young_tail_q;
    reg [3:0] young_count_q;
    reg [YOUNG_DEPTH-1:0] young_valid_q;
    reg [31:0] young_pc_even_q [0:3];
    reg [31:0] young_pc_odd_q [0:3];
    reg [31:0] young_instr_even_q [0:3];
    reg [31:0] young_instr_odd_q [0:3];
    reg [4:0] young_rd_even_q [0:3];
    reg [4:0] young_rd_odd_q [0:3];
    reg [0:0] young_we_even_q [0:3];
    reg [0:0] young_we_odd_q [0:3];
    reg [31:0] young_data_even_q [0:3];
    reg [31:0] young_data_odd_q [0:3];
    wire [YOUNG_DEPTH*32-1:0] young_pc_flat;
    wire [YOUNG_DEPTH*32-1:0] young_instr_flat;
    wire [YOUNG_DEPTH*5-1:0] young_rd_flat;
    wire [YOUNG_DEPTH-1:0] young_we_flat;
    wire [YOUNG_DEPTH*32-1:0] young_data_flat;
    assign young_pc_flat = {young_pc_odd_q[3], young_pc_even_q[3],
                            young_pc_odd_q[2], young_pc_even_q[2],
                            young_pc_odd_q[1], young_pc_even_q[1],
                            young_pc_odd_q[0], young_pc_even_q[0]};
    assign young_instr_flat = {young_instr_odd_q[3], young_instr_even_q[3],
                               young_instr_odd_q[2], young_instr_even_q[2],
                               young_instr_odd_q[1], young_instr_even_q[1],
                               young_instr_odd_q[0], young_instr_even_q[0]};
    assign young_rd_flat = {young_rd_odd_q[3], young_rd_even_q[3],
                            young_rd_odd_q[2], young_rd_even_q[2],
                            young_rd_odd_q[1], young_rd_even_q[1],
                            young_rd_odd_q[0], young_rd_even_q[0]};
    assign young_we_flat = {young_we_odd_q[3], young_we_even_q[3],
                            young_we_odd_q[2], young_we_even_q[2],
                            young_we_odd_q[1], young_we_even_q[1],
                            young_we_odd_q[0], young_we_even_q[0]};
    assign young_data_flat = {young_data_odd_q[3], young_data_even_q[3],
                              young_data_odd_q[2], young_data_even_q[2],
                              young_data_odd_q[1], young_data_even_q[1],
                              young_data_odd_q[0], young_data_even_q[0]};

    function automatic [31:0] young_pc_at;
        input [2:0] index;
        input [YOUNG_DEPTH*32-1:0] pc_flat;
        begin
            case (index)
                3'd0: young_pc_at = pc_flat[ 31:  0];
                3'd1: young_pc_at = pc_flat[ 63: 32];
                3'd2: young_pc_at = pc_flat[ 95: 64];
                3'd3: young_pc_at = pc_flat[127: 96];
                3'd4: young_pc_at = pc_flat[159:128];
                3'd5: young_pc_at = pc_flat[191:160];
                3'd6: young_pc_at = pc_flat[223:192];
                3'd7: young_pc_at = pc_flat[255:224];
                default: young_pc_at = 32'd0;
            endcase
        end
    endfunction

    function automatic [31:0] young_instr_at;
        input [2:0] index;
        input [YOUNG_DEPTH*32-1:0] instr_flat;
        begin
            case (index)
                3'd0: young_instr_at = instr_flat[ 31:  0];
                3'd1: young_instr_at = instr_flat[ 63: 32];
                3'd2: young_instr_at = instr_flat[ 95: 64];
                3'd3: young_instr_at = instr_flat[127: 96];
                3'd4: young_instr_at = instr_flat[159:128];
                3'd5: young_instr_at = instr_flat[191:160];
                3'd6: young_instr_at = instr_flat[223:192];
                3'd7: young_instr_at = instr_flat[255:224];
                default: young_instr_at = 32'd0;
            endcase
        end
    endfunction

    function automatic [4:0] young_rd_at;
        input [2:0] index;
        input [YOUNG_DEPTH*5-1:0] rd_flat;
        begin
            case (index)
                3'd0: young_rd_at = rd_flat[ 4: 0];
                3'd1: young_rd_at = rd_flat[ 9: 5];
                3'd2: young_rd_at = rd_flat[14:10];
                3'd3: young_rd_at = rd_flat[19:15];
                3'd4: young_rd_at = rd_flat[24:20];
                3'd5: young_rd_at = rd_flat[29:25];
                3'd6: young_rd_at = rd_flat[34:30];
                3'd7: young_rd_at = rd_flat[39:35];
                default: young_rd_at = 5'd0;
            endcase
        end
    endfunction

    function automatic [0:0] young_we_at;
        input [2:0] index;
        input [YOUNG_DEPTH-1:0] we_flat;
        begin
            case (index)
                3'd0: young_we_at = we_flat[0];
                3'd1: young_we_at = we_flat[1];
                3'd2: young_we_at = we_flat[2];
                3'd3: young_we_at = we_flat[3];
                3'd4: young_we_at = we_flat[4];
                3'd5: young_we_at = we_flat[5];
                3'd6: young_we_at = we_flat[6];
                3'd7: young_we_at = we_flat[7];
                default: young_we_at = 1'b0;
            endcase
        end
    endfunction

    function automatic [31:0] young_data_at;
        input [2:0] index;
        input [YOUNG_DEPTH*32-1:0] data_flat;
        begin
            case (index)
                3'd0: young_data_at = data_flat[ 31:  0];
                3'd1: young_data_at = data_flat[ 63: 32];
                3'd2: young_data_at = data_flat[ 95: 64];
                3'd3: young_data_at = data_flat[127: 96];
                3'd4: young_data_at = data_flat[159:128];
                3'd5: young_data_at = data_flat[191:160];
                3'd6: young_data_at = data_flat[223:192];
                3'd7: young_data_at = data_flat[255:224];
                default: young_data_at = 32'd0;
            endcase
        end
    endfunction
    reg        young_ex0_valid_q, young_ex1_valid_q;
    reg [31:0] young_ex0_pc_q, young_ex0_instr_q;
    reg [4:0]  young_ex0_rd_q;
    reg        young_ex0_we_q;
    reg [31:0] young_ex1_pc_q, young_ex1_instr_q;
    reg [4:0]  young_ex1_rd_q;
    reg        young_ex1_we_q;

    wire young_long_pending = r0_mem_pending_q || mdu_pending_q;
    wire young_queue_drain = (young_count_q != 0) && !young_long_pending && !irq_after_mem_q &&
                             !r0_csr_pending_q;
    wire young_queue_hold = !young_long_pending &&
                            ((young_count_q != 0) || young_ex0_valid_q || young_ex1_valid_q);
    wire [3:0] young_inflight_count = {3'b0, young_ex0_valid_q} +
                                      {3'b0, young_ex1_valid_q};
    wire [4:0] young_reserved_count = {1'b0, young_count_q} +
                                      {1'b0, young_inflight_count};
    wire young_credit_one = young_reserved_count < YOUNG_DEPTH;
    wire young_credit_two = young_reserved_count <= (YOUNG_DEPTH - 2);

    wire alu_w0_valid, alu_w1_valid;
    wire [31:0] alu_w0_data, alu_w1_data;

    function automatic young_waw_conflict;
        input [4:0] rd;
        input reg_write;
        input [YOUNG_DEPTH-1:0] valid_flat;
        input [YOUNG_DEPTH-1:0] we_flat;
        input [YOUNG_DEPTH*5-1:0] rd_flat;
        integer k;
        reg hit;
        begin
            hit = 1'b0;
            if (reg_write && (rd != 5'd0)) begin
                if (r0_writes_rd_q && (r0_rd_q != 5'd0) && rd == r0_rd_q)
                    hit = 1'b1;
                if (r1_mem_pair_pending_q && r1_writes_rd_q &&
                    (r1_rd_q != 5'd0) && rd == r1_rd_q)
                    hit = 1'b1;
                if (young_ex0_valid_q && young_ex0_we_q &&
                    (young_ex0_rd_q != 5'd0) && rd == young_ex0_rd_q)
                    hit = 1'b1;
                if (young_ex1_valid_q && young_ex1_we_q &&
                    (young_ex1_rd_q != 5'd0) && rd == young_ex1_rd_q)
                    hit = 1'b1;
                for (k = 0; k < YOUNG_DEPTH; k = k + 1) begin
                    if (valid_flat[k] && young_we_at(k[2:0], we_flat) &&
                        (young_rd_at(k[2:0], rd_flat) != 5'd0) &&
                        rd == young_rd_at(k[2:0], rd_flat))
                        hit = 1'b1;
                end
            end
            young_waw_conflict = hit;
        end
    endfunction

    function automatic young_unready_raw_conflict;
        input [4:0] rs1, rs2;
        input use_rs1, use_rs2;
        reg hit;
        begin
            hit = 1'b0;
            if (r0_writes_rd_q && (r0_rd_q != 5'd0) &&
                ((use_rs1 && rs1 == r0_rd_q) || (use_rs2 && rs2 == r0_rd_q)))
                hit = 1'b1;
            if (r1_mem_pair_pending_q && r1_writes_rd_q && (r1_rd_q != 5'd0) &&
                !(r1_mem_pair_result_valid_q || (alu_w1_valid && !young_ex1_valid_q)) &&
                ((use_rs1 && rs1 == r1_rd_q) || (use_rs2 && rs2 == r1_rd_q)))
                hit = 1'b1;
            if (young_ex0_valid_q && young_ex0_we_q && (young_ex0_rd_q != 5'd0) &&
                !alu_w0_valid &&
                ((use_rs1 && rs1 == young_ex0_rd_q) ||
                 (use_rs2 && rs2 == young_ex0_rd_q)))
                hit = 1'b1;
            if (young_ex1_valid_q && young_ex1_we_q && (young_ex1_rd_q != 5'd0) &&
                !alu_w1_valid &&
                ((use_rs1 && rs1 == young_ex1_rd_q) ||
                 (use_rs2 && rs2 == young_ex1_rd_q)))
                hit = 1'b1;
            young_unready_raw_conflict = hit;
        end
    endfunction

    function automatic [31:0] young_source_value;
        input [4:0] rs;
        input [31:0] rf_value;
        input [YOUNG_DEPTH-1:0] valid_flat;
        input [YOUNG_DEPTH-1:0] we_flat;
        input [YOUNG_DEPTH*5-1:0] rd_flat;
        input [YOUNG_DEPTH*32-1:0] young_data;
        integer k;
        reg [2:0] idx;
        reg [31:0] value;
        begin
            value = rf_value;
            if (r1_mem_pair_pending_q && r1_mem_pair_result_valid_q &&
                r1_writes_rd_q && (r1_rd_q != 5'd0) && rs == r1_rd_q)
                value = r1_mem_pair_result_q;
            else if (r1_mem_pair_pending_q && alu_w1_valid &&
                     !young_ex1_valid_q && r1_writes_rd_q &&
                     (r1_rd_q != 5'd0) && rs == r1_rd_q)
                value = alu_w1_data;
            for (k = 0; k < YOUNG_DEPTH; k = k + 1) begin
                idx = young_head_q + k;
                if ((k < young_count_q) && valid_flat[idx] &&
                    young_we_at(idx, we_flat) && (young_rd_at(idx, rd_flat) != 5'd0) &&
                    (rs == young_rd_at(idx, rd_flat)))
                    value = young_data_at(idx, young_data);
            end
            if (young_ex0_valid_q && alu_w0_valid && young_ex0_we_q &&
                (young_ex0_rd_q != 5'd0) && (rs == young_ex0_rd_q))
                value = alu_w0_data;
            if (young_ex1_valid_q && alu_w1_valid && young_ex1_we_q &&
                (young_ex1_rd_q != 5'd0) && (rs == young_ex1_rd_q))
                value = alu_w1_data;
            young_source_value = value;
        end
    endfunction

    wire young_hazard0 = young_long_pending &&
        (young_waw_conflict(d0_pair_rd, d0_pair_reg_we, young_valid_q,
                            young_we_flat, young_rd_flat) ||
         young_unready_raw_conflict(d0_rs1, d0_rs2, d0_uses_rs1, d0_uses_rs2));
    wire young_hazard1 = young_long_pending &&
        (young_waw_conflict(d1_rd, d1_reg_we, young_valid_q,
                            young_we_flat, young_rd_flat) ||
         young_unready_raw_conflict(d1_rs1, d1_rs2, d1_uses_rs1, d1_uses_rs2));

    reg         prep_valid_q;
    reg [31:0]  prep_pc_q, prep_instr_q, prep_addr_q, prep_rb_q;
    wire prep_matches_head = prep_valid_q && fq_out0_valid &&
                             (prep_pc_q == fq_out0_pc) &&
                             (prep_instr_q == fq_out0_inst);
    wire prep_raw_hazard1 = young_long_pending &&
        young_unready_raw_conflict(fq_out1_inst[19:15], fq_out1_inst[24:20],
                                   1'b1, d1_prep_store);
    wire prep_slot0_dependency = issue0 && d0_reg_we && (d0_rd != 5'd0) &&
        (((fq_out1_inst[19:15] == d0_rd)) ||
         (d1_prep_store && (fq_out1_inst[24:20] == d0_rd)));
    wire prep_next_capture = issue0 && d1_prep_mem && !prep_raw_hazard1 &&
                             !prep_slot0_dependency && !fq_out0_fault &&
                             !d0_illegal && (young_count_q == 0) &&
                             !young_ex0_valid_q && !young_ex1_valid_q &&
                             !redirect_any;
    wire prep_head_capture = fq_out0_valid && d0_is_mem && !fq_out0_fault &&
                             !d0_illegal && !young_hazard0 && !redirect_any &&
                             (young_count_q == 0) &&
                             !young_ex0_valid_q && !young_ex1_valid_q &&
                             !prep_matches_head;
    wire lsu_prep_take;
    assign d0_ra = young_long_pending ? young_source_value(r0a_addr, d0_ra_mux,
                         young_valid_q, young_we_flat, young_rd_flat, young_data_flat) : d0_ra_mux;
    assign d0_rb = young_long_pending ? young_source_value(r0b_addr, d0_rb_mux,
                         young_valid_q, young_we_flat, young_rd_flat, young_data_flat) : d0_rb_mux;
    assign d1_ra = young_long_pending ? young_source_value(r1a_addr, d1_ra_mux,
                         young_valid_q, young_we_flat, young_rd_flat, young_data_flat) : d1_ra_mux;
    assign d1_rb = young_long_pending ? young_source_value(r1b_addr, d1_rb_mux,
                         young_valid_q, young_we_flat, young_rd_flat, young_data_flat) : d1_rb_mux;
    wire young_can_issue0 = young_long_pending && fq_out0_valid && d0_is_alu &&
                            young_credit_one && !young_hazard0 &&
                            !commit0_fire && !redirect_any;
    wire young_can_issue1 = young_can_issue0 && young_credit_two && !young_hazard1;

    // On the completion cycle of an older load/MDU, an independent ALU pair,
    // a correctly predicted sequential branch+ALU pair, or the next ordered
    // memory operation can replace the retiring shadows directly. The latter
    // uses a previously prepared packet; address/cacheability decode is kept
    // out of the completion/accept decision. Existing queued/inflight younger
    // work keeps priority.
    wire lsu_wb_valid;
    wire lsu_fault_valid;
    wire mdu_done;
    wire mem_irq_boundary = r0_mem_pending_q && lsu_wb_valid && !lsu_fault_valid &&
                            !r0_trap_q && csr_irq_pending;
    wire young_completion_ready =
        (r0_mem_pending_q && lsu_wb_valid && !lsu_fault_valid) ||
        (mdu_pending_q && mdu_done);
    wire young_completion_mem_ready = (mdu_pending_q && mdu_done) ||
        (r0_mem_pending_q && !r0_mem_we_q && lsu_wb_valid && !lsu_fault_valid);
    wire young_completion_replace = young_long_pending && young_completion_ready &&
        (young_count_q == 0) && !young_ex0_valid_q && !young_ex1_valid_q &&
        fq_out0_valid && (d0_is_alu || d0_branch_alu_pairable ||
                          d0_control_completion_replaceable ||
                          (d0_is_mem && young_completion_mem_ready)) &&
        !young_hazard0 && !redirect_any && !mem_irq_boundary;
    wire prep_issue_allowed = !redirect_any && !young_hazard0 &&
                              !young_queue_hold && !mem_irq_boundary &&
                              (!backend_stall || young_completion_replace);
    wire prep_valid_to_lsu = prep_matches_head && prep_issue_allowed;

    wire [31:0] cw0_data, cw1_data, cw0_bypass_data, cw1_bypass_data;
    wire        cw0_we, cw1_we;
    wire        w0_bypass_we, w1_bypass_we;
    wire [4:0]  cw0_rd, cw1_rd;
    wire [4:0]  rf_w0_bypass_rd = r0_rd_q;
    wire [4:0]  rf_w1_bypass_rd = r1_rd_q;

    regfile_4r2w u_rf (
        .clk(clk), .rst(rst),
        .r0a_addr(r0a_addr), .r0a_data(d0_ra_mux),
        .r0b_addr(r0b_addr), .r0b_data(d0_rb_mux),
        .r1a_addr(r1a_addr), .r1a_data(d1_ra_mux),
        .r1b_addr(r1b_addr), .r1b_data(d1_rb_mux),
        .w0_we(cw0_we), .w0_bypass_we(w0_bypass_we),
        .w0_rd(cw0_rd), .w0_bypass_rd(rf_w0_bypass_rd),
        .w0_data(cw0_data), .w0_bypass_data(cw0_bypass_data),
        .w1_we(cw1_we), .w1_bypass_we(w1_bypass_we),
        .w1_rd(cw1_rd), .w1_bypass_rd(rf_w1_bypass_rd),
        .w1_data(cw1_data), .w1_bypass_data(cw1_bypass_data)
    );

    // ----------------------------------------------------------------
    // Issue / ALU path
    // ----------------------------------------------------------------
    // ⚠️ 坑位：仅发射合法分类会使illegal永远卡队首；所有有效队首
    // 都进入lane0，已有r0_trap_q负责抑制副作用并精确陷入（PR66 R1）。
    wire s0_valid = fq_out0_valid && !young_hazard0 &&
                    (!d0_is_mem || (prep_valid_to_lsu && lsu_prep_take));
    wire s1_valid = DUAL_ISSUE_EN && fq_out1_valid && d1_is_alu &&
                    (!young_long_pending || (young_credit_two && !young_hazard1));
    wire backend_stall_for_alu =
                                 (backend_stall && !young_can_issue0 &&
                                  !young_completion_replace) ||
                                 young_queue_hold;

    wire alu_issue0, alu_issue1;
    wire alu_w0_we;
    wire [4:0]  alu_w0_rd;
    wire alu_w1_we;
    wire [4:0]  alu_w1_rd;
    wire ex0_branch_request, ex0_branch_taken;
    wire [31:0] ex0_branch_pc, ex0_branch_source;

    // issue_arb's legacy s0_is_alu name is a pair-eligibility input here:
    // selected SRAM loads share the one LSU and may admit an independent ALU.
    dual_alu_path #(.BRANCH_PC_RAW(1)) u_alu (
        .clk(clk), .rst(rst),
        .s0_valid(s0_valid), .s0_illegal(1'b0),
        .s0_is_alu(d0_pair_eligible),
        .s0_reg_write(d0_pair_reg_we || d0_load_pairable),
        .s0_rs1(fq_out0_inst[19:15]), .s0_rs2(fq_out0_inst[24:20]),
        .s0_uses_rs1(1'b0), .s0_uses_rs2(1'b0), .s0_rd(d0_pair_rd),
        .s0_pc(fq_out0_pc), .s0_instr(fq_out0_inst), .s0_ra(d0_ra), .s0_rb(d0_rb),
        // s1_valid is prequalified by the exact legal-ALU classifier above,
        // so an accepted lane1 entry cannot be illegal.
        .s1_valid(s1_valid), .s1_illegal(1'b0), .s1_is_alu(d1_is_alu),
        .s1_reg_write(d1_reg_we), .s1_rs1(d1_rs1), .s1_rs2(d1_rs2),
        .s1_uses_rs1(d1_uses_rs1), .s1_uses_rs2(d1_uses_rs2), .s1_rd(d1_rd),
        .s1_pc(fq_out1_pc), .s1_instr(fq_out1_inst), .s1_ra(d1_ra), .s1_rb(d1_rb),
        .backend_stall(backend_stall_for_alu),
        .issue0(alu_issue0), .issue1(alu_issue1), .slot1_stall(slot1_stall),
        .w0_valid(alu_w0_valid), .w0_we(alu_w0_we), .w0_rd(alu_w0_rd),
        .w0_data(alu_w0_data),
        .ex0_branch_request(ex0_branch_request),
        .ex0_branch_taken(ex0_branch_taken),
        .ex0_branch_pc(ex0_branch_pc),
        .ex0_branch_source(ex0_branch_source),
        .w1_valid(alu_w1_valid), .w1_we(alu_w1_we), .w1_rd(alu_w1_rd),
        .w1_data(alu_w1_data)
    );

    assign issue0 = alu_issue0;
    assign issue1 = alu_issue1;

    // ----------------------------------------------------------------
    // D-side LSU (lane0)
    // ----------------------------------------------------------------
    wire        lsu_req_valid, lsu_req_write;
    wire [31:0] lsu_req_addr, lsu_req_wdata;
    wire [3:0]  lsu_req_wstrb;
    wire [31:0] lsu_result;
    wire        lsu_fault_misaligned;
    wire [31:0] lsu_fault_addr;
    wire        lsu_stall;
    wire        mem_fault_ack;

    // An independent younger memory operation may issue on a successful load
    // response edge. The RF bypass data path excludes load response data;
    // downstream ready does not feed the turnover issue decision.
    riscv_lsu #(.WB_ON_RESPONSE(1'b1), .TURNOVER_ON_RESPONSE(1'b1),
                .REGISTER_TURNOVER_REQUEST(1'b0),
                .PREPARED_REQUEST(1'b1), .FAST_ACCEPT(1'b0)) u_lsu (
        .clk_i(clk), .rst_i(rst),
        .valid_i(issue0 && d0_is_mem),
        .opcode_i(fq_out0_inst),
        .pc_i(fq_out0_pc),
        .ra_operand_i(d0_mem_ra),
        .rb_operand_i(d0_mem_rb),
        .hold_i(1'b0),
        .req_valid_o(lsu_req_valid),
        .req_ready_i(d_req_ready),
        .req_addr_o(lsu_req_addr),
        .req_write_o(lsu_req_write),
        .req_wdata_o(lsu_req_wdata),
        .req_wstrb_o(lsu_req_wstrb),
        .rsp_valid_i(d_rsp_valid),
        .rsp_ready_o(d_rsp_ready),
        .rsp_rdata_i(d_rsp_rdata),
        .rsp_error_i(d_rsp_error),
        .fault_valid_o(lsu_fault_valid),
        .fault_ready_i(mem_fault_ack),
        .valid_o(lsu_wb_valid),
        .result_o(lsu_result),
        .fault_o(),
        .fault_pc_o(),
        .fault_rd_o(),
        .fault_misaligned_o(lsu_fault_misaligned),
        .fault_addr_o(lsu_fault_addr),
        .stall_o(lsu_stall),
        .rd_idx_o(),
        .load_not_ready_o(),
        .mem_advanceable_o(),
        // The dual-issue integration supplies a registered request packet;
        // legacy standalone LSU users retain the default unprepared mode.
        .prep_valid_i(prep_valid_to_lsu),
        .prep_pc_i(prep_pc_q),
        .prep_instr_i(prep_instr_q),
        .prep_addr_i(prep_addr_q),
        .prep_rb_i(prep_rb_q),
        .prep_take_o(lsu_prep_take)
    );

    // Prepare either the current head (startup/flush recovery) or the next
    // memory instruction alongside a real slot-0 issue.  The packet is only
    // consumed by the LSU on its actual issue/turnover event; a redirect
    // cancels an unissued packet and no bus side effect occurs at capture.
    always @(posedge clk) begin
        if (rst || redirect_any) begin
            prep_valid_q <= 1'b0;
        end else begin
            if (lsu_prep_take || (prep_valid_q && !prep_matches_head))
                prep_valid_q <= 1'b0;
            if (prep_head_capture || prep_next_capture) begin
                prep_valid_q <= 1'b1;
                if (prep_next_capture) begin
                    prep_pc_q    <= fq_out1_pc;
                    prep_instr_q <= fq_out1_inst;
                    prep_addr_q  <= d1_prep_addr;
                    prep_rb_q    <= d1_rb_mux;
                end else begin
                    prep_pc_q    <= fq_out0_pc;
                    prep_instr_q <= fq_out0_inst;
                    prep_addr_q  <= d0_mem_ra + d0_imm;
                    prep_rb_q    <= d0_mem_rb;
                end
            end
        end
    end

    assign d_req_valid = lsu_req_valid;
    assign d_req_addr  = lsu_req_addr;
    assign d_req_write = lsu_req_write;
    assign d_req_wdata = lsu_req_wdata;
    assign d_req_wstrb = lsu_req_wstrb;

    // Reuse exactly the single-issue rv32im_unit (same bytes as board source
    // 8718956). M instructions issue alone; keep their retirement shadow until
    // done, so younger ALUs cannot overwrite the destination/result metadata.
    wire mdu_ready;
    wire [31:0] mdu_result;
    rv32im_unit #(.DIV_ENABLE(M_MODE == 2)) u_mdu (
        .clk_i(clk), .rst_i(rst || trap_redirect),
        .start_i(issue0 && d0_is_mdu), .funct3_i(fq_out0_inst[14:12]),
        .operand_a_i(d0_ra), .operand_b_i(d0_rb),
        .ready_o(mdu_ready), .done_o(mdu_done), .result_o(mdu_result)
    );
    always @(posedge clk) begin
        if (rst || trap_redirect) mdu_pending_q <= 1'b0;
        else begin
            if (commit0_fire && mdu_pending_q) mdu_pending_q <= 1'b0;
            if (issue0 && d0_is_mdu) mdu_pending_q <= 1'b1;
        end
    end

    // ----------------------------------------------------------------
    // CSR file (reused from Stage1, machine mode only)
    // ----------------------------------------------------------------
    wire [11:0] csr_addr_port;
    wire [31:0] csr_rdata;
    wire        csr_impl, csr_writable;
    wire        csr_chk_impl, csr_chk_writable;
    wire [31:0] csr_mtvec, csr_mepc;
    wire        csr_we_fire;
    wire        mret_commit;

    // Shadow/pipeline state declarations are hoisted before their first use
    // (Icarus elaboration requires declaration-before-use for module ports).
    reg [31:0] s0_cause_final;
    reg [31:0] trap_tval_final;

    csr_file u_csr (
        .clk(clk), .rst(rst_csr),
        .retire_count({1'b0, commit0_fire && !commit_trap_fire} +
                      {1'b0, commit1_fire}),
        .csr_addr(csr_addr_port),
        .csr_rdata(csr_rdata),
        .csr_implemented(csr_impl),
        .csr_writable(csr_writable),
        .csr_chk_addr(d0_csr_addr),
        .csr_chk_implemented(csr_chk_impl),
        .csr_chk_writable(csr_chk_writable),
        .csr_we(csr_we_fire),
        .csr_op(r0_csr_op_q),
        .csr_wdata(r0_csr_wdata_q),
        .trap_enter(commit_trap_fire),
        .trap_pc(commit_trap_pc),
        .trap_cause(commit_trap_cause),
        .trap_tval(trap_tval_final),
        .mret(mret_commit),
        .timer_irq(timer_irq_i),
        .ext_irq(ext_irq_i),
        .mip(), .mie(),
        .irq_pending(csr_irq_pending),
        .irq_cause(csr_irq_cause),
        .mstatus(), .mtvec(csr_mtvec), .mepc(csr_mepc),
        .mcause(), .mtval()
    );

    wire d0_csr_bad = d0_is_csr &&
                      (!csr_chk_impl || (d0_csr_we && !csr_chk_writable));
    wire d0_decode_trap = fq_out0_fault || d0_illegal || d0_csr_bad ||
                          d0_ecall || d0_ebreak;

    // ----------------------------------------------------------------
    // Retirement payload shadows
    // ----------------------------------------------------------------
    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            r0_pc_q <= 32'h0; r0_pc_plus4_q <= 32'h4; r0_instr_q <= 32'h0;
            r0_pred_valid_q <= 1'b0; r0_pred_taken_q <= 1'b0;
            r0_pred_target_q <= 32'h0; r0_pred_pending_q <= 1'b0;
            r0_csr_wdata_q <= 32'h0; r0_csr_rdata_q <= 32'h0;
            r0_cause_q <= 32'h0; r0_tval_q <= 32'h0;
            r0_rd_q <= 5'h0; r0_csr_addr_q <= 12'h0; r0_csr_op_q <= 2'b0;
            r0_writes_rd_q <= 1'b0; r0_is_alu_q <= 1'b0;
            r0_mem_we_q <= 1'b0; r0_is_csr_q <= 1'b0;
            r0_csr_we_q <= 1'b0; r0_mret_q <= 1'b0; r0_trap_q <= 1'b0;
            r1_pc_q <= 32'h0; r1_instr_q <= 32'h0;
            r1_rd_q <= 5'h0; r1_writes_rd_q <= 1'b0;
        end else begin
            if (issue0 && (!young_long_pending || young_completion_replace)) begin
                r0_pc_q        <= fq_out0_pc;
                // Precompute the fall-through PC alongside the shadow so the
                // redirect comparator never sits behind a 32-bit incrementer.
                // r0_pc_plus4_q always equals (r0_pc_q + 4) exactly when the
                // shadow pair is coherent, because both capture the same edge.
                r0_pc_plus4_q  <= fq_out0_pc + 32'd4;
                r0_instr_q     <= fq_out0_inst;
                r0_pred_valid_q <= fq_out0_pred_valid;
                r0_pred_taken_q <= fq_out0_pred_taken;
                r0_pred_target_q <= fq_out0_pred_target;
                r0_rd_q        <= d0_rd;
                r0_writes_rd_q <= d0_reg_we;
                r0_is_alu_q    <= d0_is_alu;
                r0_mem_we_q    <= d0_mem_we;
                r0_is_csr_q    <= d0_is_csr;
                r0_csr_addr_q  <= d0_csr_addr;
                r0_csr_op_q    <= d0_csr_op;
                r0_csr_we_q    <= d0_csr_we;
                r0_csr_wdata_q <= d0_csr_imm ? d0_csr_uimm : d0_ra;
                r0_csr_rdata_q <= csr_rdata;
                r0_mret_q      <= d0_mret;
                r0_trap_q      <= d0_decode_trap;
                r0_cause_q     <= fq_out0_fault  ? 32'd1  :
                                  d0_illegal      ? 32'd2  :
                                  d0_csr_bad      ? 32'd2  :
                                  d0_ecall        ? 32'd11 :
                                  d0_ebreak       ? 32'd3  : 32'd0;
                r0_tval_q      <= fq_out0_fault  ? fq_out0_pc :
                                  (d0_illegal || d0_csr_bad) ? fq_out0_inst : 32'd0;
            end else begin
                if (commit0_fire) begin
                    r0_mret_q <= 1'b0;
                    r0_trap_q <= 1'b0;
                    r0_is_alu_q <= 1'b0;
                    r0_is_csr_q <= 1'b0;
                    r0_csr_we_q <= 1'b0;
                end
            end

            if (issue1 && (!young_long_pending || young_completion_replace)) begin
                r1_pc_q        <= fq_out1_pc;
                r1_instr_q     <= fq_out1_inst;
                r1_rd_q        <= d1_rd;
                r1_writes_rd_q <= d1_reg_we;
            end
            // The execution result and this shadow correspond to the entry
            // accepted in the previous cycle. Back-to-back issue keeps the
            // valid bit set while replacing the shadow at the same edge.
            if (young_completion_replace && issue0)
                r0_pred_pending_q <= issue0;
            else if (young_long_pending && commit0_fire)
                r0_pred_pending_q <= 1'b0;
            else if (!young_long_pending)
                r0_pred_pending_q <= issue0;
        end
    end

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            r0_mem_pending_q <= 1'b0;
            r0_csr_pending_q <= 1'b0;
            r1_mem_pair_pending_q <= 1'b0;
            r1_mem_pair_result_valid_q <= 1'b0;
            r1_mem_pair_result_q <= 32'h0;
        end else begin
            if (trap_redirect) begin
                r0_mem_pending_q <= 1'b0;
                r0_csr_pending_q <= 1'b0;
                r1_mem_pair_pending_q <= 1'b0;
                r1_mem_pair_result_valid_q <= 1'b0;
            end else begin
                if (commit0_fire && r0_mem_pending_q)
                    r0_mem_pending_q <= 1'b0;
                if (commit0_fire && r0_csr_pending_q)
                    r0_csr_pending_q <= 1'b0;
                if (commit1_fire && r1_mem_pair_pending_q) begin
                    r1_mem_pair_pending_q <= 1'b0;
                    r1_mem_pair_result_valid_q <= 1'b0;
                end
            end
            if (issue0 && d0_is_mem)
                r0_mem_pending_q <= 1'b1;
            if (issue0 && d0_is_csr)
                r0_csr_pending_q <= 1'b1;
            if (issue1 && d0_mem_alu_pairable) begin
                r1_mem_pair_pending_q <= 1'b1;
                r1_mem_pair_result_valid_q <= 1'b0;
            end
            if (r1_mem_pair_pending_q && !commit1_fire &&
                alu_w1_valid && !young_ex1_valid_q) begin
                r1_mem_pair_result_q <= alu_w1_data;
                r1_mem_pair_result_valid_q <= 1'b1;
            end
        end
    end

    wire [1:0] young_push_count = {1'b0, young_ex0_valid_q} +
                                  {1'b0, young_ex1_valid_q};
    wire [1:0] young_pop_count = young_queue_drain
        ? ({1'b0, commit0_fire} + {1'b0, commit1_fire}) : 2'd0;
    wire [2:0] young_push1_index = young_tail_q + {2'b0, young_ex0_valid_q};
    wire [2:0] young_head1_index = young_head_q + 3'd1;

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            young_head_q <= 3'd0;
            young_tail_q <= 3'd0;
            young_count_q <= 4'd0;
            young_valid_q <= {YOUNG_DEPTH{1'b0}};
            young_ex0_valid_q <= 1'b0;
            young_ex1_valid_q <= 1'b0;
            young_ex0_pc_q <= 32'd0;
            young_ex0_instr_q <= 32'd0;
            young_ex0_rd_q <= 5'd0;
            young_ex0_we_q <= 1'b0;
            young_ex1_pc_q <= 32'd0;
            young_ex1_instr_q <= 32'd0;
            young_ex1_rd_q <= 5'd0;
            young_ex1_we_q <= 1'b0;
        end else if (trap_redirect) begin
            young_head_q <= 3'd0;
            young_tail_q <= 3'd0;
            young_count_q <= 4'd0;
            young_valid_q <= {YOUNG_DEPTH{1'b0}};
            young_ex0_valid_q <= 1'b0;
            young_ex1_valid_q <= 1'b0;
        end else begin
            young_ex0_valid_q <= young_long_pending && issue0 &&
                                 !young_completion_replace;
            young_ex1_valid_q <= young_long_pending && issue1 &&
                                 !young_completion_replace;
            if (young_long_pending && issue0 && !young_completion_replace) begin
                young_ex0_pc_q <= fq_out0_pc;
                young_ex0_instr_q <= fq_out0_inst;
                young_ex0_rd_q <= d0_pair_rd;
                young_ex0_we_q <= d0_pair_reg_we;
            end
            if (young_long_pending && issue1 && !young_completion_replace) begin
                young_ex1_pc_q <= fq_out1_pc;
                young_ex1_instr_q <= fq_out1_inst;
                young_ex1_rd_q <= d1_rd;
                young_ex1_we_q <= d1_reg_we;
            end

            if (young_ex0_valid_q) begin
                young_valid_q[young_tail_q] <= 1'b1;
            end
            if (young_ex1_valid_q) begin
                young_valid_q[young_push1_index] <= 1'b1;
            end

            if (young_queue_drain && commit0_fire)
                young_valid_q[young_head_q] <= 1'b0;
            if (young_queue_drain && commit1_fire)
                young_valid_q[young_head1_index] <= 1'b0;
            if (young_push_count != 0)
                young_tail_q <= young_tail_q + young_push_count;
            if (young_pop_count != 0)
                young_head_q <= young_head_q + young_pop_count;
            if (young_push_count != 0 || young_pop_count != 0)
                young_count_q <= young_count_q + {2'b0, young_push_count} -
                                 {2'b0, young_pop_count};
        end
    end

    // ----------------------------------------------------------------
    // Lane0 final writeback / trap muxes
    // ----------------------------------------------------------------
    wire young_even_lane0 = young_ex0_valid_q && !young_tail_q[0];
    wire young_even_lane1 = young_ex1_valid_q && !young_push1_index[0];
    wire young_odd_lane0  = young_ex0_valid_q &&  young_tail_q[0];
    wire young_odd_lane1  = young_ex1_valid_q &&  young_push1_index[0];
    wire young_even_write = young_even_lane0 || young_even_lane1;
    wire young_odd_write  = young_odd_lane0 || young_odd_lane1;
    wire [1:0] young_even_index = young_even_lane0 ? young_tail_q[2:1] : young_push1_index[2:1];
    wire [1:0] young_odd_index  = young_odd_lane0  ? young_tail_q[2:1] : young_push1_index[2:1];
    wire [31:0] young_even_pc_data = young_even_lane0 ? young_ex0_pc_q : young_ex1_pc_q;
    wire [31:0] young_odd_pc_data  = young_odd_lane0  ? young_ex0_pc_q : young_ex1_pc_q;
    wire [31:0] young_even_instr_data = young_even_lane0 ? young_ex0_instr_q : young_ex1_instr_q;
    wire [31:0] young_odd_instr_data  = young_odd_lane0  ? young_ex0_instr_q : young_ex1_instr_q;
    wire [4:0] young_even_rd_data = young_even_lane0 ? young_ex0_rd_q : young_ex1_rd_q;
    wire [4:0] young_odd_rd_data  = young_odd_lane0  ? young_ex0_rd_q : young_ex1_rd_q;
    wire [0:0] young_even_we_data = young_even_lane0 ? young_ex0_we_q : young_ex1_we_q;
    wire [0:0] young_odd_we_data  = young_odd_lane0  ? young_ex0_we_q : young_ex1_we_q;
    wire [31:0] young_even_data_data = young_even_lane0 ? alu_w0_data : alu_w1_data;
    wire [31:0] young_odd_data_data  = young_odd_lane0  ? alu_w0_data : alu_w1_data;

    // Two adjacent enqueue slots always split across parity banks. Each bank
    // therefore has at most one dynamic write per cycle, matching the target RAM port limit.
    always @(posedge clk) begin
        if (rst != `RstEnable && !trap_redirect) begin
            if (young_even_write) begin
                young_pc_even_q[young_even_index] <= young_even_pc_data;
                young_instr_even_q[young_even_index] <= young_even_instr_data;
                young_rd_even_q[young_even_index] <= young_even_rd_data;
                young_we_even_q[young_even_index] <= young_even_we_data;
                young_data_even_q[young_even_index] <= young_even_data_data;
            end
            if (young_odd_write) begin
                young_pc_odd_q[young_odd_index] <= young_odd_pc_data;
                young_instr_odd_q[young_odd_index] <= young_odd_instr_data;
                young_rd_odd_q[young_odd_index] <= young_odd_rd_data;
                young_we_odd_q[young_odd_index] <= young_odd_we_data;
                young_data_odd_q[young_odd_index] <= young_odd_data_data;
            end
        end
    end
    wire        w0_valid_final;
    wire [4:0]  w0_rd_final;
    wire [31:0] w0_data_final;
    wire        w0_writes_rd_final = !irq_after_mem_q &&
        (young_queue_drain ? young_we_at(young_head_q, young_we_flat) : r0_writes_rd_q);
    wire [31:0] w0_pc_final = irq_after_mem_q ? irq_after_mem_pc_q :
                              (young_queue_drain ? young_pc_at(young_head_q, young_pc_flat) : r0_pc_q);
    wire [31:0] w0_instr_final = irq_after_mem_q ? 32'd0 :
                                 (young_queue_drain ? young_instr_at(young_head_q, young_instr_flat) : r0_instr_q);
    wire        mem_wb_valid = r0_mem_pending_q && (lsu_wb_valid || lsu_fault_valid);
    wire branch_misaligned = !young_long_pending && !young_queue_drain &&
                             alu_w0_valid && ex0_branch_request &&
                             ex0_branch_taken && !r0_trap_q &&
                             (|ex0_branch_pc[1:0]);
    wire        irq_take = w0_valid_final && !irq_after_mem_q && !young_queue_drain &&
                           !r0_trap_q && !branch_misaligned &&
                           !r0_mem_pending_q && csr_irq_pending;

    assign w0_valid_final = irq_after_mem_q ? 1'b1 :
                            young_queue_drain ? young_valid_q[young_head_q] :
                            (r0_mem_pending_q ? mem_wb_valid :
                             (mdu_pending_q ? mdu_done :
                              (!young_queue_hold && alu_w0_valid)));
    assign w0_rd_final    = irq_after_mem_q ? 5'd0 :
                            (young_queue_drain ? young_rd_at(young_head_q, young_rd_flat) : r0_rd_q);
    assign w0_data_final  = young_queue_drain ? young_data_at(young_head_q, young_data_flat) :
                            (r0_mem_pending_q ? lsu_result :
                             mdu_pending_q ? mdu_result :
                             (r0_is_csr_q ? r0_csr_rdata_q : alu_w0_data));
    // The load response is written into the array but is never a combinational
    // bypass source: load RAW hazards prevent its consumers issuing this cycle.
    // Register-file read bypasses must not reuse the architectural writeback
    // muxes: those select young_head_q during queue drain and created a long
    // queue-pointer -> operand -> LSU ready feedback path. The queue drain
    // cycle has no issue, so its data never needs to appear on these ports.
    assign cw0_bypass_data = mdu_pending_q ? mdu_result :
                             (r0_is_csr_q ? r0_csr_rdata_q : alu_w0_data);
    assign cw1_bypass_data = r1_mem_pair_pending_q
        ? ((alu_w1_valid && !young_ex1_valid_q) ? alu_w1_data : r1_mem_pair_result_q)
        : alu_w1_data;

    wire s0_trap_final = irq_after_mem_q ? 1'b1 : young_queue_drain ? 1'b0 :
                         (r0_mem_pending_q ? lsu_fault_valid
                                           : (r0_trap_q || branch_misaligned || irq_take));

    // A trap suppresses the architectural array write, but it must not put the
    // same trap decision back on the timer_irq -> operand -> queue-control
    // combinational path. This bypass is read-only; redirect/stall blocks all
    // issue and architectural side effects during the trap cycle.
    // A load response is also held at the retirement head for this cycle. Its
    // RAW dependents are blocked by young_hazard0/1 and can read the value from
    // the register array after the edge, so do not send the D-cache data back
    // through the combinational read bypass into a new LSU address/cache decode.
    wire load_response_bypass_block = r0_mem_pending_q && lsu_wb_valid &&
                                     !r0_mem_we_q && !lsu_fault_valid;
    // Keep the trap/drain decisions off this read-only bypass select: the mux
    // select feeds every operand port, so qualifying it with irq_after_mem_q /
    // young_queue_drain puts timer_irq and trap control on the operand-to-LSU
    // path. Both cycles have no issue (trap_redirect / young_queue_hold) and
    // the architectural array write stays gated by w0_we, so the speculative
    // value is never consumed.
    // S4: `young_queue_hold` itself embeds young_queue_drain (irq_after_mem_q /
    // r0_csr_pending_q), so it must not qualify this select either — the hold
    // cycle has no issue (backend_stall_for_alu includes young_queue_hold).
    wire rf_w0_bypass_source_valid =
        (r0_mem_pending_q ? mem_wb_valid :
         mdu_pending_q ? mdu_done : alu_w0_valid);
    assign w0_bypass_we = rf_w0_bypass_source_valid && r0_writes_rd_q &&
                          (r0_rd_q != 5'd0) && !load_response_bypass_block;

    always @* begin
        if (irq_after_mem_q) begin
            s0_cause_final = irq_after_mem_cause_q;
            trap_tval_final = 32'd0;
        end else if (young_queue_drain) begin
            s0_cause_final = 32'd0;
            trap_tval_final = 32'd0;
        end else if (r0_mem_pending_q && lsu_fault_valid) begin
            if (lsu_fault_misaligned)
                s0_cause_final = r0_mem_we_q ? 32'd6 : 32'd4;
            else
                s0_cause_final = r0_mem_we_q ? 32'd7 : 32'd5;
            trap_tval_final = lsu_fault_addr;
        end else if (branch_misaligned) begin
            s0_cause_final = 32'd0;
            trap_tval_final = ex0_branch_pc;
        end else if (irq_take) begin
            s0_cause_final = csr_irq_cause;
            trap_tval_final = 32'd0;
        end else begin
            s0_cause_final = r0_cause_q;
            trap_tval_final = r0_tval_q;
        end
    end

    assign csr_addr_port = r0_csr_pending_q ? r0_csr_addr_q : d0_csr_addr;
    assign mem_fault_ack = commit_trap_fire && r0_mem_pending_q;

    // Preserve the just-completed load/store and an older paired lane1 ALU.
    // Any younger speculative work is flushed by the synthetic IRQ trap in
    // the following cycle and will be refetched from the saved next PC.
    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            irq_after_mem_q <= 1'b0;
            irq_after_mem_pc_q <= 32'd0;
            irq_after_mem_cause_q <= 32'd0;
        end else if (trap_redirect) begin
            irq_after_mem_q <= 1'b0;
        end else if (mem_irq_boundary && commit0_fire) begin
            irq_after_mem_q <= 1'b1;
            irq_after_mem_pc_q <= commit1_fire ? (r1_pc_q + 32'd4) : (r0_pc_q + 32'd4);
            irq_after_mem_cause_q <= csr_irq_cause;
        end
    end

    // ----------------------------------------------------------------
    // Dual commit
    // ----------------------------------------------------------------
    // A resolved branch redirect invalidates the sequential-path lane1 result
    // produced alongside that branch. Gate the retirement shadow itself so
    // commit, register bypass/write, counters, and trace all agree.
    wire s1_retire_valid = young_queue_drain
        ? ((young_count_q >= 4'd2) && young_valid_q[young_head1_index])
        : ((r1_mem_pair_pending_q ||
            (alu_w1_valid && !young_long_pending && !young_queue_hold &&
             !young_ex1_valid_q)) && !branch_redirect);
    // On an edge where the paired ALU and older load complete together, the
    // registered result shadow still has its previous value until NBA updates.
    // Forward the matching EX result on that edge; use the held value after it
    // has been captured.
    wire r1_mem_pair_result_forward = r1_mem_pair_pending_q && alu_w1_valid &&
                                      !young_ex1_valid_q;
    wire [31:0] s1_retire_data = young_queue_drain
        ? young_data_at(young_head1_index, young_data_flat)
        : (r1_mem_pair_pending_q
            ? (r1_mem_pair_result_forward ? alu_w1_data : r1_mem_pair_result_q)
            : alu_w1_data);
    wire [4:0] s1_rd_final = young_queue_drain ? young_rd_at(young_head1_index, young_rd_flat) : r1_rd_q;
    wire s1_writes_rd_final = young_queue_drain ? young_we_at(young_head1_index, young_we_flat)
                                                 : r1_writes_rd_q;
    wire [31:0] s1_pc_final = young_queue_drain ? young_pc_at(young_head1_index, young_pc_flat) : r1_pc_q;

    // As with slot0, a trap in the older slot cancels slot1's architectural
    // write but must not feed that trap decision back through the read mux.
    // redirect/stall prevents the speculative younger value from issuing.
    wire rf_w1_bypass_source_valid = !young_queue_drain && !branch_redirect &&
        ((r1_mem_pair_pending_q &&
          (r1_mem_pair_result_valid_q || (alu_w1_valid && !young_ex1_valid_q))) ||
         (alu_w1_valid && !young_long_pending && !young_queue_hold &&
          !young_ex1_valid_q));
    assign w1_bypass_we = rf_w1_bypass_source_valid && r1_writes_rd_q &&
                          (r1_rd_q != 5'd0);

    dual_commit u_commit (
        .s0_valid(w0_valid_final), .s0_trap(s0_trap_final),
        .s0_writes_rd(w0_writes_rd_final), .s0_rd(w0_rd_final),
        .s0_data(w0_data_final), .s0_cause(s0_cause_final), .s0_pc(w0_pc_final),
        .s1_valid(s1_retire_valid), .s1_trap(1'b0),
        .s1_writes_rd(s1_writes_rd_final), .s1_rd(s1_rd_final),
        .s1_data(s1_retire_data), .s1_cause(32'h0), .s1_pc(s1_pc_final),
        .commit0_fire(commit0_fire), .commit1_fire(commit1_fire),
        .trap_fire(commit_trap_fire), .trap_cause(commit_trap_cause),
        .trap_pc(commit_trap_pc), .flush_young(commit_flush_young),
        .hold_s1(commit_hold_s1),
        .w0_we(cw0_we), .w0_rd(cw0_rd), .w0_data(cw0_data),
        .w1_we(cw1_we), .w1_rd(cw1_rd), .w1_data(cw1_data)
    );

    assign retire0_valid = commit0_fire;
    assign retire1_valid = commit1_fire;

    // ----------------------------------------------------------------
    // Redirect / stall / commit pulses
    // ----------------------------------------------------------------
    // Compare each resolved instruction's actual next PC with the prediction
    // captured at fetch. This also catches a stale BTB hit on a non-control
    // instruction, which would otherwise leave fetch on the wrong path.
    // Timing: the shadow pair's branch resolution (branch_req/taken/pc/source)
    // is already registered by riscv_exec, and branch_source_q is the same
    // fq_out0_pc capture that produced r0_pc_q. Use the precomputed
    // r0_pc_plus4_q for every fall-through term so this comparator never
    // waits on a 32-bit incrementer driven by the high-fanout r0_pc_q net.
    wire [31:0] resolved_next_pc = (ex0_branch_request && ex0_branch_taken) ?
                                   ex0_branch_pc : r0_pc_plus4_q;
    wire [31:0] predicted_next_pc = (r0_pred_valid_q && r0_pred_taken_q) ?
                                    r0_pred_target_q : r0_pc_plus4_q;
    wire prediction_mismatch = !young_long_pending && !young_queue_drain &&
                               !young_queue_hold &&
                               r0_pred_pending_q && alu_w0_valid &&
                               !r0_trap_q && !s0_trap_final &&
                               (resolved_next_pc != predicted_next_pc);

    wire r0_is_jal = (r0_instr_q[6:0] == 7'h6f);
    wire r0_is_jalr = ((r0_instr_q & 32'h0000_707f) == 32'h0000_0067);
    wire r0_rd_link = (r0_instr_q[11:7] == 5'd1) || (r0_instr_q[11:7] == 5'd5);
    wire r0_rs1_link = (r0_instr_q[19:15] == 5'd1) || (r0_instr_q[19:15] == 5'd5);
    assign bp_update_valid = PREDICT_ENABLE && !young_long_pending &&
                             !young_queue_drain && commit0_fire && ex0_branch_request &&
                             !s0_trap_final;
    assign bp_update_pc = r0_pc_q;
    assign bp_update_taken = ex0_branch_taken;
    assign bp_update_target = ex0_branch_pc;
    assign bp_update_pred_taken = r0_pred_valid_q && r0_pred_taken_q;
    assign bp_update_pred_target = r0_pred_target_q;
    assign bp_update_exception = s0_trap_final;
    assign bp_update_is_call = (r0_is_jal || r0_is_jalr) && r0_rd_link;
    assign bp_update_is_ret = r0_is_jalr && r0_rs1_link && !r0_rd_link;

    assign branch_redirect = prediction_mismatch;
    assign trap_redirect   = commit_trap_fire;
    assign mret_redirect   = !young_queue_drain && commit0_fire && r0_mret_q && !s0_trap_final;
    assign redirect_any    = branch_redirect | trap_redirect | mret_redirect;
    assign redirect_target = trap_redirect ? csr_mtvec :
                             mret_redirect ? csr_mepc : resolved_next_pc;

    assign backend_stall = redirect_any | r0_mem_pending_q | r0_csr_pending_q |
                           mdu_pending_q;

    assign csr_we_fire = !young_queue_drain && commit0_fire && r0_is_csr_q && r0_csr_we_q &&
                         !s0_trap_final;
    assign mret_commit = !young_queue_drain && commit0_fire && r0_mret_q && !s0_trap_final;

    // ----------------------------------------------------------------
    // Retirement trace
    // ----------------------------------------------------------------
    dual_retire_trace u_trace (
        .clk(clk), .rst(rst),
        .commit0_valid(commit0_fire), .commit0_pc(w0_pc_final),
        .commit0_instr(w0_instr_final), .commit0_rd(cw0_rd),
        .commit0_rd_data(cw0_data), .commit0_rd_we(cw0_we),
        .commit0_trap(commit_trap_fire), .commit0_cause(commit_trap_cause),
        .commit1_valid(commit1_fire), .commit1_pc(s1_pc_final),
        .commit1_instr(young_queue_drain ? young_instr_at(young_head1_index, young_instr_flat) : r1_instr_q),
        .commit1_rd(cw1_rd),
        .commit1_rd_data(cw1_data), .commit1_rd_we(cw1_we),
        .commit1_trap(1'b0), .commit1_cause(32'h0),
        .trace0_valid(trace0_valid), .trace0_order(trace0_order),
        .trace0_pc(trace0_pc), .trace0_instr(trace0_instr),
        .trace0_rd(trace0_rd), .trace0_rd_data(trace0_rd_data),
        .trace0_rd_we(trace0_rd_we), .trace0_trap(trace0_trap),
        .trace0_cause(trace0_cause),
        .trace1_valid(trace1_valid), .trace1_order(trace1_order),
        .trace1_pc(trace1_pc), .trace1_instr(trace1_instr),
        .trace1_rd(trace1_rd), .trace1_rd_data(trace1_rd_data),
        .trace1_rd_we(trace1_rd_we), .trace1_trap(trace1_trap),
        .trace1_cause(trace1_cause)
    );

endmodule
