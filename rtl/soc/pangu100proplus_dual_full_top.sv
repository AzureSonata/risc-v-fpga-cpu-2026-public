// ============================================================================
//        Pangu 100Pro+ dual-issue FULL prototype top
//
//        I path: dual_issue_full_core(64-bit) -> wide_imem_adapter ->
//                cpu_mem_subsystem I port (ICache/ROM/SRAM path)
//        D path: dual_issue_full_core 32-bit D port -> cpu_mem_subsystem
//                (DCache + ROM/SRAM + GPIO/timer/UART)
//
//        This replaces the earlier wide_rom-only prototype with the project's
//        real memory subsystem.  Board pins are deliberately the same broad
//        shape as the other Pangu tops so synthesis/timing scripts can be
//        pointed at it.
// ============================================================================
`timescale 1ns/1ps

module pangu100proplus_dual_full_top #(
    parameter [1023:0] ROM_INIT_FILE = "verification/unit/dual_full_soc.hex",
    parameter integer  MEM_DEPTH     = 256,
    parameter integer  MEM_AW        = 8,
    parameter integer  UART_DIV      = 434,
    parameter integer  M_MODE        = 2,
    parameter          DUAL_ISSUE_EN = 1'b1,
    parameter          PREDICT_ENABLE = 1'b1,
    parameter integer  PRED_MODE = 0,
    parameter integer  BTB_ENTRIES = 64,
    parameter          ICACHE_ENABLE = 1'b1,
    parameter          WIDE_ICACHE_ENABLE = 1'b1,
    parameter          DCACHE_ENABLE = 1'b1,
    parameter          ACCEL_ENABLE = 1'b0,
    parameter          POSTED_SRAM_WRITE_ACK = 1'b1,
    parameter          ICACHE_NEXTLINE_PREFETCH = 1'b0
)(
    input  wire        clk,
    input  wire        rstn,
    input  wire [31:0] gpio_in,
    input  wire        uart_rx,
    input  wire        accel_irq,
    output wire        accel_req_valid,
    input  wire        accel_req_ready,
    output wire [31:0] accel_addr,
    output wire        accel_write,
    output wire [31:0] accel_wdata,
    output wire [3:0]  accel_wstrb,
    input  wire        accel_rsp_valid,
    output wire        accel_rsp_ready,
    input  wire [31:0] accel_rdata,
    input  wire        accel_error,

    output wire [7:0]  led,
    output wire [31:0] gpio_out,
    output wire        uart_tx,

    output wire        trace0_valid,
    output wire [63:0] trace0_order,
    output wire [31:0] trace0_pc,
    output wire [31:0] trace0_instr,
    output wire [4:0]  trace0_rd,
    output wire [31:0] trace0_rd_data,
    output wire        trace0_rd_we,
    output wire        trace0_trap,
    output wire [31:0] trace0_cause,

    output wire        trace1_valid,
    output wire [63:0] trace1_order,
    output wire [31:0] trace1_pc,
    output wire [31:0] trace1_instr,
    output wire [4:0]  trace1_rd,
    output wire [31:0] trace1_rd_data,
    output wire        trace1_rd_we,
    output wire        trace1_trap,
    output wire [31:0] trace1_cause,

    output wire [31:0] pc_debug
);
    reg [1:0] reset_pipe;
    always @(posedge clk or negedge rstn) begin
        if (!rstn)
            reset_pipe <= 2'b11;
        else
            reset_pipe <= {reset_pipe[0], 1'b0};
    end

    // Per-domain reset distribution. One source (reset_pipe) still defines the
    // reset window; only the last stage is replicated per consumer domain so
    // that the mapped design does not have a single net with ~1.6k sink pins.
    // The copies are deliberately built with different next-state logic (plain
    // delay vs. registered inversion) because the synthesis flow merges
    // functionally identical registers back into one driver - which is exactly
    // what happened to the young-queue replication experiment in the
    // fanout-2/3 evidence. Release timing is unchanged: rst_core_q(t+1) =
    // reset_pipe[0](t) and ~nrst_mem_q(t+1) = reset_pipe[0](t), both equal to
    // the old rst(t+1) = reset_pipe[1](t+1).
    reg rst_core_q;
    reg nrst_mem_q;
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            rst_core_q <= 1'b1;
            nrst_mem_q <= 1'b0;
        end else begin
            rst_core_q <= reset_pipe[0];
            nrst_mem_q <= ~reset_pipe[0];
        end
    end
    wire rst_core = rst_core_q;
    wire rst_mem  = ~nrst_mem_q;
    wire rst_imem = reset_pipe[1];

    // Core 64-bit I port
    wire        core_i_req_valid, core_i_req_ready, core_i_rsp_valid, core_i_rsp_ready;
    wire [31:0] core_i_req_addr;
    wire [63:0] core_i_rsp_data;
    wire [1:0] core_i_rsp_error;

    // Adapter 32-bit memory side
    wire        mem_i_req_valid, mem_i_req_ready, mem_i_rsp_valid, mem_i_rsp_ready;
    wire [31:0] mem_i_req_addr, mem_i_rsp_rdata;
    wire        mem_i_rsp_error;

    wire [31:0] mem_i_rsp_rdata_hi;
    wire mem_i_rsp_error_hi;
    localparam USE_WIDE_ICACHE = WIDE_ICACHE_ENABLE && ICACHE_ENABLE;
    generate if (USE_WIDE_ICACHE) begin : g_wide_imem
        assign mem_i_req_valid = core_i_req_valid;
        assign core_i_req_ready = mem_i_req_ready;
        assign mem_i_req_addr = core_i_req_addr;
        assign core_i_rsp_valid = mem_i_rsp_valid;
        assign mem_i_rsp_ready = core_i_rsp_ready;
        assign core_i_rsp_data = {mem_i_rsp_rdata_hi, mem_i_rsp_rdata};
        assign core_i_rsp_error = {mem_i_rsp_error_hi, mem_i_rsp_error};
    end else begin : g_serial_imem
    wide_imem_adapter u_imem_adapter (
        .clk(clk), .rst(rst_imem),
        .cpu_req_valid(core_i_req_valid), .cpu_req_ready(core_i_req_ready),
        .cpu_req_addr(core_i_req_addr),
        .cpu_rsp_valid(core_i_rsp_valid), .cpu_rsp_ready(core_i_rsp_ready),
        .cpu_rsp_data(core_i_rsp_data), .cpu_rsp_error(core_i_rsp_error),
        .mem_req_valid(mem_i_req_valid), .mem_req_ready(mem_i_req_ready),
        .mem_req_addr(mem_i_req_addr),
        .mem_req_write(), .mem_req_wdata(), .mem_req_wstrb(),
        .mem_rsp_valid(mem_i_rsp_valid), .mem_rsp_ready(mem_i_rsp_ready),
        .mem_rsp_rdata(mem_i_rsp_rdata), .mem_rsp_error(mem_i_rsp_error)
    );

    end endgenerate

    // Core D port
    wire        d_req_valid, d_req_ready, d_req_write;
    wire [31:0] d_req_addr, d_req_wdata;
    wire [3:0]  d_req_wstrb;
    wire        d_rsp_valid, d_rsp_ready, d_rsp_error;
    wire [31:0] d_rsp_rdata;
    wire        timer_irq_w;

`ifdef DUAL_FIVE_STAGE
    dual_issue_5stage_core #(.M_MODE(M_MODE), .DUAL_ISSUE_EN(DUAL_ISSUE_EN),
`else
    dual_issue_full_core #(.M_MODE(M_MODE), .DUAL_ISSUE_EN(DUAL_ISSUE_EN),
`endif
                           .PREDICT_ENABLE(PREDICT_ENABLE),
                           .PRED_MODE(PRED_MODE),
                           .BTB_ENTRIES(BTB_ENTRIES)) u_cpu (
        .clk(clk), .rst(rst_core),
        .i_req_valid(core_i_req_valid), .i_req_ready(core_i_req_ready),
        .i_req_addr(core_i_req_addr), .i_rsp_valid(core_i_rsp_valid),
        .i_rsp_ready(core_i_rsp_ready), .i_rsp_data(core_i_rsp_data), .i_rsp_error(core_i_rsp_error),
        .d_req_valid(d_req_valid), .d_req_ready(d_req_ready),
        .d_req_addr(d_req_addr), .d_req_write(d_req_write),
        .d_req_wdata(d_req_wdata), .d_req_wstrb(d_req_wstrb),
        .d_rsp_valid(d_rsp_valid), .d_rsp_ready(d_rsp_ready),
        .d_rsp_rdata(d_rsp_rdata), .d_rsp_error(d_rsp_error),
        .timer_irq_i(timer_irq_w), .ext_irq_i(ACCEL_ENABLE ? accel_irq : 1'b0),
        .issue0(), .issue1(), .retire0_valid(), .retire1_valid(),
        .trace0_valid(trace0_valid), .trace0_order(trace0_order),
        .trace0_pc(trace0_pc), .trace0_instr(trace0_instr),
        .trace0_rd(trace0_rd), .trace0_rd_data(trace0_rd_data),
        .trace0_rd_we(trace0_rd_we), .trace0_trap(trace0_trap),
        .trace0_cause(trace0_cause),
        .trace1_valid(trace1_valid), .trace1_order(trace1_order),
        .trace1_pc(trace1_pc), .trace1_instr(trace1_instr),
        .trace1_rd(trace1_rd), .trace1_rd_data(trace1_rd_data),
        .trace1_rd_we(trace1_rd_we), .trace1_trap(trace1_trap),
        .trace1_cause(trace1_cause),
        .pc_debug(pc_debug)
    );

    cpu_mem_subsystem #(
        .MEM_DEPTH(MEM_DEPTH), .MEM_AW(MEM_AW), .ROM_INIT_FILE(ROM_INIT_FILE),
        .UART_DIV(UART_DIV),
        .ICACHE_ENABLE(ICACHE_ENABLE), .I_FETCH_WORDS(USE_WIDE_ICACHE ? 2 : 1),
        .DCACHE_ENABLE(DCACHE_ENABLE),
        .ACCEL_ENABLE(ACCEL_ENABLE),
        .POSTED_SRAM_WRITE_ACK(POSTED_SRAM_WRITE_ACK),
        .I_NEXT_LINE_PREFETCH(ICACHE_NEXTLINE_PREFETCH)
    ) u_mem (
        .clk(clk), .rst(rst_mem),
        .i_req_valid(mem_i_req_valid), .i_req_ready(mem_i_req_ready),
        .i_req_addr(mem_i_req_addr), .i_write(1'b0), .i_wdata(32'h0),
        .i_wstrb(4'h0),
        .i_rsp_valid(mem_i_rsp_valid), .i_rsp_ready(mem_i_rsp_ready),
        .i_rdata(mem_i_rsp_rdata), .i_error(mem_i_rsp_error),
        .i_rdata_hi(mem_i_rsp_rdata_hi), .i_error_hi(mem_i_rsp_error_hi),
        .d_req_valid(d_req_valid), .d_req_ready(d_req_ready),
        .d_req_addr(d_req_addr), .d_write(d_req_write),
        .d_wdata(d_req_wdata), .d_wstrb(d_req_wstrb),
        .d_rsp_valid(d_rsp_valid), .d_rsp_ready(d_rsp_ready),
        .d_rdata(d_rsp_rdata), .d_error(d_rsp_error),
        .gpio_out(gpio_out), .gpio_in(gpio_in),
        .timer_irq(timer_irq_w),
        .uart_tx(uart_tx), .uart_rx(uart_rx),
        .accel_req_valid(accel_req_valid), .accel_req_ready(accel_req_ready),
        .accel_addr(accel_addr), .accel_write(accel_write),
        .accel_wdata(accel_wdata), .accel_wstrb(accel_wstrb),
        .accel_rsp_valid(accel_rsp_valid), .accel_rsp_ready(accel_rsp_ready),
        .accel_rdata(accel_rdata), .accel_error(accel_error)
    );

    assign led = gpio_out[7:0];

endmodule
