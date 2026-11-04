//-----------------------------------------------------------------
// B1: EX/ALU - RISC-V Core Definitions
// Version: Stage1 Draft
// Based on ultraembedded/riscv (BSD license)
//-----------------------------------------------------------------

// ALU Operations
`define ALU_NONE              4'b0000
`define ALU_SHIFTL            4'b0001
`define ALU_SHIFTR            4'b0010
`define ALU_SHIFTR_ARITH      4'b0011
`define ALU_ADD               4'b0100
`define ALU_SUB               4'b0110
`define ALU_AND               4'b0111
`define ALU_OR                4'b1000
`define ALU_XOR               4'b1001
`define ALU_LESS_THAN         4'b1010
`define ALU_LESS_THAN_SIGNED  4'b1011

// Exception width
`define EXCEPTION_W           6