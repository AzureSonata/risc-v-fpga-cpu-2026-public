`timescale 1ns/1ps
// ============================================================================
//  mem_burst_bridge —— Cache 内存侧 4-beat burst ⇄ adapter 单字 转换桥
//
//  职责（ADR-CACHE-INTEGRATION D-C4）：mem_map_adapter / rom / sram 只有单字
//  req/rsp 接口，而 icache/dcache 的填充与写穿侧说 ADR-CACHE §2 的 beat 契约。
//  本桥是两者之间**唯一**的新 RTL：读方向把一次行填充拆成 4 笔顺序单字读，
//  逐字作为 beat 递给 cache；写方向把 dcache 的单 beat 写穿转成一笔单字写。
//
//  ---- 协议要点（与 icache.sv/dcache.sv 的实际驱动逐信号对齐）----
//  读方向（cache 驱动）：
//    mem_read 是**电平**（= cache 的 S_FILL 态，整次填充期间保持）；
//    line_addr 16B 对齐、填充期间保持不变；
//    rd_beat_ready 在 S_FILL 恒 1，cache 自己数 beat、以第 4 拍的 rd_beat_last
//    收尾；任一 beat 的 error 由 cache 采样后裁决整行不分配（桥**只透传、不裁决**，
//    分配权单一化——中途出错的后续 beat 照常递出，不得由桥截断或吞掉）。
//  写方向（dcache 驱动）：
//    mem_write / wr_beat_valid 是电平（= S_WR 态）；wr_addr/wdata/wstrb 在
//    写穿期间保持；wr_beat_last 恒 1（单 beat 突发）；wr_beat_error 在
//    wr_beat_valid && wr_beat_ready 的**同一沿**被 cache 采样——桥必须在
//    adapter 响应握手完成的那一拍给出 wr_beat_ready（含 error）。
//  两方向互斥：cache 侧 S_FILL 与 S_WR 是不同状态（mem_read 与 mem_write
//  不会同时为 1），桥内部用一个共享的 adapter 请求通路即可。
//
//  实现注意（均为本项目实测踩过的坑）：
//  - Icarus 10.2：不用 always_comb/always_ff；循环变量只进时钟块；
//  - rd_beat_valid 持有到 rd_beat_ready 为止（不假设 cache 恒 ready）；
//  - rsp_ready 只在等待响应的状态置 1，避免误吞杂散响应。
// ============================================================================

`include "defines.sv"

module mem_burst_bridge (
    input  wire        clk,
    input  wire        rst,

    // ---------------- cache 侧（ADR-CACHE §2 beat 契约） ----------------
    input  wire [31:0] line_addr,       // 读突发行地址（16B 对齐，填充期保持）
    input  wire        mem_read,        // 读突发请求（电平，S_FILL 期保持）
    input  wire        mem_write,       // 写穿请求（电平，S_WR 期保持）
    input  wire [31:0] wr_addr,         // 写穿字地址（完整字节地址，S_WR 期保持）
    output reg         rd_beat_valid,   // 本拍总线上有有效 beat 数据（数据有效语义）
    input  wire        rd_beat_ready,
    output reg  [31:0] rd_beat_data,
    output reg         rd_beat_last,
    output reg         rd_beat_error,   // 本 beat 出错（逐 beat 透传，不裁决不截断）
    input  wire        wr_beat_valid,   // cache 的写穿 beat（S_WR 期保持到握手）
    output reg         wr_beat_ready,   // 写完成（含错误）回传，单拍
    input  wire [31:0] wr_beat_data,
    input  wire [3:0]  wr_beat_wstrb,
    input  wire        wr_beat_last,    // 恒 1（单 beat）；桥不使用，仅接线完整
    output reg         wr_beat_error,

    // ---------------- adapter 单字侧 ----------------
    output wire        req_valid,
    input  wire        req_ready,
    output wire [31:0] req_addr,
    output wire        req_write,
    output wire [31:0] req_wdata,
    output wire [3:0]  req_wstrb,
    input  wire        rsp_valid,
    output wire        rsp_ready,
    input  wire [31:0] rsp_rdata,
    input  wire        rsp_error
);

    // ---------------- 状态机 ----------------
    // R_* 读填充通路；W_* 写穿通路；IDLE 空闲。
    localparam [2:0] S_IDLE  = 3'd0,
                     S_R_REQ = 3'd1,    // 呈现第 beat_idx 笔单字读
                     S_R_RSP = 3'd2,    // 等 adapter 响应 → 递 beat
                     S_R_BEAT= 3'd3,    // beat 握手（持有到 rd_beat_ready）
                     S_W_REQ = 3'd4,    // 呈现写穿单字写
                     S_W_RSP = 3'd5,    // 等 adapter 响应 → wr_beat_ready 单拍
                     S_W_DONE= 3'd6;    // 等 cache 撤销 mem_write/wr_beat_valid
    reg [2:0] state;

    reg [1:0] rd_cnt;                   // 已递出 beat 数 0..3
    reg [31:0] r_line_addr;             // 锁存的行地址（mem_read 电平期间保持，仍锁存防漂移）
    reg [31:0] w_addr_q, w_data_q;
    reg [3:0]  w_strb_q;

    wire start_read  = mem_read  && !mem_write;
    wire start_write = mem_write && !mem_read;

    // adapter 请求通路：读/写共用
    // 读方向的字地址：S_R_REQ 发当前字；S_R_BEAT 在递出当前 beat 的同一拍
    // 发下一字请求（A1：将 rd_beat_ready=1 时的 3 拍/beat 压到 2 拍/beat）。
    // line_addr 已 16B 对齐，字偏移取 0/4/8/12 ⇒ 用**按位或**叠加偏移，
    // 与加法等价（无进位传播）但少一级进位链，求值也更适合综合。
    wire [1:0]  rd_req_idx  = (state == S_R_BEAT) ? (rd_cnt + 2'd1) : rd_cnt;
    wire [31:0] rd_word_off = {28'b0, rd_req_idx, 2'b00};
    wire [31:0] rd_word_addr = r_line_addr | rd_word_off;

    assign req_valid = (state == S_R_REQ) || (state == S_W_REQ) ||
                       ((state == S_R_BEAT) && (rd_cnt != 2'd3) && rd_beat_ready);
    assign req_write = (state == S_W_REQ);
    assign req_addr  = (state == S_W_REQ) ? w_addr_q
                     : {r_line_addr[31:2], 2'b00};   // NEGCTL：地址不随 beat 递增，
                                                     // 4 笔请求全部命中 word0，T1 必须捕获
    assign req_wdata = w_data_q;
    assign req_wstrb = (state == S_W_REQ) ? w_strb_q : 4'b0000;

    // 响应只在等待态消费（避免误吞杂散响应）
    assign rsp_ready = (state == S_R_RSP) || (state == S_W_RSP);

    wire req_fire  = req_valid && req_ready;
    wire rsp_fire  = rsp_valid && rsp_ready;
    wire beat_fire = rd_beat_valid && rd_beat_ready;

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            state         <= S_IDLE;
            rd_cnt        <= 2'd0;
            r_line_addr   <= 32'b0;
            w_addr_q      <= 32'b0;
            w_data_q      <= 32'b0;
            w_strb_q      <= 4'b0;
            rd_beat_valid <= 1'b0;
            rd_beat_data  <= 32'b0;
            rd_beat_last  <= 1'b0;
            rd_beat_error <= 1'b0;
            wr_beat_ready <= 1'b0;
            wr_beat_error <= 1'b0;
        end else begin
            // beat/wr 回传脉冲默认撤销（单拍语义）
            wr_beat_ready <= 1'b0;
            wr_beat_error <= 1'b0;

            case (state)
                // ------------------------------------------------------
                S_IDLE: begin
                    rd_beat_valid <= 1'b0;
                    if (start_write && wr_beat_valid) begin
                        // 写穿参数在接受时锁存（与 dcache 同思路，不依赖电平期保持）
                        w_addr_q <= wr_addr;
                        w_data_q <= wr_beat_data;
                        w_strb_q <= wr_beat_wstrb;
                        state    <= S_W_REQ;
                    end else if (start_read) begin
                        r_line_addr <= line_addr;
                        rd_cnt      <= 2'd0;
                        state       <= S_R_REQ;
                    end
                end
                // ------------------------------------------------------
                S_R_REQ: begin
                    if (req_fire)
                        state <= S_R_RSP;
                end
                // ------------------------------------------------------
                S_R_RSP: begin
                    if (rsp_fire) begin
                        // 响应字即刻成为 beat（持有到 rd_beat_ready）
                        rd_beat_valid <= 1'b1;
                        rd_beat_data  <= rsp_rdata;
                        rd_beat_error <= rsp_error;
                        rd_beat_last  <= (rd_cnt == 2'd3);
                        state         <= S_R_BEAT;
                    end
                end
                // ------------------------------------------------------
                S_R_BEAT: begin
                    if (beat_fire) begin
                        rd_beat_valid <= 1'b0;
                        rd_beat_last  <= 1'b0;
                        rd_beat_error <= 1'b0;
                        if (rd_cnt == 2'd3) begin
                            // 整行递出完毕；mem_read 电平撤销后回 IDLE
                            rd_cnt <= 2'd0;
                            state  <= S_IDLE;
                        end else begin
                            rd_cnt <= rd_cnt + 2'd1;
                            // A1：本拍已经同时发出下一字请求（req_valid 见上）。
                            // - req_fire=1：下一字已被 adapter 接受，直接等响应；
                            // - req_fire=0：回 S_R_REQ 继续呈现下一字请求。
                            state  <= req_fire ? S_R_RSP : S_R_REQ;
                        end
                    end
                end
                // ------------------------------------------------------
                S_W_REQ: begin
                    if (req_fire)
                        state <= S_W_RSP;
                end
                // ------------------------------------------------------
                S_W_RSP: begin
                    if (rsp_fire) begin
                        // 写完成随接受沿回传（dcache 在该沿采样 wr_beat_error）
                        wr_beat_ready <= 1'b1;
                        wr_beat_error <= rsp_error;
                        state         <= S_W_DONE;
                    end
                end
                // ------------------------------------------------------
                // 关键：不能直接回 IDLE。wr_beat_ready 比 rsp_fire 晚一拍才被
                // cache 看到，cache 在该沿才撤销 mem_write/wr_beat_valid——
                // 若此窗内回到 IDLE，会看到 start_write && wr_beat_valid 仍成立
                // 而再次发起写 = 同一笔 store 写两次（架构性损坏，T5 实测捕获）。
                S_W_DONE: begin
                    if (!mem_write && !wr_beat_valid)
                        state <= S_IDLE;
                end
                // ------------------------------------------------------
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
