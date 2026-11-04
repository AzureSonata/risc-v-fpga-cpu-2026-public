// ============================================================================
//        RV32I 译码器（ID 阶段）
//        纯组合逻辑：指令 -> 控制信号 + 立即数 + 寄存器地址
//        支持 fetch_fault 门控 + 完整 illegal 指令检测
//        参考：tinyriscv/id.v + V-FRONT/instruction_decoder.v
//        成员 A Stage1 -> IC-BLOCK-005 修正
// ============================================================================

`include "defines.sv"

module id_stage #(
    // SUPPORT_M=1 时接受 RV32M 的 funct7=0000001（MUL/MULH/MULHSU/MULHU/
    // DIV/DIVU/REM/REMU 共 8 条）；默认 0 保持纯 RV32I 行为不变。
    //
    // 依据：REQ-002 只强制 RV32I 基础集，M 属可选标准扩充；但 CoreMark/MHz
    // （REQ-010）对硬件乘法高度敏感——跨四篇参考文献一致显示 RV32IM ≈2.8–3.3
    // 而 RV32I 纯软乘 ≈1.19 CoreMark/MHz。故 M 应纳入，但作为可切换选项，
    // 以便 Stage3 做 RV32I / RV32IM 对照实验并保留纯 RV32I 合规证据。
    //
    // 注意：本参数只决定 ID 是否将 M 编码判为合法。M 的执行语义由 EX 侧按
    // opcode/funct3/funct7 自行译出（本分支无 EX 模块，故不新增 mul_o/div_o
    // 端口，避免无消费者的接口变更）。
    parameter SUPPORT_M = 1'b0,
    // Zmmul makes only MUL/MULH/MULHSU/MULHU legal; DIV/REM stay illegal.
    parameter SUPPORT_ZMMUL = 1'b0
)(
    input  wire rst,

    // 来自 IF/ID 的指令与 PC
    input  wire [31:0]  inst_i,
    input  wire [31:0]  pc_i,
    input  wire         inst_valid_i,       // 指令是否有效
    input  wire         fault_i,            // fetch_fault（IC-BLOCK-005）
    input  wire         pred_valid_i,       // BTB 预测是否有效
    input  wire         pred_taken_i,       // 预测方向
    input  wire [31:0]  pred_target_i,      // 预测目标

    // 来自 EX 的跳转标志（用于空闲检测）
    input  wire         ex_jump_flag_i,

    // 寄存器文件地址
    output reg  [4:0]   rs1_addr_o,
    output reg  [4:0]   rs2_addr_o,

    // 立即数
    output reg  [31:0]  imm_o,

    // 控制信号
    output reg          reg_we_o,
    output reg  [4:0]   rd_addr_o,
    output reg          mem_req_o,
    output reg          mem_we_o,
    output reg  [3:0]   mem_wstrb_o,
    output reg          branch_o,
    output reg          jal_o,
    output reg          jalr_o,
    output reg          lui_o,
    output reg          auipc_o,

    // 冒险检测辅助
    output reg          uses_rs1_o,
    output reg          uses_rs2_o,

    // 传递原始指令字段给 EX
    output reg  [6:0]   opcode_o,
    output reg  [2:0]   funct3_o,
    output reg  [6:0]   funct7_o,
    output reg  [4:0]   rd_o,

    // 预测元数据传递给 EX
    output reg          pred_valid_o,
    output reg          pred_taken_o,
    output reg  [31:0]  pred_target_o,
    output reg          illegal_instr_o,

    // ---------------- SYSTEM 类译码（CSR / ECALL / EBREAK / MRET） ----------------
    // 批 (a)：只提供"CSR 读写路径"所需的字段 + 特权指令的译码标志。
    // **合法性判定不在这里**：未实现 CSR / 写只读 CSR 的非法性由提交点用真实
    // `csr_file` 的译码结果判定（见 cpu_core_stage1），避免在 ID 期重复实现
    // 一份 CSR 地址图而产生两处漂移；陷阱进入与 mret 重定向由批 (b)/(c) 接入。
    output reg  [11:0]  csr_addr_o,     // inst[31:20]
    output reg          csr_we_o,       // 写意图：CSRRW/CSRRWI，或 CSRRS/C(SI/CI) 且 rs1/uimm != x0
    output reg  [1:0]   csr_op_o,       // 00=写 01=置位 10=清零
    output reg          csr_imm_o,      // 立即数形式（CSRRWI/CSRRSI/CSRRCI）
    output reg  [31:0]  csr_uimm_o,     // 零扩展的 5 位 uimm（rs1 域）
    output reg          sys_ecall_o,
    output reg          sys_ebreak_o,
    output reg          sys_mret_o
);

    // 指令字段提取
    wire [6:0] opcode = inst_i[6:0];
    wire [2:0] funct3 = inst_i[14:12];
    wire [6:0] funct7 = inst_i[31:25];
    wire [4:0] rd     = inst_i[11:7];
    wire [4:0] rs1    = inst_i[19:15];
    wire [4:0] rs2    = inst_i[24:20];

    // 立即数解码
    wire [31:0] imm_i = {{20{inst_i[31]}}, inst_i[31:20]};
    wire [31:0] imm_s = {{20{inst_i[31]}}, inst_i[31:25], inst_i[11:7]};
    wire [31:0] imm_b = {{20{inst_i[31]}}, inst_i[7], inst_i[30:25], inst_i[11:8], 1'b0};
    wire [31:0] imm_u = {inst_i[31:12], 12'b0};
    wire [31:0] imm_j = {{12{inst_i[31]}}, inst_i[19:12], inst_i[20], inst_i[30:21], 1'b0};

    // Illegal 指令检测（IC-BLOCK-005）
    wire illegal_opcode = (opcode != 7'b0010011) &&  // INST_TYPE_I
                          (opcode != 7'b0000011) &&  // INST_TYPE_L
                          (opcode != 7'b0100011) &&  // INST_TYPE_S
                          (opcode != 7'b0110011) &&  // INST_TYPE_R_M
                          (opcode != 7'b1100011) &&  // INST_TYPE_B
                          (opcode != 7'b1101111) &&  // INST_JAL
                          (opcode != 7'b1100111) &&  // INST_JALR
                          (opcode != 7'b0110111) &&  // INST_LUI
                          (opcode != 7'b0010111) &&  // INST_AUIPC
                          // SYSTEM（1110011）：CSR 读写 + ECALL/EBREAK/MRET。
                          // 本 opcode 已成为"已知 opcode"，其编码合法性由
                          // illegal_system 单独判定（funct3=100、funct3=000 的
                          // 保留 imm/非零 rs1/rd、以及批量 (b) 才接的陷阱语义）。
                          (opcode != 7'b1110011);    // INST_SYSTEM
    
    // I 型的 8 个 funct3 取值全部对应已实现指令
    //   (000 ADDI / 010 SLTI / 011 SLTIU / 100 XORI / 110 ORI / 111 ANDI /
    //    001 SLLI / 101 SRLI,SRAI)
    // 故此判据**有意恒为假**。这一点与原 R 型的"恒假空判据"（D-3）表面相同、
    // 性质不同：R 型的空判据掩盖了真实约束，I 型这里确实没有 funct3 级约束。
    // I 型的真实约束在移位立即数的 funct7（见 illegal_slli / illegal_sri）。
    wire illegal_i = 1'b0;

    // D-7 修复：原实现只比较 funct7[6:5]（2 位），导致 funct7 低 5 位非零的
    // 保留编码被误受——例如 funct7=7'b0000001 会被当作合法 SLLI。
    // RV32I 规定：SLLI/SRLI 的 imm[11:5] 必须为 0000000，SRAI 为 0100000，
    // 其余编码保留。故须比较**完整 7 位** funct7。
    wire illegal_slli = (opcode == 7'b0010011) && (funct3 == 3'b001) &&
                        (funct7 != 7'b0000000);
    wire illegal_sri  = (opcode == 7'b0010011) && (funct3 == 3'b101) &&
                        (funct7 != 7'b0000000) && (funct7 != 7'b0100000);
    
    wire illegal_l = (opcode == 7'b0000011) &&
                     (funct3 != 3'b000) &&
                     (funct3 != 3'b001) &&
                     (funct3 != 3'b010) &&
                     (funct3 != 3'b100) &&
                     (funct3 != 3'b101);
    
    wire illegal_s = (opcode == 7'b0100011) &&
                     (funct3 != 3'b000) &&
                     (funct3 != 3'b001) &&
                     (funct3 != 3'b010);
    
    // D-3 修复：原 illegal_r_funct3 逐一列出全部 8 个 funct3 值，该判据恒为假
    // （空判据），真正的约束被漏掉：RV32I 规定 funct7=0100000 时仅
    // SUB(funct3=000) 与 SRA(funct3=101) 合法，其余为保留编码。
    // funct7=0000000 时全部 8 个 funct3 合法。
    //
    // Stage B：M 扩展（funct7=0000001）由 SUPPORT_M 参数门控。M 类编码的
    // funct3 全部 8 个取值均合法（MUL/MULH/MULHSU/MULHU/DIV/DIVU/REM/REMU），
    // 故无需额外的 funct3 约束。
    wire m_funct7_enabled = (SUPPORT_M ||
                             (SUPPORT_ZMMUL && !funct3[2])) &&
                            (funct7 == 7'b0000001);
    wire valid_r_funct7 = (funct7 == 7'b0000000) || (funct7 == 7'b0100000) ||
                          m_funct7_enabled;
    wire illegal_r_funct7 = (opcode == 7'b0110011) && !valid_r_funct7;

    wire illegal_r_funct3 = (opcode == 7'b0110011) && (funct7 == 7'b0100000) &&
                            (funct3 != 3'b000) && (funct3 != 3'b101);
    
    wire illegal_b = (opcode == 7'b1100011) &&
                     (funct3 != 3'b000) &&
                     (funct3 != 3'b001) &&
                     (funct3 != 3'b100) &&
                     (funct3 != 3'b101) &&
                     (funct3 != 3'b110) &&
                     (funct3 != 3'b111);
    
    wire illegal_jalr = (opcode == 7'b1100111) && (funct3 != 3'b000);

    // ================= SYSTEM 类（opcode 1110011）译码（批 (a)） =================
    // 依据：TECHNICAL_BASELINE.md「最小 machine mode」+ RV32I 特权指令编码。
    //   funct3=000 → ECALL(imm=0x000) / EBREAK(0x001) / MRET(0x302)；rs1/rd 必须为 0，
    //                 其余 imm（含 WFI 0x105）为**未实现**编码 → 非法。
    //   funct3=100 → 保留编码 → 非法。
    //   其余 funct3 → CSR 类：001 CSRRW / 010 CSRRS / 011 CSRRC
    //                         101 CSRRWI / 110 CSRRSI / 111 CSRRCI
    // 说明：本批只判"编码是否合法"，**不判 CSR 地址是否存在/是否可写**——
    // 那两项在提交点用 csr_file 的 csr_implemented/csr_writable 判定。
    wire [11:0] sys_imm12 = inst_i[31:20];
    wire        is_system  = (opcode == 7'b1110011);
    wire        csr_fmt    = is_system && (funct3 != 3'b000) && (funct3 != 3'b100);
    wire        csr_is_imm = csr_fmt && funct3[2];
    // CSRRS/C(SI/CI) 在 rs1(=uimm) 为 x0/0 时**不写** CSR（RV32I 规定，且此时
    // 对只读 CSR 不得报非法）——写意图必须在这里区分，不能在 csr_file 里补。
    wire        csr_is_rw   = (funct3 == 3'b001) || (funct3 == 3'b101);
    wire        csr_write_intent = csr_is_rw || (rs1 != 5'b0);
    wire [1:0]  csr_op_sel = (funct3[1:0] == 2'b10) ? 2'b01 :   // CSRRS/I
                             (funct3[1:0] == 2'b11) ? 2'b10 :   // CSRRC/I
                                                      2'b00;    // CSRRW/I
    wire        sys_priv_legal = (funct3 == 3'b000) && (rs1 == 5'b0) && (rd == 5'b0) &&
                                 ((sys_imm12 == 12'h000) || (sys_imm12 == 12'h001) ||
                                  (sys_imm12 == 12'h302));
    wire        sys_ecall  = sys_priv_legal && (sys_imm12 == 12'h000);
    wire        sys_ebreak = sys_priv_legal && (sys_imm12 == 12'h001);
    wire        sys_mret   = sys_priv_legal && (sys_imm12 == 12'h302);
    wire        illegal_system = is_system &&
                                 ((funct3 == 3'b100) ||
                                  ((funct3 == 3'b000) && !sys_priv_legal));
    
    wire illegal = illegal_opcode || illegal_i || illegal_slli || illegal_sri ||
                   illegal_l || illegal_s || illegal_r_funct7 || illegal_r_funct3 ||
                   illegal_b || illegal_jalr || illegal_system;


    // 译码逻辑（纯组合）
    always @(*) begin
        // 默认值
        rs1_addr_o   = 5'h0;
        rs2_addr_o   = 5'h0;
        imm_o        = 32'h0;
        reg_we_o     = 1'b0;
        rd_addr_o    = 5'h0;
        mem_req_o    = 1'b0;
        mem_we_o     = 1'b0;
        mem_wstrb_o  = 4'b0000;
        branch_o     = 1'b0;
        jal_o        = 1'b0;
        jalr_o       = 1'b0;
        lui_o        = 1'b0;
        auipc_o      = 1'b0;
        // SYSTEM 类必须在默认区赋值：与 D-1 同类风险（缺默认值 → 锁存器推断）
        csr_addr_o   = 12'h0;
        csr_we_o     = 1'b0;
        csr_op_o     = 2'b00;
        csr_imm_o    = 1'b0;
        csr_uimm_o   = 32'h0;
        sys_ecall_o  = 1'b0;
        sys_ebreak_o = 1'b0;
        sys_mret_o   = 1'b0;
        uses_rs1_o   = 1'b0;
        uses_rs2_o   = 1'b0;
        // D-1 修复：illegal_instr_o 必须在默认区赋值，否则合法指令走正常
        // opcode 分支时该输出不被赋值 -> always @(*) 综合出锁存器，
        // 输出保持上一周期值（陈旧值），行为依赖历史。
        illegal_instr_o = 1'b0;

        opcode_o = opcode;
        funct3_o     = funct3;
        funct7_o     = funct7;
        rd_o         = rd;

        // 预测元数据透传
        pred_valid_o  = pred_valid_i;
        pred_taken_o  = pred_taken_i;
        pred_target_o = pred_target_i;

        // 指令无效或 fetch_fault 时输出空操作（IC-BLOCK-005）
        if (inst_valid_i == 1'b0 || fault_i == 1'b1) begin
            // 所有控制保持默认（空泡）
            // 对于 fault，pred_valid 也必须清空（不训练预测器）
            pred_valid_o  = 1'b0;
            illegal_instr_o = 1'b0;
            pred_taken_o  = 1'b0;
            pred_target_o = 32'h0;
        
        // illegal 指令：不写寄存器、不访存、不跳转、不训练预测器（IC-BLOCK-005）
        end else if (illegal == 1'b1) begin
            illegal_instr_o = 1'b1;
            reg_we_o     = 1'b0;
            rd_addr_o    = 5'h0;
            mem_req_o    = 1'b0;
            mem_we_o     = 1'b0;
            mem_wstrb_o  = 4'b0000;
            branch_o     = 1'b0;
            jal_o        = 1'b0;
            jalr_o       = 1'b0;
            lui_o        = 1'b0;
            auipc_o      = 1'b0;
            pred_valid_o  = 1'b0;
            pred_taken_o  = 1'b0;
            pred_target_o = 32'h0;
            uses_rs1_o   = 1'b0;
            uses_rs2_o   = 1'b0;

        end else begin
            case (opcode)
                7'b0010011: begin  // I 型
                    reg_we_o    = 1'b1;
                    rd_addr_o   = rd;
                    rs1_addr_o  = rs1;
                    imm_o       = imm_i;
                    uses_rs1_o  = 1'b1;
                end

                7'b0000011: begin  // L 型
                    reg_we_o    = 1'b1;
                    rd_addr_o   = rd;
                    rs1_addr_o  = rs1;
                    imm_o       = imm_i;
                    mem_req_o   = 1'b1;
                    mem_we_o    = 1'b0;
                    uses_rs1_o  = 1'b1;
                    case (funct3)
                        3'b000:   mem_wstrb_o = 4'b0001;
                        3'b001:   mem_wstrb_o = 4'b0011;
                        3'b010:   mem_wstrb_o = 4'b1111;
                        3'b100:   mem_wstrb_o = 4'b0001;
                        3'b101:   mem_wstrb_o = 4'b0011;
                        default:    mem_wstrb_o = 4'b1111;
                    endcase
                end

                7'b0100011: begin  // S 型
                    reg_we_o    = 1'b0;
                    rd_addr_o   = 5'h0;
                    rs1_addr_o  = rs1;
                    rs2_addr_o  = rs2;
                    imm_o       = imm_s;
                    mem_req_o   = 1'b1;
                    mem_we_o    = 1'b1;
                    uses_rs1_o  = 1'b1;
                    uses_rs2_o  = 1'b1;
                    case (funct3)
                        3'b000:   mem_wstrb_o = 4'b0001;
                        3'b001:   mem_wstrb_o = 4'b0011;
                        3'b010:   mem_wstrb_o = 4'b1111;
                        default:    mem_wstrb_o = 4'b1111;
                    endcase
                end

                7'b0110011: begin  // R 型
                    reg_we_o    = 1'b1;
                    rd_addr_o   = rd;
                    rs1_addr_o  = rs1;
                    rs2_addr_o  = rs2;
                    uses_rs1_o  = 1'b1;
                    uses_rs2_o  = 1'b1;
                end

                7'b1100011: begin  // B 型
                    reg_we_o    = 1'b0;
                    rd_addr_o   = 5'h0;
                    rs1_addr_o  = rs1;
                    rs2_addr_o  = rs2;
                    imm_o       = imm_b;
                    branch_o    = 1'b1;
                    uses_rs1_o  = 1'b1;
                    uses_rs2_o  = 1'b1;
                end

                7'b1101111: begin  // JAL
                    reg_we_o    = 1'b1;
                    rd_addr_o   = rd;
                    rs1_addr_o  = 5'h0;
                    rs2_addr_o  = 5'h0;
                    imm_o       = imm_j;
                    jal_o       = 1'b1;
                end

                7'b1100111: begin  // JALR
                    reg_we_o    = 1'b1;
                    rd_addr_o   = rd;
                    rs1_addr_o  = rs1;
                    rs2_addr_o  = 5'h0;
                    imm_o       = imm_i;
                    jalr_o      = 1'b1;
                    uses_rs1_o  = 1'b1;
                end

                7'b0110111: begin  // LUI
                    reg_we_o    = 1'b1;
                    rd_addr_o   = rd;
                    rs1_addr_o  = 5'h0;
                    rs2_addr_o  = 5'h0;
                    imm_o       = imm_u;
                    lui_o       = 1'b1;
                end

                7'b0010111: begin  // AUIPC
                    reg_we_o    = 1'b1;
                    rd_addr_o   = rd;
                    rs1_addr_o  = 5'h0;
                    rs2_addr_o  = 5'h0;
                    imm_o       = imm_u;
                    auipc_o     = 1'b1;
                end

                7'b1110011: begin  // SYSTEM：CSR 读写 / ECALL / EBREAK / MRET
                    if (sys_priv_legal) begin
                        // ECALL/EBREAK/MRET：无 rd 写、不访存、不跳转。
                        // 批 (a) 只完成译码（不产生架构效果）；陷阱进入与 mret
                        // 重定向在批 (b)/(c) 接入——在此之前它们以空操作退休，
                        // 这一点在 tb_cpu_core_csr 中被显式断言（不是"已支持异常"）。
                        sys_ecall_o  = sys_ecall;
                        sys_ebreak_o = sys_ebreak;
                        sys_mret_o   = sys_mret;
                    end else begin
                        // CSR 类：结果由 csr_rdata 提供（读端口见 cpu_core_stage1），
                        // 故这里只给出 reg_we/rd 与 CSR 操作描述。
                        reg_we_o   = 1'b1;
                        rd_addr_o  = rd;
                        rs1_addr_o = rs1;
                        // 立即数形式的 rs1 域是 uimm（不读寄存器）→ uses_rs1=0，
                        // 从而不参与 load-use/CSR-use 冒险判定。
                        uses_rs1_o = ~csr_is_imm;
                        csr_addr_o = sys_imm12;
                        csr_we_o   = csr_write_intent;
                        csr_op_o   = csr_op_sel;
                        csr_imm_o  = csr_is_imm;
                        csr_uimm_o = {27'b0, rs1};
                    end
                end

                default: begin
                    // 非实现指令：不写寄存器，视为非法（由全局异常处理）
                    // 同时清空 pred_* 防止误训练预测器
                    reg_we_o    = 1'b0;
                    rd_addr_o   = 5'h0;
                    rs1_addr_o  = 5'h0;
                    rs2_addr_o  = 5'h0;
                    pred_valid_o = 1'b0;
                    illegal_instr_o = 1'b0;
                    pred_taken_o = 1'b0;
                    pred_target_o = 32'h0;
                end
            endcase
        end
    end

endmodule
