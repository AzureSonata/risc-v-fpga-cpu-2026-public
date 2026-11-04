`timescale 1ns/1ps

module tb_sram;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;
    reg req_valid = 1'b0;
    wire req_ready;
    reg [31:0] addr = 32'h8000_0000;
    reg write = 1'b0;
    reg [31:0] wdata = 32'b0;
    reg [3:0] wstrb = 4'b0;
    wire rsp_valid;
    reg rsp_ready = 1'b0;
    wire [31:0] rdata;
    wire error;

    sram #(.DEPTH(4), .AW(2)) dut (
        .clk(clk), .rst(rst), .req_valid(req_valid), .req_ready(req_ready),
        .addr(addr), .write(write), .wdata(wdata), .wstrb(wstrb),
        .rsp_valid(rsp_valid), .rsp_ready(rsp_ready), .rdata(rdata), .error(error)
    );

    task transact(input write_i, input [31:0] data_i, input [3:0] strb_i);
        begin
            @(negedge clk);
            while (!req_ready) @(negedge clk);
            write = write_i;
            wdata = data_i;
            wstrb = strb_i;
            req_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
            #1;
            if (!rsp_valid || error) $fatal(1, "SRAM response missing or errored");
            rsp_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            rsp_ready = 1'b0;
        end
    endtask

    task expect_word(input [31:0] expected);
        begin
            transact(1'b0, 32'b0, 4'b0);
            if (rdata !== expected)
                $fatal(1, "SRAM data got=%08h expected=%08h", rdata, expected);
        end
    endtask

    initial begin
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        transact(1'b1, 32'h1122_3344, 4'hf);
        expect_word(32'h1122_3344);
        transact(1'b1, 32'h0000_00aa, 4'h1);
        expect_word(32'h1122_33aa);
        transact(1'b1, 32'h0000_bb00, 4'h2);
        expect_word(32'h1122_bbaa);
        transact(1'b1, 32'h00cc_0000, 4'h4);
        expect_word(32'h11cc_bbaa);
        transact(1'b1, 32'hdd00_0000, 4'h8);
        expect_word(32'hddcc_bbaa);
        transact(1'b1, 32'h0000_0000, 4'h0);
        expect_word(32'hddcc_bbaa);
        transact(1'b1, 32'h5566_7788, 4'b1010);
        expect_word(32'h55cc_77aa);
        transact(1'b1, 32'h1122_3344, 4'b0101);
        expect_word(32'h5522_7744);

        $display("PASS: SRAM full, byte-lane, mixed-mask, and zero-strobe writes");
        $display("ALL TESTS PASSED");
        $finish;
    end
endmodule
