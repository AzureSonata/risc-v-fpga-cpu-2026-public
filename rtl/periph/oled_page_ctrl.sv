// ============================================================================
//  oled_page_ctrl —— A6 OLED 显示层（128x64 SSD1306，页面合成 + 刷新策略）
//
//  职责（只做显示层，不含 I2C 底层）：
//    1. 把三行页面渲染进 1024 B GDDRAM 帧缓冲：
//         行 1  y=0..15   16x16「循芯而行」4 字，x=32..95（居中）
//         行 2  y=20..31  「RISC-V」(5x7 ASCII, x=13..48) +
//                         「五级流水」(12x12, x=49..96) +
//                         「CPU」(5x7 ASCII, x=97..114)，整体水平居中
//         行 3  y=36..42  状态文本（5x7 ASCII，按字符串宽度居中）
//    2. 刷新策略：只比较“最终显示状态” {bench_mode, bench_running, fan_enable}
//       的变化；变化才整帧重绘并触发一次 8 页写；不变则总线上没有任何活动。
//    3. 非阻塞：渲染 1024 周期 + 底层驱动串行发送；CPU 只看到 busy/状态位。
//       初始化/传输失败只置 oled_ok=0，不触碰风扇、音频与推理路径（本模块
//       没有任何风扇/音频/推理输出端口）。
//
//  状态文本选择：
//    bench_mode=0: fan_enable ? "FAN ON" : "FAN OFF"
//    bench_mode=1: bench_running ? "RUNNING" : "READY"
// ============================================================================
`timescale 1ns/1ps

module oled_page_ctrl
(
    input  wire        clk,
    input  wire        resetn,

    // 显示状态（只读输入，来自 SoC 侧风扇 / 跑分状态）
    input  wire        fan_enable,
    input  wire        bench_mode,
    input  wire        bench_running,

    // 帧缓冲写口 -> oled_ssd1306_i2c
    output reg         fb_we,
    output reg  [9:0]  fb_addr,
    output reg  [7:0]  fb_data,
    output reg         start_frame,
    output wire        busy,
    input  wire        frame_done,
    input  wire        oled_error,

    output reg  [15:0] refresh_count,
    output reg         oled_ok
);

    // Inlined verbatim from oled_font_pkg.sv (A6 asset). Yosys 0.66 has no
    // SystemVerilog package-import support, and this project's synthesis flow is
    // Yosys-netlist -> PDS, so the glyph functions live inside this module.
    // The package file is kept for the iverilog testbench and as the A6 reference.
    function automatic [15:0] cjk16_row(input [1:0] idx, input [3:0] row);
        case (idx)
            0: case (row)
                0: cjk16_row = 16'h103C;
                1: cjk16_row = 16'h17E0;
                2: cjk16_row = 16'h2420;
                3: cjk16_row = 16'h4420;
                4: cjk16_row = 16'h97FE;
                5: cjk16_row = 16'h1420;
                6: cjk16_row = 16'h25FC;
                7: cjk16_row = 16'h6504;
                8: cjk16_row = 16'hA504;
                9: cjk16_row = 16'h25FC;
                10: cjk16_row = 16'h2504;
                11: cjk16_row = 16'h25FC;
                12: cjk16_row = 16'h2904;
                13: cjk16_row = 16'h2904;
                14: cjk16_row = 16'h31FC;
                15: cjk16_row = 16'h2104;
                default: cjk16_row = 16'h0;
            endcase
            1: case (row)
                0: cjk16_row = 16'h0820;
                1: cjk16_row = 16'h0820;
                2: cjk16_row = 16'hFFFE;
                3: cjk16_row = 16'h0820;
                4: cjk16_row = 16'h0820;
                5: cjk16_row = 16'h0200;
                6: cjk16_row = 16'h0100;
                7: cjk16_row = 16'h0080;
                8: cjk16_row = 16'h0408;
                9: cjk16_row = 16'h2404;
                10: cjk16_row = 16'h2402;
                11: cjk16_row = 16'h4402;
                12: cjk16_row = 16'h8410;
                13: cjk16_row = 16'h0410;
                14: cjk16_row = 16'h03F0;
                15: cjk16_row = 16'h0000;
                default: cjk16_row = 16'h0;
            endcase
            2: case (row)
                0: cjk16_row = 16'h7FFC;
                1: cjk16_row = 16'h0100;
                2: cjk16_row = 16'h0100;
                3: cjk16_row = 16'h0200;
                4: cjk16_row = 16'h3FF8;
                5: cjk16_row = 16'h2488;
                6: cjk16_row = 16'h2488;
                7: cjk16_row = 16'h2488;
                8: cjk16_row = 16'h2488;
                9: cjk16_row = 16'h2488;
                10: cjk16_row = 16'h2488;
                11: cjk16_row = 16'h2488;
                12: cjk16_row = 16'h2488;
                13: cjk16_row = 16'h2028;
                14: cjk16_row = 16'h2010;
                15: cjk16_row = 16'h0000;
                default: cjk16_row = 16'h0;
            endcase
            3: case (row)
                0: cjk16_row = 16'h0800;
                1: cjk16_row = 16'h09FC;
                2: cjk16_row = 16'h1000;
                3: cjk16_row = 16'h2000;
                4: cjk16_row = 16'h4800;
                5: cjk16_row = 16'h0800;
                6: cjk16_row = 16'h13FE;
                7: cjk16_row = 16'h3020;
                8: cjk16_row = 16'h5020;
                9: cjk16_row = 16'h9020;
                10: cjk16_row = 16'h1020;
                11: cjk16_row = 16'h1020;
                12: cjk16_row = 16'h1020;
                13: cjk16_row = 16'h1020;
                14: cjk16_row = 16'h10A0;
                15: cjk16_row = 16'h1040;
                default: cjk16_row = 16'h0;
            endcase
            default: cjk16_row = 16'h0;
        endcase
    endfunction
    function automatic [11:0] cjk12_row(input [1:0] idx, input [3:0] row);
        case (idx)
            0: case (row)
                0: cjk12_row = 12'hFFC;
                1: cjk12_row = 12'h080;
                2: cjk12_row = 12'h080;
                3: cjk12_row = 12'h080;
                4: cjk12_row = 12'h7F8;
                5: cjk12_row = 12'h108;
                6: cjk12_row = 12'h108;
                7: cjk12_row = 12'h108;
                8: cjk12_row = 12'h208;
                9: cjk12_row = 12'h208;
                10: cjk12_row = 12'hFFE;
                11: cjk12_row = 12'h000;
                default: cjk12_row = 12'h0;
            endcase
            1: case (row)
                0: cjk12_row = 12'h200;
                1: cjk12_row = 12'h2FC;
                2: cjk12_row = 12'h444;
                3: cjk12_row = 12'h944;
                4: cjk12_row = 12'hE48;
                5: cjk12_row = 12'h24E;
                6: cjk12_row = 12'h442;
                7: cjk12_row = 12'hF62;
                8: cjk12_row = 12'h054;
                9: cjk12_row = 12'h388;
                10: cjk12_row = 12'hC94;
                11: cjk12_row = 12'h122;
                default: cjk12_row = 12'h0;
            endcase
            2: case (row)
                0: cjk12_row = 12'h020;
                1: cjk12_row = 12'h810;
                2: cjk12_row = 12'h5FE;
                3: cjk12_row = 12'h040;
                4: cjk12_row = 12'h084;
                5: cjk12_row = 12'h9FE;
                6: cjk12_row = 12'h402;
                7: cjk12_row = 12'h0A8;
                8: cjk12_row = 12'h0A8;
                9: cjk12_row = 12'h4AA;
                10: cjk12_row = 12'h92A;
                11: cjk12_row = 12'h226;
                default: cjk12_row = 12'h0;
            endcase
            3: case (row)
                0: cjk12_row = 12'h040;
                1: cjk12_row = 12'h040;
                2: cjk12_row = 12'h042;
                3: cjk12_row = 12'h764;
                4: cjk12_row = 12'h168;
                5: cjk12_row = 12'h150;
                6: cjk12_row = 12'h150;
                7: cjk12_row = 12'h248;
                8: cjk12_row = 12'h248;
                9: cjk12_row = 12'h444;
                10: cjk12_row = 12'h842;
                11: cjk12_row = 12'h1C0;
                default: cjk12_row = 12'h0;
            endcase
            default: cjk12_row = 12'h0;
        endcase
    endfunction
    function automatic [4:0] ascii5_row(input [7:0] code, input [2:0] row);
        case ({code, row})
            11'h100: ascii5_row = 5'h00;
            11'h101: ascii5_row = 5'h00;
            11'h102: ascii5_row = 5'h00;
            11'h103: ascii5_row = 5'h00;
            11'h104: ascii5_row = 5'h00;
            11'h105: ascii5_row = 5'h00;
            11'h106: ascii5_row = 5'h00;
            11'h168: ascii5_row = 5'h00;
            11'h169: ascii5_row = 5'h00;
            11'h16A: ascii5_row = 5'h1F;
            11'h16B: ascii5_row = 5'h00;
            11'h16C: ascii5_row = 5'h00;
            11'h16D: ascii5_row = 5'h00;
            11'h16E: ascii5_row = 5'h00;
            11'h208: ascii5_row = 5'h0E;
            11'h209: ascii5_row = 5'h11;
            11'h20A: ascii5_row = 5'h11;
            11'h20B: ascii5_row = 5'h1F;
            11'h20C: ascii5_row = 5'h11;
            11'h20D: ascii5_row = 5'h11;
            11'h20E: ascii5_row = 5'h11;
            11'h218: ascii5_row = 5'h0E;
            11'h219: ascii5_row = 5'h11;
            11'h21A: ascii5_row = 5'h10;
            11'h21B: ascii5_row = 5'h10;
            11'h21C: ascii5_row = 5'h10;
            11'h21D: ascii5_row = 5'h11;
            11'h21E: ascii5_row = 5'h0E;
            11'h220: ascii5_row = 5'h1E;
            11'h221: ascii5_row = 5'h11;
            11'h222: ascii5_row = 5'h11;
            11'h223: ascii5_row = 5'h11;
            11'h224: ascii5_row = 5'h11;
            11'h225: ascii5_row = 5'h11;
            11'h226: ascii5_row = 5'h1E;
            11'h228: ascii5_row = 5'h1F;
            11'h229: ascii5_row = 5'h10;
            11'h22A: ascii5_row = 5'h10;
            11'h22B: ascii5_row = 5'h1E;
            11'h22C: ascii5_row = 5'h10;
            11'h22D: ascii5_row = 5'h10;
            11'h22E: ascii5_row = 5'h1F;
            11'h230: ascii5_row = 5'h1F;
            11'h231: ascii5_row = 5'h10;
            11'h232: ascii5_row = 5'h10;
            11'h233: ascii5_row = 5'h1E;
            11'h234: ascii5_row = 5'h10;
            11'h235: ascii5_row = 5'h10;
            11'h236: ascii5_row = 5'h10;
            11'h238: ascii5_row = 5'h0E;
            11'h239: ascii5_row = 5'h11;
            11'h23A: ascii5_row = 5'h10;
            11'h23B: ascii5_row = 5'h17;
            11'h23C: ascii5_row = 5'h11;
            11'h23D: ascii5_row = 5'h11;
            11'h23E: ascii5_row = 5'h0F;
            11'h248: ascii5_row = 5'h0E;
            11'h249: ascii5_row = 5'h04;
            11'h24A: ascii5_row = 5'h04;
            11'h24B: ascii5_row = 5'h04;
            11'h24C: ascii5_row = 5'h04;
            11'h24D: ascii5_row = 5'h04;
            11'h24E: ascii5_row = 5'h0E;
            11'h270: ascii5_row = 5'h11;
            11'h271: ascii5_row = 5'h19;
            11'h272: ascii5_row = 5'h19;
            11'h273: ascii5_row = 5'h15;
            11'h274: ascii5_row = 5'h13;
            11'h275: ascii5_row = 5'h13;
            11'h276: ascii5_row = 5'h11;
            11'h278: ascii5_row = 5'h0E;
            11'h279: ascii5_row = 5'h11;
            11'h27A: ascii5_row = 5'h11;
            11'h27B: ascii5_row = 5'h11;
            11'h27C: ascii5_row = 5'h11;
            11'h27D: ascii5_row = 5'h11;
            11'h27E: ascii5_row = 5'h0E;
            11'h280: ascii5_row = 5'h1E;
            11'h281: ascii5_row = 5'h11;
            11'h282: ascii5_row = 5'h11;
            11'h283: ascii5_row = 5'h1E;
            11'h284: ascii5_row = 5'h10;
            11'h285: ascii5_row = 5'h10;
            11'h286: ascii5_row = 5'h10;
            11'h290: ascii5_row = 5'h1E;
            11'h291: ascii5_row = 5'h11;
            11'h292: ascii5_row = 5'h11;
            11'h293: ascii5_row = 5'h1E;
            11'h294: ascii5_row = 5'h14;
            11'h295: ascii5_row = 5'h12;
            11'h296: ascii5_row = 5'h11;
            11'h298: ascii5_row = 5'h0F;
            11'h299: ascii5_row = 5'h10;
            11'h29A: ascii5_row = 5'h10;
            11'h29B: ascii5_row = 5'h0E;
            11'h29C: ascii5_row = 5'h01;
            11'h29D: ascii5_row = 5'h01;
            11'h29E: ascii5_row = 5'h1E;
            11'h2A8: ascii5_row = 5'h11;
            11'h2A9: ascii5_row = 5'h11;
            11'h2AA: ascii5_row = 5'h11;
            11'h2AB: ascii5_row = 5'h11;
            11'h2AC: ascii5_row = 5'h11;
            11'h2AD: ascii5_row = 5'h11;
            11'h2AE: ascii5_row = 5'h0E;
            11'h2B0: ascii5_row = 5'h11;
            11'h2B1: ascii5_row = 5'h11;
            11'h2B2: ascii5_row = 5'h11;
            11'h2B3: ascii5_row = 5'h11;
            11'h2B4: ascii5_row = 5'h11;
            11'h2B5: ascii5_row = 5'h0A;
            11'h2B6: ascii5_row = 5'h04;
            11'h2C8: ascii5_row = 5'h11;
            11'h2C9: ascii5_row = 5'h11;
            11'h2CA: ascii5_row = 5'h11;
            11'h2CB: ascii5_row = 5'h0A;
            11'h2CC: ascii5_row = 5'h04;
            11'h2CD: ascii5_row = 5'h04;
            11'h2CE: ascii5_row = 5'h04;
            default: ascii5_row = 5'h00;
        endcase
    endfunction

    // ---------------------------------------------------------------- layout
    localparam integer ROW1_Y0 = 0;    // 16x16
    localparam integer ROW1_X0 = 32;
    localparam integer ROW2_Y0 = 20;   // 12x12 / 5x7 混排
    localparam integer ROW2_X0 = 13;
    localparam integer ROW2_CJK_X0 = 49;
    localparam integer ROW2_CPU_X0 = 97;
    localparam integer ROW3_Y0 = 36;   // 5x7
    localparam integer ASC_ADV = 6;    // 5 px 字形 + 1 px 字间距

    // 状态文本选择（最终显示状态，唯一刷新依据）
    wire [1:0] want_sel = bench_mode ? (bench_running ? 2'd3 : 2'd2)
                                     : (fan_enable    ? 2'd1 : 2'd0);

    function [3:0] status_len(input [1:0] sel);
        case (sel)
            2'd0:    status_len = 4'd7;  // FAN OFF
            2'd1:    status_len = 4'd6;  // FAN ON
            2'd2:    status_len = 4'd5;  // READY
            default: status_len = 4'd7;  // RUNNING
        endcase
    endfunction

    function [6:0] status_x0(input [1:0] sel);
        case (sel)
            2'd0:    status_x0 = 7'd43;  // 7 chars -> 41 px
            2'd1:    status_x0 = 7'd46;  // 6 chars -> 35 px
            2'd2:    status_x0 = 7'd49;  // 5 chars -> 29 px
            default: status_x0 = 7'd43;  // 7 chars -> 41 px
        endcase
    endfunction

    function [7:0] status_char(input [1:0] sel, input [3:0] ci);
        begin
            status_char = 8'h20;
            case (sel)
                2'd0: case (ci)          // "FAN OFF"
                    4'd0: status_char = "F"; 4'd1: status_char = "A";
                    4'd2: status_char = "N"; 4'd3: status_char = " ";
                    4'd4: status_char = "O"; 4'd5: status_char = "F";
                    4'd6: status_char = "F";
                    default: status_char = 8'h20;
                endcase
                2'd1: case (ci)          // "FAN ON"
                    4'd0: status_char = "F"; 4'd1: status_char = "A";
                    4'd2: status_char = "N"; 4'd3: status_char = " ";
                    4'd4: status_char = "O"; 4'd5: status_char = "N";
                    default: status_char = 8'h20;
                endcase
                2'd2: case (ci)          // "READY"
                    4'd0: status_char = "R"; 4'd1: status_char = "E";
                    4'd2: status_char = "A"; 4'd3: status_char = "D";
                    4'd4: status_char = "Y";
                    default: status_char = 8'h20;
                endcase
                default: case (ci)       // "RUNNING"
                    4'd0: status_char = "R"; 4'd1: status_char = "U";
                    4'd2: status_char = "N"; 4'd3: status_char = "N";
                    4'd4: status_char = "I"; 4'd5: status_char = "N";
                    4'd6: status_char = "G";
                    default: status_char = 8'h20;
                endcase
            endcase
        end
    endfunction

    // 「RISC-V」6 个字符 / 「CPU」3 个字符
    function [7:0] riscv_char(input [2:0] ci);
        case (ci)
            3'd0: riscv_char = "R"; 3'd1: riscv_char = "I";
            3'd2: riscv_char = "S"; 3'd3: riscv_char = "C";
            3'd4: riscv_char = "-"; default: riscv_char = "V";
        endcase
    endfunction

    function [7:0] cpu_char(input [1:0] ci);
        case (ci)
            2'd0: cpu_char = "C"; 2'd1: cpu_char = "P"; default: cpu_char = "U";
        endcase
    endfunction

    // 单像素：(x, y) 是否点亮（y 从屏幕顶部 0 起算，0..63）
    // ---------------------------------------------------------------
    // Constant-divide helpers (PDS 2022.2 cannot map Yosys'
    // bmsSIGNDIV/bmsSMOD cells for the variable /6 and /12 in pix()).
    // dx is always a small non-negative offset here, so a static
    // compare chain is an exact replacement for / and %.
    // ---------------------------------------------------------------
    function integer div_by_6(input integer v);
        integer i;
        begin
            div_by_6 = 0;
            for (i = 0; i < 16; i = i + 1)
                if (v >= (i + 1) * 6) div_by_6 = i + 1;
        end
    endfunction

    function integer div_by_12(input integer v);
        integer i;
        begin
            div_by_12 = 0;
            for (i = 0; i < 8; i = i + 1)
                if (v >= (i + 1) * 12) div_by_12 = i + 1;
        end
    endfunction

    function [7:0] pix(input [6:0] x, input [5:0] y);
        integer dx;
        integer ci;
        integer ox;
        reg [15:0] r16;
        reg [11:0] r12;
        reg [4:0]  r5;
        reg [7:0]  ch;
        reg [7:0]  sel;
        begin
            pix = 1'b0;
            if ((y < 6'd16) && (x >= ROW1_X0) && (x < (ROW1_X0 + 64))) begin
                dx = x - ROW1_X0;
                ci = dx >> 4;
                ox = dx & 15;
                r16 = cjk16_row(ci[1:0], y[3:0]);
                pix = r16[15 - ox];
            end else if ((y >= ROW2_Y0) && (y < (ROW2_Y0 + 12)) &&
                         (x >= ROW2_X0) && (x < (ROW2_CPU_X0 + 18))) begin
                if (x < ROW2_CJK_X0) begin              // "RISC-V"
                    dx = x - ROW2_X0;
                    if (dx < 0) dx = 0;
                    ci = div_by_6(dx);
                    ox = dx - ((ci << 2) + (ci << 1));
                    if ((ox < 5) && (y >= 22) && (y < 29)) begin
                        ch  = riscv_char(ci[2:0]);
                        r5  = ascii5_row(ch, y[2:0] - 3'd6); // y-22 -> (y[2:0]-6)
                        pix = r5[4 - ox];
                    end
                end else if (x < ROW2_CPU_X0) begin     // 五级流水
                    dx  = x - ROW2_CJK_X0;
                    if (dx < 0) dx = 0;
                    ci  = div_by_12(dx);
                    ox  = dx - ((ci << 3) + (ci << 2));
                    r12 = cjk12_row(ci[1:0], (y - ROW2_Y0));
                    pix = r12[11 - ox];
                end else begin                          // "CPU"
                    dx = x - ROW2_CPU_X0;
                    if (dx < 0) dx = 0;
                    ci = div_by_6(dx);
                    ox = dx - ((ci << 2) + (ci << 1));
                    if ((ox < 5) && (y >= 22) && (y < 29)) begin
                        ch  = cpu_char(ci[1:0]);
                        r5  = ascii5_row(ch, y[2:0] - 3'd6);
                        pix = r5[4 - ox];
                    end
                end
            end else if ((y >= ROW3_Y0) && (y < (ROW3_Y0 + 7))) begin
                dx = x - status_x0(want_sel);
                // keep the signed guard: negative dx falls through the
                // (dx >= 0) check below, exactly like the original / and %.
                ci = div_by_6(dx);
                ox = dx - ((ci << 2) + (ci << 1));
                if ((dx >= 0) && (ci < status_len(want_sel)) && (ox < 5)) begin
                    ch  = status_char(want_sel, ci[3:0]);
                    r5  = ascii5_row(ch, y[2:0] - 3'd4); // y-36
                    pix = r5[4 - ox];
                end
            end
        end
    endfunction

    // 一个 GDDRAM 字节：页 p 列 c，byte bit b = 像素 (c, p*8+b)
    function [7:0] render_byte(input [9:0] addr);
        integer b;
        reg [7:0] acc;
        begin
            acc = 8'h00;
            for (b = 0; b < 8; b = b + 1) begin
                if (pix(addr[6:0], {addr[9:7], b[2:0]}))
                    acc[b] = 1'b1;
            end
            render_byte = acc;
        end
    endfunction

    // ---------------------------------------------------------------- FSM
    localparam [1:0] S_IDLE     = 2'd0;
    localparam [1:0] S_RENDER   = 2'd1;
    localparam [1:0] S_START    = 2'd2;
    localparam [1:0] S_WAIT     = 2'd3;

    reg [1:0]  st;
    reg [10:0] rcnt;
    reg [1:0]  shown;          // 已完成刷新的状态
    reg        shown_valid;
    reg [1:0]  render_sel;
    reg [23:0] wait_cnt;

    wire need_render = (!shown_valid) || (want_sel != shown);

    assign busy = (st != S_IDLE);

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            st            <= S_IDLE;
            rcnt          <= 11'd0;
            shown         <= 2'd0;
            shown_valid   <= 1'b0;
            render_sel    <= 2'd0;
            wait_cnt      <= 24'd0;
            refresh_count <= 16'd0;
            oled_ok       <= 1'b1;
            fb_we         <= 1'b0;
            fb_addr       <= 10'd0;
            fb_data       <= 8'h00;
            start_frame   <= 1'b0;
        end else begin
            start_frame <= 1'b0;
            fb_we       <= 1'b0;

            case (st)
                S_IDLE: begin
                    if (oled_error && oled_ok) begin
                        oled_ok <= 1'b0;   // 初始化/传输失败：停止刷新，不影响其它路径
                    end else if (need_render && !oled_error) begin
                        render_sel <= want_sel;
                        rcnt       <= 11'd0;
                        st         <= S_RENDER;
                    end
                end

                S_RENDER: begin
                    fb_we   <= 1'b1;
                    fb_addr <= rcnt[9:0];
                    fb_data <= render_byte(rcnt[9:0]);
                    if (rcnt == 11'd1023) begin
                        st <= S_START;
                    end else begin
                        rcnt <= rcnt + 11'd1;
                    end
                end

                S_START: begin
                    start_frame <= 1'b1;   // 一帧 8 页写（含 25 条 init 后仅发一次）
                    wait_cnt    <= 24'd0;
                    st          <= S_WAIT;
                end

                S_WAIT: begin
                    wait_cnt <= wait_cnt + 24'd1;
                    if (frame_done) begin
                        shown       <= render_sel;
                        shown_valid <= 1'b1;
                        refresh_count <= refresh_count + 16'd1;
                        st          <= S_IDLE;
                    end else if (wait_cnt == 24'hFF_FFFF || oled_error) begin
                        oled_ok <= 1'b0;   // 超时或 NACK：不再刷新
                        st      <= S_IDLE;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
