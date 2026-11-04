// ============================================================================
//        Issue Arbiter (M1-5, first conservative version)
//
//        First dual-issue policy:
//        - Only ordinary integer ALU + ordinary integer ALU may issue together.
//        - lane0 must be accepted before lane1 can issue.
//        - No intra-group forwarding is implemented, so RAW/WAW between the pair
//          blocks lane1.
//        - x0 never creates a dependency.
//        - Branches, loads/stores, MDU, CSR, FENCE/privileged and illegal
//          instructions stay single-issue on lane0 in this version.
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
    assign issue1 = s1_valid && pair_allowed;
    assign slot1_stall = s1_valid && issue0 && !issue1;


endmodule
