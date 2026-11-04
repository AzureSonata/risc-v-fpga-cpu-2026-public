`timescale 1ns/1ps
`include "defines.sv"

module tb_dual_issue_mini_branch;
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
    wire [31:0] trace0_pc, trace0_instr, trace0_rd_data, trace0_cause;
    wire [31:0] trace1_pc, trace1_instr, trace1_rd_data, trace1_cause;
    wire [4:0]  trace0_rd, trace1_rd;
    wire        trace0_rd_we, trace0_trap, trace1_rd_we, trace1_trap;
    wire [31:0] pc_debug;

    reg [31:0] imem32 [0:127];
    reg [63:0] imem64 [0:63];
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
                rsp_data_q  <= imem64[i_req_addr[9:3]];
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
        .trace0_pc(trace0_pc), .trace0_instr(trace0_instr),
        .trace0_rd(trace0_rd), .trace0_rd_data(trace0_rd_data),
        .trace0_rd_we(trace0_rd_we), .trace0_trap(trace0_trap),
        .trace0_cause(trace0_cause),
        .trace1_valid(trace1_valid), .trace1_order(trace1_order),
        .trace1_pc(trace1_pc), .trace1_instr(trace1_instr),
        .trace1_rd(trace1_rd), .trace1_rd_data(trace1_rd_data),
        .trace1_rd_we(trace1_rd_we), .trace1_trap(trace1_trap),
        .trace1_cause(trace1_cause),
        .pc_debug(pc_debug)
    );

    integer cycles = 0;
    integer retired = 0;
    integer trace_events = 0;
    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            cycles <= 0; retired <= 0; trace_events <= 0;
        end else begin
            cycles <= cycles + 1;
            retired <= retired + retire0_valid + retire1_valid;
            trace_events <= trace_events + trace0_valid + trace1_valid;
        end
    end

    integer j;
    integer local_fail = 0;
    reg [31:0] expected [1:6];
    initial begin
        expected[1]=1; expected[2]=0; expected[3]=3; expected[4]=0; expected[5]=5; expected[6]=6;
        $readmemh("verification/unit/dual_branch_program.hex", imem32);
        for (i = 0; i < 64; i = i + 1)
            imem64[i] = {imem32[2*i + 1], imem32[2*i]};

        repeat (3) @(posedge clk);
        #1; rst = `RstDisable;

        wait (((dut.u_rf.regs[5] == 5) && (dut.u_rf.regs[6] == 6)) || (cycles >= 500));
        repeat (3) @(posedge clk);
        #1;

        for (j = 1; j <= 6; j = j + 1) begin
            if (dut.u_rf.regs[j] !== expected[j]) begin
                $display("FAIL: x%0d = %0d expected %0d", j, dut.u_rf.regs[j], expected[j]);
                local_fail = local_fail + 1;
            end
        end
        if (retired < 6) begin
            $display("FAIL: retired=%0d expected at least 6", retired);
            local_fail = local_fail + 1;
        end
        if (trace_events < 6) begin
            $display("FAIL: trace_events=%0d expected at least 6", trace_events);
            local_fail = local_fail + 1;
        end

        if (local_fail == 0) begin
            $display("PASS: branch target executed, wrong-path x2/x4 stayed zero");
            $display("PASS: JAL target executed, retired/trace count >= 6");
            $display("ALL TESTS PASSED (dual_issue_mini_branch)");
        end else begin
            $display("DUAL_ISSUE_MINI_BRANCH_RESULT: FAIL (%0d errors)", local_fail);
        end
        $finish;
    end

    initial begin
        #30000;
        $display("DUAL_ISSUE_MINI_BRANCH_RESULT: TIMEOUT retired=%0d", retired);
        $finish;
    end
endmodule
