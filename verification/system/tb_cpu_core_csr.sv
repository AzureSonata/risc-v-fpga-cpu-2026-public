// ============================================================================
//  cpu_core_stage1 —— CSR 读写路径系统级测试（批 (a) + 批 (b) 后的契约）
//
//  范围：**只覆盖 CSR 读写路径**（译码 + 提交点读写 + 转发/互锁 + WARL）。
//  陷阱类语义（ECALL/EBREAK/非法指令/非法 CSR/非对齐/访存故障/最老优先/mret）
//  在批 (b) 已改由 `tb_cpu_core_trap.sv` 覆盖 —— 本文件原先把"非法 CSR 只抑制副作用、
//  不进入陷阱"当作契约，那正是批 (a) 的中间状态；批 (b) 起非法 CSR **进入陷阱**，
//  故那些用例被**有意移出**本文件（不是删掉覆盖）。
//
//  覆盖：
//    T1  逐条退休序列（18 条）：pc/rd/rd_we/rd_data 全部核对，且**全程无 trap**
//    T2  CSRRW 的 rd = **旧值**（读先于写）；写入结果由后续 CSRRS 读回证明
//    T3  CSRRS/CSRRC(rs1=x0) 不改 CSR；CSRRWI/CSRRSI/CSRRCI 立即数形式
//    T4  mtvec WARL（MODE 强制 direct：写 5 → 4，写 7 → 4）
//    T5  只读 CSR（mip）的**读**合法（不报错、不改变状态）
//    T6  CSR 结果被更年轻指令消费（load-use 式互锁 + mw→EX 转发）
//    T7  load 结果作为 CSR 写入数据（load→CSR 转发链）
//    T8  误预测错路上的 CSR 指令：被解码但**绝不到达 WB、绝不写 CSR**
//    T9  CSR 写入次数 == 6（恰好一次语义：被冲刷者不写、uimm=0 不写、只读读不写）
//    T10 无陷阱：mepc/mcause/mtval 全程为 0（本文件的程序不含任何陷阱指令）
// ============================================================================
`timescale 1ns/1ps

module tb_cpu_core_csr;
    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    wire i_req_valid, i_req_ready, i_rsp_ready;
    wire [31:0] i_req_addr;
    reg i_rsp_valid = 1'b0;
    reg [31:0] i_rsp_data = 32'h00000013;
    wire d_req_valid, d_req_ready, d_req_write, d_rsp_ready;
    wire [31:0] d_req_addr, d_req_wdata, d_rsp_rdata;
    wire [3:0] d_req_wstrb;
    reg d_rsp_valid = 1'b0;
    reg [31:0] d_rsp_rdata_q = 32'h0;
    wire trace_valid, trace_rd_we, trace_trap;
    wire [63:0] trace_order;
    wire [31:0] trace_pc, trace_instr, trace_rd_data;
    wire [4:0] trace_rd;

    // ------------------------------------------------------------------
    // 程序：CSR 读写路径（地址见左列；每条的期望退休在下方 RETIRE_EXPECT）
    //   0x00 addi   x1, x0, 8           x1 = 8
    //   0x04 beq    x0, x0, +8          -> 0x0c（错路 0x08 必须被冲刷）
    //   0x08 csrrw  x0, mtvec, x1       [错路] 若执行会写 mtvec=8（T8 抓）
    //   0x0c csrrs  x10, mstatus, x0    x10 = 0x1800（rs1=x0 → 不写）
    //   0x10 csrrw  x2, mstatus, x1     x2 = 0x1800（旧值）; mstatus = 0x1808
    //   0x14 csrrs  x3, mstatus, x0     x3 = 0x1808（写生效的读回证据）
    //   0x18 csrrwi x4, mtvec, 5        x4 = 0; mtvec = 4（WARL direct）
    //   0x1c csrrsi x6, mtvec, 0        x6 = 4（uimm=0 → 不写）
    //   0x20 csrrs  x7, mip, x0         x7 = 0（只读 CSR 的读合法）
    //   0x24 csrrw  x11, mtvec, x1      x11 = 4; mtvec = 8
    //   0x28 addi   x12, x11, 1         x12 = 5（消费 CSR 结果，T6）
    //   0x2c csrrc  x13, mstatus, x1    x13 = 0x1808; mstatus = 0x1800
    //   0x30 csrrsi x14, mstatus, 8     x14 = 0x1800; mstatus = 0x1808
    //   0x34 csrrsi x16, 0x344, 0       x16 = 0（uimm=0 → 无写意图 → 合法读只读）
    //   0x38 csrrs  x17, mtvec, x0      x17 = 8
    //   0x3c lw     x18, 0(x0)          x18 = 7（D 侧 dmem[0]）
    //   0x40 csrrw  x19, mtvec, x18     x19 = 8; mtvec = 4（写入数据来自 load 转发，T7）
    //   0x44 csrrs  x20, mtvec, x0      x20 = 4
    //   0x48 csrrs  x21, mstatus, x0    x21 = 0x1808
    // ------------------------------------------------------------------
    function automatic [31:0] rom(input [31:0] addr);
        case (addr)
            32'h00: rom = 32'h00800093; // addi   x1, x0, 8
            32'h04: rom = 32'h00000463; // beq    x0, x0, +8
            32'h08: rom = 32'h30509073; // csrrw  x0, mtvec, x1        [错路]
            32'h0c: rom = 32'h30002573; // csrrs  x10, mstatus, x0
            32'h10: rom = 32'h30009173; // csrrw  x2, mstatus, x1
            32'h14: rom = 32'h300021f3; // csrrs  x3, mstatus, x0
            32'h18: rom = 32'h3052d273; // csrrwi x4, mtvec, 5
            32'h1c: rom = 32'h30506373; // csrrsi x6, mtvec, 0
            32'h20: rom = 32'h344023f3; // csrrs  x7, mip, x0
            32'h24: rom = 32'h305095f3; // csrrw  x11, mtvec, x1
            32'h28: rom = 32'h00158613; // addi   x12, x11, 1
            32'h2c: rom = 32'h3000b6f3; // csrrc  x13, mstatus, x1
            32'h30: rom = 32'h30046773; // csrrsi x14, mstatus, 8
            32'h34: rom = 32'h34406873; // csrrsi x16, 0x344, 0
            32'h38: rom = 32'h305028f3; // csrrs  x17, mtvec, x0
            32'h3c: rom = 32'h00002903; // lw     x18, 0(x0)
            32'h40: rom = 32'h305919f3; // csrrw  x19, mtvec, x18
            32'h44: rom = 32'h30502a73; // csrrs  x20, mtvec, x0
            32'h48: rom = 32'h30002af3; // csrrs  x21, mstatus, x0
            default: rom = 32'h00000013; // NOP
        endcase
    endfunction

    // I 侧：1 拍响应；地址超过程序末尾即不再 ready（CPU 停住，程序自然结束）
    assign i_req_ready = (i_req_addr <= 32'h48);
    always @(posedge clk) begin
        if (rst) begin
            i_rsp_valid <= 1'b0;
            i_rsp_data <= 32'h00000013;
        end else begin
            i_rsp_valid <= 1'b0;
            if (i_req_valid && i_req_ready) begin
                i_rsp_valid <= 1'b1;
                i_rsp_data <= rom(i_req_addr);
            end
        end
    end

    // D 侧：两拍响应，无背压（本程序只有一次 load）
    reg [31:0] dmem [0:3];
    reg pending_rsp = 1'b0;
    reg [2:0] rsp_delay = 0;
    reg [31:0] pending_addr = 0, pending_wdata = 0;
    reg [3:0] pending_wstrb = 0;
    reg pending_write = 0;
    integer accepted_requests = 0;
    assign d_req_ready = !pending_rsp;
    assign d_rsp_rdata = d_rsp_rdata_q;

    always @(posedge clk) begin
        if (rst) begin
            dmem[0] <= 32'd7;
            dmem[1] <= 32'd0;
            dmem[2] <= 32'd0;
            dmem[3] <= 32'd0;
            pending_rsp <= 1'b0;
            d_rsp_valid <= 1'b0;
            rsp_delay <= 0;
            accepted_requests <= 0;
        end else begin
            if (d_req_valid && d_req_ready) begin
                accepted_requests <= accepted_requests + 1;
                pending_rsp <= 1'b1;
                rsp_delay <= 3'd2;
                pending_addr <= d_req_addr;
                pending_write <= d_req_write;
                pending_wdata <= d_req_wdata;
                pending_wstrb <= d_req_wstrb;
            end
            if (pending_rsp && rsp_delay != 0)
                rsp_delay <= rsp_delay - 1'b1;
            if (pending_rsp && rsp_delay == 0 && !d_rsp_valid) begin
                d_rsp_valid <= 1'b1;
                d_rsp_rdata_q <= dmem[pending_addr[3:2]];
            end
            if (d_rsp_valid && d_rsp_ready) begin
                if (pending_write) begin
                    if (pending_wstrb[0]) dmem[pending_addr[3:2]][7:0] <= pending_wdata[7:0];
                    if (pending_wstrb[1]) dmem[pending_addr[3:2]][15:8] <= pending_wdata[15:8];
                    if (pending_wstrb[2]) dmem[pending_addr[3:2]][23:16] <= pending_wdata[23:16];
                    if (pending_wstrb[3]) dmem[pending_addr[3:2]][31:24] <= pending_wdata[31:24];
                end
                d_rsp_valid <= 1'b0;
                pending_rsp <= 1'b0;
            end
        end
    end

    cpu_core_stage1 dut (
        .clk(clk), .rst(rst), .i_req_valid(i_req_valid), .i_req_ready(i_req_ready),
        .i_req_addr(i_req_addr), .i_rsp_valid(i_rsp_valid), .i_rsp_ready(i_rsp_ready),
        .i_rsp_data(i_rsp_data), .i_rsp_error(1'b0), .d_req_valid(d_req_valid),
        .d_req_ready(d_req_ready), .d_req_addr(d_req_addr), .d_req_write(d_req_write),
        .d_req_wdata(d_req_wdata), .d_req_wstrb(d_req_wstrb),
        .d_rsp_valid(d_rsp_valid), .d_rsp_ready(d_rsp_ready), .d_rsp_rdata(d_rsp_rdata),
        .d_rsp_error(1'b0), .trace_valid(trace_valid), .trace_order(trace_order),
        .trace_pc(trace_pc), .trace_instr(trace_instr), .trace_rd(trace_rd),
        .trace_rd_data(trace_rd_data), .trace_rd_we(trace_rd_we), .trace_trap(trace_trap),
        .timer_irq_i(1'b0), .ext_irq_i(1'b0)   // 批 (c)：CSR 路径测试不涉及中断
    );

    // ------------------------------------------------------------------
    // 期望退休序列（不含错路 0x08）
    // ------------------------------------------------------------------
    integer N_EXP = 18;
    reg [31:0] exp_pc [0:17];
    reg [4:0]  exp_rd [0:17];
    reg        exp_we [0:17];
    reg [31:0] exp_dt [0:17];

    integer checks = 0, errors = 0;
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

    integer seen = 0;
    integer trap_events = 0;
    integer wrong_path_decoded = 0;
    integer csr_write_fires = 0;
    integer wrong_path_at_wb = 0;
    reg     wrong_path_wb_seen = 1'b0;

    always @(posedge clk) begin
        if (!rst) begin
            // 错路 CSR 确实被取到并**译码**（否则本用例无法证明"冲刷阻止了写入"）
            if (dut.id_valid && dut.dec_is_csr && (dut.id_pc == 32'h08))
                wrong_path_decoded = wrong_path_decoded + 1;
            // 错路 CSR 绝不允许到达 WB
            if (dut.mw_valid && dut.mw_csr_is_q && (dut.mw_pc == 32'h08)) begin
                wrong_path_at_wb = wrong_path_at_wb + 1;
                wrong_path_wb_seen = 1'b1;
            end
            // 提交点 CSR 写脉冲计数（恰好一次语义）
            if (dut.u_csr.csr_we)
                csr_write_fires = csr_write_fires + 1;
        end
    end

    // The program does not write counters: successful trace entries are an
    // independent observable count, including exclusion of fault/IRQ events.
    reg [63:0] retired_expected = 64'd0;
    always @(negedge clk) begin
        if (rst == `RstEnable) retired_expected = 64'd0;
        else begin
            retired_expected = retired_expected + {63'b0, trace_valid && !trace_trap};
            if (dut.u_csr.minstret_q !== retired_expected)
                $fatal(1, "FAIL minstret integration got=%0d trace=%0d",
                       dut.u_csr.minstret_q, retired_expected);
        end
    end

    initial begin
        exp_pc[0] = 32'h00; exp_rd[0] = 5'd1;  exp_we[0] = 1'b1; exp_dt[0] = 32'h00000008;
        exp_pc[1] = 32'h04; exp_rd[1] = 5'd0;  exp_we[1] = 1'b0; exp_dt[1] = 32'h0;
        exp_pc[2] = 32'h0c; exp_rd[2] = 5'd10; exp_we[2] = 1'b1; exp_dt[2] = 32'h00001800;
        exp_pc[3] = 32'h10; exp_rd[3] = 5'd2;  exp_we[3] = 1'b1; exp_dt[3] = 32'h00001800;
        exp_pc[4] = 32'h14; exp_rd[4] = 5'd3;  exp_we[4] = 1'b1; exp_dt[4] = 32'h00001808;
        exp_pc[5] = 32'h18; exp_rd[5] = 5'd4;  exp_we[5] = 1'b1; exp_dt[5] = 32'h00000000;
        exp_pc[6] = 32'h1c; exp_rd[6] = 5'd6;  exp_we[6] = 1'b1; exp_dt[6] = 32'h00000004;
        exp_pc[7] = 32'h20; exp_rd[7] = 5'd7;  exp_we[7] = 1'b1; exp_dt[7] = 32'h00000000;
        exp_pc[8] = 32'h24; exp_rd[8] = 5'd11; exp_we[8] = 1'b1; exp_dt[8] = 32'h00000004;
        exp_pc[9] = 32'h28; exp_rd[9] = 5'd12; exp_we[9] = 1'b1; exp_dt[9] = 32'h00000005;
        exp_pc[10] = 32'h2c; exp_rd[10] = 5'd13; exp_we[10] = 1'b1; exp_dt[10] = 32'h00001808;
        exp_pc[11] = 32'h30; exp_rd[11] = 5'd14; exp_we[11] = 1'b1; exp_dt[11] = 32'h00001800;
        exp_pc[12] = 32'h34; exp_rd[12] = 5'd16; exp_we[12] = 1'b1; exp_dt[12] = 32'h00000000;
        exp_pc[13] = 32'h38; exp_rd[13] = 5'd17; exp_we[13] = 1'b1; exp_dt[13] = 32'h00000008;
        exp_pc[14] = 32'h3c; exp_rd[14] = 5'd18; exp_we[14] = 1'b1; exp_dt[14] = 32'h00000007;
        exp_pc[15] = 32'h40; exp_rd[15] = 5'd19; exp_we[15] = 1'b1; exp_dt[15] = 32'h00000008;
        exp_pc[16] = 32'h44; exp_rd[16] = 5'd20; exp_we[16] = 1'b1; exp_dt[16] = 32'h00000004;
        exp_pc[17] = 32'h48; exp_rd[17] = 5'd21; exp_we[17] = 1'b1; exp_dt[17] = 32'h00001808;

        $display("==================================================");
        $display("  cpu_core_stage1 CSR 读写路径（批 (a) 契约，批 (b) 后仍无陷阱）");
        $display("==================================================");
    end

    // 逐条退休核对（T1/T2/T3/T4/T5/T6/T7/T8）
    always @(negedge clk) begin
        if (!rst && trace_valid) begin
            if (seen >= N_EXP) begin
                $fatal(1, "unexpected extra retirement pc=%08h", trace_pc);
            end
            chk("T1 retire pc", trace_pc, exp_pc[seen]);
            if (trace_rd !== exp_rd[seen]) begin
                errors = errors + 1; checks = checks + 1;
                $display("FAIL [T1 retire rd #%0d pc=%08h] got=x%0d want=x%0d", seen, trace_pc, trace_rd, exp_rd[seen]);
            end
            chk("T1 retire rd_we", {31'b0, trace_rd_we}, {31'b0, exp_we[seen]});
            chk("T1 retire trap=0", {31'b0, trace_trap}, 32'd0);
            if (exp_we[seen])
                chk("T1 retire rd_data", trace_rd_data, exp_dt[seen]);
            if (trace_order !== seen) begin
                errors = errors + 1; checks = checks + 1;
                $display("FAIL [T1 trace order] got=%0d want=%0d", trace_order, seen);
            end
            $display("RETIRE %0d pc=%08h rd=x%0d data=%08h we=%b trap=%b",
                     trace_order, trace_pc, trace_rd, trace_rd_data, trace_rd_we, trace_trap);
            seen = seen + 1;
            if (trace_trap) trap_events = trap_events + 1;
        end
    end

    initial begin
        repeat (3) @(posedge clk);
        rst = 1'b0;
        repeat (300) @(posedge clk);

        // ---------------- T1 退休条数 + T10 无陷阱 ----------------
        chk("T1 retire count", seen, N_EXP);
        chk("T10 no trap events", trap_events, 0);

        // ---------------- T8 错路 CSR：被译码但未到达 WB ----------------
        if (wrong_path_decoded < 1)
            $display("FAIL [T8 wrong-path CSR was never decoded: this test would be vacuous]");
        else
            $display("PASS [T8 wrong-path CSR decoded %0d time(s) and flushed]", wrong_path_decoded);
        if (wrong_path_wb_seen)
            $display("FAIL [T8 wrong-path CSR reached MEM/WB %0d time(s) pc=08]", wrong_path_at_wb);
        else
            $display("PASS [T8 wrong-path CSR never reached MEM/WB]");
        if (wrong_path_decoded < 1 || wrong_path_wb_seen) errors = errors + 1;
        checks = checks + 2;

        // ---------------- T9 CSR 写入次数恰好 6 ----------------
        chk("T9 CSR write fires", csr_write_fires, 32'd6);

        // ---------------- T2/T4 CSR 终态（写入确实生效且 WARL 正确） ----------------
        chk("T2/T4 mtvec final (WARL direct)", dut.u_csr.mtvec, 32'h00000004);
        chk("T3 mstatus final (MIE=1)", dut.u_csr.mstatus, 32'h00001808);
        chk("T5 mip stays 0 (read-only)", dut.u_csr.mip, 32'h00000000);
        chk("T10 mepc untouched (no trap)", dut.u_csr.mepc, 32'h00000000);
        chk("T10 mcause untouched", dut.u_csr.mcause, 32'h00000000);
        chk("T10 mtval untouched", dut.u_csr.mtval, 32'h00000000);

        // ---------------- 寄存器堆终态 ----------------
        chk("T3 x10 = first mstatus read", dut.u_regfile.regs[10], 32'h00001800);
        chk("T4 x4 = old mtvec", dut.u_regfile.regs[4], 32'd0);
        chk("T5 x7 = mip read", dut.u_regfile.regs[7], 32'd0);
        chk("T6 x12 = csr result + 1", dut.u_regfile.regs[12], 32'd5);
        chk("T7 x18 = loaded value", dut.u_regfile.regs[18], 32'd7);
        chk("T7 x19 = old mtvec (load->CSR)", dut.u_regfile.regs[19], 32'd8);
        chk("T7 x20 = new mtvec (load->CSR)", dut.u_regfile.regs[20], 32'd4);
        chk("T3 x21 = mstatus final read", dut.u_regfile.regs[21], 32'h00001808);
        chk("T1 x0 stays 0", dut.u_regfile.regs[0], 32'd0);

        $display("==================================================");
        $display("  检查项: %0d", checks);
        if (errors == 0)
            $display("  ALL TESTS PASSED (0 errors)");
        else
            $display("  %0d FAILED", errors);
        $display("==================================================");
        if (errors != 0) $fatal(1, "csr path tests failed");
        $finish;
    end

    initial begin
        #20000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
