// ============================================================================
//        branch_predictor Stage D4：RAS（返回地址栈）验证
//
//        验证要点：
//          T1  复位后 RAS 为空、无命中
//          T2  call 压栈 / ret 弹栈，且为 **LIFO** 顺序
//          T3  "返回"指令的预测目标取自 **RAS 栈顶**，而非 BTB 缓存值
//          T4  空栈时回退到 BTB 缓存目标（不产生 x/悬空）
//          T5  满栈时**丢弃**而非覆盖（避免污染更早的调用点）
//          T6  RAS_ENABLE=0 时完全忽略 RAS（q_target 恒为 BTB 目标）
//
//        对照实现：biriscv-master/src/core/biriscv_npc.v
//                  （btb_is_call_w / btb_is_ret_w 驱动 RAS push/pop）
//
//        为什么"返回目标必须来自 RAS"：同一返回指令被不同调用点调用时，
//        其返回目标不同，BTB 只能缓存其中一个，因此缓存值必然对多数调用点是错的。
// ============================================================================

`timescale 1ns / 1ps

`include "defines.sv"

module tb_predictor_ras;

    localparam IDX_BITS  = 6;
    localparam RAS_DEPTH = 2;      // 小深度以便测试满栈丢弃

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
    reg         u_is_call;
    reg         u_is_ret;
    reg         stat_clr;
    wire [31:0] st_q, st_h, st_m;

    // ---- DUT A：RAS 开启 ----
    branch_predictor #(
        .ENTRIES(64), .IDX_BITS(IDX_BITS), .PRED_MODE(0),
        .RAS_ENABLE(1'b1), .RAS_DEPTH(RAS_DEPTH)
    ) u_ras_on (
        .clk(clk), .rst(rst),
        .q_valid(q_valid), .q_pc(q_pc),
        .q_hit(q_hit), .q_taken(q_taken), .q_target(q_target),
        .u_valid(u_valid), .u_pc(u_pc), .u_taken(u_taken), .u_target(u_target),
        .u_pred_taken(u_pred_taken), .u_pred_target(u_pred_target),
        .u_exception(u_exception), .u_is_call(u_is_call), .u_is_ret(u_is_ret),
        .stat_clr(stat_clr), .stat_query(st_q), .stat_hit(st_h), .stat_mispredict(st_m)
    );

    // ---- DUT B：RAS 关闭（用于 T6 对照）----
    wire        b_hit, b_taken;
    wire [31:0] b_target;
    branch_predictor #(
        .ENTRIES(64), .IDX_BITS(IDX_BITS), .PRED_MODE(0),
        .RAS_ENABLE(1'b0), .RAS_DEPTH(RAS_DEPTH)
    ) u_ras_off (
        .clk(clk), .rst(rst),
        .q_valid(q_valid), .q_pc(q_pc),
        .q_hit(b_hit), .q_taken(b_taken), .q_target(b_target),
        .u_valid(u_valid), .u_pc(u_pc), .u_taken(u_taken), .u_target(u_target),
        .u_pred_taken(u_pred_taken), .u_pred_target(u_pred_target),
        .u_exception(u_exception), .u_is_call(u_is_call), .u_is_ret(u_is_ret),
        .stat_clr(1'b0), .stat_query(), .stat_hit(), .stat_mispredict()
    );

    integer errors;
    integer checks;

    always #5 clk = ~clk;

    task do_resolve(input [31:0] pc, input taken, input [31:0] tgt,
                    input c, input r);
        begin
            u_valid = 1'b1; u_pc = pc; u_taken = taken; u_target = tgt;
            u_pred_taken = 1'b1; u_pred_target = tgt; u_exception = 1'b0;
            u_is_call = c; u_is_ret = r;
            @(posedge clk);
            #1;
            u_valid = 1'b0; u_is_call = 1'b0; u_is_ret = 1'b0;
        end
    endtask

    task expect_target(input [8*46-1:0] tag, input [31:0] got, input [31:0] want);
        begin
            checks = checks + 1;
            if (got !== want) begin
                $display("FAIL [%0s] got=%08h want=%08h", tag, got, want);
                errors = errors + 1;
            end else $display("PASS [%0s] = %08h", tag, got);
        end
    endtask

    // 站点定义
    // 注意：PC 必须选得使 BTB 索引（PC[7:2]）互不相同，否则表项互相覆盖，
    // 测试会把"未命中"误判为"命中但目标错"。以下四个 PC 的 PC[7:2] 分别为
    // 1/2/3/4，PC[31:8] 分别为 0x10/0x20/0x30/0x40，索引与 tag 均不冲突。
    localparam [31:0] PC_C1 = 32'h0000_1004;   // call 点 1 -> 返回地址 1008
    localparam [31:0] PC_C2 = 32'h0000_2008;   // call 点 2 -> 返回地址 200C
    localparam [31:0] PC_C3 = 32'h0000_300C;   // call 点 3（用于满栈测试）-> 3010
    localparam [31:0] PC_R  = 32'h0000_4010;   // return 指令（索引 4）
    localparam [31:0] RA_C1 = 32'h0000_1008;
    localparam [31:0] RA_C2 = 32'h0000_200C;
    localparam [31:0] TGT_R_STALE = 32'hDEAD_BEEF;  // BTB 里缓存的"陈旧"返回目标

    initial begin
        $display("==========================================");
        $display("  branch_predictor RAS test (Stage D4)");
        $display("==========================================");

        errors = 0; checks = 0;
        clk = 1'b0; rst = `RstEnable;
        q_valid = 1'b0; q_pc = 32'h0;
        u_valid = 1'b0; u_pc = 32'h0; u_taken = 1'b0; u_target = 32'h0;
        u_pred_taken = 1'b0; u_pred_target = 32'h0; u_exception = 1'b0;
        u_is_call = 1'b0; u_is_ret = 1'b0; stat_clr = 1'b0;

        repeat (2) @(posedge clk);
        #1;
        rst = `RstDisable;
        #1;

        // ---- T1: 复位后无命中 ----
        q_pc = PC_R; q_valid = 1'b1; #1;
        checks = checks + 1;
        if (q_hit !== 1'b0) begin
            $display("FAIL T1: 复位后不应命中");
            errors = errors + 1;
        end else $display("PASS T1: 复位后 RAS 空、BTB 空 -> 无命中");
        q_valid = 1'b0;

        // ---- T2: 先把返回指令训练进 BTB（is_ret=1），此时 RAS 为空故弹栈无操作 ----
        do_resolve(PC_R, 1'b1, TGT_R_STALE, 1'b0, 1'b1);
        q_pc = PC_R; q_valid = 1'b1; #1;
        checks = checks + 1;
        if (q_hit !== 1'b1) begin
            $display("FAIL T2: 返回指令应 BTB 命中");
            errors = errors + 1;
        end else $display("PASS T2a: 返回指令 BTB 命中");
        expect_target("T2b 空栈 -> 回退 BTB 陈旧目标", q_target, TGT_R_STALE);
        q_valid = 1'b0;

        // ---- T3: 压两次 call，查询返回指令应取 **最近一次调用** 的返回地址（LIFO）----
        // 时序语义（与 biriscv 一致）：**查询时用栈顶预测，解析时才弹栈**。
        do_resolve(PC_C1, 1'b1, 32'h0000_8000, 1'b1, 1'b0);   // 压 RA_C1
        do_resolve(PC_C2, 1'b1, 32'h0000_9000, 1'b1, 1'b0);   // 压 RA_C2（栈顶）
        $display("  [diag T3] ras_cnt=%0d ras_mem[0]=%08h ras_mem[1]=%08h ptr_w=%0d",
                 u_ras_on.ras_cnt, u_ras_on.ras_mem[0], u_ras_on.ras_mem[1],
                 u_ras_on.RAS_PTR_W);
        q_pc = PC_R; q_valid = 1'b1; #1;
        expect_target("T3 RAS 栈顶优先（应为最近调用 RA_C2）", q_target, RA_C2);
        expect_target("T3b 对照(RAS 关)仍用 BTB 陈旧目标", b_target, TGT_R_STALE);
        q_valid = 1'b0;

        // ---- T4: 解析一次 ret -> 弹栈；再查询应得上一层调用点 RA_C1 ----
        do_resolve(PC_R, 1'b1, TGT_R_STALE, 1'b0, 1'b1);      // 弹栈
        q_pc = PC_R; q_valid = 1'b1; #1;
        expect_target("T4 弹栈后栈顶 = RA_C1", q_target, RA_C1);
        q_valid = 1'b0;

        // ---- T5: 再弹一次 -> 栈空 -> 回退 BTB ----
        do_resolve(PC_R, 1'b1, TGT_R_STALE, 1'b0, 1'b1);
        q_pc = PC_R; q_valid = 1'b1; #1;
        expect_target("T5 空栈回退到 BTB 目标", q_target, TGT_R_STALE);
        q_valid = 1'b0;

        // ---- T6: 满栈丢弃（深度 2，压 3 次只保留前 2 次）----
        do_resolve(PC_C1, 1'b1, 32'h0000_8000, 1'b1, 1'b0);   // 压 RA_C1 -> cnt 1
        do_resolve(PC_C2, 1'b1, 32'h0000_9000, 1'b1, 1'b0);   // 压 RA_C2 -> cnt 2（满）
        do_resolve(PC_C3, 1'b1, 32'h0000_A000, 1'b1, 1'b0);   // 满 -> 丢弃 RA_C3
        q_pc = PC_R; q_valid = 1'b1; #1;
        expect_target("T6a 满栈时栈顶仍为 RA_C2", q_target, RA_C2);
        q_valid = 1'b0;

        do_resolve(PC_R, 1'b1, TGT_R_STALE, 1'b0, 1'b1);      // 弹 -> cnt 1
        q_pc = PC_R; q_valid = 1'b1; #1;
        expect_target("T6b 弹一次后 = RA_C1", q_target, RA_C1);
        q_valid = 1'b0;

        do_resolve(PC_R, 1'b1, TGT_R_STALE, 1'b0, 1'b1);      // 弹 -> cnt 0
        q_pc = PC_R; q_valid = 1'b1; #1;
        expect_target("T6c 被丢弃的 RA_C3 从未入栈 -> 回退 BTB", q_target, TGT_R_STALE);
        q_valid = 1'b0;

        // ---- T7: 栈上再加一项，验证 RAS 开/关行为可区分 ----
        do_resolve(PC_C1, 1'b1, 32'h0000_8000, 1'b1, 1'b0);   // 压 RA_C1
        q_pc = PC_R; q_valid = 1'b1; #1;
        expect_target("T7 RAS 开: 取栈顶 RA_C1", q_target, RA_C1);
        expect_target("T7b RAS 关: 恒取 BTB 陈旧目标", b_target, TGT_R_STALE);
        q_valid = 1'b0;

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
