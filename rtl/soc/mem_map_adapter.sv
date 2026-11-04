// ============================================================================
//        memory-map adapter
//
//        依据：docs/architecture/TECHNICAL_BASELINE.md §「已冻结主方案」
//        「系统 | 简单内部 memory-map adapter；不采用 AXI；
//          CPU 单字侧与 Cache/外设/BRAM 解耦」
//        以及 §「分支、Cache 与异常接入」
//        「Cache 位于 CPU 单字侧和 memory-map adapter 之间：MMIO/ROM bypass」
//
//        职责（只做这一件事）：
//        1. 用 addr_decode 把上游单字地址译码到唯一目标；
//        2. 把上游请求转发给该目标，并把该目标的响应**唯一地**送回上游；
//        3. 对"没有目标"的访问产生 error 响应：未映射地址、写 ROM、
//           未使能的 AI 加速器区、非法（非字对齐）地址。
//
//        契约（来自基线 §「接口和地址图」，不得违反）：
//        - 握手发生在上升沿；valid && !ready 时载荷保持；
//        - 一次请求接受**只对应一次响应**；
//        - 上游一次只允许一个未完成事务；
//        - error 不得产生成功写回 —— 故 error 响应的 rdata 恒 0，
//          且未映射/只读写**不会**向任何目标发出请求（无副作用）。
//
//        未完成请求的记账：响应路由选择在**请求被接受的那一刻**锁存
//        （rsp_sel_q）。由于上游最多一笔未完成，锁存值在响应被取走前保持有效。
//
//        AI/音频：0x4000_0000 控制、0x4000_1000 共享缓冲、0x4000_2000 音频 FIFO
//        均经同一 accelerator 请求/响应端口交给 SoC 集成层进一步译码，
//        但 Stage3 之前其端口由 ACCEL_ENABLE=0 门控 → 访问一律 error，
//        避免"访问了不存在的设备却成功返回"。
// ============================================================================

`include "defines.sv"

module mem_map_adapter #(
    parameter [31:0]  ROM_BASE       = 32'h0000_0000,
    parameter [31:0]  ROM_SIZE       = 32'h0001_0000,
    parameter [31:0]  SRAM_BASE      = 32'h8000_0000,
    parameter [31:0]  SRAM_SIZE      = 32'h0001_0000,
    parameter [31:0]  UART_BASE      = 32'h1000_0000,
    parameter [31:0]  GPIO_BASE      = 32'h1000_0010,
    parameter [31:0]  TIMER_BASE     = 32'h1000_0020,
    parameter [31:0]  ACCEL_BASE     = 32'h4000_0000,
    parameter [31:0]  ACCEL_BUF_BASE = 32'h4000_1000,
    parameter [31:0]  ACCEL_AUDIO_BASE = 32'h4000_2000,
    parameter         ACCEL_ENABLE   = 1'b0,     // Stage3 打开
    parameter         QUERY_ADDR_ENABLE = 1'b0
)(
    input  wire         clk,
    input  wire         rst,

    // ---------------- 上游：CPU / Cache 单字端口 ----------------
    input  wire         req_valid,
    output logic        req_ready,
    input  wire [31:0]  addr,
    input  wire [31:0]  query_addr,
    input  wire         write,
    input  wire [31:0]  wdata,
    input  wire [3:0]   wstrb,

    output logic        rsp_valid,
    input  wire         rsp_ready,
    output logic [31:0] rdata,
    output logic        error,

    // 属性透出（供 Cache 决定是否缓存）
    output logic        cacheable,
    output logic        read_only,
    // 区域选择透出：供 I 侧把 ROM 一并纳入可缓存（ADR D-C3 的显式基线偏离）需要知道"是否 ROM"。
    // ⚠️ 坑位：**不要为了取 sel_rom 而在外再例化一份 `addr_decode`** ——
    //    Icarus 10.2 在同一设计里出现"同一模块的两个实例（一份嵌在本模块内、一份在外）"时，
    //    会让其中一个实例的 always 块**完全不参与求值**：外部实例输出恒 x，
    //    或内部实例卡在复位值不再更新。症状即 `cacheable=x` ⇒ 路径 mux 求值成 x
    //    ⇒ 握手信号变 x ⇒ Cache 填充挂死（本项目 2026-09-30 批 (d-2) 实测踩到，
    //    定位过程见日志 2026-09-30-03 / 2026-09-30-05 与 lessons/LESSON-001）。
    //    ⇒ 正确做法：**地址图只保留一份实例**，需要额外属性由它透出（本端口即为此而加）。
    output logic        sel_rom,

    // ---------------- 目标：启动 ROM（只读） ----------------
    output logic        rom_req_valid,
    input  wire         rom_req_ready,
    output logic [31:0] rom_addr,
    input  wire         rom_rsp_valid,
    output logic        rom_rsp_ready,
    input  wire [31:0]  rom_rdata,
    input  wire         rom_error,

    // ---------------- 目标：SRAM / 主存 ----------------
    output logic        sram_req_valid,
    input  wire         sram_req_ready,
    output logic [31:0] sram_addr,
    output logic        sram_write,
    output logic [31:0] sram_wdata,
    output logic [3:0]  sram_wstrb,
    input  wire         sram_rsp_valid,
    output logic        sram_rsp_ready,
    input  wire [31:0]  sram_rdata,
    input  wire         sram_error,

    // ---------------- 目标：UART ----------------
    output logic        uart_req_valid,
    input  wire         uart_req_ready,
    output logic [31:0] uart_addr,
    output logic        uart_write,
    output logic [31:0] uart_wdata,
    output logic [3:0]  uart_wstrb,
    input  wire         uart_rsp_valid,
    output logic        uart_rsp_ready,
    input  wire [31:0]  uart_rdata,
    input  wire         uart_error,

    // ---------------- 目标：GPIO ----------------
    output logic        gpio_req_valid,
    input  wire         gpio_req_ready,
    output logic [31:0] gpio_addr,
    output logic        gpio_write,
    output logic [31:0] gpio_wdata,
    output logic [3:0]  gpio_wstrb,
    input  wire         gpio_rsp_valid,
    output logic        gpio_rsp_ready,
    input  wire [31:0]  gpio_rdata,
    input  wire         gpio_error,

    // ---------------- 目标：定时器 ----------------
    output logic        timer_req_valid,
    input  wire         timer_req_ready,
    output logic [31:0] timer_addr,
    output logic        timer_write,
    output logic [31:0] timer_wdata,
    output logic [3:0]  timer_wstrb,
    input  wire         timer_rsp_valid,
    output logic        timer_rsp_ready,
    input  wire [31:0]  timer_rdata,
    input  wire         timer_error,

    // ---------------- 目标：AI 加速器（Stage3，ACCEL_ENABLE 门控） ----------------
    output logic        accel_req_valid,
    input  wire         accel_req_ready,
    output logic [31:0] accel_addr,
    output logic        accel_write,
    output logic [31:0] accel_wdata,
    output logic [3:0]  accel_wstrb,
    input  wire         accel_rsp_valid,
    output logic        accel_rsp_ready,
    input  wire [31:0]  accel_rdata,
    input  wire         accel_error
);

    // ---------------------------------------------------------------
    // 1. 译码
    // ---------------------------------------------------------------
    logic sel_sram, sel_uart, sel_gpio, sel_timer;
    logic sel_accel_ctrl, sel_accel_buf, sel_accel_audio, sel_none;
    logic dec_cacheable, dec_read_only, dec_sel_rom;
    logic query_cacheable_dec, query_read_only_dec, query_sel_rom_dec;
    wire [31:0] decode_query_addr = QUERY_ADDR_ENABLE ? query_addr : addr;

    addr_decode #(
        .ROM_BASE(ROM_BASE), .ROM_SIZE(ROM_SIZE),
        .SRAM_BASE(SRAM_BASE), .SRAM_SIZE(SRAM_SIZE),
        .UART_BASE(UART_BASE), .GPIO_BASE(GPIO_BASE), .TIMER_BASE(TIMER_BASE),
        .ACCEL_BASE(ACCEL_BASE), .ACCEL_BUF_BASE(ACCEL_BUF_BASE),
        .ACCEL_AUDIO_BASE(ACCEL_AUDIO_BASE)
    ) u_decode (
        .addr(addr), .query_addr(decode_query_addr),
        .sel_rom(dec_sel_rom), .sel_sram(sel_sram), .sel_uart(sel_uart),
        .sel_gpio(sel_gpio), .sel_timer(sel_timer),
        .sel_accel_ctrl(sel_accel_ctrl), .sel_accel_buf(sel_accel_buf),
        .sel_accel_audio(sel_accel_audio),
        .sel_none(sel_none),
        .cacheable(dec_cacheable), .read_only(dec_read_only),
        .query_cacheable(query_cacheable_dec), .query_read_only(query_read_only_dec),
        .query_sel_rom(query_sel_rom_dec)
    );

    always @(*) begin
        cacheable = QUERY_ADDR_ENABLE ? query_cacheable_dec : dec_cacheable;
        read_only = QUERY_ADDR_ENABLE ? query_read_only_dec : dec_read_only;
        sel_rom = QUERY_ADDR_ENABLE ? query_sel_rom_dec : dec_sel_rom;
    end

    // ---------------------------------------------------------------
    // 2. 哪些访问没有合法目标（必须由本模块产生 error 响应）
    //    - 未映射地址
    //    - 写 ROM（只读）
    //    - AI 加速器未使能（Stage3 之前）
    //    - 非字对齐地址（防御性：核心应在 EX/MEM 先报 misaligned 异常，
    //      若仍到达此处则宁可 error，也不静默错位访问）
    // ---------------------------------------------------------------
    wire accel_sel = sel_accel_ctrl | sel_accel_buf | sel_accel_audio;

    wire unsupported = sel_none
                     | (dec_sel_rom & write)
                     | (accel_sel & ~ACCEL_ENABLE)
                     | (addr[1:0] != 2'b00);

    // ---------------------------------------------------------------
    // 3. 目标选择编码（仅在请求被接受的那一拍有意义）
    // ---------------------------------------------------------------
    localparam [2:0] SEL_ROM = 3'd0, SEL_SRAM = 3'd1, SEL_UART = 3'd2,
                     SEL_GPIO = 3'd3, SEL_TIMER = 3'd4, SEL_ACCEL = 3'd5,
                     SEL_ERR = 3'd6;

    logic [2:0] sel_enc;
    always @(*) begin
        if      (unsupported)  sel_enc = SEL_ERR;
        else if (dec_sel_rom)  sel_enc = SEL_ROM;
        else if (sel_sram)     sel_enc = SEL_SRAM;
        else if (sel_uart)     sel_enc = SEL_UART;
        else if (sel_gpio)     sel_enc = SEL_GPIO;
        else if (sel_timer)    sel_enc = SEL_TIMER;
        else if (accel_sel)    sel_enc = SEL_ACCEL;
        else                   sel_enc = SEL_ERR;
    end

    // ---------------------------------------------------------------
    // 4. 下游请求转发（未映射/只读写一律不发请求 → 无副作用）
    // ---------------------------------------------------------------
    wire fwd = req_valid & ~unsupported;

    assign rom_req_valid   = fwd & dec_sel_rom;
    assign rom_addr        = addr;

    assign sram_req_valid  = fwd & sel_sram;
    assign sram_addr       = addr;
    assign sram_write      = write;
    assign sram_wdata      = wdata;
    assign sram_wstrb      = wstrb;

    assign uart_req_valid  = fwd & sel_uart;
    assign uart_addr       = addr;
    assign uart_write      = write;
    assign uart_wdata      = wdata;
    assign uart_wstrb      = wstrb;

    assign gpio_req_valid  = fwd & sel_gpio;
    assign gpio_addr       = addr;
    assign gpio_write      = write;
    assign gpio_wdata      = wdata;
    assign gpio_wstrb      = wstrb;

    assign timer_req_valid = fwd & sel_timer;
    assign timer_addr      = addr;
    assign timer_write     = write;
    assign timer_wdata     = wdata;
    assign timer_wstrb     = wstrb;

    assign accel_req_valid = fwd & accel_sel;
    assign accel_addr      = addr;
    assign accel_write     = write;
    assign accel_wdata     = wdata;
    assign accel_wstrb     = wstrb;

    // ---------------------------------------------------------------
    // 5. 错误响应记账（单笔）
    //    - 上游最多一笔未完成，故只需 1 个待决 error 位；
    //    - 已有 error 待取走时不再接受新请求（req_ready=0），
    //      否则会吞掉上游请求（契约：一次接受一次响应）。
    // ---------------------------------------------------------------
    logic err_pending_q;

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            err_pending_q <= 1'b0;
        end else if (err_pending_q) begin
            if (rsp_ready) err_pending_q <= 1'b0;
        end else if (req_valid && req_ready && (sel_enc == SEL_ERR)) begin
            err_pending_q <= 1'b1;
        end
    end

    // ---------------------------------------------------------------
    // 6. 响应路由选择锁存
    // ---------------------------------------------------------------
    logic [2:0] rsp_sel_q;

    wire accept = req_valid && req_ready;

    always @(posedge clk) begin
        if (rst == `RstEnable) rsp_sel_q <= SEL_ERR;
        else if (accept)       rsp_sel_q <= sel_enc;
    end

    // ---------------------------------------------------------------
    // 7. 上游 req_ready：由被选中的目标决定；error 通路为"立即接受"
    // ---------------------------------------------------------------
    // 目标选择窗口两两互斥，去掉 sel_enc 优先级编码链：
    // 直接把各目标的 ready 按窗口平铺并出，缩短 req_addr -> req_ready 的路径。
    wire dev_req_ready = (dec_sel_rom & rom_req_ready)
                       | (sel_sram    & sram_req_ready)
                       | (sel_uart    & uart_req_ready)
                       | (sel_gpio    & gpio_req_ready)
                       | (sel_timer   & timer_req_ready)
                       | (accel_sel   & accel_req_ready);

    assign req_ready = unsupported ? ~err_pending_q : dev_req_ready;

    // ---------------------------------------------------------------
    // 8. 响应仲裁：按锁存的目标选择取唯一来源
    // ---------------------------------------------------------------
    always @(*) begin
        rsp_valid = 1'b0;
        rdata     = `ZeroWord;
        error     = 1'b0;
        case (rsp_sel_q)
            SEL_ROM: begin
                rsp_valid = rom_rsp_valid;
                rdata     = rom_rdata;
                error     = rom_error;
            end
            SEL_SRAM: begin
                rsp_valid = sram_rsp_valid;
                rdata     = sram_rdata;
                error     = sram_error;
            end
            SEL_UART: begin
                rsp_valid = uart_rsp_valid;
                rdata     = uart_rdata;
                error     = uart_error;
            end
            SEL_GPIO: begin
                rsp_valid = gpio_rsp_valid;
                rdata     = gpio_rdata;
                error     = gpio_error;
            end
            SEL_TIMER: begin
                rsp_valid = timer_rsp_valid;
                rdata     = timer_rdata;
                error     = timer_error;
            end
            SEL_ACCEL: begin
                rsp_valid = accel_rsp_valid;
                rdata     = accel_rdata;
                error     = accel_error;
            end
            default: begin                       // SEL_ERR
                rsp_valid = err_pending_q;
                rdata     = `ZeroWord;          // error 不得产生成功写回
                error     = 1'b1;
            end
        endcase
    end

    // 只有被选中的目标才允许消费本次响应
    assign rom_rsp_ready   = rsp_ready & (rsp_sel_q == SEL_ROM);
    assign sram_rsp_ready  = rsp_ready & (rsp_sel_q == SEL_SRAM);
    assign uart_rsp_ready  = rsp_ready & (rsp_sel_q == SEL_UART);
    assign gpio_rsp_ready  = rsp_ready & (rsp_sel_q == SEL_GPIO);
    assign timer_rsp_ready = rsp_ready & (rsp_sel_q == SEL_TIMER);
    assign accel_rsp_ready = rsp_ready & (rsp_sel_q == SEL_ACCEL);

endmodule
