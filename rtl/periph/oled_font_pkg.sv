// ============================================================================
//        OLED 字模数据包（A6，自动生成，勿手改）
//        字模来源与分发说明：见 THIRD_PARTY_NOTICES.md
//        字模数据校验信息见发布说明
//        * cjk16_row: 4 字（循/芯/而/行）16x16，每行 16 bit
//        * cjk12_row: 4 字（五/级/流/水）12x12，每行 12 bit
//        * ascii5_row: 常用 ASCII 5x7，每行 5 bit（bit7 恒 0）
//        约定：某行 bit (W-1-x) = 局部列 x 像素；row 从字形顶部起算 y
// ============================================================================
`timescale 1ns/1ps

package oled_font_pkg;

    // 16x16 CJK: 0=循 1=芯 2=而 3=行
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

    // 12x12 CJK: 0=五 1=级 2=流 3=水
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

    // ASCII 5x7 (row 0..6, bit 7 unused; bit (4-x) = pixel column x)
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

endpackage
