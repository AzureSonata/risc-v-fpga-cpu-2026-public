# -*- coding: utf-8 -*-
"""为所有 pc_reg 例化补上 BTB 集成新增的 pred_valid / pred_target 两个端口。

背景：Icarus Verilog 10.2 不支持端口默认值（`input wire x = 1'b0`），
因此 pc_reg 的新增端口必须在每个例化处显式连接。标 0 即"不预测"，
行为与集成前逐位一致。

用法：python scripts/patch_pc_reg_ports.py [--check]
  --check  只检查不改写，列出仍缺端口连接的例化
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# 必须同时覆盖 rtl/ 与 verification/：
# 2026-09-28 教训 —— 只扫 verification/ 会漏掉 rtl/core/cpu_core_stage1.sv 的例化，
# 未连接的 input 端口在 Icarus 下悬空为 z，而 `(pred_valid == 1'b1)` 对 z 求值为 x，
# 导致 `pc <= x`、CPU 在第一条指令后挂死。必须显式连接而不是依赖默认值。
TARGETS = [ROOT / "verification", ROOT / "rtl"]


def inst_span(text: str, start: int) -> int:
    """从 start（'pc_reg xxx (' 的 '(' 之后）起，返回第一层括号匹配的下标。"""
    depth = 1
    i = start
    while i < len(text) and depth:
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
        i += 1
    return i


def patch(path: Path, check_only: bool) -> tuple[int, list[str]]:
    text = path.read_text(encoding="utf-8")
    notes: list[str] = []
    pieces, pos, n = [], 0, 0

    for m in re.finditer(r"\bpc_reg\s+\w+\s*\(", text):
        end = inst_span(text, m.end())
        block = text[m.start():end]
        if ".pred_valid" in block:
            continue
        rel = re.search(r"\.pc\s*\(", block)
        if not rel:
            notes.append(f"  ! 未找到 .pc 连接：{path.name}")
            continue
        abs_pc = m.start() + rel.start()
        line_start = text.rfind("\n", 0, abs_pc) + 1
        indent = re.match(r"[ \t]*", text[line_start:]).group(0)
        inj = f"{indent}.pred_valid(1'b0), .pred_target(32'b0),\n"
        pieces.append(text[pos:line_start])
        pieces.append(inj)
        pos = line_start
        n += 1

    pieces.append(text[pos:])
    if n and not check_only:
        path.write_text("".join(pieces), encoding="utf-8")
    return n, notes


def main() -> int:
    check_only = "--check" in sys.argv
    todo = 0
    files = []
    for root in TARGETS:
        files += list(root.rglob("*.sv")) + list(root.rglob("*.v"))
    for f in sorted(set(files)):
        try:
            txt = f.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        if not re.search(r"\bpc_reg\s+\w+\s*\(", txt):
            continue
        n, notes = patch(f, check_only)
        print(f"{'WOULD PATCH' if check_only else 'PATCHED'} {f.name}: {n} 处")
        for note in notes:
            print(note)
        todo += n
    print(f"合计 {'待' if check_only else '已'}修补 {todo} 处")
    return 1 if (check_only and todo) else 0


if __name__ == "__main__":
    sys.exit(main())
