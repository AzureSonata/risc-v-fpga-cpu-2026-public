`timescale 1ns/1ps

// Draft K1 load-use hazard detector.
//
// ID reports which source fields are semantically consumed.  A dependency on
// the value being produced by a valid load in EX stalls the front end for one
// cycle.  Register x0 never carries a dependency.
module hazard_detection (
    input  wire [4:0] id_rs1,
    input  wire [4:0] id_rs2,
    input  wire       id_uses_rs1,
    input  wire       id_uses_rs2,

    input  wire       ex_valid,
    input  wire       ex_is_load,
    input  wire       ex_writes_rd,
    input  wire [4:0] ex_rd,

    output wire       load_use_stall
);
    wire ex_load_writes_value;
    wire rs1_dependency;
    wire rs2_dependency;

    assign ex_load_writes_value = ex_valid && ex_is_load &&
                                  ex_writes_rd && (ex_rd != 5'd0);
    assign rs1_dependency = id_uses_rs1 && (id_rs1 == ex_rd);
    assign rs2_dependency = id_uses_rs2 && (id_rs2 == ex_rd);

    assign load_use_stall = ex_load_writes_value &&
                            (rs1_dependency || rs2_dependency);
endmodule
