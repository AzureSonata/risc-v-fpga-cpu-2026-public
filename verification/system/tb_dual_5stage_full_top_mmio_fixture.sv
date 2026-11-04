`timescale 1ns/1ps

// Fixed-image integration smoke: five-stage dual-issue RV32IM core through
// the existing full-SoC ROM/cache/MMIO path to GPIO. The fixture computes
// 0x55*0x55/0x55 using M-extension instructions before writing GPIO.
module tb_dual_5stage_full_top_mmio_fixture;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rstn = 1'b0;

    wire [7:0] led;
    wire [31:0] gpio_out;
    wire uart_tx;
    wire trace0_valid, trace0_trap, trace1_valid, trace1_trap;
    wire [31:0] trace0_pc, trace0_instr, trace0_cause;
    wire [31:0] trace1_pc, trace1_instr, trace1_cause;
    wire [63:0] trace0_order, trace1_order;
    wire [31:0] trace0_rd_data, trace1_rd_data;
    wire [4:0] trace0_rd, trace1_rd;
    wire trace0_rd_we, trace1_rd_we;
    wire [31:0] pc_debug;

    integer traps = 0;
    integer mul_retired = 0;
    integer div_retired = 0;
    integer gpio_store_retired = 0;

    always @(posedge clk) begin
        if (rstn) begin
            if (trace0_valid && trace0_trap) traps <= traps + 1;
            if (trace1_valid && trace1_trap) traps <= traps + 1;
            if (trace0_valid && trace0_pc == 32'h8 && trace0_instr == 32'h022101b3)
                mul_retired <= mul_retired + 1;
            if (trace1_valid && trace1_pc == 32'h8 && trace1_instr == 32'h022101b3)
                mul_retired <= mul_retired + 1;
            if (trace0_valid && trace0_pc == 32'hc && trace0_instr == 32'h0221c233)
                div_retired <= div_retired + 1;
            if (trace1_valid && trace1_pc == 32'hc && trace1_instr == 32'h0221c233)
                div_retired <= div_retired + 1;
            if ((trace0_valid && trace0_pc == 32'h10 && trace0_instr == 32'h0040a823) ||
                (trace1_valid && trace1_pc == 32'h10 && trace1_instr == 32'h0040a823))
                gpio_store_retired <= gpio_store_retired + 1;
        end
    end

    pangu100proplus_dual_full_top #(
        .ROM_INIT_FILE("verification/unit/dual_5stage_mmio_fixture.hex"),
        .MEM_DEPTH(256), .MEM_AW(8), .UART_DIV(4), .M_MODE(2),
        .DUAL_ISSUE_EN(1'b1), .ICACHE_ENABLE(1'b1), .DCACHE_ENABLE(1'b1)
    ) dut (
        .clk(clk), .rstn(rstn), .gpio_in(32'd0), .uart_rx(1'b1),
        .led(led), .gpio_out(gpio_out), .uart_tx(uart_tx),
        .trace0_valid(trace0_valid), .trace0_order(trace0_order),
        .trace0_pc(trace0_pc), .trace0_instr(trace0_instr),
        .trace0_rd(trace0_rd), .trace0_rd_data(trace0_rd_data),
        .trace0_rd_we(trace0_rd_we), .trace0_trap(trace0_trap),
        .trace0_cause(trace0_cause),
        .trace1_valid(trace1_valid), .trace1_order(trace1_order),
        .trace1_pc(trace1_pc), .trace1_instr(trace1_instr),
        .trace1_rd(trace1_rd), .trace1_rd_data(trace1_rd_data),
        .trace1_rd_we(trace1_rd_we), .trace1_trap(trace1_trap),
        .trace1_cause(trace1_cause), .pc_debug(pc_debug)
    );

    initial begin
        repeat (8) @(posedge clk);
        rstn = 1'b1;
        repeat (3000) @(posedge clk);
        #1;
        $display("FIXTURE_RESULT: gpio=%08x led=%02x traps=%0d mul=%0d div=%0d sw=%0d pc=%08x",
                 gpio_out, led, traps, mul_retired, div_retired,
                 gpio_store_retired, pc_debug);
        if (gpio_out !== 32'h55 || led !== 8'h55 || traps != 0 ||
            mul_retired != 1 || div_retired != 1 || gpio_store_retired != 1)
            $fatal(1, "five-stage full-SoC RV32IM fixture failed");
        $display("PASS: DUAL_FIVE_STAGE M_MODE=2 RV32IM fixture reached GPIO with zero traps");
        $finish;
    end
endmodule
