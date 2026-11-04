`timescale 1ns/1ps
`include "defines.sv"

module tb_dual_commit;
    reg        s0_valid, s0_trap, s0_writes_rd;
    reg [4:0]  s0_rd;
    reg [31:0] s0_data, s0_cause, s0_pc;
    reg        s1_valid, s1_trap, s1_writes_rd;
    reg [4:0]  s1_rd;
    reg [31:0] s1_data, s1_cause, s1_pc;
    wire commit0_fire, commit1_fire, trap_fire, flush_young, hold_s1;
    wire [31:0] trap_cause, trap_pc;
    wire w0_we, w1_we;
    wire [4:0] w0_rd, w1_rd;
    wire [31:0] w0_data, w1_data;
    dual_commit dut (.*);

    integer pass_count = 0, fail_count = 0;
    task check(input condition, input [1023:0] message);
        begin
            if (condition) begin pass_count = pass_count + 1; $display("PASS: %0s", message); end
            else begin fail_count = fail_count + 1; $display("FAIL: %0s", message); end
        end
    endtask

    task idle;
        begin
            s0_valid=0; s0_trap=0; s0_writes_rd=0; s0_rd=0; s0_data=0; s0_cause=0; s0_pc=0;
            s1_valid=0; s1_trap=0; s1_writes_rd=0; s1_rd=0; s1_data=0; s1_cause=0; s1_pc=0;
            #1;
        end
    endtask

    initial begin
        idle();
        check(commit0_fire==0 && commit1_fire==0, "no valid slots -> no commit");

        // Both normal: dual retirement and dual writeback.
        s0_valid=1; s0_writes_rd=1; s0_rd=1; s0_data=32'h11; s0_pc=32'h1000;
        s1_valid=1; s1_writes_rd=1; s1_rd=2; s1_data=32'h22; s1_pc=32'h1004; #1;
        check(commit0_fire==1 && commit1_fire==1, "normal pair commits both");
        check(w0_we==1 && w0_rd==1 && w0_data==32'h11, "slot0 writeback");
        check(w1_we==1 && w1_rd==2 && w1_data==32'h22, "slot1 writeback");

        // slot1 trap: slot0 commits, slot1 held.
        idle();
        s0_valid=1; s0_writes_rd=1; s0_rd=1; s0_data=32'h33;
        s1_valid=1; s1_trap=1; s1_cause=32'd11; s1_pc=32'h2000; #1;
        check(commit0_fire==1 && commit1_fire==0 && hold_s1==1 && trap_fire==0,
              "slot1 trap holds younger instruction");

        // slot0 trap: precise priority, flush younger, no GPR write.
        idle();
        s0_valid=1; s0_trap=1; s0_writes_rd=1; s0_rd=1; s0_data=32'h44;
        s0_cause=32'd2; s0_pc=32'h3000;
        s1_valid=1; s1_writes_rd=1; s1_rd=2; s1_data=32'h55; #1;
        check(commit0_fire==1 && commit1_fire==0 && trap_fire==1 &&
              flush_young==1 && w0_we==0 && w1_we==0,
              "slot0 trap flushes younger and suppresses writes");
        check(trap_cause==32'd2 && trap_pc==32'h3000, "trap cause/pc forwarded");

        // x0 writes are not real side effects.
        idle();
        s0_valid=1; s0_writes_rd=1; s0_rd=0; s0_data=32'h66;
        s1_valid=1; s1_writes_rd=1; s1_rd=0; s1_data=32'h77; #1;
        check(commit0_fire==1 && commit1_fire==1 && w0_we==0 && w1_we==0,
              "x0 writes retire but do not write the register file");

        // slot0 invalid: no commit.
        idle();
        s1_valid=1; s1_writes_rd=1; s1_rd=3; s1_data=32'h88; #1;
        check(commit0_fire==0 && commit1_fire==0, "slot0 invalid means no commit");

        if (fail_count == 0)
            $display("ALL TESTS PASSED (dual_commit: %0d checks)", pass_count);
        else
            $display("DUAL_COMMIT_RESULT: FAIL (%0d pass / %0d fail)", pass_count, fail_count);
        $finish;
    end
endmodule
