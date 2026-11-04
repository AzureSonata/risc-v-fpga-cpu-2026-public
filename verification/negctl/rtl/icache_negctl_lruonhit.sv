// ============================================================================
//        I-Cache（指令 Cache）—— 只读、两路组相联、突发填充
//
//        依据：docs/architecture/TECHNICAL_BASELINE.md
//          §「已冻结主方案」Cache 行：
//            「Stage2：I/D 各 2 KiB，2-way，64 sets，16 B line，1-bit LRU；
//              I 为只读，D 为 write-through/no-write-allocate，
//              miss 用 4 个 32-bit beat burst fill」
//          §「分支、Cache 与异常接入」：
//            「Cache 位于 CPU 单字侧和 memory-map adapter 之间：MMIO/ROM bypass；
//              I-cache 只读填充；…Cache miss 锁定一条 CPU 请求，完成 4 beat fill 后再响应；
//              在 CPU 未收响应前不接新请求。替换使用每 set 一位 LRU，复位 invalid。
//              这样 Stage1 的 CPU 端口无需重写。」

//
//        几何：SETS=64 × WAYS=2 × LINE_BYTES=16（4 字）= 2048 B = 2 KiB/路
//        索引：set = addr[SET_IDX_W+3 : 4]（默认 addr[9:4]）
//              word = addr[3:2]，tag = addr[31 : SET_IDX_W+4]（默认 22 位）
//
//        ---- CPU 侧（冻结单字契约，与 Stage1 完全一致）----
//        req_valid/req_ready、addr、write/wdata/wstrb、rsp_valid/rsp_ready、rdata/error。
//        一次请求接受只对应一次响应；`write` 对本模块非法 → 以 error 响应（防御性，
//        MMIO/ROM 的 bypass 与写路径由上层负责，I 端口不应出现写）。
//
//        ---- 内存侧（基线 burst 包）----
//        line_addr（行地址，16 B 对齐）、read/write、beat_valid/ready、data、last、error。
//        本项目采用"数据有效"握手：读突发时**内存**驱动 beat_valid/beat_data/beat_last/
//        beat_error，本模块在可接收时拉高 beat_ready；一次突发恰好 4 beat，
//        第 4 beat 必须 beat_last=1。约定说明见 docs/architecture/ADR-CACHE.md。
//        本模块只发读（mem_read=1、mem_write=0）。
//
//        复位：valid 全清（invalid），LRU 清 0。
// ============================================================================

`include "defines.sv"

module icache #(
    parameter integer SETS       = 64,
    parameter integer WAYS       = 2,
    parameter integer LINE_WORDS = 4          // 16 B / 4 B
)(
    input  wire         clk,
    input  wire         rst,

    // ---------------- CPU 单字端口 ----------------
    input  wire         req_valid,
    output wire         req_ready,
    input  wire [31:0]  addr,
    input  wire         write,
    input  wire [31:0]  wdata,
    input  wire [3:0]   wstrb,

    output reg          rsp_valid,
    input  wire         rsp_ready,
    output reg  [31:0]  rdata,
    output reg          error,

    // ---------------- 内存侧 burst ----------------
    output wire [31:0]  line_addr,
    output wire         mem_read,
    output wire         mem_write,
    input  wire         beat_valid,
    output wire         beat_ready,
    input  wire [31:0]  beat_data,
    input  wire         beat_last,
    input  wire         beat_error,

    // ---------------- 观测 ----------------
    output wire         hit_o,
    output reg  [31:0]  stat_hit,
    output reg  [31:0]  stat_miss
);

    localparam integer SET_IDX_W = $clog2(SETS);
    localparam integer WORD_W    = $clog2(LINE_WORDS);
    localparam integer TAG_W     = 32 - SET_IDX_W - 2 - WORD_W;
    localparam integer ENTRIES   = SETS * WAYS;

    // ---------------- 存储阵列 ----------------
    reg [TAG_W-1:0] tag   [0:ENTRIES-1];
    reg             valid [0:ENTRIES-1];
    reg [31:0]      line  [0:ENTRIES*LINE_WORDS-1];
    reg             lru   [0:SETS-1];

    // ---------------- 请求分解（组合） ----------------
    wire [SET_IDX_W-1:0] req_set  = addr[SET_IDX_W+3 : 4];
    wire [WORD_W-1:0]    req_word = addr[3+WORD_W-1 : 2];
    wire [TAG_W-1:0]     req_tag  = addr[31 : SET_IDX_W+4];

    // 显式展开 WAYS=2（冻结规格即两路），**不在 always @(*) 中使用循环变量**：
    // Icarus 会把 always @(*) 内被读写的循环变量纳入敏感列表，导致同一时刻
    // 反复自触发、仿真零延迟死循环（本项目实测踩坑）。integer i 只用于时钟块。
    wire [WAYS-1:0] wv = { valid[req_set*WAYS + 1], valid[req_set*WAYS + 0] };
    wire [WAYS-1:0] wh = { (valid[req_set*WAYS + 1] && (tag[req_set*WAYS + 1] == req_tag)),
                           (valid[req_set*WAYS + 0] && (tag[req_set*WAYS + 0] == req_tag)) };

    wire any_hit = (wh != {WAYS{1'b0}});
    assign hit_o = any_hit;

    // 命中路：两路 tag 唯一，不会同时命中（WAY=2）
    wire hit_way0 = wh[0];
    wire [31:0] hit_data = hit_way0
                         ? line[(req_set*WAYS + 0)*LINE_WORDS + req_word]
                         : line[(req_set*WAYS + 1)*LINE_WORDS + req_word];

    // 替换路：优先填无效路，否则按 LRU
    wire [31:0] victim_way = (!wv[0]) ? 32'd0
                           : ((!wv[1]) ? 32'd1 : {31'b0, lru[req_set]});

    // ---------------- 状态机 ----------------
    localparam [1:0] S_IDLE = 2'b00, S_FILL = 2'b01, S_RESP = 2'b10;
    reg [1:0] state;
    // 循环变量仅供**时钟块**使用（复位清零阵列、整行写入），
    // 绝不能在 always @(*) 中使用（见上文说明）。
    integer i;

    reg [SET_IDX_W-1:0] fill_set;
    reg [TAG_W-1:0]     fill_tag;
    reg [31:0]          fill_way;
    reg [WORD_W-1:0]    fill_word;
    reg [31:0]          fill_buf [0:LINE_WORDS-1];
    reg [2:0]           beat_cnt;        // 已接收 beat 数 0..4
    reg                 fill_err;
    // A2b-Conservative（2026-10-08）：
    //   - fill_rvd_mask：哪几笔 beat 已经到达；
    //   - fill_err_mask：逐 word 的错误，供同 fill 行后续请求使用；
    //   - fill_rsp_sent ：本次 fill 的“当前响应”是否已经发出（不重复响应）。
    reg [LINE_WORDS-1:0] fill_rvd_mask;
    reg [LINE_WORDS-1:0] fill_err_mask;
    reg                  fill_rsp_sent;

    wire beat_fire = beat_valid && beat_ready;
    wire rsp_take  = rsp_valid && rsp_ready;
    // 本拍是否正在产生“本次 fill 的当前响应”（需求 word 的首笔到达）。
    wire fill_resp_now = beat_fire && !fill_rsp_sent && (beat_cnt == fill_word);

    // 同 fill 行请求：仅当本请求地址正是正在填充的行时才可提前服务。
    // 注意：compare 的位段与 fill_set/fill_tag 同源；state 不为 S_FILL 时不会选中。
    wire fill_line_match = (state == S_FILL) &&
                           (req_set  == fill_set) &&
                           (req_tag  == fill_tag);
    wire fill_word_avail = fill_rvd_mask[req_word];
    // 约束：
    //   1) 当前响应未被取走前不得接新请求；
    //   2) 只有本 fill 的“当前响应”已经发过并被消费后，才允许同 fill 行续取；
    //   3) 本 fill 至今无错（出现 error 后不再从残行供数，等整行结束再重新缺失）；
    //   4) fill 本拍收尾（beat_last）时留一个气泡，避免与新花名响应同拍竞争。
    wire fill_serve_ok = (state == S_FILL) && !rsp_valid && fill_rsp_sent &&
                         !fill_err && fill_line_match && fill_word_avail;

    assign req_ready  = (state == S_IDLE && !rsp_valid) || fill_serve_ok;
    assign beat_ready = (state == S_FILL);          // 填充期间恒可接收
    assign mem_read   = (state == S_FILL);
    assign mem_write  = 1'b0;
    // 填充期间 line_addr 必须来自锁存的 fill_set/fill_tag：
    // 若继续用 addr，会被 IF 的下一 PC 覆盖，导致 bridge 抓错行。
    assign line_addr  = (state == S_FILL)
                      ? {fill_tag, fill_set, 4'b0}
                      : {addr[31:4], 4'b0};

    // 关键：一次请求接受只对应一次响应；且响应未被取走前不接新请求
    wire accept = req_valid && req_ready && !rsp_valid;

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            state         <= S_IDLE;
            rsp_valid     <= 1'b0;
            rdata         <= `ZeroWord;
            error         <= 1'b0;
            beat_cnt      <= 3'd0;
            fill_err      <= 1'b0;
            fill_rvd_mask <= {LINE_WORDS{1'b0}};
            fill_err_mask <= {LINE_WORDS{1'b0}};
            fill_rsp_sent <= 1'b0;
            stat_hit      <= 32'b0;
            stat_miss     <= 32'b0;
            for (i = 0; i < ENTRIES; i = i + 1) valid[i] <= 1'b0;
            for (i = 0; i < SETS; i = i + 1)    lru[i]   <= 1'b0;
        end else begin
            // 全局响应消费：early 响应与普通 S_RESP 共用同一握手清位。
            // 状态分支只负责“产生”响应，不在这里重复清位。
            if (rsp_take) rsp_valid <= 1'b0;

            case (state)
                // ------------------------------------------------------
                S_IDLE: begin
                    if (accept) begin
                        if (write) begin
                            // I-Cache 不接受写：以 error 响应，不产生副作用
                            rsp_valid <= 1'b1;
                            rdata     <= `ZeroWord;
                            error     <= 1'b1;
                            state     <= S_RESP;
                        end else if (any_hit) begin
                            rsp_valid <= 1'b1;
                            rdata     <= hit_data;
                            error     <= 1'b0;
                            state     <= S_RESP;
                            stat_hit  <= stat_hit + 32'b1;
                            // 命中即更新 LRU：**被命中的路变为 MRU**，另一路才是下次牺牲者。
                            // lru[set] 存放"下次要替换的路号"，故 lru = ~命中路号
                            // （WAY=2：命中 way0 → lru=1 牺牲 way1；命中 way1 → lru=0 牺牲 way0）。
                            lru[req_set] <= lru[req_set];   // NEGCTL: 命中不更新 LRU
                        end else begin
                            // 缺失：锁定本条请求并开始 4 beat 填充
                            fill_set      <= req_set;
                            fill_tag      <= req_tag;
                            fill_way      <= victim_way;
                            // PDS RAM inference permits one line-array write port; invalidate the
                            // victim before beat writes so a failed fill cannot expose partial data.
                            valid[req_set*WAYS + victim_way] <= 1'b0;
                            fill_word     <= req_word;
                            beat_cnt      <= 3'd0;
                            fill_err      <= 1'b0;
                            fill_rvd_mask <= {LINE_WORDS{1'b0}};
                            fill_err_mask <= {LINE_WORDS{1'b0}};
                            fill_rsp_sent <= 1'b0;
                            state         <= S_FILL;
                            stat_miss     <= stat_miss + 32'b1;
                        end
                    end
                end
                // ------------------------------------------------------
                S_FILL: begin
                    // 1) 收 beat（无论本拍是否同时在服务同 fill 行请求）
                    if (beat_fire) begin
                        fill_buf[beat_cnt]      <= beat_data;
                        // One dynamically indexed write per beat keeps this inferred memory
                        // single-port; see LESSON-001 T10 for the PDS multiport failure evidence.
                        line[(fill_set*WAYS + fill_way)*LINE_WORDS + beat_cnt] <= beat_data;
                        fill_rvd_mask[beat_cnt] <= 1'b1;
                        fill_err_mask[beat_cnt] <= beat_error;
                        if (beat_error) fill_err <= 1'b1;

                        // 早响应：需求 word 到达即发出，不再等 beat_last
                        if (fill_resp_now) begin
                            rsp_valid     <= 1'b1;
                            rdata         <= beat_data;
                            error         <= beat_error;
                            fill_rsp_sent <= 1'b1;
                        end

                        // 末 beat：整行无错才分配；响应只发一次
                        if (beat_last) begin
                            if (!(fill_err || beat_error)) begin
                                tag  [fill_set*WAYS + fill_way] <= fill_tag;
                                valid[fill_set*WAYS + fill_way] <= 1'b1;
                                lru[fill_set] <= ~fill_way[0];
                            end
                            beat_cnt <= 3'd0;
                        end else begin
                            beat_cnt <= beat_cnt + 3'd1;
                        end
                    end

                    // 2) 同 fill 行续取（可与 beat_fire 同拍；req_word 必须已到达）
                    if (accept) begin
                        if (write) begin
                            // I 侧不应出现写；防御性 error，不改变 fill 流程
                            rsp_valid <= 1'b1;
                            rdata     <= `ZeroWord;
                            error     <= 1'b1;
                        end else begin
                            rsp_valid <= 1'b1;
                            rdata     <= fill_buf[req_word];
                            error     <= fill_err_mask[req_word];
                            // 同 fill 行供数：对软件表现为一次命中（未再访问外部存储）
                            stat_hit  <= stat_hit + 32'b1;
                        end
                        // 若本拍同时是末 beat，则本次 fill 收尾、响应进 S_RESP；否则继续 S_FILL
                        state <= (beat_fire && beat_last) ? S_RESP : S_FILL;
                    end else if (beat_fire && beat_last) begin
                        // 没有新的同 fill 行请求，按本次 fill 的响应状态收尾
                        if (fill_rsp_sent || fill_resp_now) begin
                            if (fill_resp_now) begin
                                // 本次响应本拍刚产生 → 下一拍 S_RESP 保持
                                state <= S_RESP;
                            end else if (rsp_valid && !rsp_take) begin
                                // 早响应曾产生且尚未被取走 → S_RESP 保持
                                state <= S_RESP;
                            end else begin
                                // 早响应已消费，或本拍同拍消费 → 直接回 IDLE
                                state <= S_IDLE;
                            end
                        end else begin
                            // 防御：理论上不会发生；若发生也不丢响应
                            rsp_valid <= 1'b1;
                            rdata     <= fill_buf[fill_word];
                            error     <= fill_err;
                            state     <= S_RESP;
                        end
                    end
                end
                // ------------------------------------------------------
                S_RESP: begin
                    // 响应未被取走前保持有效；rsp_take 已在块首全局清位
                    if (rsp_take) state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

`ifdef SIMULATION
    // 契约断言：突发必须恰好以 beat_last 结束；S_FILL 期间不得超收 4 beat
    always @(posedge clk) begin
        if (!rst && state == S_FILL && beat_valid && beat_ready && beat_cnt >= LINE_WORDS)
            $display("ASSERT-FAIL icache: 单次突发超过 %0d beat", LINE_WORDS);
    end
`endif

endmodule
