// -----------------------------------------------------------------------------
// Filename     : warmboot_ipal.sv
// Description  : Minimal warmboot command generator for Pango Logos2 GTP_IPAL_E2
//                (internal slave parallel interface, ISPI).
//
//                Emits the "Warmboot Process" command sequence of
//                UG040005 V1.3 Table 3-26 (p.72):
//
//                  FFFFFFFF x PAD_A_WORDS          padding
//                  000000AA                        bus bit width auto detection
//                  08100020                        (preamble of the same packet)
//                  FFFFFFFF x PAD_B_WORDS          padding
//                  01332D94                        synchronization
//                  AC000001 + addr                 IRSTADRR (optional, byte addr)
//                  A8800001 + 0000000F             CMDR <- IRST   (warmboot)
//                  A8800001 + 0000000B             CMDR <- DESYNC
//                  A0000000 x PAD_NOP_WORDS        100 x NOP type-1 headers
//
//                IRSTADDR (UG040005 Table 3-23) is the Flash start address used
//                during warmboot, in *bytes*.  In a multi-image / multi-boot
//                data stream the images are placed on 4 KiB boundaries by
//                cfg_gen_multi_file, so addr[11:0] must be zero.
//
//                The module only drives the slave-parallel pins (CS_N, RW_SEL,
//                DI).  The GTP_IPAL_E2 primitive itself is instantiated by the
//                board top level; see WARMBOOT_IF.md for the wiring contract.
//
// Notes        : - One 32-bit command word is sent per word slot.  For a
//                  narrower bus the word is emitted as 2 (X16) or 4 (X8)
//                  consecutive beats with CS_N held low across the sequence.
//                - RW_SEL is kept low (write) and only changes while CS_N is
//                  high, as required by UG040005 p.89 ("The RW_SEL signal
//                  transition can only occur when CS_N is high").
//                - addr is sampled when trigger is seen; the interface is
//                  valid one clock after done.
// -----------------------------------------------------------------------------
`timescale 1 ns / 1 ps

module warmboot_ipal #(
    // Padding / NOP counts from UG040005 Table 3-26.  They are parameters so a
    // shorter simulation stream is possible, but the defaults are the manual
    // values and should be used for silicon.
    parameter integer PAD_A_WORDS   = 100,
    parameter integer PAD_B_WORDS   = 10,
    parameter integer PAD_NOP_WORDS = 100,
    // Parallel bus width in bytes: 4 = X32 (default), 2 = X16, 1 = X8.
    parameter integer BUS_BYTES     = 4,
    // 1: include the optional IRSTADRR write (needed when the golden image did
    // not embed the target address; harmless when it did).
    parameter integer INSERT_ADDR   = 1
) (
    input  wire        clk,          // 27 MHz board clock
    input  wire        rst_n,        // async reset, active low (sync to clk)
    input  wire        trigger,      // start: level/pulse; accepted when idle
    input  wire [31:0] addr,         // target image start, Flash byte address
    output reg         busy,         // high while the sequence is emitted
    output reg         done,         // one-cycle pulse when the last word sent
    output reg         err,          // one-cycle pulse on misaligned addr
    // GST_IPAL_E2 slave parallel interface (write only)
    output reg         ipal_cs_n,    // chip select, active low
    output reg         ipal_rw_sel,  // 0 = write, 1 = read
    output reg  [31:0] ipal_di       // data in
);

    // ---------------------------------------------------------------------
    // Sequence layout (word indices)
    // ---------------------------------------------------------------------
    localparam integer W_BW0   = PAD_A_WORDS;                     // 000000AA
    localparam integer W_BW1   = PAD_A_WORDS + 1;                 // 08100020
    localparam integer W_PADB0 = PAD_A_WORDS + 2;                 // padding
    localparam integer W_BEND  = PAD_A_WORDS + 2 + PAD_B_WORDS;
    localparam integer W_SYNC  = W_BEND;                          // 01332D94
    localparam integer W_ADRH  = W_BEND + 1;                      // AC000001
    localparam integer W_CMDH  = W_ADRH + (INSERT_ADDR ? 2 : 0);  // A8800001
    localparam integer W_CMDD  = W_CMDH + 1;                      // 0000000F
    localparam integer W_CMDH2 = W_CMDH + 2;                      // A8800001
    localparam integer W_CMDD2 = W_CMDH + 3;                      // 0000000B
    localparam integer W_NOP0  = W_CMDH + 4;
    localparam integer W_TOTAL = W_NOP0 + PAD_NOP_WORDS;

    localparam integer CPW = 4 / BUS_BYTES;   // beats per 32-bit word

    localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_SEND = 2'd1;

    reg [1:0]  state;
    integer    widx;    // word index within the sequence
    integer    bidx;    // beat index within a word
    reg [31:0] addr_q;  // address latched at trigger time

    // ---------------------------------------------------------------------
    // Command word generator
    // ---------------------------------------------------------------------
    function [31:0] seq_word;
        input integer k;
        begin
            if (k < PAD_A_WORDS)              seq_word = 32'hFFFF_FFFF;
            else if (k == W_BW0)              seq_word = 32'h0000_00AA;
            else if (k == W_BW1)              seq_word = 32'h0810_0020;
            else if (k < W_SYNC)              seq_word = 32'hFFFF_FFFF;
            else if (k == W_SYNC)             seq_word = 32'h0133_2D94;
            else if (INSERT_ADDR && k == W_ADRH)      seq_word = 32'hAC00_0001;
            else if (INSERT_ADDR && k == W_ADRH + 1)  seq_word = addr_q;
            else if (k == W_CMDH)             seq_word = 32'hA880_0001;
            else if (k == W_CMDD)             seq_word = 32'h0000_000F;
            else if (k == W_CMDH2)            seq_word = 32'hA880_0001;
            else if (k == W_CMDD2)            seq_word = 32'h0000_000B;
            else                              seq_word = 32'hA000_0000;
        end
    endfunction

    // Place one 32-bit word on the DI lanes for beat c (c = 0 is first beat).
    function [31:0] beat_data;
        input [31:0] word;
        input integer c;
        begin
            if (BUS_BYTES == 4)      beat_data = word;
            else if (BUS_BYTES == 2) beat_data = {16'h0000, word[16*c +: 16]};
            else                     beat_data = {24'h000000, word[8*c +: 8]};
        end
    endfunction

    // ---------------------------------------------------------------------
    // Sequencer
    // ---------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            busy        <= 1'b0;
            done        <= 1'b0;
            err         <= 1'b0;
            ipal_cs_n   <= 1'b1;
            ipal_rw_sel <= 1'b0;
            ipal_di     <= 32'h0000_0000;
            widx        <= 0;
            bidx        <= 0;
            addr_q      <= 32'h0000_0000;
        end else begin
            done <= 1'b0;
            err  <= 1'b0;

            case (state)
                S_IDLE: begin
                    ipal_cs_n   <= 1'b1;
                    ipal_rw_sel <= 1'b0;
                    if (trigger) begin
                        if (addr[11:0] != 12'h000) begin
                            // Not a 4 KiB aligned Flash image start: refuse.
                            err   <= 1'b1;
                        end else begin
                            addr_q    <= addr;
                            widx      <= 0;
                            bidx      <= 0;
                            busy      <= 1'b1;
                            ipal_cs_n <= 1'b0;
                            ipal_di   <= beat_data(seq_word(0), 0);
                            state     <= S_SEND;
                        end
                    end
                end

                S_SEND: begin
                    ipal_cs_n   <= 1'b0;
                    ipal_rw_sel <= 1'b0;
                    if (bidx == CPW - 1) begin
                        bidx <= 0;
                        if (widx == W_TOTAL - 1) begin
                            ipal_cs_n <= 1'b1;
                            busy      <= 1'b0;
                            done      <= 1'b1;
                            state     <= S_IDLE;
                        end else begin
                            widx    <= widx + 1;
                            ipal_di <= beat_data(seq_word(widx + 1), 0);
                        end
                    end else begin
                        bidx    <= bidx + 1;
                        ipal_di <= beat_data(seq_word(widx), bidx + 1);
                    end
                end

                default: begin
                    state     <= S_IDLE;
                    ipal_cs_n <= 1'b1;
                    busy      <= 1'b0;
                end
            endcase
        end
    end

    // synopsys translate_off
    // Simulation sanity: total word count is fixed by the parameters.
    initial begin
        if (W_TOTAL <= 0) begin
            $display("[warmboot_ipal] ERROR: invalid sequence parameters");
            $finish;
        end
        $display("[warmboot_ipal] sequence words = %0d (PAD_A=%0d PAD_B=%0d NOP=%0d INSERT_ADDR=%0d BUS_BYTES=%0d)",
                 W_TOTAL, PAD_A_WORDS, PAD_B_WORDS, PAD_NOP_WORDS, INSERT_ADDR, BUS_BYTES);
    end
    // synopsys translate_on

endmodule
