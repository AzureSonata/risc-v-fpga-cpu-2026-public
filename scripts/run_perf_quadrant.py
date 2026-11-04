#!/usr/bin/env python3
"""run_perf_quadrant.py —— (d-3) 性能四象限重测。

依据：docs/architecture/ADR-CACHE-INTEGRATION.md §D-C6
  「以 ICACHE_ENABLE/DCACHE_ENABLE 四象限跑性能 TB，四组数字写进 ADR 的收尾批次；
    差异必须归因（miss 率 × 填充拍数 = 桥 4 单字 + adapter 时延）」

为什么用脚本而不是一次仿真跑四个象限：
  `ICACHE_ENABLE/DCACHE_ENABLE` 是 **elaboration-time parameter**，同一仿真内只能取一组值。
  Icarus 10.2 的 `-P` 覆盖偶有怪癖（本项目实测过），故本脚本**为每个象限生成一份 TB 副本
  并改写 `parameter IC/DC` 默认值**，逐象限编译运行——最稳且与工具无关。

⚠️ 坑位：本脚本**必须用 Python 写文件**（显式 UTF-8、`newline=""`）。
  PowerShell 的 `Get-Content -Raw` 会按 cp936 猜编码毁掉中文注释并吞换行；
  `Set-Content -Encoding UTF8` 会写 BOM 让 Icarus 10.2 静默跳过整个 .sv。
  （见 各配置象限均被覆盖）

用法：
  python scripts/run_perf_quadrant.py            # 跑四象限并打印表
  python scripts/run_perf_quadrant.py --json     # 额外输出机器可读 JSON
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

# ⚠️ 坑位：Windows 默认 cp936 控制台下打印 ✅/⚠️ 会抛 UnicodeEncodeError，
# 导致四象限 JSON 已正确写出却以 exit 1 结束（本项目 2026-10-06 实测）。
# 与 run_tests.py 一致：显式把 stdout 重配置为 UTF-8；失败也不影响主逻辑。
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

REPO = Path(__file__).resolve().parents[1]
BUILD = REPO / "build" / "perf_quadrant"
TB_SRC = REPO / "verification" / "system" / "tb_perf_quadrant.sv"

# 被测链路的 RTL —— **与 run_tests.py 的 cpu_mem_subsystem 清单逐字一致**
# （顺序无关，但必须齐全；缺文件会直接编译失败）
RTL = [
    "core/pc_reg.sv", "core/branch_predictor.sv", "core/if_stage.sv", "core/if_id.sv",
    "core/id_stage.sv", "core/csr_file.sv", "core/id_ex_reg.v", "core/pipeline_control.v",
    "core/forwarding_unit.v", "core/hazard_detection.v", "core/riscv_alu.sv",
    "core/riscv_exec.sv", "core/riscv_lsu.sv", "core/regfile.v", "core/wb_stage.v",
    "core/retire_trace.v", "core/cpu_core_stage1.sv",
    "soc/addr_decode.sv", "soc/mem_map_adapter.sv", "soc/cpu_mem_subsystem.sv",
    "memory/rom.sv", "memory/sram.sv", "memory/icache.sv", "memory/dcache.sv",
    "memory/mem_burst_bridge.sv", "memory/cache_path.sv",
    "periph/gpio.sv", "periph/timer.sv", "periph/uart.sv",
]

RESULT_RE = re.compile(
    r"PERF-RESULT IC=(\d) DC=(\d) cyc=(\d+) inst=(\d+) spin=(\d+) x1=(-?\d+) trap=(\d)"
)
CACHE_RE = re.compile(
    r"PERF-CACHE\s+IC=(\d) DC=(\d) ic_hit=(\d+) ic_miss=(\d+) dc_hit=(\d+) dc_miss=(\d+) dc_store=(\d+)"
)


def make_tb(ic: int, dc: int, loop_n: int = 8) -> Path:
    """按象限生成 TB 副本（改写 parameter 默认值）。"""
    src = TB_SRC.read_text(encoding="utf-8")
    old_ic = "    parameter IC = 1'b1;"
    old_dc = "    parameter DC = 1'b1;"
    old_ln = "    parameter integer LOOP_N = 8;"
    for anchor in (old_ic, old_dc, old_ln):
        if src.count(anchor) != 1:
            raise SystemExit(f"锚点 {anchor!r} 出现 {src.count(anchor)} 次（要求 1 次）")
    dst_text = src.replace(old_ic, f"    parameter IC = 1'b{ic};").replace(
        old_dc, f"    parameter DC = 1'b{dc};"
    ).replace(old_ln, f"    parameter integer LOOP_N = {loop_n};")
    out = BUILD / f"tb_perf_q_ic{ic}_dc{dc}_n{loop_n}.sv"
    out.write_text(dst_text, encoding="utf-8", newline="")
    return out


def expected_sum(loop_n: int) -> int:
    """与 TB 的 EXPECT_SUM 同源：28+29+...+(28+N-1)。"""
    return loop_n * 28 + loop_n * (loop_n - 1) // 2


def run_one(ic: int, dc: int, loop_n: int = 8) -> dict:
    tb = make_tb(ic, dc, loop_n)
    vvp = BUILD / f"q_ic{ic}_dc{dc}_n{loop_n}.svvp"
    cmd = ["iverilog", "-g2012", "-I", str(REPO / "rtl" / "core"),
           "-I", str(REPO / "verification" / "unit"),
           "-s", "tb_perf_quadrant", "-o", str(vvp)]
    cmd += [str(REPO / "rtl" / r) for r in RTL]
    cmd += [str(tb)]
    c = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=180)
    if c.returncode != 0:
        return {"ic": ic, "dc": dc, "error": "compile", "detail": (c.stderr or "")[-800:]}
    r = subprocess.run(["vvp", str(vvp)], capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=300)
    out = r.stdout or ""
    m = RESULT_RE.search(out)
    c2 = CACHE_RE.search(out)
    if not m:
        return {"ic": ic, "dc": dc, "error": "no-result", "detail": out[-800:]}
    res = {
        "ic": ic, "dc": dc,
        "cyc": int(m.group(3)), "inst": int(m.group(4)),
        "spin": int(m.group(5)), "x1": int(m.group(6)), "trap": int(m.group(7)),
        "cpi": round(int(m.group(3)) / max(1, int(m.group(4))), 4),
        # ⚠️ 坑位：程序已改为"自写 SRAM 再读回"，累加和期望值是 **252**（28+29+…+35），
        #    首版沿用旧的 28 ⇒ `correct` 恒 False（exit 1、表格显示 ⚠️），
        #    很容易被误读成"性能自检没过"。期望值与程序必须同源更新。
        "correct": int(m.group(6)) == expected_sum(loop_n) and int(m.group(5)) == 1,
    }
    if c2:
        res.update({
            "ic_hit": int(c2.group(3)), "ic_miss": int(c2.group(4)),
            "dc_hit": int(c2.group(5)), "dc_miss": int(c2.group(6)),
            "dc_store": int(c2.group(7)),
        })
    return res


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true", help="额外写机器可读 JSON")
    ap.add_argument("--loop-n", type=int, default=8,
                    help="循环圈数（默认 8 = 原程序；N>8 提高时间局部性，"
                         "用于测 I-Cache 的「命中收益 vs 缺失惩罚」平衡点）")
    args = ap.parse_args()

    BUILD.mkdir(parents=True, exist_ok=True)
    rows = []
    for ic in (0, 1):
        for dc in (0, 1):
            r = run_one(ic, dc, args.loop_n)
            rows.append(r)
            tag = f"IC={ic} DC={dc}"
            if "error" in r:
                print(f"  ❌ {tag}: {r['error']}  {r.get('detail','')[:200]}")
            else:
                print(f"  {'✅' if r['correct'] else '⚠️ '} {tag}: cyc={r['cyc']:>5} inst={r['inst']:>4} "
                      f"CPI={r['cpi']:.4f}  ic={r.get('ic_hit','?')}/{r.get('ic_miss','?')} "
                      f"dc={r.get('dc_hit','?')}/{r.get('dc_miss','?')} x1={r['x1']}")

    ok = [r for r in rows if "error" not in r and r["correct"]]
    # ⚠️ 坑位：`correct` 为 True 时也要打 ✅ —— 首版写成 `'✅' if r['correct'] else '⚠️ '`
    #    的极性正确，但因 x1 判据用 `!==` 与整数比较在 Icarus 下返回 1'x 导致误判为 False，
    #    表现为"结果明明对却全是 ⚠️"。改为同时接受 int/逻辑真值并打印原始 x1 供核对。

    print()
    print("## (d-3) 性能四象限（ICACHE_ENABLE × DCACHE_ENABLE）")
    print("| ICACHE | DCACHE | cycles | inst | CPI | I$ hit/miss | D$ hit/miss |")
    print("|---|---|---|---|---|---|---|")
    for r in rows:
        if "error" in r:
            print(f"| {r['ic']} | {r['dc']} | — | — | — | — | **{r['error']}** |")
        else:
            print(f"| {r['ic']} | {r['dc']} | {r['cyc']} | {r['inst']} | {r['cpi']:.4f} | "
                  f"{r.get('ic_hit','-')}/{r.get('ic_miss','-')} | {r.get('dc_hit','-')}/{r.get('dc_miss','-')} |")

    if len(ok) == 4:
        base = next(r for r in ok if r["ic"] == 0 and r["dc"] == 0)
        print()
        print("### 相对基线（IC=0/DC=0）的收益")
        for r in ok:
            d = base["cyc"] - r["cyc"]
            pct = (d * 100.0 / base["cyc"]) if base["cyc"] else 0.0
            print(f"- IC={r['ic']} DC={r['dc']}: cycles {base['cyc']} → {r['cyc']} "
                  f"（省 {d} 拍，{pct:+.1f}%），CPI {base['cpi']:.4f} → {r['cpi']:.4f}")

    if args.json:
        out = REPO / "build" / "perf_quadrant" / "quadrant.json"
        out.write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding="utf-8", newline="")
        print(f"\nJSON: {out}")

    return 0 if len(ok) == 4 else 1


if __name__ == "__main__":
    sys.exit(main())
