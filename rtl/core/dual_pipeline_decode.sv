// ID-stage control for either lane of the elastic dual-issue pipeline.
// All instruction inspection belongs before ID/EX; the execute helper receives
// only these decoded controls and the forwarded source operands.
module dual_pipeline_decode #(
    parameter integer M_MODE = 2
) (
    input  wire [31:0] inst_i,
    input  wire [31:0] pc_i,
    input  wire        fault_i,
    output wire [4:0]  rs1_o,
    output wire [4:0]  rs2_o,
    output wire [4:0]  rd_o,
    output wire        uses_rs1_o,
    output wire        uses_rs2_o,
    output wire        reg_we_o,
    output wire [31:0] imm_o,
    output reg  [3:0]  alu_func_o,
    output reg         src_a_pc_o,
    output reg         src_a_zero_o,
    output reg         src_b_imm_o,
    output wire        branch_o,
    output wire        jal_o,
    output wire        jalr_o,
    output wire        mem_o,
    output wire        store_o,
    output wire [2:0]  funct3_o,
    output wire        mdu_o,
    output wire        csr_o,
    output wire [11:0] csr_addr_o,
    output wire        csr_we_o,
    output wire [1:0]  csr_op_o,
    output wire        csr_imm_o,
    output wire [31:0] csr_uimm_o,
    output wire        ecall_o,
    output wire        ebreak_o,
    output wire        mret_o,
    output wire        fence_o,
    output wire        illegal_o
);
    `include "riscv_defs.svh"

    wire id_illegal;
    wire id_lui, id_auipc;
    wire [6:0] opcode = inst_i[6:0];
    wire [6:0] funct7 = inst_i[31:25];
    assign funct3_o = inst_i[14:12];

    // Ordinary FENCE is a serializing barrier in the integration core.  A
    // stronger full barrier is safe for every pred/succ and fm encoding.  The
    // reserved rs1/rd fields do not name GPR operands.  FENCE.I remains illegal:
    // this candidate has no instruction-cache invalidation contract.
    assign fence_o = !fault_i && (opcode == 7'h0f) &&
                     (funct3_o == 3'b000);
    assign illegal_o = !fault_i && !fence_o && id_illegal;

    id_stage #(.SUPPORT_M(M_MODE == 2), .SUPPORT_ZMMUL(M_MODE == 1)) u_id (
        .rst(1'b0), .inst_i(inst_i), .pc_i(pc_i),
        .inst_valid_i(1'b1), .fault_i(fault_i),
        .pred_valid_i(1'b0), .pred_taken_i(1'b0), .pred_target_i(32'b0),
        .ex_jump_flag_i(1'b0),
        .rs1_addr_o(rs1_o), .rs2_addr_o(rs2_o),
        .imm_o(imm_o), .reg_we_o(reg_we_o), .rd_addr_o(rd_o),
        .mem_req_o(mem_o), .mem_we_o(store_o), .mem_wstrb_o(),
        .branch_o(branch_o), .jal_o(jal_o), .jalr_o(jalr_o),
        .lui_o(id_lui), .auipc_o(id_auipc),
        .uses_rs1_o(uses_rs1_o), .uses_rs2_o(uses_rs2_o),
        .opcode_o(), .funct3_o(), .funct7_o(), .rd_o(),
        .pred_valid_o(), .pred_taken_o(), .pred_target_o(),
        .illegal_instr_o(id_illegal),
        .csr_addr_o(csr_addr_o), .csr_we_o(csr_we_o),
        .csr_op_o(csr_op_o), .csr_imm_o(csr_imm_o),
        .csr_uimm_o(csr_uimm_o),
        .sys_ecall_o(ecall_o), .sys_ebreak_o(ebreak_o), .sys_mret_o(mret_o)
    );

    assign mdu_o = !fault_i && !illegal_o &&
                   (opcode == 7'h33) && (funct7 == 7'h01);
    assign csr_o = !fault_i && !illegal_o && (opcode == 7'h73) &&
                   (funct3_o != 3'b000) && (funct3_o != 3'b100);

    always @* begin
        alu_func_o  = `ALU_NONE;
        src_a_pc_o  = 1'b0;
        src_a_zero_o = 1'b1;
        src_b_imm_o = 1'b0;
        if (!fault_i && !illegal_o) begin
            if (((opcode == 7'h33) && !mdu_o) || (opcode == 7'h13)) begin
                src_a_zero_o = 1'b0;
                src_b_imm_o = (opcode == 7'h13);
                case (funct3_o)
                    3'b000: alu_func_o = ((opcode == 7'h33) && inst_i[30])
                                           ? `ALU_SUB : `ALU_ADD;
                    3'b001: alu_func_o = `ALU_SHIFTL;
                    3'b010: alu_func_o = `ALU_LESS_THAN_SIGNED;
                    3'b011: alu_func_o = `ALU_LESS_THAN;
                    3'b100: alu_func_o = `ALU_XOR;
                    3'b101: alu_func_o = inst_i[30]
                                           ? `ALU_SHIFTR_ARITH : `ALU_SHIFTR;
                    3'b110: alu_func_o = `ALU_OR;
                    3'b111: alu_func_o = `ALU_AND;
                    default: alu_func_o = `ALU_NONE;
                endcase
            end else if (id_lui || id_auipc) begin
                alu_func_o = `ALU_ADD;
                src_a_pc_o = id_auipc;
                src_a_zero_o = id_lui;
                src_b_imm_o = 1'b1;
            end else if (mem_o) begin
                alu_func_o = `ALU_ADD;
                src_a_zero_o = 1'b0;
                src_b_imm_o = 1'b1;
            end
        end
    end
endmodule
