// ============================================================================
//        IF Stage (Instruction Fetch)
//        Manages I-port request/response, epoch stale marking, redirect flush
//        Member A Stage1 - TECHNICAL_BASELINE.md V1.1
//
//        IC-BLOCK-006: Single-priority next-state FSM
//        - All state assignments through combinational next-state logic
//        - Fixed WAIT+hold response loss (backpressure via buf_full)
//        - Fixed redirect single-outstanding constraint (epoch stale-drain)
//        - Fixed multiple non-blocking assignment conflicts
//
//        Stage C（ADR-STAGE-C-FETCH-BANDWIDTH.md）：取指带宽重构
//        - 实测问题：i_req_valid 原为寄存输出，导致"响应完成的当拍"无法同时
//          发出下一请求，只能等下一拍。理想存储器下实测吞吐仅 0.47 指令/拍
//          （40 拍 19 条），40 拍仅发出 20 次请求 —— 瓶颈在 IF 自身而非存储器。
//        - 改法：请求呈现改为**组合**；在 WAIT 态、响应本拍完成的同一拍即续发
//          下一请求（early_issue）。
//        - 契约不变：**未完成事务数上限仍为 1**。逐沿核算：响应完成与下一请求
//          被接受发生在同一时钟沿，该沿前后未完成数均为 1。
//        - 预期：理想存储器下吞吐 0.47 → ≈1.00 指令/拍。
// ============================================================================
`include "defines.sv"

module if_stage (
    input  wire         clk,
    input  wire         rst,
    input  wire [31:0]  pc,
    input  wire         redirect_valid,
    input  wire         hold_if,
    input  wire         flush_if,
    output wire         i_req_valid,
    input  wire         i_req_ready,
    output wire [31:0]  i_req_addr,
    output wire         advance_valid,
    input  wire         i_rsp_valid,
    output wire          i_rsp_ready,
    input  wire [31:0]  i_rsp_data,
    input  wire         i_rsp_error,

    // BTB 查询结果（对**本拍正在取指的 pc**）。必须随在途请求锁存，
    // 不能用"响应到达时按 if_pc 重查 BTB"代替：表项可能在取指与交付之间被训练改写，
    // 重查结果与实际取指决策不一致会让恢复逻辑漏掉必需的 redirect。
    // 见 docs/architecture/ADR-BTB-INTEGRATION.md §2.2
    input  wire         pred_hit_i,
    input  wire         pred_taken_i,      // = pred_hit_i && q_taken
    input  wire [31:0]  pred_target_i,

    output reg          if_out_valid,
    input  wire         if_out_ready,
    output reg  [31:0]  if_out_pc,
    output reg  [31:0]  if_out_inst,
    output reg          if_out_fault,
    output reg          if_out_pred_valid,
    output reg          if_out_pred_taken,
    output reg  [31:0]  if_out_pred_target
);

    // ----------------------------------------------------------
    // Internal state and variables
    // ----------------------------------------------------------
    localparam STATE_IDLE  = 2'b00;
    localparam STATE_REQ   = 2'b01;
    localparam STATE_WAIT  = 2'b10;

    // ⚠️ 坑位：本网必须**声明在** state/epoch/req_epoch 之后。若写在它们之前（例如紧跟
    //    `out_slot_free`），Verilog 会把 `state` 当成 **1 位隐式 net**，
    //    `(state == 2'b10)` 恒假 ⇒ 门控静默失效（编译无警告、现象与没修一样）。
    //    （本项目已实测：把本网放在第 89 行时，8 条断言依旧全红。）
    //    本网 = 本拍 §3 是否正在把一笔**新响应直写填充**进输出槽；用途见 §2 的坑位注释。
    wire rsp_accept_fill;

    reg [1:0] state;
    reg [1:0] state_next;
    reg [1:0] epoch;
    reg [31:0] req_pc;
    reg [1:0] req_epoch;
    reg        buf_valid;
    reg [31:0] buf_pc;
    reg [31:0] buf_inst;
    reg        buf_fault;
    // 在途请求携带的预测（与 req_pc/req_epoch 同级）
    reg        req_pred_valid, req_pred_taken;
    reg [31:0] req_pred_target;
    // skid 缓冲携带的预测
    reg        buf_pred_valid, buf_pred_taken;
    reg [31:0] buf_pred_target;

    // Combinational outputs
    wire buf_full = buf_valid && if_out_valid && !if_out_ready;
    assign i_rsp_ready = (state == STATE_WAIT) && !buf_full;
    assign advance_valid = i_req_valid && i_req_ready;
    // 响应可直写 if_out 的条件：输出槽在本拍结束后确实空闲。
    // 若本拍发生 buf 提升（valid && ready && buf 占用），if_out 将被提升载荷
    // 占用，新响应必须改入 buf，否则直写会在同一 always 块中覆盖提升值
    // （非阻塞赋值末次写入生效），造成中间载荷丢失。
    wire out_slot_free = !if_out_valid || (if_out_ready && !buf_valid);

    // 见第 60 行附近的坑位注释：本 assign 必须位于 state/epoch/req_epoch/buf_valid 全部声明之后。
    assign rsp_accept_fill = (state == STATE_WAIT) && i_rsp_valid && i_rsp_ready &&
                             (req_epoch == epoch) && out_slot_free;

    // ----------------------------------------------------------
    // Stage C：请求呈现（组合）
    // ----------------------------------------------------------
    // 设计取舍（重要）：
    //   曾考虑把 redirect/flush 纳入门控以"抑制被放弃的请求"，但那会**改变
    //   REQ 态的既有语义**——原设计允许 REQ 态请求在 redirect 同拍发出并被
    //   drain（这正是 tb_redirect_race Test 2 与 double_req 负控所保护的行为）。
    //   故本轮**不引入该门控**：REQ 态行为与改造前逐拍一致，唯一新增的是
    //   early_issue（WAIT 态响应同拍续发）。把行为变更面压到最小。

    // 响应本拍完成（且属于当前 epoch，非陈旧响应）
    wire rsp_fire = (state == STATE_WAIT) && i_rsp_valid && i_rsp_ready &&
                    (req_epoch == epoch);

    // early_issue：响应完成的**同一拍**即续发下一请求。
    // 这是 Stage C 的全部收益来源——省掉原实现"响应后下一拍才发请求"的空转。
    // redirect/flush 当拍不续发（此情形 FSM 将去 IDLE，不应再发请求）。
    wire early_issue = rsp_fire && !hold_if && !flush_if && !redirect_valid;

    // 请求 valid：
    //   - REQ 态：持续呈现，直到被接受（与改造前一致，含 redirect 同拍）
    //   - WAIT 态：仅在响应完成的同拍续发
    // IDLE 态恒为 0（与改造前一致：改造前也是先转到 REQ 再呈现）。
    assign i_req_valid = (state == STATE_REQ) || early_issue;

    // 请求地址直接用 pc：pc_reg 只在 advance_valid 时推进，故 IDLE/REQ/WAIT
    // 三态下 pc 恒等于"待取地址"。req_pc 仍保留为寄存器——它承担的是
    // "在途请求标签"语义（供陈旧响应比对），与待取地址不是同一件事。
    assign i_req_addr = pc;

    // ----------------------------------------------------------
    // Combinational: next-state logic
    // Single point of truth for state transitions
    // ----------------------------------------------------------
    always @(*) begin
        state_next = state;
        case (state)
            STATE_IDLE: begin
                if (!hold_if) state_next = STATE_REQ;
            end
            STATE_REQ: begin
                if (i_req_ready) state_next = STATE_WAIT;
            end
            STATE_WAIT: begin
                if (i_rsp_valid && i_rsp_ready) begin
                    if (!hold_if && !flush_if) begin
                        // Stage C：若同拍续发的请求已被接受，则新事务立即接续，
                        // 应留在 WAIT 等待其响应；否则回 REQ 继续呈现该请求。
                        if (early_issue && i_req_ready)
                            state_next = STATE_WAIT;
                        else
                            state_next = STATE_REQ;
                    end else
                        state_next = STATE_IDLE;
                end
            end
            default: state_next = STATE_IDLE;
        endcase
    end

    // ----------------------------------------------------------
    // Sequential: all register updates
    // ----------------------------------------------------------
    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            state        <= STATE_IDLE;
            epoch        <= 2'b0;
            req_pc       <= `CpuResetAddr;
            req_epoch    <= 2'b0;
            if_out_valid <= 1'b0;
            if_out_pc    <= `ZeroWord;
            if_out_inst  <= `INST_NOP;
            if_out_fault <= 1'b0;
            buf_valid    <= 1'b0;
            buf_pc       <= `ZeroWord;
            buf_inst     <= `INST_NOP;
            buf_fault    <= 1'b0;
            if_out_pred_valid  <= 1'b0;
            if_out_pred_taken  <= 1'b0;
            if_out_pred_target <= `ZeroWord;
            buf_pred_valid     <= 1'b0;
            buf_pred_taken     <= 1'b0;
            buf_pred_target    <= `ZeroWord;
        end else begin
            // ---- 1. Redirect / Flush: highest priority ----
            if (redirect_valid == `True || flush_if == `True) begin
                epoch       <= epoch + (redirect_valid ? 2'b1 : 2'b0);
                if_out_valid      <= 1'b0;
                if_out_pred_valid <= 1'b0;
                // ⚠️ 坑位：valid 清位时必须把**整组**预测元数据一起清（taken/target 是"随行载荷"）。
                //    只清 valid 会让 taken/target 残留**上一笔**的值，下游若只看这两个字段
                //    （或 TB 做逐笔比对）就会读到"幽灵元数据"。实测探针：
                //    `oV=0 oT=0 oY=0000_0000` 与 `oV=0 oT=1 oY=0100_0000` 两种残留都出现过。
                if_out_pred_taken  <= 1'b0;
                if_out_pred_target <= `ZeroWord;
                buf_valid         <= 1'b0;
                buf_pred_valid    <= 1'b0;
                buf_pred_taken    <= 1'b0;
                buf_pred_target   <= `ZeroWord;

                // 判断是否存在需要 drain 的未完成请求：
                //   - state == STATE_WAIT：已有请求在途中（之前已接受）
                //   - state == STATE_REQ && i_req_valid && i_req_ready：本周期请求被接受（fire）
                // Stage C 保留了此项：REQ 态在 redirect 同拍仍可呈现请求并被接受，
                // 该请求随即成为在途事务，必须 drain 其响应后方可取重定向目标。
                if (state == STATE_WAIT || (state == STATE_REQ && i_req_valid && i_req_ready)) begin
                    // 有未完成请求：检查本周期是否同步收到响应（drain 完成）
                    if (state == STATE_WAIT && i_rsp_valid && i_rsp_ready) begin
                        // 响应本周期到达，已被消费 → 未完成请求立即 drain
                        // 去 IDLE（下一周期根据 hold_if 决定是否发新请求）
                        state <= STATE_IDLE;
                    end else begin
                        // 保持 WAIT 以维持 i_rsp_ready=1，等待稍后到达的陈旧响应
                        // 注意：对于 state==STATE_REQ 且本周期 fire 的情况，请求已被接收，
                        // 需保持 WAIT 以便 drain 该请求的响应
                        state <= STATE_WAIT;
                    end
                end else begin
                    // 无未完成请求：直接回到 IDLE
                    state <= STATE_IDLE;
                end
            end

            // ---- 2. IF output handshake: transfer buffer to output ----
            if (if_out_valid && if_out_ready) begin
                if (buf_valid) begin
                    if_out_valid       <= 1'b1;
                    if_out_pc          <= buf_pc;
                    if_out_inst        <= buf_inst;
                    if_out_fault       <= buf_fault;
                    if_out_pred_valid  <= buf_pred_valid;
                    if_out_pred_taken  <= buf_pred_taken;
                    if_out_pred_target <= buf_pred_target;
                    buf_valid          <= 1'b0;
                    buf_pred_valid     <= 1'b0;
                end else if (!rsp_accept_fill) begin
                    // ⚠️ 坑位（**真实缺陷，2026-10-01 修复**）：`rsp_accept_fill` 这一条门控不可省。
                    //    当 `if_out_valid && if_out_ready`（本拍输出槽被取走）**且没有 buf 可提升**、
                    //    **同时** STATE_WAIT 正把一笔新响应直写进 if_out 时，本 else 分支的
                    //    `if_out_pred_valid <= 1'b0` 会在同一 always 块内**覆盖 §3 刚写入的
                    //    `if_out_pred_valid <= req_pred_valid`**（非阻塞赋值末次写入生效）。
                    //    后果：**只有预测元数据被清掉**，pc/inst/fault 完好 ⇒ 极难察觉。
                    //    症状：`req_pred_*` 正确、`if_out_pc/inst` 正确，但 `if_out_pred_*` 恒 0
                    //    ⇒ tb_payload_hold 的 Test 1c/1i/2g 与 5 条 Final 全红。
                    //    逐拍证据：`t=205000 reqV=1 reqT=1 reqY=01000000 | outV=1 oV=0 oT=0 oY=0`。
                    //    判据：本拍 §3 是否正在"直写填充输出槽"（响应握手 + epoch 命中 + 槽空）。
                    if_out_valid      <= 1'b0;
                    if_out_pred_valid <= 1'b0;
                end
            end

            // ---- 3. Normal state machine (only if no redirect/flush) ----
            if (!(redirect_valid == `True || flush_if == `True)) begin
                case (state)
                    STATE_IDLE: begin
                        if (!hold_if) begin
                            // 请求由组合逻辑在进入 REQ 后呈现；此处只锁存在途标签
                            req_pc         <= pc;
                            req_epoch      <= epoch;
                            req_pred_valid <= pred_hit_i;
                            req_pred_taken <= pred_taken_i;
                            req_pred_target<= pred_target_i;
                            state       <= state_next;
                        end
                    end
                    STATE_REQ: begin
                        state <= state_next;
                    end
                    STATE_WAIT: begin
                        if (i_rsp_valid && i_rsp_ready) begin
                            if (req_epoch == epoch) begin
                                // ⚠️ 坑位（**试错留痕，勿重走**）：这里曾改成
                                //    `if (out_slot_free || (buf_valid && if_out_ready))`，想把
                                //    "同拍提升"也算成空位，结果 8 红 → 12 红。
                                //    错因：`buf_valid && if_out_ready` 时**提升进 if_out 的是旧 buffer 的
                                //    内容**（P_k），而新响应是**更年轻**的 P_{k+1}；把新响应直接写进
                                //    if_out 等于**越过在途的 P_k**（丢指令），故 Test 1g/1j/2a/2c/2d/2e/2f
                                //    集体变红。新响应必须留在 buffer，等下一拍再提升。
                                if (out_slot_free) begin
                                    if_out_valid       <= 1'b1;
                                    if_out_pc          <= req_pc;
                                    if_out_inst        <= i_rsp_data;
                                    if_out_fault       <= i_rsp_error;
                                    if_out_pred_valid  <= req_pred_valid;
                                    if_out_pred_taken  <= req_pred_taken;
                                    if_out_pred_target <= req_pred_target;
                                end else begin
                                    buf_valid       <= 1'b1;
                                    buf_pc          <= req_pc;
                                    buf_inst        <= i_rsp_data;
                                    buf_fault       <= i_rsp_error;
                                    buf_pred_valid  <= req_pred_valid;
                                    buf_pred_taken  <= req_pred_taken;
                                    buf_pred_target <= req_pred_target;
                                end
                            end
                            state <= state_next;
                            // Stage C：续发情形有两种落点，均需为新在途事务锁存标签
                            //   - state_next == STATE_WAIT：early_issue 已被接受（本拍已发出）
                            //   - state_next == STATE_REQ ：请求待下一拍呈现
                            if (state_next == STATE_REQ || state_next == STATE_WAIT) begin
                                req_pc         <= pc;
                                req_epoch      <= epoch;
                                req_pred_valid <= pred_hit_i;
                                req_pred_taken <= pred_taken_i;
                                req_pred_target<= pred_target_i;
                            end
                        end else begin
                            state <= state_next;
                        end
                    end
                    default: state <= STATE_IDLE;
                endcase
            end
        end
    end

endmodule
