// ============================================================================
//        Issue Arbiter (M1-5, first conservative version)
//
//        Conservative dual-issue policy:
//        - The caller marks lane0 pairable: ordinary ALU or an eligible SRAM load.
//        - Lane1 must be an ordinary integer ALU.
//        - lane0 must be accepted before lane1 can issue.
//        - No intra-group forwarding is implemented, so RAW/WAW between the pair
//          blocks lane1 (including a load-use dependency).
//        - x0 never creates a dependency.
//        - Stores, MMIO/unmapped loads, MDU, CSR, FENCE/privileged and illegal
//          instructions stay single-issue on lane0.
//
//        This deliberately follows PR #64 review T3 and the C1 scope in the
//        reference-baseline handover.  Wider pairing is a later, measured step.
// ============================================================================
`include "defines.sv"

module issue_arb (
    input  wire        s0_valid,
    input  wire        s0_illegal,
    input  wire        s0_is_alu,
    input  wire [4:0]  s0_rd,
    input  wire        s0_reg_write,

    input  wire        s1_valid,
    input  wire        s1_illegal,
    input  wire        s1_is_alu,
    input  wire [4:0]  s1_rs1,
    input  wire [4:0]  s1_rs2,
    input  wire        s1_uses_rs1,
    input  wire        s1_uses_rs2,
    input  wire [4:0]  s1_rd,
    input  wire        s1_reg_write,

    input  wire        backend_stall,

    output wire        issue0,
    output wire        issue1,
    output wire        slot1_stall
);

    // Register dependencies inside the pair.  No intra-group bypass exists in
    // this first version, so any dependency blocks lane1.
    wire raw_rs1 = s1_uses_rs1 && s0_reg_write && (s0_rd != 5'd0) &&
                   (s0_rd == s1_rs1);
    wire raw_rs2 = s1_uses_rs2 && s0_reg_write && (s0_rd != 5'd0) &&
                   (s0_rd == s1_rs2);
    wire waw = s0_reg_write && s1_reg_write && (s0_rd != 5'd0) &&
               (s0_rd == s1_rd);

    wire pair_allowed = s0_is_alu && s1_is_alu &&
                        !s0_illegal && !s1_illegal &&
                        !raw_rs1 && !raw_rs2 && !waw;

    assign issue0 = s0_valid && !backend_stall;
    assign issue1 = issue0 && s1_valid && pair_allowed;
    assign slot1_stall = s1_valid && issue0 && !issue1;


endmodule

// Small ordinary-ALU pairing classifier. The architectural ID stage remains
// authoritative for execution; this parallel predicate is used only by issue
// eligibility for either slot. Keep it aligned with id_stage legality and
// dual_issue_full_core's `is_alu` policy. Exhaustive opcode/funct verification
// lives in tb_issue_arb.
module dual_issue_alu_predecode (
    input  wire [31:0] inst_i,
    input  wire        fault_i,
    output wire        eligible_o,
    output wire [4:0]  rs1_o,
    output wire [4:0]  rs2_o,
    output wire        uses_rs1_o,
    output wire        uses_rs2_o,
    output wire [4:0]  rd_o,
    output wire        reg_write_o
);
    wire [6:0] opcode = inst_i[6:0];
    wire [2:0] funct3 = inst_i[14:12];
    wire [6:0] funct7 = inst_i[31:25];

    wire shift_imm_legal = (funct3 != 3'b001 || funct7 == 7'b0000000) &&
                           (funct3 != 3'b101 || funct7 == 7'b0000000 ||
                                               funct7 == 7'b0100000);
    wire reg_alu_legal = (funct7 == 7'b0000000) ||
                         ((funct7 == 7'b0100000) &&
                          ((funct3 == 3'b000) || (funct3 == 3'b101)));
    wire alu_encoding_legal =
        ((opcode == 7'b0010011) && shift_imm_legal) ||
        ((opcode == 7'b0110011) && reg_alu_legal) ||
        (opcode == 7'b0110111) ||
        (opcode == 7'b0010111);
    assign eligible_o = !fault_i && alu_encoding_legal;

    wire uses_rs1_encoding = (opcode == 7'b0010011) ||
                             (opcode == 7'b0110011);
    wire uses_rs2_encoding = (opcode == 7'b0110011);
    assign rs1_o = uses_rs1_encoding ? inst_i[19:15] : 5'd0;
    assign rs2_o = uses_rs2_encoding ? inst_i[24:20] : 5'd0;
    assign rd_o = inst_i[11:7];
    assign uses_rs1_o = uses_rs1_encoding;
    assign uses_rs2_o = uses_rs2_encoding;
    assign reg_write_o = eligible_o;
endmodule
