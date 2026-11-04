// ============================================================================
//  D-Cache 独立定向测试
//
//  被测：rtl/memory/dcache.sv（写穿 / 不写分配）
//  依据：TECHNICAL_BASELINE.md §「已冻结主方案」Cache 行、§「分支、Cache 与异常接入」
//
//  断言：
//    T1  复位后 req_ready=1
//    T2  load 缺失：4 beat 填充，返回被请求的字
//    T3  load 命中（1 拍）
//    T4  同行不同字也命中
//    T5  store 命中：出现**单 beat 写穿**，内存被更新，且行内数据同步更新（再读得新值）
//    T6  store 字节使能：只改指明的字节，其余保持
//    T7  **不写分配**：store 到未缓存行后再 load 该行仍为缺失
//    T8  写穿错误：响应 error=1，且**不更新行**（再读得旧值）
//    T9  单笔未完成：响应未取走前 req_ready=0
//    T10 读突发恰 4 beat、写穿恰 1 beat
//    T11 refill 出错后，部分写入的数据不能以旧 tag 命中
//    T12 成功 load 响应被取走的同沿接受下一笔 hit load，两个响应保持有序
// ============================================================================
`timescale 1ns/1ps
`include "defines.sv"

module tb_dcache;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    // ---------------- CPU 侧 ----------------
    reg         req_valid = 1'b0;
    wire        req_ready;
    reg  [31:0] addr = 32'h0;
    reg         write = 1'b0;
    reg  [31:0] wdata = 32'h0;
    reg  [3:0]  wstrb = 4'h0;
    wire        rsp_valid;
    reg         rsp_ready = 1'b1;
    wire [31:0] rdata;
    wire        error;

    // ---------------- 内存侧 ----------------
    wire [31:0] line_addr;
    wire        mem_read;
    reg         rd_beat_valid;
    wire        rd_beat_ready;
    reg  [31:0] rd_beat_data;
    reg         rd_beat_last;
    reg         rd_beat_error;
    wire        mem_write;
    wire [31:0] wr_addr;
    wire        wr_beat_valid;
    reg         wr_beat_ready;
    wire [31:0] wr_beat_data;
    wire [3:0]  wr_beat_wstrb;
    wire        wr_beat_last;
    reg         wr_beat_error;

    wire        hit_o;
    wire [31:0] stat_hit, stat_miss, stat_store;

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

    dcache #(.SETS(64), .WAYS(2), .LINE_WORDS(4)) u_dc (
        .clk(clk), .rst(rst),
        .req_valid(req_valid), .req_ready(req_ready), .addr(addr),
        .write(write), .wdata(wdata), .wstrb(wstrb),
        .rsp_valid(rsp_valid), .rsp_ready(rsp_ready), .rdata(rdata), .error(error),
        .line_addr(line_addr), .mem_read(mem_read),
        .rd_beat_valid(rd_beat_valid), .rd_beat_ready(rd_beat_ready),
        .rd_beat_data(rd_beat_data), .rd_beat_last(rd_beat_last),
        .rd_beat_error(rd_beat_error),
        .mem_write(mem_write), .wr_addr(wr_addr), .wr_beat_valid(wr_beat_valid),
        .wr_beat_ready(wr_beat_ready), .wr_beat_data(wr_beat_data),
        .wr_beat_wstrb(wr_beat_wstrb), .wr_beat_last(wr_beat_last),
        .wr_beat_error(wr_beat_error),
        .hit_o(hit_o), .stat_hit(stat_hit), .stat_miss(stat_miss),
        .stat_store(stat_store)
    );

    // ---------------- 后端存储器模型（256 字 = 1 KiB） ----------------
    reg [31:0] mem [0:255];

    task mem_init;
        begin
            integer k;
            for (k = 0; k < 256; k = k + 1) mem[k] = 32'hD000_0000 + k;
        end
    endtask

    // 读突发：mem_read 期间按 4 beat 依次给出当前内存内容
    reg [2:0] mbc = 3'd0;
    reg       inject_rd_err = 1'b0;
    reg       inject_wr_err = 1'b0;
    integer   rd_beats = 0, wr_beats = 0;
    integer   rd_burst_max = 0, wr_burst_max = 0;

    always @(*) begin
        rd_beat_valid = mem_read;
        rd_beat_last  = (mbc == 3'd3);
        rd_beat_data  = mem[line_addr[9:2] + mbc];
        rd_beat_error = inject_rd_err && rd_beat_last;
        wr_beat_ready = mem_write;          // 写穿随时可接收
        wr_beat_error = inject_wr_err;
    end

    always @(posedge clk) begin
        if (rst) begin
            mbc <= 3'd0; rd_beats <= 0; wr_beats <= 0;
            rd_burst_max <= 0; wr_burst_max <= 0;
        end else begin
            if (mem_read && rd_beat_valid && rd_beat_ready) begin
                rd_beats <= rd_beats + 1;
                if (rd_beats + 1 > rd_burst_max) rd_burst_max <= rd_beats + 1;
                if (rd_beat_last) begin mbc <= 3'd0; rd_beats <= 0; end
                else mbc <= mbc + 3'd1;
            end
            if (wr_beat_valid && wr_beat_ready) begin
                wr_beats <= wr_beats + 1;
                if (wr_beats + 1 > wr_burst_max) wr_burst_max <= wr_beats + 1;
                wr_beats <= 0;
                if (!wr_beat_error) begin
                    if (wr_beat_wstrb[0]) mem[wr_addr[9:2]][7:0]   <= wr_beat_data[7:0];
                    if (wr_beat_wstrb[1]) mem[wr_addr[9:2]][15:8]  <= wr_beat_data[15:8];
                    if (wr_beat_wstrb[2]) mem[wr_addr[9:2]][23:16] <= wr_beat_data[23:16];
                    if (wr_beat_wstrb[3]) mem[wr_addr[9:2]][31:24] <= wr_beat_data[31:24];
                end
            end
        end
    end

    // 看门狗（防止挂死时无输出）
    integer wd = 0;
    always @(posedge clk) begin
        if (!rst) begin
            wd = wd + 1;
            if (wd > 4000) begin
                $display("WATCHDOG: 卡住 state=%b req_ready=%b rsp_valid=%b mem_read=%b mem_write=%b",
                         u_dc.state, req_ready, rsp_valid, mem_read, mem_write);
                $finish;
            end
        end
    end

    // ---------------- 事务任务（全部在 negedge 驱动/采样） ----------------
    task cpu_load(input [31:0] a, output [31:0] d, output err);
        begin
            @(negedge clk);
            addr = a; write = 1'b0; wdata = 32'h0; wstrb = 4'h0;
            req_valid = 1'b1; rsp_ready = 1'b1;
            while (req_ready !== 1'b1) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
            // The upstream request may be withdrawn/advanced immediately
            // after acceptance. A refill must keep using the accepted line.
            addr = a ^ 32'h0000_0040;
            while (rsp_valid !== 1'b1) @(negedge clk);
            d = rdata; err = error;
            @(posedge clk);
            @(negedge clk);
            rsp_ready = 1'b0;
        end
    endtask

    task cpu_store(input [31:0] a, input [31:0] d, input [3:0] s, output err);
        begin
            @(negedge clk);
            addr = a; write = 1'b1; wdata = d; wstrb = s;
            req_valid = 1'b1; rsp_ready = 1'b1;
            while (req_ready !== 1'b1) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0; write = 1'b0;
            while (rsp_valid !== 1'b1) @(negedge clk);
            err = error;
            @(posedge clk);
            @(negedge clk);
            rsp_ready = 1'b0;
        end
    endtask

    reg [31:0] dv;
    reg        de;

    initial begin
        $display("==================================================");
        $display("  D-Cache 独立定向测试（write-through / no-write-allocate）");
        $display("==================================================");

        mem_init;
        repeat (3) @(posedge clk);
        chk("T1 req_ready after rst", {31'b0, req_ready}, 32'd1);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        // ---------------- T2 load 缺失 ----------------
        cpu_load(32'h0000_0000, dv, de);
        chk("T2 load miss returns word", dv, 32'hD000_0000);
        chk("T2b no error", {31'b0, de}, 32'd0);
        chk("T2c stat_miss=1", stat_miss, 32'd1);
        chk("T10 read burst exactly 4 beats", rd_burst_max, 32'd4);

        // ---------------- T3/T4 load 命中 ----------------
        cpu_load(32'h0000_0000, dv, de);
        chk("T3 load hit", dv, 32'hD000_0000);
        chk("T3b stat_hit=1", stat_hit, 32'd1);
        cpu_load(32'h0000_0004, dv, de);
        chk("T4 hit other word in line", dv, 32'hD000_0001);
        chk("T4b stat_hit=2", stat_hit, 32'd2);

        // ---------------- T5 store 命中：写穿 + 更新行 ----------------
        cpu_store(32'h0000_0000, 32'hDEAD_BEEF, 4'hF, de);
        chk("T5 store no error", {31'b0, de}, 32'd0);
        chk("T5b write-through updated memory", mem[0], 32'hDEAD_BEEF);
        chk("T10b write burst exactly 1 beat", wr_burst_max, 32'd1);
        cpu_load(32'h0000_0000, dv, de);
        chk("T5c line updated (load returns new value)", dv, 32'hDEAD_BEEF);

        // ---------------- T6 字节使能 ----------------
        cpu_store(32'h0000_0000, 32'h0000_0011, 4'h1, de);
        chk("T6 store byte-enable no error", {31'b0, de}, 32'd0);
        chk("T6b memory merged bytes", mem[0], 32'hDEAD_BE11);
        cpu_load(32'h0000_0000, dv, de);
        chk("T6c line merged bytes", dv, 32'hDEAD_BE11);

        // ---------------- T7 不写分配 ----------------
        cpu_store(32'h0000_0100, 32'h1234_5678, 4'hF, de);   // 该行从未被缓存
        chk("T7 store miss no error", {31'b0, de}, 32'd0);
        chk("T7b memory updated by write-through", mem[32'h100 >> 2], 32'h1234_5678);
        begin : t7
            integer m_before;
            m_before = stat_miss;
            cpu_load(32'h0000_0100, dv, de);                  // 未分配 → 仍应缺失
            checks = checks + 1;
            if (stat_miss == m_before + 1)
                $display("PASS [T7c no-write-allocate: line still misses] miss %0d -> %0d",
                         m_before, stat_miss);
            else begin
                errors = errors + 1;
                $display("FAIL [T7c no-write-allocate: line still misses] miss %0d -> %0d",
                         m_before, stat_miss);
            end
            chk("T7d filled line has written data", dv, 32'h1234_5678);
        end

        // ---------------- T8 写穿错误：不更新行 ----------------
        // 先确保 0x0000_0000 在缓存中且内存值为 DEADBE11
        inject_wr_err = 1'b1;
        cpu_store(32'h0000_0000, 32'hAAAA_AAAA, 4'hF, de);
        chk("T8 store error propagated", {31'b0, de}, 32'd1);
        inject_wr_err = 1'b0;
        chk("T8b memory unchanged on error", mem[0], 32'hDEAD_BE11);
        cpu_load(32'h0000_0000, dv, de);
        chk("T8c line NOT updated on error", dv, 32'hDEAD_BE11);

        // ---------------- T9 单笔未完成 ----------------
        @(negedge clk);
        addr = 32'h0000_0200; write = 1'b0; wdata = 0; wstrb = 0;
        req_valid = 1'b1; rsp_ready = 1'b0;
        while (req_ready !== 1'b1) @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        req_valid = 1'b0;
        while (rsp_valid !== 1'b1) @(negedge clk);
        chk("T9 rsp_valid held", {31'b0, rsp_valid}, 32'd1);
        chk("T9b req_ready=0 while pending", {31'b0, req_ready}, 32'd0);
        rsp_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        chk("T9c req_ready recovers", {31'b0, req_ready}, 32'd1);

        // ---------------- T12 成功 load 响应边沿接收下一笔 hit load ----------------
        // 先确保 0x200/0x204 所在行已缓存，再测同沿替换请求。
        cpu_load(32'h0000_0200, dv, de);
        chk("T12 prefill line no error", {31'b0, de}, 32'd0);
        @(negedge clk);
        addr = 32'h0000_0200; write = 1'b0; wdata = 0; wstrb = 0;
        req_valid = 1'b1; rsp_ready = 1'b1;
        while (req_ready !== 1'b1) @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        addr = 32'h0000_0204; // old response still pending; present replacement request
        chk("T12a old hit response valid", {31'b0, rsp_valid}, 32'd1);
        chk("T12b old hit response data", rdata, mem[32'h200 >> 2]);
        chk("T12c replacement accepted with old response", {31'b0, req_ready}, 32'd1);
        @(posedge clk);       // consume response for 0x200 and accept request for 0x204
        @(negedge clk);
        req_valid = 1'b0;
        chk("T12d replacement hit response stays valid", {31'b0, rsp_valid}, 32'd1);
        chk("T12e replacement hit response data", rdata, mem[32'h204 >> 2]);
        @(posedge clk);
        @(negedge clk);
        chk("T12f ready after replacement response", {31'b0, req_ready}, 32'd1);

        // ---------------- T11 refill 失败不得暴露被部分覆盖的旧行 ----------------
        // set 0 的两路先放入 tag 0 和 tag 1，再让 tag 2 选择 LRU way 0。
        cpu_load(32'h0000_0400, dv, de);
        chk("T11a second tag fill succeeds", {31'b0, de}, 32'd0);
        inject_rd_err = 1'b1;
        cpu_load(32'h0000_0800, dv, de);
        chk("T11b refill error propagated", {31'b0, de}, 32'd1);
        inject_rd_err = 1'b0;
        begin : t11
            integer m_before;
            m_before = stat_miss;
            cpu_load(32'h0000_0000, dv, de);
            chk("T11c old tag reload has no error", {31'b0, de}, 32'd0);
            chk("T11d old line data preserved by refetch", dv, 32'hDEAD_BE11);
            checks = checks + 1;
            if (stat_miss == m_before + 1)
                $display("PASS [T11e failed victim was invalidated before refill]");
            else begin
                errors = errors + 1;
                $display("FAIL [T11e miss %0d -> %0d, expected +1]", m_before, stat_miss);
            end
        end

        $display("==================================================");
        $display("  检查项: %0d  hit=%0d miss=%0d store=%0d", checks, stat_hit, stat_miss, stat_store);
        if (errors == 0)
            $display("  ALL TESTS PASSED (0 errors)");
        else
            $display("  %0d FAILED", errors);
        $display("==================================================");
        $finish;
    end

endmodule
