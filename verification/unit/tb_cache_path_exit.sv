// ============================================================================
//  tb_cache_path_exit —— 内存出口"登记式响应 + 独占保持"契约回归
//
//  依据：docs/architecture/ADR-MEM-EXIT-001（验收判据 E2/E3）
//
//  ⚠️ 坑位（本 TB 存在的理由）：`cache_path` 曾把 adapter 响应消费挂在 CPU 的
//     `up_rsp_ready` 上（`adapter_rsp_ready = bypass_done`，而 bypass_done 含
//     up_rsp_ready）。而 `mem_map_adapter` 的从设备 ready 是 `rsp_ready & sel`
//     直连门控 ⇒ **闭环反压**：下游一卡（IF 的 buf_full / 流水 hold / 重定向 drain）
//     就再也走不完握手，adapter 的 req_ready 被占住 ⇒ 永久死锁。
//     正确做法：响应**无条件登记进 1 深度 skid**，再由 skid 交付给 CPU。
//
//  本 TB 用"忠实模拟 mem_map_adapter 响应语义"的从设备：
//    · 接受请求 → 下一拍给出响应，`rsp_valid` **保持到 rsp_ready=1**
//      （adapter 内部 `slave_rsp_ready = rsp_ready & sel`，adapter 不给就撤不回来）
//    · 未完成响应时不再接受新请求（`rsp_valid` 占住出口）
//
//  ---- 用例 ----
//    B1 常规 bypass 读：下游当拍/次拍就绪 → 正常完成
//    B2 **下游卡住**（up_rsp_ready 连续 0，模拟 buf_full / hold）：响应仍须被登记
//       到 skid，解除后**恰好一次**交付给 CPU            ← E2
//    B3 连续 4 笔 bypass 事务：请求数 == 响应数，无丢无重 ← E3
//    B4 反向突变（-DTB_MUTATE_NO_SKID）：把响应侧恢复成旧式组合依赖，
//       B2 必须失败（挂死 / 露出 adapter 已给响应但 CPU 拿不到）—— 证明本 TB 有鉴别力
//    B8 Cache 响应与新 bypass 请求同拍：不得把新请求误发给仍锁定的 Cache
//
//  运行（Icarus 10.2）：
//    iverilog -g2005 -I rtl/core -o tb.vvp verification/unit/tb_cache_path_exit.sv rtl/memory/cache_path.sv
//    vvp tb.vvp
//  ⚠️ 坑位：PowerShell `>` / Set-Content 会写 UTF-16 或带 BOM，Icarus 10.2 会**静默跳过**
//     带 BOM 的文件（表现为 "Unable to find the root module"）。本文件必须保持 UTF-8 无 BOM。
// ============================================================================
`timescale 1ns/1ps
`include "defines.sv"

module tb_cache_path_exit;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    integer cyc = 0;
    always @(posedge clk) cyc = cyc + 1;
    localparam integer CYC_LIMIT = 400;      // 看门狗：超过即判定挂死

    // ---------------- 上游（CPU 单字端口） ----------------
    reg         up_valid = 1'b0;
    reg  [31:0] up_addr  = 32'h0;
    reg         up_write = 1'b0;
    wire        up_ready, up_rsp_valid, up_rsp_error;
    wire [31:0] up_rsp_data;
    reg         up_rsp_ready = 1'b0;
    reg         cacheable = 1'b0;            // 0 ⇒ 走 bypass 路径（本 TB 的主战场）
    reg         cache_busy_tb = 1'b0;        // A2b：后台 fill 占用 adapter
    reg         cache_req_ready_tb = 1'b0;   // 模拟 icache 在当前配置下的 req_ready
    reg         cache_rsp_valid_tb = 1'b0;
    reg  [31:0] cache_rsp_data_tb = 32'b0;

    // ---------------- cache_path 端口网 ----------------
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

    wire        adp_rv, adp_rr, adp_rw;
    wire [31:0] adp_ra, adp_rwd, adp_rd;
    wire [3:0]  adp_rs;
    wire        adp_sv, adp_sr, adp_se;

    cache_path u_cp (
        .clk(clk), .rst(rst),
        .cache_en(1'b1), .cacheable(cacheable),
        .cache_busy_i(cache_busy_tb),
        .up_req_valid(up_valid), .up_req_ready(up_ready),
        .up_req_addr(up_addr), .up_write(up_write), .up_wdata(32'h0), .up_wstrb(4'h0),
        .up_rsp_valid(up_rsp_valid), .up_rsp_ready(up_rsp_ready),
        .up_rsp_data(up_rsp_data), .up_rsp_error(up_rsp_error),
        // Cache 侧本 TB 不使用（cacheable=0，永不选中）：给常量以便观察
        .cache_req_valid(cp_cr), .cache_req_ready(cache_req_ready_tb),
        .cache_rsp_valid(cache_rsp_valid_tb), .cache_rsp_ready(cp_rr),
        .cache_rsp_data(cache_rsp_data_tb), .cache_rsp_error(1'b0),
        .cache_line_addr(cp_line), .cache_mem_read(cp_mr),
        .cache_beat_valid(1'b0), .cache_beat_ready(cp_br),
        .cache_beat_data(32'h0), .cache_beat_last(1'b0), .cache_beat_error(1'b0),
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

    // ------------------------------------------------------------------
    // 从设备（忠实模拟 mem_map_adapter + ROM 的响应语义）
    //   · 接受请求 → 下一拍 rsp_valid=1，**保持到 rsp_ready=1**（撤不回来）
    //   · 有未取走响应时不再接受新请求
    // ------------------------------------------------------------------
    reg         dev_busy;
    reg  [31:0] dev_data;
    reg         dev_rsp_v;

    assign adp_rr = !dev_rsp_v;
    assign adp_sv = dev_rsp_v;
    assign adp_rd = dev_data;
    assign adp_se = 1'b0;

    // 观察用：从设备"已把响应交到出口"的时刻（CPU 侧看不到，仅本 TB 层次可见）
    wire dev_delivered = dev_rsp_v;

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            dev_busy  <= 1'b0;
            dev_rsp_v <= 1'b0;
            dev_data  <= 32'h0;
        end else begin
            if (adp_rv && adp_rr) begin          // 接受请求，下一拍出响应
                dev_data  <= adp_ra ^ 32'hA5A5_0000;
                dev_rsp_v <= 1'b1;
            end else if (dev_rsp_v && adp_sr) begin
                dev_rsp_v <= 1'b0;               // 被取走
            end
        end
    end

    // ---------------- 统计与检查 ----------------
    integer nreq = 0, nrsp = 0, fails = 0;
    integer dev_rsp_seen = 0;        // 从设备给出响应的次数
    integer cache_nreq = 0, cache_nrsp = 0;
    always @(posedge clk) if (rst != `RstEnable && adp_sv) dev_rsp_seen = dev_rsp_seen + 1;

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            cache_rsp_valid_tb <= 1'b0;
            cache_rsp_data_tb <= 32'b0;
        end else begin
            if (cp_cr && cache_req_ready_tb) begin
                cache_nreq <= cache_nreq + 1;
                cache_rsp_valid_tb <= 1'b1;
                cache_rsp_data_tb <= up_addr ^ 32'h5A5A_0000;
            end else if (cache_rsp_valid_tb && cp_rr) begin
                cache_nrsp <= cache_nrsp + 1;
                cache_rsp_valid_tb <= 1'b0;
            end
            if (cache_rsp_valid_tb && cp_rr && cp_cr && cache_req_ready_tb)
                cache_nrsp <= cache_nrsp + 1;
        end
    end

    task do_bypass_read(input [31:0] a, input integer stall_cycles, input integer idx);
        integer k;
        begin
            // ⚠️ 坑位：必须先撤 up_rsp_ready 再发请求。若像最初那样在"等待 up_ready 的手摇
            //    循环"里保持 ready=1，响应会在请求被接受的下一拍就被顺手取走（skid 立即清空），
            //    E2 的检查点被绕过 ⇒ 出现假失败（数据/计数全对但 skid 检查为空）。
            up_rsp_ready = 1'b0;
            @(negedge clk);
            up_addr = a;
            up_valid = 1'b1;
            k = 0;
            while (up_ready !== 1'b1 && k < 50) begin
                @(negedge clk);
                k = k + 1;
            end
            if (up_ready !== 1'b1) begin
                fails = fails + 1;
                $display("FAIL 访问 #%0d：请求未能就绪", idx);
            end
            @(posedge clk); #1;
            nreq = nreq + 1;
            up_valid = 1'b0;

            // 下游故意卡住若干拍（模拟 IF buf_full / 流水 hold / 重定向 drain）
            // 检查点取在**卡住窗口的末尾**：从设备接受请求后需要一拍才给出响应，
            // 窗口起点那一拍 skid 必然还是空的。
            for (k = 0; k < stall_cycles; k = k + 1) begin
                @(posedge clk);
                @(negedge clk);
            end

            // ★ E2 核心检查：下游全程未 ready 的情况下，从设备的响应**仍必须已登记**，
            //    即出口没有被下游 ready 反压（旧实现这里 up_rsp_valid 恒 0 ⇒ 闭环死锁）。
            //    ⚠️ 坑位：探针**必须用 up_rsp_valid**（DUT 输出）。最初误用 bypass_rsp_valid
            //       —— 它在原设计里是"外部驱动"的口，本 TB 未连接时恒 0，探针等于看常量 0，
            //       于是出现"数据全对却报 skid 空"的假失败。
            if (stall_cycles > 0 && !(up_rsp_valid === 1'b1)) begin
                fails = fails + 1;
                $display("FAIL 访问 #%0d：下游卡住 %0d 拍后响应仍未登记 ⇒ 出口被下游 ready 反压（闭环死锁前兆）",
                         idx, stall_cycles);
            end else if (stall_cycles > 0) begin
                $display("      · 卡住 %0d 拍期间响应已登记（E2 成立）", stall_cycles);
            end

            // 释放下游，响应应交到 CPU 且恰好一次
            up_rsp_ready = 1'b1;
            k = 0;
            while (!up_rsp_valid && k < 50) begin @(negedge clk); k = k + 1; end
            if (!up_rsp_valid) begin
                fails = fails + 1;
                $display("FAIL 访问 #%0d：解除卡住后 up_rsp_valid 未在 50 拍内有效（响应丢失）", idx);
            end else begin
                nrsp = nrsp + 1;
                if (up_rsp_data !== (a ^ 32'hA5A5_0000)) begin
                    fails = fails + 1;
                    $display("FAIL 访问 #%0d addr=%h data=%h（期望 %h）—— 数据错/串行",
                             idx, a, up_rsp_data, a ^ 32'hA5A5_0000);
                end else begin
                    $display("PASS 访问 #%0d addr=%h data=%h 卡住%0d拍后正确交付",
                             idx, a, up_rsp_data, stall_cycles);
                end
            end
            @(negedge clk);                       // 消费该拍
            up_rsp_ready = 1'b0;
            @(negedge clk);
        end
    endtask

    task do_cache_response_turnover;
        begin
            cacheable = 1'b1;
            cache_req_ready_tb = 1'b1;
            up_rsp_ready = 1'b1;
            up_write = 1'b0;
            @(negedge clk);
            up_addr = 32'h8000_0100;
            up_valid = 1'b1;
            if (up_ready !== 1'b1) begin
                fails = fails + 1;
                $display("FAIL [B7] first cache request was not ready");
            end
            @(posedge clk);
            @(negedge clk);
            up_addr = 32'h8000_0104;
            if (up_ready !== 1'b1 || cp_cr !== 1'b1 || cp_rr !== 1'b1) begin
                fails = fails + 1;
                $display("FAIL [B7] replacement request not accepted with old response ready=%b req=%b rsp_ready=%b",
                         up_ready, cp_cr, cp_rr);
            end
            @(posedge clk);
            @(negedge clk);
            up_valid = 1'b0;
            if (up_rsp_valid !== 1'b1 ||
                up_rsp_data !== (32'h8000_0104 ^ 32'h5A5A_0000) ||
                u_cp.path_locked !== 1'b1) begin
                fails = fails + 1;
                $display("FAIL [B7] replacement response/owner lost valid=%b data=%08x locked=%b",
                         up_rsp_valid, up_rsp_data, u_cp.path_locked);
            end
            @(posedge clk);
            @(negedge clk);
            if (up_ready !== 1'b1 || u_cp.path_locked !== 1'b0 ||
                cache_nreq != 2 || cache_nrsp != 2) begin
                fails = fails + 1;
                $display("FAIL [B7] turnover accounting req=%0d rsp=%0d ready=%b locked=%b",
                         cache_nreq, cache_nrsp, up_ready, u_cp.path_locked);
            end else begin
                $display("PASS [B7] same-cache response edge accepts replacement in order");
            end
            up_rsp_ready = 1'b0;
            cacheable = 1'b0;
            cache_req_ready_tb = 1'b0;
        end
    endtask

    task do_cache_to_bypass_no_ghost;
        begin
            up_rsp_ready = 1'b0;
            cacheable = 1'b1;
            cache_req_ready_tb = 1'b1;
            up_write = 1'b0;
            @(negedge clk);
            up_addr = 32'h8000_0200;
            up_valid = 1'b1;
            #1;
            if (up_ready !== 1'b1 || cp_cr !== 1'b1) begin
                fails = fails + 1;
                $display("FAIL [B8] initial Cache request was not accepted");
            end
            @(posedge clk); #1;
            up_valid = 1'b0;
            if (u_cp.path_locked !== 1'b1 || u_cp.path_sel_q !== 1'b1 ||
                cache_rsp_valid_tb !== 1'b1) begin
                fails = fails + 1;
                $display("FAIL [B8] Cache response/owner was not established");
            end

            // Keep a new bypass request live on the exact edge that consumes
            // the old Cache response. It must wait for path unlock and must
            // never handshake at the Cache port without an upstream handshake.
            @(negedge clk);
            cacheable = 1'b0;
            up_addr = 32'h2000_0020;
            up_valid = 1'b1;
            up_rsp_ready = 1'b1;
            #1;
            if (up_ready !== 1'b0 || cp_rr !== 1'b1 || adp_rv !== 1'b0) begin
                fails = fails + 1;
                $display("FAIL [B8] expected old Cache response only: up_ready=%b cache_rsp_ready=%b adapter_req=%b",
                         up_ready, cp_rr, adp_rv);
            end
            if (cp_cr !== 1'b0) begin
                fails = fails + 1;
                $display("FAIL [B8] bypass request leaked to Cache: cache_req_valid=%b cache_req_ready=%b",
                         cp_cr, cache_req_ready_tb);
            end
            @(posedge clk); #1;
            if (u_cp.path_locked !== 1'b0) begin
                fails = fails + 1;
                $display("FAIL [B8] old Cache response did not release its owner");
            end
            up_valid = 1'b0;
            up_rsp_ready = 1'b0;
            cacheable = 1'b0;
            cache_req_ready_tb = 1'b0;
            @(negedge clk);
            if (fails == 0)
                $display("PASS [B8] cache→bypass boundary does not create an unowned Cache request");
        end
    endtask

    task do_bypass_read_with_live_redecode(input [31:0] a, input [31:0] changed_addr);
        integer k;
        begin
            up_rsp_ready = 1'b0;
            cacheable = 1'b0;
            @(negedge clk);
            up_addr = a;
            up_valid = 1'b1;
            k = 0;
            while (up_ready !== 1'b1 && k < 50) begin
                @(negedge clk);
                k = k + 1;
            end
            if (up_ready !== 1'b1) begin
                fails = fails + 1;
                $display("FAIL route-change request was not ready");
            end
            @(posedge clk); #1;
            nreq = nreq + 1;
            up_valid = 1'b0;

            // Change the live decode while the bypass response is in flight.
            // The saved bypass owner must keep selecting its own response.
            cacheable = 1'b1;
            up_addr = changed_addr;
            k = 0;
            while (!up_rsp_valid && k < 20) begin
                @(negedge clk);
                k = k + 1;
            end
            #1;
            if (up_rsp_valid === 1'b1 && up_rsp_data === (a ^ 32'hA5A5_0000) &&
                up_rsp_error === 1'b0 && path_is_cache === 1'b0 &&
                u_cp.path_locked === 1'b1 && u_cp.path_sel_q === 1'b0) begin
                $display("PASS registered bypass owner survives live address/cacheability change");
            end else begin
                fails = fails + 1;
                $display("FAIL response owner followed live decode: valid=%b data=%08x cache=%b locked=%b owner=%b",
                         up_rsp_valid, up_rsp_data, path_is_cache,
                         u_cp.path_locked, u_cp.path_sel_q);
            end
            up_rsp_ready = 1'b1;
            @(posedge clk); #1;
            nrsp = nrsp + 1;
            up_rsp_ready = 1'b0;
            cacheable = 1'b0;
            up_addr = changed_addr;
            @(negedge clk);
        end
    endtask

    // ---------------- 看门狗 ----------------
    initial begin
        #1;
        while (cyc < CYC_LIMIT) @(posedge clk);
        $display("--------------------------------------------------");
        $display("  *** TIMEOUT / DEADLOCK ***  仿真超过 %0d 拍未结束", CYC_LIMIT);
`ifdef TB_MUTATE_NO_SKID
        $display("  （本次为反向突变构建：挂死即为【预期】结果，说明本 TB 具备鉴别力）");
`endif
        $display("  请求=%0d 响应=%0d 从设备已给响应=%0d", nreq, nrsp, dev_rsp_seen);
        $display("==================================================");
        $finish;
    end

    initial begin
        $display("==================================================");
        $display("  cache_path 出口契约回归（登记式响应 + 独占保持）");
`ifdef TB_MUTATE_NO_SKID
        $display("  ⚠️ 反向突变构建 TB_MUTATE_NO_SKID：预期 B2 失败/挂死");
`endif
        $display("==================================================");
        repeat (3) @(posedge clk);
        rst = 1'b0;
        @(negedge clk);

        // ---- B1 常规 bypass 读（下游就绪）----
        $display("[B1] 常规 bypass 读（下游立即可消费）");
        do_bypass_read(32'h2000_0000, 0, 0);

        // ---- B4 后台 fill 占用 adapter 时：bypass 请求必须被反压，端口保持给桥 ----
        $display("[B4] cache_busy=1 + bypass 请求：端口不得切给 bypass");
        cacheable = 1'b0; cache_busy_tb = 1'b1; up_valid = 1'b1;
        up_addr = 32'h3000_0000; up_write = 1'b0; cache_req_ready_tb = 1'b0;
        #1;  // 仅用于组合稳定（小于半周期）
        if (up_ready !== 1'b0 || path_drv !== 1'b0 || adp_rv !== 1'b0) begin
            fails = fails + 1;
            $display("FAIL [B4] up_ready=%b path_drv=%b adp_rv=%b（期望 0/0/0）",
                     up_ready, path_drv, adp_rv);
        end else begin
            $display("PASS [B4] background fill 保持 adapter：up_ready=0 path_drv=0 adp_rv=0");
        end
        up_valid = 1'b0; cache_busy_tb = 1'b0; #1;  // 仅用于组合稳定（小于半周期）

        // ---- B5 后台 fill 期间走 Cache 的请求仍可提前服务，但 adapter 仍不归 bypass ----
        $display("[B5] cache_busy=1 + cacheable 请求：走 cache 且不释放 adapter");
        cacheable = 1'b1; cache_busy_tb = 1'b1; cache_req_ready_tb = 1'b1;
        up_valid = 1'b1; up_addr = 32'h4000_0100; up_write = 1'b0;
        #1;  // 仅用于组合稳定（小于半周期）
        if (up_ready !== 1'b1 || cp_cr !== 1'b1 || path_drv !== 1'b0) begin
            fails = fails + 1;
            $display("FAIL [B5] up_ready=%b cache_req_valid=%b path_drv=%b（期望 1/1/0）",
                     up_ready, cp_cr, path_drv);
        end else begin
            $display("PASS [B5] cache 请求可在后台 fill 时进入：up_ready=1 cp_cr=1 path_drv=0");
        end
        up_valid = 1'b0; cache_busy_tb = 1'b0; cacheable = 1'b0;
        cache_req_ready_tb = 1'b0; #1;  // 仅用于组合稳定（小于半周期）

        // ---- B2 下游卡住 4 拍（现场复现 (d-2) 死锁条件）----
        $display("[B2] 下游卡住 4 拍：响应必须仍被登记（E2）");
        do_bypass_read(32'h2000_0004, 4, 1);

        // ---- B3 连续事务：无丢无重（E3）----
        $display("[B3] 连续 4 笔 bypass 事务");
        do_bypass_read(32'h2000_0008,  1, 2);
        do_bypass_read(32'h2000_000C,  2, 3);
        do_bypass_read(32'h2000_0010,  3, 4);
        do_bypass_read(32'h2000_0014,  0, 5);

        // ---- B6 response routing must not follow a changed live decode ----
        $display("[B6] 已接受的 bypass 响应期间改变实时地址译码");
        do_bypass_read_with_live_redecode(32'h2000_0018, 32'h8000_0020);

        // ---- B7 Cache transaction lock can hand off to the next cacheable request ----
        $display("[B7] 成功 Cache 响应沿接收同路径的下一请求");
        do_cache_response_turnover();

        // ---- B8 Cache response + live bypass request must not ghost into Cache ----
        $display("[B8] Cache 响应交付沿拒绝未获上游握手的 bypass→Cache 请求");
        do_cache_to_bypass_no_ghost();

        $display("--------------------------------------------------");
        $display("  请求=%0d 响应=%0d 从设备已给响应=%0d", nreq, nrsp, dev_rsp_seen);
        if (nreq != 7) begin fails = fails + 1;
            $display("FAIL 请求数=%0d（期望 7）", nreq); end
        if (nrsp != 7) begin fails = fails + 1;
            $display("FAIL 响应数=%0d（期望 7）—— 丢响应或多响应", nrsp); end
        if (dev_rsp_seen != 7) begin fails = fails + 1;
            $display("FAIL 从设备给响应 %0d 次（期望 7）", dev_rsp_seen); end
        $display("  检查项: 9 失败: %0d", fails);
        // 标记串必须是运行器认得的 "ALL TESTS PASSED"（run_tests.py has_summary 判据）
        if (fails == 0) $display("  ALL TESTS PASSED  (cache_path 出口契约：登记式响应 + 独占保持)");
        else            $display("  %0d FAILED", fails);
        $display("==================================================");
        $finish;
    end

endmodule
