// ============================================================================
//  tb_icache_off_min —— 最小复现：ICACHE_ENABLE=0（纯 bypass）取指链为何挂死
//
//  背景（日志 2026-10-01/19）：(d-3) 四象限测量发现 `ICACHE_ENABLE=0` 下
//  **取指链完全挂死（inst=0）**，而该参数头注声称"1'b0 = 接入前的纯 bypass 行为"。
//  历史所有 TB 都跑默认值 1 ⇒ 这个"回退开关"从未被验证。
//
//  本 TB 只装必要件：cache_path(cache_en=0) + mem_map_adapter + rom，
//  地址图**只有一份实例**（在 adapter 内，符合 LESSON-001 T6 的修法），
//  故不会引入"同模块双实例不求值"的老坑。
//
//  判据：连续 4 笔 ROM 取指必须全部拿到正确数据。
// ============================================================================
`timescale 1ns/1ps
`include "defines.sv"

module tb_icache_off_min;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    // ---------------- CPU 单字 I 端口 ----------------
    reg         up_valid = 1'b0;
    reg  [31:0] up_addr  = 32'h0;
    wire        up_ready, up_rsp_valid, up_rsp_error;
    wire [31:0] up_rsp_data;
    reg         up_rsp_ready = 1'b0;

    // ---------------- cache_path 端口 ----------------
    wire        cv_rv, cv_rr, cv_rw;
    wire [31:0] cv_ra, cv_rwd, cv_rd;
    wire [3:0]  cv_rs;
    wire        cv_sv, cv_sr, cv_se;
    wire        cp_cr, cp_rv, cp_rr, cp_re;
    wire [31:0] cp_rd, cp_line;
    wire        cp_mr, cp_bv, cp_br, cp_bl, cp_be;
    wire [31:0] cp_bd;
    wire        cp_mw, cp_wv, cp_wrdy, cp_we;
    wire [31:0] cp_wa, cp_wd;
    wire [3:0]  cp_ws;
    wire        cp_wl;
    wire        by_rv, by_rw;
    wire [31:0] by_ra, by_rwd;
    wire [3:0]  by_rs;
    wire        by_sv, by_se;
    wire [31:0] by_sd;
    wire        path_drv, path_is_cache;

    // adapter 单字口
    wire        adp_rv, adp_rr, adp_rw;
    wire [31:0] adp_ra, adp_rwd, adp_rd;
    wire [3:0]  adp_rs;
    wire        adp_sv, adp_sr, adp_se;

    // 本 TB 不使用 Cache 路径（cache_en=0）
    cache_path u_cp (
        .clk(clk), .rst(rst),
        .cache_en(1'b0), .cacheable(1'b1),          // ★ 使能位固定 0 = 纯 bypass
        .up_req_valid(up_valid), .up_req_ready(up_ready),
        .up_req_addr(up_addr), .up_write(1'b0), .up_wdata(32'h0), .up_wstrb(4'h0),
        .up_rsp_valid(up_rsp_valid), .up_rsp_ready(up_rsp_ready),
        .up_rsp_data(up_rsp_data), .up_rsp_error(up_rsp_error),
        .cache_req_valid(cv_rv), .cache_req_ready(cv_rr),
        .cache_rsp_valid(cv_sv), .cache_rsp_ready(cv_sr),
        .cache_rsp_data(cv_rd), .cache_rsp_error(cv_se),
        .cache_line_addr(cp_line), .cache_mem_read(cp_mr),
        .cache_beat_valid(cp_bv), .cache_beat_ready(cp_br),
        .cache_beat_data(cp_bd), .cache_beat_last(cp_bl), .cache_beat_error(cp_be),
        .cache_mem_write(cp_mw), .cache_wr_addr(cp_wa),
        .cache_wr_beat_valid(cp_wv), .cache_wr_beat_ready(cp_wrdy),
        .cache_wr_beat_data(cp_wd), .cache_wr_beat_wstrb(cp_ws),
        .cache_wr_beat_last(cp_wl), .cache_wr_beat_error(cp_we),
        .bypass_req_valid(by_rv), .bypass_req_addr(by_ra), .bypass_req_write(by_rw),
        .bypass_req_wdata(by_rwd), .bypass_req_wstrb(by_rs),
        .bypass_rsp_valid(by_sv), .bypass_rsp_data(by_sd), .bypass_rsp_error(by_se),
        .adapter_req_valid(adp_rv), .adapter_req_ready(adp_rr), .adapter_req_addr(adp_ra),
        .adapter_req_write(adp_rw), .adapter_req_wdata(adp_rwd), .adapter_req_wstrb(adp_rs),
        .adapter_rsp_valid(adp_sv), .adapter_rsp_ready(adp_sr),
        .adapter_rsp_rdata(adp_rd), .adapter_rsp_error(adp_se),
        .path_is_cache_o(path_is_cache), .path_drives_adapter_o(path_drv)
    );

    // ---------------- adapter + ROM（地址图唯一实例在 adapter 内）----------------
    wire        rom_rv, rom_rr, rom_sv, rom_sr, rom_er;
    wire [31:0] rom_a, rom_rd;
    wire        q_rom, q_sram, q_uart, q_gpio, q_timer, q_ac, q_ab, q_none;
    wire        ad_cacheable, ad_read_only, sel_rom_o;

    mem_map_adapter #(.ACCEL_ENABLE(1'b0)) u_adp (
        .clk(clk), .rst(rst),
        .req_valid(adp_rv), .req_ready(adp_rr), .addr(adp_ra),
        .write(adp_rw), .wdata(adp_rwd), .wstrb(adp_rs),
        .rsp_valid(adp_sv), .rsp_ready(adp_sr), .rdata(adp_rd), .error(adp_se),
        .cacheable(ad_cacheable), .read_only(ad_read_only), .sel_rom(sel_rom_o),
        .rom_req_valid(rom_rv), .rom_req_ready(rom_rr), .rom_addr(rom_a),
        .rom_rsp_valid(rom_sv), .rom_rsp_ready(rom_sr), .rom_rdata(rom_rd), .rom_error(rom_er),
        .sram_req_valid(), .sram_req_ready(1'b0), .sram_addr(),
        .sram_write(), .sram_wdata(), .sram_wstrb(),
        .sram_rsp_valid(1'b0), .sram_rsp_ready(), .sram_rdata(32'h0), .sram_error(1'b0),
        .uart_req_valid(), .uart_req_ready(1'b0), .uart_addr(),
        .uart_write(), .uart_wdata(), .uart_wstrb(),
        .uart_rsp_valid(1'b0), .uart_rsp_ready(), .uart_rdata(32'h0), .uart_error(1'b0),
        .gpio_req_valid(), .gpio_req_ready(1'b0), .gpio_addr(),
        .gpio_write(), .gpio_wdata(), .gpio_wstrb(),
        .gpio_rsp_valid(1'b0), .gpio_rsp_ready(), .gpio_rdata(32'h0), .gpio_error(1'b0),
        .timer_req_valid(), .timer_req_ready(1'b0), .timer_addr(),
        .timer_write(), .timer_wdata(), .timer_wstrb(),
        .timer_rsp_valid(1'b0), .timer_rsp_ready(), .timer_rdata(32'h0), .timer_error(1'b0),
        .accel_req_valid(), .accel_req_ready(1'b0), .accel_addr(),
        .accel_write(), .accel_wdata(), .accel_wstrb(),
        .accel_rsp_valid(1'b0), .accel_rsp_ready(), .accel_rdata(32'h0), .accel_error(1'b0)
    );

    rom #(.DEPTH(256), .AW(8)) u_rom (
        .clk(clk), .rst(rst),
        .req_valid(rom_rv), .req_ready(rom_rr), .addr(rom_a),
        .rsp_valid(rom_sv), .rsp_ready(rom_sr), .rdata(rom_rd), .error(rom_er)
    );

    integer fails = 0, noreq = 0;

    // ---- 逐拍打点（§7.5；定位后移除）----
    always @(negedge clk)
        $display("P t=%0t rst=%b up v=%b r=%b | lock=%b selq=%b drv=%b | adp rv=%b rr=%b sv=%b sr=%b rd=%h sel=%b | rom rv=%b rr=%b sv=%b | adp_sel_enc=%b adp_errp=%b",
            $time, rst, up_valid, up_ready,
            u_cp.path_locked, u_cp.path_sel_q, path_drv,
            adp_rv, adp_rr, adp_sv, adp_sr, adp_rd, u_adp.rsp_sel_q,
            rom_rv, rom_rr, rom_sv,
            u_adp.sel_enc, u_adp.err_pending_q);

    task do_fetch(input [31:0] a, input [32:0] exp);
        integer k;
        begin
            // ⚠️ 坑位（本 TB 首版自身错）：等待响应期间**必须保持 up_rsp_ready=0**。
            //    若一直置 1，响应落进 skid 的**当拍就被消费**（skid 立即清空），
            //    negedge 采样只能看到"已变低"⇒ 误判成"无响应"。
            //    （与 tb_payload_hold 的"先撤 ready 再发请求"同一类错，见 §7.1/§7.4）
            up_rsp_ready = 1'b0;
            up_addr  = a;
            up_valid = 1'b1;
            k = 0;
            while (!(up_valid && up_ready) && k < 20) begin @(negedge clk); k = k + 1; end
            if (!(up_valid && up_ready)) begin
                fails = fails + 1; noreq = noreq + 1;
                $display("FAIL 取指 addr=%h：20 拍内 req 未被接受（up_ready=%b path_drv=%b uprsp_v=%b）",
                         a, up_ready, path_drv, up_rsp_valid);
            end else begin
                $display("      req accepted addr=%h（%0d 拍）", a, k);
            end
            up_valid = 1'b0;
            k = 0;
            while (!up_rsp_valid && k < 20) begin @(negedge clk); k = k + 1; end
            if (!up_rsp_valid) begin
                fails = fails + 1;
                $display("FAIL 取指 addr=%h：20 拍内无响应（path_drv=%b）", a, path_drv);
            end else if (up_rsp_data !== exp[31:0]) begin
                fails = fails + 1;
                $display("FAIL 取指 addr=%h data=%h（期望 %h）", a, up_rsp_data, exp[31:0]);
            end else begin
                $display("PASS 取指 addr=%h data=%h（响应等 %0d 拍）", a, up_rsp_data, k);
            end
            up_rsp_ready = 1'b1;              // 消费这一笔
            @(negedge clk);
            up_rsp_ready = 1'b0;
        end
    endtask

    integer t = 0;
    always @(posedge clk) begin
        if (!rst) begin
            t = t + 1;
            if (t > 2000) begin
                $display("*** TIMEOUT *** up_ready=%b up_rsp_v=%b path_drv=%b path_is_cache=%b adp_rv=%b adp_rr=%b adp_sv=%b",
                         up_ready, up_rsp_valid, path_drv, path_is_cache, adp_rv, adp_rr, adp_sv);
                $display("MIN-RESULT TIMEOUT fails=%0d", fails);
                $finish;
            end
        end
    end

    initial begin
        $display("==================================================");
        $display("  最小复现：cache_en=0（纯 bypass）取指链");
        $display("==================================================");
        u_rom.mem[0] = 32'h1111_1111;
        u_rom.mem[1] = 32'h2222_2222;
        u_rom.mem[2] = 32'h3333_3333;
        u_rom.mem[3] = 32'h4444_4444;
        repeat (3) @(posedge clk);
        @(negedge clk); rst = 1'b0;

        do_fetch(32'h0000_0000, 32'h1111_1111);
        do_fetch(32'h0000_0004, 32'h2222_2222);
        do_fetch(32'h0000_0008, 32'h3333_3333);
        do_fetch(32'h0000_000C, 32'h4444_4444);

        $display("==================================================");
        $display("  失败: %0d（其中 req 未被接受 %0d 次）", fails, noreq);
        if (fails == 0) $display("  ALL TESTS PASSED (cache_en=0 bypass 取指链可用)");
        else            $display("  %0d FAILED ⇒ cache_en=0 路径确有缺陷", fails);
        $display("==================================================");
        $finish;
    end

endmodule
