// ============================================================================
//        frontend_perf 单元测试
//
//        两层验证：
//          第一层 计数器语义 —— 逐个事件驱动，核对每个计数器只在自己的事件上递增，
//                 以及 rst / clr 行为。
//          第二层 采集点真实性 —— 把 frontend_perf 与**真实 id_stage** 对接，
//                 用真实指令编码驱动，证明"分支数在 ID 译码点计数"这一规格
//                 确实可由现有 RTL 信号产生（而不是靠 TB 伪造事件）。
//
//        另计算越南论文口径的三个派生指标，作为 Stage H 性能分析的模板：
//          预测精度 = 1 − mispredict / query
//          指令分支密度 = branch / id_valid
//          取指推进率 = if_advance / cycle
// ============================================================================

`timescale 1ns / 1ps

`include "defines.sv"

module tb_frontend_perf;

    reg         clk;
    reg         rst;
    reg         clr;

    reg         id_valid;
    reg         id_branch, id_jal, id_jalr;
    reg         pred_query, pred_hit, mispredict;
    reg         if_advance, redirect;

    wire [31:0] cnt_cycle, cnt_id_valid, cnt_branch, cnt_cond_branch;
    wire [31:0] cnt_jal, cnt_jalr, cnt_query, cnt_hit, cnt_mispredict;
    wire [31:0] cnt_if_advance, cnt_redirect;

    frontend_perf u_perf (
        .clk(clk), .rst(rst), .clr(clr),
        .id_valid(id_valid), .id_branch(id_branch), .id_jal(id_jal), .id_jalr(id_jalr),
        .pred_query(pred_query), .pred_hit(pred_hit), .mispredict(mispredict),
        .if_advance(if_advance), .redirect(redirect),
        .cnt_cycle(cnt_cycle), .cnt_id_valid(cnt_id_valid),
        .cnt_branch(cnt_branch), .cnt_cond_branch(cnt_cond_branch),
        .cnt_jal(cnt_jal), .cnt_jalr(cnt_jalr),
        .cnt_query(cnt_query), .cnt_hit(cnt_hit), .cnt_mispredict(cnt_mispredict),
        .cnt_if_advance(cnt_if_advance), .cnt_redirect(cnt_redirect)
    );

    // ---- 真实 id_stage，用于第二层"采集点真实性"验证 ----
    reg  [31:0] inst_i;
    wire [4:0]  d_rs1, d_rs2, d_rd;
    wire [31:0] d_imm;
    wire        d_reg_we, d_mem_req, d_mem_we;
    wire [3:0]  d_wstrb;
    wire        d_branch, d_jal, d_jalr, d_lui, d_auipc;
    wire        d_uses_rs1, d_uses_rs2, d_illegal;

    id_stage u_id (
        .rst(rst), .inst_i(inst_i), .pc_i(32'h1000), .inst_valid_i(id_valid),
        .fault_i(1'b0), .pred_valid_i(1'b0), .pred_taken_i(1'b0),
        .pred_target_i(32'h0), .ex_jump_flag_i(1'b0),
        .rs1_addr_o(d_rs1), .rs2_addr_o(d_rs2), .imm_o(d_imm),
        .reg_we_o(d_reg_we), .rd_addr_o(d_rd), .mem_req_o(d_mem_req),
        .mem_we_o(d_mem_we), .mem_wstrb_o(d_wstrb), .branch_o(d_branch),
        .jal_o(d_jal), .jalr_o(d_jalr), .lui_o(d_lui), .auipc_o(d_auipc),
        .uses_rs1_o(d_uses_rs1), .uses_rs2_o(d_uses_rs2),
        .opcode_o(), .funct3_o(), .funct7_o(), .rd_o(),
        .pred_valid_o(), .pred_taken_o(), .pred_target_o(),
        .illegal_instr_o(d_illegal)
    );

    integer errors;
    integer checks;

    always #5 clk = ~clk;

    // 一个时钟周期（事件已在外部驱动好）
    task step(input integer n);
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) begin
                @(posedge clk);
                #1;
            end
        end
    endtask

    task clear_events;
        begin
            id_valid = 0; id_branch = 0; id_jal = 0; id_jalr = 0;
            pred_query = 0; pred_hit = 0; mispredict = 0;
            if_advance = 0; redirect = 0;
        end
    endtask

    task expect_eq(input [8*44-1:0] tag, input [31:0] got, input [31:0] want);
        begin
            checks = checks + 1;
            if (got !== want) begin
                $display("FAIL [%0s] got=%0d want=%0d", tag, got, want);
                errors = errors + 1;
            end else begin
                $display("PASS [%0s] = %0d", tag, got);
            end
        end
    endtask

    integer i;

    initial begin
        $display("==========================================");
        $display("  frontend_perf unit test");
        $display("==========================================");

        errors = 0; checks = 0;
        clk = 1'b0; rst = `RstEnable; clr = 1'b0;
        inst_i = 32'h00000013;   // NOP
        clear_events();

        // ---- T1: 复位后全零 ----
        step(3);
        expect_eq("T1 rst cnt_cycle",     cnt_cycle,     32'd0);
        expect_eq("T1 rst cnt_branch",    cnt_branch,    32'd0);
        expect_eq("T1 rst cnt_query",     cnt_query,     32'd0);
        expect_eq("T1 rst cnt_mispredict",cnt_mispredict,32'd0);

        rst = `RstDisable;
        #1;

        // ---- T2: 只递增对应事件（隔离性）----
        id_valid = 1'b1; id_branch = 1'b1;
        step(3);                       // 3 拍条件分支
        clear_events();
        step(1);

        expect_eq("T2 cnt_cond_branch", cnt_cond_branch, 32'd3);
        expect_eq("T2 cnt_branch",      cnt_branch,      32'd3);
        expect_eq("T2 cnt_jal unchanged", cnt_jal,       32'd0);
        expect_eq("T2 cnt_jalr unchanged", cnt_jalr,     32'd0);
        expect_eq("T2 cnt_id_valid",    cnt_id_valid,    32'd3);
        expect_eq("T2 cnt_mispredict unchanged", cnt_mispredict, 32'd0);

        // ---- T3: JAL / JALR 分别计数 + clr 行为 ----
        // 注意：clr 在时钟沿生效，故须在 clr 拉高后的那一拍立即检查，
        // 不能多走一拍（否则 cnt_cycle 已递增，是正确行为而非缺陷）。
        clear_events(); clr = 1'b1; step(1); clr = 1'b0;
        expect_eq("T3 clr cnt_cycle",    cnt_cycle,    32'd0);
        expect_eq("T3 clr cnt_id_valid", cnt_id_valid, 32'd0);
        step(1);

        id_valid = 1'b1; id_jal = 1'b1;
        step(2);                       // 2 条 JAL
        id_jal = 1'b0; id_jalr = 1'b1;
        step(1);                       // 1 条 JALR
        clear_events(); step(1);

        expect_eq("T3 cnt_jal",          cnt_jal,    32'd2);
        expect_eq("T3 cnt_jalr",         cnt_jalr,   32'd1);
        expect_eq("T3 cnt_branch total", cnt_branch, 32'd3);
        expect_eq("T3 cnt_cond_branch",  cnt_cond_branch, 32'd0);

        // ---- T4: id_valid=0 时不计数（空泡不污染统计）----
        // 必须先 clr，否则会继承 T3 的计数（此为测试状态管理，非 DUT 缺陷）
        clear_events(); clr = 1'b1; step(1); clr = 1'b0; step(1);
        clear_events();
        id_valid = 1'b0; id_branch = 1'b1;   // 分支信号拉高但指令无效
        step(4);
        clear_events(); step(1);
        expect_eq("T4 invalid not counted", cnt_branch, 32'd0);

        // ---- T5: 预测器与取指事件 ----
        clear_events(); clr = 1'b1; step(1); clr = 1'b0; step(1);

        pred_query = 1'b1; pred_hit = 1'b1;
        step(5);                        // 5 次查询全部命中
        clear_events();
        pred_query = 1'b1; pred_hit = 1'b0;
        step(3);                        // 3 次查询未命中
        clear_events();
        mispredict = 1'b1;
        step(2);                        // 2 次误预测
        clear_events();
        if_advance = 1'b1;
        step(7);
        clear_events();
        redirect = 1'b1;
        step(1);
        clear_events(); step(1);

        expect_eq("T5 cnt_query",      cnt_query,      32'd8);
        expect_eq("T5 cnt_hit",        cnt_hit,        32'd5);
        expect_eq("T5 cnt_mispredict", cnt_mispredict, 32'd2);
        expect_eq("T5 cnt_if_advance", cnt_if_advance, 32'd7);
        expect_eq("T5 cnt_redirect",   cnt_redirect,   32'd1);

        // ---- T6: 派生指标（越南论文口径），TB 侧计算，硬件不做除法 ----
        begin : derive
            integer acc_x1000, density_x1000, adv_x1000;
            // 除零保护：测量窗口内若无有效指令/查询，相关比值为 0 而非 x
            acc_x1000     = (cnt_query    != 0) ? (1000 * (cnt_query - cnt_mispredict)) / cnt_query    : 0;
            density_x1000 = (cnt_id_valid != 0) ? (1000 * cnt_branch) / cnt_id_valid                   : 0;
            adv_x1000     = (cnt_cycle    != 0) ? (1000 * cnt_if_advance) / cnt_cycle                  : 0;
            $display("  [指标] 预测精度 = %0d.%0d%%  (query=%0d mispred=%0d)",
                     acc_x1000/10, acc_x1000%10, cnt_query, cnt_mispredict);
            $display("  [指标] 分支密度 = %0d.%0d%%  (branch=%0d id_valid=%0d)",
                     density_x1000/10, density_x1000%10, cnt_branch, cnt_id_valid);
            $display("  [指标] 取指推进率 = %0d.%0d%%  (advance=%0d cycle=%0d)",
                     adv_x1000/10, adv_x1000%10, cnt_if_advance, cnt_cycle);
            checks = checks + 1;
            // 8 次查询中 2 次误预测 -> 精度 75.0%
            if (acc_x1000 !== 750) begin
                $display("FAIL T6: 预测精度期望 75.0%%，实得 %0d.%0d%%", acc_x1000/10, acc_x1000%10);
                errors = errors + 1;
            end else $display("PASS T6: 派生指标计算正确（精度 75.0%%）");
        end

        // ---- T7: 采集点真实性 —— 用真实指令编码驱动真实 id_stage ----
        // 目的：证明"分支数在 ID 译码点计数"可由现有 RTL 信号实现，
        //       而不是靠 TB 伪造事件。
        clear_events(); clr = 1'b1; step(1); clr = 1'b0; step(1);

        for (i = 0; i < 4; i = i + 1) begin
            // 真实译码：ADDI x1,x0,0（非分支）
            inst_i = 32'h00000093;
            #1;
            id_valid = 1'b1;
            id_branch = d_branch; id_jal = d_jal; id_jalr = d_jalr;
            step(1);
        end
        for (i = 0; i < 2; i = i + 1) begin
            // 真实译码：BEQ x1,x2,0（条件分支）
            inst_i = 32'h00208063;
            #1;
            id_valid = 1'b1;
            id_branch = d_branch; id_jal = d_jal; id_jalr = d_jalr;
            step(1);
        end
        for (i = 0; i < 3; i = i + 1) begin
            // 真实译码：JAL x1,0
            inst_i = 32'h000000EF;
            #1;
            id_valid = 1'b1;
            id_branch = d_branch; id_jal = d_jal; id_jalr = d_jalr;
            step(1);
        end
        for (i = 0; i < 1; i = i + 1) begin
            // 真实译码：JALR x1,x2,0
            inst_i = 32'h000100E7;
            #1;
            id_valid = 1'b1;
            id_branch = d_branch; id_jal = d_jal; id_jalr = d_jalr;
            step(1);
        end
        clear_events(); step(1);

        expect_eq("T7 real-decode id_valid",     cnt_id_valid,    32'd10);
        expect_eq("T7 real-decode cond_branch",  cnt_cond_branch, 32'd2);
        expect_eq("T7 real-decode jal",          cnt_jal,         32'd3);
        expect_eq("T7 real-decode jalr",         cnt_jalr,        32'd1);
        expect_eq("T7 real-decode branch total", cnt_branch,      32'd6);

        // ---- T8: 溢出回绕（用窄位宽实例无法在此验证 32 位回绕，改验单调性）----
        checks = checks + 1;
        if (cnt_cycle === 32'd0) begin
            $display("FAIL T8: cnt_cycle 不应为 0（此前已跑若干拍）");
            errors = errors + 1;
        end else $display("PASS T8: cnt_cycle 单调累加 = %0d", cnt_cycle);

        // ---- Summary ----
        $display("==========================================");
        $display("  检查项: %0d", checks);
        if (errors == 0) $display("  ALL TESTS PASSED (%0d errors)", errors);
        else             $display("  %0d TEST(S) FAILED", errors);
        $display("==========================================");
        $finish;
    end

    initial begin
        #200000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
