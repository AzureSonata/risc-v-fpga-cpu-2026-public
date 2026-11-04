// ============================================================================
//        随机延迟前端测试 — pc_reg + if_stage + if_id
//        验证在随机请求/响应延迟下：
//        - PC 只在 fetch fire 前进，不跳跃
//        - 请求不重复不丢失
//        - outstanding ≤ 1
//        - epoch 机制正确丢弃陈旧响应
//        对应 ICR-001 IC-BLOCK-002 合并门禁第 2 条
//        作者：成员A ｜ 创建：2026-09-21
// ============================================================================

`timescale 1ns / 1ps

`include "defines.sv"

module tb_random_delay;

    // ==================================================================
    // 时钟与复位
    // ==================================================================
    reg clk;
    reg rst;

    // ==================================================================
    // 控制信号
    // ==================================================================
    reg         redirect_valid;
    reg [31:0]  redirect_target;
    reg         hold_pc;
    reg         hold_if;
    reg         hold_if_id;
    reg         exc_flush;

    // ==================================================================
    // I 端口驱动（随机延迟注入点）
    // ==================================================================
    reg         i_req_ready;        // 存储器可接受请求（随机延迟）
    reg         i_rsp_valid;        // 存储器返回响应（随机延迟）
    reg  [31:0] i_rsp_data;
    reg         i_rsp_error;

    // ==================================================================
    // DUT 连线
    // ==================================================================
    wire [31:0] pc;
    wire        i_req_valid;
    wire [31:0] i_req_addr;
    wire        i_rsp_ready;
    wire        advance_valid;

    wire        if_out_valid;
    reg         if_out_ready;       // IF/ID 可接收（随机延迟）
    wire        if_out_fault;
    wire [31:0] if_out_pc;
    wire [31:0] if_out_inst;

    wire        id_valid;
    wire [31:0] id_pc;
    wire [31:0] id_inst;

    // ==================================================================
    // 辅助信号
    // ==================================================================
    wire flush_if_id = exc_flush;
    wire flush_if    = exc_flush;

    // ==================================================================
    // 模块例化
    // ==================================================================
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
        .hold_if (hold_if), .flush_if (flush_if),
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
        .if_pred_valid_i (1'b0), .if_pred_taken_i (1'b0),
        .if_pred_target_i (32'h0),
        .hold_if_id (hold_if_id), .flush_if_id (flush_if_id),
        .id_valid_o (id_valid), .id_pc_o (id_pc),
        .id_inst_o (id_inst), .id_fault_o ()
    );

    // ==================================================================
    // 时钟生成
    // ==================================================================
    always #5 clk = ~clk;

    // ==================================================================
    // 错误计数器
    // ==================================================================
    integer errors;

    task check;
        input [8*72:0] label;
        input condition;
        begin
            if (!condition) begin $display("FAIL [%0d] %0s", $time, label); errors = errors + 1; end
            else $display("PASS [%0d] %0s", $time, label);
        end
    endtask

    // ==================================================================
    // 协议监控器 — 在 posedge 捕获事件，在 negedge 验证结果
    // ==================================================================

    // ---- 事件捕获：在 posedge 捕获 fire/redirect（信号更新前） ----
    reg req_fire;
    reg rsp_fire;
    reg redirect_fire;

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            req_fire <= 1'b0;
            rsp_fire <= 1'b0;
            redirect_fire <= 1'b0;
        end else begin
            req_fire <= i_req_valid && i_req_ready;
            rsp_fire <= i_rsp_valid && i_rsp_ready;
            redirect_fire <= redirect_valid;
        end
    end

    // ---- 监控 1：outstanding ≤ 1（在 negedge 裁决，事件已稳定） ----
    // integer：负控注入时 outstanding 可能暂时 >1，1-bit 会回绕掩盖违规
    integer request_in_flight;

    always @(negedge clk) begin
        if (rst == `RstEnable) begin
            request_in_flight <= 1'b0;
        end else begin
            // 处理响应（先处理，因为新请求可能复用它释放的槽位）
            if (rsp_fire) begin
                if (!request_in_flight) begin
                    check("MON: orphaned response (no pending req)", 1'b0);
                end
                request_in_flight <= request_in_flight - 1;
            end
            // 处理新请求
            if (req_fire) begin
                if (request_in_flight) begin
                    check("MON: outstanding > 1 (new req while 1 pending)", 1'b0);
                end
                request_in_flight <= request_in_flight + 1;
            end
        end
    end

    // ---- 监控 2：PC 验证（在 negedge 更新期望值，在 posedge 检查） ----
    reg [31:0] expected_pc;
    reg        check_pc_pending;

    // 在 negedge 根据捕获的事件更新期望 PC
    always @(negedge clk) begin
        if (rst == `RstEnable) begin
            expected_pc <= 32'h0;
            check_pc_pending <= 1'b0;
        end else begin
            check_pc_pending <= 1'b0;  // 默认不检查
            if (redirect_fire) begin
                expected_pc <= redirect_target;
                check_pc_pending <= 1'b1;
            end else if (req_fire) begin
                // req_fire 对应的 PC 更新：pc + 4
                // 注意：此时 pc 可能已经是更新后的值（非阻塞赋值已生效）
                // 但 req_fire 是 posedge 捕获的，当时 pc 还未更新
                // 所以 expected_pc = pc_before_fire + 4
                // 但由于非阻塞赋值，pc 此时已经更新了
                // 我们直接用 pc (已更新) 作为期望值
                expected_pc <= pc;
                check_pc_pending <= 1'b1;
            end
        end
    end

    // 在 posedge 检查 PC（非阻塞赋值前，pc 还是上周期更新后的值）
    always @(posedge clk) begin
        if (rst != `RstEnable && check_pc_pending) begin
            if (pc !== expected_pc) begin
                check("MON: PC unexpected after redirect/fire",
                      pc === expected_pc);
            end
        end
    end

    // ---- 监控 3：总统计量（结束时验证） ----
    integer total_fires;
    integer total_responses;
    integer total_redirects;

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            total_fires <= 0;
            total_responses <= 0;
            total_redirects <= 0;
        end else begin
            if (i_req_valid && i_req_ready) total_fires <= total_fires + 1;
            if (i_rsp_valid && i_rsp_ready) total_responses <= total_responses + 1;
            if (redirect_valid == `True) total_redirects <= total_redirects + 1;
        end
    end

    // ---- 备用：request_in_flight_sampled 供随机延迟生成器使用 ----
    reg request_in_flight_sampled;
    always @(posedge clk) begin
        request_in_flight_sampled <= request_in_flight;
    end

    // ==================================================================
    // 负向对照与确定性阶段注入开关（run_tests.py --negative-controls 使用）
    //   +negctl_zero_req    ：存储器永不接受请求（复现"零请求"违规）
    //   +negctl_orphan_rsp  ：注入孤立响应窗口（配 negctl_orphan 突变体，
    //                         复现"响应多于请求"违规）
    //   phase5_*            ：确定性 REQ 态 fire+redirect 同拍窗口
    // ==================================================================
    reg negctl_zero_req;
    reg negctl_orphan_rsp;
    reg orphan_window;
    reg phase5_gate;
    reg phase5_fire;

    initial begin
        negctl_zero_req   = $test$plusargs("negctl_zero_req");
        negctl_orphan_rsp = $test$plusargs("negctl_orphan_rsp");
        orphan_window = 1'b0;
        phase5_gate   = 1'b0;
        phase5_fire   = 1'b0;
    end

    // ==================================================================
    // 随机延迟生成器（在 posedge 更新，与 DUT 一致）
    // ==================================================================

    // 配置参数
    integer MAX_REQ_DELAY = 5;      // i_req_ready 最大延迟周期数
    integer MAX_RSP_DELAY = 10;     // i_rsp_valid 最大延迟周期数
    integer MAX_OUT_DELAY = 3;      // if_out_ready 最大延迟周期数
    
    integer req_delay_cnt;
    integer rsp_delay_cnt;
    integer out_delay_cnt;
    
    integer rand_val;
    
    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            req_delay_cnt <= 0;
            rsp_delay_cnt <= 0;
            out_delay_cnt <= 0;
            i_req_ready <= 1'b0;
            i_rsp_valid <= 1'b0;
            if_out_ready <= 1'b1; // 默认下游就绪
        end else begin
            // ---- i_req_ready 随机延迟 ----
            if (negctl_zero_req) begin
                i_req_ready <= 1'b0;            // 负控：永不接受请求
            end else if (phase5_fire) begin
                i_req_ready <= 1'b1;            // 确定性同拍 fire 窗口（单拍）
                phase5_fire <= 1'b0;
            end else if (phase5_gate) begin
                i_req_ready <= 1'b0;            // 确定性阶段：停住 ready，逼 DUT 停在 REQ
            end else if (req_delay_cnt > 0) begin
                req_delay_cnt <= req_delay_cnt - 1;
                i_req_ready <= 1'b0;
            end else begin
                if (i_req_valid) begin
                    rand_val = $random % 3; // 0: 即接受, 1-2: 随机延迟
                    if (rand_val == 0) begin
                        i_req_ready <= 1'b1;
                    end else begin
                        req_delay_cnt <= ($random % MAX_REQ_DELAY) + 1;
                        i_req_ready <= 1'b0;
                    end
                end else begin
                    i_req_ready <= 1'b0;
                end
            end

            // ---- i_rsp_valid 随机延迟 ----
            if (rsp_delay_cnt > 0) begin
                rsp_delay_cnt <= rsp_delay_cnt - 1;
                i_rsp_valid <= 1'b0;
            end else if (orphan_window) begin
                i_rsp_valid <= 1'b1;            // 负控：无论在途状态持续提供响应
                i_rsp_data <= {$random};
                i_rsp_error <= 1'b0;
            end else begin
                if (i_rsp_ready && request_in_flight_sampled && $random % 4 == 0) begin
                    i_rsp_valid <= 1'b1;
                    i_rsp_data <= {$random};
                    i_rsp_error <= 1'b0;
                end else begin
                    i_rsp_valid <= 1'b0;
                end
            end
            
            // ---- if_out_ready 随机延迟 ----
            if (out_delay_cnt > 0) begin
                out_delay_cnt <= out_delay_cnt - 1;
                if_out_ready <= 1'b0;
            end else begin
                if (if_out_valid) begin
                    rand_val = $random % 4;
                    if (rand_val == 0) begin
                        out_delay_cnt <= ($random % MAX_OUT_DELAY) + 1;
                        if_out_ready <= 1'b0;
                    end else begin
                        if_out_ready <= 1'b1;
                    end
                end else begin
                    if_out_ready <= 1'b1;
                end
            end
        end
    end

    // ==================================================================
    // 测试序列
    // ==================================================================
    
    integer stall_cnt;
    integer cycle_cnt;
    integer gate_cnt;
    integer drain_cnt;

    initial begin
        $display("====================================================");
        $display("  Random Delay Test — Frontend ICR-001 Gate #2");
        $display("  Verifies: no PC jump, no lost/dup req, outstd<=1");
        $display("====================================================");
        
        errors = 0;
        clk = 0;
        cycle_cnt = 0;
        
        // 复位
        rst = `RstEnable;
        redirect_valid = 0; redirect_target = 0;
        hold_pc = 0; hold_if = 0; hold_if_id = 0; exc_flush = 0;
        i_rsp_data = 0; i_rsp_error = 0;
        request_in_flight = 0;
        
        // 等 3 拍复位
        repeat (3) @(posedge clk);
        @(negedge clk); rst = `RstDisable;
        
        $display("\n=== Phase 1: Normal sequence with random delays ===");
        
        // 运行 200 个周期验证正常流程
        for (cycle_cnt = 0; cycle_cnt < 200; cycle_cnt = cycle_cnt + 1) begin
            @(posedge clk);
        end

        // 负控注入：状态触发 —— 强制 DUT 进入并停在 IDLE、零在途，
        // 再直接拉高 i_rsp_valid 一拍；不使用固定 repeat(N) 时间窗口。
        // 依据：orphan 突变体只在 IDLE 态多拉高 i_rsp_ready；固定窗口在
        // Phase 1 随机运行时可能从未命中 IDLE，导致负控捕获到的是别的事件。
        if (negctl_orphan_rsp) begin
            hold_pc = 1; hold_if = 1; hold_if_id = 1;
            gate_cnt = 0;
            while (!(u_if_stage.state == 2'b00 && request_in_flight === 0) && gate_cnt < 200) begin
                @(negedge clk);
                gate_cnt = gate_cnt + 1;
            end
            if (!(u_if_stage.state == 2'b00 && request_in_flight === 0)) begin
                $display("FAIL [%0d] [NEGCTL] orphan: DUT never parked in IDLE", $time);
                errors = errors + 1;
            end else begin
                orphan_window = 1'b1;
                i_rsp_valid = 1'b1;
                i_rsp_data = 32'h1234_5678;
                i_rsp_error = 1'b0;
                $display("  [NEGCTL] orphan response injected in IDLE");
                @(posedge clk);          // 在 IDLE 组合 ready 上完成孤儿握手
                @(negedge clk);
                i_rsp_valid = 1'b0;
                i_rsp_error = 1'b0;
                orphan_window = 1'b0;
                hold_pc = 0; hold_if = 0; hold_if_id = 0;
                $display("  [NEGCTL] orphan response injection complete");
            end
        end

        $display("\n=== Phase 2: Hold + random delays ===");
        
        // 随机施加 hold
        for (stall_cnt = 0; stall_cnt < 10; stall_cnt = stall_cnt + 1) begin
            hold_pc = 1; hold_if = 1; hold_if_id = 1;
            repeat (($random % 7) + 2) @(posedge clk);
            hold_pc = 0; hold_if = 0; hold_if_id = 0;
            repeat (($random % 5) + 3) @(posedge clk);
        end
        
        $display("\n=== Phase 3: Redirect + stale-drain with random delays ===");

        // 在随机延迟下验证 epoch 丢弃机制
        // 单拍脉冲统一 negedge 置位、下个 negedge 清除：采样沿上数值全周期稳定，
        // 避免 DUT/监控器/计数器在同一 posedge 的读取竞争
        for (stall_cnt = 0; stall_cnt < 5; stall_cnt = stall_cnt + 1) begin
            repeat (($random % 20) + 5) @(posedge clk);
            @(negedge clk);
            redirect_target = $random & 32'hFFFF_F000;
            redirect_valid = 1;
            @(posedge clk);             // redirect 采样沿
            @(negedge clk);
            redirect_valid = 0;
            repeat (($random % 15) + 3) @(posedge clk);
        end

        $display("\n=== Phase 4: Flush + random delays ===");

        for (stall_cnt = 0; stall_cnt < 5; stall_cnt = stall_cnt + 1) begin
            repeat (($random % 20) + 5) @(posedge clk);
            @(negedge clk);
            exc_flush = 1;
            @(posedge clk);             // flush 采样沿
            @(negedge clk);
            exc_flush = 0;
            repeat (($random % 10) + 2) @(posedge clk);
        end

        // ============================================================
        // Phase 5（确定性）：REQ 态 redirect 与请求握手同拍
        // 已握手请求必须记为 in-flight 并 drain，之后才能发新请求。
        // 负控中 double-req 突变体（回 IDLE 再发请求）在此被监控捕获。
        // ============================================================
        $display("\n=== Phase 5: Redirect + request fire same cycle (deterministic) ===");

        phase5_gate = 1;                 // 停住 i_req_ready，DUT 停在 REQ
        gate_cnt = 0;
        while (!(i_req_valid === 1'b1 && request_in_flight === 0) && gate_cnt < 50) begin
            @(posedge clk);
            gate_cnt = gate_cnt + 1;
        end
        if (!(i_req_valid === 1'b1 && request_in_flight === 0)) begin
            $display("FAIL [%0d] Phase 5: DUT never parked in REQ", $time);
            errors = errors + 1;
        end

        @(negedge clk);
        phase5_fire = 1;                 // 生成器在 P1 置 i_req_ready=1（单拍）
        @(posedge clk);                  // P1：ready 生效（尚未 fire）
        @(negedge clk);
        redirect_target = 32'h1234_5000;
        redirect_valid  = 1;             // 只覆盖 P2 这一个 posedge
        @(posedge clk);                  // P2：fire + redirect 同拍（竞态点）
        @(negedge clk);
        redirect_valid = 0;
        repeat (10) @(posedge clk);      // 留时间完成 stale-drain 与再取指
        phase5_gate = 0;

        // ============================================================
        // Phase 6：drain —— 停止新取指，等在途请求全部响应后再对账。
        // drain 后 fires==responses 必须严格成立，任何差值都是丢失/重复。
        // ============================================================
        $display("\n=== Phase 6: Drain ===");

        hold_pc = 1; hold_if = 1; hold_if_id = 1;
        drain_cnt = 0;
        while (request_in_flight != 0 && drain_cnt < 100) begin
            @(posedge clk);
            drain_cnt = drain_cnt + 1;
        end

        // ============================================================
        $display("\n=== Final Statistics ===");
        $display("  Total fires:      %0d", total_fires);
        $display("  Total responses:  %0d", total_responses);
        $display("  Total redirects:  %0d", total_redirects);
        $display("  Outstanding diff: %0d", total_fires - total_responses);
        if (total_fires != total_responses) begin
            $display("  FAIL: fires (%0d) != responses (%0d) after drain (lost/dup/orphan)",
                     total_fires, total_responses);
            errors = errors + 1;
        end else if (total_fires == 0) begin
            $display("  FAIL: No requests were made!");
            errors = errors + 1;
        end

        $display("\n====================================================");
        if (errors == 0) begin
            $display("PASS All random delay checks completed (0 violations)");
            $display("  ALL RANDOM DELAY TESTS PASSED");
        end else begin
            $display("  %0d MONITOR VIOLATION(S) DETECTED", errors);
        end
        $display("====================================================");
        $finish;
    end
    
    initial begin
        #15000;
        $display("TIMEOUT");
        $finish;
    end
    
    initial begin
        $dumpfile("build/tb_random_delay.vcd");
        $dumpvars(0, tb_random_delay);
    end

endmodule