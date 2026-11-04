// Physical board wrapper for the complete W3/KWS/audio application system.
// The board supplies the core 27 MHz clock and active-low KEY0 reset. Audio,
// watchdog arming, UART, LEDs, and the active-high relay command are mapped to
// the documented Pangu100Pro+ / MES-FMC-LPC-IO connector pins in the FDC file.
//
// App A2 (feat/mrev-kws-oled-20261104): the board-proven A6 OLED display layer
// is added here. It is a read-only observer of the final `fan_enable` output
// (the same net that drives the relay) and of nothing else: the KWS model,
// inference, audio frontend, decision, watchdog and fan control remain
// byte-identical v12demo logic. OLED init/timeout failure only clears the
// internal `oled_ok` flag and stops refreshes; it never resets or stalls the
// SoC. Display content is the fixed page "循芯而行 / RISC-V五级流水CPU" plus a
// live "FAN ON" / "FAN OFF" status line, refreshed only when that state
// changes (no animation, no recognition results).
`default_nettype none

module pangu100proplus_w3_kws_board_top #(
    parameter [1023:0] ROM_INIT_FILE = "build/w3-kws-live/kws_live.hex",
    parameter integer MEM_DEPTH = 16384,
    parameter integer MEM_AW = $clog2(MEM_DEPTH),
    parameter integer UART_DIV = 434,
    parameter integer M_MODE = 2,
    parameter integer TIMEOUT_DEFAULT = 704040,
    parameter integer LOGIT_OFF = 4000,
    parameter [31:0] ESTOP_WINDOW_DEFAULT = 32'd1350000,
    parameter ICACHE_ENABLE = 1'b1,
    parameter DCACHE_ENABLE = 1'b1
)(
    input  wire       clk,
    input  wire       rstn,
    input  wire       uart_rx,
    output wire       uart_tx,
    input  wire       estop_arm,
    input  wire       mic_sd,
    output wire       mic_bclk,
    output wire       mic_lrck,
    output wire       fan_enable,
    output wire [7:0] led,
    // App A2 OLED: open-drain I2C on J3-35 / J3-33 (Bank L6, 3.3 V).
    inout  wire       oled_scl,
    inout  wire       oled_sda
);
    wire estop_trip;
    wire kws_irq;
    wire [7:0] soc_led;
    wire [31:0] gpio_out;
    wire trace0_valid, trace0_trap, trace1_valid, trace1_trap;
    wire [31:0] trace0_pc, trace0_instr, trace0_cause;
    wire [31:0] trace1_pc, trace1_instr, trace1_cause, pc_debug;

    pangu100proplus_w3_kws_top #(
        .ROM_INIT_FILE(ROM_INIT_FILE),
        .MEM_DEPTH(MEM_DEPTH), .MEM_AW(MEM_AW), .UART_DIV(UART_DIV),
        .M_MODE(M_MODE), .TIMEOUT_DEFAULT(TIMEOUT_DEFAULT),
        .LOGIT_OFF(LOGIT_OFF), .ESTOP_WINDOW_DEFAULT(ESTOP_WINDOW_DEFAULT),
        .ICACHE_ENABLE(ICACHE_ENABLE), .DCACHE_ENABLE(DCACHE_ENABLE),
        .AUDIO_ENABLE(1'b1)
    ) u_system (
        .clk(clk), .rstn(rstn), .gpio_in(32'd0), .uart_rx(uart_rx),
        .estop_arm(estop_arm), .mic_sd(mic_sd),
        .mic_bclk(mic_bclk), .mic_lrck(mic_lrck),
        .estop_trip(estop_trip), .fan_enable(fan_enable), .kws_irq(kws_irq),
        .led(soc_led), .gpio_out(gpio_out), .uart_tx(uart_tx),
        .trace0_valid(trace0_valid), .trace0_pc(trace0_pc),
        .trace0_instr(trace0_instr), .trace0_trap(trace0_trap),
        .trace0_cause(trace0_cause), .trace1_valid(trace1_valid),
        .trace1_pc(trace1_pc), .trace1_instr(trace1_instr),
        .trace1_trap(trace1_trap), .trace1_cause(trace1_cause),
        .pc_debug(pc_debug)
    );

    // LED7 is the board-visible watchdog trip indicator. GPIO[6:0] retain the
    // existing software/debug display; GPIO[31] separately drives fan_enable.
    assign led = {estop_trip, gpio_out[6:0]};

    // ------------------------------------------------------------------
    // App A2 OLED display layer (A6 assets, unchanged behaviour).
    // fan_enable is sampled as an input only; OLED has no path back into
    // the SoC, the audio frontend, the watchdog or the relay output.
    // bench_mode/bench_running are tied 0 so the status line always shows
    // the live FAN ON / FAN OFF state.
    // ------------------------------------------------------------------
    wire        oled_fb_we;
    wire [9:0]  oled_fb_addr;
    wire [7:0]  oled_fb_data;
    wire        oled_start_frame;
    wire        oled_page_busy;
    wire        oled_frame_done;
    wire        oled_error;
    wire [15:0] oled_refresh_count;
    wire        oled_ok;
    wire [31:0] oled_frame_count;
    wire        oled_busy;
    wire        oled_seen_ack;

    oled_page_ctrl u_oled_page (
        .clk(clk),
        .resetn(rstn),
        .fan_enable(fan_enable),
        .bench_mode(1'b0),
        .bench_running(1'b0),
        .fb_we(oled_fb_we),
        .fb_addr(oled_fb_addr),
        .fb_data(oled_fb_data),
        .start_frame(oled_start_frame),
        .busy(oled_page_busy),
        .frame_done(oled_frame_done),
        .oled_error(oled_error),
        .refresh_count(oled_refresh_count),
        .oled_ok(oled_ok)
    );

    oled_ssd1306_i2c_pads #(
        .SYS_HZ(27_000_000),
        .I2C_TICK_HZ(400_000)
    ) u_oled_pads (
        .clk(clk),
        .resetn(rstn),
        .new_frame(oled_start_frame),
        .fb_we(oled_fb_we),
        .fb_addr(oled_fb_addr),
        .fb_data(oled_fb_data),
        .scl(oled_scl),
        .sda(oled_sda),
        .frame_done(oled_frame_done),
        .frame_count(oled_frame_count),
        .busy(oled_busy),
        .error(oled_error),
        .seen_ack(oled_seen_ack)
    );
endmodule

`default_nettype wire
