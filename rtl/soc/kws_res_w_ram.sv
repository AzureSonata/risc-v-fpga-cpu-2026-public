// =============================================================================
//  kws_res_w_ram.sv  —  KWS 结果/激活 RAM（1024 字 × 32 位，**1 写 2 读**）
//
//  与 `kws_in_w_ram.sv` 同源、同形态（理由、三条硬约束、字节地址约定见那个文件的头注），
//  差别只有：
//    · 深度 1024 字（4,096 B，与 `RES_BYTES` 一致，正好 2^10 ⇒ 地址是纯切片）；
//    · 两个读口：
//        ra0 = FC 阶段的激活字节读（核按 `vec_idx` 逐字节读上一层 requant 输出）；
//        ra1 = 总线 logit 读（`LOGIT_OFF=4000` 是 4 的倍数 ⇒ 4 个 logit 正好一个字，
//              常量字节地址直读整字，不需要选字节）；
//    · 写数据是**单个 int8**（核只写 1 字节），由 `wbe` 决定落到哪个 lane。
//
//  端口时序：`we/waddr/wbe/wdata/raN` 在 t 拍给，`b0`/`q1` 在 t+1 拍有效（1 拍）。
// =============================================================================
`default_nettype none

module kws_res_w_ram #(
    parameter integer WORDS = 1024,     // 字数（2 的幂 ⇒ 地址是纯切片）
    parameter integer AW    = 10        // log2(WORDS)
)(
    input  wire            clk,

    // ---------------- 唯一写口（字节使能） ----------------
    input  wire            we,
    input  wire [AW-1:0]   waddr,       // 字地址
    input  wire [3:0]      wbe,
    input  wire [7:0]      wdata,       // 核只写 1 个 int8 ⇒ 复制到 4 个 lane，由 wbe 选

    // ---------------- 两个读口（无条件同步读；**字节地址**） ----------------
    input  wire [AW+1:0]   ra0,         // 0：FC 激活字节读
    input  wire [AW+1:0]   ra1,         // 1：logit 整字读（常量字节地址）

    output wire [7:0]      b0,          // ra0 处的字节
    output wire [31:0]     q1           // ra1 处的整字（logit 直接取）
);
    logic [31:0] mem [0:WORDS-1];

    logic [31:0] q0_r, q1_r;
    logic [1:0]  s0_r;

    function automatic [7:0] sel_byte(input [31:0] w, input [1:0] s);
        begin
            case (s)
                2'd0:    sel_byte = w[7:0];
                2'd1:    sel_byte = w[15:8];
                2'd2:    sel_byte = w[23:16];
                default: sel_byte = w[31:24];
            endcase
        end
    endfunction

    wire [31:0] wdata_lane = {4{wdata}};

    always_ff @(posedge clk) begin
        // ---- 唯一写口：同一 word 地址 + 4 个字节使能 ----
        if (we) begin
            if (wbe[0]) mem[waddr][7:0]   <= wdata_lane[7:0];
            if (wbe[1]) mem[waddr][15:8]  <= wdata_lane[15:8];
            if (wbe[2]) mem[waddr][23:16] <= wdata_lane[23:16];
            if (wbe[3]) mem[waddr][31:24] <= wdata_lane[31:24];
        end
        // ---- 两个读口：无条件；字索引与字节选择都来自**字节地址** ----
        q0_r <= mem[ra0[AW+1:2]];
        s0_r <= ra0[1:0];
        q1_r <= mem[ra1[AW+1:2]];
    end

    assign b0 = sel_byte(q0_r, s0_r);
    assign q1 = q1_r;

endmodule

`default_nettype wire
