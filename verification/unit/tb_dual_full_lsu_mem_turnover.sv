`timescale 1ns/1ps
`include "defines.sv"

// An independent younger load may handshake on the old load's response edge;
// a backpressured replacement must hold its request payload until accepted.
module tb_dual_full_lsu_mem_turnover;
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
    reg [31:0] d_pending_addr_q = 32'b0;
    reg [31:0] d_rsp_data_q = 32'b0;
    reg [1:0] deferred_wait_q = 2'd0;
    integer d_delay_q = 0;
    integer requests = 0, response_edge_turnovers = 0, retired = 0;
    integer turnover_offers = 0;
    integer deferred_captures = 0;
    integer deferred_wait_cycles = 0;
    integer i;
    reg [31:0] expected_pc [0:5];

    assign i_req_ready = 1'b1;
    assign i_rsp_valid = i_rsp_valid_q;
    assign i_rsp_data = i_rsp_data_q;
    // Hold the third request off for two cycles after it is first presented.
    // The LSU must capture it once and keep valid/address stable in REQ_WAIT.
    assign d_req_ready = !((requests == 2) && (deferred_wait_q < 2)) &&
                         (!d_rsp_valid_q || d_rsp_ready);
    assign d_rsp_valid = d_rsp_valid_q;
    assign d_rsp_rdata = d_rsp_data_q;

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            i_rsp_valid_q <= 1'b0;
            i_rsp_data_q <= 64'b0;
            d_rsp_valid_q <= 1'b0;
            d_pending_q <= 1'b0;
            d_pending_addr_q <= 32'b0;
            d_rsp_data_q <= 32'b0;
            deferred_wait_q <= 2'd0;
            d_delay_q <= 0;
        end else begin
            if (issue0 && dut.d0_is_mem &&
                ((dut.d0_uses_rs1 && dut.d0_ra !== dut.d0_mem_ra) ||
                 (dut.d0_uses_rs2 && dut.d0_rb !== dut.d0_mem_rb)))
                $fatal(1, "memory issued with an unresolved young-result dependency");
            if (i_req_valid && i_req_ready) begin
                i_rsp_valid_q <= 1'b1;
                i_rsp_data_q <= imem[i_req_addr[31:3]];
            end else if (i_rsp_valid && i_rsp_ready) begin
                i_rsp_valid_q <= 1'b0;
            end

            if (dut.u_lsu.turnover_request)
                turnover_offers <= turnover_offers + 1;

            if (d_req_valid && !d_req_ready) begin
                if (requests != 2 || d_req_addr != 32'h8000_0008 || d_req_write ||
                    d_req_wstrb != 4'b0000)
                    $fatal(1, "unexpected request under the injected backpressure");
                if (deferred_wait_q == 0)
                    deferred_captures <= deferred_captures + 1;
                deferred_wait_cycles <= deferred_wait_cycles + 1;
                deferred_wait_q <= deferred_wait_q + 1'b1;
            end

            if (d_rsp_valid_q && d_rsp_ready)
                d_rsp_valid_q <= 1'b0;
            if (d_req_valid && d_req_ready) begin
                if (d_pending_q)
                    $fatal(1, "accepted a second request before old response became valid");
                if (d_req_write)
                    $fatal(1, "unexpected store in load-turnover test");
                if (requests == 0 && d_req_addr != 32'h8000_0000)
                    $fatal(1, "first LSU address=%08x", d_req_addr);
                if (requests == 1 && d_req_addr != 32'h8000_0004)
                    $fatal(1, "turnover LSU address=%08x", d_req_addr);
                if (requests == 2 && d_req_addr != 32'h8000_0008)
                    $fatal(1, "deferred LSU address=%08x", d_req_addr);
                requests <= requests + 1;
                d_pending_addr_q <= d_req_addr;
                d_pending_q <= 1'b1;
                d_delay_q <= 2;
                if (d_rsp_valid_q && d_rsp_ready)
                    response_edge_turnovers <= response_edge_turnovers + 1;
            end else if (d_pending_q && d_delay_q != 0) begin
                d_delay_q <= d_delay_q - 1;
            end else if (d_pending_q && d_delay_q == 0) begin
                d_pending_q <= 1'b0;
                d_rsp_valid_q <= 1'b1;
                d_rsp_data_q <= (d_pending_addr_q == 32'h8000_0000)
                    ? 32'h1111_1111 : 32'h2222_2222;
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
                $fatal(1, "unexpected trap in LSU turnover test");
            if (order !== retired)
                $fatal(1, "trace order %0d expected %0d", order, retired);
            if (pc !== expected_pc[retired])
                $fatal(1, "retire PC[%0d]=%08x expected=%08x", retired, pc,
                       expected_pc[retired]);
            retired = retired + 1;
            if (retired == 6) begin
                if (requests != 3 || response_edge_turnovers != 1 || turnover_offers == 0 || deferred_captures != 1 ||
                    deferred_wait_cycles != 2)
                    $fatal(1, "request count wrong: requests=%0d edge=%0d turnover=%0d captured=%0d waits=%0d",
                           requests, response_edge_turnovers, turnover_offers, deferred_captures, deferred_wait_cycles);
                if (dut.u_rf.regs[1] !== 32'h1111_1111 ||
                    dut.u_rf.regs[2] !== 32'h2222_2222 ||
                    dut.u_rf.regs[3] !== 32'h8000_0008 ||
                    dut.u_rf.regs[5] !== 32'h2222_2222 ||
                    dut.u_rf.regs[6] !== 32'd9)
                    $fatal(1, "load/paired-ALU result wrong: x1=%08x x2=%08x x3=%08x",
                           dut.u_rf.regs[1], dut.u_rf.regs[2], dut.u_rf.regs[3]);
                $display("PASS: dual_full_lsu_mem_turnover requests=%0d edge_turnovers=%0d retired=%0d",
                         requests, response_edge_turnovers, retired);
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
        prog[0] = {20'h80000, 5'd10, 7'h37};        // 0x00: lui x10,0x80000
        prog[1] = {12'd0, 5'd10, 3'b010, 5'd1, 7'h03}; // 0x04: lw x1,0(x10)
        prog[2] = {12'd4, 5'd10, 3'b010, 5'd2, 7'h03}; // 0x08: lw x2,4(x10)
        prog[3] = {12'd8, 5'd10, 3'b000, 5'd3, 7'h13}; // 0x0c: addi x3,x10,8
        prog[4] = {12'd0, 5'd3, 3'b010, 5'd5, 7'h03}; // 0x10: lw x5,0(x3), dependent on paired lane1
        prog[5] = {12'd9, 5'd0, 3'b000, 5'd6, 7'h13}; // 0x14: addi x6,x0,9
        imem[0] = {prog[1], prog[0]};
        imem[1] = {prog[3], prog[2]};
        imem[2] = {prog[5], prog[4]};
        expected_pc[0] = 32'h0000_0000;
        expected_pc[1] = 32'h0000_0004;
        expected_pc[2] = 32'h0000_0008;
        expected_pc[3] = 32'h0000_000c;
        expected_pc[4] = 32'h0000_0010;
        expected_pc[5] = 32'h0000_0014;
        repeat (5) @(posedge clk);
        rst = `RstDisable;
        repeat (800) @(posedge clk);
        $fatal(1, "timeout waiting for LSU memory turnover test");
    end
endmodule
