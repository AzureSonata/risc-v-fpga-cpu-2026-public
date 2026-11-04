// =============================================================================
//  kws_estop_watchdog.sv  —  无接触语音急停 Tier-2（心跳失效安全）看门狗
//
//  ★ 性质：**PROPOSED（候选 IP）**。不属于任何既有 owner 的目录：
//    SoC/集成 owner 为康文、加速器 owner 为林文翔、应用侧为 AI 侧；
//    本文件只做纯 IP 级实现 + 仿真，不改任何既有 RTL，也不接线到 SoC。
//    接线（例化进 kws_soc_top、分配 MMIO 寄存器）必须由 owner 批准后另提 ICR。
//
//  为什么需要这一层（来源：APPLICATION_SCENARIO_EVALUATION_20261021.md §6.1）：
//    MFCC 前端跑在 CPU 软件上、加速器由 CPU 每帧写 START；
//    ⇒ CPU 死锁时**没有新特征、没有 START**，语音通路（Tier-1）不可能继续判决。
//    ⇒ "软件已死仍能断开"只能由本层（心跳超时）实现，不能由语音实现。
//    把两者混为一谈是本方向唯一会被一票否决的技术漏洞。
//
//  语义（与 KWS MMIO 既有约定对齐，见 rtl/soc/kws_mmio.sv）：
//    · heartbeat : 单拍脉冲，CPU 每 10 ms 写一次心跳寄存器（本层不规定寄存器地址，
//                  地址由 owner 在 0x4000_0xxx 内裁决）；
//    · arm       : 1=武装；0=撤防并停止倒数，**不清 trip**（R4-B）。不得由同一路软件单独控制
//                  （否则软件可自行解除保护）。建议由板级 strap / 维护钥匙驱动，
//                  软件只能观察，不能写。
//    · trip      : 电平、**粘滞**；1 = 要求断开（继电器失电、制动拉高）。
//                  trip 是失效安全输出：心跳恢复、软件忙、计数回绕都不得让它自动变 0；
//                  只有 por/FPGA 重配置或整板断电重启能清；rst、arm=0、HB、软件写都不清。
//    · trip_code : 固定 3，与 kws_mmio.h 的 KWS_DEV_ERR_WATCHDOG 对齐。
//    · 时钟停：本层无法自证"时钟还在"，时钟停等于 trip 输出保持（若 trip 已是 1 则保持；
//      若 trip 是 0 则保持 0）⇒ **时钟停的覆盖必须靠继电器侧的失电动作**，不得声称本层覆盖。
//
//  超时口径：
//    window_cfg == 0 时用 WINDOW_CYC_DEFAULT。两者都是**时钟拍数**，不是毫秒；
//    换算必须带时钟：50 ms @27 MHz = 1,350,000 拍；50 ms @100 MHz = 5,000,000 拍。
//    （H1 未定稿前不得把 ms 写成定值，见 docs/research/KWS_HW_PARAM_BACKFILL_H1H4H6H7_20261026.md）
//
//  负控（编译期注入，仅用于证明 TB 有鉴别力，不是产品功能）：
//    NEGCTL_WIN_OFFBYONE  窗口少 1 拍（应让"W-1 拍打心跳不 trip"的用例变红）
//    NEGCTL_NO_STICKY     trip 随心跳恢复自动清零（应让粘滞用例变红）
// =============================================================================
`default_nettype none

module kws_estop_watchdog #(
    // 50 ms @ 27 MHz = 1,350,000；改时钟必须重算，不得沿用
    parameter integer WINDOW_CYC_DEFAULT = 1350000
)(
    input  wire        clk,
    input  wire        rst,          // 同步高有效：只清计数，**不清 trip**（R4-B）
    input  wire        por,          // 配置/上电复位：唯一清 trip/trip_code/trip_cnt 的路径

    input  wire        heartbeat,    // 单拍脉冲
    input  wire        arm,          // 1=武装（建议板级 strap，非纯软件）
    input  wire [31:0] window_cfg,   // 0 → 用参数默认值

    output reg         trip,         // 电平、粘滞：1=要求断开
    output reg  [7:0]  trip_code,    // 3 = KWS_DEV_ERR_WATCHDOG
    output reg  [31:0] trip_cnt,     // 上电以来 trip 次数（只增）
    output reg  [31:0] hb_cnt,       // 上电以来接受的心跳数
    output wire [31:0] elapsed       // 距上次心跳的拍数（观测用）
);
    localparam [7:0] CODE_WATCHDOG = 8'd3;

`ifdef NEGCTL_WIN_OFFBYONE
    // 负控：窗口少 1 拍。正确实现下"恰好 W-1 拍打心跳"不得 trip，本变异会让它 trip。
    wire [31:0] window = (window_cfg == 32'd0) ? (WINDOW_CYC_DEFAULT - 1)
                                               : (window_cfg - 32'd1);
`else
    wire [31:0] window = (window_cfg == 32'd0) ? WINDOW_CYC_DEFAULT : window_cfg;
`endif

    reg [31:0] cnt;          // 距上次心跳的拍数
    assign elapsed = cnt;

    always @(posedge clk) begin
        if (por) begin
            // 配置/上电：唯一允许清 trip 的路径（R4-B）
            trip      <= 1'b0;
            trip_code <= 8'd0;
            trip_cnt  <= 32'd0;
            cnt       <= 32'd0;
            hb_cnt    <= 32'd0;
        end else if (rst) begin
            // CPU/运行时复位：只清计数，**不清 trip**
            cnt    <= 32'd0;
            hb_cnt <= 32'd0;
`ifdef NEGCTL_ESTOP_RST_CLEARS_TRIP
            // 负控：把 trip 接到运行时 rst（R4-B 必须变红）
            trip      <= 1'b0;
            trip_code <= 8'd0;
`endif
        end else if (!arm) begin
            // 撤防：停止倒数，**不清 trip**（R4-B）
            cnt <= 32'd0;
        end else if (trip) begin
            // 已 trip：保持到 por/重配置；心跳不得自动解除（失效安全）
            cnt <= cnt;
        end else if (cnt + 32'd1 >= window) begin
            // 到期优先：即使同拍有 heartbeat，也先置 trip（ICR T7-10）
            cnt       <= cnt + 32'd1;
            trip      <= 1'b1;
            trip_code <= CODE_WATCHDOG;
            trip_cnt  <= trip_cnt + 32'd1;
        end else if (heartbeat) begin
            cnt    <= 32'd0;
            hb_cnt <= hb_cnt + 32'd1;
        end else begin
            cnt <= cnt + 32'd1;
        end
    end

`ifdef NEGCTL_NO_STICKY
    // 负控：心跳恢复就把 trip 清掉（失效安全被破坏，粘滞用例必须变红）
    always @(posedge clk) begin
        if (!rst && heartbeat && trip)
            trip <= 1'b0;
    end
`endif
endmodule

`default_nettype wire
