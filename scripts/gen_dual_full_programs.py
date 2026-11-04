#!/usr/bin/env python3
"""Generate small RV32I hex programs for the dual-issue full-core directed tests.
No external assembler is required; encodings are explicit and validated by the
handful of programs under verification/unit/.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "verification" / "unit"


def r_inst(opcode, rd, funct3, rs1, rs2, funct7):
    return ((funct7 & 0x7f) << 25) | ((rs2 & 0x1f) << 20) | ((rs1 & 0x1f) << 15) | \
           ((funct3 & 0x7) << 12) | ((rd & 0x1f) << 7) | (opcode & 0x7f)


def i_inst(opcode, rd, funct3, rs1, imm):
    return (((imm & 0xfff) << 20) | ((rs1 & 0x1f) << 15) | ((funct3 & 0x7) << 12) |
            ((rd & 0x1f) << 7) | (opcode & 0x7f))


def s_inst(opcode, funct3, rs1, rs2, imm):
    imm &= 0xfff
    return (((imm >> 5) & 0x7f) << 25) | ((rs2 & 0x1f) << 20) | ((rs1 & 0x1f) << 15) | \
           ((funct3 & 0x7) << 12) | ((imm & 0x1f) << 7) | (opcode & 0x7f)


def b_inst(opcode, funct3, rs1, rs2, imm):
    imm &= 0x1fff
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3f) << 25) | ((rs2 & 0x1f) << 20) | \
           ((rs1 & 0x1f) << 15) | ((funct3 & 0x7) << 12) | (((imm >> 1) & 0xf) << 8) | \
           (((imm >> 11) & 1) << 7) | (opcode & 0x7f)


def u_inst(opcode, rd, imm20):
    return ((imm20 & 0xfffff) << 12) | ((rd & 0x1f) << 7) | (opcode & 0x7f)


def j_inst(opcode, rd, imm):
    imm &= 0x1fffff
    return (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3ff) << 21) | \
           (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xff) << 12) | \
           ((rd & 0x1f) << 7) | (opcode & 0x7f)


def addi(rd, rs1, imm): return i_inst(0x13, rd, 0x0, rs1, imm)
def sltiu(rd, rs1, imm): return i_inst(0x13, rd, 0x3, rs1, imm)
def lui(rd, imm20): return u_inst(0x37, rd, imm20)
def add(rd, rs1, rs2): return r_inst(0x33, rd, 0x0, rs1, rs2, 0x00)
def sub(rd, rs1, rs2): return r_inst(0x33, rd, 0x0, rs1, rs2, 0x20)
def lw(rd, rs1, imm): return i_inst(0x03, rd, 0x2, rs1, imm)
def lh(rd, rs1, imm): return i_inst(0x03, rd, 0x1, rs1, imm)
def lb(rd, rs1, imm): return i_inst(0x03, rd, 0x0, rs1, imm)
def lhu(rd, rs1, imm): return i_inst(0x03, rd, 0x5, rs1, imm)
def lbu(rd, rs1, imm): return i_inst(0x03, rd, 0x4, rs1, imm)
def sw(rs2, rs1, imm): return s_inst(0x23, 0x2, rs1, rs2, imm)
def sh(rs2, rs1, imm): return s_inst(0x23, 0x1, rs1, rs2, imm)
def sb(rs2, rs1, imm): return s_inst(0x23, 0x0, rs1, rs2, imm)
def beq(rs1, rs2, imm): return b_inst(0x63, 0x0, rs1, rs2, imm)
def jal(rd, imm): return j_inst(0x6f, rd, imm)
def csrrw(rd, csr, rs1): return i_inst(0x73, rd, 0x1, rs1, csr)
def csrrs(rd, csr, rs1): return i_inst(0x73, rd, 0x2, rs1, csr)
def csrrc(rd, csr, rs1): return i_inst(0x73, rd, 0x3, rs1, csr)
def csrrwi(rd, csr, uimm): return i_inst(0x73, rd, 0x5, uimm, csr)
def csrrsi(rd, csr, uimm): return i_inst(0x73, rd, 0x6, uimm, csr)
def csrrci(rd, csr, uimm): return i_inst(0x73, rd, 0x7, uimm, csr)
ECALL = 0x00000073
EBREAK = 0x00100073
MRET = 0x30200073


def pad(words):
    words = list(words)
    if len(words) & 1:
        words.append(addi(0, 0, 0))
    return words


def write(name, words):
    lines = [f"{w & 0xffffffff:08x}" for w in pad(words)]
    (OUT / name).write_text("\n".join(lines) + "\n", encoding="ascii")
    print(f"wrote verification/unit/{name}: {len(lines)} words")


def mem_program():
    p = []
    p += [lui(1, 0x80000)]          # x1 = 0x8000_0000
    p += [addi(2, 0, 0x12)]
    p += [sw(2, 1, 0)]              # word store
    p += [addi(2, 0, 0x123)]
    p += [sb(2, 1, 4)]              # byte store
    p += [lbu(3, 1, 4)]             # expect 0x23
    p += [addi(2, 0, 0x567)]
    p += [sh(2, 1, 8)]              # half store
    p += [lhu(4, 1, 8)]             # expect 0x4567
    p += [lw(5, 1, 0)]              # expect 0x12
    p += [addi(6, 0, 1)]
    p += [addi(7, 0, 2)]
    p += [add(8, 6, 7)]             # expect 3
    p += [addi(9, 0, 0x7f)]
    p += [addi(10, 0, 0x80)]
    p += [sb(10, 1, 12)]
    p += [lb(11, 1, 12)]            # expect 0xffff_ff80
    p += [jal(0, 0)]                # halt
    return p


def csr_program():
    p = []
    # mtvec = handler @ 0x100 (64 instructions, 8-byte aligned)
    p += [addi(1, 0, 0x100)]
    p += [csrrw(0, 0x305, 1)]
    # read back mtvec
    p += [csrrs(2, 0x305, 0)]       # x2 = handler address
    # write/read mepc (12-bit immediate range)
    p += [lui(3, 0x00000)]
    p += [addi(3, 0, 0x234)]
    p += [csrrw(0, 0x341, 3)]
    p += [csrrs(4, 0x341, 0)]       # x4 = 0x1234
    # write/read mcause
    p += [addi(5, 0, 0x2a)]
    p += [csrrw(0, 0x342, 5)]
    p += [csrrs(6, 0x342, 0)]       # x6 = 0x2a
    # read mstatus (initial 0, MPP=11 -> 0x1800)
    p += [csrrs(7, 0x300, 0)]
    # enable mstatus.MIE (bit 3) and read back
    p += [csrrsi(0, 0x300, 0x8)]
    p += [csrrs(8, 0x300, 0)]       # x8 bit3 should be 1
    # ecall trap -> handler at 0x40
    p += [ECALL]
    # handler body is patched to this point; after ecall, execution is redirected.
    # The handler writes mcause into x10 and advances mepc by 4, then mret.
    p += [addi(0, 0, 0)]           # NOP: preserve handler x10/x11 after mret
    p += [addi(0, 0, 0)]           # NOP
    p += [jal(0, 0)]               # halt
    # Pad main to handler offset 0x100 (64 instructions)
    while len(p) < 0x100 // 4:
        p.append(addi(0, 0, 0))
    # handler:
    p += [csrrs(10, 0x342, 0)]     # x10 = mcause (expect 11)
    p += [csrrs(11, 0x341, 0)]     # x11 = mepc  (expect ecall PC)
    p += [addi(11, 11, 4)]
    p += [csrrw(0, 0x341, 11)]
    p += [MRET]
    return p


def irq_program():
    p = []
    # handler @ 0x100
    p += [addi(1, 0, 0x100)]
    p += [csrrw(0, 0x305, 1)]
    # enable MTIE(7) in mie and MIE(3) in mstatus; timer_irq is driven by the TB.
    p += [addi(5, 0, 0x80)]
    p += [csrrw(0, 0x304, 5)]
    p += [csrrsi(0, 0x300, 0x8)]
    # wait loop: branch to self until interrupt
    p += [beq(0, 0, 0)]
    p += [jal(0, 0)]
    while len(p) < 0x100 // 4:
        p.append(addi(0, 0, 0))
    # handler: read mcause -> x10, disable MTIE (via register operand because
    # the 5-bit CSRRCI uimm cannot encode bit 7), mret to retry the branch.
    p += [csrrs(10, 0x342, 0)]      # expect 0x8000_0007
    p += [addi(6, 0, 0x80)]
    p += [csrrc(0, 0x304, 6)]       # clear MTIE
    p += [MRET]
    return p


def soc_program():
    p = []
    # D-side SRAM write/read through cpu_mem_subsystem
    p += [lui(1, 0x80000)]          # x1 = 0x8000_0000
    p += [addi(3, 0, 0x123)]
    p += [sw(3, 1, 0)]
    p += [lw(4, 1, 0)]              # expect 0x123
    # mtvec = handler @ 0x100
    p += [addi(11, 0, 0x100)]
    p += [csrrw(0, 0x305, 11)]
    # MMIO timer: mtime=0, mtimecmp=8
    p += [lui(2, 0x10000)]          # x2 = 0x1000_0000
    p += [sw(0, 2, 0x20)]
    p += [addi(5, 0, 8)]
    p += [sw(5, 2, 0x24)]
    # enable MTIE + MIE
    p += [addi(6, 0, 0x80)]
    p += [csrrw(0, 0x304, 6)]
    p += [csrrsi(0, 0x300, 0x8)]
    # wait for timer interrupt at an instruction boundary
    p += [beq(0, 0, 0)]
    p += [jal(0, 0)]
    while len(p) < 0x100 // 4:
        p.append(addi(0, 0, 0))
    # handler @0x100: read mcause, clear the timer device request, disable MTIE, mret
    p += [csrrs(10, 0x342, 0)]      # x10 = 0x8000_0007
    p += [addi(7, 0, -1)]           # 0xFFFF_FFFF
    p += [sw(7, 2, 0x24)]           # mtimecmp > mtime -> irq deasserts
    p += [addi(6, 0, 0x80)]
    p += [csrrc(0, 0x304, 6)]       # clear MTIE
    p += [MRET]
    return p


if __name__ == "__main__":
    write("dual_full_mem.hex", mem_program())
    write("dual_full_csr.hex", csr_program())
    write("dual_full_irq.hex", irq_program())
    write("dual_full_soc.hex", soc_program())
