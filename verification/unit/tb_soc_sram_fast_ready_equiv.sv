`timescale 1ns/1ps
// ============================================================================
// S3 (feat/struct-fastaccept) 等价性自检
// ----------------------------------------------------------------------------
// cpu_mem_subsystem 内 D 侧 cacheable 快判据 `d_cacheable_fast` 必须与
// addr_decode 的 cacheable(= sel_sram) 语义逐地址相同。本 tb 复刻同一窗口
// 常量与掩码比较（SRAM_BASE / SRAM_SIZE 与 RTL 参数默认值一致），并在
// SRAM/ROM/MMIO 窗口边界与随机地址上逐点比对。
// ============================================================================
module tb_soc_sram_fast_ready_equiv;
    // 与被测 RTL 相同的窗口常量（cpu_mem_subsystem 参数默认值）
    localparam [31:0] SRAM_BASE = 32'h8000_0000;
    localparam [31:0] SRAM_SIZE = 32'h0001_0000;
    localparam [31:0] SRAM_MASK = ~(SRAM_SIZE - 32'd1);

    reg  [31:0] addr;
    wire        ref_cacheable;
    wire        sel_rom, sel_sram, sel_uart, sel_gpio, sel_timer;
    wire        sel_accel_ctrl, sel_accel_buf, sel_none;
    wire        ref_read_only, q_cacheable, q_read_only, q_sel_rom;

    addr_decode u_ref (
        .addr(addr), .query_addr(32'd0),
        .sel_rom(sel_rom), .sel_sram(sel_sram), .sel_uart(sel_uart),
        .sel_gpio(sel_gpio), .sel_timer(sel_timer),
        .sel_accel_ctrl(sel_accel_ctrl), .sel_accel_buf(sel_accel_buf),
        .sel_none(sel_none),
        .cacheable(ref_cacheable), .read_only(ref_read_only),
        .query_cacheable(q_cacheable), .query_read_only(q_read_only),
        .query_sel_rom(q_sel_rom)
    );

    wire fast_cacheable = ((addr & SRAM_MASK) == SRAM_BASE);

    integer i;
    integer errors;
    integer checks;

    task automatic check_addr(input [31:0] a);
        begin
            addr = a; #1;
            checks = checks + 1;
            if (fast_cacheable !== ref_cacheable) begin
                errors = errors + 1;
                if (errors < 20)
                    $display("FAIL addr=%08h fast=%b ref=%b", a, fast_cacheable, ref_cacheable);
            end
        end
    endtask

    initial begin
        errors = 0; checks = 0; addr = 32'd0;
        // 1) SRAM 窗口边界扫描（含 0x8000_0000 ± 16 KiB）
        for (i = -16384; i <= 16384; i = i + 4) check_addr(32'h8000_0000 + i);
        // 2) ROM / MMIO 窗口边界扫描
        for (i = -16384; i <= 16384; i = i + 4) check_addr(32'h0000_0000 + i);
        for (i = -16384; i <= 16384; i = i + 4) check_addr(32'h1000_0000 + i);
        for (i = -16384; i <= 16384; i = i + 4) check_addr(32'h4000_0000 + i);
        // 3) 随机地址
        for (i = 0; i < 20000; i = i + 1) check_addr($random);
        if (errors == 0) begin
            $display("S3 FAST-READY EQUIV: PASS (%0d addresses)", checks);
            $finish;
        end else begin
            $display("S3 FAST-READY EQUIV: FAIL (%0d/%0d mismatches)", errors, checks);
            $fatal(1);
        end
    end
endmodule
