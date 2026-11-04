#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 branch_predictor 负向对照突变体。

从 rtl/core/branch_predictor.sv 反向注入 gshare 机制缺陷，产出
verification/negctl/rtl/branch_predictor_negctl_*.sv，供
`python scripts/run_tests.py --negative-controls` 装载（配合 tb_predictor_gshare）。

模块名保持 branch_predictor 以便替换原文件编译。
"""
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parents[1]
SRC = REPO / "rtl" / "core" / "branch_predictor.sv"
OUT = REPO / "verification" / "negctl" / "rtl"

HEADER = """// ============================================================================
//        负向对照突变体（NEGATIVE CONTROL MUTANT）— 故意注入历史缺陷
//        由 scripts/run_tests.py --negative-controls 装载，
//        替换 rtl/core/branch_predictor.sv（配合 tb_predictor_gshare）
//        预期：对应测试必须 FAIL（证明回归能捕获该违规）
//        源：rtl/core/branch_predictor.sv 的已修复版本
//
//        {desc}
// ============================================================================
"""


def main() -> int:
    src = SRC.read_text(encoding="utf-8")
    OUT.mkdir(parents=True, exist_ok=True)

    # ---- M1: GHR 永不更新（gshare 退化为纯 PC 索引）----
    target = "                ghr <= {ghr[GHR_BITS-2:0], u_taken};"
    if target not in src:
        print("ERROR: GHR 更新语句未找到（branch_predictor.sv 是否已改动？）")
        return 1
    m1 = src.replace(target, "                ghr <= ghr;   // 缺陷：GHR 不更新", 1)
    m1 = HEADER.format(
        desc="注入缺陷：GHR 永不更新 -> gshare 退化为纯 PC 索引，\n"
             "//        失去全局历史参与，T5/T6 的历史相关预测断言必然失败"
    ) + m1
    (OUT / "branch_predictor_negctl_noghr.sv").write_text(m1, encoding="utf-8")

    # ---- M2: 训练路径的 PHT 索引不含 GHR（与预测路径不一致）----
    # 注意：突变体必须**可编译**，否则只会以"编译失败"被计入捕获，
    # 无法证明断言本身有效（退化捕获）。故此处只做单点表达式替换。
    target2 = "    wire [GHR_BITS-1:0] u_gidx = u_pc[GHR_BITS+1 : 2] ^ ghr;"
    if target2 not in src:
        print("ERROR: u_gidx 定义未找到")
        return 1
    m2 = src.replace(
        target2,
        "    wire [GHR_BITS-1:0] u_gidx = u_pc[GHR_BITS+1 : 2];  // 缺陷：训练索引不含 GHR",
        1)
    m2 = HEADER.format(
        desc="注入缺陷：训练路径的 PHT 索引不含 GHR -> 与预测路径索引不一致，\n"
             "//        训练写错表项、方向预测与模型不符，断言必然失败"
    ) + m2
    (OUT / "branch_predictor_negctl_nogshareidx.sv").write_text(m2, encoding="utf-8")

    # ---- M3: RAS 压入错误的返回地址（漏 +4）----
    target3 = "                            ras_mem[ras_cnt[RAS_PTR_W-1:0]] <= u_pc + 32'd4;"
    if target3 not in src:
        print("ERROR: RAS 压栈语句未找到")
        return 1
    m3 = src.replace(
        target3,
        "                            ras_mem[ras_cnt[RAS_PTR_W-1:0]] <= u_pc;  // 缺陷：漏 +4",
        1)
    m3 = HEADER.format(
        desc="注入缺陷：RAS 压入的返回地址漏加 4 -> 返回预测目标整体偏 4 字节，\n"
             "//        T3/T4/T6 的栈顶期望值必然不符"
    ) + m3
    (OUT / "branch_predictor_negctl_rasaddr.sv").write_text(m3, encoding="utf-8")

    for name in ("branch_predictor_negctl_noghr.sv",
                 "branch_predictor_negctl_nogshareidx.sv",
                 "branch_predictor_negctl_rasaddr.sv"):
        p = OUT / name
        print(f"生成 {name}: {len(p.read_text(encoding='utf-8').splitlines())} 行")
    return 0


if __name__ == "__main__":
    sys.exit(main())
