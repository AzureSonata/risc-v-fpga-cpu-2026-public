#!/usr/bin/env python3
"""resync_negctl_mutants.py —— 把"锚点表以外的"负控突变体同步到当前 RTL。

## 为什么需要这个脚本（2026-10-01，峥榕在 Icarus 13.0 的复现暴露）

`scripts/regenerate_negctl.py` 用**锚点表**（`MUTANTS`）再生突变体，但那张表只登记了
**4** 个（cache_path ×2、cpu_mem_subsystem ×2），而 `verification/negctl/rtl/` 里实际有
**42** 个文件。其余 38 个是早期用一次性脚本/手工生成的整份拷贝，**没有任何一致性检查**。

后果（本轮实测）：把 `rtl/core/cpu_core_stage1.sv` 的 4 处"先用后声明"修好以后，
10 个 `cpu_core_stage1_negctl_*.sv` **仍带着旧的声明顺序** ⇒ 在 Icarus 13.0 下全部编译失败
（这正是峥榕看到的"负控 18 条突变体编译失败"的来源），而在 Icarus 10.2 下"编译成功但作用在
旧实现上"，两种后果分别对应 §7.6 表格里的两行。
更糟的是：`regenerate_negctl.py` 当时**照样打印"全部突变体与当前 RTL 一致"**——
因为它只看了自己表里的 4 个（**过度声称**，与 §7.15"绿是空跑"同族）。

## 做法

突变体的语义 = "旧源 → 旧突变体"的文本差异。因此：

1. 取**上一版源**（`--prev <rev>`，例如 `04a2863`）；
2. 对每个未纳管突变体 `<mod>_negctl_<mut>.sv`，用 `difflib` 求
   `旧源` 与 `旧突变体` 的**最小差异块**（通常 1~3 行）；
3. 把这些差异块（`-` 行 → `+` 行）**原样施加到当前源**上；
4. 任一差异块在当前源里**找不到或匹配不唯一** ⇒ 大声报错并跳过（绝不静默）。

## 用法

    python scripts/resync_negctl_mutants.py --prev 04a2863            # 只检查（报告陈旧）
    python scripts/resync_negctl_mutants.py --prev 04a2863 --write    # 就地重生

退出码：0 = 全部已同步或已重生；1 = 存在需要重生但未加 `--write`，或有不一致块。
"""
from __future__ import annotations

import argparse
import difflib
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
NEGCTL = REPO / "verification" / "negctl" / "rtl"

# regenerate_negctl.py 的锚点表已覆盖这些（本脚本跳过，避免两套机制打架）
MANAGED = {
    "cache_path_negctl_nocache.sv",
    "cache_path_negctl_bypassall.sv",
    "cache_path_negctl_rspbackpressure.sv",
    "cache_path_negctl_busyignore.sv",
    "cpu_mem_subsystem_negctl_wdata.sv",
    "cpu_mem_subsystem_negctl_uarttie.sv",
    # 2026-10-01：该突变体曾被本脚本的"歧义锚点消歧"模糊路径改坏（突变消失），
    # 已登记进 regenerate_negctl.py 的锚点表 ⇒ 此处必须一并排除，避免两套机制打架。
    "id_stage_negctl_illegallatch.sv",
    # 2026-10-06：A1 修改了 mem_burst_bridge 的读地址/beat 过渡后，登记进锚点表，
    # 由 regenerate_negctl.py 用唯一锚点管理，不再走 resync 的模糊路径。
    "mem_burst_bridge_negctl_errswallow.sv",
    "mem_burst_bridge_negctl_beatfreeze.sv",
    # 2026-10-06：Issue #15 第 5 项新增的 retire/commit 负控（wb_stage / retire_trace），
    # 由 regenerate_negctl.py 锚点表管理。
    "wb_stage_negctl_fireblind.sv",
    "wb_stage_negctl_x0write.sv",
    "wb_stage_negctl_trapwrite.sv",
    "retire_trace_negctl_validblind.sv",
    "retire_trace_negctl_dropx0.sv",
    # 2026-10-06：Issue #15 第 4 项整机联合契约（backend_hold+redirect）的鉴别力突变体。
    "pipeline_control_negctl_holdwins.sv",
    # PR66 结构变化后已迁入 regenerate_negctl.py 的唯一语义锚点表。
    "dcache_negctl_bytemask.sv",
    "dual_full_negctl_dropillegal.sv",
    "wide_imem_adapter_negctl_nostaleflush.sv",
}

CANDIDATE_DIRS = ["rtl/core", "rtl/memory", "rtl/soc", "rtl/periph", "rtl"]


def find_source(mod: str) -> Path | None:
    for d in CANDIDATE_DIRS:
        for ext in (".sv", ".v"):
            p = REPO / d / (mod + ext)
            if p.exists():
                return p
    return None


def prev_text(rev: str, rel: str) -> str | None:
    r = subprocess.run(["git", "show", f"{rev}:{rel}"], cwd=REPO,
                       capture_output=True, text=True, encoding="utf-8",
                       errors="replace")
    return r.stdout if r.returncode == 0 else None


def extract_edits(old_src: str, old_mut: str) -> tuple[list[tuple[str, str, str]], int]:
    """把"旧源 → 旧突变体"的差异抽成可重放的编辑操作。

    返回 ([(kind, anchor, new_frag), ...], 不可定位块数)，kind ∈ {"replace", "insert_after"}：
      · replace      ：anchor 是**要替换掉的原文**
      · insert_after ：anchor 是**插入点前的唯一一行**（纯插入块没有可替换原文）

    ⚠️ 坑位（本脚本第一版）：只处理了有"被替换原文"的差异块，把**纯插入**判成"无法定位"
    ⇒ 15 个突变体被无谓地判为人工处理（其中多数其实可自动）。纯插入用"前一行做唯一锚点"即可。
    """
    a = old_src.split("\n")
    b = old_mut.split("\n")
    sm = difflib.SequenceMatcher(None, a, b, autojunk=False)
    ops = sm.get_opcodes()
    edits: list[tuple[str, str, str]] = []
    unpaired = 0
    for idx, (tag, i1, i2, j1, j2) in enumerate(ops):
        if tag == "equal":
            continue
        new_frag = "\n".join(b[j1:j2])
        old_frag = "\n".join(a[i1:i2])
        if old_frag.strip():
            edits.append(("replace", old_frag, new_frag))
            continue
        # 纯插入：收集**一组候选锚点行**（由近到远），每项带方向前缀：
        #   `A\x00<行>` = 该行在插入点**之前**（把新内容插到它后面）
        #   `B\x00<行>` = 该行在插入点**之后**（把新内容插到它前面）
        #   ⚠️ 坑位（实测）：`// ====...` 这类**分隔注释行**在源里出现多次 ⇒ 选它当锚点会
        #      "出现 2 次"而放弃。故给多个候选，取第一个**在当前源里唯一**的。
        cands: list[str] = []
        for k in range(idx - 1, -1, -1):
            if ops[k][0] == "equal":
                for cand in reversed(a[ops[k][1]:ops[k][2]]):
                    if cand.strip():
                        cands.append("A\x00" + cand)
                if len(cands) >= 3:
                    break
        for k in range(idx + 1, len(ops)):
            if ops[k][0] == "equal":
                for cand in a[ops[k][1]:ops[k][2]]:
                    if cand.strip():
                        cands.append("B\x00" + cand)
                break
        if not cands:
            unpaired += 1
            continue
        edits.append(("insert", "\n\x00".join(cands[:4]), new_frag))
    return edits, unpaired


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, OSError):
        pass

    ap = argparse.ArgumentParser()
    ap.add_argument("--prev", required=True,
                    help="上一版提交/标签（突变体当时与之同步），例如 04a2863")
    ap.add_argument("--write", action="store_true", help="就地重生")
    args = ap.parse_args()

    files = sorted(NEGCTL.glob("*.sv"))
    print(f"## 负控突变体再同步（对齐到当前 RTL）")
    print(f"   突变体目录：verification/negctl/rtl（共 {len(files)} 个）")
    print(f"   参照版本：{args.prev}")

    stale: list[str] = []
    problems: list[str] = []
    skipped = 0

    for f in files:
        if f.name in MANAGED:
            skipped += 1
            continue
        m = re.match(r"^(?P<mod>.+?)_negctl_(?P<mut>.+)\.sv$", f.name)
        if not m:
            problems.append(f"{f.name}: 文件名不符合 <mod>_negctl_<mut>.sv")
            continue
        src = find_source(m.group("mod"))
        if src is None:
            problems.append(f"{f.name}: 找不到源 RTL rtl/**/{m.group('mod')}.sv|.v")
            continue
        rel = src.relative_to(REPO).as_posix()
        old_src = prev_text(args.prev, rel)
        if old_src is None:
            problems.append(f"{f.name}: {args.prev} 中不存在 {rel}")
            continue

        # ⚠️ 坑位（实测）：`old_mut` **必须取自 `--prev` 那个版本**，不能取工作区当前内容。
        #   因为一旦本脚本重生过某个突变体，工作区内容就已经是"新源+突变"，
        #   再对旧源求差异会把"源本身的历史改动"也算成突变块 ⇒ 二次施加 ⇒ 内容错乱/重复。
        #   取历史版本后，差异**恒等于突变本身**，脚本可反复运行（幂等）。
        # ⚠️ 坑位（实测）：**差异派生**用 `--prev` 的历史内容（`old_mut`），
        #   **"是否已同步"的比较**必须用**工作区当前内容**（`have`）。
        #   第一版把两者混用同一个变量 ⇒ 重生之后重跑仍然报"陈旧"（永不收敛，自欺）。
        have = f.read_text(encoding="utf-8", errors="replace")
        old_mut = prev_text(args.prev, f"verification/negctl/rtl/{f.name}")
        if old_mut is None:
            old_mut = have
        new_src = src.read_text(encoding="utf-8", errors="replace")

        if old_mut == old_src:
            problems.append(f"{f.name}: 与旧源完全相同（没有突变？）")
            continue

        edits, unpaired = extract_edits(old_src, old_mut)
        if unpaired:
            problems.append(f"{f.name}: 有 {unpaired} 个差异块无法定位（需人工确认）")
            continue
        if not edits:
            problems.append(f"{f.name}: 未提取到差异块")
            continue

        # 把所有差异块施加到当前源 ⇒ `want` = 本突变体**应当**的内容
        # ⚠️ 坑位（实测）：唯一性检查必须在**原始的当前源 new_src** 上做，不能在"边改边算"的 `out` 上做
        #   —— 否则前一个编辑插入的文本会让后一个编辑的锚点变成"出现 2 次"而误判失败
        #   （实测：10 个 cpu_core_stage1 突变体因此被判"锚点出现 2 次"）。
        out = new_src
        ok = True
        for kind, anchor, new_frag in edits:
            if kind == "replace":
                # ⚠️ 坑位（实测）：锚点在当前源里不唯一时（例：`illegal_instr_o = 1'b0;` 出现 3 次），
                #   不能直接放弃 —— 用**上文逐行加长**做消歧，直到唯一或加满 3 行。
                cand = anchor
                lines_old = anchor.split("\n")
                pos = old_src.find(anchor)
                prefix_lines = old_src[:pos].split("\n") if pos >= 0 else []
                for extra in range(1, 4):
                    if new_src.count(cand) == 1:
                        break
                    if len(prefix_lines) < extra + 1:
                        break
                    cand = "\n".join(prefix_lines[-(extra + 1):]) 
                c = new_src.count(cand)
                if c != 1:
                    problems.append(
                        f"{f.name}: 待替换原文在当前源中出现 {c} 次（加长上文后仍不唯一）："
                        f"{anchor.strip()[:70]!r}")
                    ok = False
                    break
                if cand != anchor:
                    # 加长后的锚点：新内容也要补回上文
                    extra_prefix = cand[: len(cand) - len(anchor)]
                    out = out.replace(cand, extra_prefix + new_frag, 1)
                else:
                    out = out.replace(anchor, new_frag, 1)
            elif kind == "insert":
                # anchor 是候选列表（由近到远，带 A/B 方向前缀），取第一个在当前源里唯一的
                chosen = None
                direction = None
                for cand in anchor.split("\n\x00"):
                    d, _, line = cand.partition("\x00")
                    if line and new_src.count(line) == 1:
                        chosen, direction = line, d
                        break
                if chosen is None:
                    problems.append(f"{f.name}: 纯插入块找不到唯一锚点（候选都不唯一）")
                    ok = False
                    break
                if direction == "A":
                    out = out.replace(chosen, chosen + "\n" + new_frag, 1)
                else:
                    out = out.replace(chosen, new_frag + "\n" + chosen, 1)
            else:
                problems.append(f"{f.name}: 未知编辑类型 {kind}")
                ok = False
                break
        if not ok:
            continue

        # ⚠️ 坑位：陈旧判定必须是**内容比较**（want vs 现有），不能用"旧片段是否还在新源里"当代理
        #   —— 那只是代理指标，会把仍然正确的突变体误报为陈旧（本脚本第一版如此，实测误报 23 个）。
        if out == have:
            print(f"  ✅ {f.name}: 已与当前 {rel} 同步")
            continue

        stale.append(f.name)
        if args.write:
            f.write_text(out, encoding="utf-8", newline="")
            print(f"  ✍️  {f.name}: 已重生（源 {rel}）")
        else:
            print(f"  ⚠️  {f.name}: **已陈旧**（需 --write 重生）")

    print()
    if problems:
        print(f"❌ {len(problems)} 个突变体**无法自动处理**，必须人工确认：")
        for p in problems:
            print(f"   - {p}")
    if stale and not args.write:
        print(f"⚠️ {len(stale)} 个突变体陈旧 —— 负向对照可能假绿或编译失败，请加 --write")
    if skipped:
        print(f"（已跳过 {skipped} 个由 regenerate_negctl.py 锚点表管理的突变体）")
    if problems or (stale and not args.write):
        return 1
    print("✅ 全部未纳管突变体已与当前 RTL 同步")
    return 0


if __name__ == "__main__":
    sys.exit(main())
