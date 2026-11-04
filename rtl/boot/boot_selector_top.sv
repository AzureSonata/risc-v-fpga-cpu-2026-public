// =============================================================================
//  boot_selector_top.sv — Multi-image boot selector (A4 / MULTIBOOT P2)
//
//  Scope: standalone 27 MHz single-clock RTL. NO CPU / cache / memory subsystem
//  is instantiated or loaded here: during selector operation the CPU is held in
//  reset (cpu_reset=1) and nothing is fetched/executed. The selector only
//  decides which flash image to hand to the A3 warmboot block and pulses it.
//
//  Power-up semantics (per user requirement):
//    * default (no key)        : KWS image
//    * KEY1 held at power-on   : CoreMark bench image, "READY" shown to OLED
//    * KEY2 pressed in READY   : start the bench image (warmboot to CPU image)
//    * KEY0 held               : CPU held in reset, selector restarts
//
//  KEY polarity: MES2L676-100HP user keys are active-low (unpressed=1, pressed=0);
//  see hardware guide 2.1.3.4.1 and fpga/constraints/pangu100proplus_w3_kws.fdc.
//  KEY pins (100HP, PG2L100H-676): KEY0=C22, KEY1=C23, KEY2=B22  [A8 to confirm
//  against the final board constraint file; see README "TBD" section].
//
//  Design notes:
//    * KEY1/KEY2 are 2-FF synchronized then debounced with a stable-level
//      counter (default 10 ms). A level change is only accepted after it has
//      been stable for the full window, so glitches shorter than that are
//      filtered (testbench case T4).
//    * KEY0 is NOT debounced: it is the CPU reset path and must pass through
//      without the selector being able to block/swallow it ("直通/不阻挡").
//      2-FF synchronization only (metastability), then it drives cpu_reset and
//      restarts the selector FSM.
//    * KEY2 is only accepted in the CoreMark READY branch: BENCH_READY anchors
//      a released level, then WAIT_KEY2 additionally requires KEY2 to stay
//      de-bounced released for one full DEBOUNCE window before a press counts,
//      so a press already in flight when READY ends can never be taken as a
//      fresh press edge. In every other state KEY2 has no effect (T3).
//    * All FSM states are exported on state_o for OLED/debug instrumentation.
//
//  Handoff semantics (pinned by the user requirement, 2026-11-04):
//    * KWS branch (KEY1 not held): hand off IMMEDIATELY after sampling.
//      S_LOAD_KWS is a single-cycle "no key" decode: it never waits for a key,
//      a display or an image-load delay, so power-on -> warmboot_trigger
//      latency is SETTLE_MS + 4 cycles.
//    * CoreMark branch: SETTLE_MS + READY_HOLD_MS + a few cycles to anchor a
//      released KEY2, then DEBOUNCE_MS until the KEY2 press is accepted, then
//      the LOAD_CYCLES bench-image placeholder before handoff.
//    * mode_sel is sampled exactly once, in S_SAMPLE_KEY, right after
//      SETTLE_MS. KEY1 changes after that never modify the mode of the current
//      boot; changing mode = power cycle (no run-time switching).
//
//  Golden bitstream requirement (UG040005 3.7.1 / 3.7.2):
//    The golden image must NOT be generated with the embedded warmboot option
//    (Fabric Configuration > Operations > Convert File > Generate Multi
//    Revision File > Data Stream Type: Multi Boot Data Stream > Insert IRST CMD
//    to Data Stream). The FPGA boots the golden image from flash address 0,
//    golden enters user mode, and THIS selector (user logic, via A3's
//    GTP_IPAL_E2 warmboot block) issues the warmboot command, so the KEY1
//    sample is always honoured. An embedded IRST CMD would auto-jump before
//    the selector can sample KEY1 and would bypass this decision entirely.
//    IRSTADDR (warmboot address register) is byte addressed and 32-bit, which
//    is exactly what warmboot_addr/flash_addr carry on this interface.
//
//  Cycle accounting: no pipeline stages, no CDC; the FSM advances once per
//  clock. power-on -> warmboot_trigger latency = SETTLE_MS + 4 cycles (KWS) or
//  SETTLE_MS + READY_HOLD_MS + DEBOUNCE_MS + LOAD_CYCLES + a few cycles
//  (CoreMark bench image).
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module boot_selector_top #(
    // ---- key conditioning -------------------------------------------------
    parameter         KEY_ACTIVE_LOW   = 1'b1,        // board keys: active low
    parameter integer CLK_HZ           = 27_000_000,  // 27 MHz board clock
    parameter integer DEBOUNCE_MS      = 10,          // KEY1/KEY2 debounce time
    parameter integer SETTLE_MS        = 20,          // power-on settle before KEY1 sample
    parameter integer READY_HOLD_MS    = 100,         // "READY" shown before KEY2 accepted
    // ---- image / handoff --------------------------------------------------
    parameter integer LOAD_CYCLES      = 1_350_000,   // 50 ms @27 MHz bench-image load placeholder
                                                      // (S_BENCH_RUNNING only; KWS hands off at once)
    parameter integer WARMBOOT_PULSE   = 16,          // warmboot_trigger pulse width (cycles)
    parameter [31:0]  FLASH_BASE       = 32'h0000_0000,
    // The golden bitstream occupies flash from address 0 and is ~0x003A_F000
    // bytes (sbit = 3,791,112 B), so application images must start above it.
    // These offsets are safe placeholders (> golden size); the A2 flash map
    // must confirm/adjust them before the flash packaging step.
    parameter [31:0]  KWS_IMAGE_OFFSET   = 32'h003A_2000,  // app A (KWS)  [P1 layout: 0x003A2000]
    // CPU image start must leave a 4 KiB head region above the previous stream
    // payload (A9 cfg_gen_multi_file hard constraint: start >= prev_end + 0x1000);
    // 0x0074_0000 sits only 0x6F8 past the KWS stream -> use 0x0074_1000.
    parameter [31:0]  BENCH_IMAGE_OFFSET = 32'h0074_1000   // app B (CoreMark/CPU) [P1 packaging: 0x00741000]
)(
    input  wire        clk,
    input  wire        rst_n,            // asynchronous active-low board reset
    input  wire        key0_n,           // active-low: CPU reset / selector restart
    input  wire        key1_n,           // active-low: mode select at power-on
    input  wire        key2_n,           // active-low: start bench image
    // ---- selection / handoff ----
    output reg         mode_sel,         // 0 = KWS image, 1 = CoreMark bench image
    output wire [31:0] flash_addr,       // image base selected for this boot
    output wire        bench_ready,      // "CoreMark READY" to OLED/LED
    output wire        bench_running,    // bench image started (OLED/LED)
    output reg         warmboot_trigger, // handoff pulse to A3 (WARMBOOT_PULSE wide)
    output reg         warmboot_start,   // ONE-cycle start pulse for warmboot_ipal.trigger
    output wire [31:0] warmboot_addr,    // address handed to A3 warmboot
    output wire        cpu_reset,        // 1 = CPU held in reset (KEY0 or pre-handoff)
    output wire [3:0]  state_o           // FSM state, fully observable
);
    // ------------------------------------------------------------------
    // FSM encoding
    // ------------------------------------------------------------------
    localparam [3:0] S_POWER_ON      = 4'd0;
    localparam [3:0] S_SAMPLE_KEY    = 4'd1;
    localparam [3:0] S_SELECT_MODE   = 4'd2;
    localparam [3:0] S_LOAD_KWS      = 4'd3;
    localparam [3:0] S_BENCH_READY   = 4'd4;
    localparam [3:0] S_WAIT_KEY2     = 4'd5;
    localparam [3:0] S_BENCH_RUNNING = 4'd6;
    localparam [3:0] S_WARMBOOT      = 4'd7;

    // ------------------------------------------------------------------
    // Time -> cycles (rounded down, at least 1)
    // ------------------------------------------------------------------
    localparam integer DEBOUNCE_CYCLES   = (CLK_HZ / 1000) * DEBOUNCE_MS;
    localparam integer SETTLE_CYCLES     = (CLK_HZ / 1000) * SETTLE_MS;
    localparam integer READY_HOLD_CYCLES = (CLK_HZ / 1000) * READY_HOLD_MS;

    localparam integer DEB_W  = (DEBOUNCE_CYCLES   <= 1) ? 1 : $clog2(DEBOUNCE_CYCLES);
    localparam integer SET_W  = (SETTLE_CYCLES     <= 1) ? 1 : $clog2(SETTLE_CYCLES);
    localparam integer RDY_W  = (READY_HOLD_CYCLES <= 1) ? 1 : $clog2(READY_HOLD_CYCLES);
    localparam integer LOAD_W = (LOAD_CYCLES       <= 1) ? 1 : $clog2(LOAD_CYCLES);
    localparam integer WB_W   = (WARMBOOT_PULSE    <= 1) ? 1 : $clog2(WARMBOOT_PULSE + 1);

    localparam [DEB_W-1:0]  DEB_LAST   = DEBOUNCE_CYCLES   - 1;
    localparam [SET_W-1:0]  SET_LAST   = SETTLE_CYCLES     - 1;
    localparam [RDY_W-1:0]  RDY_LAST   = READY_HOLD_CYCLES - 1;
    localparam [LOAD_W-1:0] LOAD_LAST  = LOAD_CYCLES       - 1;
    localparam [WB_W-1:0]   WB_DONE    = WARMBOOT_PULSE;      // pulse width = WARMBOOT_PULSE cycles

    // ------------------------------------------------------------------
    // Key synchronization (metastability only; no debounce here)
    // ------------------------------------------------------------------
    reg [2:0] key_meta1, key_meta2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_meta1 <= 3'b111;
            key_meta2 <= 3'b111;
        end else begin
            key_meta1 <= {key2_n, key1_n, key0_n};
            key_meta2 <= key_meta1;
        end
    end

    // pressed_raw[0]=KEY0, [1]=KEY1, [2]=KEY2 (active-high "pressed" view)
    wire [2:0] pressed_raw;
    assign pressed_raw[0] = KEY_ACTIVE_LOW ? ~key_meta2[0] : key_meta2[0];
    assign pressed_raw[1] = KEY_ACTIVE_LOW ? ~key_meta2[1] : key_meta2[1];
    assign pressed_raw[2] = KEY_ACTIVE_LOW ? ~key_meta2[2] : key_meta2[2];

    // ------------------------------------------------------------------
    // KEY1 / KEY2 debounce (stable-level counter)
    // ------------------------------------------------------------------
    reg [DEB_W-1:0] deb_cnt [0:1];
    reg [1:0]       deb_level;       // [0]=KEY1 debounced, [1]=KEY2 debounced
    integer         di;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            deb_level <= 2'b00;
            for (di = 0; di < 2; di = di + 1) begin
                deb_cnt[di] <= {DEB_W{1'b0}};
            end
        end else begin
            for (di = 0; di < 2; di = di + 1) begin
                if (pressed_raw[di+1] == deb_level[di]) begin
                    deb_cnt[di] <= {DEB_W{1'b0}};
                end else if (deb_cnt[di] == DEB_LAST) begin
                    deb_level[di] <= pressed_raw[di+1];
                    deb_cnt[di]   <= {DEB_W{1'b0}};
                end else begin
                    deb_cnt[di] <= deb_cnt[di] + 1'b1;
                end
            end
        end
    end

    wire key1_pressed = deb_level[0];
    wire key2_pressed = deb_level[1];

    // ------------------------------------------------------------------
    // FSM
    // ------------------------------------------------------------------
    reg [3:0]        state;
    reg [SET_W-1:0]  settle_cnt;
    reg [RDY_W-1:0]  ready_cnt;
    reg [LOAD_W-1:0] load_cnt;
    reg [WB_W-1:0]   wb_cnt;
    reg [DEB_W-1:0]  key2_rel_cnt;    // KEY2 released-level counter inside WAIT_KEY2
    reg              key2_rel_armed;  // KEY2 released for a full window after READY

    // KEY0 reset path: synchronized, NOT debounced, never gated by the FSM.
    wire key0_held    = pressed_raw[0];
    wire key0_restart = key0_held;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= S_POWER_ON;
            mode_sel         <= 1'b0;
            settle_cnt       <= {SET_W{1'b0}};
            ready_cnt        <= {RDY_W{1'b0}};
            load_cnt         <= {LOAD_W{1'b0}};
            wb_cnt           <= {WB_W{1'b0}};
            key2_rel_cnt     <= {DEB_W{1'b0}};
            key2_rel_armed   <= 1'b0;
            warmboot_trigger <= 1'b0;
            warmboot_start   <= 1'b0;
        end else if (key0_restart) begin
            // KEY0 held: CPU reset asserted, selector held at POWER_ON, no handoff.
            state            <= S_POWER_ON;
            mode_sel         <= 1'b0;
            settle_cnt       <= {SET_W{1'b0}};
            ready_cnt        <= {RDY_W{1'b0}};
            load_cnt         <= {LOAD_W{1'b0}};
            wb_cnt           <= {WB_W{1'b0}};
            key2_rel_cnt     <= {DEB_W{1'b0}};
            key2_rel_armed   <= 1'b0;
            warmboot_trigger <= 1'b0;
            warmboot_start   <= 1'b0;
        end else begin
            warmboot_trigger <= 1'b0;     // default low; S_WARMBOOT extends it
            warmboot_start   <= 1'b0;     // one-cycle pulse, armed on the handoff transition

            case (state)
                // ---- wait for keys/supplies to settle, then sample KEY1 ----
                S_POWER_ON: begin
                    if (settle_cnt == SET_LAST) begin
                        settle_cnt <= {SET_W{1'b0}};
                        state      <= S_SAMPLE_KEY;
                    end else begin
                        settle_cnt <= settle_cnt + 1'b1;
                    end
                end

                // ---- latch the mode: KEY1 held at power-on => CoreMark ----
                S_SAMPLE_KEY: begin
                    mode_sel <= key1_pressed;
                    state    <= S_SELECT_MODE;
                end

                S_SELECT_MODE: begin
                    state <= mode_sel ? S_BENCH_READY : S_LOAD_KWS;
                end

                // ---- KWS branch: hand off at once (no key wait, no delay) ----
                // The user requirement is explicit: KEY1 not held => load the
                // KWS image immediately, without waiting, without READY and
                // without stopping in the selector. This state therefore only
                // decodes "no key" and moves on in a single cycle.
                S_LOAD_KWS: begin
                    load_cnt       <= {LOAD_W{1'b0}};
                    warmboot_start <= 1'b1;   // single-cycle start for warmboot_ipal
                    state          <= S_WARMBOOT;
                end

                // ---- CoreMark branch: show READY, anchor a released KEY2 ----
                S_BENCH_READY: begin
                    if (ready_cnt == RDY_LAST) begin
                        ready_cnt <= {RDY_W{1'b0}};
                        if (!key2_pressed) begin
                            state          <= S_WAIT_KEY2;
                            key2_rel_cnt   <= {DEB_W{1'b0}};
                            key2_rel_armed <= 1'b0;
                        end
                    end else begin
                        ready_cnt <= ready_cnt + 1'b1;
                    end
                end

                // ---- accept the next full KEY2 press edge ----
                // Qualification: KEY2 must first be de-bounced released for a full
                // DEBOUNCE window *after* READY, so a press already in flight when
                // READY ends can never be mistaken for a fresh press edge.
                S_WAIT_KEY2: begin
                    if (key2_pressed) begin
                        if (key2_rel_armed) begin
                            state          <= S_BENCH_RUNNING;
                            key2_rel_armed <= 1'b0;
                        end
                        key2_rel_cnt <= {DEB_W{1'b0}};
                    end else if (key2_rel_cnt == DEB_LAST) begin
                        key2_rel_armed <= 1'b1;
                    end else begin
                        key2_rel_cnt <= key2_rel_cnt + 1'b1;
                    end
                end

                // ---- bench image started: hold, then handoff to warmboot ----
                S_BENCH_RUNNING: begin
                    if (load_cnt == LOAD_LAST) begin
                        load_cnt       <= {LOAD_W{1'b0}};
                        warmboot_start <= 1'b1;   // single-cycle start for warmboot_ipal
                        state          <= S_WARMBOOT;
                    end else begin
                        load_cnt <= load_cnt + 1'b1;
                    end
                end

                // ---- emit warmboot pulse and stay parked (A3 takes over) ----
                S_WARMBOOT: begin
                    if (wb_cnt == WB_DONE) begin
                        wb_cnt           <= wb_cnt;
                        warmboot_trigger <= 1'b0;
                    end else begin
                        wb_cnt           <= wb_cnt + 1'b1;
                        warmboot_trigger <= 1'b1;
                    end
                end

                default: state <= S_POWER_ON;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Outputs
    // ------------------------------------------------------------------
    wire [31:0] image_base = mode_sel
                           ? (FLASH_BASE + BENCH_IMAGE_OFFSET)
                           : (FLASH_BASE + KWS_IMAGE_OFFSET);

    assign flash_addr    = image_base;
    assign warmboot_addr = image_base;

    assign bench_ready   = (state == S_BENCH_READY) || (state == S_WAIT_KEY2);
    assign bench_running = (state == S_BENCH_RUNNING);

    // CPU is held in reset while KEY0 is pressed (pass-through) and until the
    // selector hands off (WARMBOOT). A3 owns the actual CPU release after the
    // reconfiguration; this output only guarantees "not loaded while selecting".
    assign cpu_reset = key0_held || (state != S_WARMBOOT);

    assign state_o = state;

endmodule

`default_nettype wire
