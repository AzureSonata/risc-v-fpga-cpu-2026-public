#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 frontend_perf 负向对照突变体。

从 rtl/core/frontend_perf.sv 反向注入计数门控缺陷，产出
verification/negctl/rtl/frontend_perf_negctl_*.sv，供
`python scripts/run_tests.py --negative-controls` 装载（配合 tb_frontend_perf）。

模块名保持 frontend_perf 以便替换原文件编译。
突变体必须**可编译**，否则只会以"编译失败"被计入捕获，无法证明断言有效。
"""
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parents[1]
SRC = REPO / "rtl" / "core" / "frontend_perf.sv"
OUT = REPO / "verification" / "negctl" / "rtl"

HEADER = """// ============================================================================
//        负向对照突变体（NEGATIVE CONTROL MUTANT）— 故意注入历史缺陷
//        由 scripts/run_tests.py --negative-controls 装载，
//        替换 rtl/core/frontend_perf.sv（配合 tb_frontend_perf）
//        预期：对应测试必须 FAIL（证明回归能捕获该违规）
//        源：rtl/core/frontend_perf.sv 的已修复版本
//
//        {desc}
// ============================================================================
"""


def main() -> int:
    src = SRC.read_text(encoding="utf-8")
    OUT.mkdir(parents=True, exist_ok=True)

    # ---- M1: 分支计数未用 id_valid 门控（空泡被计入统计）----
    target = (
        "            if (id_valid && (id_branch || id_jal || id_jalr))\n"
        "                                cnt_branch   <= cnt_branch   + {{(CNT_W-1){1'b0}}, 1'b1};"
    )
    if target not in src:
        print("ERROR: cnt_branch 门控语句未找到（frontend_perf.sv 是否已改动？）")
        return 1
    m1 = src.replace(
        target,
        "            if (id_branch || id_jal || id_jalr)   // 缺陷：未用 id_valid 门控\n"
        "                                cnt_branch   <= cnt_branch   + {{(CNT_W-1){1'b0}}, 1'b1};",
        1)
    m1 = HEADER.format(
        desc="注入缺陷：分支计数未用 id_valid 门控 -> 空泡周期被计入分支统计，\n"
             "//        污染预测精度与分支密度（T4 断言必然失败）"
    ) + m1
    (OUT / "frontend_perf_negctl_nogate.sv").write_text(m1, encoding="utf-8")

    # ---- M2: 条件分支计数误用 id_branch 之外的条件（污染分类）----
    target2 = (
        "            if (id_valid && id_branch)\n"
        "                                cnt_cond_branch <= cnt_cond_branch + {{(CNT_W-1){1'b0}}, 1'b1};"
    )
    if target2 not in src:
        print("ERROR: cnt_cond_branch 语句未找到")
        return 1
    m2 = src.replace(
        target2,
        "            if (id_valid)   // 缺陷：条件分支计数未区分指令类型\n"
        "                                cnt_cond_branch <= cnt_cond_branch + {{(CNT_W-1){1'b0}}, 1'b1};",
        1)
    m2 = HEADER.format(
        desc="注入缺陷：条件分支计数未区分指令类型 -> 所有有效指令都计入条件分支，\n"
             "//        分类统计失真（T3/T7 断言必然失败）"
    ) + m2
    (OUT / "frontend_perf_negctl_misclass.sv").write_text(m2, encoding="utf-8")

    for name in ("frontend_perf_negctl_nogate.sv",
                 "frontend_perf_negctl_misclass.sv"):
        p = OUT / name
        print(f"生成 {name}: {len(p.read_text(encoding='utf-8').splitlines())} 行")
    return 0


if __name__ == "__main__":
    sys.exit(main())
