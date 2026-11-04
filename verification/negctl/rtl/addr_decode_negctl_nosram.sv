// ============================================================================
//        地址译码（memory-map decode）
//
//        依据：docs/architecture/TECHNICAL_BASELINE.md §「接口和地址图」
//        | 区域        | 地址                        | 属性                      |
//        |------------|-----------------------------|---------------------------|
//        | 启动 ROM    | 0x0000_0000 起              | 只读、不可缓存             |
//        | SRAM/主存   | 0x8000_0000 起              | I/D Cache 可缓存           |
//        | UART       | 0x1000_0000 数据 / _0004 状态| 强制 bypass               |
//        | GPIO       | 0x1000_0010 输出 / _0014 输入| 强制 bypass               |
//        | 定时器      | 0x1000_0020 计数 / _0024 比较| 强制 bypass，产生中断      |
//        | AI 加速器   | 0x4000_0000 控制状态 / 0x4000_1000 起共享缓冲 | Stage3；共享缓冲不可缓存 |
//
//        解码规则：
//        - ROM / SRAM 使用「基址+掩码」比较，故容量必须是 2 的幂，
//          实际大小待板卡回填（见基线的待确认表）。参数化，不写死。
//        - MMIO 各设备占独立窗口：UART/GPIO/TIMER 各 16 字节，按 addr[31:4] 比较；
//          AI 控制区与共享缓冲各 4 KiB，按 addr[31:12] 比较。
//        - MMIO 判定优先于 ROM/SRAM，避免 ROM 容量取大时吞掉 MMIO 空间。
//        - 无匹配 → sel_none=1，由 mem_map_adapter 产生 error 响应。
//
//        本模块为**纯组合**，无状态，便于独立穷尽测试。
// ============================================================================

`include "defines.sv"

module addr_decode #(
    parameter [31:0] ROM_BASE       = 32'h0000_0000,
    parameter [31:0] ROM_SIZE       = 32'h0001_0000,   // 64 KiB（待板卡回填）
    parameter [31:0] SRAM_BASE      = 32'h8000_0000,
    parameter [31:0] SRAM_SIZE      = 32'h0001_0000,   // 64 KiB（待板卡回填）
    parameter [31:0] UART_BASE      = 32'h1000_0000,
    parameter [31:0] GPIO_BASE      = 32'h1000_0010,
    parameter [31:0] TIMER_BASE     = 32'h1000_0020,
    parameter [31:0] ACCEL_BASE     = 32'h4000_0000,
    parameter [31:0] ACCEL_BUF_BASE = 32'h4000_1000
)(
    input  wire [31:0] addr,
    input  wire [31:0] query_addr,

    // 目标选择（互斥 one-hot；全 0 表示未映射）
    output logic       sel_rom,
    output logic       sel_sram,
    output logic       sel_uart,
    output logic       sel_gpio,
    output logic       sel_timer,
    output logic       sel_accel_ctrl,
    output logic       sel_accel_buf,
    output logic       sel_none,

    // 属性（供 Cache / 上层查询）
    output logic       cacheable,      // 可缓存：仅 SRAM
    output logic       read_only,      // 只读：仅 ROM
    output logic       query_cacheable,
    output logic       query_read_only,
    output logic       query_sel_rom
);

    // 2 的幂容量掩码；~(SIZE-1) 在 32 位宽下求值
    localparam [31:0] ROM_MASK  = ~(ROM_SIZE  - 32'd1);
    localparam [31:0] SRAM_MASK = ~(SRAM_SIZE - 32'd1);

    always @(*) begin
        sel_rom        = 1'b0;
        sel_sram       = 1'b0;
        sel_uart       = 1'b0;
        sel_gpio       = 1'b0;
        sel_timer      = 1'b0;
        sel_accel_ctrl = 1'b0;
        sel_accel_buf  = 1'b0;

        // MMIO 窗口优先（最具体）
        if      (addr[31:4]  == UART_BASE[31:4])        sel_uart       = 1'b1;
        else if (addr[31:4]  == GPIO_BASE[31:4])        sel_gpio       = 1'b1;
        else if (addr[31:4]  == TIMER_BASE[31:4])       sel_timer      = 1'b1;
        else if (addr[31:12] == ACCEL_BUF_BASE[31:12])  sel_accel_buf  = 1'b1;
        else if (addr[31:12] == ACCEL_BASE[31:12])      sel_accel_ctrl = 1'b1;
        // 存储器区域
        else if ((addr & ROM_MASK)  == ROM_BASE)        sel_rom        = 1'b1;
        // NEGCTL: SRAM 不再被译码（访存将落到未映射 error）
    end

    assign sel_none = ~(sel_rom | sel_sram | sel_uart | sel_gpio |
                        sel_timer | sel_accel_ctrl | sel_accel_buf);

    assign cacheable = sel_sram;
    assign read_only = sel_rom;

    // 并行查询上游 CPU 地址的属性；目标选择仍严格使用 addr。
    always @(*) begin
        query_cacheable = 1'b0;
        query_read_only = 1'b0;
        query_sel_rom = 1'b0;
        if      (query_addr[31:4]  == UART_BASE[31:4])       begin end
        else if (query_addr[31:4]  == GPIO_BASE[31:4])       begin end
        else if (query_addr[31:4]  == TIMER_BASE[31:4])      begin end
        else if (query_addr[31:12] == ACCEL_BUF_BASE[31:12]) begin end
        else if (query_addr[31:12] == ACCEL_BASE[31:12])     begin end
        else if ((query_addr & ROM_MASK) == ROM_BASE) begin
            query_sel_rom = 1'b1;
            query_read_only = 1'b1;
        end else if ((query_addr & SRAM_MASK) == SRAM_BASE) begin
            query_cacheable = 1'b1;
        end
    end

endmodule
