// Candidate integration source: PR #46 isolated experiment at 9efc6c693309af7e23fd0fc10d5a7c161b394994.
// Only this candidate worktree integrates it; unit-level evidence is not CPU proof.
// RV32IM arithmetic unit for the parameter-gated CPU candidate; M_MODE=0 preserves the RV32I baseline.
// MUL uses registered 16x16 partial products: low results take two execution
// cycles after request acceptance, high results four. DIV/REM use a 32-step
// restoring divider and retain exact RISC-V corner semantics.
module rv32im_unit #(parameter DIV_ENABLE = 1'b1) (
    input  logic        clk_i,
    input  logic        rst_i,
    input  logic        start_i,
    input  logic [2:0]  funct3_i, // RV32M OP funct3: MUL..REMU
    input  logic [31:0] operand_a_i,
    input  logic [31:0] operand_b_i,
    output logic        ready_o,
    output logic        done_o,
    output logic [31:0] result_o
);
    logic busy_q;
    logic [5:0] step_q;
    logic [31:0] quotient_q, divisor_q;
    logic [32:0] remainder_q;
    logic quotient_mode_q;
    logic quotient_negate_q, remainder_negate_q;

    logic mul_busy_q;
    logic [1:0] mul_stage_q;
    logic [31:0] mul_a_q, mul_b_q;
    logic [2:0] mul_funct3_q;
    logic [31:0] mul_p00_q, mul_p01_q, mul_p10_q, mul_p11_q;
    logic [31:0] mul_low_q, mul_high_q, mul_correction_q;
    logic [16:0] mul_cross_high_q;
    logic mul_low_carry_q;
    wire [16:0] mul_cross_low = {1'b0, mul_p01_q[15:0]} +
                                  {1'b0, mul_p10_q[15:0]};
    // The high cross-term sum already includes its bit-16 carry.  Add only
    // the low 16 cross bits here, so mul_low_carry_q counts just the carry
    // from combining that low word with p00, not the cross carry a second time.
    wire [32:0] mul_low_accum = {1'b0, mul_p00_q} +
                              {1'b0, mul_cross_low[15:0], 16'b0};

    logic [32:0] shifted_remainder;
    logic [31:0] shifted_quotient;
    logic [32:0] reduced_remainder;
    logic [31:0] reduced_quotient;
    logic [31:0] final_quotient, final_remainder;

    always_comb begin
        shifted_remainder = {remainder_q[31:0], quotient_q[31]};
        shifted_quotient  = {quotient_q[30:0], 1'b0};
        reduced_remainder = shifted_remainder;
        reduced_quotient  = shifted_quotient;
        if (shifted_remainder >= {1'b0, divisor_q}) begin
            reduced_remainder = shifted_remainder - {1'b0, divisor_q};
            reduced_quotient[0] = 1'b1;
        end

        final_quotient = quotient_negate_q ? (~reduced_quotient + 32'd1)
                                           : reduced_quotient;
        final_remainder = remainder_negate_q ? (~reduced_remainder[31:0] + 32'd1)
                                             : reduced_remainder[31:0];
    end

    assign ready_o = !busy_q && !mul_busy_q;

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            busy_q             <= 1'b0;
            mul_busy_q         <= 1'b0;
            mul_stage_q        <= '0;
            mul_a_q            <= '0;
            mul_b_q            <= '0;
            mul_funct3_q       <= '0;
            mul_p00_q          <= '0;
            mul_p01_q          <= '0;
            mul_p10_q          <= '0;
            mul_p11_q          <= '0;
            mul_low_q          <= '0;
            mul_high_q         <= '0;
            mul_correction_q   <= '0;
            mul_cross_high_q   <= '0;
            mul_low_carry_q    <= 1'b0;
            step_q             <= '0;
            quotient_q         <= '0;
            divisor_q          <= '0;
            remainder_q        <= '0;
            quotient_mode_q    <= 1'b0;
            quotient_negate_q  <= 1'b0;
            remainder_negate_q <= 1'b0;
            done_o             <= 1'b0;
            result_o           <= '0;
        end else begin
            done_o <= 1'b0;
            {mul_low_carry_q, mul_low_q} <= mul_low_accum;
            if (!busy_q && !mul_busy_q && start_i) begin
                case (funct3_i)
                    3'b000, 3'b001, 3'b010, 3'b011: begin
                        // Four unsigned 16x16 partial products are registered over
                        // multiple cycles; the CPU already waits on ready/done.
                        mul_a_q      <= operand_a_i;
                        mul_b_q      <= operand_b_i;
                        mul_funct3_q <= funct3_i;
                        mul_stage_q  <= 2'd0;
                        mul_busy_q   <= 1'b1;
                    end
                    3'b100, 3'b101, 3'b110, 3'b111: begin
                        if (!DIV_ENABLE) begin result_o <= 32'b0; done_o <= 1'b1; end
                        else begin
                        quotient_mode_q    <= !funct3_i[1];
                        quotient_negate_q  <= !funct3_i[0] && (operand_a_i[31] ^ operand_b_i[31]);
                        remainder_negate_q <= !funct3_i[0] && operand_a_i[31];
                        if (!operand_b_i) begin
                            result_o <= funct3_i[1] ? operand_a_i : 32'hffff_ffff;
                            done_o <= 1'b1;
                        end else if (!funct3_i[0] &&
                                     operand_a_i == 32'h8000_0000 &&
                                     operand_b_i == 32'hffff_ffff) begin
                            result_o <= funct3_i[1] ? 32'b0 : 32'h8000_0000;
                            done_o <= 1'b1;
                        end else begin
                            quotient_q <= (!funct3_i[0] && operand_a_i[31])
                                        ? (~operand_a_i + 32'd1) : operand_a_i;
                            divisor_q <= (!funct3_i[0] && operand_b_i[31])
                                       ? (~operand_b_i + 32'd1) : operand_b_i;
                            remainder_q <= '0;
                            step_q <= '0;
                            busy_q <= 1'b1;
                        end
                        end
                    end
                    default: begin result_o <= 32'b0; done_o <= 1'b1; end
                endcase
            end else if (mul_busy_q) begin
                case (mul_stage_q)
                    2'd0: begin
                        mul_p00_q <= mul_a_q[15:0] * mul_b_q[15:0];
                        mul_p01_q <= mul_a_q[31:16] * mul_b_q[15:0];
                        mul_p10_q <= mul_a_q[15:0] * mul_b_q[31:16];
                        mul_p11_q <= mul_a_q[31:16] * mul_b_q[31:16];
                        if (mul_funct3_q == 3'b001)
                            mul_correction_q <= (mul_a_q[31] ? mul_b_q : 32'b0) +
                                                (mul_b_q[31] ? mul_a_q : 32'b0);
                        else if (mul_funct3_q == 3'b010)
                            mul_correction_q <= mul_a_q[31] ? mul_b_q : 32'b0;
                        else
                            mul_correction_q <= 32'b0;
                        mul_stage_q <= 2'd1;
                    end
                    2'd1: begin
                        mul_cross_high_q <= {1'b0, mul_p01_q} + {1'b0, mul_p10_q} >> 16;
                        if (mul_funct3_q == 3'b000) begin
                            // The low product needs only the registered 16x16
                            // partial products. Return it now; high-result
                            // accumulation and signed correction are irrelevant.
                            result_o <= mul_low_accum[31:0];
                            mul_busy_q <= 1'b0;
                            done_o <= 1'b1;
                        end else begin
                            mul_stage_q <= 2'd2;
                        end
                    end
                    2'd2: begin
                        mul_high_q <= mul_p11_q + mul_cross_high_q + mul_low_carry_q;
                        mul_stage_q <= 2'd3;
                    end
                    default: begin
                        case (mul_funct3_q)
                            3'b000: result_o <= mul_low_q;
                            3'b001, 3'b010: result_o <= mul_high_q - mul_correction_q;
                            default: result_o <= mul_high_q;
                        endcase
                        mul_busy_q <= 1'b0;
                        done_o <= 1'b1;
                    end
                endcase
            end else if (busy_q) begin
                quotient_q  <= reduced_quotient;
                remainder_q <= reduced_remainder;
                step_q <= step_q + 1'b1;
                if (step_q == 6'd31) begin
                    result_o <= quotient_mode_q ? final_quotient : final_remainder;
                    busy_q <= 1'b0;
                    done_o <= 1'b1;
                end
            end
        end
    end
endmodule
