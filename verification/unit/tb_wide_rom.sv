`timescale 1ns/1ps
`include "defines.sv"

module tb_wide_rom;
    reg clk = 1'b0;
    reg rst = `RstEnable;
    always #5 clk = ~clk;

    reg         req_valid;
    wire        req_ready;
    reg  [31:0] req_addr;
    wire        rsp_valid;
    reg         rsp_ready;
    wire [63:0] rsp_data;
    wire        error;

    wide_rom #(
        .DEPTH(16), .AW(4),
        .INIT_FILE("verification/unit/wide_rom_test.hex")
    ) dut (
        .clk(clk), .rst(rst),
        .req_valid(req_valid), .req_ready(req_ready), .req_addr(req_addr),
        .rsp_valid(rsp_valid), .rsp_ready(rsp_ready), .rsp_data(rsp_data),
        .error(error)
    );

    integer pass_count = 0, fail_count = 0;
    task check(input condition, input [1023:0] message);
        begin
            if (condition) begin pass_count = pass_count + 1; $display("PASS: %0s", message); end
            else begin fail_count = fail_count + 1; $display("FAIL: %0s", message); end
        end
    endtask

    reg [31:0] exp_lo, exp_hi;
    initial begin
        req_valid = 0; req_addr = 0; rsp_ready = 1;
        repeat (3) @(posedge clk);
        #1; rst = `RstDisable; @(posedge clk); #1;

        // Word 0/1 from the deterministic test image.
        @(negedge clk); req_valid = 1; req_addr = 32'h0;
        @(posedge clk); #1; req_valid = 0;
        exp_lo = 32'h00000013 | (1 << 20) | (1 << 7);
        exp_hi = 32'h00000013 | (2 << 20) | (2 << 7);
        check(rsp_valid == 1 && rsp_data[31:0] == exp_lo && rsp_data[63:32] == exp_hi,
              "64-bit block 0 combines adjacent ROM words");
        @(posedge clk); #1;

        // Word 2/3.
        @(negedge clk); req_valid = 1; req_addr = 32'h8;
        @(posedge clk); #1; req_valid = 0;
        exp_lo = 32'h00000013 | (3 << 20) | (3 << 7);
        exp_hi = 32'h00000013 | (4 << 20) | (4 << 7);
        check(rsp_valid == 1 && rsp_data[31:0] == exp_lo && rsp_data[63:32] == exp_hi,
              "64-bit block 1 combines adjacent ROM words");
        @(posedge clk); #1;

        if (fail_count == 0)
            $display("ALL TESTS PASSED (wide_rom: %0d checks)", pass_count);
        else
            $display("WIDE_ROM_RESULT: FAIL (%0d pass / %0d fail)", pass_count, fail_count);
        $finish;
    end

    initial begin
        #20000; $display("WIDE_ROM_RESULT: TIMEOUT"); $finish;
    end
endmodule
