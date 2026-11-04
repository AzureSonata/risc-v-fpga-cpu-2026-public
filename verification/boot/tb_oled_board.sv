// =============================================================================
//  tb_oled_board.sv — bring-up check for the A4 step-2 wrapper (selector + OLED)
//
//  Checks, against the REAL board wrapper (boot_selector_oled_board_top):
//    A. power-up with KEY1 held  -> mode_sel=1, FSM reaches BENCH_READY,
//       the A6 display layer selects the READY text (want_sel=2), issues one
//       frame transfer (start_frame pulse) and the I2C pads actually toggle
//       SCL on the pin (>= 8 falling edges).
//    B. KEY2 press after the qualified release -> FSM reaches BENCH_RUNNING and
//       the display layer switches to the RUNNING text (want_sel=3).
//    C. reset + power-up with KEY1 released -> KWS branch: the OLED stack is
//       held in reset (no start_frame, no SCL activity).
//
//  The panel itself is not modelled here (no I2C slave), so ACK-dependent
//  signals (oled_ok / frame_done) are only reported, not asserted. Pin-level
//  activity is what proves the display layer is wired and running.
// =============================================================================
`timescale 1ns/1ps

module tb_oled_board;

    localparam real CLK_PERIOD = 37.037037;   // 27 MHz
    localparam integer SET_CYC = 540_000;      // 20 ms  (SETTLE_MS at 27 MHz)
    localparam integer DEB_CYC = 270_000;      // 10 ms  (DEBOUNCE_MS)
    localparam integer RDY_CYC = 2_700_000;    // 100 ms (READY_HOLD_MS)
    localparam integer LOAD_CYC= 1_350_000;    // 50 ms  (bench image placeholder)

    reg clk = 1'b0;
    always #(CLK_PERIOD/2.0) clk = ~clk;

    reg key0_n = 1'b1;
    reg key1_n = 1'b1;
    reg key2_n = 1'b1;
    reg uart_rx = 1'b1;

    wire [7:0] led;
    wire       uart_tx;
    wire       oled_scl;
    wire       oled_sda;
    pullup (oled_scl);
    pullup (oled_sda);

    boot_selector_oled_board_top dut (
        .clk      (clk),
        .key0_n   (key0_n),
        .key1_n   (key1_n),
        .key2_n   (key2_n),
        .uart_rx  (uart_rx),
        .led      (led),
        .uart_tx  (uart_tx),
        .oled_scl (oled_scl),
        .oled_sda (oled_sda)
    );

    integer errors = 0;
    integer checks = 0;
    task check(input bit cond, input string what);
        begin
            checks = checks + 1;
            if (cond) $display("[OK  ] %s", what);
            else begin
                errors = errors + 1;
                $display("[FAIL] %s", what);
            end
        end
    endtask

    // SCL falling-edge counter (I2C bus activity on the package pin)
    integer scl_falls = 0;
    always @(negedge oled_scl) scl_falls = scl_falls + 1;

    // start_frame pulse counter from the display layer
    integer frame_starts = 0;
    always @(posedge clk) if (dut.oled_start_frame) frame_starts = frame_starts + 1;

    integer cyc = 0;
    always @(posedge clk) cyc = cyc + 1;

    task wait_state(input [3:0] st, input integer max_cyc, output bit ok);
        integer i;
        begin
            ok = 1'b0;
            for (i = 0; i < max_cyc; i = i + 1) begin
                @(posedge clk);
                if (dut.u_sel.state_o == st) begin
                    ok = 1'b1;
                    i  = max_cyc;
                end
            end
        end
    endtask

    task do_reset(input bit key1_hold);
        integer i;
        begin
            key0_n = 1'b0;
            key1_n = key1_hold ? 1'b0 : 1'b1;
            key2_n = 1'b1;
            for (i = 0; i < 20; i = i + 1) @(posedge clk);
            key0_n = 1'b1;
        end
    endtask

    bit ok;
    integer f0, c0;

    initial begin
        $display("=== tb_oled_board: A4 step-2 wrapper (selector + READY/RUNNING OLED) ===");

        // ---------------- Phase A: KEY1 held at power-up -> READY ----------
        do_reset(1'b1);
        ok = 1'b0;
        wait_state(4'h4, SET_CYC + RDY_CYC + 1000, ok);   // S_BENCH_READY
        check(ok, "A: FSM reaches BENCH_READY with KEY1 held");
        check(dut.mode_sel == 1'b1, "A: mode_sel = bench branch");
        check(dut.u_oled_page.want_sel == 2'd2, "A: display layer selects READY text (want_sel=2)");

        // wait for the renderer to push a frame onto the I2C pins
        f0 = frame_starts; c0 = scl_falls;
        for (integer i = 0; i < 4_000_000; i = i + 1) begin
            @(posedge clk);
            if ((frame_starts > f0) && (scl_falls > c0 + 16)) i = 4_000_000;
        end
        check(frame_starts > f0, "A: display layer starts a frame transfer in READY");
        check(scl_falls > c0 + 16, "A: I2C SCL toggles on the package pin (>=16 falling edges)");

        // ---------------- Phase B: KEY2 -> RUNNING -------------------------
        // The selector only honours KEY2 in WAIT_KEY2, after READY_HOLD_MS has
        // elapsed and after KEY2 has been released for a full debounce window.
        ok = 1'b0;
        wait_state(4'h5, RDY_CYC + DEB_CYC + 4000, ok);   // S_WAIT_KEY2
        check(ok, "B: FSM reaches WAIT_KEY2 after the READY window");
        key2_n = 1'b1;                       // released ...
        for (integer i = 0; i < DEB_CYC + 2000; i = i + 1) @(posedge clk);
        key2_n = 1'b0;                       // ... then a qualified press
        ok = 1'b0;
        wait_state(4'h6, LOAD_CYC + 4000, ok);   // S_BENCH_RUNNING
        check(ok, "B: FSM reaches BENCH_RUNNING after the qualified KEY2 press");
        check(dut.u_oled_page.want_sel == 2'd3, "B: display layer selects RUNNING text (want_sel=3)");

        // ---------------- Phase C: KWS branch keeps the panel quiet --------
        key2_n = 1'b1;
        do_reset(1'b0);                       // KEY1 released -> KWS branch
        f0 = frame_starts; c0 = scl_falls;
        for (integer i = 0; i < 2_000_000; i = i + 1) @(posedge clk);
        check(dut.u_oled_page.resetn == 1'b0, "C: OLED stack stays in reset on the KWS branch");
        check(frame_starts == f0, "C: no frame transfer on the KWS branch");
        check(scl_falls == c0, "C: no I2C activity on the KWS branch");

        $display("TB SUMMARY: checks=%0d errors=%0d scl_falls=%0d frames=%0d",
                 checks, errors, scl_falls, frame_starts);
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL");
        $finish;
    end

endmodule
