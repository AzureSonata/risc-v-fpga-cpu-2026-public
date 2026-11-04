// oled_ssd1306_i2c_pads — inout 焊盘包装（A6：帧缓冲写口 + 开漏 SCL/SDA）
//
// A5b 的 pads 包装把 A5b 驱动的文本输入直通到 inout 焊盘；A6 的驱动内容源改为
// 1024 B 帧缓冲写口（见 rtl/periph/oled_ssd1306_i2c.sv 头注释 D1..D3），因此本包装
// 只做「帧缓冲写口 + new_frame → inout 焊盘」的直通，不含任何协议逻辑。
// 开漏语义与 A5b/历史实现一致：scl_low/sda_low=1 拉低，否则释放（模块侧上拉）。
`default_nettype none

module oled_ssd1306_i2c_pads #(
    parameter integer SYS_HZ      = 27_000_000,
    parameter integer I2C_TICK_HZ = 400_000
) (
    input  wire        clk,
    input  wire        resetn,
    input  wire        new_frame,     // 单周期脉冲：整帧刷新（来自 oled_page_ctrl.start_frame）
    input  wire        fb_we,
    input  wire [9:0]  fb_addr,
    input  wire [7:0]  fb_data,
    inout  wire        scl,
    inout  wire        sda,
    output wire        frame_done,
    output wire [31:0] frame_count,
    output wire        busy,
    output wire        error,
    output wire        seen_ack
);
    wire scl_low;
    wire sda_low;

    oled_ssd1306_i2c #(
        .SYS_HZ(SYS_HZ),
        .I2C_TICK_HZ(I2C_TICK_HZ)
    ) u_core (
        .clk(clk),
        .resetn(resetn),
        .new_frame(new_frame),
        .fb_we(fb_we),
        .fb_addr(fb_addr),
        .fb_data(fb_data),
        .scl_low(scl_low),
        .sda_low(sda_low),
        .sda_in(sda),
        .frame_done(frame_done),
        .frame_count(frame_count),
        .busy(busy),
        .error(error),
        .seen_ack(seen_ack)
    );

    assign scl = scl_low ? 1'b0 : 1'bz;
    assign sda = sda_low ? 1'b0 : 1'bz;
endmodule

`default_nettype wire
