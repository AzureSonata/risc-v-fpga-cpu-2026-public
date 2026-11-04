`timescale 1ns / 1ps

// ============================================================================
//  tb_redirect_race — Redirect 同拍竞态确定性测试（ICR-001 Gate #1）
//
//  覆盖三种同拍组合（2026-09-25 独立复核发现 stale-drain 竞态后的回归防护）：
//    Test 1: WAIT 态 redirect_valid 与 i_rsp_valid && i_rsp_ready 同拍
//            响应被握手消费后必须视为 drain 完成，随后必须发出指向
//            redirect_target 的新请求（修复前 FSM 搁浅在 WAIT，无请求发出）
//    Test 2: REQ 态 redirect_valid 与 i_req_valid && i_req_ready 同拍
//            已握手请求即为 in-flight，必须保持 WAIT 等待其响应 drain，
//            不得回到 IDLE 后再次发请求（outstanding<=1）
//    Test 3: redirect_valid 与 flush_if 同拍（WAIT 态，请求在途）
//
//  另含协议监控：outstanding<=1、无孤立响应、结束前 drain 到 0（非搁浅）。
//
//  时序约定：所有激励在 NEGEDGE 设置，保证 DUT 在 POSEDGE 采样稳定。
//  等待类辅助任务均有界，任何 DUT 搁浅都会以 FAIL 而非挂死呈现。
// ============================================================================
`include "defines.sv"

module tb_redirect_race;

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

    wire [31:0] pc;
    wire        i_req_valid;
    wire [31:0] i_req_addr;
    wire        i_rsp_ready;
    wire        advance_valid;
    wire        if_out_valid;
    reg         if_out_ready;
    wire [31:0] if_out_pc;
    wire [31:0] if_out_inst;

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
        .if_out_fault ()
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
    // 协议监控：posedge 捕获 fire 事件，negedge 裁决 outstanding
    // ----------------------------------------------------------
    reg     req_fire;
    reg     rsp_fire;
    integer inflight;
    integer err_outstanding;
    integer err_orphan;

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            req_fire <= 1'b0;
            rsp_fire <= 1'b0;
        end else begin
            req_fire <= i_req_valid && i_req_ready;
            rsp_fire <= i_rsp_valid && i_rsp_ready;
        end
    end

    always @(negedge clk) begin
        if (rst == `RstEnable) begin
            inflight       <= 0;
            err_outstanding <= 0;
            err_orphan      <= 0;
        end else begin
            if (rsp_fire && req_fire) begin
                // 本协议下不可能同时发生（WAIT 无 i_req_valid，REQ 无 i_rsp_ready），
                // 防御分支：数量不变
                inflight <= inflight;
            end else if (rsp_fire) begin
                if (inflight == 0) begin
                    $display("FAIL [%0d] MON: orphaned response (no outstanding req)", $time);
                    err_orphan = err_orphan + 1;
                    errors = errors + 1;
                end
                inflight <= inflight - 1;
            end else if (req_fire) begin
                if (inflight > 0) begin
                    $display("FAIL [%0d] MON: outstanding > 1 (new req while 1 pending)", $time);
                    err_outstanding = err_outstanding + 1;
                    errors = errors + 1;
                end
                inflight <= inflight + 1;
            end
        end
    end

    // ----------------------------------------------------------
    // 有界等待辅助：进入 WAIT（有在途请求）/ 停在 REQ（等待 ready）
    // REQ 判据：i_req_valid=1 且 i_rsp_ready=0（WAIT 时 i_rsp_ready=1）
    // ----------------------------------------------------------
    task wait_wait_state;
        integer n;
        begin
            n = 0;
            while (i_rsp_ready !== 1'b1 && n < 20) begin
                @(posedge clk);
                n = n + 1;
            end
            if (i_rsp_ready !== 1'b1) begin
                $display("FAIL [%0d] helper: DUT never reached WAIT within 20 cycles", $time);
                errors = errors + 1;
            end
        end
    endtask

    task wait_req_state;
        integer n;
        begin
            n = 0;
            while (!(i_req_valid === 1'b1 && i_rsp_ready !== 1'b1) && n < 20) begin
                @(posedge clk);
                n = n + 1;
            end
            if (!(i_req_valid === 1'b1 && i_rsp_ready !== 1'b1)) begin
                $display("FAIL [%0d] helper: DUT never parked in REQ within 20 cycles", $time);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("build/tb_redirect_race.vcd");
        $dumpvars(0, tb_redirect_race);
    end

    integer w;
    integer seen;
    integer drained;

    initial begin
        $display("====================================================");
        $display("  Redirect Race Test — same-cycle redirect/response");
        $display("  ICR-001 Gate #1");
        $display("====================================================");

        errors = 0;
        clk = 0;
        rst = 1;
        redirect_valid = 0; redirect_target = 0;
        hold_pc = 0; hold_if = 0; hold_if_id = 0; exc_flush = 0;
        i_req_ready = 0; i_rsp_valid = 0; i_rsp_data = 0; i_rsp_error = 0;
        if_out_ready = 1;

        repeat (3) @(posedge clk);
        @(negedge clk); rst = 0;

        // ==========================================================
        //  TEST 1: WAIT 态 redirect + 响应同拍
        // ==========================================================
        $display("");
        $display("=== Test 1: Redirect + Response same cycle (WAIT) ===");

        i_req_ready = 1;
        wait_wait_state();              // 首请求 fire，进入 WAIT

        @(negedge clk);
        redirect_target = 32'hF000_0000;
        redirect_valid  = 1;
        i_rsp_valid     = 1;
        i_rsp_data      = 32'h00000013;
        i_rsp_error     = 0;

        @(posedge clk);                 // redirect + response 同拍（竞态点）
        // 修复后：响应被消费 => drain 完成 => IDLE，随后发 target 新请求
        // 修复前：响应被消费但 FSM 停留 WAIT（搁浅）

        @(negedge clk);
        redirect_valid = 0;
        i_rsp_valid = 0;
        check("Test 1a: PC updated to redirect_target", pc === 32'hF000_0000);

        // 1b：drain 后必须在数拍内发出指向 target 的新请求（非搁浅证据）
        seen = 0;
        for (w = 0; w < 6 && !seen; w = w + 1) begin
            @(negedge clk);
            if (i_req_valid === 1'b1 && i_req_addr === 32'hF000_0000)
                seen = 1;
        end
        check("Test 1b: new target request issued after same-cycle drain", seen !== 0);

        // 流水恢复：该请求 fire 进入 WAIT，正常响应后继续取指
        wait_wait_state();
        @(negedge clk);
        i_rsp_valid = 1;
        i_rsp_data  = 32'h00000013;
        // Stage C 适配（非功能退化）：本拍**不**允许续发请求被接受。
        // 改造前 FSM 在响应消费后总是回到 REQ；改造后若 i_req_ready=1，
        // early_issue 会在同一拍被接受，FSM 直接留在 WAIT（吞吐提升的体现）。
        // 要让 FSM 落回 REQ 以便构造 Test 2 的前置状态，须令 ready=0。
        i_req_ready = 0;
        @(posedge clk);                 // 响应消费；early_issue 未被接受 => 进入 REQ
        @(negedge clk);
        i_rsp_valid = 0;

        // ==========================================================
        //  TEST 2: REQ 态 redirect + 请求握手同拍
        // ==========================================================
        $display("");
        $display("=== Test 2: Redirect + request fire same cycle (REQ) ===");

        wait_req_state();               // 停在 REQ
        @(negedge clk);
        i_req_ready = 0;
        repeat (2) @(posedge clk);      // 确认停在 REQ

        @(negedge clk);
        redirect_target = 32'hABCD_0000;
        redirect_valid  = 1;
        i_req_ready     = 1;            // 同拍 fire

        @(posedge clk);                 // fire + redirect 同拍（竞态点）
        // 修复后：已握手请求记为 in-flight，保持 WAIT 等待 drain
        // 缺陷态：回 IDLE 后再发请求 => outstanding>1

        @(negedge clk);
        redirect_valid = 0;
        i_req_ready = 0;
        check("Test 2a: kept WAIT (i_rsp_ready=1) to drain accepted req", i_rsp_ready === 1'b1);

        @(negedge clk);
        i_rsp_valid = 1;                // 陈旧响应
        i_rsp_data  = 32'h00000013;

        @(posedge clk);                 // drain：握手并丢弃（epoch 已递增）
        @(negedge clk);
        i_rsp_valid = 0;
        check("Test 2b: new request issued after drain (addr=redirect_target)",
              i_req_valid === 1'b1 && i_req_addr === 32'hABCD_0000);

        // 该新请求 fire 并正常响应，恢复流水
        @(negedge clk);
        i_req_ready = 1;
        wait_wait_state();
        @(negedge clk);
        i_rsp_valid = 1;
        i_rsp_data  = 32'h00000013;
        @(posedge clk);
        @(negedge clk);
        i_rsp_valid = 0;
        i_req_ready = 0;

        // ==========================================================
        //  TEST 3: redirect + flush 同拍（WAIT 态，请求在途）
        // ==========================================================
        $display("");
        $display("=== Test 3: Redirect + Flush same cycle (WAIT) ===");

        @(negedge clk);
        i_req_ready = 1;                // 发出请求并进入 WAIT（在途无响应）
        wait_wait_state();

        @(negedge clk);
        redirect_valid = 1;
        exc_flush      = 1;
        i_req_ready    = 0;

        @(posedge clk);                 // redirect + flush 同拍
        // 请求在途且无同拍响应：保持 WAIT 等 drain，epoch 递增

        @(negedge clk);
        redirect_valid = 0;
        exc_flush      = 0;

        @(negedge clk);
        i_rsp_valid = 1;                // 陈旧响应
        i_rsp_data  = 32'h00000013;
        i_req_ready = 1;

        @(posedge clk);                 // drain：握手丢弃 => 发新请求
        @(negedge clk);
        i_rsp_valid = 0;
        check("Test 3: new request issued after redirect+flush drain",
              i_req_valid === 1'b1);

        // ==========================================================
        //  收尾：drain 所有在途请求，确认 FSM 未搁浅、协议无违规
        // ==========================================================
        $display("");
        $display("=== Final: drain and protocol summary ===");

        i_req_ready = 0;
        drained = 0;
        for (w = 0; w < 20 && !drained; w = w + 1) begin
            if (inflight === 0) begin
                drained = 1;
            end else begin
                @(negedge clk);
                i_rsp_valid = (i_rsp_ready === 1'b1);
                i_rsp_data  = 32'h00000013;
                @(posedge clk);
            end
        end
        @(negedge clk);
        i_rsp_valid = 0;
        check("Final: outstanding drained to 0 (FSM not stranded)", drained !== 0);
        check("Final: no orphan-response events", err_orphan == 0);
        check("Final: no outstanding>1 events", err_outstanding == 0);

        $display("");
        $display("=== Summary ===");
        $display("  Errors: %0d", errors);

        if (errors == 0) begin
            $display("");
            $display("====================================================");
            $display("PASS All redirect race tests completed (0 violations)");
            $display("  ALL REDIRECT RACE TESTS PASSED");
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
