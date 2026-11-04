// ============================================================================
//  tb_icache_path_iso2 —— I 侧 Cache 路径隔离回归（批 (d-2) 排查用）
//
//  链路：cache_path(I) + icache + mem_burst_bridge + mem_map_adapter + rom
//  **不含 D 侧任何实例、不含 CPU**。激励：一次一笔、响应即取走。
//
//  ⚠️ 坑位（本 TB 存在的理由）：该链路在"顺序取指"上会挂死 ——
//     现象 `upR=1`（请求被接受）但 `ic=0/mr=0/cnt=0/hit=0/miss=0`（既未命中也没开始填充），
//     且 `cache_path` 内部 `sel_cache=x` ⇒ 缺陷在 **I 侧路径自身**，D 侧块只是暴露者
//     （d-1 属侥幸通过）。见日志 2026-09-30-03 与 lessons/LESSON-001。
//
//  ⚠️ 坑位（取文件时踩到）：`git show <rev>:<path> > file` 在 PowerShell 下写 UTF-16，
//     iverilog 完全读不了（无语法错）。⇒ 用 `git checkout <rev> -- <path>` 或编辑工具。
//     （见 lessons/LESSON-001 附录 T1/T3）
// ============================================================================
`timescale 1ns/1ps
`include "defines.sv"

module tb_icache_path_iso2;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    reg         up_valid = 1'b0;
    reg  [31:0] up_addr  = 32'h0;
    wire        up_ready, up_rsp_valid, up_rsp_error;
    wire [31:0] up_rsp_data;
    reg         up_rsp_ready = 1'b0;

    wire q_rom, q_sram, q_uart, q_gpio, q_timer, q_ac, q_ab, q_none;
    wire q_cacheable, q_read_only;
    addr_decode #(
        .ROM_BASE(32'h0000_0000), .ROM_SIZE(32'h0001_0000),
        .SRAM_BASE(32'h8000_0000), .SRAM_SIZE(32'h0001_0000),
        .UART_BASE(32'h1000_0000), .GPIO_BASE(32'h1000_0010), .TIMER_BASE(32'h1000_0020),
        .ACCEL_BASE(32'h4000_0000), .ACCEL_BUF_BASE(32'h4000_1000)
    ) u_dec_i (
        .addr(up_addr),
        .sel_rom(q_rom), .sel_sram(q_sram), .sel_uart(q_uart),
        .sel_gpio(q_gpio), .sel_timer(q_timer),
        .sel_accel_ctrl(q_ac), .sel_accel_buf(q_ab),
        .sel_none(q_none), .cacheable(q_cacheable), .read_only(q_read_only)
    );
    wire cacheable_eff = q_rom | q_sram;

    wire        cp_cv, cp_cr, cp_rv, cp_rr, cp_re;
    wire [31:0] cp_rd, cp_line;
    wire        cp_mr, cp_bv, cp_br, cp_bl, cp_be;
    wire [31:0] cp_bd;
    wire        cp_mw, cp_wv, cp_wrdy, cp_we;
    wire [31:0] cp_wa, cp_wd;
    wire [3:0]  cp_ws;
    wire        cp_wl;
    wire        br_rv, br_rr, br_rw;
    wire [31:0] br_ra, br_rwd, br_rd;
    wire [3:0]  br_rs;
    wire        br_sv, br_sr, br_se;
    wire        cv_rv, cv_rr, cv_rw;
    wire [31:0] cv_ra, cv_rwd, cv_rd;
    wire [3:0]  cv_rs;
    wire        cv_sv, cv_sr, cv_se;
    wire        by_rv, by_rw;
    wire [31:0] by_ra, by_rwd;
    wire [3:0]  by_rs;
    wire        by_sv, by_se, by_sr;
    wire [31:0] by_sd;
    wire        path_drv;
    wire        adp_rv, adp_rr, adp_rw;
    wire [31:0] adp_ra, adp_rwd, adp_rd;
    wire [3:0]  adp_rs;
    wire        adp_sv, adp_sr, adp_se;

    cache_path u_cp (
        .clk(clk), .rst(rst),
        .cache_en(1'b1), .cacheable(cacheable_eff),
        .up_req_valid(up_valid), .up_req_ready(up_ready),
        .up_req_addr(up_addr), .up_write(1'b0), .up_wdata(32'h0), .up_wstrb(4'h0),
        .up_rsp_valid(up_rsp_valid), .up_rsp_ready(up_rsp_ready),
        .up_rsp_data(up_rsp_data), .up_rsp_error(up_rsp_error),
        .cache_req_valid(cp_cv), .cache_req_ready(cp_cr),
        .cache_rsp_valid(cp_rv), .cache_rsp_ready(cp_rr),
        .cache_rsp_data(cp_rd), .cache_rsp_error(cp_re),
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
        .adapter_req_valid(cv_rv), .adapter_req_ready(cv_rr), .adapter_req_addr(cv_ra),
        .adapter_req_write(cv_rw), .adapter_req_wdata(cv_rwd), .adapter_req_wstrb(cv_rs),
        .adapter_rsp_valid(cv_sv), .adapter_rsp_ready(cv_sr),
        .adapter_rsp_rdata(cv_rd), .adapter_rsp_error(cv_se),
        .path_is_cache_o(), .path_drives_adapter_o(path_drv)
    );

    icache u_ic (
        .clk(clk), .rst(rst),
        .req_valid(cp_cv), .req_ready(cp_cr), .addr(up_addr),
        .write(1'b0), .wdata(32'h0), .wstrb(4'h0),
        .rsp_valid(cp_rv), .rsp_ready(cp_rr), .rdata(cp_rd), .error(cp_re),
        .line_addr(cp_line), .mem_read(cp_mr), .mem_write(cp_mw),
        .beat_valid(cp_bv), .beat_ready(cp_br), .beat_data(cp_bd),
        .beat_last(cp_bl), .beat_error(cp_be),
        .hit_o(), .stat_hit(), .stat_miss()
    );

    mem_burst_bridge u_br (
        .clk(clk), .rst(rst),
        .line_addr(cp_line), .mem_read(cp_mr), .mem_write(cp_mw), .wr_addr(cp_wa),
        .rd_beat_valid(cp_bv), .rd_beat_ready(cp_br), .rd_beat_data(cp_bd),
        .rd_beat_last(cp_bl), .rd_beat_error(cp_be),
        .wr_beat_valid(cp_wv), .wr_beat_ready(cp_wrdy), .wr_beat_data(cp_wd),
        .wr_beat_wstrb(cp_ws), .wr_beat_last(cp_wl), .wr_beat_error(cp_we),
        .req_valid(br_rv), .req_ready(br_rr), .req_addr(br_ra), .req_write(br_rw),
        .req_wdata(br_rwd), .req_wstrb(br_rs),
        .rsp_valid(br_sv), .rsp_ready(br_sr), .rsp_rdata(br_rd), .rsp_error(br_se)
    );

    assign br_rr = path_drv ? 1'b0 : adp_rr;
    assign br_sr = path_drv ? 1'b0 : adp_sv;
    assign cv_rr = br_rr;
    assign cv_sv = adp_sv;
    assign cv_rd = adp_rd;
    assign cv_se = adp_se;
    assign by_sr = cv_sr & path_drv;
    assign adp_sr = br_sr | by_sr;
    assign adp_rv  = path_drv ? by_rv  : br_rv;
    assign adp_ra  = path_drv ? by_ra  : br_ra;
    assign adp_rw  = path_drv ? by_rw  : br_rw;
    assign adp_rwd = path_drv ? by_rwd : br_rwd;
    assign adp_rs  = path_drv ? by_rs  : br_rs;
    assign br_sv   = adp_sv;
    assign br_rd   = adp_rd;
    assign br_se   = adp_se;
    assign by_sv   = adp_sv;
    assign by_sd   = adp_rd;
    assign by_se   = adp_se;

    wire        ai_rom_rv, ai_rom_rr, ai_rom_sv, ai_rom_sr, ai_rom_se;
    wire [31:0] ai_rom_a, ai_rom_d;
    wire        ai_cacheable, ai_ro;
    wire        un_rv, un_rr, un_sv, un_sr, un_e, un_w;
    wire [31:0] un_a, un_wd, un_rd;
    wire [3:0]  un_ws;

    mem_map_adapter #(.ACCEL_ENABLE(1'b0)) u_adp (
        .clk(clk), .rst(rst),
        .req_valid(adp_rv), .req_ready(adp_rr), .addr(adp_ra),
        .write(adp_rw), .wdata(adp_rwd), .wstrb(adp_rs),
        .rsp_valid(adp_sv), .rsp_ready(adp_sr), .rdata(adp_rd), .error(adp_se),
        .cacheable(ai_cacheable), .read_only(ai_ro),
        .rom_req_valid(ai_rom_rv), .rom_req_ready(ai_rom_rr), .rom_addr(ai_rom_a),
        .rom_rsp_valid(ai_rom_sv), .rom_rsp_ready(ai_rom_sr),
        .rom_rdata(ai_rom_d), .rom_error(ai_rom_se),
        .sram_req_valid(un_rv), .sram_req_ready(un_rr), .sram_addr(un_a),
        .sram_write(un_w), .sram_wdata(un_wd), .sram_wstrb(un_ws),
        .sram_rsp_valid(un_sv), .sram_rsp_ready(un_sr), .sram_rdata(un_rd), .sram_error(un_e),
        .uart_req_valid(), .uart_req_ready(1'b1), .uart_addr(),
        .uart_write(), .uart_wdata(), .uart_wstrb(),
        .uart_rsp_valid(1'b0), .uart_rsp_ready(), .uart_rdata(32'b0), .uart_error(1'b0),
        .gpio_req_valid(), .gpio_req_ready(1'b1), .gpio_addr(),
        .gpio_write(), .gpio_wdata(), .gpio_wstrb(),
        .gpio_rsp_valid(1'b0), .gpio_rsp_ready(), .gpio_rdata(32'b0), .gpio_error(1'b0),
        .timer_req_valid(), .timer_req_ready(1'b1), .timer_addr(),
        .timer_write(), .timer_wdata(), .timer_wstrb(),
        .timer_rsp_valid(1'b0), .timer_rsp_ready(), .timer_rdata(32'b0), .timer_error(1'b0),
        .accel_req_valid(), .accel_req_ready(1'b1), .accel_addr(),
        .accel_write(), .accel_wdata(), .accel_wstrb(),
        .accel_rsp_valid(1'b0), .accel_rsp_ready(), .accel_rdata(32'b0), .accel_error(1'b0)
    );
    assign un_rr = 1'b1; assign un_sv = 1'b0; assign un_rd = 32'b0; assign un_e = 1'b0;

    rom #(.DEPTH(256), .AW(8)) u_rom (
        .clk(clk), .rst(rst),
        .req_valid(ai_rom_rv), .req_ready(ai_rom_rr), .addr(ai_rom_a),
        .write(1'b0), .wdata(32'h0), .wstrb(4'h0),
        .rsp_valid(ai_rom_sv), .rsp_ready(ai_rom_sr),
        .rdata(ai_rom_d), .error(ai_rom_se)
    );

    // ---- 定向探针：复位后前 24 拍打印"路径判据"的每一分项，定位 sel_cache=x 的来源 ----
    integer pn = 0;
    always @(negedge clk) begin
        if (pn < 24) begin
            pn = pn + 1;
            $display("P t%0d up_addr=%h u_dec_i.addr=%h | EQ=%b | MY rom=%b sram=%b none=%b cb=%b ro=%b | ADP rom=%b sram=%b",
                pn, up_addr, u_dec_i.addr, (up_addr === u_dec_i.addr),
                q_rom, q_sram, q_none, q_cacheable, q_read_only,
                u_adp.sel_rom, u_adp.sel_sram);
        end
    end

    integer nreq = 0, nrsp = 0, fails = 0;

    integer wd = 0;
    always @(posedge clk) begin
        if (!rst) begin
            wd = wd + 1;
            if (wd > 2000) begin
                $display("WATCHDOG: upV=%b upR=%b upRV=%b | sel=%b lock=%b drv=%b cvV=%b | ic=%0d mr=%b cnt=%0d rspv=%b rr=%b | br=%0d rQ=%b rR=%b sQ=%b | adpV=%b adpR=%b adpSV=%b adpSR=%b romRV=%b romRR=%b",
                    up_valid, up_ready, up_rsp_valid,
                    u_cp.sel_cache, u_cp.path_locked, path_drv, cp_cv,
                    u_ic.state, u_ic.mem_read, u_ic.beat_cnt, u_ic.rsp_valid, cp_rr,
                    u_br.state, br_rv, br_rr, br_sv,
                    adp_rv, adp_rr, adp_sv, adp_sr, ai_rom_rv, ai_rom_rr);
                $display("  统计: 请求=%0d 响应=%0d hit=%0d miss=%0d", nreq, nrsp,
                         u_ic.stat_hit, u_ic.stat_miss);
                $finish;
            end
        end
    end

    task do_access(input integer idx, input [31:0] a);
        begin
            @(negedge clk);
            up_addr  = a;
            up_valid = 1'b1;
            @(negedge clk);
            while (!up_ready) @(negedge clk);
            nreq     = nreq + 1;
            up_valid = 1'b0;
            while (!up_rsp_valid) @(negedge clk);
            nrsp = nrsp + 1;
            if (up_rsp_data !== a) begin
                fails = fails + 1;
                $display("FAIL 访问 #%0d addr=%h 得 data=%h（期望 %h）—— 陈旧/错行",
                         idx, a, up_rsp_data, a);
            end else begin
                $display("PASS 访问 #%0d addr=%h data=%h", idx, a, up_rsp_data);
            end
            up_rsp_ready = 1'b1;
            @(negedge clk);
            up_rsp_ready = 1'b0;
        end
    endtask

    initial begin
        $display("==================================================");
        $display("  I 侧 Cache 路径隔离回归（无 D 侧、无 CPU）");
        $display("==================================================");
        u_rom.mem[0] = 32'h0000_0000; u_rom.mem[1] = 32'h0000_0004;
        u_rom.mem[2] = 32'h0000_0008; u_rom.mem[3] = 32'h0000_000C;
        u_rom.mem[4] = 32'h0000_0010; u_rom.mem[5] = 32'h0000_0014;
        u_rom.mem[6] = 32'h0000_0018; u_rom.mem[7] = 32'h0000_001C;
        repeat (3) @(posedge clk);
        rst = 1'b0;

        do_access(0,  32'h0000_0000);
        do_access(1,  32'h0000_0004);
        do_access(2,  32'h0000_0008);
        do_access(3,  32'h0000_000C);
        do_access(4,  32'h0000_0010);
        do_access(5,  32'h0000_0014);
        do_access(6,  32'h0000_0018);
        do_access(7,  32'h0000_001C);
        do_access(8,  32'h0000_0000);
        do_access(9,  32'h0000_0004);
        do_access(10, 32'h0000_0010);
        do_access(11, 32'h0000_000C);

        $display("--------------------------------------------------");
        $display("  请求=%0d 响应=%0d  icache hit=%0d miss=%0d",
                 nreq, nrsp, u_ic.stat_hit, u_ic.stat_miss);
        $display("  检查项: %0d 失败: %0d", nreq, fails);
        if (fails == 0) $display("  ALL ISO TESTS PASSED");
        else            $display("  %0d FAILED", fails);
        $display("==================================================");
        $finish;
    end

endmodule
