`timescale 1ns/1ps

// Full-system check of the Pangu W3 top with its KWS block integrated inside
// the SoC wrapper: five-stage dual-issue CPU -> D-side MMIO -> OpenEye/model ROM
// -> firmware logits/golden/decision/GPIO -> digital estop.
module tb_w3_kws_fixed_system;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rstn = 1'b0;
    // Models the external board strap. It is asserted before CPU reset release;
    // software has no MMIO arm/clear control under the approved ABI.
    reg estop_arm = 1'b1;

    wire estop_trip, kws_irq, uart_tx;
    wire [7:0] led;
    wire [31:0] gpio_out, trace0_pc, trace0_instr, trace0_cause;
    wire [31:0] trace1_pc, trace1_instr, trace1_cause, pc_debug;
    wire trace0_valid, trace0_trap, trace1_valid, trace1_trap;

    integer traps = 0;
    integer result_reads = 0;
    integer input_byte_writes = 0;
    integer start_writes = 0;
    integer heartbeat_writes = 0;
    integer estop_window_writes = 0;
    integer cycles = 0;
    integer decision_gpio_cycle = -1;
    integer estop_trip_cycle = -1;
    integer trip_gpio_cycle = -1;
    integer wait_cycles;
    reg result_pending = 1'b0;
    reg [31:0] last_logit_word = 32'd0;

    always @(posedge clk) begin
        if (rstn) begin
            cycles <= cycles + 1;
            if (trace0_valid && trace0_trap) traps <= traps + 1;
            if (trace1_valid && trace1_trap) traps <= traps + 1;

            if (gpio_out == 32'h4553_7901 && decision_gpio_cycle < 0)
                decision_gpio_cycle <= cycles;
            if (gpio_out == 32'h4553_7902 && trip_gpio_cycle < 0)
                trip_gpio_cycle <= cycles;
            if (estop_trip && estop_trip_cycle < 0)
                estop_trip_cycle <= cycles;

            if (dut.u_w3.accel_req_valid && dut.u_w3.accel_req_ready &&
                dut.u_w3.accel_write && dut.u_w3.accel_addr >= 32'h4000_1000 &&
                dut.u_w3.accel_addr < 32'h4000_17a8) begin
                if (input_byte_writes < 16)
                    $display("W3_INPUT_WRITE[%0d]: addr=%08x data=%08x strb=%x",
                             input_byte_writes, dut.u_w3.accel_addr,
                             dut.u_w3.accel_wdata, dut.u_w3.accel_wstrb);
                input_byte_writes <= input_byte_writes + 1;
            end
            if (dut.u_w3.accel_req_valid && dut.u_w3.accel_req_ready &&
                dut.u_w3.accel_write && dut.u_w3.accel_addr == 32'h4000_0004 &&
                dut.u_w3.accel_wdata == 32'd1)
                start_writes <= start_writes + 1;
            if (dut.u_w3.accel_req_valid && dut.u_w3.accel_req_ready &&
                dut.u_w3.accel_write && dut.u_w3.accel_addr == 32'h4000_004c)
                heartbeat_writes <= heartbeat_writes + 1;
            if (dut.u_w3.accel_req_valid && dut.u_w3.accel_req_ready &&
                dut.u_w3.accel_write && dut.u_w3.accel_addr == 32'h4000_0050)
                estop_window_writes <= estop_window_writes + 1;

            if (dut.u_w3.accel_req_valid && dut.u_w3.accel_req_ready &&
                !dut.u_w3.accel_write && dut.u_w3.accel_addr == 32'h4000_1800)
                result_pending <= 1'b1;
            if (dut.u_w3.accel_rsp_valid && dut.u_w3.accel_rsp_ready && result_pending) begin
                result_pending <= 1'b0;
                result_reads <= result_reads + 1;
                last_logit_word <= dut.u_w3.accel_rdata;
                if (dut.u_w3.accel_error)
                    $display("KWS_RESULT_BUS_ERROR: data=%08x", dut.u_w3.accel_rdata);
                else
                    $display("KWS_LOGITS[%0d]=%08x", result_reads,
                             dut.u_w3.accel_rdata);
            end
        end
    end

    pangu100proplus_w3_kws_top #(
        .ROM_INIT_FILE("build/w3-kws-fixed/kws.hex"),
        .MEM_DEPTH(16384), .MEM_AW(14), .UART_DIV(434), .M_MODE(2),
        .ICACHE_ENABLE(1'b1), .DCACHE_ENABLE(1'b1),
        .TIMEOUT_DEFAULT(704040), .LOGIT_OFF(4000)
    ) dut (
        .clk(clk), .rstn(rstn), .gpio_in(32'd0), .uart_rx(1'b1),
        .estop_arm(estop_arm), .estop_trip(estop_trip), .kws_irq(kws_irq),
        .led(led), .gpio_out(gpio_out), .uart_tx(uart_tx),
        .trace0_valid(trace0_valid), .trace0_pc(trace0_pc),
        .trace0_instr(trace0_instr), .trace0_trap(trace0_trap),
        .trace0_cause(trace0_cause), .trace1_valid(trace1_valid),
        .trace1_pc(trace1_pc), .trace1_instr(trace1_instr),
        .trace1_trap(trace1_trap), .trace1_cause(trace1_cause),
        .pc_debug(pc_debug)
    );

    initial begin
        repeat (10) @(posedge clk);
        rstn = 1'b1;
        wait_cycles = 0;
        while (gpio_out !== 32'h4553_7901 && wait_cycles < 10000000) begin
            @(posedge clk);
            wait_cycles = wait_cycles + 1;
        end
        #1;
        $display("W3_KWS_RESULT: gpio=%08x led=%02x starts=%0d input_bytes=%0d starts_mmio=%0d result_reads=%0d logits=%08x traps=%0d cycles=%0d pc=%08x",
                 gpio_out, led, dut.u_kws.o_start_count, input_byte_writes,
                 start_writes, result_reads, last_logit_word, traps, cycles, pc_debug);
        $display("W3_KWS_INPUT_RAM: word0=%08x word1=%08x word2=%08x word3=%08x expected first two words=5f766274/5165556a",
                 dut.u_kws.u_in_w.mem[0], dut.u_kws.u_in_w.mem[1],
                 dut.u_kws.u_in_w.mem[2], dut.u_kws.u_in_w.mem[3]);
        $display("W3_KWS_STATE: active=%0b done=%0b error=%0b code=%02x timeout=%0b cycle_count=%0d reject=%0d crc=%08x",
                 dut.u_kws.o_job_active, dut.u_kws.o_done_sticky,
                 dut.u_kws.o_error_sticky, dut.u_kws.o_error_code,
                 dut.u_kws.o_timeout_hit, dut.u_kws.o_cycle_count,
                 dut.u_kws.o_reject_count, dut.u_kws.crc_hold);
        $display("W3_KWS_ROM_CFG: dw=%0dx%0d -> %0dx%0dx%0d kernel=%0dx%0d stride=%0dx%0d pad=%0d/%0d zp=%0d/%0d fc=%0d->%0d fc_zp=%0d act=%0d..%0d",
                 dut.u_kws.u_model_rom.dw_ih, dut.u_kws.u_model_rom.dw_iw,
                 dut.u_kws.u_model_rom.dw_oh, dut.u_kws.u_model_rom.dw_ow,
                 dut.u_kws.u_model_rom.dw_cout, dut.u_kws.u_model_rom.dw_kh,
                 dut.u_kws.u_model_rom.dw_kw, dut.u_kws.u_model_rom.dw_sh,
                 dut.u_kws.u_model_rom.dw_sw, dut.u_kws.u_model_rom.dw_pt,
                 dut.u_kws.u_model_rom.dw_pl, dut.u_kws.u_model_rom.in_zp,
                 dut.u_kws.u_model_rom.dw_out_zp, dut.u_kws.u_model_rom.fc_nin,
                 dut.u_kws.u_model_rom.fc_nout, dut.u_kws.u_model_rom.fc_out_zp,
                 dut.u_kws.u_model_rom.act_min, dut.u_kws.u_model_rom.act_max);
        $display("W3_KWS_ROM_WORDS: dw=%02x,%02x,%02x,%02x fc=%02x,%02x,%02x,%02x bias=%08x quant=%08x/%08x",
                 dut.u_kws.u_model_rom.dw_weights[0], dut.u_kws.u_model_rom.dw_weights[1],
                 dut.u_kws.u_model_rom.dw_weights[2], dut.u_kws.u_model_rom.dw_weights[3],
                 dut.u_kws.u_model_rom.fc_weights[0], dut.u_kws.u_model_rom.fc_weights[1],
                 dut.u_kws.u_model_rom.fc_weights[2], dut.u_kws.u_model_rom.fc_weights[3],
                 dut.u_kws.u_model_rom.biases[0], dut.u_kws.u_model_rom.quant[0],
                 dut.u_kws.u_model_rom.quant[4]);
        if (gpio_out !== 32'h4553_7901 || dut.u_kws.o_start_count != 3 ||
            input_byte_writes != 5880 || start_writes != 3 ||
            result_reads != 3 || last_logit_word !== 32'hfc79_fcce || traps != 0 ||
            estop_arm !== 1'b1 || heartbeat_writes != 0 || estop_window_writes != 0 ||
            decision_gpio_cycle < 0)
            $fatal(1, "W3/OpenEye/firmware fixed-golden decision path failed");

        wait_cycles = 0;
        while (estop_trip !== 1'b1 && wait_cycles < 1350100) begin
            @(posedge clk);
            wait_cycles = wait_cycles + 1;
        end
        while (gpio_out !== 32'h4553_7902 && wait_cycles < 1350100) begin
            @(posedge clk);
            wait_cycles = wait_cycles + 1;
        end
        #1;
        $display("W3_KWS_ESTOP: trip=%0b wait_after_decision=%0d gpio=%08x arm_strap=%0b hb_writes=%0d window_writes=%0d decision_gpio_cycle=%0d estop_trip_cycle=%0d trip_gpio_cycle=%0d starts=%0d traps=%0d",
                 estop_trip, wait_cycles, gpio_out, estop_arm, heartbeat_writes,
                 estop_window_writes,
                 decision_gpio_cycle, estop_trip_cycle, trip_gpio_cycle,
                 dut.u_kws.o_start_count, traps);
        if (estop_trip !== 1'b1 || gpio_out !== 32'h4553_7902 ||
            heartbeat_writes != 0 || estop_window_writes != 0 || estop_arm !== 1'b1 ||
            decision_gpio_cycle < 0 || estop_trip_cycle <= decision_gpio_cycle ||
            trip_gpio_cycle <= estop_trip_cycle || traps != 0)
            $fatal(1, "W3 digital estop closure failed");
        $display("PASS: W3 -> real KWS -> T7 decision -> GPIO event -> external arm strap/no-heartbeat watchdog trip -> firmware GPIO acknowledgement");
        $finish;
    end
endmodule
