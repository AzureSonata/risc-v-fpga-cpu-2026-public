`timescale 1ns/1ps

// Board-level fan gate regression: a real watchdog timeout must override a
// high GPIO fan request, and a CPU reset must not clear the latched trip.
module tb_w3_kws_board_estop_gate;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rstn = 1'b0;
    reg uart_rx = 1'b1;
    reg estop_arm = 1'b1;
    reg mic_sd = 1'b0;
    wire uart_tx, mic_bclk, mic_lrck, fan_enable;
    wire [7:0] led;
    integer cycles = 0;

    pangu100proplus_w3_kws_board_top #(
        .ROM_INIT_FILE("build/w3-kws-live/kws_live.hex"),
        .MEM_DEPTH(16384), .MEM_AW(14), .UART_DIV(434), .M_MODE(2),
        .ESTOP_WINDOW_DEFAULT(32'd16),
        .ICACHE_ENABLE(1'b1), .DCACHE_ENABLE(1'b1)
    ) dut (
        .clk(clk), .rstn(rstn), .uart_rx(uart_rx), .uart_tx(uart_tx),
        .estop_arm(estop_arm), .mic_sd(mic_sd), .mic_bclk(mic_bclk),
        .mic_lrck(mic_lrck), .fan_enable(fan_enable), .led(led)
    );

    initial begin
        repeat (10) @(posedge clk);
        #1;
        if (dut.u_system.estop_por !== 1'b0 || dut.u_system.estop_trip !== 1'b0)
            $fatal(1, "configuration POR did not release into an untripped state");

        // Hold the GPIO request high across the watchdog timeout to isolate
        // the board's combinational safety gate from application behavior.
        force dut.u_system.gpio_out = 32'h8000_0000;
        rstn = 1'b1;
        #1;
        if (fan_enable !== 1'b1)
            $fatal(1, "fan GPIO request did not reach the output before trip");

        while (dut.u_system.estop_trip !== 1'b1 && cycles < 100) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        #1;
        if (dut.u_system.estop_trip !== 1'b1)
            $fatal(1, "armed watchdog did not latch a timeout trip");
        if (fan_enable !== 1'b0 || led[7] !== 1'b1)
            $fatal(1, "watchdog trip did not force fan low and assert LED7");

        rstn = 1'b0;
        repeat (2) @(posedge clk);
        #1;
        if (dut.u_system.estop_trip !== 1'b1)
            $fatal(1, "CPU reset cleared the watchdog trip");

        rstn = 1'b1;
        repeat (2) @(posedge clk);
        #1;
        if (dut.u_system.estop_trip !== 1'b1 || fan_enable !== 1'b0)
            $fatal(1, "trip did not remain latched after CPU reset release");

        $display("PASS: board watchdog trip overrides forced fan GPIO, lights LED7, and survives CPU reset (%0d cycles)", cycles);
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "board watchdog gate test timed out");
    end
endmodule
