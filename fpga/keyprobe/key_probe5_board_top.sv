// =============================================================================
// key_probe5_board_top.sv - A4e key-pin probe (5 user keys), board-level top
//
// Purpose: bring-up design that reports the raw and de-glitched logic levels of
//          the five board user keys over the board UART, so the physical
//          silkscreen key order (and whether a key is wired to the FPGA at all)
//          can be confirmed on real hardware.
//
//   KEY0 = C22, KEY1 = C23, KEY2 = B22, KEY3 = A22, KEY4 = B20  (all active low,
//   hardware guide 2.1.3.4.1, printed page 46).
//
//   UART: TX = C24, 115200 8N1 (27 MHz / 234 = 115,384 baud, +1.6%).
//   Clock: 27 MHz core-board oscillator = D18.
//
// Line format (29 chars + CR LF = 31 bytes), sent every 100 ms and immediately
// on any change:
//
//   KEY raw=<k4k3k2k1k0> pressed=<p4p3p2p1p0>\r\n
//   CHG raw=...          pressed=...        \r\n
//
//   raw     = synchronized pin level      (1 = pin high = key released)
//   pressed = active-low interpretation   (1 = pin low  = key pressed)
//
// There is NO external reset: a key held low at power-up cannot hold the design
// in reset (an internal 8-bit power-on counter gates everything).
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module key_probe5_board_top (
    input  wire clk,
    input  wire key0_n,
    input  wire key1_n,
    input  wire key2_n,
    input  wire key3_n,
    input  wire key4_n,
    output wire uart_tx
);

    localparam integer BAUD_DIV   = 234;        // 27e6 / 234 = 115384 baud
    localparam integer TICK_100MS = 27_000_000 / 10;   // 2,700,000 cycles
    localparam integer MSG_LEN    = 29;         // chars per line (without CR LF)

    // ---------------------------------------------------------------------
    // Power-on reset (no external reset pin)
    // ---------------------------------------------------------------------
    reg [7:0] por_cnt;
    reg       por_n;

    initial por_cnt = 8'd0;

    always @(posedge clk) begin
        if (!por_cnt[7]) begin
            por_cnt <= por_cnt + 8'd1;
            por_n   <= 1'b0;
        end else begin
            por_n   <= 1'b1;
        end
    end

    // ---------------------------------------------------------------------
    // Two-flop synchronizers: k?_s[0] = first stage, k?_s[1] = second stage
    // raw uses the first stage (fastest visibility), "stable" the second one.
    // ---------------------------------------------------------------------
    reg [1:0] k0_s, k1_s, k2_s, k3_s, k4_s;

    always @(posedge clk) begin
        if (!por_n) begin
            k0_s <= 2'b11;
            k1_s <= 2'b11;
            k2_s <= 2'b11;
            k3_s <= 2'b11;
            k4_s <= 2'b11;
        end else begin
            k0_s <= {k0_s[0], key0_n};
            k1_s <= {k1_s[0], key1_n};
            k2_s <= {k2_s[0], key2_n};
            k3_s <= {k3_s[0], key3_n};
            k4_s <= {k4_s[0], key4_n};
        end
    end

    wire [4:0] raw    = {k4_s[0], k3_s[0], k2_s[0], k1_s[0], k0_s[0]};  // 1 = pin high
    wire [4:0] pres   = {~k4_s[1], ~k3_s[1], ~k2_s[1], ~k1_s[1], ~k0_s[1]};
    wire [4:0] stable = {k4_s[1], k3_s[1], k2_s[1], k1_s[1], k0_s[1]};

    // ---------------------------------------------------------------------
    // 100 ms heartbeat and change detector
    // ---------------------------------------------------------------------
    reg [21:0] tick_cnt;
    reg        tick_100ms;
    reg [4:0]  stable_d;
    reg        chg_pending;

    // ---------------------------------------------------------------------
    // Line sender state
    // ---------------------------------------------------------------------
    reg [4:0] pos;
    reg       hdr_chg;
    reg [4:0] raw_l, pres_l;
    reg       sending;
    reg       start_byte;
    reg [7:0] tx_data;
    reg [7:0] msg_byte;
    wire      tx_busy;

    always @(posedge clk) begin
        if (!por_n) begin
            tick_cnt    <= 22'd0;
            tick_100ms  <= 1'b0;
            stable_d    <= 5'b11111;
            chg_pending <= 1'b0;
            pos         <= 5'd0;
            hdr_chg     <= 1'b0;
            raw_l       <= 5'b00000;
            pres_l      <= 5'b00000;
            sending     <= 1'b0;
            start_byte  <= 1'b0;
            tx_data     <= 8'h00;
        end else begin
            start_byte <= 1'b0;
            stable_d   <= stable;
            if (stable != stable_d) chg_pending <= 1'b1;

            if (tick_cnt == TICK_100MS - 1) begin
                tick_cnt   <= 22'd0;
                tick_100ms <= 1'b1;
            end else begin
                tick_cnt   <= tick_cnt + 22'd1;
                tick_100ms <= 1'b0;
            end

            if (!sending) begin
                if (chg_pending && !tx_busy && !start_byte) begin
                    hdr_chg     <= 1'b1;
                    raw_l       <= raw;
                    pres_l      <= pres;
                    pos         <= 5'd0;
                    sending     <= 1'b1;
                    chg_pending <= 1'b0;
                end else if (tick_100ms && !tx_busy && !start_byte) begin
                    hdr_chg <= 1'b0;
                    raw_l   <= raw;
                    pres_l  <= pres;
                    pos     <= 5'd0;
                    sending <= 1'b1;
                end
            end else if (!tx_busy && !start_byte) begin
                tx_data    <= msg_byte;
                start_byte <= 1'b1;
                if (pos == MSG_LEN - 1) begin
                    sending <= 1'b0;
                    pos     <= 5'd0;
                end else begin
                    pos <= pos + 5'd1;
                end
            end
        end
    end

    // ---------------------------------------------------------------------
    // "KEY raw=<k4k3k2k1k0> pressed=<p4p3p2p1p0>"
    //   0..3   header  "KEY " / "CHG "
    //   4..7   "raw="
    //   8..12  raw[4:0]
    //   13     ' '
    //   14..21 "pressed="
    //   22..26 pressed[4:0]
    //   27     CR
    //   28     LF
    // ---------------------------------------------------------------------
    always @* begin
        case (pos)
            5'd0:  msg_byte = hdr_chg ? 8'h43 : 8'h4B;   // 'C' / 'K'
            5'd1:  msg_byte = hdr_chg ? 8'h48 : 8'h45;   // 'H' / 'E'
            5'd2:  msg_byte = hdr_chg ? 8'h47 : 8'h59;   // 'G' / 'Y'
            5'd3:  msg_byte = 8'h20;                     // ' '
            5'd4:  msg_byte = 8'h72;                     // 'r'
            5'd5:  msg_byte = 8'h61;                     // 'a'
            5'd6:  msg_byte = 8'h77;                     // 'w'
            5'd7:  msg_byte = 8'h3D;                     // '='
            5'd8:  msg_byte = {7'b0011000, raw_l[4]};
            5'd9:  msg_byte = {7'b0011000, raw_l[3]};
            5'd10: msg_byte = {7'b0011000, raw_l[2]};
            5'd11: msg_byte = {7'b0011000, raw_l[1]};
            5'd12: msg_byte = {7'b0011000, raw_l[0]};
            5'd13: msg_byte = 8'h20;
            5'd14: msg_byte = 8'h70;                     // 'p'
            5'd15: msg_byte = 8'h72;                     // 'r'
            5'd16: msg_byte = 8'h65;                     // 'e'
            5'd17: msg_byte = 8'h73;                     // 's'
            5'd18: msg_byte = 8'h73;                     // 's'
            5'd19: msg_byte = 8'h65;                     // 'e'
            5'd20: msg_byte = 8'h64;                     // 'd'
            5'd21: msg_byte = 8'h3D;                     // '='
            5'd22: msg_byte = {7'b0011000, pres_l[4]};
            5'd23: msg_byte = {7'b0011000, pres_l[3]};
            5'd24: msg_byte = {7'b0011000, pres_l[2]};
            5'd25: msg_byte = {7'b0011000, pres_l[1]};
            5'd26: msg_byte = {7'b0011000, pres_l[0]};
            5'd27: msg_byte = 8'h0D;                     // CR
            default: msg_byte = 8'h0A;                   // LF
        endcase
    end

    // ---------------------------------------------------------------------
    // 8N1 transmitter, LSB first, start bit low, stop bit high
    // ---------------------------------------------------------------------
    uart_tx_byte #(.DIV(BAUD_DIV)) u_uart (
        .clk   (clk),
        .por_n (por_n),
        .start (start_byte),
        .data  (tx_data),
        .tx    (uart_tx),
        .busy  (tx_busy)
    );

endmodule

// =============================================================================
// Minimal 8N1 UART transmitter (115200 baud at 27 MHz with DIV = 234)
// =============================================================================
module uart_tx_byte #(
    parameter integer DIV = 234
) (
    input  wire       clk,
    input  wire       por_n,
    input  wire       start,
    input  wire [7:0] data,
    output reg        tx,
    output reg        busy
);

    reg [15:0] tcnt;
    reg [3:0]  nbits;
    reg [7:0]  sh;

    always @(posedge clk) begin
        if (!por_n) begin
            tx    <= 1'b1;
            busy  <= 1'b0;
            tcnt  <= 16'd0;
            nbits <= 4'd0;
            sh    <= 8'h00;
        end else if (!busy) begin
            tx <= 1'b1;
            if (start) begin
                busy  <= 1'b1;
                sh    <= data;
                nbits <= 4'd0;
                tcnt  <= 16'd0;
                tx    <= 1'b0;          // start bit
            end
        end else begin
            if (tcnt == DIV - 1) begin
                tcnt <= 16'd0;
                if (nbits == 4'd9) begin
                    busy <= 1'b0;
                    tx   <= 1'b1;
                end else begin
                    nbits <= nbits + 4'd1;
                    tx    <= (nbits < 4'd8) ? sh[nbits] : 1'b1;
                end
            end else begin
                tcnt <= tcnt + 16'd1;
            end
        end
    end

endmodule

`default_nettype wire
