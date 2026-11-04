// ============================================================================
//  tb_payload_hold_min —— Gate #3 的**最小骨架**（§7.11 末条：先 1 笔跑通再扩展）
//
//  只做一件事：**冻结 PC → 一笔请求 → 一笔响应 → 载荷与它自己的预测元数据一起到 IF/ID**。
//  不做多笔、不做随机、不做 hold 注入。跑通后再逐步加（hold 注入 → 多笔）。
//
//  为什么另开极简 TB：`tb_payload_hold_v2.sv` 一次性写了 8 笔随机激励，
//  5 轮无法分层定位（PC 会自动 +4、输出不被消费导致 PC 跑飞）。先证明单笔对。
//
// ============================================================================
//  ⚠️ 当前状态（2026-10-01 第 9 轮）：**分层结果已拿到，元数据那一层仍有问题**
// ============================================================================
//  已验证**通过**（这些 PASS 就是"分层"的价值）：
//    · BTB 训练后命中：`q_pc=0 q_hit=1 q_taken=1 q_target=01000000`（期望值取自预测器组合输出，§7.1）；
//    · 请求被接受且 `u_if.req_pc == CpuResetAddr`（PC 冻结 ⇒ 请求 PC 确定，不依赖 TB 副本）；
//    · 响应被接受（`i_rsp_ready=1`）；
//    · **IF 输出载荷正确**（`if_out_pc == req_pc`、`if_out_inst == 响应数据`）。
//
//  仍 FAIL（**下一轮的唯一焦点**）：
//    · `u_if.req_pred_valid` 锁到 **0**（而同一拍 `q_hit=1`）⇒ **预测元数据没被锁进 req_* 标签**；
//    · 因此 IF 输出与 IF/ID 的元数据也都为 0；
//    · 另有一条"响应后 IF 离开 WAIT"的断言在 negedge 采样属**假失败**（本设计里 IF 会立刻
//      再去取下一笔，采样点看到的是新一笔的 WAIT）——下一轮应改为"看 `advance_valid` 是否发生过"
//      或直接删掉该条（它是过程观察，不是契约）。
//
//  ★ 第 9 轮追加实证（逐拍打点，见下方常开的 M 打点）：
//      `t=40000 st=01(REQ) fire=1 q_hit=0`  →  `t=50000 st=10(WAIT) q_hit=1 tgt=01000000`
//    即"**请求被接受的那一拍，BTB 组合输出还是 0，下一拍才是 1**"。
//    曾试图用"查询地址提前一拍（pc+4）"规避 —— **无效**（t=40000 仍是 0），
//    说明不是"查得晚"，而是**预测器输出本身存在首拍未生效**的时序（或 `pc` 在那一拍尚未稳定）。
//    ⇒ 下一轮应从这条切入：对 `pc` / `pc_next` / `q_hit` **逐拍同时打点**，
//      确认 t=40000 那一拍被测的 pc 到底是什么；再对照 `cpu_core_stage1.sv` 里
//      `if_stage` 的预测输入真实接线（真实顶层可能接了**流水化**的预测输出）。
//
//  下一步（已收窄到一点）：核对 `if_stage` 在 `STATE_IDLE` 接受请求时锁存的 `req_pred_*`
//  与**同一拍**的 `pred_hit_i/pred_taken_i/pred_target_i`。BTB 组合输出已证明为 1，
//  故嫌疑在：①锁存发生的**拍**与 TB 观测的拍不同（`state` 由 IDLE→REQ 的那一拍）；
//  ②`pred_hit_i` 等输入在 `if_stage` 例化处的接线（对照 `cpu_core_stage1.sv` 的真实接线）。
//  ⇒ 建议下一轮：在 TB 里对 `req_pred_valid` 与 `q_hit` **逐拍同时打点**（§7.5），
//    定位到具体是哪一拍锁的、那一拍 `q_hit` 是多少。
// ============================================================================
`timescale 1ns/1ps
`include "defines.sv"

module tb_payload_hold_min;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    // pc_reg：★ hold_pc 常置 1，PC 全程冻结在 `CpuResetAddr`（0），
    // 这样"请求的 PC"是确定的，不依赖任何 TB 侧的 PC 副本。
    reg         hold_pc = 1'b1;
    wire [31:0] pc;
    wire        advance_valid;

    // 预测器：★ 查询地址**提前一拍**给出（pc + 4）。
    //    ⚠️ 关键实证（逐拍打点）：`if_stage` 在**接受请求的那一拍**锁存 `req_pred_*`，
    //    而 BTB 的组合输出要到**下一拍**才有效——
    //      `t=40000 st=REQ fire=1 q_hit=0` → `t=50000 st=WAIT q_hit=1 tgt=01000000`
    //    ⇒ 若查询地址就等于 `pc`，接受那一拍锁到的是 0（元数据恒 0）。
    //    真实系统靠"PC 先呈现、下一拍才 fire"的节拍把这一拍藏起来；
    //    本骨架冻结了 PC，故必须**显式预取**下一拍的 PC。
    //    （这也解释了为何 `req_pred_valid` 一直为 0 而 `q_hit` 明明为 1。）
    wire [31:0] pc_next = pc + 32'd4;
    wire        q_hit, q_taken;
    wire [31:0] q_target;
    reg         train_valid  = 1'b0;
    reg  [31:0] train_pc     = 32'h0;
    reg         train_taken  = 1'b0;
    reg  [31:0] train_target = 32'h0;

    wire        i_req_valid, i_rsp_ready;
    wire [31:0] i_req_addr;
    reg         i_rsp_valid = 1'b0;
    reg  [31:0] i_rsp_data  = 32'h0;
    reg         i_rsp_error = 1'b0;
    reg         if_out_ready = 1'b1;      // 最小骨架：下游恒可接收
    wire        if_out_valid, if_out_fault;
    wire [31:0] if_out_pc, if_out_inst;
    wire        dut_pred_valid, dut_pred_taken;
    wire [31:0] dut_pred_target;
    reg         hold_if_id = 1'b0;
    wire        id_valid, id_fault, id_pred_valid, id_pred_taken;
    wire [31:0] id_pc, id_inst, id_pred_target;

    pc_reg u_pc (
        .clk(clk), .rst(rst),
        .redirect_valid(1'b0), .redirect_target(32'h0),
        .advance_valid(advance_valid),
        .pred_valid(1'b0), .pred_target(32'b0),
        .hold_pc(hold_pc), .pc(pc)
    );

    branch_predictor u_predictor (
        .clk(clk), .rst(rst),
        .q_valid(1'b1), .q_pc(pc),
        .q_hit(q_hit), .q_taken(q_taken), .q_target(q_target),
        .u_valid(train_valid), .u_pc(train_pc), .u_taken(train_taken),
        .u_target(train_target), .u_pred_taken(1'b0), .u_pred_target(32'b0),
        .u_exception(1'b0), .stat_clr(1'b0),
        .stat_query(), .stat_hit(), .stat_mispredict()
    );

    if_stage u_if (
        .clk(clk), .rst(rst),
        .pc(pc), .redirect_valid(1'b0),
        .hold_if(1'b0), .flush_if(1'b0),
        .advance_valid(advance_valid),
        .pred_hit_i(q_hit), .pred_taken_i(q_taken), .pred_target_i(q_target),
        .i_req_valid(i_req_valid), .i_req_ready(1'b1), .i_req_addr(i_req_addr),
        .i_rsp_valid(i_rsp_valid), .i_rsp_ready(i_rsp_ready),
        .i_rsp_data(i_rsp_data), .i_rsp_error(i_rsp_error),
        .if_out_valid(if_out_valid), .if_out_ready(if_out_ready),
        .if_out_pc(if_out_pc), .if_out_inst(if_out_inst), .if_out_fault(if_out_fault),
        .if_out_pred_valid(dut_pred_valid), .if_out_pred_taken(dut_pred_taken),
        .if_out_pred_target(dut_pred_target)
    );

    if_id u_if_id (
        .clk(clk), .rst(rst),
        .if_valid_i(if_out_valid), .if_pc_i(if_out_pc),
        .if_inst_i(if_out_inst), .if_fault_i(if_out_fault),
        .if_pred_valid_i(dut_pred_valid), .if_pred_taken_i(dut_pred_taken),
        .if_pred_target_i(dut_pred_target),
        .hold_if_id(hold_if_id), .flush_if_id(1'b0),
        .id_valid_o(id_valid), .id_pc_o(id_pc), .id_inst_o(id_inst), .id_fault_o(id_fault),
        .id_pred_valid_o(id_pred_valid), .id_pred_taken_o(id_pred_taken),
        .id_pred_target_o(id_pred_target)
    );

    integer errors = 0, checks = 0;
    localparam [31:0] EXP_PC   = `CpuResetAddr;          // PC 冻结在此
    localparam [31:0] EXP_TAKE = 1'b1;
    localparam [31:0] EXP_TGT  = `CpuResetAddr + 32'h0100_0000;
    localparam [31:0] RSP_DATA = 32'hA000_0000 | `CpuResetAddr;

    task chk(input [255:0] label, input cond);
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                $display("FAIL %0s  (t=%0t)", label, $time);
            end else begin
                $display("PASS %0s", label);
            end
        end
    endtask

    task train1(input [31:0] a);
        begin
            @(negedge clk);
            train_valid = 1'b1; train_pc = a; train_taken = 1'b1;
            train_target = a + 32'h0100_0000;
            @(negedge clk);
            train_valid = 1'b0;
            @(negedge clk);
        end
    endtask

    integer w;
    // ---- 逐拍打点（§7.5；定位 req_pred_* 为何锁到 0；定位后移除）----
    always @(negedge clk)
        $display("M t=%0t st=%b pc=%h fire=%b q_hit=%b q_tk=%b q_tgt=%h | reqPC=%h reqV=%b reqT=%b reqY=%h | outv=%b oV=%b | bp valid0=%b tag0=%h tgt0=%h",
            $time, u_if.state, pc, advance_valid, q_hit, q_taken, q_target,
            u_if.req_pc, u_if.req_pred_valid, u_if.req_pred_taken, u_if.req_pred_target,
            if_out_valid, dut_pred_valid,
            u_predictor.valid[0], u_predictor.tag[0], u_predictor.target[0]);

    integer wd = 0;
    always @(posedge clk) if (!rst) begin
        wd = wd + 1;
        if (wd > 2000) begin
            $display("*** TIMEOUT *** st=%b outv=%b idv=%b", u_if.state, if_out_valid, id_valid);
            $display("MIN-RESULT TIMEOUT errors=%0d", errors);
            $finish;
        end
    end

    initial begin
        $display("==================================================");
        $display("  Gate #3 最小骨架：1 笔请求 → 1 笔交付（PC 冻结）");
        $display("==================================================");
        repeat (3) @(posedge clk);
        @(negedge clk); rst = 1'b0;

        // 1) 训练 PC
        train1(EXP_PC);
        // ★★ 关键：等 BTB **真的命中**再放行请求。
        //    ⚠️ 坑位（本轮根因）：`train1` 的写在 t=40000 那个 posedge 才生效，
        //    而 `if_stage` 在**同一个 posedge** 就 fire 了首个请求 ⇒ 竞态，
        //    `req_pred_*` 锁到的是**写之前**的 `q_hit=0`（实证：`valid0` 在 t=45000 才变 1，
        //    而 fire 已在 t=40000 发生）⇒ 元数据恒 0，此前一路误判成"元数据通路坏了"。
        //    正确做法：**先确认预测器已就绪**（组合输出 `q_hit=1`）再发起请求。
        w = 0;
        while (q_hit !== 1'b1 && w < 20) begin @(negedge clk); w = w + 1; end
        chk("BTB 已就绪（q_hit=1）后才发起请求", q_hit === 1'b1);
        $display("BTB 自检：q_pc=%h q_hit=%b q_taken=%b q_target=%h（期望 hit=1 taken=1 tgt=%h）",
                 pc, q_hit, q_taken, q_target, EXP_TGT);
        chk("BTB 训练后命中且方向=taken（期望值取自预测器组合输出）",
            q_hit === 1'b1 && q_taken === 1'b1 && q_target === EXP_TGT);

        // 2) 等"进入 WAIT"（等状态，§7.11）
        w = 0;
        while (u_if.state !== 2'b10 && w < 30) begin @(negedge clk); w = w + 1; end
        chk("请求被接受（IF 进入 WAIT）", u_if.state === 2'b10);
        chk("请求 PC == CpuResetAddr", u_if.req_pc === EXP_PC);
        chk("req 预测标签已锁存（valid/taken/target）",
            u_if.req_pred_valid === 1'b1 && u_if.req_pred_taken === EXP_TAKE &&
            u_if.req_pred_target === EXP_TGT);

        // 3) 发响应（数据取自 DUT 的 req_pc，§7.12）
        i_rsp_valid = 1'b1;
        i_rsp_data  = 32'hA000_0000 | u_if.req_pc;
        i_rsp_error = 1'b0;
        @(negedge clk);
        chk("响应被接受（i_rsp_ready=1）", i_rsp_ready === 1'b1);
        i_rsp_valid = 1'b0;
        @(negedge clk);
        chk("响应后 IF 离开 WAIT", u_if.state !== 2'b10);

        // 4) 载荷应出现在 IF 输出，并携带**它自己的**元数据
        @(negedge clk);
        chk("IF 输出载荷（pc/inst）", if_out_pc === EXP_PC && if_out_inst === RSP_DATA);
        chk("IF 输出元数据随载荷（v/t/tgt）",
            dut_pred_valid === 1'b1 && dut_pred_taken === EXP_TAKE &&
            dut_pred_target === EXP_TGT);

        // 5) IF/ID 捕获
        repeat (2) @(negedge clk);
        chk("IF/ID 捕获载荷与元数据",
            id_valid === 1'b1 && id_pc === EXP_PC && id_inst === RSP_DATA &&
            id_pred_valid === 1'b1 && id_pred_taken === EXP_TAKE &&
            id_pred_target === EXP_TGT);

        $display("--------------------------------------------------");
        $display("  检查项=%0d 失败=%0d", checks, errors);
        $display("MIN-RESULT checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("  ALL TESTS PASSED  (Gate #3 最小骨架)");
        else             $display("  %0d FAILED", errors);
        $display("==================================================");
        $finish;
    end

endmodule
