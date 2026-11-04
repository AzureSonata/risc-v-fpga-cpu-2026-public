`timescale 1ns/1ps
`include "defines.sv"

module tb_dual_full_mem;
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
    wire [63:0] trace0_order, trace1_order;
    wire [31:0] trace0_pc, trace1_pc, trace0_rd_data, trace1_rd_data;
    wire [4:0] trace0_rd, trace1_rd;
    wire trace0_rd_we, trace1_rd_we;
    wire [31:0] pc_debug;

    wire [31:0] d_req_addr_t = d_req_addr;
    wire [9:0]  didx = d_req_addr_t[11:2];

    reg [31:0] prog [0:255];
    reg [63:0] imem [0:255];
    reg [31:0] dmem [0:1023];
    reg        i_rsp_valid_q;
    reg [63:0] i_rsp_data_q;
    reg        d_rsp_valid_q;
    reg [31:0] d_rsp_rdata_q;
    integer i;

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
                if (d_req_write) begin
                    if (d_req_wstrb[0]) dmem[didx][7:0]   <= d_req_wdata[7:0];
                    if (d_req_wstrb[1]) dmem[didx][15:8]  <= d_req_wdata[15:8];
                    if (d_req_wstrb[2]) dmem[didx][23:16] <= d_req_wdata[23:16];
                    if (d_req_wstrb[3]) dmem[didx][31:24] <= d_req_wdata[31:24];
                end else begin
                    d_rsp_rdata_q <= dmem[didx];
                end
                d_rsp_valid_q <= 1'b1;
            end
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
        .trace0_pc(trace0_pc), .trace0_instr(), .trace0_rd(trace0_rd),
        .trace0_rd_data(trace0_rd_data), .trace0_rd_we(trace0_rd_we),
        .trace0_trap(), .trace0_cause(),
        .trace1_valid(trace1_valid), .trace1_order(trace1_order),
        .trace1_pc(trace1_pc), .trace1_instr(), .trace1_rd(trace1_rd),
        .trace1_rd_data(trace1_rd_data),
        .trace1_rd_we(trace1_rd_we), .trace1_trap(), .trace1_cause(),
        .pc_debug(pc_debug)
    );

    integer fail = 0;
    integer issue1_cycles = 0;
    integer trace_events = 0;
    integer alu_pair_issue_cycles = 0;
    integer alu_pair_retire_cycles = 0;
    integer alu_pair_order_or_data_errors = 0;

    always @(posedge clk) begin
        if (rst == `RstDisable) begin
            if (issue1) issue1_cycles <= issue1_cycles + 1;
            trace_events <= trace_events + trace0_valid + trace1_valid;
            if (issue0 && issue1 && dut.fq_out0_pc == 32'h0000_0000 &&
                dut.fq_out1_pc == 32'h0000_0004)
                alu_pair_issue_cycles <= alu_pair_issue_cycles + 1;
            if (trace0_valid && trace1_valid) begin
                if (trace1_order != trace0_order + 64'd1) begin
                    alu_pair_order_or_data_errors <= alu_pair_order_or_data_errors + 1;
                    $display("DUAL_TRACE_ORDER_ERROR: cycle=%0t pc0=%08x pc1=%08x order0=%0d order1=%0d",
                             $time, trace0_pc, trace1_pc, trace0_order, trace1_order);
                end
                if (trace0_pc == 32'h0000_0000 && trace1_pc == 32'h0000_0004) begin
                    alu_pair_retire_cycles <= alu_pair_retire_cycles + 1;
                    // ⚠️ 坑位：0x01200113 的 ADDI immediate 是 0x12，不是 0 ⇒ 期望值按指令字段解码核验 ⇒ trace x2=0x12（见 LESSON-001 T17 / 日志 2026-10-19）。
                    if (trace0_rd != 5'd1 || trace0_rd_we !== 1'b1 ||
                        trace0_rd_data !== 32'h8000_0000 || trace1_rd != 5'd2 ||
                        trace1_rd_we !== 1'b1 || trace1_rd_data !== 32'h0000_0012) begin
                        alu_pair_order_or_data_errors <= alu_pair_order_or_data_errors + 1;
                        $display("DUAL_ALU_PAIR_DATA_ERROR: pc0=%08x rd0=%0d we0=%b data0=%08x pc1=%08x rd1=%0d data1=%08x orders=%0d,%0d",
                                 trace0_pc, trace0_rd, trace0_rd_we, trace0_rd_data,
                                 trace1_pc, trace1_rd, trace1_rd_data, trace0_order, trace1_order);
                    end
                end
            end
        end
    end

    initial begin
        for (i = 0; i < 256; i = i + 1) prog[i] = 32'h00000013;
        for (i = 0; i < 1024; i = i + 1) dmem[i] = 32'h0;
        $readmemh("verification/unit/dual_full_mem.hex", prog);
        for (i = 0; i < 128; i = i + 1)
            imem[i] = {prog[2*i + 1], prog[2*i]};

        repeat (3) @(posedge clk);
        #1; rst = `RstDisable;

        repeat (400) @(posedge clk);
        #1;

        if (dut.u_rf.regs[3] !== 32'h23) begin
            $display("FAIL: x3=0x%08x expected 0x23", dut.u_rf.regs[3]); fail=fail+1;
        end
        if (dut.u_rf.regs[4] !== 32'h567) begin
            $display("FAIL: x4=0x%08x expected 0x0567", dut.u_rf.regs[4]); fail=fail+1;
        end
        if (dut.u_rf.regs[5] !== 32'h12) begin
            $display("FAIL: x5=0x%08x expected 0x12", dut.u_rf.regs[5]); fail=fail+1;
        end
        if (dut.u_rf.regs[8] !== 32'd3) begin
            $display("FAIL: x8=0x%08x expected 3", dut.u_rf.regs[8]); fail=fail+1;
        end
        if (dut.u_rf.regs[11] !== 32'hffffff80) begin
            $display("FAIL: x11=0x%08x expected 0xffffff80", dut.u_rf.regs[11]); fail=fail+1;
        end
        if (dmem[0] !== 32'h12) begin
            $display("FAIL: dmem[0]=0x%08x expected 0x12", dmem[0]); fail=fail+1;
        end
        if (dmem[1][7:0] !== 8'h23) begin
            $display("FAIL: dmem[1].b0=0x%02x expected 0x23", dmem[1][7:0]); fail=fail+1;
        end
        if (dmem[2][15:0] !== 16'h567) begin
            $display("FAIL: dmem[2].h0=0x%04x expected 0x0567", dmem[2][15:0]); fail=fail+1;
        end
        if (dmem[3][7:0] !== 8'h80) begin
            $display("FAIL: dmem[3].b0=0x%02x expected 0x80", dmem[3][7:0]); fail=fail+1;
        end

        $display("DUAL_FULL_MEM: issue1_cycles=%0d trace_events=%0d alu_pair_issue=%0d alu_pair_retire=%0d alu_pair_errors=%0d",
                 issue1_cycles, trace_events, alu_pair_issue_cycles,
                 alu_pair_retire_cycles, alu_pair_order_or_data_errors);
        if (alu_pair_issue_cycles == 0 || alu_pair_retire_cycles == 0 ||
            alu_pair_order_or_data_errors != 0) begin
            $display("FAIL: independent LUI+ADDI pair lacked ordered same-cycle retirement or correct trace data");
            fail = fail + 1;
        end
        if (fail == 0 && trace_events > 0 && issue1_cycles > 0) begin
            $display("PASS: lane0 load/store byte/half/word and sign extension");
            $display("PASS: independent LUI+ADDI pair issued and retired together in order with correct trace data");
            $display("ALL TESTS PASSED (dual_full_mem)");
        end else begin
            $display("DUAL_FULL_MEM_RESULT: FAIL failures=%0d", fail);
        end
        $finish;
    end

    initial begin
        #100000;
        $display("DUAL_FULL_MEM_RESULT: TIMEOUT");
        $finish;
    end
endmodule
