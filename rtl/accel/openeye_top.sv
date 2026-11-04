// =============================================================================
//  openeye_top.sv  —  OpenEye 加速器顶层（K4 计算核心）
//
//  范围声明（重要）：本模块**只含计算核心**，不含 MMIO/控制窗/buffer 窗。
//    接口（`accel_*` 端口、0x4000_0000 / 0x4000_1000 的 ABI）按分工由康文签署；
//    本模块把「层描述符」作为离散端口输入，方便在任何 ABI 下定稿。
//
//  数据来源（四个外部存储，均由调用方提供；**全部按「1 拍延迟同步读」设计**）：
//    · 输入平面 / 输入向量 RAM
//    · 权重 ROM（DW: OHWI 展平；FC: output-major 展平）
//    · bias ROM（int32，按通道；**平表**：[DW 0..cout-1][FC cout..cout+nout-1]）
//    · quant ROM（int32：{q31_multiplier, shift} 交错，per-channel；
//      布局与 bias 一致：DW 用 c，FC 用 cout+o）
//
//  一层流程：
//    START → 计算核心逐 (oy,ox,c) 或 (o,k) 累加 → 每个结果做 requant → 写结果 RAM
//  本模块顺序执行「DW 层 → FC 层」，与 layers.json 的 layer1 → layer2 一致。
//
//  ---- 2026-10-21 变更（F6 / F7 / F8，均为「零端口变更」实现）----
//  F8 存储读口：四个读口全部改为「地址当拍给、数据 1 拍后到」。
//     · DW/FC 内部各有 2 拍取数流水（见各子模块）；
//     · requant 改为两级：第 1 级锁存 acc/地址/quant 索引，第 2 级用 ROM 返回的
//       mult/shift 做 SRDHM 并写结果 ⇒ quant ROM 也可以是同步读。
//     · 周期数因此由 344,016 变为 352,012（+2.3 %），见 rtl/accel/README.md §2.2。
//  F7 层间结果同址：结果写口加**层偏移**。DW 写 [0, oh*ow*cout)，FC 从
//     `fc_res_base = oh*ow*cout` 起写 ⇒ 两层不再互相覆盖，一帧结果落在连续窗口内。
//  F6 错误路径：`error`/`error_code` 真实现，错误码沿用 RFC-KWS-MMIO-ABI §3 枚举
//     （不新增值）：1 OP（层参数非法）、2 BUFFER（几何/窗口越界）、4 ARITH（累加溢出）。
//     出错时不置 done、不再写任何结果（不产出半份 logits），
//     error/error_code 保持到下一次 start 被接受（与 STATUS.error-sticky 对齐）。
// =============================================================================
`default_nettype none

module openeye_top (
    input  wire                clk,
    input  wire                rst,

    // ---- 启动与状态 ----
    input  wire                start,
    output logic               busy,
    output logic               done,
    // 错误路径（F6）：error 为 sticky，直到下一次 start 被接受或复位
    output logic               error,
    output logic [7:0]         error_code,   // 见下方 E_* 编码（= RFC §3 枚举）

    // ---- 层参数（DW）----
    input  wire [15:0]         dw_ih,
    input  wire [15:0]         dw_iw,
    input  wire [15:0]         dw_oh,
    input  wire [15:0]         dw_ow,
    input  wire [7:0]          dw_kh,
    input  wire [7:0]          dw_kw,
    input  wire [7:0]          dw_sh,
    input  wire [7:0]          dw_sw,
    input  wire [7:0]          dw_pt,
    input  wire [7:0]          dw_pl,
    input  wire [7:0]          dw_cout,
    input  wire signed [31:0]  in_zp,
    input  wire signed [31:0]  dw_out_zp,

    // ---- 层参数（FC）----
    input  wire [15:0]         fc_nin,
    input  wire [15:0]         fc_nout,
    input  wire signed [31:0]  fc_out_zp,

    // ---- 激活裁剪（int8）----
    input  wire signed [31:0]  act_min,
    input  wire signed [31:0]  act_max,

    // ---- 输入 RAM（DW 用平面 / FC 用向量）----
    output logic [15:0]        in_y,
    output logic [15:0]        in_x,
    output logic [15:0]        vec_idx,
    input  wire signed [7:0]   in_q,

    // ---- 权重 ROM ----
    output logic [15:0]        dw_w_idx,
    output logic [31:0]        fc_w_idx,
    input  wire signed [7:0]   w_q,

    // ---- bias ROM（平表：DW 0..cout-1，FC cout..cout+nout-1）----
    output logic [15:0]        bias_idx,
    input  wire signed [31:0]  bias_q,

    // ---- quant ROM：{mult, shift} 交错，按 per-channel 索引 ----
    //   dw 通道 c 用 [c]，fc 输出 o 用 [dw_cout + o]（与 bias 平表一致）
    output logic [15:0]        quant_idx,
    input  wire signed [31:0]  quant_mult,
    input  wire signed [31:0]  quant_shift,

    // ---- 结果写口（DW 写 [0, oh*ow*cout)；FC 写 [oh*ow*cout, +nout)）----
    output logic               res_we,
    output logic [15:0]        res_addr,
    output logic signed [7:0]  res_data
);
    // ------------------------------------------------------------- 层调度
    localparam [2:0] L_IDLE = 3'd0, L_DW = 3'd1, L_FC = 3'd2,
                     L_DONE = 3'd3, L_ERR = 3'd4;
    reg [2:0] layer_st;

    // 错误码：严格沿用 docs/architecture/RFC-KWS-MMIO-ABI.md §3 的枚举，不新增值
    localparam [7:0] E_NONE   = 8'd0,
                     E_OP     = 8'd1,   // 不支持的算子/层参数（0 维、0 步长…）
                     E_BUFFER = 8'd2,   // buffer/几何越界（核+步长+pad 超出平面；窗口溢出）
                     E_ARITH  = 8'd4;   // 累加/范围检查失败（32 位溢出）

    reg [7:0] err_code_r;

    // ---- DW 子模块 ----
    wire                 dw_acc_valid;
    wire [15:0]          dw_acc_oy, dw_acc_ox;
    wire [7:0]           dw_acc_c;
    wire signed [31:0]   dw_acc_q;
    wire                 dw_layer_done, dw_layer_err;
    wire [7:0]           dw_bias_idx;

    // ---- FC 子模块 ----
    wire                 fc_acc_valid;
    wire [15:0]          fc_acc_o;
    wire signed [31:0]   fc_acc_q;
    wire                 fc_layer_done, fc_layer_err;
    wire [15:0]          fc_bias_idx;

    reg dw_start_r, fc_start_r;

    openeye_dw_conv u_dw (
        .clk(clk), .rst(rst),
        .start(dw_start_r),
        .ih(dw_ih), .iw(dw_iw), .oh(dw_oh), .ow(dw_ow),
        .kh(dw_kh), .kw(dw_kw), .sh(dw_sh), .sw(dw_sw),
        .pt(dw_pt), .pl(dw_pl), .cout(dw_cout), .in_zp(in_zp),
        .in_y(in_y), .in_x(in_x), .in_q(in_q),
        .wk_idx(dw_w_idx), .wk_q(w_q),
        .bias_idx(dw_bias_idx), .bias_q(bias_q),
        .acc_valid(dw_acc_valid), .acc_oy(dw_acc_oy), .acc_ox(dw_acc_ox),
        .acc_c(dw_acc_c), .acc_q(dw_acc_q), .layer_done(dw_layer_done),
        .layer_err(dw_layer_err)
    );

    openeye_fc u_fc (
        .clk(clk), .rst(rst),
        .start(fc_start_r),
        .nin(fc_nin), .nout(fc_nout),
        .in_idx(vec_idx), .in_q(in_q),
        .w_idx(fc_w_idx), .w_q(w_q),
        .bias_idx(fc_bias_idx), .bias_q(bias_q),
        .acc_valid(fc_acc_valid), .acc_o(fc_acc_o),
        .acc_q(fc_acc_q), .layer_done(fc_layer_done),
        .layer_err(fc_layer_err)
    );

    // ------------------------------------------------------------- 层参数合法性
    wire cfg_bad = (dw_ih   == 16'd0) || (dw_iw == 16'd0) ||
                   (dw_oh   == 16'd0) || (dw_ow == 16'd0) ||
                   (dw_kh   ==  8'd0) || (dw_kw ==  8'd0) ||
                   (dw_sh   ==  8'd0) || (dw_sw ==  8'd0) ||
                   (dw_cout ==  8'd0) ||
                   (fc_nin  == 16'd0) || (fc_nout == 16'd0);

    // 几何一致性（K4-GAP-02）：
    //   SAME 语义下 总 pad = (oh-1)*sh + kh - ih，且 pt/pb、pl/pr 都必须落在 [0, kh) / [0, kw)。
    //   注意：抽头超出输入平面**不是错误**——那是 pad 抽头（用 in_zp 顶替）；
    //   真正的错误是 pad 与 (oh, ih, kh, sh) 互相矛盾（例如 pb >= kh，说明输出尺寸算错了）。
    wire signed [31:0] tot_pady = ($signed({16'd0, dw_oh}) - 32'sd1) * $signed({16'd0, dw_sh})
                                + $signed({16'd0, dw_kh}) - $signed({16'd0, dw_ih});
    wire signed [31:0] tot_padx = ($signed({16'd0, dw_ow}) - 32'sd1) * $signed({16'd0, dw_sw})
                                + $signed({16'd0, dw_kw}) - $signed({16'd0, dw_iw});
    wire signed [31:0] pad_b = tot_pady - $signed({24'd0, dw_pt});
    wire signed [31:0] pad_r = tot_padx - $signed({24'd0, dw_pl});

    // DW 结果元素数（= FC 输入向量长度 = FC 结果基址）
    wire [39:0] dw_bytes = {24'd0, dw_oh} * {24'd0, dw_ow} * {32'd0, dw_cout};

    wire geo_bad  = (tot_pady < 0) || (tot_padx < 0) ||
                    (pad_b < 0) || (pad_b >= $signed({24'd0, dw_kh})) ||
                    (pad_r < 0) || (pad_r >= $signed({24'd0, dw_kw})) ||
                    ({24'd0, fc_nin} != dw_bytes);      // FC 输入长度必须 = DW 输出元素数

    // 结果窗口：DW 结果 + FC 结果必须落在 16 位地址窗口内
    wire win_bad  = (dw_bytes + {32'd0, fc_nout}) > 40'd65536;

    // ------------------------------------------------------------- 读口选择
    //  bias 平表：[DW 0..cout-1][FC cout..cout+nout-1]
    always @(*) begin
        if (layer_st == L_FC) bias_idx = dw_cout + fc_bias_idx[7:0];
        else                  bias_idx = {8'd0, dw_bias_idx};
    end

    // ------------------------------------------------------------- 结果地址（F7 层偏移）
    //   DW: addr = (oy*ow + ox)*cout + c
    //   FC: addr = oh*ow*cout + o        <-- 层偏移，不再覆盖 DW 前 4 字节
    wire [31:0] dw_addr32 = ({16'd0, dw_acc_oy} * {16'd0, dw_ow} + {16'd0, dw_acc_ox})
                          * {24'd0, dw_cout} + {24'd0, dw_acc_c};
    wire [15:0] fc_res_base = dw_bytes[15:0];

    wire [15:0] cur_addr = (layer_st == L_FC) ? (fc_res_base + fc_acc_o) : dw_addr32[15:0];
    wire [15:0] cur_qidx = (layer_st == L_FC) ? (dw_cout + fc_acc_o[7:0]) : {8'd0, dw_acc_c};

    wire signed [31:0] sel_acc = (layer_st == L_FC) ? fc_acc_q : dw_acc_q;
    wire signed [31:0] sel_zp  = (layer_st == L_FC) ? fc_out_zp : dw_out_zp;
    wire               sel_val = (layer_st == L_FC) ? fc_acc_valid : dw_acc_valid;

    // ------------------------------------------------------------- requant（两级）
    //  第 1 级：锁存累加值/地址/quant 索引（quant 地址因此提前 1 拍给出）
    //  第 2 级：用 ROM 返回的 mult/shift 做 SRDHM 并写结果
    reg               rq1_valid, rq2_valid;
    reg signed [31:0] rq1_acc, rq1_zp;
    reg [15:0]        rq1_qidx, rq1_addr;

    always @(posedge clk) begin
        if (rst) begin
            rq1_valid <= 1'b0;
            rq2_valid <= 1'b0;
            rq1_acc   <= 32'sd0;
            rq1_zp    <= 32'sd0;
            rq1_qidx  <= 16'd0;
            rq1_addr  <= 16'd0;
        end else begin
            rq1_valid <= sel_val;
            rq2_valid <= rq1_valid;
            if (sel_val) begin
                rq1_acc  <= sel_acc;
                rq1_zp   <= sel_zp;
                rq1_qidx <= cur_qidx;
                rq1_addr <= cur_addr;
            end
        end
    end

    always @(*) quant_idx = rq1_valid ? rq1_qidx : cur_qidx;

    wire signed [7:0] q_out;

    openeye_srdhm u_srdhm (
        .acc_i(rq1_acc), .mult_i(quant_mult), .shift_i(quant_shift),
        .out_zp_i(rq1_zp), .act_min_i(act_min), .act_max_i(act_max),
        .q_o(q_out)
    );

    always @(*) begin
        res_we   = rq2_valid;
        res_addr = rq1_addr;
        res_data = q_out;
    end

    // ------------------------------------------------------------- 主状态机
    always @(posedge clk) begin
        if (rst) begin
            layer_st   <= L_IDLE;
            dw_start_r <= 1'b0;
            fc_start_r <= 1'b0;
            busy       <= 1'b0;
            done       <= 1'b0;
            error      <= 1'b0;
            error_code <= E_NONE;
            err_code_r <= E_NONE;
        end else begin
            dw_start_r <= 1'b0;
            fc_start_r <= 1'b0;
            done       <= 1'b0;
            case (layer_st)
            L_IDLE: begin
                if (start) begin
                    if (cfg_bad) begin
                        err_code_r <= E_OP;
                        layer_st   <= L_ERR;
                    end else if (geo_bad || win_bad) begin
                        err_code_r <= E_BUFFER;
                        layer_st   <= L_ERR;
                    end else begin
                        busy       <= 1'b1;
                        error      <= 1'b0;      // 新 job 接受时清 sticky
                        error_code <= E_NONE;
                        layer_st   <= L_DW;
                        dw_start_r <= 1'b1;
                    end
                end
            end
            L_DW: begin
                if (dw_layer_done) begin
                    if (dw_layer_err) begin
                        err_code_r <= E_ARITH;
                        layer_st   <= L_ERR;
                    end else begin
                        layer_st   <= L_FC;
                        fc_start_r <= 1'b1;
                    end
                end
            end
            L_FC: begin
                if (fc_layer_done) begin
                    if (fc_layer_err) begin
                        err_code_r <= E_ARITH;
                        layer_st   <= L_ERR;
                    end else begin
                        layer_st   <= L_DONE;
                    end
                end
            end
            L_ERR: begin
                // 终止：不置 done，不再写结果，error 保持到下一次 start
                busy       <= 1'b0;
                done       <= 1'b0;
                error      <= 1'b1;
                error_code <= err_code_r;
                layer_st   <= L_IDLE;
            end
            L_DONE: begin
                // requant 是两级流水：必须等最后一条结果**真的写进结果 RAM** 再置 done，
                // 否则调用方在 done 后立刻回读会丢掉最后一个 logit。
                if (!rq1_valid && !rq2_valid) begin
                    busy     <= 1'b0;
                    done     <= 1'b1;
                    layer_st <= L_IDLE;
                end
            end
            default: layer_st <= L_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
