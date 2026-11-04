// ============================================================================
// ============================================================================
// ============================================================================
//        负向对照突变体（NEGATIVE CONTROL MUTANT）— 故意注入历史缺陷
//        由 scripts/run_tests.py --negative-controls 装载，
//        替换 rtl/core/branch_predictor.sv（配合 tb_predictor_gshare）
//        预期：对应测试必须 FAIL（证明回归能捕获该违规）
//        源：rtl/core/branch_predictor.sv 的已修复版本
//
//        注入缺陷：RAS 压入的返回地址漏加 4 -> 返回预测目标整体偏 4 字节，
//        T3/T4/T6 的栈顶期望值必然不符
//        Branch Target Buffer + 方向预测器
//        Stage2 成员A — 可选两种方向预测组织（PRED_MODE）
//        依据：TECHNICAL_BASELINE.md「分支、Cache 与异常接入」
//
//        设计要点
//        - 查询（IF）为纯组合：命中且方向预测 taken 时输出缓存的 target，
//          否则调用方按 PC+4 顺序取指。
//        - 训练/恢复（EX）在时钟沿：方向计数器 2-bit 饱和（00 强不取 → 11 强取），
//          命中时刷新 target（JALR 的 rs1 可能变化）。
//        - epoch/redirect 由 if_stage 负责，本模块不改变 EX resolve 点、
//          级间字段或 I 端口协议；预测元数据经调用方携带。
//
//        PRED_MODE 两档（默认 0，保证与既有基线行为逐位一致）
//          0 = BIMODAL：方向计数器**内嵌于 BTB 每项**（现行基线方案）
//          1 = GSHARE ：BTB 只存 {valid, tag, target}；方向来自独立 PHT，
//                       索引 = PC[GHR_BITS+1:2] ⊕ GHR
//
//        为何提供 GSHARE 档
//        TECHNICAL_BASELINE.md 第 77 行规定「BTB 冲突率高且资源允许时评估
//        gshare」，本参数即为该"证据触发"升级路径提供可直接切换的实现，
//        免去届时重新开发。RVCoreP 在同 4KB BRAM 前提下测得 gshare 相对
//        bimodal 在 CoreMark 上精度 +4.1pp（0.801 vs 0.760），是切换依据。
//
//        索引 / tag 划分规范（评审检查单 D5）
//        - 索引：PC[IDX_BITS+1 : 2]   —— 取字对齐低位，跳过 bit[1:0]
//        - tag ：PC[31 : IDX_BITS+2]  —— 与索引**无位重叠**
//        反例警示：dummy32 的 branchPredictorGshare.sv:49-50 用
//          index = exPc[IDX_W+1:2]、tag = exPc[31:IDX_W]，位 [IDX_W+1:IDX_W]
//        被索引与 tag 同时占用，等效 tag 少 2 位、别名率上升。本模块的划分
//        是正确的。任何后续改动须保持"索引位宽 + 2 + tag 位宽 = 32"恒等式。
//
//        已知局限（须走接口评审才能消除）
//        GSHARE 档在**训练**时用当前的 GHR 重组索引，而预测时用的是当时的 GHR；
//        若两次之间有其他分支解析，两者可能不一致（经典 gshare 别名问题）。
//        RVCoreP 的做法是把预测时使用的 PHT 索引随流水线保存到 EX
//        （§4.3 "we have to keep the PHT index value used for the prediction"）。
//        本模块接口无此字段，故本档对训练索引采用"当前 GHR 重组"的近似做法
//        （与 dummy32 相同）。要做到精确训练，须新增 u_pred_index 输入，
//        属 ID↔EX 接口变更，须按治理规则提接口评审，不得静默添加。
//
//        外部对照（2026-09-27 核实）
//        - dummy32/rtl/core/branchPredictor.sv：64 项、2-bit 计数器，BIMODAL 档
//          的正确结构对照。
//        - dummy32/rtl/core/branchPredictorGshare.sv：GSHARE 档结构对照（注意其
//          tag/index 位重叠缺陷，勿照抄）。
//        - 注意：lowRISC/ibex 的 rtl/ 中**不存在** BTB/BHT（其
//          ibex_branch_predict.sv 为纯组合静态预测）。早期参考资料把 Ibex 标为
//          本模块的参考实现，该说法已核实为错误。
// ============================================================================

`include "defines.sv"

module branch_predictor #(
    parameter ENTRIES   = 64,     // BTB 项数（直接映射）
    parameter IDX_BITS  = 6,      // log2(ENTRIES)：PC[IDX_BITS+1 : 2] 作为索引
    parameter PRED_MODE = 0,      // 0 = BIMODAL（基线）；1 = GSHARE
    parameter GHR_BITS  = 8,      // GSHARE 档 GHR 宽度 → PHT 深度 = 2^GHR_BITS
    // ---- Stage D4：RAS（返回地址栈）----
    // 默认关闭 → 行为与不含 RAS 时逐位一致（回归安全）。
    // 开启后：BTB 表项增加 is_ret 位；预测一条"返回"指令时目标取自 RAS 栈顶，
    // 而非 BTB 缓存的目标（返回目标随调用点变化，缓存无意义）。
    // 蓝本：biriscv-master/src/core/biriscv_npc.v 的 btb_is_call_w / btb_is_ret_w。
    parameter RAS_ENABLE = 1'b0,
    parameter RAS_DEPTH  = 4      // 返回地址栈深度（biriscv 默认 8）
)(
    input  wire         clk,
    input  wire         rst,

    // ---------------- IF 查询（组合） ----------------
    input  wire         q_valid,          // 本拍确实发起一次预测查询（仅用于统计）
    input  wire [31:0]  q_pc,
    output wire         q_hit,            // BTB 命中
    output wire         q_taken,          // 命中且方向预测 taken
    output wire [31:0]  q_target,         // 命中项缓存的跳转目标

    // ---------------- EX 训练 / 恢复（时钟沿） ----------------
    input  wire         u_valid,          // 本拍 EX 解析了一条控制转移指令
    input  wire [31:0]  u_pc,             // 该指令 PC
    input  wire         u_taken,          // 实际是否跳转
    input  wire [31:0]  u_target,         // 实际目标地址
    input  wire         u_pred_taken,     // 取指时对该指令的方向预测（流水线携带）
    input  wire [31:0]  u_pred_target,    // 取指时使用的预测目标（流水线携带）
    input  wire         u_exception,      // 该指令有异常，不训练预测器（IC-BLOCK-005）

    // ---- Stage D4：RAS 事件（RAS_ENABLE=0 时被常量折叠，不影响行为）----
    // 由 ID/EX 侧判定：call = JAL/JALR 且 rd ∈ {x1,x5}；ret = JALR 且 rs1 ∈ {x1,x5} 且 rd=x0
    input  wire         u_is_call,
    input  wire         u_is_ret,

    // ---------------- 统计 / 对拍 ----------------
    input  wire         stat_clr,
    output reg  [31:0]  stat_query,       // 查询次数
    output reg  [31:0]  stat_hit,         // 命中次数
    output reg  [31:0]  stat_mispredict   // 预测错误次数（方向或目标不一致）
);

    localparam TAG_W       = 32 - IDX_BITS - 2;   // PC 低两位恒 0（RV32I 无压缩）
    localparam [1:0] DIR_WEAK_NOT_TAKEN = 2'b01;
    localparam [1:0] DIR_WEAK_TAKEN     = 2'b10;
    localparam PHT_ENTRIES = (1 << GHR_BITS);

    // BTB 表体（两档共用）
    reg              valid  [0:ENTRIES-1];
    reg [TAG_W-1:0]  tag    [0:ENTRIES-1];
    reg [31:0]       target [0:ENTRIES-1];

    // ---- Stage D4：RAS 状态 ----
    // is_ret 随 BTB 表项一起维护：查询侧只能看到 PC，看不到指令，
    // 因此"这是不是一条返回指令"必须随表项缓存下来（biriscv 同样做法）。
    localparam RAS_PTR_W = (RAS_DEPTH <= 2) ? 1 : $clog2(RAS_DEPTH);
    reg               is_ret  [0:ENTRIES-1];
    reg [31:0]        ras_mem [0:RAS_DEPTH-1];
    reg [RAS_PTR_W:0] ras_cnt;                    // 0..RAS_DEPTH（多 1 位以容纳满栈）
    wire              ras_has = (ras_cnt != 0);
    // 栈顶索引 = ras_cnt - 1。**必须用多 1 位的临时量**再做位截断：
    // 若直接写 ras_cnt[RAS_PTR_W-1:0] - 1'b1，在 RAS_DEPTH=2（RAS_PTR_W=1）时
    // 该表达式只有 1 位，ras_cnt=2 时取位得 0，0-1 的回绕在索引上下文中会被
    // Icarus 判为 x（本模块初版即因此读出 xxxxxxxx）。
    wire [RAS_PTR_W:0] ras_top_idx_w = ras_cnt - 1'b1;
    wire [31:0]       ras_top = ras_has ? ras_mem[ras_top_idx_w[RAS_PTR_W-1:0]]
                                        : 32'h0;

    // 方向状态（按档择一使用）
    reg [1:0]          dir [0:ENTRIES-1];        // BIMODAL：每项 2-bit 计数器
    reg [1:0]          pht [0:PHT_ENTRIES-1];    // GSHARE ：独立 PHT
    reg [GHR_BITS-1:0] ghr;                      // GSHARE ：全局历史寄存器

    // ------------------------------------------------------------------
    // 查询路径（纯组合）
    // ------------------------------------------------------------------
    wire [IDX_BITS-1:0] q_idx  = q_pc[IDX_BITS+1 : 2];
    wire [TAG_W-1:0]    q_tag  = q_pc[31 : IDX_BITS+2];
    wire [GHR_BITS-1:0] q_gidx = q_pc[GHR_BITS+1 : 2] ^ ghr;

    assign q_hit    = valid[q_idx] && (tag[q_idx] == q_tag);
    // Stage D4：命中项若为"返回"且 RAS 非空，目标取栈顶，而非 BTB 缓存值
    //（返回目标随调用点变化，缓存无意义）。RAS_ENABLE=0 时本项被常量折叠，
    //  行为与不含 RAS 时逐位一致。
    wire q_is_ret = valid[q_idx] && is_ret[q_idx];
    assign q_target = (RAS_ENABLE && q_hit && q_is_ret && ras_has) ? ras_top
                                                                   : target[q_idx];

    // ------------------------------------------------------------------
    // 更新路径公共信号
    // ------------------------------------------------------------------
    wire [IDX_BITS-1:0] u_idx  = u_pc[IDX_BITS+1 : 2];
    wire [TAG_W-1:0]    u_tag  = u_pc[31 : IDX_BITS+2];
    wire                u_hit  = valid[u_idx] && (tag[u_idx] == u_tag);
    wire [GHR_BITS-1:0] u_gidx = u_pc[GHR_BITS+1 : 2] ^ ghr;

    // 预测错误：方向不符，或两者都 taken 但目标不同
    wire u_mispredict = u_valid &&
                        ((u_taken !== u_pred_taken) ||
                         (u_taken && u_pred_taken && (u_target != u_pred_target)));

    // ------------------------------------------------------------------
    // BIMODAL 档（PRED_MODE=0）：方向计数器内嵌于 BTB 每项
    // ------------------------------------------------------------------
    generate
    if (PRED_MODE == 0) begin : g_bimodal
        integer bi;
        assign q_taken = q_hit && dir[q_idx][1];

        always @(posedge clk) begin
            if (rst == `RstEnable) begin
                for (bi = 0; bi < ENTRIES; bi = bi + 1)
                    dir[bi] <= DIR_WEAK_NOT_TAKEN;
            end else if (u_valid && !u_exception) begin
                if (!u_hit) begin
                    dir[u_idx] <= u_taken ? DIR_WEAK_TAKEN : DIR_WEAK_NOT_TAKEN;
                end else if (u_taken) begin
                    if (dir[u_idx] != 2'b11) dir[u_idx] <= dir[u_idx] + 2'b01;
                end else begin
                    if (dir[u_idx] != 2'b00) dir[u_idx] <= dir[u_idx] - 2'b01;
                end
            end
        end
    end
    endgenerate

    // ------------------------------------------------------------------
    // GSHARE 档（PRED_MODE=1）：BTB 只存 tag+target，方向来自 PHT[PC 低位 ⊕ GHR]
    // ------------------------------------------------------------------
    generate
    if (PRED_MODE == 1) begin : g_gshare
        integer gi;
        assign q_taken = q_hit && pht[q_gidx][1];

        always @(posedge clk) begin
            if (rst == `RstEnable) begin
                for (gi = 0; gi < PHT_ENTRIES; gi = gi + 1)
                    pht[gi] <= DIR_WEAK_NOT_TAKEN;
                ghr <= {GHR_BITS{1'b0}};
            end else if (u_valid && !u_exception) begin
                // 历史左移，真实方向进最低位
                ghr <= {ghr[GHR_BITS-2:0], u_taken};

                if (!u_hit) begin
                    pht[u_gidx] <= u_taken ? DIR_WEAK_TAKEN : DIR_WEAK_NOT_TAKEN;
                end else if (u_taken) begin
                    if (pht[u_gidx] != 2'b11) pht[u_gidx] <= pht[u_gidx] + 2'b01;
                end else begin
                    if (pht[u_gidx] != 2'b00) pht[u_gidx] <= pht[u_gidx] - 2'b01;
                end
            end
        end
    end
    endgenerate

    // ------------------------------------------------------------------
    // 公共：BTB 表体维护 + 统计（两档共用）
    // ------------------------------------------------------------------
    integer si;
    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            for (si = 0; si < ENTRIES; si = si + 1) begin
                valid[si]  <= 1'b0;
                tag[si]    <= {TAG_W{1'b0}};
                target[si] <= 32'b0;
                is_ret[si] <= 1'b0;
            end
            // Stage D4：RAS 状态必须复位（漏复位会使 ras_cnt 上电为 x，
            // 进而 ras_has / ras_top 全 x —— 本模块初版即因此失败）
            ras_cnt <= {(RAS_PTR_W+1){1'b0}};
            stat_query      <= 32'b0;
            stat_hit        <= 32'b0;
            stat_mispredict <= 32'b0;
        end else begin
            // ---------- 统计 ----------
            if (stat_clr) begin
                stat_query      <= 32'b0;
                stat_hit        <= 32'b0;
                stat_mispredict <= 32'b0;
            end else begin
                if (q_valid)          stat_query      <= stat_query + 32'b1;
                if (q_valid && q_hit) stat_hit        <= stat_hit + 32'b1;
                if (u_mispredict)     stat_mispredict <= stat_mispredict + 32'b1;
            end

            // ---------- BTB 表体 ----------
            if (u_valid && !u_exception) begin
                is_ret[u_idx] <= u_is_ret;              // Stage D4：缓存"是否返回"
                if (!u_hit) begin
                    // 未命中：分配新项（同索引不同标签时覆盖旧项）
                    valid[u_idx]  <= 1'b1;
                    tag[u_idx]    <= u_tag;
                    target[u_idx] <= u_target;
                end else if (u_taken) begin
                    // 命中且 taken：刷新目标（JALR 的 rs1 可能变化）
                    target[u_idx] <= u_target;
                end
            end

            // ---------- Stage D4：RAS 维护（RAS_ENABLE=0 时整块被常量折叠）----------
            if (RAS_ENABLE) begin
                if (u_valid && !u_exception) begin
                    if (u_is_call) begin
                        // 压入返回地址。满栈时**丢弃**而非覆盖——覆盖会污染更早的调用点。
                        if (ras_cnt < RAS_DEPTH) begin
                            ras_mem[ras_cnt[RAS_PTR_W-1:0]] <= u_pc;  // 缺陷：漏 +4
                            ras_cnt <= ras_cnt + 1'b1;
                        end
                    end else if (u_is_ret) begin
                        if (ras_has) ras_cnt <= ras_cnt - 1'b1;   // 弹栈
                    end
                end
            end
        end
    end

endmodule
