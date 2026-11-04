#!/usr/bin/env python3
"""check_ifstage_mutants.py —— `if_stage` 元数据写点突变**鉴别力检验**（§7.15 制度化）。

## 为什么有这个脚本

2026-10-01 记录的两条教训：
1. **§7.15**：新判据/套件在被称为"守卫"之前，**必须**至少注入一次能让它变红的突变；
2. **§7.2**：突变要覆盖信号的**全部写点**——只改一处会让检验变成**假通过**。

本项目实测：把 `if_stage` 的 `if_out_pred_valid <= req_pred_valid` 改成 `<= 1'b0`
（元数据丢失），当时新跑通的 `pred_payload_stream` 套件**仍然全绿** ⇒ 该套件当时**不是**守卫。
本脚本把这个"鉴别力检验"变成一条**可重复执行的命令**，避免下次靠人记得。

## 用法

    python scripts/check_ifstage_mutants.py           # 逐个写点突变并报告结果
    python scripts/check_ifstage_mutants.py --keep    # 保留突变体（默认删除）

退出码：0 = 至少一处突变被捕获（判据有鉴别力）；1 = **全部突变都未被捕获**（判据无鉴别力）。

## 实现

每个突变体 = `if_stage.sv` 全文 + **一处**写点改为常量 0/1（见 MUTATIONS）。
逐份编译并跑指定 TB，解析 `STREAM-RESULT ... errors=N`：
`errors>0` 即"被捕获"。
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
BUILD = REPO / "build" / "ifstage_mut"
SRC = REPO / "rtl" / "core" / "if_stage.sv"

# (名称, 锚点原文, 替换文本)
# ⚠️ 锚点必须**恰好出现一次**，否则报错退出（源文件重构后不得静默失效）。
MUTATIONS: list[tuple[str, str, str]] = [
    ("ifout_meta_lost",        "                                    if_out_pred_valid  <= req_pred_valid;",
                               "                                    if_out_pred_valid  <= 1'b0;"),
    ("buf_meta_lost",          "                                    buf_pred_valid  <= req_pred_valid;",
                               "                                    buf_pred_valid  <= 1'b0;"),
    ("ifout_taken_lost",       "                                    if_out_pred_taken  <= req_pred_taken;",
                               "                                    if_out_pred_taken  <= 1'b0;"),
    ("ifout_target_lost",      "                                    if_out_pred_target <= req_pred_target;",
                               "                                    if_out_pred_target <= 32'b0;"),
]

TB = "tb_pred_payload_stream.sv"
RTL = ["core/pc_reg.sv", "core/if_stage.sv", "core/if_id.sv", "core/branch_predictor.sv"]
RESULT_RE = re.compile(r"STREAM-RESULT\s+delivered=(\d+)\s+sb_hit=(\d+)\s+holds=(\d+)\s+checks=(\d+)\s+errors=(\d+)")


def run_baseline() -> dict:
    """先跑**未突变**的基线（§7.15：鉴别力必须相对基线判定）。"""
    BUILD.mkdir(parents=True, exist_ok=True)
    vvp = BUILD / "tb_baseline.svvp"
    cmd = ["iverilog", "-g2012", "-I", str(REPO / "rtl" / "core"),
           "-I", str(REPO / "verification" / "unit"),
           "-s", "tb_pred_payload_stream", "-o", str(vvp)]
    for r in RTL:
        cmd.append(str(REPO / "rtl" / r))
    cmd.append(str(REPO / "verification" / "unit" / TB))
    c = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                       errors="replace", timeout=180)
    if c.returncode != 0:
        return {"errors": None, "detail": (c.stderr or "")[-400:]}
    r = subprocess.run(["vvp", str(vvp)], capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=300)
    m = RESULT_RE.search(r.stdout or "")
    if not m:
        return {"errors": None, "detail": (r.stdout or "")[-400:]}
    return {"errors": int(m.group(5)), "delivered": int(m.group(1))}


def run_one(name: str, anchor: str, repl: str) -> dict:
    src = SRC.read_text(encoding="utf-8")
    n = src.count(anchor)
    if n != 1:
        return {"name": name, "error": f"锚点出现 {n} 次（要求 1 次）"}
    BUILD.mkdir(parents=True, exist_ok=True)
    mut = BUILD / f"if_stage_mut_{name}.sv"
    mut.write_text(src.replace(anchor, repl, 1), encoding="utf-8", newline="")

    vvp = BUILD / f"tb_{name}.svvp"
    cmd = ["iverilog", "-g2012", "-I", str(REPO / "rtl" / "core"),
           "-I", str(REPO / "verification" / "unit"),
           "-s", "tb_pred_payload_stream", "-o", str(vvp)]
    # 把 if_stage 换成突变体，其余照常
    for r in RTL:
        cmd.append(str(mut if r.endswith("if_stage.sv") else REPO / "rtl" / r))
    cmd.append(str(REPO / "verification" / "unit" / TB))
    c = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                       errors="replace", timeout=180)
    if c.returncode != 0:
        return {"name": name, "error": "compile", "detail": (c.stderr or "")[-400:]}
    r = subprocess.run(["vvp", str(vvp)], capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=300)
    out = r.stdout or ""
    m = RESULT_RE.search(out)
    if not m:
        return {"name": name, "error": "no-result", "detail": out[-400:]}
    errs = int(m.group(5))
    return {"name": name, "errors": errs, "caught": None,   # caught 由 main 相对基线判定
            "delivered": int(m.group(1)), "sb_hit": int(m.group(2))}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()

    # ⚠️ 坑位：Windows 控制台默认 GBK，脚本里打印 ✅/❌ 会抛
    #   `UnicodeEncodeError: 'gbk' codec can't encode character '\u2705'`
    #   ⇒ 结果表**一行都没打出来**就被异常打断，看起来像"脚本坏了"。
    #   正确做法：显式把 stdout 切到 UTF-8（errors="replace" 兜底），不要靠控制台代码页
    #   （见 同类编码往返不一致问题）。
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, OSError):
        pass

    rows = [run_one(*m) for m in MUTATIONS]
    caught = 0
    print("## if_stage 元数据写点突变 × pred_payload_stream（§7.15 鉴别力检验）")
    print(f"| 行 | 结果 | errors | sb_hit |")
    print("|---|---|---|---|")

    # ⚠️⚠️ 坑位（**判据本身的假绿，2026-10-01 第 13 轮修掉**）：
    #   旧判据是 `caught = errors > 0`。**当基线本身已经非绿时**（本项目曾出现
    #   基线 errors=2），突变体同样 errors=2 也会被判成"已捕获" ⇒ 打印"捕获 4/4"
    #   而**实际毫无鉴别力**。这正是 §7.15 想防的假绿，却由 §7.15 的检验脚本自己造出来。
    #   正确判据：**先跑基线**，只有 `突变 errors > 基线 errors`（严格多）才算捕获；
    #   且基线非绿时必须显式声明"判据的鉴别力不可判定（基线未绿）"。
    base = run_baseline()
    if base["errors"] is None:
        print("| **基线** | **编译/运行失败** | — | — |")
        print(f"\n基线无法运行：{base.get('detail','')}")
        return 1
    base_errs = base["errors"]
    base_tag = "✅ 全绿" if base_errs == 0 else f"❌ 非绿（errors={base_errs}）"
    print(f"| **基线（未突变）** | {base_tag} | {base_errs} | {base.get('delivered','—')} delivered |")

    for r in rows:
        if "error" in r:
            print(f"| {r['name']} | **{r['error']}** | — | — |")
        else:
            r["caught"] = r["errors"] > base_errs     # 相对基线：必须**多**变红
            tag = "✅ 已捕获" if r["caught"] else "❌ **未捕获**"
            caught += 1 if r["caught"] else 0
            print(f"| {r['name']} | {tag} | {r['errors']} | {r['sb_hit']} |")
    print()
    print(f"捕获 {caught}/{len(rows)}（判据：突变 errors 必须**严格大于**基线 {base_errs}）")
    if base_errs != 0:
        print("⚠️ **基线非绿 ⇒ 本判据的鉴别力不可判定**：不得据此宣称'有鉴别力'或'已收口'。")
    if caught == 0:
        print("⇒ **该判据当前无鉴别力**（全部突变都未比基线更多变红）——不得称其为守卫（§7.15）。")
    if not args.keep and BUILD.exists():
        for f in BUILD.glob("*"):
            try:
                f.unlink()
            except OSError:
                pass
    return 0 if caught > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
