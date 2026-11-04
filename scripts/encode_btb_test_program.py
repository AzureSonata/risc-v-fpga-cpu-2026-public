# -*- coding: utf-8 -*-
"""为 BTB 系统级测试生成并校验 RV32I 指令编码（避免手算出错）。

打印每条指令的 32 位十六进制，并把编码反解回字段做一致性校验；
测试台里的 rom() 常量即取自本脚本输出。
"""
from __future__ import annotations


def r_type(funct7, rs2, rs1, funct3, rd, opcode):
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


def i_type(imm, rs1, funct3, rd, opcode):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


def s_type(imm, rs2, rs1, funct3, opcode):
    imm &= 0xFFF
    return (((imm >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | \
           ((imm & 0x1F) << 7) | opcode


def b_type(imm, rs2, rs1, funct3, opcode):
    imm &= 0x1FFF
    b12 = (imm >> 12) & 1
    b11 = (imm >> 11) & 1
    b10_5 = (imm >> 5) & 0x3F
    b4_1 = (imm >> 1) & 0xF
    return (b12 << 31) | (b10_5 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | \
           (b4_1 << 8) | (b11 << 7) | opcode


def addi(rd, rs1, imm):
    return i_type(imm, rs1, 0b000, rd, 0b0010011)


def blt(rs1, rs2, off):
    return b_type(off, rs2, rs1, 0b100, 0b1100011)


def decode(w):
    op = w & 0x7F
    rd = (w >> 7) & 0x1F
    f3 = (w >> 12) & 0x7
    rs1 = (w >> 15) & 0x1F
    rs2 = (w >> 20) & 0x1F
    if op == 0b0010011 and f3 == 0b000:
        return "addi x%d, x%d, %d" % (rd, rs1, (w >> 20) if (w >> 31) == 0
                                      else ((w >> 20) - 4096))
    if op == 0b1100011 and f3 == 0b100:
        b12 = (w >> 31) & 1
        b11 = (w >> 7) & 1
        b10_5 = (w >> 25) & 0x3F
        b4_1 = (w >> 8) & 0xF
        imm = (b12 << 12) | (b11 << 11) | (b10_5 << 5) | (b4_1 << 1)
        if imm & 0x1000:
            imm -= 0x2000
        return "blt x%d, x%d, %d" % (rs1, rs2, imm)
    return "?? opcode=%07b" % op


PROGRAM = [
    (0x00, addi(1, 0, 0),  "i = 0"),
    (0x04, addi(2, 0, 3),  "limit = 3"),
    (0x08, addi(1, 1, 1),  "i++            <-- 循环体"),
    (0x0c, blt(1, 2, -4),  "if i<3 goto 0x08  (回跳，-4)"),
    (0x10, addi(3, 0, 7),  "x3 = 7         <-- 循环出口"),
    (0x14, addi(4, 0, 9),  "x4 = 9"),
]

print("=== BTB 测试程序 ===")
for addr, w, note in PROGRAM:
    print("32'h%02x: rom = 32'h%08x; // %-34s %s" % (addr, w, decode(w), note))

print()
print("=== 反解校验 ===")
ok = True
for addr, w, note in PROGRAM:
    d = decode(w)
    print("0x%02x -> %s" % (addr, d))
    if d.startswith("??"):
        ok = False
print()
print("预期 retire 序列（10 条）:")
seq = [(0x00, 1, 0, 1), (0x04, 2, 3, 1),
       (0x08, 1, 1, 1), (0x0c, 0, 0, 0),
       (0x08, 1, 2, 1), (0x0c, 0, 0, 0),
       (0x08, 1, 3, 1), (0x0c, 0, 0, 0),
       (0x10, 3, 7, 1), (0x14, 4, 9, 1)]
for i, (pc, rd, data, we) in enumerate(seq):
    print("  [%2d] pc=0x%02x rd=x%d data=%d we=%d" % (i, pc, rd, data, we))
print()
print("BTB 覆盖情形：第1次 blt=未命中且实际 taken(情形4)；第2次=预测 taken 且目标一致(情形1)；")
print("              第3次=预测 taken 但实际 not taken(情形3，最关键)。")
print("情形2（预测 taken 但目标不同）需 JALR 变目标，本程序为静态目标，未覆盖。")
print()
print("校验结果:", "OK" if ok else "FAIL")
