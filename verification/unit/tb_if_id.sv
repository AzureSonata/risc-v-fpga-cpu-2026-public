// ============================================================================
//        IF/ID 级间寄存器 — 单元测试
//        覆盖：正常锁存、暂停保持、冲刷清空、复位
// ============================================================================

`timescale 1ns / 1ps

`include "defines.sv"

module tb_if_id;

    reg         clk;
    reg         rst;
    reg         if_valid_i;
    reg  [31:0] if_pc_i;
    reg  [31:0] if_inst_i;
    reg         if_fault_i;
    reg         hold_if_id;
    reg         flush_if_id;
    wire        id_valid_o;
    wire [31:0] id_pc_o;
    wire [31:0] id_inst_o;
    wire        id_fault_o;

    if_id u_if_id (
        .clk        (clk),
        .rst        (rst),
        .if_valid_i (if_valid_i),
        .if_pc_i    (if_pc_i),
        .if_inst_i  (if_inst_i),
        .if_fault_i (if_fault_i),
        .hold_if_id (hold_if_id),
        .flush_if_id(flush_if_id),
        .id_valid_o (id_valid_o),
        .id_pc_o    (id_pc_o),
        .id_inst_o  (id_inst_o),
        .id_fault_o (id_fault_o)
    );

    always #5 clk = ~clk;

    integer errors;
    initial begin
        $display("==========================================");
        $display("  IF/ID Pipeline Register Test");
        $display("==========================================");
        errors = 0;

        clk = 0;
        rst = `RstEnable;
        if_valid_i = 1'b0;
        if_pc_i = 32'h0;
        if_inst_i = 32'h0;
        if_fault_i = 1'b0;
        hold_if_id = `False;
        flush_if_id = `False;

        // Test 1: Reset
        @(negedge clk);
        rst = `RstDisable;
        @(posedge clk); #1;
        if (id_valid_o !== 1'b0) begin
            $display("FAIL Test 1: Reset - id_valid not 0");
            errors = errors + 1;
        end else $display("PASS Test 1: Reset");

        // Test 2: Normal capture
        if_valid_i = 1'b1;
        if_pc_i = 32'h1000;
        if_inst_i = 32'h00000013;  // NOP
        @(posedge clk); #1;
        if (id_valid_o !== 1'b1 || id_pc_o !== 32'h1000 || id_inst_o !== 32'h00000013) begin
            $display("FAIL Test 2: Normal capture - got valid=%b pc=%08h inst=%08h",
                      id_valid_o, id_pc_o, id_inst_o);
            errors = errors + 1;
        end else $display("PASS Test 2: Normal capture");

        // Test 3: Hold
        hold_if_id = `True;
        if_pc_i = 32'h2000;
        @(posedge clk); #1;
        if (id_pc_o !== 32'h1000) begin
            $display("FAIL Test 3: Hold - expected pc=1000 got %08h", id_pc_o);
            errors = errors + 1;
        end else $display("PASS Test 3: Hold");
        hold_if_id = `False;

        // Test 4: Flush
        flush_if_id = `True;
        if_valid_i = 1'b1;
        if_pc_i = 32'h3000;
        @(posedge clk); #1;
        if (id_valid_o !== 1'b0) begin
            $display("FAIL Test 4: Flush - id_valid not 0");
            errors = errors + 1;
        end else $display("PASS Test 4: Flush");
        flush_if_id = `False;

        // Test 5: Recovery after flush
        if_valid_i = 1'b1;
        if_pc_i = 32'h4000;
        @(posedge clk); #1;
        if (id_valid_o !== 1'b1 || id_pc_o !== 32'h4000) begin
            $display("FAIL Test 5: Recovery - got pc=%08h", id_pc_o);
            errors = errors + 1;
        end else $display("PASS Test 5: Recovery after flush");

        // Summary
        $display("==========================================");
        if (errors == 0) $display("  ALL TESTS PASSED");
        else $display("  %0d TEST(S) FAILED", errors);
        $display("==========================================");
        $finish;
    end

    initial begin
        #500;
        $display("TIMEOUT");
        $finish;
    end

    initial begin
        $dumpfile("build/tb_if_id.vcd");
        $dumpvars(0, tb_if_id);
    end
endmodule