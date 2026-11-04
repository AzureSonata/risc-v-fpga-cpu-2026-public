`timescale 1ns/1ps
`include "defines.sv"

// Unit test for the narrow pre-decoded fetch-queue output fields
// (out0_rs1/rs2/rd/reg_write/is_alu/is_mem and the out1 counterparts).
// The fields are decoded on the push side and travel inside the entry, so the
// test only has to push known instructions and read the fields back.
module tb_fetch_queue_predecode;
    reg clk = 1'b0;
    reg rst = `RstEnable;
    always #5 clk = ~clk;

    reg         in0_valid, in1_valid;
    reg  [31:0] in0_pc, in0_inst, in0_pred_target;
    reg  [31:0] in1_pc, in1_inst, in1_pred_target;
    reg         in0_fault, in0_pred_valid, in0_pred_taken;
    reg         in1_fault, in1_pred_valid, in1_pred_taken;

    wire [1:0]  in_ready;
    wire        decode0_valid, decode1_valid;
    wire        out0_valid, out1_valid;
    wire [31:0] out0_pc, out0_inst, out0_pred_target;
    wire [31:0] out1_pc, out1_inst, out1_pred_target;
    wire        out0_fault, out0_pred_valid, out0_pred_taken;
    wire        out1_fault, out1_pred_valid, out1_pred_taken;
    wire [4:0]  out0_rs1, out0_rs2, out0_rd;
    wire [4:0]  out1_rs1, out1_rs2, out1_rd;
    wire        out0_reg_write, out0_is_alu, out0_is_mem;
    wire        out1_reg_write, out1_is_alu, out1_is_mem;
    reg         out0_consume, out1_consume, flush;

    fetch_queue #(.DEPTH(4)) dut (
        .clk(clk), .rst(rst),
        .in0_valid(in0_valid), .in0_pc(in0_pc), .in0_inst(in0_inst),
        .in0_fault(in0_fault), .in0_pred_valid(in0_pred_valid),
        .in0_pred_taken(in0_pred_taken), .in0_pred_target(in0_pred_target),
        .in1_valid(in1_valid), .in1_pc(in1_pc), .in1_inst(in1_inst),
        .in1_fault(in1_fault), .in1_pred_valid(in1_pred_valid),
        .in1_pred_taken(in1_pred_taken), .in1_pred_target(in1_pred_target),
        .in_ready(in_ready),
        .decode0_valid(decode0_valid), .decode1_valid(decode1_valid),
        .out0_valid(out0_valid), .out0_pc(out0_pc), .out0_inst(out0_inst),
        .out0_fault(out0_fault), .out0_pred_valid(out0_pred_valid),
        .out0_pred_taken(out0_pred_taken), .out0_pred_target(out0_pred_target),
        .out0_rs1(out0_rs1), .out0_rs2(out0_rs2), .out0_rd(out0_rd),
        .out0_reg_write(out0_reg_write), .out0_is_alu(out0_is_alu),
        .out0_is_mem(out0_is_mem),
        .out1_valid(out1_valid), .out1_pc(out1_pc), .out1_inst(out1_inst),
        .out1_fault(out1_fault), .out1_pred_valid(out1_pred_valid),
        .out1_pred_taken(out1_pred_taken), .out1_pred_target(out1_pred_target),
        .out1_rs1(out1_rs1), .out1_rs2(out1_rs2), .out1_rd(out1_rd),
        .out1_reg_write(out1_reg_write), .out1_is_alu(out1_is_alu),
        .out1_is_mem(out1_is_mem),
        .out0_consume(out0_consume), .out1_consume(out1_consume),
        .flush(flush)
    );

    // addi a0, a1, 1  (OP-IMM, rd=10, rs1=11, rs2 unused)
    localparam [31:0] INST_ADDI = 32'h0015_8513;
    // sw a1, 0(a0)    (STORE, rd field=0, rs1=10, rs2=11)
    localparam [31:0] INST_SW   = 32'h00b5_2023;
    // lui x5, 0x12345 (LUI, rd=5, reg_write, not alu/mem)
    localparam [31:0] INST_LUI  = 32'h1234_52b7;

    integer pass_count = 0;
    integer fail_count = 0;

    task automatic check5(input [8*40-1:0] name, input [4:0] got, input [4:0] exp);
        begin
            if (got === exp) begin
                pass_count = pass_count + 1;
            end else begin
                fail_count = fail_count + 1;
                $display("FAIL: %0s got=%0d exp=%0d", name, got, exp);
            end
        end
    endtask

    task automatic check1(input [8*40-1:0] name, input got, input exp);
        begin
            if (got === exp) begin
                pass_count = pass_count + 1;
            end else begin
                fail_count = fail_count + 1;
                $display("FAIL: %0s got=%0b exp=%0b", name, got, exp);
            end
        end
    endtask

    initial begin
        in0_valid = 1'b0; in1_valid = 1'b0;
        in0_pc = 32'h0; in1_pc = 32'h0;
        in0_inst = 32'h0; in1_inst = 32'h0;
        in0_fault = 1'b0; in1_fault = 1'b0;
        in0_pred_valid = 1'b0; in1_pred_valid = 1'b0;
        in0_pred_taken = 1'b0; in1_pred_taken = 1'b0;
        in0_pred_target = 32'h0; in1_pred_target = 32'h0;
        out0_consume = 1'b0; out1_consume = 1'b0; flush = 1'b0;

        repeat (3) @(posedge clk);
        rst <= `RstDisable;
        repeat (2) @(posedge clk);

        // Push one pair: addi in slot 0, sw in slot 1.
        in0_valid <= 1'b1; in1_valid <= 1'b1;
        in0_pc <= 32'h8000_0000; in1_pc <= 32'h8000_0004;
        in0_inst <= INST_ADDI;   in1_inst <= INST_SW;
        @(posedge clk);
        in0_valid <= 1'b0; in1_valid <= 1'b0;
        @(posedge clk);
        #1;

        check1("slot0 valid", out0_valid, 1'b1);
        check1("slot1 valid", out1_valid, 1'b1);
        check5("slot0 rs1 (addi a0,a1,1)", out0_rs1, 5'd11);
        // ADDI carries imm[4:0] in the rs2 slot: the field is a raw ISA slice,
        // meaningful only where the format defines it (documented in the
        // interface note). addi a0,a1,1 -> imm[4:0]=1.
        check5("slot0 rs2 (addi -> imm[4:0]", out0_rs2, 5'd1);
        check5("slot0 rd  (a0)",            out0_rd, 5'd10);
        check1("slot0 reg_write",           out0_reg_write, 1'b1);
        check1("slot0 is_alu",              out0_is_alu, 1'b1);
        check1("slot0 is_mem",              out0_is_mem, 1'b0);

        check5("slot1 rs1 (sw a1,0(a0))", out1_rs1, 5'd10);
        check5("slot1 rs2 (sw a1)",       out1_rs2, 5'd11);
        check5("slot1 rd  (sw -> 0)",     out1_rd, 5'd0);
        check1("slot1 reg_write (store)", out1_reg_write, 1'b0);
        check1("slot1 is_alu (store)",    out1_is_alu, 1'b0);
        check1("slot1 is_mem (store)",    out1_is_mem, 1'b1);

        // Consume slot 0: the sw entry must slide into slot 0 with its fields.
        out0_consume <= 1'b1;
        @(posedge clk);
        out0_consume <= 1'b0;
        @(posedge clk);
        #1;
        check1("after pop slot0 valid", out0_valid, 1'b1);
        check1("after pop slot1 valid", out1_valid, 1'b0);
        check5("after pop rs1", out0_rs1, 5'd10);
        check5("after pop rs2", out0_rs2, 5'd11);
        check1("after pop is_mem", out0_is_mem, 1'b1);
        check1("after pop reg_write", out0_reg_write, 1'b0);

        // Push LUI into the freed slot and read it back at slot 1.
        in0_valid <= 1'b1; in0_inst <= INST_LUI; in0_pc <= 32'h8000_0008;
        @(posedge clk);
        in0_valid <= 1'b0;
        @(posedge clk);
        #1;
        // LUI: [19:15] is imm[19:15] of 0x12345 -> 8, so rs1 is a raw slice.
        check5("lui rs1 (imm[19:15]=8)", out1_rs1, 5'd8);
        check5("lui rd  (x5)", out1_rd, 5'd5);
        check1("lui reg_write", out1_reg_write, 1'b1);
        check1("lui is_alu", out1_is_alu, 1'b0);
        check1("lui is_mem", out1_is_mem, 1'b0);

        // Flush must clear the decoded fields together with the entry.
        flush <= 1'b1;
        @(posedge clk);
        flush <= 1'b0;
        @(posedge clk);
        #1;
        check1("flushed slot0 valid", out0_valid, 1'b0);

        $display("FETCH_QUEUE_PREDECODE: %0d PASS / %0d FAIL", pass_count, fail_count);
        if (fail_count != 0) $display("FETCH_QUEUE_PREDECODE_RESULT: FAIL");
        else                 $display("FETCH_QUEUE_PREDECODE_RESULT: PASS");
        $finish;
    end
endmodule
