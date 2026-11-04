// =============================================================================
//  openeye_dw_conv.sv  —  Depthwise (=Cin 1) 卷积数据通路（单 MAC 串行版）
//
//  逐行对齐 tools/kws/compile_openeye.py : accumulate_conv()
//
//  参考语义（必须完全一致）：
//      xp = 以 in_zp 填充的 (ih+pt+pb) x (iw+pl+pr) 平面，再把 ih x iw 输入贴到 (pt,pl)
//      for c in 0..Cout-1:
//          wc = w_ohwi[c]                        // [kh][kw]，OHWI 布局，Cin=1
//          for dy, dx:
//              acc[c] += xp[dy + sh*oy][dx + sw*ox] * wc[dy][dx]
//          acc[c] += bias_hw[c]                  // ★ bias 在通道内**只加一次**
//
//  ⚠️ 契约 §5.9：**pad 抽头带的是 raw input zero point（in_zp），不是 0**。
//
//  ---- 2026-10-21 变更（K4-GAP-F8 / K4-GAP-03）----
//  1) 存储读口改为「1 拍延迟」语义（同步读 BRAM 可直接接）：
//     地址由状态寄存器组合产生（clk 沿前稳定），返回数据在本模块内寄存一拍再参与 MAC。
//     ⇒ 每通道多 2 拍取数（FILL），MAC 拍数与抽头数严格相等。
//     周期：每通道 = 2(取数) + kh*kw(MAC) + 1(bias) + 1(推进) = kh*kw + 4。
//     本模型 4000 x (80+4) = 336,000 拍/层（组合读版本是 328,000）。
//  2) 累加溢出检测（契约 §10 A11：32-bit signed 精确累加，溢出即 ARITH）：
//     每次 MAC 与 bias 折叠都用 33 位中间量，超出 int32 范围即置 layer_err，
//     立刻停层、不再输出任何结果（不产出半份 logits）。
//
//  权重读口：wk_idx = c*(kh*kw) + dy*kw + dx，即与 OHWI 打包顺序一致。
//  bias 读口：c，在通道内稳定 (kh*kw+4) 拍 ⇒ 同步读 1 拍延迟天然安全。
// =============================================================================
`default_nettype none

module openeye_dw_conv (
    input  wire                    clk,
    input  wire                    rst,

    // ---- 层参数 ----
    input  wire                    start,       // 单拍脉冲
    input  wire [15:0]             ih,
    input  wire [15:0]             iw,
    input  wire [15:0]             oh,
    input  wire [15:0]             ow,
    input  wire [7:0]              kh,
    input  wire [7:0]              kw,
    input  wire [7:0]              sh,
    input  wire [7:0]              sw,
    input  wire [7:0]              pt,
    input  wire [7:0]              pl,
    input  wire [7:0]              cout,
    input  wire signed [31:0]      in_zp,

    // ---- 输入平面（地址组合给出，数据可 1 拍延迟）----
    output logic [15:0]            in_y,
    output logic [15:0]            in_x,
    input  wire signed [7:0]       in_q,

    // ---- 权重 / bias ----
    output logic [15:0]            wk_idx,
    input  wire signed [7:0]       wk_q,
    output logic [7:0]             bias_idx,
    input  wire signed [31:0]      bias_q,

    // ---- 输出：每通道一个 (oy, ox, c) 的累加结果（已含折叠 bias）----
    output logic                   acc_valid,
    output logic [15:0]            acc_oy,
    output logic [15:0]            acc_ox,
    output logic [7:0]             acc_c,
    output logic signed [31:0]     acc_q,
    output logic                   layer_done,
    // 1 = 本层因累加溢出（ARITH）中止：layer_done 仍出一次，但不含结果
    output logic                   layer_err
);
    localparam [2:0] S_IDLE = 3'd0,
                     S_FILL = 3'd1,   // 2 拍：把前两个抽头的返回数据打进寄存器
                     S_MAC  = 3'd2,   // 每拍一次 MAC（用上一拍锁存的数据）
                     S_BIAS = 3'd3,   // 通道末折叠 bias 并输出
                     S_NEXT = 3'd4,   // 推进 (c, oy, ox)
                     S_DONE = 3'd5;

    reg [2:0]  st;
    reg [15:0] oy, ox;
    reg [7:0]  c, dy, dx;
    reg signed [31:0] acc;

    // ---- 取数流水 ----
    reg signed [7:0]  tap_q_r, wk_q_r;

    // ---- 抽头序号：0..taps+1（taps = kh*kw）----
    //   t=0/1 是 FILL；t>=2 时本拍 MAC 的是第 (t-2) 个抽头，
    //   地址仍按当前 (dy,dx) 给出（t>=taps 后冻结地址，不会越界）。
    reg [16:0]  t;
    wire [16:0] taps = {9'd0, kh} * {9'd0, kw};

    // ---- 输入地址（越界 ⇒ 不是有效抽头，用 in_zp 代替）----
    //   iy = dy + sh*oy - pt ;  ix = dx + sw*ox - pl
    wire signed [31:0] iy_s = $signed({16'd0, dy}) + $signed({24'd0, sh}) * $signed({16'd0, oy})
                              - $signed({24'd0, pt});
    wire signed [31:0] ix_s = $signed({16'd0, dx}) + $signed({24'd0, sw}) * $signed({16'd0, ox})
                              - $signed({24'd0, pl});
    wire iy_ok = (iy_s >= 0) && (iy_s < $signed({16'd0, ih}));
    wire ix_ok = (ix_s >= 0) && (ix_s < $signed({16'd0, iw}));

    // 抽头有效掩码必须**跟着地址一起延迟**：存储是 1 拍延迟同步读，
    // 本拍返回的 in_q 对应的是上一拍的地址，所以掩码也要打一拍再对齐。
    reg  tap_ok_d;
    always @(posedge clk) tap_ok_d <= (iy_ok && ix_ok) && (st != S_IDLE);

    // 抽头值：地址越界时用 in_zp 顶替（契约 §5.9）
    wire signed [7:0] tap_q = tap_ok_d ? in_q : in_zp[7:0];

    always @(*) begin
        in_y    = iy_s[15:0];
        in_x    = ix_s[15:0];
        wk_idx  = c * (kh * kw) + dy * kw + dx;   // OHWI 展平
        bias_idx= c;
    end

    // ---- 32 位有符号累加溢出检测（契约 A11）----
    wire signed [32:0] prod33 = $signed({{25{tap_q_r[7]}}, tap_q_r})
                              * $signed({{25{wk_q_r[7]}},  wk_q_r});
    wire signed [32:0] sum33  = $signed({{1{acc[31]}}, acc}) + prod33;
    wire               ovf_mac = (sum33[32] != sum33[31]);

    wire signed [32:0] sum_bias = $signed({{1{acc[31]}}, acc})
                                + $signed({{1{bias_q[31]}}, bias_q});
    wire               ovf_bias = (sum_bias[32] != sum_bias[31]);

    always @(posedge clk) begin
        if (rst) begin
            st         <= S_IDLE;
            oy <= '0; ox <= '0; c <= '0; dy <= '0; dx <= '0;
            acc        <= 32'sd0;
            t          <= 17'd0;
            tap_q_r    <= 8'sd0; wk_q_r <= 8'sd0;
            acc_valid  <= 1'b0;
            acc_oy     <= '0; acc_ox <= '0; acc_c <= '0; acc_q <= 32'sd0;
            layer_done <= 1'b0;
            layer_err  <= 1'b0;
        end else begin
            acc_valid  <= 1'b0;
            layer_done <= 1'b0;
            layer_err  <= 1'b0;
            // 取数流水：地址当拍有效，数据在本沿锁存，下一拍参与 MAC
            tap_q_r <= tap_q;
            wk_q_r  <= wk_q;
            // 抽头索引 (dy,dx) 必须**每拍推进**（FILL 两拍也在推进），
            // 这样「第 t 拍给出的地址 = 第 t 个抽头」，MAC 用的是第 (t-2) 个抽头。
            if ((st == S_FILL || st == S_MAC) && (t < taps)) begin
                if (dx == kw - 8'd1) begin
                    dx <= '0; dy <= dy + 8'd1;
                end else begin
                    dx <= dx + 8'd1;
                end
            end
            case (st)
            S_IDLE: begin
                if (start) begin
                    oy <= '0; ox <= '0; c <= '0; dy <= '0; dx <= '0;
                    acc <= 32'sd0;
                    t   <= 17'd0;
                    st  <= S_FILL;
                end
            end
            S_FILL: begin
                // 2 拍：t=0 给出抽头 0 地址，t=1 给出抽头 1 地址
                if (t == 17'd1) begin
                    t  <= 17'd2;
                    st <= S_MAC;
                end else begin
                    t <= 17'd1;
                end
            end
            S_MAC: begin
                if (ovf_mac) begin
                    layer_done <= 1'b1;
                    layer_err  <= 1'b1;
                    st         <= S_IDLE;
                end else begin
                    acc <= sum33[31:0];
                    if (t == taps + 17'd1) begin
                        st <= S_BIAS;              // 本拍已消耗最后一个抽头
                    end else begin
                        t <= t + 17'd1;
                    end
                end
            end
            S_BIAS: begin
                // 通道末：折叠 bias（只加一次），送出该 (oy,ox,c) 的累加结果
                if (ovf_bias) begin
                    layer_done <= 1'b1;
                    layer_err  <= 1'b1;
                    st         <= S_IDLE;
                end else begin
                    acc_q     <= sum_bias[31:0];
                    acc_valid <= 1'b1;
                    acc_oy    <= oy;
                    acc_ox    <= ox;
                    acc_c     <= c;
                    st        <= S_NEXT;
                end
            end
            S_NEXT: begin
                acc <= 32'sd0;
                t   <= 17'd0;
                dy  <= '0; dx <= '0;
                if (c == cout - 8'd1) begin
                    c <= '0;
                    if (ox == ow - 16'd1) begin
                        ox <= '0;
                        if (oy == oh - 16'd1) begin
                            st <= S_DONE;
                        end else begin
                            oy <= oy + 16'd1;
                            st <= S_FILL;
                        end
                    end else begin
                        ox <= ox + 16'd1;
                        st <= S_FILL;
                    end
                end else begin
                    c  <= c + 8'd1;
                    st <= S_FILL;
                end
            end
            S_DONE: begin
                layer_done <= 1'b1;
                st         <= S_IDLE;
            end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
