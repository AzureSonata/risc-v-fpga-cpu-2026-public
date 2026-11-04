// ============================================================================
//  tb_pred_payload_stream —— Gate #3 的**载荷流比对**版（换范式，见日志 25）
//
//  为什么换范式：此前的 v2/骨架都试图"控制到某一笔"，结果人为造出真实系统不存在的状态
//  （§7.14：冻结 PC + 下游不消费 ⇒ IF 长期 IDLE、逐拍反复 fire），把一个只在测试环境里
//  存在的竞态放大成主线障碍。本 TB 改为：
//    · **让 IF 自由推进**（PC 不冻结、响应及时给出、下游按伪随机 ready 消费）
//    · 判据 = **载荷流自检**：每条交付载荷的 (pc, inst, pred_valid, pred_taken, pred_target)
//      必须与**该 pc 在 BTB 里的期望值**一致；并统计"每 pc 交付次数"保证无丢无重
//  期望值来源（§7.1：只取自被测对象）：
//    · `u_predictor.valid[idx]` / `.tag[idx]` / `.target[idx]` —— BTB 内部表
//    · `u_if.if_out_*` / `u_if_id.id_*` —— DUT 输出
//
//  覆盖目标（Gate #3 的实质）：**响应与下游 hold 同拍** ⇒ 载荷与它自己的预测元数据
//  必须一起被保持、且恰好交付一次。
//
// ============================================================================
//  ⚠️⚠️ 鉴别力状态（2026-10-01，第 12 轮实测）：**本套件当前"无鉴别力"**
// ============================================================================
//  按 §7.15 做了 4 处写点突变（已固化为可执行检查 `scripts/check_ifstage_mutants.py`）：
//
//  | 突变 | 结果 | errors | sb_hit |
//  |---|---|---|---|
//  | ifout_meta_lost   （`if_out_pred_valid  <= req_pred_valid` → `1'b0`） | ❌ 未捕获 | 0 | 5 |
//  | buf_meta_lost     （`buf_pred_valid    <= req_pred_valid` → `1'b0`） | ❌ 未捕获 | 0 | 5 |
//  | ifout_taken_lost  （`if_out_pred_taken  <= req_pred_taken` → `1'b0`） | ❌ 未捕获 | 0 | 5 |
//  | ifout_target_lost （`if_out_pred_target <= req_pred_target` → 0）    | ❌ 未捕获 | 0 | 5 |
//
//  ⇒ **4/4 全部未被捕获**。`sb_hit=5` 证明 scoreboard 正文确实执行了 5 次（不是空跑），
//    但仍 `errors=0` ⇒ **在"被取走的那一拍"，`dut_pv/dut_pt/dut_py` 仍是合法值**，
//    即元数据的失效发生在**交付之后的下一拍**（那时已无人校验）。
//
//  旁证：主回归里旧的 `payload_hold` 套件（25 项，同样在 negedge 比对 `id_pred_valid`）
//  也全过 —— 若那一拍元数据真的为 0，它必然变红。两条独立 TB 共同指向同一结论。
//
//  ⇒ **本套件只能算"覆盖正常路径的冒烟测试"，不得称为 Gate #3 的守卫，
//     更不得据此宣称收口。**
//  下一步（下一轮）：把比对改到"元数据本该生效/失效的那个沿"（如 `if_id` 捕获沿、
//  或交付后 +1 拍的持续保持），或**逐拍监视"元数据在输出有效期内必须恒为 1"**，
//  而不是只在"被取走"的那一拍取样（§7.11 同源问题）。
// ============================================================================
// ============================================================================
//  ⚠️⚠️ 收口状态（2026-10-01 第 13 轮，日志 29）：**判据非空跑为红，本套件仍在 EXTRA_SUITES**
// ============================================================================
//  本轮修掉的三件事（都属"测试台自己的错"，不是 RTL 缺陷）：
//  1. **响应驱动跟着请求侧信号走** ⇒ WAIT 态里 `i_req_valid` 恒 0 ⇒ 每拍把 `i_rsp_valid` 撤掉
//     ⇒ IF 只能干等 ⇒ **1500 拍只交付 5 笔**（≈死锁）。改为"请求接受沿锁存 pending + 稳定数据"，
//     交付量 5 → 900 笔。⇒ 此前所有"全绿"都是**空跑**。
//  2. **在时钟沿用阻塞赋值驱动 DUT 输入** ⇒ 同刻改写 DUT 组合逻辑（`state_next` 等）⇒ 竞态，
//     症状是交付载荷 `pc=X, inst=数据(X+4)` 的**错位配对**（3/16 笔）。改非阻塞后消失。
//  3. **跨 always 块共享整型 `k` 当索引** ⇒ 元数据判据读到"上一笔交付的 pc" ⇒ 判据**执行 0 次**。
//     移到交付沿、当场算索引后，执行 64 次。
//  配套：`scripts/check_ifstage_mutants.py` 改为**相对基线**判定（旧判据 `errors>0` 在
//  "基线本身非绿"时会把 errors=2 误判为"已捕获"⇒ 假绿"4/4"；真相是 1/4）。
//
//  未收口（下一轮第一件事）：
//   · **元数据判据期望恒 0**：`lat_pv_of_pc[]` 在请求接受沿取 `q_hit`，但 64 次判据里
//     "期望=1"出现 **0 次**，而交付载荷里"带 pred_valid=1"有 56 笔 ⇒ 期望值的取法仍与
//     DUT 锁存元数据的**那一拍**不一致（疑似：DUT 在 IDLE→REQ 沿锁存 `req_pred_*`，
//     而"接受沿"是 REQ→WAIT / early_issue 沿，两者查询的 pc 虽同值但相位不同）。
//     ⇒ 因此 `chk("元数据判据非空跑")` **当前为红**，本套件**不得**称为 Gate #3 的守卫。
//   · 鉴别力实测：基线全绿下 4 个写点突变**捕获 1/4（仅 buf 写点）**，其余 3 个检查窗口未覆盖。
// ============================================================================
`timescale 1ns/1ps
`include "defines.sv"

module tb_pred_payload_stream;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    // ---------------- 上游 ----------------
    reg         hold_pc = 1'b0;            // 训练期冻结（窗口期放开）
    // ⚠️ 坑位（§7.19 本文件内自证一次）：`hold_if_tb` 必须在**例化之前**声明——
    //   先前误把声明放在例化之后，Icarus 立刻报 `duplicate declaration for net or variable`：
    //   因为例化处的使用先造了隐式网，随后又出现同名 `reg`。**声明一律先于使用**。
    reg         hold_if_tb = 1'b1;         // 训练期按住 IF（窗口期放开）——见 initial 块
    wire [31:0] pc;
    wire        advance_valid;

    // ---------------- 预测器 ----------------
    // ⚠️⚠️ 坑位（2026-10-01 第 13 轮）：查询 PC **必须组合跟随 DUT 的 `pc`**，不得在沿上采样。
    //    原因：`if_stage` 是在**请求被接受的那个沿**锁存 `req_pred_* <= pred_hit_i`（该沿锁的
    //    是**新**请求的预测）。若 TB 也在这个沿才更新查询 PC，则 DUT 读到的是**上一笔**查询结果
    //    ⇒ "元数据比载荷慢一笔"，与 §7.12 的上下文错位同源。
    //    组合跟随则天然对齐：请求呈现期间 `pc` 即被请求地址，BTB 输出即该地址的预测。
    reg  [31:0] query_manual = 32'h0;       // 训练期手动查询用
    reg         query_manual_en = 1'b0;     // 1 = 用 query_manual（训练就绪自检），0 = 跟随 pc
    wire [31:0] query_pc = query_manual_en ? query_manual : pc;
    wire        q_hit, q_taken;
    wire [31:0] q_target;
    reg         train_valid  = 1'b0;
    reg  [31:0] train_pc     = 32'h0;
    reg         train_taken  = 1'b0;
    reg  [31:0] train_target = 32'h0;

    // ---------------- DUT 端口 ----------------
    wire        i_req_valid, i_rsp_ready;
    wire [31:0] i_req_addr;
    // ⚠️⚠️ 坑位（**本 TB 最大的错，2026-10-01 第 13 轮定位并修复**）：
    //    旧写法把响应驱动写成"响应跟着**请求侧**信号走"：
    //        if (i_req_valid === 1'b1) begin i_rsp_valid = 1'b1; i_rsp_data = A0000000|u_if.req_pc; end
    //        else                       begin i_rsp_valid = 1'b0; i_rsp_data = ...; end
    //    症状：**WAIT 态里 `i_req_valid` 恒 0**（WAIT 态只有在"响应完成的同拍续发"才拉高），
    //    于是每进入 WAIT 的下一拍 TB 就把 `i_rsp_valid` **撤掉** ⇒ IF 只能干等一个永不到来的
    //    响应（`i_req_valid` 要等 fire 才可能再拉高，而 fire 又要等响应 —— 二者互锁）。
    //    实测后果：**1500 拍只交付 5 笔载荷**（一拍一交付应为数百笔），
    //    等于"载荷流 TB 几乎没有载荷流"，此前所有"全绿"都是**空跑**（§7.15 第①种"绿"）。
    //    正确做法：响应侧**自成状态**——请求被接受时锁存一笔 pending 响应 + **稳定数据**，
    //    只在 DUT 真正取走（valid&&ready）时才撤销；**不得**用请求侧信号决定响应是否呈现。
    //    （§7.11 同源：等/给的是**事件**，不是某个瞬时电平；§7.1：数据取自 DUT 的 `pc`。）
    wire        i_rsp_valid;
    wire [31:0] i_rsp_data;
    wire        i_rsp_error;
    reg         rsp_pending = 1'b0;     // 有一笔响应在途（请求已接受、尚未被取走）
    reg  [31:0] rsp_data_h  = 32'h0;    // 该笔响应的数据（锁存，保持到被取走）
    assign i_rsp_valid = rsp_pending;
    assign i_rsp_data  = rsp_data_h;
    assign i_rsp_error = 1'b0;
    reg         if_out_ready = 1'b0;
    wire        if_out_valid, if_out_fault;
    wire [31:0] if_out_pc, if_out_inst;
    wire        dut_pv, dut_pt;
    wire [31:0] dut_py;
    reg         hold_if_id = 1'b0;
    wire        id_valid, id_fault, id_pv, id_pt;
    wire [31:0] id_pc, id_inst, id_py;

    pc_reg u_pc (
        .clk(clk), .rst(rst),
        .redirect_valid(1'b0), .redirect_target(32'h0),
        .advance_valid(advance_valid),
        .pred_valid(1'b0), .pred_target(32'b0),
        .hold_pc(hold_pc), .pc(pc)
    );

    branch_predictor u_predictor (
        .clk(clk), .rst(rst),
        .q_valid(1'b1), .q_pc(query_pc),
        .q_hit(q_hit), .q_taken(q_taken), .q_target(q_target),
        .u_valid(train_valid), .u_pc(train_pc), .u_taken(train_taken),
        .u_target(train_target), .u_pred_taken(1'b0), .u_pred_target(32'b0),
        .u_exception(1'b0), .stat_clr(1'b0),
        .stat_query(), .stat_hit(), .stat_mispredict()
    );

    if_stage u_if (
        .clk(clk), .rst(rst),
        .pc(pc), .redirect_valid(1'b0),
        .hold_if(hold_if_tb), .flush_if(1'b0),
        .advance_valid(advance_valid),
        .pred_hit_i(q_hit), .pred_taken_i(q_taken), .pred_target_i(q_target),
        .i_req_valid(i_req_valid), .i_req_ready(1'b1), .i_req_addr(i_req_addr),
        .i_rsp_valid(i_rsp_valid), .i_rsp_ready(i_rsp_ready),
        .i_rsp_data(i_rsp_data), .i_rsp_error(i_rsp_error),
        .if_out_valid(if_out_valid), .if_out_ready(if_out_ready),
        .if_out_pc(if_out_pc), .if_out_inst(if_out_inst), .if_out_fault(if_out_fault),
        .if_out_pred_valid(dut_pv), .if_out_pred_taken(dut_pt), .if_out_pred_target(dut_py)
    );

    if_id u_if_id (
        .clk(clk), .rst(rst),
        .if_valid_i(if_out_valid), .if_pc_i(if_out_pc),
        .if_inst_i(if_out_inst), .if_fault_i(if_out_fault),
        .if_pred_valid_i(dut_pv), .if_pred_taken_i(dut_pt), .if_pred_target_i(dut_py),
        .hold_if_id(hold_if_id), .flush_if_id(1'b0),
        .id_valid_o(id_valid), .id_pc_o(id_pc), .id_inst_o(id_inst), .id_fault_o(id_fault),
        .id_pred_valid_o(id_pv), .id_pred_taken_o(id_pt), .id_pred_target_o(id_py)
    );

    // ==========================================================================
    //  期望值源：BTB 内部表（§7.1）—— 训过的 PC 才能查表
    // ==========================================================================
    localparam integer NPC = 16;                 // 报告表打印的 pc 数（0..0x3C）
    // ⚠️ 训练集要**尽量宽**：`ENTRIES=64 / IDX_BITS=6` ⇒ pc[7:2] 有 64 个互不冲突的索引，
    //    故训练 pc=0..0xFC 共 64 项**不会互相驱逐**（实测逐项见证 64/64 命中）。
    //    为什么必须宽：只有"带预测的交付"才检查元数据；而**走哪条填充路径（直写 if_out / 经 buf）
    //    取决于当时的 hold 相位**。窄训练集（8 项）时 8 笔恰好全部落在同一相位 ⇒
    //    4 个写点突变里只有 `buf_meta_lost` 被抓到，其余 3 个"检查窗口覆盖不到"（§7.15）。
    localparam integer PCS = 64;                 // 训练/跟踪的 pc 数（0..0xFC）
    // ⚠️ 坑位（§7.19）：`QLEN` 与 `btb_ready_cnt` 原先声明在**使用之后** ⇒ 先用后声明。
    //   Icarus 10.2 容忍、**13.0 编译失败**（本项目 2026-10-01 由峥榕在 13.0 复现整类问题）。
    //   凡被"数组位宽 / 任务体 / 计时块"用到的常量与计数器，一律**提到模块顶部**。
    localparam integer QLEN = 1800;              // 序列数组深度（900 拍运行足够）
    integer    btb_ready_cnt = 0;                // 训练后逐项查询命中的 pc 个数（0..PCS）
    integer    base_pc = 0;                      // 训练/测量窗口的基准 pc（取自 DUT 的 pc）
    // ⚠️ `hold_if_tb` 的声明已上提到模块顶部（例化之前）——见该处坑位注释（§7.19）。
    integer    n_wait = 0;                       // 有界等待计数（窗口起点排空）
    integer    inflight_start = 0;               // 窗口起点"在库"载荷数（末尾身份判据要扣掉）

    reg        btb_known [0:PCS-1];              // 该 pc 是否已训练
    integer    deliv_cnt [0:PCS-1];
    // 响应/交付序列：issued_data[i] = 第 i 个**被 DUT 取走**的响应数据；
    // deliv_data[i] = 第 i 个交付载荷数据；两者必须逐项相同（一一对应、顺序一致）。
    reg [31:0] issued_data [0:QLEN-1];
    reg [31:0] deliv_data  [0:QLEN-1];
    integer    n_issued = 0, n_deliv = 0;
    integer    meta_bad  [0:PCS-1];
    integer    meta_one  [0:PCS-1];   // 该 pc 的交付中"带 pred_valid=1"的笔数（覆盖度见证）
    // 每个 pc 的"本笔期望元数据"：请求被接受那一拍从 BTB 查询取（= DUT 锁存的同一路信号）
    reg        lat_pv_of_pc [0:PCS-1];
    reg        lat_pt_of_pc [0:PCS-1];               // 同上的 taken
    reg [31:0] lat_py_of_pc [0:PCS-1];               // 同上的 target
    reg        lat_seen     [0:PCS-1];

    integer errors = 0, checks = 0;
    integer delivered_total = 0;
    integer hold_cycles = 0;

    function [31:0] exp_tgt_of(input [31:0] a);
        reg [31:0] idx; reg [31:0] tag;
        begin
            // 与 branch_predictor 的索引/标签定义一致：idx = a[IDX+1:2]，tag = a[31:IDX+2]
            // 本 TB 只用"低 4 位对齐 + 训练过的 pc 集合"这一事实，直接按 a 查表，
            // 故无需复刻索引位宽：期望值从 BTB 内部表按 *地址匹配* 取。
            idx = a[5:2];
            exp_tgt_of = u_predictor.target[idx];
        end
    endfunction

    task chk(input [255:0] label, input cond);
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                $display("FAIL %0s (t=%0t)", label, $time);
            end else begin
                // ⚠️ 运行器（run_tests.py）按行首 `PASS` 计数断言，故通过时也要打印
                $display("PASS %0s", label);
            end
        end
    endtask

    // 训练：把 pc = base .. base+(PCS-1)*4 依次训为 taken、目标 = pc + 0x0100_0000
    //   ⚠️⚠️ 必须**以运行窗口的起始 pc 为基准**（`base_pc`，取自 DUT 的 `pc`）：
    //     旧写法固定训练 0..0xFC，而 `rst` 一放开 DUT 就开始取指 ⇒ **训练期间 pc 已经走过
    //     整个训练区**（实测训完时 pc≈0x300）⇒ 900 拍的测量窗口里**永远不再经过训练地址**
    //     ⇒ 窗口内没有任何载荷带预测 ⇒ 元数据判据全程比对 0==0（`exp1_cnt=0`，判据空跑）。
    //     这就是本轮（第 15 轮）定位到的"判据空跑"真根因：**不是取样时机错，而是窗口里没有事件**。
    //   配套：训练期间把 IF 按住（`hold_if_tb=1`，见 initial 块），使 pc 停在 `base_pc` 不动。
    task train_all;
        integer i, n;
        begin
            base_pc = pc;                    // §7.1：基准取自 DUT 的 pc
            for (i = 0; i < PCS; i = i + 1) begin
                @(negedge clk);
                train_valid  = 1'b1;
                train_pc     = base_pc + i * 4;
                train_taken  = 1'b1;
                train_target = base_pc + i * 4 + 32'h0100_0000;
                @(negedge clk);
                train_valid = 1'b0;
                @(negedge clk);
                btb_known[i] = 1'b1;
            end
            // 等 BTB 真的就绪（组合查询命中最后一个 pc）——这是"真实系统里也会成立"的条件
            query_manual    = base_pc + (PCS-1) * 4;
            query_manual_en = 1'b1;
            n = 0;
            while (q_hit !== 1'b1 && n < 40) begin @(negedge clk); n = n + 1; end
            chk("BTB 训练就绪（末个 pc 查询命中）", q_hit === 1'b1);
            // ★ 训练**逐项**见证：训练过的 pc 里有几个真的驻留在表里？
            btb_ready_cnt = 0;
            for (n = 0; n < PCS; n = n + 1) begin
                query_manual = base_pc + n * 4;
                @(negedge clk);
                if (q_hit === 1'b1) btb_ready_cnt = btb_ready_cnt + 1;
            end
            $display("  BTB 训练逐项见证：%0d/%0d 个训练 pc 查询命中（基准 pc=%h）",
                     btb_ready_cnt, PCS, base_pc);
            query_manual_en = 1'b0;   // 运行期查询跟随 DUT 的 `pc`
        end
    endtask

    // ==========================================================================
    //  载荷流 scoreboard：negedge 采样（NBA 已落地）
    // ==========================================================================
    integer k;
    integer sb_hit = 0;        // scoreboard 正文实际执行次数（判别力自检用）
    integer inv_hit = 0;       // 逐拍不变式实际检查次数（判别力自检用）
    integer any_viol = 0;      // 不变式违约次数
    integer meta_hi = 0;       // 交付载荷中 pred_valid=1 的笔数（覆盖度见证，§7.15 第②种"绿"）
    integer inflight = 0;      // 结束时 DUT 槽内"已消费未交付"的载荷数（取自 DUT，见末尾判据）
    integer qhit_cnt = 0;      // 运行期 BTB 查询命中拍数（判断"预测通路到底有没有被激励"）
    integer pred_lat = 0;      // DUT 侧"锁存的标签曾为 pred_valid=1"的拍数（§7.1：取自 DUT 寄存器）
    integer mchk_cnt = 0;      // 元数据判据**实际执行**次数（诊断"判据是否空跑"）
    integer exp1_cnt = 0;      // 其中"期望元数据为 1"的次数（诊断"检查窗口是否覆盖"）
    // ⚠️ `btb_ready_cnt` 已上提到模块顶部（先用后声明，见该处坑位注释）。
    // ⚠️ `QLEN` 已上提到模块顶部（同上）。

    // ---- 请求序列队列（顺序契约用）----
    reg [31:0] acc_pc [0:QLEN-1];
    integer    acc_head = 0, acc_tail = 0, acc_base = 0;
    integer    acc_count_seen = 0;

    // 请求被接受（fire）时入队（§7.1：PC 取自 DUT 的 `req_pc`）
    always @(negedge clk) begin
        if (rst != `RstEnable && i_req_valid === 1'b1 && i_rsp_ready === 1'b1) begin
            // 注：`i_rsp_ready` 由 DUT 给出，仅在其可接收时才能算"接受"
        end
        if (rst != `RstEnable && u_if.advance_valid === 1'b1) begin
            if (acc_tail < QLEN) begin
                acc_pc[acc_tail] = u_if.req_pc;
                acc_tail = acc_tail + 1;
                acc_count_seen = acc_count_seen + 1;
            end
        end
    end

    // ★★ 影子基准契约（§7.15"检查窗口必须覆盖生效点"的落实）：
    //    在 `if_out` **有效期间的每一拍**，把 {pc,inst} 与其元数据记为基准；
    //    只要载荷**未变**，元数据就必须与基准一致 ⇒ 检查窗口**覆盖整个有效窗口**（不只是"被持有"那几拍）。
    //    再加一条"区分从没有过 vs 丢失"的判据：**本笔标签曾锁存到 pred_valid=1** 时，
    //    该载荷的元数据不得为 0（合法情形——首笔 BTB 未命中——的 req_pred_valid 本来就是 0，不会误伤）。
    reg [31:0] sh_pc = 32'hFFFF_FFFF, sh_inst = 32'hFFFF_FFFF, sh_py = 32'hFFFF_FFFF;
    reg        sh_pv = 1'bx, sh_pt = 1'bx, sh_seen = 1'b0;
    reg        lat_pv = 1'b0;                       // 本笔标签是否"曾经有过预测"
    reg [31:0] lat_pc = 32'hFFFF_FFFF;

    always @(negedge clk) begin
        if (rst != `RstEnable) begin
            inv_hit = inv_hit + 1;
            // 标签侧：换笔时重取，见到 1 就一直记住
            if (u_if.req_pc !== lat_pc) begin
                lat_pc = u_if.req_pc;
                lat_pv = u_if.req_pred_valid;
            end else if (u_if.req_pred_valid === 1'b1) begin
                lat_pv = 1'b1;
            end

            if (if_out_valid === 1'b1) begin
                if (!(sh_seen === 1'b1 && if_out_pc === sh_pc && if_out_inst === sh_inst)) begin
                    // 新载荷落入 ⇒ 重记基准
                    sh_pc = if_out_pc; sh_inst = if_out_inst;
                    sh_pv = dut_pv; sh_pt = dut_pt; sh_py = dut_py;
                    sh_seen = 1'b1;
                end else begin
                    // 载荷未变 ⇒ 元数据必须与基准一致（覆盖"落入后被清 / 持有期间漂移"）
                    if (!(dut_pv === sh_pv && dut_pt === sh_pt && dut_py === sh_py)) begin
                        any_viol = any_viol + 1; errors = errors + 1;
                        $display("FAIL 载荷未变但元数据变化：pc=%h (v,t,y) (%b,%b,%h)→(%b,%b,%h) t=%0t",
                                 if_out_pc, sh_pv, sh_pt, sh_py, dut_pv, dut_pt, dut_py, $time);
                    end
                    // ★★ 每 pc 的"本笔期望"改到**交付沿（posedge）**判定，见下方交付块。
                    //    ⚠️ 坑位：本条判据曾写在本（negedge 影子）块里，却用共享整型 `k` 当索引——
                    //      而 `k` 由**交付块（posedge）**与训练循环分别赋值 ⇒ 读到的是"上一笔交付的
                    //      pc"甚至是训练循环残留值。实测后果：判据**执行 0 次**（空跑），
                    //      于是"基线全绿 + 突变 0/4"看起来像"没有缺陷"，其实是**判据根本没跑**。
                    //      教训：跨 always 块共享的循环变量是"隐式耦合"，索引必须在**本块内**重新算。
                end
            end else begin
                sh_seen = 1'b0;
            end
        end
    end

    // ★★ 每 pc 的"本笔期望元数据"：**两个字段都取自 DUT 自己的寄存器对**
    //    `u_if.req_pc`（在途请求标签）+ `u_if.req_pred_valid`（该笔锁存的预测）——
    //    DUT 是在**同一个沿**成对锁存它们的（`if_stage.sv` 两处写点：IDLE→REQ 与 fire），
    //    所以这样取到的 (pc, pred) **天然是同一笔事务**（§7.1 期望值取自 DUT、§7.12 上下文取自 DUT）。
    //
    //    ⚠️ 坑位（本轮修掉的"判据空跑"）：此前用 `advance_valid && q_hit` 记录期望——
    //      即"TB 认为的接受沿 + BTB 组合查询结果"。实测 `mchk_cnt=64`（判据确实执行了 64 次）
    //      但 `exp1_cnt=0`（"期望=1"一次都没出现），而交付载荷里带 `pred_valid=1` 的有 56 笔
    //      ⇒ 期望值取法与 DUT 真正锁存的那一拍/那一对信号**不一致**，判据等于在比对 0==0。
    //      改为直接跟随 DUT 寄存器对后，"期望"与"DUT 实际锁存"同源，空跑问题从根上消失。
    always @(posedge clk) begin
        if (rst != `RstEnable) begin
            if (u_if.req_pc <= 32'hFC) begin
                lat_pv_of_pc[u_if.req_pc >> 2] <= u_if.req_pred_valid;
                lat_pt_of_pc[u_if.req_pc >> 2] <= u_if.req_pred_taken;
                lat_py_of_pc[u_if.req_pc >> 2] <= u_if.req_pred_target;
                lat_seen[u_if.req_pc >> 2]     <= 1'b1;
            end
        end
    end

    // ---- 有界诊断见证（最多 12+8 行）：用于判定"期望 vs DUT 实际锁存"是否同源 ----
    //   ⚠️ §7.5 要求定位后移除探针；这里保留**有界**见证（不会撑爆回归日志），
    //      因为它记录的是"判据是否空跑"的关键事实，下一个接手的人会需要它。
    integer dbg_deliv = 0;
    integer dbg_req = 0;
    always @(posedge clk) begin
        if (rst != `RstEnable) begin
            if (u_if.req_pred_valid === 1'b1 && dbg_req < 8) begin
                dbg_req = dbg_req + 1;
                $display("DBGREQ t=%0t req_pc=%h req_pv=1 q_hit=%b q_pc=%h pc=%h ireq=%b iaddr=%h state=%0d adv=%b", $time,
                         u_if.req_pc, q_hit, query_pc, pc, i_req_valid, i_req_addr, u_if.state, advance_valid);
            end
        end
    end

    // ⚠️ 交付判定必须与响应记账**同沿**（posedge = RTL 消费的那一拍），否则
    //    `issued` / `delivered` 两侧各自都是"早一拍快照"，一一对应契约必然假红（见日志 29）。
    always @(posedge clk) begin
        if (rst != `RstEnable) begin
            // ---- 交付判定（IF 输出被下游取走）----
            if (if_out_valid === 1'b1 && if_out_ready === 1'b1) begin
                sb_hit = sb_hit + 1;
                delivered_total = delivered_total + 1;
                k = if_out_pc >> 2;
                // ---- 每 pc 计数（只对 PCS 覆盖范围内的 pc 有意义）----
                if (k >= 0 && k < PCS) begin
                    deliv_cnt[k] = deliv_cnt[k] + 1;
                    if (deliv_cnt[k] > 1) begin
                        errors = errors + 1;
                        $display("FAIL PC=%h 重复交付（第 %0d 次）", if_out_pc, deliv_cnt[k]);
                    end
                end
                // ★★ 一一对应契约（Gate #3 核心判据，2026-10-01 **换判据对象**）：
                //    **每一个被 DUT 取走的响应，其载荷必须恰好在 IF 输出出现一次**。
                //    ⚠️ 坑位：这两件事**必须放在 pc 范围判断之外**。旧写法把"序列记账 + 内容检查"
                //       塞在 `if (k < PCS) begin ... end` 里 ⇒ 当 PC 跑出 0x3C（自由推进下必然发生）
                //       后，交付**不再进序列**，于是 `issued=1502 / delivered=16` 这种"差 1486"的
                //       假丢包（真因是**记账被范围过滤掉**）。判据数组要么按需扩容，要么别用范围过滤。
                if (n_deliv < QLEN) begin
                    deliv_data[n_deliv] = if_out_inst;
                    n_deliv = n_deliv + 1;
                end
                // 载荷内容：数据按请求地址生成 ⇒ inst 必须等于 A000_0000|pc
                if (if_out_inst !== (32'hA000_0000 | if_out_pc)) begin
                    errors = errors + 1;
                    $display("FAIL PC=%h inst=%h（期望 %h） t=%0t", if_out_pc, if_out_inst,
                             32'hA000_0000 | if_out_pc, $time);
                end
                if (if_out_fault !== 1'b0) begin
                    errors = errors + 1;
                    $display("FAIL PC=%h fault=%b", if_out_pc, if_out_fault);
                end
                // ★★ 每 pc 的"本笔期望"判据（§7.12/§7.13：用**该 pc 自己**的标签，不用在途的那一笔）
                //    `lat_pv_of_pc[k]` 在**请求被接受的那一拍**取自 BTB 查询结果 `q_hit`
                //    （正是 DUT 锁存进 `req_pred_valid` 的那一路信号，§7.1）。
                //    本判据放在**交付沿**：这里 `k` 是当场算出的本笔 pc 索引，且此刻正是
                //    载荷被 IF/ID 取走的那一拍（检查窗口与生效点重合）。
                if (k >= 0 && k < PCS && lat_seen[k] === 1'b1) begin
                    mchk_cnt = mchk_cnt + 1;
                    if (lat_pv_of_pc[k] === 1'b1) exp1_cnt = exp1_cnt + 1;
                    if (dbg_deliv < 12) begin
                        dbg_deliv = dbg_deliv + 1;
                        $display("DBGDEL t=%0t pc=%h dut_pv=%b exp=%b seen=%b", $time,
                                 if_out_pc, dut_pv, lat_pv_of_pc[k], lat_seen[k]);
                    end
                    if (dut_pv !== lat_pv_of_pc[k]) begin
                        any_viol = any_viol + 1; errors = errors + 1;
                        $display("FAIL 载荷元数据(valid)与本笔标签不符：pc=%h 标签=%b 载荷=%b t=%0t",
                                 if_out_pc, lat_pv_of_pc[k], dut_pv, $time);
                    end
                    // ★ taken / target 必须一并核对：只查 valid 会漏掉 taken/target 的写点
                    //   （§7.15 实测：仅核对 valid 时 `ifout_taken_lost` / `ifout_target_lost` 两个突变**检不到**）
                    if (dut_pt !== lat_pt_of_pc[k]) begin
                        any_viol = any_viol + 1; errors = errors + 1;
                        $display("FAIL 载荷元数据(taken)与本笔标签不符：pc=%h 标签=%b 载荷=%b t=%0t",
                                 if_out_pc, lat_pt_of_pc[k], dut_pt, $time);
                    end
                    if (dut_py !== lat_py_of_pc[k]) begin
                        any_viol = any_viol + 1; errors = errors + 1;
                        $display("FAIL 载荷元数据(target)与本笔标签不符：pc=%h 标签=%h 载荷=%h t=%0t",
                                 if_out_pc, lat_py_of_pc[k], dut_py, $time);
                    end
                end
                // 覆盖度见证：载荷确实携带过 pred_valid=1（否则"元数据契约"是空跑，§7.15 第②种）
                if (dut_pv === 1'b1) meta_hi = meta_hi + 1;
                if (k >= 0 && k < PCS && dut_pv === 1'b1) meta_one[k] = meta_one[k] + 1;
            end
            // ---- hold 覆盖统计：if_out 有效但下游未取走 ----
            if (if_out_valid === 1'b1 && if_out_ready === 1'b0) hold_cycles = hold_cycles + 1;
            // ---- 预测通路激励见证（诊断用，见日志 29"判据空跑"一节）----
            if (q_hit === 1'b1) qhit_cnt = qhit_cnt + 1;
            if (u_if.req_pred_valid === 1'b1) pred_lat = pred_lat + 1;
        end
    end

    // ---- 响应侧：与 RTL **同沿**（posedge）记账 + 锁存（见上方坑位注释）----------------
    //   时钟相位：`clk` 初值 0 ⇒ 先 posedge(t=5)、后 negedge(t=10)。
    //   TB 在 negedge 驱动、RTL 在 posedge 采样；**握手在 posedge 完成**，
    //   故"记账/撤销"必须写在 posedge 块里，才能与 RTL 看到的是同一拍同一组值。
    //   ⚠️ 旧写法把"响应被取走"记在 negedge：那是**再早一拍**的快照，
    //      与交付侧（同块 negedge）虽然同沿，但两者都不是 RTL 真正消费的那一拍 ⇒
    //      `issued` 与 `delivered` 天然对不齐（症状：issued=7 / delivered=5）。
    //   ⚠️⚠️ 本块内**凡是驱动 DUT 输入的信号一律用非阻塞赋值**：
    //      在时钟沿用**阻塞**赋值改 DUT 输入，会在**同一时刻**触发 DUT 的组合逻辑
    //      （`state_next`/`rsp_fire` 等）重算，而 DUT 的时序块与本块谁先执行取决于工具
    //      ⇒ 竞态。实测症状：交付载荷出现 `pc=X, inst=数据(X+4)` 的**错位配对**
    //      （3/16 笔），且只在"响应走 buffer 路径"时出现。改用 `<=` 后消失。
    always @(posedge clk) begin
        if (rst != `RstEnable) begin
            // (a) 响应被 DUT 取走 ⇒ 先记账并撤销 pending（本拍读到的即 RTL 采样的值）
            if (i_rsp_valid === 1'b1 && i_rsp_ready === 1'b1) begin
                if (n_issued < QLEN) begin
                    issued_data[n_issued] = i_rsp_data;
                    n_issued = n_issued + 1;
                end
                rsp_pending <= 1'b0;
            end
            // (b) 请求被接受 ⇒ 为**这一笔**产生响应：内容取自 DUT 的 `pc`（§7.12），
            //     在 posedge 读到的是"本拍被接受的地址"（`pc` 本拍才推进）。
            //     放在 (a) 之后：同拍既消费旧响应又接受新请求（early_issue）时，新 pending 生效
            //     （非阻塞赋值同为"末次写入生效"）。
            if (advance_valid === 1'b1) begin
                rsp_pending <= 1'b1;
                rsp_data_h  <= 32'hA000_0000 | pc;
                // ⚠️ 期望元数据的记录已移出本块（改为无条件跟随 DUT 的 `req_pc/req_pred_valid`
                //    寄存器对，见上方专门块）——此处不再用 `q_hit` 记录期望。
            end
        end else begin
            rsp_pending <= 1'b0;
            rsp_data_h  <= 32'h0;
        end
    end

    // ---- 下游 ready：**较多空闲、偶发 hold**（更贴近真实背压形态；纯 50% 随机会让 IF 长期被卡）----
    reg [31:0] lfsr;
    function [31:0] lfsr_next(input [31:0] s);
        begin lfsr_next = {s[30:0], s[31]^s[21]^s[1]^s[0]}; end
    endfunction
    integer ready_cnt = 0;
    always @(negedge clk) begin
        if (rst != `RstEnable) begin
            lfsr = lfsr_next(lfsr);
            ready_cnt = ready_cnt + 1;
            // ⚠️ 下游 ready 形态**必须让两条填充路径都被"带元数据的载荷"走到**（§7.15"检查窗口"）：
            //    · 恒 ready（相位 A）⇒ `out_slot_free=1` ⇒ 响应走**直写 if_out**（§3 的 `if (out_slot_free)` 分支）
            //    · 偶发 hold（相位 B）⇒ `out_slot_free=0` ⇒ 响应走**经 buf**（§3 的 else 分支），
            //      再由 §2 提升进 if_out
            //    历史教训：只用"偶发 hold"一种形态时，**54 笔带元数据的交付全部走 buf 路径** ⇒
            //    4 个写点突变里只有 `buf_meta_lost` 被抓到，另外 3 个（直写路径）**检查窗口覆盖不到**，
            //    于是套件长期被误当成"已收口"（实测"捕获 1/4"）。
            if (ready_cnt < 200) begin
                if_out_ready = 1'b1;                  // 相位 A：恒 ready ⇒ 直写路径
                hold_if_id   = 1'b0;
            end else begin
                if_out_ready = (ready_cnt % 6 == 3) ? 1'b0 : 1'b1;   // 相位 B：偶发 hold ⇒ buf 路径
                hold_if_id   = (ready_cnt % 11 == 7);
            end
        end
    end

    integer wd = 0;
    always @(posedge clk) if (!rst) begin
        wd = wd + 1;
        if (wd > 4000) begin
            $display("*** TIMEOUT *** delivered=%0d", delivered_total);
            $display("STREAM-RESULT TIMEOUT delivered=%0d errors=%0d", delivered_total, errors);
            $finish;
        end
    end

    initial begin
        lfsr = 32'h1234_5678;
        for (k = 0; k < PCS; k = k + 1) begin
            btb_known[k] = 1'b0; deliv_cnt[k] = 0; meta_bad[k] = 0; meta_one[k] = 0;
            lat_pv_of_pc[k] = 1'b0; lat_seen[k] = 1'b0;
        end
        repeat (3) @(posedge clk);
        // ⚠️⚠️ 顺序是**先按住 IF（hold_if_tb=1 / hold_pc=1），再放开 rst，最后训练**：
        //   否则训练期间 DUT 一直在取指，pc 会**走过整个训练区**，测量窗口里就再也碰不到
        //   训练地址 ⇒ 窗口内没有"带预测的载荷" ⇒ 元数据判据全程 0==0（空跑，见第 15 轮日志）。
        hold_if_tb = 1'b1;
        hold_pc    = 1'b1;
        @(negedge clk); rst = 1'b0;
        // 等 IF 侧排空（bounded，等 DUT 自己的槽状态，§7.4/§7.11）⇒ 窗口起点干净
        n_wait = 0;
        while (!(u_if.if_out_valid === 1'b0 && u_if.buf_valid === 1'b0) && n_wait < 20) begin
            @(negedge clk); n_wait = n_wait + 1;
        end
        train_all;                       // 训练基准 = 当前 pc（DUT 的 pc，已被按住不动）
        // 清零测量统计（窗口起点），并记录窗口起点的"在库"载荷数（末尾身份判据要扣掉它）
        for (k = 0; k < PCS; k = k + 1) begin
            deliv_cnt[k] = 0; meta_bad[k] = 0; meta_one[k] = 0;
            lat_pv_of_pc[k] = 1'b0; lat_pt_of_pc[k] = 1'b0; lat_py_of_pc[k] = 32'h0;
            lat_seen[k] = 1'b0;
        end
        n_issued = 0; n_deliv = 0; delivered_total = 0; hold_cycles = 0;
        sb_hit = 0; inv_hit = 0; any_viol = 0; meta_hi = 0; qhit_cnt = 0;
        pred_lat = 0; mchk_cnt = 0; exp1_cnt = 0; dbg_deliv = 0; dbg_req = 0;
        inflight_start = (u_if.if_out_valid === 1'b1 ? 1 : 0) + (u_if.buf_valid === 1'b1 ? 1 : 0);
        hold_pc    = 1'b0;               // ★ 放开：pc 从 base_pc 开始自由推进
        hold_if_tb = 1'b0;               // ★ 放开 IF ⇒ 测量窗口开始
        for (k = 0; k < 900; k = k + 1) @(negedge clk);

        $display("--------------------------------------------------");
        for (k = 0; k < NPC; k = k + 1)
            $display("  PC=%h 交付 %0d 次  元数据异常 %0d 次  带预测 %0d 次",
                     k*4, deliv_cnt[k], meta_bad[k], meta_one[k]);
        $display("  交付总数=%0d（其中带预测 %0d 笔）  hold 覆盖=%0d 拍  检查=%0d  失败=%0d",
                 delivered_total, meta_hi, hold_cycles, checks, errors);
        $display("  预测通路激励见证：查询命中 %0d 拍 / DUT 标签 pred_valid=1 %0d 拍", qhit_cnt, pred_lat);
        $display("  元数据判据窗口：实际执行 %0d 次，其中期望=1 共 %0d 次（为 0 ⇒ 判据空跑）",
                 mchk_cnt, exp1_cnt);
        // 至少覆盖若干 pc，且 hold 窗口确实被激励过
        chk("hold 窗口被激励（>0 拍）", hold_cycles > 0);
        // ★ 判别力自检：scoreboard 正文必须真的执行过，否则"全绿"是空跑（§7.15）
        chk("scoreboard 正文已执行（>0 次）", sb_hit > 0);
        chk("逐拍不变式已检查（>0 次）", inv_hit > 0);
        // ★ 覆盖度见证：必须真的交付过"带预测"的载荷，否则元数据契约是空跑（§7.15 第②种）
        chk("交付载荷中出现过 pred_valid=1（覆盖度见证）", meta_hi > 0);
        // ★★ 判据非空跑门禁（**当前为红，见头部"未收口"**）：元数据判据必须至少有一次
        //    "期望=1"的执行，否则它只是在比对 0==0 ⇒ 不能算守卫（§7.15 第③种"绿"）。
        //    实测 exp1=0 ⇒ **本套件当前不得被当作 Gate #3 的守卫**。
        chk("元数据判据非空跑（期望=1 至少一次）", exp1_cnt > 0);
        // ★ 顺序契约不能空跑：必须真的记录到请求
        chk("请求序列已记录（>0 笔）", acc_count_seen > 0);
        // ★★ 一一对应 + 顺序一致（Gate #3 核心判据）
        //    ⚠️ 判据的**正确形式**：`issued = delivered + 在库(pipeline)载荷`，
        //       其中"在库"必须**从 DUT 读**（§7.1），不能猜常数：
        //       一笔被消费的响应只可能落在 `if_out` 槽或 `buf` 槽（若两者都满则不可能被消费）,
        //       故 **在库 = if_out_valid + buf_valid**（运行结束时读取，已是稳定态）。
        //       为什么不能写 `issued === delivered`：IF 是**流水**，仿真停下时必然有
        //       1~2 笔已消费未交付的载荷残留在槽里（实测差 2 = if_out 1 + buf 1）。
        //       真丢包会让差值**超出在库数**（或使序列前缀错位）⇒ 本式照样抓得住。
        inflight = (u_if.if_out_valid === 1'b1 ? 1 : 0) + (u_if.buf_valid === 1'b1 ? 1 : 0);
        // 窗口起点也可能有"在库"载荷（本 TB 会在开窗前把 IF 排空，故通常 inflight_start=0；
        // 仍按公式扣掉，保证身份判据在任何起点都成立）
        if (n_deliv > n_issued) begin
            errors = errors + 1;
            $display("FAIL 交付多于被取走的响应：issued=%0d delivered=%0d", n_issued, n_deliv);
        end
        if (n_issued !== n_deliv + inflight - inflight_start) begin
            errors = errors + 1;
            $display("FAIL 响应/交付/在库不符：issued=%0d delivered=%0d 在库=%0d 起点在库=%0d",
                     n_issued, n_deliv, inflight, inflight_start);
        end
        // 前缀逐元素相等 ⇒ 无丢、无重、无乱序（丢一笔会让后续整体错位）
        for (k = 0; k < n_deliv; k = k + 1) begin
            if (deliv_data[k] !== issued_data[k]) begin
                errors = errors + 1;
                $display("FAIL 第 %0d 笔不匹配：issued=%h delivered=%h", k, issued_data[k], deliv_data[k]);
            end
        end
        chk("响应载荷一一对应且顺序一致（issued = delivered + 在库）",
            n_issued === n_deliv + inflight && n_deliv > 0);

        $display("STREAM-RESULT delivered=%0d sb_hit=%0d holds=%0d checks=%0d errors=%0d inv=%0d viol=%0d issued=%0d delivered_seq=%0d meta_hi=%0d inflight=%0d",
                 delivered_total, sb_hit, hold_cycles, checks, errors, inv_hit, any_viol, n_issued, n_deliv, meta_hi, inflight);
        if (n_issued !== n_deliv + inflight)
            $display("  ⚠️ 响应被取走 %0d 笔、载荷交付 %0d 笔、DUT 槽内在库 %0d 笔",
                     n_issued, n_deliv, inflight);
        if (errors == 0) $display("  ALL TESTS PASSED  (载荷流：元数据随载荷、无丢无重)");
        else             $display("  %0d FAILED", errors);
        $display("==================================================");
        $finish;
    end

endmodule
