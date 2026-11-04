// ============================================================================
//        CPU + 存储子系统（CPU 单字端口 → memory-map adapter → ROM/SRAM）
//
//        目的：把 `cpu_core_stage1` 的冻结单字 I/D 端口真正接到 memory-map adapter，
//        使 CPU 能**通过真实地址图**取指（ROM 0x0000_0000）与访存（SRAM 0x8000_0000）。
//        这是"接入"的第一步：此前 adapter、ROM/SRAM、外围都只做过独立定向验证，
//        从未与 CPU 连在一起跑过程序。
//
//        结构：
//          I 端口 → u_adapter_i → u_rom_i / u_sram_i
//          D 端口 → u_adapter_d → u_rom_d / u_sram_d
//        两个 adapter 各自单端口，故 I/D 各用一个（adapter 无仲裁能力）。
//
//        ---- 本模块**有意不做**的事（如实声明，避免误读为完整 SoC）----
//        1. **I 侧与 D 侧不共享 SRAM**：真实 SoC 应是一份主存 + 仲裁器；本模块为了
//           先打通"CPU 能否通过 adapter 正确取指/访存"而复用两份实例，
//           因此"通过 D 侧写入、再通过 I 侧取指读到"这类自修改代码场景**不成立**。
//        2. **GPIO / 定时器 / UART 均已接入**（D 侧接真实实例）：
//             GPIO  0x1000_0010 输出 / 0x1000_0014 输入
//             定时器 0x1000_0020 计数 / 0x1000_0024 比较
//             UART  0x1000_0000 数据 / 0x1000_0004 状态（TX/RX 引脚已引出）
//           因此 CPU 程序可经 MMIO 点灯、读计数、发送串口字节；
//           **AI 加速器仍未接入**，其设备端口显式 tie-off
//           （ready=1、rsp_valid 于下一拍、error=1），一旦被选中即以 error 响应，
//           不会静默返回 0、也不会挂死。
//           外围自身的语义与 MMIO 路由已在 `tb_periph`（20 项）与 `tb_mem_map`（35 项）中验证。
//        3. 无 Cache：`cacheable` 属性已由 adapter 输出，但 I/D Cache 尚未置于
//           CPU 与 adapter 之间（Cache 模块本身已独立验证）。
//
//        存储容量：ROM/SRAM 各默认 1 KiB 实例（`DEPTH=256`），仅用于仿真；
//        adapter 的**译码区间**仍为基线的 64 KiB 默认值，两者解耦且互不冲突
//        （用到未实例化的字地址会读到 NOP/0，属仿真模型的取舍，已在 TB 中断言
//        程序只用实例化范围内的地址）。
// ============================================================================

`include "defines.sv"

module cpu_mem_subsystem #(
    parameter integer MEM_DEPTH     = 256,    // 实例化字数（仿真规模）
    parameter integer MEM_AW        = 8,
    parameter [1023:0] ROM_INIT_FILE = 1024'd0,
    parameter integer UART_DIV      = 434,    // UART 分频数（50 MHz / 115200 ≈ 434）；
                                              // TB 可覆写以缩短仿真，默认即真实波特率配置
    parameter         ICACHE_ENABLE = 1'b1,   // I 侧 Cache 接入开关（0 = 接入前的纯 bypass 行为）
    parameter         DCACHE_ENABLE = 1'b1    // D 侧 Cache 接入开关（批 (d-2)，ADR-MEM-EXIT-001 修复后重新启用）
)(
    input  wire         clk,
    input  wire         rst,

    // ---------------- CPU I 端口（冻结契约） ----------------
    input  wire         i_req_valid,
    output wire         i_req_ready,
    input  wire [31:0]  i_req_addr,
    input  wire         i_write,
    input  wire [31:0]  i_wdata,
    input  wire [3:0]   i_wstrb,
    output wire         i_rsp_valid,
    input  wire         i_rsp_ready,
    output wire [31:0]  i_rdata,
    output wire         i_error,

    // ---------------- CPU D 端口（冻结契约） ----------------
    input  wire         d_req_valid,
    output wire         d_req_ready,
    input  wire [31:0]  d_req_addr,
    input  wire         d_write,
    input  wire [31:0]  d_wdata,
    input  wire [3:0]   d_wstrb,
    output wire         d_rsp_valid,
    input  wire         d_rsp_ready,
    output wire [31:0]  d_rdata,
    output wire         d_error,

    // ---------------- 已接入的 MMIO 设备引脚 ----------------
    // GPIO：D 侧已接到真实 gpio 实例（地址 0x1000_0010 输出 / 0x1000_0014 输入）。
    // 这是"外围与 CPU 连起来"的第一个设备；UART/定时器/AI 仍为 tie-off。
    output wire [31:0]  gpio_out,
    input  wire [31:0]  gpio_in,

    // 定时器：D 侧已接真实 timer 实例（0x1000_0020 计数 / 0x1000_0024 比较），
    // 其机器定时器中断以电平形式引出；批 (c) 起由顶层把它接回 CPU 的 timer_irq_i
    // （接入 csr_file 的 mip.MTIP 与中断采样，见 ADR-CSR-ACCESS.md 批 (c) D12/D14）。
    output wire         timer_irq,

    // UART：D 侧已接真实 uart 实例（0x1000_0000 数据 / 0x1000_0004 状态）。
    // TX 为输出引脚，RX 为输入（当前 TB 固定接高，即空闲电平）。
    output wire         uart_tx,
    input  wire         uart_rx
);

    // ==================================================================
    // I 侧：adapter + ROM + SRAM
    // ==================================================================
    wire        ai_rom_req_valid, ai_rom_req_ready, ai_rom_rsp_valid, ai_rom_rsp_ready;
    wire        ai_rom_error;
    wire [31:0] ai_rom_addr, ai_rom_rdata;

    wire        ai_sram_req_valid, ai_sram_req_ready, ai_sram_rsp_valid, ai_sram_rsp_ready;
    wire        ai_sram_write, ai_sram_error;
    wire [31:0] ai_sram_addr, ai_sram_wdata, ai_sram_rdata;
    wire [3:0]  ai_sram_wstrb;

    // 未接入设备（UART/GPIO/TIMER/AI）的端口
    wire        ai_u_req_valid, ai_u_req_ready, ai_u_rsp_valid, ai_u_rsp_ready, ai_u_error;
    wire        ai_u_write;
    wire [31:0] ai_u_addr, ai_u_wdata, ai_u_rdata;
    wire [3:0]  ai_u_wstrb;
    wire        ai_g_req_valid, ai_g_req_ready, ai_g_rsp_valid, ai_g_rsp_ready, ai_g_error;
    wire        ai_g_write;
    wire [31:0] ai_g_addr, ai_g_wdata, ai_g_rdata;
    wire [3:0]  ai_g_wstrb;
    wire        ai_t_req_valid, ai_t_req_ready, ai_t_rsp_valid, ai_t_rsp_ready, ai_t_error;
    wire        ai_t_write;
    wire [31:0] ai_t_addr, ai_t_wdata, ai_t_rdata;
    wire [3:0]  ai_t_wstrb;
    wire        ai_a_req_valid, ai_a_req_ready, ai_a_rsp_valid, ai_a_rsp_ready, ai_a_error;
    wire        ai_a_write;
    wire [31:0] ai_a_addr, ai_a_wdata, ai_a_rdata;
    wire [3:0]  ai_a_wstrb;

    wire ai_cacheable_i, ai_read_only_i;

    // ---- I 侧 bypass 通路：cache_path 的 bypass 端口 ⇄ u_adapter_i 的上游口 ----
    wire        ai_byp_req_valid, ai_byp_req_write;
    wire [31:0] ai_byp_req_addr, ai_byp_req_wdata;
    wire [3:0]  ai_byp_req_wstrb;
    wire        ai_byp_rsp_valid, ai_byp_rsp_error, ai_byp_rsp_ready;
    wire [31:0] ai_byp_rsp_data;

    // ==================================================================
    // I 侧 Cache 接入（批 (d-1)，ADR-CACHE-INTEGRATION）
    // ==================================================================
    // 拓扑：CPU 冻结单字口 → cache_path（bypass mux + 路径保持锁）
    //         ├─ Cache 路径： icache ── mem_burst_bridge ─┐
    //         └─ bypass 路径： ───────────────────────────┴→ adapter 单字口
    //
    // · 可缓存性判据的**单一来源**仍是 addr_decode：此处另例化一个**查询实例**（同一份地址图），
    //   I 侧取 `sel_rom | sel_sram`（ADR D-C3 的**显式基线偏离**：基线原写"I 侧 ROM 不可缓存"，
    //   但当前所有程序都从 ROM 取指，照搬会让 I-Cache 永远零命中、接入沦为摆设；
    //   偏离理由与"ROM 结构上不可写"的安全性论证见 ADR D-C3）。
    // · 写永不进 Cache 路径（I 侧上游本就无写；D 侧 store 走 bypass 以保证写 ROM 一定下发）。
    // · **cpu_core_stage1 零改动**（D-C1）：CPU 冻结单字端口与全部例化点不变。
    // ---- I 侧可缓存性判据：**复用 adapter 内部唯一那份地址图实例**，不再另开查询实例 ----
    // ⚠️ 坑位：这里曾例化第二份 `addr_decode` 作为"查询实例"（ADR 原定方案）。
    //    Icarus 10.2 下"同一模块两个实例（一份嵌在 mem_map_adapter 内、一份在外）"
    //    会让其中一个实例的 always 块**完全不参与求值**：外部实例输出恒 x。
    //    后果链：`cacheable=x` ⇒ `cache_path` 路径 mux 求值成 x ⇒ 握手信号变 x
    //    ⇒ 请求被"接受"但 icache 从未开始填充 ⇒ 取指流挂死（d-1 侥幸未触发）。
    //    ⇒ 正确做法：地址图**只保留一份实例**，额外属性由它透出
    //    （为此给 `mem_map_adapter` 增加了 `sel_rom` 输出）。
    //    见日志 2026-09-30-03 / 2026-09-30-05 与 lessons/LESSON-001。
    wire ai_sel_rom_i;                                          // 本拍地址是否落在 ROM 区（adapter 透出）
    wire ai_cacheable_i_eff = ai_sel_rom_i | ai_cacheable_i;    // I 侧：ROM+SRAM 可缓存（D-C3 偏离）

    // ---- CPU ⇄ cache_path ----
    wire        i_cpu_req_ready, i_cpu_rsp_valid, i_cpu_error;
    wire [31:0] i_cpu_rdata;
    // ---- cache_path ⇄ icache（单字口 + 填充口；I 侧写穿口不接） ----
    wire        i_cp_cache_req_valid, i_cp_cache_req_ready;
    wire        i_cp_cache_rsp_valid, i_cp_cache_rsp_ready, i_cp_cache_rsp_error;
    wire [31:0] i_cp_cache_rsp_data;
    wire [31:0] i_cp_line_addr;
    wire        i_cp_mem_read, i_cp_beat_valid, i_cp_beat_ready, i_cp_beat_last, i_cp_beat_error;
    wire [31:0] i_cp_beat_data;
    wire        i_cp_mem_write, i_cp_wr_beat_valid, i_cp_wr_beat_ready, i_cp_wr_beat_error;
    wire [31:0] i_cp_wr_addr, i_cp_wr_beat_data;
    wire [3:0]  i_cp_wr_beat_wstrb;
    wire        i_cp_wr_beat_last;
    // A2b：后台 I-Cache 填充/写穿仍占用内存侧 adapter 时置 1。
    wire        i_cache_busy = i_cp_mem_read | i_cp_mem_write;
    // ---- cache_path ⇄ 桥（桥 = Cache 路径的内存侧代理） ----
    wire        i_br_req_valid, i_br_req_ready, i_br_req_write;
    wire [31:0] i_br_req_addr, i_br_req_wdata, i_br_rsp_rdata;
    wire [3:0]  i_br_req_wstrb;
    wire        i_br_rsp_valid, i_br_rsp_ready, i_br_rsp_error;
    // ---- cache_path 的 adapter 端口（Cache 路径一侧的"虚拟 adapter 口"） ----
    // 注意：**不能与上面的 i_br_* 同网**——桥会驱动 i_br_req_addr，而 cache_path 的
    // adapter_req_addr 也是一个驱动源，同网即形成双驱动（实测表现为 addr 被求值成 x）。
    wire        i_cv_req_valid, i_cv_req_ready, i_cv_req_write;
    wire [31:0] i_cv_req_addr, i_cv_req_wdata, i_cv_rsp_rdata;
    wire [3:0]  i_cv_req_wstrb;
    wire        i_cv_rsp_valid, i_cv_rsp_ready, i_cv_rsp_error;
    // ---- cache_path ⇄ adapter（adapter 的冻结上游口） ----
    wire        i_adp_req_valid, i_adp_req_ready, i_adp_req_write;
    wire [31:0] i_adp_req_addr, i_adp_req_wdata, i_adp_rsp_rdata;
    wire [3:0]  i_adp_req_wstrb;
    wire        i_adp_rsp_valid, i_adp_rsp_ready, i_adp_rsp_error;
    wire        i_path_drives_adp;     // 1 = cache_path 在用 adapter 口（⇒ 桥让出）
    // adapter 输出端口的专用中间网（只由 u_adapter_i 驱动，见其例化处说明）
    wire        adp_req_ready, adp_rsp_valid, adp_rsp_error;
    wire [31:0] adp_rsp_rdata;

    cache_path u_cache_path_i (
        .clk(clk), .rst(rst),
        .cache_en(ICACHE_ENABLE), .cacheable(ai_cacheable_i_eff),
        .cache_busy_i(i_cache_busy),
        .up_req_valid(i_req_valid), .up_req_ready(i_cpu_req_ready),
        .up_req_addr(i_req_addr), .up_write(i_write),
        .up_wdata(i_wdata), .up_wstrb(i_wstrb),
        .up_rsp_valid(i_cpu_rsp_valid), .up_rsp_ready(i_rsp_ready),
        .up_rsp_data(i_cpu_rdata), .up_rsp_error(i_cpu_error),
        .cache_req_valid(i_cp_cache_req_valid), .cache_req_ready(i_cp_cache_req_ready),
        .cache_rsp_valid(i_cp_cache_rsp_valid), .cache_rsp_ready(i_cp_cache_rsp_ready),
        .cache_rsp_data(i_cp_cache_rsp_data), .cache_rsp_error(i_cp_cache_rsp_error),
        // A2b：line/mem 由 icache 直接驱动，cache_path 不再重复驱动 line_addr
        //（早响应后 up_req_addr 可能已经换行，双驱动会让桥抓到 x/错行）。
        .cache_line_addr(), .cache_mem_read(i_cp_mem_read),
        .cache_beat_valid(i_cp_beat_valid), .cache_beat_ready(i_cp_beat_ready),
        .cache_beat_data(i_cp_beat_data), .cache_beat_last(i_cp_beat_last),
        .cache_beat_error(i_cp_beat_error),
        .cache_mem_write(i_cp_mem_write), .cache_wr_addr(i_cp_wr_addr),
        .cache_wr_beat_valid(i_cp_wr_beat_valid), .cache_wr_beat_ready(i_cp_wr_beat_ready),
        .cache_wr_beat_data(i_cp_wr_beat_data), .cache_wr_beat_wstrb(i_cp_wr_beat_wstrb),
        .cache_wr_beat_last(i_cp_wr_beat_last), .cache_wr_beat_error(i_cp_wr_beat_error),
        // bypass 端口：旁路事务直连 adapter 侧（与 u_adapter_i 的上游口同网）
        .bypass_req_valid(ai_byp_req_valid), .bypass_req_addr(ai_byp_req_addr),
        .bypass_req_write(ai_byp_req_write), .bypass_req_wdata(ai_byp_req_wdata),
        .bypass_req_wstrb(ai_byp_req_wstrb),
        .bypass_rsp_valid(ai_byp_rsp_valid), .bypass_rsp_data(ai_byp_rsp_data),
        .bypass_rsp_error(ai_byp_rsp_error),
        // adapter 端口：缓存填充/写穿由桥代理（i_cv_* 为本模块"虚拟 adapter 口"）
        .adapter_req_valid(i_cv_req_valid), .adapter_req_ready(i_cv_req_ready),
        .adapter_req_addr(i_cv_req_addr), .adapter_req_write(i_cv_req_write),
        .adapter_req_wdata(i_cv_req_wdata), .adapter_req_wstrb(i_cv_req_wstrb),
        .adapter_rsp_valid(i_cv_rsp_valid), .adapter_rsp_ready(i_cv_rsp_ready),
        .adapter_rsp_rdata(i_cv_rsp_rdata), .adapter_rsp_error(i_cv_rsp_error),
        .path_is_cache_o(), .path_drives_adapter_o(i_path_drives_adp)
    );

    icache u_icache (
        .clk(clk), .rst(rst),
        .req_valid(i_cp_cache_req_valid), .req_ready(i_cp_cache_req_ready),
        .addr(i_req_addr), .write(1'b0), .wdata(32'h0), .wstrb(4'h0),
        .rsp_valid(i_cp_cache_rsp_valid), .rsp_ready(i_cp_cache_rsp_ready),
        .rdata(i_cp_cache_rsp_data), .error(i_cp_cache_rsp_error),
        .line_addr(i_cp_line_addr), .mem_read(i_cp_mem_read), .mem_write(i_cp_mem_write),
        .beat_valid(i_cp_beat_valid), .beat_ready(i_cp_beat_ready),
        .beat_data(i_cp_beat_data), .beat_last(i_cp_beat_last), .beat_error(i_cp_beat_error),
        .hit_o(), .stat_hit(), .stat_miss()
    );

    mem_burst_bridge u_bridge_i (
        .clk(clk), .rst(rst),
        .line_addr(i_cp_line_addr), .mem_read(i_cp_mem_read), .mem_write(i_cp_mem_write),
        .wr_addr(i_cp_wr_addr),
        .rd_beat_valid(i_cp_beat_valid), .rd_beat_ready(i_cp_beat_ready),
        .rd_beat_data(i_cp_beat_data), .rd_beat_last(i_cp_beat_last),
        .rd_beat_error(i_cp_beat_error),
        .wr_beat_valid(i_cp_wr_beat_valid), .wr_beat_ready(i_cp_wr_beat_ready),
        .wr_beat_data(i_cp_wr_beat_data), .wr_beat_wstrb(i_cp_wr_beat_wstrb),
        .wr_beat_last(i_cp_wr_beat_last), .wr_beat_error(i_cp_wr_beat_error),
        .req_valid(i_br_req_valid), .req_ready(i_br_req_ready), .req_addr(i_br_req_addr),
        .req_write(i_br_req_write), .req_wdata(i_br_req_wdata), .req_wstrb(i_br_req_wstrb),
        .rsp_valid(i_br_rsp_valid), .rsp_ready(i_br_rsp_ready),
        .rsp_rdata(i_br_rsp_rdata), .rsp_error(i_br_rsp_error)
    );

    mem_map_adapter #(.ACCEL_ENABLE(1'b0), .QUERY_ADDR_ENABLE(1'b1)) u_adapter_i (
        .clk(clk), .rst(rst),
        // 注意：adapter 的 req_ready / rsp_* 是**输出端口**，作为端口实参的信号只能由
        // 该端口驱动；若同一根线再被 assign 赋值，就会形成双驱动（iverilog 报
        // "must have a single driver"，或在未开告警时表现为该网被求值成 z/x）。
        // 因此这里先落到一组**专用中间网** adp_*，再由下面的 assign 扇出到桥与 bypass，
        // 端口实参与被 assign 的网不再重合。
        .req_valid(i_adp_req_valid), .req_ready(adp_req_ready), .addr(i_adp_req_addr), .query_addr(i_req_addr),
        .write(i_adp_req_write), .wdata(i_adp_req_wdata), .wstrb(i_adp_req_wstrb),
        .rsp_valid(adp_rsp_valid), .rsp_ready(i_adp_rsp_ready),
        .rdata(adp_rsp_rdata), .error(adp_rsp_error),
        .cacheable(ai_cacheable_i), .read_only(ai_read_only_i), .sel_rom(ai_sel_rom_i),
        .rom_req_valid(ai_rom_req_valid), .rom_req_ready(ai_rom_req_ready),
        .rom_addr(ai_rom_addr), .rom_rsp_valid(ai_rom_rsp_valid),
        .rom_rsp_ready(ai_rom_rsp_ready), .rom_rdata(ai_rom_rdata), .rom_error(ai_rom_error),
        .sram_req_valid(ai_sram_req_valid), .sram_req_ready(ai_sram_req_ready),
        .sram_addr(ai_sram_addr), .sram_write(ai_sram_write), .sram_wdata(ai_sram_wdata),
        .sram_wstrb(ai_sram_wstrb), .sram_rsp_valid(ai_sram_rsp_valid),
        .sram_rsp_ready(ai_sram_rsp_ready), .sram_rdata(ai_sram_rdata), .sram_error(ai_sram_error),
        .uart_req_valid(ai_u_req_valid), .uart_req_ready(ai_u_req_ready),
        .uart_addr(ai_u_addr), .uart_write(ai_u_write), .uart_wdata(ai_u_wdata),
        .uart_wstrb(ai_u_wstrb), .uart_rsp_valid(ai_u_rsp_valid),
        .uart_rsp_ready(ai_u_rsp_ready), .uart_rdata(ai_u_rdata), .uart_error(ai_u_error),
        .gpio_req_valid(ai_g_req_valid), .gpio_req_ready(ai_g_req_ready),
        .gpio_addr(ai_g_addr), .gpio_write(ai_g_write), .gpio_wdata(ai_g_wdata),
        .gpio_wstrb(ai_g_wstrb), .gpio_rsp_valid(ai_g_rsp_valid),
        .gpio_rsp_ready(ai_g_rsp_ready), .gpio_rdata(ai_g_rdata), .gpio_error(ai_g_error),
        .timer_req_valid(ai_t_req_valid), .timer_req_ready(ai_t_req_ready),
        .timer_addr(ai_t_addr), .timer_write(ai_t_write), .timer_wdata(ai_t_wdata),
        .timer_wstrb(ai_t_wstrb), .timer_rsp_valid(ai_t_rsp_valid),
        .timer_rsp_ready(ai_t_rsp_ready), .timer_rdata(ai_t_rdata), .timer_error(ai_t_error),
        .accel_req_valid(ai_a_req_valid), .accel_req_ready(ai_a_req_ready),
        .accel_addr(ai_a_addr), .accel_write(ai_a_write), .accel_wdata(ai_a_wdata),
        .accel_wstrb(ai_a_wstrb), .accel_rsp_valid(ai_a_rsp_valid),
        .accel_rsp_ready(ai_a_rsp_ready), .accel_rdata(ai_a_rdata), .accel_error(ai_a_error)
    );

    // 未接入设备：显式 tie-off。ready=1 使请求被立即接受，但 rsp_valid 恒 0 会挂死，
    // 故同时给出 error=1 的一次性响应通道不可行 —— 故改为 ready=1 且由 error 响应。
    // 为避免"永不响应"，这里让 rsp_valid 跟随 req_valid 一拍后由 error 应答：
    // 实现方式见下方 tie_off 说明。实际本项目未选中这些设备，tie-off 仅保证不悬空。
    reg  ai_u_rsp_v, ai_g_rsp_v, ai_t_rsp_v, ai_a_rsp_v;
    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            ai_u_rsp_v <= 1'b0; ai_g_rsp_v <= 1'b0;
            ai_t_rsp_v <= 1'b0; ai_a_rsp_v <= 1'b0;
        end else begin
            ai_u_rsp_v <= ai_u_req_valid && ai_u_req_ready;
            ai_g_rsp_v <= ai_g_req_valid && ai_g_req_ready;
            ai_t_rsp_v <= ai_t_req_valid && ai_t_req_ready;
            ai_a_rsp_v <= ai_a_req_valid && ai_a_req_ready;
        end
    end
    assign ai_u_req_ready = 1'b1;  assign ai_u_rsp_valid = ai_u_rsp_v;  assign ai_u_error = 1'b1;
    assign ai_u_rdata     = 32'b0;
    assign ai_g_req_ready = 1'b1;  assign ai_g_rsp_valid = ai_g_rsp_v;  assign ai_g_error = 1'b1;
    assign ai_g_rdata     = 32'b0;
    assign ai_t_req_ready = 1'b1;  assign ai_t_rsp_valid = ai_t_rsp_v;  assign ai_t_error = 1'b1;
    assign ai_t_rdata     = 32'b0;
    assign ai_a_req_ready = 1'b1;  assign ai_a_rsp_valid = ai_a_rsp_v;  assign ai_a_error = 1'b1;
    assign ai_a_rdata     = 32'b0;

    rom #(.DEPTH(MEM_DEPTH), .AW(MEM_AW), .INIT_FILE(ROM_INIT_FILE)) u_rom_i (
        .clk(clk), .rst(rst),
        .req_valid(ai_rom_req_valid), .req_ready(ai_rom_req_ready), .addr(ai_rom_addr),
        .write(1'b0), .wdata(32'h0), .wstrb(4'h0),
        .rsp_valid(ai_rom_rsp_valid), .rsp_ready(ai_rom_rsp_ready),
        .rdata(ai_rom_rdata), .error(ai_rom_error)
    );

    sram #(.DEPTH(MEM_DEPTH), .AW(MEM_AW)) u_sram_i (
        .clk(clk), .rst(rst),
        .req_valid(ai_sram_req_valid), .req_ready(ai_sram_req_ready), .addr(ai_sram_addr),
        .write(ai_sram_write), .wdata(ai_sram_wdata), .wstrb(ai_sram_wstrb),
        .rsp_valid(ai_sram_rsp_valid), .rsp_ready(ai_sram_rsp_ready),
        .rdata(ai_sram_rdata), .error(ai_sram_error)
    );

    // ---- 上游端口：对外仍是接入前的冻结契约（逐信号等价；仅时序因 Cache 命中/缺失而变） ----
    assign i_req_ready = i_cpu_req_ready;
    assign i_rsp_valid = i_cpu_rsp_valid;
    assign i_rdata     = i_cpu_rdata;
    assign i_error     = i_cpu_error;

    // ---- adapter 口的多路复用：桥（Cache 事务）与 bypass（直通）共用同一个上游口 ----
    // 依据 ADR D-C2：两条路径在同一时刻至多一个有在途事务 ⇒ 只是 mux，不是仲裁器
    // （真仲裁器需要优先级/饥饿规则，而拓扑上不存在竞争）。
    // 发号方是 cache_path 自己：`i_path_drives_adp=1` 表示本次事务走 bypass（它占用 adapter 口），
    // 为 0 表示本次是 Cache 事务（它把 adapter 口让给桥，桥在 S_FILL/S_W_REQ.. 期间驱动）。
    // 四条网各自只有一个驱动者：bypass 侧由 cache_path 驱动、桥侧由 u_bridge_i 驱动，
    // 本模块只做选择（缓存侧口的 ready/响应回程也只回给桥）。
    assign i_br_req_ready  = i_path_drives_adp ? 1'b0 : adp_req_ready;
    // ⚠️ 坑位（**真实缺陷，2026-10-01 修复；症状：`ICACHE_ENABLE=0` 下 I 侧取指链挂死，inst=0**）：
    //    原写作 `assign i_cv_req_ready = i_br_req_ready;`，即"把**桥的** ready 当作 cache_path
    //    adapter 口的 ready"。但 `i_br_req_ready = i_path_drives_adp ? 1'b0 : adp_req_ready`
    //    ——**恰好在 bypass 占用出口（`i_path_drives_adp=1`）时被钳成 0**。
    //    而 `cache_path` 用这个 ready 去算 `up_req_ready`（bypass 分支），于是：
    //      `ICACHE_ENABLE=1` 时走的是 Cache 分支（`cache_req_ready`）⇒ **缺陷被掩盖**；
    //      `ICACHE_ENABLE=0` 时全部走 bypass ⇒ `up_req_ready` 恒 0 ⇒ 请求永不被接受 ⇒ **挂死**。
    //    同时这条路径还引入了网络重命名不清导致的悬空网（探针实测 `adp_req_ready` 为 z），
    //    进一步说明"谁驱动谁"必须逐网对齐。
    //    ⇒ 正确做法：cache_path 的 adapter 口是**适配器出口的统一代表**，其 req_ready
    //       **直接取 adapter 的 `adp_req_ready`**（与桥共用同一个真实 ready），
    //       由 `cache_path` 内部按 `sel_cache` 分发（Cache 分支给 icache、bypass 分支自己用）。
    assign i_cv_req_ready  = adp_req_ready;   // ★ 取真实 adapter ready 转发给 cache_path 出口
    // 桥的 ready 直接取自 adapter，**不绕回 cache_path 的 adapter_rsp_ready**。
    // 注意（ADR-MEM-EXIT-001 起语义已变）：cache_path 的 `adapter_rsp_ready` 现在只是
    // "登记握手"——它仅取决于本侧 skid 是否为空，**不再含下游 ready**，所以历史文档里
    // "它与桥响应成环"的原因已不成立；沿用它仍然危险（会形成**两个消费者**竞争同一笔
    // 响应），故保持"桥自己取、cache_path 不参与"这条分权。
    // 历史环状反压（adapter.rsp_ready → rom.rsp_ready → rom.rsp_valid → 桥响应 → 桥状态 →
    // 桥.rsp_ready）曾把整条响应通路求值成 x、填充永不推进（本项目实测踩到）。
    // ⚠️ 坑位（2026-10-14，PR #52 的 D 侧同型缺陷在 I 侧的独立收口）：
    //    `i_br_rsp_ready` 是 `u_bridge_i.rsp_ready` 的输出端口网，**只能由桥驱动**。
    //    旧写法 `assign i_br_rsp_ready = i_path_drives_adp ? 1'b0 : adp_rsp_valid;`
    //    造成同一根网 2 drivers，并把 adapter 的 `rsp_valid` 当成桥的 `rsp_ready`，
    //    绕开桥“只在 S_R_RSP 接收响应”的状态约束；现有 TB 因 `valid && ready` 掩蔽 x 而难以鉴别。
    //    ⇒ 正确做法：桥输出只由桥驱动；adapter 响应 ready 在下方 owner mux 选择。
    // 同构参考：`SparrowRV-master/rtl/soc/icb_2m8s.v:157`（MIT）按锁存 owner 选择
    // `master_icb_rsp_ready`，而不是把某一路 valid 当 ready。
    // cache_path 的 adapter 口接"Cache 路径的代理"（即 u_bridge_i）：
    // 其 `req_ready` 已在上方直接取真实 adapter ready（★ 见该处坑位注释）；
    // `rsp_valid/data/error` 同样直连 adapter 输出。
    assign i_cv_rsp_valid  = adp_rsp_valid;
    assign i_cv_rsp_rdata  = adp_rsp_rdata;
    assign i_cv_rsp_error  = adp_rsp_error;
    // 谁有权消费 adapter 的响应：Cache 事务期间是桥（其状态机 ready），
    // bypass 事务期间是 cache_path（其 adapter_rsp_ready 现在 = "skid 空" 的登记握手，
    // 见 ADR-MEM-EXIT-001）。两条路径在拓扑上互斥 ⇒ 用 owner mux，不用 OR，也
    // 不能把 adapter 的 rsp_valid 当作 bridge rsp_ready（ADR D-C2：这不是仲裁器）。
    assign i_adp_rsp_ready  = i_path_drives_adp ? ai_byp_rsp_ready : i_br_rsp_ready;
    // bypass 侧要等路径锁确认走的是 bypass 才允许消费（否则会把别人事务的响应吞掉，
    // 见 cache_path 头注 1）。
    assign ai_byp_rsp_ready = i_cv_rsp_ready & i_path_drives_adp;

    assign i_adp_req_valid = i_path_drives_adp ? ai_byp_req_valid : i_br_req_valid;
    assign i_adp_req_addr  = i_path_drives_adp ? ai_byp_req_addr  : i_br_req_addr;
    assign i_adp_req_write = i_path_drives_adp ? ai_byp_req_write : i_br_req_write;
    assign i_adp_req_wdata = i_path_drives_adp ? ai_byp_req_wdata : i_br_req_wdata;
    assign i_adp_req_wstrb = i_path_drives_adp ? ai_byp_req_wstrb : i_br_req_wstrb;
    // 响应回程：桥只在 S_R_RSP/S_W_RSP 取数（空闲时 rsp_ready=0，看到也不消费）
    assign i_br_rsp_valid  = adp_rsp_valid;
    assign i_br_rsp_rdata  = adp_rsp_rdata;
    assign i_br_rsp_error  = adp_rsp_error;
    // ⚠️ 坑位（**真实缺陷，2026-10-01 修复；症状：`ICACHE_ENABLE=0` 下 I 侧取指链完全挂死**）：
    //    这三行曾把 adapter 的响应**又** assign 回 `ai_byp_rsp_*`，而那三个网同时是
    //    `cache_path` 的**输入端口**；`cache_path` 内部自 ADR-MEM-EXIT-001 起已改为由
    //    §3 的 skid **自行生成**响应（`up_rsp_valid` 取 `bypass_skid_valid`），
    //    不再需要外部喂 `bypass_rsp_*`。于是**同一个 net 被"模块输入端口 + 本模块 assign"同时驱动**
    //    ⇒ 双驱动 ⇒ 在仿真里表现为 **z/x**（`i_adp_req_ready` 观测为 z 即此故），
    //    握手判定彻底失效 ⇒ CPU 请求永不被接受（inst=0）。
    //    与 LESSON-001 的"输出端口 + assign 双驱动"是同一类病灶，只是方向反过来（输入端口侧）。
    //    ⇒ 正确做法：**删掉这三行**；`bypass_rsp_*` 端口保留仅为接线兼容（内部已不使用）。
    //    最小复现：`verification/unit/tb_icache_off_min.sv`；四象限见 `scripts/run_perf_quadrant.py`。

    // ==================================================================
    // D 侧：adapter + ROM + SRAM
    // ==================================================================
    wire        ad_rom_req_valid, ad_rom_req_ready, ad_rom_rsp_valid, ad_rom_rsp_ready;
    wire        ad_rom_error;
    wire [31:0] ad_rom_addr, ad_rom_rdata;

    wire        ad_sram_req_valid, ad_sram_req_ready, ad_sram_rsp_valid, ad_sram_rsp_ready;
    wire        ad_sram_write, ad_sram_error;
    wire [31:0] ad_sram_addr, ad_sram_wdata, ad_sram_rdata;
    wire [3:0]  ad_sram_wstrb;

    wire        ad_u_req_valid, ad_u_req_ready, ad_u_rsp_valid, ad_u_rsp_ready, ad_u_error;
    wire        ad_u_write;
    wire [31:0] ad_u_addr, ad_u_wdata, ad_u_rdata;
    wire [3:0]  ad_u_wstrb;
    wire        ad_g_req_valid, ad_g_req_ready, ad_g_rsp_valid, ad_g_rsp_ready, ad_g_error;
    wire        ad_g_write;
    wire [31:0] ad_g_addr, ad_g_wdata, ad_g_rdata;
    wire [3:0]  ad_g_wstrb;
    wire        ad_t_req_valid, ad_t_req_ready, ad_t_rsp_valid, ad_t_rsp_ready, ad_t_error;
    wire        ad_t_write;
    wire [31:0] ad_t_addr, ad_t_wdata, ad_t_rdata;
    wire [3:0]  ad_t_wstrb;
    wire        ad_a_req_valid, ad_a_req_ready, ad_a_rsp_valid, ad_a_rsp_ready, ad_a_error;
    wire        ad_a_write;
    wire [31:0] ad_a_addr, ad_a_wdata, ad_a_rdata;
    wire [3:0]  ad_a_wstrb;

    wire ad_cacheable_d, ad_read_only_d, d_sel_rom;

    // NOTE: u_adapter_d is instantiated after the D-side cache_path/bridge/adapter
    // nets are declared, to avoid implicit-net/use-before-declaration hazards.

    // ==================================================================
    // D 侧 Cache 接入（批 (d-2)，ADR-CACHE-INTEGRATION；与 I 侧同构）
    // ==================================================================
    // 与 I 侧的判据差异（ADR D-C3 的 cacheable 拆分）：
    //   D 侧 cacheable = `ad_cacheable_d`（= addr_decode 的 `sel_sram`，**保持原样不改**）；
    //   即 ROM 与全部 MMIO **永不进入 D-Cache 标签比较**。
    // 批 (d-2) 出口租约修订后的 D 侧硬约束：
    //   · cacheable SRAM store 进入 D-Cache；D-Cache 在 S_WR 经桥写穿 adapter，
    //     命中时按 wstrb 合并更新行，未命中不分配；写错误不得更新行。
    //   · ROM/MMIO store 继续 bypass adapter；写 ROM 必然取得 adapter error，
    //     绝不会变成"静默成功"。
    //   · 任一 store 最终都必须且只到 adapter 一次。
    // ⚠️ 组合环修复：`ad_cacheable_d` 是 adapter 对复用地址的译码输出，不能反过来
    //    决定 adapter 地址 mux（见 cache_path.sv 头注 4.1）；owner 由 d_path_drives_adp
    //    的锁存路径状态/`cache_busy` 生成。
    wire        d_cpu_req_ready, d_cpu_rsp_valid, d_cpu_error;
    wire [31:0] d_cpu_rdata;
    // cache_path ⇄ dcache（单字口 + 读填充口 + 写穿口）
    wire        d_cp_cache_req_valid, d_cp_cache_req_ready;
    wire        d_cp_cache_rsp_valid, d_cp_cache_rsp_ready, d_cp_cache_rsp_error;
    wire [31:0] d_cp_cache_rsp_data;
    wire [31:0] d_cp_line_addr;
    wire        d_cp_mem_read, d_cp_beat_valid, d_cp_beat_ready, d_cp_beat_last, d_cp_beat_error;
    wire [31:0] d_cp_beat_data;
    wire        d_cp_mem_write, d_cp_wr_beat_valid, d_cp_wr_beat_ready, d_cp_wr_beat_error;
    wire [31:0] d_cp_wr_addr, d_cp_wr_beat_data;
    wire [3:0]  d_cp_wr_beat_wstrb;
    wire        d_cp_wr_beat_last;
    wire        d_cache_busy = d_cp_mem_read | d_cp_mem_write;
    // cache_path ⇄ 桥（桥 = Cache 路径的内存侧代理）
    wire        d_br_req_valid, d_br_req_ready, d_br_req_write;
    wire [31:0] d_br_req_addr, d_br_req_wdata, d_br_rsp_rdata;
    wire [3:0]  d_br_req_wstrb;
    wire        d_br_rsp_valid, d_br_rsp_ready, d_br_rsp_error;
    // cache_path 的 adapter 端口（Cache 路径一侧的"虚拟 adapter 口"）
    wire        d_cv_req_valid, d_cv_req_ready, d_cv_req_write;
    wire [31:0] d_cv_req_addr, d_cv_req_wdata, d_cv_rsp_rdata;
    wire [3:0]  d_cv_req_wstrb;
    wire        d_cv_rsp_valid, d_cv_rsp_ready, d_cv_rsp_error;
    // bypass 通路（旁路事务直连 adapter 侧）
    wire        d_byp_req_valid, d_byp_req_write;
    wire [31:0] d_byp_req_addr, d_byp_req_wdata;
    wire [3:0]  d_byp_req_wstrb;
    wire        d_byp_rsp_valid, d_byp_rsp_error, d_byp_rsp_ready;
    wire [31:0] d_byp_rsp_data;
    wire        d_path_drives_adp;
    // adapter 输出端口的专用中间网（只由 u_adapter_d 驱动；见 I 侧说明）
    wire        adp_d_req_ready, adp_d_rsp_valid, adp_d_rsp_error, d_adp_rsp_ready;
    wire [31:0] adp_d_rsp_rdata;
    // adapter 上游请求口（由"桥 / bypass"两路 mux 驱动）
    wire        d_adp_req_valid, d_adp_req_write;
    wire [31:0] d_adp_req_addr, d_adp_req_wdata;
    wire [3:0]  d_adp_req_wstrb;

    mem_map_adapter #(.ACCEL_ENABLE(1'b0)) u_adapter_d (
        .clk(clk), .rst(rst),
        // 与 I 侧同构：adapter 的 req_ready / rsp_* 是输出端口，先落到专用
        // adp_d_* 网，再在下方扇出到桥与 cache_path，避免端口实参与 assign 双驱动。
        .req_valid(d_adp_req_valid), .req_ready(adp_d_req_ready), .addr(d_adp_req_addr),
        .write(d_adp_req_write), .wdata(d_adp_req_wdata), .wstrb(d_adp_req_wstrb),
        .rsp_valid(adp_d_rsp_valid), .rsp_ready(d_adp_rsp_ready),
        .rdata(adp_d_rsp_rdata), .error(adp_d_rsp_error),
        .cacheable(ad_cacheable_d), .read_only(ad_read_only_d), .sel_rom(d_sel_rom),
        .rom_req_valid(ad_rom_req_valid), .rom_req_ready(ad_rom_req_ready),
        .rom_addr(ad_rom_addr), .rom_rsp_valid(ad_rom_rsp_valid),
        .rom_rsp_ready(ad_rom_rsp_ready), .rom_rdata(ad_rom_rdata), .rom_error(ad_rom_error),
        .sram_req_valid(ad_sram_req_valid), .sram_req_ready(ad_sram_req_ready),
        .sram_addr(ad_sram_addr), .sram_write(ad_sram_write), .sram_wdata(ad_sram_wdata),
        .sram_wstrb(ad_sram_wstrb), .sram_rsp_valid(ad_sram_rsp_valid),
        .sram_rsp_ready(ad_sram_rsp_ready), .sram_rdata(ad_sram_rdata), .sram_error(ad_sram_error),
        .uart_req_valid(ad_u_req_valid), .uart_req_ready(ad_u_req_ready),
        .uart_addr(ad_u_addr), .uart_write(ad_u_write), .uart_wdata(ad_u_wdata),
        .uart_wstrb(ad_u_wstrb), .uart_rsp_valid(ad_u_rsp_valid),
        .uart_rsp_ready(ad_u_rsp_ready), .uart_rdata(ad_u_rdata), .uart_error(ad_u_error),
        .gpio_req_valid(ad_g_req_valid), .gpio_req_ready(ad_g_req_ready),
        .gpio_addr(ad_g_addr), .gpio_write(ad_g_write), .gpio_wdata(ad_g_wdata),
        .gpio_wstrb(ad_g_wstrb), .gpio_rsp_valid(ad_g_rsp_valid),
        .gpio_rsp_ready(ad_g_rsp_ready), .gpio_rdata(ad_g_rdata), .gpio_error(ad_g_error),
        .timer_req_valid(ad_t_req_valid), .timer_req_ready(ad_t_req_ready),
        .timer_addr(ad_t_addr), .timer_write(ad_t_write), .timer_wdata(ad_t_wdata),
        .timer_wstrb(ad_t_wstrb), .timer_rsp_valid(ad_t_rsp_valid),
        .timer_rsp_ready(ad_t_rsp_ready), .timer_rdata(ad_t_rdata), .timer_error(ad_t_error),
        .accel_req_valid(ad_a_req_valid), .accel_req_ready(ad_a_req_ready),
        .accel_addr(ad_a_addr), .accel_write(ad_a_write), .accel_wdata(ad_a_wdata),
        .accel_wstrb(ad_a_wstrb), .accel_rsp_valid(ad_a_rsp_valid),
        .accel_rsp_ready(ad_a_rsp_ready), .accel_rdata(ad_a_rdata), .accel_error(ad_a_error)
    );


    cache_path #(.CACHE_WRITES(1'b1)) u_cache_path_d (
        .clk(clk), .rst(rst),
        .cache_en(DCACHE_ENABLE), .cacheable(ad_cacheable_d),
        .cache_busy_i(d_cache_busy),
        .up_req_valid(d_req_valid), .up_req_ready(d_cpu_req_ready),
        .up_req_addr(d_req_addr), .up_write(d_write),
        .up_wdata(d_wdata), .up_wstrb(d_wstrb),
        .up_rsp_valid(d_cpu_rsp_valid), .up_rsp_ready(d_rsp_ready),
        .up_rsp_data(d_cpu_rdata), .up_rsp_error(d_cpu_error),
        .cache_req_valid(d_cp_cache_req_valid), .cache_req_ready(d_cp_cache_req_ready),
        .cache_rsp_valid(d_cp_cache_rsp_valid), .cache_rsp_ready(d_cp_cache_rsp_ready),
        .cache_rsp_data(d_cp_cache_rsp_data), .cache_rsp_error(d_cp_cache_rsp_error),
        // A2b/接线修正：line_addr、mem_read/mem_write、beat_ready、wr_* 输出均由
        // dcache 直接驱动；cache_path 不再重复驱动这些网，避免多驱动。
        .cache_line_addr(), .cache_mem_read(),
        .cache_beat_valid(d_cp_beat_valid), .cache_beat_ready(),
        .cache_beat_data(d_cp_beat_data), .cache_beat_last(d_cp_beat_last),
        .cache_beat_error(d_cp_beat_error),
        .cache_mem_write(), .cache_wr_addr(),
        .cache_wr_beat_valid(), .cache_wr_beat_ready(d_cp_wr_beat_ready),
        .cache_wr_beat_data(), .cache_wr_beat_wstrb(),
        .cache_wr_beat_last(), .cache_wr_beat_error(d_cp_wr_beat_error),
        .bypass_req_valid(d_byp_req_valid), .bypass_req_addr(d_byp_req_addr),
        .bypass_req_write(d_byp_req_write), .bypass_req_wdata(d_byp_req_wdata),
        .bypass_req_wstrb(d_byp_req_wstrb),
        .bypass_rsp_valid(d_byp_rsp_valid), .bypass_rsp_data(d_byp_rsp_data),
        .bypass_rsp_error(d_byp_rsp_error),
        .adapter_req_valid(d_cv_req_valid), .adapter_req_ready(d_cv_req_ready),
        .adapter_req_addr(d_cv_req_addr), .adapter_req_write(d_cv_req_write),
        .adapter_req_wdata(d_cv_req_wdata), .adapter_req_wstrb(d_cv_req_wstrb),
        .adapter_rsp_valid(d_cv_rsp_valid), .adapter_rsp_ready(d_cv_rsp_ready),
        .adapter_rsp_rdata(d_cv_rsp_rdata), .adapter_rsp_error(d_cv_rsp_error),
        .path_is_cache_o(), .path_drives_adapter_o(d_path_drives_adp)
    );

    dcache u_dcache (
        .clk(clk), .rst(rst),
        .req_valid(d_cp_cache_req_valid), .req_ready(d_cp_cache_req_ready),
        // D-Cache CPU store path: only valid when cache_path selects the cacheable
        // SRAM store; ROM/MMIO still bypass via cacheable=0 in cache_path.
        .addr(d_req_addr), .write(d_write), .wdata(d_wdata), .wstrb(d_wstrb),
        .rsp_valid(d_cp_cache_rsp_valid), .rsp_ready(d_cp_cache_rsp_ready),
        .rdata(d_cp_cache_rsp_data), .error(d_cp_cache_rsp_error),
        .line_addr(d_cp_line_addr), .mem_read(d_cp_mem_read),
        .rd_beat_valid(d_cp_beat_valid), .rd_beat_ready(d_cp_beat_ready),
        .rd_beat_data(d_cp_beat_data), .rd_beat_last(d_cp_beat_last),
        .rd_beat_error(d_cp_beat_error),
        .mem_write(d_cp_mem_write), .wr_addr(d_cp_wr_addr),
        .wr_beat_valid(d_cp_wr_beat_valid), .wr_beat_ready(d_cp_wr_beat_ready),
        .wr_beat_data(d_cp_wr_beat_data), .wr_beat_wstrb(d_cp_wr_beat_wstrb),
        .wr_beat_last(d_cp_wr_beat_last), .wr_beat_error(d_cp_wr_beat_error),
        .hit_o(), .stat_hit(), .stat_miss(), .stat_store()
    );

    mem_burst_bridge u_bridge_d (
        .clk(clk), .rst(rst),
        .line_addr(d_cp_line_addr), .mem_read(d_cp_mem_read), .mem_write(d_cp_mem_write),
        .wr_addr(d_cp_wr_addr),
        .rd_beat_valid(d_cp_beat_valid), .rd_beat_ready(d_cp_beat_ready),
        .rd_beat_data(d_cp_beat_data), .rd_beat_last(d_cp_beat_last),
        .rd_beat_error(d_cp_beat_error),
        .wr_beat_valid(d_cp_wr_beat_valid), .wr_beat_ready(d_cp_wr_beat_ready),
        .wr_beat_data(d_cp_wr_beat_data), .wr_beat_wstrb(d_cp_wr_beat_wstrb),
        .wr_beat_last(d_cp_wr_beat_last), .wr_beat_error(d_cp_wr_beat_error),
        .req_valid(d_br_req_valid), .req_ready(d_br_req_ready), .req_addr(d_br_req_addr),
        .req_write(d_br_req_write), .req_wdata(d_br_req_wdata), .req_wstrb(d_br_req_wstrb),
        .rsp_valid(d_br_rsp_valid), .rsp_ready(d_br_rsp_ready),
        .rsp_rdata(d_br_rsp_rdata), .rsp_error(d_br_rsp_error)
    );

    // ---- 「桥 ⇄ adapter」与「bypass ⇄ adapter」的选择（owner 来自 cache_path 锁存状态，
    //      这里只是纯组合 mux；不是通用仲裁器） ----
    assign d_br_req_ready    = d_path_drives_adp ? 1'b0 : adp_d_req_ready;
    // ⚠️ 坑位：`d_br_rsp_ready` 是 `u_bridge_d.rsp_ready` 的输出端口网，**只能由桥驱动**。
    //    旧写法 `assign d_br_rsp_ready = d_path_drives_adp ? 1'b0 : adp_d_rsp_valid;`
    //    造成同一根网 2 drivers，并把 adapter 的 `rsp_valid` 当成桥的 `rsp_ready`
    //    ⇒ 绕开桥“只在 S_R_RSP/S_W_RSP 接收响应”的状态约束；两者在常规时序下偶合，
    //    仿真可能不立刻出错，但结构上已失去单一消费者/单一 driver 保证。
    //    ⇒ 正确做法：桥输出只由桥驱动；adapter 的 rsp_ready 仅在下方的 owner mux 选择。
    //    同构参考：SparrowRV `rtl/soc/icb_2m8s.v` 用锁存 `master_sel_rb` 选择
    //    `master_icb_rsp_ready`（MIT），而不是把某一路 valid 当作 ready。
    // 与 I 侧同构：cache_path 的 adapter 口 ready 必须直接取真实 adapter ready，
    // 不能取桥的 ready（否则 bypass 期间会被钳成 0）。
    assign d_cv_req_ready    = adp_d_req_ready;
    assign d_cv_rsp_valid    = adp_d_rsp_valid;
    assign d_cv_rsp_rdata    = adp_d_rsp_rdata;
    assign d_cv_rsp_error    = adp_d_rsp_error;
    assign d_byp_rsp_ready     = d_cv_rsp_ready & d_path_drives_adp;
    // adapter 响应 ready 由当前 owner 唯一选择：桥 owner 时取桥状态机输出，
    // bypass owner 时取 cache_path 的登记式 ready；不能用 OR，也不能用 adp_d_rsp_valid 代替。
    // （owner 由 cache_path 锁存状态/`cache_busy_i` 产生，事务期间稳定，故不是仲裁器。）
    assign d_adp_rsp_ready   = d_path_drives_adp ? d_byp_rsp_ready : d_br_rsp_ready;

    assign d_adp_req_valid = d_path_drives_adp ? d_byp_req_valid : d_br_req_valid;
    assign d_adp_req_addr  = d_path_drives_adp ? d_byp_req_addr  : d_br_req_addr;
    assign d_adp_req_write = d_path_drives_adp ? d_byp_req_write : d_br_req_write;
    assign d_adp_req_wdata = d_path_drives_adp ? d_byp_req_wdata : d_br_req_wdata;
    assign d_adp_req_wstrb = d_path_drives_adp ? d_byp_req_wstrb : d_br_req_wstrb;
    assign d_br_rsp_valid  = adp_d_rsp_valid;
    assign d_br_rsp_rdata  = adp_d_rsp_rdata;
    assign d_br_rsp_error  = adp_d_rsp_error;
    // 注意：d_byp_rsp_valid/data 是 cache_path 的输入端口，自 ADR-MEM-EXIT-001 起
    // 内部响应由 skid 自行生成，这里不再 assign（否则会双驱动输入端口）。

    // ---- 上游端口：D 侧对外仍是接入前的冻结契约 ----
    assign d_req_ready = d_cpu_req_ready;
    assign d_rsp_valid = d_cpu_rsp_valid;
    assign d_rdata     = d_cpu_rdata;
    assign d_error     = d_cpu_error;


    // D 侧未接入设备（仅 AI 加速器）：同样以"下一拍 error 响应"方式 tie-off，避免挂死
    reg ad_g_rsp_v, ad_t_rsp_v, ad_a_rsp_v;
    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            ad_g_rsp_v <= 1'b0;
            ad_t_rsp_v <= 1'b0; ad_a_rsp_v <= 1'b0;
        end else begin
            ad_g_rsp_v <= ad_g_req_valid && ad_g_req_ready;
            ad_t_rsp_v <= ad_t_req_valid && ad_t_req_ready;
            ad_a_rsp_v <= ad_a_req_valid && ad_a_req_ready;
        end
    end
    assign ad_a_req_ready = 1'b1;  assign ad_a_rsp_valid = ad_a_rsp_v;  assign ad_a_error = 1'b1;
    assign ad_a_rdata     = 32'b0;

    // D 侧 UART：**真实设备**（0x1000_0000 数据 / 0x1000_0004 状态）
    uart #(.DIV(UART_DIV)) u_uart (
        .clk(clk), .rst(rst),
        .req_valid(ad_u_req_valid), .req_ready(ad_u_req_ready), .addr(ad_u_addr),
        .write(ad_u_write), .wdata(ad_u_wdata), .wstrb(ad_u_wstrb),
        .rsp_valid(ad_u_rsp_valid), .rsp_ready(ad_u_rsp_ready),
        .rdata(ad_u_rdata), .error(ad_u_error),
        // NEGCTL：D 侧 UART 回退为 tie-off（TX 恒高 = 永不发帧），T8 必须捕获「无帧」
        .uart_tx(), .uart_rx(uart_rx)
    );

    // D 侧定时器：**真实设备**（0x1000_0020 计数 / 0x1000_0024 比较）
    timer u_timer (
        .clk(clk), .rst(rst),
        .req_valid(ad_t_req_valid), .req_ready(ad_t_req_ready), .addr(ad_t_addr),
        .write(ad_t_write), .wdata(ad_t_wdata), .wstrb(ad_t_wstrb),
        .rsp_valid(ad_t_rsp_valid), .rsp_ready(ad_t_rsp_ready),
        .rdata(ad_t_rdata), .error(ad_t_error),
        .timer_irq(timer_irq)
    );

    // D 侧 GPIO：**真实设备**（0x1000_0010 输出 / 0x1000_0014 输入）
    gpio u_gpio (
        .clk(clk), .rst(rst),
        .req_valid(ad_g_req_valid), .req_ready(ad_g_req_ready), .addr(ad_g_addr),
        .write(ad_g_write), .wdata(ad_g_wdata), .wstrb(ad_g_wstrb),
        .rsp_valid(ad_g_rsp_valid), .rsp_ready(ad_g_rsp_ready),
        .rdata(ad_g_rdata), .error(ad_g_error),
        .gpio_out(gpio_out), .gpio_in(gpio_in)
    );

    rom #(.DEPTH(MEM_DEPTH), .AW(MEM_AW), .INIT_FILE(ROM_INIT_FILE)) u_rom_d (
        .clk(clk), .rst(rst),
        .req_valid(ad_rom_req_valid), .req_ready(ad_rom_req_ready), .addr(ad_rom_addr),
        .write(1'b0), .wdata(32'h0), .wstrb(4'h0),
        .rsp_valid(ad_rom_rsp_valid), .rsp_ready(ad_rom_rsp_ready),
        .rdata(ad_rom_rdata), .error(ad_rom_error)
    );

    sram #(.DEPTH(MEM_DEPTH), .AW(MEM_AW)) u_sram_d (
        .clk(clk), .rst(rst),
        .req_valid(ad_sram_req_valid), .req_ready(ad_sram_req_ready), .addr(ad_sram_addr),
        .write(ad_sram_write), .wdata(ad_sram_wdata), .wstrb(ad_sram_wstrb),
        .rsp_valid(ad_sram_rsp_valid), .rsp_ready(ad_sram_rsp_ready),
        .rdata(ad_sram_rdata), .error(ad_sram_error)
    );

endmodule
