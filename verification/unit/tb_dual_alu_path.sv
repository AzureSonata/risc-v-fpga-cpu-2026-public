`timescale 1ns/1ps
`include "defines.sv"

module tb_dual_alu_path;
    reg clk = 1'b0;
    reg rst = `RstEnable;
    always #5 clk = ~clk;

    reg        s0_valid, s0_illegal, s0_is_alu, s0_reg_write;
    reg [4:0]  s0_rs1, s0_rs2, s0_rd;
    reg        s0_uses_rs1, s0_uses_rs2;
    reg [31:0] s0_pc, s0_instr, s0_ra, s0_rb;
    reg        s1_valid, s1_illegal, s1_is_alu, s1_reg_write;
    reg [4:0]  s1_rs1, s1_rs2, s1_rd;
    reg        s1_uses_rs1, s1_uses_rs2;
    reg [31:0] s1_pc, s1_instr, s1_ra, s1_rb;
    reg        backend_stall;

    wire issue0, issue1, slot1_stall;
    wire w0_valid, w0_we;
    wire [4:0] w0_rd;
    wire [31:0] w0_data;
    wire w1_valid, w1_we;
    wire [4:0] w1_rd;
    wire [31:0] w1_data;
    wire ex0_branch_request, ex0_branch_taken;
    wire [31:0] ex0_branch_pc, ex0_branch_source;

    dual_alu_path dut (.*);

    // Put the writeback ports through the 4R2W register file so the test proves
    // the ALU slice and dual-write contract together.
    reg  [4:0] r0a_addr, r0b_addr, r1a_addr, r1b_addr;
    wire [31:0] r0a_data, r0b_data, r1a_data, r1b_data;
    regfile_4r2w u_rf (
        .clk(clk), .rst(rst),
        .r0a_addr(r0a_addr), .r0a_data(r0a_data),
        .r0b_addr(r0b_addr), .r0b_data(r0b_data),
        .r1a_addr(r1a_addr), .r1a_data(r1a_data),
        .r1b_addr(r1b_addr), .r1b_data(r1b_data),
        .w0_we(w0_we), .w0_bypass_we(w0_we),
        .w0_rd(w0_rd), .w0_bypass_rd(w0_rd),
        .w0_data(w0_data), .w0_bypass_data(w0_data),
        .w1_we(w1_we), .w1_bypass_we(w1_we),
        .w1_rd(w1_rd), .w1_bypass_rd(w1_rd),
        .w1_data(w1_data), .w1_bypass_data(w1_data)
    );

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
            s0_valid=0; s0_illegal=0; s0_is_alu=0; s0_reg_write=0;
            s0_rs1=0; s0_rs2=0; s0_rd=0; s0_uses_rs1=0; s0_uses_rs2=0;
            s0_pc=0; s0_instr=0; s0_ra=0; s0_rb=0;
            s1_valid=0; s1_illegal=0; s1_is_alu=0; s1_reg_write=0;
            s1_rs1=0; s1_rs2=0; s1_rd=0; s1_uses_rs1=0; s1_uses_rs2=0;
            s1_pc=0; s1_instr=0; s1_ra=0; s1_rb=0;
            backend_stall=0;
            r0a_addr=0; r0b_addr=0; r1a_addr=0; r1b_addr=0;
        end
    endtask

    initial begin
        idle();
        repeat (3) @(posedge clk);
        #1; rst = `RstDisable; @(posedge clk); #1;

        // The default dual ALU slice is shared with the mini-core and must
        // retain the legacy selected-PC contract for an untaken branch.
        idle(); @(negedge clk);
        s0_valid=1; s0_is_alu=1; s0_pc=32'h0000_0008;
        s0_instr=32'h0000_1163; // BNE x0,x0,+2 (not taken)
        @(posedge clk); #1;
        check(ex0_branch_request==1 && ex0_branch_taken==0 &&
              ex0_branch_pc==32'h0000_000c,
              "default branch_pc remains pc+4 for a not-taken branch");

        idle(); @(negedge clk);
        s0_valid=1; s0_is_alu=1; s0_pc=32'h0000_0010;
        s0_instr=32'h0000_006f; // JAL x0,0
        @(posedge clk); #1;
        check(ex0_branch_request==1 && ex0_branch_taken==1 &&
              ex0_branch_pc==32'h0000_0010,
              "default branch_pc remains target for a taken JAL");

        // Two independent ADDI instructions: x1=5, x2=7.
        @(negedge clk);
        s0_valid=1; s0_is_alu=1; s0_reg_write=1; s0_rd=1; s0_instr=32'h00500093;
        s1_valid=1; s1_is_alu=1; s1_reg_write=1; s1_rd=2; s1_instr=32'h00700113; #1;
        check(issue0==1 && issue1==1, "independent ALU pair issues together");
        @(posedge clk); #1;
        check(w0_valid==1 && w0_we==1 && w0_rd==1 && w0_data==32'd5,
              "lane0 ALU writeback valid");
        check(w1_valid==1 && w1_we==1 && w1_rd==2 && w1_data==32'd7,
              "lane1 ALU writeback valid in same cycle");
        @(posedge clk); #1;
        r0a_addr=1; r0b_addr=2; #1;
        check(r0a_data==32'd5 && r0b_data==32'd7,
              "both ALU results land in 4R2W register file");

        // RAW: s1 reads x1 written by s0 -> lane1 must not issue.
        idle(); @(negedge clk);
        s0_valid=1; s0_is_alu=1; s0_reg_write=1; s0_rd=1; s0_instr=32'h00500093;
        s1_valid=1; s1_is_alu=1; s1_reg_write=1; s1_rd=2; s1_rs1=1;
        s1_uses_rs1=1; s1_instr=32'h00100113; #1;
        check(issue0==1 && issue1==0 && slot1_stall==1,
              "intra-group RAW blocks lane1");
        @(posedge clk); #1;
        check(w0_valid==1 && w1_valid==0, "RAW leaves only lane0 writeback");

        // WAW: both write x3 -> lane1 must not issue.
        idle(); @(negedge clk);
        s0_valid=1; s0_is_alu=1; s0_reg_write=1; s0_rd=3; s0_instr=32'h00500193;
        s1_valid=1; s1_is_alu=1; s1_reg_write=1; s1_rd=3; s1_instr=32'h00700193; #1;
        check(issue0==1 && issue1==0, "intra-group WAW blocks lane1");

        // lane1 non-ALU -> reject.
        idle(); @(negedge clk);
        s0_valid=1; s0_is_alu=1; s0_reg_write=1; s0_rd=1; s0_instr=32'h00500093;
        s1_valid=1; s1_is_alu=0; s1_reg_write=1; s1_rd=2; s1_instr=32'h00700113; #1;
        check(issue0==1 && issue1==0, "non-ALU lane1 is rejected");

        // x0 write does not create a dependency.
        idle(); @(negedge clk);
        s0_valid=1; s0_is_alu=1; s0_reg_write=1; s0_rd=0; s0_instr=32'h00500013;
        s1_valid=1; s1_is_alu=1; s1_reg_write=1; s1_rd=2; s1_rs1=0;
        s1_uses_rs1=1; s1_instr=32'h00700113; #1;
        check(issue0==1 && issue1==1, "x0 write does not block lane1");

        // backend stall blocks both lanes.
        idle(); @(negedge clk);
        s0_valid=1; s0_is_alu=1; s0_reg_write=1; s0_rd=1; s0_instr=32'h00500093;
        s1_valid=1; s1_is_alu=1; s1_reg_write=1; s1_rd=2; s1_instr=32'h00700113;
        backend_stall=1; #1;
        check(issue0==0 && issue1==0, "backend stall blocks both lanes");

        if (fail_count == 0)
            $display("ALL TESTS PASSED (dual_alu_path: %0d checks)", pass_count);
        else
            $display("DUAL_ALU_PATH_RESULT: FAIL (%0d pass / %0d fail)", pass_count, fail_count);
        $finish;
    end

    initial begin
        #10000;
        $display("DUAL_ALU_PATH_RESULT: TIMEOUT");
        $finish;
    end
endmodule
