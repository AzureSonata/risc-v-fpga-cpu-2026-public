`timescale 1ns/1ps

module tb_mem_burst_bridge_posted;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;
    reg [31:0] line_addr = 32'b0;
    reg mem_read = 1'b0;
    reg mem_write = 1'b0;
    reg [31:0] wr_addr = 32'b0;
    reg wr_beat_valid = 1'b0;
    wire wr_beat_ready;
    reg [31:0] wr_beat_data = 32'b0;
    reg [3:0] wr_beat_wstrb = 4'hf;
    reg wr_beat_last = 1'b1;
    wire wr_beat_error;
    wire busy;

    wire rd_beat_valid;
    wire rd_beat_ready = 1'b1;
    wire [31:0] rd_beat_data;
    wire rd_beat_last;
    wire rd_beat_error;

    wire req_valid;
    wire req_ready;
    wire [31:0] req_addr;
    wire req_write;
    wire [31:0] req_wdata;
    wire [3:0] req_wstrb;
    reg req_ready_enable = 1'b1;
    reg rsp_valid = 1'b0;
    wire rsp_ready;
    reg [31:0] rsp_rdata = 32'b0;
    reg rsp_error = 1'b0;

    assign req_ready = req_ready_enable && !rsp_valid;

    mem_burst_bridge #(.POSTED_SRAM_WRITE_ACK(1'b1)) dut (
        .clk(clk), .rst(rst),
        .line_addr(line_addr), .mem_read(mem_read), .mem_write(mem_write), .wr_addr(wr_addr),
        .rd_beat_valid(rd_beat_valid), .rd_beat_ready(rd_beat_ready),
        .rd_beat_data(rd_beat_data), .rd_beat_last(rd_beat_last), .rd_beat_error(rd_beat_error),
        .wr_beat_valid(wr_beat_valid), .wr_beat_ready(wr_beat_ready),
        .wr_beat_data(wr_beat_data), .wr_beat_wstrb(wr_beat_wstrb),
        .wr_beat_last(wr_beat_last), .wr_beat_error(wr_beat_error), .busy_o(busy),
        .req_valid(req_valid), .req_ready(req_ready), .req_addr(req_addr),
        .req_write(req_write), .req_wdata(req_wdata), .req_wstrb(req_wstrb),
        .rsp_valid(rsp_valid), .rsp_ready(rsp_ready), .rsp_rdata(rsp_rdata), .rsp_error(rsp_error)
    );

    reg rsp_pending = 1'b0;
    integer rsp_delay = 0;
    integer write_count = 0;
    integer first_read_after_writes = -1;
    integer read_beat_count = 0;
    integer errors = 0;
    reg [31:0] seen_addr [0:7];
    reg [31:0] seen_data [0:7];

    always @(posedge clk) begin
        if (rst) begin
            rsp_valid <= 1'b0;
            rsp_pending <= 1'b0;
            rsp_delay <= 0;
            rsp_rdata <= 32'b0;
        end else begin
            if (rsp_valid && rsp_ready)
                rsp_valid <= 1'b0;

            if (req_valid && req_ready) begin
                if (req_write) begin
                    if (write_count < 8) begin
                        seen_addr[write_count] = req_addr;
                        seen_data[write_count] = req_wdata;
                    end
                    write_count = write_count + 1;
                    if (req_wstrb != 4'hf)
                        errors = errors + 1;
                end else if (first_read_after_writes < 0) begin
                    first_read_after_writes = write_count;
                end
                rsp_pending <= 1'b1;
                rsp_delay <= 2;
                rsp_rdata <= req_addr ^ 32'h5a5a_a5a5;
            end else if (rsp_pending) begin
                if (rsp_delay == 0) begin
                    rsp_valid <= 1'b1;
                    rsp_pending <= 1'b0;
                end else begin
                    rsp_delay <= rsp_delay - 1;
                end
            end

            if (rd_beat_valid && rd_beat_ready) begin
                if (rd_beat_last !== (read_beat_count == 3))
                    errors = errors + 1;
                read_beat_count = read_beat_count + 1;
            end
        end
    end

    task send_store;
        input [31:0] addr;
        input [31:0] data;
        input expect_ready;
        begin
            @(negedge clk);
            mem_write = 1'b1;
            wr_addr = addr;
            wr_beat_data = data;
            wr_beat_valid = 1'b1;
            #1;
            if (wr_beat_ready !== expect_ready) begin
                $display("FAIL: store ready addr=%08x ready=%b expected=%b count=%0d state=%0d",
                         addr, wr_beat_ready, expect_ready, dut.posted_count_q, dut.state);
                errors = errors + 1;
            end
            if (expect_ready && wr_beat_error !== 1'b0) begin
                $display("FAIL: posted SRAM enqueue reported error");
                errors = errors + 1;
            end
            @(posedge clk);
            #1;
            mem_write = 1'b0;
            wr_beat_valid = 1'b0;
        end
    endtask

    task wait_for_write_count;
        input integer target;
        integer timeout;
        begin
            timeout = 0;
            while ((write_count < target) && (timeout < 100)) begin
                @(posedge clk);
                #1;
                timeout = timeout + 1;
            end
            if (write_count < target) begin
                $display("FAIL: timed out waiting for physical writes target=%0d seen=%0d state=%0d",
                         target, write_count, dut.state);
                errors = errors + 1;
            end
        end
    endtask

    task pulse_reset;
        begin
            @(negedge clk);
            rst = 1'b1;
            mem_read = 1'b0;
            mem_write = 1'b0;
            wr_beat_valid = 1'b0;
            repeat (2) @(posedge clk);
            #1;
            @(negedge clk);
            rst = 1'b0;
        end
    endtask

    integer guard;
    initial begin
        repeat (3) @(posedge clk);
        #1 rst = 1'b0;

        // Reset before an active request is accepted. The active payload must
        // survive and retry exactly once after reset is released.
        req_ready_enable = 1'b0;
        send_store(32'h8000_0100, 32'haaaa_0001, 1'b1);
        @(posedge clk);
        #1;
        if ((dut.state != 3'd4) || !dut.active_write_valid_q) begin
            $display("FAIL: expected a retained unaccepted active write before reset");
            errors = errors + 1;
        end
        pulse_reset();
        req_ready_enable = 1'b1;
        wait_for_write_count(1);
        guard = 0;
        while (busy && guard < 100) begin
            @(posedge clk);
            #1;
            guard = guard + 1;
        end
        if (busy) begin
            $display("FAIL: retried write did not drain after reset");
            errors = errors + 1;
        end

        // Reset after SRAM accepted the write but before its response. It is
        // already committed, so reset recovery must not send it a second time.
        send_store(32'h8000_0104, 32'haaaa_0002, 1'b1);
        wait_for_write_count(2);
        if (dut.state != 3'd5) begin
            $display("FAIL: expected response wait before reset state=%0d", dut.state);
            errors = errors + 1;
        end
        pulse_reset();
        repeat (10) begin
            @(posedge clk);
            #1;
        end
        if (write_count != 2 || busy) begin
            $display("FAIL: accepted write repeated or bridge stayed busy after reset writes=%0d busy=%b",
                     write_count, busy);
            errors = errors + 1;
        end

        // The first store starts physical drain; two later stores occupy the
        // queue. A fourth store must see backpressure until a queue slot opens.
        send_store(32'h8000_0000, 32'h1111_1111, 1'b1);
        if (!busy) begin
            $display("FAIL: bridge did not remain busy after early store acknowledgement");
            errors = errors + 1;
        end
        send_store(32'h8000_0004, 32'h2222_2222, 1'b1);
        send_store(32'h8000_0008, 32'h3333_3333, 1'b1);
        send_store(32'h8000_000c, 32'h4444_4444, 1'b0);

        // A refill requested behind queued writes must not reach the adapter
        // until all older stores have physically completed.
        @(negedge clk);
        mem_read = 1'b1;
        line_addr = 32'h8000_1000;
        guard = 0;
        while ((read_beat_count < 4) && (guard < 200)) begin
            @(posedge clk);
            #1;
            guard = guard + 1;
        end
        @(negedge clk);
        mem_read = 1'b0;
        repeat (3) @(posedge clk);
        #1;

        if (write_count != 5) begin
            $display("FAIL: physical store count=%0d expected=5", write_count);
            errors = errors + 1;
        end
        if (seen_addr[0] !== 32'h8000_0100 || seen_data[0] !== 32'haaaa_0001 ||
            seen_addr[1] !== 32'h8000_0104 || seen_data[1] !== 32'haaaa_0002 ||
            seen_addr[2] !== 32'h8000_0000 || seen_data[2] !== 32'h1111_1111 ||
            seen_addr[3] !== 32'h8000_0004 || seen_data[3] !== 32'h2222_2222 ||
            seen_addr[4] !== 32'h8000_0008 || seen_data[4] !== 32'h3333_3333) begin
            $display("FAIL: posted stores were lost, duplicated, or reordered");
            errors = errors + 1;
        end
        if (first_read_after_writes != 5 || read_beat_count != 4) begin
            $display("FAIL: refill ordering/count writes_before_read=%0d beats=%0d",
                     first_read_after_writes, read_beat_count);
            errors = errors + 1;
        end
        if (busy) begin
            $display("FAIL: bridge remained busy after draining posted stores and refill state=%0d count=%0d beats=%0d rd_valid=%b rsp_valid=%b pending=%b",
                     dut.state, dut.posted_count_q, read_beat_count, rd_beat_valid, rsp_valid, rsp_pending);
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("PASS: posted SRAM stores acknowledge on enqueue, drain once in order, backpressure when full, and fence refills");
            $display("ALL TESTS PASSED (mem_burst_bridge_posted)");
        end else
            $display("FAIL: posted SRAM bridge errors=%0d", errors);
        $finish;
    end
endmodule
