// ============================================================================
//  cpu_core_stage1 —— 同步异常精确陷阱（批 (b)）
//
//  被测：rtl/core/cpu_core_stage1.sv（陷阱判定在 EX/MEM 边界）、
//        rtl/core/csr_file.sv（trap_enter/mret 与 mepc/mcause/mtval）、
//        rtl/core/riscv_lsu.sv（非对齐/故障归因）、rtl/core/id_stage.sv（SYSTEM 译码）
//  依据：TECHNICAL_BASELINE.md「异常提交为精确 machine trap：最老 fault 指令及更年轻
//        指令不产生架构效果；已完成的更老效果保留」「先实现 illegal instruction、
//        instruction/data access fault、misaligned load/store、ECALL/EBREAK；设置
//        mepc/mcause/mtval 并跳转 mtvec direct。mret 恢复 mepc 与最小 mstatus 位」
//
//  覆盖：
//    T1  ECALL → 陷阱（cause 11）→ 处理器读 mcause/mepc → 改写 mepc → mret 正确返回
//        （同时验证「重定向保持到提交」：紧邻 mret 前的 csrrw mepc 必须先落地）
//    T2  EBREAK → cause 3
//    T3  非法指令 → cause 2，mtval = 指令字
//    T4  非法 CSR（未实现地址）→ cause 2，rd 不写
//    T5  非法 CSR（对只读 CSR 的写意图）→ cause 2，rd 不写
//    T6  非对齐 load → cause 4，mtval = 非对齐地址，**不发访存请求**
//    T7  非对齐 store → cause 6，mtval = 非对齐地址，**不发请求、不改内存**
//    T8  访存故障 load → cause 5，mtval = 访问地址
//    T9  访存故障 store → cause 7，mtval = 访问地址，内存不变
//    T10 最老 fault 优先：老 load 故障 + 年轻非法指令 → 恰好 1 次陷阱，mepc = 老指令
//    T11 更年轻指令**无架构效果**：老 load 故障 + 年轻 store → 年轻 store 不得写内存
//    T12 陷阱状态恰好写入一次（trap_enter 脉冲计数 == 1），且处理器读到的就是它
// ============================================================================
`timescale 1ns/1ps

module tb_cpu_core_trap;
    localparam integer S_ECALL         = 0;
    localparam integer S_EBREAK        = 1;
    localparam integer S_ILLEGAL_INSTR = 2;
    localparam integer S_CSR_UNIMPL    = 3;
    localparam integer S_CSR_RO_WRITE  = 4;
    localparam integer S_LD_MISALIGN   = 5;
    localparam integer S_ST_MISALIGN   = 6;
    localparam integer S_LD_FAULT      = 7;
    localparam integer S_ST_FAULT      = 8;
    localparam integer S_OLDEST_WINS   = 9;
    localparam integer S_YOUNG_STORE   = 10;

    reg clk = 1'b0;
    reg rst = 1'b1;
    integer scenario = S_ECALL;
    always #5 clk = ~clk;

    // 程序统一布局（便于逐场景对齐）：
    //   0x00 addi  x1, x0, 32        ; 处理器入口
    //   0x04 csrrw x0, mtvec, x1     ; mtvec = 0x20
    //   0x08 <场景前置指令 / NOP>
    //   0x0c <出错指令>
    //   0x10 <更年轻指令 1>
    //   0x14 <更年轻指令 2>
    //   0x18 NOP                     ; 程序末尾（其后取指不 ready → CPU 停住）
    //   0x20..0x30 处理器
    // 取指 ready 规则：程序区 [0x00, prog_end] 与处理器区 [0x20, handler_hi]；
    //                   其余地址一律不 ready → CPU 停住（可稳定观测）
    reg [31:0] prog_end = 32'h18;
    reg [31:0] handler_hi = 32'h28;

    function automatic [31:0] rom(input [31:0] addr);
        begin
            rom = 32'h00000013;                           // 默认 NOP
            case (addr)
                32'h00: rom = 32'h02000093;               // addi  x1, x0, 32
                32'h04: rom = 32'h30509073;               // csrrw x0, mtvec, x1
                32'h20: rom = 32'h34202573;               // csrrs x10, mcause, x0
                32'h24: rom = 32'h341025f3;               // csrrs x11, mepc, x0
                // ECALL 场景的处理器继续 mret（改写 mepc 后返回）；其余场景读到 mtval 即停
                32'h28: rom = (scenario == S_ECALL) ? 32'h00458593   // addi x11, x11, 4
                                                    : 32'h34302673;  // csrrs x12, mtval, x0
                32'h2c: rom = 32'h34159073;               // csrrw x0, mepc, x11
                32'h30: rom = 32'h30200073;               // mret
                default: rom = 32'h00000013;
            endcase
            // ---- 场景相关单元 ----
            case (scenario)
                S_ECALL: begin
                    if (addr == 32'h08) rom = 32'h00100113;      // addi x2, x0, 1
                    if (addr == 32'h0c) rom = 32'h00000073;      // ecall
                    if (addr == 32'h10) rom = 32'h00300193;      // addi x3, x0, 3
                    if (addr == 32'h14) rom = 32'h00400213;      // addi x4, x0, 4
                end
                S_EBREAK: begin
                    if (addr == 32'h0c) rom = 32'h00100073;      // ebreak
                    if (addr == 32'h10) rom = 32'h00300193;      // addi x3, x0, 3
                end
                S_ILLEGAL_INSTR: begin
                    if (addr == 32'h0c) rom = 32'h12345678;      // 非法编码（opcode 0x78）
                    if (addr == 32'h10) rom = 32'h00300193;
                end
                S_CSR_UNIMPL: begin
                    if (addr == 32'h0c) rom = 32'h000022f3;      // csrrs x5, 0x000, x0
                    if (addr == 32'h10) rom = 32'h00300193;
                end
                S_CSR_RO_WRITE: begin
                    if (addr == 32'h0c) rom = 32'h344092f3;      // csrrw x5, mip, x1
                    if (addr == 32'h10) rom = 32'h00300193;
                end
                S_LD_MISALIGN: begin
                    if (addr == 32'h0c) rom = 32'h00102283;      // lw x5, 1(x0)
                    if (addr == 32'h10) rom = 32'h00300193;
                end
                S_ST_MISALIGN: begin
                    if (addr == 32'h08) rom = 32'h05500393;      // addi x7, x0, 0x55
                    if (addr == 32'h0c) rom = 32'h00102123;      // sw x1, 2(x0)
                    if (addr == 32'h10) rom = 32'h00300193;
                end
                S_LD_FAULT: begin
                    if (addr == 32'h0c) rom = 32'h00802283;      // lw x5, 8(x0)（响应报错）
                    if (addr == 32'h10) rom = 32'h00300193;
                end
                S_ST_FAULT: begin
                    if (addr == 32'h08) rom = 32'h05500393;      // addi x7, x0, 0x55
                    if (addr == 32'h0c) rom = 32'h00102623;      // sw x1, 12(x0)（响应报错）
                    if (addr == 32'h10) rom = 32'h00300193;
                end
                S_OLDEST_WINS: begin
                    if (addr == 32'h08) rom = 32'h00802283;      // 老：lw x5, 8(x0)（响应报错）
                    if (addr == 32'h0c) rom = 32'h12345678;      // 年轻：非法指令（须被冲刷）
                    if (addr == 32'h10) rom = 32'h00600313;      // 年轻：addi x6, x0, 6
                end
                S_YOUNG_STORE: begin
                    if (addr == 32'h08) rom = 32'h05500393;      // addi x7, x0, 0x55
                    if (addr == 32'h0c) rom = 32'h00802283;      // 老：lw x5, 8(x0)（响应报错）
                    if (addr == 32'h10) rom = 32'h00702223;      // 年轻：sw x7, 4(x0) 不得执行
                end
            endcase
        end
    endfunction

    // ---------------- I 侧 ----------------
    wire i_req_valid, i_req_ready, i_rsp_ready;
    wire [31:0] i_req_addr;
    reg i_rsp_valid = 1'b0;
    wire [31:0] i_rsp_data;
    reg [31:0] i_rsp_data_q = 32'h00000013;
    assign i_req_ready = (i_req_addr <= prog_end) ||
                         (i_req_addr >= 32'h20 && i_req_addr <= handler_hi);
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

    // ---------------- D 侧：两拍响应；访存故障场景下带 error ----------------
    wire d_req_valid, d_req_ready, d_req_write, d_rsp_ready;
    wire [31:0] d_req_addr, d_req_wdata, d_rsp_rdata;
    wire [3:0] d_req_wstrb;
    reg d_rsp_valid = 1'b0, d_rsp_error = 1'b0;
    reg [31:0] d_rsp_rdata_q = 32'h0;
    reg [31:0] dmem [0:3];
    reg pending_rsp = 1'b0;
    reg [2:0] rsp_delay = 0;
    reg [31:0] pending_addr = 0, pending_wdata = 0;
    reg [3:0] pending_wstrb = 0;
    reg pending_write = 0;
    integer d_req_count = 0, d_write_count = 0;
    assign d_req_ready = !pending_rsp;
    assign d_rsp_rdata = d_rsp_rdata_q;

    // 本场景是否要求 D 侧以 error 响应（访存故障类场景）
    reg d_err_scenario;
    always @(*) begin
        d_err_scenario = (scenario == S_LD_FAULT) || (scenario == S_ST_FAULT) ||
                         (scenario == S_OLDEST_WINS) || (scenario == S_YOUNG_STORE);
    end

    always @(posedge clk) begin
        if (rst) begin
            dmem[0] <= 32'h11223344;
            dmem[1] <= 32'h0000ABCD;
            dmem[2] <= 32'h0;
            dmem[3] <= 32'h0;
            pending_rsp <= 1'b0; d_rsp_valid <= 1'b0; d_rsp_error <= 1'b0;
            rsp_delay <= 0; d_req_count <= 0; d_write_count <= 0;
            pending_addr <= 0; pending_wdata <= 0; pending_wstrb <= 0; pending_write <= 0;
            d_rsp_rdata_q <= 0;
        end else begin
            if (d_req_valid && d_req_ready) begin
                d_req_count <= d_req_count + 1;
                if (d_req_write) d_write_count <= d_write_count + 1;
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
                d_rsp_error <= d_err_scenario;
                d_rsp_rdata_q <= dmem[pending_addr[3:2]];
            end
            if (d_rsp_valid && d_rsp_ready) begin
                if (pending_write && !d_rsp_error) begin
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

    wire trace_valid, trace_rd_we, trace_trap;
    wire [63:0] trace_order;
    wire [31:0] trace_pc, trace_instr, trace_rd_data;
    wire [31:0] trace_cause;
    wire [4:0] trace_rd;

    cpu_core_stage1 dut (
        .clk(clk), .rst(rst), .i_req_valid(i_req_valid), .i_req_ready(i_req_ready),
        .i_req_addr(i_req_addr), .i_rsp_valid(i_rsp_valid), .i_rsp_ready(i_rsp_ready),
        .i_rsp_data(i_rsp_data), .i_rsp_error(1'b0), .d_req_valid(d_req_valid),
        .d_req_ready(d_req_ready), .d_req_addr(d_req_addr), .d_req_write(d_req_write),
        .d_req_wdata(d_req_wdata), .d_req_wstrb(d_req_wstrb),
        .d_rsp_valid(d_rsp_valid), .d_rsp_ready(d_rsp_ready), .d_rsp_rdata(d_rsp_rdata),
        .d_rsp_error(d_rsp_error), .trace_valid(trace_valid), .trace_order(trace_order),
        .trace_pc(trace_pc), .trace_instr(trace_instr), .trace_rd(trace_rd),
        .trace_rd_data(trace_rd_data), .trace_rd_we(trace_rd_we), .trace_trap(trace_trap),
        .trace_cause(trace_cause),
        .timer_irq_i(1'b0), .ext_irq_i(1'b0)   // 批 (c)：同步异常测试不涉及中断（中断见 tb_cpu_core_irq）
    );

    // ---------------- 观测 ----------------
    integer checks = 0, errors = 0;
    integer trap_fires = 0;
    integer mret_fires = 0;
    integer retires = 0;
    reg [31:0] ret_pc [0:63];
    reg        ret_trap [0:63];
    reg [31:0] ret_cause [0:63];
    integer trap_zero_cause = 0;
    integer probe_hits = 0;
    // Issue #15 第 4 项：backend_hold 与 redirect 同拍的**整机联合观测**（跨全部 11 个场景累计）。
    // 场景：老访存指令未完成（backend_hold）时，年轻指令在 ID/EX 且同拍发生重定向
    // （同步异常/陷阱保持窗），pipeline_control 必须"保持老、冲刷年轻"。
    integer hold_redir_joint = 0;        // dut.backend_hold && dut.redirect_valid
    integer hold_redir_joint_idex = 0;   // 上者 && dut.idex_valid（有效年轻 ID/EX 确实在位）
    integer hold_redir_joint_flush = 0;  // 上者 && dut.flush_id_ex（同拍冲刷年轻 ID/EX）
    reg [31:0] probe_pc = 32'hFFFFFFFF;

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

    // 统计某 PC 的退役次数（循环变量置于模块级，避免 Icarus 对函数内声明的限制）
    integer rpc_count, lp_i;
    task automatic count_retired(input [31:0] pc);
        begin
            rpc_count = 0;
            for (lp_i = 0; lp_i < retires; lp_i = lp_i + 1)
                if (ret_pc[lp_i] === pc) rpc_count = rpc_count + 1;
        end
    endtask

    always @(posedge clk) begin
        if (!rst) begin
            if (dut.trap_commit) trap_fires = trap_fires + 1;
            if (dut.mret_commit) mret_fires = mret_fires + 1;
            if (dut.id_valid && (dut.id_pc === probe_pc)) probe_hits = probe_hits + 1;
            if (dut.backend_hold && dut.redirect_valid) begin
                hold_redir_joint = hold_redir_joint + 1;
                if (dut.idex_valid)  hold_redir_joint_idex  = hold_redir_joint_idex  + 1;
                if (dut.flush_id_ex) hold_redir_joint_flush = hold_redir_joint_flush + 1;
            end
        end
    end

    always @(negedge clk) begin
        if (!rst && trace_valid) begin
            if (retires < 64) begin
                ret_pc[retires] = trace_pc;
                ret_trap[retires] = trace_trap;
                ret_cause[retires] = trace_cause;
            end
            retires = retires + 1;
            if (trace_trap && (trace_cause == 32'd0)) trap_zero_cause = trap_zero_cause + 1;
        end
    end

    // 退休 trace 的 cause 字段（批 (b) 新增字段）核对
    task automatic chk_cause(input [255:0] nm, input integer idx, input [31:0] want);
        begin
            checks = checks + 1;
            if (retires <= idx) begin
                errors = errors + 1;
                $display("FAIL [%0s] only %0d retirements", nm, retires);
            end else if (ret_cause[idx] !== want) begin
                errors = errors + 1;
                $display("FAIL [%0s] got=%08h want=%08h", nm, ret_cause[idx], want);
            end else begin
                $display("PASS [%0s] = %08h", nm, ret_cause[idx]);
            end
        end
    endtask

    task automatic run_case(input integer which, input [31:0] endpc);
        begin
            @(negedge clk);
            rst = 1'b1; scenario = which; prog_end = endpc;
            handler_hi = (which == S_ECALL) ? 32'h30 : 32'h28;
            repeat (3) @(posedge clk);
            @(negedge clk);
            trap_fires = 0; mret_fires = 0; retires = 0; probe_hits = 0;
            d_req_count = 0; d_write_count = 0;
            rst = 1'b0;
            repeat (160) @(posedge clk);
        end
    endtask

    initial begin
        $display("==================================================");
        $display("  cpu_core_stage1 同步异常精确陷阱（批 (b)）");
        $display("==================================================");

        // ---------------- T1 ECALL → 处理器 → mret 返回 ----------------
        probe_pc = 32'h10;
        run_case(S_ECALL, 32'h18);
        chk("T1 mcause = ECALL(11)", dut.u_csr.mcause, 32'd11);
        // 处理器把 mepc 改写成 mepc+4 后才 mret，故终态 mepc = 0x10；
        // "陷阱时 mepc=0x0c"由 x11 = mepc+4 = 0x10 反证（并见退休顺序）
        chk("T1 mepc after handler = pc+4", dut.u_csr.mepc, 32'h10);
        chk("T1 mtval = 0 (ECALL)", dut.u_csr.mtval, 32'h0);
        chk("T1 trap_enter fired once", trap_fires, 1);
        chk("T1 mret fired once", mret_fires, 1);
        chk("T1 handler read mcause", dut.u_regfile.regs[10], 32'd11);
        chk("T1 handler rewrote mepc+4", dut.u_regfile.regs[11], 32'h10);
        chk("T1 pre-trap marker executed", dut.u_regfile.regs[2], 32'd1);
        chk("T1 post-mret instruction ran", dut.u_regfile.regs[3], 32'd3);
        chk("T1 tail instruction ran", dut.u_regfile.regs[4], 32'd4);
        // 退休顺序证明「更年轻指令在处理器之后才执行」
        chk("T1 retire count", retires, 12);
        if (retires >= 12) begin
            chk("T1 retire 0", ret_pc[0], 32'h00);
            chk("T1 retire 1", ret_pc[1], 32'h04);
            chk("T1 retire 2", ret_pc[2], 32'h08);
            chk("T1 retire 3 = ecall", ret_pc[3], 32'h0c);
            chk("T1 trap marked once", {31'b0, ret_trap[3]}, 32'd1);
            chk("T1 retire 4 = handler", ret_pc[4], 32'h20);
            chk("T1 handler not trap", {31'b0, ret_trap[4]}, 32'd0);
            chk("T1 retire 8 = mret", ret_pc[8], 32'h30);
            chk("T1 retire 9 = returned", ret_pc[9], 32'h10);
            chk("T1 retire 10", ret_pc[10], 32'h14);
            chk_cause("T1 trace cause = 11", 3, 32'd11);
            chk_cause("T1 handler cause = 0", 4, 32'd0);
        end else begin
            errors = errors + 1; checks = checks + 1;
            $display("FAIL [T1 retire count] got=%0d want=12", retires);
        end

        // ---------------- T2 EBREAK ----------------
        run_case(S_EBREAK, 32'h18);
        chk("T2 mcause = BREAKPOINT(3)", dut.u_csr.mcause, 32'd3);
        chk("T2 mepc = faulting pc", dut.u_csr.mepc, 32'h0c);
        chk("T2 mtval = 0 (EBREAK)", dut.u_csr.mtval, 32'h0);
        chk("T2 trap_enter fired once", trap_fires, 1);
        count_retired(32'h10); chk("T2 younger never retired", rpc_count, 0);
        chk("T2 handler ran", dut.u_regfile.regs[10], 32'd3);
        chk_cause("T2 trace cause = 3", 3, 32'd3);

        // ---------------- T3 非法指令 ----------------
        probe_pc = 32'h10;
        run_case(S_ILLEGAL_INSTR, 32'h18);
        chk("T3 mcause = ILLEGAL(2)", dut.u_csr.mcause, 32'd2);
        chk("T3 mepc = faulting pc", dut.u_csr.mepc, 32'h0c);
        chk("T3 mtval = instruction word", dut.u_csr.mtval, 32'h12345678);
        chk("T3 younger decoded at least once", probe_hits > 0, 32'd1);
        count_retired(32'h10); chk("T3 younger never retired", rpc_count, 0);
        chk("T3 younger wrote nothing", dut.u_regfile.regs[3], 32'd0);
        chk_cause("T3 trace cause = 2", 3, 32'd2);

        // ---------------- T4 非法 CSR（未实现地址） ----------------
        probe_pc = 32'h10;
        run_case(S_CSR_UNIMPL, 32'h18);
        chk("T4 mcause = ILLEGAL(2)", dut.u_csr.mcause, 32'd2);
        chk("T4 mepc = faulting pc", dut.u_csr.mepc, 32'h0c);
        chk("T4 mtval = instruction word", dut.u_csr.mtval, 32'h000022f3);
        chk("T4 rd not written", dut.u_regfile.regs[5], 32'd0);
        chk("T4 younger decoded at least once", probe_hits > 0, 32'd1);
        count_retired(32'h10); chk("T4 younger never retired", rpc_count, 0);
        chk_cause("T4 trace cause = 2", 3, 32'd2);

        // ---------------- T5 非法 CSR（对只读 CSR 的写意图） ----------------
        run_case(S_CSR_RO_WRITE, 32'h18);
        chk("T5 mcause = ILLEGAL(2)", dut.u_csr.mcause, 32'd2);
        chk("T5 mepc = faulting pc", dut.u_csr.mepc, 32'h0c);
        chk("T5 mtval = instruction word", dut.u_csr.mtval, 32'h344092f3);
        chk("T5 rd not written", dut.u_regfile.regs[5], 32'd0);
        chk("T5 mip unchanged", dut.u_csr.mip, 32'h0);
        chk_cause("T5 trace cause = 2", 3, 32'd2);

        // ---------------- T6 非对齐 load ----------------
        run_case(S_LD_MISALIGN, 32'h18);
        chk("T6 mcause = LOAD_MISALIGNED(4)", dut.u_csr.mcause, 32'd4);
        chk("T6 mepc = faulting pc", dut.u_csr.mepc, 32'h0c);
        chk("T6 mtval = misaligned addr", dut.u_csr.mtval, 32'd1);
        chk("T6 no data request issued", d_req_count, 0);
        chk("T6 rd not written", dut.u_regfile.regs[5], 32'd0);
        chk_cause("T6 trace cause = 4", 3, 32'd4);

        // ---------------- T7 非对齐 store ----------------
        run_case(S_ST_MISALIGN, 32'h18);
        chk("T7 mcause = STORE_MISALIGNED(6)", dut.u_csr.mcause, 32'd6);
        chk("T7 mepc = faulting pc", dut.u_csr.mepc, 32'h0c);
        chk("T7 mtval = misaligned addr", dut.u_csr.mtval, 32'd2);
        chk("T7 no data request issued", d_req_count, 0);
        chk("T7 memory unchanged", dmem[1], 32'h0000ABCD);
        chk_cause("T7 trace cause = 6", 3, 32'd6);

        // ---------------- T8 访存故障 load ----------------
        run_case(S_LD_FAULT, 32'h18);
        chk("T8 mcause = LOAD_FAULT(5)", dut.u_csr.mcause, 32'd5);
        chk("T8 mepc = faulting pc", dut.u_csr.mepc, 32'h0c);
        chk("T8 mtval = access addr 8", dut.u_csr.mtval, 32'd8);
        chk("T8 exactly one data request", d_req_count, 1);
        chk("T8 rd not written", dut.u_regfile.regs[5], 32'd0);
        chk_cause("T8 trace cause = 5", 3, 32'd5);

        // ---------------- T9 访存故障 store ----------------
        run_case(S_ST_FAULT, 32'h18);
        chk("T9 mcause = STORE_FAULT(7)", dut.u_csr.mcause, 32'd7);
        chk("T9 mepc = faulting pc", dut.u_csr.mepc, 32'h0c);
        chk("T9 mtval = access addr 12", dut.u_csr.mtval, 32'd12);
        chk("T9 exactly one data request", d_req_count, 1);
        chk("T9 write attempted once", d_write_count, 1);
        chk("T9 memory unchanged", dmem[3], 32'd0);
        chk_cause("T9 trace cause = 7", 3, 32'd7);

        // ---------------- T10 最老 fault 优先 ----------------
        probe_pc = 32'h0c;
        run_case(S_OLDEST_WINS, 32'h18);
        chk("T10 exactly one trap", trap_fires, 1);
        chk("T10 cause = older load fault", dut.u_csr.mcause, 32'd5);
        chk("T10 mepc = older pc 8", dut.u_csr.mepc, 32'h08);
        chk("T10 mtval = older addr 8", dut.u_csr.mtval, 32'd8);
        chk("T10 younger illegal decoded", probe_hits > 0, 32'd1);
        count_retired(32'h0c); chk("T10 younger illegal not retired", rpc_count, 0);
        count_retired(32'h10); chk("T10 youngest never retired", rpc_count, 0);
        chk("T10 youngest wrote nothing", dut.u_regfile.regs[6], 32'd0);
        chk_cause("T10 trace cause = 5", 2, 32'd5);

        // ---------------- T11 更年轻 store 无架构效果 ----------------
        probe_pc = 32'h10;
        run_case(S_YOUNG_STORE, 32'h18);
        chk("T11 exactly one trap", trap_fires, 1);
        chk("T11 cause = older load fault", dut.u_csr.mcause, 32'd5);
        chk("T11 mepc = older pc 0x0c", dut.u_csr.mepc, 32'h0c);
        chk("T11 younger store decoded", probe_hits > 0, 32'd1);
        chk("T11 only the load issued a request", d_req_count, 1);
        chk("T11 no write was issued", d_write_count, 0);
        chk("T11 younger store did not mutate", dmem[1], 32'h0000ABCD);
        chk_cause("T11 trace cause = 5", 3, 32'd5);

        // ---------------- T12 陷阱状态恰好一次 + 处理器读到同一份 ----------------
        run_case(S_LD_FAULT, 32'h18);
        chk("T12 trap_enter fired exactly once", trap_fires, 1);
        chk("T12 handler read cause", dut.u_regfile.regs[10], 32'd5);
        chk("T12 handler read mepc", dut.u_regfile.regs[11], 32'h0c);
        chk("T12 handler read mtval", dut.u_regfile.regs[12], 32'd8);
        chk("T12 no mret in this scenario", mret_fires, 0);
        chk_cause("T12 trace cause = 5", 3, 32'd5);
        // 任何被标记为 trap 的退休事件都必须带非零 cause（trace 字段与 csr 状态一致）
        chk("T12 no trap with zero cause", trap_zero_cause, 0);

        // ---- T13（Issue #15 第 4 项）：backend_hold + redirect 的**整机联合契约** ----
        // 来源：PR #25 复评时指出"有效年轻 ID/EX + older redirect + stale-drain 的联合场景
        //       未在整机测试中出现（system TB 观测到 0 拍）"。
        // 实测（本 TB 全部 11 个场景累计）：backend_hold&redirect_valid 同拍 **2 拍**，
        //       其中持有效年轻 ID/EX **2 拍**，且 **2 拍**都同拍 flush_id_ex。
        // 契约：redirect 拍即使 backend_hold=1，年轻 ID/EX 也必须被冲刷（"保持老、冲刷年轻"）。
        chk("T13 联合场景 backend_hold&redirect 至少一次",
            (hold_redir_joint > 0) ? 32'd1 : 32'd0, 32'd1);
        chk("T13 联合场景持有效年轻 ID/EX 至少一次",
            (hold_redir_joint_idex > 0) ? 32'd1 : 32'd0, 32'd1);
        chk("T13 联合拍 flush_id_ex 必与 redirect 同拍（不得被 hold 吞掉）",
            (hold_redir_joint == hold_redir_joint_flush) ? 32'd1 : 32'd0, 32'd1);

        $display("==================================================");
        $display("  联合场景: backend_hold&redirect_valid = %0d 拍（其中有效年轻 ID/EX = %0d 拍，同拍 flush_id_ex = %0d 拍）",
                 hold_redir_joint, hold_redir_joint_idex, hold_redir_joint_flush);
        $display("  检查项: %0d", checks);
        if (errors == 0)
            $display("  ALL TESTS PASSED (0 errors)");
        else
            $display("  %0d FAILED", errors);
        $display("==================================================");
        if (errors != 0) $fatal(1, "trap tests failed");
        $finish;
    end

    initial begin
        #200000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
