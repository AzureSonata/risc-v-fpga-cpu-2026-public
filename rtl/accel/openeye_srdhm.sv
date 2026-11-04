// =============================================================================
//  openeye_srdhm.sv  —  TFLite/gemmlowp 精确 requant 原语
//
//  来源（逐行对齐，不自行发挥）：
//    tools/kws/compile_openeye.py : _gemmlowp_srdhm /
//                                   _gemmlowp_rounding_divide_by_pot / requant_srdhm
//
//  TFLite 的顺序是**三步**，不是"先 SRDHM 再移位"：
//      left  = max(shift, 0);  right = max(-shift, 0)
//      x1 = acc << left
//      x2 = SaturatingRoundingDoublingHighMul(x1, q31_multiplier)   // /2^31 向零截断
//      x3 = RoundingDivideByPOT(x2, right)                          // 四舍五入
//      out = clamp(x3 + out_zp, act_min, act_max)
//
//  ⚠️ 两个坑（见 compile_openeye.py 注释，错则 DW 约 10% 字节不符）：
//    1) SRDHM 的 /2^31 必须**向零截断**，不能用算术右移（算术右移会把负数向下取整）；
//    2) 右移必须**四舍五入**（round half away from zero），不能用截断移位。
//
//  本模块组合实现。acc 取 32 位有符号：本模型最坏 |acc| 见
//  layers.json 的 raw_mac_min/max（FC 最坏 25 位有符号，含折叠 bias）。
// =============================================================================
`default_nettype none

module openeye_srdhm (
    input  wire signed [31:0] acc_i,
    input  wire signed [31:0] mult_i,     // Q31 multiplier（TFLite 存为 int32）
    input  wire signed [31:0] shift_i,    // >0 左移，<0 右移
    input  wire signed [31:0] out_zp_i,
    input  wire signed [31:0] act_min_i,
    input  wire signed [31:0] act_max_i,
    output logic signed [7:0] q_o
);
    // ---------------- 1) 左移 ----------------
    // 本模型 |shift| <= 12（layers.json: shift ∈ [-12,-10]），左移最多 12 位。
    // 用 64 位中间量吸收左移，避免溢出。
    wire signed [63:0] acc64  = {{32{acc_i[31]}}, acc_i};
    wire        [5:0]  left   = (shift_i > 0) ? shift_i[5:0] : 6'd0;
    wire signed [63:0] x1     = acc64 <<< left;

    // ---------------- 2) SRDHM ----------------
    // ⚠️ 坑位（我实测踩到）：96 位乘法的两个操作数**必须显式符号扩展**。
    //   若直接写 `x1 * {{32{mult_i[31]}}, mult_i}`，其中 x1 是 64 位 signed，
    //   综合/仿真会把整个乘法上下文按**无符号**解释（另一个操作数是无符号拼接），
    //   ⇒ x1 被零扩展 ⇒ 负的 acc 变成巨大的正数 ⇒ qtrunc 溢出 ⇒ 恒饱和到 I32_MAX。
    //   故这里先各自扩成 signed 96 位 wire 再相乘。
    wire signed [95:0] x1_96   = {{32{x1[63]}}, x1};
    wire signed [95:0] mult_96 = {{64{mult_i[31]}}, mult_i};
    wire signed [95:0] ab_prod = x1_96 * mult_96;

    // nudge = (ab >= 0) ? 2^30 : 1-2^30
    wire signed [95:0] nudge = (ab_prod >= 0)
                             ? 96'sd1_073_741_824           // 2^30
                             : (96'sd1 - 96'sd1_073_741_824); // 1 - 2^30
    wire signed [95:0] num = ab_prod + nudge;

    // 向零截断除以 2^31：正数右移、负数取反后右移再取反
    wire signed [95:0] absnum = (num >= 0) ? num : -num;
    wire signed [95:0] qtrunc = num[95] ? -(absnum >>> 31) : (absnum >>> 31);

    // 饱和到 int32
    localparam signed [95:0] I32_MAX = 96'sd2_147_483_647;
    localparam signed [95:0] I32_MIN = -96'sd2_147_483_648;
    wire signed [95:0] x2_wide = (qtrunc > I32_MAX) ? I32_MAX
                               : (qtrunc < I32_MIN) ? I32_MIN
                               : qtrunc;
    wire signed [31:0] x2 = x2_wide[31:0];

    // ---------------- 3) RoundingDivideByPOT(右移) ----------------
    wire        [5:0]  right = (shift_i < 0) ? (~shift_i[5:0] + 6'd1) : 6'd0;  // = -shift
    // ⚠️ 坑位（我实测踩到）：mask/remainder **必须是 unsigned**。
    //   若写成 signed：`(32'sd1 << right) - 32'sd1` 在 32 位下得到 32'hFFFF_FFFF
    //   （因为 1<<31 是负数，减 1 仍是 -1），再 `>>> 1` 得 32'hFFFF_FFFF ⇒ -1，
    //   于是 remainder > threshold 恒为假 ⇒ 负数永远不进位 ⇒ 约 3/4 的 DW 输出错。
    wire        [31:0] rem_mask  = (right == 6'd0) ? 32'd0 : ((32'd1 << right) - 32'd1);
    wire        [31:0] remainder = x2 & rem_mask;
    // threshold = (mask >> 1) + (x2 < 0 ? 1 : 0)，同样用无符号比较
    wire        [31:0] threshold = (rem_mask >> 1) + (x2[31] ? 32'd1 : 32'd0);
    wire signed [31:0] x2_shift  = x2 >>> right;
    wire signed [31:0] x3 = x2_shift + ((remainder > threshold) ? 32'sd1 : 32'sd0);

    // ---------------- 4) +out_zp 并 clamp ----------------
    wire signed [32:0] with_zp = {{1{x3[31]}}, x3} + {{1{out_zp_i[31]}}, out_zp_i};
    // ⚠️ 坑位（我实测踩到）：这里**不能**写成
    //      clamped = (with_zp > {{1{act_max[31]}}, act_max}) ? act_max : ...
    //    因为 33 位拼接结果是**无符号**字面量，与 signed 的 with_zp 比较时会被
    //    按无符号解释 ⇒ 负的 with_zp 变成极大值 ⇒ 判成 < act_min ⇒ 恒被夹到 -128。
    //    正确做法：先把上下界各自扩成 signed 33 位 wire（重复符号位），再比较。
    wire signed [32:0] act_max33 = {{1{act_max_i[31]}}, act_max_i};
    wire signed [32:0] act_min33 = {{1{act_min_i[31]}}, act_min_i};
    wire signed [32:0] clamped = (with_zp > act_max33) ? act_max33
                              : (with_zp < act_min33) ? act_min33
                              : with_zp;

    assign q_o = clamped[7:0];
endmodule

`default_nettype wire
