`timescale 1ns/1ps

module tb_pangu100proplus_dual_top;
    reg clk = 1'b0;
    reg rstn = 1'b0;
    always #5 clk = ~clk;

    wire [7:0] led;
    wire        trace0_valid, trace0_rd_we, trace0_trap;
    wire [63:0] trace0_order;
    wire [31:0] trace0_pc, trace0_instr, trace0_rd_data, trace0_cause;
    wire [4:0]  trace0_rd;
    wire        trace1_valid, trace1_rd_we, trace1_trap;
    wire [63:0] trace1_order;
    wire [31:0] trace1_pc, trace1_instr, trace1_rd_data, trace1_cause;
    wire [4:0]  trace1_rd;
    wire [31:0] pc_debug;

    pangu100proplus_dual_top dut (
        .clk(clk), .rstn(rstn), .led(led),
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
    integer trace_events = 0;
    integer issue1_cycles = 0;
    always @(posedge clk) begin
        if (!rstn) begin
            cycles <= 0; trace_events <= 0; issue1_cycles <= 0;
        end else begin
            cycles <= cycles + 1;
            trace_events <= trace_events + trace0_valid + trace1_valid;
            if (dut.u_cpu.u_core.issue1) issue1_cycles <= issue1_cycles + 1;
        end
    end

    integer j;
    integer local_fail = 0;
    initial begin
        repeat (5) @(posedge clk);
        rstn = 1'b1;

        wait ((trace_events >= 64) || (cycles >= 500));
        repeat (3) @(posedge clk);
        #1;

        for (j = 1; j <= 8; j = j + 1) begin
            if (dut.u_cpu.u_core.u_rf.regs[j] !== (56 + j)) begin
                $display("FAIL: x%0d = %0d expected %0d", j, dut.u_cpu.u_core.u_rf.regs[j], 56 + j);
                local_fail = local_fail + 1;
            end
        end
        if (trace_events < 64) begin
            $display("FAIL: trace_events=%0d expected at least 64", trace_events);
            local_fail = local_fail + 1;
        end
        if (led !== 8'h40) begin
            $display("FAIL: led=%02x expected 40", led);
            local_fail = local_fail + 1;
        end
        if (issue1_cycles == 0) begin
            $display("FAIL: dual lane never issued");
            local_fail = local_fail + 1;
        end

        if (local_fail == 0) begin
            $display("PASS: pangu dual top retired 64 instructions");
            $display("PASS: pangu dual top observed at least 64 trace events");
            $display("PASS: pangu dual top LED and registers correct");
            $display("ALL TESTS PASSED (pangu100proplus_dual_top)");
        end else begin
            $display("PANGU_DUAL_TOP_RESULT: FAIL (%0d errors)", local_fail);
        end
        $finish;
    end

    initial begin
        #50000;
        $display("PANGU_DUAL_TOP_RESULT: TIMEOUT trace=%0d", trace_events);
        $finish;
    end
endmodule
