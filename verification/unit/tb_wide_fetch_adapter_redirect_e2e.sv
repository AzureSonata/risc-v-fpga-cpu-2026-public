`timescale 1ns/1ps
`include "defines.sv"

// End-to-end protocol test for the real 64-to-32-bit fetch adapter chain.
// An accepted old request must be drained after redirect, and the high word
// at a PC[2]=1 target must be the only instruction exposed to the queue.
module tb_wide_fetch_adapter_redirect_e2e;
    reg clk = 1'b0;
    reg rst = `RstEnable;
    always #5 clk = ~clk;

    reg redirect_valid = 1'b0;
    reg [31:0] redirect_target = 32'h0;
    reg [1:0] push_ready = 2'd0;

    wire cpu_req_valid, cpu_req_ready;
    wire [31:0] cpu_req_addr;
    wire cpu_rsp_valid, cpu_rsp_ready;
    wire [63:0] cpu_rsp_data;
    wire [1:0] cpu_rsp_error;

    wire mem_req_valid, mem_req_ready;
    wire [31:0] mem_req_addr;
    wire mem_req_write;
    wire [31:0] mem_req_wdata;
    wire [3:0] mem_req_wstrb;
    reg mem_rsp_valid = 1'b0;
    wire mem_rsp_ready;
    reg [31:0] mem_rsp_rdata = 32'h0;
    reg mem_rsp_error = 1'b0;

    wire q0_valid, q1_valid;
    wire [31:0] q0_pc, q1_pc, q0_inst, q1_inst;
    wire q0_fault, q1_fault;
    wire [31:0] pc_debug;

    integer i;
    integer stale_rsp_count = 0;

    assign mem_req_ready = 1'b1;

    wide_fetch u_wide_fetch (
        .clk(clk), .rst(rst),
        .redirect_valid(redirect_valid), .redirect_target(redirect_target),
        .i_req_valid(cpu_req_valid), .i_req_ready(cpu_req_ready),
        .i_req_addr(cpu_req_addr),
        .i_rsp_valid(cpu_rsp_valid), .i_rsp_ready(cpu_rsp_ready),
        .i_rsp_data(cpu_rsp_data), .i_rsp_error(cpu_rsp_error),
        .push_ready(push_ready),
        .q0_valid(q0_valid), .q0_pc(q0_pc), .q0_inst(q0_inst), .q0_fault(q0_fault),
        .q1_valid(q1_valid), .q1_pc(q1_pc), .q1_inst(q1_inst), .q1_fault(q1_fault),
        .pc_debug(pc_debug)
    );

    wide_imem_adapter u_adapter (
        .clk(clk), .rst(rst),
        .cpu_req_valid(cpu_req_valid), .cpu_req_ready(cpu_req_ready),
        .cpu_req_addr(cpu_req_addr),
        .cpu_rsp_valid(cpu_rsp_valid), .cpu_rsp_ready(cpu_rsp_ready),
        .cpu_rsp_data(cpu_rsp_data), .cpu_rsp_error(cpu_rsp_error),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
        .mem_req_addr(mem_req_addr), .mem_req_write(mem_req_write),
        .mem_req_wdata(mem_req_wdata), .mem_req_wstrb(mem_req_wstrb),
        .mem_rsp_valid(mem_rsp_valid), .mem_rsp_ready(mem_rsp_ready),
        .mem_rsp_rdata(mem_rsp_rdata), .mem_rsp_error(mem_rsp_error)
    );

    always @(posedge clk) begin
        if (!rst && cpu_rsp_valid && cpu_rsp_ready && stale_rsp_count == 0)
            stale_rsp_count <= stale_rsp_count + 1;
    end

    // Each wait is bounded to five cycles per the verification contract.
    task take_mem_command;
        input [31:0] expected_addr;
        integer n;
        begin
            n = 0;
            while ((!mem_req_valid || !mem_req_ready || mem_req_addr != expected_addr) && n < 5) begin
                @(negedge clk);
                n = n + 1;
            end
            if (!mem_req_valid || !mem_req_ready || mem_req_addr != expected_addr)
                $fatal(1, "FAIL: expected memory command %08x, got valid=%b addr=%08x",
                       expected_addr, mem_req_valid, mem_req_addr);
            if (mem_req_write || mem_req_wdata != 32'h0 || mem_req_wstrb != 4'h0)
                $fatal(1, "FAIL: instruction adapter emitted non-read command");
            @(posedge clk);
            @(negedge clk);
        end
    endtask

    task return_mem_response;
        input [31:0] response_data;
        begin
            mem_rsp_rdata = response_data;
            mem_rsp_error = 1'b0;
            mem_rsp_valid = 1'b1;
            @(posedge clk);
            if (!mem_rsp_ready)
                $fatal(1, "FAIL: adapter did not accept memory response");
            @(negedge clk);
            mem_rsp_valid = 1'b0;
            #1;
        end
    endtask

    initial begin
        repeat (2) @(negedge clk);
        rst = `RstDisable;

        // First fetch at PC 0 is accepted by the adapter and memory accepts
        // the old low-word command. Redirect while its response is outstanding.
        take_mem_command(32'h00000000);
        redirect_target = 32'h0000000c;
        redirect_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        redirect_valid = 1'b0;

        // Delay old low and high responses independently; the adapter must
        // complete the old 64-bit response so wide_fetch can drain it stale.
        repeat (2) @(negedge clk);
        return_mem_response(32'h0bad0000);
        take_mem_command(32'h00000004);
        repeat (2) @(negedge clk);
        return_mem_response(32'h0bad0004);

        // The stale completion and redirected CPU request can handshake in
        // the same cycle. New target block is aligned at 8; PC 0xC is high word.
        take_mem_command(32'h00000008);
        return_mem_response(32'h11111118);
        take_mem_command(32'h0000000c);
        return_mem_response(32'hc0dec00c);

        // Keep the target block in the fetch slot, then expose only its high word.
        repeat (2) @(negedge clk);
        #1;
        if (stale_rsp_count != 1)
            $fatal(1, "FAIL: old adapter response did not handshake as stale (%0d)", stale_rsp_count);
        if (!u_wide_fetch.block_valid_q || !u_wide_fetch.block_hi_q)
            $fatal(1, "FAIL: target high-word block was not retained");
        if (q0_valid || q1_valid)
            $fatal(1, "FAIL: fetch queue exposed an instruction before ready");

        push_ready = 2'd1;
        #1;
        if (!q0_valid || q0_pc != 32'h0000000c || q0_inst != 32'hc0dec00c || q0_fault)
            $fatal(1, "FAIL: wrong PC[2]=1 target word pc=%08x inst=%08x fault=%b",
                   q0_pc, q0_inst, q0_fault);
        if (q1_valid)
            $fatal(1, "FAIL: high-word target generated a second instruction");

        @(posedge clk);
        @(negedge clk);
        #1;
        if (u_wide_fetch.block_valid_q)
            $fatal(1, "FAIL: target high-word block did not consume");

        $display("PASS: accepted old request drained after redirect through wide_imem_adapter");
        $display("PASS: delayed stale low/high responses did not leak into fetch queue");
        $display("PASS: PC[2]=1 target exposed only the target high word (PC=0xC)");
        $display("ALL TESTS PASSED (wide_fetch_adapter_redirect_e2e)");
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "FAIL: timeout");
    end
endmodule
