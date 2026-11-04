`timescale 1ns/1ps
`include "defines.sv"

// ============================================================================
//  tb_dcache_store_path —— D-Cache store/write-through 直达接口回归
//
//  被测：cpu_mem_subsystem（含 dcache + bridge + adapter + SRAM/ROM/GPIO）。
//  直接驱动冻结的 D 单字端口，覆盖 CPU-visible TB 不易构造的路径：
//    · 冷 load miss → warm hit；
//    · store-hit 写穿并更新命中行；
//    · store-miss/no-write-allocate（不分配行，后续 load 仍 miss）；
//    · 部分 byte strobe 的命中行合并；
//    · 写 ROM 由 adapter 返回 error，且不进入 D-Cache；
//    · MMIO store 继续 bypass，不污染 D-Cache store 计数；
//    · CPU response 背压期间 D-Cache 响应保持、不丢响应。
//
//  说明：adapter 请求端背压、写错误注入分别由已有 bridge/dcache 单元 TB 覆盖；
//        本 TB 只验证真实子系统级 store 路径与出口 owner。
// ============================================================================
module tb_dcache_store_path #(
    parameter POSTED_SRAM_WRITE_ACK = 1'b0
);

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    // D 侧冻结单字端口
    reg         d_req_valid = 1'b0;
    wire        d_req_ready;
    reg  [31:0] d_req_addr = 32'b0;
    reg         d_write = 1'b0;
    reg  [31:0] d_wdata = 32'b0;
    reg  [3:0]  d_wstrb = 4'b0;
    wire        d_rsp_valid;
    reg         d_rsp_ready = 1'b1;
    wire [31:0] d_rdata;
    wire        d_error;

    // I 侧端口全部 tie-off（本 TB 不取指）
    wire        i_req_ready, i_rsp_valid, i_error;
    wire [31:0] i_rdata;

    // 外设引脚
    wire [31:0] gpio_out;
    reg  [31:0] gpio_in = 32'h0;
    wire        timer_irq, uart_tx;

    integer checks = 0;
    integer errors = 0;
    integer wait_cnt = 0;
    integer sram_wr_fire = 0;      // adapter→SRAM 的单字写握手次数
    integer adp_wr_fire  = 0;      // D 侧 adapter 上游写握手次数（含 bypass error 请求）
    integer posted_same_cycle_acks = 0;
    reg [31:0] rom_word_before = 32'h0;
    reg [31:0] last_rsp_data = 32'h0;
    reg        last_rsp_error = 1'b0;

    cpu_mem_subsystem #(
        .MEM_DEPTH(256), .MEM_AW(8), .UART_DIV(4),
        .ICACHE_ENABLE(1'b1), .DCACHE_ENABLE(1'b1),
        .POSTED_SRAM_WRITE_ACK(POSTED_SRAM_WRITE_ACK)
    ) u_sub (
        .clk(clk), .rst(rst),
        .i_req_valid(1'b0), .i_req_ready(i_req_ready), .i_req_addr(32'b0),
        .i_write(1'b0), .i_wdata(32'b0), .i_wstrb(4'b0),
        .i_rsp_valid(i_rsp_valid), .i_rsp_ready(1'b1), .i_rdata(i_rdata), .i_error(i_error),
        .d_req_valid(d_req_valid), .d_req_ready(d_req_ready), .d_req_addr(d_req_addr),
        .d_write(d_write), .d_wdata(d_wdata), .d_wstrb(d_wstrb),
        .d_rsp_valid(d_rsp_valid), .d_rsp_ready(d_rsp_ready), .d_rdata(d_rdata), .d_error(d_error),
        .gpio_out(gpio_out), .gpio_in(gpio_in), .timer_irq(timer_irq),
        .uart_tx(uart_tx), .uart_rx(1'b1)
    );

    task chk32;
        input [255:0] name;
        input [31:0]  got;
        input [31:0]  want;
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

    task chk1;
        input [255:0] name;
        input         got;
        input         want;
        begin
            checks = checks + 1;
            if (got !== want) begin
                errors = errors + 1;
                $display("FAIL [%0s] got=%b want=%b", name, got, want);
            end else begin
                $display("PASS [%0s] = %b", name, got);
            end
        end
    endtask

    // Posted mode acknowledges queue admission; drain before inspecting SRAM.
    task wait_posted_drain;
        begin
            if (POSTED_SRAM_WRITE_ACK) begin
                wait_cnt = 0;
                while (u_sub.d_br_busy && wait_cnt < 200) begin
                    @(posedge clk);
                    wait_cnt = wait_cnt + 1;
                end
                if (u_sub.d_br_busy) begin
                    errors = errors + 1;
                    $display("FAIL [posted store drain timeout]");
                end
            end
        end
    endtask

    // 一笔 D 单字访问。hold_rsp>0 时先压住 d_rsp_ready，验证响应保持。
    task d_access;
        input [31:0] addr;
        input        wr;
        input [31:0] wdata;
        input [3:0]  wstrb;
        input [31:0] exp_data;
        input        exp_error;
        input integer hold_rsp;
        begin
            // 请求握手：在 negedge 呈现，posedge 采样 valid&&ready
            d_req_valid = 1'b0;
            d_rsp_ready = (hold_rsp == 0);
            @(negedge clk);
            d_req_valid = 1'b1;
            d_req_addr  = addr;
            d_write     = wr;
            d_wdata     = wdata;
            d_wstrb     = wstrb;

            wait_cnt = 0;
            while (!(d_req_valid && d_req_ready) && wait_cnt < 100) begin
                @(posedge clk);
                wait_cnt = wait_cnt + 1;
            end
            if (!(d_req_valid && d_req_ready)) begin
                errors = errors + 1;
                $display("FAIL [D request handshake timeout] addr=%08h wr=%b", addr, wr);
            end

            @(negedge clk);
            d_req_valid = 1'b0;

            if (hold_rsp > 0) begin
                // ready=0，响应必须保持；先等 valid，再压 N 拍
                wait_cnt = 0;
                while (!d_rsp_valid && wait_cnt < 200) begin
                    @(negedge clk);
                    wait_cnt = wait_cnt + 1;
                end
                if (!d_rsp_valid) begin
                    errors = errors + 1;
                    $display("FAIL [D response missing under backpressure] addr=%08h", addr);
                end
                repeat (hold_rsp) @(negedge clk);
                if (!d_rsp_valid) begin
                    errors = errors + 1;
                    $display("FAIL [D response dropped under backpressure] addr=%08h", addr);
                end
                d_rsp_ready = 1'b1;
                @(posedge clk);
            end else begin
                // ready=1：在 posedge 等 valid&&ready 的握手沿
                wait_cnt = 0;
                while (!(d_rsp_valid && d_rsp_ready) && wait_cnt < 200) begin
                    @(posedge clk);
                    wait_cnt = wait_cnt + 1;
                end
                if (!(d_rsp_valid && d_rsp_ready)) begin
                    errors = errors + 1;
                    $display("FAIL [D response handshake timeout] addr=%08h", addr);
                end
            end

            // 在握手沿之后、deassert 之前检查数据/错误
            if (d_rdata !== exp_data) begin
                errors = errors + 1;
                $display("FAIL [D data] addr=%08h got=%08h want=%08h", addr, d_rdata, exp_data);
            end
            if (d_error !== exp_error) begin
                errors = errors + 1;
                $display("FAIL [D error] addr=%08h got=%b want=%b", addr, d_error, exp_error);
            end
            last_rsp_data  = d_rdata;
            last_rsp_error = d_error;

            @(negedge clk);
            d_rsp_ready = 1'b1;
        end
    endtask

    initial begin
        #1;
        // SRAM word0 初值 42；ROM 给一个可辨识值用于“写 ROM 必须 error 且不改 ROM”
        {u_sub.u_sram_d.mem3[0], u_sub.u_sram_d.mem2[0], u_sub.u_sram_d.mem1[0], u_sub.u_sram_d.mem0[0]} = 32'd42;
        u_sub.u_rom_d.mem[0] = 32'h1234_5678;
        rom_word_before = u_sub.u_rom_d.mem[0];

        repeat (3) @(negedge clk);
        rst = 1'b0;
        repeat (2) @(negedge clk);

        // 1) 冷 load A：miss fill，读回 42
        d_access(32'h8000_0000, 1'b0, 32'h0, 4'h0, 32'd42, 1'b0, 0);
        chk32("T1 cold load A=42", last_rsp_data, 32'd42);
        chk32("T1 dcache miss=1", u_sub.u_dcache.stat_miss, 32'd1);
        chk32("T1 dcache store=0", u_sub.u_dcache.stat_store, 32'd0);

        // 2) store-hit A=99：写穿 + 更新命中行
        d_access(32'h8000_0000, 1'b1, 32'h0000_0063, 4'hf, 32'd0, 1'b0, 0);
        wait_posted_drain();
        chk32("T2 sram word0=99", {u_sub.u_sram_d.mem3[0], u_sub.u_sram_d.mem2[0], u_sub.u_sram_d.mem1[0], u_sub.u_sram_d.mem0[0]}, 32'd99);
        chk32("T2 dcache store=1", u_sub.u_dcache.stat_store, 32'd1);

        // 3) warm reload A：必须命中 dcache 且返回 99
        d_access(32'h8000_0000, 1'b0, 32'h0, 4'h0, 32'd99, 1'b0, 0);
        chk32("T3 warm load A=99", last_rsp_data, 32'd99);

        // 4) store-miss B (0x10) = 0x5A5A5A5A：不分配行，但写穿到 SRAM
        d_access(32'h8000_0010, 1'b1, 32'h5A5A_5A5A, 4'hf, 32'd0, 1'b0, 0);
        wait_posted_drain();
        chk32("T4 sram word4=5A5A5A5A", {u_sub.u_sram_d.mem3[4], u_sub.u_sram_d.mem2[4], u_sub.u_sram_d.mem1[4], u_sub.u_sram_d.mem0[4]}, 32'h5A5A_5A5A);
        chk32("T4 store miss increments miss", u_sub.u_dcache.stat_miss, 32'd2);
        chk32("T4 store count=2", u_sub.u_dcache.stat_store, 32'd2);

        // 5) load B：store 未分配 ⇒ 必须再 miss fill，返回写穿值
        d_access(32'h8000_0010, 1'b0, 32'h0, 4'h0, 32'h5A5A_5A5A, 1'b0, 0);
        chk32("T5 load B=5A5A5A5A", last_rsp_data, 32'h5A5A_5A5A);

        // 6) 部分 byte strobe：A 的 byte1 写 0xAB ⇒ 0x0000AB63
        d_access(32'h8000_0000, 1'b1, 32'h0000_AB00, 4'b0010, 32'd0, 1'b0,
                 POSTED_SRAM_WRITE_ACK ? 3 : 0);
        wait_posted_drain();
        chk32("T6 sram word0 partial=0000AB63", {u_sub.u_sram_d.mem3[0], u_sub.u_sram_d.mem2[0], u_sub.u_sram_d.mem1[0], u_sub.u_sram_d.mem0[0]}, 32'h0000_AB63);

        // 7) 部分写后 reload A：命中行必须返回合并后的 0x0000AB63
        d_access(32'h8000_0000, 1'b0, 32'h0, 4'h0, 32'h0000_AB63, 1'b0, 0);
        chk32("T7 partial reload=0000AB63", last_rsp_data, 32'h0000_AB63);

        // 8) 写 ROM：adapter error，D-Cache 不得吞掉；ROM 内容不变
        d_access(32'h0000_0000, 1'b1, 32'hDEAD_BEEF, 4'hf, 32'h0, 1'b1, 0);
        chk1("T8 ROM write error=1", last_rsp_error, 1'b1);
        chk32("T8 ROM content unchanged", u_sub.u_rom_d.mem[0], rom_word_before);
        chk32("T8 ROM store does not enter dcache", u_sub.u_dcache.stat_store, 32'd3);

        // 9) MMIO store 继续 bypass；GPIO 输出更新，D-Cache store 计数不增加
        d_access(32'h1000_0010, 1'b1, 32'h0000_0055, 4'hf, 32'd0, 1'b0, 0);
        chk32("T9 GPIO out=55", gpio_out, 32'h0000_0055);
        chk32("T9 MMIO store does not enter dcache", u_sub.u_dcache.stat_store, 32'd3);

        // In posted mode the D-cache bridge contract is limited to legal SRAM
        // writes; late adapter-error injection is covered only in legacy mode.
        if (!POSTED_SRAM_WRITE_ACK) begin
            force u_sub.ad_sram_error = 1'b1;
            d_access(32'h8000_0000, 1'b1, 32'hDEAD_BEEF, 4'hf, 32'h0, 1'b1, 0);
            release u_sub.ad_sram_error;
            chk1("T13 adapter write error propagated", last_rsp_error, 1'b1);
            chk32("T13 SRAM model write occurred", {u_sub.u_sram_d.mem3[0], u_sub.u_sram_d.mem2[0], u_sub.u_sram_d.mem1[0], u_sub.u_sram_d.mem0[0]}, 32'hDEAD_BEEF);
            d_access(32'h8000_0000, 1'b0, 32'h0, 4'h0, 32'h0000_AB63, 1'b0, 0);
            chk32("T13 error did not update dcache line", last_rsp_data, 32'h0000_AB63);
        end


        // 10) CPU response 背压：压 3 拍，响应 must hold，解除后正确交付
        d_access(32'h8000_0000, 1'b0, 32'h0, 4'h0, 32'h0000_AB63, 1'b0, 3);
        chk32("T10 backpressure reload=0000AB63", last_rsp_data, 32'h0000_AB63);

        // 最终计数：hit=7 miss=3 store=4
        chk32("T11 final dcache hit", u_sub.u_dcache.stat_hit,
              POSTED_SRAM_WRITE_ACK ? 32'd5 : 32'd7);
        chk32("T11 final dcache miss=3", u_sub.u_dcache.stat_miss, 32'd3);
        chk32("T11 final dcache store", u_sub.u_dcache.stat_store,
              POSTED_SRAM_WRITE_ACK ? 32'd3 : 32'd4);

        // Exactly-once write accounting: legacy mode includes T13's injected
        // SRAM error path; posted mode exercises the three legal cached stores.
        wait_posted_drain();
        chk32("T12 SRAM write fire exactly once per cacheable store", sram_wr_fire,
              POSTED_SRAM_WRITE_ACK ? 32'd3 : 32'd4);
        chk32("T12 adapter upstream write fire exactly once per D write", adp_wr_fire,
              POSTED_SRAM_WRITE_ACK ? 32'd5 : 32'd6);
        if (POSTED_SRAM_WRITE_ACK)
            chk32("T13 posted same-cycle cache store responses", posted_same_cycle_acks, 32'd3);

        if (errors == 0) begin
            $display("PASS [tb_dcache_store_path: checks=%0d]", checks);
            $display("ALL TESTS PASSED (tb_dcache_store_path)");
            $finish;
        end else begin
            $display("TESTS FAILED errors=%0d checks=%0d", errors, checks);
            $finish_and_return(1);
        end
    end

    // 写事务计数：adapter 上游握手 vs 真正进入 SRAM 的写穿。
    always @(posedge clk) begin
        if (!rst) begin
            if (u_sub.ad_sram_req_valid && u_sub.ad_sram_req_ready && u_sub.ad_sram_write)
                sram_wr_fire <= sram_wr_fire + 1;
            if (u_sub.d_adp_req_valid && u_sub.adp_d_req_ready && u_sub.d_adp_req_write)
                adp_wr_fire <= adp_wr_fire + 1;
            if (POSTED_SRAM_WRITE_ACK && d_rsp_valid &&
                u_sub.d_cp_wr_beat_valid && u_sub.d_cp_wr_beat_ready) begin
                posted_same_cycle_acks <= posted_same_cycle_acks + 1;
                if (u_sub.d_cp_wr_addr[31:16] != 16'h8000 ||
                    u_sub.d_cp_wr_addr[1:0] != 2'b00) begin
                    errors = errors + 1;
                    $display("FAIL [posted cache write outside aligned SRAM window] addr=%08h",
                             u_sub.d_cp_wr_addr);
                end
            end
        end
    end

endmodule
