`timescale 1ns/1ps

// Isolated board wrapper for the dual-issue CoreMark candidate.
// It intentionally reuses the established Pangu100Pro+ PLL and board pins.
module dual_issue_coremark_board_top #(
    parameter [1023:0] ROM_INIT_FILE = "coremark.hex",
    parameter integer M_MODE = 2,
    parameter DUAL_ISSUE_EN = 1'b1,
    parameter PREDICT_ENABLE = 1'b1,
    parameter integer PRED_MODE = 0,
    parameter integer BTB_ENTRIES = 64,
    parameter integer PLL_F = 63,
    parameter integer PLL_O = 17,
    parameter integer UART_DIV = 434,
    parameter ICACHE_ENABLE = 1'b1,
    parameter DCACHE_ENABLE = 1'b1
)(
    input  wire       clk27,
    input  wire       reset_n,
    output wire       uart_tx,
    output wire [7:0] led
);
    wire cpu_clk;
    wire pll_lock;
    wire pll_reset_n;

    pll100_candidate #(.PLL_F(PLL_F), .PLL_O(PLL_O)) u_pll (
        .clkin(clk27), .clkout(cpu_clk), .lock(pll_lock),
        .core_reset_n(pll_reset_n)
    );

    wire [31:0] gpio_out;

    pangu100proplus_dual_full_top #(
        .ROM_INIT_FILE(ROM_INIT_FILE),
        .MEM_DEPTH(16384),
        .MEM_AW(14),
        .UART_DIV(UART_DIV),
        .M_MODE(M_MODE),
        .DUAL_ISSUE_EN(DUAL_ISSUE_EN),
        .PREDICT_ENABLE(PREDICT_ENABLE),
        .PRED_MODE(PRED_MODE),
        .BTB_ENTRIES(BTB_ENTRIES),
        .ICACHE_ENABLE(ICACHE_ENABLE),
        .DCACHE_ENABLE(DCACHE_ENABLE)
    ) u_soc (
        .clk(cpu_clk),
        .rstn(reset_n & pll_reset_n),
        .gpio_in(32'b0),
        .uart_rx(1'b1),
        .led(),
        .gpio_out(gpio_out),
        .uart_tx(uart_tx),
        .trace0_valid(), .trace0_order(), .trace0_pc(), .trace0_instr(),
        .trace0_rd(), .trace0_rd_data(), .trace0_rd_we(), .trace0_trap(),
        .trace0_cause(),
        .trace1_valid(), .trace1_order(), .trace1_pc(), .trace1_instr(),
        .trace1_rd(), .trace1_rd_data(), .trace1_rd_we(), .trace1_trap(),
        .trace1_cause(),
        .pc_debug()
    );

    assign led = gpio_out[7:0];
endmodule
