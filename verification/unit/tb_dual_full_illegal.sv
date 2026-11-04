`timescale 1ns/1ps
`include "defines.sv"

module tb_dual_full_illegal;
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
    wire [4:0] trace0_rd, trace1_rd;
    wire trace0_rd_we, trace1_rd_we;
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
    integer x5_trace_writes = 0;
    integer younger_pair_observed = 0;

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
            if (trace0_valid && trace0_rd_we && trace0_rd == 5'd5)
                x5_trace_writes <= x5_trace_writes + 1;
            if (trace1_valid && trace1_rd_we && trace1_rd == 5'd5)
                x5_trace_writes <= x5_trace_writes + 1;
            if (dut.fq_out0_valid && dut.fq_out0_pc == 32'h00000000 &&
                dut.fq_out0_inst == 32'hffffffff && dut.fq_out1_valid &&
                dut.fq_out1_pc == 32'h00000004 && dut.fq_out1_inst == 32'h06300293)
                younger_pair_observed <= younger_pair_observed + 1;
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
        .trace0_pc(), .trace0_instr(), .trace0_rd(trace0_rd), .trace0_rd_data(),
        .trace0_rd_we(trace0_rd_we), .trace0_trap(trace0_trap), .trace0_cause(),
        .trace1_valid(trace1_valid), .trace1_order(trace1_order),
        .trace1_pc(), .trace1_instr(), .trace1_rd(trace1_rd), .trace1_rd_data(),
        .trace1_rd_we(trace1_rd_we), .trace1_trap(trace1_trap), .trace1_cause(),
        .pc_debug()
    );


 initial begin
        for (i = 0; i < 256; i = i + 1) prog[i] = 32'h00000013;
        for (i = 0; i < 1024; i = i + 1) dmem[i] = 0;
        prog[0] = 32'hffffffff;             // illegal instruction at PC 0
        prog[1] = 32'h06300293;             // younger addi x5, x0, 99
        for (i = 0; i < 128; i = i + 1) imem[i] = {prog[2*i+1], prog[2*i]};
        repeat (3) @(posedge clk);
        #1 rst = `RstDisable;
        repeat (100) @(posedge clk);
        #1;

        $display("OBS: traps=%0d pair=%0d mepc=%h mcause=%h mtval=%h x5=%0d x5_trace_writes=%0d",
                 trap_events, younger_pair_observed,
                 dut.u_csr.mepc, dut.u_csr.mcause, dut.u_csr.mtval,
                 dut.u_rf.regs[5], x5_trace_writes);
        if (trap_events > 0) begin
            if (younger_pair_observed == 0)
                $fatal(1, "FAIL: illegal head and younger slot1 addi were never simultaneously present");
            if (dut.u_csr.mepc !== 32'h00000000)
                $fatal(1, "FAIL: mepc must identify illegal instruction PC 0, got %h", dut.u_csr.mepc);
            if (dut.u_csr.mtval !== 32'hffffffff)
                $fatal(1, "FAIL: mtval must contain illegal encoding ffffffff, got %h", dut.u_csr.mtval);
            if (dut.u_csr.mcause !== 32'd2)
                $fatal(1, "FAIL: mcause must be 2 for illegal instruction, got %h", dut.u_csr.mcause);
            if (dut.u_rf.regs[5] !== 32'd0 || x5_trace_writes != 0)
                $fatal(1, "FAIL: younger slot1 addi wrote x5 (RF=%h trace_writes=%0d)",
                       dut.u_rf.regs[5], x5_trace_writes);
        end else begin
            $fatal(1, "FAIL: illegal instruction did not produce a trap retirement");
        end
        $display("PASS: precise illegal trap state and younger slot1 suppression");
        $display("ALL TESTS PASSED (dual_full_illegal)");
        $finish;
 end
 endmodule
