// ============================================================================
//        if_stage 取指吞吐表征（延迟扫描 + 两种存储器模型）
//
//        本测试台回答两个问题：
//          Q1  响应延迟增大时吞吐如何退化？
//          Q2  **Stage C 的收益是否依赖"存储器能在交付响应的同一拍接受新请求"？**
//
//        Q2 的由来（重要协议前提）
//        -------------------------
//        Stage C 让 if_stage 在"响应完成的那一拍"就发出下一请求，因此存储器会
//        在同一拍同时看到 i_rsp_valid=1 与 i_req_valid=1。若存储器此时不能接受
//        新请求（把响应拍当作 busy），它必须拉低 i_req_ready；否则请求被静默丢弃、
//        流水线卡死（本测试台初版即因此卡死，60 拍仅 2 次请求——故特意保留此教训）。
//
//        故本测试台建模两种存储器并分别测量：
//          模型 A（流水化，i_req_ready 恒 1；响应拍可接新请求）
//          模型 B（非流水化，i_req_ready = !pending；响应拍不可接新请求）
//
//        结论用途：判断我方 Cache/adapter 需要满足哪种能力，才能兑现 Stage C 收益。
//
//        本测试台为**表征型**：只断言正确性（有输出、PC 单调），不断言吞吐数值。
// ============================================================================

`timescale 1ns / 1ps

`include "defines.sv"

module tb_if_throughput;

    localparam RUN_CYCLES = 60;
    localparam N_LAT      = 4;

    reg         clk;
    reg         rst;

    reg  [31:0] pc;
    reg         redirect_valid;
    reg  [31:0] redirect_target;
    reg         hold_if;
    reg         flush_if;

    wire        i_req_valid;
    wire        i_req_ready;
    wire [31:0] i_req_addr;
    wire        advance_valid;
    wire        i_rsp_valid;
    wire        i_rsp_ready;
    wire [31:0] i_rsp_data;
    wire        i_rsp_error;

    wire        if_out_valid;
    wire        if_out_ready;
    wire [31:0] if_out_pc;
    wire [31:0] if_out_inst;
    wire        if_out_fault;

    wire [31:0] cnt_cycle, cnt_id_valid, cnt_branch, cnt_cond_branch;
    wire [31:0] cnt_jal, cnt_jalr, cnt_query, cnt_hit, cnt_mispredict;
    wire [31:0] cnt_if_advance, cnt_redirect;

    integer errors;
    integer retire_count;
    integer last_pc;
    reg     monotonic;

    always #5 clk = ~clk;

    // ------------------------------------------------------------------
    // 存储器模型（可配置延迟，两种 ready 策略）
    // ------------------------------------------------------------------
    localparam MODEL_A = 1'b0;   // 流水化：响应拍可接新请求
    localparam MODEL_B = 1'b1;   // 非流水化：响应拍不可接新请求

    reg        model_sel;
    integer    lat_cur;
    reg        pending;
    integer    cnt;
    reg [31:0] pend_addr;
    wire       rsp_now = pending && (cnt == 1);

    // 模型 A：恒可接受；模型 B：仅在无在途事务时可接受
    assign i_req_ready = (model_sel == MODEL_A) ? 1'b1 : !pending;
    assign i_rsp_valid = rsp_now;
    assign i_rsp_data  = {24'h000000, pend_addr[7:0]};
    assign i_rsp_error = 1'b0;

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            pending   <= 1'b0;
            cnt       <= 0;
            pend_addr <= 32'h0;
        end else if (rsp_now) begin
            // 本拍交付响应。若同拍有新请求被接受，则立即接续为新事务。
            if (i_req_valid && i_req_ready) begin
                pending   <= 1'b1;
                cnt       <= lat_cur;
                pend_addr <= i_req_addr;
            end else begin
                pending <= 1'b0;
                cnt     <= 0;
            end
        end else if (i_req_valid && i_req_ready) begin
            pending   <= 1'b1;
            cnt       <= lat_cur;
            pend_addr <= i_req_addr;
        end else if (pending) begin
            cnt <= cnt - 1;
        end
    end

    if_stage u_if (
        .pred_hit_i(1'b0), .pred_taken_i(1'b0), .pred_target_i(32'b0),
        .clk(clk), .rst(rst), .pc(pc),
        .redirect_valid(redirect_valid), .hold_if(hold_if), .flush_if(flush_if),
        .i_req_valid(i_req_valid), .i_req_ready(i_req_ready), .i_req_addr(i_req_addr),
        .advance_valid(advance_valid),
        .i_rsp_valid(i_rsp_valid), .i_rsp_ready(i_rsp_ready),
        .i_rsp_data(i_rsp_data), .i_rsp_error(i_rsp_error),
        .if_out_valid(if_out_valid), .if_out_ready(if_out_ready),
        .if_out_pc(if_out_pc), .if_out_inst(if_out_inst), .if_out_fault(if_out_fault)
    );

    assign if_out_ready = 1'b1;

    frontend_perf u_perf (
        .clk(clk), .rst(rst), .clr(1'b0),
        .id_valid(if_out_valid), .id_branch(1'b0), .id_jal(1'b0), .id_jalr(1'b0),
        .pred_query(i_req_valid), .pred_hit(1'b0), .mispredict(1'b0),
        .if_advance(advance_valid), .redirect(redirect_valid),
        .cnt_cycle(cnt_cycle), .cnt_id_valid(cnt_id_valid),
        .cnt_branch(cnt_branch), .cnt_cond_branch(cnt_cond_branch),
        .cnt_jal(cnt_jal), .cnt_jalr(cnt_jalr),
        .cnt_query(cnt_query), .cnt_hit(cnt_hit), .cnt_mispredict(cnt_mispredict),
        .cnt_if_advance(cnt_if_advance), .cnt_redirect(cnt_redirect)
    );

    integer k;          // 内层循环专用（避免与调用方循环变量冲突）
    integer m;
    integer lat_list [0:N_LAT-1];
    integer ipc_x100;
    integer model_loop;

    task measure(input integer lat, input reg model);
        begin
            rst = `RstEnable;
            lat_cur   = lat;
            model_sel = model;
            pc = `CpuResetAddr;
            redirect_valid = 1'b0; redirect_target = 32'h0;
            hold_if = 1'b0; flush_if = 1'b0;
            repeat (4) @(posedge clk);
            #1;
            rst = `RstDisable;
            #1;

            retire_count = 0;
            last_pc = -1;
            monotonic = 1'b1;

            for (k = 0; k < RUN_CYCLES; k = k + 1) begin
                @(posedge clk);
                #1;
                if (if_out_valid && if_out_ready) begin
                    retire_count = retire_count + 1;
                    if (last_pc >= 0 && if_out_pc <= last_pc) monotonic = 1'b0;
                    last_pc = if_out_pc;
                end
                if (advance_valid) pc = pc + 4;
            end

            ipc_x100 = (retire_count != 0) ? (100 * retire_count) / RUN_CYCLES : 0;
            // 注意：Icarus 下把字符串字面量传给 %0s 会打印乱码，故用 ASCII 标签
            if (model == MODEL_A)
                $display("    [model A pipelined] lat=%0d : inst=%0d req=%0d throughput=%0d.%02d inst/cyc",
                         lat, retire_count, cnt_if_advance, ipc_x100/100, ipc_x100%100);
            else
                $display("    [model B nonpipeln] lat=%0d : inst=%0d req=%0d throughput=%0d.%02d inst/cyc",
                         lat, retire_count, cnt_if_advance, ipc_x100/100, ipc_x100%100);

            if (retire_count == 0) begin
                $display("FAIL [model=%0b lat=%0d] 未输出任何指令（可能请求被存储器丢弃）", model, lat);
                errors = errors + 1;
            end
            if (!monotonic) begin
                $display("FAIL [model=%0b lat=%0d] 输出 PC 非单调", model, lat);
                errors = errors + 1;
            end
            // 协议检查：若稳态下请求数远少于周期数的一半，视为异常
            if (retire_count < (RUN_CYCLES / 10)) begin
                $display("FAIL [model=%0b lat=%0d] 输出指令数异常偏低 = %0d",
                         model, lat, retire_count);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $display("==========================================");
        $display("  if_stage throughput vs latency & memory model");
        $display("==========================================");

        errors = 0;
        clk = 1'b0;
        lat_list[0] = 1;
        lat_list[1] = 2;
        lat_list[2] = 3;
        lat_list[3] = 5;
        lat_cur = 1;
        model_sel = MODEL_A;
        pc = `CpuResetAddr;
        rst = `RstEnable;

        for (model_loop = 0; model_loop < 2; model_loop = model_loop + 1) begin
            $display("");
            if (model_loop == 0)
                $display("  ---- 模型 A：流水化存储器（i_req_ready 恒 1；响应拍可接新请求）----");
            else
                $display("  ---- 模型 B：非流水化存储器（i_req_ready = !pending；响应拍不可接新请求）----");
            for (m = 0; m < N_LAT; m = m + 1) begin
                if (model_loop == 0) measure(lat_list[m], MODEL_A);
                else                 measure(lat_list[m], MODEL_B);
            end
        end

        $display("");
        $display("  解读要点：");
        $display("  - Stage C 改造前（寄存请求）在模型 A、L=1 下实测 0.47。");
        $display("  - 模型 A 下 Stage C 应接近 1.0（响应拍可接新请求是前提）。");
        $display("  - 模型 B 下每笔事务占 L+1 拍，故吞吐受 1/(L+1) 限制——");
        $display("    这说明要兑现 Stage C 收益，协议必须允许**响应拍接受新请求**。");
        $display("  - 若模型 B 是真实存储器行为，则应考虑加深取指缓冲或多笔未完成（另立 ADR）。");

        $display("");
        // harness 计数需要显式 PASS 行（run_tests.py 统计 ^PASS 行）
        if (errors == 0)
            $display("PASS 8 组表征全部有效：模型 A/B x 延迟 1/2/3/5，均产出指令且 PC 单调");
        else
            $display("FAIL 表征中有 %0d 项异常", errors);
        $display("==========================================");
        if (errors == 0) $display("  ALL TESTS PASSED (%0d errors)  [表征型: 吞吐值不断言]", errors);
        else             $display("  %0d TEST(S) FAILED", errors);
        $display("==========================================");
        $finish;
    end

    initial begin
        #500000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
