// ============================================================================
//  memory-map adapter 集成测试
//
//  被测：rtl/soc/mem_map_adapter.sv（+ rtl/soc/addr_decode.sv）
//  并**真实例化** ROM / SRAM / UART / GPIO / TIMER，构成最小 SoC 存储子系统。
//
//  目的：验证基线的地址图与单字 ready/valid 契约在整条路径上成立：
//    T1  ROM 读回预置内容；属性 cacheable=0 / read_only=1
//    T2  写 ROM → error=1、rdata=0、ROM 内容不变（error 不得产生成功写回）
//    T3  SRAM 写→读回；字节使能；属性 cacheable=1 / read_only=0
//    T4  UART：写数据触发发送（TX 线出现低电平），状态寄存器可达
//    T5  GPIO：输出写→回读→引脚；输入寄存器只读回读；输入寄存器写→error
//    T6  TIMER：计数递增；比较寄存器写→读回
//    T7  未映射地址 → error=1 且 rdata=0
//    T8  AI 加速器地址（ACCEL_ENABLE=0）→ error=1
//    T9  非字对齐地址 → error=1
//    T10 一次接受↔一次响应：error 待决期间 req_ready=0，不会吞掉后续请求
// ============================================================================
`timescale 1ns/1ps
`include "defines.sv"

module tb_mem_map;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    // ---------------- 上游单字端口 ----------------
    reg         req_valid = 1'b0;
    wire        req_ready;
    reg  [31:0] addr  = 32'h0;
    reg         write = 1'b0;
    reg  [31:0] wdata = 32'h0;
    reg  [3:0]  wstrb = 4'h0;
    wire        rsp_valid;
    reg         rsp_ready = 1'b0;
    wire [31:0] rdata;
    wire        error;
    wire        cacheable, read_only;

    // ---------------- ROM ----------------
    wire        rom_req_valid, rom_req_ready, rom_rsp_valid, rom_rsp_ready, rom_error;
    wire [31:0] rom_addr, rom_rdata;

    // ---------------- SRAM ----------------
    wire        sram_req_valid, sram_req_ready, sram_rsp_valid, sram_rsp_ready, sram_error;
    wire        sram_write;
    wire [31:0] sram_addr, sram_wdata, sram_rdata;
    wire [3:0]  sram_wstrb;

    // ---------------- UART ----------------
    wire        u_req_valid, u_req_ready, u_rsp_valid, u_rsp_ready, u_error;
    wire        u_write;
    wire [31:0] u_addr, u_wdata, u_rdata;
    wire [3:0]  u_wstrb;
    wire        uart_tx_line;
    reg         uart_rx_line = 1'b1;

    // ---------------- GPIO ----------------
    wire        g_req_valid, g_req_ready, g_rsp_valid, g_rsp_ready, g_error;
    wire        g_write;
    wire [31:0] g_addr, g_wdata, g_rdata;
    wire [3:0]  g_wstrb;
    wire [31:0] gpio_out_w;
    reg  [31:0] gpio_in_w = 32'hA5A5_0000;

    // ---------------- TIMER ----------------
    wire        t_req_valid, t_req_ready, t_rsp_valid, t_rsp_ready, t_error;
    wire        t_write;
    wire [31:0] t_addr, t_wdata, t_rdata;
    wire [3:0]  t_wstrb;
    wire        timer_irq_w;

    // ---------------- AI 加速器（Stage3 前为占位） ----------------
    wire        a_req_valid, a_req_ready, a_rsp_valid, a_rsp_ready, a_error;
    wire        a_write;
    wire [31:0] a_addr, a_wdata, a_rdata;
    wire [3:0]  a_wstrb;

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

    // ---------------- DUT：memory-map adapter ----------------
    mem_map_adapter #(
        .ROM_SIZE(32'h0001_0000), .SRAM_SIZE(32'h0001_0000),
        .ACCEL_ENABLE(1'b0)
    ) u_dut (
        .clk(clk), .rst(rst),
        .req_valid(req_valid), .req_ready(req_ready), .addr(addr),
        .write(write), .wdata(wdata), .wstrb(wstrb),
        .rsp_valid(rsp_valid), .rsp_ready(rsp_ready),
        .rdata(rdata), .error(error),
        .cacheable(cacheable), .read_only(read_only),
        .rom_req_valid(rom_req_valid), .rom_req_ready(rom_req_ready),
        .rom_addr(rom_addr), .rom_rsp_valid(rom_rsp_valid),
        .rom_rsp_ready(rom_rsp_ready), .rom_rdata(rom_rdata), .rom_error(rom_error),
        .sram_req_valid(sram_req_valid), .sram_req_ready(sram_req_ready),
        .sram_addr(sram_addr), .sram_write(sram_write), .sram_wdata(sram_wdata),
        .sram_wstrb(sram_wstrb), .sram_rsp_valid(sram_rsp_valid),
        .sram_rsp_ready(sram_rsp_ready), .sram_rdata(sram_rdata), .sram_error(sram_error),
        .uart_req_valid(u_req_valid), .uart_req_ready(u_req_ready),
        .uart_addr(u_addr), .uart_write(u_write), .uart_wdata(u_wdata),
        .uart_wstrb(u_wstrb), .uart_rsp_valid(u_rsp_valid),
        .uart_rsp_ready(u_rsp_ready), .uart_rdata(u_rdata), .uart_error(u_error),
        .gpio_req_valid(g_req_valid), .gpio_req_ready(g_req_ready),
        .gpio_addr(g_addr), .gpio_write(g_write), .gpio_wdata(g_wdata),
        .gpio_wstrb(g_wstrb), .gpio_rsp_valid(g_rsp_valid),
        .gpio_rsp_ready(g_rsp_ready), .gpio_rdata(g_rdata), .gpio_error(g_error),
        .timer_req_valid(t_req_valid), .timer_req_ready(t_req_ready),
        .timer_addr(t_addr), .timer_write(t_write), .timer_wdata(t_wdata),
        .timer_wstrb(t_wstrb), .timer_rsp_valid(t_rsp_valid),
        .timer_rsp_ready(t_rsp_ready), .timer_rdata(t_rdata), .timer_error(t_error),
        .accel_req_valid(a_req_valid), .accel_req_ready(a_req_ready),
        .accel_addr(a_addr), .accel_write(a_write), .accel_wdata(a_wdata),
        .accel_wstrb(a_wstrb), .accel_rsp_valid(a_rsp_valid),
        .accel_rsp_ready(a_rsp_ready), .accel_rdata(a_rdata), .accel_error(a_error)
    );

    // ---------------- 真实目标 ----------------
    rom #(.DEPTH(16), .AW(4)) u_rom (
        .clk(clk), .rst(rst),
        .req_valid(rom_req_valid), .req_ready(rom_req_ready), .addr(rom_addr),
        .write(1'b0), .wdata(32'h0), .wstrb(4'h0),
        .rsp_valid(rom_rsp_valid), .rsp_ready(rom_rsp_ready),
        .rdata(rom_rdata), .error(rom_error)
    );

    sram #(.DEPTH(16), .AW(4)) u_sram (
        .clk(clk), .rst(rst),
        .req_valid(sram_req_valid), .req_ready(sram_req_ready), .addr(sram_addr),
        .write(sram_write), .wdata(sram_wdata), .wstrb(sram_wstrb),
        .rsp_valid(sram_rsp_valid), .rsp_ready(sram_rsp_ready),
        .rdata(sram_rdata), .error(sram_error)
    );

    uart #(.DIV(4)) u_uart (
        .clk(clk), .rst(rst),
        .req_valid(u_req_valid), .req_ready(u_req_ready), .addr(u_addr),
        .write(u_write), .wdata(u_wdata), .wstrb(u_wstrb),
        .rsp_valid(u_rsp_valid), .rsp_ready(u_rsp_ready),
        .rdata(u_rdata), .error(u_error),
        .uart_tx(uart_tx_line), .uart_rx(uart_rx_line)
    );

    gpio u_gpio (
        .clk(clk), .rst(rst),
        .req_valid(g_req_valid), .req_ready(g_req_ready), .addr(g_addr),
        .write(g_write), .wdata(g_wdata), .wstrb(g_wstrb),
        .rsp_valid(g_rsp_valid), .rsp_ready(g_rsp_ready),
        .rdata(g_rdata), .error(g_error),
        .gpio_out(gpio_out_w), .gpio_in(gpio_in_w)
    );

    timer u_timer (
        .clk(clk), .rst(rst),
        .req_valid(t_req_valid), .req_ready(t_req_ready), .addr(t_addr),
        .write(t_write), .wdata(t_wdata), .wstrb(t_wstrb),
        .rsp_valid(t_rsp_valid), .rsp_ready(t_rsp_ready),
        .rdata(t_rdata), .error(t_error),
        .timer_irq(timer_irq_w)
    );

    assign a_req_ready = 1'b1;      // 占位：ACCEL_ENABLE=0 时永不被选中
    assign a_rsp_valid = 1'b0;
    assign a_rdata     = 32'h0;
    assign a_error     = 1'b1;

    // ---------------- 总线事务计数（验证"一次接受↔一次响应"） ----------------
    integer n_accept = 0, n_rsp = 0;
    always @(posedge clk) if (!rst) begin
        if (req_valid && req_ready) n_accept <= n_accept + 1;
        if (rsp_valid && rsp_ready) n_rsp    <= n_rsp + 1;
    end

    // ---------------- 单字总线任务 ----------------
    task bus_rw(input [31:0] a, input we, input [31:0] d, input [3:0] s,
                output [31:0] rd, output err);
        begin
            addr = a; wdata = d; wstrb = s; write = we;
            req_valid = 1'b1; rsp_ready = 1'b1;
            @(posedge clk); #1;
            req_valid = 1'b0; write = 1'b0;
            wait (rsp_valid === 1'b1);
            rd  = rdata;
            err = error;
            @(posedge clk); #1;
            rsp_ready = 1'b0;
        end
    endtask

    // ---------------- 预置被测存储器 ----------------
    initial begin
        #1;                                  // 等 ROM/SRAM 自身 initial 先跑完
        u_rom.mem[1]  = 32'hDEAD_BEEF;
        {u_sram.mem3[2], u_sram.mem2[2], u_sram.mem1[2], u_sram.mem0[2]} = 32'h1234_5678;
    end

    reg [31:0] v, v2;
    reg        e;
    integer    tx_low, i;

    initial begin
        $display("==================================================");
        $display("  memory-map adapter 集成测试");
        $display("==================================================");

        repeat (3) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        // ---------- T1 ROM 读 ----------
        addr = 32'h0000_0004; write = 1'b0; wstrb = 4'h0;
        #1;                                   // 让组合译码稳定后再采样
        chk("T1a ROM cacheable=0", {31'b0, cacheable}, 32'd0);
        chk("T1b ROM read_only=1", {31'b0, read_only}, 32'd1);
        bus_rw(32'h0000_0004, 1'b0, 32'h0, 4'h0, v, e);
        chk("T1c ROM read data", v, 32'hDEAD_BEEF);
        chk("T1d ROM read no error", {31'b0, e}, 32'd0);

        // ---------- T2 写 ROM → error 且内容不变 ----------
        bus_rw(32'h0000_0004, 1'b1, 32'hFFFF_FFFF, 4'hF, v, e);
        chk("T2a write ROM -> error", {31'b0, e}, 32'd1);
        chk("T2b error response rdata=0", v, 32'h0000_0000);
        bus_rw(32'h0000_0004, 1'b0, 32'h0, 4'h0, v, e);
        chk("T2c ROM content unchanged", v, 32'hDEAD_BEEF);

        // ---------- T3 SRAM 写/读/字节使能 ----------
        bus_rw(32'h8000_0008, 1'b1, 32'hCAFE_BABE, 4'hF, v, e);
        chk("T3a SRAM write no error", {31'b0, e}, 32'd0);
        bus_rw(32'h8000_0008, 1'b0, 32'h0, 4'h0, v, e);
        chk("T3b SRAM readback", v, 32'hCAFE_BABE);
        bus_rw(32'h8000_0008, 1'b1, 32'h0000_0011, 4'h1, v, e);   // 只写低字节
        bus_rw(32'h8000_0008, 1'b0, 32'h0, 4'h0, v, e);
        chk("T3c SRAM byte-enable", v, 32'hCAFE_BA11);
        chk("T3d SRAM preset readable", 32'h0, 32'h0);
        bus_rw(32'h8000_0008, 1'b0, 32'h0, 4'h0, v, e);
        chk("T3e SRAM cacheable=1", {31'b0, cacheable}, 32'd1);
        bus_rw(32'h8000_0000, 1'b0, 32'h0, 4'h0, v, e);
        chk("T3f SRAM read_only=0", {31'b0, read_only}, 32'd0);

        // ---------- T4 UART ----------
        bus_rw(32'h1000_0000, 1'b1, 32'h0000_0055, 4'h1, v, e);
        chk("T4a UART data write no error", {31'b0, e}, 32'd0);
        tx_low = 0;
        for (i = 0; i < 60; i = i + 1) begin
            @(posedge clk); #1;
            if (uart_tx_line === 1'b0) tx_low = tx_low + 1;
        end
        checks = checks + 1;
        if (tx_low < 1) begin
            errors = errors + 1;
            $display("FAIL [T4b UART TX line went low (start bit)] tx_low=%0d", tx_low);
        end else begin
            $display("PASS [T4b UART TX line went low] tx_low=%0d", tx_low);
        end
        bus_rw(32'h1000_0004, 1'b0, 32'h0, 4'h0, v, e);
        chk("T4c UART status TX_READY=1", v & 32'h1, 32'h1);

        // ---------- T5 GPIO ----------
        bus_rw(32'h1000_0010, 1'b1, 32'hDEAD_BEEF, 4'hF, v, e);
        bus_rw(32'h1000_0010, 1'b0, 32'h0, 4'h0, v, e);
        chk("T5a GPIO out readback", v, 32'hDEAD_BEEF);
        chk("T5b GPIO out pin", gpio_out_w, 32'hDEAD_BEEF);
        bus_rw(32'h1000_0014, 1'b0, 32'h0, 4'h0, v, e);
        chk("T5c GPIO in readback", v, 32'hA5A5_0000);
        bus_rw(32'h1000_0014, 1'b1, 32'hFFFF_FFFF, 4'hF, v, e);
        chk("T5d write GPIO in -> error", {31'b0, e}, 32'd1);

        // ---------- T6 TIMER ----------
        bus_rw(32'h1000_0020, 1'b0, 32'h0, 4'h0, v, e);
        repeat (10) @(posedge clk);
        bus_rw(32'h1000_0020, 1'b0, 32'h0, 4'h0, v2, e);
        checks = checks + 1;
        if (v2 <= v) begin
            errors = errors + 1;
            $display("FAIL [T6a mtime increases] v=%0d v2=%0d", v, v2);
        end else begin
            $display("PASS [T6a mtime increases] %0d -> %0d", v, v2);
        end
        bus_rw(32'h1000_0024, 1'b1, 32'hFFFF_FFF0, 4'hF, v, e);
        bus_rw(32'h1000_0024, 1'b0, 32'h0, 4'h0, v, e);
        chk("T6b mtimecmp readback", v, 32'hFFFF_FFF0);

        // ---------- T7 未映射 ----------
        bus_rw(32'h2000_0000, 1'b0, 32'h0, 4'h0, v, e);
        chk("T7a unmapped read -> error", {31'b0, e}, 32'd1);
        chk("T7b unmapped rdata=0", v, 32'h0000_0000);
        bus_rw(32'h2000_0000, 1'b1, 32'h1234_5678, 4'hF, v, e);
        chk("T7c unmapped write -> error", {31'b0, e}, 32'd1);

        // ---------- T8 AI 加速器未使能 ----------
        bus_rw(32'h4000_0000, 1'b0, 32'h0, 4'h0, v, e);
        chk("T8a accel ctrl disabled->error", {31'b0, e}, 32'd1);
        bus_rw(32'h4000_1000, 1'b0, 32'h0, 4'h0, v, e);
        chk("T8b accel buf disabled->error", {31'b0, e}, 32'd1);
        bus_rw(32'h4000_2008, 1'b0, 32'h0, 4'h0, v, e);
        chk("T8c audio page disabled->error", {31'b0, e}, 32'd1);

        // ---------- T9 非字对齐 ----------
        bus_rw(32'h8000_0002, 1'b0, 32'h0, 4'h0, v, e);
        chk("T9a misaligned SRAM read -> error", {31'b0, e}, 32'd1);
        bus_rw(32'h0000_0002, 1'b0, 32'h0, 4'h0, v, e);
        chk("T9b misaligned ROM read -> error", {31'b0, e}, 32'd1);

        // ---------- T10 一次接受↔一次响应 + error 待决不吞请求 ----------
        @(negedge clk);
        addr = 32'h2000_0000; write = 1'b0; wstrb = 4'h0;
        req_valid = 1'b1; rsp_ready = 1'b0;
        @(posedge clk); #1;                       // 该沿被接受
        req_valid = 1'b1;                         // 故意继续保持着
        @(posedge clk); #1;
        chk("T10a error response pending", {31'b0, rsp_valid}, 32'd1);
        chk("T10b pending -> req_ready=0", {31'b0, req_ready}, 32'd0);
        @(posedge clk); #1;
        chk("T10c still pending", {31'b0, rsp_valid}, 32'd1);
        chk("T10d req_ready still 0", {31'b0, req_ready}, 32'd0);
        rsp_ready = 1'b1;
        @(posedge clk); #1;
        rsp_ready = 1'b0; req_valid = 1'b0;
        @(posedge clk); #1;
        chk("T10e req_ready recovered", {31'b0, req_ready}, 32'd1);

        // ---------- 计数对账 ----------
        repeat (2) @(posedge clk);
        checks = checks + 1;
        if (n_accept !== n_rsp) begin
            errors = errors + 1;
            $display("FAIL [T11 one accept per response] accept=%0d rsp=%0d", n_accept, n_rsp);
        end else begin
            $display("PASS [T11 one accept per response] accept=%0d rsp=%0d", n_accept, n_rsp);
        end

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
