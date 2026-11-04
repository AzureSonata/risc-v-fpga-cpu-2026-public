//-----------------------------------------------------------------
// B1: EX Unit Testbench - ALU control, immediates, branch
//-----------------------------------------------------------------

`timescale 1ns/1ns

module tb_exec;

logic        clk, rst;
logic        valid_i;
logic [31:0] opcode_i, pc_i;
logic [31:0] ra_operand_i, rb_operand_i;
logic        hold_i;

logic        valid_o;
logic [31:0] alu_result_o, alu_result_e1_o;
logic        branch_request_o, branch_taken_o, branch_not_taken_o;
logic [31:0] branch_pc_o, branch_source_o;
logic        branch_call_o, branch_ret_o, branch_jmp_o;

riscv_exec u_exec (
    .clk_i(clk),
    .rst_i(rst),
    .valid_i(valid_i),
    .opcode_i(opcode_i),
    .pc_i(pc_i),
    .ra_operand_i(ra_operand_i),
    .rb_operand_i(rb_operand_i),
    .hold_i(hold_i),
    .valid_o(valid_o),
    .alu_result_o(alu_result_o),
    .alu_result_e1_o(alu_result_e1_o),
    .branch_request_o(branch_request_o),
    .branch_taken_o(branch_taken_o),
    .branch_not_taken_o(branch_not_taken_o),
    .branch_pc_o(branch_pc_o),
    .branch_source_o(branch_source_o),
    .branch_call_o(branch_call_o),
    .branch_ret_o(branch_ret_o),
    .branch_jmp_o(branch_jmp_o)
);

// Clock generation
always #5 clk = ~clk;

integer pass_cnt, fail_cnt;

initial begin
    pass_cnt = 0; fail_cnt = 0;
    clk = 0; rst = 1; hold_i = 0;
    valid_i = 0; opcode_i = 0; pc_i = 0;
    ra_operand_i = 0; rb_operand_i = 0;

    $display("========================================");
    $display("  EX Unit Testbench - Stage1 B1");
    $display("========================================");
    $display("");

    // Reset
    #12 rst = 0;
    #10;

    //==============================================================
    // 1. ADDI: x1 = x0 + 5
    //==============================================================
    $display("--- ADDI ---");
    // ADDI x1, x0, 5 = 0x00500293 (imm=5, rs1=x0, rd=x1, opcode=0x13)
    // Actually: opcode[6:0]=0010011, rd=x1=00001, funct3=000, rs1=x0=00000, imm=000000000101
    // = 0x00500293
    apply(32'h00500293, 32'h100, 32'd0, 32'd0);
    #10;
    check("ADDI: x0+5=5", 32'd5);
    // Also check E1 bypass
    if (alu_result_e1_o !== 32'd5) begin
        $display("  FAIL: E1 bypass wrong (got 0x%h)", alu_result_e1_o);
        fail_cnt = fail_cnt + 1;
    end else
        pass_cnt = pass_cnt + 1;

    //==============================================================
    // 2. ADD: x3 = x1 + x2
    //==============================================================
    $display("--- ADD ---");
    // ADD x3, x1, x2 = 0x002081B3
    apply(32'h002081B3, 32'h104, 32'd10, 32'd20);
    #10;
    check("ADD: 10+20=30", 32'd30);

    //==============================================================
    // 3. SUB: x4 = x1 - x2
    //==============================================================
    $display("--- SUB ---");
    // SUB x4, x1, x2 = 0x40208233
    apply(32'h40208233, 32'h108, 32'd20, 32'd8);
    #10;
    check("SUB: 20-8=12", 32'd12);

    //==============================================================
    // 4. ANDI
    //==============================================================
    $display("--- ANDI ---");
    // ANDI x5, x1, 0xFF = 0x0FF0F293 (imm=0x0FF, rs1=x1, rd=x5)
    // Actually: imm=000000001111, funct3=111, rs1=00001, rd=00101, opcode=0010011
    // = 0xFF0F293... need correct encoding
    // ANDI x1, x0, 0xFF = 0xFF007293? No...
    // Let me check: I-type: imm[11:0] | rs1[4:0] | funct3[2:0] | rd[4:0] | opcode[6:0]
    // For ANDI x1, x0, 0xFF:
    // imm=0xFF=000011111111, rs1=x0=00000, funct3=111, rd=x1=00001, opcode=0010011
    // = 0000_1111_1111_0000_0111_0000_1001_0011 = 0x0FF07093
    apply(32'h0FF07093, 32'h10C, 32'hA5, 32'd0);
    #10;
    check("ANDI: 0xA5 & 0xFF = 0xA5", 32'hA5);

    //==============================================================
    // 5. ORI
    //==============================================================
    $display("--- ORI ---");
    // ORI x1, x0, 0xF0 = 0x0F006093 (imm=0x0F0, funct3=110, rd=x1)
    apply(32'h0F006093, 32'h110, 32'h05, 32'd0);
    #10;
    check("ORI: 0x05 | 0xF0 = 0xF5", 32'hF5);

    //==============================================================
    // 6. XORI
    //==============================================================
    $display("--- XORI ---");
    // XORI x1, x0, 0xFF = 0xFF004013 (imm=0xFF, funct3=100, rd=x1)
    apply(32'h0FF04013, 32'h114, 32'hA5, 32'd0);
    #10;
    check("XORI: 0xA5 ^ 0xFF = 0x5A", 32'h5A);

    //==============================================================
    // 7. LUI
    //==============================================================
    $display("--- LUI ---");
    // LUI x1, 0x12345 = 0x12345037 (imm=0x12345, rd=x1, opcode=0110111)
    apply(32'h12345037, 32'h118, 32'd0, 32'd0);
    #10;
    check("LUI: 0x12345000", 32'h12345000);

    //==============================================================
    // 8. AUIPC
    //==============================================================
    $display("--- AUIPC ---");
    // AUIPC x1, 0x10000 (imm << 12 = 0x10000)
    // = 0x10000197
    apply(32'h10000197, 32'h1000, 32'd0, 32'd0);
    #10;
    check("AUIPC: 0x1000 + 0x10000000 = 0x10001000", 32'h10001000);

    //==============================================================
    // 9. Branch: BEQ taken
    //==============================================================
    $display("--- BEQ (taken) ---");
    // BEQ x1, x2, +8 (offset=8 = 0b0000000_00100_0XX)
    // B-type: imm[12|10:5] | rs2 | rs1 | funct3 | imm[4:1|11] | opcode
    // offset=8 = 0b000000001000, bit0 always 0
    // = 0x00208463
    apply(32'h00208463, 32'h120, 32'd5, 32'd5);
    #10;
    // Check branch: taken expected
    if (!branch_request_o || !branch_taken_o || branch_not_taken_o) begin
        $display("  FAIL: BEQ taken expected");
        fail_cnt = fail_cnt + 1;
    end else begin
        $display("  PASS: BEQ taken (req=%b, taken=%b, nTaken=%b)",
                 branch_request_o, branch_taken_o, branch_not_taken_o);
        pass_cnt = pass_cnt + 1;
    end

    //==============================================================
    // 10. Branch: BNE taken
    //==============================================================
    $display("--- BNE (taken) ---");
    // BNE x1, x2, offset=0 (not taken check)
    apply(32'h00209463, 32'h124, 32'd5, 32'd10);
    #10;
    if (!branch_request_o || !branch_taken_o) begin
        $display("  FAIL: BNE taken expected");
        fail_cnt = fail_cnt + 1;
    end else begin
        $display("  PASS: BNE taken (req=%b, taken=%b)", branch_request_o, branch_taken_o);
        pass_cnt = pass_cnt + 1;
    end

    //==============================================================
    // 11. Branch: BNE not taken
    //==============================================================
    $display("--- BNE (not taken) ---");
    apply(32'h00209463, 32'h128, 32'd5, 32'd5);
    #10;
    if (!branch_request_o || branch_taken_o || !branch_not_taken_o) begin
        $display("  FAIL: BNE not taken expected");
        fail_cnt = fail_cnt + 1;
    end else begin
        $display("  PASS: BNE not taken (req=%b, taken=%b, nTaken=%b)",
                 branch_request_o, branch_taken_o, branch_not_taken_o);
        pass_cnt = pass_cnt + 1;
    end

    //==============================================================
    // 12. Shift: SLLI
    //==============================================================
    $display("--- SLLI ---");
    // SLLI x1, x1, 4 = 0x00409093 (shamt=4, funct3=001, rs1=x1, rd=x1)
    apply(32'h00409093, 32'h12C, 32'd3, 32'd0);
    #10;
    check("SLLI: 3 << 4 = 48", 32'd48);

    //==============================================================
    // 13. Shift: SRAI (arithmetic)
    //==============================================================
    $display("--- SRAI ---");
    // SRAI x1, x1, 4 = 0x4040D013 (funct7=0100000, shamt=00100, funct3=101, rs1=x1, rd=x1)
    apply(32'h4040D013, 32'h130, 32'h80000000, 32'd0);
    #10;
    check("SRAI: 0x80000000 >>> 4 = 0xF8000000", 32'hF8000000);

    //==============================================================
    // 14. SLTI (signed less than immediate)
    //==============================================================
    $display("--- SLTI ---");
    // SLTI x1, x0, 10 = 0x00A02013 (imm=10=0x00A, funct3=010)
    apply(32'h00A02013, 32'h134, 32'd5, 32'd0);
    #10;
    check("SLTI: 5 < 10 = 1", 32'd1);
    // SLTI x1, x0, 3 = 0x00302013 (imm=3, 5 < 3 = false)
    apply(32'h00302013, 32'h138, 32'd5, 32'd0);
    #10;
    check("SLTI: 5 < 3 = 0", 32'd0);

    //==============================================================
    // 15. Hold behavior
    //==============================================================
    $display("--- HOLD ---");
    // Clear pipeline first
    valid_i = 0;
    hold_i = 0;
    #10;
    // Now apply with hold=1
    hold_i = 1;
    apply(32'h00500293, 32'h140, 32'd10, 32'd0);
    #10;
    hold_i = 0;
    if (valid_o) begin
        $display("  FAIL: Pipeline should hold (vld=%b, res=0x%h)", valid_o, alu_result_o);
        fail_cnt = fail_cnt + 1;
    end else begin
        $display("  PASS: Pipeline holding correctly");
        pass_cnt = pass_cnt + 1;
    end

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

task apply(input [31:0] opcode, pc, ra, rb);
begin
    @(negedge clk);
    valid_i = 1;
    opcode_i = opcode;
    pc_i = pc;
    ra_operand_i = ra;
    rb_operand_i = rb;
end
endtask

task check(input [255:0] desc, input [31:0] expected);
begin
    @(posedge clk);
    #1; // Allow combinational settling
    if (alu_result_o === expected) begin
        $display("  PASS: %s (result=0x%h)", desc, alu_result_o);
        pass_cnt = pass_cnt + 1;
    end
    else begin
        fail_cnt = fail_cnt + 1;
        $display("  FAIL: %s (got 0x%h, expected 0x%h)", desc, alu_result_o, expected);
    end
    valid_i = 0;
end
endtask

endmodule