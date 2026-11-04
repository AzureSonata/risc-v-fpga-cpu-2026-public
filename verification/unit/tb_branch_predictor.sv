// ============================================================================
//        branch_predictor 单元测试
//        覆盖：复位 / 分配 / 2-bit 饱和方向训练 / 目标刷新 /
//              直接映射标签替换 / 预测错误计数 / 统计
// ============================================================================
`timescale 1ns / 1ps
`include "defines.sv"

module tb_branch_predictor;
    reg         clk, rst;
    reg         q_valid;  reg [31:0] q_pc;
    wire        q_hit, q_taken;  wire [31:0] q_target;
    reg         u_valid;  reg [31:0] u_pc;  reg u_taken;  reg [31:0] u_target;
    reg         u_pred_taken;  reg [31:0] u_pred_target;
    reg         stat_clr;
    wire [31:0] stat_query, stat_hit, stat_mispredict;

    localparam [31:0] BR1 = 32'h0000_2000;  // index 0, tag 0x20
    localparam [31:0] BR2 = 32'h0000_2100;  // index 0, tag 0x21 (alias BR1)
    localparam [31:0] BR3 = 32'h0000_0010;  // index 4, tag 0x00

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

    task qcheck;
        input [31:0] pc; input ehit; input etaken; input [31:0] etgt;
        input [8*36-1:0] label;
        begin
            q_valid=1'b1; q_pc=pc; #1;
            if ((q_hit!==ehit)||(q_taken!==etaken)||(q_target!==etgt)) begin
                $display("FAIL [%0d] %0s: pc=%08h hit=%b taken=%b tgt=%08h (exp %b/%b/%08h)",
                         cycle,label,pc,q_hit,q_taken,q_target,ehit,etaken,etgt);
                errors=errors+1;
            end else begin
                $display("PASS [%0d] %0s: pc=%08h hit=%b taken=%b tgt=%08h",
                         cycle,label,pc,q_hit,q_taken,q_target);
            end
            q_valid=1'b0;
        end
    endtask

    task q_pulse;
        input [31:0] pc;
        begin
            @(negedge clk); q_valid=1'b1; q_pc=pc;
            @(posedge clk); #1;
            @(negedge clk); q_valid=1'b0;
        end
    endtask

    task stat_clear;
        begin
            @(negedge clk); stat_clr=1'b1;
            @(posedge clk); #1;
            @(negedge clk); stat_clr=1'b0;
        end
    endtask

    task chk;
        input cond; input [8*40-1:0] label;
        begin
            if (!cond) begin $display("FAIL [%0d] %0s", cycle, label); errors=errors+1; end
            else       $display("PASS [%0d] %0s", cycle, label);
        end
    endtask

    initial begin
        $display("==============================================");
        $display("  Branch Predictor (BTB + 2-bit) Unit Test");
        $display("==============================================");
        errors=0; cycle=0; clk=0; rst=`RstEnable;
        q_valid=0; q_pc=0;
        u_valid=0; u_pc=0; u_taken=0; u_target=0;
        u_pred_taken=0; u_pred_target=0; stat_clr=0;

        repeat (3) @(posedge clk);
        @(negedge clk); rst = `RstDisable;

        $display("\n--- T1: reset state ---");
        qcheck(BR1, 1'b0, 1'b0, 32'h0, "reset: no entry");
        chk(stat_query===32'd0,      "reset: stat_query=0");
        chk(stat_hit===32'd0,        "reset: stat_hit=0");
        chk(stat_mispredict===32'd0, "reset: stat_mispredict=0");

        $display("\n--- T2: allocate on taken branch ---");
        do_update(BR1, 1'b1, 32'h0000_3000, 1'b0, 32'h0);
        qcheck(BR1, 1'b1, 1'b1, 32'h0000_3000, "alloc taken -> hit/taken/tgt");

        $display("\n--- T3: direction saturates at 00 ---");
        do_update(BR1, 1'b0, 32'h0000_3000, 1'b1, 32'h0000_3000);
        qcheck(BR1, 1'b1, 1'b0, 32'h0000_3000, "1 not-taken: not-taken");
        do_update(BR1, 1'b0, 32'h0000_3000, 1'b1, 32'h0000_3000);
        qcheck(BR1, 1'b1, 1'b0, 32'h0000_3000, "2 not-taken: not-taken");
        do_update(BR1, 1'b0, 32'h0000_3000, 1'b1, 32'h0000_3000);
        qcheck(BR1, 1'b1, 1'b0, 32'h0000_3000, "saturated at 00");

        $display("\n--- T4: direction trains up ---");
        do_update(BR1, 1'b1, 32'h0000_3000, 1'b0, 32'h0);
        qcheck(BR1, 1'b1, 1'b0, 32'h0000_3000, "00->01 not-taken");
        do_update(BR1, 1'b1, 32'h0000_3000, 1'b0, 32'h0);
        qcheck(BR1, 1'b1, 1'b1, 32'h0000_3000, "01->10 predicted taken");

        $display("\n--- T5: target refreshes on taken hit ---");
        do_update(BR1, 1'b1, 32'h0000_4000, 1'b1, 32'h0000_3000);
        qcheck(BR1, 1'b1, 1'b1, 32'h0000_4000, "taken hit refreshes target");

        $display("\n--- T6: direct-mapped tag replacement ---");
        do_update(BR2, 1'b1, 32'h0000_5000, 1'b0, 32'h0);
        qcheck(BR2, 1'b1, 1'b1, 32'h0000_5000, "alias: new tag present");
        qcheck(BR1, 1'b0, 1'b0, 32'h0000_5000, "alias: old tag evicted");

        $display("\n--- T7: independent index unaffected ---");
        do_update(BR3, 1'b1, 32'h0000_6000, 1'b0, 32'h0);
        qcheck(BR3, 1'b1, 1'b1, 32'h0000_6000, "index 4 allocated");
        qcheck(BR2, 1'b1, 1'b1, 32'h0000_5000, "index 0 intact");

        $display("\n--- T8: statistics ---");
        stat_clear;
        q_pulse(BR2);            // hit
        q_pulse(BR2);            // hit
        q_pulse(BR3);            // hit
        q_pulse(32'h0000_3000);  // miss
        chk(stat_query===32'd4,      "stat_query=4");
        chk(stat_hit===32'd3,        "stat_hit=3");
        chk(stat_mispredict===32'd0, "stat_mispredict=0");

        do_update(BR2, 1'b1, 32'h0000_5000, 1'b0, 32'h0);            // dir mispredict
        do_update(BR2, 1'b1, 32'h0000_5000, 1'b1, 32'h0000_5000);    // correct
        do_update(BR2, 1'b1, 32'h0000_7777, 1'b1, 32'h0000_5000);    // target mispredict
        chk(stat_mispredict===32'd2, "stat_mispredict=2 (dir+target)");

        $display("\n==============================================");
        if (errors==0) $display("  ALL TESTS PASSED");
        else           $display("  %0d TEST(S) FAILED", errors);
        $display("==============================================");
        $finish;
    end

    initial begin #5000; $display("TIMEOUT"); $finish; end
    initial begin $dumpfile("build/tb_branch_predictor.vcd"); $dumpvars(0, tb_branch_predictor); end
endmodule
