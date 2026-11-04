`timescale 1ns/1ps

module tb_wb_trace;
    reg         clk;
    reg         rst;
    reg         wb_valid;
    reg         commit_fire;
    reg         wb_writes_rd;
    reg  [4:0]  wb_rd;
    reg  [31:0] wb_data;
    reg         wb_trap;
    reg  [31:0] retire_cause;

    wire        rd_we;
    wire [4:0]  rd_addr;
    wire [31:0] rd_data;
    wire        trace_valid;
    wire [63:0] trace_order;
    wire [31:0] trace_pc;
    wire [31:0] trace_instr;
    wire [4:0]  trace_rd;
    wire [31:0] trace_rd_data;
    wire        trace_rd_we;
    wire        trace_trap;
    wire [31:0] trace_cause;

    reg  [31:0] retire_pc;
    reg  [31:0] retire_instr;

    integer checks;
    integer failures;
    integer cycles;

    wb_stage dut_wb (
        .wb_valid(wb_valid),
        .commit_fire(commit_fire),
        .wb_writes_rd(wb_writes_rd),
        .wb_rd(wb_rd),
        .wb_data(wb_data),
        .wb_trap(wb_trap),
        .rd_we(rd_we),
        .rd_addr(rd_addr),
        .rd_data(rd_data)
    );

    retire_trace dut_trace (
        .clk(clk),
        .rst(rst),
        .retire_valid(wb_valid),
        .commit_fire(commit_fire),
        .retire_pc(retire_pc),
        .retire_instr(retire_instr),
        .retire_rd(rd_addr),
        .retire_rd_data(rd_data),
        .retire_rd_we(rd_we),
        .retire_trap(wb_trap),
        .retire_cause(retire_cause),
        .trace_valid(trace_valid),
        .trace_order(trace_order),
        .trace_pc(trace_pc),
        .trace_instr(trace_instr),
        .trace_rd(trace_rd),
        .trace_rd_data(trace_rd_data),
        .trace_rd_we(trace_rd_we),
        .trace_trap(trace_trap),
        .trace_cause(trace_cause)
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        cycles <= cycles + 1;
        if (cycles > 100) begin
            $display("FAIL timeout after %0d cycles", cycles);
            $finish_and_return(2);
        end
    end

    task check;
        input condition;
        input [8*80-1:0] message;
        begin
            checks = checks + 1;
            if (!condition) begin
                failures = failures + 1;
                $display("FAIL: %0s", message);
            end
        end
    endtask

    task drive_commit;
        input        valid_i;
        input        fire_i;
        input        writes_i;
        input [4:0]  rd_i;
        input [31:0] data_i;
        input        trap_i;
        input [31:0] pc_i;
        input [31:0] instr_i;
        begin
            @(negedge clk);
            wb_valid     = valid_i;
            commit_fire  = fire_i;
            wb_writes_rd = writes_i;
            wb_rd        = rd_i;
            wb_data      = data_i;
            wb_trap      = trap_i;
            retire_pc    = pc_i;
            retire_instr = instr_i;
            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        clk          = 1'b0;
        rst          = 1'b1;
        wb_valid     = 1'b0;
        commit_fire  = 1'b0;
        wb_writes_rd = 1'b0;
        wb_rd        = 5'd0;
        wb_data      = 32'd0;
        wb_trap      = 1'b0;
        retire_cause = 32'd0;
        retire_pc    = 32'd0;
        retire_instr = 32'd0;
        checks       = 0;
        failures     = 0;
        cycles       = 0;

        // Negative harness check: +FORCE_TIMEOUT intentionally stops normal
        // stimulus so the watchdog must terminate simulation with exit code 2.
        if ($test$plusargs("FORCE_TIMEOUT")) begin
            rst = 1'b0;
            forever @(posedge clk);
        end

        repeat (2) @(posedge clk);
        #1;
        check(!trace_valid, "reset clears trace_valid");
        check(trace_order == 64'd0, "reset clears trace order");
        @(negedge clk);
        rst = 1'b0;

        // Ordinary architectural write and first retirement (order zero).
        drive_commit(1'b1, 1'b1, 1'b1, 5'd5, 32'h1234_5678,
                     1'b0, 32'h0000_0100, 32'h0010_0293);
        check(rd_we, "ordinary write enables register file");
        check(rd_addr == 5'd5 && rd_data == 32'h1234_5678,
              "ordinary write preserves destination and data");
        check(trace_valid && trace_order == 64'd0,
              "first commit emits order zero");
        check(trace_rd_we && trace_rd == 5'd5 &&
              trace_rd_data == 32'h1234_5678,
              "trace reports ordinary register side effect");

        // x0 is retired and recorded, but never written.
        drive_commit(1'b1, 1'b1, 1'b1, 5'd0, 32'hffff_ffff,
                     1'b0, 32'h0000_0104, 32'h0000_0013);
        check(!rd_we, "x0 write is suppressed");
        check(trace_valid && trace_order == 64'd1,
              "x0 instruction still retires once");
        check(trace_rd == 5'd0 && !trace_rd_we,
              "x0 trace records rd with no side effect");

        // A bubble cannot write, retire, or advance order.
        drive_commit(1'b0, 1'b1, 1'b1, 5'd6, 32'haaaa_5555,
                     1'b0, 32'h0000_0108, 32'h0000_0000);
        check(!rd_we && !trace_valid, "bubble has no side effect or trace");

        // A trap is observable, but its register write is cancelled.
        retire_cause = 32'h0000_0005;
        drive_commit(1'b1, 1'b1, 1'b1, 5'd7, 32'hdead_beef,
                     1'b1, 32'h0000_010c, 32'hffff_ffff);
        check(!rd_we, "trap suppresses register write");
        check(trace_valid && trace_order == 64'd2 && trace_trap,
              "trap retires once with the next order");
        check(trace_cause == 32'h0000_0005,
              "trap cause propagates on the trace event");
        retire_cause = 32'd0;
        check(trace_rd == 5'd7 && !trace_rd_we,
              "trap keeps rd metadata but no side effect");

        // Hold the same valid payload for multiple clocks.  With fire low it
        // must not repeat the write, trace event, or order increment.
        drive_commit(1'b1, 1'b0, 1'b1, 5'd8, 32'hcafe_babe,
                     1'b0, 32'h0000_0110, 32'h0080_0413);
        check(!rd_we && !trace_valid, "held payload does not commit without fire");
        drive_commit(1'b1, 1'b0, 1'b1, 5'd8, 32'hcafe_babe,
                     1'b0, 32'h0000_0110, 32'h0080_0413);
        check(!rd_we && !trace_valid, "multi-cycle hold does not repeat commit");
        drive_commit(1'b1, 1'b1, 1'b1, 5'd8, 32'hcafe_babe,
                     1'b0, 32'h0000_0110, 32'h0080_0413);
        check(rd_we && trace_valid && trace_order == 64'd3,
              "held payload commits exactly once when consumed");

        // Consecutive one-cycle commits receive consecutive order values.
        drive_commit(1'b1, 1'b1, 1'b0, 5'd0, 32'd0,
                     1'b0, 32'h0000_0114, 32'h0000_0013);
        check(trace_valid && trace_order == 64'd4 && !trace_rd_we,
              "first consecutive commit has next order");
        drive_commit(1'b1, 1'b1, 1'b1, 5'd9, 32'h0000_0009,
                     1'b0, 32'h0000_0118, 32'h0090_0493);
        check(trace_valid && trace_order == 64'd5 && trace_rd_we,
              "second consecutive commit has consecutive order");

        // Return to idle so trace_valid is demonstrably a pulse.
        drive_commit(1'b0, 1'b0, 1'b0, 5'd0, 32'd0,
                     1'b0, 32'd0, 32'd0);
        check(!trace_valid, "trace_valid deasserts after a commit pulse");

        // More empty clocks leave the order counter untouched; the next event
        // proves that only a real valid+fire handshake advances retirement.
        drive_commit(1'b0, 1'b1, 1'b1, 5'd10, 32'hbad0_bad0,
                     1'b0, 32'h0000_0120, 32'hdead_dead);
        check(!rd_we && !trace_valid, "fire without valid is an empty clock");
        drive_commit(1'b1, 1'b0, 1'b1, 5'd10, 32'h1010_1010,
                     1'b1, 32'h0000_0124, 32'hffff_ffff);
        check(!rd_we && !trace_valid, "trap payload held without fire is inert");
        drive_commit(1'b1, 1'b1, 1'b1, 5'd10, 32'h1010_1010,
                     1'b1, 32'h0000_0124, 32'hffff_ffff);
        check(trace_valid && trace_order==64'd6 && trace_trap && !trace_rd_we,
              "held trap commits once at unchanged next order");
        drive_commit(1'b1, 1'b1, 1'b1, 5'd11, 32'h1111_1111,
                     1'b0, 32'h0000_0128, 32'h00b0_0593);
        check(trace_valid && trace_order==64'd7 && trace_pc==32'h128 &&
              trace_instr==32'h00b0_0593 && trace_rd==5'd11 &&
              trace_rd_data==32'h1111_1111 && trace_rd_we && !trace_trap,
              "back-to-back commit preserves full trace payload");

        if (failures == 0) begin
            $display("PASS tb_wb_trace: %0d checks", checks);
            $display("ALL WB TRACE TESTS PASSED");
            $finish_and_return(0);
        end else begin
            $display("FAIL tb_wb_trace: %0d of %0d checks failed", failures, checks);
            $finish_and_return(1);
        end
    end

endmodule
