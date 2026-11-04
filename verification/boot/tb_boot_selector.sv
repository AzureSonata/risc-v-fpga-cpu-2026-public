// =============================================================================
//  tb_boot_selector.sv — self-checking testbench for boot_selector_top (A4)
//
//  Cases covered (kept in sync with README.md):
//    T1  no key at power-up            -> KWS path, no bench activity, one handoff
//    T2  KEY1 held at power-up         -> CoreMark READY -> full KEY2 press ->
//                                          BENCH_RUNNING -> warmboot to bench image
//    T3  KEY2 pressed outside READY    -> ignored (power-on / LOAD_KWS)
//    T4  glitches shorter than debounce-> filtered (KEY1 mode sample, KEY2 start)
//    T5  reset behaviour               -> rst_n mid-run restarts; KEY0 pass-through
//                                          holds CPU reset and aborts the handoff
//
//  Simulation scaling: the DUT derives its timeouts from CLK_HZ x *_MS, so the
//  bench passes CLK_HZ=27000 with 1-2 ms parameters. That keeps every counter
//  small while preserving the exact same cycle-level behaviour as 27 MHz
//  (all timeouts are cycle counters; only the nominal wall-time meaning of the
//  "ms" parameters changes).
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_boot_selector;

    // ---- bench-visible configuration (must match DUT parameters) ----------
    localparam [31:0]  FLASH_BASE = 32'h0000_0000;
    localparam [31:0]  KWS_OFF    = 32'h0000_0000;
    localparam [31:0]  BENCH_OFF  = 32'h0008_0000;
    localparam [31:0]  KWS_IMAGE   = FLASH_BASE + KWS_OFF;
    localparam [31:0]  BENCH_IMAGE = FLASH_BASE + BENCH_OFF;
    localparam integer LOAD_CYCLES = 20;
    localparam integer WB_PULSE    = 5;
    localparam integer DEB_CYCLES  = 27;   // CLK_HZ/1000 * DEBOUNCE_MS   = 27
    localparam integer SET_CYCLES  = 54;   // CLK_HZ/1000 * SETTLE_MS     = 54
    localparam integer RDY_CYCLES  = 27;   // CLK_HZ/1000 * READY_HOLD_MS = 27

    // ---- DUT FSM codes ---------------------------------------------------
    localparam [3:0] S_POWER_ON      = 4'd0;
    localparam [3:0] S_SAMPLE_KEY    = 4'd1;
    localparam [3:0] S_SELECT_MODE   = 4'd2;
    localparam [3:0] S_LOAD_KWS      = 4'd3;
    localparam [3:0] S_BENCH_READY   = 4'd4;
    localparam [3:0] S_WAIT_KEY2     = 4'd5;
    localparam [3:0] S_BENCH_RUNNING = 4'd6;
    localparam [3:0] S_WARMBOOT      = 4'd7;

    // ---- clock / reset / keys -------------------------------------------
    reg clk    = 1'b0;
    reg rst_n  = 1'b0;
    reg key0_n = 1'b1;
    reg key1_n = 1'b1;
    reg key2_n = 1'b1;

    wire        mode_sel;
    wire [31:0] flash_addr;
    wire        bench_ready;
    wire        bench_running;
    wire        warmboot_trigger;
    wire        warmboot_start;
    wire [31:0] warmboot_addr;
    wire        cpu_reset;
    wire [3:0]  state_o;

    always #5 clk = ~clk;   // 10 ns period; cycle counts are what matter here

    boot_selector_top #(
        .CLK_HZ            (27_000),
        .DEBOUNCE_MS       (1),
        .SETTLE_MS         (2),
        .READY_HOLD_MS     (1),
        .LOAD_CYCLES       (LOAD_CYCLES),
        .WARMBOOT_PULSE    (WB_PULSE),
        .FLASH_BASE        (FLASH_BASE),
        .KWS_IMAGE_OFFSET  (KWS_OFF),
        .BENCH_IMAGE_OFFSET(BENCH_OFF)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .key0_n           (key0_n),
        .key1_n           (key1_n),
        .key2_n           (key2_n),
        .mode_sel         (mode_sel),
        .flash_addr       (flash_addr),
        .bench_ready      (bench_ready),
        .bench_running    (bench_running),
        .warmboot_trigger (warmboot_trigger),
        .warmboot_start   (warmboot_start),
        .warmboot_addr    (warmboot_addr),
        .cpu_reset        (cpu_reset),
        .state_o          (state_o)
    );

    // ---- scoreboard / monitors ------------------------------------------
    integer checks = 0;
    integer errors = 0;
    integer wb_pulses = 0;
    integer wb_width = 0;
    integer wb_max_width = 0;
    integer wb_active = 0;
    integer wbs_pulses = 0;
    integer wbs_width = 0;
    integer wbs_max_width = 0;
    integer wbs_active = 0;
    integer bench_ready_cnt = 0;
    integer bench_running_cnt = 0;
    reg [3:0] state_q = 4'hx;

    always @(posedge clk) begin
        if (bench_ready) bench_ready_cnt = bench_ready_cnt + 1;
        if (bench_running) bench_running_cnt = bench_running_cnt + 1;

        if (warmboot_trigger) begin
            if (!wb_active) begin
                wb_active = 1;
                wb_pulses = wb_pulses + 1;
                wb_width  = 1;
            end else begin
                wb_width = wb_width + 1;
            end
        end else if (wb_active) begin
            wb_active = 0;
            if (wb_width > wb_max_width) wb_max_width = wb_width;
        end

        // A3 asks for a ONE-cycle start pulse; record it separately.
        if (warmboot_start) begin
            if (!wbs_active) begin
                wbs_active = 1;
                wbs_pulses = wbs_pulses + 1;
                wbs_width  = 1;
            end else begin
                wbs_width = wbs_width + 1;
            end
        end else if (wbs_active) begin
            wbs_active = 0;
            if (wbs_width > wbs_max_width) wbs_max_width = wbs_width;
        end

        if ((state_o !== state_q) && (state_o !== 4'hx)) begin
            $display("[%0t] state %0d -> %0d (key0_n=%b key1_n=%b key2_n=%b mode=%b ready=%b run=%b wb=%b cpu_rst=%b)",
                     $time, state_q, state_o, key0_n, key1_n, key2_n,
                     mode_sel, bench_ready, bench_running, warmboot_trigger, cpu_reset);
            state_q <= state_o;
        end
    end

    // ---- helpers ---------------------------------------------------------
    task automatic check(input bit cond, input string what);
        begin
            checks = checks + 1;
            if (cond) begin
                $display("  PASS: %0s", what);
            end else begin
                errors = errors + 1;
                $display("  FAIL: %0s (state=%0d mode=%b ready=%b run=%b wb=%b addr=%h)",
                         what, state_o, mode_sel, bench_ready, bench_running,
                         warmboot_trigger, warmboot_addr);
            end
        end
    endtask

    task automatic clear_monitors;
        begin
            bench_ready_cnt   = 0;
            bench_running_cnt = 0;
            wb_pulses         = 0;
            wb_width          = 0;
            wb_max_width      = 0;
            wb_active         = 0;
            wbs_pulses        = 0;
            wbs_width         = 0;
            wbs_max_width     = 0;
            wbs_active        = 0;
        end
    endtask

    task automatic do_reset;
        begin
            rst_n  = 1'b0;
            key0_n = 1'b1;
            key1_n = 1'b1;
            key2_n = 1'b1;
            repeat (5) @(posedge clk);
            rst_n = 1'b1;
            repeat (3) @(posedge clk);
            state_q = 4'hx;
        end
    endtask

    task automatic key_down(input integer which);
        begin
            case (which)
                0: key0_n = 1'b0;
                1: key1_n = 1'b0;
                2: key2_n = 1'b0;
            endcase
        end
    endtask

    task automatic key_up(input integer which);
        begin
            case (which)
                0: key0_n = 1'b1;
                1: key1_n = 1'b1;
                2: key2_n = 1'b1;
            endcase
        end
    endtask

    task automatic wait_cycles(input integer n);
        repeat (n) @(posedge clk);
    endtask

    // Wait until state matches; ok=1 if reached within max_cycles.
    task automatic wait_state(input [3:0] st, input integer max_cycles, output bit ok);
        integer i;
        begin
            ok = 0;
            for (i = 0; i < max_cycles; i = i + 1) begin
                @(posedge clk);
                if (state_o === st) begin
                    ok = 1;
                    i  = max_cycles;
                end
            end
        end
    endtask

    // Let a warmboot pulse complete and be scored by the monitor.
    task automatic wait_pulse_scored;
        begin
            wait_cycles(WB_PULSE * 3 + 20);
        end
    endtask

    // ---- test bodies -----------------------------------------------------
    bit ok;

    initial begin
        $display("================================================================");
        $display(" tb_boot_selector -- A4 boot selector (P2)");
        $display(" params: SET=%0d DEB=%0d RDY=%0d LOAD=%0d WB_PULSE=%0d",
                 SET_CYCLES, DEB_CYCLES, RDY_CYCLES, LOAD_CYCLES, WB_PULSE);
        $display("================================================================\n");

        // ---------------------------------------------------------------
        // T1: no key at power-up -> KWS image, no bench activity
        // ---------------------------------------------------------------
        $display("--- T1: power-up with no key -> KWS ---");
        clear_monitors;
        do_reset;
        wait_state(S_WARMBOOT, SET_CYCLES + 50, ok);
        wait_pulse_scored;
        check(ok,                         "T1 reached WARMBOOT");
        check(mode_sel == 1'b0,           "T1 mode_sel == KWS(0)");
        check(flash_addr == KWS_IMAGE,    "T1 flash_addr == KWS image");
        check(warmboot_addr == KWS_IMAGE, "T1 warmboot_addr == KWS image");
        check(bench_ready_cnt == 0,       "T1 bench_ready never asserted");
        check(bench_running_cnt == 0,     "T1 bench_running never asserted");
        check(wb_pulses == 1,             "T1 exactly one warmboot pulse");
        check(wb_max_width == WB_PULSE,   "T1 warmboot pulse width == WARMBOOT_PULSE");
        check(cpu_reset == 1'b0,          "T1 CPU released after handoff");
        check(wbs_pulses == 1,            "T1 warmboot_start issued exactly once (A3 trigger)");
        check(wbs_max_width == 1,         "T1 warmboot_start is a one-cycle pulse");

        // ---------------------------------------------------------------
        // T2: KEY1 held at power-up -> READY -> full KEY2 press -> RUNNING
        // ---------------------------------------------------------------
        $display("\n--- T2: KEY1 held at power-up -> CoreMark READY -> KEY2 -> RUNNING ---");
        clear_monitors;
        key_down(1);
        do_reset;
        key_down(1);                      // keep KEY1 held across reset
        wait_state(S_BENCH_READY, SET_CYCLES + 50, ok);
        check(ok,                         "T2 reached BENCH_READY");
        check(mode_sel == 1'b1,           "T2 mode_sel == CoreMark(1) latched at power-on");
        check(bench_ready == 1'b1,        "T2 bench_ready asserted in BENCH_READY");
        check(cpu_reset == 1'b1,          "T2 CPU still held in reset during selector");

        // KEY2 already held while in BENCH_READY must NOT start the bench: the
        // press edge has to begin inside WAIT_KEY2.
        key_down(2);
        wait_cycles(RDY_CYCLES + DEB_CYCLES + 20);
        check(((state_o == S_BENCH_READY) || (state_o == S_WAIT_KEY2)) && (bench_running == 1'b0),
              "T2 in-flight KEY2 press during READY ignored");
        key_up(2);
        wait_state(S_WAIT_KEY2, RDY_CYCLES + 2 * DEB_CYCLES + 50, ok);
        check(ok,                         "T2 entered WAIT_KEY2 after KEY2 released");
        check(bench_ready == 1'b1,        "T2 READY stays visible in WAIT_KEY2");

        // KEY2 must be qualified released for one debounce window after READY
        // before a press is accepted (full press edge requirement).
        wait_cycles(DEB_CYCLES + 10);
        state_q = state_o;
        // Now a real full press edge inside WAIT_KEY2.
        key_down(2);
        wait_state(S_BENCH_RUNNING, DEB_CYCLES + 20, ok);
        check(ok,                         "T2 KEY2 full press -> BENCH_RUNNING");
        check(bench_running == 1'b1,      "T2 bench_running asserted");
        check(bench_ready == 1'b0,        "T2 READY deasserted in RUNNING");
        key_up(2);
        wait_state(S_WARMBOOT, LOAD_CYCLES + 50, ok);
        wait_pulse_scored;
        check(ok,                         "T2 reached WARMBOOT after RUNNING");
        check(mode_sel == 1'b1,           "T2 mode_sel still CoreMark");
        check(warmboot_addr == BENCH_IMAGE, "T2 warmboot_addr == bench image");
        check(flash_addr == BENCH_IMAGE,  "T2 flash_addr == bench image");
        check(wb_pulses == 1,             "T2 exactly one warmboot pulse");
        check(cpu_reset == 1'b0,          "T2 CPU released after handoff");
        check(wbs_pulses == 1,            "T2 exactly one warmboot_start pulse (A3 trigger)");
        check(wbs_max_width == 1,         "T2 warmboot_start is a one-cycle pulse");

        // ---------------------------------------------------------------
        // T3: KEY2 pressed outside READY is ignored
        // ---------------------------------------------------------------
        $display("\n--- T3: KEY2 outside READY is ignored ---");
        clear_monitors;
        do_reset;
        key_down(2);                      // pressed during power-on settle
        wait_state(S_WARMBOOT, SET_CYCLES + 50, ok);
        check(ok,                         "T3 KWS handoff reached despite KEY2 held");
        check(mode_sel == 1'b0,           "T3 mode still KWS");
        wait_pulse_scored;
        check(bench_running_cnt == 0,     "T3 bench_running never asserted");
        check(bench_ready_cnt == 0,       "T3 bench_ready never asserted");
        check(warmboot_addr == KWS_IMAGE, "T3 handoff to KWS image");
        check(flash_addr == KWS_IMAGE,    "T3 flash_addr == KWS image");
        key_up(2);

        // A KEY2 press arriving after the KWS branch has already handed off
        // (inside the warmboot pulse window) must neither re-trigger warmboot
        // nor change the selected mode.
        clear_monitors;
        do_reset;
        wait_state(S_WARMBOOT, SET_CYCLES + 50, ok);
        check(ok,                         "T3b KWS handoff reached");
        key_down(2);                      // press inside the handoff window
        wait_cycles(WB_PULSE + 20);
        check(wb_pulses == 1,             "T3b KEY2 in handoff window keeps one pulse");
        check(mode_sel == 1'b0,           "T3b late KEY2 does not change mode");
        check(bench_running_cnt == 0,     "T3b bench_running never asserted");
        key_up(2);

        // ---------------------------------------------------------------
        // T4: glitches shorter than the debounce window are filtered
        // ---------------------------------------------------------------
        $display("\n--- T4: debounce / glitch rejection ---");
        // (a) KEY1 glitch (10 cycles < 27) around power-on -> must stay KWS
        clear_monitors;
        do_reset;
        key_down(1);
        wait_cycles(10);
        key_up(1);
        wait_state(S_WARMBOOT, SET_CYCLES + 50, ok);
        wait_pulse_scored;
        check(ok,                         "T4a selector completes");
        check(mode_sel == 1'b0,           "T4a KEY1 glitch ignored -> KWS");
        check(bench_ready_cnt == 0,       "T4a no READY from KEY1 glitch");

        // (b) KEY2 glitches in WAIT_KEY2 do not start the bench
        clear_monitors;
        key_down(1);
        do_reset;
        key_down(1);
        wait_state(S_WAIT_KEY2, SET_CYCLES + RDY_CYCLES + 50, ok);
        check(ok,                         "T4b reached WAIT_KEY2");
        wait_cycles(DEB_CYCLES + 10);     // qualify a released KEY2 level
        repeat (2) begin
            key_down(2);
            wait_cycles(10);              // 10 < DEB_CYCLES
            key_up(2);
            wait_cycles(DEB_CYCLES + 10); // let the filter return to idle
        end
        check(state_o == S_WAIT_KEY2,     "T4b KEY2 glitches did not start bench");
        check(bench_running_cnt == 0,     "T4b bench_running still 0");
        key_down(2);                      // now a real press
        wait_state(S_BENCH_RUNNING, DEB_CYCLES + 20, ok);
        check(ok,                         "T4b real KEY2 press starts bench");
        key_up(1);
        key_up(2);

        // ---------------------------------------------------------------
        // T5: reset behaviour (rst_n restart + KEY0 pass-through)
        // ---------------------------------------------------------------
        $display("\n--- T5: reset behaviour ---");
        // (a) rst_n asserted mid-run -> back to POWER_ON, outputs cleared
        clear_monitors;
        key_down(1);
        do_reset;
        key_down(1);
        wait_state(S_BENCH_READY, SET_CYCLES + 50, ok);
        check(ok,                         "T5a reached BENCH_READY before reset");
        rst_n = 1'b0;
        wait_cycles(3);
        check(state_o == S_POWER_ON,      "T5a rst_n -> POWER_ON");
        check(mode_sel == 1'b0,           "T5a mode_sel cleared by reset");
        check(bench_ready == 1'b0,        "T5a bench_ready cleared by reset");
        check(warmboot_trigger == 1'b0,   "T5a no warmboot while reset");
        check(cpu_reset == 1'b1,          "T5a CPU held in reset");
        rst_n = 1'b1;
        key_up(1);
        wait_cycles(5);

        // (b) KEY0 held: CPU reset passes through, selector cannot hand off
        clear_monitors;
        do_reset;
        key_down(0);
        wait_cycles(200);
        check(state_o == S_POWER_ON,      "T5b KEY0 holds selector in POWER_ON");
        check(cpu_reset == 1'b1,          "T5b KEY0 asserts cpu_reset (pass-through)");
        check(warmboot_trigger == 1'b0,   "T5b no warmboot while KEY0 held");
        check(bench_ready == 1'b0,        "T5b no READY while KEY0 held");
        key_up(0);
        wait_cycles(5);
        wait_state(S_WARMBOOT, SET_CYCLES + RDY_CYCLES + LOAD_CYCLES + 300, ok);
        wait_pulse_scored;
        check(ok,                         "T5b selector resumes after KEY0 release");
        check(mode_sel == 1'b0,           "T5b default mode is KWS");
        check(wb_pulses == 1,             "T5b handoff issued after KEY0 release");

        // ---------------------------------------------------------------
        $display("\n================================================================");
        $display(" TB SUMMARY: checks=%0d errors=%0d warmboot_pulses=%0d max_pulse_width=%0d",
                 checks, errors, wb_pulses, wb_max_width);
        if (errors == 0) begin
            $display(" RESULT: PASS");
            $display("================================================================");
            $finish;
        end else begin
            $display(" RESULT: FAIL");
            $display("================================================================");
            $fatal(1, "tb_boot_selector: %0d check(s) failed", errors);
        end
    end

    // Hard timeout guard.
    initial begin
        #2000000;
        $display(" RESULT: FAIL (global timeout)");
        $fatal(1, "tb_boot_selector: global timeout");
    end

endmodule

`default_nettype wire
