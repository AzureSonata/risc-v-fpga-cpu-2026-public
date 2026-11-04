// 最小探针：单独验证 addr_decode 是否输出确定值（排除"是它出 x 还是接线出 x"）
`timescale 1ns/1ps
module tb_deq;
    reg  [31:0] a;
    wire s_rom, s_sram, s_uart, s_gpio, s_timer, s_ac, s_ab, s_none, s_cb, s_ro;
    addr_decode u (
        .addr(a),
        .sel_rom(s_rom), .sel_sram(s_sram), .sel_uart(s_uart),
        .sel_gpio(s_gpio), .sel_timer(s_timer),
        .sel_accel_ctrl(s_ac), .sel_accel_buf(s_ab),
        .sel_none(s_none), .cacheable(s_cb), .read_only(s_ro)
    );
    wire cbe = s_rom | s_sram;      // 与 cache_path 喂入的形式一致
    wire cbe2;
    assign cbe2 = s_rom | s_sram;

    initial begin
        a = 32'h0000_0000; #1;
        $display("a=%h rom=%b sram=%b none=%b cb=%b | cbe=%b cbe2=%b", a, s_rom, s_sram, s_none, s_cb, cbe, cbe2);
        a = 32'h8000_0000; #1;
        $display("a=%h rom=%b sram=%b none=%b cb=%b | cbe=%b cbe2=%b", a, s_rom, s_sram, s_none, s_cb, cbe, cbe2);
        $finish;
    end
endmodule
