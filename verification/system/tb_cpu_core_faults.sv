`timescale 1ns/1ps

// ============================================================================
//  cpu_core_stage1 —— 故障类同步异常（批 (b)：精确陷阱契约）
//
//  本文件在批 (a) 时的断言是"故障指令只抑制自身副作用、**更年轻指令照常退休**"
//  （非精确）。批 (b) 改为精确契约后，这些断言被**有意改写**为：
//    故障指令提交一次并进入陷阱；**更年轻指令绝不退休、绝无副作用**；
//    PC 重定向到 mtvec；mepc/mcause/mtval 正确。
//
//  场景（每个场景的处理器地址 0x100 故意不可取指 → CPU 重定向后停在那里，便于观测）：
//    FETCH_FAULT   : 0x08 的 JAL 取指出错（instruction access fault, cause 1）
//    ILLEGAL_STORE : 0x08 的保留 SW funct3（illegal instruction, cause 2）
//    LOAD_ERROR    : 0x08 的 LW 响应报错（load access fault, cause 5）
//    STORE_ERROR   : 0x08 的 SW 响应报错（store access fault, cause 7）
//
//  非对齐 / ECALL / EBREAK / 非法 CSR / 最老优先 / mret 往返见 tb_cpu_core_trap.sv。
// ============================================================================

module tb_cpu_core_faults;
    localparam integer FETCH_FAULT = 0;
    localparam integer ILLEGAL_STORE = 1;
    localparam integer LOAD_ERROR = 2;
    localparam integer STORE_ERROR = 3;
    localparam [31:0] HANDLER = 32'h100;      // 不可取指 → CPU 停在此处

    reg clk = 0;
    reg rst = 1;
    integer scenario = FETCH_FAULT;
    always #5 clk = ~clk;

    wire i_req_valid, i_req_ready, i_rsp_ready;
    wire [31:0] i_req_addr;
    reg i_rsp_valid = 0, i_rsp_error = 0;
    reg [31:0] i_rsp_data = 32'h00000013;
    wire d_req_valid, d_req_ready, d_req_write, d_rsp_ready;
    wire [31:0] d_req_addr, d_req_wdata, d_rsp_rdata;
    wire [3:0] d_req_wstrb;
    reg d_rsp_valid = 0, d_rsp_error = 0;
    reg [31:0] d_rsp_rdata_q = 0;
    wire trace_valid, trace_rd_we, trace_trap;
    wire [63:0] trace_order;
    wire [31:0] trace_pc, trace_instr, trace_rd_data;
    wire [31:0] trace_cause;
    wire [4:0] trace_rd;

    // 统一布局：0x00/0x04 为"设 mtvec 到不可取指处理器"的前导，
    //           0x08 出错指令，0x0c 更年轻指令（必须不退休）
    function automatic [31:0] rom(input [31:0] addr);
        begin
            rom = 32'h00000013;                                   // 默认 NOP
            case (addr)
                32'h00: rom = 32'h10000093;                       // addi  x1, x0, 0x100
                32'h04: rom = 32'h30509073;                       // csrrw x0, mtvec, x1
                32'h0c: rom = 32'h00300193;                       // addi  x3, x0, 3（更年轻）
                default: rom = 32'h00000013;
            endcase
            case (scenario)
                FETCH_FAULT:   if (addr == 32'h08) rom = 32'h010000ef; // JAL x1,+16（取指出错）
                ILLEGAL_STORE: if (addr == 32'h08) rom = 32'h00203023; // 保留 SW funct3
                LOAD_ERROR:    if (addr == 32'h08) rom = 32'h00802283; // lw x5, 8(x0)
                STORE_ERROR:   if (addr == 32'h08) rom = 32'h00202623; // sw x2, 12(x0)
            endcase
        end
    endfunction

    assign i_req_ready = (i_req_addr <= 32'h0c);
    always @(posedge clk) begin
        if (rst) begin
            i_rsp_valid <= 0;
            i_rsp_error <= 0;
            i_rsp_data <= 32'h00000013;
        end else begin
            i_rsp_valid <= i_req_valid && i_req_ready;
            i_rsp_error <= i_req_valid && i_req_ready &&
                           (scenario == FETCH_FAULT) && (i_req_addr == 32'h08);
            if (i_req_valid && i_req_ready)
                i_rsp_data <= rom(i_req_addr);
        end
    end

    reg [31:0] dmem [0:3];
    reg pending_rsp = 0;
    reg [2:0] rsp_delay = 0;
    reg [31:0] pending_addr = 0, pending_wdata = 0;
    reg [3:0] pending_wstrb = 0;
    reg pending_write = 0;
    integer d_req_count = 0, d_write_count = 0;
    assign d_req_ready = !pending_rsp;
    assign d_rsp_rdata = d_rsp_rdata_q;

    always @(posedge clk) begin
        if (rst) begin
            dmem[0] <= 32'h12345678;
            dmem[1] <= 0; dmem[2] <= 0; dmem[3] <= 0;
            pending_rsp <= 0; d_rsp_valid <= 0; d_rsp_error <= 0;
            rsp_delay <= 0; d_req_count <= 0; d_write_count <= 0;
            pending_addr <= 0; pending_wdata <= 0; pending_wstrb <= 0;
            pending_write <= 0; d_rsp_rdata_q <= 0;
        end else begin
            if (d_req_valid && d_req_ready) begin
                d_req_count <= d_req_count + 1;
                if (d_req_write) d_write_count <= d_write_count + 1;
                pending_rsp <= 1;
                rsp_delay <= 2;
                pending_addr <= d_req_addr;
                pending_write <= d_req_write;
                pending_wdata <= d_req_wdata;
                pending_wstrb <= d_req_wstrb;
            end
            if (pending_rsp && rsp_delay != 0)
                rsp_delay <= rsp_delay - 1'b1;
            if (pending_rsp && rsp_delay == 0 && !d_rsp_valid) begin
                d_rsp_valid <= 1;
                d_rsp_error <= (scenario == LOAD_ERROR || scenario == STORE_ERROR);
                d_rsp_rdata_q <= dmem[pending_addr[3:2]];
            end
            if (d_rsp_valid && d_rsp_ready) begin
                if (pending_write && !d_rsp_error) begin
                    if (pending_wstrb[0]) dmem[pending_addr[3:2]][7:0] <= pending_wdata[7:0];
                    if (pending_wstrb[1]) dmem[pending_addr[3:2]][15:8] <= pending_wdata[15:8];
                    if (pending_wstrb[2]) dmem[pending_addr[3:2]][23:16] <= pending_wdata[23:16];
                    if (pending_wstrb[3]) dmem[pending_addr[3:2]][31:24] <= pending_wdata[31:24];
                end
                d_rsp_valid <= 0;
                pending_rsp <= 0;
            end
        end
    end

    cpu_core_stage1 dut (
        .clk(clk), .rst(rst), .i_req_valid(i_req_valid), .i_req_ready(i_req_ready),
        .i_req_addr(i_req_addr), .i_rsp_valid(i_rsp_valid), .i_rsp_ready(i_rsp_ready),
        .i_rsp_data(i_rsp_data), .i_rsp_error(i_rsp_error), .d_req_valid(d_req_valid),
        .d_req_ready(d_req_ready), .d_req_addr(d_req_addr), .d_req_write(d_req_write),
        .d_req_wdata(d_req_wdata), .d_req_wstrb(d_req_wstrb),
        .d_rsp_valid(d_rsp_valid), .d_rsp_ready(d_rsp_ready), .d_rsp_rdata(d_rsp_rdata),
        .d_rsp_error(d_rsp_error), .trace_valid(trace_valid), .trace_order(trace_order),
        .trace_pc(trace_pc), .trace_instr(trace_instr), .trace_rd(trace_rd),
        .trace_rd_data(trace_rd_data), .trace_rd_we(trace_rd_we), .trace_trap(trace_trap),
        .trace_cause(trace_cause),
        .timer_irq_i(1'b0), .ext_irq_i(1'b0)   // 批 (c)：故障类测试不涉及中断
    );

    integer retired = 0, traps = 0, trap_writes = 0;
    reg [31:0] retired_pc [0:15];
    // 批 (b)：退休 trace 的 cause 字段（新增字段）必须与该场景的陷阱原因一致
    reg [31:0] trap_cause_seen = 32'hFFFFFFFF;
    always @(negedge clk) begin
        if (!rst && trace_valid) begin
            retired_pc[retired] = trace_pc;
            retired = retired + 1;
            if (trace_trap) begin
                traps = traps + 1;
                trap_cause_seen = trace_cause;
                if (trace_rd_we) trap_writes = trap_writes + 1;
            end
        end
    end

    // 更年轻指令是否**被取到并译码过**（证明"被冲刷"而非"根本没取到"）
    integer younger_decoded = 0;
    always @(posedge clk) begin
        if (!rst && dut.id_valid && (dut.id_pc === 32'h0c)) younger_decoded = younger_decoded + 1;
    end

    // 统计某 PC 的退休次数
    integer rpc_count, lp_i;
    task automatic count_retired(input [31:0] pc);
        begin
            rpc_count = 0;
            for (lp_i = 0; lp_i < retired; lp_i = lp_i + 1)
                if (retired_pc[lp_i] === pc) rpc_count = rpc_count + 1;
        end
    endtask

    task automatic reset_case(input integer which);
        begin
            @(negedge clk); rst = 1; scenario = which;
            repeat (3) @(posedge clk);
            @(negedge clk); rst = 0;
            retired = 0; traps = 0; trap_writes = 0; younger_decoded = 0;
            trap_cause_seen = 32'hFFFFFFFF;
            d_req_count = 0; d_write_count = 0;
            repeat (160) @(posedge clk);
        end
    endtask

    task automatic check_condition(input integer condition, input [8*120-1:0] message);
        begin
            if (!condition) $fatal(1, "FAIL: %0s", message);
            $display("PASS: %0s", message);
        end
    endtask

    initial begin
        // ---------------- 取指故障 → 精确陷阱 ----------------
        reset_case(FETCH_FAULT);
        check_condition(traps == 1 && trap_writes == 0,
                        "fetch fault retires once as trap without register write");
        count_retired(32'h08);
        check_condition(rpc_count == 1 && retired_pc[0] == 32'h00 &&
                        retired_pc[1] == 32'h04 && retired_pc[2] == 32'h08,
                        "faulted instruction retires once, in order, after the mtvec prologue");
        count_retired(32'h0c);
        check_condition(rpc_count == 0, "younger instruction never retires (precise trap)");
        check_condition(younger_decoded > 0, "younger instruction was fetched and decoded before the flush");
        check_condition(dut.u_csr.mcause == 32'd1, "cause = instruction access fault (1)");
        check_condition(dut.u_csr.mepc == 32'h08, "mepc = faulting pc");
        check_condition(dut.u_csr.mtval == 32'h08, "mtval = faulting fetch pc");
        check_condition(trap_cause_seen == 32'd1, "trace cause = instruction access fault (1)");
        check_condition(dut.pc == HANDLER, "pc redirected to mtvec handler");
        check_condition(d_req_count == 0, "fetch fault issues no data request");

        // ---------------- 非法指令（store 编码） → 精确陷阱 ----------------
        reset_case(ILLEGAL_STORE);
        check_condition(traps == 1 && trap_writes == 0,
                        "illegal store retires once as trap without register write");
        count_retired(32'h0c);
        check_condition(rpc_count == 0, "illegal: younger instruction never retires");
        check_condition(younger_decoded > 0, "illegal: younger instruction was decoded before the flush");
        check_condition(dut.u_csr.mcause == 32'd2, "illegal: cause = illegal instruction (2)");
        check_condition(dut.u_csr.mepc == 32'h08, "illegal: mepc = faulting pc");
        check_condition(dut.u_csr.mtval == 32'h00203023, "illegal: mtval = instruction word");
        check_condition(trap_cause_seen == 32'd2, "illegal: trace cause = illegal instruction (2)");
        check_condition(dut.pc == HANDLER, "illegal: pc redirected to mtvec handler");
        check_condition(d_req_count == 0 && dmem[0] == 32'h12345678,
                        "illegal store causes no data request or memory mutation");

        // ---------------- load 访问故障 → 精确陷阱 ----------------
        reset_case(LOAD_ERROR);
        check_condition(traps == 1 && trap_writes == 0,
                        "load access fault is reported exactly once without writeback");
        count_retired(32'h0c);
        check_condition(rpc_count == 0, "load fault: younger instruction never retires");
        check_condition(dut.u_csr.mcause == 32'd5, "load fault: cause = load access fault (5)");
        check_condition(dut.u_csr.mepc == 32'h08, "load fault: mepc = faulting pc");
        check_condition(dut.u_csr.mtval == 32'd8, "load fault: mtval = access address");
        check_condition(trap_cause_seen == 32'd5, "load fault: trace cause = load access fault (5)");
        check_condition(dut.pc == HANDLER, "load fault: pc redirected to mtvec handler");
        check_condition(d_req_count == 1 && dut.u_regfile.regs[5] == 0,
                        "failed load does not write bad data");

        // ---------------- store 访问故障 → 精确陷阱 ----------------
        reset_case(STORE_ERROR);
        check_condition(traps == 1 && trap_writes == 0,
                        "store access fault is reported exactly once");
        count_retired(32'h0c);
        check_condition(rpc_count == 0, "store fault: younger instruction never retires");
        check_condition(dut.u_csr.mcause == 32'd7, "store fault: cause = store access fault (7)");
        check_condition(dut.u_csr.mepc == 32'h08, "store fault: mepc = faulting pc");
        check_condition(dut.u_csr.mtval == 32'd12, "store fault: mtval = access address");
        check_condition(trap_cause_seen == 32'd7, "store fault: trace cause = store access fault (7)");
        check_condition(dut.pc == HANDLER, "store fault: pc redirected to mtvec handler");
        check_condition(d_req_count == 1 && d_write_count == 1 && dmem[0] == 32'h12345678,
                        "errored store response leaves memory unchanged");

        $display("PASS tb_cpu_core_faults: 4 fault scenarios take precise traps (redirect to mtvec, younger killed)");
        $finish;
    end
endmodule
