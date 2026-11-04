`timescale 1ns/1ps
// ============================================================================
//  cache_path —— Cache 接入路径选择（bypass mux + 路径保持锁）
//
//  依据：docs/architecture/ADR-CACHE-INTEGRATION.md
//    D-C1：Cache 位于 cpu_mem_subsystem 内部、CPU 冻结单字端口之下（cpu_core_stage1 零改动）；
//    D-C2：每侧只需一个 2:1 选择 mux + "路径保持到响应完成"的锁存，**不是仲裁器**
//          —— 因为 cache 侧与 bypass 侧在上游契约下不可能同时有在途事务；
//    D-C3：bypass 判据 = addr_decode 查询输出 `cacheable`（本模块**不自带地址图**，
//          由调用方例化 addr_decode 并把结果接进来 —— 单一来源原则）。
//
//  ---- 拓扑（每侧一份：I 侧与 D 侧各例化一个本模块）----
//
//                     ┌──── cache（icache/dcache） ──── mem_burst_bridge ───┐
//   CPU 单字端口 ─ mux ┤                                                    ├─> adapter 单字端口
//                     └──────────────── bypass 直连 ───────────────────────┘
//
//  ---- 路径判据 ----
//    sel = cache_en && cacheable && (CACHE_WRITES || !up_write)
//      cache_en ：本侧 Cache 使能（调用方传 ICACHE_ENABLE / DCACHE_ENABLE）
//      CACHE_WRITES ：
//        0 = 写请求永不进 Cache 路径（I 侧默认，保持原行为）；
//        1 = 可缓存写进入 Cache 路径。D 侧用此把 SRAM store 交给 dcache：
//            dcache 在 S_WR 写穿，命中时按 wstrb 合并更新行；未命中不分配。
//            注意：ROM/MMIO 的 store 仍必须由调用方以 cacheable=0 强制走 bypass，
//            否则写 ROM 会变成静默成功（ADR D-C3 安全链）。
//      cacheable：调用方 addr_decode 的 cacheable 输出。I 侧传 `sel_rom | sel_sram`
//                 （ADR D-C3 的显式基线偏离：I 侧 ROM 纳入可缓存），
//                 D 侧传 `sel_sram`。
//
//  ---- 路径保持锁（ADR D-C2 的"锁存"要求）----
//    上游 handshake 成功（up_req_valid && up_req_ready）的**当拍**锁存路径选择，
//    直到本次事务的响应被真正消费（path_done）才允许重新选择。
//    · 选中 Cache：path_done = cache_rsp_valid && up_rsp_ready（响应被取走）
//    · 选中 bypass：path_done = bypass_rsp_valid && bypass_rsp_ready（响应被取走）
//    因此"一次上游请求只对应一次响应、响应恰好被消费一次"在两条路径上分别成立。
//
//  ---- 关键正确性点（实测/推理得出，勿按"看起来更简单"改写）----
//    1. `bypass_rsp_ready` 只允许在**本次事务确实走了 bypass**（path_sel_q==1）时为 1。
//       若在 Cache 事务期间让它恒定跟随 up_rsp_ready，dbg 侧的**陈旧响应**会在响应被取走
//       的同一沿被记录成 path_done，锁在错误时刻释放（同一沿内 bypass 还会把别人的响应
//       当成自己的消费掉）。真实系统里每次 fill 完成后必然存在这样一拍窗口。
//    2. `adapter_req_valid` 在 Cache 事务期间**必须恒 0**：桥自己产生 adapter 请求，
//       若在此处再叠加 cache 的原始单字请求，adapter 会收到两笔请求却只给一次响应，
//       第二笔永远拿不到 rsp → 死锁。
//    3. Cache 事务期间本模块对上游的 req_ready 恒为 0（cache 在 S_FILL/S_RESP 时
//       req_ready=0），故不存在"Cache 未完成时接新请求"的窗口。
//    4. A2b（2026-10-08）：`cache_busy_i` 表示后台 Cache fill/write 仍占用 adapter。
//       此时 Cache 的 CPU 事务锁可以已释放（早响应已消费），但 adapter 口不能切给
//       bypass；bypass 请求在总线忙时由 `up_req_ready=0` 反压。
//    4.1 ⚠️ 出口 owner 不能由 `cacheable` 组合反馈生成。
//       D 侧 `cacheable=sel_sram` 而 bridge 空闲地址 0x0 属于 ROM；若 owner 由
//       `!sel_cache` 组合生成，就形成
//       `ad_cacheable -> sel_cache -> owner -> d_adp_req_addr -> ad_cacheable`
//       的组合环，D 侧第一笔可缓存请求即可能振荡/挂死。故 owner 必须由**已锁存
//       的事务状态**（`path_locked && path_sel_q`）或 `cache_busy_i` 生成；idle 时
//       adapter 默认看 CPU 的 `up_req_addr`，让 cacheable 有稳定输入。
//    4.2 `cache_txn_active` 为 1 时桥是唯一 owner；`adapter_self` 只为 bypass 且
//       必须带 `!sel_cache`，防止 Cache 请求在 handshake 当拍误发 bypass 请求。
//    4. ⚠️ **adapter 的响应必须"无条件登记"，绝不能挂在 up_rsp_ready 上**（ADR-MEM-EXIT-001）。
//       旧写法 `adapter_rsp_ready = bypass_done`（bypass_done 含 up_rsp_ready）与 adapter 内部
//       `slave_rsp_ready = rsp_ready & sel` 直连门控形成**闭环反压**：下游一卡（IF 的 buf_full、
//       流水 hold、重定向 drain 窗口）⇒ rsp_valid 无法握手 ⇒ adapter 的 req_ready 被占住 ⇒
//       **连"把响应吃掉"都做不到，永久死锁**。批 (d-2) 的 D 侧 store 实测复现。
//       正确做法（= cod23 `WbArbiter` 的 ack 只给被授权者 / tinyriscv 从设备不受上游 ready 反压）：
//       响应**先落进 1 深度 skid**（`bypass_skid_*`），再由 skid 面向 CPU；
//       `up_rsp_ready` 只用于**清 skid**，不出现在任何 adapter 握手表达式中。
//       ⚠️ 坑位：出口 rsp_ready 依赖下游 ready ⇒ 闭环反压死锁 ⇒ 响应先登记再交付
//          （见 ADR-MEM-EXIT-001 / 日志 2026-10-01-14）
//
//  实现注意（本项目实测踩过的坑）：
//  - Icarus 10.2：不用 always_comb/always_ff；不在 always @(*) 里使用循环变量。
// ============================================================================

`include "defines.sv"

module cache_path #(
    // 0 = 写请求永不进 Cache 路径（I 侧默认，保持原行为）；
    // 1 = 可缓存写也进入 Cache 路径（D 侧 store-hit/write-through 需要）。
    // 非可缓存地址（ROM/MMIO）仍在调用方由 cacheable=0 强制走 bypass。
    parameter bit CACHE_WRITES = 1'b0
)(
    input  wire        clk,
    input  wire        rst,

    // 本侧 Cache 使能（=0 时整条 Cache 路径被旁路，上游行为与接入前完全一致）
    input  wire        cache_en,
    // 本次请求地址是否可缓存（来自调用方 addr_decode 的查询实例）
    input  wire        cacheable,
    // A2b（2026-10-08）：后台 Cache 事务是否仍占用内存侧 adapter。
    // 置 1 时：桥仍保有 adapter 口，bypass 不得抢端口；走 Cache 的请求仍可由
    // cache_req_ready 决定是否提前服务（icache 的 early-restart / fill-buffer 供数）。
    input  wire        cache_busy_i,

    // ---------------- 上游：CPU 单字端口（冻结契约） ----------------
    input  wire        up_req_valid,
    output wire        up_req_ready,
    input  wire [31:0] up_req_addr,
    input  wire        up_write,
    input  wire [31:0] up_wdata,
    input  wire [3:0]  up_wstrb,
    output wire        up_rsp_valid,
    input  wire        up_rsp_ready,
    output wire [31:0] up_rsp_data,
    output wire        up_rsp_error,

    // ---------------- Cache 侧 ----------------
    // 单字端口（与上游同构）
    output wire        cache_req_valid,
    input  wire        cache_req_ready,
    input  wire        cache_rsp_valid,
    output wire        cache_rsp_ready,
    input  wire [31:0] cache_rsp_data,
    input  wire        cache_rsp_error,
    // 读突发填充（→ mem_burst_bridge 读方向）
    output wire [31:0] cache_line_addr,
    output wire        cache_mem_read,
    input  wire        cache_beat_valid,
    output wire        cache_beat_ready,
    input  wire [31:0] cache_beat_data,
    input  wire        cache_beat_last,
    input  wire        cache_beat_error,
    // 写穿（→ mem_burst_bridge 写方向；I 侧固定接 0）
    output wire        cache_mem_write,
    output wire [31:0] cache_wr_addr,
    output wire        cache_wr_beat_valid,
    input  wire        cache_wr_beat_ready,
    output wire [31:0] cache_wr_beat_data,
    output wire [3:0]  cache_wr_beat_wstrb,
    output wire        cache_wr_beat_last,
    input  wire        cache_wr_beat_error,

    // ---------------- bypass 侧（→ adapter 单字端口） ----------------
    output wire        bypass_req_valid,
    output wire [31:0] bypass_req_addr,
    output wire        bypass_req_write,
    output wire [31:0] bypass_req_wdata,
    output wire [3:0]  bypass_req_wstrb,
    input  wire        bypass_rsp_valid,
    input  wire [31:0] bypass_rsp_data,
    input  wire        bypass_rsp_error,

    // ---------------- adapter 单字端口（统一出口） ----------------
    output wire        adapter_req_valid,
    input  wire        adapter_req_ready,
    output wire [31:0] adapter_req_addr,
    output wire        adapter_req_write,
    output wire [31:0] adapter_req_wdata,
    output wire [3:0]  adapter_req_wstrb,
    input  wire        adapter_rsp_valid,
    output wire        adapter_rsp_ready,
    input  wire [31:0] adapter_rsp_rdata,
    input  wire        adapter_rsp_error,

    // ---------------- 观测 ----------------
    output wire        path_is_cache_o,     // 当前事务走 Cache 路径（供 TB/ILA 观测）
    output wire        path_drives_adapter_o // 本模块是否在用 adapter 端口（=0 ⇒ 桥可用）
);

    // ---------------------------------------------------------------
    // 1. 路径判据（组合）
    // ---------------------------------------------------------------
    wire sel_cache_now = cache_en && cacheable && (CACHE_WRITES || !up_write);

    // ---------------------------------------------------------------
    // 2. 路径保持锁
    //    path_locked=0：空闲，本拍的选择即 sel_cache_now
    //    path_locked=1：事务在途，选择保持 path_sel_q
    // ---------------------------------------------------------------
    reg  path_locked;
    reg  path_sel_q;          // 1 = 本次事务走 Cache 路径

    // 本拍生效的选择：空闲时看新鲜判据，锁定期看锁存值。
    // 注意：请求被接受的**当拍**仍处于空闲态，故组合值此刻已是最终值，响应组合 mux
    // 与之同拍一致（无需等一拍）。
    wire sel_cache = path_locked ? path_sel_q : sel_cache_now;

    wire up_req_fire = up_req_valid && up_req_ready;

    // ---------------------------------------------------------------
    // 3. 响应登记（bypass 分支的 1 深度 skid）与路径完成
    //    ⚠️ 见头注 4：bypass 响应必须无条件被 adapter 交付给我方（落进 skid），
    //    **不得**让 adapter_rsp_ready 依赖 up_rsp_ready —— 否则闭环反压死锁。
    // ---------------------------------------------------------------
    reg         bypass_skid_valid;
    reg  [31:0] bypass_skid_data;
    reg         bypass_skid_error;

    // A2b/批 (d-2) owner 规则（见头注 4.1/4.2）：
    //   · Cache 事务已锁存，或后台 Cache 仍占用 adapter ⇒ 桥是唯一 owner；
    //   · 其余空闲/纯 bypass 周期 ⇒ 本模块（bypass）是 owner。
    // 关键：owner 只看**寄存器状态/cache_busy_i**，不得看 `sel_cache` 组合值；
    // idle 时 `adapter_self=1`，让 adapter 译码的是 CPU 的 up_req_addr，
    // 从而切断 `cacheable → owner → adapter.addr → cacheable` 组合环。
    wire cache_txn_active = path_locked && path_sel_q;
    // NEGCTL(A2b 端口租用)：忽略后台 fill 占用，bypass 会抢走 adapter 口
    //   ⇒ B4/B5 必须捕获（cache_path_exit 的端口保持判据）。
    wire adapter_self      = !cache_txn_active; // NEGCTL busyignore

    // adapter 响应被本模块取走（登记）——**不含任何下游 ready**
    // 只有本次生效 sel_cache=0 的 bypass 事务才允许登记，避免 Cache handshake
    // 同拍误吞 bridge 的响应。
    wire bypass_land  = adapter_self && !sel_cache &&
                        adapter_rsp_valid && !bypass_skid_valid;
    // skid → CPU 的交付
    wire bypass_give  = bypass_skid_valid && up_rsp_ready;

    wire cache_done  = cache_rsp_valid && up_rsp_ready;
    // bypass 事务完成的判据 = skid 空（响应已被 CPU 取走）。
    // 用"skid 空"而非"bypass_give 那一拍"：路径锁因此天然覆盖到响应交付完成，
    // 且解锁后 skid 必为空，不会把陈旧响应留给下一笔事务。
    wire bypass_done = !bypass_skid_valid;

    wire path_done = path_locked ? (path_sel_q ? cache_done : bypass_done) : 1'b0;

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            bypass_skid_valid <= 1'b0;
            bypass_skid_data  <= 32'b0;
            bypass_skid_error <= 1'b0;
        end else begin
            if (bypass_land) begin
                bypass_skid_valid <= 1'b1;
                bypass_skid_data  <= adapter_rsp_rdata;
                bypass_skid_error <= adapter_rsp_error;
            end else if (bypass_give) begin
                bypass_skid_valid <= 1'b0;
            end
        end
    end

    // 响应取走的同一沿即可解锁（下一拍接新请求），（sel, response）自洽：
    // _q 落后一拍时的 sel 仍指向本次已完成的路径，而那时该路径不可能已有新响应。
    wire unlock_now = path_locked && path_done;

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            path_locked <= 1'b0;
            path_sel_q   <= 1'b0;
        end else if (unlock_now) begin
            path_locked <= 1'b0;
        end else if (!path_locked && up_req_fire) begin
            path_locked <= 1'b1;
            path_sel_q   <= sel_cache_now;
        end
    end

    // ---------------------------------------------------------------
    // 4. 上游请求多路分发
    // ---------------------------------------------------------------
    // 4.1 → Cache 侧：仅在选中 Cache 路径时呈现。
    // CACHE_WRITES=0 时本模块不把写送进 Cache；D 侧 CACHE_WRITES=1 时写使能/数据/
    // strobe 由调用方直接接到 dcache 的同构单字端口（CPU 接口不变）。
    assign cache_req_valid = sel_cache && up_req_valid;
    assign cache_rsp_ready = up_rsp_ready & sel_cache;
    assign cache_line_addr    = {up_req_addr[31:4], 4'b0};
    assign cache_beat_ready   = 1'b1;   // 数据有效语义：cache 在 S_FILL 期间恒可接收
    assign cache_wr_addr      = 32'b0;
    assign cache_wr_beat_valid= 1'b0;
    assign cache_wr_beat_data = 32'b0;
    assign cache_wr_beat_wstrb= 4'b0;
    assign cache_wr_beat_last = 1'b0;

    // Cache 事务 handshake 当拍 owner 仍可能是 idle 的 adapter_self=1，但此时
    // `sel_cache=1`，必须禁止 bypass 口发请求；否则会与 dcache 同时看到请求。
    assign bypass_req_valid = adapter_self && !sel_cache && up_req_valid;
    assign bypass_req_addr  = up_req_addr;
    assign bypass_req_write = up_write;
    assign bypass_req_wdata = up_wdata;
    assign bypass_req_wstrb = up_wstrb;

    // 4.2 上游 req_ready：本次生效路径的 ready（路径锁定期内不再接受新请求）
    //     ⚠️ 说明（2026-10-01）：曾试过把"锁定期一律 req_ready=0"作为 `ICACHE_ENABLE=0` 挂死的修法，
    //    但未在完整子系统上验证出收益，为避免影响**已验证的 `ICACHE_ENABLE=1` 路径**，
    //    本批保持"按生效路径取 ready"的原语义，仅在 `path_locked` 时收紧（与 §3 的
    //    "skid 无条件登记"配套：响应不会因不接受新请求而丢）。
    assign up_req_ready = path_locked ? 1'b0
                                      : (sel_cache ? cache_req_ready
                                                   : (cache_busy_i ? 1'b0 : adapter_req_ready));

    // 4.3 上游响应：Cache 分支直通；**bypass 分支取自登记 skid**（见 §3 与头注 4）
    assign up_rsp_valid = sel_cache ? cache_rsp_valid      : bypass_skid_valid;
    assign up_rsp_data  = sel_cache ? cache_rsp_data       : bypass_skid_data;
    assign up_rsp_error = sel_cache ? cache_rsp_error      : bypass_skid_error;

    // ---------------------------------------------------------------
    // 5. adapter 统一出口
    //    分成两个"租用方"，owner 由锁存路径状态发号：
    //      · bypass 事务：adapter_self=1，本模块自己直通驱动 adapter 口；
    //      · Cache 事务 ：cache_txn_active=1，adapter_self=0，**把口让给内存侧代理**
    //                     （mem_burst_bridge），代理用 `!path_drives_adapter_o`
    //                     作为自己的使能。
    //    使能互斥保证同一时刻只有一个驱动者 ⇒ 是 mux/租约，不是通用仲裁器（ADR D-C2）。
    //    ⚠️ owner 不能写回 `sel_cache` 组合值，否则 D 侧形成组合环（见头注 4.1）。
    // ---------------------------------------------------------------
    // ⚠️ 坑位（**真实缺陷，2026-10-01 修复；症状：`ICACHE_ENABLE=0` 下取指链完全挂死**）：
    //    原先写作 `adapter_self = !sel_cache && up_req_valid`，即"只有上游有效请求时才占用出口"。
    //    但 `up_req_ready = sel_cache ? cache_req_ready : adapter_req_ready` 会在**空闲且 cache_en=0**
    //    时直接承认请求（`adapter_req_ready` 常为 1）⇒ 路径锁把本笔锁成 `path_sel_q=0`（= Cache
    //    事务），而此刻 `up_req_valid` 已撤销、`adapter_req_valid` 回到 0 ⇒ **adapter 从未收到这笔
    //    请求**，此后只在等 `cache_rsp_valid` ⇒ **响应永不到来，永久死锁**（CPU 侧表现为"请求被
    //    0 拍接受，但永远没响应"= **假握手**）。
    //    根因：**"出口占用权"缺一条兜底** —— 只要本侧**没有真正可用的 Cache 路径**（`!sel_cache`），
    //    就必须由 bypass 持有 adapter 出口，**与 `up_req_valid` 无关**（"占位"与"有请求"是两件事）。
    //    最小复现：`verification/unit/tb_icache_off_min.sv`（`cache_en=0` + adapter + ROM，4 笔全挂）。
    //    历史所有 TB 都跑 `ICACHE_ENABLE=1`，故该"回退开关"从未被验证（AGENTS.md §7.8）。
    wire byp_req_v    = adapter_self && !sel_cache && up_req_valid;  // 真正呈现给 adapter 的请求有效

    assign path_drives_adapter_o = adapter_self;

    assign adapter_req_valid = byp_req_v;
    assign adapter_req_addr  = bypass_req_addr;
    assign adapter_req_write = bypass_req_write;
    assign adapter_req_wdata = bypass_req_wdata;
    assign adapter_req_wstrb = bypass_req_wstrb;
    // 5.2 adapter 响应侧：**登记式消费**（ADR-MEM-EXIT-001 的 E1/E2）
    //     `adapter_rsp_ready` 只与"skid 是否为空"有关，**绝不出现 up_rsp_ready**。
    //     ⚠️ 坑位：adapter 的响应 ready **不在端口表里**——它由本模块的
    //     `adapter_rsp_ready` 直接充当（`mem_map_adapter` 内部是 `slave_rsp_ready =
    //     rsp_ready & sel` 直连门控）。所以这里**不得**再给 `bypass_rsp_ready` 赋值
    //     （该名字不是端口，Icarus 会报 "port is not a port of u_cp"）。
    //     登记动作由 §3 的 `bypass_land` 完成，取走的是 `adapter_rsp_valid/rdata/error`。
`ifdef TB_MUTATE_NO_SKID
    // ⚠️ 坑位（**仅供验证使用的反向突变，禁止在正常构建中定义 TB_MUTATE_NO_SKID**）：
    //    这里恢复成旧式的"响应消费依赖下游 ready"实现，用来证明
    //    verification/unit/tb_cache_path_exit.sv 真的具备鉴别力（B2 必须挂死/报错）。
    //    正常运行路径走下面的正式实现。见 ADR-MEM-EXIT-001 §4 E1。
    assign adapter_rsp_ready = adapter_self ? 1'b0
                                            : (bypass_skid_valid ? 1'b0 : up_rsp_ready);
`else
    assign adapter_rsp_ready = adapter_self && !sel_cache && !bypass_skid_valid;
`endif



    assign path_is_cache_o = sel_cache;

`ifndef CACHE_PATH_NO_ASSERT
    // ---------------- 契约断言（本地宏控制，不依赖外部 +define） ----------------
    // 说明：断言用的是**组合**条件，使能（用当前生效的 sel_cache 与 path_locked）保证
    // 结论与使能同拍自洽，不需要打拍。失败只打印、不 $fatal —— 与 icache/dcache/bridge
    // 既有风格一致，由 TB 侧把这些打印纳入 PASS/FAIL 统计。
    reg [255:0] cp_assert_fail;      // 供 TB 观测（非 0 表示曾违反契约）

    always @(posedge clk) begin
        if (rst == `RstEnable) cp_assert_fail <= 256'b0;
        else begin
            // A1 上游 handshake 的那一刻，生效路径的 ready 必须为 1（否则"接受"是假接受）
            if (up_req_valid && up_req_ready &&
                !(sel_cache ? cache_req_ready : adapter_req_ready)) begin
                cp_assert_fail[0] <= 1'b1;
                $display("ASSERT-FAIL cache_path A1: handshake 而当拍生效路径 ready=0");
            end
            // A2 Cache 事务在途（尚未给出响应）时，不得向上游声称可接收新请求
            if (path_locked && path_sel_q && up_req_valid && up_req_ready && !cache_rsp_valid) begin
                cp_assert_fail[1] <= 1'b1;
                $display("ASSERT-FAIL cache_path A2: Cache 事务未完成即接受了新上游请求");
            end
            // A3 Cache 事务期间 adapter 请求线必须为 0（否则 adapter 收到多余请求而无人取响应）
            if (path_locked && path_sel_q && adapter_req_valid) begin
                cp_assert_fail[2] <= 1'b1;
                $display("ASSERT-FAIL cache_path A3: Cache 事务期间 adapter_req_valid 必须为 0");
            end
            // A4 同一拍不得同时出现两条路径的响应（Cache 直通 vs bypass 登记入 skid）
            if (cache_rsp_valid && bypass_land) begin
                cp_assert_fail[3] <= 1'b1;
                $display("ASSERT-FAIL cache_path A4: Cache 与 bypass 同拍响应（拓扑不应发生）");
            end
            // A5 bypass 事务期间不得消费 Cache 响应
            if (path_locked && !path_sel_q && cache_rsp_ready) begin
                cp_assert_fail[4] <= 1'b1;
                $display("ASSERT-FAIL cache_path A5: bypass 事务期间消费了 Cache 响应");
            end
            // A6（ADR-MEM-EXIT-001 E3）锁定期内 skid 不得被同一笔事务二次登记
            //    （重复登记 = adapter 给了一次响应却被吃掉两次 / 或响应被覆盖）
            if (bypass_land && bypass_skid_valid) begin
                cp_assert_fail[5] <= 1'b1;
                $display("ASSERT-FAIL cache_path A6: 已登记未取走时又发生了一次 bypass 响应登记");
            end
            // A7 登记的响应在 CPU 取走前必须持续有效（不得丢响应）
            if (bypass_skid_valid && !up_rsp_valid) begin
                cp_assert_fail[6] <= 1'b1;
                $display("ASSERT-FAIL cache_path A7: skid 有已登记响应但未呈现给上游");
            end
        end
    end
`endif

endmodule
