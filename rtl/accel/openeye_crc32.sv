// =============================================================================
//  openeye_crc32.sv  —  CRC-32/ISO-HDLC（与 zlib.crc32 / Python 同源）
//
//  参数（与合同 §4 的 0x040 INPUT_CRC32 要求一致）：
//      poly    = 0xEDB88320   （反射形式；正向多项式 0x04C11DB7）
//      init    = 0xFFFFFFFF
//      xorout  = 0xFFFFFFFF
//      refin   = true, refout = true
//
//  与 host 侧的一致性依据：仓库里 tools/kws/compile_openeye.py 的
//      def crc32_ieee(b): return zlib.crc32(b) & 0xFFFFFFFF
//  用的正是这个变体（zlib.crc32 即 CRC-32/ISO-HDLC）。**RTL 必须与之逐位相同**，
//  否则描述符 CRC（描述符 0x70 偏移）与寄存器 0x040 会各算一套。
//
//  算法（反射版，逐字节）：
//      for each byte b:
//          crc ^= b;                     // 只异或低 8 位
//          repeat 8:
//              crc = (crc & 1) ? (crc >> 1) ^ 32'hEDB8_8320 : (crc >> 1);
//      crc ^= 0xFFFFFFFF;                // xorout
//
//  ⚠️ 两个易错点（都已用负控覆盖）：
//   1) **每个字节必须恰好 8 次移位**。只做 7 次会得到一个"看起来像随机数"的结果，
//      且单字节测试向量也可能碰巧过——必须用多长度向量覆盖。
//   2) 本模块**不做** bit reversal。反射语义由"先异或低字节 + 右移"体现，
//      这正是 zlib.crc32 的做法；若额外加反射会与 host 不符。
//
//  结构：bit-serial（8 拍/字节），**不用 256 项查表**。
//     本模型每帧只需算 1960 字节 ⇒ 1960*8 = 15,680 拍，
//     相对 DW 层 320,000 拍约 4.9%，不值得为它引入 8 Kbit 表。
//     将来若需高吞吐，可在保持同一接口的前提下换表版本。
//
//  接口：valid/ready 字节流
//      start        单拍脉冲：装载 INIT，开始一次新 CRC
//      b_valid/b_data/b_ready   逐字节输入
//      finish       单拍：字节流结束（len==0 时也要发），下一拍 result_valid
//      result/result_valid      完成后的最终 CRC（已 xorout），valid 保持一拍
// =============================================================================
`default_nettype none

module openeye_crc32 #(
    parameter [31:0] POLY   = 32'hEDB8_8320,
    parameter [31:0] INIT   = 32'hFFFF_FFFF,
    parameter [31:0] XOROUT = 32'hFFFF_FFFF
)(
    input  wire        clk,
    input  wire        rst,

    input  wire        start,
    input  wire        b_valid,
    output logic       b_ready,
    input  wire [7:0]  b_data,
    input  wire        finish,       // 单拍：字节流结束（len==0 时也要发），下一拍给结果

    output logic [31:0] result,
    output logic        result_valid
);
    localparam [1:0] S_IDLE = 2'd0,
                     S_RUN  = 2'd1,
                     S_DONE = 2'd2;

    reg [1:0]  st;
    reg [31:0] crc;
    reg [2:0]  bitcnt;
    // finish 挂起锁存：允许调用方在字节之间提前一拍发 finish，
    // 模块会在本轮字节处理完（bitcnt 回 0）后立即收尾，而不是把 finish 丢掉。
    reg        fin_pending;

    // 常规一位推进
    wire [31:0] crc_step  = crc[0] ? ((crc >> 1) ^ POLY) : (crc >> 1);
    // 进字节那一拍：先异或低 8 位，再做第 1 次移位（所以每字节合计 8 次）
    wire [31:0] crc_xor_b = crc ^ {24'd0, b_data};
    wire [31:0] crc_step0 = crc_xor_b[0] ? ((crc_xor_b >> 1) ^ POLY) : (crc_xor_b >> 1);

    assign b_ready = (st == S_RUN) && (bitcnt == 3'd0);

    always @(posedge clk) begin
        if (rst) begin
            st           <= S_IDLE;
            crc          <= INIT;
            bitcnt       <= 3'd0;
            fin_pending  <= 1'b0;
            result       <= 32'd0;
            result_valid <= 1'b0;
        end else begin
            result_valid <= 1'b0;
            if (finish && (st == S_RUN)) fin_pending <= 1'b1;
            case (st)
            S_IDLE: begin
                bitcnt      <= 3'd0;
                fin_pending <= 1'b0;
                if (start) begin
                    crc <= INIT;
                    st  <= S_RUN;
                end
            end
            S_RUN: begin
                if (bitcnt == 3'd0) begin
                    if (fin_pending || finish) begin
                        fin_pending <= 1'b0;
                        st <= S_DONE;                    // len==0 也能收尾
                    end else if (b_valid) begin
                        crc    <= crc_step0;             // 异或 + 第 1 次移位
                        bitcnt <= 3'd1;
                    end
                end else begin
                    crc    <= crc_step;                  // 第 2..8 次移位
                    bitcnt <= bitcnt + 3'd1;
                    if (bitcnt == 3'd7) bitcnt <= 3'd0;
                end
            end
            S_DONE: begin
                result       <= crc ^ XOROUT;
                result_valid <= 1'b1;
                st           <= S_IDLE;
            end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
