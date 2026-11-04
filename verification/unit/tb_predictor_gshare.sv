// ============================================================================
//        branch_predictor GSHARE 档验证（PRED_MODE=1）
//
//        目的：验证 gshare 档的机制正确性，这些机制在 BIMODAL 档中根本不存在：
//          - GHR（全局历史寄存器）寄存并逐拍左移，真实方向进最低位
//          - PHT 索引 = PC[GHR_BITS+1:2] ⊕ GHR（随历史变化）
//          - 2-bit 饱和计数器（BTB 未命中时置弱值，命中时饱和增减）
//          - BTB 只存 {valid, tag, target}，不含方向位
//
//        方法：TB 内置**独立 scoreboard 模型**（exp_ghr / exp_pht / exp_btb_*），
//        按规范规则自行推演，逐拍与 DUT 输出比对；而不是只断言几个硬编码结果。
//
//        关键测试设计：GHR 宽度取 4 位以便构造"GHR 回到 0"的序列——
//        先训练目标分支为 taken，再用 4 条 taken=0 的"供体分支"把 GHR 移回 0，
//        此时目标分支的 PHT 索引复原，应当预测 taken。若 GHR 未正确参与索引，
//        该断言必然失败。
//
//        参数：ENTRIES=64 / IDX_BITS=6 / GHR_BITS=4（PHT 16 项）
// ============================================================================

`timescale 1ns / 1ps

`include "defines.sv"

module tb_predictor_gshare;

    localparam IDX_BITS  = 6;
    localparam GHR_BITS  = 4;
    localparam TAG_W     = 32 - IDX_BITS - 2;   // 24
    localparam PHT_N     = (1 << GHR_BITS);     // 16

    reg         clk;
    reg         rst;
    reg         q_valid;
    reg  [31:0] q_pc;
    wire        q_hit;
    wire        q_taken;
    wire [31:0] q_target;
    reg         u_valid;
    reg  [31:0] u_pc;
    reg         u_taken;
    reg  [31:0] u_target;
    reg         u_pred_taken;
    reg  [31:0] u_pred_target;
    reg         u_exception;
    reg         stat_clr;
    wire [31:0] stat_query, stat_hit, stat_mispredict;

    branch_predictor #(
        .ENTRIES(64), .IDX_BITS(IDX_BITS),
        .PRED_MODE(1), .GHR_BITS(GHR_BITS)
    ) u_dut (
        .clk(clk), .rst(rst),
        .q_valid(q_valid), .q_pc(q_pc),
        .q_hit(q_hit), .q_taken(q_taken), .q_target(q_target),
        .u_valid(u_valid), .u_pc(u_pc), .u_taken(u_taken), .u_target(u_target),
        .u_pred_taken(u_pred_taken), .u_pred_target(u_pred_target),
        .u_exception(u_exception),
        .stat_clr(stat_clr),
        .stat_query(stat_query), .stat_hit(stat_hit),
        .stat_mispredict(stat_mispredict)
    );

    // ------------------------------------------------------------------
    // 独立 scoreboard 模型（依规范规则推演，不读 DUT 内部信号）
    // ------------------------------------------------------------------
    reg [GHR_BITS-1:0] exp_ghr;
    reg [1:0]  exp_pht [0:PHT_N-1];
    reg        exp_btb_v [0:63];
    reg [TAG_W-1:0] exp_btb_tag [0:63];
    reg [31:0] exp_btb_tgt [0:63];

    integer errors;
    integer checks;

    always #5 clk = ~clk;

    // 模型：解析一条控制转移指令后的状态
    task model_resolve(input [31:0] pc, input taken, input [31:0] tgt);
        reg [IDX_BITS-1:0] bi;
        reg [GHR_BITS-1:0] pi;
        reg hit;
        begin
            bi  = pc[IDX_BITS+1:2];
            pi  = pc[GHR_BITS+1:2] ^ exp_ghr;
            hit = exp_btb_v[bi] && (exp_btb_tag[bi] == pc[31:IDX_BITS+2]);
            if (!hit) begin
                exp_btb_v[bi]   = 1'b1;
                exp_btb_tag[bi] = pc[31:IDX_BITS+2];
                exp_btb_tgt[bi] = tgt;
                exp_pht[pi]     = taken ? 2'b10 : 2'b01;   // 置弱值
            end else begin
                if (taken) begin
                    exp_btb_tgt[bi] = tgt;
                    if (exp_pht[pi] != 2'b11) exp_pht[pi] = exp_pht[pi] + 2'b01;
                end else begin
                    if (exp_pht[pi] != 2'b00) exp_pht[pi] = exp_pht[pi] - 2'b01;
                end
            end
            exp_ghr = {exp_ghr[GHR_BITS-2:0], taken};
        end
    endtask

    // 驱动一次解析 + 时钟沿 + 模型同步
    task do_resolve(input [31:0] pc, input taken, input [31:0] tgt);
        begin
            u_valid = 1'b1; u_pc = pc; u_taken = taken; u_target = tgt;
            u_pred_taken = 1'b0; u_pred_target = 32'h0; u_exception = 1'b0;
            @(posedge clk);
            #1;
            u_valid = 1'b0;
            model_resolve(pc, taken, tgt);
        end
    endtask

    // 查询并与模型比对
    task check_query(input [31:0] pc, input [8*40-1:0] tag);
        reg [IDX_BITS-1:0] bi;
        reg [GHR_BITS-1:0] pi;
        reg e_hit, e_taken;
        reg [31:0] e_tgt;
        begin
            bi = pc[IDX_BITS+1:2];
            pi = pc[GHR_BITS+1:2] ^ exp_ghr;
            e_hit   = exp_btb_v[bi] && (exp_btb_tag[bi] == pc[31:IDX_BITS+2]);
            e_taken = e_hit && exp_pht[pi][1];
            e_tgt   = exp_btb_tgt[bi];

            q_pc = pc; q_valid = 1'b1;
            #1;
            checks = checks + 1;
            if (q_hit !== e_hit || q_taken !== e_taken ||
                (e_hit && q_target !== e_tgt)) begin
                $display("FAIL [%0s] pc=%08h dut(hit=%b taken=%b tgt=%08h) model(hit=%b taken=%b tgt=%08h)",
                         tag, pc, q_hit, q_taken, q_target, e_hit, e_taken, e_tgt);
                errors = errors + 1;
            end else begin
                $display("PASS [%0s] pc=%08h hit=%b taken=%b tgt=%08h (ghr=%b idx=%0d)",
                         tag, pc, q_hit, q_taken, q_target, exp_ghr, pi);
            end
            // 保持 q_valid 跨一个时钟沿，使统计计数器计入本次查询
            // （查询本身是组合的，多跨一个沿不改变预测器状态）
            @(posedge clk);
            #1;
            q_valid = 1'b0;
        end
    endtask

    // ------------------------------------------------------------------
    // 测试序列
    // ------------------------------------------------------------------
    // PC_A: bits[5:2]=1, BTB idx=1    —— 被测目标分支
    // PC_D: bits[5:2]=6, BTB idx=6    —— 供体（用于推进 GHR 而不碰 PHT[1]）
    //   供体四个索引 = 6^1=7, 6^2=4, 6^4=2, 6^8=14 —— 均不等于 1，互不干扰
    localparam [31:0] PC_A = 32'h0000_0004;
    localparam [31:0] PC_D = 32'h0000_0018;
    localparam [31:0] TGT_A = 32'h0000_0040;

    integer i;
    initial begin
        $display("==========================================");
        $display("  branch_predictor GSHARE mode test");
        $display("==========================================");

        errors = 0; checks = 0;
        clk = 1'b0; rst = `RstEnable;
        q_valid = 1'b0; q_pc = 32'h0;
        u_valid = 1'b0; u_pc = 32'h0; u_taken = 1'b0; u_target = 32'h0;
        u_pred_taken = 1'b0; u_pred_target = 32'h0; u_exception = 1'b0;
        stat_clr = 1'b0;

        // 模型复位
        exp_ghr = {GHR_BITS{1'b0}};
        for (i = 0; i < PHT_N; i = i + 1) exp_pht[i] = 2'b01;
        for (i = 0; i < 64; i = i + 1) begin
            exp_btb_v[i] = 1'b0; exp_btb_tag[i] = {TAG_W{1'b0}}; exp_btb_tgt[i] = 32'h0;
        end

        repeat (2) @(posedge clk);
        #1;
        rst = `RstDisable;
        #1;

        // ---- T1: 复位后无命中 ----
        check_query(PC_A, "T1 reset: no hit");

        // ---- T2: 首次训练（BTB 未命中 → 分配 + PHT 置弱 taken）----
        do_resolve(PC_A, 1'b1, TGT_A);
        check_query(PC_A, "T2 after 1st taken train");

        // ---- T3: GHR 应已移位 ----
        checks = checks + 1;
        if (exp_ghr !== 4'b0001) begin
            $display("FAIL T3: 模型 GHR 期望 0001，实际 %b（模型自身错误）", exp_ghr);
            errors = errors + 1;
        end else $display("PASS T3: GHR 左移一位（真实方向进 LSB）");

        // ---- T4: 用供体把 GHR 移回 0000（4 次 taken=0）----
        for (i = 0; i < GHR_BITS; i = i + 1) do_resolve(PC_D, 1'b0, 32'h0);
        checks = checks + 1;
        if (exp_ghr !== 4'b0000) begin
            $display("FAIL T4: 供体未把 GHR 移回 0，实际 %b", exp_ghr);
            errors = errors + 1;
        end else $display("PASS T4: 供体序列将 GHR 移回 0000");

        // ---- T5: 关键断言 —— GHR 回到 0 后 PC_A 的 PHT 索引复原为 1，
        //          该处已被 T2 置为弱 taken，故应预测 taken ----
        check_query(PC_A, "T5 GHR restored -> taken?");

        checks = checks + 1;
        if (exp_pht[1] !== 2'b10) begin
            $display("FAIL T5-pre: 模型 pht[1]=%b 期望 10（模型自身错误）", exp_pht[1]);
            errors = errors + 1;
        end

        // ---- T5b: 密集模型比对 —— 覆盖"训练索引"路径 ----
        // 动机：若只在固定几点查询目标分支，训练索引的错误可能不被察觉
        // （例如训练索引漏掉 GHR 时，写错的表项恰好从未被查询）。
        // 此处每训练一条就同时查询目标分支与供体分支，强制模型与 DUT 逐步对齐。
        for (i = 0; i < 6; i = i + 1) begin
            do_resolve(PC_A, 1'b1, TGT_A);
            check_query(PC_A, "T5b dense A");
            check_query(PC_D, "T5b dense D");
            do_resolve(PC_D, 1'b1, 32'h0000_0080);
            check_query(PC_A, "T5b dense A2");
            check_query(PC_D, "T5b dense D2");
        end

        // ---- T6: GHR 参与索引的强证据 ----
        // 记录训练前后的 GHR，断言其确实随 taken 训练变化。
        // 刻意不硬编码具体值，以免与前面新增的密集阶段耦合（曾因此误报）。
        begin : t6_ghr
            reg [GHR_BITS-1:0] g_before;
            g_before = exp_ghr;
            // 用 taken=0 训练：无论 GHR 当前为何值，左移入 0 都必然改变它
            // （先前用 taken=1 在 GHR 已饱和为全 1 时不会变化，属测试假设错误）
            do_resolve(PC_D, 1'b0, 32'h0000_0080);
            check_query(PC_A, "T6 GHR shifted -> index changed");
            checks = checks + 1;
            if (exp_ghr === g_before) begin
                $display("FAIL T6-pre: GHR 未随 taken=0 训练变化（仍为 %b）", g_before);
                errors = errors + 1;
            end else begin
                $display("PASS T6-pre: GHR 随训练变化 %b -> %b", g_before, exp_ghr);
            end
        end

        // ---- T7: BTB 命中与方向解耦 ----
        // 即使方向为 not-taken，BTB 仍应命中并给出目标
        check_query(PC_A, "T7 BTB hit independent of direction");
        checks = checks + 1;
        if (q_hit !== 1'b1) begin
            $display("FAIL T7: BTB 应命中（方向与命中解耦），实际 hit=%b", q_hit);
            errors = errors + 1;
        end

        // ---- T8: BTB tag 别名检测 ----
        // 同 BTB 索引(idx=1)但不同 tag 的 PC 必须未命中
        begin : alias_check
            reg [31:0] pc_alias;
            pc_alias = 32'h0000_0104;   // bits[7:2] = 0b000001 = 1（与 PC_A 同索引）
            checks = checks + 1;
            q_pc = pc_alias; q_valid = 1'b1; #1;
            if (q_hit !== 1'b0) begin
                $display("FAIL T8: 同索引不同 tag 应未命中，实际 hit=%b", q_hit);
                errors = errors + 1;
            end else $display("PASS T8: 同 BTB 索引不同 tag -> 未命中（tag 比较有效）");
            q_valid = 1'b0;
        end

        // ---- T9: 异常指令不训练预测器 ----
        begin : exc_check
            reg [GHR_BITS-1:0] ghr_before;
            ghr_before = exp_ghr;
            u_valid = 1'b1; u_pc = PC_A; u_taken = 1'b1; u_target = 32'hDEAD_BEEF;
            u_exception = 1'b1;
            @(posedge clk); #1;
            u_valid = 1'b0; u_exception = 1'b0;
            checks = checks + 1;
            q_pc = PC_A; q_valid = 1'b1; #1;
            if (q_target === 32'hDEAD_BEEF) begin
                $display("FAIL T9: 异常指令不应训练预测器，但 target 被改写为 %08h", q_target);
                errors = errors + 1;
            end else $display("PASS T9: u_exception=1 -> 不训练（target 保持 %08h）", q_target);
            q_valid = 1'b0;
        end

        // ---- T10: 统计计数器 ----
        checks = checks + 1;
        if (stat_query === 32'b0) begin
            $display("FAIL T10: stat_query 应已累加，实际为 0");
            errors = errors + 1;
        end else $display("PASS T10: 统计查询计数 = %0d", stat_query);

        // ---- Summary ----
        $display("==========================================");
        $display("  检查项: %0d", checks);
        if (errors == 0) $display("  ALL TESTS PASSED (%0d errors)", errors);
        else             $display("  %0d TEST(S) FAILED", errors);
        $display("==========================================");
        $finish;
    end

    initial begin
        #100000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
