// Experimental five-stage, in-order dual-issue core.
// IF: fetch/FQ; ID: full decode, RF read and producer-tag allocation;
// EX: ID/EX packet and decoded functional units; MEM: registered completion
// slots plus one ordered memory transaction; WB: explicit MEM/WB packets.
// Completed ALUs may wait behind a load without changing architectural state.
// Producer tags, rather than retirement age, select forwarded operands.
module dual_issue_5stage_core #(
    parameter bit DUAL_ISSUE_EN = 1'b1,
    parameter integer M_MODE = 2,
    parameter [31:0] CACHEABLE_BASE = 32'h8000_0000,
    parameter [31:0] CACHEABLE_SIZE = 32'h0001_0000,
    parameter integer FETCH_QUEUE_DEPTH = 8,
    parameter bit PREDICT_ENABLE = 1'b1,
    parameter integer PRED_MODE = 0,
    parameter integer BTB_ENTRIES = 64
)(
    input wire clk, rst,
    output wire i_req_valid, input wire i_req_ready,
    output wire [31:0] i_req_addr, input wire i_rsp_valid,
    output wire i_rsp_ready, input wire [63:0] i_rsp_data,
    input wire [1:0] i_rsp_error,
    output wire d_req_valid, input wire d_req_ready,
    output wire [31:0] d_req_addr, output wire d_req_write,
    output wire [31:0] d_req_wdata, output wire [3:0] d_req_wstrb,
    input wire d_rsp_valid, output wire d_rsp_ready,
    input wire [31:0] d_rsp_rdata, input wire d_rsp_error,
    input wire timer_irq_i, ext_irq_i,
    output wire issue0, issue1, retire0_valid, retire1_valid,
    output wire trace0_valid, output wire [63:0] trace0_order,
    output wire [31:0] trace0_pc, trace0_instr,
    output wire [4:0] trace0_rd, output wire [31:0] trace0_rd_data,
    output wire trace0_rd_we, trace0_trap, output wire [31:0] trace0_cause,
    output wire trace1_valid, output wire [63:0] trace1_order,
    output wire [31:0] trace1_pc, trace1_instr,
    output wire [4:0] trace1_rd, output wire [31:0] trace1_rd_data,
    output wire trace1_rd_we, trace1_trap, output wire [31:0] trace1_cause,
    output wire [31:0] pc_debug
);
    localparam integer N = 8;
    typedef struct packed {
        logic valid;
        logic [31:0] pc, instr;
        logic fault, pred_valid, pred_taken;
        logic [31:0] pred_target;
        logic [4:0] rs1, rs2, rd;
        logic use_rs1, use_rs2, reg_we;
        logic [31:0] imm, ra, rb;
        logic src1_pending, src2_pending;
        logic [2:0] src1_tag, src2_tag, tag;
        logic [3:0] alu_func;
        logic src_a_pc, src_a_zero, src_b_imm;
        logic branch, jal, jalr, mem, store, mdu;
        logic [2:0] funct3;
        logic csr;
        logic [11:0] csr_addr;
        logic csr_we;
        logic [1:0] csr_op;
        logic csr_imm;
        logic [31:0] csr_uimm;
        logic ecall, ebreak, mret, fence, illegal;
    } id_packet_t;
    typedef struct packed {
        logic valid;
        logic [2:0] tag;
        logic [31:0] pc, instr, result, next_pc;
        logic [4:0] rd;
        logic reg_we, trap;
        logic [31:0] cause, tval;
        logic mem, store;
        logic [2:0] funct3;
        logic [31:0] addr, store_data;
        logic csr;
        logic [11:0] csr_addr;
        logic csr_we;
        logic [1:0] csr_op;
        logic [31:0] csr_wdata;
        logic mret, serial;
    } result_packet_t;
    typedef struct packed {
        logic [2:0] tag;
        logic [31:0] addr, store_data;
        logic [2:0] funct3;
        logic store;
    } mem_request_t;
    // Sum the packed fields above explicitly: the Yosys SystemVerilog
    // frontend used by the PDS flow does not accept $bits(a typedef name).
    localparam integer RESULT_W = 1+3+128+5+2+64+2+3+64+1+12+1+2+32+2;

    wire redirect_any, wb_flush, irq_boundary, ex_redirect, pipeline_clear;
    wire [31:0] redirect_target, ex_redirect_target;
    wire [1:0] fq_credit, fq_raw_credit;
    wire [1:0] wf_valid, wf_fault, wf_pv, wf_pt;
    wire [31:0] wf_pc[0:1], wf_inst[0:1], wf_target[0:1];
    wire bp_update_valid, bp_update_taken;
    wire [31:0] bp_update_pc, bp_update_target, bp_pred_target;
    wire bp_pred_taken, bp_is_call, bp_is_ret;
    wide_fetch #(.PREDICT_ENABLE(PREDICT_ENABLE), .PRED_MODE(PRED_MODE),
                 .BTB_ENTRIES(BTB_ENTRIES)) u_fetch (
        .clk(clk), .rst(rst), .i_req_valid(i_req_valid), .i_req_ready(i_req_ready),
        .i_req_addr(i_req_addr), .i_rsp_valid(i_rsp_valid), .i_rsp_ready(i_rsp_ready),
        .i_rsp_data(i_rsp_data), .i_rsp_error(i_rsp_error),
        .redirect_valid(redirect_any), .redirect_target(redirect_target), .push_ready(fq_raw_credit),
        .q0_valid(wf_valid[0]), .q0_pc(wf_pc[0]), .q0_inst(wf_inst[0]), .q0_fault(wf_fault[0]),
        .q0_pred_valid(wf_pv[0]), .q0_pred_taken(wf_pt[0]), .q0_pred_target(wf_target[0]),
        .q1_valid(wf_valid[1]), .q1_pc(wf_pc[1]), .q1_inst(wf_inst[1]), .q1_fault(wf_fault[1]),
        .q1_pred_valid(wf_pv[1]), .q1_pred_taken(wf_pt[1]), .q1_pred_target(wf_target[1]),
        .update_valid(bp_update_valid), .update_pc(bp_update_pc), .update_taken(bp_update_taken),
        .update_target(bp_update_target), .update_pred_taken(bp_pred_taken),
        .update_pred_target(bp_pred_target), .update_exception(1'b0),
        .update_is_call(bp_is_call), .update_is_ret(bp_is_ret), .pc_debug(pc_debug)
    );

    wire [1:0] fq_valid, fq_present, fq_fault, fq_pv, fq_pt;
    wire [31:0] fq_pc[0:1], fq_inst[0:1], fq_target[0:1];
    wire [4:0] fq_rs1[0:1], fq_rs2[0:1], fq_rd[0:1];
    wire [1:0] fq_regwe, fq_mem;
    wire [10:0] fq_sidecar[0:1];
    wire fq_consume0, fq_consume1, fq_pop_intent0, fq_pop_intent1;
    fetch_queue #(.DEPTH(FETCH_QUEUE_DEPTH), .M_MODE(M_MODE), .SIDECAR_ENABLE(1)) u_fq (
        .clk(clk), .rst(rst),
        .in0_valid(wf_valid[0]), .in0_pc(wf_pc[0]), .in0_inst(wf_inst[0]),
        .in0_fault(wf_fault[0]), .in0_pred_valid(wf_pv[0]), .in0_pred_taken(wf_pt[0]),
        .in0_pred_target(wf_target[0]),
        .in1_valid(wf_valid[1]), .in1_pc(wf_pc[1]), .in1_inst(wf_inst[1]),
        .in1_fault(wf_fault[1]), .in1_pred_valid(wf_pv[1]), .in1_pred_taken(wf_pt[1]),
        .in1_pred_target(wf_target[1]), .in_ready(fq_credit), .raw_credit(fq_raw_credit),
        .decode0_valid(fq_present[0]), .decode1_valid(fq_present[1]),
        .out0_valid(fq_valid[0]), .out0_pc(fq_pc[0]), .out0_inst(fq_inst[0]),
        .out0_fault(fq_fault[0]), .out0_pred_valid(fq_pv[0]), .out0_pred_taken(fq_pt[0]),
        .out0_pred_target(fq_target[0]), .out0_sidecar(fq_sidecar[0]),
        .out0_rs1(fq_rs1[0]), .out0_rs2(fq_rs2[0]), .out0_rd(fq_rd[0]),
        .out0_reg_write(fq_regwe[0]), .out0_is_mem(fq_mem[0]),
        .out1_valid(fq_valid[1]), .out1_pc(fq_pc[1]), .out1_inst(fq_inst[1]),
        .out1_fault(fq_fault[1]), .out1_pred_valid(fq_pv[1]), .out1_pred_taken(fq_pt[1]),
        .out1_pred_target(fq_target[1]), .out1_sidecar(fq_sidecar[1]),
        .out1_rs1(fq_rs1[1]), .out1_rs2(fq_rs2[1]), .out1_rd(fq_rd[1]),
        .out1_reg_write(fq_regwe[1]), .out1_is_mem(fq_mem[1]),
        .out0_consume(fq_pop_intent0), .out1_consume(fq_pop_intent1), .flush(redirect_any)
    );

    wire id_packet_t dec0, dec1;
    id_packet_t id_ex0_q, id_ex1_q, intake0, intake1;
    result_packet_t ex_result0, ex_result1, mem_wb0_q, mem_wb1_q;
    wire [31:0] rf0a, rf0b, rf1a, rf1b;
    reg branch_pair_prev_valid_q;
    reg [2:0] branch_pair_prev_tag_q;
    wire cw0_we, cw1_we;
    wire [4:0] cw0_rd, cw1_rd;
    wire [31:0] cw0_data, cw1_data;
    wire commit0, commit1, wb_trap, wb_hold1;
    wire [31:0] trap_pc, trap_cause;
    reg serial_busy_q;

    reg [N-1:0] q_valid, q_ready, q_executed;
    reg [RESULT_W-1:0] q_payload[0:N-1];
    reg [2:0] head_q, tail_q;
    reg [3:0] count_q;
    reg [31:0] rename_valid_q;
    // Four reads and two writes require FFs, not a multi-ported block RAM.
    reg [95:0] rename_tags_q;
    function automatic [2:0] rename_tag(input [4:0] index, input [95:0] tags);
        rename_tag = tags[index*3 +: 3];
    endfunction

    regfile_4r2w u_rf (
        .clk(clk), .rst(rst),
        .r0a_addr(dec0.rs1), .r0a_data(rf0a), .r0b_addr(dec0.rs2), .r0b_data(rf0b),
        .r1a_addr(dec1.rs1), .r1a_data(rf1a), .r1b_addr(dec1.rs2), .r1b_data(rf1b),
        .w0_we(cw0_we), .w0_rd(cw0_rd), .w0_data(cw0_data),
        .w0_bypass_we(cw0_we), .w0_bypass_rd(cw0_rd), .w0_bypass_data(cw0_data),
        .w1_we(cw1_we), .w1_rd(cw1_rd), .w1_data(cw1_data),
        .w1_bypass_we(cw1_we), .w1_bypass_rd(cw1_rd), .w1_bypass_data(cw1_data)
    );
    assign dec0.valid=fq_valid[0];
    assign dec0.pc=fq_pc[0];
    assign dec0.instr=fq_inst[0];
    assign dec0.fault=fq_fault[0];
    assign dec0.pred_valid=fq_pv[0];
    assign dec0.pred_taken=fq_pt[0];
    assign dec0.pred_target=fq_target[0];
    assign dec0.ra=0;
    assign dec0.rb=0;
    assign dec0.src1_pending=0;
    assign dec0.src2_pending=0;
    assign dec0.src1_tag=0;
    assign dec0.src2_tag=0;
    assign dec0.tag=0;
    dual_pipeline_decode #(.M_MODE(M_MODE)) u_decode0 (
        .inst_i(fq_inst[0]), .pc_i(fq_pc[0]), .fault_i(fq_fault[0]),
        .rs1_o(dec0.rs1), .rs2_o(dec0.rs2), .rd_o(dec0.rd), .uses_rs1_o(dec0.use_rs1), .uses_rs2_o(dec0.use_rs2), .reg_we_o(dec0.reg_we), .imm_o(dec0.imm), .alu_func_o(dec0.alu_func), .src_a_pc_o(dec0.src_a_pc), .src_a_zero_o(dec0.src_a_zero), .src_b_imm_o(dec0.src_b_imm), .branch_o(dec0.branch), .jal_o(dec0.jal), .jalr_o(dec0.jalr), .mem_o(dec0.mem), .store_o(dec0.store), .funct3_o(dec0.funct3), .mdu_o(dec0.mdu), .csr_o(dec0.csr), .csr_addr_o(dec0.csr_addr), .csr_we_o(dec0.csr_we), .csr_op_o(dec0.csr_op), .csr_imm_o(dec0.csr_imm), .csr_uimm_o(dec0.csr_uimm), .ecall_o(dec0.ecall), .ebreak_o(dec0.ebreak), .mret_o(dec0.mret), .fence_o(dec0.fence), .illegal_o(dec0.illegal)
    );
    assign dec1.valid=fq_valid[1];
    assign dec1.pc=fq_pc[1];
    assign dec1.instr=fq_inst[1];
    assign dec1.fault=fq_fault[1];
    assign dec1.pred_valid=fq_pv[1];
    assign dec1.pred_taken=fq_pt[1];
    assign dec1.pred_target=fq_target[1];
    assign dec1.ra=0;
    assign dec1.rb=0;
    assign dec1.src1_pending=0;
    assign dec1.src2_pending=0;
    assign dec1.src1_tag=0;
    assign dec1.src2_tag=0;
    assign dec1.tag=0;
    dual_pipeline_decode #(.M_MODE(M_MODE)) u_decode1 (
        .inst_i(fq_inst[1]), .pc_i(fq_pc[1]), .fault_i(fq_fault[1]),
        .rs1_o(dec1.rs1), .rs2_o(dec1.rs2), .rd_o(dec1.rd), .uses_rs1_o(dec1.use_rs1), .uses_rs2_o(dec1.use_rs2), .reg_we_o(dec1.reg_we), .imm_o(dec1.imm), .alu_func_o(dec1.alu_func), .src_a_pc_o(dec1.src_a_pc), .src_a_zero_o(dec1.src_a_zero), .src_b_imm_o(dec1.src_b_imm), .branch_o(dec1.branch), .jal_o(dec1.jal), .jalr_o(dec1.jalr), .mem_o(dec1.mem), .store_o(dec1.store), .funct3_o(dec1.funct3), .mdu_o(dec1.mdu), .csr_o(dec1.csr), .csr_addr_o(dec1.csr_addr), .csr_we_o(dec1.csr_we), .csr_op_o(dec1.csr_op), .csr_imm_o(dec1.csr_imm), .csr_uimm_o(dec1.csr_uimm), .ecall_o(dec1.ecall), .ebreak_o(dec1.ebreak), .mret_o(dec1.mret), .fence_o(dec1.fence), .illegal_o(dec1.illegal)
    );

    wire serial0 = fq_sidecar[0][8];
    wire serial1 = fq_sidecar[1][8];
    wire control0 = fq_sidecar[0][5];
    wire control1 = fq_sidecar[1][5];
    wire bad0 = fq_sidecar[0][0];
    wire bad1 = fq_sidecar[1][0];
    wire intra_raw = fq_sidecar[0][1] && (fq_rd[0] != 0) &&
        ((fq_sidecar[1][2] && fq_rs1[1] == fq_rd[0]) ||
         (fq_sidecar[1][3] && fq_rs2[1] == fq_rd[0]));
    wire intra_waw = fq_sidecar[0][1] && fq_sidecar[1][1] &&
                     (fq_rd[0] != 0) && fq_rd[0] == fq_rd[1];
    // Propagate a move's source tag or a literal without serial ALUs.
    wire copy0 = fq_sidecar[0][9];
    wire literal0 = fq_sidecar[0][10];
    // MDU may occupy slot0 with one independent non-memory ALU in slot1.
    // The MDU result stays unready in its completion slot while the ALU packet
    // can complete; ordered retirement still waits for the older MDU tag.
    wire mdu_alu_pair = fq_sidecar[0][7] && !fq_sidecar[1][7] && !fq_sidecar[1][6] &&
                       !serial1 && !control1;
    wire regular_pair = !fq_sidecar[0][7] && !fq_sidecar[1][7] &&
                        !(fq_sidecar[0][6] && fq_sidecar[1][6]);
    wire branch_alu_pair = fq_sidecar[0][4] && !fq_sidecar[1][6] && !fq_sidecar[1][7] &&
        !serial1 && !control1 &&
        (!dec0.pred_valid || !dec0.pred_taken || dec0.pred_target == dec1.pc);
    wire pair_eligible_raw = DUAL_ISSUE_EN && !bad0 && !bad1 &&
        !serial0 && !serial1 &&
        (branch_alu_pair || (!control0 && (regular_pair || mdu_alu_pair))) &&
        (!intra_raw || copy0 || literal0) &&
        (fq_pc[1] == fq_pc[0] + 32'd4);
    wire ex_fire, ex_sources_ready, mdu_ready, branch_pair_kill;
    wire ex_slot_free = !id_ex0_q.valid || ex_fire;
    wire consume0_intent = !rst && ex_slot_free && !pipeline_clear && !branch_pair_kill &&
                    !serial_busy_q && (count_q < N) &&
                    (!serial0 || ((count_q == 0) && !id_ex0_q.valid));
    wire issue0_pre_redirect = fq_present[0] && consume0_intent;
    wire issue1_pre_redirect = issue0_pre_redirect && fq_present[1] && pair_eligible_raw && (count_q <= N-2);
    assign issue0 = issue0_pre_redirect && !ex_redirect;
    assign issue1 = issue1_pre_redirect && !ex_redirect;
    // The FQ remains the IF/ID storage boundary. Its pre-consume may assert
    // during EX redirect because synchronous flush wins at the same edge.
    assign fq_pop_intent0 = issue0_pre_redirect;
    assign fq_pop_intent1 = issue1_pre_redirect;
    assign fq_consume0 = issue0_pre_redirect;
    assign fq_consume1 = issue1_pre_redirect;
    wire [1:0] push_count = {1'b0, issue0} + {1'b0, issue1};
    wire [1:0] pop_count = wb_trap ? 2'd0 :
        ({1'b0, commit0} + {1'b0, commit1});
    wire [2:0] tail1 = tail_q + 3'd1;
    wire [2:0] visible_head = head_q + pop_count;
    wire [2:0] visible_head1 = visible_head + 3'd1;
    wire [3:0] visible_count = count_q - pop_count;

    function automatic wb_hits(input [4:0] rs);
        wb_hits = (cw0_we && cw0_rd == rs && rs != 0) ||
                  (cw1_we && cw1_rd == rs && rs != 0);
    endfunction
    function automatic [31:0] wb_value(input [4:0] rs, input [31:0] value);
        wb_value = rs == 0 ? 32'd0 :
            (cw1_we && cw1_rd == rs) ? cw1_data :
            (cw0_we && cw0_rd == rs) ? cw0_data : value;
    endfunction
    function automatic retiring_source(input [4:0] rs, input [2:0] tag);
        retiring_source = (cw0_we && cw0_rd == rs && mem_wb0_q.tag == tag) ||
                          (cw1_we && cw1_rd == rs && mem_wb1_q.tag == tag);
    endfunction
    always @* begin
        intake0 = dec0;
        intake0.tag = tail_q;
        intake0.ra = wb_value(dec0.rs1, rf0a);
        intake0.rb = wb_value(dec0.rs2, rf0b);
        intake0.src1_tag = rename_tag(fq_rs1[0], rename_tags_q);
        intake0.src2_tag = rename_tag(fq_rs2[0], rename_tags_q);
        intake0.src1_pending = fq_sidecar[0][2] && fq_rs1[0] != 0 &&
            rename_valid_q[fq_rs1[0]] && !retiring_source(fq_rs1[0], rename_tag(fq_rs1[0], rename_tags_q));
        intake0.src2_pending = fq_sidecar[0][3] && fq_rs2[0] != 0 &&
            rename_valid_q[fq_rs2[0]] && !retiring_source(fq_rs2[0], rename_tag(fq_rs2[0], rename_tags_q));
        if (intake0.src1_pending && source_available(intake0.src1_tag)) begin
            intake0.ra = source_value(intake0.src1_tag);
            intake0.src1_pending = 1'b0;
        end
        if (intake0.src2_pending && source_available(intake0.src2_tag)) begin
            intake0.rb = source_value(intake0.src2_tag);
            intake0.src2_pending = 1'b0;
        end
        intake0.valid = issue0;
        intake1 = dec1;
        intake1.tag = tail1;
        intake1.ra = wb_value(dec1.rs1, rf1a);
        intake1.rb = wb_value(dec1.rs2, rf1b);
        intake1.src1_tag = rename_tag(fq_rs1[1], rename_tags_q);
        intake1.src2_tag = rename_tag(fq_rs2[1], rename_tags_q);
        intake1.src1_pending = fq_sidecar[1][2] && fq_rs1[1] != 0 &&
            rename_valid_q[fq_rs1[1]] && !retiring_source(fq_rs1[1], rename_tag(fq_rs1[1], rename_tags_q));
        intake1.src2_pending = fq_sidecar[1][3] && fq_rs2[1] != 0 &&
            rename_valid_q[fq_rs2[1]] && !retiring_source(fq_rs2[1], rename_tag(fq_rs2[1], rename_tags_q));
        if (intake1.src1_pending && source_available(intake1.src1_tag)) begin
            intake1.ra = source_value(intake1.src1_tag);
            intake1.src1_pending = 1'b0;
        end
        if (intake1.src2_pending && source_available(intake1.src2_tag)) begin
            intake1.rb = source_value(intake1.src2_tag);
            intake1.src2_pending = 1'b0;
        end
        if (intra_raw && dec1.use_rs1 && dec1.rs1 == dec0.rd) begin
            if (literal0) begin
                intake1.ra = dec0.imm;
                intake1.src1_pending = 1'b0;
            end else if (copy0) begin
                intake1.ra = intake0.ra;
                intake1.src1_pending = intake0.src1_pending;
                intake1.src1_tag = intake0.src1_tag;
            end
        end
        if (intra_raw && dec1.use_rs2 && dec1.rs2 == dec0.rd) begin
            if (literal0) begin
                intake1.rb = dec0.imm;
                intake1.src2_pending = 1'b0;
            end else if (copy0) begin
                intake1.rb = intake0.ra;
                intake1.src2_pending = intake0.src1_pending;
                intake1.src2_tag = intake0.src1_tag;
            end
        end
        intake1.valid = issue1;
    end

    // The tag names the exact producer, including across WAW chains. A tag
    // remains allocated until WB; held consumers capture retiring producer
    // data before the slot can be reused. No queue-age selection is required.
    wire [N*32-1:0] forward_data;
    genvar f;
    generate for (f=0; f<N; f=f+1) begin : g_forward_data
        wire result_packet_t entry = q_payload[f];
        assign forward_data[f*32 +: 32] = entry.result;
    end endgenerate
    function automatic [31:0] tagged_value(
        input pending, input [2:0] tag, input [31:0] held,
        input [N*32-1:0] data_flat);
        integer k;
        reg [31:0] v;
        begin
            v = 32'd0;
            for (k=0; k<N; k=k+1)
                v = v | (data_flat[k*32 +: 32] & {32{tag == k[2:0]}});
            tagged_value = pending ? v : held;
        end
    endfunction
    wire [31:0] ex0_ra = id_ex0_q.ra;
    wire [31:0] ex0_rb = id_ex0_q.rb;
    wire [31:0] ex1_ra = id_ex1_q.ra;
    wire [31:0] ex1_rb = id_ex1_q.rb;
    assign ex_sources_ready = !id_ex0_q.src1_pending && !id_ex0_q.src2_pending &&
        (!id_ex1_q.valid || (!id_ex1_q.src1_pending && !id_ex1_q.src2_pending));
    assign ex_fire = id_ex0_q.valid && ex_sources_ready &&
        (!id_ex0_q.mdu || mdu_ready) && !wb_flush && !irq_boundary && !rst;

    wire [31:0] ex_value[0:1], ex_addr[0:1], ex_target[0:1];
    wire [1:0] ex_taken;
    wire ex_taken0_fast;
    wire ex_taken1_fast;
    dual_pipeline_execute u_execute0 (
        .alu_func_i(id_ex0_q.alu_func), .src_a_pc_i(id_ex0_q.src_a_pc),
        .src_a_zero_i(id_ex0_q.src_a_zero), .src_b_imm_i(id_ex0_q.src_b_imm),
        .branch_i(id_ex0_q.branch), .jal_i(id_ex0_q.jal), .jalr_i(id_ex0_q.jalr),
        .funct3_i(id_ex0_q.funct3), .pc_i(id_ex0_q.pc), .imm_i(id_ex0_q.imm),
        .ra_i(ex0_ra), .rb_i(ex0_rb), .result_o(ex_value[0]),
        .branch_taken_o(ex_taken[0]), .branch_taken_fast_o(ex_taken0_fast),
        .branch_target_o(ex_target[0]),
        .effective_addr_o(ex_addr[0])
    );
    dual_pipeline_execute u_execute1 (
        .alu_func_i(id_ex1_q.alu_func), .src_a_pc_i(id_ex1_q.src_a_pc),
        .src_a_zero_i(id_ex1_q.src_a_zero), .src_b_imm_i(id_ex1_q.src_b_imm),
        .branch_i(id_ex1_q.branch), .jal_i(id_ex1_q.jal), .jalr_i(id_ex1_q.jalr),
        .funct3_i(id_ex1_q.funct3), .pc_i(id_ex1_q.pc), .imm_i(id_ex1_q.imm),
        .ra_i(ex1_ra), .rb_i(ex1_rb), .result_o(ex_value[1]),
        .branch_taken_o(ex_taken[1]), .branch_taken_fast_o(ex_taken1_fast),
        .branch_target_o(ex_target[1]),
        .effective_addr_o(ex_addr[1])
    );

    wire [31:0] csr_rdata, csr_mtvec, csr_mepc, csr_irq_cause;
    wire csr_implemented, csr_writable, csr_irq_pending;
    wire csr_write = commit0 && !wb_trap && mem_wb0_q.csr && mem_wb0_q.csr_we;
    wire mret_commit = commit0 && !wb_trap && mem_wb0_q.mret;
    wire [11:0] csr_port_addr = mem_wb0_q.valid && mem_wb0_q.csr ?
        mem_wb0_q.csr_addr : id_ex0_q.csr_addr;
    csr_file u_csr (
        .clk(clk), .rst(rst),
        .retire_count({1'b0, commit0 && !wb_trap} + {1'b0, commit1}),
        .csr_addr(csr_port_addr), .csr_rdata(csr_rdata),
        .csr_implemented(csr_implemented), .csr_writable(csr_writable),
        .csr_chk_addr(id_ex0_q.csr_addr), .csr_chk_implemented(), .csr_chk_writable(),
        .csr_we(csr_write), .csr_op(mem_wb0_q.csr_op), .csr_wdata(mem_wb0_q.csr_wdata),
        .trap_enter(wb_trap), .trap_pc(trap_pc), .trap_cause(trap_cause),
        .trap_tval(mem_wb0_q.tval), .mret(mret_commit),
        .timer_irq(timer_irq_i), .ext_irq(ext_irq_i), .mip(), .mie(),
        .irq_pending(csr_irq_pending), .irq_cause(csr_irq_cause),
        .mstatus(), .mtvec(csr_mtvec), .mepc(csr_mepc), .mcause(), .mtval()
    );

    function automatic result_packet_t make_result(
        input id_packet_t p, input [31:0] value, addr, rb,
        input taken, input [31:0] target);
        result_packet_t r;
        reg misaligned;
        begin
            r = '0;
            r.valid = p.valid; r.tag=p.tag; r.pc=p.pc; r.instr=p.instr;
            r.rd=p.rd; r.reg_we=p.reg_we; r.result=value;
            r.next_pc = taken ? target : p.pc + 32'd4;
            r.mem=p.mem; r.store=p.store; r.funct3=p.funct3; r.addr=addr; r.store_data=rb;
            r.csr=p.csr; r.csr_addr=p.csr_addr; r.csr_we=p.csr_we; r.csr_op=p.csr_op;
            r.csr_wdata=p.csr_imm ? p.csr_uimm : 32'd0;
            r.mret=p.mret; r.serial=p.csr || p.mret || p.fence;
            misaligned = p.mem && ((p.funct3[1:0] == 2'b10) ? |addr[1:0] :
                                      (p.funct3[1:0] == 2'b01) ? addr[0] : 1'b0);
            r.trap = p.fault || p.illegal || p.ecall || p.ebreak || misaligned ||
                     (taken && target[1]);
            r.cause = p.fault ? 32'd1 : p.illegal ? 32'd2 :
                      p.ecall ? 32'd11 : p.ebreak ? 32'd3 :
                      misaligned ? (p.store ? 32'd6 : 32'd4) : 32'd0;
            r.tval = p.fault ? p.pc : p.illegal ? p.instr :
                     misaligned ? addr : taken && target[1] ? target : 32'd0;
            make_result = r;
        end
    endfunction
    always @* begin
        ex_result0 = make_result(id_ex0_q, ex_value[0], ex_addr[0], ex0_rb, ex_taken[0], ex_target[0]);
        ex_result1 = make_result(id_ex1_q, ex_value[1], ex_addr[1], ex1_rb, ex_taken[1], ex_target[1]);
        ex_result0.csr_wdata = id_ex0_q.csr_imm ? id_ex0_q.csr_uimm : ex0_ra;
        if (id_ex0_q.csr) begin
            ex_result0.result = csr_rdata;
            if (!csr_implemented || (id_ex0_q.csr_we && !csr_writable)) begin
                ex_result0.trap=1'b1; ex_result0.cause=32'd2; ex_result0.tval=id_ex0_q.instr;
            end
        end
        if (id_ex0_q.mret) ex_result0.next_pc = csr_mepc;
    end

    wire [31:0] predicted0 = id_ex0_q.pred_valid && id_ex0_q.pred_taken ?
        id_ex0_q.pred_target : id_ex0_q.pc + 32'd4;
    wire [31:0] predicted1 = id_ex1_q.pred_valid && id_ex1_q.pred_taken ?
        id_ex1_q.pred_target : id_ex1_q.pc + 32'd4;
    // Compare both possible next PCs in parallel with the branch condition.
    // This avoids placing a 32-bit predicted-PC comparator after the forwarded
    // operand -> branch comparison path, without adding a recovery cycle.
    wire mismatch0 = !id_ex0_q.mret && (ex_taken0_fast ?
        (ex_target[0] != predicted0) : (id_ex0_q.pc + 32'd4 != predicted0));
    wire mismatch1 = id_ex1_q.valid && (ex_taken1_fast ?
        (ex_target[1] != predicted1) : (id_ex1_q.pc + 32'd4 != predicted1));
    assign ex_redirect = ex_fire && !ex_result0.trap &&
        (mismatch0 || (mismatch1 && !ex_result1.trap));
    assign ex_redirect_target = mismatch0 ? ex_result0.next_pc : ex_result1.next_pc;
    wire pair_target_mismatch = ex_target[0] != id_ex1_q.pc;
    wire pair_sequential_mismatch = (id_ex0_q.pc + 32'd4) != id_ex1_q.pc;
    wire pair_mret_mismatch = csr_mepc != id_ex1_q.pc;
    assign branch_pair_kill = ex_fire && id_ex1_q.valid && id_ex0_q.branch &&
        (id_ex0_q.mret ? pair_mret_mismatch :
         (ex_taken0_fast ? pair_target_mismatch : pair_sequential_mismatch));
    wire train1 = id_ex1_q.valid && (id_ex1_q.branch || id_ex1_q.jal || id_ex1_q.jalr ||
                                    (!id_ex0_q.pred_valid && id_ex1_q.pred_valid));
    assign bp_update_valid = ex_fire && !ex_result0.trap &&
        (id_ex0_q.branch || id_ex0_q.jal || id_ex0_q.jalr || id_ex0_q.pred_valid || train1);
    assign bp_update_pc = train1 ? id_ex1_q.pc : id_ex0_q.pc;
    assign bp_update_taken = train1 ? ex_taken[1] : ex_taken[0];
    assign bp_update_target = train1 ? ex_target[1] : ex_target[0];
    assign bp_pred_taken = train1 ? id_ex1_q.pred_taken : id_ex0_q.pred_taken;
    assign bp_pred_target = train1 ? id_ex1_q.pred_target : id_ex0_q.pred_target;
    wire [31:0] train_inst = train1 ? id_ex1_q.instr : id_ex0_q.instr;
    assign bp_is_call = ((train_inst[6:0] == 7'h6f) || (train_inst[6:0] == 7'h67)) &&
                        ((train_inst[11:7] == 5'd1) || (train_inst[11:7] == 5'd5));
    assign bp_is_ret = train_inst[6:0] == 7'h67 && train_inst[11:7] == 0 &&
                       ((train_inst[19:15] == 5'd1) || (train_inst[19:15] == 5'd5));

    wire mdu_done;
    wire [31:0] mdu_result;
    reg [2:0] mdu_tag_q;
    rv32im_unit #(.DIV_ENABLE(M_MODE == 2)) u_mdu (
        .clk_i(clk), .rst_i(rst || wb_flush || irq_boundary),
        .start_i(ex_fire && id_ex0_q.mdu && !ex_result0.trap),
        .funct3_i(id_ex0_q.funct3), .operand_a_i(ex0_ra), .operand_b_i(ex0_rb),
        .ready_o(mdu_ready), .done_o(mdu_done), .result_o(mdu_result)
    );
    always @(posedge clk)
        if (ex_fire && id_ex0_q.mdu) mdu_tag_q <= id_ex0_q.tag;

    // MEM/WB selection is separate from forwarding. Retirement head/age
    // selects only registered packets for WB, never a live EX operand.
    wire result_packet_t visible0 = q_payload[visible_head];
    wire result_packet_t visible1 = q_payload[visible_head1];
    wire wb_refill0 = visible_count != 0 && q_valid[visible_head] && q_ready[visible_head];
    wire wb_refill1 = wb_refill0 && visible_count >= 2 &&
        q_valid[visible_head1] && q_ready[visible_head1] &&
        !visible0.trap && !visible0.serial && !visible1.serial;
    dual_commit u_commit (
        .s0_valid(mem_wb0_q.valid), .s0_trap(mem_wb0_q.trap),
        .s0_writes_rd(mem_wb0_q.reg_we), .s0_rd(mem_wb0_q.rd),
        .s0_data(mem_wb0_q.result), .s0_cause(mem_wb0_q.cause), .s0_pc(mem_wb0_q.pc),
        .s1_valid(mem_wb1_q.valid), .s1_trap(mem_wb1_q.trap),
        .s1_writes_rd(mem_wb1_q.reg_we), .s1_rd(mem_wb1_q.rd),
        .s1_data(mem_wb1_q.result), .s1_cause(mem_wb1_q.cause), .s1_pc(mem_wb1_q.pc),
        .commit0_fire(commit0), .commit1_fire(commit1),
        .trap_fire(wb_trap), .trap_cause(trap_cause), .trap_pc(trap_pc),
        .flush_young(), .hold_s1(wb_hold1),
        .w0_we(cw0_we), .w0_rd(cw0_rd), .w0_data(cw0_data),
        .w1_we(cw1_we), .w1_rd(cw1_rd), .w1_data(cw1_data)
    );
    assign retire0_valid=commit0;
    assign retire1_valid=commit1;
    assign wb_flush = wb_trap || mret_commit;
    assign irq_boundary = commit0 && !wb_trap && !wb_hold1 && !mem_wb0_q.serial &&
                          csr_irq_pending;
    assign pipeline_clear = wb_flush || irq_boundary;
    assign redirect_any = pipeline_clear || ex_redirect;
    assign redirect_target = wb_trap || irq_boundary ? csr_mtvec :
                             mret_commit ? csr_mepc : ex_redirect_target;

    // Single ordered D transaction. Payload comes only from EX/MEM registers.
    // A speculative cacheable read may overlap an older completed ALU; stores
    // and MMIO start only at the oldest not-yet-committed position.
    reg mem_active_q, mem_discard_q;
    reg [2:0] mem_tag_q;
    reg request_hold_q, request_discard_q;
    reg [2:0] request_tag_q;
    mem_request_t request_payload_q;
    // Memory instructions enter this tag FIFO in EX order. It permits an
    // independent cacheable load to start while older completed instructions
    // await WB, and lets the next cacheable load use a successful response
    // edge. Stores and MMIO still wait until they are the oldest instruction.
    reg [2:0] memq_head_q, memq_tail_q;
    reg [3:0] memq_count_q;
    reg [2:0] memq_tags[0:N-1];
    reg [N*71-1:0] memq_requests_flat;
    wire memq_push0 = ex_fire && id_ex0_q.mem && !ex_result0.trap;
    wire memq_push1 = ex_fire && id_ex1_q.valid && id_ex1_q.mem && !ex_result1.trap;
    wire memq_push = memq_push0 || memq_push1;
    wire [2:0] mem_candidate_tag = memq_tags[memq_head_q];
    mem_request_t mem_candidate;
    always @* begin
        mem_candidate='0;
        case (mem_candidate_tag)
            3'd0: mem_candidate=memq_requests_flat[0*71 +: 71];
            3'd1: mem_candidate=memq_requests_flat[1*71 +: 71];
            3'd2: mem_candidate=memq_requests_flat[2*71 +: 71];
            3'd3: mem_candidate=memq_requests_flat[3*71 +: 71];
            3'd4: mem_candidate=memq_requests_flat[4*71 +: 71];
            3'd5: mem_candidate=memq_requests_flat[5*71 +: 71];
            3'd6: mem_candidate=memq_requests_flat[6*71 +: 71];
            3'd7: mem_candidate=memq_requests_flat[7*71 +: 71];
            default: mem_candidate='0;
        endcase
    end
    wire candidate_valid = (memq_count_q != 0) && q_valid[mem_candidate_tag] &&
        q_executed[mem_candidate_tag] && !q_ready[mem_candidate_tag] &&
        mem_candidate.tag == mem_candidate_tag;
    wire candidate_cached_load = !mem_candidate.store &&
        mem_candidate.addr >= CACHEABLE_BASE &&
        (mem_candidate.addr - CACHEABLE_BASE < CACHEABLE_SIZE);
    wire candidate_is_oldest = visible_count != 0 && mem_candidate_tag == visible_head;
    // Once offered, a ready/valid transaction cannot be withdrawn on a
    // speculative flush. Preserve it in this skid entry, then drain its
    // response with discard set before allowing another request.
    wire successful_turnover = mem_active_q && d_rsp_valid && !d_rsp_error &&
                               !mem_discard_q && candidate_cached_load;
    wire new_request_offer = candidate_valid && !pipeline_clear &&
        (candidate_cached_load || candidate_is_oldest) &&
        (!mem_active_q || successful_turnover);
    wire mem_request_t request_payload = request_hold_q ? request_payload_q : mem_candidate;
    wire [2:0] request_tag = request_hold_q ? request_tag_q : mem_candidate_tag;
    assign d_req_valid = !rst && (request_hold_q || new_request_offer);
    assign d_req_addr = {request_payload.addr[31:2], 2'b00};
    assign d_req_write = request_payload.store;
    assign d_req_wdata = request_payload.store_data << (8*request_payload.addr[1:0]);
    assign d_req_wstrb = (request_payload.funct3[1:0] == 2'b00 ? 4'b0001 :
                          request_payload.funct3[1:0] == 2'b01 ? 4'b0011 : 4'b1111)
                         << request_payload.addr[1:0];
    wire mem_req_fire = d_req_valid && d_req_ready;
    wire memq_pop = mem_req_fire && !pipeline_clear &&
                    (!request_hold_q || !request_discard_q);
    // The completion slots always have room for the one outstanding response.
    // Keep response readiness independent of request readiness: the cache path
    // derives request credit from response readiness and would otherwise form
    // a combinational ready loop on a same-cycle response.
    assign d_rsp_ready = !rst;
    wire mem_rsp_fire = d_rsp_valid && d_rsp_ready && (mem_active_q || mem_req_fire);
    wire [2:0] response_tag = mem_active_q ? mem_tag_q : request_tag;
    wire response_discard = mem_active_q ? mem_discard_q :
                            (request_discard_q || pipeline_clear);
    mem_request_t response_request_q;
    always @* begin
        response_request_q='0;
        case (response_tag)
            3'd0: response_request_q=memq_requests_flat[0*71 +: 71];
            3'd1: response_request_q=memq_requests_flat[1*71 +: 71];
            3'd2: response_request_q=memq_requests_flat[2*71 +: 71];
            3'd3: response_request_q=memq_requests_flat[3*71 +: 71];
            3'd4: response_request_q=memq_requests_flat[4*71 +: 71];
            3'd5: response_request_q=memq_requests_flat[5*71 +: 71];
            3'd6: response_request_q=memq_requests_flat[6*71 +: 71];
            3'd7: response_request_q=memq_requests_flat[7*71 +: 71];
            default: response_request_q='0;
        endcase
    end
    wire mem_request_t response_request = mem_active_q ? response_request_q : request_payload;
    // Keep the existing performance harness probe while narrowing its payload
    // from the full completion packet to the MEM request sidecar.
    wire mem_request_t response_entry = response_request;
    wire [31:0] shifted_response = d_rsp_rdata >> (8*response_request.addr[1:0]);
    reg [31:0] load_result;
    always @* begin
        case (response_request.funct3)
            3'b000: load_result={{24{shifted_response[7]}}, shifted_response[7:0]};
            3'b001: load_result={{16{shifted_response[15]}}, shifted_response[15:0]};
            3'b100: load_result={24'd0, shifted_response[7:0]};
            3'b101: load_result={16'd0, shifted_response[15:0]};
            default: load_result=d_rsp_rdata;
        endcase
    end
    result_packet_t direct_response_result;
    always @* begin
        direct_response_result=q_payload[response_tag];
        direct_response_result.result=load_result;
        if (d_rsp_error) begin
            direct_response_result.trap=1'b1;
            direct_response_result.cause=response_request.store ? 32'd7 : 32'd5;
            direct_response_result.tval=response_request.addr;
        end
    end
    // A response may enter WB on the same edge that frees its slot. The tag
    // must already be the visible retirement head, and all discard/flush and
    // slot1-trap hold rules remain in force.
    function automatic source_available(input [2:0] tag);
        begin
            source_available =
                (cw1_we && mem_wb1_q.tag == tag) ||
                (cw0_we && mem_wb0_q.tag == tag) ||
                (mem_rsp_fire && !response_discard && response_tag == tag) ||
                (mdu_done && mdu_tag_q == tag && q_valid[tag]) ||
                (ex_fire && id_ex0_q.tag == tag && (ex_result0.trap || (!id_ex0_q.mem && !id_ex0_q.mdu))) ||
                (ex_fire && id_ex1_q.valid && id_ex1_q.tag == tag && (ex_result1.trap || !id_ex1_q.mem)) ||
                (q_valid[tag] && q_ready[tag]);
        end
    endfunction
    function automatic [31:0] source_value(input [2:0] tag);
        begin
            if (cw1_we && mem_wb1_q.tag == tag) source_value = cw1_data;
            else if (cw0_we && mem_wb0_q.tag == tag) source_value = cw0_data;
            else if (mem_rsp_fire && !response_discard && response_tag == tag) source_value = load_result;
            else if (mdu_done && mdu_tag_q == tag && q_valid[tag]) source_value = mdu_result;
            else if (ex_fire && id_ex0_q.tag == tag && (ex_result0.trap || (!id_ex0_q.mem && !id_ex0_q.mdu))) source_value = ex_result0.result;
            else if (ex_fire && id_ex1_q.valid && id_ex1_q.tag == tag && (ex_result1.trap || !id_ex1_q.mem)) source_value = ex_result1.result;
            else source_value = tagged_value(1'b1, tag, 32'd0, forward_data);
        end
    endfunction
    wire wb_response_direct = mem_rsp_fire && !response_discard && !pipeline_clear &&
        !wb_hold1 && (response_tag == visible_head) && q_valid[visible_head] &&
        (!mem_wb0_q.valid || commit0);
    wire wb_response_direct_refill1 = wb_response_direct && visible_count >= 2 &&
        q_valid[visible_head1] && q_ready[visible_head1] &&
        !direct_response_result.trap && !direct_response_result.serial && !visible1.serial;
    result_packet_t multiply_result;
    always @* begin
        multiply_result=q_payload[mdu_tag_q];
        multiply_result.result=mdu_result;
    end
    always @(posedge clk) begin
        if (rst) begin
            mem_active_q<=0; mem_discard_q<=0; mem_tag_q<=0;
            request_hold_q<=0; request_discard_q<=0; request_tag_q<=0;
        end
        else begin
            if (!request_hold_q && d_req_valid && !d_req_ready) begin
                request_hold_q<=1; request_discard_q<=0;
                request_tag_q<=mem_candidate_tag; request_payload_q<=mem_candidate;
            end
            if (pipeline_clear && request_hold_q) request_discard_q<=1;
            if (mem_req_fire) begin
                request_hold_q<=0;
                mem_active_q<=1; mem_tag_q<=request_tag;
                mem_discard_q<=request_hold_q && (request_discard_q || pipeline_clear);
                request_discard_q<=0;
            end
            if (pipeline_clear && mem_active_q && !mem_rsp_fire) mem_discard_q<=1;
            if (mem_rsp_fire && !(mem_active_q && mem_req_fire)) begin
                mem_active_q<=0; mem_discard_q<=0;
            end
        end
    end
    always @(posedge clk) begin
        if (rst || pipeline_clear) begin
            memq_head_q<=0; memq_tail_q<=0; memq_count_q<=0;
        end else begin
            if (memq_push) begin
                memq_tags[memq_tail_q] <= memq_push0 ? id_ex0_q.tag : id_ex1_q.tag;
                memq_tail_q <= memq_tail_q + 3'd1;
            end
            if (memq_pop) memq_head_q <= memq_head_q + 3'd1;
            if (memq_push || memq_pop)
                memq_count_q <= memq_count_q + {3'b0,memq_push} - {3'b0,memq_pop};
        end
    end

    always @(posedge clk) begin
        if (rst || pipeline_clear) begin
            head_q<=0; tail_q<=0; count_q<=0; rename_valid_q<=0; serial_busy_q<=0;
        end else begin
            head_q<=head_q+pop_count;
            tail_q<=tail_q+push_count-branch_pair_kill;
            count_q<=count_q+push_count-pop_count-branch_pair_kill;
            if (commit0 && mem_wb0_q.serial) serial_busy_q<=0;
            if (cw0_we && rename_valid_q[cw0_rd] && rename_tag(cw0_rd,rename_tags_q) == mem_wb0_q.tag)
                rename_valid_q[cw0_rd]<=0;
            if (cw1_we && rename_valid_q[cw1_rd] && rename_tag(cw1_rd,rename_tags_q) == mem_wb1_q.tag)
                rename_valid_q[cw1_rd]<=0;
            if (issue0 && fq_sidecar[0][1] && fq_rd[0] != 0 && !bad0) begin
                rename_valid_q[fq_rd[0]]<=1;
            end
            if (issue1 && fq_sidecar[1][1] && fq_rd[1] != 0 && !bad1) begin
                rename_valid_q[fq_rd[1]]<=1;
            end
            if (branch_pair_kill && id_ex1_q.reg_we && id_ex1_q.rd != 0) begin
                if (branch_pair_prev_valid_q && q_valid[branch_pair_prev_tag_q] &&
                    !(cw0_we && mem_wb0_q.tag == branch_pair_prev_tag_q) &&
                    !(cw1_we && mem_wb1_q.tag == branch_pair_prev_tag_q))
                    rename_valid_q[id_ex1_q.rd]<=1'b1;
                else
                    rename_valid_q[id_ex1_q.rd]<=1'b0;
            end
            if (issue0 && serial0) serial_busy_q<=1;
        end
    end
    genvar tag_reg;
    generate for (tag_reg=0; tag_reg<32; tag_reg=tag_reg+1) begin : g_rename_tags
        always @(posedge clk) begin
            if (rst || pipeline_clear) rename_tags_q[tag_reg*3 +: 3] <= 3'd0;
            else if (branch_pair_kill && id_ex1_q.reg_we && id_ex1_q.rd == tag_reg && tag_reg != 0)
                rename_tags_q[tag_reg*3 +: 3] <=
                    (branch_pair_prev_valid_q && q_valid[branch_pair_prev_tag_q] &&
                     !(cw0_we && mem_wb0_q.tag == branch_pair_prev_tag_q) &&
                     !(cw1_we && mem_wb1_q.tag == branch_pair_prev_tag_q)) ?
                    branch_pair_prev_tag_q : 3'd0;
            else if (issue1 && fq_sidecar[1][1] && fq_rd[1] == tag_reg && tag_reg != 0 && !bad1)
                rename_tags_q[tag_reg*3 +: 3] <= tail1;
            else if (issue0 && fq_sidecar[0][1] && fq_rd[0] == tag_reg && tag_reg != 0 && !bad0)
                rename_tags_q[tag_reg*3 +: 3] <= tail_q;
        end
    end endgenerate
    generate for (f=0; f<N; f=f+1) begin : g_completion_slot
        result_packet_t response_result_f;
        always @* begin
            response_result_f=q_payload[f];
            response_result_f.result=load_result;
            if (d_rsp_error) begin
                response_result_f.trap=1'b1;
                response_result_f.cause=response_request.store ? 32'd7 : 32'd5;
                response_result_f.tval=response_request.addr;
            end
        end
        always @(posedge clk) begin
            if (rst || pipeline_clear) begin
                q_valid[f]<=0; q_ready[f]<=0; q_executed[f]<=0;
            end else begin
                if ((commit0 && mem_wb0_q.tag == f) || (commit1 && mem_wb1_q.tag == f))
                    q_valid[f]<=0;
                if ((issue0 && tail_q == f) || (issue1 && tail1 == f)) begin
                    q_valid[f]<=1; q_ready[f]<=0; q_executed[f]<=0;
                end
                if (ex_fire && id_ex0_q.tag == f) begin
                    q_payload[f]<=ex_result0; q_executed[f]<=1;
                    q_ready[f]<=ex_result0.trap || (!id_ex0_q.mem && !id_ex0_q.mdu);
                end
                if (ex_fire && id_ex1_q.valid && id_ex1_q.tag == f) begin
                    q_payload[f]<=ex_result1; q_executed[f]<=1;
                    q_ready[f]<=ex_result1.trap || !id_ex1_q.mem;
                end
                if (branch_pair_kill && id_ex1_q.tag == f) begin
                    q_valid[f]<=0; q_ready[f]<=0; q_executed[f]<=0;
                end
                if (mdu_done && mdu_tag_q == f && q_valid[f]) begin
                    q_payload[f]<=multiply_result; q_ready[f]<=1;
                end
                if (mem_rsp_fire && !response_discard && response_tag == f && q_valid[f]) begin
                    q_payload[f]<=response_result_f; q_ready[f]<=1;
                end
            end
        end
    end endgenerate
    genvar mem_slot;
    generate for (mem_slot=0; mem_slot<N; mem_slot=mem_slot+1) begin : g_mem_request_slot
        always @(posedge clk) begin
            if (memq_push0 && id_ex0_q.tag == mem_slot)
                memq_requests_flat[mem_slot*71 +: 71] <= {id_ex0_q.tag, ex_result0.addr,
                    ex_result0.store_data, ex_result0.funct3, ex_result0.store};
            else if (memq_push1 && id_ex1_q.tag == mem_slot)
                memq_requests_flat[mem_slot*71 +: 71] <= {id_ex1_q.tag, ex_result1.addr,
                    ex_result1.store_data, ex_result1.funct3, ex_result1.store};
        end
    end endgenerate

    always @(posedge clk) begin
        if (rst || pipeline_clear || ex_redirect || branch_pair_kill) begin
            branch_pair_prev_valid_q<=0;
            branch_pair_prev_tag_q<=0;
        end else if (ex_slot_free) begin
            if (issue1 && fq_sidecar[0][4] && fq_sidecar[1][1] && fq_rd[1] != 0) begin
                branch_pair_prev_valid_q <= rename_valid_q[fq_rd[1]] &&
                    !retiring_source(fq_rd[1], rename_tag(fq_rd[1], rename_tags_q));
                branch_pair_prev_tag_q <= rename_tag(fq_rd[1], rename_tags_q);
            end else begin
                branch_pair_prev_valid_q<=0;
                branch_pair_prev_tag_q<=0;
            end
        end
    end
    always @(posedge clk) begin
        if (rst || pipeline_clear || ex_redirect) begin
            id_ex0_q<='0; id_ex1_q<='0;
        end else if (ex_slot_free) begin
            id_ex0_q<=intake0; id_ex1_q<=intake1;
        end else begin
            // WB snooping prevents an operand tag becoming stale when its
            // producer commits and that physical completion slot is reused.
            if (id_ex0_q.src1_pending && source_available(id_ex0_q.src1_tag)) begin
                id_ex0_q.ra<=source_value(id_ex0_q.src1_tag);
                id_ex0_q.src1_pending<=0;
            end
            if (id_ex0_q.src2_pending && source_available(id_ex0_q.src2_tag)) begin
                id_ex0_q.rb<=source_value(id_ex0_q.src2_tag);
                id_ex0_q.src2_pending<=0;
            end
            if (id_ex1_q.src1_pending && source_available(id_ex1_q.src1_tag)) begin
                id_ex1_q.ra<=source_value(id_ex1_q.src1_tag);
                id_ex1_q.src1_pending<=0;
            end
            if (id_ex1_q.src2_pending && source_available(id_ex1_q.src2_tag)) begin
                id_ex1_q.rb<=source_value(id_ex1_q.src2_tag);
                id_ex1_q.src2_pending<=0;
            end
        end
    end
    always @(posedge clk) begin
        if (rst || wb_flush) begin
            mem_wb0_q<='0; mem_wb1_q<='0;
        end else if (irq_boundary) begin
            mem_wb0_q<='0; mem_wb1_q<='0;
            mem_wb0_q.valid<=1; mem_wb0_q.trap<=1;
            mem_wb0_q.pc<=commit1 ? mem_wb1_q.next_pc : mem_wb0_q.next_pc;
            mem_wb0_q.cause<=csr_irq_cause;
        end else if (wb_hold1) begin
            mem_wb0_q<=mem_wb1_q; mem_wb1_q<='0;
        end else if (wb_response_direct) begin
            mem_wb0_q<=direct_response_result; mem_wb0_q.valid<=1'b1;
            mem_wb1_q<=visible1; mem_wb1_q.valid<=wb_response_direct_refill1;
        end else begin
            mem_wb0_q<=visible0; mem_wb0_q.valid<=wb_refill0;
            mem_wb1_q<=visible1; mem_wb1_q.valid<=wb_refill1;
        end
    end

    dual_retire_trace u_trace (
        .clk(clk), .rst(rst),
        .commit0_valid(commit0), .commit0_pc(mem_wb0_q.pc), .commit0_instr(mem_wb0_q.instr),
        .commit0_rd(cw0_rd), .commit0_rd_data(cw0_data), .commit0_rd_we(cw0_we),
        .commit0_trap(wb_trap), .commit0_cause(trap_cause),
        .commit1_valid(commit1), .commit1_pc(mem_wb1_q.pc), .commit1_instr(mem_wb1_q.instr),
        .commit1_rd(cw1_rd), .commit1_rd_data(cw1_data), .commit1_rd_we(cw1_we),
        .commit1_trap(1'b0), .commit1_cause(32'd0),
        .trace0_valid(trace0_valid), .trace0_order(trace0_order), .trace0_pc(trace0_pc),
        .trace0_instr(trace0_instr), .trace0_rd(trace0_rd), .trace0_rd_data(trace0_rd_data),
        .trace0_rd_we(trace0_rd_we), .trace0_trap(trace0_trap), .trace0_cause(trace0_cause),
        .trace1_valid(trace1_valid), .trace1_order(trace1_order), .trace1_pc(trace1_pc),
        .trace1_instr(trace1_instr), .trace1_rd(trace1_rd), .trace1_rd_data(trace1_rd_data),
        .trace1_rd_we(trace1_rd_we), .trace1_trap(trace1_trap), .trace1_cause(trace1_cause)
    );
endmodule

