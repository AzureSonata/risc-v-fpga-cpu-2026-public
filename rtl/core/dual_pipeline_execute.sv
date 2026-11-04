// Pure combinational EX stage.  The caller owns the ID/EX and EX/MEM
// registers, valid/ready control, operand forwarding and precise side effects.
// No raw instruction bits are decoded beyond this boundary.
module dual_pipeline_execute (
    input  wire [3:0]  alu_func_i,
    input  wire        src_a_pc_i,
    input  wire        src_a_zero_i,
    input  wire        src_b_imm_i,
    input  wire        branch_i,
    input  wire        jal_i,
    input  wire        jalr_i,
    input  wire [2:0]  funct3_i,
    input  wire [31:0] pc_i,
    input  wire [31:0] imm_i,
    input  wire [31:0] ra_i,
    input  wire [31:0] rb_i,
    output wire [31:0] result_o,
    output reg         branch_taken_o,
    output reg         branch_taken_fast_o,
    output wire [31:0] branch_target_o,
    output wire [31:0] effective_addr_o
);
    wire [31:0] alu_a = src_a_pc_i ? pc_i :
                        src_a_zero_i ? 32'b0 : ra_i;
    wire [31:0] alu_b = src_b_imm_i ? imm_i : rb_i;
    wire [31:0] alu_result;
    riscv_alu u_alu (
        .alu_op_i(alu_func_i), .alu_a_i(alu_a), .alu_b_i(alu_b),
        .alu_p_o(alu_result)
    );

    assign result_o = (jal_i || jalr_i) ? (pc_i + 32'd4) : alu_result;
    assign effective_addr_o = ra_i + imm_i;
    assign branch_target_o = jalr_i ? {effective_addr_o[31:1], 1'b0}
                                   : (pc_i + imm_i);

    // Timing-oriented duplicate of the branch condition.  Four independent
    // byte compares are combined lexicographically (most-significant byte
    // first), avoiding the single 32-bit relational operator used below.
    // Signed ordering is unsigned ordering after sign-bit biasing; equivalently,
    // differing signs select ra_i[31], otherwise the unsigned result applies.
    // This output is intended only for redirect control; architectural result,
    // target, trap, and predictor paths continue to use branch_taken_o.
    wire [3:0] cmp_eq8 = {
        (ra_i[31:24] == rb_i[31:24]),
        (ra_i[23:16] == rb_i[23:16]),
        (ra_i[15:8]  == rb_i[15:8]),
        (ra_i[7:0]   == rb_i[7:0])
    };
    wire [3:0] cmp_lt8 = {
        (ra_i[31:24] < rb_i[31:24]),
        (ra_i[23:16] < rb_i[23:16]),
        (ra_i[15:8]  < rb_i[15:8]),
        (ra_i[7:0]   < rb_i[7:0])
    };
    wire cmp_unsigned_lt = cmp_lt8[3] |
        (cmp_eq8[3] & cmp_lt8[2]) |
        (cmp_eq8[3] & cmp_eq8[2] & cmp_lt8[1]) |
        (cmp_eq8[3] & cmp_eq8[2] & cmp_eq8[1] & cmp_lt8[0]);
    wire cmp_signed_lt = (ra_i[31] ^ rb_i[31]) ? ra_i[31] : cmp_unsigned_lt;
    wire cmp_equal = &cmp_eq8;

    always @* begin
        branch_taken_fast_o = jal_i || jalr_i;
        if (branch_i) begin
            case (funct3_i)
                3'b000: branch_taken_fast_o = cmp_equal;
                3'b001: branch_taken_fast_o = !cmp_equal;
                3'b100: branch_taken_fast_o = cmp_signed_lt;
                3'b101: branch_taken_fast_o = !cmp_signed_lt;
                3'b110: branch_taken_fast_o = cmp_unsigned_lt;
                3'b111: branch_taken_fast_o = !cmp_unsigned_lt;
                default: branch_taken_fast_o = 1'b0;
            endcase
        end
    end

    always @* begin
        branch_taken_o = jal_i || jalr_i;
        if (branch_i) begin
            case (funct3_i)
                3'b000: branch_taken_o = (ra_i == rb_i);
                3'b001: branch_taken_o = (ra_i != rb_i);
                3'b100: branch_taken_o = ($signed(ra_i) < $signed(rb_i));
                3'b101: branch_taken_o = ($signed(ra_i) >= $signed(rb_i));
                3'b110: branch_taken_o = (ra_i < rb_i);
                3'b111: branch_taken_o = (ra_i >= rb_i);
                default: branch_taken_o = 1'b0;
            endcase
        end
    end
endmodule
