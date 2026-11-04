// =============================================================================
//  kws_in_w_ram.sv  —  KWS 输入缓冲区 RAM（512 字 × 32 位，**1 写 3 读**）
//
//  ★ 为什么单独一个模块（2026-10-25 实测结论，不是风格偏好）
//  ---------------------------------------------------------------------------
//  ADS（PDS 的综前引擎）只有在"**一个 RAM 一个 always_ff、读写都在里面、地址/数据/
//  使能都是端口或纯切片**"的形态下才会打印
//      `I: Sdm-0001: Found Ram <name>, depth=..., width=...`
//  并据此把它映射到 DRM。把同样的数组留在 `kws_mmio` 里（读口分散在多个 always 块、
//  写数据/使能是包装层算出来的表达式、读地址还被 `cond ? 切片 : 0` 钳过位）时，
//  compile 日志里**连一条 `Found Ram` 都没有** ⇒ 按普通触发器处理 ⇒
//  `DFF-inference` 单核跑 30+ 分钟不收敛（内存却恒定在 ~500 MB，这是它的指纹）。
//
//  对照证据（同一台机器、同一 PDS 2025.2）：
//    · `verification/kws/k6/logs/rambe_probe.v`（1 写 1 读，单进程）→ `Found Ram mem,
//      depth=1024, width=8`，秒级完成；
//    · `verification/kws/k6/logs/ram3r_probe.v`（1 写 3 读，三个读口**同一** always 块）
//      → 2022.2 实测 DRM 1.5 / LUT 24 / FF 6。
//  ⇒ 本模块就是探针形态，只是端口按项目的真实需求固定。
//
//  ★ 三条硬约束（改动前请先读）
//  ---------------------------------------------------------------------------
//  1. **没有复位、没有 `initial`**。本器件的 BRAM 不支持初值，一句 `initial` 或
//     复位清零循环就会让它放弃 BRAM 推断。仿真需要的零初值由**测试台**在 time 0
//     直接写 `dut.u_in_w.mem[]` 提供，RAM 本体保持纯净。
//  2. **读是无条件的**：`qN_r <= mem[raN[...]]` 不能包在 `if (re)` 里，也不能写成
//     `qN_r <= ok ? mem[...] : 0`。"越界读给 0 / 给 in_zp" 由包装层用**寄存后的**
//     ok 标志选择。
//  3. **写地址只有一个**（`waddr`），4 个 lane 由 `wbe` 选；否则 ADS 判多写口
//     （`W: Sdm-2010 Not support multi-write simultaneously`）。
//
//  ★ 地址约定：三个读口都是 **字节地址**（`AW+2` 位），模块内部自己取字索引
//  `raN[AW+1:2]` 与字节选择 `raN[1:0]`。
//  ⚠️ 坑位（2026-10-25，C10/C11 抓到）：早一版传的是**字索引**，于是 `sN <= raN[1:0]`
//     取到了字索引的低 2 位（等于 `byte_addr[3:2]`），字节坐标全错 —— 表现为
//     CRC 校验错、0x800 读出的 logit 位置不对。**字节选择只能来自字节地址的低 2 位。**
//
//  ★ 深度为什么是 512（而不是 490）
//  ---------------------------------------------------------------------------
//  `INPUT_BYTES=1960` ⇒ 490 个有效字。补到 512（2^9，2048 字节）之后，三路读地址
//  都是**纯位切片**，任何值都不会越界 ⇒ 包装层不需要再插 `cond ? 切片 : 0` 的钳位
//  mux（那正是探针与本设计最后一处结构差异）。多出的 22 字永不写、永不读；
//  语义边界仍由 `INPUT_BYTES` 控制。
//
//  端口时序：`we/waddr/wbe/wdata/raN` 在 t 拍给，`bN` 在 t+1 拍有效（1 拍）。
// =============================================================================
`default_nettype none

module kws_in_w_ram #(
    parameter integer WORDS = 512,      // 字数（2 的幂 ⇒ 地址是纯切片）
    parameter integer AW    = 9         // log2(WORDS)
)(
    input  wire            clk,

    // ---------------- 唯一写口（字节使能） ----------------
    input  wire            we,
    input  wire [AW-1:0]   waddr,       // 字地址
    input  wire [3:0]      wbe,
    input  wire [31:0]     wdata,

    // ---------------- 三个读口（无条件同步读；**字节地址**） ----------------
    input  wire [AW+1:0]   ra0,         // 0：加速器核的像素读
    input  wire [AW+1:0]   ra1,         // 1：CRC 后台引擎
    input  wire [AW+1:0]   ra2,         // 2：CPU 总线（buffer 窗）

    output wire [7:0]      b0,          // 已寄存的字 + 已寄存的字节选择 → 组合 mux
    output wire [7:0]      b1,
    output wire [7:0]      b2
);
    logic [31:0] mem [0:WORDS-1];

    // 与字数据**同沿**寄存的字节选择位：这样 mux 在寄存器之后，读延迟仍是 1 拍
    logic [31:0] q0_r, q1_r, q2_r;
    logic [1:0]  s0_r, s1_r, s2_r;

    function automatic [7:0] sel_byte(input [31:0] w, input [1:0] s);
        begin
            case (s)
                2'd0:    sel_byte = w[7:0];
                2'd1:    sel_byte = w[15:8];
                2'd2:    sel_byte = w[23:16];
                default: sel_byte = w[31:24];
            endcase
        end
    endfunction

    always_ff @(posedge clk) begin
        // ---- 唯一写口：同一 word 地址 + 4 个字节使能 ----
        if (we) begin
            if (wbe[0]) mem[waddr][7:0]   <= wdata[7:0];
            if (wbe[1]) mem[waddr][15:8]  <= wdata[15:8];
            if (wbe[2]) mem[waddr][23:16] <= wdata[23:16];
            if (wbe[3]) mem[waddr][31:24] <= wdata[31:24];
        end
        // ---- 三个读口：无条件；字索引与字节选择都来自**字节地址** ----
        q0_r <= mem[ra0[AW+1:2]];
        s0_r <= ra0[1:0];
        q1_r <= mem[ra1[AW+1:2]];
        s1_r <= ra1[1:0];
        q2_r <= mem[ra2[AW+1:2]];
        s2_r <= ra2[1:0];
    end

    assign b0 = sel_byte(q0_r, s0_r);
    assign b1 = sel_byte(q1_r, s1_r);
    assign b2 = sel_byte(q2_r, s2_r);

endmodule

`default_nettype wire
