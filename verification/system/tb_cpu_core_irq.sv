// ============================================================================
//  cpu_core_stage1 —— 机器中断接入（批 (c)：D12/D13/D14）
//
//  被测：rtl/core/cpu_core_stage1.sv（中断采样在 EX/MEM 边界，与批 (b) 同点）、
//        rtl/core/csr_file.sv（mip/mie/mstatus 门控、trap_enter 的中断路径、mret）
//  依据：TECHNICAL_BASELINE.md「中断仅在指令边界采样，异常优先于同拍中断；
//        Stage2 实现 timer 和外部 machine interrupt」
//        ADR-CSR-ACCESS.md §6 D12（EX/MEM 采样 + 异常优先）/ D13（重试语义：
//        mepc 记被中断指令 PC，mret 后恰好再退休一次）/ D14（MTIP 真实接入，
//        MEIP 仅接线未验证）
//
//  覆盖：
//    I1 定时器中断进入并 mret 返回：cause=0x80000007（bit31=1）、mepc=0x18、
//       被中断指令以 trap 事件退役（rd_we=0）且 mret 后恰好再退休一次；
//       处理器读到 mstatus=0x1880（MIE→MPIE、MIE=0）
//    I2 mstatus.MIE=0 时全局不响应：mip.MTIP=1 且 mie.MTIE=1 也不进陷阱
//    I3 mie.MTIE=0 时按源不响应：MIE=1 且 mip.MTIP=1 也不进陷阱
//    I4 异常优先于同拍中断：ECALL 与 MTIP 同拍成立时 mcause=11（bit31=0），
//       陷阱拍 mip=0x80 是「同拍两者都成立」的直接证据
//    I5 mip.MTIP 随 timer_irq 电平撤销：trap_commit 拍撤销后处理器读 mip=0，
//       且 mret 后无重入（重试恰好一次完成）
//
//  ---- 期望值来自静态推导（仿真只确证一次，不得反向改期望迁就仿真）----
//  被中断指令落点的推导（I1，程序见 rom()）：
//    hazard_detection.v:26 的 (ex_rd != 5'd0) 排除了 rd=x0 的 CSR 生产者
//    （csrrsi x0,mstatus,8）触发的 CSR-use 互锁 → 0x10..0x18 区间无气泡，
//    各级逐拍推进：
//      0x10(csrrsi mstatus) 提交拍 C：XM 持 0x14(nop)，该拍 mstatus_mie_q
//      仍为旧值 0（写在该拍末生效）→ irq_pending=0 → 不采 0x14；
//      C+1 拍：XM 持 0x18(addi x20)，MIE=1 已可见、MTIP/MTIE 均为 1
//      → 首个满足 D12 采样条件的指令 = 0x18，mepc = 0x18。
//
//  ---- timer_irq 的撤销是结构性必须，不是保险措施 ----
//    trap_enter 把 MIE→MPIE、MIE←0；mret 在提交拍恢复 MIE=1。若不撤销
//    timer_irq，mret 之后第一条回到 XM 的指令（重取的被中断指令本身）会在
//    MIE=1 且 MTIP 仍高的拍被再次采样 → 无限重入。故 TB 在 dut.trap_commit
//    拍无条件撤销 timer_irq。
// ============================================================================
`timescale 1ns/1ps

module tb_cpu_core_irq;
    localparam integer S_IRQ_ENTRY = 0;
    localparam integer S_MIE0      = 1;
    localparam integer S_MTIE0     = 2;
    localparam integer S_EXC_PRI   = 3;
    localparam integer S_LEVEL     = 4;

    reg clk = 1'b0;
    reg rst = 1'b1;
    integer scenario = S_IRQ_ENTRY;
    always #5 clk = ~clk;

    // 程序统一布局（全部场景同一骨架，仅 5 个场景化单元）：
    //   0x00 addi  x1, x0, 0x40     ; mtvec 值
    //   0x04 csrrw  x0, mtvec, x1
    //   0x08 addi  x2, x0, 0x80     ; mie.MTIE
    //   0x0c csrrw  x0, mie, x2     ; I3(S_MTIE0) 时为 nop（不使能源）
    //   0x10 csrrsi x0, mstatus, 8  ; MIE=1；I2(S_MIE0) 时为 nop（不开全局）
    //   0x14 nop                    ; 隔离 nop（把采样点从时序巧合变成确定结论）
    //   0x18 addi  x20, x0, 1       ; I1/I2/I3/I5 的被中断/不应中断指令；
    //                                ; I4(S_EXC_PRI) 时为 ecall
    //   0x1c addi  x21, x0, 2
    //   0x20 addi  x22, x0, 3
    //   0x24 addi  x23, x0, 4       ; 程序末尾（其后取指不 ready → CPU 停住）
    //   0x40 csrrs  x10, mcause, x0 ; 处理器（全部场景共用骨架）
    //   0x44 csrrs  x11, mepc, x0
    //   0x48 <场景化>：I1 读 mstatus / I4 改 mepc+4 / I5 读 mip / 其余 nop
    //   0x4c <场景化>：I4 csrrw mepc / 其余 nop
    //   0x50 nop
    //   0x54 mret                   ; I1/I5 不改 mepc（重试语义）；I4 已改（ecall 不重试）
    reg [31:0] prog_end = 32'h24;

    function automatic [31:0] rom(input [31:0] addr);
        begin
            rom = 32'h00000013;                           // 默认 NOP
            case (addr)
                32'h00: rom = 32'h04000093;               // addi  x1, x0, 0x40
                32'h04: rom = 32'h30509073;               // csrrw  x0, mtvec, x1
                32'h08: rom = 32'h08000113;               // addi  x2, x0, 0x80
                32'h0c: rom = (scenario == S_MTIE0) ? 32'h00000013  // nop：不使能源
                                                     : 32'h30411073; // csrrw x0, mie, x2
                32'h10: rom = (scenario == S_MIE0) ? 32'h00000013  // nop：不开全局使能
                                                     : 32'h30045073; // csrrsi x0, mstatus, 8
                32'h14: rom = 32'h00000013;               // 隔离 nop
                32'h18: rom = (scenario == S_EXC_PRI) ? 32'h00000073  // ecall
                                                       : 32'h00100A13; // addi x20, x0, 1
                32'h1c: rom = 32'h00200A93;               // addi  x21, x0, 2
                32'h20: rom = 32'h00300B13;               // addi  x22, x0, 3
                32'h24: rom = 32'h00400B93;               // addi  x23, x0, 4
                32'h40: rom = 32'h34202573;               // csrrs  x10, mcause, x0
                32'h44: rom = 32'h341025F3;               // csrrs  x11, mepc, x0
                32'h48: rom = (scenario == S_IRQ_ENTRY) ? 32'h30002673  // csrrs x12, mstatus
                                                      : (scenario == S_EXC_PRI) ? 32'h00458593  // addi x11,x11,4
                                                      : (scenario == S_LEVEL)     ? 32'h34402673  // csrrs x12, mip
                                                      : 32'h00000013;
                32'h4c: rom = (scenario == S_EXC_PRI) ? 32'h34159073  // csrrw x0, mepc, x11
                                                       : 32'h00000013;
                32'h50: rom = 32'h00000013;               // nop
                32'h54: rom = 32'h30200073;               // mret
                default: rom = 32'h00000013;
            endcase
        end
    endfunction

    // ---------------- I 侧（与 tb_cpu_core_trap 同款模型） ----------------
    wire i_req_valid, i_req_ready, i_rsp_ready;
    wire [31:0] i_req_addr;
    reg i_rsp_valid = 1'b0;
    wire [31:0] i_rsp_data;
    reg [31:0] i_rsp_data_q = 32'h00000013;
    assign i_req_ready = (i_req_addr <= prog_end) ||
                         (i_req_addr >= 32'h40 && i_req_addr <= 32'h54);
    always @(posedge clk) begin
        if (rst) begin
            i_rsp_valid <= 1'b0;
            i_rsp_data_q <= 32'h00000013;
        end else begin
            i_rsp_valid <= 1'b0;
            if (i_req_valid && i_req_ready) begin
                i_rsp_valid <= 1'b1;
                i_rsp_data_q <= rom(i_req_addr);
            end
        end
    end
    assign i_rsp_data = i_rsp_data_q;

    // ---------------- D 侧（本测试无访存指令，最小化从端） ----------------
    wire d_req_valid, d_req_ready, d_req_write, d_rsp_ready;
    wire [31:0] d_req_addr, d_req_wdata, d_rsp_rdata;
    wire [3:0] d_req_wstrb;
    assign d_req_ready = 1'b1;
    assign d_rsp_rdata = 32'h0;

    // ---------------- 中断源驱动（场景化） ----------------
    // I1/I2/I3/I5：场景开始即拉高（MIE/mie 门控自然把首个可采样拍排到 0x18）；
    // I4：等到 ecall 进入 ID（dut.id_pc===0x18）才拉高 —— 保证 MTIP 与 ECALL
    //     在 EX/MEM 判定拍同拍成立（提前一拍置位，避开同沿竞争）。
    // 所有产生陷阱的场景：dut.trap_commit 拍无条件撤销（结构性必须，见文件头）。
    reg timer_irq_q = 1'b0;
    reg f_raise4 = 1'b0;
    always @(posedge clk) begin
        if (rst) begin
            timer_irq_q <= (scenario == S_EXC_PRI) ? 1'b0 : 1'b1;
            f_raise4 <= 1'b0;
        end else begin
            if (scenario == S_EXC_PRI && !f_raise4 && dut.id_pc === 32'h18) begin
                timer_irq_q <= 1'b1;
                f_raise4 <= 1'b1;
            end
            if (dut.trap_commit)
                timer_irq_q <= 1'b0;
        end
    end

    wire trace_valid, trace_rd_we, trace_trap;
    wire [63:0] trace_order;
    wire [31:0] trace_pc, trace_instr, trace_rd_data, trace_cause;
    wire [4:0] trace_rd;

    cpu_core_stage1 dut (
        .clk(clk), .rst(rst), .i_req_valid(i_req_valid), .i_req_ready(i_req_ready),
        .i_req_addr(i_req_addr), .i_rsp_valid(i_rsp_valid), .i_rsp_ready(i_rsp_ready),
        .i_rsp_data(i_rsp_data), .i_rsp_error(1'b0), .d_req_valid(d_req_valid),
        .d_req_ready(d_req_ready), .d_req_addr(d_req_addr), .d_req_write(d_req_write),
        .d_req_wdata(d_req_wdata), .d_req_wstrb(d_req_wstrb),
        .d_rsp_valid(1'b0), .d_rsp_ready(d_rsp_ready), .d_rsp_rdata(d_rsp_rdata),
        .d_rsp_error(1'b0), .trace_valid(trace_valid), .trace_order(trace_order),
        .trace_pc(trace_pc), .trace_instr(trace_instr), .trace_rd(trace_rd),
        .trace_rd_data(trace_rd_data), .trace_rd_we(trace_rd_we), .trace_trap(trace_trap),
        .trace_cause(trace_cause),
        .timer_irq_i(timer_irq_q), .ext_irq_i(1'b0)   // D14：只验证 MTIP 路径
    );

    // ---------------- 观测 ----------------
    integer checks = 0, errors = 0;
    integer trap_fires = 0;
    integer mret_fires = 0;
    integer retires = 0;
    reg [31:0] ret_pc [0:63];
    reg        ret_trap [0:63];
    reg        ret_rd_we [0:63];
    reg [31:0] ret_cause [0:63];
    reg [31:0] mip_at_trap = 32'hFFFFFFFF;
    reg [31:0] trap_pc_seen = 32'hFFFFFFFF;
    reg [31:0] x20_at_mret = 32'hFFFFFFFF;

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

    // 统计某 PC 的退役次数（循环变量置于模块级：Icarus 10.2 对函数内声明的限制）
    integer rpc_count, lp_i;
    task automatic count_retired(input [31:0] pc);
        begin
            rpc_count = 0;
            for (lp_i = 0; lp_i < retires; lp_i = lp_i + 1)
                if (ret_pc[lp_i] === pc) rpc_count = rpc_count + 1;
        end
    endtask

    // trap_commit 拍采证：mip 电平（同拍中断是否真的成立）+ 计数；
    // mret_commit 拍采证：x20 尚未被写（被中断指令在重试前无架构效果）
    always @(posedge clk) begin
        if (!rst) begin
            if (dut.trap_commit) begin
                trap_fires = trap_fires + 1;
                mip_at_trap = dut.u_csr.mip;
                // D13 直接证据：trap_commit 拍写入 mepc 的正是 mw_pc（被中断指令 PC）
                trap_pc_seen = dut.mw_pc;
            end
            if (dut.mret_commit) begin
                mret_fires = mret_fires + 1;
                x20_at_mret = dut.u_regfile.regs[20];
            end
        end
    end

    always @(negedge clk) begin
        if (!rst && trace_valid) begin
            if (retires < 64) begin
                ret_pc[retires] = trace_pc;
                ret_trap[retires] = trace_trap;
                ret_rd_we[retires] = trace_rd_we;
                ret_cause[retires] = trace_cause;
            end
            retires = retires + 1;
        end
    end

    task automatic run_case(input integer which, input [31:0] endpc);
        begin
            @(negedge clk);
            rst = 1'b1; scenario = which; prog_end = endpc;
            repeat (3) @(posedge clk);
            @(negedge clk);
            trap_fires = 0; mret_fires = 0; retires = 0;
            mip_at_trap = 32'hFFFFFFFF; trap_pc_seen = 32'hFFFFFFFF;
            x20_at_mret = 32'hFFFFFFFF;
            rst = 1'b0;
            repeat (200) @(posedge clk);
        end
    endtask

    initial begin
        $display("==================================================");
        $display("  cpu_core_stage1 机器中断接入（批 (c)）");
        $display("==================================================");

        // ---------------- I1 定时器中断进入 + mret 重试往返 ----------------
        run_case(S_IRQ_ENTRY, 32'h24);
        chk("I1 mcause=MTIP 0x80000007", dut.u_csr.mcause, 32'h80000007);
        chk("I1 mepc=interrupted pc 18", dut.u_csr.mepc, 32'h18);
        chk("I1 mtval=0 (interrupt)", dut.u_csr.mtval, 32'h0);
        chk("I1 trap_pc written = 18", trap_pc_seen, 32'h18);
        chk("I1 mip@trap=0x80 pending", mip_at_trap, 32'h80);
        chk("I1 trap_enter fired once", trap_fires, 1);
        chk("I1 mret fired once", mret_fires, 1);
        chk("I1 handler mcause read", dut.u_regfile.regs[10], 32'h80000007);
        chk("I1 handler mepc read 18", dut.u_regfile.regs[11], 32'h18);
        chk("I1 handler mstatus 1880", dut.u_regfile.regs[12], 32'h1880);
        chk("I1 mstatus after mret 1888", dut.u_csr.mstatus, 32'h1888);
        chk("I1 x20 unwritten at mret", x20_at_mret, 32'h0);
        chk("I1 x20 written on retry", dut.u_regfile.regs[20], 32'd1);
        chk("I1 x21 ran after retry", dut.u_regfile.regs[21], 32'd2);
        chk("I1 x22 ran after retry", dut.u_regfile.regs[22], 32'd3);
        chk("I1 x23 ran after retry", dut.u_regfile.regs[23], 32'd4);
        count_retired(32'h18);
        chk("I1 pc18 retired exactly 2x", rpc_count, 2);
        chk("I1 retire count", retires, 17);
        if (retires >= 17) begin
            chk("I1 retire 6 = pc18 trap", ret_pc[6], 32'h18);
            chk("I1 pc18 retire trap=1", {31'b0, ret_trap[6]}, 32'd1);
            // D10/D13 验收面：中断退役事件在 trace_cause 上承载 bit31=1 且低 4 位=7
            chk("I1 trace cause 0x80000007", ret_cause[6], 32'h80000007);
            chk("I1 trap retire rd_we=0", {31'b0, ret_rd_we[6]}, 32'd0);
            chk("I1 retire 7 = handler", ret_pc[7], 32'h40);
            chk("I1 retire 12 = mret", ret_pc[12], 32'h54);
            chk("I1 retire 13 = pc18 retry", ret_pc[13], 32'h18);
            chk("I1 retry not trap", {31'b0, ret_trap[13]}, 32'd0);
            chk("I1 retry cause=0", ret_cause[13], 32'd0);
            chk("I1 retry wrote rd", {31'b0, ret_rd_we[13]}, 32'd1);
            chk("I1 retire 14", ret_pc[14], 32'h1c);
            chk("I1 retire 15", ret_pc[15], 32'h20);
            chk("I1 retire 16", ret_pc[16], 32'h24);
        end else begin
            errors = errors + 1; checks = checks + 1;
            $display("FAIL [I1 retire count] got=%0d want=17", retires);
        end

        // ---------------- I2 mstatus.MIE=0：全局不响应 ----------------
        run_case(S_MIE0, 32'h24);
        chk("I2 no trap fired", trap_fires, 0);
        chk("I2 mcause stays 0", dut.u_csr.mcause, 32'd0);
        chk("I2 mepc stays 0", dut.u_csr.mepc, 32'd0);
        chk("I2 mie.MTIE was set", dut.u_csr.mie, 32'h00000080);
        chk("I2 mip.MTIP still high", dut.u_csr.mip, 32'h00000080);
        chk("I2 mstatus.MIE still 0", dut.u_csr.mstatus, 32'h1800);
        chk("I2 irq_pending gated off", {31'b0, dut.u_csr.irq_pending}, 32'd0);
        chk("I2 retire count", retires, 10);
        if (retires >= 10) begin
            chk("I2 retire 6 = pc18 normal", ret_pc[6], 32'h18);
            chk("I2 pc18 not trap", {31'b0, ret_trap[6]}, 32'd0);
            chk("I2 pc18 wrote rd", {31'b0, ret_rd_we[6]}, 32'd1);
        end
        chk("I2 x20..x23 all ran", dut.u_regfile.regs[23], 32'd4);

        // ---------------- I3 mie.MTIE=0：按源不响应 ----------------
        run_case(S_MTIE0, 32'h24);
        chk("I3 no trap fired", trap_fires, 0);
        chk("I3 mcause stays 0", dut.u_csr.mcause, 32'd0);
        chk("I3 mie stays 0", dut.u_csr.mie, 32'h0);
        chk("I3 mstatus.MIE was set", dut.u_csr.mstatus, 32'h1808);
        chk("I3 mip.MTIP still high", dut.u_csr.mip, 32'h00000080);
        chk("I3 irq_pending gated off", {31'b0, dut.u_csr.irq_pending}, 32'd0);
        chk("I3 retire count", retires, 10);
        chk("I3 x20..x23 all ran", dut.u_regfile.regs[23], 32'd4);

        // ---------------- I4 异常优先于同拍中断 ----------------
        run_case(S_EXC_PRI, 32'h24);
        chk("I4 mcause=ECALL 11 not irq", dut.u_csr.mcause, 32'd11);
        // I4：处理器把 mepc 改写为 mepc+4 后才 mret（ecall 不重试），故终态 mepc=0x1c；
        // "陷阱时 mepc=0x18"由 trap_commit 拍采样的 trap_pc_seen 直接证明
        chk("I4 mepc final = ecall+4", dut.u_csr.mepc, 32'h1c);
        chk("I4 trap_pc written = 18", trap_pc_seen, 32'h18);
        chk("I4 mip@trap=0x80 same-cyc", mip_at_trap, 32'h80);
        chk("I4 trap_enter fired once", trap_fires, 1);
        chk("I4 mret fired once", mret_fires, 1);
        chk("I4 handler mcause read 11", dut.u_regfile.regs[10], 32'd11);
        // x11 = mepc+4 = 0x1c 反证处理器读到的 mepc 是 0x18（而非 0x80000018）
        chk("I4 handler mepc read 18 (+4)", dut.u_regfile.regs[11], 32'h1c);
        count_retired(32'h18);
        chk("I4 pc18 retired once only", rpc_count, 1);
        chk("I4 retire count", retires, 16);
        if (retires >= 16) begin
            chk("I4 retire 6 = ecall trap", ret_pc[6], 32'h18);
            chk("I4 trace cause=11 no bit31", ret_cause[6], 32'd11);
            chk("I4 retire 13 = return 1c", ret_pc[13], 32'h1c);
            chk("I4 retire 14", ret_pc[14], 32'h20);
            chk("I4 retire 15", ret_pc[15], 32'h24);
        end else begin
            errors = errors + 1; checks = checks + 1;
            $display("FAIL [I4 retire count] got=%0d want=16", retires);
        end
        chk("I4 x21 ran after return", dut.u_regfile.regs[21], 32'd2);
        chk("I4 x23 ran after return", dut.u_regfile.regs[23], 32'd4);

        // ---------------- I5 mip.MTIP 随 timer_irq 电平撤销 ----------------
        run_case(S_LEVEL, 32'h24);
        chk("I5 mcause=MTIP 0x80000007", dut.u_csr.mcause, 32'h80000007);
        chk("I5 mepc=interrupted pc 18", dut.u_csr.mepc, 32'h18);
        chk("I5 trap_pc written = 18", trap_pc_seen, 32'h18);
        chk("I5 mip@trap=0x80 pending", mip_at_trap, 32'h80);
        chk("I5 handler read mip=0", dut.u_regfile.regs[12], 32'h0);
        chk("I5 trap fired exactly once", trap_fires, 1);
        chk("I5 mret fired once", mret_fires, 1);
        chk("I5 mstatus restored 1888", dut.u_csr.mstatus, 32'h1888);
        count_retired(32'h18);
        chk("I5 pc18 retired exactly 2x", rpc_count, 2);
        chk("I5 retire count", retires, 17);
        chk("I5 x20 written on retry", dut.u_regfile.regs[20], 32'd1);
        chk("I5 x23 ran after retry", dut.u_regfile.regs[23], 32'd4);

        $display("==================================================");
        $display("  检查项: %0d", checks);
        if (errors == 0)
            $display("  ALL TESTS PASSED (0 errors)");
        else
            $display("  %0d FAILED", errors);
        $display("==================================================");
        if (errors != 0) $fatal(1, "irq tests failed");
        $finish;
    end

    initial begin
        #500000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
