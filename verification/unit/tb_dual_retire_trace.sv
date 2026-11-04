`timescale 1ns/1ps
`include "defines.sv"

module tb_dual_retire_trace;
    reg clk = 1'b0;
    reg rst = `RstEnable;
    always #5 clk = ~clk;

    reg commit0_valid, commit0_rd_we, commit0_trap;
    reg [31:0] commit0_pc, commit0_instr, commit0_rd_data, commit0_cause;
    reg [4:0] commit0_rd;
    reg commit1_valid, commit1_rd_we, commit1_trap;
    reg [31:0] commit1_pc, commit1_instr, commit1_rd_data, commit1_cause;
    reg [4:0] commit1_rd;

    wire trace0_valid, trace1_valid;
    wire [63:0] trace0_order, trace1_order;
    wire [31:0] trace0_pc, trace0_instr, trace0_rd_data, trace0_cause;
    wire [31:0] trace1_pc, trace1_instr, trace1_rd_data, trace1_cause;
    wire [4:0] trace0_rd, trace1_rd;
    wire trace0_rd_we, trace0_trap, trace1_rd_we, trace1_trap;

    dual_retire_trace dut (.*);

    integer pass_count = 0, fail_count = 0;
    task check(input condition, input [1023:0] message);
        begin
            if (condition) begin pass_count = pass_count + 1; $display("PASS: %0s", message); end
            else begin fail_count = fail_count + 1; $display("FAIL: %0s", message); end
        end
    endtask

    task idle;
        begin
            commit0_valid=0; commit0_rd_we=0; commit0_trap=0; commit0_pc=0; commit0_instr=0; commit0_rd=0; commit0_rd_data=0; commit0_cause=0;
            commit1_valid=0; commit1_rd_we=0; commit1_trap=0; commit1_pc=0; commit1_instr=0; commit1_rd=0; commit1_rd_data=0; commit1_cause=0;
        end
    endtask

    initial begin
        idle(); repeat (3) @(posedge clk); #1; rst = `RstDisable; @(posedge clk); #1;
        idle(); @(posedge clk); #1;
        check(trace0_valid==0 && trace1_valid==0, "no commit -> no trace");

        // Two events in one cycle: order 0 and 1.
        @(negedge clk);
        commit0_valid=1; commit0_pc=32'h1000; commit0_instr=32'h13; commit0_rd=1; commit0_rd_data=32'h11; commit0_rd_we=1;
        commit1_valid=1; commit1_pc=32'h1004; commit1_instr=32'h33; commit1_rd=2; commit1_rd_data=32'h22; commit1_rd_we=1;
        @(posedge clk); #1;
        check(trace0_valid==1 && trace1_valid==1, "dual trace channels registered");
        check(trace0_order==0 && trace1_order==1, "dual trace order 0/1");
        check(trace0_pc==32'h1000 && trace1_pc==32'h1004, "dual trace payloads");

        // One event next cycle: order 2.
        @(negedge clk); idle();
        commit0_valid=1; commit0_pc=32'h2000; commit0_instr=32'h03; commit0_rd=3; commit0_rd_data=32'h33; commit0_rd_we=1;
        @(posedge clk); #1;
        check(trace0_valid==1 && trace1_valid==0, "single trace event");
        check(trace0_order==2, "order advances by number of committed events");

        // Trap event is still a retirement event.
        @(negedge clk); idle();
        commit0_valid=1; commit0_trap=1; commit0_pc=32'h3000; commit0_cause=32'd2;
        @(posedge clk); #1;
        check(trace0_valid==1 && trace0_trap==1 && trace0_cause==32'd2, "trap retirement trace");

        if (fail_count == 0)
            $display("ALL TESTS PASSED (dual_retire_trace: %0d checks)", pass_count);
        else
            $display("DUAL_RETIRE_TRACE_RESULT: FAIL (%0d pass / %0d fail)", pass_count, fail_count);
        $finish;
    end
endmodule
