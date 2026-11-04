// ============================================================================
//        Dual Retirement / Precise-Exception Commit Rules (M1-8)
//
//        Slot0 is the older instruction; slot1 is the younger one.
//        This module only defines the architectural commit decision:
//
//        1. slot0 valid normal + slot1 valid normal:
//             commit both in the same cycle.
//        2. slot0 valid normal + slot1 valid trap:
//             commit only slot0 this cycle; hold_s1=1 tells the upstream to
//             present the younger trap as the next oldest instruction.
//        3. slot0 valid trap:
//             commit only slot0's trap; flush_young=1 discards slot1 and all
//             younger instructions.  slot0 never writes rd in this case.
//        4. slot0 invalid:
//             no commit; the upstream must compact slot1 into slot0.
//
//        Result data/rd are forwarded unchanged; write enables are suppressed
//        for traps and x0.
// ============================================================================
`include "defines.sv"

module dual_commit (
    input  wire        s0_valid,
    input  wire        s0_trap,
    input  wire        s0_writes_rd,
    input  wire [4:0]  s0_rd,
    input  wire [31:0] s0_data,
    input  wire [31:0] s0_cause,
    input  wire [31:0] s0_pc,

    input  wire        s1_valid,
    input  wire        s1_trap,
    input  wire        s1_writes_rd,
    input  wire [4:0]  s1_rd,
    input  wire [31:0] s1_data,
    input  wire [31:0] s1_cause,
    input  wire [31:0] s1_pc,

    output wire        commit0_fire,
    output wire        commit1_fire,
    output wire        trap_fire,
    output wire [31:0] trap_cause,
    output wire [31:0] trap_pc,
    output wire        flush_young,
    output wire        hold_s1,

    output wire        w0_we,
    output wire [4:0]  w0_rd,
    output wire [31:0] w0_data,
    output wire        w1_we,
    output wire [4:0]  w1_rd,
    output wire [31:0] w1_data
);

    assign commit0_fire = s0_valid;
    assign commit1_fire = s0_valid && !s0_trap && s1_valid && !s1_trap;

    assign flush_young = s0_valid && s0_trap;
    assign hold_s1     = s0_valid && !s0_trap && s1_valid && s1_trap;

    assign trap_fire  = s0_valid && s0_trap;
    assign trap_cause = s0_cause;
    assign trap_pc    = s0_pc;

    assign w0_we   = commit0_fire && s0_writes_rd && (s0_rd != 5'd0) && !s0_trap;
    assign w0_rd   = s0_rd;
    assign w0_data = s0_data;

    assign w1_we   = commit1_fire && s1_writes_rd && (s1_rd != 5'd0) && !s1_trap;
    assign w1_rd   = s1_rd;
    assign w1_data = s1_data;

endmodule
