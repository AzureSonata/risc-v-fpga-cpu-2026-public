`timescale 1ns/1ps
`include "defines.sv"

// Machine counter tests from RISC-V Privileged 1.13 and Zicsr 2.0.
// Expectations are explicit arithmetic values, not a copy of the RTL update logic.
module tb_csr_counters;
    reg clk = 0;
    always #10 clk = ~clk;
    reg rst = 1;
    reg [1:0] retire_count = 0;
    reg [11:0] addr = 0, chk_addr = 0;
    reg we = 0;
    reg [1:0] op = 0;
    reg [31:0] wdata = 0;
    reg trap = 0, mret = 0;
    wire [31:0] rdata;
    wire impl, writable, chk_impl, chk_writable;
    integer checks = 0;
    reg [31:0] before_cycle;

    csr_file dut (
        .clk(clk), .rst(rst), .retire_count(retire_count),
        .csr_addr(addr), .csr_rdata(rdata),
        .csr_implemented(impl), .csr_writable(writable),
        .csr_chk_addr(chk_addr), .csr_chk_implemented(chk_impl),
        .csr_chk_writable(chk_writable),
        .csr_we(we), .csr_op(op), .csr_wdata(wdata),
        .trap_enter(trap), .trap_pc(32'h40), .trap_cause(32'd11),
        .trap_tval(32'd0), .mret(mret), .timer_irq(1'b0), .ext_irq(1'b0),
        .mip(), .mie(), .irq_pending(), .irq_cause(),
        .mstatus(), .mtvec(), .mepc(), .mcause(), .mtval()
    );

    task check32(input [255:0] name, input [31:0] got, input [31:0] expected);
        begin
            checks = checks + 1;
            if (got !== expected) begin
                $display("FAIL %0s got=%08x expected=%08x", name, got, expected);
                $fatal(1, "counter check failed");
            end
            $display("PASS %0s", name);
        end
    endtask

    // All stimulus changes are at/after negedge and before the next posedge.
    task step(input [1:0] n);
        begin
            retire_count = n;
            @(posedge clk); #1;
            @(negedge clk);
        end
    endtask

    task wr(input [11:0] a, input [1:0] operation,
            input [31:0] value, input [1:0] n);
        begin
            addr = a; op = operation; wdata = value; we = 1;
            retire_count = n;
            @(posedge clk); #1;
            we = 0; retire_count = 0;
            @(negedge clk);
        end
    endtask

    task rd(input [11:0] a, input [31:0] expected);
        begin
            addr = a; chk_addr = a; #1;
            check32("counter address implemented/RW", {28'b0, impl, writable,
                    chk_impl, chk_writable}, 32'hf);
            check32("counter value", rdata, expected);
        end
    endtask

    initial begin
        repeat (2) @(posedge clk);
        @(negedge clk);
        rd(12'hB00, 0); rd(12'hB80, 0);
        rd(12'hB02, 0); rd(12'hB82, 0);
        rst = 0;
        step(0); rd(12'hB00, 1); rd(12'hB02, 0);
        step(1); rd(12'hB02, 1);
        step(2); rd(12'hB02, 3);
        step(0); rd(12'hB02, 3);

        // Low-half rollover carries into high, for both one and two retires.
        wr(12'hB02, 0, 32'hfffffffe, 1);
        rd(12'hB02, 32'hfffffffe);
        step(2); rd(12'hB02, 0); rd(12'hB82, 1);
        wr(12'hB82, 0, 32'h12345678, 1);
        rd(12'hB02, 0); rd(12'hB82, 32'h12345678);
        wr(12'hB02, 1, 32'hf, 1); rd(12'hB02, 32'hf);
        wr(12'hB02, 2, 32'h5, 1); rd(12'hB02, 32'ha);
        wr(12'hB82, 1, 32'h80000000, 1); rd(12'hB82, 32'h92345678);
        wr(12'hB82, 2, 32'h90000000, 1); rd(12'hB82, 32'h02345678);

        // Full 64-bit modulo wrap and an explicit write suppressing its own retire.
        wr(12'hB82, 0, 32'hffffffff, 1);
        wr(12'hB02, 0, 32'hffffffff, 1);
        step(1); rd(12'hB02, 0); rd(12'hB82, 0);
        wr(12'hB02, 0, 32'd20, 1); rd(12'hB02, 20);
        addr = 12'hB02; retire_count = 1; #1;
        check32("CSR read sees pre-retirement value", rdata, 20);
        @(posedge clk); #1;
        check32("CSR read instruction subsequently retires", rdata, 21);
        retire_count = 0; @(negedge clk);

        // mcycle high/low writes suppress increment to the whole counter on that edge.
        wr(12'hB00, 0, 32'hfffffffe, 0);
        wr(12'hB80, 0, 32'd7, 0);
        rd(12'hB00, 32'hfffffffe); rd(12'hB80, 7);
        step(0); rd(12'hB00, 32'hffffffff); rd(12'hB80, 7);
        step(0); rd(12'hB00, 0); rd(12'hB80, 8);
        wr(12'hB80, 0, 32'hffffffff, 0);
        wr(12'hB00, 0, 32'hffffffff, 0);
        step(0); rd(12'hB00, 0); rd(12'hB80, 0);
        wr(12'hB00, 0, 32'h10, 0);
        wr(12'hB00, 1, 32'h4, 0); rd(12'hB00, 32'h14);
        wr(12'hB00, 2, 32'h10, 0); rd(12'hB00, 4);

        // A write to another CSR does not stop cycle counting; faulted writes are ignored.
        addr = 12'hB00; #1; before_cycle = rdata;
        wr(12'hB02, 0, 32'd55, 1);
        rd(12'hB00, before_cycle + 1); rd(12'hB02, 55);
        addr = 12'hB00; #1; before_cycle = rdata;
        trap = 1;
        wr(12'hB00, 0, 32'hdeadbeef, 0);
        rd(12'hB00, before_cycle + 1); rd(12'hB02, 55);
        trap = 0;
        step(0); rd(12'hB02, 55);
        mret = 1; step(1); mret = 0; rd(12'hB02, 56);

        // No new cycle aliases, inhibit or unsupported counters are silently enabled.
        addr=12'hC00; chk_addr=12'hC00; #1;
        check32("user cycle alias stays unsupported", {30'b0,impl,chk_impl}, 0);
        addr=12'hB03; chk_addr=12'hB03; #1;
        check32("unsupported HPM stays illegal", {30'b0,impl,chk_impl}, 0);
        $display("ALL TESTS PASSED (csr_counters checks=%0d)", checks);
        $finish;
    end
    initial begin #100000; $fatal(1,"FAIL csr_counters timeout"); end
endmodule
