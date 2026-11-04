// ============================================================================
//  I-Cache 独立定向测试
//
//  被测：rtl/memory/icache.sv
//  依据：TECHNICAL_BASELINE.md §「已冻结主方案」Cache 行、§「分支、Cache 与异常接入」
//
//  断言：
//    T1  复位后 req_ready=1、无响应
//    T2  首次访问为缺失：发起 4 beat 突发，响应数据 = 被请求的那个字；stat_miss=1
//    T3  同一行同一字再访问为命中（1 拍响应），stat_hit=1
//    T4  同一行不同字也命中（16 B 行 = 4 字）
//    T5  冲突缺失：同 set 不同 tag 逐出，随后原行再访问应为缺失（证明逐出真实发生）
//    T6  LRU：命中会更新 LRU，使**刚命中的路**不再成为下次牺牲者（不抖动）
//    T7  写请求对本模块非法 → error=1 且不分配行
//    T8  需求 word 本身带 error → 该响应 error=1，且不分配行
//        T8c/T8d 需求 word 之后的 beat 才 error → 已交付响应合法，但行仍不分配
//    T9  响应未被取走前 req_ready=0；A2b 下响应取走后同 fill 行可继续服务（T9d）
//    T10 每次突发恰好 4 beat（以 beat_last 收尾；早响应后需等后台 fill 收尾再数）
// ============================================================================
`timescale 1ns/1ps
`include "defines.sv"

module tb_icache;

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
    wire        mem_read, mem_write;
    wire        beat_ready;
    reg         beat_valid;
    reg  [31:0] beat_data;
    reg         beat_last;
    reg         beat_error;

    wire        hit_o;
    wire [31:0] stat_hit, stat_miss;

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

    icache #(.SETS(64), .WAYS(2), .LINE_WORDS(4)) u_ic (
        .clk(clk), .rst(rst),
        .req_valid(req_valid), .req_ready(req_ready), .addr(addr),
        .write(write), .wdata(wdata), .wstrb(wstrb),
        .rsp_valid(rsp_valid), .rsp_ready(rsp_ready), .rdata(rdata), .error(error),
        .line_addr(line_addr), .mem_read(mem_read), .mem_write(mem_write),
        .beat_valid(beat_valid), .beat_ready(beat_ready), .beat_data(beat_data),
        .beat_last(beat_last), .beat_error(beat_error),
        .hit_o(hit_o), .stat_hit(stat_hit), .stat_miss(stat_miss)
    );

    // ---------------- 后端存储器模型 ----------------
    // 内容函数：每个字唯一，便于校验取到的是正确的那一行/那个字
    function automatic [31:0] mem_word(input [31:0] a);
        mem_word = 32'hC000_0000 + (a >> 2);
    endfunction

    reg [2:0]  mbc       = 3'd0;      // 当前突发内已发出的 beat 序号（0..3）
    reg        inject_err = 1'b0;
    reg [1:0]  err_beat   = 2'd3;     // 错误注入到第几笔 beat（A2b 需要 word0/后续分别测）
    integer    beats_this_burst = 0;
    integer    burst_max = 0;

    // 请求读时按 4 beat 依次给出数据；beat_last 必须在第 4 beat
    always @(*) begin
        beat_valid = mem_read;
        beat_last  = (mbc == 3'd3);
        beat_data  = mem_word(line_addr + {mbc, 2'b00});
        beat_error = inject_err && (mbc == {1'b0, err_beat});
    end

    always @(posedge clk) begin
        if (rst) begin
            mbc <= 3'd0;
            beats_this_burst <= 0;
            burst_max <= 0;
        end else if (mem_read && beat_valid && beat_ready) begin
            beats_this_burst <= beats_this_burst + 1;
            if (beats_this_burst + 1 > burst_max) burst_max <= beats_this_burst + 1;
            if (beat_last) begin
                mbc <= 3'd0;
                beats_this_burst <= 0;
            end else begin
                mbc <= mbc + 3'd1;
            end
        end
    end

    // ---------------- 事务任务 ----------------
    // 全部在 negedge 驱动/采样（半拍处信号稳定）：避免"在接受沿之后又去等
    // req_ready"——那时 FSM 已离开 IDLE，会死等（本项目实测踩坑）。
    task cpu_read(input [31:0] a, output [31:0] d, output err);
        begin
            @(negedge clk);
            addr = a; write = 1'b0; wdata = 32'h0; wstrb = 4'h0;
            req_valid = 1'b1; rsp_ready = 1'b1;
            // A2b 下 req_ready 可能是“同 fill 行服务的瞬时 1”，也可能被旧 fill 反压。
            // 保持 req_valid 直到响应到达，不在中间猜“是否已被接受”。
            #0;                                          // 让组合 req_ready 随新 addr 稳定
            while (rsp_valid !== 1'b1) @(negedge clk);   // 等响应（缺失时含填充）
            d = rdata; err = error;
            @(posedge clk);                              // 该沿取走响应
            @(negedge clk);
            req_valid = 1'b0; rsp_ready = 1'b0;
        end
    endtask

    // 一次 CPU 写（I-Cache 视为非法）
    task cpu_write(input [31:0] a);
        begin
            @(negedge clk);
            addr = a; write = 1'b1; wdata = 32'h1234_5678; wstrb = 4'hF;
            req_valid = 1'b1; rsp_ready = 1'b1;
            #0;                                          // 让组合 req_ready 随新 addr 稳定
            while (rsp_valid !== 1'b1) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0; write = 1'b0; rsp_ready = 1'b0;
        end
    endtask

    reg [31:0] dv, dv2;
    reg        de, de2;

    // 看门狗：卡住时打印状态并结束，避免仿真挂死（本项目实测踩坑）
    integer wd = 0;
    always @(posedge clk) begin
        if (!rst) begin
            wd = wd + 1;
            if (wd > 3000) begin
                $display("WATCHDOG: 仿真卡住 —— icache.state=%b req_valid=%b req_ready=%b rsp_valid=%b rsp_ready=%b",
                         u_ic.state, req_valid, req_ready, rsp_valid, rsp_ready);
                $display("          addr=%h mem_read=%b beat_valid=%b beat_ready=%b beat_last=%b mbc=%0d beat_cnt=%0d",
                         addr, mem_read, beat_valid, beat_ready, beat_last, mbc, u_ic.beat_cnt);
                $finish;
            end
        end
    end

    // 同 set 不同 tag 的三个地址（64 组 → set 索引 = addr[9:4]，tag = addr[31:10]）
    localparam [31:0] A0 = 32'h0000_0000;   // set0 tag0 word0
    localparam [31:0] A4 = 32'h0000_0004;   // set0 tag0 word1
    localparam [31:0] B0 = 32'h0000_0400;   // set0 tag1 word0
    localparam [31:0] C0 = 32'h0000_0800;   // set0 tag2 word0
    // set1（addr[9:4]=1）的三个 tag，用于 T6 的 LRU 区分性测试
    localparam [31:0] D0 = 32'h0000_0010;   // set1 tag0
    localparam [31:0] E0 = 32'h0000_0410;   // set1 tag1
    localparam [31:0] F0 = 32'h0000_0810;   // set1 tag2

    initial begin
        $display("==================================================");
        $display("  I-Cache 独立定向测试");
        $display("==================================================");

        repeat (3) @(posedge clk);

        // ---------------- T1 复位 ----------------
        chk("T1 req_ready after rst", {31'b0, req_ready}, 32'd1);
        chk("T1b no response after rst", {31'b0, rsp_valid}, 32'd0);

        rst = 1'b0;
        repeat (2) @(posedge clk);

        // ---------------- T2 首次访问 = 缺失 + 4 beat 填充 ----------------
        cpu_read(A0, dv, de);
        chk("T2 miss fill returns requested word", dv, mem_word(A0));
        chk("T2b no error on fill", {31'b0, de}, 32'd0);
        chk("T2c stat_miss = 1", stat_miss, 32'd1);
        // A2b：响应可在 beat0 提前交付；T10 必须等后台 fill 收尾再数 beat。
        while (mem_read !== 1'b0) @(negedge clk);
        // T10：刚结束的突发恰好 4 beat
        chk("T10 burst exactly 4 beats", burst_max, 32'd4);

        // ---------------- T3 命中（同字） ----------------
        cpu_read(A0, dv, de);
        chk("T3 hit returns data", dv, mem_word(A0));
        chk("T3b stat_hit = 1", stat_hit, 32'd1);
        chk("T3c stat_miss still 1", stat_miss, 32'd1);

        // ---------------- T4 同行不同字也命中 ----------------
        cpu_read(A4, dv, de);
        chk("T4 hit other word in line", dv, mem_word(A4));
        chk("T4b stat_hit = 2", stat_hit, 32'd2);

        // ---------------- T5 冲突缺失与逐出 ----------------
        cpu_read(B0, dv, de);                    // 同 set 不同 tag → 缺失，填另一路
        chk("T5 conflict miss fills tag1", dv, mem_word(B0));
        chk("T5b stat_miss = 2", stat_miss, 32'd2);
        cpu_read(A0, dv, de);                    // A0 应仍在（2 路都在）
        chk("T5c A0 still resident (2 ways)", dv, mem_word(A0));
        cpu_read(C0, dv, de);                    // 第三次不同 tag → 必逐出 LRU 路
        chk("T5d tag2 miss", dv, mem_word(C0));
        // 访问被逐出的那一行应再次缺失
        cpu_read(B0, dv, de);
        checks = checks + 1;
        if (stat_miss == 32'd3 || stat_miss == 32'd4)
            $display("PASS [T5e evicted line re-misses] stat_miss=%0d", stat_miss);
        else begin
            errors = errors + 1;
            $display("FAIL [T5e evicted line re-misses] stat_miss=%0d", stat_miss);
        end

        // ---------------- T6 LRU：命中必须更新，否则会逐出 MRU 行 ----------------
        // 注意（首轮教训）：反复命中同一条**测不出** LRU 是否更新——命中不会引起逐出。
        // 必须构造"第三个 tag 到来"才能真正区分：
        //   set1 依次填 D0(way0) → E0(way1)；此时 lru=0（victim=way0=D0）
        //   命中 D0 → 正确实现把 lru 更新为 1（victim=way1=E0）；
        //              错误实现（不更新）lru 仍为 0 → 会逐出刚用过的 D0
        //   再访问 F0(新 tag) → 逐出对象不同
        //   最后访问 D0：正确实现应仍命中；错误实现已把它逐出 → 缺失
        cpu_read(D0, dv, de);            // miss → way0
        cpu_read(E0, dv, de);            // miss → way1，lru=0
        cpu_read(D0, dv, de);            // hit way0 → lru 应为 1
        cpu_read(F0, dv, de);            // miss → 按 lru 逐出
        begin : t6
            integer h_before, m_before;
            h_before = stat_hit;
            m_before = stat_miss;
            cpu_read(D0, dv, de);
            checks = checks + 1;
            if (stat_hit == h_before + 1 && stat_miss == m_before)
                $display("PASS [T6 LRU keeps just-hit line resident] hit %0d -> %0d",
                         h_before, stat_hit);
            else begin
                errors = errors + 1;
                $display("FAIL [T6 LRU keeps just-hit line resident] hit %0d -> %0d, miss %0d -> %0d（MRU 行被逐出）",
                         h_before, stat_hit, m_before, stat_miss);
            end
        end

        // ---------------- T9 单笔未完成：响应未取走前不接新请求 ----------------
        @(negedge clk);
        addr = 32'h0000_1000; write = 1'b0; req_valid = 1'b1; rsp_ready = 1'b0;
        while (req_ready !== 1'b1) @(negedge clk);
        @(posedge clk);                       // 该沿被接受（缺失 → 开始填充）
        @(negedge clk);
        req_valid = 1'b0;
        while (rsp_valid !== 1'b1) @(negedge clk);
        chk("T9 rsp_valid held while rsp_ready=0", {31'b0, rsp_valid}, 32'd1);
        chk("T9b req_ready=0 while response pending", {31'b0, req_ready}, 32'd0);
        @(negedge clk);
        chk("T9c still pending next cycle", {31'b0, req_ready}, 32'd0);
        rsp_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        chk("T9d req_ready recovers after response taken", {31'b0, req_ready}, 32'd1);
        // 响应提前后 fill 还在后台；等它收完，避免污染后续用例。
        while (mem_read !== 1'b0) @(negedge clk);

        // ---------------- T7 写请求非法 ----------------
        cpu_write(A0);
        chk("T7 write -> error response", {31'b0, error}, 32'd1);
        chk("T7b mem_write never asserted", {31'b0, mem_write}, 32'd0);

        // ---------------- T8 需求 word 本身带 error：该响应必须 error=1 ----------------
        inject_err = 1'b1;
        err_beat   = 2'd0;
        cpu_read(32'h0000_2000, dv, de);         // 新行 → 缺失，word0 即需求字
        chk("T8 demand beat error propagated", {31'b0, de}, 32'd1);
        inject_err = 1'b0;
        while (mem_read !== 1'b0) @(negedge clk);
        // 出错的行不得被分配：再访问同一地址应再次缺失
        begin : t8
            integer m_before;
            m_before = stat_miss;
            cpu_read(32'h0000_2000, dv, de);
            checks = checks + 1;
            if (stat_miss == m_before + 1)
                $display("PASS [T8b errored line not allocated] stat_miss %0d -> %0d",
                         m_before, stat_miss);
            else begin
                errors = errors + 1;
                $display("FAIL [T8b errored line not allocated] stat_miss %0d -> %0d",
                         m_before, stat_miss);
            end
        end

        // ---------------- T8c 需求 word 之后的 beat 出错：已交付响应合法，不追发 error ----------------
        inject_err = 1'b1;
        err_beat   = 2'd3;
        cpu_read(32'h0000_3000, dv, de);         // word0 已提前响应（数据合法）
        chk("T8c later beat error after early response does not change rsp", {31'b0, de}, 32'd0);
        // 保持 inject_err=1 直到后台 fill 收完，否则 beat3 的 error 根本不会发生。
        while (mem_read !== 1'b0) @(negedge clk);
        inject_err = 1'b0;
        // 后续 beat 出错仍不得分配残行
        begin : t8c
            integer m_before;
            m_before = stat_miss;
            cpu_read(32'h0000_3000, dv, de);
            checks = checks + 1;
            if (stat_miss == m_before + 1)
                $display("PASS [T8d later-error line not allocated] stat_miss %0d -> %0d",
                         m_before, stat_miss);
            else begin
                errors = errors + 1;
                $display("FAIL [T8d later-error line not allocated] stat_miss %0d -> %0d",
                         m_before, stat_miss);
            end
        end

        $display("==================================================");
        $display("  检查项: %0d   stat_hit=%0d stat_miss=%0d", checks, stat_hit, stat_miss);
        if (errors == 0)
            $display("  ALL TESTS PASSED (0 errors)");
        else
            $display("  %0d FAILED", errors);
        $display("==================================================");
        $finish;
    end

endmodule
