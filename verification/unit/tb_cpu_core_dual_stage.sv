`timescale 1ns/1ps
`include "defines.sv"

module tb_cpu_core_dual_stage;
    reg clk = 1'b0;
    reg rst = `RstEnable;
    always #5 clk = ~clk;

    wire        i_req_valid;
    reg         i_req_ready;
    wire [31:0] i_req_addr;
    reg         i_rsp_valid;
    wire        i_rsp_ready;
    reg  [63:0] i_rsp_data;
    reg         i_rsp_error;
    wire        d_req_valid;
    reg         d_req_ready;
    wire [31:0] d_req_addr;
    wire        d_req_write;
    wire [31:0] d_req_wdata;
    wire [3:0]  d_req_wstrb;
    reg         d_rsp_valid;
    wire        d_rsp_ready;
    reg  [31:0] d_rsp_rdata;
    reg         d_rsp_error;
    reg         timer_irq_i, ext_irq_i;

    wire        trace_valid;
    wire [63:0] trace_order;
    wire [31:0] trace_pc, trace_instr, trace_rd_data, trace_cause;
    wire [4:0]  trace_rd;
    wire        trace_rd_we, trace_trap;
    wire        trace1_valid;
    wire [63:0] trace1_order;
    wire [31:0] trace1_pc, trace1_instr, trace1_rd_data, trace1_cause;
    wire [4:0]  trace1_rd;
    wire        trace1_rd_we, trace1_trap;
    wire [31:0] pc_debug;

    reg [63:0] imem [0:127];
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
                rsp_data_q  <= imem[i_req_addr[9:3]];
            end else if (i_rsp_valid && i_rsp_ready) begin
                rsp_valid_q <= 1'b0;
            end
        end
    end

    cpu_core_dual_stage dut (
        .clk(clk), .rst(rst),
        .i_req_valid(i_req_valid), .i_req_ready(i_req_ready),
        .i_req_addr(i_req_addr), .i_rsp_valid(i_rsp_valid),
        .i_rsp_ready(i_rsp_ready), .i_rsp_data(i_rsp_data),
        .i_rsp_error(i_rsp_error),
        .d_req_valid(d_req_valid), .d_req_ready(d_req_ready),
        .d_req_addr(d_req_addr), .d_req_write(d_req_write),
        .d_req_wdata(d_req_wdata), .d_req_wstrb(d_req_wstrb),
        .d_rsp_valid(d_rsp_valid), .d_rsp_ready(d_rsp_ready),
        .d_rsp_rdata(d_rsp_rdata), .d_rsp_error(d_rsp_error),
        .timer_irq_i(timer_irq_i), .ext_irq_i(ext_irq_i),
        .trace_valid(trace_valid), .trace_order(trace_order),
        .trace_pc(trace_pc), .trace_instr(trace_instr),
        .trace_rd(trace_rd), .trace_rd_data(trace_rd_data),
        .trace_rd_we(trace_rd_we), .trace_trap(trace_trap),
        .trace_cause(trace_cause),
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
        if (rst == `RstEnable) begin
            cycles <= 0; trace_events <= 0; issue1_cycles <= 0;
        end else begin
            cycles <= cycles + 1;
            trace_events <= trace_events + trace_valid + trace1_valid;
            if (dut.u_core.issue1) issue1_cycles <= issue1_cycles + 1;
        end
    end

    integer j;
    integer local_fail = 0;
    initial begin
        i_rsp_error=0; d_req_ready=1; d_rsp_valid=0; d_rsp_rdata=0; d_rsp_error=0;
        timer_irq_i=0; ext_irq_i=0;

        for (i = 0; i < 64; i = i + 1)
            prog[i] = 32'h00000013 | ((i + 1) << 20) | (((i % 8) + 1) << 7);
        for (i = 0; i < 64; i = i + 1)
            imem[i] = {prog[2*i + 1], prog[2*i]};

        repeat (3) @(posedge clk);
        #1; rst = `RstDisable;

        wait ((trace_events >= 64) || (cycles >= 500));
        repeat (3) @(posedge clk);
        #1;

        for (j = 1; j <= 8; j = j + 1) begin
            if (dut.u_core.u_rf.regs[j] !== (56 + j)) begin
                $display("FAIL: x%0d = %0d expected %0d", j, dut.u_core.u_rf.regs[j], 56 + j);
                local_fail = local_fail + 1;
            end
        end
        if (trace_events != 64) begin
            $display("FAIL: trace_events=%0d expected 64", trace_events);
            local_fail = local_fail + 1;
        end
        if (issue1_cycles == 0) begin
            $display("FAIL: CPU top never issued lane1");
            local_fail = local_fail + 1;
        end

        if (local_fail == 0) begin
            $display("PASS: CPU top dual retirement trace observed 64 events");
            $display("PASS: CPU top register results match");
            $display("ALL TESTS PASSED (cpu_core_dual_stage)");
        end else begin
            $display("CPU_CORE_DUAL_STAGE_RESULT: FAIL (%0d errors)", local_fail);
        end
        $finish;
    end

    initial begin
        #50000;
        $display("CPU_CORE_DUAL_STAGE_RESULT: TIMEOUT trace=%0d", trace_events);
        $finish;
    end
endmodule
