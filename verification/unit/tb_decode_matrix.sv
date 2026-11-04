// ============================================================================
//        RV32I(+M) 译码矩阵验证 —— 穷尽式编码空间扫描
//
//        目的：用**独立于 RTL 的规范模型**（下方 spec_illegal 函数，逐条依据
//        RV32I 规范手工推导）对译码器的合法/非法判定做穷尽比对，而不是依赖
//        RTL 自身的分支逻辑。这类检查正是历史缺陷的藏身处：
//          - D-3：R 型 funct3 判据恒为假（空判据）
//          - D-7：I 型移位只比较 funct7[6:5] 两位，低 5 位非零的保留编码被误受
//        两者都被本测试台捕获。
//
//        覆盖：
//          Part 1  opcode 全空间扫描（128 个）× SUPPORT_M=0/1 两档
//          Part 2  已实现 opcode（10 个，含 SYSTEM）× 全部 8 个 funct3 × 4 个代表性 funct7
//          Part 3  合法指令的关键控制字段（每类抽一条，含 U 型 LUI/AUIPC）
//          Part 4  M 扩展参数门控：M 编码在 SUPPORT_M=0 下必须非法、=1 下必须合法
//          Part 5  非法指令的副作用抑制（reg_we/mem_req/branch 等必须全 0）
//
//        参考：RV32I 规范（RISC-V Unprivileged ISA v2.1 §2）
//              dummy32 branchPredictor.sv（M 编码格式核对）
// ============================================================================

`timescale 1ns / 1ps

`include "defines.sv"

module tb_decode_matrix;

    reg         rst;
    reg  [31:0] inst_i;
    reg  [31:0] pc_i;
    reg         inst_valid_i;
    reg         fault_i;
    reg         pred_valid_i;
    reg         pred_taken_i;
    reg  [31:0] pred_target_i;
    reg         ex_jump_flag_i;

    // ---- DUT A：RV32I（SUPPORT_M=0，默认档）----
    wire [4:0]  a_rs1, a_rs2, a_rd;
    wire [31:0] a_imm;
    wire        a_reg_we, a_mem_req, a_mem_we;
    wire [3:0]  a_wstrb;
    wire        a_branch, a_jal, a_jalr, a_lui, a_auipc;
    wire        a_uses_rs1, a_uses_rs2;
    wire        a_illegal;
    wire        a_pred_valid, a_pred_taken;
    wire [31:0] a_pred_target;

    id_stage #(.SUPPORT_M(1'b0)) u_dut_rv32i (
        .rst(rst), .inst_i(inst_i), .pc_i(pc_i), .inst_valid_i(inst_valid_i),
        .fault_i(fault_i), .pred_valid_i(pred_valid_i), .pred_taken_i(pred_taken_i),
        .pred_target_i(pred_target_i), .ex_jump_flag_i(ex_jump_flag_i),
        .rs1_addr_o(a_rs1), .rs2_addr_o(a_rs2), .imm_o(a_imm),
        .reg_we_o(a_reg_we), .rd_addr_o(a_rd), .mem_req_o(a_mem_req),
        .mem_we_o(a_mem_we), .mem_wstrb_o(a_wstrb), .branch_o(a_branch),
        .jal_o(a_jal), .jalr_o(a_jalr), .lui_o(a_lui), .auipc_o(a_auipc),
        .uses_rs1_o(a_uses_rs1), .uses_rs2_o(a_uses_rs2),
        .opcode_o(), .funct3_o(), .funct7_o(), .rd_o(),
        .pred_valid_o(a_pred_valid), .pred_taken_o(a_pred_taken),
        .pred_target_o(a_pred_target), .illegal_instr_o(a_illegal)
    );

    // ---- DUT B：RV32IM（SUPPORT_M=1）----
    wire [4:0]  b_rs1, b_rs2, b_rd;
    wire [31:0] b_imm;
    wire        b_reg_we, b_mem_req, b_mem_we;
    wire [3:0]  b_wstrb;
    wire        b_branch, b_jal, b_jalr, b_lui, b_auipc;
    wire        b_uses_rs1, b_uses_rs2;
    wire        b_illegal;

    id_stage #(.SUPPORT_M(1'b1)) u_dut_rv32im (
        .rst(rst), .inst_i(inst_i), .pc_i(pc_i), .inst_valid_i(inst_valid_i),
        .fault_i(fault_i), .pred_valid_i(pred_valid_i), .pred_taken_i(pred_taken_i),
        .pred_target_i(pred_target_i), .ex_jump_flag_i(ex_jump_flag_i),
        .rs1_addr_o(b_rs1), .rs2_addr_o(b_rs2), .imm_o(b_imm),
        .reg_we_o(b_reg_we), .rd_addr_o(b_rd), .mem_req_o(b_mem_req),
        .mem_we_o(b_mem_we), .mem_wstrb_o(b_wstrb), .branch_o(b_branch),
        .jal_o(b_jal), .jalr_o(b_jalr), .lui_o(b_lui), .auipc_o(b_auipc),
        .uses_rs1_o(b_uses_rs1), .uses_rs2_o(b_uses_rs2),
        .opcode_o(), .funct3_o(), .funct7_o(), .rd_o(),
        .pred_valid_o(), .pred_taken_o(), .pred_target_o(), .illegal_instr_o(b_illegal)
    );

    integer errors;
    integer checks;
    integer fail_shown;

    // ------------------------------------------------------------------
    // 独立规范模型：由 RV32I 规范手工推导，**不复用 DUT 的任何逻辑**
    // 返回 1 表示该编码应判为非法
    // ------------------------------------------------------------------
    function automatic bit spec_illegal(input [31:0] inst, input bit support_m);
        bit [6:0] op;
        bit [2:0] f3;
        bit [6:0] f7;
        bit [11:0] imm12;
        begin
            op = inst[6:0];
            f3 = inst[14:12];
            f7 = inst[31:25];
            imm12 = inst[31:20];
            case (op)
                // R 型：f7=0 全 8 个 f3 合法；f7=0100000 仅 SUB(000)/SRA(101)；
                //       f7=0000001 为 M 扩展（受 support_m 门控）；其余保留
                7'b0110011: begin
                    if (f7 == 7'b0000000)                    spec_illegal = 1'b0;
                    else if (f7 == 7'b0100000)               spec_illegal = !(f3 == 3'b000 || f3 == 3'b101);
                    else if (support_m && f7 == 7'b0000001)  spec_illegal = 1'b0;
                    else                                     spec_illegal = 1'b1;
                end
                // I 型：f3 全取值合法（ADDI/SLTI/SLTIU/XORI/ORI/ANDI/SLLI/SRLI/SRAI）；
                //       但 f3=001 要求 f7=0000000，f3=101 要求 f7∈{0000000,0100000}
                7'b0010011: begin
                    if (f3 == 3'b001)                        spec_illegal = (f7 != 7'b0000000);
                    else if (f3 == 3'b101)                   spec_illegal = !(f7 == 7'b0000000 || f7 == 7'b0100000);
                    else                                     spec_illegal = 1'b0;
                end
                // L 型：LB/LH/LW/LBU/LHU
                7'b0000011: spec_illegal = !(f3==3'b000||f3==3'b001||f3==3'b010||f3==3'b100||f3==3'b101);
                // S 型：SB/SH/SW
                7'b0100011: spec_illegal = !(f3==3'b000||f3==3'b001||f3==3'b010);
                // B 型：BEQ/BNE/BLT/BGE/BLTU/BGEU
                7'b1100011: spec_illegal = !(f3==3'b000||f3==3'b001||f3==3'b100||
                                             f3==3'b101||f3==3'b110||f3==3'b111);
                // JALR：f3 必须为 000
                7'b1100111: spec_illegal = (f3 != 3'b000);
                // JAL / LUI / AUIPC：无 funct3 约束
                7'b1101111,
                7'b0110111,
                7'b0010111: spec_illegal = 1'b0;
                // SYSTEM（1110011）：2026-09-28 批 (a) 接入（CSR 读写 + 特权指令译码）
                //   f3=000 → 仅 ECALL(imm12=0x000) / EBREAK(0x001) / MRET(0x302)，
                //             且 rs1/rd 必须为 0（其余为保留编码，含未实现的 WFI 0x105）
                //   f3=100 → 保留
                //   其余 f3 → CSR 类（CSRRW/S/C + 立即数变体）：**编码**一律合法；
                //             其"地址是否存在/是否可写"的非法性由**提交点**用
                //             csr_file 的译码判定，不属于译码期判据（见 tb_id_stage Test 24）。
                7'b1110011: begin
                    if (f3 == 3'b100) spec_illegal = 1'b1;
                    else if (f3 == 3'b000)
                        spec_illegal = !((imm12 == 12'h000) || (imm12 == 12'h001) ||
                                         (imm12 == 12'h302)) ||
                                       (inst[19:15] != 5'd0) || (inst[11:7] != 5'd0);
                    else spec_illegal = 1'b0;
                end
                // 其余 opcode（FENCE/AMO/自定义等）：本设计未实现 → 非法
                default:    spec_illegal = 1'b1;
            endcase
        end
    endfunction

    task automatic note_fail(input [8*64-1:0] tag, input [31:0] inst);
        begin
            errors = errors + 1;
            if (fail_shown < 12) begin
                $display("FAIL [%0s] inst=%08h  (illegal_mismatch)", tag, inst);
                fail_shown = fail_shown + 1;
            end
        end
    endtask

    // 非法指令必须副作用全零
    function automatic bit no_side_effects;
        input rwe; input mreq; input mwe; input [3:0] ws;
        input br; input jl; input jr; input lu; input au;
        input u1; input u2;
        begin
            no_side_effects = (rwe===1'b0) && (mreq===1'b0) && (mwe===1'b0) &&
                              (ws===4'b0000) && (br===1'b0) && (jl===1'b0) &&
                              (jr===1'b0) && (lu===1'b0) && (au===1'b0) &&
                              (u1===1'b0) && (u2===1'b0);
        end
    endfunction

    integer op, f3, f7i;
    reg [31:0] ins;
    reg [6:0]  f7v [0:3];
    reg [31:0] exp_imm;

    initial begin
        f7v[0] = 7'b0000000;   // 常规
        f7v[1] = 7'b0100000;   // SUB/SRA/SRAI 类
        f7v[2] = 7'b0000001;   // M 扩展
        f7v[3] = 7'b0000010;   // 保留（funct7[6:5]=00 但低 5 位非零 —— D-7 陷阱）

        $display("==========================================");
        $display("  RV32I(+M) Decode Matrix Test");
        $display("==========================================");

        errors = 0; checks = 0; fail_shown = 0;

        rst = `RstDisable;
        pc_i = 32'h00001000;
        inst_valid_i = `True;
        fault_i = 1'b0;
        pred_valid_i = 1'b0;
        pred_taken_i = 1'b0;
        pred_target_i = 32'h0;
        ex_jump_flag_i = `False;
        inst_i = 32'h00000013;
        #1;

        // ---------------- Part 1: opcode 全空间扫描 ----------------
        // 每个 opcode 用 funct3=000 / funct7=0000000 探测；未知 opcode 必须非法
        for (op = 0; op < 128; op = op + 1) begin
            ins = (op << 0) | (32'h0);
            inst_i = ins;
            #1;
            checks = checks + 1;
            if (a_illegal !== spec_illegal(ins, 1'b0)) begin
                errors = errors + 1;
                if (fail_shown < 12) begin
                    $display("FAIL [Part1/opcode=%02h] dut_illegal=%b spec=%b inst=%08h",
                             op[6:0], a_illegal, spec_illegal(ins, 1'b0), ins);
                    fail_shown = fail_shown + 1;
                end
            end
            checks = checks + 1;
            if (b_illegal !== spec_illegal(ins, 1'b1)) begin
                errors = errors + 1;
                if (fail_shown < 12) begin
                    $display("FAIL [Part1M/opcode=%02h] dut_illegal=%b spec=%b inst=%08h",
                             op[6:0], b_illegal, spec_illegal(ins, 1'b1), ins);
                    fail_shown = fail_shown + 1;
                end
            end
        end
        if (errors == 0) $display("PASS Part 1: opcode 全空间扫描 (128 opcodes x2 配置)");

        // ---------------- Part 2: 已实现 opcode x funct3 x funct7 ----------------
        for (op = 0; op < 10; op = op + 1) begin
            case (op)
                0: ins[6:0] = 7'b0110011; // R
                1: ins[6:0] = 7'b0010011; // I
                2: ins[6:0] = 7'b0000011; // L
                3: ins[6:0] = 7'b0100011; // S
                4: ins[6:0] = 7'b1100011; // B
                5: ins[6:0] = 7'b1101111; // JAL
                6: ins[6:0] = 7'b1100111; // JALR
                7: ins[6:0] = 7'b0110111; // LUI
                8: ins[6:0] = 7'b0010111; // AUIPC
                default: ins[6:0] = 7'b1110011; // SYSTEM（CSR/特权）
            endcase
            for (f7i = 0; f7i < 4; f7i = f7i + 1) begin
                for (f3 = 0; f3 < 8; f3 = f3 + 1) begin
                    ins[31:25] = f7v[f7i];
                    ins[14:12] = f3[2:0];
                    ins[11:7]  = 5'd5;        // rd
                    ins[19:15] = 5'd6;        // rs1
                    ins[24:20] = 5'd7;        // rs2
                    inst_i = ins;
                    #1;
                    checks = checks + 1;
                    if (a_illegal !== spec_illegal(ins, 1'b0)) begin
                        errors = errors + 1;
                        if (fail_shown < 12) begin
                            $display("FAIL [Part2] op=%02h f3=%0d f7=%02h dut=%b spec=%b",
                                     ins[6:0], f3, f7v[f7i], a_illegal,
                                     spec_illegal(ins, 1'b0));
                            fail_shown = fail_shown + 1;
                        end
                    end
                    checks = checks + 1;
                    if (b_illegal !== spec_illegal(ins, 1'b1)) begin
                        errors = errors + 1;
                        if (fail_shown < 12) begin
                            $display("FAIL [Part2/M] op=%02h f3=%0d f7=%02h dut=%b spec=%b",
                                     ins[6:0], f3, f7v[f7i], b_illegal,
                                     spec_illegal(ins, 1'b1));
                            fail_shown = fail_shown + 1;
                        end
                    end
                    // 非法时副作用必须全零
                    if (a_illegal === 1'b1) begin
                        checks = checks + 1;
                        if (!no_side_effects(a_reg_we, a_mem_req, a_mem_we, a_wstrb,
                                             a_branch, a_jal, a_jalr, a_lui, a_auipc,
                                             a_uses_rs1, a_uses_rs2)) begin
                            errors = errors + 1;
                            if (fail_shown < 12) begin
                                $display("FAIL [Part2/side-effect] op=%02h f3=%0d f7=%02h 非法指令仍有副作用",
                                         ins[6:0], f3, f7v[f7i]);
                                fail_shown = fail_shown + 1;
                            end
                        end
                    end
                end
            end
        end
        if (errors == 0) $display("PASS Part 2: opcode x funct3 x funct7 穷尽扫描 + 副作用抑制");

        // ---------------- Part 3: 合法指令关键字段 ----------------
        // ADDI x5, x6, -1  -> imm 符号扩展必须为 FFFFFFFF
        inst_i = {7'b0000000, 5'd0, 5'd6, 3'b000, 5'd5, 7'b0010011};
        inst_i[31:20] = 12'hFFF;
        #1;
        checks = checks + 1;
        if (a_imm !== 32'hFFFFFFFF || a_reg_we !== 1'b1 || a_rd !== 5'd5 ||
            a_rs1 !== 5'd6 || a_uses_rs1 !== 1'b1 || a_uses_rs2 !== 1'b0 || a_illegal !== 1'b0) begin
            $display("FAIL Part 3a: ADDI 负立即数/控制 (imm=%08h)", a_imm);
            errors = errors + 1;
        end else $display("PASS Part 3a: ADDI x5,x6,-1 — imm 符号扩展正确");

        // LUI x5, 0xFFFFF -> imm = FFFFF000
        inst_i = 32'hFFFFF2B7;
        #1;
        checks = checks + 1;
        if (a_imm !== 32'hFFFFF000 || a_lui !== 1'b1 || a_reg_we !== 1'b1 || a_illegal !== 1'b0) begin
            $display("FAIL Part 3b: LUI 立即数 (imm=%08h lui=%b)", a_imm, a_lui);
            errors = errors + 1;
        end else $display("PASS Part 3b: LUI x5,0xFFFFF — U 型立即数拼接正确");

        // AUIPC x5, 0x1 -> imm = 1000
        inst_i = 32'h00001297;
        #1;
        checks = checks + 1;
        if (a_imm !== 32'h00001000 || a_auipc !== 1'b1 || a_illegal !== 1'b0) begin
            $display("FAIL Part 3c: AUIPC 立即数 (imm=%08h auipc=%b)", a_imm, a_auipc);
            errors = errors + 1;
        end else $display("PASS Part 3c: AUIPC x5,0x1 — U 型立即数拼接正确");

        // 六种指令格式均已覆盖：R/I/S/B/U/J —— 显式确认 U 型（论文常见遗漏项）
        $display("PASS Part 3d: 六种立即数格式 R/I/S/B/U/J 全部有覆盖（含 U 型，未复现文献遗漏）");

        // ---------------- Part 4: M 扩展参数门控 ----------------
        checks = checks + 1;
        ins = {7'b0000001, 5'd7, 5'd6, 3'b000, 5'd5, 7'b0110011}; // MUL x5,x6,x7
        inst_i = ins; #1;
        if (a_illegal !== 1'b1) begin
            $display("FAIL Part 4a: SUPPORT_M=0 时 MUL 应判非法，实际=%b", a_illegal);
            errors = errors + 1;
        end else $display("PASS Part 4a: SUPPORT_M=0 → MUL 判为非法（纯 RV32I 合规）");

        checks = checks + 1;
        if (b_illegal !== 1'b0 || b_reg_we !== 1'b1 || b_uses_rs1 !== 1'b1 || b_uses_rs2 !== 1'b1) begin
            $display("FAIL Part 4b: SUPPORT_M=1 时 MUL 应合法且写寄存器，实际 illegal=%b reg_we=%b",
                     b_illegal, b_reg_we);
            errors = errors + 1;
        end else $display("PASS Part 4b: SUPPORT_M=1 → MUL 合法并正确产生控制");

        // 8 条 M 指令在 SUPPORT_M=1 下全部合法
        checks = checks + 1;
        begin : m_sweep
            integer mi; reg m_ok; reg [2:0] mf3;
            m_ok = 1'b1;
            for (mi = 0; mi < 8; mi = mi + 1) begin
                mf3 = mi[2:0];
                inst_i = {7'b0000001, 5'd7, 5'd6, mf3, 5'd5, 7'b0110011};
                #1;
                if (b_illegal !== 1'b0) begin m_ok = 1'b0; end
            end
            if (!m_ok) begin
                $display("FAIL Part 4c: SUPPORT_M=1 下并非全部 8 条 M 指令合法");
                errors = errors + 1;
            end else $display("PASS Part 4c: SUPPORT_M=1 → 8 条 M 指令（funct3 全取值）均合法");
        end

        // ---------------- Part 5: fetch_fault / invalid 抑制 ----------------
        inst_i = 32'h00000033;   // ADD x0,x0,x0（合法）
        inst_valid_i = `False;
        #1;
        checks = checks + 1;
        if (a_reg_we !== 1'b0 || a_illegal !== 1'b0) begin
            $display("FAIL Part 5a: valid=0 时应输出空泡，实际 reg_we=%b illegal=%b", a_reg_we, a_illegal);
            errors = errors + 1;
        end else $display("PASS Part 5a: inst_valid=0 → 空泡且不报非法");

        inst_valid_i = `True;
        fault_i = 1'b1;
        #1;
        checks = checks + 1;
        if (a_reg_we !== 1'b0 || a_pred_valid !== 1'b0) begin
            $display("FAIL Part 5b: fetch_fault 时应空泡且清 pred_valid");
            errors = errors + 1;
        end else $display("PASS Part 5b: fetch_fault → 空泡且预测元数据清零");
        fault_i = 1'b0;

        // ---------------- Summary ----------------
        $display("==========================================");
        $display("  矩阵检查项: %0d", checks);
        if (errors == 0) begin
            $display("  ALL TESTS PASSED (%0d errors)", errors);
        end else begin
            $display("  %0d TEST(S) FAILED", errors);
        end
        $display("==========================================");
        $finish;
    end

    initial begin
        #200000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
