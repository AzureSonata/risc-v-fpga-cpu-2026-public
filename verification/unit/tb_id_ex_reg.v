`timescale 1ns/1ps
module tb_id_ex_reg;
    reg clk=0, rst=0, flush=0, hold=0, in_valid=0;
    reg [31:0] in_pc=0,in_instr=0,in_rs1_value=0,in_rs2_value=0,in_imm=0;
    reg [4:0] in_rs1=0,in_rs2=0,in_rd=0; reg [3:0] in_alu_op=0;
    reg in_alu_src_imm=0,in_branch=0,in_jal=0,in_jalr=0,in_mem_read=0,in_mem_write=0;
    reg [1:0] in_mem_size=0; reg in_mem_unsigned=0,in_reg_write=0;
    reg in_fetch_fault=0,in_illegal=0,in_pred_valid=0,in_pred_taken=0;
    reg in_uses_rs1=0,in_uses_rs2=0;
    reg [31:0] in_pred_target=0;
    wire out_valid; wire [31:0] out_pc,out_instr,out_rs1_value,out_rs2_value,out_imm;
    wire [4:0] out_rs1,out_rs2,out_rd; wire [3:0] out_alu_op;
    wire out_alu_src_imm,out_branch,out_jal,out_jalr,out_mem_read,out_mem_write;
    wire [1:0] out_mem_size; wire out_mem_unsigned,out_reg_write;
    wire out_fetch_fault,out_illegal,out_pred_valid,out_pred_taken;
    wire out_uses_rs1,out_uses_rs2;
    wire [31:0] out_pred_target;
    integer checks=0, i;
    id_ex_reg dut(.*); always #5 clk=~clk;
    task step; begin @(posedge clk); #1; end endtask
    task check_ok; input condition; input [8*40-1:0] label; begin checks=checks+1; if(!condition) begin $display("FAIL %0s",label); $fatal(1); end end endtask
    task check_a; input [8*40-1:0] label; begin check_ok(out_valid&&out_pc==32'h100&&out_instr==32'h11223344&&out_rs1_value==32'h11&&out_rs2_value==32'h22&&out_imm==32'hfffffff0&&out_rs1==1&&out_rs2==2&&out_rd==3&&out_alu_op==4'ha&&out_alu_src_imm&&!out_branch&&!out_jal&&!out_jalr&&!out_mem_read&&!out_mem_write&&out_mem_size==2'b10&&out_mem_unsigned&&!out_reg_write&&out_fetch_fault&&out_illegal&&out_pred_valid&&out_pred_taken&&out_pred_target==32'h3456&&out_uses_rs1&&out_uses_rs2,label); end endtask
    task load_a; begin
        in_valid=1; in_pc=32'h100; in_instr=32'h11223344; in_rs1_value=32'h11;
        in_rs2_value=32'h22; in_imm=32'hfffffff0; in_rs1=1; in_rs2=2; in_rd=3;
        in_alu_op=4'ha; in_alu_src_imm=1; in_branch=1; in_jal=1; in_jalr=1;
        in_mem_read=1; in_mem_write=1; in_mem_size=2'b10; in_mem_unsigned=1; in_reg_write=1;
        in_fetch_fault=1; in_illegal=1; in_pred_valid=1; in_pred_taken=1; in_pred_target=32'h3456;
        in_uses_rs1=1; in_uses_rs2=1;
    end endtask
    initial begin
        #2000 $display("FAIL timeout"); $fatal(1);
    end
    initial begin
        rst=1; load_a(); step();
        check_ok(!out_valid && !out_reg_write && !out_mem_write && !out_fetch_fault && !out_illegal && !out_pred_valid && !out_pred_taken && out_pred_target==0 && out_pc==0 && !out_uses_rs1 && !out_uses_rs2,"reset clears metadata");
        rst=0; step(); check_a("complete payload capture");
        hold=1; in_pc=32'h200; in_rd=9; in_fetch_fault=0; in_illegal=0;
        in_pred_valid=0; in_pred_taken=0; in_pred_target=0; repeat(3) step();
        check_a("three-cycle hold preserves metadata");
        hold=0; in_valid=0; step();
        check_ok(!out_valid && !out_reg_write && !out_mem_read && !out_mem_write && !out_fetch_fault && !out_illegal && !out_pred_valid && !out_pred_taken && out_pred_target==0 && out_pc==0 && !out_uses_rs1 && !out_uses_rs2,"bubble clears metadata");
        load_a(); step(); flush=1; step();
        check_ok(!out_valid && !out_reg_write && !out_mem_write && !out_fetch_fault && !out_illegal && !out_pred_valid && out_pred_target==0 && !out_uses_rs1 && !out_uses_rs2,"flush clears metadata");
        load_a(); hold=1; step();
        check_ok(!out_valid,"flush wins hold");
        flush=0; hold=0; in_pc=32'h300; in_rd=7; step();
        check_ok(out_valid && out_pc==32'h300 && out_rd==7,"recover after flush");
        for(i=0;i<4;i=i+1) begin in_valid=0; step(); check_ok(!out_valid&&!out_reg_write&&!out_mem_write&&out_pc==0&&!out_uses_rs1&&!out_uses_rs2,"continuous bubble clears payload"); end
        load_a(); step(); check_a("reload before alternating controls");
        for(i=0;i<4;i=i+1) begin hold=1; flush=0; in_pc=32'h900+i; step(); check_a("alternating hold preserves complete payload"); hold=1; flush=1; step(); check_ok(!out_valid&&!out_reg_write&&out_pc==0&&!out_uses_rs1&&!out_uses_rs2,"alternating flush wins hold"); flush=0; hold=0; load_a(); step(); end
        $display("PASS tb_id_ex_reg: %0d checks",checks);
        $display("ALL ID_EX_REG TESTS PASSED"); $finish;
    end
endmodule
