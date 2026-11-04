`timescale 1ns/1ps
`include "defines.sv"

// Core-level branch-predictor contract test.
// Architectural expectations below are derived from the hand-assembled
// program, independent of DUT predictor state:
//   * the BEQ at 0x04 is taken once, then not taken on its second visit;
//   * after the first outcome trains the BTB, the second outcome is predicted
//     taken and must redirect to the fall-through instruction at 0x08;
//   * the target instruction at 0x10 retires exactly once, so a younger
//     instruction from the second, mispredicted target cannot retire;
//   * PC 0x104 is a non-control ADDI aliasing PC 0x004 in BTB index 1 but has
//     a different tag. It must not receive a taken prediction or redirect.
module tb_dual_full_predictor_recovery;
    reg clk = 1'b0;
    reg rst = `RstEnable;
    always #5 clk = ~clk;

    wire i_req_valid, i_req_ready;
    wire [31:0] i_req_addr;
    wire i_rsp_valid, i_rsp_ready;
    wire [63:0] i_rsp_data;
    wire d_req_valid, d_req_ready, d_req_write;
    wire [31:0] d_req_addr, d_req_wdata;
    wire [3:0] d_req_wstrb;
    wire d_rsp_valid, d_rsp_ready;
    wire [31:0] d_rsp_rdata;
    wire d_rsp_error = 1'b0;

    wire issue0, issue1, retire0_valid, retire1_valid;
    wire trace0_valid, trace1_valid, trace0_trap, trace1_trap;
    wire [63:0] trace0_order, trace1_order;
    wire [31:0] trace0_pc, trace1_pc;

    reg [31:0] prog [0:511];
    reg [63:0] imem [0:255];
    reg i_rsp_valid_q = 1'b0;
    reg [63:0] i_rsp_data_q = 64'b0;
    integer i;

    integer first_taken_redirects = 0;
    integer trained_reverse_redirects = 0;
    integer alias_lookups = 0;
    integer noncontrol_alias_predictions = 0;
    integer noncontrol_alias_redirects = 0;
    integer target_retire_count = 0;
    integer retire_seen = 0;
    integer taken_branch_pair_issues = 0;
    integer taken_branch_pair_squashes = 0;
    integer nottaken_branch_pair_issues = 0;
    integer nottaken_branch_pair_retires = 0;
    reg [31:0] expected_pc [0:12];

    assign i_req_ready = 1'b1;
    assign i_rsp_valid = i_rsp_valid_q;
    assign i_rsp_data = i_rsp_data_q;
    assign d_req_ready = 1'b1;
    assign d_rsp_valid = 1'b0;
    assign d_rsp_rdata = 32'b0;

    function [31:0] enc_i;
        input integer imm;
        input [4:0] rs1;
        input [2:0] funct3;
        input [4:0] rd;
        input [6:0] opcode;
        reg [11:0] off;
        begin
            off = imm[11:0];
            enc_i = {off, rs1, funct3, rd, opcode};
        end
    endfunction

    function [31:0] enc_b;
        input integer imm;
        input [4:0] rs2;
        input [4:0] rs1;
        input [2:0] funct3;
        reg [12:0] off;
        begin
            off = imm[12:0];
            enc_b = {off[12], off[10:5], rs2, rs1, funct3,
                     off[4:1], off[11], 7'b1100011};
        end
    endfunction

    function [31:0] enc_j;
        input integer imm;
        input [4:0] rd;
        reg [20:0] off;
        begin
            off = imm[20:0];
            enc_j = {off[20], off[10:1], off[11], off[19:12], rd, 7'h6f};
        end
    endfunction

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            i_rsp_valid_q <= 1'b0;
            i_rsp_data_q <= 64'b0;
        end else if (i_req_valid && i_req_ready) begin
            i_rsp_valid_q <= 1'b1;
            i_rsp_data_q <= imem[i_req_addr[31:3]];
        end else if (i_rsp_valid && i_rsp_ready) begin
            i_rsp_valid_q <= 1'b0;
        end
    end

    dual_issue_full_core #(
        .DUAL_ISSUE_EN(1'b1),
        .PREDICT_ENABLE(1'b1)
    ) dut (
        .clk(clk), .rst(rst),
        .i_req_valid(i_req_valid), .i_req_ready(i_req_ready),
        .i_req_addr(i_req_addr), .i_rsp_valid(i_rsp_valid),
        .i_rsp_ready(i_rsp_ready), .i_rsp_data(i_rsp_data), .i_rsp_error(2'b00),
        .d_req_valid(d_req_valid), .d_req_ready(d_req_ready),
        .d_req_addr(d_req_addr), .d_req_write(d_req_write),
        .d_req_wdata(d_req_wdata), .d_req_wstrb(d_req_wstrb),
        .d_rsp_valid(d_rsp_valid), .d_rsp_ready(d_rsp_ready),
        .d_rsp_rdata(d_rsp_rdata), .d_rsp_error(d_rsp_error),
        .timer_irq_i(1'b0), .ext_irq_i(1'b0),
        .issue0(issue0), .issue1(issue1),
        .retire0_valid(retire0_valid), .retire1_valid(retire1_valid),
        .trace0_valid(trace0_valid), .trace0_order(trace0_order),
        .trace0_pc(trace0_pc), .trace0_instr(), .trace0_rd(),
        .trace0_rd_data(), .trace0_rd_we(), .trace0_trap(trace0_trap),
        .trace0_cause(),
        .trace1_valid(trace1_valid), .trace1_order(trace1_order),
        .trace1_pc(trace1_pc), .trace1_instr(), .trace1_rd(),
        .trace1_rd_data(), .trace1_rd_we(), .trace1_trap(trace1_trap),
        .trace1_cause(), .pc_debug()
    );

    // Check redirect causes at the resolving instruction, before its trace
    // record is registered. The second BEQ must have carried a taken BTB hit.
    always @(posedge clk) begin
        if (rst == `RstDisable) begin
            if (dut.branch_redirect && dut.r0_pc_q == 32'h0000_0004 &&
                dut.ex0_branch_request && dut.ex0_branch_taken)
                first_taken_redirects = first_taken_redirects + 1;

            if (dut.branch_redirect && dut.r0_pc_q == 32'h0000_0004 &&
                dut.ex0_branch_request && !dut.ex0_branch_taken &&
                dut.r0_pred_valid_q && dut.r0_pred_taken_q)
                trained_reverse_redirects = trained_reverse_redirects + 1;

            if (dut.r0_pc_q == 32'h0000_0104 && dut.r0_pred_valid_q &&
                dut.r0_pred_taken_q)
                noncontrol_alias_predictions = noncontrol_alias_predictions + 1;

            if (dut.branch_redirect && dut.r0_pc_q == 32'h0000_0104 &&
                !dut.ex0_branch_request)
                noncontrol_alias_redirects = noncontrol_alias_redirects + 1;

            if (dut.issue0 && dut.issue1 && dut.fq_out0_pc == 32'h0000_0004 &&
                dut.fq_out1_pc == 32'h0000_0008)
                taken_branch_pair_issues = taken_branch_pair_issues + 1;

            // A taken branch predicted sequentially must retire alone. The
            // paired ADDI is already in EX, so check every architectural path
            // that could otherwise leak the wrong-path result.
            if (dut.branch_redirect && dut.r0_pc_q == 32'h0000_0004 &&
                dut.r1_pc_q == 32'h0000_0008 && dut.alu_w1_valid) begin
                if (!dut.commit0_fire || dut.commit1_fire || dut.cw1_we ||
                    dut.w1_bypass_we)
                    $fatal(1, "FAIL taken-branch pair was not fully squashed at commit");
                taken_branch_pair_squashes = taken_branch_pair_squashes + 1;
            end

            if (dut.issue0 && dut.issue1 && dut.fq_out0_pc == 32'h0000_0108 &&
                dut.fq_out1_pc == 32'h0000_010c)
                nottaken_branch_pair_issues = nottaken_branch_pair_issues + 1;

            if (dut.r0_pc_q == 32'h0000_0108 && dut.alu_w0_valid &&
                dut.ex0_branch_request && !dut.ex0_branch_taken) begin
                if (dut.branch_redirect || !dut.commit0_fire || !dut.commit1_fire ||
                    dut.r1_pc_q != 32'h0000_010c)
                    $fatal(1, "FAIL correct sequential branch+ALU pair did not retire together");
                nottaken_branch_pair_retires = nottaken_branch_pair_retires + 1;
            end

            // At request PC 0x100, the second lookup is PC 0x104. Both map to
            // BTB index 1 as PC 0x004, but their tags differ (0 vs 1).
            if (dut.u_fetch.req_fire && dut.u_fetch.pc_q == 32'h0000_0100) begin
                alias_lookups = alias_lookups + 1;
                if (dut.u_fetch.g_predictor.u_predictor.valid[1] !== 1'b1 ||
                    dut.u_fetch.g_predictor.u_predictor.tag[1] !== 24'd0 ||
                    dut.u_fetch.g_predictor.u_predictor.q1_idx !== 6'd1 ||
                    dut.u_fetch.g_predictor.u_predictor.q1_tag !== 24'd1 ||
                    dut.u_fetch.bp_q1_hit !== 1'b0)
                    $fatal(1, "FAIL BTB alias contract: trained entry/index/tag/query mismatch");
            end
        end
    end

    // Retire stream expected from the hand-written program. trace0 is older
    // than trace1; order numbers must be contiguous and PCs must match exactly.
    task check_retire;
        input [63:0] order;
        input [31:0] pc;
        begin
            if (order !== retire_seen)
                $fatal(1, "FAIL trace order got=%0d expected=%0d", order, retire_seen);
            if (retire_seen < 13 && pc !== expected_pc[retire_seen])
                $fatal(1, "FAIL retire PC[%0d] got=%08x expected=%08x",
                       retire_seen, pc, expected_pc[retire_seen]);
            if (pc == 32'h0000_0010)
                target_retire_count = target_retire_count + 1;
            retire_seen = retire_seen + 1;
        end
    endtask

    always @(negedge clk) begin
        if (rst == `RstDisable) begin
            if (trace0_valid) begin
                if (trace0_trap) $fatal(1, "FAIL unexpected trap at PC %08x", trace0_pc);
                check_retire(trace0_order, trace0_pc);
            end
            if (trace1_valid) begin
                if (trace1_trap) $fatal(1, "FAIL unexpected younger-slot trap at PC %08x", trace1_pc);
                check_retire(trace1_order, trace1_pc);
            end
        end
    end

    initial begin
        for (i = 0; i < 512; i = i + 1)
            prog[i] = 32'h0000_0013; // ADDI x0,x0,0
        for (i = 0; i < 256; i = i + 1)
            imem[i] = 64'h0000_0013_0000_0013;

        // First BEQ is taken on x1=0. The target increments x3 and sets x1=1,
        // then JAL revisits the same BEQ. On that visit the BTB predicts taken,
        // while the architectural result is not taken.
        prog[0] = enc_i(0, 0, 3'b000, 1, 7'h13);       // 0x000: x1 = 0
        prog[1] = enc_b(12, 0, 1, 3'b000);             // 0x004: BEQ x1,x0,0x010
        prog[2] = enc_i(7, 0, 3'b000, 2, 7'h13);       // 0x008: x2 = 7
        prog[3] = enc_j(244, 0);                       // 0x00c: JAL to 0x100
        prog[4] = enc_i(1, 3, 3'b000, 3, 7'h13);       // 0x010: x3 = x3 + 1
        prog[5] = enc_i(1, 0, 3'b000, 1, 7'h13);       // 0x014: x1 = 1
        prog[6] = enc_j(-20, 0);                       // 0x018: JAL back to 0x004
        prog[64] = enc_i(70, 0, 3'b000, 7, 7'h13);    // 0x100: x7 = 70
        prog[65] = enc_i(42, 0, 3'b000, 6, 7'h13);    // 0x104: alias, x6 = 42
        prog[66] = enc_b(8, 0, 1, 3'b000);             // 0x108: BEQ x1,x0,0x110 (not taken)
        prog[67] = enc_i(99, 0, 3'b000, 9, 7'h13);    // 0x10c: paired sequential ALU
        prog[68] = enc_j(0, 0);                        // 0x110: stable terminal loop

        expected_pc[0] = 32'h0000_0000;
        expected_pc[1] = 32'h0000_0004;
        expected_pc[2] = 32'h0000_0010;
        expected_pc[3] = 32'h0000_0014;
        expected_pc[4] = 32'h0000_0018;
        expected_pc[5] = 32'h0000_0004;
        expected_pc[6] = 32'h0000_0008;
        expected_pc[7] = 32'h0000_000c;
        expected_pc[8] = 32'h0000_0100;
        expected_pc[9] = 32'h0000_0104;
        expected_pc[10] = 32'h0000_0108;
        expected_pc[11] = 32'h0000_010c;
        expected_pc[12] = 32'h0000_0110;

        for (i = 0; i < 256; i = i + 1)
            imem[i] = {prog[2*i + 1], prog[2*i]};

        repeat (3) @(posedge clk);
        #1 rst = `RstDisable;
        repeat (300) @(posedge clk);
        #1;

        if (first_taken_redirects < 1)
            $fatal(1, "FAIL initial taken branch did not recover from not-taken prediction");
        if (trained_reverse_redirects != 1)
            $fatal(1, "FAIL trained opposite-direction recovery count=%0d expected=1",
                   trained_reverse_redirects);
        if (alias_lookups < 1 || noncontrol_alias_predictions != 0 ||
            noncontrol_alias_redirects != 0)
            $fatal(1, "FAIL BTB alias check lookups=%0d metadata=%0d redirects=%0d",
                   alias_lookups, noncontrol_alias_predictions, noncontrol_alias_redirects);
        if (retire_seen < 13 || target_retire_count != 1)
            $fatal(1, "FAIL retire stream count=%0d target retires=%0d",
                   retire_seen, target_retire_count);
        if (taken_branch_pair_issues != 1 || taken_branch_pair_squashes != 1 ||
            nottaken_branch_pair_issues != 1 || nottaken_branch_pair_retires != 1)
            $fatal(1, "FAIL branch-pair issue/squash/retire counts taken=%0d/%0d nottaken=%0d/%0d",
                   taken_branch_pair_issues, taken_branch_pair_squashes,
                   nottaken_branch_pair_issues, nottaken_branch_pair_retires);
        if (dut.u_rf.regs[1] !== 32'd1 || dut.u_rf.regs[2] !== 32'd7 ||
            dut.u_rf.regs[3] !== 32'd1 || dut.u_rf.regs[6] !== 32'd42 ||
            dut.u_rf.regs[7] !== 32'd70 || dut.u_rf.regs[9] !== 32'd99)
            $fatal(1, "FAIL architectural state x1=%0d x2=%0d x3=%0d x6=%0d x7=%0d x9=%0d",
                   dut.u_rf.regs[1], dut.u_rf.regs[2], dut.u_rf.regs[3],
                   dut.u_rf.regs[6], dut.u_rf.regs[7], dut.u_rf.regs[9]);

        $display("OBS: initial_taken_redirects=%0d trained_reverse_redirects=%0d alias_lookups=%0d target_retires=%0d retire_seen=%0d taken_pair=%0d/%0d nottaken_pair=%0d/%0d",
                 first_taken_redirects, trained_reverse_redirects,
                 alias_lookups, target_retire_count, retire_seen,
                 taken_branch_pair_issues, taken_branch_pair_squashes,
                 nottaken_branch_pair_issues, nottaken_branch_pair_retires);
        $display("PASS: committed retire stream matches ISA path; trained opposite outcome redirects; no younger wrong-path retirement; BTB tag alias filtered");
        $display("ALL TESTS PASSED (dual_full_predictor_recovery)");
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "FAIL timeout");
    end
endmodule
