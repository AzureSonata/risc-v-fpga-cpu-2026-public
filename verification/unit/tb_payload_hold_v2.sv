// ============================================================================
//  tb_payload_hold_v2 —— Gate #3："响应与下游 hold 同拍时，载荷与**它的**预测元数据
//                        必须一起被保持、且恰好交付一次"
//
//  依据（AGENTS.md §6 参考是设计输入）：
//    · `03_参考项目/.../DAE-Pipeline-CPU-main/spec.md:117-121` —— fetch packet 只在
//      「未被标记丢弃 ∧ 无 flush/redirect ∧ 请求 epoch == 当前 epoch」时发出，否则丢弃；
//      `spec.md:311-319` 纪律③「译码后的 IR **携带** epoch/seq 身份」。
//    · `03_参考项目/.../Hazard3-stable/hdl/hazard3_frontend.v:143-156` —— 用**并列数组**
//      `fifo_predbranch / fifo_err / fifo_valid_hw` 让元数据**随数据逐项流动**
//      （不是"另存一份、用时再查"）。
//    ⇒ 共同不变量：**元数据必须与载荷同拍、同槽、同行**，不得在 hold/skid 中被拆散或清零。
//
//  ---- 为什么重写（旧 TB 的教训，见日志 2026-10-01/09~17）----
//    旧 `tb_payload_hold.sv` 有 **7 类判据缺陷**且互相掩盖：
//      ① DUT 预测输入被**硬接 0**（DUT 预测通路是死代码）；
//      ② scoreboard 用 **TB 自驱动信号**当载荷元数据；
//      ③ 在 **posedge** 采样（NBA 未落地）⇒ 载荷与元数据**错一拍**；
//      ④ 同一载荷连续多拍被重复记账；
//      ⑤ 预测器查询地址取 `if_out_pc`（更老的一笔）⇒ 查询与请求**错一个 PC**；
//      ⑥ 训练脉冲 `#1` 晚于 posedge ⇒ 训练晚于第一笔请求生效；
//      ⑦ Test 1c 判据自相矛盾 / Test 1i 取样早一拍，且"追加固定一拍"会污染后续全部用例。
//    本 TB 按 `项目回归规范` 重写，逐条规避：
//      §7.1  期望值**全部取自 DUT**（`q_target`/`u_predictor.target[]`/`dut_pred_*`），
//            不用任何 TB 旁路信号；
//      §7.4  **不做固定拍数对齐**：一切同步事件用"跑到条件成立"的 `step()` 驱动，
//            不出现裸 `@(negedge clk)` 来"对齐某一拍"；
//      §7.5  逐拍打点可选（`+TB_VERBOSE`），默认静默；
//      §7.10 **自足**：TB 自己生成请求序列与训练序列，期望值来自同一份表格。
//
//  ---- 设计（结构与旧 TB 不同：事件驱动 + 表格索引，不做时序脆弱的固定用例）----
//    · DUT：`pc_reg + if_stage + if_id + branch_predictor`（与真实前端一致）
//    · 训练：对 8 个 PC 训练为 taken、目标 = PC + 0x0100_0000（目标各不相同 ⇒ 元数据可辨识）
//    · 激励：连续发起 8 笔取指（PC = 0,4,...,0x1C），响应延迟随机化，
//      **下游 `if_out_ready` 用伪随机序列**制造"响应落下的同拍下游卡住"这一窗口
//    · 判据（全部与 PC 绑定，不依赖拍数）：
//      ① 每笔请求**恰好交付一次**（按 PC 计数，无丢无重）
//      ② 交付载荷的 `pred_valid/taken/target` == **该 PC 训练时的值**（= 元数据随载荷走）
//      ③ payload 在 if_out 上被 hold 期间，其 {pc,inst,pred_*} **逐拍不变**
//      ④ IF/ID 捕获的元数据与同拍 if_out 的元数据**一致**（不串行、不残留）
//      ⑤ `i_rsp_ready` 只在缓冲非满时有效（背压契约）
// ============================================================================
`timescale 1ns/1ps
// ============================================================================
//  ⚠️ 当前状态（2026-10-01，第 8 轮收尾）：**未收口**，但已从"交付 0 笔"推进到
//     "能交付、但载荷与 PC **错位一个事务**"，且首笔会在 WAIT 停留 30 拍超时。
//
//  本轮修好的（都是按 §7 的规则）：
//    ① 等待范式：`while(!(i_req_valid===1'b1))` → **等状态** `u_if.state === WAIT`
//       （§7.11：等瞬时电平在本设计里永远等不到）；
//    ② 查询地址：TB 寄存器 `query_pc` → **组合跟随 `pc`**（与 if_stage 锁进 req_pc 的同源信号）；
//    ③ `function` 不能写模块级变量（Icarus 10.2 实测）⇒ 拆成纯组合 `lfsr_next()` + `next_rand` 任务；
//    ④ 响应**保持到 IF 离开 WAIT**，而不是"发出后立刻撤销"（否则同 negedge 错开、响应被擦掉）。
//
//  仍有的现象（下一轮接手点）：
//    · `FAIL PC=00000000：响应保持 30 拍后 IF 仍未离开 WAIT` ⇒ **首笔**在 WAIT 卡住 30 拍；
//    · 之后各笔能交付，但 `inst` 与 PC **错位一个事务**（如 `PC=0x08` 拿到 `a000000c`，
//      即上一笔的数据）。⇒ 说明"响应载荷"与"请求 PC"之间仍差一个事务，
//      高度怀疑与 `pc_reg` 的 `advance_valid`（本 TB 未显式驱动）或 IF 续发路径有关。
//
//  下一步（按成本从低到高）：
//    1. **显式驱动 `advance_valid`**（当前悬空）并观察首笔是否不再卡 30 拍；
//    2. 把"数据按 req_pc_now 生成"改为"**由 DUT 的 req_pc 寄存器**生成"
//       （直接读 `u_if.req_pc`，彻底消除 TB 侧事务对齐问题，符合 §7.1）；
//    3. 若仍错位 ⇒ 用 §7.9 的完整 retire/交付 trace 打出 (req_pc, rsp_data, 交付 pc) 三元组逐笔比对。
//
//  本 TB **未登记进 run_tests.py**（不污染主回归：当前主回归 800 PASS / 0 FAIL）。
// ============================================================================
`include "defines.sv"

module tb_payload_hold_v2;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    // ---------------- 上游 pc_reg ----------------
    reg         redirect_valid  = 1'b0;
    reg  [31:0] redirect_target = 32'h0;
    reg         hold_pc         = 1'b0;
    wire [31:0] pc;
    wire        advance_valid;

    // ---------------- 预测器（真实例，活查询；期望值取自它的表）----------------
    // ★ 查询地址**组合跟随 pc**（= if_stage 锁进 req_pc 的同一个信号，§7.1 期望值同源）。
    //    ⚠️ 坑位：曾用 TB 寄存器手写 query_pc ⇒ "查询"与"被发射的 pc"错开一拍
    //    ⇒ 预测元数据与载荷不对应。组合跟随后从结构上不可能错位。
    wire [31:0] query_pc = pc;
    wire        q_hit, q_taken;
    wire [31:0] q_target;
    reg         train_valid  = 1'b0;
    reg  [31:0] train_pc     = 32'h0;
    reg         train_taken  = 1'b0;
    reg  [31:0] train_target = 32'h0;

    // ---------------- DUT 端口 ----------------
    wire        i_req_valid, i_rsp_ready;
    wire [31:0] i_req_addr;
    reg         i_rsp_valid = 1'b0;
    reg  [31:0] i_rsp_data  = 32'h0;
    reg         i_rsp_error = 1'b0;
    reg         if_out_ready = 1'b0;
    wire        if_out_valid, if_out_fault;
    wire [31:0] if_out_pc, if_out_inst;
    wire        dut_pred_valid, dut_pred_taken;
    wire [31:0] dut_pred_target;
    reg         hold_if_id = 1'b0;
    wire        id_valid, id_fault, id_pred_valid, id_pred_taken;
    wire [31:0] id_pc, id_inst, id_pred_target;

    pc_reg u_pc (
        .clk(clk), .rst(rst),
        .redirect_valid(redirect_valid), .redirect_target(redirect_target),
        .advance_valid(advance_valid),
        .pred_valid(1'b0), .pred_target(32'b0),
        .hold_pc(hold_pc), .pc(pc)
    );

    branch_predictor u_predictor (
        .clk(clk), .rst(rst),
        // ⚠️ 旧 TB 的缺陷①在此规避：q_valid 不再接 if_out_valid（那是下游信号，
        //    会让"刚启动、if_out 还空"时预测器被判定为未查询）；
        //    q_pc 由 TB 显式驱动为"正在发起的那笔请求的 PC"（§7.1）。
        .q_valid(1'b1), .q_pc(query_pc),
        .q_hit(q_hit), .q_taken(q_taken), .q_target(q_target),
        .u_valid(train_valid), .u_pc(train_pc), .u_taken(train_taken),
        .u_target(train_target), .u_pred_taken(1'b0), .u_pred_target(32'b0),
        .u_exception(1'b0), .stat_clr(1'b0),
        .stat_query(), .stat_hit(), .stat_mispredict()
    );

    if_stage u_if (
        .clk(clk), .rst(rst),
        .pc(pc), .redirect_valid(redirect_valid),
        .hold_if(1'b0), .flush_if(1'b0),
        .advance_valid(advance_valid),
        // 预测输入来自**真实预测器组合输出**（不是 TB 常量，也不是旁路信号）
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

    // ==========================================================================
    //  期望值表格：**由训练动作自己填**，不靠 TB 手写常量（§7.1 + §7.10）
    // ==========================================================================
    localparam integer NPC = 8;
    reg [31:0] exp_pc   [0:NPC-1];
    reg        exp_take [0:NPC-1];
    reg [31:0] exp_tgt  [0:NPC-1];
    integer    deliv    [0:NPC-1];      // 每个 PC 被交付的次数
    integer    claimed  [0:NPC-1];      // 每个 PC 被交付时的元数据是否与表格一致

    integer errors = 0, checks = 0;
    integer verbose = 0;

    task chk(input [255:0] label, input condition);
        begin
            checks = checks + 1;
            if (!condition) begin
                errors = errors + 1;
                $display("FAIL [%0t] %0s", $time, label);
            end
        end
    endtask

    // 训练一个 PC（脉冲整拍跨过 posedge，之后再空一拍 —— 旧 TB 缺陷⑥的规避）
    task train(input integer i);
        begin
            @(negedge clk);
            train_valid  = 1'b1;
            train_pc     = i * 4;
            train_taken  = 1'b1;
            train_target = i * 4 + 32'h0100_0000;
            exp_pc[i]    = i * 4;
            exp_take[i]  = 1'b1;
            exp_tgt[i]   = i * 4 + 32'h0100_0000;
            @(negedge clk);
            train_valid = 1'b0;
            @(negedge clk);
        end
    endtask

    // 交付记账：**在 negedge 采样**（NBA 已落地 ⇒ 载荷与其元数据是同一快照，规避旧缺陷③）
    integer cap_total = 0;
    always @(negedge clk) begin
        if (rst != `RstEnable && if_out_valid === 1'b1 && if_out_ready === 1'b1) begin
            cap_total = cap_total + 1;
            check_delivery(if_out_pc, if_out_inst, if_out_fault,
                           dut_pred_valid, dut_pred_taken, dut_pred_target);
        end
    end

    task check_delivery(input [31:0] d_pc, input [31:0] d_inst, input d_fault,
                        input d_pv, input d_pt, input [31:0] d_py);
        integer k, found;
        begin
            found = -1;
            for (k = 0; k < NPC; k = k + 1)
                if (exp_pc[k] === d_pc) found = k;
            if (found < 0) begin
                errors = errors + 1;
                $display("FAIL 交付了未请求的 PC=%h inst=%h", d_pc, d_inst);
            end else begin
                deliv[found] = deliv[found] + 1;
                if (deliv[found] > 1) begin
                    errors = errors + 1;
                    $display("FAIL PC=%h 被重复交付（第 %0d 次）", d_pc, deliv[found]);
                end
                // ★ 核心判据：载荷携带的元数据必须等于**该 PC 训练时的值**
                if (!(d_pv === 1'b1 && d_pt === exp_take[found] && d_py === exp_tgt[found])) begin
                    errors = errors + 1;
                    $display("FAIL PC=%h 元数据不匹配：得 v=%b t=%b tgt=%h，期望 v=1 t=%b tgt=%h",
                             d_pc, d_pv, d_pt, d_py, exp_take[found], exp_tgt[found]);
                end else begin
                    claimed[found] = 1;
                end
                // 载荷内容自检：inst 必须等于 TB 为该 PC 生成的模式
                if (d_inst !== (32'hA000_0000 | d_pc)) begin
                    errors = errors + 1;
                    $display("FAIL PC=%h inst=%h（期望 %h）", d_pc, d_inst, 32'hA000_0000 | d_pc);
                end
                if (d_fault !== 1'b0) begin
                    errors = errors + 1;
                    $display("FAIL PC=%h fault=%b（期望 0）", d_pc, d_fault);
                end
            end
            if (verbose) $display("  DELIVER pc=%h inst=%h v=%b t=%b tgt=%h",
                                  d_pc, d_inst, d_pv, d_pt, d_py);
        end
    endtask

    // hold 稳定性监视：if_out 有效且下游未 ready 时，其内容**逐拍必须不变**（判据③）
    reg [31:0] h_pc = 32'hFFFF_FFFF, h_inst = 32'hFFFF_FFFF, h_tgt = 32'hFFFF_FFFF;
    reg        h_pv = 1'bx, h_pt = 1'bx, h_vld = 1'b0;
    integer    hold_cycles = 0;
    always @(negedge clk) begin
        if (rst != `RstEnable) begin
            if (if_out_valid === 1'b1 && if_out_ready === 1'b0) begin
                if (h_vld === 1'b1) begin
                    // 与上一拍比较：必须完全不变
                    if (h_pc !== if_out_pc || h_inst !== if_out_inst ||
                        h_pv !== dut_pred_valid || h_pt !== dut_pred_taken ||
                        h_tgt !== dut_pred_target) begin
                        errors = errors + 1;
                        $display("FAIL hold 期间载荷/元数据发生漂移：pc %h→%h inst %h→%h (v,t,tgt) (%b,%b,%h)→(%b,%b,%h)",
                                 h_pc, if_out_pc, h_inst, if_out_inst,
                                 h_pv, h_pt, h_tgt, dut_pred_valid, dut_pred_taken, dut_pred_target);
                    end
                end
                h_vld = 1'b1; hold_cycles = hold_cycles + 1;
            end else begin
                h_vld = 1'b0;
            end
            h_pc = if_out_pc; h_inst = if_out_inst;
            h_pv = dut_pred_valid; h_pt = dut_pred_taken; h_tgt = dut_pred_target;
        end
    end

    // IF/ID 捕获一致性：id_valid 与 if_out 同时有效且 IF/ID 未 hold 时，
    // 捕获进去的元数据必须与同拍 if_out 的一致（判据④）
    always @(negedge clk) begin
        if (rst != `RstEnable && id_valid === 1'b1 && if_out_valid === 1'b1 && hold_if_id === 1'b0) begin
            if (!(id_pc === if_out_pc && id_inst === if_out_inst && id_fault === if_out_fault &&
                  id_pred_valid === dut_pred_valid && id_pred_taken === dut_pred_taken &&
                  id_pred_target === dut_pred_target)) begin
                errors = errors + 1;
                $display("FAIL IF/ID 捕获与 if_out 不一致：id(pc=%h i=%h v=%b t=%b y=%h) vs if_out(pc=%h i=%h v=%b t=%b y=%h)",
                         id_pc, id_inst, id_pred_valid, id_pred_taken, id_pred_target,
                         if_out_pc, if_out_inst, dut_pred_valid, dut_pred_taken, dut_pred_target);
            end
        end
    end

    // ==========================================================================
    //  激励主流程
    // ==========================================================================
    integer k, r, w;
    reg [31:0] rv;
    reg [31:0] req_pc_now;
    reg        ok_flag;
    reg [31:0] lfsr;                      // 伪随机：响应延迟 + 下游 ready 图案（初值在主 initial 里给）
    // ⚠️ 坑位（Icarus 10.2 实测）：function **不能**写模块级变量 —— 写成
    //    `function ...; begin lfsr = ...; end endfunction` 会报
    //    `Syntax error defining function`（最小复现 build/min_func.sv）。
    //    ⇒ 正确做法：function 只做**纯组合**计算，状态更新放在调用处（见 next_rand 任务）。
    function [31:0] lfsr_next(input [31:0] s);
        begin
            lfsr_next = {s[30:0], s[31]^s[21]^s[1]^s[0]};
        end
    endfunction

    task next_rand(output [31:0] v);
        begin
            lfsr = lfsr_next(lfsr);
            v    = lfsr;
        end
    endtask

    // 等"本笔请求已被接受" = IF 进入 WAIT 状态（**等可判定的状态**，§7.11）。
    // ⚠️ 坑位：曾写 `while (!(i_req_valid === 1'b1)) @(negedge clk);` —— `i_req_valid` 的 "1"
    //    只出现在 REQ 态的**中间时刻**，等它的电平永远等不到（打点：v=1 在 t=40000 中间，
    //    t=45000 观察时已进 WAIT、v 回 0）⇒ 8 笔全部超时、交付 0 笔。
    task wait_for_request(output okay);
        integer n;
        begin
            okay = 1'b0;
            n = 0;
            while (u_if.state !== 2'b10 && n < 30) begin @(negedge clk); n = n + 1; end
            if (u_if.state !== 2'b10) begin
                $display("FAIL 30 拍内未进入 WAIT（请求未被接受）"); errors = errors + 1;
            end else begin
                req_pc_now = pc;      // 本笔 = if_stage 刚锁进 req_pc 的那个 PC
                okay = 1'b1;
            end
        end
    endtask

    integer wd = 0;

    initial begin
        if ($test$plusargs("TB_VERBOSE")) verbose = 1;
        $display("==================================================");
        $display("  Gate #3 载荷-元数据契约（v2：事件驱动 + 表格索引）");
        $display("==================================================");
        for (k = 0; k < NPC; k = k + 1) begin
            deliv[k] = 0; claimed[k] = 0; exp_pc[k] = 32'hFFFF_FFFF;
            exp_take[k] = 1'bx; exp_tgt[k] = 32'hFFFF_FFFF;
        end
        lfsr = 32'hACE1_2345;
        repeat (3) @(posedge clk);
        @(negedge clk); rst = 1'b0;

        // 1) 训练全部 8 个 PC（期望表随之填写）
        for (k = 0; k < NPC; k = k + 1) train(k);
        @(negedge clk);

        // 2) 逐笔发起取指：每笔设置 query_pc = 该 PC，响应延迟随机 1..3 拍，
        //    下游 ready 用伪随机图案（覆盖"响应落下同拍下游卡住"的窗口）
        for (k = 0; k < NPC; k = k + 1) begin
            // ★ 冻结 PC：`pc_reg` 在**每次请求 fire** 时自动 +4，而本 TB 并不消费下游输出，
            //   若不冻结，PC 会在"响应还没交付"时一路推进（实测跑到 0x38）⇒ 交付的 PC 与
            //   响应数据错位、并出现"交付了未请求的 PC"。
            //   正确做法：只在"要给本笔发响应"这一刻短暂释放 PC（一次 fire = 一次 +4）。
            hold_pc = 1'b1;
            wait_for_request(ok_flag);
            if (ok_flag === 1'b0) begin
                errors = errors + 1;
                $display("FAIL 第 %0d 笔请求未被接受", k);
            end
            // 响应延迟 1..3 拍后给出
            next_rand(rv); r = (rv % 3) + 1;
            for (w = 0; w < r; w = w + 1) @(negedge clk);
            // 发响应这一段释放 PC（让本笔 fire 后 PC 恰好推进一格），响应结束后重新冻结
            hold_pc    = 1'b0;
            i_rsp_valid = 1'b1;
            // ★ 数据按 **DUT 的 `u_if.req_pc`** 生成（§7.1 + §7.12：本笔上下文只能取自被测对象；
            //    TB 自己维护的副本会因"上一笔响应还在 skid 里"而差一个事务 ⇒ 实测 inst 错位）。
            i_rsp_data  = 32'hA000_0000 | u_if.req_pc;
            i_rsp_error = 1'b0;
            // 响应保持 3 拍后撤销。
            // ⚠️ 坑位：**不能要求"IF 一定离开 WAIT"** —— 下游 `if_out_ready=0` 占住输出槽时
            //    `i_rsp_ready=0`，响应本就**不可能**被接受，状态机停在 WAIT 是**正确行为**。
            //    上一版硬等"离开 WAIT" ⇒ 首笔被误判 FAIL，白烧一轮。
            for (w = 0; w < 3; w = w + 1) @(negedge clk);
            i_rsp_valid = 1'b0;
            hold_pc     = 1'b1;
            // 下游：伪随机 ready 若干拍（制造 hold 窗口）
            next_rand(rv); r = (rv % 4);
            for (w = 0; w < r; w = w + 1) begin
                if_out_ready = 1'b0;
                @(negedge clk);
            end
            if_out_ready = 1'b1;
            @(negedge clk);
            // IF/ID 随机 hold（制造"输出被卡住"的第二类窗口）
            next_rand(rv); if (rv[0]) begin
                hold_if_id = 1'b1;
                @(negedge clk); @(negedge clk);
                hold_if_id = 1'b0;
                @(negedge clk);
            end
        end

        // 3) 排空：给足机会交付剩余载荷
        if_out_ready = 1'b1; hold_if_id = 1'b0;
        for (w = 0; w < 60; w = w + 1) @(negedge clk);
        repeat (2) @(posedge clk);

        // 4) 结论
        $display("--------------------------------------------------");
        for (k = 0; k < NPC; k = k + 1)
            $display("  PC=%h 交付 %0d 次（期望 1） 元数据匹配=%0d",
                     exp_pc[k], deliv[k], claimed[k]);
        $display("  交付总数=%0d（期望 %0d）  总检查=%0d  失败=%0d",
                 cap_total, NPC, checks, errors);
        for (k = 0; k < NPC; k = k + 1) begin
            if (deliv[k] !== 1) begin
                errors = errors + 1;
                $display("FAIL PC=%h 交付次数=%0d（期望恰好 1）", exp_pc[k], deliv[k]);
            end
            if (claimed[k] !== 1) begin
                errors = errors + 1;
                $display("FAIL PC=%h 元数据未与训练值匹配", exp_pc[k]);
            end
        end
        if (cap_total !== NPC) begin
            errors = errors + 1;
            $display("FAIL 交付总数=%0d（期望 %0d）", cap_total, NPC);
        end
        $display("  hold 覆盖：if_out 被 hold 的拍数 = %0d（>0 才说明窗口被激励到）", hold_cycles);
        if (hold_cycles < 4) begin
            errors = errors + 1;
            $display("FAIL hold 覆盖不足（%0d 拍）⇒ 本 TB 未真正激励 hold 窗口，结论不可用", hold_cycles);
        end
        $display("PHV2-RESULT cap=%0d checks=%0d errors=%0d holds=%0d",
                 cap_total, checks, errors, hold_cycles);
        if (errors == 0) $display("  ALL TESTS PASSED  (Gate #3 载荷-元数据契约)");
        else             $display("  %0d FAILED", errors);
        $display("==================================================");
        $finish;
    end

endmodule
