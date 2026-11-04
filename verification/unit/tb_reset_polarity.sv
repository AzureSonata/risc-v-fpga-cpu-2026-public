`timescale 1ns / 1ps

// ============================================================================
//  tb_reset_polarity — 前端复位极性门禁（ICR-001 Gate #4）
//
//  契约（与康文 K1 五个时序模块、成员 B EX/LSU 对齐）：同步复位、高有效。
//  本 TB 给出正向证据，负向对照由 if_stage_negctl_rstpol.sv（低有效突变体）
//  经 --negative-controls 证明"极性接反必然 FAIL"：
//
//    Phase 1: rst=0（非有效电平）下完整取指流程可运行
//             —— 低有效 DUT 将永久处于复位，有界等待 FAIL（负向对照捕获点）
//    Phase 2: 运行中拉高 rst：
//             2a) 上升沿后、采样沿前输出不变 —— 证明非异步复位
//             2b) 下一 posedge 全部状态清零 —— 同步、高有效生效
//             2c) rst 持续期间保持清零
//    Phase 3: rst 释放后恢复正常运行（复位可恢复性）
//
//  覆盖模块：pc_reg / if_stage / if_id（前端全部三个时序模块）。
//  时序约定：激励在 NEGEDGE 设置；XMR 判定前 #1 等 NBA 落地。
// ============================================================================
`include "defines.sv"

module tb_reset_polarity;

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

    reg         pred_v;
    reg         pred_t;
    reg [31:0]  pred_tgt;

    wire [31:0] pc;
    wire        i_req_valid;
    wire [31:0] i_req_addr;
    wire        i_rsp_ready;
    wire        advance_valid;
    wire        if_out_valid;
    wire [31:0] if_out_pc;
    wire [31:0] if_out_inst;
    wire        if_out_fault;

    wire        id_valid;
    wire [31:0] id_pc;
    wire [31:0] id_inst;
    wire        id_fault;

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
        .id_pred_valid_o (), .id_pred_taken_o (), .id_pred_target_o ()
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

    // 有界等待：进入 WAIT 态（XMR + #1 等 NBA 落地）
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

    // 完成一笔取指：调用时须在 WAIT 态
    task fetch_rsp;
        input [31:0] data;
        begin
            @(negedge clk);
            i_rsp_valid = 1;
            i_rsp_data  = data;
            i_rsp_error = 0;
            @(posedge clk);
            @(negedge clk);
            i_rsp_valid = 0;
        end
    endtask

    initial begin
        $dumpfile("build/tb_reset_polarity.vcd");
        $dumpvars(0, tb_reset_polarity);
    end

    initial begin
        $display("====================================================");
        $display("  Reset Polarity Test — sync / active-high (Gate #4)");
        $display("====================================================");

        errors = 0;
        clk = 0;
        rst = 1;
        redirect_valid = 0; redirect_target = 0;
        hold_pc = 0; hold_if = 0; hold_if_id = 0; exc_flush = 0;
        i_req_ready = 0; i_rsp_valid = 0; i_rsp_data = 0; i_rsp_error = 0;
        if_out_ready = 1;
        pred_v = 0; pred_t = 0; pred_tgt = 0;

        repeat (3) @(posedge clk);
        @(negedge clk); rst = 0;

        // ==========================================================
        //  Phase 1: rst=0 下完整取指（低有效 DUT 在此卡死 → 负向对照捕获点）
        // ==========================================================
        $display("");
        $display("=== Phase 1: operation runs with rst INACTIVE (low) ===");

        i_req_ready = 1;
        wait_state_wait();                  // 请求 0x0 fire → WAIT
        fetch_rsp(32'h00000013);            // INST1 @ 0x0
        check("Phase 1a: fetch completed with rst=0 (active-high polarity)",
              if_out_valid === 1'b1 && if_out_pc === 32'h0 &&
              if_out_inst === 32'h00000013);
        @(posedge clk);                     #1;   // P1 → IF/ID，请求 0x4 fire
        check("Phase 1b: IF/ID captured under rst=0 (if_id polarity)",
              id_valid === 1'b1 && id_pc === 32'h0);
        check("Phase 1c: PC advanced under rst=0 (pc_reg polarity)",
              pc === 32'h8);

        // 下游先 stall：P2 直写 if_out 后保持，id 保持 P1 —— rst 上升时
        // if_out_valid / id_valid / i_req_valid / pc 四个状态元素均非零
        @(negedge clk);
        if_out_ready = 0;
        wait_state_wait();                  // 请求 0x4 已在 WAIT
        fetch_rsp(32'h00000013);            // INST2 @ 0x4 → if_out（out 空，直写）
        i_req_ready = 0;                    // 停在 REQ（i_req_valid=1）
        @(posedge clk);                     #1;   // IF/ID 捕获 P2

        // ==========================================================
        //  Phase 2: 运行中拉高 rst —— 同步（非异步）、高有效
        // ==========================================================
        $display("");
        $display("=== Phase 2: mid-operation rst=1 — sync, not async ===");

        @(negedge clk);
        rst = 1;
        #1;                                 // 上升沿后、采样沿前
        // 诊断信息：区分"异步清零"与"i_req_valid 在 WAIT 态本就为 0"
        $display("  [diag 2a] if_out_valid=%b i_req_valid=%b id_valid=%b pc=%08h state=%b",
                 if_out_valid, i_req_valid, id_valid, pc, u_if_stage.state);
        // Stage C 后 i_req_valid 为组合信号，其值取决于状态机当前状态
        // （WAIT 态且无响应同拍时为 0 是**正确**行为）。故本断言改为检查
        // 真正的"非异步清零"性质：状态寄存器与数据寄存器未被异步改变。
        check("Phase 2a: rst rising edge does NOT clear asynchronously",
              if_out_valid === 1'b1 && id_valid === 1'b1 && pc !== 32'h0 &&
              u_if_stage.state !== 2'b00);

        @(posedge clk);                     #1;   // 同步采样沿
        check("Phase 2b: state cleared at first posedge with rst=1 (sync)",
              i_req_valid === 1'b0 && if_out_valid === 1'b0 &&
              id_valid === 1'b0 && pc === 32'h0 &&
              if_out_pc === 32'h0 && if_out_inst === `INST_NOP);

        @(posedge clk);                     #1;
        check("Phase 2c: cleared state held while rst=1",
              i_req_valid === 1'b0 && if_out_valid === 1'b0 && pc === 32'h0);

        // ==========================================================
        //  Phase 3: rst 释放后恢复运行
        // ==========================================================
        $display("");
        $display("=== Phase 3: operation resumes after rst release ===");

        @(negedge clk);
        rst = 0;
        i_req_ready   = 1;
        if_out_ready  = 1;
        wait_state_wait();                  // 复位后首请求 fire → WAIT
        fetch_rsp(32'h00000013);
        check("Phase 3a: fetch resumed after release",
              if_out_valid === 1'b1 && if_out_pc === 32'h0);
        @(posedge clk);                     #1;
        check("Phase 3b: IF/ID capture resumed after release",
              id_valid === 1'b1);

        $display("");
        $display("=== Summary ===");
        $display("  Errors: %0d", errors);

        if (errors == 0) begin
            $display("");
            $display("====================================================");
            $display("PASS All reset polarity tests completed (0 violations)");
            $display("  ALL RESET POLARITY TESTS PASSED");
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
