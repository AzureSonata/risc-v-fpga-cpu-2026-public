// ============================================================================
//  IF → IF/ID 级间握手契约测试（D-8 回归）
//
//  目的：在**真实对端相连**的条件下验证 IF 与 IF/ID 的握手契约。
//
//  背景（D-8，2026-09-28 两线集成时发现）：
//    旧版 if_id 写作 `assign if_ready_o = `True;`（恒 1），而 if_stage 的
//    IF→IF/ID 输出握手 (if_out_valid && if_out_ready) 并没有用 hold_if 门控。
//    于是 hold 期间 if_stage 误判"下游已取走"，把 IF 输出槽里的指令丢弃，
//    在完整 CPU 上表现为最后一条指令永久丢失、retire 数少 1。
//
//    该缺陷逃过了 210 项前端单元测试，原因是那些测试把 if_out_ready 当作
//    独立 tb 寄存器并在 hold 时手工置 0（无意中模拟了正确语义），从未连接
//    真实的 if_id.if_ready_o。本测试补上这一环。
//
//  断言：
//    T1  复位期间 if_ready_o = 0（复位不锁存）
//    T2  hold 期间每拍 if_ready_o 必须为 0（不得谎报"可接收"）
//    T3  hold 期间至少有一拍 IF 输出仍持有有效载荷（证明窗口被真正激励）
//    T4  hold 释放后 8 条指令全部到达 ID，恰好一次、无缺失无重复
//    T5  ID 收到的 pc 序列严格等于 0,4,8,...,28
//    T6  ID 收到的指令与 ROM 内容逐条一致
// ============================================================================
`timescale 1ns/1ps
`include "defines.sv"

module tb_if_id_hold_contract;

    localparam integer N_INST = 8;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    // ---- IF 侧单字请求/响应端口 ----
    wire        i_req_valid;
    wire        i_req_ready;
    wire [31:0] i_req_addr;
    wire        i_rsp_ready;
    reg         i_rsp_valid = 1'b0;
    reg  [31:0] i_rsp_data  = 32'h00000013;
    reg         i_rsp_error = 1'b0;

    reg         hold     = 1'b0;
    reg         flush_x  = 1'b0;
    reg         redirect = 1'b0;

    wire [31:0] pc;
    wire        advance_valid;

    wire        if_out_valid;
    wire [31:0] if_out_pc, if_out_inst;
    wire        if_out_fault;
    wire        if_out_ready;      // ← 由真实 if_id 驱动（本测试的关键）

    wire        id_valid;
    wire [31:0] id_pc, id_inst;
    wire        id_fault;
    wire        id_pred_valid, id_pred_taken;
    wire [31:0] id_pred_target;

    integer checks = 0;
    integer errors = 0;

    task chk(input [255:0] name, input [31:0] got, input [31:0] want);
        begin
            checks = checks + 1;
            if (got !== want) begin
                errors = errors + 1;
                $display("FAIL [%0s] got=%08h want=%08h", name, got, want);
            end else begin
                $display("PASS [%0s] = %08h", name, got);
            end
        end
    endtask

    // 每条地址对应一条不同的合法 NOP 型指令（addi x0,x0,imm），便于按 pc 区分
    function automatic [31:0] rom(input [31:0] addr);
        rom = 32'h00000013 + (addr >> 2);
    endfunction

    // 理想 I 存储器：**只应答前 N_INST 条指令的地址**（此后回压），
    // 使取指总数恰好为 N_INST，便于精确断言"无缺失、无重复"。
    // 响应下一拍返回。
    assign i_req_ready = (i_req_addr < (N_INST * 4));
    always @(posedge clk) begin
        if (rst) begin
            i_rsp_valid <= 1'b0;
            i_rsp_data  <= 32'h00000013;
        end else begin
            i_rsp_valid <= 1'b0;
            if (i_req_valid && i_req_ready) begin
                i_rsp_valid <= 1'b1;
                i_rsp_data  <= rom(i_req_addr);
            end
        end
    end

    pc_reg u_pc (
        .clk(clk), .rst(rst), .redirect_valid(redirect),
        .redirect_target(32'b0), .advance_valid(advance_valid),
        .pred_valid(1'b0), .pred_target(32'b0),
        .hold_pc(1'b0), .pc(pc)
    );

    if_stage u_if (
        .pred_hit_i(1'b0), .pred_taken_i(1'b0), .pred_target_i(32'b0),
        .clk(clk), .rst(rst), .pc(pc), .redirect_valid(redirect),
        .hold_if(hold), .flush_if(flush_x),
        .i_req_valid(i_req_valid), .i_req_ready(i_req_ready),
        .i_req_addr(i_req_addr), .advance_valid(advance_valid),
        .i_rsp_valid(i_rsp_valid), .i_rsp_ready(i_rsp_ready),
        .i_rsp_data(i_rsp_data), .i_rsp_error(i_rsp_error),
        .if_out_valid(if_out_valid), .if_out_ready(if_out_ready),
        .if_out_pc(if_out_pc), .if_out_inst(if_out_inst),
        .if_out_fault(if_out_fault)
    );

    // 真实 IF/ID 驱动 if_out_ready —— 这是本测试与旧单元测试的本质区别
    if_id u_if_id (
        .clk(clk), .rst(rst),
        .if_valid_i(if_out_valid), .if_ready_o(if_out_ready),
        .if_pc_i(if_out_pc), .if_inst_i(if_out_inst), .if_fault_i(if_out_fault),
        .if_pred_valid_i(1'b0), .if_pred_taken_i(1'b0),
        .if_pred_target_i(32'b0),
        .hold_if_id(hold), .flush_if_id(flush_x),
        .id_valid_o(id_valid), .id_pc_o(id_pc), .id_inst_o(id_inst),
        .id_fault_o(id_fault), .id_pred_valid_o(id_pred_valid),
        .id_pred_taken_o(id_pred_taken), .id_pred_target_o(id_pred_target)
    );

    // ---- ID 侧载荷采集：pc 变化才算"取走一条"（IF/ID 会保持同一载荷） ----
    reg [31:0] seen_pc   [0:N_INST-1];
    reg [31:0] seen_inst [0:N_INST-1];
    integer    n_seen  = 0;
    reg [31:0] last_pc = 32'hFFFF_FFFF;

    always @(posedge clk) begin
        if (!rst && id_valid && (id_pc !== last_pc)) begin
            if (n_seen < N_INST) begin
                seen_pc[n_seen]   = id_pc;
                seen_inst[n_seen] = id_inst;
            end
            if (n_seen < 16)
                $display("IDTAKE %0d pc=%08h inst=%08h", n_seen, id_pc, id_inst);
            n_seen  = n_seen + 1;
            last_pc = id_pc;
        end
    end

    // ---- hold 窗口内 IF 输出仍持有有效载荷的拍数（证明窗口被激励） ----
    integer held_with_valid = 0;
    reg     in_hold_window  = 1'b0;
    always @(posedge clk) begin
        if (in_hold_window && if_out_valid) held_with_valid = held_with_valid + 1;
    end

    integer i, bad;
    initial begin
        $display("==================================================");
        $display("  IF -> IF/ID 级间握手契约测试（D-8 回归）");
        $display("==================================================");

        repeat (3) @(posedge clk);

        // T1：复位（不锁存）期间不得报告可接收
        chk("T1 ready=0 during rst", {31'b0, if_out_ready}, 32'd0);

        rst = 1'b0;

        // 让前端先正常跑几条
        repeat (6) @(posedge clk);

        // T2：hold 窗口内逐拍检查 ready，失败时报出轮次以便定位
        // 注意：#1 用于让 hold 的阻塞赋值经组合逻辑传播后再采样组合输出，
        // 避免"同一 delta 内读未更新的组合输出"这一测试台自身竞争。
        in_hold_window = 1'b1;
        hold = 1'b1;
        #1;
        for (i = 0; i < 8; i = i + 1) begin
            checks = checks + 1;
            if (if_out_ready !== 1'b0) begin
                errors = errors + 1;
                $display("FAIL [T2 ready=0 in hold, iter %0d] got=%b", i, if_out_ready);
            end else begin
                $display("PASS [T2 ready=0 in hold, iter %0d]", i);
            end
            @(posedge clk);
        end
        hold = 1'b0;
        in_hold_window = 1'b0;
        #1;

        // T3：hold 期间确实有有效载荷被保住（否则本测试是空判据）
        checks = checks + 1;
        if (held_with_valid < 1) begin
            errors = errors + 1;
            $display("FAIL [T3 hold window exercised] held_with_valid=%0d", held_with_valid);
        end else begin
            $display("PASS [T3 hold window exercised] held_with_valid=%0d", held_with_valid);
        end

        // 释放 hold，给足时间让全部指令流完
        repeat (80) @(posedge clk);

        // T4：恰好 N_INST 条，无缺失无重复
        chk("T4 ID takes == N_INST", n_seen, N_INST);

        // T5：pc 序列严格为 0,4,...,28
        bad = 0;
        for (i = 0; i < N_INST; i = i + 1) begin
            if (i < n_seen && seen_pc[i] !== (i * 4)) bad = bad + 1;
        end
        chk("T5 ID pc seq == 0,4,..,28", bad, 0);

        // T6：指令内容与 ROM 一致
        bad = 0;
        for (i = 0; i < N_INST; i = i + 1) begin
            if (i < n_seen && seen_inst[i] !== rom(i * 4)) bad = bad + 1;
        end
        chk("T6 ID inst == ROM", bad, 0);

        $display("==================================================");
        $display("  检查项: %0d", checks);
        if (errors == 0)
            $display("  ALL TESTS PASSED (0 errors)");
        else
            $display("  %0d FAILED", errors);
        $display("==================================================");
        $finish;
    end

endmodule
