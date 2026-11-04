`timescale 1ns / 1ps

// ============================================================================
//  tb_payload_hold — 同拍响应 × 下游 hold 的载荷保持确定性测试（ICR-001 Gate #3）
//
//  覆盖（随机延迟测试无 if_out 载荷 scoreboard，不能替代本定向用例）：
//    Test 1: IF 在 WAIT 态收到精确响应的同周期，下游 IF/ID 因 hold/if_out_ready=0
//            无法接收。载荷必须落入 skid buffer：
//              1a) ready=1 直写路径正常交付（反向对照，证明检查非恒真）
//              1b/1c) hold 期间 if_out 与 IF/ID 输出保持
//              1d/1e) 响应到达同拍下游无法接收：if_out 不被覆盖，载荷进 skid
//              1f)    buf 占用后 i_rsp_ready=0（背压：内存必须保持响应）
//              1g/1h/1i) ready 恢复同拍又有新响应（历史缺陷窗口）：
//                  buf 提升 vs 新响应直写同拍冲突，修复前中间载荷丢失
//              1j)    第二次同拍窗口（P4 亦经 buf 中转），排空序列完整
//              1k)    非 reset 内容 hold 稳定
//    Test 2: fault 载荷经 skid/hold 保持，fault=1 与 {pc,inst,pred} 同拍交付
//    Final:  载荷 scoreboard —— 5 条 {pc,inst,fault,pred_*} 恰好一次、顺序一致
//
//  激励纪律：每个竞态窗口结束后同一 negedge 立即重新 stall，否则流水线会在
//  下一个 fire 边沿正常排空，后续窗口无法确定性构造。
//  时序约定：所有激励在 NEGEDGE 设置；WAIT 判定用 u_if_stage.state XMR
//  （buf 占用时 i_rsp_ready=0，端口探针失效）；XMR 采样前 #1 等 NBA 落地。
//  载荷 scoreboard 在 POSEDGE 采样握手（读 DUT NBA 旧值 = 本拍被消费的载荷）。
// ============================================================================
`include "defines.sv"

module tb_payload_hold;

    reg clk;
    reg rst;

    reg         redirect_valid;
    reg [31:0]  redirect_target;
    reg         hold_pc;
    reg         hold_if;
    reg         hold_if_id;
    reg         exc_flush;

    reg         i_req_ready;
    reg         i_rsp_valid;
    reg [31:0]  i_rsp_data;
    reg         i_rsp_error;

    reg         if_out_ready;

    // 真实 BTB 查询输出按当前 if_out_pc 关联到 IF/ID，检查同一 PC 的预测载荷。
    reg         train_valid;
    reg [31:0]  train_pc;
    reg         train_taken;
    reg [31:0]  train_target;
    reg         perturb_pred_query;
    wire [31:0] pred_query_pc;
    wire        pred_v;
    wire        pred_t;
    wire [31:0] pred_tgt;
    wire        pred_hit;

    wire [31:0] pc;
    wire        i_req_valid;
    wire [31:0] i_req_addr;
    wire        i_rsp_ready;
    wire        advance_valid;
    wire        if_out_valid;
    wire [31:0] if_out_pc;
    wire [31:0] if_out_inst;
    wire        if_out_fault;

    assign pred_query_pc = perturb_pred_query ? 32'h4 : if_out_pc;

    wire        id_valid;
    wire [31:0] id_pc;
    wire [31:0] id_inst;
    wire        id_fault;
    wire        id_pred_valid;
    wire        id_pred_taken;
    wire [31:0] id_pred_target;

    branch_predictor u_predictor (
        .clk (clk), .rst (rst),
        .q_valid (if_out_valid), .q_pc (pred_query_pc),
        .q_hit (pred_hit), .q_taken (pred_t), .q_target (pred_tgt),
        .u_valid (train_valid), .u_pc (train_pc), .u_taken (train_taken),
        .u_target (train_target), .u_pred_taken (1'b0), .u_pred_target (32'b0),
        .u_exception (1'b0), .stat_clr (1'b0),
        .stat_query (), .stat_hit (), .stat_mispredict ()
    );
    assign pred_v = pred_hit;

    pc_reg u_pc_reg (
        .clk             (clk), .rst (rst),
        .redirect_valid  (redirect_valid), .redirect_target (redirect_target),
        .advance_valid   (advance_valid),
        .pred_valid(1'b0), .pred_target(32'b0),
        .hold_pc         (hold_pc), .pc (pc)
    );

    if_stage u_if_stage (
        .pred_hit_i(1'b0), .pred_taken_i(1'b0), .pred_target_i(32'b0),
        .clk (clk), .rst (rst),
        .pc (pc), .redirect_valid (redirect_valid),
        .hold_if (hold_if), .flush_if (exc_flush),
        .i_req_valid (i_req_valid), .i_req_ready (i_req_ready),
        .i_req_addr (i_req_addr),
        .advance_valid (advance_valid),
        .i_rsp_valid (i_rsp_valid), .i_rsp_ready (i_rsp_ready),
        .i_rsp_data (i_rsp_data), .i_rsp_error (i_rsp_error),
        .if_out_valid (if_out_valid), .if_out_ready (if_out_ready),
        .if_out_pc (if_out_pc), .if_out_inst (if_out_inst),
        .if_out_fault (if_out_fault)
    );

    if_id u_if_id (
        .clk (clk), .rst (rst),
        .if_valid_i (if_out_valid), .if_pc_i (if_out_pc),
        .if_inst_i (if_out_inst), .if_fault_i (if_out_fault),
        .if_pred_valid_i (pred_v), .if_pred_taken_i (pred_t),
        .if_pred_target_i (pred_tgt),
        .hold_if_id (hold_if_id), .flush_if_id (exc_flush),
        .id_valid_o (id_valid), .id_pc_o (id_pc),
        .id_inst_o (id_inst), .id_fault_o (id_fault),
        .id_pred_valid_o (id_pred_valid), .id_pred_taken_o (id_pred_taken),
        .id_pred_target_o (id_pred_target)
    );

    always #5 clk = ~clk;

    integer errors;

    task check;
        input [8*72:0] label;
        input condition;
        begin
            if (!condition) begin
                $display("FAIL [%0d] %0s", $time, label);
                errors = errors + 1;
            end else begin
                $display("PASS [%0d] %0s", $time, label);
            end
        end
    endtask

    // ----------------------------------------------------------
    // 载荷 scoreboard：POSEDGE 采样 if_out 握手（valid&&ready）
    // 读 DUT NBA 旧值 = 本拍被下游消费的载荷
    // ----------------------------------------------------------
    integer    cap_count;
    reg [31:0] cap_pc   [0:31];
    reg [31:0] cap_inst [0:31];
    reg        cap_fault[0:31];
    reg        cap_pred_valid[0:31];
    reg        cap_pred_taken[0:31];
    reg [31:0] cap_pred_target[0:31];

    always @(posedge clk) begin
        if (rst != `RstEnable) begin
            if (if_out_valid === 1'b1 && if_out_ready === 1'b1) begin
                cap_pc[cap_count]    = if_out_pc;
                cap_inst[cap_count]  = if_out_inst;
                cap_fault[cap_count] = if_out_fault;
                cap_pred_valid[cap_count] = pred_v;
                cap_pred_taken[cap_count] = pred_t;
                cap_pred_target[cap_count] = pred_tgt;
                cap_count = cap_count + 1;
            end
        end
    end

    // ----------------------------------------------------------
    // 有界等待：进入 WAIT 态（无论是否背压）—— XMR 判定，#1 等 NBA 落地
    // ----------------------------------------------------------
    task wait_state_wait;
        integer n;
        begin
            n = 0;
            while (u_if_stage.state !== 2'b10 && n < 20) begin
                @(posedge clk);
                #1;
                n = n + 1;
            end
            if (u_if_stage.state !== 2'b10) begin
                $display("FAIL [%0d] helper: DUT never reached WAIT within 20 cycles", $time);
                errors = errors + 1;
            end
        end
    endtask

    // 预先训练真实 BTB：各测试 PC 均预测 taken，目标为 PC+0x01000000。
    task train_prediction;
        input [31:0] train_address;
        begin
            @(negedge clk);
            train_valid  = 1'b1;
            train_pc     = train_address;
            train_taken  = 1'b1;
            train_target = train_address + 32'h0100_0000;
            @(posedge clk);
            #1;
            train_valid = 1'b0;
        end
    endtask

    initial begin
        $dumpfile("build/tb_payload_hold.vcd");
        $dumpvars(0, tb_payload_hold);
    end

    initial begin
        $display("====================================================");
        $display("  Payload Hold Test — same-cycle rsp x downstream hold");
        $display("  ICR-001 Gate #3");
        $display("====================================================");

        errors = 0;
        cap_count = 0;
        clk = 0;
        rst = 1;
        redirect_valid = 0; redirect_target = 0;
        hold_pc = 0; hold_if = 0; hold_if_id = 0; exc_flush = 0;
        i_req_ready = 0; i_rsp_valid = 0; i_rsp_data = 0; i_rsp_error = 0;
        if_out_ready = 1;
        train_valid = 0; train_pc = 0; train_taken = 0; train_target = 0;
        perturb_pred_query = 0;

        repeat (3) @(posedge clk);
        @(negedge clk); rst = 0;

        train_prediction(32'h0);
        train_prediction(32'h4);
        train_prediction(32'h8);
        train_prediction(32'hC);
        train_prediction(32'h10);
        @(negedge clk);

        // ==========================================================
        //  TEST 1: 同拍响应 × 下游 hold —— skid 保持与恰好一次交付
        // ==========================================================
        $display("");
        $display("=== Test 1: response lands while downstream holds ===");

        // P1 = {0x0, INST1, fault=0}：ready=1 直写路径（反向对照基线）
        i_req_ready = 1;
        wait_state_wait();                  // 请求 0x0 fire → WAIT
        @(negedge clk);
        i_rsp_valid = 1;
        i_rsp_data  = 32'h1111_1111;        // INST1 @ 0x0
        i_rsp_error = 0;
        @(posedge clk);                     // E1：直写 if_out
        @(negedge clk);
        i_rsp_valid = 0;
        // 同一 negedge 立即拉下游 hold（若晚一拍 P1 会被正常握手消费）
        if_out_ready = 0;
        hold_if_id   = 1;
        perturb_pred_query = 1;             // 真实 BTB 换查 P2，ID 必须保留 P1 预测字段
        check("Test 1a: direct path fills if_out (control case)",
              if_out_valid === 1'b1 && if_out_pc === 32'h0 && if_out_inst === 32'h1111_1111);

        repeat (2) @(posedge clk);
        check("Test 1b: if_out payload preserved under downstream hold",
              if_out_valid === 1'b1 && if_out_pc === 32'h0 && if_out_inst === 32'h1111_1111);
        check("Test 1c: real BTB query changes while IF/ID preserves held tuple",
              id_valid === 1'b0 && id_pc === 32'h0 && id_inst === `INST_NOP &&
              id_fault === 1'b0 && id_pred_valid === 1'b1 &&
              id_pred_taken === 1'b1 && id_pred_target === 32'h0100_0000 &&
              pred_v === 1'b1 && pred_t === 1'b1 && pred_tgt === 32'h0100_0004);

        // P2 = {0x4, INST2}：同拍「响应到达 × 下游无法接收」→ 必须进 skid buffer
        perturb_pred_query = 0;
        wait_state_wait();                  // 请求 0x4 fire → WAIT
        @(negedge clk);
        i_rsp_valid = 1;
        i_rsp_data  = 32'h2222_2222;        // INST2 @ 0x4
        @(posedge clk);                     // skid edge：rsp fire, ready=0
        @(negedge clk);
        i_rsp_valid = 0;
        check("Test 1d: stalled if_out NOT overwritten by same-cycle response",
              if_out_pc === 32'h0 && if_out_inst === 32'h1111_1111);
        check("Test 1e: IF/ID still held (no premature capture)",
              id_valid === 1'b0);

        // P3 = {0x8, INST3}：buf 已占用 → i_rsp_ready=0（背压），响应保持
        wait_state_wait();                  // 请求 0x8 fire → WAIT
        check("Test 1f: backpressure asserted when skid buffer full",
              i_rsp_ready === 1'b0);
        @(negedge clk);
        i_rsp_valid = 1;                    // P3 保持有效（合法：等待握手）
        i_rsp_data  = 32'h3333_3333;

        // ready 恢复同拍 P3 仍在途：历史缺陷窗口（修复前提升载荷被直写覆盖丢失）
        @(negedge clk);
        if_out_ready = 1;
        hold_if_id   = 0;
        @(posedge clk);                     // 竞态点 #1：提升 + 新响应同拍
        @(negedge clk);
        i_rsp_valid = 0;
        check("Test 1g: promoted payload survives response landing same cycle",
              if_out_pc === 32'h4 && if_out_inst === 32'h2222_2222);
        check("Test 1h: P1 captured into IF/ID exactly once",
              id_valid === 1'b1 && id_pc === 32'h0 && id_inst === 32'h1111_1111);
        check("Test 1i: real BTB metadata captured with P1",
              id_pred_valid === 1'b1 && id_pred_taken === 1'b1 &&
              id_pred_target === 32'h0100_0000);

        // 窗口后立即重新 stall：P2 停在 if_out、P3 停在 buf
        if_out_ready = 0;
        hold_if_id   = 1;
        wait_state_wait();                  // 请求 0xC fire → WAIT（背压）
        @(negedge clk);
        i_rsp_valid = 1;                    // P4 被背压保持
        i_rsp_data  = 32'h4444_4444;        // INST4 @ 0xC

        // 第二次同拍窗口：P2 交付、P3 提升、P4 经 buf 中转
        @(negedge clk);
        if_out_ready = 1;
        hold_if_id   = 0;
        @(posedge clk);                     // 竞态点 #2
        @(negedge clk);
        i_rsp_valid = 0;
        check("Test 1j: second window intact — P3 promoted, P2 captured",
              if_out_pc === 32'h8 && id_pc === 32'h4 && id_inst === 32'h2222_2222);

        // 非 reset 内容的 hold 稳定性：stall 两个周期，IF/ID 与 if_out 均保持
        if_out_ready = 0;
        hold_if_id   = 1;
        repeat (2) @(posedge clk);
        check("Test 1k: IF/ID holds non-reset payload across hold",
              id_valid === 1'b1 && id_pc === 32'h4 && id_inst === 32'h2222_2222 &&
              if_out_pc === 32'h8);

        // ==========================================================
        //  TEST 2: fault 载荷经 skid/hold 保持并恰好一次交付
        // ==========================================================
        $display("");
        $display("=== Test 2: fault payload preserved through skid/hold ===");

        // 释放 hold：P3 交付，P4 提升，请求 0x10 fire → WAIT
        @(negedge clk);
        if_out_ready = 1;
        hold_if_id   = 0;
        @(posedge clk);                     // P3 → IF/ID，P4 → if_out
        @(negedge clk);
        check("Test 2a: P3 captured, P4 promoted",
              id_pc === 32'h8 && if_out_pc === 32'hC);

        // P5 = {0x10, INST5, fault=1}：out 停滞、buf 空 → 响应可进 skid
        if_out_ready = 0;
        hold_if_id   = 1;
        wait_state_wait();                  // 0x10 已在途 → WAIT
        check("Test 2b: skid accepts response while output stalled (buf empty)",
              i_rsp_ready === 1'b1);
        @(negedge clk);
        i_rsp_valid = 1;
        i_rsp_data  = 32'h5555_5555;        // INST5 @ 0x10
        i_rsp_error = 1'b1;                 // fault 载荷
        @(posedge clk);                     // P5 进 buf（fault 同拍锁存）
        @(negedge clk);
        i_rsp_valid = 0;
        i_rsp_error = 0;
        i_req_ready = 0;                    // 停发请求：0x14 停在 REQ
        check("Test 2c: backpressure re-asserted after fault buffered",
              i_rsp_ready === 1'b0);

        // 释放 hold：P4 交付（fault=0），P5 提升（fault=1）
        @(negedge clk);
        if_out_ready = 1;
        hold_if_id   = 0;
        @(posedge clk);                     // P4 → IF/ID，P5 → if_out
        @(negedge clk);
        check("Test 2d: P4 captured with fault=0",
              id_pc === 32'hC && id_fault === 1'b0);
        check("Test 2e: P5 promoted, fault bit held in if_out",
              if_out_pc === 32'h10 && if_out_fault === 1'b1);

        @(posedge clk);                     // P5 → IF/ID
        @(negedge clk);
        check("Test 2f: fault payload delivered exactly once with {pc,inst}",
              id_valid === 1'b1 && id_pc === 32'h10 && id_inst === 32'h5555_5555 &&
              id_fault === 1'b1);
        check("Test 2g: real BTB metadata captured with P5",
              id_pred_valid === 1'b1 && id_pred_taken === 1'b1 &&
              id_pred_target === 32'h0100_0010);

        // ==========================================================
        //  Final: scoreboard — 每条载荷恰好一次、顺序一致
        // ==========================================================
        $display("");
        $display("=== Final: payload scoreboard ===");

        check("Final: exactly 5 payloads delivered", cap_count == 5);
        if (cap_count == 5) begin
            check("Final: seq[0] = P1 full tuple",
                  cap_pc[0] === 32'h0 && cap_inst[0] === 32'h1111_1111 && cap_fault[0] === 1'b0 &&
                  cap_pred_valid[0] === 1'b1 && cap_pred_taken[0] === 1'b1 &&
                  cap_pred_target[0] === 32'h0100_0000);
            check("Final: seq[1] = P2 full tuple",
                  cap_pc[1] === 32'h4 && cap_inst[1] === 32'h2222_2222 && cap_fault[1] === 1'b0 &&
                  cap_pred_valid[1] === 1'b1 && cap_pred_taken[1] === 1'b1 &&
                  cap_pred_target[1] === 32'h0100_0004);
            check("Final: seq[2] = P3 full tuple",
                  cap_pc[2] === 32'h8 && cap_inst[2] === 32'h3333_3333 && cap_fault[2] === 1'b0 &&
                  cap_pred_valid[2] === 1'b1 && cap_pred_taken[2] === 1'b1 &&
                  cap_pred_target[2] === 32'h0100_0008);
            check("Final: seq[3] = P4 full tuple",
                  cap_pc[3] === 32'hC && cap_inst[3] === 32'h4444_4444 && cap_fault[3] === 1'b0 &&
                  cap_pred_valid[3] === 1'b1 && cap_pred_taken[3] === 1'b1 &&
                  cap_pred_target[3] === 32'h0100_000C);
            check("Final: seq[4] = P5 full tuple",
                  cap_pc[4] === 32'h10 && cap_inst[4] === 32'h5555_5555 && cap_fault[4] === 1'b1 &&
                  cap_pred_valid[4] === 1'b1 && cap_pred_taken[4] === 1'b1 &&
                  cap_pred_target[4] === 32'h0100_0010);
        end

        $display("");
        $display("=== Summary ===");
        $display("  Errors: %0d", errors);

        if (errors == 0) begin
            $display("");
            $display("====================================================");
            $display("PASS All payload hold tests completed (0 violations)");
            $display("  ALL PAYLOAD HOLD TESTS PASSED");
            $display("====================================================");
        end else begin
            $display("");
            $display("====================================================");
            $display("  %0d VIOLATION(S) DETECTED", errors);
            $display("====================================================");
        end
        $finish;
    end

    // 兜底超时：所有等待均有界，正常不会触发
    initial begin
        #50000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
