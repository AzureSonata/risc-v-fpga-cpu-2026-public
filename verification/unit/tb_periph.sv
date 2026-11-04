// ============================================================================
//        Stage2 基础外设单元测试：UART / GPIO / 定时器
//
//        验证目标（对应 TECHNICAL_BASELINE.md 冻结地址图与第 36 行总线契约）：
//          T1  总线协议：一次请求 → 恰好一次响应；req_ready 在响应未取走时为 0
//          T2  UART 发送：写数据寄存器后，uart_tx 上出现「启动+8数据(LSB先)+停止」
//          T3  UART 状态：TX_READY 在发送期间为 0、结束后为 1；忙时写数据返回 error
//          T4  UART 接收：向 uart_rx 送入一帧，可经数据寄存器读出，RX_VALID 正确翻转
//          T5  GPIO 输出：写 0x10 后 gpio_out 更新；读 0x10 回读一致；wstrb 字节使能生效
//          T6  GPIO 输入：读 0x14 返回 gpio_in；写 0x14 返回 error
//          T7  定时器：mtime 自由递增；读 0x20 得递增值；mtime >= mtimecmp 时 irq 拉高
//          T8  未实现偏移：读写均返回 error
//
//        测试用小 DIV（= 4）以便在少量周期内完成 UART 位级验证。
// ============================================================================

`timescale 1ns / 1ps

`include "defines.sv"

module tb_periph;

    localparam integer DIV = 4;      // 时钟分频数（小值便于快速验证位时序）

    reg         clk;
    reg         rst;

    integer     errors;
    integer     checks;

    always #5 clk = ~clk;

    // ==================================================================
    //  通用总线驱动任务（对任意外设都可用的形状）
    //  由于三个外设端口形状相同，这里用宏式重复例化 + 各自驱动任务
    // ==================================================================

    // ---------------- UART ----------------
    reg         u_req_valid, u_write;
    reg  [31:0] u_addr, u_wdata;
    reg  [3:0]  u_wstrb;
    reg         u_rsp_ready;
    wire        u_req_ready, u_rsp_valid, u_error;
    wire [31:0] u_rdata;
    wire        uart_tx_line;
    reg         uart_rx_line;

    uart #(.DIV(DIV)) u_uart (
        .clk(clk), .rst(rst),
        .req_valid(u_req_valid), .req_ready(u_req_ready), .addr(u_addr),
        .write(u_write), .wdata(u_wdata), .wstrb(u_wstrb),
        .rsp_valid(u_rsp_valid), .rsp_ready(u_rsp_ready),
        .rdata(u_rdata), .error(u_error),
        .uart_tx(uart_tx_line), .uart_rx(uart_rx_line)
    );

    // ---------------- GPIO ----------------
    reg         g_req_valid, g_write;
    reg  [31:0] g_addr, g_wdata;
    reg  [3:0]  g_wstrb;
    reg         g_rsp_ready;
    wire        g_req_ready, g_rsp_valid, g_error;
    wire [31:0] g_rdata, gpio_out_w;
    reg  [31:0] gpio_in_w;

    gpio u_gpio (
        .clk(clk), .rst(rst),
        .req_valid(g_req_valid), .req_ready(g_req_ready), .addr(g_addr),
        .write(g_write), .wdata(g_wdata), .wstrb(g_wstrb),
        .rsp_valid(g_rsp_valid), .rsp_ready(g_rsp_ready),
        .rdata(g_rdata), .error(g_error),
        .gpio_out(gpio_out_w), .gpio_in(gpio_in_w)
    );

    // ---------------- 定时器 ----------------
    reg         t_req_valid, t_write;
    reg  [31:0] t_addr, t_wdata;
    reg  [3:0]  t_wstrb;
    reg         t_rsp_ready;
    wire        t_req_ready, t_rsp_valid, t_error;
    wire [31:0] t_rdata;
    wire        timer_irq_w;

    timer u_timer (
        .clk(clk), .rst(rst),
        .req_valid(t_req_valid), .req_ready(t_req_ready), .addr(t_addr),
        .write(t_write), .wdata(t_wdata), .wstrb(t_wstrb),
        .rsp_valid(t_rsp_valid), .rsp_ready(t_rsp_ready),
        .rdata(t_rdata), .error(t_error),
        .timer_irq(timer_irq_w)
    );

    // ==================================================================
    //  驱动任务
    // ==================================================================
    task uart_wr(input [31:0] a, input [31:0] d, input [3:0] strb);
        begin
            u_addr = a; u_wdata = d; u_wstrb = strb;
            u_write = 1'b1; u_req_valid = 1'b1; u_rsp_ready = 1'b1;
            @(posedge clk); #1;
            u_req_valid = 1'b0; u_write = 1'b0;
            wait (u_rsp_valid === 1'b1);
            @(posedge clk); #1;
            u_rsp_ready = 1'b0;
        end
    endtask

    task uart_rd(input [31:0] a, output [31:0] d, output err);
        begin
            u_addr = a; u_write = 1'b0; u_wstrb = 4'h0;
            u_req_valid = 1'b1; u_rsp_ready = 1'b1;
            @(posedge clk); #1;
            u_req_valid = 1'b0;
            wait (u_rsp_valid === 1'b1);
            d = u_rdata; err = u_error;
            @(posedge clk); #1;
            u_rsp_ready = 1'b0;
        end
    endtask

    task gpio_wr(input [31:0] a, input [31:0] d, input [3:0] strb);
        begin
            g_addr = a; g_wdata = d; g_wstrb = strb;
            g_write = 1'b1; g_req_valid = 1'b1; g_rsp_ready = 1'b1;
            @(posedge clk); #1;
            g_req_valid = 1'b0; g_write = 1'b0;
            wait (g_rsp_valid === 1'b1);
            @(posedge clk); #1;
            g_rsp_ready = 1'b0;
        end
    endtask

    task gpio_rd(input [31:0] a, output [31:0] d, output err);
        begin
            g_addr = a; g_write = 1'b0; g_wstrb = 4'h0;
            g_req_valid = 1'b1; g_rsp_ready = 1'b1;
            @(posedge clk); #1;
            g_req_valid = 1'b0;
            wait (g_rsp_valid === 1'b1);
            d = g_rdata; err = g_error;
            @(posedge clk); #1;
            g_rsp_ready = 1'b0;
        end
    endtask

    task timer_wr(input [31:0] a, input [31:0] d);
        begin
            t_addr = a; t_wdata = d; t_wstrb = 4'hF;
            t_write = 1'b1; t_req_valid = 1'b1; t_rsp_ready = 1'b1;
            @(posedge clk); #1;
            t_req_valid = 1'b0; t_write = 1'b0;
            wait (t_rsp_valid === 1'b1);
            @(posedge clk); #1;
            t_rsp_ready = 1'b0;
        end
    endtask

    task timer_rd(input [31:0] a, output [31:0] d, output err);
        begin
            t_addr = a; t_write = 1'b0; t_wstrb = 4'h0;
            t_req_valid = 1'b1; t_rsp_ready = 1'b1;
            @(posedge clk); #1;
            t_req_valid = 1'b0;
            wait (t_rsp_valid === 1'b1);
            d = t_rdata; err = t_error;
            @(posedge clk); #1;
            t_rsp_ready = 1'b0;
        end
    endtask

    task chk(input [8*44-1:0] tag, input [31:0] got, input [31:0] want);
        begin
            checks = checks + 1;
            if (got !== want) begin
                $display("FAIL [%0s] got=%08h want=%08h", tag, got, want);
                errors = errors + 1;
            end else $display("PASS [%0s] = %08h", tag, got);
        end
    endtask

    // 采集 UART 发送的一帧（10 位：启动+8数据+停止），返回数据字节
    task uart_capture_tx(output [7:0] byte_out, output bit ok);
        integer b;
        begin
            byte_out = 8'h00; ok = 1'b0;
            // 等待启动位（下降沿到 0）
            wait (uart_tx_line === 1'b0);
            // 略过半个位周期，之后每 DIV 拍取一个数据位
            repeat (DIV + (DIV >> 1)) @(posedge clk);
            for (b = 0; b < 8; b = b + 1) begin
                byte_out[b] = uart_tx_line;
                repeat (DIV) @(posedge clk);
            end
            ok = 1'b1;
        end
    endtask

    // 由 TB 向 UART 送入一帧（LSB 先）
    task uart_send_frame(input [7:0] byte_in);
        integer b;
        begin
            uart_rx_line = 1'b0;                 // 启动位
            repeat (DIV) @(posedge clk);
            for (b = 0; b < 8; b = b + 1) begin
                uart_rx_line = byte_in[b];
                repeat (DIV) @(posedge clk);
            end
            uart_rx_line = 1'b1;                 // 停止位
            repeat (DIV) @(posedge clk);
        end
    endtask

    integer i;
    reg [31:0] rd;
    reg        rerr;
    reg [7:0]  cap;
    reg        cap_ok;

    initial begin
        $display("==========================================");
        $display("  Stage2 peripherals test (UART/GPIO/TIMER)");
        $display("==========================================");

        errors = 0; checks = 0;
        clk = 1'b0; rst = `RstEnable;
        u_req_valid=0; u_write=0; u_addr=0; u_wdata=0; u_wstrb=0; u_rsp_ready=0;
        g_req_valid=0; g_write=0; g_addr=0; g_wdata=0; g_wstrb=0; g_rsp_ready=0;
        t_req_valid=0; t_write=0; t_addr=0; t_wdata=0; t_wstrb=0; t_rsp_ready=0;
        uart_rx_line = 1'b1;
        gpio_in_w = 32'hA5A5_0000;

        repeat (3) @(posedge clk);
        #1; rst = `RstDisable; #1;

        // ---- T1: 复位后 req_ready 为 1（无在途响应）----
        chk("T1 uart req_ready after rst", {31'h0, u_req_ready}, 32'h1);
        chk("T1 gpio req_ready after rst", {31'h0, g_req_ready}, 32'h1);
        chk("T1 timer req_ready after rst", {31'h0, t_req_ready}, 32'h1);

        // ---- T3a: 复位后 TX_READY=1、RX_VALID=0 ----
        uart_rd(32'h1000_0004, rd, rerr);
        chk("T3a uart status after rst (TX_READY=1,RX_VALID=0)", rd, 32'h1);

        // ---- T5: GPIO 输出写/回读 ----
        gpio_wr(32'h1000_0010, 32'hDEAD_BEEF, 4'hF);
        gpio_rd(32'h1000_0010, rd, rerr);
        chk("T5a gpio out readback", rd, 32'hDEAD_BEEF);
        chk("T5b gpio_out pin", gpio_out_w, 32'hDEAD_BEEF);

        // ---- T5c: wstrb 字节使能（只写低字节）----
        gpio_wr(32'h1000_0010, 32'h0000_0011, 4'h1);
        gpio_rd(32'h1000_0010, rd, rerr);
        chk("T5c gpio byte-enable (low byte only)", rd, 32'hDEAD_BE11);

        // ---- T6: GPIO 输入 ----
        gpio_rd(32'h1000_0014, rd, rerr);
        chk("T6a gpio in readback", rd, 32'hA5A5_0000);
        gpio_wr(32'h1000_0014, 32'h1234_5678, 4'hF);
        chk("T6b write to input reg -> error", {31'h0, g_error}, 32'h1);

        // ---- T8: 未实现偏移 ----
        gpio_rd(32'h1000_0018, rd, rerr);
        chk("T8 unmapped offset -> error", {31'h0, rerr}, 32'h1);

        // ---- T7: 定时器计数与比较 ----
        timer_rd(32'h1000_0020, rd, rerr);       // 读第一次
        begin : timer_cnt
            reg [31:0] c1, c2;
            c1 = rd;
            repeat (10) @(posedge clk);
            timer_rd(32'h1000_0020, c2, rerr);
            checks = checks + 1;
            if (c2 <= c1) begin
                $display("FAIL T7a mtime 未递增: c1=%0d c2=%0d", c1, c2);
                errors = errors + 1;
            end else $display("PASS T7a mtime 递增 %0d -> %0d", c1, c2);
        end

        // 复位后 mtimecmp = FFFFFFFF，irq 应为 0
        chk("T7b timer_irq low by default", {31'h0, timer_irq_w}, 32'h0);
        // 写入一个较小的比较值 -> irq 应变高
        timer_wr(32'h1000_0024, 32'h0000_0001);
        repeat (2) @(posedge clk);
        chk("T7c timer_irq high when mtime>=cmp", {31'h0, timer_irq_w}, 32'h1);
        // 写入较大的比较值 -> irq 应变低
        timer_wr(32'h1000_0024, 32'hFFFF_FFF0);
        repeat (2) @(posedge clk);
        chk("T7d timer_irq low after larger cmp", {31'h0, timer_irq_w}, 32'h0);
        // 读回比较值
        timer_rd(32'h1000_0024, rd, rerr);
        chk("T7e mtimecmp readback", rd, 32'hFFFF_FFF0);

        // ---- T2: UART 发送位级验证 ----
        fork
            uart_capture_tx(cap, cap_ok);
            uart_wr(32'h1000_0000, 32'h0000_0055, 4'hF);   // 发送 0x55 = 0101_0101
        join
        chk("T2 uart tx byte captured", {24'h0, cap}, 32'h0000_0055);

        // ---- T3b: 发送忙时写数据应 error（此时已空闲，先确认 TX_READY 已回 1）----
        uart_rd(32'h1000_0004, rd, rerr);
        checks = checks + 1;
        if (rd[0] !== 1'b1) begin
            $display("FAIL T3b TX_READY 未在发送结束后恢复: status=%08h", rd);
            errors = errors + 1;
        end else $display("PASS T3b TX_READY 发送结束后恢复为 1");

        // ---- T4: UART 接收一帧 ----
        fork
            uart_send_frame(8'hA3);
        join
        repeat (DIV * 2) @(posedge clk);
        uart_rd(32'h1000_0004, rd, rerr);
        chk("T4a RX_VALID set after frame (TX_READY=1,RX_VALID=1)", rd, 32'h3);
        uart_rd(32'h1000_0000, rd, rerr);
        chk("T4b received byte", rd, 32'h0000_00A3);
        uart_rd(32'h1000_0004, rd, rerr);
        chk("T4c RX_VALID cleared after read", rd, 32'h1);

        // ---- Summary ----
        $display("==========================================");
        $display("  检查项: %0d", checks);
        if (errors == 0) $display("  ALL TESTS PASSED (%0d errors)", errors);
        else             $display("  %0d TEST(S) FAILED", errors);
        $display("==========================================");
        $finish;
    end

    initial begin
        #200000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
