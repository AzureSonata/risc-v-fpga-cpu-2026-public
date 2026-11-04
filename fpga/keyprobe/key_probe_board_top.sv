// =============================================================================
// key_probe_board_top.sv -- KEY pin / polarity probe for the MES2L676-100HP stack
//
// Purpose
//   Golden v3 booted from Flash and warm-booted KWS successfully, but holding the
//   physical "KEY1" during power-up still ended up in KWS. Before changing the
//   selector again we need ground truth: which balls are the three user keys
//   wired to, and what polarity do they really have on this board?
//
//   This design does nothing but sample KEY0/KEY1/KEY2 and report them on the
//   board USB-UART at 115200 8N1 (27 MHz / 234). Every 100 ms it prints one line
//       KEY raw=<k2k1k0> pressed=<p2p1p0> k0=<0/1> k1=<0/1> k2=<0/1>
//   and it prints an immediate CHG line (same body) whenever the synchronized
//   levels change, so a single press/release is visible with timestamps.
//       raw     = raw pin levels after one synchronizer flop (1 = pin high)
//       pressed = ~synced level per key (1 = "pressed" under the active-low
//                 assumption; if a key reads 1 at rest, the board wiring or the
//                 assumption differs and raw/pressed will disagree)
//
// Pins (same mapping as the A4 boot selector, so the comparison is apples-to-
// apples): clk = D18 (27 MHz), key0_n = C22, key1_n = C23, key2_n = B22,
// uart_tx = C24. No reset pin is used on purpose: the probe must not depend on
// KEY0, which is one of the signals under test.
//
// Written in plain Verilog-2001 style on purpose: the PDS 2022.2 front end
// rejects SystemVerilog `parameter bit` and friends (see A4b notes).
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module key_probe_board_top (
    input  wire clk,
    input  wire key0_n,
    input  wire key1_n,
    input  wire key2_n,
    output wire uart_tx
);

    localparam integer BAUD_DIV   = 234;                 // 27e6 / 115200 = 234.4
    localparam integer TICK_100MS = 27_000_000 / 10;     // 2,700,000 clocks
    localparam integer MSG_LEN    = 40;

    // ---------------------------------------------------------------------
    // Power-on reset: hold ~256 clocks, then release. Keeps the probe
    // independent of any external reset pin.
    // ---------------------------------------------------------------------
    reg [7:0] por_cnt;
    initial por_cnt = 8'd0;
    wire por_n = por_cnt[7];
    always @(posedge clk) begin
        if (!por_n) por_cnt <= por_cnt + 8'd1;
    end

    // ---------------------------------------------------------------------
    // 2-FF synchronizers per key
    // ---------------------------------------------------------------------
    reg [1:0] k0_s, k1_s, k2_s;

    always @(posedge clk) begin
        if (!por_n) begin
            k0_s <= 2'b11;
            k1_s <= 2'b11;
            k2_s <= 2'b11;
        end else begin
            k0_s <= {k0_s[0], key0_n};
            k1_s <= {k1_s[0], key1_n};
            k2_s <= {k2_s[0], key2_n};
        end
    end

    wire [2:0] raw    = {k2_s[0], k1_s[0], k0_s[0]};      // 1 = pin high
    wire [2:0] pres   = {~k2_s[1], ~k1_s[1], ~k0_s[1]};   // 1 = pressed (active low)
    wire [2:0] stable = {k2_s[1], k1_s[1], k0_s[1]};      // change detector

    // ---------------------------------------------------------------------
    // 100 ms heartbeat and change detector
    // ---------------------------------------------------------------------
    reg [21:0] tick_cnt;
    reg        tick_100ms;
    reg [2:0]  stable_d;
    reg        chg_pending;

    // ---------------------------------------------------------------------
    // Line sender state
    // ---------------------------------------------------------------------
    reg [5:0] pos;
    reg       hdr_chg;
    reg [2:0] raw_l, pres_l;
    reg       sending;
    reg       start_byte;
    reg [7:0] tx_data;
    reg [7:0] msg_byte;
    wire      tx_busy;

    always @(posedge clk) begin
        if (!por_n) begin
            tick_cnt    <= 22'd0;
            tick_100ms  <= 1'b0;
            stable_d    <= 3'b111;
            chg_pending <= 1'b0;
            pos         <= 6'd0;
            hdr_chg     <= 1'b0;
            raw_l       <= 3'b000;
            pres_l      <= 3'b000;
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
                    pos         <= 6'd0;
                    sending     <= 1'b1;
                    chg_pending <= 1'b0;
                end else if (tick_100ms && !tx_busy && !start_byte) begin
                    hdr_chg <= 1'b0;
                    raw_l   <= raw;
                    pres_l  <= pres;
                    pos     <= 6'd0;
                    sending <= 1'b1;
                end
            end else if (!tx_busy && !start_byte) begin
                tx_data    <= msg_byte;
                start_byte <= 1'b1;
                if (pos == MSG_LEN - 1) begin
                    sending <= 1'b0;
                    pos     <= 6'd0;
                end else begin
                    pos <= pos + 6'd1;
                end
            end
        end
    end

    // ---------------------------------------------------------------------
    // Message: "KEY raw=<k2k1k0> pressed=<p2p1p0> k0=<0/1> k1=<0/1> k2=<0/1>\r\n"
    // (identical body for CHG, only the 4-char header differs)
    //   0..3   header          "KEY " / "CHG "
    //   4..7   "raw="
    //   8..10  raw[2:0]
    //   11     ' '
    //   12..19 "pressed="
    //   20..22 pressed[2:0]
    //   23     ' '
    //   24..26 "k0="  27 k0
    //   28     ' '
    //   29..31 "k1="  32 k1
    //   33     ' '
    //   34..36 "k2="  37 k2
    //   38     CR     39 LF
    // ---------------------------------------------------------------------


    always @* begin
        case (pos)
            6'd0:  msg_byte = hdr_chg ? 8'h43 : 8'h4B;   // 'C' / 'K'
            6'd1:  msg_byte = hdr_chg ? 8'h48 : 8'h45;   // 'H' / 'E'
            6'd2:  msg_byte = hdr_chg ? 8'h47 : 8'h59;   // 'G' / 'Y'
            6'd3:  msg_byte = 8'h20;                     // ' '
            6'd4:  msg_byte = 8'h72;                     // 'r'
            6'd5:  msg_byte = 8'h61;                     // 'a'
            6'd6:  msg_byte = 8'h77;                     // 'w'
            6'd7:  msg_byte = 8'h3D;                     // '='
            6'd8:  msg_byte = {7'b0011000, raw_l[2]};
            6'd9:  msg_byte = {7'b0011000, raw_l[1]};
            6'd10: msg_byte = {7'b0011000, raw_l[0]};
            6'd11: msg_byte = 8'h20;
            6'd12: msg_byte = 8'h70;                     // 'p'
            6'd13: msg_byte = 8'h72;                     // 'r'
            6'd14: msg_byte = 8'h65;                     // 'e'
            6'd15: msg_byte = 8'h73;                     // 's'
            6'd16: msg_byte = 8'h73;                     // 's'
            6'd17: msg_byte = 8'h65;                     // 'e'
            6'd18: msg_byte = 8'h64;                     // 'd'
            6'd19: msg_byte = 8'h3D;                     // '='
            6'd20: msg_byte = {7'b0011000, pres_l[2]};
            6'd21: msg_byte = {7'b0011000, pres_l[1]};
            6'd22: msg_byte = {7'b0011000, pres_l[0]};
            6'd23: msg_byte = 8'h20;
            6'd24: msg_byte = 8'h6B;                     // 'k'
            6'd25: msg_byte = 8'h30;                     // '0'
            6'd26: msg_byte = 8'h3D;                     // '='
            6'd27: msg_byte = {7'b0011000, pres_l[0]};
            6'd28: msg_byte = 8'h20;
            6'd29: msg_byte = 8'h6B;                     // 'k'
            6'd30: msg_byte = 8'h31;                     // '1'
            6'd31: msg_byte = 8'h3D;                     // '='
            6'd32: msg_byte = {7'b0011000, pres_l[1]};
            6'd33: msg_byte = 8'h20;
            6'd34: msg_byte = 8'h6B;                     // 'k'
            6'd35: msg_byte = 8'h32;                     // '2'
            6'd36: msg_byte = 8'h3D;                     // '='
            6'd37: msg_byte = {7'b0011000, pres_l[2]};
            6'd38: msg_byte = 8'h0D;                     // CR
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
