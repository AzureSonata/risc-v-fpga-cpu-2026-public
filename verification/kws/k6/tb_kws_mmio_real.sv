// =============================================================================
//  tb_kws_mmio_real.sv  —  真实几何 / 真实参数的整 job 验证（K6 S5 + D2）
//
//  与 tb_kws_mmio_min 的分工：
//    · min  ：小几何，只验协议与语义（2158 笔事务，不验数值模型）
//    · real ：真实模型几何与真实向量，验「数值 + 4000 偏移」两件事
//
//  真实几何（= verification/kws/k4/tb_openeye_k4.sv 的同一组参数）：
//    输入 49×40 int8（1960 B） → DW 10×8/stride2 → 25×20×8（4000 B） → FC 4000→4
//  向量：verification/kws/k4/vectors/（作者封存的那一套，未重生成）
//
//  判据：
//    R1  整 job 在预算内完成：done=1、error=0、busy 落 0
//    R2  CYCLE_COUNT ≈ 352,020（±32；超出即判 FAIL，不是"打印一下"）
//    R3  结果 RAM [0..3999] 与 golden_dw 逐字节相同
//    R4  总线读 0x800 得到 FC logits（4 个 int8）与 golden_fc 相同
//    R5  0x800 不等于 buffer 偏移 0 的内容（D2 别名反证：证明映射不是恒等）
//    R6  INPUT_CRC32 与 TB 独立算的 zlib CRC 相同（顺带复核 A8 在真实数据上成立）
//
//  ⚠️ 本台不替代 K4 的 7/7 向量回归：K4 TB 直接例化 openeye_top，
//     本台走 kws_mmio 的寄存器 / buffer 窗 / 结果窗，验的是"包起来之后数值没变"。
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_kws_mmio_real;

    // ---------------------------------------------------------------- 时钟/复位
    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    // K6-04：TB 侧拍计数器（**不读 DUT 内部状态**做期望值）。
    //   四段边界全部由"外部总线事务 + done/IRQ 可见"定义，见文件末尾 SEG 段。
    integer cyc = 0;
    always @(posedge clk) cyc = cyc + 1;

    // ---------------------------------------------------------------- 总线
    reg         req_valid = 1'b0;
    wire        req_ready;
    reg  [31:0] addr  = 32'd0;
    reg         write = 1'b0;
    reg  [31:0] wdata = 32'd0;
    reg  [3:0]  wstrb = 4'd0;
    wire        rsp_valid;
    reg         rsp_ready = 1'b1;
    wire [31:0] rdata;
    wire        error;

    // ---------------------------------------------------------------- 真实几何
    localparam integer IH = 49, IW = 40;
    localparam integer OH = 25, OW = 20;
    localparam integer KH = 10, KW = 8;
    localparam integer SH = 2,  SW = 2;
    localparam integer PT = 4,  PL = 3;
    localparam integer COUT = 8;
    localparam integer FC_NIN = 4000, FC_NOUT = 4;
    localparam integer IN_ZP = -128, DW_OUT_ZP = -128, FC_OUT_ZP = 14;
    localparam integer ACT_MIN = -128, ACT_MAX = 127;

    localparam integer IN_BYTES  = IH * IW;             // 1960
    localparam integer DW_O_BYTES= OH * OW * COUT;      // 4000
    localparam integer RES_BYTES = 4096;                // D2：按 4 KiB 实现
    localparam integer CYC_GOLDEN= 352020;              // 作者实测（SIM 口径）

    // ---------------------------------------------------------------- 向量
    reg signed [7:0]  in_plane [0:IN_BYTES-1];
    reg signed [7:0]  dw_w     [0:639];
    reg signed [7:0]  fc_w     [0:15999];
    reg signed [31:0] dw_bias  [0:COUT-1];
    reg signed [31:0] fc_bias  [0:FC_NOUT-1];
    reg signed [31:0] bias_all [0:COUT+FC_NOUT-1];
    reg signed [31:0] q_mult   [0:COUT+FC_NOUT-1];
    reg signed [31:0] q_shift  [0:COUT+FC_NOUT-1];
    reg signed [7:0]  gold_dw  [0:DW_O_BYTES-1];
    reg signed [7:0]  gold_fc  [0:FC_NOUT-1];

    // ---------------------------------------------------------------- 四组存储（同步读）
    wire [15:0] dw_w_idx, bias_idx, quant_idx;
    wire [31:0] fc_w_idx;
    wire        fc_phase_dbg;

    reg signed [7:0]  w_q_r;
    reg signed [31:0] bias_q_r, qmult_r, qshift_r;
    wire signed [7:0]  w_q         = w_q_r;
    wire signed [31:0] bias_q      = bias_q_r;
    wire signed [31:0] quant_mult  = qmult_r;
    wire signed [31:0] quant_shift = qshift_r;

    always @(posedge clk) begin
        w_q_r    <= fc_phase_dbg ? fc_w[fc_w_idx] : dw_w[dw_w_idx];
        bias_q_r <= bias_all[bias_idx];
        qmult_r  <= q_mult[quant_idx];
        qshift_r <= q_shift[quant_idx];
    end

    // ---------------------------------------------------------------- DUT
    wire        irq, busy_o, done_o, err_o, timeout_o;
    wire [7:0]  code_o;
    wire [31:0] cyc_o, start_o, reject_o;

    kws_mmio #(
        .INPUT_BYTES    (IN_BYTES),
        .RES_BYTES      (RES_BYTES),
        .LOGIT_OFF      (DW_O_BYTES),        // D2：4000
        .TIMEOUT_DEFAULT(32'd704040)         // D1 提案：2 × 352,020
    ) dut (
        .clk(clk), .rst(rst),
        .estop_arm(1'b0), .estop_por(1'b1), .estop_trip(),
        .req_valid(req_valid), .req_ready(req_ready),
        .addr(addr), .write(write), .wdata(wdata), .wstrb(wstrb),
        .rsp_valid(rsp_valid), .rsp_ready(rsp_ready), .rdata(rdata), .error(error),

        // Exercise the production configuration: MODEL_ROM_ENABLE defaults on,
        // so no external descriptor or quantization values may be required.
        .dw_ih(16'd0), .dw_iw(16'd0), .dw_oh(16'd0), .dw_ow(16'd0),
        .dw_kh(16'd0), .dw_kw(16'd0),
        .dw_sh(16'd0), .dw_sw(16'd0),
        .dw_pt(16'd0), .dw_pl(16'd0), .dw_cout(16'd0),
        .in_zp(32'sd0), .dw_out_zp(32'sd0),
        .fc_nin(16'd0), .fc_nout(16'd0), .fc_out_zp(32'sd0),
        .act_min(32'sd0), .act_max(32'sd0),

        .dw_w_idx(dw_w_idx), .fc_w_idx(fc_w_idx),
        .bias_idx(bias_idx), .quant_idx(quant_idx),
        .w_q(8'sd0), .bias_q(32'sd0),
        .quant_mult(32'sd0), .quant_shift(32'sd0),

        .irq(irq),
        .o_job_active(busy_o), .o_done_sticky(done_o), .o_error_sticky(err_o),
        .o_error_code(code_o), .o_cycle_count(cyc_o), .o_timeout_hit(timeout_o),
        .o_fc_phase(fc_phase_dbg), .o_start_count(start_o), .o_reject_count(reject_o)
    );

    // ---------------------------------------------------------------- IRQ 见证（K6-04）
    //   只用 `irq` 这个 **output 引脚** + IRQ_EN/IRQ_PEND/IRQ_CLR 三个寄存器事务判定，
    //   不引用 `dut.irq_q` 之类内部信号——否则"见证"就变成"拿期望值当结论"。
    integer irq_hi = 0;      // irq 累计高电平拍数
    integer t_irq  = -1;     // 首次看到 irq=1 的拍号；-1 = 整场从未出现
    always @(posedge clk) begin
        if (irq === 1'b1) begin
            irq_hi = irq_hi + 1;
            if (t_irq < 0) t_irq = cyc;
        end
    end

    // ---------------------------------------------------------------- 地址常量
    localparam [31:0] CTRL   = 32'h4000_0000;
    localparam [31:0] REG_ID = CTRL + 32'h000;
    localparam [31:0] REG_CTRL = CTRL + 32'h004;
    localparam [31:0] REG_STATUS = CTRL + 32'h008;
    localparam [31:0] REG_ERC  = CTRL + 32'h014;
    localparam [31:0] REG_CYCLE= CTRL + 32'h01C;
    localparam [31:0] REG_CRC  = CTRL + 32'h040;
    // IRQ 三件套（K6-04 的"IRQ 见证"只走这三个寄存器 + `irq` 引脚，不碰 DUT 内部）
    localparam [31:0] REG_IRQ_EN   = CTRL + 32'h00C;   // [0]=EN
    localparam [31:0] REG_IRQ_CLR  = CTRL + 32'h010;   // 写 1 清 pending
    localparam [31:0] REG_IRQ_PEND = CTRL + 32'h044;   // [0]=pending
    localparam [31:0] BUF      = 32'h4000_1000;
    localparam [31:0] WIN_LOGIT= BUF  + 32'h800;

    // ---------------------------------------------------------------- 记账
    integer cases = 0;
    integer fails = 0;

    // K6-04 四段时间戳（单位：拍）
    integer t_feat0 = 0, t_feat1 = 0, t_crc = 0, t_start = 0, t_done = 0, t_logit = 0;
    integer seg_to_feature = 0, seg_to_start = 0, seg_busy = 0, seg_tail = 0, seg_e2e = 0;

    task automatic bus_xfer(input [31:0] a, input wr, input [31:0] d, input [3:0] s,
                            input bit exp_err, output [31:0] q);
        integer guard;
        reg accepted;
        begin
            @(negedge clk);
            req_valid = 1'b1; addr = a; write = wr; wdata = d; wstrb = s;
            // 握手前的 req_ready 才是"被接受"的真值（见 tb_kws_mmio_min 的同款注释）
            accepted = req_ready;
            @(posedge clk); #1;
            req_valid = 1'b0;
            // ⚠️ 坑位：**不能假设"次拍必有 rsp_valid"**。读 0x040 时后台 CRC 引擎
            //    若尚未收敛（写完 buffer 后 1,961 拍内，本 TB 的 R6 正是这种时机），
            //    slave 会挂起该次读；主设备必须有界等待（4,096 拍上限）。
            guard = 0;
            while (rsp_valid !== 1'b1 && guard < 4096) begin
                @(negedge clk); guard = guard + 1;
            end
            if (!accepted) begin
                $display("FAIL  bus: req_ready=0 on first cycle @%h", a); fails = fails + 1;
            end
            if (rsp_valid !== 1'b1) begin
                $display("FAIL  bus: no rsp_valid @%h (waited %0d cycles)", a, guard);
                fails = fails + 1;
            end
            if (error !== exp_err) begin
                $display("FAIL  bus: %h wr=%0d err=%0b expect %0b", a, wr, error, exp_err);
                fails = fails + 1;
            end
            q = rdata;
        end
    endtask

    task automatic wr(input [31:0] a, input [31:0] d, input bit exp_err);
        reg [31:0] dummy;
        begin bus_xfer(a, 1'b1, d, 4'hF, exp_err, dummy); cases = cases + 1; end
    endtask

    task automatic rd(input [31:0] a, input bit exp_err, output [31:0] q);
        begin bus_xfer(a, 1'b0, 32'd0, 4'h0, exp_err, q); cases = cases + 1; end
    endtask

    // ---------------------------------------------------------------- 载入向量
    integer i, j;
`ifdef VECDIR_STR
    reg [1023:0] vecdir = `VECDIR_STR;
`else
    reg [1023:0] vecdir = "verification/kws/k4/vectors";
`endif

    // ---------------------------------------------------------------- 独立 CRC32（zlib）
    function automatic [31:0] crc32_byte(input [31:0] c, input [7:0] b);
        integer k;
        reg [31:0] x;
        begin
            x = c ^ {24'd0, b};
            for (k = 0; k < 8; k = k + 1)
                x = (x[0]) ? ((x >> 1) ^ 32'hEDB8_8320) : (x >> 1);
            crc32_byte = x;
        end
    endfunction

    // ---------------------------------------------------------------- 主流程
    reg [31:0] v, s, crc_calc, cyc_read;

    // 结果 RAM 在 DUT 内部是**独立 RAM 模块**里的 32 位字数组（`u_res_w.mem`，见
    //   rtl/soc/kws_res_w_ram.sv）。判据仍按**字节地址**看，故用同一套字/字节换算。
    //   这是对 DUT 内部的观测口；期望值来自 golden_dw.hex / golden_fc.hex（K4 冻结夹具）。
    function automatic [7:0] ram_byte(input integer a);
        ram_byte = dut.u_res_w.mem[a / 4] >> (8 * (a % 4));
    endfunction

    // ★ 两块 RAM 无初值（BRAM 不能带 init），零初值由 TB 在 time 0 直接写数组提供。
    task automatic zero_rams();
        integer k;
        begin
            for (k = 0; k < 512;  k = k + 1) dut.u_in_w.mem[k]  = 32'd0;
            for (k = 0; k < 1024; k = k + 1) dut.u_res_w.mem[k] = 32'd0;
        end
    endtask

    integer    bad_dw = 0, bad_fc = 0, first_bad_dw = -1, w;
    integer    guard;
    reg [31:0] logit_word, buf0_word;

    initial begin
        zero_rams();      // ★ 两块 RAM 无初值，由 TB 在 time 0 置零
        $readmemh({vecdir, "/dw_in.hex"},     in_plane);
        $readmemh({vecdir, "/dw_w.hex"},      dw_w);
        $readmemh({vecdir, "/fc_w.hex"},      fc_w);
        $readmemh({vecdir, "/dw_bias.hex"},   dw_bias);
        $readmemh({vecdir, "/fc_bias.hex"},   fc_bias);
        $readmemh({vecdir, "/quant_mult.hex"}, q_mult);
        $readmemh({vecdir, "/quant_shift.hex"}, q_shift);
        $readmemh({vecdir, "/golden_dw.hex"}, gold_dw);
        $readmemh({vecdir, "/golden_fc.hex"}, gold_fc);

        // 扁平 bias / quant 表：[DW 0..7][FC 8..11]
        for (i = 0; i < COUT; i = i + 1) bias_all[i] = dw_bias[i];
        for (i = 0; i < FC_NOUT; i = i + 1) bias_all[COUT+i] = fc_bias[i];

        $display("=== kws_mmio 真实几何整 job 验证 ===");
        $display("NOTE  几何 %0dx%0d -> %0dx%0d x%0d (DW %0d B) -> FC %0d->%0d",
                 IH, IW, OH, OW, COUT, DW_O_BYTES, FC_NIN, FC_NOUT);

        repeat (4) @(posedge clk);
        rst <= 1'b0;
        repeat (2) @(posedge clk);

        // ---------- R0：ID 可读（先确认总线活着） ----------
        rd(REG_ID, 1'b0, v);
        if (v !== 32'h3153_574B) begin
            $display("FAIL  R0 ID 读回 %h，应为 3153574B", v); fails = fails + 1;
        end else $display("PASS  R0 ID=%h", v);

        // ---------- R7：IRQ 使能（放 job 之前，不进四段窗口） ----------
        wr(REG_IRQ_EN, 32'd1, 1'b0);
        rd(REG_IRQ_EN, 1'b0, v);
        if (v !== 32'd1) begin
            $display("FAIL  R7 IRQ_EN 读回 %h，应为 1", v); fails = fails + 1;
        end else $display("PASS  R7 IRQ_EN=1");
        if (irq !== 1'b0) begin
            $display("FAIL  R7 使能后、START 前 irq 已为高（pending=%0d）", irq_hi);
            fails = fails + 1;
        end

        // CRC 的软件参考值先算好（纯 TB 计算，**不能**放在 t_feat0 之后：
        //   1960 次循环会混进 to_start，把它变成"TB 算 CRC 的时间"而不是总线时间）。
        crc_calc = 32'hFFFF_FFFF;
        for (i = 0; i < IN_BYTES; i = i + 1) crc_calc = crc32_byte(crc_calc, in_plane[i]);
        crc_calc = ~crc_calc;

        // ---------- 写 1960 B 输入到 buffer 窗 ----------
        t_feat0 = cyc;                       // SEG 边界①：第一个特征写事务开始
        for (w = 0; w < IN_BYTES/4; w = w + 1) begin
            wr(BUF + 4*w, {in_plane[4*w+3], in_plane[4*w+2], in_plane[4*w+1], in_plane[4*w]}, 1'b0);
        end
        t_feat1 = cyc;                       // SEG 边界②：第 1,960 B 特征写完

        // ---------- R6：CRC 与 TB 独立计算一致（真实 1960 B 上复核 A8） ----------
        rd(REG_CRC, 1'b0, v);
        t_crc = cyc;    // CRC 读完成（crc32_buf 逐字节引擎会反压约 1,961 拍）
        if (v !== crc_calc) begin
            $display("FAIL  R6 CRC 读回 %h，独立算 %h", v, crc_calc); fails = fails + 1;
        end else $display("PASS  R6 INPUT_CRC32=%h（zlib，1960 B 真实输入）", v);

        // ---------- 启动 ----------
        wr(REG_CTRL, 32'd1, 1'b0);
        t_start = cyc;                       // SEG 边界③：START 被接受（写事务完成）
        if (start_o !== 32'd1) begin
            $display("FAIL  START 未被接受 start_count=%0d", start_o); fails = fails + 1;
        end

        // ---------- 等 done（真实 job ≈ 352k 拍） ----------
        guard = 0;
        while (!done_o && !err_o && guard < 800000) begin
            @(posedge clk);
            guard = guard + 1;
        end
        t_done = cyc;                        // SEG 边界④：done 对外可见（轮询首次看到）

        // ---------- R1：终态 ----------
        if (!done_o || err_o || busy_o) begin
            $display("FAIL  R1 终态异常 done=%0b err=%0b busy=%0b code=%0d guard=%0d",
                     done_o, err_o, busy_o, code_o, guard);
            fails = fails + 1;
        end else
            $display("PASS  R1 完成 done=1 err=0 busy=0（%0d 拍后轮询到）", guard);

        // ---------- R2：CYCLE_COUNT ----------
        rd(REG_CYCLE, 1'b0, cyc_read);
        if (cyc_read > CYC_GOLDEN + 32 || cyc_read + 32 < CYC_GOLDEN) begin
            $display("FAIL  R2 CYCLE_COUNT=%0d 偏离 %0d 超过 ±32", cyc_read, CYC_GOLDEN);
            fails = fails + 1;
        end else
            $display("PASS  R2 CYCLE_COUNT=%0d（作者口径 %0d，差 %0d）",
                     cyc_read, CYC_GOLDEN, cyc_read - CYC_GOLDEN);

        // ---------- R3：结果 RAM 前 4000 B 逐字节 ----------
        for (i = 0; i < DW_O_BYTES; i = i + 1) begin
            if ($signed(ram_byte(i)) !== gold_dw[i]) begin
                bad_dw = bad_dw + 1;
                if (first_bad_dw < 0) first_bad_dw = i;
            end
        end
        if (bad_dw != 0) begin
            $display("FAIL  R3 DW 输出 %0d/%0d 字节不符，首个坏点 %0d（RTL %0d vs golden %0d）",
                     bad_dw, DW_O_BYTES, first_bad_dw,
                     $signed(ram_byte(first_bad_dw)), gold_dw[first_bad_dw]);
            fails = fails + 1;
        end else
            $display("PASS  R3 DW 输出 %0d 字节逐字节相同（golden_dw）", DW_O_BYTES);

        // ---------- R4：0x800 读出 FC logits ----------
        rd(WIN_LOGIT, 1'b0, logit_word);
        t_logit = cyc;                       // SEG 边界⑤：logits 读完（外部主取走最终结果）
        if (logit_word !== {gold_fc[3], gold_fc[2], gold_fc[1], gold_fc[0]}) begin
            $display("FAIL  R4 0x800 读回 %h，golden %h（%0d %0d %0d %0d）",
                     logit_word, {gold_fc[3], gold_fc[2], gold_fc[1], gold_fc[0]},
                     gold_fc[0], gold_fc[1], gold_fc[2], gold_fc[3]);
            fails = fails + 1;
        end else
            $display("PASS  R4 0x800 = %h（logit0..3 = %0d %0d %0d %0d，偏移 %0d）",
                     logit_word, gold_fc[0], gold_fc[1], gold_fc[2], gold_fc[3], DW_O_BYTES);

        // ---------- R5：0x800 不是 buffer 偏移 0 的别名 ----------
        rd(BUF, 1'b0, buf0_word);
        if (logit_word === buf0_word) begin
            $display("FAIL  R5 0x800 与 buffer[0..3] 相同（%h），无法区分映射是否生效", logit_word);
            fails = fails + 1;
        end else
            $display("PASS  R5 0x800(%h) != buffer[0..3](%h) ⇒ 映射不是恒等", logit_word, buf0_word);

        // ---------- R8：IRQ 见证（done/err → irq 上升，且不提前） ----------
        //   放在 R4/R5 之后：`irq` 是 **sticky 电平**（irq_q 锁到清为止），晚查不改变结论，
        //   但能避免"在 R1 那一拍的 delta 内就查"导致 t_logit 被采样窗口推后
        //   （`done_q` 与 `irq_q` 同拍置位，见 kws_mmio.sv:530-535）。
        //   t_irq 由独立监视器在**首个 irq=1 的 posedge**记录，与在哪里检查无关。
        if (t_irq < 0) begin
            $display("FAIL  R8 irq 整场从未拉高（irq_hi=0）⇒ 中断不可见");
            $display("DBG   irq=%0b dut.irq_q=%0b dut.irq_en=%0b done_o=%0b",
                     irq, dut.irq_q, dut.irq_en, done_o);
            fails = fails + 1;
        end else if (t_irq < t_start) begin
            $display("FAIL  R8 irq 在 START 之前就拉高（t_irq=%0d < t_start=%0d）", t_irq, t_start);
            fails = fails + 1;
        end else if (!err_o && (t_irq > t_done + 8)) begin
            $display("FAIL  R8 irq 比 done 晚 %0d 拍（t_irq=%0d t_done=%0d）",
                     t_irq - t_done, t_irq, t_done);
            fails = fails + 1;
        end else
            $display("PASS  R8 irq 在 t_irq=%0d 拉高（done 后 %0d 拍，累计保持 %0d 拍）",
                     t_irq, t_irq - t_done, irq_hi);

        // ---------- R9：IRQ_PENDING 可读、可清（清后电平必须掉） ----------
        rd(REG_IRQ_PEND, 1'b0, v);
        if (v !== 32'd1) begin
            $display("FAIL  R9 IRQ_PENDING 读回 %h，应为 1", v); fails = fails + 1;
        end else $display("PASS  R9 IRQ_PENDING=1");
        wr(REG_IRQ_CLR, 32'd1, 1'b0);
        repeat (3) @(posedge clk);
        if (irq !== 1'b0) begin
            $display("FAIL  R9 清 pending 后 irq 仍为高（电平没掉）"); fails = fails + 1;
        end
        rd(REG_IRQ_PEND, 1'b0, v);
        if (v !== 32'd0) begin
            $display("FAIL  R9 清后 IRQ_PENDING 读回 %h，应为 0", v); fails = fails + 1;
        end else $display("PASS  R9 清 pending 后 irq=0 / pending=0");

        // ---------- K6-04：四段周期分项（全部来自 TB 侧时间戳）----------
        //   边界定义（先冻结、后测量，禁止看完结果再改定义）：
        //     ① t_feat0 第一个特征写事务开始
        //     ② t_feat1 第 1,960 B 特征写入完成
        //     ③ t_start CTRL.START 被接受（写事务完成）
        //     ④ t_done  done 对总线可见（轮询首次看到）
        //     ⑤ t_logit 4 个 logit 读完
        //   注意：②→③ 之间夹一次 INPUT_CRC32 寄存器读（4 拍）—— 固件同样会读，
        //   故 to_start 含这次读；报告里必须写明，不能当成纯"特征完成到 START"。
        seg_to_feature = t_feat1 - t_feat0;
        seg_to_start   = t_start - t_feat1;
        seg_busy       = t_done  - t_start;
        seg_tail       = t_logit - t_done;
        seg_e2e        = t_logit - t_feat0;
        //   to_start 分两个口径（必须都报，否则会把 CRC 阻塞算成"启动开销"）：
        //     to_start      : 特征写完 → START（含一次 CRC 寄存器读）
        //     to_start_nocrc: CRC 读完成 → START（真实"启动开销"）
        $display("SEG to_feature=%0d to_start=%0d to_start_nocrc=%0d busy=%0d logit_tail=%0d end_to_end=%0d",
                 seg_to_feature, seg_to_start, t_start - t_crc, seg_busy, seg_tail, seg_e2e);
        $display("SEGCRC crc_read_block=%0d cycles (crc32_buf byte engine back-pressure)",
                 t_crc - t_feat1);

        cases = cases + 1;
        if (seg_to_feature <= 0 || seg_to_start <= 0 || seg_busy <= 0 || seg_tail <= 0) begin
            $display("FAIL  SEG 存在非正分段（%0d/%0d/%0d/%0d）⇒ 计时边界失效",
                     seg_to_feature, seg_to_start, seg_busy, seg_tail);
            fails = fails + 1;
        end else if (seg_to_feature + seg_to_start + seg_busy + seg_tail !== seg_e2e) begin
            $display("FAIL  SEG 四段之和 %0d != end_to_end %0d",
                     seg_to_feature + seg_to_start + seg_busy + seg_tail, seg_e2e);
            fails = fails + 1;
        end else if (seg_busy > CYC_GOLDEN + 64 || seg_busy + 64 < CYC_GOLDEN) begin
            $display("FAIL  SEG busy=%0d 与核内 CYCLE_COUNT=%0d 相差超过 ±64（边界口径不一致）",
                     seg_busy, cyc_read);
            fails = fails + 1;
        end else begin
            $display("PASS  SEG 四段自洽（和=%0d），busy=%0d vs CYCLE_COUNT=%0d 差 %0d",
                     seg_e2e, seg_busy, cyc_read, seg_busy - cyc_read);
        end

        // ---------- 结果 RAM 尾部未被污染（4 KiB 只用到 4004）----------
        for (i = DW_O_BYTES + FC_NOUT; i < RES_BYTES; i = i + 1) begin
            if (ram_byte(i) !== 8'd0) begin
                $display("FAIL  结果 RAM 越界写：res_w[%0d]=%0d（应为 0）", i, ram_byte(i));
                fails = fails + 1;
                i = RES_BYTES;
            end
        end

        $display("SUMMARY cases=%0d fails=%0d", cases, fails);
        if (fails == 0) $display("RESULT PASS");
        else            $display("RESULT FAIL");
        $finish;
    end

    // 全局超时保护
    initial begin
        #50000000;   // 50 ms 仿真时间 ≫ 一个真实 job
        $display("FAIL  全局超时（50 ms 仿真时间）");
        $display("SUMMARY cases=%0d fails=%0d", cases, fails + 1);
        $display("RESULT FAIL");
        $finish;
    end

endmodule

`default_nettype wire
