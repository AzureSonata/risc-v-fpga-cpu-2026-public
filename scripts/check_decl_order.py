#!/usr/bin/env python3
"""check_decl_order.py —— 全仓库"先用后声明"静态检查（可移植性门禁）。

## 为什么有这个脚本（2026-10-01，峥榕在 Icarus 13.0 的复现）

`rtl/core/cpu_core_stage1.sv` 里有 4 处**先用后声明**：
`ex_pred_taken_q/ex_pred_target_q`（用在 L398、声明在 L419-420）、
`csr_mepc/csr_mtvec`（用在 L413、声明在 L702）、`xm_is_mret`（用在 L496、声明在 L628）。

- **Icarus 10.2（本机 CI 用的版本）容忍**：静默把后置声明与前面的名字合并，
  `-Wall` 连告警都没有，跑出来 **805 PASS / 0 FAIL**；
- **Icarus 13.0 直接编译失败** ⇒ 7 个套件全红（`id_stage`、`cpu_core_mem_subsystem`、
  `cpu_core_btb/csr/trap/irq`、`icache_off`），负控 18 条"突变体编译失败"。

⇒ 这是**只在一个工具版本上成立的绿**：同一个提交、不同版本的 Icarus 给出相反结论。
风险还不止"编译失败"：若某版本选择**造隐式 1 位网**而不是合并（§7.3 的实证行为），
就会把 32 位 CSR 重定向目标**静默截断**——比编译失败危险得多。

本脚本用**正则静态扫描**把这一类一次性找全（不依赖任何仿真器），退出码非零即阻塞。

## 判据

对每个文件、每个 module：先收集**模块级声明**（`wire/reg/logic/integer/...`，含 ANSI 端口列表）
得到 `名 -> 声明行`；再扫描代码中每个标识符的**首次使用行**；
若 `首次使用行 < 声明行` ⇒ 报一条。

## 已知局限（宁可漏报，不要误报）

- 不解析 `generate`/`function`/`task`/`begin` 作用域内的局部声明（会被当作模块级）⇒
  可能把"局部同名变量"误判为已声明（**漏报**）；
- 多行声明只取**起始行**（同一行里的多个名字共享该行号）⇒ 不产生误报；
- 注释与字符串会先被剥离；`` `define / `ifdef `` 不动（条件编译下的声明照常收集）。
- 因此本脚本的定位是**廉价的兜底门禁**，不是形式化工具。

## 用法

    python scripts/check_decl_order.py                # 检查 rtl/ （默认）
    python scripts/check_decl_order.py --roots rtl verification
    python scripts/check_decl_order.py --all          # 含 verification/ 与 external/
    python scripts/check_decl_order.py --verbose      # 打印每个文件的声明统计

退出码：0 = 无先用后声明；1 = 存在（列出 文件:行:名字）。
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]

# 模块级声明的关键字（ANSI 端口列表里的 input/output 也在此列）
DECL_KW = r"(?:input|output|inout|wire|reg|logic|integer|int|localparam|parameter|genvar|real|time|bit)"
# 例：wire [31:0] a, b;   /  reg  a;   /  output reg [1:0] x, y,   （端口列表项以逗号结尾）
# ⚠️ 坑位（本脚本第一版的两个假阳性来源，2026-10-01 实测）：
#   ① 结尾只允许 `;` ⇒ **ANSI 端口列表里以 `,` 结尾的行全部漏收集**，于是头部的端口
#      （如 `input wire [31:0] inst_i,`）被当成"未声明"，再被后面的同名/无关行配成"先用后声明"；
#   ② 未剥离数字字面量 `1'b0` / `7'b0010111` ⇒ `b0` 被当成标识符 ⇒ 误报 `b0` 先用后声明。
#   ③ 未剥离具名端口连接的**形式名** `.ex_valid(...)` ⇒ 把实例的形式名当成"本地信号使用"，
#      误报 `ex_valid/ex_writes_rd/ex_rd`（它们在 L273 才声明，而 L240 只是端口名）。
#   教训：**检查脚本自己也要按 §7.15 做"假阳性/假阴性"核对**，否则会指挥人去改没问题的代码。
DECL_RE = re.compile(
    r"^\s*(?:" + DECL_KW + r")\b"
    r"(?P<rest>[^;=]*)"
    r"(?:=[^;]*)?[,;]")
# 取标识符（跳过关键字与位宽里的数字）
IDENT_RE = re.compile(r"[A-Za-z_][A-Za-z_0-9]*")
NUM_LIT_RE = re.compile(r"\d*'[sS]?[bBoOdDhH][0-9a-fA-FxXzZ_]+")
PORT_FORMAL_RE = re.compile(r"\.\s*[A-Za-z_][A-Za-z_0-9]*")
KEYWORDS = {
    "input", "output", "inout", "wire", "reg", "logic", "integer", "int",
    "localparam", "parameter", "genvar", "real", "time", "bit", "signed",
    "unsigned", "reg", "wire", "assign", "always", "always_comb", "always_ff",
    "begin", "end", "if", "else", "case", "endcase", "for", "while", "function",
    "endfunction", "task", "endtask", "module", "endmodule", "generate",
    "endgenerate", "posedge", "negedge", "default", "return", "initial",
}

MODULE_RE = re.compile(r"^\s*module\s+([A-Za-z_][A-Za-z_0-9]*)")


def strip_comments_and_strings(text: str) -> str:
    """剥离 // 与 /* */ 注释、字符串，避免把注释里的说明文字当代码（保留换行数以维持行号）。"""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
        elif c == "/" and i + 1 < n and text[i + 1] == "*":
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                if text[i] == "\n":
                    out.append("\n")
                i += 1
            i += 2
        elif c == '"':
            i += 1
            while i < n and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
            i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def decl_names(rest: str) -> list[str]:
    """从声明尾部（去掉关键字后的部分）取出所有被声明的名字。"""
    rest = re.sub(r"\[[^\]]*\]", " ", rest)          # 去掉位宽
    rest = re.sub(r"\b(?:signed|unsigned|logic|reg|var)\b", " ", rest)
    names = []
    for part in rest.split(","):
        ids = [m.group(0) for m in IDENT_RE.finditer(part)]
        ids = [x for x in ids if x not in KEYWORDS]
        if ids:
            names.append(ids[0])                     # 逗号段的首个标识符即被声明名
    return names


def check_file(path: Path) -> list[tuple[int, str, int]]:
    """返回 [(使用行, 名字, 声明行), ...]（1-based 行号）。"""
    raw = path.read_text(encoding="utf-8", errors="replace")
    text = strip_comments_and_strings(raw)
    lines = text.split("\n")

    decls: dict[str, int] = {}
    # 模块头（module ... );）整段当作"声明区"：ANSI 端口/参数都在这里，且可能跨很多行。
    # ⚠️ 坑位（第二类假阳性，实测 12 条）：**非 ANSI 头**（`module tb_x;`，测试台常见）没有端口列表，
    #   而"下一个 `);`"要等到 **DUT 例化的收尾括号** ⇒ 若照此把 9~30 行都当头部，会
    #   ①漏收集行内的多段声明（`reg a; reg b;` 只收前半段），
    #   ②把例化端口列表里的**实参名**误当成"声明" ⇒ 于是真正的声明行被判成"使用在声明之后"。
    #   正确判据：只有 `module` 那一行**含 `(`** 才可能存在跨行端口列表；否则头部就是那一行。
    header_span: set[int] = set()
    module_start: int | None = None
    header_multiline = False
    for idx, line in enumerate(lines, start=1):
        if MODULE_RE.match(line):
            module_start = idx
            header_multiline = ("(" in line) and not re.search(r"\)\s*;", line)
            header_span.add(idx)
            continue
        if module_start is None:
            continue
        if header_multiline:
            header_span.add(idx)
            if re.search(r"\)\s*;", line):
                header_multiline = False
        else:
            module_start = None

    for idx, line in enumerate(lines, start=1):
        if idx in header_span:
            # 头部内的端口/参数：逐个取标识符中"像名字"的那些（关键字与数字字面量已剥离）
            body = NUM_LIT_RE.sub(" ", re.sub(r"^\s*module\b", " ", line))
            body = re.sub(r"^\s*" + DECL_KW + r"\b", " ", body)
            for part in body.split(","):
                ids = [x for x in IDENT_RE.findall(part) if x not in KEYWORDS]
                if ids:
                    decls.setdefault(ids[-1], idx)   # 端口名在行尾（`input wire [31:0] inst_i`）
            continue
        if not DECL_RE.match(line):
            continue
        rest = line.strip()
        rest = re.sub(r"^\s*" + DECL_KW + r"\b", " ", rest)
        rest = rest.rstrip(",;")
        for name in decl_names(rest):
            decls.setdefault(name, idx)              # 首次声明行
    if not decls:
        return []

    first_use: dict[str, int] = {}
    for idx, line in enumerate(lines, start=1):
        scan = NUM_LIT_RE.sub(" ", line)             # 剥数字字面量（1'b0 → 不是标识符 b0）
        scan = PORT_FORMAL_RE.sub(" ", scan)          # 剥具名端口连接的形式名 .foo(
        for m in IDENT_RE.finditer(scan):
            name = m.group(0)
            if name in decls and name not in first_use:
                first_use[name] = idx

    bad = []
    for name, use_line in first_use.items():
        decl_line = decls[name]
        # 同行算合法（ANSI 端口/同行声明+使用）；只有**严格早于**声明行才报
        if use_line < decl_line:
            bad.append((use_line, name, decl_line))
    # ⚠️ 只报"疑似真前向引用"：若该名字在文件中出现次数很多，多半是端口/实例名之类的
    #    结构性名字（本脚本不建符号表），为避免**误报指挥人改代码**，这里不额外过滤，
    #    而是在 log 中提醒"逐条人工核对"（见 §7.15：检查脚本自身也要核对假阳性）。
    return sorted(bad)


def iter_files(roots: list[Path]):
    for root in roots:
        if not root.exists():
            continue
        for ext in ("*.sv", "*.v"):
            for f in sorted(root.rglob(ext)):
                # ⚠️ 排除"自检语料"目录：`verification/selftest/` 里**故意**含先用后声明，
                #   用于证明本门禁有鉴别力（§7.15）。若算进默认扫描，门禁会一直报红
                #   ⇒ 真违规被淹没（"狼来了"）。**显式把该目录本身当作 root** 时仍会扫它。
                #   坑位：本条第一版把判断写成 `parts[-2] != "selftest"` ⇒ 恰好把自检文件
                #   放行、把真正的排除判反了；判据要"正反都验一次"再收工。
                if "selftest" in f.parts and root.name != "selftest":
                    continue
                yield f


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, OSError):
        pass

    ap = argparse.ArgumentParser()
    ap.add_argument("--roots", nargs="*", default=["rtl"],
                    help="要扫描的目录（相对仓库根；默认 rtl）")
    ap.add_argument("--all", action="store_true",
                    help="扫描 rtl/ + verification/ + external/")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    if args.all:
        names = ["rtl", "verification", "external"]
    else:
        names = args.roots
    roots = [REPO / n for n in names]

    total_files = 0
    hits = 0
    print("## 先用后声明静态检查（可移植性门禁，见 E:\\CPU\\AGENTS.md §7.19）")
    print(f"扫描范围：{', '.join(names)}")
    for f in iter_files(roots):
        total_files += 1
        bad = check_file(f)
        if args.verbose and bad:
            print(f"  [检查] {f.relative_to(REPO)}")
        for use_line, name, decl_line in bad:
            hits += 1
            print(f"  ❌ {f.relative_to(REPO)}:{use_line}: `{name}` 先用后声明（声明在 L{decl_line}）")
    print()
    if hits:
        print(f"⇒ 发现 {hits} 处先用后声明（扫描 {total_files} 个文件）。")
        print("   Icarus 10.2 容忍、**13.0 编译失败**；某些版本还可能造隐式 1 位网而**静默截断**。")
        print("   修法：把声明上提到首次使用之前（不要依赖工具宽容）。")
        return 1
    print(f"✅ 无先用后声明（扫描 {total_files} 个文件）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
