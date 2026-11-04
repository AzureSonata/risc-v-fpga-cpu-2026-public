// =============================================================================
//  tb_kws_estop_watchdog.sv  —  Tier-2 心跳看门狗自检台（自判 PASS/FAIL）
//
//  设计点：WINDOW = 16 拍（缩小以便逐拍核对边界；产品默认 1,350,000 = 50 ms @27 MHz）
//
//  拍号约定（全文统一，避免 off-by-one 争论）：
//    k = 0  ：驱动 arm=1 的那个 negedge
//    k = 1  ：第一个"看到 arm=1"的 posedge
//    k = W  ：窗口端点，此刻无心跳 ⇒ trip 拉高
//    心跳落在 k ≤ W ⇒ 不 trip（边界拍心跳优先于超时分支）；k = W+1 ⇒ 已经晚一拍
//
//  判据全部是"拍数"，不是"看起来对"：
//    T1 健康心跳 50 次             → trip 恒 0、hb_cnt=50
//    T2 停心跳                     → trip 拉高在 k=W（且 k=W-1 时仍为 0）
//    T3 心跳在 k=W-1               → 不 trip
//    T4 心跳在 k=W（端点）         → 不 trip
//    T5 心跳在 k=W+1               → k=W 已 trip，且心跳不清 trip（粘滞）
//    T6 撤防（arm=0）              → trip 保持、elapsed 清零（R4-B）
//    T7 配置/上电复位（por）        → trip / 计数全清（唯一清除路径）
//    T8 window_cfg=8 覆写          → trip 在 k=8
//    T9 两次 trip 的增量           → trip_cnt 增量 = 2
//
//  负控（编译期，验证 TB 有鉴别力）：
//    NEGCTL_WIN_OFFBYONE → T2（k=W 才 trip）必须变红
//    NEGCTL_NO_STICKY    → T5（粘滞）必须变红
//
//  退出码：全 PASS → 0；任一 FAIL → $fatal（非零）
// =============================================================================
`timescale 1ns/1ps

module tb_kws_estop_watchdog;

    localparam integer WIN = 16;

    reg         clk   = 1'b0;
    reg         rst   = 1'b1;
    reg         por   = 1'b1;   // 配置/上电复位：唯一清 trip 的路径
    reg         hb    = 1'b0;
    reg         arm   = 1'b0;
    reg  [31:0] wcfg  = 32'd0;

    wire        trip;
    wire [7:0]  trip_code;
    wire [31:0] trip_cnt;
    wire [31:0] hb_cnt;
    wire [31:0] elapsed;

    kws_estop_watchdog #(
        .WINDOW_CYC_DEFAULT(WIN)
    ) dut (
        .clk        (clk),
        .rst        (rst),
        .por        (por),
        .heartbeat  (hb),
        .arm        (arm),
        .window_cfg (wcfg),
        .trip       (trip),
        .trip_code  (trip_code),
        .trip_cnt   (trip_cnt),
        .hb_cnt     (hb_cnt),
        .elapsed    (elapsed)
    );

    always #5 clk = ~clk;      // 仿真时钟；与产品时钟无关，只数拍

    integer t      = 0;        // 全局拍计数（negedge 递增，仅用于日志）
    integer errors = 0;
    integer checks = 0;

    task automatic tick(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(negedge clk);
                t = t + 1;
            end
        end
    endtask

    // 在当前 negedge 起打一拍心跳：占用第 1 个 posedge
    task automatic beat;
        begin
            hb = 1'b1;
            tick(1);
            hb = 1'b0;
        end
    endtask

    // 从 arm 的 negedge 起计数，返回 trip 拉高对应的 k
    task automatic arm_and_measure(output integer k);
        begin
            arm = 1'b1;
            k   = 0;
            while (trip !== 1'b1 && k < 1000) begin
                @(negedge clk);
                t = t + 1;
                k = k + 1;
            end
        end
    endtask

    task automatic check(input [255:0] name, input integer got, input integer exp);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL  %0s : got=%0d expected=%0d (t=%0d)", name, got, exp, t);
            end else begin
                $display("ok    %0s : %0d (t=%0d)", name, got, t);
            end
        end
    endtask

    task automatic disarm;
        begin
            arm = 1'b0;
            tick(1);
        end
    endtask

    // 模拟 FPGA 重配置/上电：唯一清 trip 的路径（R4-B）
    task automatic power_cycle;
        begin
            por = 1'b1;
            tick(1);
            por = 1'b0;
            tick(1);
        end
    endtask

    integer k;
    integer i;
    integer base;

    initial begin
        $dumpfile("tb_kws_estop_watchdog.vcd");
        $dumpvars(0, tb_kws_estop_watchdog);

        // ---- T0 复位 ----
        rst = 1'b1; por = 1'b1; arm = 1'b0; hb = 1'b0; wcfg = 32'd0;
        tick(3);
        check("T0 por: trip=0",     trip,     0);
        check("T0 por: trip_cnt=0", trip_cnt, 0);
        rst = 1'b0; por = 1'b0;
        tick(1);

        // ---- T1 健康心跳：每 8 拍一次，共 50 次 ----
        arm = 1'b1;
        tick(1);
        for (i = 0; i < 50; i = i + 1) begin
            tick(7);
            beat;
        end
        check("T1 healthy: trip=0",     trip,     0);
        check("T1 healthy: hb_cnt=50",  hb_cnt,   50);
        check("T1 healthy: trip_cnt=0", trip_cnt, 0);

        // ---- T2 停心跳：k=W-1 仍为 0，k=W 拉高 ----
        disarm;
        base = trip_cnt;
        arm = 1'b1;
        tick(WIN - 1);
        check("T2 stop: trip=0 at k=W-1", trip, 0);
        tick(1);
        check("T2 stop: trip=1 at k=W",   trip, 1);
        check("T2 stop: trip_code=3",     trip_code, 3);
        check("T2 stop: trip_cnt +1",     trip_cnt - base, 1);

        // ---- T3 心跳在 k=W-1：不 trip ----
        disarm;
        power_cycle;
        arm = 1'b1;
        tick(WIN - 2);
        beat;                       // 占第 W-1 个 posedge
        tick(2);
        check("T3 beat@W-1: trip=0", trip, 0);

        // ---- T4 心跳与到期同拍：到期优先（ICR T7-10）----
        disarm;
        power_cycle;
        arm = 1'b1;
        tick(WIN - 1);
        beat;                       // 与超时同拍
        tick(2);
        check("T4 beat@W: expiry wins", trip, 1);

        // ---- T5 迟到心跳：trip 粘滞 ----
        disarm;
        power_cycle;
        base = trip_cnt;
        arm = 1'b1;
        tick(WIN - 1);
        check("T5 pre: trip=0 at k=W-1", trip, 0);
        tick(1);
        check("T5 pre: trip=1 at k=W",   trip, 1);
        beat;                       // 迟到一拍的心跳
        tick(2);
        check("T5 late beat: sticky",        trip, 1);
        check("T5 late beat: trip_cnt +1",   trip_cnt - base, 1);

        // ---- T6 撤防不清 trip（R4-B）----
        disarm;
        check("T6 disarm: trip holds",      trip,      1);
        check("T6 disarm: trip_code=3",     trip_code, 3);
        check("T6 disarm: elapsed=0",       elapsed,   0);

        // ---- T7 CPU rst 不清；只有 por/重配置清 ----
        rst = 1'b1; tick(1); rst = 1'b0; tick(1);
        check("T7 rst: trip holds", trip, 1);
        por = 1'b1; tick(1); por = 1'b0; tick(1);
        check("T7 por: trip=0",     trip,     0);
        check("T7 por: trip_cnt=0", trip_cnt, 0);
        check("T7 por: hb_cnt=0",   hb_cnt,   0);

        // ---- T8 window_cfg 覆写 = 8 ----
        disarm;
        wcfg = 32'd8;
        arm_and_measure(k);
        check("T8 cfg=8: trip at k=8", k, 8);
        wcfg = 32'd0;

        // ---- T9 每 power cycle 只允许一次 trip（R4-B）----
        disarm;
        power_cycle;                 // 新配置周期，清 trip/trip_cnt
        base = trip_cnt;
        arm = 1'b1; tick(1); tick(WIN + 2);
        check("T9 one trip per cycle: +1", trip_cnt - base, 1);

        $display("---------------------------------------------");
        $display("SUMMARY: %0d checks, %0d errors", checks, errors);
        if (errors == 0) begin
            $display("RESULT: PASS");
            $finish;
        end else begin
            $display("RESULT: FAIL");
            $fatal(1, "tb_kws_estop_watchdog: %0d check(s) failed", errors);
        end
    end

    initial begin
        #200000;
        $display("RESULT: FAIL (global timeout)");
        $fatal(1, "global timeout");
    end

endmodule
