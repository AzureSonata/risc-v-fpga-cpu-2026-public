`timescale 1ns/1ps
`include "defines.sv"

// A branch and its sequential ALU successor may replace an older successful
// load on the load-response edge. A taken branch must cancel lane1 completely.
// A standalone JAL may also replace the completed load, then redirect cleanly.
module tb_dual_full_lsu_branch_pair;
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

    reg [31:0] prog [0:63];
    reg [63:0] imem [0:31];
    reg i_rsp_valid_q = 1'b0;
    reg [63:0] i_rsp_data_q = 64'b0;
    reg d_rsp_valid_q = 1'b0;
    reg d_pending_q = 1'b0;
    integer d_delay_q = 0;
    integer i;
    integer retired = 0;
    integer completion_branch_pair = 0;
    integer taken_pair_squashed = 0;
    integer completion_jal_solo = 0;
    integer jal_redirect = 0;
    reg [31:0] expected_pc [0:5];

    assign i_req_ready = 1'b1;
    assign i_rsp_valid = i_rsp_valid_q;
    assign i_rsp_data = i_rsp_data_q;
    assign d_req_ready = 1'b1;
    assign d_rsp_valid = d_rsp_valid_q;
    assign d_rsp_rdata = 32'h1234_5678;

    function [31:0] enc_i;
        input integer imm;
        input [4:0] rs1;
        input [2:0] funct3;
        input [4:0] rd;
        input [6:0] opcode;
        begin enc_i = {imm[11:0], rs1, funct3, rd, opcode}; end
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
            enc_j = {off[20], off[10:1], off[11], off[19:12], rd, 7'b1101111};
        end
    endfunction

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            i_rsp_valid_q <= 1'b0;
            i_rsp_data_q <= 64'b0;
            d_rsp_valid_q <= 1'b0;
            d_pending_q <= 1'b0;
            d_delay_q <= 0;
        end else begin
            if (i_req_valid && i_req_ready) begin
                i_rsp_valid_q <= 1'b1;
                i_rsp_data_q <= imem[i_req_addr[31:3]];
            end else if (i_rsp_valid && i_rsp_ready) begin
                i_rsp_valid_q <= 1'b0;
            end

            if (d_req_valid && d_req_ready && !d_pending_q && !d_rsp_valid_q) begin
                if (d_req_write) $fatal(1, "unexpected store request");
                d_pending_q <= 1'b1;
                d_delay_q <= 4;
            end else if (d_pending_q && d_delay_q != 0) begin
                d_delay_q <= d_delay_q - 1;
            end else if (d_pending_q && d_delay_q == 0) begin
                d_pending_q <= 1'b0;
                d_rsp_valid_q <= 1'b1;
            end
            if (d_rsp_valid_q && d_rsp_ready)
                d_rsp_valid_q <= 1'b0;

            if (dut.r0_mem_pending_q && dut.lsu_wb_valid &&
                dut.young_completion_replace && dut.issue0 && dut.issue1 &&
                dut.d0_branch_alu_pairable)
                completion_branch_pair <= completion_branch_pair + 1;

            if (dut.r0_mem_pending_q && dut.lsu_wb_valid &&
                dut.young_completion_replace && dut.issue0 && dut.d0_jal &&
                !dut.issue1)
                completion_jal_solo <= completion_jal_solo + 1;

            if (dut.branch_redirect && dut.r0_pc_q == 32'h0000_0004 &&
                dut.r1_pc_q == 32'h0000_0008 && dut.alu_w1_valid) begin
                if (!dut.commit0_fire || dut.commit1_fire || dut.cw1_we ||
                    dut.w1_bypass_we)
                    $fatal(1, "taken branch failed to squash paired lane1");
                taken_pair_squashed <= taken_pair_squashed + 1;
            end

            if (dut.branch_redirect && dut.r0_pc_q == 32'h0000_0014) begin
                if (!dut.commit0_fire || dut.commit1_fire || dut.cw1_we ||
                    dut.w1_bypass_we)
                    $fatal(1, "JAL response-edge replacement failed to redirect precisely");
                jal_redirect <= jal_redirect + 1;
            end
        end
    end

    dual_issue_full_core #(.DUAL_ISSUE_EN(1'b1), .PREDICT_ENABLE(1'b1)) dut (
        .clk(clk), .rst(rst),
        .i_req_valid(i_req_valid), .i_req_ready(i_req_ready), .i_req_addr(i_req_addr),
        .i_rsp_valid(i_rsp_valid), .i_rsp_ready(i_rsp_ready), .i_rsp_data(i_rsp_data),
        .i_rsp_error(2'b00),
        .d_req_valid(d_req_valid), .d_req_ready(d_req_ready), .d_req_addr(d_req_addr),
        .d_req_write(d_req_write), .d_req_wdata(d_req_wdata), .d_req_wstrb(d_req_wstrb),
        .d_rsp_valid(d_rsp_valid), .d_rsp_ready(d_rsp_ready),
        .d_rsp_rdata(d_rsp_rdata), .d_rsp_error(d_rsp_error),
        .timer_irq_i(1'b0), .ext_irq_i(1'b0), .issue0(issue0), .issue1(issue1),
        .retire0_valid(retire0_valid), .retire1_valid(retire1_valid),
        .trace0_valid(trace0_valid), .trace0_order(trace0_order),
        .trace0_pc(trace0_pc), .trace0_instr(), .trace0_rd(), .trace0_rd_data(),
        .trace0_rd_we(), .trace0_trap(trace0_trap), .trace0_cause(),
        .trace1_valid(trace1_valid), .trace1_order(trace1_order),
        .trace1_pc(trace1_pc), .trace1_instr(), .trace1_rd(), .trace1_rd_data(),
        .trace1_rd_we(), .trace1_trap(trace1_trap), .trace1_cause(), .pc_debug()
    );

    task check_retire;
        input [63:0] order;
        input [31:0] pc;
        begin
            if (trace0_trap || trace1_trap)
                $fatal(1, "unexpected trap in branch-pair test");
            if (order !== retired)
                $fatal(1, "trace order %0d expected %0d", order, retired);
            if (pc !== expected_pc[retired])
                $fatal(1, "retire PC[%0d]=%08x expected=%08x", retired, pc,
                       expected_pc[retired]);
            retired = retired + 1;
            if (retired == 6) begin
                if (completion_branch_pair != 1 || taken_pair_squashed != 1 ||
                    completion_jal_solo != 1 || jal_redirect != 1)
                    $fatal(1, "control replacement counts wrong: pair=%0d squash=%0d jal=%0d redirect=%0d",
                           completion_branch_pair, taken_pair_squashed,
                           completion_jal_solo, jal_redirect);
                if (dut.u_rf.regs[5] !== 32'b0 || dut.u_rf.regs[6] !== 32'd7 ||
                    dut.u_rf.regs[7] !== 32'd9)
                    $fatal(1, "wrong-path ALU leaked or target failed: x5=%08x x6=%08x x7=%08x",
                           dut.u_rf.regs[5], dut.u_rf.regs[6], dut.u_rf.regs[7]);
                $display("PASS: dual_full_lsu_branch_pair retired=%0d pair=%0d squashed=%0d jal=%0d redirect=%0d",
                         retired, completion_branch_pair, taken_pair_squashed,
                         completion_jal_solo, jal_redirect);
                $display("ALL TESTS PASSED");
                $finish;
            end
        end
    endtask

    always @(negedge clk) begin
        if (rst == `RstDisable) begin
            if (trace0_valid) check_retire(trace0_order, trace0_pc);
            if (trace1_valid) check_retire(trace1_order, trace1_pc);
        end
    end

    initial begin
        for (i = 0; i < 64; i = i + 1) prog[i] = 32'h0000_0013;
        for (i = 0; i < 32; i = i + 1) imem[i] = 64'h0000_0013_0000_0013;
        prog[0] = enc_i(0, 0, 3'b010, 1, 7'h03); // 0x00: lw x1,0(x0)
        prog[1] = enc_b(8, 0, 0, 3'b000);        // 0x04: beq x0,x0,0x0c
        prog[2] = enc_i(99, 0, 3'b000, 5, 7'h13);// 0x08: wrong-path x5=99
        prog[3] = enc_i(7, 0, 3'b000, 6, 7'h13); // 0x0c: target x6=7
        prog[4] = enc_i(0, 0, 3'b010, 2, 7'h03);// 0x10: lw x2,0(x0)
        prog[5] = enc_j(8, 0);                   // 0x14: jal x0,0x1c
        prog[6] = enc_i(99, 0, 3'b000, 5, 7'h13);// 0x18: wrong-path x5=99
        prog[7] = enc_i(9, 0, 3'b000, 7, 7'h13); // 0x1c: target x7=9
        imem[0] = {prog[1], prog[0]};
        imem[1] = {prog[3], prog[2]};
        imem[2] = {prog[5], prog[4]};
        imem[3] = {prog[7], prog[6]};
        expected_pc[0] = 32'h0000_0000;
        expected_pc[1] = 32'h0000_0004;
        expected_pc[2] = 32'h0000_000c;
        expected_pc[3] = 32'h0000_0010;
        expected_pc[4] = 32'h0000_0014;
        expected_pc[5] = 32'h0000_001c;
        repeat (5) @(posedge clk);
        rst = `RstDisable;
        repeat (500) @(posedge clk);
        $fatal(1, "timeout waiting for branch pair completion test");
    end
endmodule
