//-----------------------------------------------------------------
// B1: ALU Unit Testbench - All 10 operations + edge cases
//-----------------------------------------------------------------

`timescale 1ns/1ns

module tb_alu;

logic [3:0]  alu_op;
logic [31:0] alu_a, alu_b;
logic [31:0] alu_p;

riscv_alu u_alu (
    .alu_op_i(alu_op),
    .alu_a_i (alu_a),
    .alu_b_i (alu_b),
    .alu_p_o (alu_p)
);

`define ALU_ADD              4'b0100
`define ALU_SUB              4'b0110
`define ALU_AND              4'b0111
`define ALU_OR               4'b1000
`define ALU_XOR              4'b1001
`define ALU_SHIFTL           4'b0001
`define ALU_SHIFTR           4'b0010
`define ALU_SHIFTR_ARITH     4'b0011
`define ALU_LESS_THAN        4'b1010
`define ALU_LESS_THAN_SIGNED 4'b1011

integer pass_cnt, fail_cnt;

initial begin
    pass_cnt = 0;
    fail_cnt = 0;

    $display("========================================");
    $display("  ALU Unit Testbench - Stage1 B1");
    $display("========================================");
    $display("");

    //==============================================================
    // 1. ADD Tests
    //==============================================================
    $display("--- ADD ---");
    test_alu(`ALU_ADD, 32'd1, 32'd2, 32'd3, "1 + 2 = 3");
    test_alu(`ALU_ADD, 32'hFFFFFFFF, 32'd1, 32'd0, "0xFFFFFFFF + 1 = 0");
    test_alu(`ALU_ADD, 32'h7FFFFFFF, 32'd1, 32'h80000000, "MAX_INT + 1 = MIN_INT");
    test_alu(`ALU_ADD, 32'd0, 32'd0, 32'd0, "0 + 0 = 0");
    test_alu(`ALU_ADD, 32'hA5A5A5A5, 32'h5A5A5A5A, 32'hFFFFFFFF, "0xA5A5A5A5 + 0x5A5A5A5A = 0xFFFFFFFF");

    //==============================================================
    // 2. SUB Tests
    //==============================================================
    $display("--- SUB ---");
    test_alu(`ALU_SUB, 32'd5, 32'd3, 32'd2, "5 - 3 = 2");
    test_alu(`ALU_SUB, 32'd0, 32'd1, 32'hFFFFFFFF, "0 - 1 = 0xFFFFFFFF");
    test_alu(`ALU_SUB, 32'd10, 32'd10, 32'd0, "10 - 10 = 0");
    test_alu(`ALU_SUB, 32'h80000000, 32'd1, 32'h7FFFFFFF, "MIN_INT - 1 = MAX_INT");

    //==============================================================
    // 3. AND Tests
    //==============================================================
    $display("--- AND ---");
    test_alu(`ALU_AND, 32'hFF00FF00, 32'h0F0F0F0F, 32'h0F000F00, "AND test 1");
    test_alu(`ALU_AND, 32'hFFFFFFFF, 32'h00000000, 32'h00000000, "AND with zero");
    test_alu(`ALU_AND, 32'hFFFFFFFF, 32'hFFFFFFFF, 32'hFFFFFFFF, "AND with all ones");

    //==============================================================
    // 4. OR Tests
    //==============================================================
    $display("--- OR ---");
    test_alu(`ALU_OR, 32'hFF00FF00, 32'h0F0F0F0F, 32'hFF0FFF0F, "OR test 1");
    test_alu(`ALU_OR, 32'h00000000, 32'hFFFFFFFF, 32'hFFFFFFFF, "OR with all ones");
    test_alu(`ALU_OR, 32'h12345678, 32'h00000000, 32'h12345678, "OR with zero");

    //==============================================================
    // 5. XOR Tests
    //==============================================================
    $display("--- XOR ---");
    test_alu(`ALU_XOR, 32'hFFFFFFFF, 32'hFFFFFFFF, 32'h00000000, "XOR same value");
    test_alu(`ALU_XOR, 32'h12345678, 32'h00000000, 32'h12345678, "XOR with zero");
    test_alu(`ALU_XOR, 32'hFF00FF00, 32'h0F0F0F0F, 32'hF00FF00F, "XOR test");

    //==============================================================
    // 6. Shift Left Tests
    //==============================================================
    $display("--- SLL ---");
    test_alu(`ALU_SHIFTL, 32'd1, 32'd5, 32'd32, "1 << 5 = 32");
    test_alu(`ALU_SHIFTL, 32'd1, 32'd31, 32'h80000000, "1 << 31 = 0x80000000");
    test_alu(`ALU_SHIFTL, 32'hFFFFFFFF, 32'd4, 32'hFFFFFFF0, "0xFFFFFFFF << 4");
    test_alu(`ALU_SHIFTL, 32'd1, 32'd0, 32'd1, "1 << 0 = 1");
    test_alu(`ALU_SHIFTL, 32'hA5, 32'd24, 32'hA5000000, "0xA5 << 24");

    //==============================================================
    // 7. Shift Right Logical Tests
    //==============================================================
    $display("--- SRL ---");
    test_alu(`ALU_SHIFTR, 32'h80000000, 32'd31, 32'd1, "0x80000000 >> 31 = 1");
    test_alu(`ALU_SHIFTR, 32'hFFFFFFFF, 32'd4, 32'h0FFFFFFF, "0xFFFFFFFF >> 4 (logical)");
    test_alu(`ALU_SHIFTR, 32'hF0000000, 32'd4, 32'h0F000000, "0xF0000000 >> 4");
    test_alu(`ALU_SHIFTR, 32'd256, 32'd8, 32'd1, "256 >> 8 = 1");

    //==============================================================
    // 8. Shift Right Arithmetic Tests
    //==============================================================
    $display("--- SRA ---");
    test_alu(`ALU_SHIFTR_ARITH, 32'h80000000, 32'd31, 32'hFFFFFFFF, "0x80000000 >>> 31 = -1");
    test_alu(`ALU_SHIFTR_ARITH, 32'hF0000000, 32'd4, 32'hFF000000, "0xF0000000 >>> 4 = 0xFF000000");
    test_alu(`ALU_SHIFTR_ARITH, 32'h0FFFFFFF, 32'd4, 32'h00FFFFFF, "0x0FFFFFFF >>> 4 (positive)");
    test_alu(`ALU_SHIFTR_ARITH, 32'h7FFFFFFF, 32'd30, 32'd1, "MAX_INT >>> 30 = 1");
    test_alu(`ALU_SHIFTR_ARITH, 32'h80000000, 32'd1, 32'hC0000000, "0x80000000 >>> 1 = 0xC0000000");

    //==============================================================
    // 9. Less Than Unsigned Tests
    //==============================================================
    $display("--- SLTU ---");
    test_alu(`ALU_LESS_THAN, 32'd5, 32'd10, 32'd1, "5 < 10 = true");
    test_alu(`ALU_LESS_THAN, 32'd10, 32'd5, 32'd0, "10 < 5 = false");
    test_alu(`ALU_LESS_THAN, 32'd5, 32'd5, 32'd0, "5 < 5 = false");
    test_alu(`ALU_LESS_THAN, 32'd0, 32'd1, 32'd1, "0 < 1 = true");
    // Unsigned: 0x80000000 > 0x00000001 unsigned
    test_alu(`ALU_LESS_THAN, 32'h80000000, 32'd1, 32'd0, "unsigned: 0x80000000 < 1 = false");

    //==============================================================
    // 10. Less Than Signed Tests
    //==============================================================
    $display("--- SLT ---");
    test_alu(`ALU_LESS_THAN_SIGNED, 32'd5, 32'd10, 32'd1, "signed: 5 < 10 = true");
    test_alu(`ALU_LESS_THAN_SIGNED, 32'd10, 32'd5, 32'd0, "signed: 10 < 5 = false");
    test_alu(`ALU_LESS_THAN_SIGNED, 32'd5, 32'd5, 32'd0, "signed: 5 < 5 = false");
    // -2147483648 (0x80000000) < 1 = true (signed)
    test_alu(`ALU_LESS_THAN_SIGNED, 32'h80000000, 32'd1, 32'd1, "signed: MIN_INT < 1 = true");
    // -1 (0xFFFFFFFF) < 5 = true (signed)
    test_alu(`ALU_LESS_THAN_SIGNED, 32'hFFFFFFFF, 32'd5, 32'd1, "signed: -1 < 5 = true");
    // 1 < -1 = false (signed)
    test_alu(`ALU_LESS_THAN_SIGNED, 32'd1, 32'hFFFFFFFF, 32'd0, "signed: 1 < -1 = false");

    //==============================================================
    // Summary
    //==============================================================
    $display("");
    $display("========================================");
    if (fail_cnt == 0)
        $display("  ALL TESTS PASS (%0d passed)", pass_cnt);
    else
        $display("  FAILED: %0d passed, %0d failed", pass_cnt, fail_cnt);
    $display("========================================");

    if (fail_cnt == 0)
        $finish;
    else
        $fatal(1, "TESTBENCH FAILED");
end

task test_alu(
    input [3:0]  op,
    input [31:0] a,
    input [31:0] b,
    input [31:0] expected,
    input [255:0] desc
);
begin
    alu_op = op;
    alu_a  = a;
    alu_b  = b;
    #1; // Small delay for combinational propagation

    if (alu_p === expected) begin
        pass_cnt = pass_cnt + 1;
        $display("  PASS: %s (result=0x%h)", desc, alu_p);
    end
    else begin
        fail_cnt = fail_cnt + 1;
        $display("  FAIL: %s (got 0x%h, expected 0x%h)", desc, alu_p, expected);
    end
end
endtask

endmodule