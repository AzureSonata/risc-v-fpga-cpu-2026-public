//-----------------------------------------------------------------
// B1: EX/ALU - Execute Stage
// Immediate decode, ALU control, branch comparison, pipeline reg
// Based on ultraembedded/riscv (BSD license)
//-----------------------------------------------------------------

module riscv_exec #(
    // Dual-issue EX can defer the taken/not-taken PC select until after the
    // EX register boundary. Single-issue users keep the legacy branch_pc_o
    // contract (target when taken, fall-through otherwise).
    parameter integer BRANCH_PC_RAW = 0
)(
    input  logic        clk_i,
    input  logic        rst_i,
    input  logic        valid_i,         // Input instruction valid
    input  logic [31:0] opcode_i,        // Instruction opcode
    input  logic [31:0] pc_i,            // PC of instruction
    input  logic [31:0] ra_operand_i,    // RS1 value
    input  logic [31:0] rb_operand_i,    // RS2 value
    input  logic        hold_i,          // Pipeline hold

    // Outputs
    output logic        valid_o,         // Output valid
    output logic [31:0] alu_result_o,    // ALU result
    output logic [31:0] alu_result_e1_o, // ALU result (E1 bypass)
    output logic        branch_request_o,// Branch request
    output logic        branch_taken_o,  // Branch taken
    output logic        branch_not_taken_o, // Branch not taken
    output logic [31:0] branch_pc_o,     // Branch target PC
    output logic [31:0] branch_source_o, // Branch source PC
    output logic        branch_call_o,   // Is call (JAL/JALR with rd=x1)
    output logic        branch_ret_o,    // Is return (JALR rs1=x1, imm=0)
    output logic        branch_jmp_o,    // Is unconditional jump
    output logic [ 4:0] rd_idx_o,        // Destination register index
    output logic        writes_rd_o      // Instruction writes rd
);

`include "riscv_defs.svh"

//-----------------------------------------------------------------
// Immediate Decoding
//-----------------------------------------------------------------
logic [31:0] imm20;
logic [31:0] imm12;
logic [31:0] bimm;
logic [31:0] jimm20;
logic [4:0]  shamt;

always @* begin
    imm20  = {opcode_i[31:12], 12'b0};
    imm12  = {{20{opcode_i[31]}}, opcode_i[31:20]};
    bimm   = {{19{opcode_i[31]}}, opcode_i[31], opcode_i[7],
              opcode_i[30:25], opcode_i[11:8], 1'b0};
    jimm20 = {{12{opcode_i[31]}}, opcode_i[19:12], opcode_i[20],
              opcode_i[30:25], opcode_i[24:21], 1'b0};
    shamt  = opcode_i[24:20];
end

//-----------------------------------------------------------------
// ALU Control
//-----------------------------------------------------------------
logic [3:0] alu_func;
logic [31:0] alu_input_a;
logic [31:0] alu_input_b;

always @* begin
    alu_func    = `ALU_NONE;
    alu_input_a = '0;
    alu_input_b = '0;

    // R-type: register-register
    if ((opcode_i & 32'hfe00707f) == 32'h33) begin          // ADD
        alu_func    = `ALU_ADD;
        alu_input_a = ra_operand_i;
        alu_input_b = rb_operand_i;
    end
    else if ((opcode_i & 32'hfe00707f) == 32'h40000033) begin // SUB
        alu_func    = `ALU_SUB;
        alu_input_a = ra_operand_i;
        alu_input_b = rb_operand_i;
    end
    else if ((opcode_i & 32'hfe00707f) == 32'h7033) begin   // AND
        alu_func    = `ALU_AND;
        alu_input_a = ra_operand_i;
        alu_input_b = rb_operand_i;
    end
    else if ((opcode_i & 32'hfe00707f) == 32'h6033) begin   // OR
        alu_func    = `ALU_OR;
        alu_input_a = ra_operand_i;
        alu_input_b = rb_operand_i;
    end
    else if ((opcode_i & 32'hfe00707f) == 32'h4033) begin   // XOR
        alu_func    = `ALU_XOR;
        alu_input_a = ra_operand_i;
        alu_input_b = rb_operand_i;
    end
    else if ((opcode_i & 32'hfe00707f) == 32'h1033) begin   // SLL
        alu_func    = `ALU_SHIFTL;
        alu_input_a = ra_operand_i;
        alu_input_b = rb_operand_i;
    end
    else if ((opcode_i & 32'hfe00707f) == 32'h5033) begin   // SRL
        alu_func    = `ALU_SHIFTR;
        alu_input_a = ra_operand_i;
        alu_input_b = rb_operand_i;
    end
    else if ((opcode_i & 32'hfe00707f) == 32'h40005033) begin // SRA
        alu_func    = `ALU_SHIFTR_ARITH;
        alu_input_a = ra_operand_i;
        alu_input_b = rb_operand_i;
    end
    else if ((opcode_i & 32'hfe00707f) == 32'h2033) begin   // SLT
        alu_func    = `ALU_LESS_THAN_SIGNED;
        alu_input_a = ra_operand_i;
        alu_input_b = rb_operand_i;
    end
    else if ((opcode_i & 32'hfe00707f) == 32'h3033) begin   // SLTU
        alu_func    = `ALU_LESS_THAN;
        alu_input_a = ra_operand_i;
        alu_input_b = rb_operand_i;
    end
    // I-type: register-immediate
    else if ((opcode_i & 32'h707f) == 32'h13) begin         // ADDI
        alu_func    = `ALU_ADD;
        alu_input_a = ra_operand_i;
        alu_input_b = imm12;
    end
    else if ((opcode_i & 32'h707f) == 32'h7013) begin       // ANDI
        alu_func    = `ALU_AND;
        alu_input_a = ra_operand_i;
        alu_input_b = imm12;
    end
    else if ((opcode_i & 32'h707f) == 32'h6013) begin       // ORI
        alu_func    = `ALU_OR;
        alu_input_a = ra_operand_i;
        alu_input_b = imm12;
    end
    else if ((opcode_i & 32'h707f) == 32'h4013) begin       // XORI
        alu_func    = `ALU_XOR;
        alu_input_a = ra_operand_i;
        alu_input_b = imm12;
    end
    else if ((opcode_i & 32'h707f) == 32'h2013) begin       // SLTI
        alu_func    = `ALU_LESS_THAN_SIGNED;
        alu_input_a = ra_operand_i;
        alu_input_b = imm12;
    end
    else if ((opcode_i & 32'h707f) == 32'h3013) begin       // SLTIU
        alu_func    = `ALU_LESS_THAN;
        alu_input_a = ra_operand_i;
        alu_input_b = imm12;
    end
    else if ((opcode_i & 32'hfc00707f) == 32'h1013) begin   // SLLI
        alu_func    = `ALU_SHIFTL;
        alu_input_a = ra_operand_i;
        alu_input_b = {27'b0, shamt};
    end
    else if ((opcode_i & 32'hfc00707f) == 32'h5013) begin   // SRLI
        alu_func    = `ALU_SHIFTR;
        alu_input_a = ra_operand_i;
        alu_input_b = {27'b0, shamt};
    end
    else if ((opcode_i & 32'hfc00707f) == 32'h40005013) begin // SRAI
        alu_func    = `ALU_SHIFTR_ARITH;
        alu_input_a = ra_operand_i;
        alu_input_b = {27'b0, shamt};
    end
    // U-type
    else if ((opcode_i & 32'h7f) == 32'h37) begin           // LUI
        alu_func    = `ALU_NONE;
        alu_input_a = imm20;
        alu_input_b = '0;
    end
    else if ((opcode_i & 32'h7f) == 32'h17) begin           // AUIPC
        alu_func    = `ALU_ADD;
        alu_input_a = pc_i;
        alu_input_b = imm20;
    end
    // J-type (return address = PC+4)
    else if ((opcode_i & 32'h7f) == 32'h6f ||               // JAL
             (opcode_i & 32'h707f) == 32'h67) begin         // JALR
        alu_func    = `ALU_ADD;
        alu_input_a = pc_i;
        alu_input_b = 32'd4;
    end
    // Illegal / unrecognized instruction: safe default
    else begin
        alu_func    = `ALU_NONE;
        alu_input_a = '0;
        alu_input_b = '0;
    end
end

//-----------------------------------------------------------------
// ALU Instantiation
//-----------------------------------------------------------------
logic [31:0] alu_result;

riscv_alu u_alu (
    .alu_op_i(alu_func),
    .alu_a_i (alu_input_a),
    .alu_b_i (alu_input_b),
    .alu_p_o (alu_result)
);

//-----------------------------------------------------------------
// Destination Register Decode
//-----------------------------------------------------------------
logic       writes_rd;

always @* begin
    writes_rd = 1'b0;

    // R-type (register-register ALU)
    if ((opcode_i & 32'hfe00707f) == 32'h33)           writes_rd = 1'b1;  // ADD
    else if ((opcode_i & 32'hfe00707f) == 32'h40000033) writes_rd = 1'b1;  // SUB
    else if ((opcode_i & 32'hfe00707f) == 32'h7033)    writes_rd = 1'b1;  // AND
    else if ((opcode_i & 32'hfe00707f) == 32'h6033)    writes_rd = 1'b1;  // OR
    else if ((opcode_i & 32'hfe00707f) == 32'h4033)    writes_rd = 1'b1;  // XOR
    else if ((opcode_i & 32'hfe00707f) == 32'h1033)    writes_rd = 1'b1;  // SLL
    else if ((opcode_i & 32'hfe00707f) == 32'h5033)    writes_rd = 1'b1;  // SRL
    else if ((opcode_i & 32'hfe00707f) == 32'h40005033) writes_rd = 1'b1; // SRA
    else if ((opcode_i & 32'hfe00707f) == 32'h2033)    writes_rd = 1'b1;  // SLT
    else if ((opcode_i & 32'hfe00707f) == 32'h3033)    writes_rd = 1'b1;  // SLTU
    // I-type (register-immediate ALU)
    else if ((opcode_i & 32'h707f) == 32'h13)          writes_rd = 1'b1;  // ADDI
    else if ((opcode_i & 32'h707f) == 32'h7013)        writes_rd = 1'b1;  // ANDI
    else if ((opcode_i & 32'h707f) == 32'h6013)        writes_rd = 1'b1;  // ORI
    else if ((opcode_i & 32'h707f) == 32'h4013)        writes_rd = 1'b1;  // XORI
    else if ((opcode_i & 32'h707f) == 32'h2013)        writes_rd = 1'b1;  // SLTI
    else if ((opcode_i & 32'h707f) == 32'h3013)        writes_rd = 1'b1;  // SLTIU
    else if ((opcode_i & 32'hfc00707f) == 32'h1013)    writes_rd = 1'b1;  // SLLI
    else if ((opcode_i & 32'hfc00707f) == 32'h5013)    writes_rd = 1'b1;  // SRLI
    else if ((opcode_i & 32'hfc00707f) == 32'h40005013) writes_rd = 1'b1; // SRAI
    // U-type
    else if ((opcode_i & 32'h7f) == 32'h37)            writes_rd = 1'b1;  // LUI
    else if ((opcode_i & 32'h7f) == 32'h17)            writes_rd = 1'b1;  // AUIPC
    // J-type (return address)
    else if ((opcode_i & 32'h7f) == 32'h6f)            writes_rd = 1'b1;  // JAL
    else if ((opcode_i & 32'h707f) == 32'h67)          writes_rd = 1'b1;  // JALR
    // Loads (address in EX, data in LSU)
    else if ((opcode_i & 32'h707f) == 32'h3)           writes_rd = 1'b1;  // LB
    else if ((opcode_i & 32'h707f) == 32'h1003)        writes_rd = 1'b1;  // LH
    else if ((opcode_i & 32'h707f) == 32'h2003)        writes_rd = 1'b1;  // LW
    else if ((opcode_i & 32'h707f) == 32'h4003)        writes_rd = 1'b1;  // LBU
    else if ((opcode_i & 32'h707f) == 32'h5003)        writes_rd = 1'b1;  // LHU
end
//-----------------------------------------------------------------
// Signed Comparison Functions
//-----------------------------------------------------------------
function automatic logic less_than_signed(input [31:0] x, y);
    logic [31:0] v;
begin
    v = x - y;
    if (x[31] != y[31])
        less_than_signed = x[31];
    else
        less_than_signed = v[31];
end
endfunction

function automatic logic greater_than_signed(input [31:0] x, y);
    logic [31:0] v;
begin
    v = y - x;
    if (x[31] != y[31])
        greater_than_signed = y[31];
    else
        greater_than_signed = v[31];
end
endfunction

//-----------------------------------------------------------------
// Branch Logic
//-----------------------------------------------------------------
logic        branch_req;
logic        branch_taken;
logic [31:0] branch_target;
logic        branch_call;
logic        branch_ret;
logic        branch_jmp;
logic [4:0]  rd_idx;
logic [4:0]  rs1_idx;

assign rd_idx = opcode_i[11:7];
assign rs1_idx = opcode_i[19:15];

always @* begin
    branch_req    = 1'b0;
    branch_taken  = 1'b0;
    branch_call   = 1'b0;
    branch_ret    = 1'b0;
    branch_jmp    = 1'b0;
    branch_target = pc_i + bimm;  // default: B-type target

    if ((opcode_i & 32'h7f) == 32'h6f) begin                 // JAL
        branch_req    = 1'b1;
        branch_taken  = 1'b1;
        branch_target = pc_i + jimm20;
        branch_call   = (rd_idx == 5'd1);  // RA = x1
        branch_jmp    = 1'b1;
    end
    else if ((opcode_i & 32'h707f) == 32'h67) begin          // JALR
        branch_req    = 1'b1;
        branch_taken  = 1'b1;
        branch_target = ra_operand_i + imm12;
        branch_target[0] = 1'b0;  // JALR target bit 0 = 0
        branch_ret    = (rs1_idx == 5'd1 && imm12[11:0] == 12'b0);
        branch_call   = ~branch_ret && (rd_idx == 5'd1);
        branch_jmp    = ~(branch_call | branch_ret);
    end
    else if ((opcode_i & 32'h707f) == 32'h63) begin          // BEQ
        branch_req    = 1'b1;
        branch_taken  = (ra_operand_i == rb_operand_i);
    end
    else if ((opcode_i & 32'h707f) == 32'h1063) begin        // BNE
        branch_req    = 1'b1;
        branch_taken  = (ra_operand_i != rb_operand_i);
    end
    else if ((opcode_i & 32'h707f) == 32'h4063) begin        // BLT
        branch_req    = 1'b1;
        branch_taken  = less_than_signed(ra_operand_i, rb_operand_i);
    end
    else if ((opcode_i & 32'h707f) == 32'h5063) begin        // BGE
        branch_req    = 1'b1;
        branch_taken  = greater_than_signed(ra_operand_i, rb_operand_i) ||
                        (ra_operand_i == rb_operand_i);
    end
    else if ((opcode_i & 32'h707f) == 32'h6063) begin        // BLTU
        branch_req    = 1'b1;
        branch_taken  = (ra_operand_i < rb_operand_i);
    end
    else if ((opcode_i & 32'h707f) == 32'h7063) begin        // BGEU
        branch_req    = 1'b1;
        branch_taken  = (ra_operand_i >= rb_operand_i);
    end
end

//-----------------------------------------------------------------
// Pipeline Register (E1 stage)
//-----------------------------------------------------------------
logic        branch_req_q;
logic        branch_taken_q;
logic        branch_not_taken_q;
logic [31:0] branch_pc_q;
logic [31:0] branch_source_q;
logic        branch_call_q;
logic        branch_ret_q;
logic        branch_jmp_q;
logic [31:0] result_q;
logic        valid_q;
logic [ 4:0] rd_idx_q;
logic        writes_rd_q;

always @(posedge clk_i) begin
    if (rst_i) begin
        valid_q          <= 1'b0;
        result_q         <= '0;
        branch_req_q     <= 1'b0;
        branch_taken_q   <= 1'b0;
        branch_not_taken_q <= 1'b0;
        branch_pc_q      <= '0;
        branch_source_q  <= '0;
        branch_call_q    <= 1'b0;
        branch_ret_q     <= 1'b0;
        branch_jmp_q     <= 1'b0;
        rd_idx_q         <= '0;
        writes_rd_q      <= 1'b0;
    end
    else if (valid_i && ~hold_i) begin
        valid_q          <= 1'b1;
        result_q         <= alu_result;
        branch_req_q     <= branch_req;
        branch_taken_q   <= branch_req && branch_taken;
        branch_not_taken_q <= branch_req && ~branch_taken;
        branch_pc_q      <= BRANCH_PC_RAW ? branch_target :
                            (branch_taken ? branch_target : pc_i + 32'd4);
        branch_source_q  <= pc_i;
        branch_call_q    <= branch_req && branch_call;
        branch_ret_q     <= branch_req && branch_ret;
        branch_jmp_q     <= branch_req && branch_jmp;
        rd_idx_q         <= rd_idx;
        writes_rd_q      <= writes_rd;
    end
    else if (~hold_i) begin
        valid_q          <= 1'b0;
        branch_req_q     <= 1'b0;
        branch_taken_q   <= 1'b0;
        branch_not_taken_q <= 1'b0;
        branch_pc_q      <= '0;
        branch_source_q  <= '0;
        branch_call_q    <= 1'b0;
        branch_ret_q     <= 1'b0;
        branch_jmp_q     <= 1'b0;
        rd_idx_q         <= '0;
        writes_rd_q      <= 1'b0;
    end
end

// Output assignments
assign valid_o           = valid_q;
assign alu_result_o      = result_q;
assign alu_result_e1_o   = alu_result;         // E1 bypass (combinational)
assign branch_request_o  = branch_req_q;
assign branch_taken_o    = branch_taken_q;
assign branch_not_taken_o= branch_not_taken_q;
assign branch_pc_o       = branch_pc_q;
assign branch_source_o   = branch_source_q;
assign branch_call_o     = branch_call_q;
assign branch_ret_o      = branch_ret_q;
assign branch_jmp_o      = branch_jmp_q;
assign rd_idx_o          = rd_idx_q;
assign writes_rd_o       = writes_rd_q;

endmodule
