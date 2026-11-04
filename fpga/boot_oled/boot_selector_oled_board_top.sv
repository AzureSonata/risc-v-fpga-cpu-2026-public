// =============================================================================
//  boot_selector_oled_board_top.sv — A4 second step: boot selector + READY OLED
//
//  Same wrapper contents as fpga/boot/boot_selector_board_top.sv (A4b/A4c/A4d),
//  plus the A5b/A6 OLED stack so that a board operator can see the selector
//  state during bring-up:
//
//    BENCH_READY / WAIT_KEY2 : OLED line 3 shows "READY"
//    BENCH_RUNNING           : OLED line 3 shows "RUNNING"
//    every other state       : the OLED stack is held in reset, no refresh
//                              (the KWS branch never touches the panel)
//
//  CPU/KWS image logic is unchanged: u_sel parameters, warmboot address
//  constants (KWS 0x003A2000 / CPU 0x00741000) and the A3/A4 warmboot handshake
//  are bit-identical to fpga/boot/boot_selector_board_top.sv.
//
//  Contents
//    u_sel        : rtl/boot/boot_selector_top.sv          (A4 selector)
//    u_warmboot   : rtl/boot/warmboot_ipal.sv              (A3, frozen 121c5d8a)
//    u_ipal       : GTP_IPAL_E2 primitive (X32, IDCODE 0xA5A5A5A5)
//    u_oled_page  : rtl/periph/oled_page_ctrl.sv           (A6 display layer)
//    u_oled_pads  : rtl/periph/oled_ssd1306_i2c_pads.sv    (A5b/A6 driver + I2C pads)
//    u_uart       : status byte every ~1 ms at ~115 kbaud (bring-up channel)
//
//  OLED stack reset gating: oled_resetn = key0_n & mode_sel.
//  mode_sel is only set once KEY1 has been sampled, so in the KWS branch
//  (mode_sel = 0) the panel stays in reset and is never written. The READY
//  text therefore only ever appears on the CoreMark/bench branch.
//
//  Panel pins (A5/A7 evidence, fpga/boot_oled/boot_selector_oled.fdc):
//  SCL = W24, SDA = AA25, both open drain, pull-ups on the panel module.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module boot_selector_oled_board_top (
    input  wire       clk,        // 27 MHz core-board oscillator (D18)
    input  wire       key0_n,     // KEY0 = C22, active low (also board reset)
    input  wire       key1_n,     // KEY1 = C23, active low
    input  wire       key2_n,     // KEY2 = B22, active low
    input  wire       uart_rx,    // board USB-UART RX (B24), unused (kept pinned)
    output wire [7:0] led,        // active-high LEDs
    output wire       uart_tx,    // board USB-UART TX (C24)
    inout  wire       oled_scl,   // OLED I2C SCL (W24, open drain)
    inout  wire       oled_sda    // OLED I2C SDA (AA25, open drain)
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

    // ---- A4 selector (identical parameters to fpga/boot/board top) ----------
    boot_selector_top #(
        .KEY_ACTIVE_LOW     (1'b1),
        .CLK_HZ             (CLK_HZ),
        .DEBOUNCE_MS        (10),
        .SETTLE_MS          (20),
        .READY_HOLD_MS      (100),
        .LOAD_CYCLES        (1_350_000),   // bench-image load placeholder (bench branch only)
        .WARMBOOT_PULSE     (16),
        .FLASH_BASE         (32'h0000_0000),
        // P1 flash layout (A3 WARMBOOT_IF.md §4 / A9 cfg_gen_multi_file):
        //   golden 0x0000_4000, KWS 0x003A_2000, CPU 0x0074_1000.
        .KWS_IMAGE_OFFSET   (32'h003A_2000),
        .BENCH_IMAGE_OFFSET (32'h0074_1000)
    ) u_sel (
        .clk              (clk),
        // KEY0 is active LOW: idle = 1 = released, so rst_n takes the raw pin.
        .rst_n            (key0_n),
        .key0_n           (key0_n),
        .key1_n           (key1_n),
        .key2_n           (key2_n),
        .mode_sel         (mode_sel),
        .flash_addr       (flash_addr),
        .bench_ready      (bench_ready),
        .bench_running    (bench_running),
        .warmboot_trigger (warmboot_trigger),
        .warmboot_start   (warmboot_start),   // one-cycle pulse for A3 trigger
        .warmboot_addr    (warmboot_addr),
        .cpu_reset        (cpu_reset),
        .state_o          (state_o)
    );

    // ---- A3 warmboot command generator + IPAL primitive ---------------------
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

    // ---- A5b/A6 OLED stack (READY / RUNNING status line only) --------------
    // The stack is held in reset unless the selector is on the bench branch, so
    // the panel only ever displays READY / RUNNING while waiting for KEY2 and
    // while the benchmark image is running. Nothing is drawn on the KWS branch.
    wire        oled_resetn   = key0_n & mode_sel;
    wire        oled_fb_we;
    wire [9:0]  oled_fb_addr;
    wire [7:0]  oled_fb_data;
    wire        oled_start_frame;
    wire        oled_page_busy;
    wire        oled_frame_done;
    wire        oled_error;
    wire        oled_ok;
    wire [15:0] oled_refresh_count;
    wire [31:0] oled_frame_count;
    wire        oled_drv_busy;
    wire        oled_seen_ack;

    oled_page_ctrl u_oled_page (
        .clk           (clk),
        .resetn        (oled_resetn),
        .fan_enable    (1'b0),
        .bench_mode    (mode_sel),
        .bench_running (bench_running),
        .fb_we         (oled_fb_we),
        .fb_addr       (oled_fb_addr),
        .fb_data       (oled_fb_data),
        .start_frame   (oled_start_frame),
        .busy          (oled_page_busy),
        .frame_done    (oled_frame_done),
        .oled_error    (oled_error),
        .refresh_count (oled_refresh_count),
        .oled_ok       (oled_ok)
    );

    oled_ssd1306_i2c_pads #(
        .SYS_HZ      (CLK_HZ),
        .I2C_TICK_HZ (400_000)
    ) u_oled_pads (
        .clk         (clk),
        .resetn      (oled_resetn),
        .new_frame   (oled_start_frame),
        .fb_we       (oled_fb_we),
        .fb_addr     (oled_fb_addr),
        .fb_data     (oled_fb_data),
        .scl         (oled_scl),
        .sda         (oled_sda),
        .frame_done  (oled_frame_done),
        .frame_count (oled_frame_count),
        .busy        (oled_drv_busy),
        .error       (oled_error),
        .seen_ack    (oled_seen_ack)
    );

    // ---- status LEDs (active high) ----------------------------------------
    // led[7] keeps the warmboot activity meaning of the non-OLED build; OLED
    // acknowledge visibility is folded in so bring-up can see an ACK without
    // touching the panel wiring.
    assign led[3:0] = state_o;
    assign led[4]   = mode_sel;
    assign led[5]   = bench_ready;
    assign led[6]   = bench_running;
    assign led[7]   = wb_busy | wb_done | wb_err | oled_seen_ack;

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
        .DIV (234)                             // 27 MHz / 234 = 115384 baud
    ) u_uart (
        .clk      (clk),
        .rst_n    (key0_n),
        .data     (status_byte),
        .start    (tx_start),
        .busy     (tx_busy),
        .tx       (uart_tx)
    );

    // Keep constrained-but-unused inputs / observability outputs alive so the
    // synthesiser does not report floating top-level ports.
    wire [2:0] unused_inputs = {uart_rx, cpu_reset, oled_ok};
    wire       unused_ok     = &{1'b0, unused_inputs, flash_addr[0], warmboot_addr[0],
                                 warmboot_trigger, wb_busy, wb_done, wb_err,
                                 oled_page_busy, oled_drv_busy, oled_refresh_count[0],
                                 oled_frame_count[0], oled_error};

endmodule

// =============================================================================
//  uart_tx_byte — minimal 8N1 transmitter (status channel only).
//  Same implementation as fpga/boot/boot_selector_board_top.sv.
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
