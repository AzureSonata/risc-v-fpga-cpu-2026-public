`timescale 1ns/1ps

// Isolated full-core CoreMark candidate; do not use as the production top.
module coremark_board_top #(
    parameter [1023:0] ROM_INIT_FILE = "coremark.hex",
    parameter integer UART_DIV = 869,
    parameter ICACHE_ENABLE = 1'b1,
    parameter BTB_ENABLE = 1'b1,
    parameter integer M_MODE = 2
)(
    input wire clk27,
    input wire reset_n,
    output wire uart_tx,
    output wire [7:0] led
);
    wire cpu_clk;
    wire pll_lock, pll_reset_n;
    pll100_candidate u_pll(
        .clkin(clk27), .clkout(cpu_clk), .lock(pll_lock), .core_reset_n(pll_reset_n)
    );

    reg reset_meta = 1'b0;
    reg reset_sync = 1'b0;
    // reset_n is asynchronous to both clocks. Only its path to reset_meta is
    // an asynchronous-input path; reset_meta->reset_sync and all CPU logic
    // remain normally timed. pll_reset_n is already synchronized to cpu_clk.
    always @(posedge cpu_clk) begin
        if (!pll_reset_n) begin
            reset_meta <= 1'b0;
            reset_sync <= 1'b0;
        end else begin
            reset_meta <= reset_n;
            reset_sync <= reset_meta;
        end
    end

    wire rst = !reset_sync;

    wire iv, ir, isv, isr, ie;
    wire [31:0] ia, idata;
    wire dv, dr, dw, dsv, dsr, de;
    wire [31:0] da, wd, rd;
    wire [3:0] ws;
    wire timer_irq;
    wire [31:0] gpio_out;
    wire trace_valid, trace_trap, trace_rd_we;
    wire [63:0] trace_order;
    wire [31:0] trace_pc, trace_instr, trace_data, trace_cause;
    wire [4:0] trace_rd;

    cpu_core_stage1 #(.BTB_ENABLE(BTB_ENABLE), .M_MODE(M_MODE)) u_cpu (
        .clk(cpu_clk), .rst(rst),
        .i_req_valid(iv), .i_req_ready(ir), .i_req_addr(ia),
        .i_rsp_valid(isv), .i_rsp_ready(isr), .i_rsp_data(idata), .i_rsp_error(ie),
        .d_req_valid(dv), .d_req_ready(dr), .d_req_addr(da),
        .d_req_write(dw), .d_req_wdata(wd), .d_req_wstrb(ws),
        .d_rsp_valid(dsv), .d_rsp_ready(dsr), .d_rsp_rdata(rd), .d_rsp_error(de),
        .timer_irq_i(timer_irq), .ext_irq_i(1'b0),
        .trace_valid(trace_valid), .trace_order(trace_order), .trace_pc(trace_pc),
        .trace_instr(trace_instr), .trace_rd(trace_rd), .trace_rd_data(trace_data),
        .trace_rd_we(trace_rd_we), .trace_trap(trace_trap), .trace_cause(trace_cause)
    );

    cpu_mem_subsystem #(
        .MEM_DEPTH(16384), .MEM_AW(14), .ROM_INIT_FILE(ROM_INIT_FILE),
        .UART_DIV(UART_DIV), .ICACHE_ENABLE(ICACHE_ENABLE), .DCACHE_ENABLE(1'b0)
    ) u_mem (
        .clk(cpu_clk), .rst(rst),
        .i_req_valid(iv), .i_req_ready(ir), .i_req_addr(ia),
        .i_write(1'b0), .i_wdata(32'b0), .i_wstrb(4'b0),
        .i_rsp_valid(isv), .i_rsp_ready(isr), .i_rdata(idata), .i_error(ie),
        .d_req_valid(dv), .d_req_ready(dr), .d_req_addr(da),
        .d_write(dw), .d_wdata(wd), .d_wstrb(ws),
        .d_rsp_valid(dsv), .d_rsp_ready(dsr), .d_rdata(rd), .d_error(de),
        .gpio_out(gpio_out), .gpio_in(32'b0), .timer_irq(timer_irq),
        .uart_tx(uart_tx), .uart_rx(1'b1)
    );

    reg trap_seen;
    always @(posedge cpu_clk) begin
        if (rst) trap_seen <= 1'b0;
        else if (trace_valid && trace_trap) trap_seen <= 1'b1;
    end
    assign led = {trap_seen, gpio_out[6:0]};
endmodule

module pll100_candidate #(
    parameter integer PLL_F = 63,
    parameter integer PLL_O = 17
)(input wire clkin, output wire clkout, output wire lock, output wire core_reset_n);
`ifdef SIMULATION
    assign clkout = clkin;
    assign lock = 1'b1;
    reg [1:0] reset_release = 2'b00;
    always @(posedge clkout) reset_release <= {reset_release[0], 1'b1};
    assign core_reset_n = reset_release[1];
`else
    GTP_PPLL #(
        .CLKIN_FREQ(27.0), .LOCK_MODE(1'b0),
        .STATIC_RATIOI(1), .STATIC_RATIOM(1),
        .STATIC_RATIOF(PLL_F), .STATIC_RATIO0(PLL_O),
        .STATIC_DUTYF(PLL_F), .STATIC_DUTY0(PLL_O),
        .INTERNAL_FB("CLKOUTF"), .EXTERNAL_FB("DISABLE"), .BANDWIDTH("OPTIMIZED")
    ) u_pll (
        .CLKOUT0(clkout), .CLKOUT0N(), .CLKOUT1(), .CLKOUT1N(),
        .CLKOUT2(), .CLKOUT2N(), .CLKOUT3(), .CLKOUT3N(), .CLKOUT4(),
        .CLKOUTPHY(), .CLKOUTPHYN(), .CLKOUTF(), .CLKOUTFN(), .LOCK(lock),
        .APB_RDATA(), .APB_READY(), .CLKIN1(clkin), .CLKIN2(1'b0), .CLKFB(1'b0),
        .CLKIN_SEL(1'b0), .CLKOUT0_SYN(1'b0), .CLKOUT1_SYN(1'b0), .CLKOUT2_SYN(1'b0),
        .CLKOUT3_SYN(1'b0), .CLKOUT4_SYN(1'b0), .CLKOUTPHY_SYN(1'b0), .CLKOUTF_SYN(1'b0),
        .PLL_PWD(1'b0), .RST(1'b0), .APB_CLK(1'b0), .APB_RST_N(1'b0),
        .APB_ADDR(5'b0), .APB_SEL(1'b0), .APB_EN(1'b0), .APB_WRITE(1'b0), .APB_WDATA(16'b0)
    );
    reg [1:0] reset_release = 2'b00;
    always @(posedge clkout or negedge lock) begin
        if (!lock) reset_release <= 2'b00;
        else reset_release <= {reset_release[0], 1'b1};
    end
    assign core_reset_n = reset_release[1];
`endif
endmodule
