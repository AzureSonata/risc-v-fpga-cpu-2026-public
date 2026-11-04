// ============================================================================
//  tb_mem_burst_bridge —— burst ⇄ 单字转换桥 定向测试（批 (d-0)，ADR-CACHE-INTEGRATION D-C4）
//
//  被测：rtl/memory/mem_burst_bridge.sv
//  协议基准：ADR-CACHE §2（beat 数据有效语义）+ icache/dcache 的实际驱动
//  （mem_read/mem_write 电平、rd_beat_ready 填充期恒 1、wr_beat_error 随接受沿采样）
//
//  覆盖：
//    T1 读突发顺序与 last：4 笔单字读按 line_addr+0/4/8/12 递增，beat 数据同序，第 4 拍 last
//    T2 错误逐 beat 透传：任一单字读 error → 对应 beat error=1，后续 beat 照常递出不截断，
//       last 仍在第 4 拍（分配/不分配的裁决归 cache，桥只透传）
//    T3 背靠背两次填充：无串拍、无丢 beat，每次 addr 序列重新对齐行基址
//    T4 双向背压：rd_beat_ready=0 时 beat 持有；req_ready=0 时 adapter 请求持有
//    T5 写穿成功：恰好 1 笔写请求（addr/wdata/wstrb 一致），wr_beat_ready 单拍 + error=0
//    T6 写穿错误：adapter error → wr_beat_error=1（与 wr_beat_ready 同拍，dcache 在该沿采样）
//    T7 方向切换：写完成后紧跟读突发，桥无残留状态
// ============================================================================
`timescale 1ns/1ps

module tb_mem_burst_bridge;
    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    // ---------------- DUT ----------------
    // cache 侧驱动**精确镜像 icache 的寄存行为**：
    //   mem_read = in_fill（寄存电平）；line_addr 在填充期保持；
    //   最后一拍握手（valid&&ready&&last）的**同一沿**撤销 in_fill ——
    //   晚一拍撤销会让桥在 IDLE 看到 mem_read 仍高而假重触发（实测踩过）。
    reg  [31:0] line_addr = 32'b0;
    reg         fill_req  = 1'b0;
    reg  [31:0] fill_base  = 32'b0;
    reg         in_fill    = 1'b0;
    wire        mem_read   = in_fill;
    reg         mem_write = 1'b0;
    reg  [31:0] wr_addr   = 32'b0;
    wire        rd_beat_valid, rd_beat_last, rd_beat_error, wr_beat_ready, wr_beat_error;
    wire [31:0] rd_beat_data;
    reg         rd_beat_ready = 1'b1;
    reg         wr_beat_valid = 1'b0;
    reg  [31:0] wr_beat_data  = 32'b0;
    reg  [3:0]  wr_beat_wstrb = 4'b0;
    wire        wr_beat_last  = 1'b1;   // dcache 恒 1，桥不使用

    always @(posedge clk) begin
        if (rst) begin
            in_fill  <= 1'b0;
            fill_req <= 1'b0;
        end else begin
            if (!in_fill && fill_req) begin
                in_fill   <= 1'b1;
                line_addr <= fill_base;      // 与 icache 一致：接受后锁存并保持
            end else if (in_fill && rd_beat_valid && rd_beat_ready && rd_beat_last) begin
                in_fill   <= 1'b0;           // 与 icache 一致：最后一拍握手同沿撤销
                fill_req  <= 1'b0;
            end
        end
    end

    wire        req_valid, req_write, rsp_ready;
    wire [31:0] req_addr, req_wdata;
    wire [3:0]  req_wstrb;
    reg         req_ready = 1'b1;
    reg         rsp_valid = 1'b0;
    reg  [31:0] rsp_rdata = 32'b0;
    reg         rsp_error = 1'b0;

    mem_burst_bridge dut (
        .clk(clk), .rst(rst),
        .line_addr(line_addr), .mem_read(mem_read), .mem_write(mem_write),
        .wr_addr(wr_addr),
        .rd_beat_valid(rd_beat_valid), .rd_beat_ready(rd_beat_ready),
        .rd_beat_data(rd_beat_data), .rd_beat_last(rd_beat_last),
        .rd_beat_error(rd_beat_error),
        .wr_beat_valid(wr_beat_valid), .wr_beat_ready(wr_beat_ready),
        .wr_beat_data(wr_beat_data), .wr_beat_wstrb(wr_beat_wstrb),
        .wr_beat_last(wr_beat_last), .wr_beat_error(wr_beat_error),
        .req_valid(req_valid), .req_ready(req_ready), .req_addr(req_addr),
        .req_write(req_write), .req_wdata(req_wdata), .req_wstrb(req_wstrb),
        .rsp_valid(rsp_valid), .rsp_ready(rsp_ready),
        .rsp_rdata(rsp_rdata), .rsp_error(rsp_error)
    );

    // ---------------- adapter 模型 ----------------
    // 接受请求后延时 rsp_delay 拍给出响应；数据/错误按注入寄存器决定。
    integer rsp_delay = 0;
    reg pending = 1'b0;
    reg [31:0] pend_addr = 32'b0, pend_wdata = 32'b0;
    reg [3:0]  pend_wstrb = 4'b0;
    reg        pend_write = 1'b0;
    reg [31:0] err_addr  = 32'hFFFF_FFFF;   // 该地址的响应带 error（读/写通用）
    reg [7:0]  req_count = 0;               // 收到的请求总数（检查"恰好 1 笔"等）

    always @(posedge clk) begin
        if (rst) begin
            pending <= 1'b0; rsp_valid <= 1'b0;
            rsp_delay <= 0; req_count <= 0;
        end else begin
            // 响应被消费时必须同时清 pending，否则旧响应会被
            // 下方的 setup 分支再次呈现（实测导致 beat 序列整体错位）
            if (rsp_valid && rsp_ready) begin
                rsp_valid <= 1'b0;
                pending   <= 1'b0;
            end
            if (req_valid && req_ready) begin
                req_count  <= req_count + 8'd1;
                pend_addr  <= req_addr;
                pend_wdata <= req_wdata;
                pend_wstrb <= req_wstrb;
                pend_write <= req_write;
                pending    <= 1'b1;
                rsp_delay  <= 2;               // 固定 2 拍响应延迟（可被场景改写）
            end
            if (pending && rsp_delay != 0)
                rsp_delay <= rsp_delay - 1;
            if (pending && rsp_delay == 0 && !rsp_valid) begin
                rsp_valid <= 1'b1;
                rsp_rdata <= ~pend_addr;        // 默认数据：地址取反，便于核对顺序
                rsp_error <= (pend_addr == err_addr);
            end
        end
    end

    // ---------------- 检查基础设施 ----------------
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

    // beat 采集（negedge 采样，避免与 DUT 边沿变化竞争）
    integer beats = 0;
    reg [31:0] beat_data_q [0:7];
    reg        beat_last_q [0:7];
    reg        beat_err_q  [0:7];
    always @(negedge clk) begin
        if (!rst && rd_beat_valid && rd_beat_ready) begin
            if (beats < 8) begin
                beat_data_q[beats] = rd_beat_data;
                beat_last_q[beats] = rd_beat_last;
                beat_err_q[beats]  = rd_beat_error;
            end
            beats = beats + 1;
        end
    end

    integer wr_fires = 0;
    reg wr_err_at_fire = 1'b0;
    always @(posedge clk) begin
        if (!rst && wr_beat_valid && wr_beat_ready) begin
            wr_fires = wr_fires + 1;
            wr_err_at_fire = wr_beat_error;
        end
    end

    // 请求地址采集（读方向）：在 req_fire 拍记下地址
    integer rd_reqs = 0;
    reg [31:0] rd_req_addr_q [0:7];
    always @(posedge clk) begin
        if (!rst && req_valid && req_ready && !req_write) begin
            if (rd_reqs < 8) rd_req_addr_q[rd_reqs] = req_addr;
            rd_reqs = rd_reqs + 1;
        end
    end

    // 等待 N 个握手（带超时）
    task automatic wait_beats(input integer n);
        integer seen, guard;
        begin
            seen = beats; guard = 0;
            while (beats < seen + n && guard < 500) begin
                @(posedge clk); guard = guard + 1;
            end
        end
    endtask

    task automatic do_read_burst(input [31:0] base);
        begin
            @(negedge clk);
            fill_req  = 1'b1;
            fill_base = base;
            wait_beats(4);
            // fill_req 已由镜像 FSM 在最后一拍握手的同沿清除（in_fill 同拍撤销）
            @(negedge clk);
        end
    endtask

    integer i;
    initial begin
        $display("==================================================");
        $display("  mem_burst_bridge 定向测试（批 (d-0)）");
        $display("==================================================");

        // ---------------- T1 读突发顺序与 last ----------------
        @(negedge clk); rst = 1'b0;
        do_read_burst(32'h0000_0100);
        chk("T1 beat count", beats, 4);
        chk("T1 read requests", rd_reqs, 4);
        for (i = 0; i < 4; i = i + 1) begin
            chk("T1 beat data seq", beat_data_q[i], ~(32'h0000_0100 + i*4));
            chk("T1 req addr seq", rd_req_addr_q[i], 32'h0000_0100 + i*4);
        end
        chk("T1 last on beat3", {31'b0, beat_last_q[3]}, 32'd1);
        chk("T1 no early last", {31'b0, beat_last_q[0]} + {31'b0, beat_last_q[1]} +
                                {31'b0, beat_last_q[2]}, 32'd0);
        chk("T1 no error", {31'b0, beat_err_q[0]} + {31'b0, beat_err_q[1]} +
                           {31'b0, beat_err_q[2]} + {31'b0, beat_err_q[3]}, 32'd0);

        // ---------------- T2 错误逐 beat 透传（beat2 出错，不截断） ----------------
        beats = 0; rd_reqs = 0;
        err_addr = 32'h0000_0104;               // 第 2 笔单字读出错
        do_read_burst(32'h0000_0100);
        err_addr = 32'hFFFF_FFFF;
        chk("T2 beat count", beats, 4);         // 出错后仍递满 4 beat（不截断）
        chk("T2 beat2 error", {31'b0, beat_err_q[1]}, 32'd1);
        chk("T2 others clean", {31'b0, beat_err_q[0]} + {31'b0, beat_err_q[2]} +
                               {31'b0, beat_err_q[3]}, 32'd0);
        chk("T2 last still on beat3", {31'b0, beat_last_q[3]}, 32'd1);
        chk("T2 beat2 data still delivered", beat_data_q[1], ~(32'h0000_0104));

        // ---------------- T3 背靠背两次填充 ----------------
        beats = 0; rd_reqs = 0;
        do_read_burst(32'h0000_0200);
        do_read_burst(32'h0000_0300);
        chk("T3 total beats", beats, 8);
        chk("T3 total requests", rd_reqs, 8);
        chk("T3 burst2 restarts base", rd_req_addr_q[4], 32'h0000_0300);
        chk("T3 burst2 word3", rd_req_addr_q[7], 32'h0000_030C);
        chk("T3 burst2 data3", beat_data_q[7], ~(32'h0000_030C));
        chk("T3 burst2 last", {31'b0, beat_last_q[7]}, 32'd1);

        // ---------------- T4 双向背压 ----------------
        beats = 0; rd_reqs = 0;
        @(negedge clk);
        rd_beat_ready = 1'b0;                    // cache 侧背压
        fill_req = 1'b1; fill_base = 32'h0000_0400;
        repeat (6) @(posedge clk);
        rd_beat_ready = 1'b1;                    // 放行
        wait_beats(4);
        @(negedge clk); fill_req = 1'b0;         // 兜底（正常已由镜像 FSM 清除）
        chk("T4 beats under backpressure", beats, 4);
        chk("T4 order preserved", beat_data_q[0], ~(32'h0000_0400));
        chk("T4 order preserved 3", beat_data_q[3], ~(32'h0000_040C));

        // ---------------- T5 写穿成功（恰好 1 笔请求） ----------------
        req_count = 0;
        @(negedge clk);
        wr_addr = 32'h8000_0100; wr_beat_data = 32'h0000_55AA;
        wr_beat_wstrb = 4'b1010; mem_write = 1'b1; wr_beat_valid = 1'b1;
        // 等 wr 握手（最多 100 拍）
        i = 0;
        while (wr_fires == 0 && i < 100) begin @(posedge clk); i = i + 1; end
        @(negedge clk);
        mem_write = 1'b0; wr_beat_valid = 1'b0;
        chk("T5 wr handshake once", wr_fires, 1);
        chk("T5 wr error=0", {31'b0, wr_err_at_fire}, 32'd0);
        chk("T5 exactly one request", req_count, 1);
        chk("T5 wr addr", pend_addr, 32'h8000_0100);
        chk("T5 wr wdata", pend_wdata, 32'h0000_55AA);
        chk("T5 wr wstrb", {28'b0, pend_wstrb}, 32'hA);
        chk("T5 is write", {31'b0, pend_write}, 32'd1);

        // ---------------- T6 写穿错误回传 ----------------
        wr_fires = 0;
        err_addr = 32'h8000_0200;
        @(negedge clk);
        wr_addr = 32'h8000_0200; wr_beat_data = 32'hDEAD_BEEF;
        wr_beat_wstrb = 4'b1111; mem_write = 1'b1; wr_beat_valid = 1'b1;
        i = 0;
        while (wr_fires == 0 && i < 100) begin @(posedge clk); i = i + 1; end
        @(negedge clk);
        mem_write = 1'b0; wr_beat_valid = 1'b0;
        err_addr = 32'hFFFF_FFFF;
        chk("T6 wr handshake once", wr_fires, 1);
        chk("T6 wr error=1", {31'b0, wr_err_at_fire}, 32'd1);

        // ---------------- T7 方向切换：写后紧跟读 ----------------
        beats = 0; rd_reqs = 0;
        do_read_burst(32'h0000_0500);
        chk("T7 post-write read beats", beats, 4);
        chk("T7 post-write base addr", rd_req_addr_q[0], 32'h0000_0500);
        chk("T7 post-write data0", beat_data_q[0], ~(32'h0000_0500));
        chk("T7 post-write last", {31'b0, beat_last_q[3]}, 32'd1);

        $display("==================================================");
        $display("  检查项: %0d", checks);
        if (errors == 0)
            $display("  ALL TESTS PASSED (0 errors)");
        else
            $display("  %0d FAILED", errors);
        $display("==================================================");
        if (errors != 0) $fatal(1, "bridge tests failed");
        $finish;
    end

    initial begin
        #100000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
