// ============================================================================
//        D-Cache（数据 Cache）—— 两路组相联、写穿、不写分配
//
//        依据：docs/architecture/TECHNICAL_BASELINE.md
//          §「已冻结主方案」Cache 行：
//            「I/D 各 2 KiB，2-way，64 sets，16 B line，1-bit LRU；
//              I 为只读，**D 为 write-through/no-write-allocate**，
//              miss 用 4 个 32-bit beat burst fill」
//          §「分支、Cache 与异常接入」：
//            「D-cache 命中读返回 line 数据，**store 命中更新 line 后单字 write-through，
//              下次 miss 不分配 line**。Cache miss 锁定一条 CPU 请求，完成 4 beat fill 后再响应；
//              在 CPU 未收响应前不接新请求。替换使用每 set 一位 LRU，复位 invalid。」
//
//        几何与索引与 I-Cache 完全一致（SETS=64 × WAYS=2 × 16 B = 2 KiB 总容量，每路 1 KiB）：
//          set = addr[9:4]、word = addr[3:2]、tag = addr[31:10]
//
//        ---- 读（load）----
//        命中：直接返回 line 中该字（1 拍，更新 LRU）；
//        缺失：锁请求 → 4 beat 突发填充 → 返回被请求的字；**仅当整条突发无错才分配行**。
//
//        ---- 写（store）：write-through / no-write-allocate ----
//        store 一律**单字写穿到内存**（1 beat，wr_beat_last=1）；
//        若该行命中，同时按 wstrb 字节使能更新行内该字；
//        未命中则**不分配行**（no-write-allocate）；
//        只有内存写成功（无 wr_beat_error）时才更新行，避免 Cache 与内存不一致。
//
//        ---- 内存侧 burst 方向约定（ADR-CACHE §2 的细化）----
//        读方向用 rd_*（内存驱动数据），写方向用 wr_*（本模块驱动数据），
//        两个方向各有自己的 ready，避免同一根线双向驱动。
//        写方向额外带 `wr_wstrb[3:0]`：基线的 burst 包未给字节使能，
//        而单字写穿必须保留其余字节，故显式扩展并记录在 ADR-CACHE。
//        写方向没有独立的数据回程，`wr_beat_error` 在
//        **wr_beat_valid && wr_beat_ready 的同一沿**被采样（写错误随接受握手一起报告）。
//
//        实现注意（均为本项目实测踩过的坑）：
//        - 不在 always @(*) 中使用循环变量（Icarus 会纳入敏感列表 → 零延迟死循环）；
//        - 写穿所需参数（set/way/word/strb）在**接受时锁存**，不依赖 addr 在 S_WR 期间保持。
//
//        复位：valid 全清（invalid），LRU 清 0。
// ============================================================================

`include "defines.sv"

module dcache #(
    parameter integer SETS       = 64,
    parameter integer WAYS       = 2,
    parameter integer LINE_WORDS = 4
)(
    input  wire         clk,
    input  wire         rst,

    // ---------------- CPU 单字端口（冻结契约） ----------------
    input  wire         req_valid,
    output wire         req_ready,
    input  wire [31:0]  addr,
    input  wire         write,
    input  wire [31:0]  wdata,
    input  wire [3:0]   wstrb,

    output wire         rsp_valid,
    input  wire         rsp_ready,
    output wire [31:0]  rdata,
    output wire         error,

    // ---------------- 内存侧：读突发 ----------------
    output wire [31:0]  line_addr,
    output wire         mem_read,
    input  wire         rd_beat_valid,
    output wire         rd_beat_ready,
    input  wire [31:0]  rd_beat_data,
    input  wire         rd_beat_last,
    input  wire         rd_beat_error,

    // ---------------- 内存侧：单字写穿 ----------------
    output wire         mem_write,
    output wire [31:0]  wr_addr,       // 被写字的**完整字节地址**（行内偏移由它给出）
    output wire         wr_beat_valid,
    input  wire         wr_beat_ready,
    output wire [31:0]  wr_beat_data,
    output wire [3:0]   wr_beat_wstrb,
    output wire         wr_beat_last,
    input  wire         wr_beat_error,

    // ---------------- 观测 ----------------
    output wire         hit_o,
    output reg  [31:0]  stat_hit,
    output reg  [31:0]  stat_miss,
    output reg  [31:0]  stat_store
);

    localparam integer SET_IDX_W = $clog2(SETS);
    localparam integer WORD_W    = $clog2(LINE_WORDS);
    localparam integer TAG_W     = 32 - SET_IDX_W - 2 - WORD_W;
    localparam integer ENTRIES   = SETS * WAYS;

    reg         rsp_valid_q;
    reg [31:0]  rdata_q;
    reg         error_q;
    reg         rsp_array_data_q;
    reg [31:0]  line_read_data_q;

    // ---------------- 存储阵列 ----------------
    // Tag 按路拆成单写口阵列：读地址恒为 req_set、写地址恒为 fill_set，
    // 于是 PDS 可以推断成 LUTRAM（1 RADDR + 1 WADDR），而不是 128×22 个
    // 触发器加一棵 128:1 的读 mux 树。那种写法的 mux 树第一级选择位正是
    // set 的高位（addr[9:8]），实测让这两根网各带 714 个 LUT6 输入。
    reg [TAG_W-1:0] tag_way0 [0:SETS-1];
    reg [TAG_W-1:0] tag_way1 [0:SETS-1];
    reg             valid [0:ENTRIES-1];
    reg [31:0]      line  [0:ENTRIES*LINE_WORDS-1];
    reg             lru   [0:SETS-1];

    // ---------------- 请求分解（组合） ----------------
    wire [SET_IDX_W-1:0] req_set  = addr[SET_IDX_W+3 : 4];
    wire [WORD_W-1:0]    req_word = addr[3+WORD_W-1 : 2];
    wire [TAG_W-1:0]     req_tag  = addr[31 : SET_IDX_W+4];

    // 显式展开 WAYS=2（冻结规格即两路）；不在 always @(*) 里用循环变量
    wire [TAG_W-1:0]     tag_rd0 = tag_way0[req_set];
    wire [TAG_W-1:0]     tag_rd1 = tag_way1[req_set];
    wire [WAYS-1:0] wv = { valid[req_set*WAYS + 1], valid[req_set*WAYS + 0] };
    wire [WAYS-1:0] wh = { (valid[req_set*WAYS + 1] && (tag_rd1 == req_tag)),
                           (valid[req_set*WAYS + 0] && (tag_rd0 == req_tag)) };

    wire        any_hit  = (wh != {WAYS{1'b0}});
    assign      hit_o    = any_hit;
    wire        hit_way0 = wh[0];
    wire [31:0] hit_line_index = hit_way0
                               ? (req_set*WAYS + 0)*LINE_WORDS + req_word
                               : (req_set*WAYS + 1)*LINE_WORDS + req_word;
    wire [31:0] hit_data;

    wire [31:0] victim_way = (!wv[0]) ? 32'd0
                           : ((!wv[1]) ? 32'd1 : {31'b0, lru[req_set]});

    // ---------------- 状态机 ----------------
    localparam [1:0] S_IDLE = 2'b00, S_FILL = 2'b01, S_WR = 2'b10, S_RESP = 2'b11;
    reg [1:0] state;
    integer i;                        // 仅供时钟块使用

    // A write response can be returned on the accepted write beat. In posted
    // mode this handshake means the ordered bridge has taken responsibility
    // for the store; legacy bridges still report any same-cycle write error.
    // If the CPU applies response backpressure, the sequential response slot
    // below retains the result exactly as before.
    wire early_store_response = (state == S_WR) && wr_beat_valid && wr_beat_ready;
    assign rsp_valid = rsp_valid_q || early_store_response;
    assign rdata = early_store_response ? `ZeroWord
                 : rsp_array_data_q ? line_read_data_q : rdata_q;
    assign error = early_store_response ? wr_beat_error : error_q;

    reg [SET_IDX_W-1:0] fill_set;
    reg [TAG_W-1:0]     fill_tag;
    reg [31:0]          fill_line_addr_q;
    reg [31:0]          fill_way;
    reg [WORD_W-1:0]    fill_word;
    reg [31:0]          fill_buf [0:LINE_WORDS-1];
    reg [2:0]           beat_cnt;
    reg                 fill_err;

    // 写穿事务在**接受时锁存**的全部参数
    reg [SET_IDX_W-1:0] st_set;
    reg [31:0]          st_addr;      // 被写字的完整字节地址
    reg [31:0]          st_way;       // 0 或 1
    reg                 st_hit;
    reg [31:0]          st_word;
    reg [31:0]          st_data;
    reg [3:0]           st_strb;
    reg                 st_err;

    // 写更新用的字节掩码（由锁存的 st_strb 展开）
    wire [31:0] st_mask = {{8{st_strb[3]}}, {8{st_strb[2]}},
                           {8{st_strb[1]}}, {8{st_strb[0]}}};
    wire [31:0] st_index = (st_set*WAYS + st_way)*LINE_WORDS + st_word;

    // Capture the accepted hit word on the request edge so the 512x32 line
    // array has one synchronous read port. The response mux exposes its
    // registered output in the existing one-cycle hit-response slot.
    wire accept = req_valid && req_ready;
    always @(posedge clk) begin
        if ((rst == `RstDisable) && accept && any_hit)
            line_read_data_q <= line[hit_line_index];
    end
    wire [31:0] line_read_data = line_read_data_q;
    assign hit_data = line_read_data_q;

    // Keep the data array on one synchronous write port for FPGA RAM inference.
    // A refill writes one beat at a time; a successful store hit uses the same port.
    wire        refill_line_we = (rst == `RstDisable) && (state == S_FILL) &&
                                 rd_beat_valid && rd_beat_ready;
    wire        store_line_we  = (rst == `RstDisable) && (state == S_WR) &&
                                 wr_beat_valid && wr_beat_ready &&
                                 !wr_beat_error && st_hit;
    wire [31:0] refill_line_index = (fill_set*WAYS + fill_way)*LINE_WORDS + beat_cnt;
    wire [31:0] store_line_data = (line_read_data & ~st_mask) | (st_data & st_mask);
    wire [31:0] line_write_index = refill_line_we ? refill_line_index : st_index;
    wire [31:0] line_write_data  = refill_line_we ? rd_beat_data : store_line_data;
    wire        line_write_en    = refill_line_we || store_line_we;

    // One syntactic memory write keeps Yosys/PDS from exporting mutually exclusive
    // refill/store writes as multiple drivers for the same line-array word.
    always @(posedge clk) begin
        if (line_write_en) line[line_write_index] <= line_write_data;
    end

    // Permit an in-order replacement request on the edge that consumes a
    // registered load response. The LSU only asserts this for a successful
    // older load and holds the next request payload stable through handshake.
    wire response_turnover = (state == S_RESP) && rsp_valid_q && rsp_ready;
    assign req_ready = (state == S_IDLE) || response_turnover;

    assign mem_read      = (state == S_FILL);
    assign mem_write     = (state == S_WR);
    assign rd_beat_ready = (state == S_FILL);
    // Keep the burst address stable for the full refill. The CPU may advance
    // or withdraw its request immediately after req_valid && req_ready.
    assign line_addr     = (state == S_FILL) ? fill_line_addr_q : {addr[31:4], 4'b0};

    assign wr_beat_valid = (state == S_WR);
    assign wr_addr       = st_addr;
    assign wr_beat_data  = st_data;
    assign wr_beat_wstrb = st_strb;
    assign wr_beat_last  = 1'b1;      // 写穿 = 单 beat 突发

    // 单写口 tag 阵列：写地址 = fill_set，路由锁存的 fill_way 选择。
    // 写入条件与原 gen_tag_write 完全一致（整条突发无错、beat_last 提交）。
    wire tag_fill_commit = (state == S_FILL) && rd_beat_valid && rd_beat_ready &&
                           rd_beat_last && !(fill_err || rd_beat_error);
    always @(posedge clk) begin
        if ((rst == `RstDisable) && tag_fill_commit) begin
            if (fill_way[0]) tag_way1[fill_set] <= fill_tag;
            else             tag_way0[fill_set] <= fill_tag;
        end
    end

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            state      <= S_IDLE;
            rsp_valid_q <= 1'b0;
            rdata_q      <= `ZeroWord;
            error_q      <= 1'b0;
            rsp_array_data_q <= 1'b0;
            fill_line_addr_q <= 32'b0;
            beat_cnt   <= 3'd0;
            fill_err   <= 1'b0;
            stat_hit   <= 32'b0;
            stat_miss  <= 32'b0;
            stat_store <= 32'b0;
            st_hit     <= 1'b0;
            st_err     <= 1'b0;
            for (i = 0; i < ENTRIES; i = i + 1) valid[i] <= 1'b0;
            for (i = 0; i < SETS; i = i + 1)    lru[i]   <= 1'b0;
        end else begin
            if (accept) rsp_array_data_q <= 1'b0;
            case (state)
                // ------------------------------------------------------
                S_IDLE: begin
                    if (accept) begin
                        if (write) begin
                            // ---- store：写穿 + 命中时更新行；不分配 ----
                            st_set   <= req_set;
                            st_addr  <= addr;
                            // 存**路号索引**（命中 way0 → 0；命中 way1 → 1），
                            // 故为 ~hit_way0。首版误存 hit_way0 本身（布尔"是否 way0 命中"），
                            // 导致命中 way0 时把更新写到 way1，行数据不生效（由 T5c/T6c/T8c 捕获）。
                            st_way   <= {31'b0, ~hit_way0};
                            st_hit   <= any_hit;
                            st_word  <= {28'b0, req_word};
                            st_data  <= wdata;
                            st_strb  <= wstrb;
                            stat_store <= stat_store + 32'b1;
                            if (any_hit) begin
                                stat_hit     <= stat_hit + 32'b1;
                                lru[req_set] <= hit_way0;      // 命中路变 MRU
                            end else begin
                                stat_miss <= stat_miss + 32'b1;
                            end
                            state <= S_WR;
                        end else if (any_hit) begin
                            // ---- load 命中 ----
                            rsp_valid_q  <= 1'b1;
                            rsp_array_data_q <= 1'b1;
                            error_q      <= 1'b0;
                            state        <= S_RESP;
                            stat_hit     <= stat_hit + 32'b1;
                            lru[req_set] <= hit_way0;
                        end else begin
                            // ---- load 缺失：锁定请求并 4 beat 填充 ----
                            fill_set  <= req_set;
                            fill_tag  <= req_tag;
                            fill_line_addr_q <= {addr[31:4], 4'b0};
                            fill_way  <= victim_way;
                            // Refill writes each beat before the final error is known.
                            // Hide the victim so a failed fill cannot expose overwritten data.
                            valid[req_set*WAYS + victim_way] <= 1'b0;
                            fill_word <= req_word;
                            beat_cnt  <= 3'd0;
                            fill_err  <= 1'b0;
                            state     <= S_FILL;
                            stat_miss <= stat_miss + 32'b1;
                        end
                    end
                end
                // ------------------------------------------------------
                S_FILL: begin
                    if (rd_beat_valid && rd_beat_ready) begin
                        fill_buf[beat_cnt] <= rd_beat_data;
                        if (rd_beat_error) fill_err <= 1'b1;
                        if (rd_beat_last) begin
                            // 仅当整条突发无错才分配（出错仍分配会让后续访问命中
                            // 半填充垃圾行并返回 error=0，静默掩盖错误）
                            if (!(fill_err || rd_beat_error)) begin
                                valid[fill_set*WAYS + fill_way] <= 1'b1;
                                lru[fill_set] <= ~fill_way[0];
                            end
                            rsp_valid_q <= 1'b1;
                            rdata_q     <= (beat_cnt == fill_word) ? rd_beat_data
                                                                   : fill_buf[fill_word];
                            error_q     <= fill_err || rd_beat_error;
                            state     <= S_RESP;
                            beat_cnt  <= 3'd0;
                        end else begin
                            beat_cnt <= beat_cnt + 3'd1;
                        end
                    end
                end
                // ------------------------------------------------------
                S_WR: begin
                    // 单 beat 写穿；接受沿同时采样写错误
                    if (wr_beat_valid && wr_beat_ready) begin
                        if (wr_beat_error) begin
                            // 内存写失败：不更新行（避免 Cache 与内存不一致）
                            st_err <= 1'b1;
                            error_q <= 1'b1;
                            rsp_array_data_q <= 1'b0;
                            rdata_q <= `ZeroWord;    // error 不得产生成功写回
                        end else begin
                            st_err <= 1'b0;
                            error_q <= 1'b0;
                            rsp_array_data_q <= 1'b0;
                            rdata_q <= `ZeroWord;
                            if (st_hit) begin
                                // 命中时的数据合并由共享单写端口完成。
                                lru[st_set] <= ~st_way[0];   // 命中路变 MRU
                            end
                        end
                        if (rsp_ready) begin
                            rsp_valid_q <= 1'b0;
                            state       <= S_IDLE;
                        end else begin
                            rsp_valid_q <= 1'b1;
                            state       <= S_RESP;
                        end
                    end
                end
                // ------------------------------------------------------
                S_RESP: begin
                    if (rsp_ready) begin
                        if (accept) begin
                            rsp_valid_q <= 1'b0;
                            if (write) begin
                                // A replacement store starts only after the
                                // older response has been consumed. Its data
                                // and destination are captured independently.
                                st_set   <= req_set;
                                st_addr  <= addr;
                                st_way   <= {31'b0, ~hit_way0};
                                st_hit   <= any_hit;
                                st_word  <= {28'b0, req_word};
                                st_data  <= wdata;
                                st_strb  <= wstrb;
                                stat_store <= stat_store + 32'b1;
                                if (any_hit) begin
                                    stat_hit <= stat_hit + 32'b1;
                                    lru[req_set] <= hit_way0;
                                end else begin
                                    stat_miss <= stat_miss + 32'b1;
                                end
                                state <= S_WR;
                            end else if (any_hit) begin
                                rsp_valid_q <= 1'b1;
                                rsp_array_data_q <= 1'b1;
                                error_q <= 1'b0;
                                state <= S_RESP;
                                stat_hit <= stat_hit + 32'b1;
                                lru[req_set] <= hit_way0;
                            end else begin
                                fill_set <= req_set;
                                fill_tag <= req_tag;
                                fill_line_addr_q <= {addr[31:4], 4'b0};
                                fill_way <= victim_way;
                                valid[req_set*WAYS + victim_way] <= 1'b0;
                                fill_word <= req_word;
                                beat_cnt <= 3'd0;
                                fill_err <= 1'b0;
                                rsp_valid_q <= 1'b0;
                                state <= S_FILL;
                                stat_miss <= stat_miss + 32'b1;
                            end
                        end else begin
                            rsp_valid_q <= 1'b0;
                            state <= S_IDLE;
                        end
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

`ifdef SIMULATION
    always @(posedge clk) begin
        if (!rst && state == S_FILL && rd_beat_valid && rd_beat_ready && beat_cnt >= LINE_WORDS)
            $display("ASSERT-FAIL dcache: 单次读突发超过 %0d beat", LINE_WORDS);
    end
`endif

endmodule
