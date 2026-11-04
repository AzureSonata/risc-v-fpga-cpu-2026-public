// oled_ssd1306_i2c — SSD1306 128x64 OLED I2C 帧驱动（A6：A5b 提取版 + 仅帧内容源适配）
//
// ==== 来源与边界（A6 复审要求：I2C 收发全部由 A5 已验证驱动完成）=================
// Base (byte-for-byte): feat/mrev-oled-extract-20261104 @ 9680775dda11af20bd6665168b73650664aa9f6b
//   rtl/periph/oled_ssd1306_i2c.sv , 17,470 B, sha256
//   4E7E83CA2761CD9071EBD1E24CE476DD747725E2182BECFEDCC960C914D43114
// Pristine copy kept for audit: verification/board/ref/oled_ssd1306_i2c_a5b.sv
// A5b itself is extracted verbatim from the only board-proven implementation:
//   codex/pangu-peripheral-selftest-20261102 (a35390fe) rtl/board/peripheral_selftest_top.sv
//   module oled_i2c_selftest (L268-648), source sha256 38561AF8…1702F.
// Frozen behavioral golden reference: verification/board/ref/oled_i2c_selftest_ref.sv
//
// ==== 本文件对 A5b 的**全部**改动（仅内容来源，不碰 I2C 后端）======================
//   D1 端口：文本输入 peak_display/mic_active/seconds_bcd/fan_on/key_down
//            → 帧缓冲写口 fb_we / fb_addr[9:0] / fb_data[7:0]（1024 B = 8 page × 128 col）；
//   D2 内容：删除 hex_char/display_char/pixel_byte 与 `include "oled_font_5x7.svh"`
//            （文本页渲染器不再使用；三行中文页面由 oled_page_ctrl 渲染进 fb），
//            tx_value 的 data 分支改为 tx_value = fb[page*128 + (idx-2)]；
//   D3 删除随文本内容出现的状态锁存 peak/seconds/fan/key/mic_activity_latched
//            与 displayed_seconds 输出（A6 不再输出“已显示秒数”）。
// 其余全部逐行保留：15 个 PHY 状态、tick 分频（每 bit 4 tick → SCL≈100 kHz）、
//   27 字节 init（0x78,0x00 + 24 条显式命令 + default 0xAF）、每页 5 字节命令
//   (0x78,0x00,0xB0|page,0x00,0x10) + 130 字节数据 (0x78,0x40+128)、8 页、
//   ACK 采样位置、NACK sticky、STOP、帧提交（frame_count/frame_done）、busy。
// 等价证据：verification/board/tb_oled_equiv.sv（A6 vs golden ref，逐字节 diff 0）。
`default_nettype none

module oled_ssd1306_i2c #(
    parameter integer SYS_HZ        = 27_000_000,
    parameter integer I2C_TICK_HZ   = 400_000,
    parameter [7:0]   I2C_ADDR_WRITE = 8'h78, // 7-bit 0x3C shifted left, write bit clear
    parameter integer PAGES         = 8       // GDDRAM pages written per frame
) (
    input  wire        clk,
    input  wire        resetn,        // active-low asynchronous reset
    input  wire        new_frame,     // one-cycle pulse: start a full 8-page refresh
    input  wire        fb_we,         // framebuffer write enable (page*128 + column)
    input  wire [9:0]  fb_addr,       // 0..1023
    input  wire [7:0]  fb_data,       // byte for the addressed page/column
    output wire        scl_low,       // 1 = drive SCL low (open-drain)
    output wire        sda_low,       // 1 = drive SDA low (open-drain)
    input  wire        sda_in,        // SDA pad value, sampled in the ACK slot
    output reg         frame_done,    // one-cycle pulse: frame committed with no NACK
    output reg  [31:0] frame_count,
    output reg         busy,          // transaction engine is not idle
    output reg         error,         // sticky NACK observed
    output reg         seen_ack       // sticky: at least one ACK observed
);
    localparam [4:0] ST_WAIT      = 0;
    localparam [4:0] ST_START_A   = 1;
    localparam [4:0] ST_START_B   = 2;
    localparam [4:0] ST_START_C   = 3;
    localparam [4:0] ST_BIT_LOW   = 4;
    localparam [4:0] ST_BIT_HIGH  = 5;
    localparam [4:0] ST_BIT_HOLD  = 6;
    localparam [4:0] ST_BIT_FALL  = 7;
    localparam [4:0] ST_ACK_LOW   = 8;
    localparam [4:0] ST_ACK_HIGH  = 9;
    localparam [4:0] ST_ACK_HOLD  = 10;
    localparam [4:0] ST_ACK_FALL  = 11;
    localparam [4:0] ST_STOP_LOW  = 12;
    localparam [4:0] ST_STOP_HIGH = 13;
    localparam [4:0] ST_STOP_REL  = 14;

    reg [4:0]  state;
    reg [1:0]  tx_kind;   // 0 = init commands, 1 = page commands, 2 = page data
    reg [2:0]  page_index;
    reg [7:0]  tx_index;
    reg [7:0]  tx_count;
    reg [7:0]  tx_byte;
    reg [2:0]  bit_index;
    reg [31:0] tick_phase;
    reg        refresh_pending;
    reg        scl_low_r;
    reg        sda_low_r;
    reg [7:0]  init_delay;
    reg        ack_sample;

    // ---- D1: 1024 B 帧缓冲（8 page × 128 column）写口；内容由 oled_page_ctrl 渲染 -------
    reg [7:0] fb [0:1023];
    always @(posedge clk) begin
        if (fb_we) fb[fb_addr] <= fb_data;
    end

    wire tick = tick_phase >= SYS_HZ - I2C_TICK_HZ;
    wire [31:0] tick_sum = tick_phase + I2C_TICK_HZ;

    assign scl_low = scl_low_r;
    assign sda_low = sda_low_r;

    function [7:0] command_byte(input [4:0] idx);
        begin
            case (idx)
                0:  command_byte = 8'hAE;
                1:  command_byte = 8'hD5;
                2:  command_byte = 8'h80;
                3:  command_byte = 8'hA8;
                4:  command_byte = 8'h3F;
                5:  command_byte = 8'hD3;
                6:  command_byte = 8'h00;
                7:  command_byte = 8'h40;
                8:  command_byte = 8'h8D;
                9:  command_byte = 8'h14;
                10: command_byte = 8'h20;
                11: command_byte = 8'h02; // SSD1306 page addressing mode
                12: command_byte = 8'hA1;
                13: command_byte = 8'hC8;
                14: command_byte = 8'hDA;
                15: command_byte = 8'h12;
                16: command_byte = 8'h81;
                17: command_byte = 8'h7F;
                18: command_byte = 8'hD9;
                19: command_byte = 8'hF1;
                20: command_byte = 8'hDB;
                21: command_byte = 8'h40;
                22: command_byte = 8'hA4;
                23: command_byte = 8'hA6;
                default: command_byte = 8'hAF;
            endcase
        end
    endfunction

    // ---- D2: data 分支直接读帧缓冲（A5b 此处为 pixel_byte(...) 文本渲染）----------------
    function [7:0] tx_value(input [1:0] kind, input [7:0] idx, input [2:0] page);
        begin
            case (kind)
                0: begin
                    if (idx == 0) tx_value = I2C_ADDR_WRITE;
                    else if (idx == 1) tx_value = 8'h00;
                    else tx_value = command_byte(idx - 2);
                end
                1: begin
                    case (idx)
                        0:tx_value = I2C_ADDR_WRITE;
                        1:tx_value = 8'h00;
                        2:tx_value = 8'hB0 | page;
                        3:tx_value = 8'h00;
                        default:tx_value = 8'h10;
                    endcase
                end
                default: begin
                    if (idx == 0) tx_value = I2C_ADDR_WRITE;
                    else if (idx == 1) tx_value = 8'h40;
                    else tx_value = fb[page * 128 + (idx - 2)];
                end
            endcase
        end
    endfunction

    task start_byte;
        begin
            tx_byte <= tx_value(tx_kind, tx_index, page_index);
            bit_index <= 7;
            state <= ST_BIT_LOW;
        end
    endtask

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            state <= ST_WAIT;
            tx_kind <= 0;
            page_index <= 0;
            tx_index <= 0;
            tx_count <= 27;
            tx_byte <= I2C_ADDR_WRITE;
            bit_index <= 7;
            tick_phase <= 0;
            refresh_pending <= 1'b0;
            scl_low_r <= 0;
            sda_low_r <= 0;
            error <= 0;
            seen_ack <= 0;
            init_delay <= 0;
            ack_sample <= 0;
            frame_done <= 1'b0;
            frame_count <= 0;
            busy <= 1'b0;
        end else begin
            tick_phase <= tick ? tick_sum - SYS_HZ : tick_sum;
            frame_done <= 1'b0;
            busy <= (state != ST_WAIT);
            if (new_frame)
                refresh_pending <= 1'b1;
            if (state == ST_WAIT) begin
                scl_low_r <= 0;
                sda_low_r <= 0;
                if (tx_kind == 0 && init_delay == 0) begin
                    tx_count <= 27;
                    tx_index <= 0;
                    state <= ST_START_A;
                    init_delay <= 1;
                end else if (refresh_pending || new_frame) begin
                    refresh_pending <= 1'b0;
                    tx_kind <= 1;
                    page_index <= 0;
                    tx_count <= 5;
                    tx_index <= 0;
                    state <= ST_START_A;
                end
            end else if (tick) begin
                case (state)
                    ST_START_A: begin scl_low_r<=0; sda_low_r<=0; state<=ST_START_B; end
                    ST_START_B: begin scl_low_r<=0; sda_low_r<=1; state<=ST_START_C; end
                    ST_START_C: begin scl_low_r<=1; sda_low_r<=1; start_byte(); end
                    ST_BIT_LOW: begin
                        scl_low_r<=1;
                        sda_low_r<=!tx_byte[bit_index];
                        state<=ST_BIT_HIGH;
                    end
                    ST_BIT_HIGH: begin scl_low_r<=0; state<=ST_BIT_HOLD; end
                    ST_BIT_HOLD: begin scl_low_r<=0; state<=ST_BIT_FALL; end
                    ST_BIT_FALL: begin
                        scl_low_r<=1;
                        if (bit_index == 0) state<=ST_ACK_LOW;
                        else begin bit_index<=bit_index-1'b1; state<=ST_BIT_LOW; end
                    end
                    ST_ACK_LOW: begin scl_low_r<=1; sda_low_r<=0; state<=ST_ACK_HIGH; end
                    ST_ACK_HIGH: begin scl_low_r<=0; state<=ST_ACK_HOLD; end
                    ST_ACK_HOLD: begin ack_sample<=sda_in; scl_low_r<=0; state<=ST_ACK_FALL; end
                    ST_ACK_FALL: begin
                        scl_low_r<=1;
                        if (ack_sample) error<=1;
                        else seen_ack<=1;
                        if (tx_index + 1'b1 < tx_count) begin
                            tx_index<=tx_index+1'b1;
                            tx_byte<=tx_value(tx_kind, tx_index+1'b1, page_index);
                            bit_index<=7;
                            state<=ST_BIT_LOW;
                        end else state<=ST_STOP_LOW;
                    end
                    ST_STOP_LOW: begin scl_low_r<=1; sda_low_r<=1; state<=ST_STOP_HIGH; end
                    ST_STOP_HIGH: begin scl_low_r<=0; sda_low_r<=1; state<=ST_STOP_REL; end
                    ST_STOP_REL: begin
                        scl_low_r<=0;
                        sda_low_r<=0;
                        if (tx_kind == 0) begin
                            tx_kind<=1;
                            page_index<=0;
                            tx_count<=5;
                            tx_index<=0;
                            state<=ST_START_A;
                        end else if (tx_kind == 1) begin
                            tx_kind<=2;
                            tx_count<=8'd130;
                            tx_index<=0;
                            state<=ST_START_A;
                        end else if (page_index < PAGES - 1) begin
                            page_index<=page_index+1'b1;
                            tx_kind<=1;
                            tx_count<=5;
                            tx_index<=0;
                            state<=ST_START_A;
                        end else begin
                            tx_kind<=1;
                            page_index<=0;
                            state<=ST_WAIT;
                            if (!error) begin
                                frame_count <= frame_count + 1'b1;
                                frame_done <= 1'b1;
                            end
                        end
                    end
                    default: state<=ST_WAIT;
                endcase
            end
        end
    end
endmodule

`default_nettype wire
