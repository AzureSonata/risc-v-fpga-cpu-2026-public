// ============================================================================
//        RV32I 译码器 — 单元测试
//        覆盖：I/L/S/R/B/JAL/JALR/LUI/AUIPC + 立即数类型 + x0
// ============================================================================

`timescale 1ns / 1ps

`include "defines.sv"

module tb_id_stage;

    reg         rst;
    reg  [31:0] inst_i;
    reg  [31:0] pc_i;
    reg         inst_valid_i;
    reg         ex_jump_flag_i;
    reg         fault_i;
    reg         pred_valid_i;
    reg         pred_taken_i;
    reg  [31:0] pred_target_i;

    wire        illegal_instr_o;

    wire [4:0]  rs1_addr_o;
    wire [4:0]  rs2_addr_o;
    wire [31:0] imm_o;
    wire        reg_we_o;
    wire [4:0]  rd_addr_o;
    wire        mem_req_o;
    wire        mem_we_o;
    wire [3:0]  mem_wstrb_o;
    wire        branch_o;
    wire        jal_o;
    wire        jalr_o;
    wire        lui_o;
    wire        auipc_o;
    wire        uses_rs1_o;
    wire        uses_rs2_o;
    wire [6:0]  opcode_o;
    wire [2:0]  funct3_o;
    wire [6:0]  funct7_o;
    wire [4:0]  rd_o;

    // SYSTEM 类译码输出（批 (a)）
    wire [11:0] csr_addr_o;
    wire        csr_we_o;
    wire [1:0]  csr_op_o;
    wire        csr_imm_o;
    wire [31:0] csr_uimm_o;
    wire        sys_ecall_o, sys_ebreak_o, sys_mret_o;

    id_stage u_id_stage (
        .rst            (rst),
        .inst_i         (inst_i),
        .pc_i           (pc_i),
        .inst_valid_i   (inst_valid_i),
        .ex_jump_flag_i (ex_jump_flag_i),
        .rs1_addr_o     (rs1_addr_o),
        .rs2_addr_o     (rs2_addr_o),
        .imm_o          (imm_o),
        .reg_we_o       (reg_we_o),
        .rd_addr_o      (rd_addr_o),
        .mem_req_o      (mem_req_o),
        .mem_we_o       (mem_we_o),
        .mem_wstrb_o    (mem_wstrb_o),
        .branch_o       (branch_o),
        .jal_o          (jal_o),
        .jalr_o         (jalr_o),
        .lui_o          (lui_o),
        .auipc_o        (auipc_o),
        .uses_rs1_o     (uses_rs1_o),
        .uses_rs2_o     (uses_rs2_o),
        .opcode_o       (opcode_o),
        .funct3_o       (funct3_o),
        .funct7_o       (funct7_o),
.rd_o           (rd_o),
        .fault_i        (fault_i),
        .pred_valid_i   (pred_valid_i),
        .pred_taken_i   (pred_taken_i),
        .pred_target_i  (pred_target_i),
        .illegal_instr_o(illegal_instr_o),
        .csr_addr_o     (csr_addr_o),
        .csr_we_o       (csr_we_o),
        .csr_op_o       (csr_op_o),
        .csr_imm_o      (csr_imm_o),
        .csr_uimm_o     (csr_uimm_o),
        .sys_ecall_o    (sys_ecall_o),
        .sys_ebreak_o   (sys_ebreak_o),
        .sys_mret_o     (sys_mret_o)
    );

    // 新用例的逐字段核对：任一字段不符即记一次 FAIL（每个用例只打印一行 PASS）
    integer errors_before;
    // ⚠️ 坑位（§7.19）：`errors` 原先声明在下面的任务**之后**，而任务体里已经 `errors = errors + 1;`
    //   ⇒ 先用后声明。Icarus 10.2 容忍、**13.0 编译失败**。声明必须提到所有使用之前。
    integer errors;
    task chk_field(input [255:0] nm, input [31:0] got, input [31:0] want);
        begin
            if (got !== want) begin
                errors = errors + 1;
                $display("FAIL %0s: got=%08h want=%08h", nm, got, want);
            end
        end
    endtask

    initial begin
        $display("==========================================");
        $display("  RV32I Decoder Unit Test");
        $display("==========================================");
        errors = 0;

        rst = `RstDisable;
        inst_i = 32'h0;
        pc_i = 32'h00001000;
        inst_valid_i = `True;
        ex_jump_flag_i = `False;

        // Allow combinational logic to settle
        #1;

        // ---- Test 1: Invalid instruction (valid=0) ----
        inst_valid_i = `False;
        #1;
        if (reg_we_o !== `WriteDisable || branch_o !== `JumpDisable) begin
            $display("FAIL Test 1: Invalid instruction — control not zeroed");
            errors = errors + 1;
        end else begin
            $display("PASS Test 1: Invalid instruction output zeroed");
        end
        inst_valid_i = `True;

        // ---- Test 2: ADDI (I-type) ----
        // ADDI x1, x2, 0x7FF   (inst = 0x7FF10093)
        // opcode=0010011, rd=00001, funct3=000, rs1=00010, imm=0x7FF
        inst_i = 32'h7FF10093;
        #1;
        if (reg_we_o !== `WriteEnable)        $display("FAIL Test 2a: ADDI reg_we");
        else if (rd_addr_o !== 5'd1)           $display("FAIL Test 2b: ADDI rd");
        else if (rs1_addr_o !== 5'd2)          $display("FAIL Test 2c: ADDI rs1");
        else if (imm_o !== 32'h000007FF)       $display("FAIL Test 2d: ADDI imm");
        else if (uses_rs1_o !== `True)         $display("FAIL Test 2e: ADDI uses_rs1");
        else if (uses_rs2_o !== `False)        $display("FAIL Test 2f: ADDI uses_rs2");
        else if (mem_req_o !== `ReadDisable)   $display("FAIL Test 2g: ADDI mem_req");
        else $display("PASS Test 2: ADDI x1, x2, 0x7FF — imm=%08h", imm_o);

        // ---- Test 3: ADDI with negative immediate ----
        // ADDI x3, x4, -1 (imm=0xFFF)
        // inst = 0xFFF20193, rd=00011, rs1=00100
        inst_i = 32'hFFF20193;
        #1;
        if (imm_o !== 32'hFFFFFFFF) begin
            $display("FAIL Test 3: ADDI negative imm — expected FFFFFFFF, got %08h", imm_o);
            errors = errors + 1;
        end else begin
            $display("PASS Test 3: ADDI x3, x4, -1 — imm=%08h", imm_o);
        end

        // ---- Test 4: LW (load word) ----
        // LW x5, 0x100(x6)  (inst = 0x10032283)
        // opcode=0000011, rd=00101, funct3=010, rs1=00110, imm=0x100
        inst_i = 32'h10032283;
        #1;
        if (reg_we_o !== `WriteEnable)        $display("FAIL Test 4a: LW reg_we");
        else if (rd_addr_o !== 5'd5)           $display("FAIL Test 4b: LW rd");
        else if (mem_req_o !== `ReadEnable)    $display("FAIL Test 4c: LW mem_req");
        else if (mem_we_o !== `WriteDisable)   $display("FAIL Test 4d: LW mem_we");
        else if (mem_wstrb_o !== 4'b1111)      $display("FAIL Test 4e: LW wstrb");
        else if (uses_rs1_o !== `True)         $display("FAIL Test 4f: LW uses_rs1");
        else $display("PASS Test 4: LW x5, 0x100(x6) — imm=%08h, wstrb=%b", imm_o, mem_wstrb_o);

        // ---- Test 5: SW (store word) ----
        // SW x7, 0x200(x8)  (inst = 0x20742223)
        // opcode=0100011, imm[11:5]=0010000, rs2=00111, rs1=01000, funct3=010, imm[4:0]=00010
        // = 0100011 | 00010 | 010 | 01000 | 00111 | 0010000
        // = 0x20742223
        inst_i = 32'h20742223;
        #1;
        if (reg_we_o !== `WriteDisable)       $display("FAIL Test 5a: SW reg_we");
        else if (mem_req_o !== `ReadEnable)    $display("FAIL Test 5b: SW mem_req");
        else if (mem_we_o !== `WriteEnable)    $display("FAIL Test 5c: SW mem_we");
        else if (mem_wstrb_o !== 4'b1111)      $display("FAIL Test 5d: SW wstrb");
        else if (rs1_addr_o !== 5'd8)          $display("FAIL Test 5e: SW rs1");
        else if (rs2_addr_o !== 5'd7)          $display("FAIL Test 5f: SW rs2");
        else if (uses_rs2_o !== `True)         $display("FAIL Test 5g: SW uses_rs2");
        else $display("PASS Test 5: SW x7, 0x200(x8) — imm=%08h", imm_o);

        // ---- Test 6: ADD (R-type) ----
        // ADD x9, x10, x11  (inst = 0x00B504B3)
        // opcode=0110011, rd=01001, funct3=000, rs1=01010, rs2=01011, funct7=0000000
        // = 0000000 | 01011 | 01010 | 000 | 01001 | 0110011
        inst_i = 32'h00B504B3;
        #1;
        if (reg_we_o !== `WriteEnable)        $display("FAIL Test 6a: ADD reg_we");
        else if (rd_addr_o !== 5'd9)           $display("FAIL Test 6b: ADD rd");
        else if (rs1_addr_o !== 5'd10)         $display("FAIL Test 6c: ADD rs1");
        else if (rs2_addr_o !== 5'd11)         $display("FAIL Test 6d: ADD rs2");
        else if (uses_rs2_o !== `True)         $display("FAIL Test 6e: ADD uses_rs2");
        else $display("PASS Test 6: ADD x9, x10, x11");

        // ---- Test 7: BEQ (branch) ----
        // BEQ x12, x13, +0x010  (inst = 0x00D60463)
        // opcode=1100011, imm[12|10:5]=0_000001, rs2=01101, rs1=01100, funct3=000, imm[4:1|11]=0000_0
        // = 0_000001 | 01101 | 01100 | 000 | 0000_0 | 1100011
        inst_i = 32'h00D60463;
        #1;
        if (branch_o !== `JumpEnable)          $display("FAIL Test 7a: BEQ branch");
        else if (reg_we_o !== `WriteDisable)   $display("FAIL Test 7b: BEQ reg_we");
        else if (rs1_addr_o !== 5'd12)         $display("FAIL Test 7c: BEQ rs1");
        else if (rs2_addr_o !== 5'd13)         $display("FAIL Test 7d: BEQ rs2");
        else if (uses_rs2_o !== `True)         $display("FAIL Test 7e: BEQ uses_rs2");
        else $display("PASS Test 7: BEQ x12, x13, target — imm=%08h", imm_o);

        // ---- Test 8: JAL ----
        // JAL x1, +0x100  (inst = 0x100000EF)
        // opcode=1101111, rd=00001, imm=0x100
        inst_i = 32'h100000EF;
        #1;
        if (jal_o !== `JumpEnable)             $display("FAIL Test 8a: JAL");
        else if (reg_we_o !== `WriteEnable)    $display("FAIL Test 8b: JAL reg_we");
        else if (rd_addr_o !== 5'd1)           $display("FAIL Test 8c: JAL rd");
        else if (uses_rs1_o !== `False)        $display("FAIL Test 8d: JAL uses_rs1");
        else $display("PASS Test 8: JAL x1, target — imm=%08h", imm_o);

        // ---- Test 9: JALR ----
        // JALR x0, x14, 0  (inst = 0x00070067)
        // opcode=1100111, rd=00000, funct3=000, rs1=01110, imm=0x000
        inst_i = 32'h00070067;
        #1;
        if (jalr_o !== `JumpEnable)            $display("FAIL Test 9a: JALR");
        else if (reg_we_o !== `WriteEnable)    $display("FAIL Test 9b: JALR reg_we");
        else if (rd_addr_o !== 5'd0)           $display("FAIL Test 9c: JALR rd");
        else if (rs1_addr_o !== 5'd14)         $display("FAIL Test 9d: JALR rs1");
        else if (uses_rs1_o !== `True)         $display("FAIL Test 9e: JALR uses_rs1");
        else $display("PASS Test 9: JALR x0, x14, 0 — imm=%08h", imm_o);

        // ---- Test 10: LUI ----
        // LUI x15, 0x12345  (inst = 0x123457B7)
        // opcode=0110111, rd=01111, imm=0x12345000
        inst_i = 32'h123457B7;
        #1;
        if (lui_o !== `True)                   $display("FAIL Test 10a: LUI");
        else if (reg_we_o !== `WriteEnable)    $display("FAIL Test 10b: LUI reg_we");
        else if (rd_addr_o !== 5'd15)          $display("FAIL Test 10c: LUI rd");
        else if (imm_o !== 32'h12345000)        $display("FAIL Test 10d: LUI imm");
        else $display("PASS Test 10: LUI x15, 0x12345 — imm=%08h", imm_o);

        // ---- Test 11: AUIPC ----
        // AUIPC x16, 0x10000  (inst = 0x10000817)
        // opcode=0010111, rd=10000, imm=0x10000000
        inst_i = 32'h10000817;
        #1;
        if (auipc_o !== `True)                 $display("FAIL Test 11a: AUIPC");
        else if (rd_addr_o !== 5'd16)          $display("FAIL Test 11b: AUIPC rd");
        else if (imm_o !== 32'h10000000)        $display("FAIL Test 11c: AUIPC imm");
        else $display("PASS Test 11: AUIPC x16, 0x10000 — imm=%08h", imm_o);

        // ---- Test 12: x0 read (rs1=x0) ----
        // ADDI x0, x0, 0x7FF  (inst = 0x7FF00013, but rd=x0 reg_we should be 1 but skip x0 write)
        inst_i = 32'h7FF00013;  // ADDI x0, x0, 0x7FF
        #1;
        if (rd_addr_o !== 5'd0) begin
            $display("FAIL Test 12a: x0 rd");
            errors = errors + 1;
        end else begin
            $display("PASS Test 12: ADDI x0, x0, 0 — rd=x0");
        end

        // ---- Test 13 (D-1): illegal_instr_o 不得锁存 ----
        // 原本默认赋值区缺少 illegal_instr_o，合法指令走正常 opcode 分支时该输出
        // 不被赋值 -> always @(*) 综合出锁存器，输出保持上一周期的值。
        // 检测手法：先驱动一条非法指令使其为 1，再切到合法指令，
        // 组合逻辑必须当拍把它拉回 0；若锁存则仍为 1。
        inst_i = 32'h00000000;   // opcode=0000000，非任何已实现 opcode
        #1;
        if (illegal_instr_o !== 1'b1) begin
            $display("FAIL Test 13a: illegal encoding not flagged (illegal_instr_o=%b)", illegal_instr_o);
            errors = errors + 1;
        end else begin
            inst_i = 32'h7FF10093;   // ADDI x1, x2, 0x7FF（合法）
            #1;
            if (illegal_instr_o !== 1'b0) begin
                $display("FAIL Test 13b: illegal_instr_o latched across illegal->legal (=%b)", illegal_instr_o);
                errors = errors + 1;
            end else begin
                $display("PASS Test 13: illegal_instr_o not latched across illegal->legal");
            end
        end

        // ---- Test 14 (D-3): R 型 funct7=0100000 的保留 funct3 必须判非法 ----
        // RV32I 规定 funct7=0100000 时仅 SUB(funct3=000) 与 SRA(funct3=101) 合法。
        // 原判据逐一列出全部 8 个 funct3 值 -> 恒为假（空判据），保留编码被误受。
        inst_i = 32'h40001033;   // funct7=0100000, funct3=001 -> 保留编码
        #1;
        if (illegal_instr_o !== 1'b1) begin
            $display("FAIL Test 14a: reserved R-type (funct7=0100000,funct3=001) not flagged");
            errors = errors + 1;
        end else begin
            $display("PASS Test 14: reserved R-type encoding flagged illegal");
        end

        // ---- Test 15 (D-3 回归): 合法的 SUB / SRA 仍必须被接受 ----
        inst_i = 32'h40000033;   // SUB x0, x0, x0（funct7=0100000, funct3=000）
        #1;
        if (illegal_instr_o !== 1'b0 || reg_we_o !== `WriteEnable) begin
            $display("FAIL Test 15a: SUB wrongly rejected (illegal=%b reg_we=%b)", illegal_instr_o, reg_we_o);
            errors = errors + 1;
        end else begin
            inst_i = 32'h40005033;   // SRA x0, x0, x0（funct7=0100000, funct3=101）
            #1;
            if (illegal_instr_o !== 1'b0) begin
                $display("FAIL Test 15b: SRA wrongly rejected");
                errors = errors + 1;
            end else begin
                $display("PASS Test 15: legal SUB/SRA still accepted after funct3 tightening");
            end
        end

        // ================================================================
        //  SYSTEM 类（opcode 1110011）译码 —— 批 (a)：CSR 读写路径 + 特权译码
        //  说明：**CSR 地址合法性（未实现/只读写）不在本单元判定**，见 Test 24。
        // ================================================================

        // ---- Test 16: CSRRW x11, mstatus, x1 ----
        inst_i = 32'h300095F3;
        #1;
        errors_before = errors;
        chk_field("16a csr_addr", {20'b0, csr_addr_o}, 32'h00000300);
        chk_field("16b csr_we", {31'b0, csr_we_o}, 32'd1);
        chk_field("16c csr_op", {30'b0, csr_op_o}, 32'd0);
        chk_field("16d csr_imm", {31'b0, csr_imm_o}, 32'd0);
        chk_field("16e csr_uimm", csr_uimm_o, 32'd1);
        chk_field("16f reg_we", {31'b0, reg_we_o}, 32'd1);
        chk_field("16g rd", {27'b0, rd_addr_o}, 32'd11);
        chk_field("16h rs1", {27'b0, rs1_addr_o}, 32'd1);
        chk_field("16i uses_rs1", {31'b0, uses_rs1_o}, 32'd1);
        chk_field("16j illegal", {31'b0, illegal_instr_o}, 32'd0);
        if (errors == errors_before)
            $display("PASS Test 16: CSRRW x11,mstatus,x1 — addr/we/op/imm/uimm/rd/rs1");

        // ---- Test 17: CSRRS x12, mstatus, x0（rs1=x0 → 无写意图） ----
        inst_i = 32'h30002673;
        #1;
        errors_before = errors;
        chk_field("17a csr_we (rs1=x0)", {31'b0, csr_we_o}, 32'd0);
        chk_field("17b csr_op=set", {30'b0, csr_op_o}, 32'd1);
        chk_field("17c csr_addr", {20'b0, csr_addr_o}, 32'h00000300);
        chk_field("17d reg_we", {31'b0, reg_we_o}, 32'd1);
        chk_field("17e rd", {27'b0, rd_addr_o}, 32'd12);
        chk_field("17f illegal", {31'b0, illegal_instr_o}, 32'd0);
        if (errors == errors_before)
            $display("PASS Test 17: CSRRS x12,mstatus,x0 — reads without write intent");

        // ---- Test 18: CSRRSI x13, mtvec, 0（uimm=0 → 无写意图） ----
        inst_i = 32'h305066F3;
        #1;
        errors_before = errors;
        chk_field("18a csr_imm", {31'b0, csr_imm_o}, 32'd1);
        chk_field("18b csr_we (uimm=0)", {31'b0, csr_we_o}, 32'd0);
        chk_field("18c csr_uimm", csr_uimm_o, 32'd0);
        chk_field("18d uses_rs1=0", {31'b0, uses_rs1_o}, 32'd0);
        chk_field("18e csr_addr", {20'b0, csr_addr_o}, 32'h00000305);
        chk_field("18f rd", {27'b0, rd_addr_o}, 32'd13);
        if (errors == errors_before)
            $display("PASS Test 18: CSRRSI x13,mtvec,0 — immediate form, uimm=0 no write");

        // ---- Test 19: CSRRCI x14, mstatus, 8（清零 + 立即数写） ----
        inst_i = 32'h30047773;
        #1;
        errors_before = errors;
        chk_field("19a csr_op=clear", {30'b0, csr_op_o}, 32'd2);
        chk_field("19b csr_we", {31'b0, csr_we_o}, 32'd1);
        chk_field("19c csr_uimm=8", csr_uimm_o, 32'd8);
        chk_field("19d csr_imm", {31'b0, csr_imm_o}, 32'd1);
        chk_field("19e uses_rs1=0", {31'b0, uses_rs1_o}, 32'd0);
        if (errors == errors_before)
            $display("PASS Test 19: CSRRCI x14,mstatus,8 — clear-immediate encoding");

        // ---- Test 20: CSRRWI 即使 uimm=0 也必须写（写意图与 rs1 域无关） ----
        inst_i = 32'h300052F3;
        #1;
        errors_before = errors;
        chk_field("20a csr_we (RW always)", {31'b0, csr_we_o}, 32'd1);
        chk_field("20b csr_op=write", {30'b0, csr_op_o}, 32'd0);
        chk_field("20c csr_imm", {31'b0, csr_imm_o}, 32'd1);
        chk_field("20d csr_uimm=0", csr_uimm_o, 32'd0);
        chk_field("20e rd", {27'b0, rd_addr_o}, 32'd5);
        if (errors == errors_before)
            $display("PASS Test 20: CSRRWI always has write intent (even uimm=0)");

        // ---- Test 21: ECALL / EBREAK / MRET 译码合法且无副作用 ----
        errors_before = errors;
        inst_i = 32'h00000073;   // ECALL
        #1;
        chk_field("21a ecall flag", {31'b0, sys_ecall_o}, 32'd1);
        chk_field("21b ecall reg_we=0", {31'b0, reg_we_o}, 32'd0);
        chk_field("21c ecall not illegal", {31'b0, illegal_instr_o}, 32'd0);
        chk_field("21d ecall no mem", {31'b0, mem_req_o}, 32'd0);
        inst_i = 32'h00100073;   // EBREAK
        #1;
        chk_field("21e ebreak flag", {31'b0, sys_ebreak_o}, 32'd1);
        chk_field("21f ebreak not illegal", {31'b0, illegal_instr_o}, 32'd0);
        inst_i = 32'h30200073;   // MRET
        #1;
        chk_field("21g mret flag", {31'b0, sys_mret_o}, 32'd1);
        chk_field("21h mret reg_we=0", {31'b0, reg_we_o}, 32'd0);
        chk_field("21i mret not illegal", {31'b0, illegal_instr_o}, 32'd0);
        if (errors == errors_before)
            $display("PASS Test 21: ECALL/EBREAK/MRET decode legal as NOPs");

        // ---- Test 22: 未实现/保留的特权编码必须判非法 ----
        errors_before = errors;
        inst_i = 32'h10500073;   // WFI（本实现不含 WFI）
        #1;
        chk_field("22a WFI illegal", {31'b0, illegal_instr_o}, 32'd1);
        inst_i = 32'h00008073;   // ECALL 但 rs1 != x0（保留编码）
        #1;
        chk_field("22b ecall rs1!=0 illegal", {31'b0, illegal_instr_o}, 32'd1);
        inst_i = 32'h302000F3;   // MRET 但 rd != x0（保留编码）
        #1;
        chk_field("22c mret rd!=0 illegal", {31'b0, illegal_instr_o}, 32'd1);
        inst_i = 32'h30004073;   // funct3=100（保留）
        #1;
        chk_field("22d funct3=100 illegal", {31'b0, illegal_instr_o}, 32'd1);
        inst_i = 32'h7FF10093;   // 回到合法 ADDI（防止判据被锁存/串扰）
        #1;
        chk_field("22e legal after rejects", {31'b0, illegal_instr_o}, 32'd0);
        if (errors == errors_before)
            $display("PASS Test 22: reserved/WFI privilege encodings flagged illegal");

        // ---- Test 23: fetch_fault 门控同样覆盖 SYSTEM 类 ----
        fault_i = 1'b1;
        inst_i = 32'h300095F3;   // CSRRW（但取指出错）
        #1;
        errors_before = errors;
        chk_field("23a fault csr_we=0", {31'b0, csr_we_o}, 32'd0);
        chk_field("23b fault reg_we=0", {31'b0, reg_we_o}, 32'd0);
        chk_field("23c fault illegal=0", {31'b0, illegal_instr_o}, 32'd0);
        fault_i = 1'b0;
        if (errors == errors_before)
            $display("PASS Test 23: fetch fault suppresses CSR/system side effects");

        // ---- Test 24: 锁定设计决策 —— ID **不判** CSR 地址合法性 ----
        // 未实现 CSR / 只读 CSR 写 的非法性在**提交点**用 csr_file 自己的译码
        // 判定（见 cpu_core_stage1 的 CSR 接入节），ID 期不重复实现一份 CSR
        // 地址图。若将来把合法性移回 ID，本用例会 FAIL，从而强制同步更新两处判定。
        errors_before = errors;
        inst_i = 32'h00002073;   // CSRRS x0, 0x000, x0（未实现地址）
        #1;
        chk_field("24a unimpl CSR not ID-illegal", {31'b0, illegal_instr_o}, 32'd0);
        inst_i = 32'h34401073;   // CSRRW x0, mip, x0（对只读 CSR 的写意图）
        #1;
        chk_field("24b ro-write not ID-illegal", {31'b0, illegal_instr_o}, 32'd0);
        chk_field("24c ro-write has intent", {31'b0, csr_we_o}, 32'd1);
        inst_i = 32'h7FF10093;
        #1;
        if (errors == errors_before)
            $display("PASS Test 24: CSR address legality deferred to commit point");

        // ---- Summary ----
        $display("==========================================");
        if (errors == 0) begin
            $display("  ALL TESTS PASSED (%0d errors)", errors);
        end else begin
            $display("  %0d TEST(S) FAILED", errors);
        end
        $display("==========================================");
        $finish;
    end

    initial begin
        #500;
        $display("TIMEOUT");
        $finish;
    end

    initial begin
        $dumpfile("build/tb_id_stage.vcd");
        $dumpvars(0, tb_id_stage);
    end

endmodule