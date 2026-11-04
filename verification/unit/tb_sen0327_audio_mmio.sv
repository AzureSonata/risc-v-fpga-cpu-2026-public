`timescale 1ns/1ps
`default_nettype none

module tb_sen0327_audio_mmio;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;
    reg sample_valid = 1'b0;
    wire sample_ready;
    reg signed [15:0] sample_data = 16'sd0;
    reg [9:0] fifo_level = 10'd0;
    reg overrun = 1'b0;
    wire overrun_clear;

    reg req_valid = 1'b0;
    wire req_ready;
    reg [31:0] addr = 32'd0;
    reg write = 1'b0;
    reg [31:0] wdata = 32'd0;
    reg [3:0] wstrb = 4'd0;
    wire rsp_valid;
    reg rsp_ready = 1'b1;
    wire [31:0] rdata;
    wire error;

    integer pop_count = 0;
    integer overrun_clear_count = 0;

    sen0327_audio_mmio #(.FIFO_DEPTH(512)) dut (
        .clk(clk), .rst(rst),
        .sample_valid(sample_valid), .sample_ready(sample_ready),
        .sample_data(sample_data), .fifo_level(fifo_level),
        .overrun(overrun), .overrun_clear(overrun_clear),
        .req_valid(req_valid), .req_ready(req_ready), .addr(addr),
        .write(write), .wdata(wdata), .wstrb(wstrb),
        .rsp_valid(rsp_valid), .rsp_ready(rsp_ready),
        .rdata(rdata), .error(error)
    );

    always @(posedge clk) begin
        if (!rst && sample_ready) pop_count <= pop_count + 1;
        if (!rst && overrun_clear) overrun_clear_count <= overrun_clear_count + 1;
    end

    task automatic access(
        input reg do_write,
        input [31:0] address,
        input [31:0] data,
        input [3:0] strobe,
        output reg [31:0] result,
        output reg failed
    );
        begin
            @(negedge clk);
            addr = address;
            write = do_write;
            wdata = data;
            wstrb = strobe;
            req_valid = 1'b1;
            while (!req_ready) @(negedge clk);
            @(posedge clk);
            #1;
            if (!rsp_valid) $fatal(1, "audio MMIO response missing for %08x", address);
            result = rdata;
            failed = error;
            req_valid = 1'b0;
            write = 1'b0;
            wstrb = 4'd0;
            @(posedge clk);
            #1;
        end
    endtask

    reg [31:0] value;
    reg failed;
    initial begin
        repeat (3) @(posedge clk);
        rst = 1'b0;
        @(negedge clk);

        access(1'b0, 32'h4000_2000, 32'd0, 4'd0, value, failed);
        if (failed || value !== 32'd0 || pop_count != 0)
            $fatal(1, "empty DATA read must return zero without pop");

        sample_valid = 1'b1;
        sample_data = -16'sd128;
        fifo_level = 10'd1;
        access(1'b0, 32'h4000_2000, 32'd0, 4'd0, value, failed);
        if (failed || value !== 32'hffff_ff80 || pop_count != 1)
            $fatal(1, "DATA sign extension/pop mismatch: value=%08x pops=%0d", value, pop_count);

        access(1'b0, 32'h4000_2004, 32'd0, 4'd0, value, failed);
        if (failed || value !== 32'd1)
            $fatal(1, "LEVEL mismatch: %08x", value);
        access(1'b0, 32'h4000_2008, 32'd0, 4'd0, value, failed);
        if (failed || value !== 32'd1)
            $fatal(1, "nonempty STATUS mismatch: %08x", value);

        fifo_level = 10'd512;
        overrun = 1'b1;
        access(1'b0, 32'h4000_2008, 32'd0, 4'd0, value, failed);
        if (failed || value !== 32'd7)
            $fatal(1, "full/overrun STATUS mismatch: %08x", value);
        access(1'b0, 32'h4000_200c, 32'd0, 4'd0, value, failed);
        if (failed || value !== 32'd1)
            $fatal(1, "OVERRUN read mismatch: %08x", value);

        access(1'b1, 32'h4000_200c, 32'd1, 4'b0001, value, failed);
        if (failed || overrun_clear_count != 1)
            $fatal(1, "OVERRUN W1C did not pulse on accepted byte write");
        overrun = 1'b0;

        access(1'b0, 32'h4000_2001, 32'd0, 4'd0, value, failed);
        if (!failed) $fatal(1, "misaligned access must return bus error");
        access(1'b1, 32'h4000_2000, 32'd1, 4'b1111, value, failed);
        if (!failed) $fatal(1, "write to read-only DATA must return bus error");
        access(1'b0, 32'h4000_2010, 32'd0, 4'd0, value, failed);
        if (!failed) $fatal(1, "unallocated register must return bus error");

        // A stalled response must remain stable and must not repeat the FIFO pop.
        rsp_ready = 1'b0;
        @(negedge clk);
        addr = 32'h4000_2000;
        req_valid = 1'b1;
        sample_data = 16'sh1234;
        sample_valid = 1'b1;
        @(posedge clk);
        #1;
        req_valid = 1'b0;
        if (!rsp_valid || rdata !== 32'h0000_1234 || pop_count != 2)
            $fatal(1, "stalled DATA response/pop mismatch");
        repeat (3) begin
            @(posedge clk);
            #1;
            if (!rsp_valid || rdata !== 32'h0000_1234 || pop_count != 2)
                $fatal(1, "stalled response changed or popped twice");
        end
        rsp_ready = 1'b1;
        @(posedge clk);
        #1;
        if (rsp_valid) $fatal(1, "response did not retire after ready");

        $display("PASS: SEN0327 audio MMIO DATA/LEVEL/STATUS/OVERRUN handshake");
        $finish;
    end
endmodule

`default_nettype wire
