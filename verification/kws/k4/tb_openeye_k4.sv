// =============================================================================
//  tb_openeye_k4.sv  —  OpenEye 计算核心 vs host golden 逐字节比对
//
//  这是 K4 的**主验证台**：不用合成激励，直接吃仓库里真实模型的
//    · 输入平面  verification/kws/k2/vectors/<fixture>/layer_00_RESHAPE_out_04.bin (1960 B)
//    · DW 权重   fpga/kws/generated/micro_speech-230c9/params_rom.bin[0    .. 639]
//    · DW bias   params_rom.bin[640  .. 671]   (int32 × 8)
//    · FC 权重   params_rom.bin[672  .. 16671]
//    · FC bias   params_rom.bin[16672.. 16687] (int32 × 4)
//    · quant     quant.mem (int32 × 24：每通道 {mult, shift})
//    · 期望 DW 输出 layer_01_DEPTHWISE_CONV_2D_out_02.bin (4000 B)
//    · 期望 FC 输出 layer_02_FULLY_CONNECTED_out_06.bin    (4 B)
//
//  判定：DW 4000 字节 + FC 4 字节，**逐字节相等**才算 PASS。
//
//  ---- 2026-10-21 变更 ----
//  1) 存储模型改为**同步读（1 拍延迟）**：所有读口先寄存一拍再交给 DUT。
//     原先 TB 用组合读，恰好掩盖了 F8（组合读口）这个缺陷。
//  2) 结果 RAM 改为**单窗口 0..4003**，不再用 capture_fc 切换数组：
//     DW 应写 0..3999、FC 应写 4000..4003。若 DUT 仍有「层间同址」（F7），
//     FC 会覆盖 0..3，DW 比对必然失败 ⇒ 这个台现在能直接抓住 F7 回归。
//  3) 增加周期计数打印（F8 的取数流水会让周期数从 344,016 变成 352,012）。
//  4) 结束时检查 `error==0`（数值正确的 job 不应该报错）。
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_openeye_k4;

    // ------------------------------------------------------------ 参数（本模型）
    localparam integer DW_IH = 49, DW_IW = 40;      // layer_00 输出平面
    localparam integer DW_OH = 25, DW_OW = 20;      // layer_01 输出
    localparam integer DW_KH = 10, DW_KW = 8;       // 非方形核
    localparam integer DW_SH = 2,  DW_SW = 2;
    localparam integer DW_PT = 4,  DW_PL = 3;       // 非对称 pad（bottom=5/right=3 由 SAME 推出）
    localparam integer DW_COUT = 8;
    localparam integer FC_NIN = 4000, FC_NOUT = 4;

    localparam integer IN_ZP     = -128;
    localparam integer DW_OUT_ZP = -128;
    localparam integer FC_OUT_ZP = 14;
    localparam integer ACT_MIN   = -128;
    localparam integer ACT_MAX   = 127;

    localparam integer DW_OUT_BYTES = DW_OH * DW_OW * DW_COUT;   // 4000
    localparam integer RES_BYTES    = DW_OUT_BYTES + FC_NOUT;    // 4004

    // ------------------------------------------------------------ 时钟/复位
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    // ------------------------------------------------------------ 存储
    reg signed [7:0]  in_plane [0:DW_IH*DW_IW-1];       // 1960
    reg signed [7:0]  dw_w     [0:DW_COUT*DW_KH*DW_KW-1]; // 640
    reg signed [7:0]  fc_w     [0:FC_NOUT*FC_NIN-1];    // 16000
    reg signed [7:0]  gold_dw  [0:DW_OUT_BYTES-1];      // 4000
    reg signed [7:0]  gold_fc  [0:FC_NOUT-1];           // 4

    // bias 平表：[DW 0..7][FC 8..11]（与 DUT 的 dw_cout + o 布局一致）
    reg signed [31:0] dw_bias   [0:DW_COUT-1];
    reg signed [31:0] fc_bias   [0:FC_NOUT-1];
    reg signed [31:0] bias_all  [0:DW_COUT+FC_NOUT-1];
    reg signed [31:0] q_mult    [0:DW_COUT+FC_NOUT-1];
    reg signed [31:0] q_shift   [0:DW_COUT+FC_NOUT-1];

    // ------------------------------------------------------------ DUT 信号
    reg               start;
    wire              busy, done, error;
    wire [7:0]        error_code;

    wire [15:0]       in_y, in_x, vec_idx;
    wire [15:0]       dw_w_idx;
    wire signed [7:0] w_q;
    wire [31:0]       fc_w_idx;
    wire [15:0]       bias_idx;
    wire signed [31:0] bias_q;
    wire [15:0]       quant_idx;
    wire signed [31:0] quant_mult, quant_shift;
    wire              res_we;
    wire [15:0]       res_addr;
    wire signed [7:0] res_data;

    // 结果窗口：DW 0..3999 + FC 4000..4003（F7 之后不再需要 capture 切换）
    reg signed [7:0]  res_rst [0:RES_BYTES-1];
    integer           res_oob = 0;

    always @(posedge clk) begin
        if (res_we) begin
            if (res_addr < RES_BYTES) res_rst[res_addr] <= res_data;
            else res_oob = res_oob + 1;
        end
    end

    // ------------------------------------------------------------ 读口：同步读（1 拍延迟）
    //  真实 BRAM 是同步读；本台显式寄存一拍返回数据（这是 F8 的验证前提）。
    wire               fc_phase;
    reg signed [7:0]   in_q_r;
    reg signed [7:0]   w_q_r;
    reg signed [31:0]  bias_q_r, qmult_r, qshift_r;

    // ------------------------------------------------------------ DUT
    openeye_top u_dut (
        .clk(clk), .rst(rst),
        .start(start), .busy(busy), .done(done), .error(error), .error_code(error_code),
        .dw_ih(DW_IH[15:0]), .dw_iw(DW_IW[15:0]), .dw_oh(DW_OH[15:0]), .dw_ow(DW_OW[15:0]),
        .dw_kh(DW_KH[7:0]), .dw_kw(DW_KW[7:0]), .dw_sh(DW_SH[7:0]), .dw_sw(DW_SW[7:0]),
        .dw_pt(DW_PT[7:0]), .dw_pl(DW_PL[7:0]), .dw_cout(DW_COUT[7:0]),
        .in_zp(IN_ZP), .dw_out_zp(DW_OUT_ZP),
        .fc_nin(FC_NIN[15:0]), .fc_nout(FC_NOUT[15:0]), .fc_out_zp(FC_OUT_ZP),
        .act_min(ACT_MIN), .act_max(ACT_MAX),
        .in_y(in_y), .in_x(in_x), .vec_idx(vec_idx), .in_q(in_q_r),
        .dw_w_idx(dw_w_idx), .fc_w_idx(fc_w_idx), .w_q(w_q),
        .bias_idx(bias_idx), .bias_q(bias_q),
        .quant_idx(quant_idx), .quant_mult(quant_mult), .quant_shift(quant_shift),
        .res_we(res_we), .res_addr(res_addr), .res_data(res_data)
    );

    // ------------------------------------------------------------ 同步读存储（1 拍延迟）
    assign fc_phase = (u_dut.layer_st == 3'd2);      // L_FC

    always @(posedge clk) begin
        // FC 阶段直接读结果窗口（= DUT 自己写出的 DW 输出），与 SoC 的真实数据流一致
        in_q_r    <= fc_phase ? res_rst[vec_idx]
                              : ((in_y < DW_IH && in_x < DW_IW) ? in_plane[in_y * DW_IW + in_x]
                                                                : 8'sd0);
        w_q_r     <= fc_phase ? fc_w[fc_w_idx] : dw_w[dw_w_idx];
        bias_q_r  <= bias_all[bias_idx];
        qmult_r   <= q_mult[quant_idx];
        qshift_r  <= q_shift[quant_idx];
    end

    assign w_q         = w_q_r;
    assign bias_q      = bias_q_r;
    assign quant_mult  = qmult_r;
    assign quant_shift = qshift_r;

    // ------------------------------------------------------------ 载入数据
    integer i;
    integer total_err = 0;
    integer first_bad_dw = -1, first_bad_fc = -1;

`ifdef VECDIR_STR
    reg [1023:0] vecdir = `VECDIR_STR;
`else
    reg [1023:0] vecdir = "verification/kws/k4/vectors";
`endif
    reg          vec_ok = 1'b0;
    integer      nz_ok;

    initial begin
        $readmemh({vecdir, "/dw_in.hex"},    in_plane);
        $readmemh({vecdir, "/dw_w.hex"},     dw_w);
        $readmemh({vecdir, "/fc_w.hex"},     fc_w);
        $readmemh({vecdir, "/dw_bias.hex"},  dw_bias);
        $readmemh({vecdir, "/fc_bias.hex"},  fc_bias);
        $readmemh({vecdir, "/quant_mult.hex"},  q_mult);
        $readmemh({vecdir, "/quant_shift.hex"}, q_shift);
        $readmemh({vecdir, "/golden_dw.hex"}, gold_dw);
        $readmemh({vecdir, "/golden_fc.hex"}, gold_fc);

        // bias 平表 = DW bias ++ FC bias（与 DUT 的 dw_cout + o 对齐）
        for (i = 0; i < DW_COUT; i = i + 1) bias_all[i]           = dw_bias[i];
        for (i = 0; i < FC_NOUT; i = i + 1) bias_all[DW_COUT + i] = fc_bias[i];

        $display("LOAD in_plane[0..3] = %0d %0d %0d %0d", in_plane[0], in_plane[1], in_plane[2], in_plane[3]);
        $display("LOAD dw_w[0..3]     = %0d %0d %0d %0d", dw_w[0], dw_w[1], dw_w[2], dw_w[3]);
        $display("LOAD dw_bias[0]     = %0d  fc_bias[0] = %0d", dw_bias[0], fc_bias[0]);
        $display("LOAD quant_mult[0]  = %0d  shift[0] = %0d", q_mult[0], q_shift[0]);
        $display("LOAD golden_dw[0..3]= %0d %0d %0d %0d", gold_dw[0], gold_dw[1], gold_dw[2], gold_dw[3]);

        // sentinel：确认真的载入了，不是全 x
        nz_ok = 0;
        for (i = 0; i < DW_OUT_BYTES; i = i + 1)
            if (gold_dw[i] !== 8'bx) nz_ok = nz_ok + 1;
        if (q_mult[0] === 32'd1653229999 && dw_bias[0] === 32'sd3722 && nz_ok == DW_OUT_BYTES)
            vec_ok = 1'b1;
        else begin
            $display("FATAL [tb_openeye_k4] vectors not loaded (vecdir=%0s) q_mult[0]=%0d dw_bias[0]=%0d known=%0d/%0d",
                     vecdir, q_mult[0], dw_bias[0], nz_ok, DW_OUT_BYTES);
            $fatal(1);
        end
        $display("LOAD sentinel OK (vecdir=%0s)", vecdir);
    end

    // ------------------------------------------------------------ 激励
    integer dw_bad, fc_bad;
    integer cyc_dw = 0, cyc_fc = 0, cyc_all = 0;
    integer t0 = 0;

    initial begin
        for (i = 0; i < RES_BYTES; i = i + 1) res_rst[i] = 8'sd0;

        repeat (4) @(posedge clk);
        rst   <= 1'b0;
        start <= 1'b0;
        repeat (2) @(posedge clk);

        // ---------------- START ----------------
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;
        t0 = $time;

        // ---------------- DW 层 ----------------
        wait (u_dut.layer_st == 3'd1);            // L_DW
        wait (u_dut.layer_st == 3'd2);            // DW 完成、进入 L_FC
        repeat (4) @(posedge clk);                // 等 requant 两级流水把最后一个 DW 结果写完
        cyc_dw = ($time - t0) / 10;

        // 此时 DW 结果已全部写入 res_rst[0..3999]
        dw_bad = 0;
        for (i = 0; i < DW_OUT_BYTES; i = i + 1) begin
            if ((res_rst[i] === 8'hxx) || (gold_dw[i] === 8'hxx)) begin
                if (dw_bad == 0) $display("  DW has X @%0d (rst=%b gold=%b)", i, res_rst[i], gold_dw[i]);
                dw_bad = dw_bad + 1;
            end else if (res_rst[i] !== gold_dw[i]) begin
                if (dw_bad < 12) $display("  DBG DW @%0d (oy=%0d ox=%0d c=%0d) got %0d want %0d",
                                          i, i/(DW_OW*DW_COUT), (i/DW_COUT)%DW_OW, i%DW_COUT, res_rst[i], gold_dw[i]);
                if (dw_bad == 0) begin
                    $display("  DW first mismatch @%0d : got %0d  want %0d", i, res_rst[i], gold_dw[i]);
                    first_bad_dw = i;
                end
                dw_bad = dw_bad + 1;
            end
        end
        $display("DW: %0d / %0d bytes match (%0d mismatch)", DW_OUT_BYTES - dw_bad, DW_OUT_BYTES, dw_bad);

        // ---------------- FC 层 ----------------
        wait (done == 1'b1);                      // done 已在「最后一条结果写完之后」才置位
        cyc_all = ($time - t0) / 10;
        cyc_fc  = cyc_all - cyc_dw;

        fc_bad = 0;
        for (i = 0; i < FC_NOUT; i = i + 1) begin
            if ((res_rst[DW_OUT_BYTES + i] === 8'hxx) || (gold_fc[i] === 8'hxx)) begin
                if (fc_bad == 0) $display("  FC has X @%0d (rst=%b gold=%b)",
                                          DW_OUT_BYTES + i, res_rst[DW_OUT_BYTES + i], gold_fc[i]);
                fc_bad = fc_bad + 1;
            end else if (res_rst[DW_OUT_BYTES + i] !== gold_fc[i]) begin
                if (fc_bad == 0) begin
                    $display("  FC first mismatch @%0d : got %0d  want %0d",
                             DW_OUT_BYTES + i, res_rst[DW_OUT_BYTES + i], gold_fc[i]);
                    first_bad_fc = i;
                end
                fc_bad = fc_bad + 1;
            end
        end
        $display("FC: %0d / %0d bytes match (%0d mismatch)  [base=%0d]",
                 FC_NOUT - fc_bad, FC_NOUT, fc_bad, DW_OUT_BYTES);

        $display("CYCLES dw=%0d fc=%0d total=%0d", cyc_dw, cyc_fc, cyc_all);
        if (res_oob != 0) $display("  WARN res_we with res_addr outside 0..%0d : %0d 次", RES_BYTES-1, res_oob);
        if (error !== 1'b0) $display("  WARN unexpected error=1 code=%0d（数值正确时不应报错）", error_code);

        // ---------------- 判定 ----------------
        total_err = dw_bad + fc_bad;
        if (total_err == 0 && error === 1'b0 && res_oob == 0)
            $display("PASS [tb_openeye_k4] DW %0d/%0d + FC %0d/%0d bytes byte-exact",
                     DW_OUT_BYTES, DW_OUT_BYTES, FC_NOUT, FC_NOUT);
        else begin
            $display("FAIL [tb_openeye_k4] %0d byte mismatch (DW=%0d FC=%0d) error=%0b oob=%0d",
                     total_err, dw_bad, fc_bad, error, res_oob);
            $fatal(1);
        end
        $finish;
    end

    // 超时保护：本模型约 33.6 万拍 DW + 1.6 万拍 FC
    initial begin
        #220_000_000;
        $display("FAIL [tb_openeye_k4] timeout at %0t (layer_st=%0d)", $time, u_dut.layer_st);
        $fatal(1);
    end

endmodule

`default_nettype wire
