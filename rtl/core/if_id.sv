// ============================================================================
//        IF/ID 级间寄存器
//        在 IF 与 ID 之间寄存 {valid, pc, inst, fault, pred_*}
//        支持 hold（暂停保持）与 flush（冲刷清空）
//        参考：tinyriscv/if_id.v
//
//        背压约定（重要，已于 2026-09-28 两线集成时订正）：
//        if_ready_o = !hold_if_id && !flush_if_id —— 即"只有在本拍确实会
//        锁存新数据时才报告 ready"。
//
//        历史教训（D-8，集成期发现的真实缺陷）：
//          旧版本写作 `assign if_ready_o = `True;`（恒 1），理由是"hold 时
//          本模块保持原值、同时 hold_if_id 也广播给 if_stage.hold_if，两侧同步
//          冻结"。该理由是**错的**：if_stage 的 IF→IF/ID 输出握手
//          （if_out_valid && if_out_ready）并没有用 hold_if 门控，而恒 1 的
//          if_ready_o 让它误判"下游已取走"，于是在 hold 期间把 IF 输出槽里的
//          指令丢弃 —— 与 TASK-012 完整 CPU 集成后表现为最后一条指令永久
//          丢失、retire 数少 1。
//          该缺陷未被 210 项前端单元测试发现，原因是那些测试把 if_out_ready
//          作为独立 tb 寄存器并在 hold 时手工置 0（即无意中模拟了正确语义），
//          从未连接真实的 if_id.if_ready_o。教训：级间握手信号必须在**真实
//          对端相连**的条件下验证，不能用模型信号代替。
//          同时，if_stage 内部 `buf_full = buf_valid && if_out_valid &&
//          !if_out_ready` 这一项也只有在 if_out_ready 真会拉低时才有意义。
//          改回真实 ready 语义后，该式恢复有效性，且 flush 当拍 if_ready=0，
//          顺带堵住"flush 同拍从 skid 缓冲提升陈旧载荷"的隐患。
//        （另一条修复记录：原文件在 synthesis translate_off 块内重复出现一条
//         assign if_ready_o，构成同一 wire 的双驱动，已删除；本文件保持
//         单驱动。）
// ============================================================================

`include "defines.sv"

module if_id (

    input  wire         clk,
    input  wire         rst,

    // 来自 IF 阶段
    input  wire         if_valid_i,
    output wire         if_ready_o,         // !hold && !flush：见文件头背压约定
    input  wire [31:0]  if_pc_i,
    input  wire [31:0]  if_inst_i,
    input  wire         if_fault_i,
    input  wire         if_pred_valid_i,    // BTB 命中
    input  wire         if_pred_taken_i,    // 预测方向
    input  wire [31:0]  if_pred_target_i,   // 预测目标

    // 全局控制
    input  wire         hold_if_id,         // 暂停：保持当前值
    input  wire         flush_if_id,        // 冲刷：清空 valid

    // 输出到 ID 阶段
    output reg          id_valid_o,
    output reg  [31:0]  id_pc_o,
    output reg  [31:0]  id_inst_o,
    output reg          id_fault_o,
    output reg          id_pred_valid_o,
    output reg          id_pred_taken_o,
    output reg  [31:0]  id_pred_target_o
);

    // ------------------------------------------------------------------
    // IF/ID 级间寄存器
    // hold 时保持；flush 时清 valid；否则从 IF 锁存
    // ready 必须与本拍的真实行为一致：只有"确实会锁存"才是 ready，
    // 否则上游会在 hold 期间误以为载荷已被取走而丢弃它（D-8）。
    // 复位期间同样不锁存，故 ready 也应为 0。
    // ------------------------------------------------------------------
    assign if_ready_o = (rst != `RstEnable) && !hold_if_id && !flush_if_id;

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            id_valid_o       <= 1'b0;
            id_pc_o          <= `ZeroWord;
            id_inst_o        <= `INST_NOP;
            id_fault_o       <= 1'b0;
            id_pred_valid_o  <= 1'b0;
            id_pred_taken_o  <= 1'b0;
            id_pred_target_o <= `ZeroWord;
        end else if (flush_if_id == `True) begin
            // 冲刷：插入空泡
            id_valid_o  <= 1'b0;
            id_pc_o     <= `ZeroWord;
            id_inst_o   <= `INST_NOP;
            id_fault_o  <= 1'b0;
            id_pred_valid_o  <= 1'b0;
            id_pred_taken_o  <= 1'b0;
            id_pred_target_o <= `ZeroWord;
        end else if (hold_if_id == `True) begin
            // 暂停：保持当前值不变
            id_valid_o  <= id_valid_o;
            id_pc_o     <= id_pc_o;
            id_inst_o   <= id_inst_o;
            id_fault_o  <= id_fault_o;
            id_pred_valid_o  <= id_pred_valid_o;
            id_pred_taken_o  <= id_pred_taken_o;
            id_pred_target_o <= id_pred_target_o;
        end else begin
            // 正常：从 IF 锁存
            id_valid_o  <= if_valid_i;
            id_pc_o     <= if_pc_i;
            id_inst_o   <= if_inst_i;
            id_fault_o  <= if_fault_i;
            id_pred_valid_o  <= if_pred_valid_i;
            id_pred_taken_o  <= if_pred_taken_i;
            id_pred_target_o <= if_pred_target_i;
        end
    end

    // 仿真断言：hold 与 flush 不得同拍断言（语义冲突，优先级未定义）
    // synthesis translate_off
    always @(posedge clk) begin
        if (hold_if_id == `True && flush_if_id == `True) begin
            $error("if_id: hold and flush asserted simultaneously");
        end
    end
    // synthesis translate_on

endmodule
