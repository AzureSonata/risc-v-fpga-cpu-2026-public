// =============================================================================
// tb_board_powerup.sv -- board-level power-up / key interaction regression (A4d)
//
// Purpose
//   Exercises the REAL board wrapper (fpga/boot/boot_selector_board_top.sv), not
//   only the bare selector, using the actual 27 MHz clock and the wrapper's real
//   millisecond parameters. This is the case that catches board-level wiring
//   mistakes which a direct-DUT test cannot see -- in particular the KEY0 reset
//   polarity: KEY0 is an active-LOW key, so the selector's active-low rst_n must
//   be the raw pin (idle = 1 = released). With rst_n inverted the selector is
//   held in reset whenever the key is idle and never leaves S_POWER_ON.
//
//   Checks (in order):
//     A. power-up with KEY1 released -> FSM leaves S_POWER_ON, selects KWS mode,
//        hands off immediately with warmboot_addr = 0x003A2000, one-cycle
//        warmboot_start, cpu_reset deasserted at handoff.
//     B. power-up with KEY1 held -> CoreMark mode, READY observable, KEY2 pressed
//        during READY is ignored, then release + re-arm + press -> BENCH_RUNNING,
//        finally handoff with warmboot_addr = 0x00741000.
//
//   The GTP_IPAL_E2 primitive is wrapped by gtp_ipal_e2_lint_stub.v here: this
//   test only observes the selector side, and the A3 case in run_iverilog.ps1
//   already elaborates the real vendor model against the real command sequence.
//
// Usage: iverilog -g2012 -Wall -o tb_board_powerup.vvp \
//            rtl/boot/boot_selector_top.sv rtl/boot/warmboot_ipal.sv \
//            fpga/boot/boot_selector_board_top.sv \
//            verification/boot/gtp_ipal_e2_lint_stub.v \
//            verification/boot/tb_board_powerup.sv
//        vvp tb_board_powerup.vvp
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_board_powerup;

    // 27 MHz board clock (D18)
    localparam real    CLK_NS  = 37.037037;

    // Wrapper timing at 27 MHz (these are the REAL production numbers)
    localparam integer SET_CYC = 540_000;     // SETTLE_MS   20  -> 20 ms
    localparam integer RDY_CYC = 2_700_000;   // READY_HOLD_MS 100 -> 100 ms
    localparam integer DEB_CYC = 270_000;     // DEBOUNCE_MS 10  -> 10 ms
    localparam integer LOAD_CYC = 1_350_000;  // LOAD_CYCLES (bench branch)

    localparam [31:0] KWS_IMAGE   = 32'h003A_2000;
    localparam [31:0] BENCH_IMAGE = 32'h0074_1000;

    // ---- DUT -----------------------------------------------------------------
    reg  clk    = 1'b0;
    reg  key0_n = 1'b0;   // start asserted: gives the async reset a real edge
    reg  key1_n = 1'b1;
    reg  key2_n = 1'b1;
    reg  uart_rx = 1'b1;
    wire [7:0] led;
    wire       uart_tx;

    boot_selector_board_top dut (
        .clk    (clk),
        .key0_n (key0_n),
        .key1_n (key1_n),
        .key2_n (key2_n),
        .uart_rx(uart_rx),
        .led    (led),
        .uart_tx(uart_tx));

    // ---- observable selector state (hierarchical, read-only) -----------------
    wire [3:0]  st        = dut.u_sel.state_o;
    wire        mode_sel  = dut.u_sel.mode_sel;
    wire [31:0] wb_addr   = dut.u_sel.warmboot_addr;
    wire [31:0] fl_addr   = dut.u_sel.flash_addr;
    wire        wb_start  = dut.u_sel.warmboot_start;
    wire        cpu_rst   = dut.u_sel.cpu_reset;
    wire        b_ready   = dut.u_sel.bench_ready;
    wire        b_running = dut.u_sel.bench_running;

    localparam [3:0] S_POWER_ON      = 4'd0,
                     S_SAMPLE_KEY    = 4'd1,
                     S_SELECT_MODE   = 4'd2,
                     S_LOAD_KWS      = 4'd3,
                     S_BENCH_READY   = 4'd4,
                     S_WAIT_KEY2     = 4'd5,
                     S_BENCH_RUNNING = 4'd6,
                     S_WARMBOOT      = 4'd7;

    integer checks     = 0;
    bit     a_done     = 1'b0;   // phase-A handshake: B must not disturb A
    integer errors     = 0;
    integer wbs_pulses = 0;

    always #(CLK_NS/2.0) clk = ~clk;

    always @(posedge clk) if (wb_start) wbs_pulses <= wbs_pulses + 1;

    // ---- helpers -------------------------------------------------------------
    task automatic check(input bit cond, input string what);
        checks = checks + 1;
        if (!cond) begin
            errors = errors + 1;
            $display("  FAIL  %s", what);
        end else begin
            $display("  ok    %s", what);
        end
    endtask

    task automatic wait_state(input [3:0] want, input integer max_cycles, output bit ok);
        integer n;
        ok = 1'b0;
        n  = 0;
        while (n < max_cycles) begin
            @(posedge clk);
            n = n + 1;
            if (st == want) begin ok = 1'b1; n = max_cycles; end
        end
    endtask

    task automatic wait_leave_power_on(input integer max_cycles, output bit ok);
        integer n;
        ok = 1'b0;
        n  = 0;
        while (n < max_cycles) begin
            @(posedge clk);
            n = n + 1;
            if (st != S_POWER_ON) begin ok = 1'b1; n = max_cycles; end
        end
    endtask

    bit ok;

    // ---- phase A: KEY1 released at power-up -> KWS image ---------------------
    initial begin
        $display("[phase A] power-up with KEY1 released (KWS path)");
        repeat (10) @(posedge clk);
        key0_n = 1'b1;                       // release KEY0: idle = high
        wait_leave_power_on(SET_CYC + 10_000, ok);
        check(ok, "A: FSM leaves S_POWER_ON after KEY0 is released (reset polarity)");
        check(st != S_POWER_ON, "A: selector is not stuck in reset");

        wait_state(S_WARMBOOT, SET_CYC + 10_000, ok);
        check(ok, "A: KWS branch reaches S_WARMBOOT (immediate handoff)");
        @(posedge clk);
        $display("        state=%0d mode_sel=%0d warmboot_addr=0x%08h flash_addr=0x%08h",
                 st, mode_sel, wb_addr, fl_addr);
        check(mode_sel == 1'b0,              "A: KEY1 released at power-on selects KWS mode");
        check(wb_addr  == KWS_IMAGE,         "A: warmboot address = 0x003A2000");
        check(fl_addr  == KWS_IMAGE,         "A: flash address    = 0x003A2000");
        check(cpu_rst  == 1'b0,              "A: cpu_reset released at handoff");
        check(wbs_pulses == 1,               "A: exactly one warmboot_start pulse");
        a_done = 1'b1;
    end

    // ---- phase B: KEY1 held at power-up -> READY -> KEY2 -> CPU image --------
    initial begin
        wait (a_done);                       // phase A checks complete
        $display("[phase B] power-up with KEY1 held (CoreMark path)");
        key0_n = 1'b0;                       // assert KEY0 (active-low reset)
        key1_n = 1'b0;                       // KEY1 held through power-up
        repeat (10) @(posedge clk);
        wbs_pulses = 0;
        key0_n = 1'b1;                       // release reset, KEY1 still held

        wait_state(S_BENCH_READY, SET_CYC + RDY_CYC + 20_000, ok);
        check(ok, "B: KEY1 held at power-on reaches S_BENCH_READY");
        check(mode_sel == 1'b1,              "B: mode_sel latched to CoreMark by KEY1 sample");
        check(b_ready  == 1'b1,              "B: bench_ready asserted (OLED/status)");
        check(cpu_rst  == 1'b1,              "B: cpu_reset held while selector runs");

        // KEY2 pressed while still in READY must be ignored
        key2_n = 1'b0;
        repeat (5000) @(posedge clk);
        check(b_running == 1'b0,             "B: KEY2 during READY is ignored (no BENCH_RUNNING)");

        // release KEY2, then the selector needs one full debounce window armed
        key2_n = 1'b1;
        wait_state(S_WAIT_KEY2, RDY_CYC + 20_000, ok);
        check(ok, "B: READY window ends in S_WAIT_KEY2");
        repeat (DEB_CYC + 5000) @(posedge clk);   // released long enough to re-arm
        key2_n = 1'b0;                            // real press after re-arm
        wait_state(S_BENCH_RUNNING, DEB_CYC + 20_000, ok);
        key2_n = 1'b1;
        check(ok, "B: KEY2 press after READY enters S_BENCH_RUNNING");
        check(b_running == 1'b1,             "B: bench_running observable");
        check(b_ready   == 1'b0,             "B: bench_ready drops once running");

        wait_state(S_WARMBOOT, LOAD_CYC + 20_000, ok);
        check(ok, "B: bench branch handoff reaches S_WARMBOOT");
        @(posedge clk);
        $display("        state=%0d mode_sel=%0d warmboot_addr=0x%08h flash_addr=0x%08h",
                 st, mode_sel, wb_addr, fl_addr);
        check(mode_sel == 1'b1,              "B: still CoreMark mode at handoff");
        check(wb_addr  == BENCH_IMAGE,       "B: warmboot address = 0x00741000");
        check(fl_addr  == BENCH_IMAGE,       "B: flash address    = 0x00741000");
        check(cpu_rst  == 1'b0,              "B: cpu_reset released at handoff");
        check(wbs_pulses == 1,               "B: exactly one warmboot_start pulse");

        $display("TB SUMMARY: checks=%0d errors=%0d warmboot_pulses(B)=%0d", checks, errors, wbs_pulses);
        $display("RESULT: %s", (errors == 0) ? "PASS" : "FAIL");
        $finish;
    end

    // ---- watchdog ------------------------------------------------------------
    initial begin
        #400_000_000;   // 400 ms sim-time guard
        $display("TB SUMMARY: TIMEOUT checks=%0d errors=%0d state=%0d", checks, errors, st);
        $display("RESULT: FAIL");
        $finish;
    end

endmodule
