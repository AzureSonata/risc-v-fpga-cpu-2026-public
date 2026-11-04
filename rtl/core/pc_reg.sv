// ============================================================================
//        PC 寄存器模块
//        复位 → 0；顺序 → PC+4；重定向 → 跳转目标；预测命中 → 预测目标；暂停 → 保持
//        成员 A Stage1 — 参考 tinyriscv/pc_reg.v
//
//        BTB 集成（2026-09-28，见 docs/architecture/ADR-BTB-INTEGRATION.md）：
//        新增 pred_valid / pred_target 两个输入。当 IF 对**本拍正在取指的 PC**
//        查询 BTB 且命中、方向预测为 taken 时，PC 应在同一拍直接推进到预测目标，
//        而不是 PC+4。这正是预测取指的收益来源：
//          - 预测在"取到分支的同一拍"就已可用（BTB 用取指 PC 索引），
//            因此 fall-through 路径**尚未被取入流水线**，无需冲刷、无需额外气泡；
//          - 这与 EX 重定向（redirect_valid）语义不同：后者是**误预测恢复**，
//            必须冲刷年轻指令；前者只是换一条取指路径。
//        两个新输入带默认值 1'b0 / 32'b0：未连接时行为与集成前**逐位一致**，
//        既有 testbench 无需改动即可保持零行为变更。
// ============================================================================

`include "defines.sv"

module pc_reg (
    input  wire         clk,
    input  wire         rst,

    // 来自 EX 的分支重定向（最高优先级，误预测恢复）
    input  wire         redirect_valid,
    input  wire [31:0]  redirect_target,

    // 来自 IF 的取指发射信号（IC-BLOCK-002）
    input  wire         advance_valid,      // i_req_valid && i_req_ready

    // 来自全局控制的流水线暂停
    input  wire         hold_pc,

    // 来自 BTB 的预测目标（BTB 集成新增；驱动器须显式连接，标 0 表示不预测）
    input  wire         pred_valid,         // 命中且方向预测 taken
    input  wire [31:0]  pred_target,

    // PC 输出
    output reg  [31:0]  pc
);

    // ------------------------------------------------------------------
    // PC 更新逻辑
    // 优先级：复位 > EX 重定向 > 暂停 > 取指发射（预测目标或顺序 +4）
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            pc <= `CpuResetAddr;
        end else if (redirect_valid == `True) begin
            // 分支/跳转误预测恢复：EX 计算的实际目标（或实际顺序地址）
            pc <= redirect_target;
        end else if (hold_pc == `True) begin
            // 暂停：保持当前 PC（load-use、后端未就绪等）
            pc <= pc;
        end else if (advance_valid == `True) begin
            // 取指请求已发射：命中预测则走预测目标，否则顺序 +4
            pc <= (pred_valid == `True) ? pred_target : (pc + 32'd4);
        end else begin
            // 无任何事件：PC 保持不变
            pc <= pc;
        end
    end
endmodule
