`timescale 1ns/1ps
`include "defines.sv"

module tb_wide_imem_adapter;
    reg clk = 1'b0;
    reg rst = `RstEnable;
    always #5 clk = ~clk;

    reg         cpu_req_valid = 1'b0;
    wire        cpu_req_ready;
    reg  [31:0] cpu_req_addr = 32'h0;
    wire        cpu_rsp_valid;
    reg         cpu_rsp_ready = 1'b0;
    wire [63:0] cpu_rsp_data;

    wire        mem_req_valid, mem_req_ready;
    wire [31:0] mem_req_addr;
    wire        mem_req_write;
    wire [31:0] mem_req_wdata;
    wire [3:0]  mem_req_wstrb;
    reg         mem_rsp_valid = 1'b0;
    wire        mem_rsp_ready;
    reg  [31:0] mem_rsp_data = 32'h0;
    reg         mem_rsp_error = 1'b0;
    wire [1:0] cpu_rsp_error;

    reg [31:0] mem [0:255];
    integer i;
    integer fail = 0;
    reg [63:0] second_data = 64'h0;
    reg        saw_second_rsp = 1'b0;
    reg        saw_new_ready = 1'b0;

    assign mem_req_ready = 1'b1;
    assign mem_rsp_ready = 1'b1;

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            mem_rsp_valid <= 1'b0;
            mem_rsp_data  <= 32'h0;
        end else begin
            if (mem_req_valid && mem_req_ready) begin
                mem_rsp_valid <= 1'b1;
                mem_rsp_data  <= mem[mem_req_addr[31:2]];
                mem_rsp_error <= (mem_req_addr == 0 || mem_req_addr == 12);
            end else if (mem_rsp_valid && mem_rsp_ready) begin
                mem_rsp_valid <= 1'b0;
            end
        end
    end

    wide_imem_adapter dut (
        .clk(clk), .rst(rst),
        .cpu_req_valid(cpu_req_valid), .cpu_req_ready(cpu_req_ready),
        .cpu_req_addr(cpu_req_addr),
        .cpu_rsp_valid(cpu_rsp_valid), .cpu_rsp_ready(cpu_rsp_ready),
        .cpu_rsp_data(cpu_rsp_data), .cpu_rsp_error(cpu_rsp_error),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
        .mem_req_addr(mem_req_addr), .mem_req_write(mem_req_write),
        .mem_req_wdata(mem_req_wdata), .mem_req_wstrb(mem_req_wstrb),
        .mem_rsp_valid(mem_rsp_valid), .mem_rsp_ready(mem_rsp_ready),
        .mem_rsp_rdata(mem_rsp_data), .mem_rsp_error(mem_rsp_error)
    );

    always @(posedge clk) begin
        if (rst == `RstDisable) begin
            if (cpu_req_valid && cpu_req_ready && cpu_req_addr == 32'h8)
                saw_new_ready <= 1'b1;
            if (cpu_rsp_valid && cpu_rsp_ready && saw_new_ready && !saw_second_rsp) begin
                saw_second_rsp <= 1'b1;
                second_data <= cpu_rsp_data;
                if (cpu_rsp_error !== 2'b10) begin
                    $display("FAIL: per-word response error lost"); fail=fail+1;
                end
            end
        end
    end

    initial begin
        for (i = 0; i < 256; i = i + 1) mem[i] = 32'h0;
        mem[0] = 32'h11111111;
        mem[1] = 32'h22222222;
        mem[2] = 32'h33333333;
        mem[3] = 32'h44444444;

        repeat (4) @(posedge clk);
        #1; rst = `RstDisable;

        // First request: consume both beats into S_DONE, but keep CPU refusing
        // the response.  This is the state wide_fetch reaches after a redirect
        // when its fetch epoch has advanced.
        cpu_req_addr  = 32'h0;
        cpu_req_valid = 1'b1;
        wait (cpu_req_valid && cpu_req_ready);
        @(posedge clk);
        cpu_req_valid = 1'b0;

        wait (cpu_rsp_valid);
        repeat (5) @(posedge clk);
        if (!cpu_rsp_valid) begin
            $display("FAIL: adapter did not hold stale response");
            fail = fail + 1;
        end

        // A pending new request cannot cancel a backpressured old response.
        @(negedge clk);
        cpu_req_addr = 32'h8;
        cpu_req_valid = 1'b1;
        repeat (5) begin
            @(negedge clk);
            if (cpu_req_ready || !cpu_rsp_valid ||
                cpu_rsp_data !== 64'h2222222211111111 || cpu_rsp_error !== 2'b01) begin
                $display("FAIL: response changed or request accepted before response handshake");
                fail = fail + 1;
            end
        end
        cpu_rsp_ready = 1'b1;
        @(posedge clk); // old response and new request handshake together
        @(negedge clk);
        cpu_req_valid = 1'b0;

        repeat (100) @(posedge clk);
        #1;
        if (!saw_second_rsp || second_data !== 64'h4444444433333333) begin
            $display("FAIL: second block data=0x%016x expected 0x4444444433333333", second_data);
            fail = fail + 1;
        end

        if (fail == 0) begin
            $display("PASS: response held under backpressure; new request accepted only on response handshake");
            $display("PASS: second 64-bit block assembled correctly with per-word errors");
            $display("ALL TESTS PASSED (wide_imem_adapter)");
        end else begin
            $display("WIDE_IMEM_ADAPTER_RESULT: FAIL failures=%0d", fail);
        end
        $finish;
    end

    initial begin
        #50000;
        $display("WIDE_IMEM_ADAPTER_RESULT: TIMEOUT");
        $finish;
    end
endmodule
