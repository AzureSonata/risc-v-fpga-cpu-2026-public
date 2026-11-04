`timescale 1ns/1ps
`include "defines.sv"

module tb_regfile_4r2w;
    reg clk = 1'b0;
    reg rst = `RstEnable;
    always #5 clk = ~clk;

    reg  [4:0] r0a_addr, r0b_addr, r1a_addr, r1b_addr;
    wire [31:0] r0a_data, r0b_data, r1a_data, r1b_data;
    reg         w0_we, w0_bypass_we, w1_we, w1_bypass_we;
    reg  [4:0]  w0_rd, w0_bypass_rd, w1_rd, w1_bypass_rd;
    reg  [31:0] w0_data, w1_data, w1_bypass_data;
    reg         bypass_override;
    reg  [31:0] bypass_override_data;
    wire [31:0] w0_bypass_data = bypass_override ? bypass_override_data : w0_data;

    regfile_4r2w dut (.*);

    integer pass_count = 0;
    integer fail_count = 0;
    task check(input condition, input [1023:0] message);
        begin
            if (condition) begin
                pass_count = pass_count + 1;
                $display("PASS: %0s", message);
            end else begin
                fail_count = fail_count + 1;
                $display("FAIL: %0s", message);
            end
        end
    endtask

    task idle;
        begin
            r0a_addr=0; r0b_addr=0; r1a_addr=0; r1b_addr=0;
            w0_we=0; w0_bypass_we=0; w1_we=0; w1_bypass_we=0;
            w0_rd=0; w0_bypass_rd=0; w1_rd=0; w1_bypass_rd=0;
            w0_data=0; w1_data=0; w1_bypass_data=0;
            bypass_override=0; bypass_override_data=0;
        end
    endtask

    initial begin
        idle();
        repeat (3) @(posedge clk);
        #1; rst = `RstDisable; @(posedge clk); #1;

        r0a_addr=1; r0b_addr=2; r1a_addr=3; r1b_addr=4; #1;
        check(r0a_data==0 && r0b_data==0 && r1a_data==0 && r1b_data==0,
              "register file resets to zero");

        // Write x1 through w0.
        @(negedge clk); w0_we=1; w0_bypass_we=1; w0_rd=1; w0_bypass_rd=1; w0_data=32'h1111_1111;
        @(posedge clk); #1; w0_we=0;
        w0_bypass_we=0;
        r0a_addr=1; #1;
        check(r0a_data==32'h1111_1111, "w0 write is visible on read port");

        // Write x2 through w1 and x3 through w0 in the same cycle.
        @(negedge clk); w0_we=1; w0_bypass_we=1; w0_rd=3; w0_bypass_rd=3; w0_data=32'h3333_3333;
        w1_we=1; w1_bypass_we=1; w1_rd=2; w1_bypass_rd=2; w1_data=32'h2222_2222; w1_bypass_data=32'h2222_2222;
        @(posedge clk); #1; w0_we=0; w0_bypass_we=0; w1_we=0; w1_bypass_we=0;
        r0a_addr=3; r0b_addr=2; #1;
        check(r0a_data==32'h3333_3333 && r0b_data==32'h2222_2222,
              "both write ports work in the same cycle");

        // Same-cycle bypass on all four read ports.
        @(negedge clk); w0_we=1; w0_bypass_we=1; w0_rd=5; w0_bypass_rd=5; w0_data=32'h5555_5555;
        r0a_addr=5; r0b_addr=5; r1a_addr=5; r1b_addr=5; #1;
        check(r0a_data==32'h5555_5555 && r0b_data==32'h5555_5555 &&
              r1a_data==32'h5555_5555 && r1b_data==32'h5555_5555,
              "four read ports see write-port bypass");
        @(posedge clk); #1; w0_we=0; w0_bypass_we=0;

        // The architectural write and same-cycle bypass can use separate
        // data paths; the array must retain the architectural value.
        @(negedge clk); w0_we=1; w0_bypass_we=1; w0_rd=7;
        w0_bypass_rd=7;
        w0_data=32'h1234_5678; bypass_override=1; bypass_override_data=32'hdead_beef;
        r0a_addr=7; r0b_addr=7; r1a_addr=7; r1b_addr=7; #1;
        check(r0a_data==32'hdead_beef && r0b_data==32'hdead_beef &&
              r1a_data==32'hdead_beef && r1b_data==32'hdead_beef,
              "separate bypass data reaches all read ports");
        @(posedge clk); #1; w0_we=0; w0_bypass_we=0; bypass_override=0; #1;
        check(r0a_data==32'h1234_5678, "array write uses architectural data");

        // The read-bypass address is independent of the architectural write
        // address, just like the data paths above.
        @(negedge clk); w0_we=1; w0_bypass_we=1; w0_rd=8; w0_bypass_rd=9;
        w0_data=32'h8888_8888; bypass_override=1; bypass_override_data=32'h9999_9999;
        r0a_addr=9; r0b_addr=8; #1;
        check(r0a_data==32'h9999_9999 && r0b_data==0,
              "bypass rd is independent from architectural write rd");
        @(posedge clk); #1; w0_we=0; w0_bypass_we=0; bypass_override=0; #1;
        check(dut.regs[8]==32'h8888_8888 && dut.regs[9]==0,
              "split bypass rd does not redirect architectural write");

        @(negedge clk); w1_we=1; w1_bypass_we=1; w1_rd=10; w1_bypass_rd=11;
        w1_data=32'h1010_1010; w1_bypass_data=32'h1111_1111;
        r0a_addr=11; r0b_addr=10; #1;
        check(r0a_data==32'h1111_1111 && r0b_data==0,
              "w1 bypass rd/data are independent from architectural write");
        @(posedge clk); #1; w1_we=0; w1_bypass_we=0; #1;
        check(dut.regs[10]==32'h1010_1010 && dut.regs[11]==0,
              "split w1 bypass does not redirect architectural write");

        // Younger w1 wins on same-address write.
        @(negedge clk); w0_we=1; w0_bypass_we=1; w0_rd=6; w0_bypass_rd=6; w0_data=32'h6666_6666;
        w1_we=1; w1_bypass_we=1; w1_rd=6; w1_bypass_rd=6; w1_data=32'h7777_7777; w1_bypass_data=32'h7777_7777;
        @(posedge clk); #1; w0_we=0; w0_bypass_we=0; w1_we=0; w1_bypass_we=0;
        r0a_addr=6; #1;
        check(r0a_data==32'h7777_7777, "younger w1 wins same-address WAW");
        @(negedge clk); w0_we=1; w0_bypass_we=1; w0_rd=6; w0_bypass_rd=6; w0_data=32'h6666_6666; w1_we=1; w1_bypass_we=1; w1_rd=6; w1_bypass_rd=6; w1_data=32'h7777_7777; w1_bypass_data=32'h7777_7777; #1;
        check(r0a_data==32'h7777_7777, "same-cycle WAW bypass selects younger value");
        @(posedge clk); #1; w0_we=0; w0_bypass_we=0; w1_we=0; w1_bypass_we=0;

        // x0 write ignore and x0 read zero.
        @(negedge clk); w0_we=1; w0_bypass_we=1; w0_rd=0; w0_bypass_rd=0; w0_data=32'hdead_beef; r0a_addr=0; #1;
        check(r0a_data==0, "x0 reads zero even during a forced write");
        @(posedge clk); #1; w0_we=0; w0_bypass_we=0;

        // A trap may expose a speculative result through the read bypass while
        // keeping the architectural array write disabled.
        @(negedge clk); w0_we=0; w0_bypass_we=1; w0_rd=1; w0_bypass_rd=1;
        w0_data=32'hdead_beef; r0a_addr=1; #1;
        check(r0a_data==32'hdead_beef, "read-only bypass is visible without array write enable");
        @(posedge clk); #1; w0_bypass_we=0; #1;
        check(r0a_data==32'h1111_1111, "read-only bypass does not update architectural register");

        @(negedge clk); w1_we=0; w1_bypass_we=1; w1_rd=2; w1_bypass_rd=2;
        w1_data=32'hdead_beef; w1_bypass_data=32'hdead_beef; r0b_addr=2; #1;
        check(r0b_data==32'hdead_beef, "younger read-only bypass is visible without array write enable");
        @(posedge clk); #1; w1_bypass_we=0; #1;
        check(r0b_data==32'h2222_2222, "younger read-only bypass does not update architectural register");

        if (fail_count == 0)
            $display("ALL TESTS PASSED (regfile_4r2w: %0d checks)", pass_count);
        else
            $display("REGFILE_4R2W_RESULT: FAIL (%0d pass / %0d fail)", pass_count, fail_count);
        $finish;
    end

    initial begin
        #5000;
        $display("REGFILE_4R2W_RESULT: TIMEOUT");
        $finish;
    end
endmodule
