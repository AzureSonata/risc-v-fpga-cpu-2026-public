`timescale 1ns/1ps

// First FPGA synthesis top for the Pangu 100Pro+ MES2L676-100HP.
// This is a deliberately small standalone SoC demo: the Stage1 CPU runs a
// fixed instruction ROM and a four-word on-chip data RAM. It does not use DDR3.
module pangu100proplus_top (
    input  wire       clk,       // 27 MHz core-board oscillator, FPGA ball D18
    input  wire       rstn,      // KEY0 on C22, active low user pushbutton
    output wire [7:0] led        // high level lights LED0..LED7
);
    reg [1:0] reset_pipe;
    always @(posedge clk or negedge rstn) begin
        if (!rstn)
            reset_pipe <= 2'b11;
        else
            reset_pipe <= {reset_pipe[0], 1'b0};
    end
    wire rst = reset_pipe[1];

    wire i_req_valid, i_req_ready, i_rsp_valid, i_rsp_ready, i_rsp_error;
    wire [31:0] i_req_addr, i_rsp_data;
    reg i_rsp_pending;
    reg [31:0] i_rsp_addr;

    function [31:0] boot_rom(input [31:0] addr);
        begin
            case (addr)
                32'h00: boot_rom = 32'h00100093; // addi x1,x0,1
                32'h04: boot_rom = 32'h00108463; // beq x1,x1,+8
                32'h08: boot_rom = 32'h06300113; // wrong path: addi x2,x0,99
                32'h0c: boot_rom = 32'h00108113; // addi x2,x1,1
                32'h10: boot_rom = 32'h002081b3; // add x3,x1,x2
                32'h14: boot_rom = 32'h00002203; // lw x4,0(x0)
                32'h18: boot_rom = 32'h00120293; // addi x5,x4,1
                32'h1c: boot_rom = 32'h00502223; // sw x5,4(x0)
                32'h20: boot_rom = 32'h00402303; // lw x6,4(x0)
                32'h24: boot_rom = 32'h00130393; // addi x7,x6,1
                32'h28: boot_rom = 32'h06300013; // addi x0,x0,99
                default: boot_rom = 32'h00000013; // addi x0,x0,0
            endcase
        end
    endfunction

    assign i_req_ready = !i_rsp_pending;
    assign i_rsp_valid = i_rsp_pending;
    assign i_rsp_data = boot_rom(i_rsp_addr);
    assign i_rsp_error = 1'b0;

    always @(posedge clk) begin
        if (rst) begin
            i_rsp_pending <= 1'b0;
            i_rsp_addr <= 32'b0;
        end else begin
            if (i_rsp_pending && i_rsp_ready)
                i_rsp_pending <= 1'b0;
            if (i_req_valid && i_req_ready) begin
                i_rsp_pending <= 1'b1;
                i_rsp_addr <= i_req_addr;
            end
        end
    end

    wire d_req_valid, d_req_ready, d_req_write, d_rsp_valid, d_rsp_ready;
    wire [31:0] d_req_addr, d_req_wdata, d_rsp_rdata;
    wire [3:0] d_req_wstrb;
    reg d_rsp_pending;
    reg [31:0] d_rsp_addr, d_rsp_data;
    reg [31:0] dmem [0:3];
    integer lane;

    assign d_req_ready = !d_rsp_pending;
    assign d_rsp_valid = d_rsp_pending;
    assign d_rsp_rdata = d_rsp_data;

    always @(posedge clk) begin
        if (rst) begin
            d_rsp_pending <= 1'b0;
            d_rsp_addr <= 32'b0;
            d_rsp_data <= 32'b0;
            dmem[0] <= 32'd7;
            dmem[1] <= 32'b0;
            dmem[2] <= 32'b0;
            dmem[3] <= 32'b0;
        end else begin
            if (d_rsp_pending && d_rsp_ready)
                d_rsp_pending <= 1'b0;
            if (d_req_valid && d_req_ready) begin
                d_rsp_pending <= 1'b1;
                d_rsp_addr <= d_req_addr;
                if (d_req_addr[31:4] == 0)
                    d_rsp_data <= dmem[d_req_addr[3:2]];
                else
                    d_rsp_data <= 32'b0;
                if (d_req_write && d_req_addr[31:4] == 0) begin
                    for (lane = 0; lane < 4; lane = lane + 1)
                        if (d_req_wstrb[lane])
                            dmem[d_req_addr[3:2]][lane*8 +: 8] <= d_req_wdata[lane*8 +: 8];
                end
            end
        end
    end

    wire trace_valid, trace_rd_we, trace_trap;
    wire [63:0] trace_order;
    wire [31:0] trace_pc, trace_instr, trace_rd_data;
    wire [4:0] trace_rd;

    cpu_core_stage1 u_cpu (
        .clk(clk), .rst(rst),
        .i_req_valid(i_req_valid), .i_req_ready(i_req_ready),
        .i_req_addr(i_req_addr), .i_rsp_valid(i_rsp_valid),
        .i_rsp_ready(i_rsp_ready), .i_rsp_data(i_rsp_data),
        .i_rsp_error(i_rsp_error), .d_req_valid(d_req_valid),
        .d_req_ready(d_req_ready), .d_req_addr(d_req_addr),
        .d_req_write(d_req_write), .d_req_wdata(d_req_wdata),
        .d_req_wstrb(d_req_wstrb), .d_rsp_valid(d_rsp_valid),
        .d_rsp_ready(d_rsp_ready), .d_rsp_rdata(d_rsp_rdata),
        .d_rsp_error(1'b0), .trace_valid(trace_valid),
        .trace_order(trace_order), .trace_pc(trace_pc),
        .trace_instr(trace_instr), .trace_rd(trace_rd),
        .trace_rd_data(trace_rd_data), .trace_rd_we(trace_rd_we),
        .trace_trap(trace_trap),
        // 批 (c) D14：本顶层为最小点灯 demo，无定时器外设与外部中断源，
        // 两个中断输入显式接 0（Icarus 10.2 无端口默认值，未连接会成 z 传播为 x）
        .timer_irq_i(1'b0), .ext_irq_i(1'b0)
    );

    // Show the low byte of the most recently committed non-x0 register write.
    reg [7:0] led_value;
    always @(posedge clk) begin
        if (rst)
            led_value <= 8'b0;
        else if (trace_valid && trace_rd_we)
            led_value <= trace_rd_data[7:0];
    end
    assign led = led_value;
endmodule
