// ============================================================================
//  BTB / 分支预测集成测试（系统级）
//
//  被测：cpu_core_stage1 + branch_predictor（见 docs/architecture/ADR-BTB-INTEGRATION.md）
//
//  A/B 对照用法（同程序、同 TB，仅改编译宏）：
//    iverilog ... -s tb_cpu_core_btb ...              # 启用预测（默认）
//    iverilog ... -DBTB_OFF -s tb_cpu_core_btb ...    # 关闭预测（基线）
//  两次输出中的 CYCLES= 用于实测收益对比（不凭声称）。
//  注：不用 -P 覆盖参数——本机 Icarus 10.2 的 -P 会在解析时报内部断言失败。
//
//  测试程序（循环 3 次后退出；编码由 scripts/encode_btb_test_program.py 生成并反解校验）：
//    0x00 addi x1,x0,0     i=0
//    0x04 addi x2,x0,3     limit=3
//    0x08 addi x1,x1,1     i++            <-- 循环体
//    0x0c blt  x1,x2,-4    if i<3 -> 0x08 (回跳)
//    0x10 addi x3,x0,7     循环出口
//    0x14 addi x4,x0,9
//
//  BTB 情形覆盖：
//    第1次 blt：表项无效 -> 未命中，实际 taken        = ADR §2.4 情形 4
//    第2次 blt：预测 taken 且目标一致，实际 taken      = 情形 1（收益来源，应无 redirect）
//    第3次 blt：预测 taken 但实际 not taken            = 情形 3（最关键：必须 redirect 到 0x10）
//    其余指令                                         = 情形 5
//    情形 2（预测 taken 但目标不同）需 JALR 变目标，本静态程序**未覆盖**（已在日志中记录）。
//
//  断言：
//    T1 复位后 BTB 无命中（表项 valid 复位为 0，不得在 PC=0 假命中）
//    T2 BTB 被真实查询（stat_query > 0）
//    T3 retire 序列精确等于预期 10 条（pc/rd/we/data 全字段）
//    T4 第 11 条及以后不得再有 retire（错路指令不得提交）
//    T5 BTB_EN=1 时 stat_hit > 0（预测确实生成了）
//    T6 寄存器堆终值正确（x1=3, x2=3, x3=7, x4=9, x0=0）
// ============================================================================
`timescale 1ns/1ps
`include "defines.sv"

module tb_cpu_core_btb;

`ifdef BTB_OFF
    localparam BTB_EN = 1'b0;          // 基线对照：编译时加 -DBTB_OFF
`else
    localparam BTB_EN = 1'b1;          // 默认：启用预测
`endif
    // 循环迭代次数：case 1（预测 taken 且目标一致、实际 taken）发生 N_ITER-1 次，
    // 次数越多，预测收益越应当显现；用于 A/B 度量的灵敏度。
`ifdef ITER_3
    localparam integer N_ITER = 3;
`else
    localparam integer N_ITER = 8;
`endif
    localparam integer N_EXP  = 4 + 2*N_ITER;   // 0x00,0x04,(0x08,0x0c)*N,0x10,0x14

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    // ---------------- I 端口 ----------------
    wire        i_req_valid, i_req_ready, i_rsp_ready;
    wire [31:0] i_req_addr;
    reg         i_rsp_valid = 1'b0;
    reg  [31:0] i_rsp_data  = 32'h00000013;

    // ---------------- D 端口（本程序无访存，仍提供最小模型避免挂死） ----------------
    wire        d_req_valid, d_req_ready, d_req_write, d_rsp_ready;
    wire [31:0] d_req_addr, d_req_wdata, d_rsp_rdata;
    wire [3:0]  d_req_wstrb;
    reg         d_rsp_valid = 1'b0;

    // ---------------- 提交 trace ----------------
    wire        trace_valid, trace_rd_we, trace_trap;
    wire [63:0] trace_order;
    wire [31:0] trace_pc, trace_instr, trace_rd_data;
    wire [4:0]  trace_rd;

    function automatic [31:0] rom(input [31:0] addr);
        case (addr)
            32'h00: rom = 32'h00000093;   // addi x1,x0,0
            32'h04: rom = (N_ITER << 20) | (5'd2 << 7) | 7'h13;  // addi x2,x0,N_ITER
            32'h08: rom = 32'h00108093;   // addi x1,x1,1
            32'h0c: rom = 32'hfe20cee3;   // blt  x1,x2,-4
            32'h10: rom = 32'h00700193;   // addi x3,x0,7
            32'h14: rom = 32'h00900213;   // addi x4,x0,9
            default: rom = 32'h00000013;
        endcase
    endfunction

    // 只应答 0x00..0x14，其后回压（使 retire 总数恰好受限）
    assign i_req_ready = (i_req_addr <= 32'h14);
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

    assign d_req_ready = ~d_rsp_valid;
    assign d_rsp_rdata = 32'h0;
    always @(posedge clk) begin
        if (rst) d_rsp_valid <= 1'b0;
        else if (d_req_valid && d_req_ready) d_rsp_valid <= 1'b1;
        else if (d_rsp_valid && d_rsp_ready) d_rsp_valid <= 1'b0;
    end

    cpu_core_stage1 #(.BTB_ENABLE(BTB_EN)) u_dut (
        .clk(clk), .rst(rst), .i_req_valid(i_req_valid), .i_req_ready(i_req_ready),
        .i_req_addr(i_req_addr), .i_rsp_valid(i_rsp_valid), .i_rsp_ready(i_rsp_ready),
        .i_rsp_data(i_rsp_data), .i_rsp_error(1'b0), .d_req_valid(d_req_valid),
        .d_req_ready(d_req_ready), .d_req_addr(d_req_addr), .d_req_write(d_req_write),
        .d_req_wdata(d_req_wdata), .d_req_wstrb(d_req_wstrb),
        .d_rsp_valid(d_rsp_valid), .d_rsp_ready(d_rsp_ready), .d_rsp_rdata(d_rsp_rdata),
        .d_rsp_error(1'b0), .trace_valid(trace_valid), .trace_order(trace_order),
        .trace_pc(trace_pc), .trace_instr(trace_instr), .trace_rd(trace_rd),
        .trace_rd_data(trace_rd_data), .trace_rd_we(trace_rd_we), .trace_trap(trace_trap),
        .timer_irq_i(1'b0), .ext_irq_i(1'b0)   // 批 (c)：BTB 测试不涉及中断
    );

    // ---------------- 校验基础设施 ----------------
    integer checks = 0;
    integer errors = 0;
    integer cyc = 0;
    integer cyc10 = -1;

    always @(posedge clk) if (!rst) cyc = cyc + 1;

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

    // 预期 retire 序列：{pc, rd, data, we}
    reg [31:0] exp_pc   [0:63];
    reg [31:0] exp_data [0:63];
    reg [4:0]  exp_rd   [0:63];
    reg        exp_we   [0:63];

    // 故障/顺序计数
    integer seen = 0;
    integer seq_err = 0;
    integer extra_after = 0;
    reg     stopped = 1'b0;

    always @(negedge clk) begin
        if (!rst && trace_valid) begin
            if (seen < N_EXP) begin
                if (trace_pc !== exp_pc[seen] || trace_rd !== exp_rd[seen] ||
                    trace_rd_data !== exp_data[seen] || trace_rd_we !== exp_we[seen]) begin
                    seq_err = seq_err + 1;
                    $display("FAIL retire[%0d] pc=%08h rd=x%0d data=%08h we=%b (期望 pc=%08h rd=x%0d data=%08h we=%b)",
                             seen, trace_pc, trace_rd, trace_rd_data, trace_rd_we,
                             exp_pc[seen], exp_rd[seen], exp_data[seen], exp_we[seen]);
                end else begin
                    $display("RETIRE %0d pc=%08h rd=x%0d data=%08h we=%b",
                             seen, trace_pc, trace_rd, trace_rd_data, trace_rd_we);
                end
                if (trace_order !== seen) begin
                    seq_err = seq_err + 1;
                    $display("FAIL trace_order=%0d 期望 %0d", trace_order, seen);
                end
                seen = seen + 1;
                if (seen == N_EXP) cyc10 = cyc;
            end else begin
                extra_after = extra_after + 1;
            end
        end
        if (stopped) ;
    end

    integer i;
    initial begin
        $display("==================================================");
        $display("  BTB 集成系统级测试    BTB_EN=%0d", BTB_EN);
        $display("==================================================");

        begin : build_exp
            integer ii, kk;
            ii = 0;
            exp_pc[ii]=32'h00; exp_rd[ii]=5'd1; exp_data[ii]=32'd0;     exp_we[ii]=1'b1; ii=ii+1;
            exp_pc[ii]=32'h04; exp_rd[ii]=5'd2; exp_data[ii]=N_ITER;  exp_we[ii]=1'b1; ii=ii+1;
            for (kk = 1; kk <= N_ITER; kk = kk + 1) begin
                exp_pc[ii]=32'h08; exp_rd[ii]=5'd1; exp_data[ii]=kk; exp_we[ii]=1'b1; ii=ii+1;
                exp_pc[ii]=32'h0c; exp_rd[ii]=5'd0; exp_data[ii]=32'd0; exp_we[ii]=1'b0; ii=ii+1;
            end
            exp_pc[ii]=32'h10; exp_rd[ii]=5'd3; exp_data[ii]=32'd7; exp_we[ii]=1'b1; ii=ii+1;
            exp_pc[ii]=32'h14; exp_rd[ii]=5'd4; exp_data[ii]=32'd9; exp_we[ii]=1'b1; ii=ii+1;
        end

        repeat (3) @(posedge clk);

        // T1：复位期间 BTB 不得命中（表项 valid 复位为 0）
        chk("T1 no BTB hit during rst", {31'b0, u_dut.u_btb.q_hit}, 32'd0);

        rst = 1'b0;

        // 等 10 条 retire 完成（或超时）
        while (seen < N_EXP && cyc < 40*N_EXP) @(posedge clk);
        stopped = 1'b1;

        // T2：BTB 被真实查询
        checks = checks + 1;
        if (u_dut.u_btb.stat_query == 0) begin
            errors = errors + 1;
            $display("FAIL [T2 BTB queried] stat_query=0");
        end else begin
            $display("PASS [T2 BTB queried] stat_query=%0d", u_dut.u_btb.stat_query);
        end

        // T3：retire 序列
        chk("T3 retire count == N_EXP", seen, N_EXP);
        chk("T3b retire sequence errors", seq_err, 0);

        // 再跑一段时间，确认没有额外 retire（错路指令不得提交）
        repeat (60) @(posedge clk);
        chk("T4 no retirement after N_EXP", extra_after, 0);

        // T5：启用预测时 BTB 必须真的命中过
        if (BTB_EN) begin
            checks = checks + 1;
            if (u_dut.u_btb.stat_hit == 0) begin
                errors = errors + 1;
                $display("FAIL [T5 BTB hit > 0 when BTB_EN=1] stat_hit=0 —— 预测未真正生效，本测试形同虚设");
            end else begin
                $display("PASS [T5 BTB hit > 0] stat_hit=%0d", u_dut.u_btb.stat_hit);
            end
        end else begin
            $display("INFO BTB_EN=0（基线）：stat_hit=%0d", u_dut.u_btb.stat_hit);
        end

        // T6：寄存器堆终值
        chk("T6 x0", u_dut.u_regfile.regs[0], 32'd0);
        chk("T6 x1", u_dut.u_regfile.regs[1], N_ITER);
        chk("T6 x2", u_dut.u_regfile.regs[2], N_ITER);
        chk("T6 x3", u_dut.u_regfile.regs[3], 32'd7);
        chk("T6 x4", u_dut.u_regfile.regs[4], 32'd9);

        $display("--------------------------------------------------");
        $display("CYCLES=%0d BTB_EN=%0d STAT_QUERY=%0d STAT_HIT=%0d STAT_MISPREDICT=%0d",
                 cyc10, BTB_EN, u_dut.u_btb.stat_query, u_dut.u_btb.stat_hit,
                 u_dut.u_btb.stat_mispredict);
        $display("--------------------------------------------------");
        $display("  检查项: %0d", checks);
        if (errors == 0)
            $display("  ALL TESTS PASSED (0 errors)");
        else
            $display("  %0d FAILED", errors);
        $display("==================================================");
        $finish;
    end

endmodule
