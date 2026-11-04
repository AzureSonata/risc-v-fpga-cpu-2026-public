`timescale 1ns/1ps
`include "defines.sv"

module tb_dual_full_redirect_pc4;
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
    integer not_taken_redirects = 0;

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

    always @(posedge clk) begin
        if (rst == `RstDisable && dut.branch_redirect &&
            dut.ex0_branch_request && !dut.ex0_branch_taken)
            not_taken_redirects <= not_taken_redirects + 1;
    end

    initial begin
        for (i = 0; i < 256; i = i + 1)
            prog[i] = 32'h0000_0013;
        for (i = 0; i < 1024; i = i + 1)
            dmem[i] = 32'h0;

        // A not-taken BNE has a deliberately misaligned +2 target. It must
        // resume at pc+4 without trapping. Then JAL at 0x08 targets 0x14,
        // whose PC[2] is one. The low word at 0x10 loops forever, so a
        // redirect that rounds the target down must fail to set x6.
        prog[0] = 32'h0000_1163; // BNE x0,x0,+2 (not taken)
        prog[1] = 32'h0070_0393; // ADDI x7,x0,7
        prog[2] = 32'h00c0_006f; // JAL x0,+12: target 0x14 has PC[2]=1
        prog[3] = 32'h0000_0013; // skipped sequential instruction
        prog[4] = 32'h0000_006f; // wrong aligned target 0x10 loops forever
        prog[5] = 32'h0070_0313; // target 0x14: ADDI x6,x0,7
        for (i = 0; i < 128; i = i + 1)
            imem[i] = {prog[2*i+1], prog[2*i]};

        repeat (3) @(posedge clk);
        #1 rst = `RstDisable;
        repeat (100) @(posedge clk);
        #1;
        $display("OBS: trap_events=%0d not_taken_redirects=%0d x5=%0d x6=%0d x7=%0d queue_pc=%h",
                 trap_events, not_taken_redirects,
                 dut.u_rf.regs[5], dut.u_rf.regs[6],
                 dut.u_rf.regs[7], dut.fq_out0_pc);
        if (trap_events == 0 && not_taken_redirects == 0 &&
            dut.u_rf.regs[7] == 7 && dut.u_rf.regs[6] == 7)
            $display("PASS: not-taken branch falls through; JAL preserves target PC[2]=1 at 0x14");
        else
            $fatal(1, "FAIL: branch target/fall-through behavior or misaligned trap");
        $display("ALL TESTS PASSED (dual_full_redirect_pc4)");
        $finish;
    end
 endmodule
