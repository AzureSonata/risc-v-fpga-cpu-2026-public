// ============================================================================
//        PC 寄存器模块 — 单元测试
//        覆盖：复位、顺序+4、重定向、暂停、优先级
// ============================================================================

`timescale 1ns / 1ps

`include "defines.sv"

module tb_pc_reg;

    reg         clk;
    reg         rst;
    reg         redirect_valid;
    reg  [31:0] redirect_target;
    reg         hold_pc;
    reg         advance_valid;
    wire [31:0] pc;

    // DUT
    pc_reg u_pc_reg (
        .clk             (clk),
        .rst             (rst),
        .redirect_valid  (redirect_valid),
        .redirect_target (redirect_target),
        .advance_valid   (advance_valid),
        .hold_pc         (hold_pc),
        .pred_valid(1'b0), .pred_target(32'b0),
        .pc              (pc)
    );

    // Clock: 10 ns period
    always #5 clk = ~clk;

    // Test sequence
    integer errors;
    initial begin
        $display("==========================================");
        $display("  PC Register Unit Test");
        $display("==========================================");
        errors = 0;

        // Initialize
        clk = 0;
        rst = `RstEnable;
        redirect_valid = `False;
        redirect_target = 32'h0;
        hold_pc = `False;

        // ---- Test 1: Reset ----
        // Check PC = 0 right after first posedge while rst still active
        @(posedge clk);
        #1;
        if (pc !== 32'h00000000) begin
            $display("FAIL Test 1: Reset — expected 00000000, got %08h", pc);
            errors = errors + 1;
        end else begin
            $display("PASS Test 1: Reset — PC = %08h", pc);
        end

        // Deassert reset
        @(negedge clk);
        rst = `RstDisable;
        advance_valid = `True;

        // ---- Test 2: Sequential PC+4 ----
        repeat (3) begin
            @(posedge clk);
            #1;
            $display("    PC = %08h (checking +4)", pc);
        end
        if (pc === 32'h0000000c) begin
            $display("PASS Test 2: Sequential +4 — PC = %08h", pc);
        end else begin
            $display("FAIL Test 2: Sequential +4 — expected 0000000c, got %08h", pc);
            errors = errors + 1;
        end

        // ---- Test 3: Redirect ----
        redirect_target = 32'h00001000;
        @(negedge clk);
        redirect_valid = `True;
        @(posedge clk);
        #1;
        if (pc !== 32'h00001000) begin
            $display("FAIL Test 3a: Redirect — expected 00001000, got %08h", pc);
            errors = errors + 1;
        end else begin
            $display("PASS Test 3a: Redirect to 00001000 — PC = %08h", pc);
        end
        @(negedge clk);
        redirect_valid = `False;
        @(posedge clk);
        #1;
        if (pc !== 32'h00001004) begin
            $display("FAIL Test 3b: After redirect +4 — expected 00001004, got %08h", pc);
            errors = errors + 1;
        end else begin
            $display("PASS Test 3b: After redirect +4 — PC = %08h", pc);
        end

        // ---- Test 4: Hold ----
        hold_pc = `True;
        @(posedge clk);
        #1;
        if (pc !== 32'h00001004) begin
            $display("FAIL Test 4a: Hold — expected 00001004, got %08h", pc);
            errors = errors + 1;
        end else begin
            $display("PASS Test 4a: Hold — PC = %08h (unchanged)", pc);
        end
        @(posedge clk);
        #1;
        if (pc !== 32'h00001004) begin
            $display("FAIL Test 4b: Hold sustained — expected 00001004, got %08h", pc);
            errors = errors + 1;
        end else begin
            $display("PASS Test 4b: Hold sustained — PC = %08h (unchanged)", pc);
        end

        // ---- Test 5: Hold release ----
        hold_pc = `False;
        @(posedge clk);
        #1;
        if (pc !== 32'h00001008) begin
            $display("FAIL Test 5a: Release hold — expected 00001008, got %08h", pc);
            errors = errors + 1;
        end else begin
            $display("PASS Test 5a: Release hold — PC = %08h", pc);
        end

        // ---- Test 6: Redirect overrides hold ----
        hold_pc = `True;
        redirect_target = 32'h00002000;
        @(negedge clk);
        redirect_valid = `True;
        @(posedge clk);
        #1;
        if (pc !== 32'h00002000) begin
            $display("FAIL Test 6: Redirect overrides hold — expected 00002000, got %08h", pc);
            errors = errors + 1;
        end else begin
            $display("PASS Test 6: Redirect overrides hold — PC = %08h", pc);
        end
        redirect_valid = `False;

        // ---- Summary ----
        $display("==========================================");
        if (errors == 0) begin
            $display("  ALL TESTS PASSED (%0d errors)", errors);
        end else begin
            $display("  %0d TEST(S) FAILED", errors);
        end
        $display("==========================================");
        $finish;
    end

    // Timeout: 500 ns
    initial begin
        #500;
        $display("TIMEOUT — Test did not finish in 500 ns");
        $finish;
    end

    // Dump VCD for GTKWave debugging
    initial begin
        $dumpfile("build/tb_pc_reg.vcd");
        $dumpvars(0, tb_pc_reg);
    end

endmodule