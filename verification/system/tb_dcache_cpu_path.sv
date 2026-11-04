`timescale 1ns/1ps
`include "defines.sv"

// CPU-visible D-cache integration regression: load A, store A, load A.
// This deliberately instantiates the real CPU and cpu_mem_subsystem. The SRAM
// line starts with 42; the CPU stores 99; the architecturally visible reload
// must be 99 and must agree with the cache-path response.
module tb_dcache_cpu_path;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    wire i_req_valid, i_req_ready, i_rsp_ready;
    wire [31:0] i_req_addr;
    wire i_rsp_valid, i_error;
    wire [31:0] i_rdata;
    wire d_req_valid, d_req_ready, d_rsp_ready;
    wire [31:0] d_req_addr, d_wdata, d_rdata;
    wire d_write;
    wire [3:0] d_wstrb;
    wire d_rsp_valid, d_error;
    wire trace_valid, trace_rd_we, trace_trap;
    wire [63:0] trace_order;
    wire [31:0] trace_pc, trace_instr, trace_rd_data;
    wire [4:0] trace_rd;
    wire [31:0] gpio_out;
    wire timer_irq, uart_tx;
    reg [31:0] gpio_in = 0;
    integer cpu_d_rsp_count = 0;
    integer cache_rsp_count = 0;
    reg [31:0] cpu_load_rsp [0:3];
    reg [31:0] cache_rsp [0:3];
    reg saw_x3 = 0, saw_x5 = 0;
    reg [31:0] x3_value = 0, x5_value = 0;
    reg done = 0;
    integer cycles = 0;
    integer errors = 0;

    cpu_core_stage1 u_cpu (
        .clk(clk), .rst(rst),
        .i_req_valid(i_req_valid), .i_req_ready(i_req_ready), .i_req_addr(i_req_addr),
        .i_rsp_valid(i_rsp_valid), .i_rsp_ready(i_rsp_ready), .i_rsp_data(i_rdata),
        .i_rsp_error(i_error),
        .d_req_valid(d_req_valid), .d_req_ready(d_req_ready), .d_req_addr(d_req_addr),
        .d_req_write(d_write), .d_req_wdata(d_wdata), .d_req_wstrb(d_wstrb),
        .d_rsp_valid(d_rsp_valid), .d_rsp_ready(d_rsp_ready), .d_rsp_rdata(d_rdata),
        .d_rsp_error(d_error),
        .trace_valid(trace_valid), .trace_order(trace_order), .trace_pc(trace_pc),
        .trace_instr(trace_instr), .trace_rd(trace_rd), .trace_rd_data(trace_rd_data),
        .trace_rd_we(trace_rd_we), .trace_trap(trace_trap),
        .timer_irq_i(timer_irq), .ext_irq_i(1'b0)
    );

    cpu_mem_subsystem #(.MEM_DEPTH(256), .MEM_AW(8), .UART_DIV(4)) u_sub (
        .clk(clk), .rst(rst),
        .i_req_valid(i_req_valid), .i_req_ready(i_req_ready), .i_req_addr(i_req_addr),
        .i_write(1'b0), .i_wdata(32'b0), .i_wstrb(4'b0),
        .i_rsp_valid(i_rsp_valid), .i_rsp_ready(i_rsp_ready), .i_rdata(i_rdata), .i_error(i_error),
        .d_req_valid(d_req_valid), .d_req_ready(d_req_ready), .d_req_addr(d_req_addr),
        .d_write(d_write), .d_wdata(d_wdata), .d_wstrb(d_wstrb),
        .d_rsp_valid(d_rsp_valid), .d_rsp_ready(d_rsp_ready), .d_rdata(d_rdata), .d_error(d_error),
        .gpio_out(gpio_out), .gpio_in(gpio_in), .timer_irq(timer_irq),
        .uart_tx(uart_tx), .uart_rx(1'b1)
    );

    initial begin
        #1;
        u_sub.u_rom_i.mem[0] = 32'h8000_0137; // lui x2,0x80000: SRAM base
        u_sub.u_rom_i.mem[1] = 32'h0001_2183; // lw x3,0(x2): cold load A
        u_sub.u_rom_i.mem[2] = 32'h0630_0213; // addi x4,x0,99
        u_sub.u_rom_i.mem[3] = 32'h0041_2023; // sw x4,0(x2): store A
        u_sub.u_rom_i.mem[4] = 32'h0001_2283; // lw x5,0(x2): warm reload A
        u_sub.u_rom_i.mem[5] = 32'h0000_006f; // jal x0,0
        {u_sub.u_sram_d.mem3[0], u_sub.u_sram_d.mem2[0], u_sub.u_sram_d.mem1[0], u_sub.u_sram_d.mem0[0]} = 32'd42;
        repeat (3) @(negedge clk);
        rst = 1'b0;
        #100000;
        if (!done) begin
            $display("FAIL [watchdog] CPU did not retire reload before timeout");
            errors = errors + 1;
            $finish_and_return(1);
        end
        $display("DCPU-OBS x3=%0d x5=%0d cpu_rsp=%0d cache_rsp=%0d hit=%0d miss=%0d store=%0d",
                 x3_value, x5_value, cpu_d_rsp_count, cache_rsp_count,
                 u_sub.u_dcache.stat_hit, u_sub.u_dcache.stat_miss, u_sub.u_dcache.stat_store);
        if (!saw_x3 || x3_value !== 32'd42) begin
            $display("FAIL [cold CPU load A] saw=%b value=%0d expected=42", saw_x3, x3_value);
            errors = errors + 1;
        end
        if (!saw_x5 || x5_value !== 32'd99) begin
            $display("FAIL [architectural store/reload] saw=%b value=%0d expected=99", saw_x5, x5_value);
            errors = errors + 1;
        end
        // 本序列 D 侧响应依次为：冷 load 42、store 0、warm reload 99。
        // 不能再用 cache_rsp[1]：store 现在也走 D-Cache，占用了一个响应槽。
        if (cache_rsp_count < 3 || cache_rsp[0] !== 32'd42 ||
            cache_rsp[1] !== 32'd0 || cache_rsp[2] !== 32'd99) begin
            $display("FAIL [CPU-visible cache-path responses] n=%0d [0]=%0d [1]=%0d [2]=%0d expected 42/0/99",
                     cache_rsp_count,
                     cache_rsp_count > 0 ? cache_rsp[0] : 32'hxxxx_xxxx,
                     cache_rsp_count > 1 ? cache_rsp[1] : 32'hxxxx_xxxx,
                     cache_rsp_count > 2 ? cache_rsp[2] : 32'hxxxx_xxxx);
            errors = errors + 1;
        end
        // 本序列必须同时观测到：冷 load miss、store hit、warm load hit。
        if (u_sub.u_dcache.stat_hit !== 32'd2 ||
            u_sub.u_dcache.stat_miss !== 32'd1 ||
            u_sub.u_dcache.stat_store !== 32'd1) begin
            $display("FAIL [cache hit/miss/store counters] hit=%0d miss=%0d store=%0d expected 2/1/1",
                     u_sub.u_dcache.stat_hit, u_sub.u_dcache.stat_miss, u_sub.u_dcache.stat_store);
            errors = errors + 1;
        end
        if (errors == 0) begin
            $display("PASS [CPU-visible D-cache load/store/reload: x3=42 x5=99, counters 2/1/1]");
            $display("ALL TESTS PASSED (CPU-visible D-cache load/store/reload)");
            $finish;
        end else begin
            $display("TESTS FAILED errors=%0d", errors);
            $finish_and_return(1);
        end
    end

    always @(posedge clk) begin
        if (!rst) begin
            cycles <= cycles + 1;
            if (d_rsp_valid && d_rsp_ready) begin
                cpu_load_rsp[cpu_d_rsp_count] <= d_rdata;
                cpu_d_rsp_count <= cpu_d_rsp_count + 1;
                $display("CPU-D-RSP cycle=%0d addr=%08h write=%b data=%08h error=%b",
                         cycles, d_req_addr, d_write, d_rdata, d_error);
            end
            if (u_sub.d_cpu_rsp_valid && d_rsp_ready) begin
                cache_rsp[cache_rsp_count] <= u_sub.d_cpu_rdata;
                cache_rsp_count <= cache_rsp_count + 1;
                $display("CACHE-PATH-RSP cycle=%0d data=%08h error=%b",
                         cycles, u_sub.d_cpu_rdata, u_sub.d_cpu_error);
            end
            if (trace_valid && trace_rd_we && trace_rd == 5'd3) begin
                saw_x3 <= 1'b1;
                x3_value <= trace_rd_data;
            end
            if (trace_valid && trace_rd_we && trace_rd == 5'd5) begin
                saw_x5 <= 1'b1;
                x5_value <= trace_rd_data;
                done <= 1'b1;
            end
        end
    end
endmodule
