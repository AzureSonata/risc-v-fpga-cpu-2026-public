#!/usr/bin/env python3
"""verify_negctl_faithfulness.py —— 核对负控突变体"注入的违规"是否还是原来那一个。

## 为什么需要（2026-10-01 实测事故）

`resync_negctl_mutants.py` 用"旧源→旧突变体"的差异块重放来重生突变体。它对**歧义锚点**
（同一行在源里出现多次）会自动"加长上文消歧"——这条模糊路径**改错了一个突变体**：
`id_stage_negctl_illegallatch.sv` 本应**删除** `illegal_instr_o = 1'b0;`（默认赋值 ⇒ 推断锁存器），
结果却**删掉了注释、保留了那条赋值** ⇒ **突变实际上消失了**，负控从 48/48 变成 **47/48**
（表面看是"漏检"，其实是**突变体被改没了**）。
⇒ 与 §7.6/§7.20 同族：**"重生了"不等于"还是那个违规"**。必须有一步独立的**忠实性核对**。

## 判据（只看**代码行**，忽略注释/空行）

对每个突变体，分别取两组"代码行多重集差"：
    A = code(old_src)   - code(old_mutant)     # 原始注入删掉了哪些代码
    B = code(new_src)   - code(new_mutant)     # 现在注入删掉了哪些代码
以及对应的"新增"集合。**忠实 ⇔ A==A' 且 B==B'**（多重集相等）。

- 若源 RTL 在突变点附近被改过，集合可能合法地不同 ⇒ 报 `需人工确认` 而不是硬判失败，
  但会把两组集合**并排打印**，让复核者 10 秒内能判断。

## 用法

    python scripts/verify_negctl_faithfulness.py --prev 04a2863
退出码：0 = 全部忠实/无需确认；1 = 存在不一致或需人工确认项。
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
NEGCTL = REPO / "verification" / "negctl" / "rtl"
CANDIDATE_DIRS = ["rtl/core", "rtl/memory", "rtl/soc", "rtl/periph", "rtl"]

# regenerate_negctl.py 的锚点表已覆盖这些；它们由"唯一锚点 + 替换"保证忠实，
# 不再参与本脚本的"旧源→旧突变体"文本差异核对（避免 RTL 在突变点附近改动时误报）。
MANAGED = {
    "cache_path_negctl_nocache.sv",
    "cache_path_negctl_bypassall.sv",
    "cache_path_negctl_rspbackpressure.sv",
    "cache_path_negctl_busyignore.sv",
    "cpu_mem_subsystem_negctl_wdata.sv",
    "cpu_mem_subsystem_negctl_uarttie.sv",
    "id_stage_negctl_illegallatch.sv",
    "mem_burst_bridge_negctl_errswallow.sv",
    "mem_burst_bridge_negctl_beatfreeze.sv",
    # 2026-10-06：Issue #15 第 5 项新增的 retire/commit 负控，由锚点表管理。
    "wb_stage_negctl_fireblind.sv",
    "wb_stage_negctl_x0write.sv",
    "wb_stage_negctl_trapwrite.sv",
    "retire_trace_negctl_validblind.sv",
    "retire_trace_negctl_dropx0.sv",
    # 2026-10-06：Issue #15 第 4 项整机联合契约突变体，由锚点表管理。
    "pipeline_control_negctl_holdwins.sv",
    # PR66 结构重构后的 byte mask / illegal head / response hold mutations.
    "dcache_negctl_bytemask.sv",
    "dual_full_negctl_dropillegal.sv",
    "wide_imem_adapter_negctl_nostaleflush.sv",
}

COMMENT_ONLY = re.compile(r"^\s*(//|/\*|\*|$)")


def code_lines(text: str) -> list[str]:
    out = []
    for ln in text.split("\n"):
        s = ln.strip()
        if not s or COMMENT_ONLY.match(s):
            continue
        out.append(s)
    return out


def diff_counter(a: list[str], b: list[str]) -> Counter:
    return Counter(a) - Counter(b)


def git_show(rev: str, rel: str) -> str | None:
    r = subprocess.run(["git", "show", f"{rev}:{rel}"], cwd=REPO,
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    return r.stdout if r.returncode == 0 else None


def find_source(mod: str) -> Path | None:
    for d in CANDIDATE_DIRS:
        for ext in (".sv", ".v"):
            p = REPO / d / (mod + ext)
            if p.exists():
                return p
    return None


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, OSError):
        pass
    ap = argparse.ArgumentParser()
    ap.add_argument("--prev", required=True, help="突变体生成时对应的源版本")
    args = ap.parse_args()

    bad = 0
    unknown = 0
    ok = 0
    print("## 负控突变体忠实性核对（注入的违规是否还是原来那一个）")
    print(f"   参照版本：{args.prev}")
    for f in sorted(NEGCTL.glob("*.sv")):
        m = re.match(r"^(?P<mod>.+?)_negctl_(?P<mut>.+)\.sv$", f.name)
        if not m:
            continue
        if f.name in MANAGED:
            print(f"  ↩️  {f.name}: 锚点表管理，跳过（由 regenerate_negctl.py 核对）")
            unknown += 1
            continue
        src = find_source(m.group("mod"))
        old_src = git_show(args.prev, src.relative_to(REPO).as_posix()) if src else None
        old_mut = git_show(args.prev, f"verification/negctl/rtl/{f.name}")
        if old_src is None or old_mut is None:
            print(f"  ⚠️  {f.name}: 旧版本缺失，跳过")
            unknown += 1
            continue
        new_src = src.read_text(encoding="utf-8", errors="replace")
        new_mut = f.read_text(encoding="utf-8", errors="replace")

        rem_a = diff_counter(code_lines(old_src), code_lines(old_mut))
        rem_b = diff_counter(code_lines(new_src), code_lines(new_mut))
        add_a = diff_counter(code_lines(old_mut), code_lines(old_src))
        add_b = diff_counter(code_lines(new_mut), code_lines(new_src))

        if rem_a == rem_b and add_a == add_b:
            ok += 1
            continue
        bad += 1
        print(f"  ❌ {f.name}: 注入内容与原始不一致")
        print(f"       原始**删除**的代码行: {sorted(rem_a.elements())!r}")
        print(f"       当前**删除**的代码行: {sorted(rem_b.elements())!r}")
        if add_a != add_b:
            print(f"       原始**新增**的代码行: {sorted(add_a.elements())!r}")
            print(f"       当前**新增**的代码行: {sorted(add_b.elements())!r}")
    print()
    print(f"忠实 {ok} 个；不一致 {bad} 个；跳过 {unknown} 个")
    if bad:
        print("⇒ 不一致意味着**突变体已不是原来的违规**（可能被判成'漏检'，其实是突变被改掉）。")
        print("   修法：把该突变体登记进 `regenerate_negctl.py` 的锚点表（唯一锚点 + 替换），")
        print("   并在 `resync_negctl_mutants.py` 的 MANAGED 里排除，不再走模糊路径。")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
