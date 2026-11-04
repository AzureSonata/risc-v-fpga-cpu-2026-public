// SEN0327 I2S master receiver for the W3 KWS audio path.
//
// The system clock is 27 MHz by default. A fractional phase accumulator makes
// BCLK average 1.024 MHz; LRCK divides the 64 BCLK periods in a stereo frame
// into 32-bit left and right slots, giving 16 kHz frames. I2S data is sampled
// MSB first with the standard one-bit delay after each LRCK transition.
// Only the 24-bit left-channel word is retained. The signed 24-bit sample is
// reduced to signed PCM16 by taking bits [23:8], matching the firmware frontend.
//
// The 512-entry system-clock FIFO uses a ready/valid contract. A consumer must
// keep ready low until it can accept the current sample. A full FIFO drops the
// newly completed sample and sets sticky overrun; queued samples are preserved.
`timescale 1ns/1ps
`default_nettype none

module sen0327_i2s_rx #(
    parameter integer CLK_HZ = 27000000,
    parameter integer SAMPLE_RATE_HZ = 16000,
    parameter integer SLOT_BITS = 32,
    parameter integer FIFO_DEPTH = 512
)(
    input  wire                 clk,
    input  wire                 rst,
    output reg                  mic_bclk,
    output reg                  mic_lrck,
    input  wire                 mic_sd,

    output wire                 sample_valid,
    input  wire                 sample_ready,
    output wire signed [15:0]   sample_data,
    output wire [9:0]           fifo_level,
    output reg                  overrun,
    input  wire                 overrun_clear
);
    localparam integer BCLK_HZ = SAMPLE_RATE_HZ * SLOT_BITS * 2;
    // The accumulator overflows twice per BCLK period because each overflow
    // toggles BCLK. Round to nearest; at 27 MHz this yields bounded 13/14-cycle
    // half-periods and a frame-rate error below the accumulator's quantization.
    localparam [31:0] PHASE_INC = ((64'd1 << 33) * BCLK_HZ + CLK_HZ / 2) / CLK_HZ;
    localparam integer FIFO_AW = $clog2(FIFO_DEPTH);

    reg [31:0] phase_acc;
    wire [32:0] phase_sum = {1'b0, phase_acc} + {1'b0, PHASE_INC};
    wire bclk_tick = phase_sum[32];
    wire bclk_rise = bclk_tick && !mic_bclk;
    wire bclk_fall = bclk_tick && mic_bclk;

    reg [5:0] slot_bit;
    reg lrck_change_pending;
    reg [23:0] shift_reg;
    wire sample_complete = bclk_rise && !mic_lrck && (slot_bit == 6'd24);
    wire [23:0] completed_sample = {shift_reg[22:0], mic_sd};

    reg signed [15:0] fifo_mem [0:FIFO_DEPTH-1];
    reg signed [15:0] fifo_head;
    reg [FIFO_AW-1:0] wr_ptr;
    reg [FIFO_AW-1:0] rd_ptr;
    reg [9:0] count;
    wire [FIFO_AW-1:0] rd_ptr_next = rd_ptr + 1'b1;

    assign sample_valid = (count != 0);
    // Expose a registered queue head.  The only array read is synchronous in
    // the clocked block below so the sample storage can map to block RAM.
    assign sample_data = fifo_head;
    assign fifo_level = count;

    wire sample_pop = sample_valid && sample_ready;
    wire fifo_space = (count < FIFO_DEPTH) || sample_pop;
    wire sample_push = sample_complete && fifo_space;
    wire sample_drop = sample_complete && !fifo_space;

    // Keep the FIFO storage write port in its own clocked process. The array
    // is intentionally not reset; resetting the pointers/count is sufficient
    // to invalidate its contents and lets PDS infer the synchronous RAM port.
    always @(posedge clk) begin
        if (sample_push)
            fifo_mem[wr_ptr] <= $signed(completed_sample[23:8]);
    end

    always @(posedge clk) begin
        if (rst) begin
            phase_acc <= 32'd0;
            mic_bclk <= 1'b0;
            mic_lrck <= 1'b0;
            slot_bit <= 6'd0;
            lrck_change_pending <= 1'b0;
            shift_reg <= 24'd0;
            fifo_head <= 16'sd0;
            wr_ptr <= {FIFO_AW{1'b0}};
            rd_ptr <= {FIFO_AW{1'b0}};
            count <= 10'd0;
            overrun <= 1'b0;
        end else begin
            phase_acc <= phase_sum[31:0];
            if (bclk_tick) begin
                mic_bclk <= ~mic_bclk;
                if (bclk_rise) begin
                    if (!mic_lrck && slot_bit >= 6'd1 && slot_bit <= 6'd24)
                        shift_reg <= completed_sample;

                    if (slot_bit == SLOT_BITS - 1) begin
                        slot_bit <= 6'd0;
                        lrck_change_pending <= 1'b1;
                    end else begin
                        slot_bit <= slot_bit + 1'b1;
                    end
                end else if (bclk_fall && lrck_change_pending) begin
                    mic_lrck <= ~mic_lrck;
                    lrck_change_pending <= 1'b0;
                end
            end

            if (sample_push) begin
                wr_ptr <= wr_ptr + 1'b1;
            end
            if (sample_pop) begin
                rd_ptr <= rd_ptr + 1'b1;
                if (count > 10'd1)
                    fifo_head <= fifo_mem[rd_ptr_next];
                else if (sample_push)
                    // One-entry pop+push replaces the head with the new item.
                    fifo_head <= $signed(completed_sample[23:8]);
            end else if (sample_push && count == 10'd0) begin
                // Empty-to-one bypass avoids an extra-cycle valid/data bubble.
                fifo_head <= $signed(completed_sample[23:8]);
            end

            case ({sample_push, sample_pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase

            // An overflow event wins over a simultaneous clear so data loss is
            // never hidden by software acknowledging the previous event.
            if (overrun_clear)
                overrun <= 1'b0;
            if (sample_drop)
                overrun <= 1'b1;
        end
    end
endmodule

`default_nettype wire

