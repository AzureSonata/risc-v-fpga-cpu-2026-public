`timescale 1ns/1ps

// Full board-wrapper path: SEN0327 serial input -> synchronous FIFO -> CPU
// audio MMIO -> live frontend -> real KWS/OpenEye -> same-class fan decision.
module tb_w3_kws_live_system #(
    parameter ROM_INIT_FILE = "build/w3-kws-live/kws_live.hex"
);
    localparam integer PCM_SAMPLES = 16000;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rstn = 1'b0;
    reg uart_rx = 1'b1;
    reg estop_arm = 1'b1;
    reg mic_sd = 1'b0;
    wire uart_tx, mic_bclk, mic_lrck, fan_enable;
    wire [7:0] led;

    reg [15:0] pcm_words [0:PCM_SAMPLES-1];
    reg [1023:0] pcm_hex_path;
    reg [1023:0] pcm_hex_second_path;
    reg [1023:0] pcm_hex_pre_fan_path;
    integer frame_index = 0;
    integer bit_index = 0;
    reg lrck_prev = 1'b0;
    reg [23:0] source_word;
    reg [15:0] source_sample;

    integer cycles = 0;
    integer traps = 0;
    integer audio_pop_requests = 0;
    integer samples_accepted = 0;
    integer start_writes = 0;
    integer result_reads = 0;
    integer heartbeat_writes = 0;
    integer estop_window_writes = 0;
    integer max_cycles = 60000000;
    integer expect_fan = 1;
    integer expect_led = -1;
    integer min_results = 2;
    integer transition_mode = 0;
    integer pre_fan_mode = 0;
    integer pre_fan_after_results = 3;
    integer pre_fan_results_after_on = 3;
    integer post_switch_results = 1;
    integer results_before_pre_fan = 0;
    integer results_before_switch = 0;
    integer pre_fan_switch_sample = 0;
    integer samples_before_switch = 0;
    integer fan_on_seen = 0;
    integer overrun_seen = 0;
    reg result_pending = 1'b0;
    integer last_result_cycle = -1;
    reg [31:0] last_logits = 32'd0;
    integer trace_results = 0;
    reg trace_fan_last = 1'b0;
    integer signed logits_q0;
    integer signed logits_q1;
    integer signed logits_q2;
    integer signed logits_q3;
    reg [1023:0] logits_csv_path;
    integer logits_csv_fd = 0;

    wire estop_trip = dut.u_system.estop_trip;

    function automatic integer signed byte_s8(input reg [7:0] value);
        byte_s8 = $signed({{24{value[7]}}, value});
    endfunction

    initial begin
        if (!$value$plusargs("PCM_HEX=%s", pcm_hex_path))
            $fatal(1, "missing +PCM_HEX=<16 kHz PCM16 hex file>");
        if ($value$plusargs("MAX_CYCLES=%d", max_cycles) == 0)
            max_cycles = 60000000;
        if ($value$plusargs("EXPECT_FAN=%d", expect_fan) == 0)
            expect_fan = 1;
        if ($value$plusargs("EXPECT_LED=%d", expect_led) == 0)
            expect_led = -1;
        if ($value$plusargs("MIN_RESULTS=%d", min_results) == 0)
            min_results = 2;
        if (min_results < 2)
            $fatal(1, "MIN_RESULTS must be at least two");
        transition_mode = $value$plusargs("PCM_HEX_SECOND=%s", pcm_hex_second_path);
        pre_fan_mode = $value$plusargs("PCM_HEX_PRE_FAN=%s", pcm_hex_pre_fan_path);
        if ($value$plusargs("PRE_FAN_AFTER_RESULTS=%d", pre_fan_after_results) == 0)
            pre_fan_after_results = 3;
        if ($value$plusargs("PRE_FAN_RESULTS_AFTER_ON=%d", pre_fan_results_after_on) == 0)
            pre_fan_results_after_on = 3;
        if ($value$plusargs("POST_SWITCH_RESULTS=%d", post_switch_results) == 0)
            post_switch_results = 1;
        if (pre_fan_mode != 0 && pre_fan_after_results <= 0)
            $fatal(1, "PRE_FAN_AFTER_RESULTS must be positive");
        if (pre_fan_mode != 0 && pre_fan_results_after_on <= 0)
            $fatal(1, "PRE_FAN_RESULTS_AFTER_ON must be positive");
        if (transition_mode != 0 && post_switch_results <= 0)
            $fatal(1, "POST_SWITCH_RESULTS must be positive");
        trace_results = $test$plusargs("TRACE_RESULTS");
        if ($value$plusargs("LOGITS_FILE=%s", logits_csv_path) != 0) begin
            logits_csv_fd = $fopen(logits_csv_path, "w");
            if (logits_csv_fd == 0)
                $fatal(1, "cannot open +LOGITS_FILE=%0s", logits_csv_path);
            $fdisplay(logits_csv_fd,
                      "result,cycle,samples_accepted,pre_fan_switch_sample,fan_on_switch_sample,phase,raw_word,q0,q1,q2,q3");
        end
        $readmemh(pcm_hex_path, pcm_words, 0, PCM_SAMPLES-1);

        repeat (10) @(posedge clk);
        rstn = 1'b1;

        if (transition_mode != 0 || pre_fan_mode != 0) begin
            // Keep one CPU/accelerator/watchdog session running while the live
            // PCM source changes from a positive phrase to a negative phrase.
            // Mode-B Yes segmentation needs a quiet source to close the Yes
            // segment before fan-on; optionally insert that source first.
            if (pre_fan_mode != 0) begin
                while (result_reads < pre_fan_after_results && cycles < max_cycles)
                    @(posedge clk);
                if (result_reads < pre_fan_after_results)
                    $fatal(1, "pre-fan PCM switch result threshold not reached");
                @(negedge mic_lrck);
                #1;
                $readmemh(pcm_hex_pre_fan_path, pcm_words, 0, PCM_SAMPLES-1);
                results_before_pre_fan = result_reads;
                pre_fan_switch_sample = samples_accepted;
                if (fan_enable !== 1'b0)
                    $fatal(1, "fan turned on before the pre-fan closure PCM was applied");
                $display("W3_KWS_LIVE_TRANSITION: switched to pre-fan PCM at frame boundary; results=%0d cycles=%0d",
                         result_reads, cycles);
            end
            while (fan_enable !== 1'b1 && cycles < max_cycles)
                @(posedge clk);
            if (fan_enable !== 1'b1)
                $fatal(1, "positive/quiet sequence did not turn fan on before source switch");
            fan_on_seen = 1;
            if (transition_mode != 0) begin
                results_before_switch = result_reads;
                @(negedge mic_lrck);
                #1;
                $readmemh(pcm_hex_second_path, pcm_words, 0, PCM_SAMPLES-1);
                samples_before_switch = samples_accepted;
                $display("W3_KWS_LIVE_TRANSITION: switched PCM at frame boundary after fan-on; prior_results=%0d cycles=%0d",
                         results_before_switch, cycles);
                while ((fan_enable !== (expect_fan != 0) ||
                        result_reads < results_before_switch + post_switch_results) &&
                       cycles < max_cycles)
                    @(posedge clk);
            end else begin
                while ((fan_enable !== (expect_fan != 0) ||
                        result_reads < results_before_pre_fan + pre_fan_results_after_on) &&
                       (transition_mode != 0 ||
                        fan_enable === (expect_fan != 0)) &&
                       cycles < max_cycles)
                    @(posedge clk);
            end
        end else if (expect_fan != 0) begin
            while ((fan_enable !== 1'b1 || result_reads < min_results) &&
                   cycles < max_cycles)
                @(posedge clk);
        end else begin
            while ((result_reads < min_results || cycles < last_result_cycle + 10000) &&
                   cycles < max_cycles)
                @(posedge clk);
        end
        #1;

        $display("W3_KWS_LIVE: fan=%0b led=%02x starts=%0d results=%0d last_logits=%08x audio_reads=%0d samples=%0d fifo_level=%0d overrun=%0b heartbeats=%0d trip=%0b traps=%0d cycles=%0d pc=%08x",
                 fan_enable, led, start_writes, result_reads, last_logits,
                 audio_pop_requests, samples_accepted,
                 dut.u_system.audio_fifo_level, overrun_seen,
                 heartbeat_writes, estop_trip, traps, cycles,
                 dut.u_system.pc_debug);

        if (logits_csv_fd != 0)
            $fclose(logits_csv_fd);

        if (cycles >= max_cycles)
            $fatal(1, "live audio application timed out");
        if (fan_enable !== (expect_fan != 0))
            $fatal(1, "fan output mismatch: expected=%0d got=%0b", expect_fan, fan_enable);
        if (expect_led >= 0 && led !== expect_led[7:0])
            $fatal(1, "LED event marker mismatch: expected=%02x got=%02x", expect_led[7:0], led);
        if (transition_mode != 0 &&
            (fan_on_seen == 0 ||
             result_reads < results_before_switch + post_switch_results ||
             fan_enable !== (expect_fan != 0)))
            $fatal(1, "continuous positive-to-negative fan transition did not complete");
        if (pre_fan_mode != 0 && transition_mode == 0 &&
            (fan_on_seen == 0 ||
             result_reads < results_before_pre_fan + pre_fan_results_after_on ||
             fan_enable !== (expect_fan != 0)))
            $fatal(1, "positive-to-quiet segment closure control did not complete");
        if (start_writes < min_results || result_reads < min_results)
            $fatal(1, "fewer than the requested real accelerator inferences completed");
        if (audio_pop_requests < 18000 || samples_accepted < 18000)
            $fatal(1, "live PCM did not traverse the audio FIFO/MMIO path");
        if (overrun_seen != 0 || dut.u_system.audio_fifo_level >= 10'd512)
            $fatal(1, "audio FIFO overrun/full condition observed");
        if (heartbeat_writes == 0 || estop_trip !== 1'b0)
            $fatal(1, "watchdog heartbeat/trip behavior mismatch");
        if (estop_window_writes != 0)
            $fatal(1, "firmware unexpectedly modified the watchdog window");
        if (traps != 0)
            $fatal(1, "CPU trap observed during the live audio run");

        if (transition_mode != 0 && pre_fan_mode != 0)
            $display("PASS: W3 board wrapper positive->quiet->second PCM; fan ended at expected state %0d, no overrun/trip/trap",
                     expect_fan);
        else if (transition_mode != 0)
            $display("PASS: W3 board wrapper positive->second PCM; fan ended at expected state %0d, no overrun/trip/trap",
                     expect_fan);
        else if (pre_fan_mode != 0)
            $display("PASS: W3 board wrapper positive->quiet PCM; fan remained at expected state for configured results, no overrun/trip/trap");
        else
            $display("PASS: W3 board wrapper live %0s PCM -> I2S/FIFO/MMIO -> frontend/OpenEye -> fan GPIO; no overrun, watchdog trip, or CPU trap",
                     (expect_fan != 0) ? "positive" : "negative");
        $finish;
    end

    // I2S stimulus source: the first bit after LRCK transition is the standard
    // one-bit delay; the 24-bit left sample is PCM16 followed by eight zeroes.
    always @(negedge mic_bclk) begin
        if (!rstn) begin
            mic_sd <= 1'b0;
            bit_index = 0;
            frame_index = 0;
            lrck_prev = mic_lrck;
        end else if (mic_lrck != lrck_prev) begin
            if (lrck_prev && !mic_lrck)
                frame_index = frame_index + 1;
            lrck_prev = mic_lrck;
            bit_index = 0;
            mic_sd <= 1'b0;
        end else if (bit_index < 24) begin
            if (!mic_lrck) begin
                source_sample = pcm_words[frame_index % PCM_SAMPLES];
                source_word = {source_sample, 8'b0};
            end else begin
                source_word = 24'd0;
            end
            mic_sd <= source_word[23-bit_index];
            bit_index = bit_index + 1;
        end else begin
            mic_sd <= 1'b0;
        end
    end

    always @(posedge clk) begin
        if (rstn) begin
            cycles = cycles + 1;
            if (dut.u_system.trace0_valid && dut.u_system.trace0_trap)
                begin
                    traps = traps + 1;
                    if (traps <= 8)
                        $display("TRAP0 cycle=%0d pc=%08x instr=%08x cause=%08x next_pc=%08x mepc=%08x mcause=%08x mtval=%08x d_req=%b addr=%08x wr=%b strb=%x error=%b",
                                 cycles,
                                 dut.u_system.trace0_pc, dut.u_system.trace0_instr,
                                 dut.u_system.trace0_cause, dut.u_system.pc_debug,
                                 dut.u_system.u_w3.u_cpu.u_csr.mepc_q,
                                 dut.u_system.u_w3.u_cpu.u_csr.mcause_q,
                                 dut.u_system.u_w3.u_cpu.u_csr.mtval_q,
                                 dut.u_system.u_w3.d_req_valid,
                                 dut.u_system.u_w3.d_req_addr,
                                 dut.u_system.u_w3.d_req_write,
                                 dut.u_system.u_w3.d_req_wstrb,
                                 dut.u_system.u_w3.d_rsp_error);
                end
            if (dut.u_system.trace1_valid && dut.u_system.trace1_trap)
                begin
                    traps = traps + 1;
                    if (traps <= 8)
                        $display("TRAP1 cycle=%0d pc=%08x instr=%08x cause=%08x next_pc=%08x", cycles,
                                 dut.u_system.trace1_pc, dut.u_system.trace1_instr,
                                 dut.u_system.trace1_cause, dut.u_system.pc_debug);
                end

            if (dut.u_system.audio_sample_valid && dut.u_system.audio_sample_ready)
                samples_accepted = samples_accepted + 1;
            if (dut.u_system.audio_overrun)
                overrun_seen = 1;

            if (dut.u_system.accel_req_valid && dut.u_system.accel_req_ready) begin
                if (!dut.u_system.accel_write && dut.u_system.accel_addr == 32'h40002000)
                    audio_pop_requests = audio_pop_requests + 1;
                if (dut.u_system.accel_write && dut.u_system.accel_addr == 32'h40000004 &&
                    dut.u_system.accel_wdata == 32'd1)
                    start_writes = start_writes + 1;
                if (dut.u_system.accel_write && dut.u_system.accel_addr == 32'h4000004c)
                    heartbeat_writes = heartbeat_writes + 1;
                if (dut.u_system.accel_write && dut.u_system.accel_addr == 32'h40000050)
                    estop_window_writes = estop_window_writes + 1;
                if (!dut.u_system.accel_write && dut.u_system.accel_addr == 32'h40001800)
                    result_pending = 1'b1;
            end

            if (dut.u_system.accel_rsp_valid && dut.u_system.accel_rsp_ready && result_pending) begin
                result_pending = 1'b0;
                result_reads = result_reads + 1;
                last_result_cycle = cycles;
                last_logits = dut.u_system.accel_rdata;
                logits_q0 = byte_s8(dut.u_system.accel_rdata[7:0]);
                logits_q1 = byte_s8(dut.u_system.accel_rdata[15:8]);
                logits_q2 = byte_s8(dut.u_system.accel_rdata[23:16]);
                logits_q3 = byte_s8(dut.u_system.accel_rdata[31:24]);
                if (trace_results != 0) begin
                    $display("KWS_RESULT window=%0d cycle=%0d logits=[%0d,%0d,%0d,%0d] fan=%0b",
                             result_reads, cycles, logits_q0, logits_q1, logits_q2, logits_q3,
                             fan_enable);
                end
                if (logits_csv_fd != 0)
                    $fdisplay(logits_csv_fd, "%0d,%0d,%0d,%0d,%0d,%0s,%08x,%0d,%0d,%0d,%0d",
                              result_reads, cycles, samples_accepted,
                              pre_fan_switch_sample, samples_before_switch,
                              (transition_mode != 0 && results_before_switch != 0 &&
                               result_reads > results_before_switch ? "post" :
                               (pre_fan_mode != 0 && results_before_pre_fan != 0 &&
                                result_reads > results_before_pre_fan ? "closure" :
                                (transition_mode != 0 || pre_fan_mode != 0 ? "pre" : "single"))),
                              dut.u_system.accel_rdata,
                              logits_q0, logits_q1, logits_q2, logits_q3);
            end

            if (trace_results != 0 && fan_enable !== trace_fan_last) begin
                trace_fan_last = fan_enable;
                $display("KWS_FAN cycle=%0d fan=%0b led=%02x", cycles,
                         fan_enable, led);
            end
        end
    end

    pangu100proplus_w3_kws_board_top #(
        .ROM_INIT_FILE(ROM_INIT_FILE),
        .MEM_DEPTH(16384), .MEM_AW(14), .UART_DIV(434), .M_MODE(2),
        .ICACHE_ENABLE(1'b1), .DCACHE_ENABLE(1'b1)
    ) dut (
        .clk(clk), .rstn(rstn), .uart_rx(uart_rx), .uart_tx(uart_tx),
        .estop_arm(estop_arm), .mic_sd(mic_sd), .mic_bclk(mic_bclk),
        .mic_lrck(mic_lrck), .fan_enable(fan_enable), .led(led)
    );
endmodule
