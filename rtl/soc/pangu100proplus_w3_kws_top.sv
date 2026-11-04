// Pangu 100Pro+ W3 CPU system with the real KWS accelerator attached to the
// dual full-top D-side accelerator port.  The KWS block owns its hash-locked
// model ROM, input/result RAMs, OpenEye engine and digital estop watchdog.
`timescale 1ns/1ps
`default_nettype none

module pangu100proplus_w3_kws_top #(
    parameter [1023:0] ROM_INIT_FILE = "verification/unit/dual_full_soc.hex",
    parameter integer MEM_DEPTH = 16384,
    parameter integer MEM_AW = $clog2(MEM_DEPTH),
    parameter integer UART_DIV = 434,
    parameter integer M_MODE = 2,
    parameter integer TIMEOUT_DEFAULT = 704040,
    parameter integer LOGIT_OFF = 4000,
    parameter [31:0] ESTOP_WINDOW_DEFAULT = 32'd1350000,
    parameter ICACHE_ENABLE = 1'b1,
    parameter DCACHE_ENABLE = 1'b1,
    parameter AUDIO_ENABLE = 1'b0
)(
    input  wire clk,
    input  wire rstn,
    input  wire [31:0] gpio_in,
    input  wire uart_rx,
    input  wire estop_arm,
    input  wire mic_sd,
    output wire mic_bclk,
    output wire mic_lrck,
    output wire estop_trip,
    output wire fan_enable,
    output wire kws_irq,
    output wire [7:0] led,
    output wire [31:0] gpio_out,
    output wire uart_tx,
    output wire trace0_valid,
    output wire [31:0] trace0_pc,
    output wire [31:0] trace0_instr,
    output wire trace0_trap,
    output wire [31:0] trace0_cause,
    output wire trace1_valid,
    output wire [31:0] trace1_pc,
    output wire [31:0] trace1_instr,
    output wire trace1_trap,
    output wire [31:0] trace1_cause,
    output wire [31:0] pc_debug
);
    wire rst = ~rstn;
    wire accel_req_valid, accel_req_ready, accel_write;
    wire [31:0] accel_addr, accel_wdata, accel_rdata;
    wire [3:0] accel_wstrb;
    wire accel_rsp_valid, accel_rsp_ready, accel_error;

    wire audio_req_ready, audio_rsp_valid, audio_error;
    wire [31:0] audio_rdata;
    wire audio_sample_valid, audio_sample_ready;
    wire signed [15:0] audio_sample_data;
    wire [9:0] audio_fifo_level;
    wire audio_overrun, audio_overrun_clear;

    wire kws_req_ready, kws_rsp_valid, kws_error;
    wire [31:0] kws_rdata;
    wire kws_rsp_ready;

    // The accelerator page is split into three disjoint windows:
    //   KWS control/buffer: 0x4000_0000..0x4000_1fff
    //   Audio FIFO:         0x4000_2000..0x4000_2fff
    // All other accesses receive an explicit bus error.  The upstream adapter
    // allows one outstanding accelerator transaction, so capture its target
    // until the selected slave response is consumed.
    localparam [1:0] ACCEL_TARGET_KWS   = 2'd0;
    localparam [1:0] ACCEL_TARGET_AUDIO = 2'd1;
    localparam [1:0] ACCEL_TARGET_ERROR = 2'd2;
    wire accel_route_kws = (accel_addr[31:13] == 19'h20000);
    wire accel_route_audio = AUDIO_ENABLE &&
                             (accel_addr[31:12] == 20'h40002);
    wire [1:0] accel_request_target = accel_route_kws ? ACCEL_TARGET_KWS :
                                      accel_route_audio ? ACCEL_TARGET_AUDIO :
                                      ACCEL_TARGET_ERROR;
    wire selected_accel_req_ready = accel_route_kws ? kws_req_ready :
                                    accel_route_audio ? audio_req_ready : 1'b1;
    reg accel_outstanding_q;
    reg [1:0] accel_target_q;
    wire accel_req_fire = accel_req_valid && accel_req_ready;
    wire accel_rsp_fire = accel_rsp_valid && accel_rsp_ready;

    assign accel_req_ready = !accel_outstanding_q && selected_accel_req_ready;
    assign accel_rsp_valid = accel_outstanding_q &&
                             ((accel_target_q == ACCEL_TARGET_KWS) ? kws_rsp_valid :
                              (accel_target_q == ACCEL_TARGET_AUDIO) ? audio_rsp_valid :
                              1'b1);
    assign accel_rdata = (accel_target_q == ACCEL_TARGET_KWS) ? kws_rdata :
                         (accel_target_q == ACCEL_TARGET_AUDIO) ? audio_rdata : 32'd0;
    assign accel_error = (accel_target_q == ACCEL_TARGET_KWS) ? kws_error :
                         (accel_target_q == ACCEL_TARGET_AUDIO) ? audio_error : 1'b1;
    assign kws_rsp_ready = accel_outstanding_q &&
                           (accel_target_q == ACCEL_TARGET_KWS) && accel_rsp_ready;

    always @(posedge clk) begin
        if (rst) begin
            accel_outstanding_q <= 1'b0;
            accel_target_q <= ACCEL_TARGET_ERROR;
        end else begin
            if (accel_rsp_fire)
                accel_outstanding_q <= 1'b0;
            if (accel_req_fire) begin
                accel_outstanding_q <= 1'b1;
                accel_target_q <= accel_request_target;
            end
        end
    end

    // Separate configuration POR from CPU reset: CPU reset must not clear an
    // already latched estop trip.  This pipe models the board configuration
    // release and is intentionally independent of rstn.
    reg [1:0] estop_por_pipe = 2'b11;
    always @(posedge clk)
        estop_por_pipe <= {estop_por_pipe[0], 1'b0};
    wire estop_por = estop_por_pipe[1];

    // Keep the H-trigger relay off during FPGA power-up, CPU reset, and any
    // latched watchdog trip. GPIO reset also clears bit31; rstn is an immediate
    // combinational hardware inhibit while reset is asserted.
    assign fan_enable = gpio_out[31] && rstn && !estop_por && !estop_trip;

    pangu100proplus_dual_full_top #(
        .ROM_INIT_FILE(ROM_INIT_FILE),
        .MEM_DEPTH(MEM_DEPTH), .MEM_AW(MEM_AW), .UART_DIV(UART_DIV),
        .M_MODE(M_MODE), .DUAL_ISSUE_EN(1'b1),
        .ICACHE_ENABLE(ICACHE_ENABLE), .WIDE_ICACHE_ENABLE(1'b1),
        .DCACHE_ENABLE(DCACHE_ENABLE), .ACCEL_ENABLE(1'b1)
    ) u_w3 (
        .clk(clk), .rstn(rstn), .gpio_in(gpio_in), .uart_rx(uart_rx),
        .accel_irq(kws_irq),
        .accel_req_valid(accel_req_valid), .accel_req_ready(accel_req_ready),
        .accel_addr(accel_addr), .accel_write(accel_write),
        .accel_wdata(accel_wdata), .accel_wstrb(accel_wstrb),
        .accel_rsp_valid(accel_rsp_valid), .accel_rsp_ready(accel_rsp_ready),
        .accel_rdata(accel_rdata), .accel_error(accel_error),
        .led(led), .gpio_out(gpio_out), .uart_tx(uart_tx),
        .trace0_valid(trace0_valid), .trace0_order(), .trace0_pc(trace0_pc),
        .trace0_instr(trace0_instr), .trace0_rd(), .trace0_rd_data(),
        .trace0_rd_we(), .trace0_trap(trace0_trap), .trace0_cause(trace0_cause),
        .trace1_valid(trace1_valid), .trace1_order(), .trace1_pc(trace1_pc),
        .trace1_instr(trace1_instr), .trace1_rd(), .trace1_rd_data(),
        .trace1_rd_we(), .trace1_trap(trace1_trap), .trace1_cause(trace1_cause),
        .pc_debug(pc_debug)
    );

    wire [15:0] dw_w_idx, bias_idx, quant_idx;
    wire [31:0] fc_w_idx;
    wire signed [7:0] dw_w_q, fc_w_q;
    wire signed [31:0] bias_q, quant_mult, quant_shift;

    kws_mmio #(
        .TIMEOUT_DEFAULT(TIMEOUT_DEFAULT),
        .ESTOP_WINDOW_DEFAULT(ESTOP_WINDOW_DEFAULT),
        .LOGIT_OFF(LOGIT_OFF),
        .MODEL_ROM_ENABLE(1'b1)
    ) u_kws (
        .clk(clk), .rst(rst),
        .estop_arm(estop_arm), .estop_por(estop_por), .estop_trip(estop_trip),
        .req_valid(accel_req_valid && !accel_outstanding_q && accel_route_kws),
        .req_ready(kws_req_ready),
        .addr(accel_addr), .write(accel_write), .wdata(accel_wdata),
        .wstrb(accel_wstrb), .rsp_valid(kws_rsp_valid),
        .rsp_ready(kws_rsp_ready), .rdata(kws_rdata), .error(kws_error),
        .dw_ih(16'd0), .dw_iw(16'd0), .dw_oh(16'd0), .dw_ow(16'd0),
        .dw_kh(16'd0), .dw_kw(16'd0), .dw_sh(16'd0), .dw_sw(16'd0),
        .dw_pt(16'd0), .dw_pl(16'd0), .dw_cout(16'd0),
        .in_zp(32'sd0), .dw_out_zp(32'sd0),
        .fc_nin(16'd0), .fc_nout(16'd0), .fc_out_zp(32'sd0),
        .act_min(32'sd0), .act_max(32'sd0),
        .dw_w_idx(dw_w_idx), .fc_w_idx(fc_w_idx),
        .bias_idx(bias_idx), .quant_idx(quant_idx),
        .w_q(8'sd0), .bias_q(32'sd0), .quant_mult(32'sd0),
        .quant_shift(32'sd0), .irq(kws_irq),
        .o_job_active(), .o_done_sticky(), .o_error_sticky(),
        .o_error_code(), .o_cycle_count(), .o_timeout_hit(), .o_fc_phase(),
        .o_start_count(), .o_reject_count(),
        .dbg_res_we(), .dbg_res_addr(), .dbg_res_data()
    );

    generate if (AUDIO_ENABLE) begin : g_audio
        sen0327_i2s_rx #(
            .CLK_HZ(27000000), .SAMPLE_RATE_HZ(16000), .SLOT_BITS(32),
            .FIFO_DEPTH(512)
        ) u_i2s_rx (
            .clk(clk), .rst(rst),
            .mic_bclk(mic_bclk), .mic_lrck(mic_lrck), .mic_sd(mic_sd),
            .sample_valid(audio_sample_valid), .sample_ready(audio_sample_ready),
            .sample_data(audio_sample_data), .fifo_level(audio_fifo_level),
            .overrun(audio_overrun), .overrun_clear(audio_overrun_clear)
        );

        sen0327_audio_mmio #(.FIFO_DEPTH(512)) u_audio_mmio (
            .clk(clk), .rst(rst),
            .sample_valid(audio_sample_valid), .sample_ready(audio_sample_ready),
            .sample_data(audio_sample_data), .fifo_level(audio_fifo_level),
            .overrun(audio_overrun), .overrun_clear(audio_overrun_clear),
            .req_valid(accel_req_valid && !accel_outstanding_q && accel_route_audio),
            .req_ready(audio_req_ready), .addr(accel_addr), .write(accel_write),
            .wdata(accel_wdata), .wstrb(accel_wstrb),
            .rsp_valid(audio_rsp_valid),
            .rsp_ready(accel_outstanding_q &&
                       (accel_target_q == ACCEL_TARGET_AUDIO) && accel_rsp_ready),
            .rdata(audio_rdata), .error(audio_error)
        );
    end else begin : g_no_audio
        assign mic_bclk = 1'b0;
        assign mic_lrck = 1'b0;
        assign audio_req_ready = 1'b0;
        assign audio_rsp_valid = 1'b0;
        assign audio_rdata = 32'd0;
        assign audio_error = 1'b1;
        assign audio_sample_valid = 1'b0;
        assign audio_sample_data = 16'sd0;
        assign audio_fifo_level = 10'd0;
        assign audio_overrun = 1'b0;
        assign audio_sample_ready = 1'b0;
        assign audio_overrun_clear = 1'b0;
    end endgenerate

    // The production MMIO's default model-ROM path supplies all parameter,
    // quantization and descriptor ports internally; these are intentionally
    // not programmable through the CPU address map in ABI v1.
    assign dw_w_q = 8'sd0;
    assign fc_w_q = 8'sd0;
    assign bias_q = 32'sd0;
    assign quant_mult = 32'sd0;
    assign quant_shift = 32'sd0;
endmodule

`default_nettype wire
