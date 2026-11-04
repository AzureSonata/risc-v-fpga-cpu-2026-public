// ============================================================================
//  csr_file 独立定向测试
//
//  被测：rtl/core/csr_file.sv（CSR 状态 + 精确 machine trap 状态迁移 + 中断判定）
//  依据：TECHNICAL_BASELINE.md §「已冻结主方案」CSR 行、§「分支、Cache 与异常接入」
//
//  断言：
//    T1  复位值：mstatus=0x1800（MPP=11）、其余 CSR=0、mip 反映中断输入
//    T2  CSRRW 写 mstatus.MIE 可读回
//    T3  CSRRS 置位 / CSRRC 清零（mie）
//    T4  mtvec 为 direct-only：写入 MODE=01 被 WARL 强制为 00
//    T5  mepc 写入按 4 字节对齐（低位被清零）
//    T6  未实现 CSR 一律 csr_implemented=0（不得静默返回 0）
//    T7  mip 只读（csr_writable=0），且 MTIP/MEIP 直接反映 timer_irq/ext_irq
//    T8  trap_enter：mepc/mcause/mtval 记录正确；MIE→MPIE、MIE=0、MPP=11
//    T9  mret：MIE←MPIE、MPIE=1
//    T10 中断判定：mstatus.MIE 门控；mie 位门控；外部中断(11) 优先于定时器(7)
//    T11 trap_enter 同拍的 CSR 写被忽略（陷阱优先）
// ============================================================================
`timescale 1ns/1ps
`include "defines.sv"

module tb_csr;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    reg  [11:0] csr_addr = 12'h0;
    wire [31:0] csr_rdata;
    wire        csr_implemented, csr_writable;

    // 地址合法性查询端口（批 (b)：供流水线在 EX/MEM 边界提前判定非法 CSR）
    reg  [11:0] csr_chk_addr = 12'h0;
    wire        csr_chk_implemented, csr_chk_writable;

    reg         csr_we = 1'b0;
    reg  [1:0]  csr_op = 2'b00;
    reg  [31:0] csr_wdata = 32'h0;

    reg         trap_enter = 1'b0;
    reg  [31:0] trap_pc = 32'h0, trap_cause = 32'h0, trap_tval = 32'h0;
    reg         mret = 1'b0;

    // 中断输入：**不要**用声明初始化（reg x = 1'b0）。
    // Icarus 10.2 下声明初始化可能与 always @(*) 的首次求值顺序不定，
    // 使组合输出停在 x 且此后无"变化事件"触发重算；用 initial 块显式赋值
    // 会产生确定的 x->0 变化事件。（实测踩坑，见 ICARUS_TOOL_CONSTRAINTS.md）
    reg         timer_irq, ext_irq;
    initial begin
        timer_irq = 1'b0;
        ext_irq   = 1'b0;
    end
    wire [31:0] mip, mie;
    wire        irq_pending;
    wire [31:0] irq_cause;
    wire [31:0] mstatus, mtvec, mepc, mcause, mtval;

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

    csr_file u_csr (
        .clk(clk), .rst(rst),
        .retire_count(2'd0),
        .csr_addr(csr_addr), .csr_rdata(csr_rdata),
        .csr_implemented(csr_implemented), .csr_writable(csr_writable),
        .csr_chk_addr(csr_chk_addr),
        .csr_chk_implemented(csr_chk_implemented), .csr_chk_writable(csr_chk_writable),
        .csr_we(csr_we), .csr_op(csr_op), .csr_wdata(csr_wdata),
        .trap_enter(trap_enter), .trap_pc(trap_pc),
        .trap_cause(trap_cause), .trap_tval(trap_tval), .mret(mret),
        .timer_irq(timer_irq), .ext_irq(ext_irq),
        .mip(mip), .mie(mie), .irq_pending(irq_pending), .irq_cause(irq_cause),
        .mstatus(mstatus), .mtvec(mtvec), .mepc(mepc),
        .mcause(mcause), .mtval(mtval)
    );

    // 一次 CSR 写（在 posedge 采样，脉冲一拍）
    task csr_write(input [11:0] a, input [1:0] op, input [31:0] d);
        begin
            @(negedge clk);
            csr_addr = a; csr_op = op; csr_wdata = d; csr_we = 1'b1;
            @(posedge clk); #1;
            csr_we = 1'b0;
            @(negedge clk);
        end
    endtask

    // 组合读：设地址后等一拍让组合逻辑稳定
    task csr_read(input [11:0] a, output [31:0] d, output impl, output wr);
        begin
            csr_addr = a;
            #1;
            d = csr_rdata; impl = csr_implemented; wr = csr_writable;
        end
    endtask

    reg [31:0] rd_v;
    reg [31:0] rd_before;
    reg        rd_impl, rd_wr;
    integer    i;
    integer    mism;
    reg [11:0] bad_addrs [0:4];

    initial begin
        $display("==================================================");
        $display("  csr_file 独立定向测试");
        $display("==================================================");

        repeat (3) @(posedge clk);

        // ---------------- T1 复位值 ----------------
        csr_read(12'h300, rd_v, rd_impl, rd_wr);
        chk("T1 mstatus reset (MPP=11)", rd_v, 32'h0000_1800);
        csr_read(12'h305, rd_v, rd_impl, rd_wr);
        chk("T1 mtvec reset", rd_v, 32'h0);
        csr_read(12'h341, rd_v, rd_impl, rd_wr);
        chk("T1 mepc reset", rd_v, 32'h0);
        csr_read(12'h342, rd_v, rd_impl, rd_wr);
        chk("T1 mcause reset", rd_v, 32'h0);
        csr_read(12'h343, rd_v, rd_impl, rd_wr);
        chk("T1 mtval reset", rd_v, 32'h0);
        csr_read(12'h304, rd_v, rd_impl, rd_wr);
        chk("T1 mie reset", rd_v, 32'h0);
        // 通过 CSR 读端口取 mip（csr_read 内含 #1，保证组合逻辑已稳定；
        // 直接读 wire 在复位前相位可能落在组合块求值之前）
        csr_read(12'h344, rd_v, rd_impl, rd_wr);
        chk("T1 mip reset (no irq)", rd_v, 32'h0);

        rst = 1'b0;
        repeat (2) @(posedge clk);

        // ---------------- T2 CSRRW 写 mstatus.MIE ----------------
        csr_write(12'h300, 2'b00, 32'h0000_0008);
        csr_read(12'h300, rd_v, rd_impl, rd_wr);
        chk("T2 CSRRW mstatus.MIE set", rd_v & 32'h8, 32'h8);
        chk("T2b MPP still 11 after write", rd_v & 32'h1800, 32'h1800);

        // ---------------- T3 CSRRS / CSRRC（mie） ----------------
        csr_write(12'h304, 2'b01, 32'h0000_0080);   // set MTIE(7)
        csr_read(12'h304, rd_v, rd_impl, rd_wr);
        chk("T3 CSRRS set MTIE", rd_v, 32'h0000_0080);
        csr_write(12'h304, 2'b10, 32'h0000_0080);   // clear MTIE
        csr_read(12'h304, rd_v, rd_impl, rd_wr);
        chk("T3b CSRRC clear MTIE", rd_v, 32'h0);

        // ---------------- T4 mtvec direct-only（WARL） ----------------
        csr_write(12'h305, 2'b00, 32'h0000_1005);   // MODE=01（vectored）请求
        csr_read(12'h305, rd_v, rd_impl, rd_wr);
        chk("T4 mtvec WARL forces direct(00)", rd_v, 32'h0000_1004);

        // ---------------- T5 mepc 4 字节对齐 ----------------
        csr_write(12'h341, 2'b00, 32'h0000_1006);
        csr_read(12'h341, rd_v, rd_impl, rd_wr);
        chk("T5 mepc aligned to 4", rd_v, 32'h0000_1004);

        // ---------------- T6 未实现 CSR 必须报非法 ----------------
        bad_addrs[0] = 12'h000;   // 未定义
        bad_addrs[1] = 12'hC00;   // cycle（只读计数器，未实现）
        bad_addrs[2] = 12'h301;   // misa（未实现）
        bad_addrs[3] = 12'hF11;   // mvendorid（未实现）
        bad_addrs[4] = 12'h340;   // mscratch（未在冻结清单内）
        for (i = 0; i < 5; i = i + 1) begin
            csr_read(bad_addrs[i], rd_v, rd_impl, rd_wr);
            chk("T6 unimplemented CSR -> illegal", {31'b0, rd_impl}, 32'd0);
        end

        // ---------------- T7 mip 只读 + 反映中断输入 ----------------
        csr_read(12'h344, rd_v, rd_impl, rd_wr);
        chk("T7 mip implemented", {31'b0, rd_impl}, 32'd1);
        chk("T7b mip read-only", {31'b0, rd_wr}, 32'd0);
        timer_irq = 1'b1; ext_irq = 1'b1;
        #1;
        csr_read(12'h344, rd_v, rd_impl, rd_wr);
        chk("T7c mip reflects MTIP|MEIP", rd_v, 32'h0000_0880);
        timer_irq = 1'b0; ext_irq = 1'b0;
        #1;

        // ---------------- T10 中断判定 ----------------
        // 此时 mstatus.MIE=1（T2 设置），mie=0 → 不应 pending
        chk("T10 no irq when mie=0", {31'b0, irq_pending}, 32'd0);

        csr_write(12'h304, 2'b01, 32'h0000_0080);   // MTIE=1
        timer_irq = 1'b1;
        #1;
        chk("T10b MTI pending when clock-enabled", {31'b0, irq_pending}, 32'd1);
        chk("T10c MTI cause = 0x80000007", irq_cause, 32'h8000_0007);

        ext_irq = 1'b1;
        csr_write(12'h304, 2'b01, 32'h0000_0800);   // MEIE=1
        #1;
        chk("T10d MEI cause = 0x8000000B", irq_cause, 32'h8000_000B);

        csr_write(12'h300, 2'b10, 32'h0000_0008);   // 清 mstatus.MIE
        #1;
        chk("T10e gated by mstatus.MIE", {31'b0, irq_pending}, 32'd0);
        csr_write(12'h300, 2'b01, 32'h0000_0008);   // 恢复 MIE=1
        #1;
        timer_irq = 1'b0; ext_irq = 1'b0;
        #1;

        // ---------------- T8 精确陷阱进入 ----------------
        // 当前：mstatus.MIE=1, MPIE=0
        @(negedge clk);
        trap_pc = 32'h0000_2044; trap_cause = 32'h0000_0002;   // illegal instruction
        trap_tval = 32'hDEAD_BEEF; trap_enter = 1'b1;
        @(posedge clk); #1;
        trap_enter = 1'b0;
        repeat (1) @(posedge clk);
        chk("T8 mepc = trap_pc", mepc, 32'h0000_2044);
        chk("T8b mcause = cause", mcause, 32'h0000_0002);
        chk("T8c mtval = tval", mtval, 32'hDEAD_BEEF);
        chk("T8d MIE cleared on trap", mstatus & 32'h8, 32'h0);
        chk("T8e MPIE = old MIE(1)", mstatus & 32'h80, 32'h80);
        chk("T8f MPP = 11", mstatus & 32'h1800, 32'h1800);

        // ---------------- T11 trap_enter 同拍的 CSR 写被忽略 ----------------
        // 先把 mstatus.MIE 恢复为 1：T8 的陷阱已把 MIE 清 0，若此处不恢复，
        // 本陷阱会把 MPIE 也写成 0，随后 mret 得到 MIE=0 —— 那样 T9 就无法
        // 真正验证"MIE ← MPIE"这条语义（曾在首轮误判为 RTL 缺陷）。
        csr_write(12'h300, 2'b01, 32'h0000_0008);
        @(negedge clk);
        csr_addr = 12'h341; csr_op = 2'b00; csr_wdata = 32'h0000_9990;
        csr_we = 1'b1;
        trap_pc = 32'h0000_3000; trap_cause = 32'h0000_000B; trap_tval = 32'h0;
        trap_enter = 1'b1;
        @(posedge clk); #1;
        csr_we = 1'b0; trap_enter = 1'b0;
        repeat (1) @(posedge clk);
        chk("T11 trap wins over CSR write (mepc)", mepc, 32'h0000_3000);
        chk("T11b mcause = ECALL(11)", mcause, 32'h0000_000B);

        // ---------------- T9 mret ----------------
        @(negedge clk);
        mret = 1'b1;
        @(posedge clk); #1;
        mret = 1'b0;
        repeat (1) @(posedge clk);
        chk("T9 mret MIE <- MPIE(1)", mstatus & 32'h8, 32'h8);
        chk("T9b MPIE set to 1", mstatus & 32'h80, 32'h80);
        chk("T9c mepc unchanged by mret", mepc, 32'h0000_3000);

        // ---------------- T12 查询端口与读端口的译码一致性（穷尽 4096 地址） ----------------
        // 两个端口由**同一个函数**译码，一致性由构造保证；本用例守的是**装配**：
        // 地址绑定正确、无位序错接，且查询端口是纯组合（不扰动状态）。
        csr_read(12'h300, rd_before, rd_impl, rd_wr);
        // Icarus 坑（见 ICARUS_TOOL_CONSTRAINTS.md）：声明初始化不产生"变化事件"，
        // 组合 always 块可能停在 x；先做一次确定的赋值 + #1 触发求值。
        csr_chk_addr = 12'h7FF;
        #1;
        mism = 0;
        for (i = 0; i < 4096; i = i + 1) begin
            csr_addr = i[11:0];
            csr_chk_addr = i[11:0];
            #1;
            if (csr_implemented !== csr_chk_implemented ||
                csr_writable    !== csr_chk_writable) begin
                mism = mism + 1;
                if (mism <= 3)
                    $display("FAIL T12 mismatch @%03h: read={%b,%b} chk={%b,%b}",
                             i[11:0], csr_implemented, csr_writable,
                             csr_chk_implemented, csr_chk_writable);
            end
        end
        chk("T12 chk-port decode == read-port", mism, 32'd0);
        csr_read(12'h300, rd_v, rd_impl, rd_wr);
        chk("T12b state untouched by queries", rd_v, rd_before);

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
