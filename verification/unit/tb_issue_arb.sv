`timescale 1ns/1ps
`include "defines.sv"

module tb_issue_arb;
    reg s0_valid, s0_illegal, s0_is_alu, s0_reg_write;
    reg [4:0] s0_rd;
    reg s1_valid, s1_illegal, s1_is_alu, s1_uses_rs1, s1_uses_rs2, s1_reg_write;
    reg [4:0] s1_rs1, s1_rs2, s1_rd;
    reg backend_stall;
    wire issue0, issue1, slot1_stall;

    issue_arb dut (.*);

    reg [31:0] pre_inst;
    reg pre_fault;
    wire pre_eligible, pre_uses_rs1, pre_uses_rs2, pre_reg_write;
    wire [4:0] pre_rs1, pre_rs2, pre_rd;
    dual_issue_alu_predecode predecode (
        .inst_i(pre_inst), .fault_i(pre_fault), .eligible_o(pre_eligible),
        .rs1_o(pre_rs1), .rs2_o(pre_rs2), .uses_rs1_o(pre_uses_rs1),
        .uses_rs2_o(pre_uses_rs2), .rd_o(pre_rd), .reg_write_o(pre_reg_write)
    );

    wire [4:0] ref_rs1, ref_rs2, ref_rd;
    wire [6:0] ref_opcode, ref_funct7;
    wire ref_reg_write, ref_mem_req, ref_branch, ref_jal, ref_jalr;
    wire ref_lui, ref_auipc, ref_uses_rs1, ref_uses_rs2, ref_illegal;
    wire ref_ecall, ref_ebreak, ref_mret;
    id_stage #(.SUPPORT_M(1'b1)) reference_decode (
        .rst(1'b0), .inst_i(pre_inst), .pc_i(32'b0),
        .inst_valid_i(1'b1), .fault_i(pre_fault),
        .pred_valid_i(1'b0), .pred_taken_i(1'b0), .pred_target_i(32'b0),
        .ex_jump_flag_i(1'b0), .rs1_addr_o(ref_rs1), .rs2_addr_o(ref_rs2),
        .imm_o(), .reg_we_o(ref_reg_write), .rd_addr_o(ref_rd),
        .mem_req_o(ref_mem_req), .mem_we_o(), .mem_wstrb_o(),
        .branch_o(ref_branch), .jal_o(ref_jal), .jalr_o(ref_jalr),
        .lui_o(ref_lui), .auipc_o(ref_auipc),
        .uses_rs1_o(ref_uses_rs1), .uses_rs2_o(ref_uses_rs2),
        .opcode_o(ref_opcode), .funct3_o(), .funct7_o(ref_funct7), .rd_o(),
        .pred_valid_o(), .pred_taken_o(), .pred_target_o(),
        .illegal_instr_o(ref_illegal),
        .csr_addr_o(), .csr_we_o(), .csr_op_o(), .csr_imm_o(), .csr_uimm_o(),
        .sys_ecall_o(ref_ecall), .sys_ebreak_o(ref_ebreak), .sys_mret_o(ref_mret)
    );

    integer pass_count = 0;
    integer fail_count = 0;
    integer predecode_checks = 0;
    integer op_i, f3_i, f7_i, fault_i;
    reg expected_alu;
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

    task reset_inputs;
        begin
            s0_valid=0; s0_illegal=0; s0_is_alu=0; s0_reg_write=0; s0_rd=0;
            s1_valid=0; s1_illegal=0; s1_is_alu=0; s1_uses_rs1=0; s1_uses_rs2=0;
            s1_reg_write=0; s1_rs1=0; s1_rs2=0; s1_rd=0; backend_stall=0;
            #1;
        end
    endtask

    initial begin
        reset_inputs();
        pre_inst = 32'b0;
        pre_fault = 1'b0;
        check(issue0==0 && issue1==0 && slot1_stall==0, "idle");

        s0_valid=1; s0_is_alu=1; s0_reg_write=1; s0_rd=1;
        #1;
        check(issue0==1 && issue1==0, "single ALU on lane0");

        s1_valid=1; s1_is_alu=1; s1_uses_rs1=1; s1_rs1=2; #1;
        check(issue0==1 && issue1==1 && slot1_stall==0, "independent ALU+ALU");

        s1_rs1=1; #1;
        check(issue0==1 && issue1==0 && slot1_stall==1, "intra-group RAW blocks lane1");

        s1_rs1=2; s1_uses_rs1=0; s1_reg_write=1; s1_rd=1; #1;
        check(issue0==1 && issue1==0 && slot1_stall==1, "intra-group WAW blocks lane1");

        s1_reg_write=0; s1_rd=0; s0_rd=0; s1_uses_rs1=1; s1_rs1=0; #1;
        check(issue0==1 && issue1==1, "x0 writes do not create a dependency");

        s0_is_alu=0; s1_uses_rs1=0; #1;
        check(issue0==1 && issue1==0, "lane0 non-ALU blocks lane1");

        s0_is_alu=1; s1_is_alu=0; #1;
        check(issue0==1 && issue1==0, "lane1 non-ALU is rejected");

        s1_is_alu=1; s0_illegal=1; #1;
        check(issue0==1 && issue1==0, "illegal lane0 blocks lane1");

        s0_illegal=0; s1_illegal=1; #1;
        check(issue0==1 && issue1==0, "illegal lane1 is rejected");

        s1_illegal=0; s0_valid=0; #1;
        check(issue0==0 && issue1==0, "no valid lane0 means no issue");

        s0_valid=1; backend_stall=1; #1;
        check(issue0==0 && issue1==0, "backend stall blocks the whole pair");

        // Compare the lane1 shortcut with the existing decoder across every
        // opcode/funct3/funct7 combination and both fetch-fault states.
        for (op_i = 0; op_i < 128; op_i = op_i + 1) begin
            for (f3_i = 0; f3_i < 8; f3_i = f3_i + 1) begin
                for (f7_i = 0; f7_i < 128; f7_i = f7_i + 1) begin
                    pre_inst = {f7_i[6:0], 5'd7, 5'd3, f3_i[2:0], 5'd5, op_i[6:0]};
                    for (fault_i = 0; fault_i < 2; fault_i = fault_i + 1) begin
                        pre_fault = fault_i[0];
                        #1;
                        expected_alu = !pre_fault && !ref_illegal &&
                            !ref_branch && !ref_jal && !ref_jalr && !ref_mem_req &&
                            !ref_ecall && !ref_ebreak && !ref_mret &&
                            ((ref_opcode == 7'h13) ||
                             ((ref_opcode == 7'h33) && (ref_funct7 != 7'h01)) ||
                             ref_lui || ref_auipc);
                        predecode_checks = predecode_checks + 1;
                        if (pre_eligible !== expected_alu) begin
                            fail_count = fail_count + 1;
                            if (fail_count <= 8)
                                $display("FAIL predecode eligibility op=%02x f3=%x f7=%02x fault=%b got=%b expected=%b",
                                         op_i, f3_i, f7_i, pre_fault, pre_eligible, expected_alu);
                        end else if (pre_eligible &&
                            ({pre_rs1, pre_rs2, pre_uses_rs1, pre_uses_rs2,
                              pre_rd, pre_reg_write} !==
                             {ref_rs1, ref_rs2, ref_uses_rs1, ref_uses_rs2,
                              ref_rd, ref_reg_write})) begin
                            fail_count = fail_count + 1;
                            if (fail_count <= 8)
                                $display("FAIL predecode metadata op=%02x f3=%x f7=%02x",
                                         op_i, f3_i, f7_i);
                        end
                    end
                end
            end
        end

        if (fail_count == 0) begin
            $display("ALL TESTS PASSED (issue_arb: %0d checks; predecode exhaustive=%0d)",
                     pass_count, predecode_checks);
        end else begin
            $display("ISSUE_ARB_RESULT: FAIL (%0d pass / %0d fail; predecode exhaustive=%0d)",
                     pass_count, fail_count, predecode_checks);
        end
        $finish;
    end

    initial begin
        #300000;
        $display("ISSUE_ARB_RESULT: TIMEOUT");
        $finish;
    end
endmodule
