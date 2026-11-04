`timescale 1ns/1ps
`default_nettype none

module tb_sen0327_i2s_rx;
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg mic_sd = 1'b0;
    wire mic_bclk;
    wire mic_lrck;
    wire sample_valid;
    reg sample_ready = 1'b0;
    wire signed [15:0] sample_data;
    wire [9:0] fifo_level;
    wire overrun;
    reg overrun_clear = 1'b0;

    integer frame_index = 0;
    integer bit_index = 0;
    reg lrck_prev = 1'b0;
    integer accepted = 0;
    integer bclk_slot_edges = 0;
    reg lrck_monitor = 1'b0;
    integer sys_cycle_count = 0;
    integer last_bclk_transition = -1;
    integer last_left_frame = -1;
    integer measured_interval;
    integer measured_frames = 0;
    reg bclk_sys_previous = 1'b0;
    reg lrck_sys_previous = 1'b0;
    reg [15:0] held_sample = 16'd0;
    reg held_valid = 1'b0;
    reg [23:0] source_word;
    reg signed [15:0] expected_sample;
    reg signed [15:0] drain_expected;

    always #18.518518 clk = ~clk;

    sen0327_i2s_rx dut (
        .clk(clk), .rst(rst),
        .mic_bclk(mic_bclk), .mic_lrck(mic_lrck), .mic_sd(mic_sd),
        .sample_valid(sample_valid), .sample_ready(sample_ready),
        .sample_data(sample_data), .fifo_level(fifo_level),
        .overrun(overrun), .overrun_clear(overrun_clear)
    );

    // Verify the fractional divider produces 13/14 system-clock BCLK half
    // periods and 1687/1688 system-clock periods between 16 kHz frames.
    always @(posedge clk) begin
        if (rst) begin
            sys_cycle_count = 0;
            last_bclk_transition = -1;
            last_left_frame = -1;
            measured_frames = 0;
            bclk_sys_previous = mic_bclk;
            lrck_sys_previous = mic_lrck;
        end else begin
            sys_cycle_count = sys_cycle_count + 1;
            if (mic_bclk != bclk_sys_previous) begin
                if (last_bclk_transition >= 0) begin
                    measured_interval = sys_cycle_count - last_bclk_transition;
                    if (measured_interval < 13 || measured_interval > 14)
                        $fatal(1, "BCLK half-period was %0d clocks", measured_interval);
                end
                last_bclk_transition = sys_cycle_count;
                bclk_sys_previous = mic_bclk;
            end
            if (mic_lrck != lrck_sys_previous) begin
                if (lrck_sys_previous && !mic_lrck) begin
                    if (last_left_frame >= 0) begin
                        measured_interval = sys_cycle_count - last_left_frame;
                        if (measured_interval < 1687 || measured_interval > 1688)
                            $fatal(1, "16 kHz frame period was %0d clocks", measured_interval);
                        measured_frames = measured_frames + 1;
                    end
                    last_left_frame = sys_cycle_count;
                end
                lrck_sys_previous = mic_lrck;
            end
        end
    end

    function [23:0] left_word(input integer idx);
        begin
            case (idx)
                0: left_word = 24'h123456;
                1: left_word = 24'hFEDCBA;
                2: left_word = 24'h8000FF;
                3: left_word = 24'h7FFFFF;
                default: left_word = (idx * 24'h010203) & 24'hFFFFFF;
            endcase
        end
    endfunction

    function [23:0] right_word(input integer idx);
        begin
            right_word = (24'hA5C39E ^ (idx * 24'h000101)) & 24'hFFFFFF;
        end
    endfunction

    // I2S source model: LRCK changes at the slot boundary; the first bit clock
    // is the one-bit delay, then the next 24 clocks carry MSB-first sample data.
    always @(negedge mic_bclk) begin
        if (rst) begin
            mic_sd <= 1'b0;
            bit_index <= 0;
            frame_index <= 0;
            lrck_prev <= mic_lrck;
        end else if (mic_lrck != lrck_prev) begin
            if (lrck_prev == 1'b1 && mic_lrck == 1'b0)
                frame_index <= frame_index + 1;
            lrck_prev <= mic_lrck;
            bit_index <= 0;
            mic_sd <= 1'b0;
        end else if (bit_index < 24) begin
            if (mic_lrck == 1'b0)
                source_word = left_word(frame_index);
            else
                source_word = right_word(frame_index);
            mic_sd <= source_word[23-bit_index];
            bit_index <= bit_index + 1;
        end else begin
            mic_sd <= 1'b0;
        end
    end

    // Each LRCK half-frame must contain exactly 32 BCLK rising edges.
    always @(posedge mic_bclk) begin
        if (!rst) begin
            if (mic_lrck != lrck_monitor) begin
                if (bclk_slot_edges != 32)
                    $fatal(1, "LRCK slot had %0d BCLK edges, expected 32", bclk_slot_edges);
                lrck_monitor <= mic_lrck;
                bclk_slot_edges <= 1;
            end else begin
                bclk_slot_edges <= bclk_slot_edges + 1;
            end
        end else begin
            bclk_slot_edges <= 0;
            lrck_monitor <= mic_lrck;
        end
    end

    always @(posedge clk) begin
        if (!rst && sample_valid && sample_ready) begin
            expected_sample = left_word(accepted) >> 8;
            if (sample_data !== expected_sample)
                $fatal(1, "sample %0d got %04x expected %04x", accepted,
                       sample_data, expected_sample);
            accepted <= accepted + 1;
            held_valid <= 1'b0;
        end
        if (!rst && sample_valid && !sample_ready) begin
            if (held_valid && held_sample !== sample_data)
                $fatal(1, "valid/data changed under backpressure");
            held_sample <= sample_data;
            held_valid <= 1'b1;
        end
    end

    integer timeout_count;
    integer drain_index;
    initial begin
        repeat (8) @(posedge clk);
        rst = 1'b0;

        // First three samples are consumed immediately and verify I2S delay,
        // left-channel selection, MSB ordering, signedness and PCM16 truncation.
        @(negedge clk);
        sample_ready = 1'b1;
        timeout_count = 0;
        while (accepted < 3 && timeout_count < 12000) begin
            @(posedge clk);
            timeout_count = timeout_count + 1;
        end
        if (accepted != 3) $fatal(1, "timed out waiting for first three samples");

        // Stop the consumer. The production FIFO must retain the oldest 512 samples while
        // dropping the next one and setting sticky overrun.
        @(negedge clk);
        sample_ready = 1'b0;
        timeout_count = 0;
        while ((!overrun || fifo_level != 512) && timeout_count < 1000000) begin
            @(posedge clk);
            timeout_count = timeout_count + 1;
        end
        if (fifo_level != 512) $fatal(1, "FIFO did not fill to 512; level=%0d", fifo_level);
        if (!overrun) $fatal(1, "full FIFO did not set sticky overrun");
        if (!sample_valid) $fatal(1, "full FIFO not valid");

        @(negedge clk);
        sample_ready = 1'b1;
        drain_index = 0;
        timeout_count = 0;
        while (drain_index < 512 && timeout_count < 2000) begin
            @(posedge clk);
            if (sample_valid && sample_ready) begin
                drain_expected = left_word(3 + drain_index) >> 8;
                if (sample_data !== drain_expected)
                    $fatal(1, "FIFO drain %0d got %04x expected %04x", drain_index,
                           sample_data, drain_expected);
                drain_index = drain_index + 1;
            end
            timeout_count = timeout_count + 1;
        end
        if (drain_index != 512) $fatal(1, "timed out draining FIFO");
        if (overrun !== 1'b1) $fatal(1, "overrun did not remain sticky");

        @(negedge clk);
        overrun_clear = 1'b1;
        @(negedge clk);
        overrun_clear = 1'b0;
        @(posedge clk);
        if (overrun !== 1'b0) $fatal(1, "overrun clear did not clear sticky flag");
        if (fifo_level != 0) $fatal(1, "FIFO not empty after drain: %0d", fifo_level);
        if (measured_frames < 500)
            $fatal(1, "only %0d 16 kHz frame periods measured", measured_frames);

        $display("PASS: SEN0327 I2S timing, PCM16 samples, FIFO backpressure/overflow/clear");
        $finish;
    end
endmodule

`default_nettype wire
