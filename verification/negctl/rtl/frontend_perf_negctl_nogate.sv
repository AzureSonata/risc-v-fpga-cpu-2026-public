// ============================================================================
// ============================================================================
// ============================================================================
//        负向对照突变体（NEGATIVE CONTROL MUTANT）— 故意注入历史缺陷
//        由 scripts/run_tests.py --negative-controls 装载，
//        替换 rtl/core/frontend_perf.sv（配合 tb_frontend_perf）
//        预期：对应测试必须 FAIL（证明回归能捕获该违规）
//        源：rtl/core/frontend_perf.sv 的已修复版本
//
//        注入缺陷：分支计数未用 id_valid 门控 -> 空泡周期被计入分支统计，
//        污染预测精度与分支密度（T4 断言必然失败）
//        前端性能计数器（Frontend Performance Counters）
//        Stage2 成员A — 为 REQ-010 性能分析 / REQ-012 ILA 波形提供硬件观测点
//
//        设计定位：**纯被动观测模块**。只读既有信号，不产生任何控制输出，
//        因此接入它不会改变任何被观测模块的行为（零功能风险）。
//
//        采集点规格依据
//        -----------------
//        越南 UIT 论文（J. VLSI Circuits and Systems 7(2):68-76, 2025）Table 1
//        是公开文献中**唯一给出分支计数器硬件采集点**的：
//          - TotalBranches ：在 **ID 级译码出条件分支**时递增（不在执行级）
//          - Mispredictions：在 **BPU 拉起 flush 信号**时递增
//        本模块沿用该规格，以便与文献数字可比；同时额外区分条件分支与
//        无条件跳转（JAL/JALR），因为二者的预测机制不同。
//
//        为什么需要它（Stage E 的意义）
//        -----------------
//        1. 精度数字必须能与基准绑定。越南论文报 90.4% 是在四重嵌套 for 循环的
//           合成程序上测的；RVCoreP 在 CoreMark 上 gshare 仅 80.1%。没有硬件
//           计数器，报告里的"预测精度"就只是仿真脚本的副产品，不可复现。
//        2. 派生指标：预测精度 = 1 − mispredict/branch；误预测停顿占比 =
//           mispredict × 罚期 / cycle；分支密度 = branch / instr。
//        3. REQ-012 要求用 ILA 分析流水线效率——这些计数器就是 ILA 的抓取对象。
//
//        实现纪律
//        -----------------
//        - 全部计数在 `clk` 上升沿、`rst` 释放后递增；`clr` 提供测量窗口清零。
//        - **不做除法**：只暴露原始计数，派生比值由上层/TB 计算，避免引入除法器
//          与精度分歧（与 hpmcounter 的语义一致）。
//        - 计数器位宽参数化；溢出行为为自然回绕（与 RISC-V 计数器一致）。
// ============================================================================

`include "defines.sv"

module frontend_perf #(
    parameter CNT_W = 32          // 计数器位宽
)(
    input  wire             clk,
    input  wire             rst,
    input  wire             clr,            // 单拍清零（测量窗口起点）

    // ---------------- ID 译码点采集（越南篇规格） ----------------
    input  wire             id_valid,       // ID 级指令有效（空泡时为 0）
    input  wire             id_branch,      // 条件分支（BEQ/BNE/BLT/BGE/BLTU/BGEU）
    input  wire             id_jal,         // JAL
    input  wire             id_jalr,        // JALR

    // ---------------- 预测器采集 ----------------
    input  wire             pred_query,     // IF 发起一次预测查询
    input  wire             pred_hit,       // BTB 命中
    input  wire             mispredict,     // 预测错误（EX 解析不一致 / flush 断言点）

    // ---------------- 取指采集 ----------------
    input  wire             if_advance,     // 本拍取指推进（i_req_valid && i_req_ready）
    input  wire             redirect,       // 本拍发生重定向（flush 断言）

    // ---------------- 计数输出（原始计数，不做除法） ----------------
    output reg [CNT_W-1:0]  cnt_cycle,      // 时钟周期数
    output reg [CNT_W-1:0]  cnt_id_valid,   // 到达 ID 的有效指令数
    output reg [CNT_W-1:0]  cnt_branch,     // 控制转移指令总数（条件+JAL+JALR）
    output reg [CNT_W-1:0]  cnt_cond_branch,// 仅条件分支
    output reg [CNT_W-1:0]  cnt_jal,        // 仅 JAL
    output reg [CNT_W-1:0]  cnt_jalr,       // 仅 JALR
    output reg [CNT_W-1:0]  cnt_query,      // 预测查询次数
    output reg [CNT_W-1:0]  cnt_hit,        // BTB 命中次数
    output reg [CNT_W-1:0]  cnt_mispredict, // 误预测次数
    output reg [CNT_W-1:0]  cnt_if_advance, // 取指推进次数
    output reg [CNT_W-1:0]  cnt_redirect    // 重定向次数
);

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            cnt_cycle       <= {CNT_W{1'b0}};
            cnt_id_valid    <= {CNT_W{1'b0}};
            cnt_branch      <= {CNT_W{1'b0}};
            cnt_cond_branch <= {CNT_W{1'b0}};
            cnt_jal         <= {CNT_W{1'b0}};
            cnt_jalr        <= {CNT_W{1'b0}};
            cnt_query       <= {CNT_W{1'b0}};
            cnt_hit         <= {CNT_W{1'b0}};
            cnt_mispredict  <= {CNT_W{1'b0}};
            cnt_if_advance  <= {CNT_W{1'b0}};
            cnt_redirect    <= {CNT_W{1'b0}};
        end else if (clr == `True) begin
            cnt_cycle       <= {CNT_W{1'b0}};
            cnt_id_valid    <= {CNT_W{1'b0}};
            cnt_branch      <= {CNT_W{1'b0}};
            cnt_cond_branch <= {CNT_W{1'b0}};
            cnt_jal         <= {CNT_W{1'b0}};
            cnt_jalr        <= {CNT_W{1'b0}};
            cnt_query       <= {CNT_W{1'b0}};
            cnt_hit         <= {CNT_W{1'b0}};
            cnt_mispredict  <= {CNT_W{1'b0}};
            cnt_if_advance  <= {CNT_W{1'b0}};
            cnt_redirect    <= {CNT_W{1'b0}};
        end else begin
            cnt_cycle <= cnt_cycle + {{(CNT_W-1){1'b0}}, 1'b1};

            if (id_valid)       cnt_id_valid <= cnt_id_valid + {{(CNT_W-1){1'b0}}, 1'b1};
            if (id_branch || id_jal || id_jalr)   // 缺陷：未用 id_valid 门控
                                cnt_branch   <= cnt_branch   + {{(CNT_W-1){1'b0}}, 1'b1};
            if (id_valid && id_branch)
                                cnt_cond_branch <= cnt_cond_branch + {{(CNT_W-1){1'b0}}, 1'b1};
            if (id_valid && id_jal)
                                cnt_jal      <= cnt_jal      + {{(CNT_W-1){1'b0}}, 1'b1};
            if (id_valid && id_jalr)
                                cnt_jalr     <= cnt_jalr     + {{(CNT_W-1){1'b0}}, 1'b1};

            if (pred_query)     cnt_query      <= cnt_query      + {{(CNT_W-1){1'b0}}, 1'b1};
            if (pred_query && pred_hit)
                                cnt_hit        <= cnt_hit        + {{(CNT_W-1){1'b0}}, 1'b1};
            if (mispredict)     cnt_mispredict <= cnt_mispredict + {{(CNT_W-1){1'b0}}, 1'b1};

            if (if_advance)     cnt_if_advance <= cnt_if_advance + {{(CNT_W-1){1'b0}}, 1'b1};
            if (redirect)       cnt_redirect   <= cnt_redirect   + {{(CNT_W-1){1'b0}}, 1'b1};
        end
    end

endmodule
