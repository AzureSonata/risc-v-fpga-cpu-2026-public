// 最小复现探针：addr_decode 的"外部实例"与 mem_map_adapter 内部实例共存时，
// 外部实例的输出是否变成 x？（定位 (d-2) 隔离 TB 中 sel_cache=x 的引入条件）
`timescale 1ns/1ps
module tb_deq2;
    reg  [31:0] a = 32'h0;
    wire        s_rom, s_sram, s_uart, s_gpio, s_timer, s_ac, s_ab, s_none, s_cb, s_ro;

    // 外部查询实例（与子系统里的 u_decode_q_i 同构）
    addr_decode u_q (
        .addr(a),
        .sel_rom(s_rom), .sel_sram(s_sram), .sel_uart(s_uart),
        .sel_gpio(s_gpio), .sel_timer(s_timer),
        .sel_accel_ctrl(s_ac), .sel_accel_buf(s_ab),
        .sel_none(s_none), .cacheable(s_cb), .read_only(s_ro)
    );

    // adapter（内部有第二份 addr_decode 实例）
    wire        rv, rr, rw, sv, sr, se;
    wire [31:0] ra, rwd, rd;
    wire [3:0]  rs;
    wire        a_rom_rv, a_rom_rr, a_rom_sv, a_rom_sr, a_rom_se;
    wire [31:0] a_rom_a, a_rom_d;
    wire        a_cb, a_ro;
    mem_map_adapter #(.ACCEL_ENABLE(1'b0)) u_adp (
        .clk(1'b0), .rst(1'b1),
        .req_valid(rv), .req_ready(rr), .addr(ra), .write(rw), .wdata(rwd), .wstrb(rs),
        .rsp_valid(sv), .rsp_ready(sr), .rdata(rd), .error(se),
        .cacheable(a_cb), .read_only(a_ro),
        .rom_req_valid(a_rom_rv), .rom_req_ready(a_rom_rr), .rom_addr(a_rom_a),
        .rom_rsp_valid(a_rom_sv), .rom_rsp_ready(a_rom_sr),
        .rom_rdata(a_rom_d), .rom_error(a_rom_se),
        .sram_req_valid(), .sram_req_ready(1'b1), .sram_addr(),
        .sram_write(), .sram_wdata(), .sram_wstrb(),
        .sram_rsp_valid(1'b0), .sram_rsp_ready(), .sram_rdata(32'b0), .sram_error(1'b0),
        .uart_req_valid(), .uart_req_ready(1'b1), .uart_addr(),
        .uart_write(), .uart_wdata(), .uart_wstrb(),
        .uart_rsp_valid(1'b0), .uart_rsp_ready(), .uart_rdata(32'b0), .uart_error(1'b0),
        .gpio_req_valid(), .gpio_req_ready(1'b1), .gpio_addr(),
        .gpio_write(), .gpio_wdata(), .gpio_wstrb(),
        .gpio_rsp_valid(1'b0), .gpio_rsp_ready(), .gpio_rdata(32'b0), .gpio_error(1'b0),
        .timer_req_valid(), .timer_req_ready(1'b1), .timer_addr(),
        .timer_write(), .timer_wdata(), .timer_wstrb(),
        .timer_rsp_valid(1'b0), .timer_rsp_ready(), .timer_rdata(32'b0), .timer_error(1'b0),
        .accel_req_valid(), .accel_req_ready(1'b1), .accel_addr(),
        .accel_write(), .accel_wdata(), .accel_wstrb(),
        .accel_rsp_valid(1'b0), .accel_rsp_ready(), .accel_rdata(32'b0), .accel_error(1'b0)
    );

    initial begin
        a = 32'h0000_0000; #1;
        $display("addr=%h | EXT rom=%b sram=%b none=%b cb=%b | INNER rom=%b sram=%b",
                 a, s_rom, s_sram, s_none, s_cb, u_adp.sel_rom, u_adp.sel_sram);
        a = 32'h8000_0000; #1;
        $display("addr=%h | EXT rom=%b sram=%b none=%b cb=%b | INNER rom=%b sram=%b",
                 a, s_rom, s_sram, s_none, s_cb, u_adp.sel_rom, u_adp.sel_sram);
        $finish;
    end
endmodule
