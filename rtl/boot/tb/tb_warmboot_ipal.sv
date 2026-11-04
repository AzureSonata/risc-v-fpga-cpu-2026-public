// -----------------------------------------------------------------------------
// Filename     : tb_warmboot_ipal.sv
// Description  : Testbench for warmboot_ipal.sv against the Pango
//                GTP_IPAL_E2 simulation model (arch/vendor/pango/
//                verilog/simulation/GTP_IPAL_E2.v).
//
//                Checks:
//                  1. The DI stream equals UG040005 Table 3-26 warmboot
//                     sequence for addr = 0x0000_4000.
//                  2. The vendor model latches IRSTADRR = 0x0000_4000 and sees
//                     CMDR = IRST (0x0F) followed by DESYNC (0x0B).
//                  3. A second run with addr = 0x000C_D000 changes only the
//                     IRSTADDR data word and latches the new address.
//                  4. A misaligned address (addr[11:0] != 0) is refused
//                     (err pulse, no bus activity).
//
//                The keyboard-1252/ASCII log is the evidence artifact;
//                see WARMBOOT_IPAL/sim.log in the evidence directory.
// -----------------------------------------------------------------------------
`timescale 1 ns / 1 ps

module tb_warmboot_ipal;

    // ------------------------------------------------------------------
    // Clock / DUT control
    // ------------------------------------------------------------------
    localparam real CLK27_NS = 37.037037;   // 27 MHz board clock

    reg clk = 1'b0;
    always #(CLK27_NS / 2.0) clk = ~clk;

    reg         rst_n   = 1'b0;
    reg         trigger = 1'b0;
    reg  [31:0] addr    = 32'h0000_0000;

    wire        busy, done, err, cs_n, rw_sel;
    wire [31:0] di;

    wire [31:0] do_ipal;
    wire        rbcrc_err, rbcrc_valid, ecc_valid, serror, derror;
    wire [11:0] ecc_index;
    wire [7:0]  seu_frame_addr, seu_column_addr, seu_frame_naddr, seu_column_naddr;
    wire [4:0]  seu_region_addr, seu_region_naddr;
    wire        prcfg_over, prcfg_err, drcfg_over, drcfg_err;

    // Sequence layout, identical to warmboot_ipal defaults.
    localparam integer PAD_A   = 100;
    localparam integer PAD_B   = 10;
    localparam integer PAD_NOP = 100;
    localparam integer W_SYNC  = PAD_A + 2 + PAD_B;
    localparam integer W_ADRH  = W_SYNC + 1;
    localparam integer W_CMDH  = W_ADRH + 2;
    localparam integer W_NOP0  = W_CMDH + 4;
    localparam integer W_TOTAL = W_NOP0 + PAD_NOP;

    // ------------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------------
    warmboot_ipal #(
        .PAD_A_WORDS   (PAD_A),
        .PAD_B_WORDS   (PAD_B),
        .PAD_NOP_WORDS (PAD_NOP),
        .BUS_BYTES     (4),          // X32: one word per clock
        .INSERT_ADDR   (1)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .trigger     (trigger),
        .addr        (addr),
        .busy        (busy),
        .done        (done),
        .err         (err),
        .ipal_cs_n   (cs_n),
        .ipal_rw_sel (rw_sel),
        .ipal_di     (di)
    );

    // ------------------------------------------------------------------
    // Pango GTP_IPAL_E2 vendor model (top level is plain Verilog; its four
    // encrypted submodules are replaced by ipal_e2_model_shim.v).
    // ------------------------------------------------------------------
    GTP_IPAL_E2 #(
        .SIM_DEVICE ("PG2L100H"),
        .IDCODE     (32'h0060_2899),
        .DATA_WIDTH ("X32")
    ) u_ipal (
        .DO               (do_ipal),
        .RBCRC_ERR        (rbcrc_err),
        .RBCRC_VALID      (rbcrc_valid),
        .ECC_VALID        (ecc_valid),
        .ECC_INDEX        (ecc_index),
        .SERROR           (serror),
        .DERROR           (derror),
        .SEU_FRAME_ADDR   (seu_frame_addr),
        .SEU_COLUMN_ADDR  (seu_column_addr),
        .SEU_REGION_ADDR  (seu_region_addr),
        .SEU_FRAME_NADDR  (seu_frame_naddr),
        .SEU_COLUMN_NADDR (seu_column_naddr),
        .SEU_REGION_NADDR (seu_region_naddr),
        .PRCFG_OVER       (prcfg_over),
        .PRCFG_ERR        (prcfg_err),
        .DRCFG_OVER       (drcfg_over),
        .DRCFG_ERR        (drcfg_err),
        .RST_N            (rst_n),
        .CLK              (clk),
        .CS_N             (cs_n),
        .RW_SEL           (rw_sel),
        .DI               (di)
    );

    // ------------------------------------------------------------------
    // Bus capture and checks
    // ------------------------------------------------------------------
    reg [31:0] words [0:1023];
    integer    n_words;
    integer    fail_cnt;
    integer    irst_seen, desync_seen, misaligned_seen;
    reg        run_active;
    integer    prev_cmd;

    // Expected word for index k of the Table 3-26 sequence.
    function [31:0] expected_word;
        input integer k;
        input [31:0]  a;
        begin
            if (k < PAD_A)              expected_word = 32'hFFFF_FFFF;
            else if (k == PAD_A)        expected_word = 32'h0000_00AA;
            else if (k == PAD_A + 1)    expected_word = 32'h0810_0020;
            else if (k < W_SYNC)        expected_word = 32'hFFFF_FFFF;
            else if (k == W_SYNC)       expected_word = 32'h0133_2D94;
            else if (k == W_ADRH)       expected_word = 32'hAC00_0001;
            else if (k == W_ADRH + 1)   expected_word = a;
            else if (k == W_CMDH)       expected_word = 32'hA880_0001;
            else if (k == W_CMDH + 1)   expected_word = 32'h0000_000F;
            else if (k == W_CMDH + 2)   expected_word = 32'hA880_0001;
            else if (k == W_CMDH + 3)   expected_word = 32'h0000_000B;
            else                        expected_word = 32'hA000_0000;
        end
    endfunction

    // Capture the bus during write cycles (pre-edge values are the word that
    // was driven during the cycle that just ended).  CMDR writes are detected
    // as transitions of the model's reg_cmd so a stale value from a previous
    // run cannot produce a false positive.
    always @(posedge clk) begin
        if (run_active) begin
            if (!cs_n && !rw_sel) begin
                words[n_words] = di;
                n_words        = n_words + 1;
            end
            if (u_ipal.reg_cmd !== prev_cmd) begin
                if (u_ipal.reg_cmd == 5'b01111) irst_seen   = 1'b1;
                if (u_ipal.reg_cmd == 5'b01011) desync_seen = 1'b1;
            end
            prev_cmd = u_ipal.reg_cmd;
        end
    end

    always @(posedge clk) begin
        if (err) misaligned_seen = 1'b1;
    end

    // ------------------------------------------------------------------
    // One warmboot injection
    // ------------------------------------------------------------------
    task run_warmboot;
        input [31:0] target;
        input [8*24-1:0] tag;
        integer i;
        integer timeout;
        reg [31:0] latched;
        begin
            n_words = 0;
            irst_seen    = 1'b0;
            desync_seen  = 1'b0;
            misaligned_seen = 1'b0;
            prev_cmd     = u_ipal.reg_cmd;
            run_active   = 1'b1;

            @(posedge clk);
            addr    <= target;
            trigger <= 1'b1;
            @(posedge clk);
            trigger <= 1'b0;

            timeout = 0;
            while (!done && timeout < 4096) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (!done) begin
                $display("[TB] %0s FAIL: timeout waiting for done (busy=%b)", tag, busy);
                fail_cnt = fail_cnt + 1;
            end
            repeat (3) @(posedge clk);

            // --- check word stream -------------------------------------
            if (n_words != W_TOTAL) begin
                $display("[TB] %0s FAIL: captured %0d words, expected %0d",
                         tag, n_words, W_TOTAL);
                fail_cnt = fail_cnt + 1;
            end else begin
                $display("[TB] %0s captured %0d words (expected %0d)", tag, n_words, W_TOTAL);
            end
            for (i = 0; i < n_words; i = i + 1) begin
                $display("[TB] %0s W[%0d] = 32'h%08x", tag, i, words[i]);
                if (words[i] !== expected_word(i, target)) begin
                    $display("[TB] %0s FAIL: W[%0d] mismatch (got %08x, expected %08x)",
                             tag, i, words[i], expected_word(i, target));
                    fail_cnt = fail_cnt + 1;
                end
            end

            // --- literal Table 3-26 spot checks ------------------------
            if (words[100] !== 32'h0000_00AA) begin
                $display("[TB] %0s FAIL: bus-width autodetect word", tag);
                fail_cnt = fail_cnt + 1;
            end
            if (words[101] !== 32'h0810_0020) begin
                $display("[TB] %0s FAIL: preamble second word", tag);
                fail_cnt = fail_cnt + 1;
            end
            if (words[112] !== 32'h0133_2D94) begin
                $display("[TB] %0s FAIL: synchronization word", tag);
                fail_cnt = fail_cnt + 1;
            end
            if (words[113] !== 32'hAC00_0001) begin
                $display("[TB] %0s FAIL: IRSTADRR type-1 header", tag);
                fail_cnt = fail_cnt + 1;
            end
            if (words[114] !== target) begin
                $display("[TB] %0s FAIL: IRSTADRR data (=target addr)", tag);
                fail_cnt = fail_cnt + 1;
            end
            if (words[115] !== 32'hA880_0001 || words[117] !== 32'hA880_0001) begin
                $display("[TB] %0s FAIL: CMDR type-1 header", tag);
                fail_cnt = fail_cnt + 1;
            end
            if (words[116] !== 32'h0000_000F) begin
                $display("[TB] %0s FAIL: IRST command data", tag);
                fail_cnt = fail_cnt + 1;
            end
            if (words[118] !== 32'h0000_000B) begin
                $display("[TB] %0s FAIL: DESYNC command data", tag);
                fail_cnt = fail_cnt + 1;
            end
            if (words[119] !== 32'hA000_0000) begin
                $display("[TB] %0s FAIL: first NOP header", tag);
                fail_cnt = fail_cnt + 1;
            end

            // --- vendor model internal latches -------------------------
            latched = u_ipal.reg_irstadrr;
            if (latched !== target) begin
                $display("[TB] %0s FAIL: GTP_IPAL_E2 reg_irstadrr = 32'h%08x, expected 32'h%08x",
                         tag, latched, target);
                fail_cnt = fail_cnt + 1;
            end else begin
                $display("[TB] %0s GTP_IPAL_E2 reg_irstadrr = 32'h%08x (match)", tag, latched);
            end
            if (!irst_seen) begin
                $display("[TB] %0s FAIL: CMDR IRST (0x0F) never observed", tag);
                fail_cnt = fail_cnt + 1;
            end
            if (!desync_seen) begin
                $display("[TB] %0s FAIL: CMDR DESYNC (0x0B) never observed", tag);
                fail_cnt = fail_cnt + 1;
            end
            if (u_ipal.reg_irstctrlr !== 32'h0000_0000) begin
                $display("[TB] %0s NOTE: reg_irstctrlr = 32'h%08x (not written by this sequence)",
                         tag, u_ipal.reg_irstctrlr);
            end

            $display("[TB] %0s irst_seen=%0d desync_seen=%0d -> %0s",
                     tag, irst_seen, desync_seen,
                     (fail_cnt == 0) ? "PASS" : "CHECK FAILURES");
        end
    endtask

    // ------------------------------------------------------------------
    // Stimulus
    // ------------------------------------------------------------------
    integer base_fail;

    initial begin
        n_words    = 0;
        fail_cnt   = 0;
        irst_seen  = 0;
        desync_seen = 0;
        misaligned_seen = 0;

        $display("=============================================================");
        $display("[TB] warmboot_ipal vs Pango GTP_IPAL_E2 model");
        $display("[TB] clk = 27 MHz (%.6f ns), DATA_WIDTH=X32, SIM_DEVICE=PG2L100H", CLK27_NS);
        $display("=============================================================");

        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
        repeat (5) @(posedge clk);

        // ---- run 1: image at 0x0000_4000 (16 KiB offset) -------------
        run_warmboot(32'h0000_4000, "RUN1");

        // ---- run 2: image at 0x000C_D000 (multi-image example address)
        base_fail = fail_cnt;
        run_warmboot(32'h000C_D000, "RUN2");
        if (fail_cnt == base_fail) begin
            $display("[TB] RUN2: address sensitivity confirmed (only IRSTADDR data word changed)");
        end

        // ---- run 3: misaligned address must be refused ---------------
        @(posedge clk);
        addr    <= 32'h0000_4123;   // addr[11:0] != 0
        trigger <= 1'b1;
        @(posedge clk);
        trigger <= 1'b0;
        repeat (4) @(posedge clk);
        if (misaligned_seen !== 1'b1) begin
            $display("[TB] FAIL: misaligned addr did not raise err");
            fail_cnt = fail_cnt + 1;
        end else if (cs_n !== 1'b1) begin
            $display("[TB] FAIL: misaligned addr still drove CS_N low");
            fail_cnt = fail_cnt + 1;
        end else begin
            $display("[TB] RUN3: misaligned addr 0x00004123 refused (err pulse, no bus activity) -> PASS");
        end

        // ---- summary -------------------------------------------------
        $display("=============================================================");
        if (fail_cnt == 0) begin
            $display("[TB] RESULT: PASS (all warmboot sequence checks passed)");
        end else begin
            $display("[TB] RESULT: FAIL (%0d check(s) failed)", fail_cnt);
        end
        $display("=============================================================");
        $finish;
    end

    // Global watchdog
    initial begin
        #(10_000_000);   // 10 ms
        $display("[TB] FAIL: global timeout");
        $finish;
    end

endmodule
