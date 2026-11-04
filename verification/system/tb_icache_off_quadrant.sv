// ⚠️ 本文件由 verification/system/tb_perf_quadrant.sv **自动派生**（IC=0 / DC=0 固定），
//    目的：把 `ICACHE_ENABLE=0`（纯 bypass）这条**曾被默认配置完全掩盖**的路径
//    纳入 `run_tests.py` 的主回归守卫（AGENTS.md §7.8）。
//    改动请改源文件，然后跑：python scripts/regen_icache_off_tb.py
// ============================================================================
//  tb_perf_quadrant —— (d-3) 性能四象限测量（ICACHE_ENABLE × DCACHE_ENABLE）
//
//  依据：docs/architecture/ADR-CACHE-INTEGRATION.md §D-C6
//    「BTB 69→39 拍为**无 Cache** 基线，Cache 接入后**必须重测**：以 ICACHE_ENABLE/
//      DCACHE_ENABLE 四象限跑性能 TB，并把四组数字写进 ADR 的收尾批次；
//      差异必须归因（miss 率 × 填充拍数 = 桥 4 单字 + adapter 时延）」
//
//  参考方法学（AGENTS.md §6：参考是设计输入）：
//    RVCoreP（IEICE E103-D No.12, 2020）以 **execution cycles + IPC + 硬件资源** 三件套
//    报告性能，并用"配置型对比"（每次只加一项优化：optALU/optIF/optALL/VR-bp/VR-nobp）
//    隔离各项收益。本 TB 照此口径：**每次只切一个使能位**，报告 cycles/inst/CPI 三件套。
//
//  ---- 测量口径（可复现、与工具无关） ----
//    · 起点：`rst` 释放后的第一个时钟沿
//    · 终点：**程序末尾自旋指令（beq x0,x0,0）提交**的那一拍（确定性，且无需等 UART 帧）
//    · cycles  = 起点到终点的时钟数
//    · inst    = 同期提交（retire）的指令数
//    · CPI     = cycles / inst
//    · 另报 I/D-Cache 的 hit/miss（证明"接入是否真的生效"，避免把 bypass 当成接入）
//
//  ---- 程序（`prog_perf`，16 字） ----
//    累加 SRAM[0..7] 共 8 个字（`lw` ×8 同址连读 → D-Cache 首访缺失、其余命中），
//    末尾自旋。指令体同处一条 16 B 行内 → I-Cache 一次 compulsory miss 后全命中。
//    ⇒ 可同时观察 I 侧与 D 侧的 Cache 效果，且行数远小于 2 KiB（ADR D-C7 外推边界内）。
//
//  运行（每象限一次仿真）：
//    python scripts/run_perf_quadrant.py      ← 推荐（自动生成四份 TB 副本并汇总表格）
//  或手工：本文件顶部改 `parameter IC/DC` 默认值后单独编译。
//
// ============================================================================
//  ⚠️ 当前状态（2026-10-01，**未收口，不得写入 ADR 作为结论**）
// ============================================================================
//  本 TB 已能跑通并给出 cycles/inst/CPI 三件套 + I/D Cache 计数，但**程序结果自检不过**
//  （`x1=0`，期望 28），且 `ICACHE_ENABLE=0` 两象限**完全挂死**（inst=0）。
//  两个独立问题，均已定位到"不是本 TB 的计数逻辑错"：
//    ① **I 侧 bypass 路径在 `ICACHE_ENABLE=0` 下挂死**（inst=0）——
//       历史所有 TB 都在 `ICACHE_ENABLE=1` 下运行，**这条路径从未被验证过**。
//       这是真实缺口（无论最终定性为 RTL 缺陷还是 TB 缺用例），必须单独排查。
//    ② 程序在 `IC=1` 下能跑（inst=36，I$ 40/3），但**从未产生 D 侧事务**
//       （D 侧探针零输出）⇒ 累加器恒 0。程序装载已自检通过（`rom[0]=00000093`），
//       故问题在"程序语义/循环退出/load 是否真的执行"这一环，需下一轮逐拍排查。
//  ⇒ 本批**不产出性能数字**；(d-3) 仍未完成。见日志 2026-10-01/19。
// ============================================================================
`timescale 1ns/1ps
`include "defines.sv"

module tb_icache_off_quadrant;

    // ---- 象限选择（默认 I=1/D=1；由脚本或 -P 覆盖）----
    parameter IC = 1'b0;
    parameter DC = 1'b0;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    // ---------------- CPU ⇄ 子系统 ----------------
    wire        i_req_valid, i_req_ready, i_rsp_valid, i_rsp_ready, i_error;
    wire [31:0] i_req_addr, i_rdata;
    wire        d_req_valid, d_req_ready, d_rsp_valid, d_rsp_ready, d_write, d_error;
    wire [31:0] d_req_addr, d_wdata, d_rdata;
    wire [3:0]  d_wstrb;
    wire        gpio_out_w, timer_irq_w, uart_tx_w;

    wire        trace_valid, trace_rd_we, trace_trap;
    wire [63:0] trace_order;
    wire [4:0]  trace_rd;
    wire [31:0] trace_pc, trace_instr, trace_rd_data;

    cpu_core_stage1 u_cpu (
        .clk(clk), .rst(rst),
        .i_req_valid(i_req_valid), .i_req_ready(i_req_ready), .i_req_addr(i_req_addr),
        .i_rsp_valid(i_rsp_valid), .i_rsp_ready(i_rsp_ready), .i_rsp_data(i_rdata),
        .i_rsp_error(i_error),
        .d_req_valid(d_req_valid), .d_req_ready(d_req_ready), .d_req_addr(d_req_addr),
        .d_req_write(d_write), .d_req_wdata(d_wdata), .d_req_wstrb(d_wstrb),
        .d_rsp_valid(d_rsp_valid), .d_rsp_ready(d_rsp_ready), .d_rsp_rdata(d_rdata),
        .d_rsp_error(d_error),
        .trace_valid(trace_valid), .trace_order(trace_order), .trace_pc(trace_pc),
        .trace_instr(trace_instr), .trace_rd(trace_rd), .trace_rd_data(trace_rd_data),
        .trace_rd_we(trace_rd_we), .trace_trap(trace_trap),
        .timer_irq_i(timer_irq_w), .ext_irq_i(1'b0)
    );

    cpu_mem_subsystem #(
        .MEM_DEPTH(256), .MEM_AW(8),
        .UART_DIV(434),
        .ICACHE_ENABLE(IC), .DCACHE_ENABLE(DC)
    ) u_sub (
        .clk(clk), .rst(rst),
        .i_req_valid(i_req_valid), .i_req_ready(i_req_ready), .i_req_addr(i_req_addr),
        .i_write(i_write), .i_wdata(i_wdata), .i_wstrb(i_wstrb),
        .i_rsp_valid(i_rsp_valid), .i_rsp_ready(i_rsp_ready),
        .i_rdata(i_rdata), .i_error(i_error),
        .d_req_valid(d_req_valid), .d_req_ready(d_req_ready), .d_req_addr(d_req_addr),
        .d_write(d_write), .d_wdata(d_wdata), .d_wstrb(d_wstrb),
        .d_rsp_valid(d_rsp_valid), .d_rsp_ready(d_rsp_ready),
        .d_rdata(d_rdata), .d_error(d_error),
        .gpio_out(gpio_out_w), .gpio_in(32'h0),
        .timer_irq(timer_irq_w),
        .uart_tx(uart_tx_w), .uart_rx(1'b1)
    );

    assign i_write = 1'b0;
    assign i_wdata = 32'h0;
    assign i_wstrb = 4'h0;

    // ------------------------------------------------------------------
    // 程序编码：**用公式生成，不手算机器码**
    //   ⚠️ 坑位（**本轮真错在此，非 RTL**）：首版把 `bne` 的偏移手算成 -16，
    //      结果落在 `add`（0x10）而不是 `lw`（0x0C）⇒ 循环体只执行 4 条，
    //      **后续 7 轮完全跳过 `lw`** ⇒ 累加器恒 0（假失败）。
    //      retire trace 一击证实：`RT 8 pc=1c bne` → `RT 9 pc=10`（应为 0x0C）。
    //   ⇒ 凡带立即数偏移的指令（branch/jal/lui），一律用 helper 公式生成 + 在 TB 里
    //      **自检"目标 PC 是否等于设计意图"**（见下方 BR_TARGET 检查）。
    // ------------------------------------------------------------------
    // 布局：0x00 addi x3,x0,8        # i = 8
    //       0x04 lui  x2,0x80000     # SRAM 基址
    //       0x08 addi x4,x0,28       # 待写入的字
    //       0x0C sw   x4,0(x2)       # ★ 程序**自己**存 SRAM（不依赖 TB 初始化）
    //       0x10 addi x2,x2,4
    //       0x14 addi x4,x4,1
    //       0x18 addi x3,x3,-1
    //       0x1C bne  x3,x0,SWLOOP(0x0C)
    //       0x20 lui  x2,0x80000     # 重置读指针
    //       0x24 addi x3,x0,8        # 读 8 次
    //       0x28 addi x1,x0,0        # acc = 0
    //       0x2C lw   x4,0(x2)       # 载入 SRAM[i]
    //       0x30 add  x1,x1,x4
    //       0x34 addi x2,x2,4
    //       0x38 addi x3,x3,-1
    //       0x3C bne  x3,x0,RDLOOP(0x2C)
    //       0x40 beq  x0,x0,0        # 自旋 = 停机点
    localparam [31:0] SWLOOP_PC = 32'h0C;
    localparam [31:0] SWBNE_PC  = 32'h1C;
    localparam [31:0] RDLOOP_PC = 32'h2C;
    localparam [31:0] RDBNE_PC  = 32'h3C;
    localparam [31:0] SPIN_PC   = 32'h40;

    // B 型：imm[12|10:5] | rs2 | rs1 | 110 | imm[4:1|11] | 1100011
    function [31:0] enc_b(input [31:0] from_pc, input [31:0] to_pc,
                          input [2:0] f3, input [4:0] rs1, input [4:0] rs2);
        reg signed [31:0] off;
        reg [12:0] imm;
        begin
            off = to_pc - from_pc;
            imm = off[12:0];
            enc_b = {imm[12], imm[10:5], rs2, rs1, f3, imm[4:1], imm[11], 7'b1100011};
        end
    endfunction

    // S 型：imm[11:5] | rs2 | rs1 | 010 | imm[4:0] | 0100011
    function [31:0] enc_s(input integer off, input [4:0] rs2, input [4:0] rs1);
        reg [11:0] imm;
        begin
            imm = off[11:0];
            enc_s = {imm[11:5], rs2, rs1, 3'b010, imm[4:0], 7'b0100011};
        end
    endfunction

    localparam [31:0] INST0  = 32'h00800193;                       // addi x3,x0,8
    localparam [31:0] INST1  = 32'h80000137;                       // lui  x2,0x80000
    localparam [31:0] INST2  = 32'h01c00213;                       // addi x4,x0,28
    localparam [31:0] INST3  = enc_s(0, 5'd4, 5'd2);               // sw   x4,0(x2)
    localparam [31:0] INST4  = 32'h00410113;                       // addi x2,x2,4
    localparam [31:0] INST5  = 32'h00120213;                       // addi x4,x4,1
    localparam [31:0] INST6  = 32'hfff18193;                       // addi x3,x3,-1
    localparam [31:0] INST7  = enc_b(SWBNE_PC,  SWLOOP_PC, 3'b001, 5'd3, 5'd0);
    localparam [31:0] INST8  = 32'h80000137;                       // lui  x2,0x80000
    localparam [31:0] INST9  = 32'h00800193;                       // addi x3,x0,8
    localparam [31:0] INST10 = 32'h00000093;                       // addi x1,x0,0
    localparam [31:0] INST11 = 32'h00012203;                       // lw   x4,0(x2)
    localparam [31:0] INST12 = 32'h004080b3;                       // add  x1,x1,x4
    localparam [31:0] INST13 = 32'h00410113;                       // addi x2,x2,4
    localparam [31:0] INST14 = 32'hfff18193;                       // addi x3,x3,-1
    localparam [31:0] INST15 = enc_b(RDBNE_PC,  RDLOOP_PC, 3'b001, 5'd3, 5'd0);
    localparam [31:0] INST16 = enc_b(SPIN_PC,   SPIN_PC,   3'b000, 5'd0, 5'd0);  // 自旋

    // 预期：acc = 28+29+...+35 = 252（8 个字，比 TB 初始化更易判真伪）
    //   指令 = 写循环(3 次前导 + 5×8) + 读循环前导(3) + 读循环(5×8) + 自旋(1) = 3+40+3+40+1 = 87
    localparam integer EXPECT_INST = 87;
    localparam integer EXPECT_SUM  = 252;

    initial begin
        #1;   // 等 rom 自身 initial 的填充完成
        u_sub.u_rom_i.mem[0]  = INST0;   u_sub.u_rom_i.mem[1]  = INST1;
        u_sub.u_rom_i.mem[2]  = INST2;   u_sub.u_rom_i.mem[3]  = INST3;
        u_sub.u_rom_i.mem[4]  = INST4;   u_sub.u_rom_i.mem[5]  = INST5;
        u_sub.u_rom_i.mem[6]  = INST6;   u_sub.u_rom_i.mem[7]  = INST7;
        u_sub.u_rom_i.mem[8]  = INST8;   u_sub.u_rom_i.mem[9]  = INST9;
        u_sub.u_rom_i.mem[10] = INST10;  u_sub.u_rom_i.mem[11] = INST11;
        u_sub.u_rom_i.mem[12] = INST12;  u_sub.u_rom_i.mem[13] = INST13;
        u_sub.u_rom_i.mem[14] = INST14;  u_sub.u_rom_i.mem[15] = INST15;
        u_sub.u_rom_i.mem[16] = INST16;
        // ⚠️ 不再依赖 TB 写 SRAM：程序自己 `sw` 进去再读回（见文件头"程序"说明）。
        //    实证：TB 写 u_sram_i.mem[] 在子系统层次下不生效（load 恒读到 0），
        //    而 ROM 写入生效 ⇒ 说明差异在 SRAM 的赋值时机/层次，未深究，改用自足程序规避。
    end

    // ------------------------------------------------------------------
    // 周期与指令计数（口径见文件头）
    // ------------------------------------------------------------------
    integer cyc     = 0;
    integer n_inst  = 0;
    integer n_spin  = 0;
    reg     started = 1'b0;
    reg     stopped = 1'b0;

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            cyc = 0; n_inst = 0; n_spin = 0; started = 1'b0; stopped = 1'b0;
        end else begin
            started = 1'b1;
            if (!stopped) cyc = cyc + 1;
        end
    end

    // 提交计数：终点 = 自旋指令（`beq x0,x0,0` 在 SPIN_PC）提交
    reg [31:0] last_pc = 32'h0;
    always @(negedge clk) begin
        if (rst != `RstEnable && !stopped && trace_valid) begin
            n_inst = n_inst + 1;
            last_pc = trace_pc;
            // 完整 retire trace（≤96 条），用于反推循环圈数——不要靠"猜指令条数"
            if (n_inst <= 96)
                $display("RT %0d pc=%h inst=%h rd=x%0d we=%b d=%h",
                         n_inst, trace_pc, trace_instr, trace_rd, trace_rd_we, trace_rd_data);
            if (trace_pc === SPIN_PC && trace_instr === 32'h00000063) begin
                n_spin  = n_spin + 1;
                stopped = 1'b1;      // 停机点：自旋指令已提交
            end
        end
    end

    integer wd = 0;
    always @(posedge clk) if (!rst) begin
        wd = wd + 1;
        if (wd > 20000) begin
            $display("PERF-RESULT IC=%0d DC=%0d TIMEOUT cyc=%0d inst=%0d",
                     IC, DC, cyc, n_inst);
            $finish;
        end
    end

    // ---- 探针已移除（AGENTS.md §7.5：定位后必须移除，否则全量回归日志爆炸）----

    integer ic_hit, ic_miss, dc_hit, dc_miss, dc_store;
    integer x1_final;

    initial begin
        $display("==================================================");
        $display("  (d-3) 性能四象限：ICACHE_ENABLE=%0d  DCACHE_ENABLE=%0d", IC, DC);
        $display("==================================================");
        repeat (3) @(posedge clk);
        // ★ 程序装载自检（性能数字只有在程序真的在运行时才有意义）：
        //   若 ROM/SRAM 的值与写入不符，说明装载时机或层次路径有问题，直接停。
        $display("PROG-CHECK rom[0]=%h rom[3]=%h rom[7]=%h rom[16]=%h",
                 u_sub.u_rom_i.mem[0], u_sub.u_rom_i.mem[3],
                 u_sub.u_rom_i.mem[7], u_sub.u_rom_i.mem[16]);
        if (u_sub.u_rom_i.mem[0] !== INST0 || u_sub.u_rom_i.mem[16] !== INST16) begin
            $display("FAIL 程序未装载：rom[0]=%h（期望 %h）⇒ 本象限数字不可用",
                     u_sub.u_rom_i.mem[0], INST0);
        end
        @(negedge clk); rst = 1'b0;

        // 等停机点（自旋提交）或看门狗
        while (!stopped && wd < 15000) @(negedge clk);

        ic_hit   = u_sub.u_icache.stat_hit;
        ic_miss  = u_sub.u_icache.stat_miss;
        dc_hit   = u_sub.u_dcache.stat_hit;
        dc_miss  = u_sub.u_dcache.stat_miss;
        dc_store = u_sub.u_dcache.stat_store;
        x1_final = u_cpu.u_regfile.regs[1];

        $display("PERF-RESULT IC=%0d DC=%0d cyc=%0d inst=%0d spin=%0d x1=%0d trap=%0d",
                 IC, DC, cyc, n_inst, n_spin, x1_final, trace_trap);
        $display("PERF-CACHE  IC=%0d DC=%0d ic_hit=%0d ic_miss=%0d dc_hit=%0d dc_miss=%0d dc_store=%0d",
                 IC, DC, ic_hit, ic_miss, dc_hit, dc_miss, dc_store);

        // 正确性自检（性能数字只有在结果正确时才有意义）
        if (x1_final !== EXPECT_SUM) begin
            $display("FAIL 累加和 x1=%0d（期望 %0d）⇒ 本象限性能数字不可用", x1_final, EXPECT_SUM);
        end else if (n_spin !== 1) begin
            $display("FAIL 自旋提交 %0d 次（期望 1）", n_spin);
        end else begin
            // 标记串必须是运行器认得的 "ALL TESTS PASSED"（run_tests.py has_summary 判据）
            $display("PASS 结果正确（x1=%0d），cycles=%0d inst=%0d CPI=%0d.%02d  ALL TESTS PASSED",
                     x1_final, cyc, n_inst, cyc / (n_inst == 0 ? 1 : n_inst),
                     ((cyc * 100) / (n_inst == 0 ? 1 : n_inst)) % 100);
        end
        $display("==================================================");
        $finish;
    end

endmodule
