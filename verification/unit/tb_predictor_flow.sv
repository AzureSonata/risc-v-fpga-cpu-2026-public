// ============================================================================
//        branch_predictor 取指流集成测试
//        按 IF 规则 (next = hit&&taken ? target : pc+4) 推进取指地址流，
//        验证「预测 -> 取指地址序列 -> 预测错误后重训练 -> 序列变化」闭环。
// ============================================================================
`timescale 1ns / 1ps
`include "defines.sv"

module tb_predictor_flow;
    reg         clk, rst;
    reg         q_valid;  reg [31:0] q_pc;
    wire        q_hit, q_taken;  wire [31:0] q_target;
    reg         u_valid;  reg [31:0] u_pc;  reg u_taken;  reg [31:0] u_target;
    reg         u_pred_taken;  reg [31:0] u_pred_target;
    reg         stat_clr;
    wire [31:0] stat_query, stat_hit, stat_mispredict;

    localparam [31:0] A = 32'h0000_2000;   // 分支
    localparam [31:0] T = 32'h0000_3000;   // A 的目标

    branch_predictor dut (
        .clk (clk), .rst (rst),
        .q_valid (q_valid), .q_pc (q_pc),
        .q_hit (q_hit), .q_taken (q_taken), .q_target (q_target),
        .u_valid (u_valid), .u_pc (u_pc), .u_taken (u_taken), .u_target (u_target),
        .u_exception (1'b0),
        .u_pred_taken (u_pred_taken), .u_pred_target (u_pred_target),
        .stat_clr (stat_clr), .stat_query (stat_query),
        .stat_hit (stat_hit), .stat_mispredict (stat_mispredict)
    );

    always #5 clk = ~clk;
    integer errors;  integer cycle;
    always @(posedge clk) cycle <= cycle + 1;

    reg [31:0] next_pc;

    // 按 IF 预测规则推进一步取指
    task fetch_step;
        input [31:0] pc;
        begin
            @(negedge clk); q_valid = 1'b1; q_pc = pc;
            #1;
            next_pc = (q_hit && q_taken) ? q_target : (pc + 32'd4);
            @(posedge clk); #1;
            @(negedge clk); q_valid = 1'b0;
        end
    endtask

    task do_update;
        input [31:0] pc; input taken; input [31:0] tgt;
        input ptaken; input [31:0] ptgt;
        begin
            @(negedge clk);
            u_valid=1'b1; u_pc=pc; u_taken=taken; u_target=tgt;
            u_pred_taken=ptaken; u_pred_target=ptgt;
            @(posedge clk); #1;
            u_valid=1'b0; u_pred_taken=1'b0; u_pred_target=32'b0;
        end
    endtask

    task stat_clear;
        begin
            @(negedge clk); stat_clr = 1'b1;
            @(posedge clk); #1;
            @(negedge clk); stat_clr = 1'b0;
        end
    endtask

    task chk;
        input cond; input [8*44-1:0] label;
        begin
            if (!cond) begin $display("FAIL [%0d] %0s", cycle, label); errors=errors+1; end
            else       $display("PASS [%0d] %0s", cycle, label);
        end
    endtask

    initial begin
        $display("==============================================");
        $display("  Predictor Fetch-Flow Integration Test");
        $display("==============================================");
        errors=0; cycle=0; clk=0; rst=`RstEnable;
        q_valid=0; q_pc=0;
        u_valid=0; u_pc=0; u_taken=0; u_target=0;
        u_pred_taken=0; u_pred_target=0; stat_clr=0;

        repeat (3) @(posedge clk);
        @(negedge clk); rst = `RstDisable;

        // 训练 A(taken) -> T
        do_update(A, 1'b1, T, 1'b0, 32'h0);

        $display("\n--- F1: predicted-taken address stream ---");
        fetch_step(A);
        chk(next_pc === T,        "fetch A -> predicted target T");
        fetch_step(T);
        chk(next_pc === T + 32'd4, "fetch T -> sequential T+4");
        fetch_step(T + 32'd4);
        chk(next_pc === T + 32'd8, "fetch T+4 -> sequential T+8");

        stat_clear;   // 只统计检索/恢复阶段
        $display("\n--- F2: EX reports not-taken, retrain, stream reverts ---");
        do_update(A, 1'b0, T, 1'b1, T);      // dir 10 -> 01
        fetch_step(A);
        chk(next_pc === A + 32'd4, "1st not-taken: A -> A+4");
        do_update(A, 1'b0, T, 1'b0, 32'h0);  // dir 01 -> 00
        fetch_step(A);
        chk(next_pc === A + 32'd4, "2nd not-taken: A -> A+4 (saturated)");

        $display("\n--- F3: retrain taken again ---");
        do_update(A, 1'b1, T, 1'b0, 32'h0);  // 00 -> 01
        fetch_step(A);
        chk(next_pc === A + 32'd4, "01 still not-taken");
        do_update(A, 1'b1, T, 1'b0, 32'h0);  // 01 -> 10
        fetch_step(A);
        chk(next_pc === T,        "10 -> predicted target T again");

        $display("\n--- F4: stats ---");
        chk(stat_query > 32'd0,    "stat_query counted fetches");
        chk(stat_hit > 32'd0,      "stat_hit counted hits");
        chk(stat_mispredict === 32'd3, "three direction mispredicts recorded");

        $display("\n==============================================");
        if (errors==0) $display("  ALL TESTS PASSED");
        else           $display("  %0d TEST(S) FAILED", errors);
        $display("==============================================");
        $finish;
    end

    initial begin #5000; $display("TIMEOUT"); $finish; end
    initial begin $dumpfile("build/tb_predictor_flow.vcd"); $dumpvars(0, tb_predictor_flow); end
endmodule
