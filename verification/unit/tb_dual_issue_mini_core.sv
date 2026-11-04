`timescale 1ns/1ps
`include "defines.sv"

module tb_dual_issue_mini_core;
    reg clk = 1'b0;
    reg rst = `RstEnable;
    always #5 clk = ~clk;

    wire        i_req_valid;
    reg         i_req_ready;
    wire [31:0] i_req_addr;
    reg         i_rsp_valid;
    wire        i_rsp_ready;
    reg  [63:0] i_rsp_data;
    wire        issue0, issue1;
    wire        retire0_valid, retire1_valid;
    wire        trace0_valid, trace1_valid;
    wire [63:0] trace0_order, trace1_order;
    wire [31:0] pc_debug;

    // 64-bit single-outstanding instruction memory.
    reg [63:0] imem [0:255];
    reg [31:0] prog [0:63];
    reg        rsp_valid_q;
    reg [63:0] rsp_data_q;
    integer i;

    assign i_req_ready = 1'b1;
    assign i_rsp_valid = rsp_valid_q;
    assign i_rsp_data  = rsp_data_q;

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            rsp_valid_q <= 1'b0;
            rsp_data_q  <= 64'h0;
        end else begin
            if (i_req_valid && i_req_ready) begin
                rsp_valid_q <= 1'b1;
                rsp_data_q  <= imem[i_req_addr[10:3]];
            end else if (i_rsp_valid && i_rsp_ready) begin
                rsp_valid_q <= 1'b0;
            end
        end
    end

`ifdef DUAL_ISSUE_OFF
    dual_issue_mini_core #(.DUAL_ISSUE_EN(1'b0)) dut (
`else
    dual_issue_mini_core #(.DUAL_ISSUE_EN(1'b1)) dut (
`endif
        .clk(clk), .rst(rst),
        .i_req_valid(i_req_valid), .i_req_ready(i_req_ready),
        .i_req_addr(i_req_addr), .i_rsp_valid(i_rsp_valid),
        .i_rsp_ready(i_rsp_ready), .i_rsp_data(i_rsp_data),
        .issue0(issue0), .issue1(issue1),
        .retire0_valid(retire0_valid), .retire1_valid(retire1_valid),
        .trace0_valid(trace0_valid), .trace0_order(trace0_order),
        .trace1_valid(trace1_valid), .trace1_order(trace1_order),
        .pc_debug(pc_debug)
    );

    integer cycles = 0;
    integer cycles_at_retire = 0;
    integer retired = 0;
    integer issue1_cycles = 0;
    integer trace_events = 0;
    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            cycles <= 0;
            retired <= 0;
            issue1_cycles <= 0;
            trace_events <= 0;
        end else begin
            cycles <= cycles + 1;
            retired <= retired + retire0_valid + retire1_valid;
            trace_events <= trace_events + trace0_valid + trace1_valid;
            if (issue1)
                issue1_cycles <= issue1_cycles + 1;
        end
    end

    integer j;
    integer local_fail = 0;
    initial begin
        for (i = 0; i < 64; i = i + 1)
            prog[i] = 32'h0000006F; // jal x0,0 padding
        for (i = 0; i < 64; i = i + 1)
            prog[i] = 32'h00000013 | ((i + 1) << 20) | (((i % 8) + 1) << 7);
        for (i = 0; i < 128; i = i + 1)
            imem[i] = {prog[2*i + 1], prog[2*i]};

        repeat (3) @(posedge clk);
        #1; rst = `RstDisable;

        wait ((retired >= 64) || (cycles >= 500));
        cycles_at_retire = cycles;
        repeat (3) @(posedge clk);
        #1;

        $display("MINI_CORE_DUAL=%0d CYCLES=%0d RETIRED=%0d ISSUE1_CYCLES=%0d",
`ifdef DUAL_ISSUE_OFF
                 0,
`else
                 1,
`endif
                 cycles_at_retire, retired, issue1_cycles);

        for (j = 1; j <= 8; j = j + 1) begin
            if (dut.u_rf.regs[j] !== (56 + j)) begin
                $display("FAIL: x%0d = %0d expected %0d", j, dut.u_rf.regs[j], 56 + j);
                local_fail = local_fail + 1;
            end
        end

        if (trace_events != 64) begin
            $display("FAIL: trace_events=%0d expected 64", trace_events);
            local_fail = local_fail + 1;
        end

        if (local_fail == 0 && retired >= 64) begin
            $display("PASS: 64 independent ALU instructions retired");
            $display("PASS: 8 register results match expected values");
            $display("PASS: dual retirement trace observed 64 events");
`ifdef DUAL_ISSUE_OFF
            if (issue1_cycles == 0) begin
                $display("PASS: single mode never issued lane1");
                $display("ALL TESTS PASSED (dual_issue_mini_core single mode)");
            end else begin
                $display("DUAL_ISSUE_MINI_RESULT: FAIL (single mode issued lane1)");
            end
`else
            if (issue1_cycles > 0) begin
                $display("PASS: dual mode issued lane1");
                $display("ALL TESTS PASSED (dual_issue_mini_core dual mode)");
            end else begin
                $display("DUAL_ISSUE_MINI_RESULT: FAIL (dual mode never issued lane1)");
            end
`endif
        end else begin
            $display("DUAL_ISSUE_MINI_RESULT: FAIL (%0d reg errors, retired=%0d)", local_fail, retired);
        end
        $finish;
    end

    initial begin
        #50000;
        $display("DUAL_ISSUE_MINI_RESULT: TIMEOUT cycles=%0d retired=%0d", cycles, retired);
        $finish;
    end
endmodule
