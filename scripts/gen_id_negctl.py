#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 id_stage 负向对照突变体。

从已修复的 rtl/core/id_stage.sv 反向注入历史缺陷，产出
verification/negctl/rtl/id_stage_negctl_*.sv，供
`python scripts/run_tests.py --negative-controls` 装载。

突变体是完整模块副本（与既有 if_stage_negctl_*.sv 同做法），
模块名保持 id_stage 以便替换原文件编译。
"""
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parents[1]
SRC = REPO / "rtl" / "core" / "id_stage.sv"
OUT = REPO / "verification" / "negctl" / "rtl"

HEADER = """// ============================================================================
//        负向对照突变体（NEGATIVE CONTROL MUTANT）— 故意注入历史缺陷
//        由 scripts/run_tests.py --negative-controls 装载，替换 rtl/core/id_stage.sv
//        预期：对应测试必须 FAIL（证明回归能捕获该违规）
//        源：rtl/core/id_stage.sv 的已修复版本
//
//        {desc}
// ============================================================================
"""


def main() -> int:
    src = SRC.read_text(encoding="utf-8")
    OUT.mkdir(parents=True, exist_ok=True)

    # ---- M1: 移除 illegal_instr_o 默认赋值（还原 D-1 锁存器推断）----
    target1 = "        illegal_instr_o = 1'b0;\n"
    if target1 not in src:
        print("ERROR: M1 目标行未找到（id_stage.sv 是否已改动？）")
        return 1
    m1 = src.replace(target1, "", 1)
    m1 = HEADER.format(
        desc="注入缺陷 D-1：移除 illegal_instr_o 默认赋值 -> always @(*) 推断锁存器，\n"
             "//        合法指令走正常 opcode 分支后输出保持上一周期的 illegal 值"
    ) + m1
    (OUT / "id_stage_negctl_illegallatch.sv").write_text(m1, encoding="utf-8")

    # ---- M2: 还原 D-3 的恒假 funct3 判据 ----
    old2 = (
        "    wire illegal_r_funct3 = (opcode == 7'b0110011) && (funct7 == 7'b0100000) &&\n"
        "                            (funct3 != 3'b000) && (funct3 != 3'b101);"
    )
    new2 = (
        "    wire illegal_r_funct3 = (opcode == 7'b0110011) && valid_r_funct7 &&\n"
        "                            (funct3 != 3'b000) && (funct3 != 3'b001) &&\n"
        "                            (funct3 != 3'b010) && (funct3 != 3'b011) &&\n"
        "                            (funct3 != 3'b100) && (funct3 != 3'b101) &&\n"
        "                            (funct3 != 3'b110) && (funct3 != 3'b111);"
    )
    if old2 not in src:
        print("ERROR: M2 目标段未找到")
        return 1
    m2 = src.replace(old2, new2, 1)
    m2 = HEADER.format(
        desc="注入缺陷 D-3：还原恒假 funct3 判据 -> funct7=0100000 的保留编码\n"
             "//        （如 funct3=001）被误判为合法 R 型"
    ) + m2
    (OUT / "id_stage_negctl_funct3blind.sv").write_text(m2, encoding="utf-8")

    # ---- M3: 还原 D-7（移位立即数只比较 funct7[6:5] 两位）----
    old3 = (
        "    wire illegal_slli = (opcode == 7'b0010011) && (funct3 == 3'b001) &&\n"
        "                        (funct7 != 7'b0000000);\n"
        "    wire illegal_sri  = (opcode == 7'b0010011) && (funct3 == 3'b101) &&\n"
        "                        (funct7 != 7'b0000000) && (funct7 != 7'b0100000);"
    )
    new3 = (
        "    wire illegal_slli = (opcode == 7'b0010011) && (funct3 == 3'b001) && (funct7[6:5] != 2'b00);\n"
        "    wire illegal_sri = (opcode == 7'b0010011) && (funct3 == 3'b101) &&\n"
        "                       (funct7[6:5] != 2'b00) && (funct7[6:5] != 2'b01);"
    )
    if old3 not in src:
        print("ERROR: M3 目标段未找到")
        return 1
    m3 = src.replace(old3, new3, 1)
    m3 = HEADER.format(
        desc="注入缺陷 D-7：移位立即数只比较 funct7[6:5] 两位 -> funct7 低 5 位非零\n"
             "//        的保留编码（如 7'b0000001）被误判为合法 SLLI/SRLI"
    ) + m3
    (OUT / "id_stage_negctl_shiftf7.sv").write_text(m3, encoding="utf-8")

    for name in ("id_stage_negctl_illegallatch.sv",
                 "id_stage_negctl_funct3blind.sv",
                 "id_stage_negctl_shiftf7.sv"):
        p = OUT / name
        print(f"生成 {name}: {len(p.read_text(encoding='utf-8').splitlines())} 行")
    return 0


if __name__ == "__main__":
    sys.exit(main())
