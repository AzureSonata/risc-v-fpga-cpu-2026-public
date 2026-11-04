`timescale 1ns/1ps
`include "defines.sv"

module tb_dual_full_csr;
    reg clk = 1'b0;
    reg rst = `RstEnable;
    always #5 clk = ~clk;

    wire        i_req_valid, i_req_ready;
    wire [31:0] i_req_addr;
    reg         i_rsp_valid;
    wire        i_rsp_ready;
    reg  [63:0] i_rsp_data;
    wire        d_req_valid, d_req_ready, d_req_write;
    wire [31:0] d_req_addr, d_req_wdata;
    wire [3:0]  d_req_wstrb;
    reg         d_rsp_valid;
    wire        d_rsp_ready;
    reg  [31:0] d_rsp_rdata;
    wire        d_rsp_error = 1'b0;

    wire issue0, issue1, retire0_valid, retire1_valid;
    wire trace0_valid, trace1_valid;
    wire trace0_trap, trace1_trap;
    wire [63:0] trace0_order, trace1_order;

    reg [31:0] prog [0:255];
    reg [63:0] imem [0:255];
    reg [31:0] dmem [0:1023];
    reg        i_rsp_valid_q;
    reg [63:0] i_rsp_data_q;
    reg        d_rsp_valid_q;
    reg [31:0] d_rsp_rdata_q;
    integer i;
    integer fail = 0;
    integer trap_events = 0;
    integer trace_events = 0;

    assign i_req_ready = 1'b1;
    assign i_rsp_valid = i_rsp_valid_q;
    assign i_rsp_data  = i_rsp_data_q;
    assign d_req_ready = 1'b1;
    assign d_rsp_valid = d_rsp_valid_q;
    assign d_rsp_rdata = d_rsp_rdata_q;

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            i_rsp_valid_q <= 1'b0;
            i_rsp_data_q  <= 64'h0;
        end else begin
            if (i_req_valid && i_req_ready) begin
                i_rsp_valid_q <= 1'b1;
                i_rsp_data_q  <= imem[i_req_addr[31:3]];
            end else if (i_rsp_valid && i_rsp_ready) begin
                i_rsp_valid_q <= 1'b0;
            end
        end
    end

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            d_rsp_valid_q <= 1'b0;
            d_rsp_rdata_q <= 32'h0;
        end else begin
            d_rsp_valid_q <= 1'b0;
            if (d_req_valid && d_req_ready) begin
                if (!d_req_write)
                    d_rsp_rdata_q <= dmem[d_req_addr[11:2]];
                d_rsp_valid_q <= 1'b1;
            end
        end
    end

    always @(posedge clk) begin
        if (rst == `RstDisable) begin
            trace_events <= trace_events + trace0_valid + trace1_valid;
            if (trace0_valid && trace0_trap) trap_events <= trap_events + 1;
            if (trace1_valid && trace1_trap) trap_events <= trap_events + 1;
        end
    end

    dual_issue_full_core dut (
        .clk(clk), .rst(rst),
        .i_req_valid(i_req_valid), .i_req_ready(i_req_ready),
        .i_req_addr(i_req_addr), .i_rsp_valid(i_rsp_valid),
        .i_rsp_ready(i_rsp_ready), .i_rsp_data(i_rsp_data), .i_rsp_error(2'b00),
        .d_req_valid(d_req_valid), .d_req_ready(d_req_ready),
        .d_req_addr(d_req_addr), .d_req_write(d_req_write),
        .d_req_wdata(d_req_wdata), .d_req_wstrb(d_req_wstrb),
        .d_rsp_valid(d_rsp_valid), .d_rsp_ready(d_rsp_ready),
        .d_rsp_rdata(d_rsp_rdata), .d_rsp_error(d_rsp_error),
        .timer_irq_i(1'b0), .ext_irq_i(1'b0),
        .issue0(issue0), .issue1(issue1),
        .retire0_valid(retire0_valid), .retire1_valid(retire1_valid),
        .trace0_valid(trace0_valid), .trace0_order(trace0_order),
        .trace0_pc(), .trace0_instr(), .trace0_rd(), .trace0_rd_data(),
        .trace0_rd_we(), .trace0_trap(trace0_trap), .trace0_cause(),
        .trace1_valid(trace1_valid), .trace1_order(trace1_order),
        .trace1_pc(), .trace1_instr(), .trace1_rd(), .trace1_rd_data(),
        .trace1_rd_we(), .trace1_trap(trace1_trap), .trace1_cause(),
        .pc_debug()
    );

    // The program does not write counters: successful trace entries are an
    // independent observable count, including exclusion of fault/IRQ events.
    reg [63:0] retired_expected = 64'd0;
    always @(negedge clk) begin
        if (rst == `RstEnable) retired_expected = 64'd0;
        else begin
            retired_expected = retired_expected + {63'b0, trace0_valid && !trace0_trap} +
                               {63'b0, trace1_valid && !trace1_trap};
            if (dut.u_csr.minstret_q !== retired_expected)
                $fatal(1, "FAIL minstret integration got=%0d trace=%0d",
                       dut.u_csr.minstret_q, retired_expected);
        end
    end

    initial begin
        for (i = 0; i < 256; i = i + 1) prog[i] = 32'h00000013;
        for (i = 0; i < 1024; i = i + 1) dmem[i] = 32'h0;
        $readmemh("verification/unit/dual_full_csr.hex", prog);
        for (i = 0; i < 128; i = i + 1)
            imem[i] = {prog[2*i + 1], prog[2*i]};

        repeat (3) @(posedge clk);
        #1; rst = `RstDisable;
        repeat (800) @(posedge clk);
        #1;

        if (dut.u_rf.regs[2] !== 32'h100) begin
            $display("FAIL: x2=0x%08x expected 0x100", dut.u_rf.regs[2]); fail=fail+1;
        end
        if (dut.u_rf.regs[4] !== 32'h234) begin
            $display("FAIL: x4=0x%08x expected 0x234", dut.u_rf.regs[4]); fail=fail+1;
        end
        if (dut.u_rf.regs[6] !== 32'h2a) begin
            $display("FAIL: x6=0x%08x expected 0x2a", dut.u_rf.regs[6]); fail=fail+1;
        end
        if (dut.u_rf.regs[7] !== 32'h1800) begin
            $display("FAIL: x7=0x%08x expected 0x1800", dut.u_rf.regs[7]); fail=fail+1;
        end
        if (dut.u_rf.regs[8] !== 32'h1808) begin
            $display("FAIL: x8=0x%08x expected 0x1808", dut.u_rf.regs[8]); fail=fail+1;
        end
        if (dut.u_rf.regs[10] !== 32'h0000000b) begin
            $display("FAIL: x10=0x%08x expected 0x0000000b", dut.u_rf.regs[10]); fail=fail+1;
        end
        if (dut.u_rf.regs[11] !== 32'h38) begin
            $display("FAIL: x11=0x%08x expected 0x38", dut.u_rf.regs[11]); fail=fail+1;
        end

        $display("DUAL_FULL_CSR: trace_events=%0d trap_events=%0d", trace_events, trap_events);
        if (fail == 0 && trap_events > 0 && trace_events > 20) begin
            $display("PASS: CSR read/write through csr_file (mtvec/mepc/mcause/mstatus)");
            $display("PASS: ECALL precise trap, mcause=11, mret returns after ecall");
            $display("ALL TESTS PASSED (dual_full_csr)");
        end else begin
            $display("DUAL_FULL_CSR_RESULT: FAIL failures=%0d", fail);
        end
        $finish;
    end

    initial begin
        #200000;
        $display("DUAL_FULL_CSR_RESULT: TIMEOUT");
        $finish;
    end
endmodule
