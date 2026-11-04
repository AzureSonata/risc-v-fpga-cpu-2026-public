//-----------------------------------------------------------------
// B1: EX/ALU - ALU Core
// RV32I ALU: 10 operations + barrel shifter
// Based on ultraembedded/riscv (BSD license)
//-----------------------------------------------------------------

module riscv_alu (
    input  logic [ 3:0]  alu_op_i,   // ALU operation select
    input  logic [31:0]  alu_a_i,    // Source operand A
    input  logic [31:0]  alu_b_i,    // Source operand B
    output logic [31:0]  alu_p_o     // ALU result
);

`include "riscv_defs.svh"

//-----------------------------------------------------------------
// Barrel Shifter Intermediate Signals
//-----------------------------------------------------------------
logic [31:0] shift_right_1, shift_right_2, shift_right_4, shift_right_8;
logic [31:0] shift_left_1,  shift_left_2,  shift_left_4,  shift_left_8;
logic [31:0] shift_fill;

// Subtraction result (shared by SUB and less-than-signed)
wire [31:0] sub_res = alu_a_i - alu_b_i;

//-----------------------------------------------------------------
// ALU Core
//-----------------------------------------------------------------
always @* begin
    // Defaults
    shift_fill      = 32'b0;
    shift_right_1   = '0;
    shift_right_2   = '0;
    shift_right_4   = '0;
    shift_right_8   = '0;
    shift_left_1    = '0;
    shift_left_2    = '0;
    shift_left_4    = '0;
    shift_left_8    = '0;
    alu_p_o         = alu_a_i;  // default: passthrough

    case (alu_op_i)

        //==============================================================
        // Shift Left
        //==============================================================
        `ALU_SHIFTL: begin
            // Stage 1: shift by 1
            if (alu_b_i[0])
                shift_left_1 = {alu_a_i[30:0], 1'b0};
            else
                shift_left_1 = alu_a_i;
            // Stage 2: shift by 2
            if (alu_b_i[1])
                shift_left_2 = {shift_left_1[29:0], 2'b00};
            else
                shift_left_2 = shift_left_1;
            // Stage 3: shift by 4
            if (alu_b_i[2])
                shift_left_4 = {shift_left_2[27:0], 4'b0000};
            else
                shift_left_4 = shift_left_2;
            // Stage 4: shift by 8
            if (alu_b_i[3])
                shift_left_8 = {shift_left_4[23:0], 8'b00000000};
            else
                shift_left_8 = shift_left_4;
            // Stage 5: shift by 16
            if (alu_b_i[4])
                alu_p_o = {shift_left_8[15:0], 16'b0000000000000000};
            else
                alu_p_o = shift_left_8;
        end

        //==============================================================
        // Shift Right (logical and arithmetic)
        //==============================================================
        `ALU_SHIFTR, `ALU_SHIFTR_ARITH: begin
            // Arithmetic fill = MSB of input, placed in upper bits for concatenation
            if (alu_a_i[31] && alu_op_i == `ALU_SHIFTR_ARITH)
                shift_fill = 32'hFFFFFFFF;
            else
                shift_fill = 32'h00000000;
            // Stage 1: shift by 1 (fill 1 bit)
            if (alu_b_i[0])
                shift_right_1 = {shift_fill[31], alu_a_i[31:1]};
            else
                shift_right_1 = alu_a_i;
            // Stage 2: shift by 2 (fill 2 bits)
            if (alu_b_i[1])
                shift_right_2 = {shift_fill[31:30], shift_right_1[31:2]};
            else
                shift_right_2 = shift_right_1;
            // Stage 3: shift by 4 (fill 4 bits)
            if (alu_b_i[2])
                shift_right_4 = {shift_fill[31:28], shift_right_2[31:4]};
            else
                shift_right_4 = shift_right_2;
            // Stage 4: shift by 8 (fill 8 bits)
            if (alu_b_i[3])
                shift_right_8 = {shift_fill[31:24], shift_right_4[31:8]};
            else
                shift_right_8 = shift_right_4;
            // Stage 5: shift by 16 (fill 16 bits)
            if (alu_b_i[4])
                alu_p_o = {shift_fill[31:16], shift_right_8[31:16]};
            else
                alu_p_o = shift_right_8;
        end

        //==============================================================
        // Arithmetic
        //==============================================================
        `ALU_ADD:  alu_p_o = alu_a_i + alu_b_i;
        `ALU_SUB:  alu_p_o = sub_res;

        //==============================================================
        // Logical
        //==============================================================
        `ALU_AND:  alu_p_o = alu_a_i & alu_b_i;
        `ALU_OR:   alu_p_o = alu_a_i | alu_b_i;
        `ALU_XOR:  alu_p_o = alu_a_i ^ alu_b_i;

        //==============================================================
        // Comparison
        //==============================================================
        `ALU_LESS_THAN:  // unsigned <
            alu_p_o = (alu_a_i < alu_b_i) ? 32'h1 : 32'h0;

        `ALU_LESS_THAN_SIGNED: begin
            if (alu_a_i[31] != alu_b_i[31])
                alu_p_o = alu_a_i[31] ? 32'h1 : 32'h0;
            else
                alu_p_o = sub_res[31] ? 32'h1 : 32'h0;
        end

        // Default: passthrough alu_a_i
        default: alu_p_o = alu_a_i;
    endcase
end

endmodule