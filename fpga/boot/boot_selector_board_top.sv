// =============================================================================
//  boot_selector_board_top.sv — A4b/A4c board wrapper for the boot selector
//
//  Purpose: make the A4 boot selector a self-contained bitstream candidate for
//  a 27 MHz PDS run (compile -> synthesize -> dev_map -> pnr -> bitgen). It is
//  NOT wired into the CPU/KWS SoC: no CPU, cache, DDR or flash controller is
//  instantiated here, so nothing is loaded while the selector runs.
//
//  Contents
//    * u_sel       : rtl/boot/boot_selector_top.sv (the A4 selector)
//    * u_warmboot  : A3 rtl/boot/warmboot_ipal.sv (frozen at 121c5d8a), the
//                    UG040005 Table 3-26 warmboot command generator. It drives
//                    the internal slave parallel interface pins only; the
//                    primitive itself is instantiated here (u_ipal).
//    * u_ipal      : GTP_IPAL_E2 primitive, X32 mode, IDCODE 0xA5A5A5A5.
//                    Data-width X32 matches the 32-bit warmboot word stream.
//    * status LEDs : led[3:0] = FSM state, led[4] = mode_sel,
//                    led[5] = bench_ready, led[6] = bench_running,
//                    led[7] = warmboot activity (busy|done|err)
//    * status UART : repeats one status byte every ~1 ms at ~115 kbaud
//                    (divider 234 @27 MHz). Byte = {2'b00, mode_sel,
//                    bench_ready, bench_running, state[3:0]}. Bring-up/visibility
//                    channel only, not a protocol.
//
//  Keys are active low (board keys), see fpga/boot/boot_selector.fdc.
//
//  Golden-bitstream constraint (UG040005 3.7.1/3.7.2, A3 WARMBOOT_IF.md §4):
//  do NOT insert an IRST command into this golden bitstream (-insert_irst is
//  forbidden here); the selector samples KEY1 in user mode and only then asks
//  A3/A4 to drive warmboot over the IPAL interface.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module boot_selector_board_top (
    input  wire       clk,        // 27 MHz core-board oscillator (D18)
    input  wire       key0_n,     // KEY0 = C22, active low
    input  wire       key1_n,     // KEY1 = C23, active low
    input  wire       key2_n,     // KEY2 = B22, active low
    input  wire       uart_rx,    // board USB-UART RX (B24), unused (kept pinned)
    output wire [7:0] led,        // active-high LEDs (B17,C17,A18,A17,E18,C19,C18,A20)
    output wire       uart_tx     // board USB-UART TX (C24)
);
    localparam integer CLK_HZ = 27_000_000;

    wire        mode_sel;
    wire [31:0] flash_addr;
    wire        bench_ready;
    wire        bench_running;
    wire        warmboot_trigger;
    wire        warmboot_start;
    wire [31:0] warmboot_addr;
    wire        cpu_reset;
    wire [3:0]  state_o;

    boot_selector_top #(
        .KEY_ACTIVE_LOW     (1'b1),
        .CLK_HZ             (CLK_HZ),
        .DEBOUNCE_MS        (10),
        .SETTLE_MS          (20),
        .READY_HOLD_MS      (100),
        .LOAD_CYCLES        (1_350_000),   // 50 ms bench-image load placeholder (bench branch only)
        .WARMBOOT_PULSE     (16),
        .FLASH_BASE         (32'h0000_0000),
        // P1 flash layout (A3 WARMBOOT_IF.md §4 / A9 cfg_gen_multi_file):
        //   golden 0x0000_4000, KWS 0x003A_2000, CPU 0x0074_1000.
        // Each application stream must keep a 4 KiB head region above the previous
        // stream payload (A9 tool hard constraint start >= prev_end + 0x1000), hence
        // CPU starts at 0x0074_1000 rather than 0x0074_0000.
        // The selector addresses images with FLASH_BASE + offset.
        .KWS_IMAGE_OFFSET   (32'h003A_2000),
        .BENCH_IMAGE_OFFSET (32'h0074_1000)
    ) u_sel (
        .clk              (clk),
        // KEY0 is the board reset key (C22) and is active LOW: idle = 1 = released.
        // The selector's rst_n is therefore the raw pin (NOT inverted); inverting it
        // would hold the whole selector in reset whenever the key is released.
        .rst_n            (key0_n),
        .key0_n           (key0_n),
        .key1_n           (key1_n),
        .key2_n           (key2_n),
        .mode_sel         (mode_sel),
        .flash_addr       (flash_addr),
        .bench_ready      (bench_ready),
        .bench_running    (bench_running),
        .warmboot_trigger (warmboot_trigger),
        .warmboot_start   (warmboot_start),  // one-cycle pulse for A3 trigger
        .warmboot_addr    (warmboot_addr),
        .cpu_reset        (cpu_reset),
        .state_o          (state_o)
    );

    // ---- A3 warmboot command generator + IPAL primitive ---------------------
    // Interface contract: boot selector and warmboot handshake use rtl/boot modules.    // warmboot_ipal only drives the IPAL byte/word pins; GTP_IPAL_E2 must be
    // instantiated by the board top (this block). Both run on the same 27 MHz
    // clock. A3 asks for a ONE-cycle trigger, which the selector provides.
    wire        wb_busy;
    wire        wb_done;
    wire        wb_err;
    wire        ipal_cs_n;
    wire        ipal_rw_sel;
    wire [31:0] ipal_di;

    warmboot_ipal #(
        .PAD_A_WORDS   (100),
        .PAD_B_WORDS   (10),
        .PAD_NOP_WORDS (100),
        .BUS_BYTES     (4),
        .INSERT_ADDR   (1)
    ) u_warmboot (
        .clk         (clk),
        .rst_n       (key0_n),
        .trigger     (warmboot_start),
        .addr        (warmboot_addr),
        .busy        (wb_busy),
        .done        (wb_done),
        .err         (wb_err),
        .ipal_cs_n   (ipal_cs_n),
        .ipal_rw_sel (ipal_rw_sel),
        .ipal_di     (ipal_di)
    );

    // GTP_IPAL_E2: internal slave parallel interface (UG040005 §7.1.4 template
    // allows every output to be left unconnected; only DATA_WIDTH/IDCODE are
    // parameters in the synthesis model). RST_N is simulation-only per the
    // manual, tie it inactive. X32 = 32-bit word stream used by warmboot_ipal.
    GTP_IPAL_E2 #(
        .DATA_WIDTH ("X32"),
        .IDCODE     (32'hA5A5A5A5)
    ) u_ipal (
        .DO              (),
        .RBCRC_ERR       (),
        .RBCRC_VALID     (),
        .ECC_VALID       (),
        .ECC_INDEX       (),
        .SERROR          (),
        .DERROR          (),
        .SEU_FRAME_ADDR  (),
        .SEU_COLUMN_ADDR (),
        .SEU_REGION_ADDR (),
        .SEU_FRAME_NADDR (),
        .SEU_COLUMN_NADDR(),
        .SEU_REGION_NADDR(),
        .PRCFG_OVER      (),
        .PRCFG_ERR       (),
        .DRCFG_OVER      (),
        .DRCFG_ERR       (),
        .RST_N           (1'b1),
        .CLK             (clk),
        .CS_N            (ipal_cs_n),
        .RW_SEL          (ipal_rw_sel),
        .DI              (ipal_di)
    );

    // ---- status LEDs (active high) ----------------------------------------
    assign led[3:0] = state_o;
    assign led[4]   = mode_sel;
    assign led[5]   = bench_ready;
    assign led[6]   = bench_running;
    assign led[7]   = wb_busy | wb_done | wb_err;   // warmboot activity

    // ---- status UART: repeat {2'b00, mode_sel, ready, running, state} -----
    wire [7:0] status_byte = {2'b00, mode_sel, bench_ready, bench_running, state_o};

    reg [14:0] repeat_cnt;
    reg        tx_start;
    wire       tx_busy;

    always @(posedge clk) begin
        if (repeat_cnt == 15'd27000) begin     // ~1 ms between status bytes
            repeat_cnt <= 15'd0;
            tx_start   <= ~tx_busy;
        end else begin
            repeat_cnt <= repeat_cnt + 15'd1;
            tx_start   <= 1'b0;
        end
    end

    uart_tx_byte #(
        .DIV (234)                             // 27 MHz / 234 = 115384 baud (~0.16% fast vs 115200)
    ) u_uart (
        .clk      (clk),
        .rst_n    (key0_n),
        .data     (status_byte),
        .start    (tx_start),
        .busy     (tx_busy),
        .tx       (uart_tx)
    );

    // uart_rx is pinned/constrained but not used by this build; keep the input
    // alive so synthesis does not report a floating top-level port.
    wire [1:0] unused_inputs = {uart_rx, cpu_reset};
    wire       unused_ok     = &{1'b0, unused_inputs, flash_addr[0], warmboot_addr[0],
                                 warmboot_trigger, wb_busy, wb_done, wb_err};

endmodule

// =============================================================================
//  uart_tx_byte — minimal 8N1 transmitter (status channel only).
// =============================================================================
module uart_tx_byte #(
    parameter integer DIV = 234
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] data,
    input  wire       start,
    output wire       busy,
    output reg        tx
);
    localparam integer CW = (DIV <= 2) ? 2 : $clog2(DIV + 1);

    reg [CW-1:0] div_cnt;
    reg [3:0]    bit_idx;
    reg [9:0]    shift;
    reg          active;

    assign busy = active;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt <= {CW{1'b0}};
            bit_idx <= 4'd0;
            shift   <= 10'h3FF;      // idle line high
            active  <= 1'b0;
            tx      <= 1'b1;
        end else if (!active) begin
            tx <= 1'b1;
            if (start) begin
                // shift[0]=start(0), shift[8:1]=data, shift[9]=stop(1)
                shift   <= {1'b1, data, 1'b0};
                bit_idx <= 4'd1;
                div_cnt <= {CW{1'b0}};
                tx      <= 1'b0;     // drive the start bit immediately
                active  <= 1'b1;
            end
        end else begin
            if (div_cnt == DIV - 1) begin
                div_cnt <= {CW{1'b0}};
                if (bit_idx == 4'd9) begin
                    tx      <= 1'b1;         // stop bit
                    active  <= 1'b0;
                    bit_idx <= 4'd0;
                end else begin
                    tx      <= shift[bit_idx];
                    bit_idx <= bit_idx + 4'd1;
                end
            end else begin
                div_cnt <= div_cnt + 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
