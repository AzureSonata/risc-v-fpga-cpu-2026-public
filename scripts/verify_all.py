#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
按项目验收要求执行 Stage1 + Stage2 全量检核，并生成报告。

依据：
- governance/REVIEW_POLICY.md  「按证据类型验收」「证据最小字段」「Review 顺序」
- docs/architecture/TECHNICAL_BASELINE.md「验证、性能和工具策略」
- docs/collaboration/EXECUTION_LOG_POLICY.md

产出：
- build/verification_report.json   机器可读
- build/verification_report.md     人读（可直接贴入执行说明）

退出码：0=全部 PASS；1=存在 FAIL。
"""
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

REPO = Path(__file__).resolve().parents[1]
BUILD = REPO / "build"
BUILD.mkdir(exist_ok=True)
os.chdir(REPO)

# ---- 用例：(名称, RTL 文件, TB 文件, top module, 期望断言数) ----
CASES = [
    ("pc_reg",            ["rtl/core/pc_reg.v"], "verification/unit/tb_pc_reg.v", "tb_pc_reg", 8),
    ("if_stage",          ["rtl/core/if_stage.v"], "verification/unit/tb_if_stage.v", "tb_if_stage", 9),
    ("if_id",             ["rtl/core/if_id.v"], "verification/unit/tb_if_id.v", "tb_if_id", 5),
    ("id_stage",          ["rtl/core/id_stage.v"], "verification/unit/tb_id_stage.v", "tb_id_stage", 12),
    ("frontend",          ["rtl/core/pc_reg.v", "rtl/core/if_stage.v", "rtl/core/if_id.v",
                           "rtl/core/id_stage.v"], "verification/unit/tb_frontend.v", "tb_frontend", 12),
    ("branch_predictor",  ["rtl/core/branch_predictor.v"], "verification/unit/tb_branch_predictor.v",
                          "tb_branch_predictor", 19),
    ("predictor_flow",    ["rtl/core/branch_predictor.v"], "verification/unit/tb_predictor_flow.v",
                          "tb_predictor_flow", 10),
]

PASS_RE = re.compile(r"^\s*PASS\b")
FAIL_RE = re.compile(r"^\s*FAIL\b")
WARN_RE = re.compile(r":\s*warning:", re.I)


def run(cmd, timeout=90):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True,
                           encoding="utf-8", errors="replace", timeout=timeout)
        return r.returncode, (r.stdout or ""), (r.stderr or "")
    except subprocess.TimeoutExpired:
        return 124, "", "TIMEOUT"
    except FileNotFoundError as e:
        return 127, "", str(e)


def tool_version(cmd):
    rc, out, err = run(cmd, timeout=30)
    return ((out + err).strip().splitlines() or ["NOT_FOUND"])[0]


def git_meta():
    rc, out, _ = run(["git", "rev-parse", "HEAD"], timeout=20)
    head = out.strip() if rc == 0 else "UNKNOWN"
    rc, out, _ = run(["git", "status", "--porcelain"], timeout=20)
    dirty = bool(out.strip())
    return head, dirty


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


# ============================================================================
# 接口核对：RTL 端口 vs 冻结契约
# ============================================================================
EXPECTED_PORTS = {
    "pc_reg": ["clk", "rst", "redirect_valid", "redirect_target", "hold_pc", "pc"],
    "if_stage": ["clk", "rst", "pc", "redirect_valid", "hold_if", "flush_if",
                 "i_req_valid", "i_req_ready", "i_req_addr", "i_req_epoch",
                 "i_rsp_valid", "i_rsp_ready", "i_rsp_data", "i_rsp_error", "i_rsp_epoch",
                 "if_valid", "if_pc", "if_inst", "if_fault"],
    "if_id": ["clk", "rst", "if_valid_i", "if_pc_i", "if_inst_i", "if_fault_i",
              "hold_if_id", "flush_if_id", "id_valid_o", "id_pc_o", "id_inst_o", "id_fault_o"],
    "id_stage": ["rst", "inst_i", "pc_i", "inst_valid_i", "ex_jump_flag_i",
                 "rs1_addr_o", "rs2_addr_o", "imm_o", "reg_we_o", "rd_addr_o",
                 "mem_req_o", "mem_we_o", "mem_wstrb_o", "branch_o", "jal_o", "jalr_o",
                 "lui_o", "auipc_o", "uses_rs1_o", "uses_rs2_o",
                 "opcode_o", "funct3_o", "funct7_o", "rd_o"],
    "branch_predictor": ["clk", "rst", "q_valid", "q_pc", "q_hit", "q_taken", "q_target",
                         "u_valid", "u_pc", "u_taken", "u_target", "u_pred_taken", "u_pred_target",
                         "stat_clr", "stat_query", "stat_hit", "stat_mispredict"],
}

# 技术路线冻结的 I 端口最小集合（write/wdata/wstrb 对只读 I 口不适用）
FROZEN_I_MIN = {"i_req_valid", "i_req_ready", "i_req_addr",
                "i_rsp_valid", "i_rsp_ready", "i_rsp_data", "i_rsp_error"}
# 冻结列表未列出、但实现存在的信号 → 需接口变更请求/文档明确的观察项
I_PORT_OBSERVATIONS = {"i_req_epoch", "i_rsp_epoch"}

KEYWORDS = {"wire", "reg", "logic", "signed", "unsigned"}


def module_ports(path, module):
    src = Path(path).read_text(encoding="utf-8")
    m = re.search(r"module\s+" + re.escape(module) +
                  r"\s*(?:#\s*\([^;]*?\)\s*)?\((.*?)\)\s*;", src, re.S)
    if not m:
        return None
    header = re.sub(r"//[^\n]*", "", m.group(1))
    header = re.sub(r"/\*.*?\*/", "", header, flags=re.S)
    ports = []
    for d in re.finditer(r"\b(input|output|inout)\b([^,;]*)", header):
        names = [n for n in re.findall(r"[A-Za-z_]\w*", d.group(2)) if n not in KEYWORDS]
        if names:
            ports.append(names[-1])
    return ports


def check_interfaces():
    results = []
    for module, expected in EXPECTED_PORTS.items():
        path = next((c[1][0] for c in CASES if c[0] == module), None)
        if module == "frontend":
            continue
        if path is None:
            continue
        actual = module_ports(path, module)
        if actual is None:
            results.append({"module": module, "status": "FAIL", "detail": "module header not parsed"})
            continue
        missing = [p for p in expected if p not in actual]
        extra = [p for p in actual if p not in expected]
        st = "PASS" if not missing and not extra else "FAIL"
        results.append({"module": module, "status": st, "missing": missing, "extra": extra,
                        "actual": actual})
    # I 端口相对冻结契约
    ifp = module_ports("rtl/core/if_stage.v", "if_stage") or []
    missing_frozen = sorted(FROZEN_I_MIN - set(ifp))
    obs = sorted(I_PORT_OBSERVATIONS & set(ifp))
    results.append({"module": "if_stage:I-port-vs-frozen", "status": "PASS" if not missing_frozen else "FAIL",
                    "missing_from_impl": missing_frozen,
                    "observations": obs})
    return results


# ============================================================================
# 用例执行
# ============================================================================
def run_case(name, rtl, tb, top, expected):
    vvp = BUILD / f"verify_{name}.vvp"
    cmd = ["iverilog", "-g2012", "-Wall", "-I", "rtl/core", "-I", "verification/unit",
           "-s", top, "-o", str(vvp)] + list(rtl) + [tb]
    rc, out, err = run(cmd, timeout=90)
    warns = len(WARN_RE.findall((out or "") + (err or "")))
    warn_lines = [l.strip() for l in ((out or "") + "\n" + (err or "")).splitlines() if WARN_RE.search(l)]
    rec = {"name": name, "compile_cmd": " ".join(cmd), "compile_rc": rc,
           "compile_warnings": warns, "warning_lines": warn_lines[:5],
           "expected_assertions": expected,
           "inputs_sha256": {p: sha256(p) for p in list(rtl) + [tb]},
           "waveform": f"build/tb_{name}.vcd"}
    if rc != 0:
        rec.update(status="FAIL", reason="compile error",
                   compile_err=(err or "")[-500:])
        return rec
    rc2, out2, err2 = run(["vvp", str(vvp)], timeout=120)
    txt = (out2 or "") + "\n" + (err2 or "")
    np = sum(1 for l in txt.splitlines() if PASS_RE.match(l))
    nf = sum(1 for l in txt.splitlines() if FAIL_RE.match(l))
    timed = ("TIMEOUT" in txt) and ("ALL TESTS PASSED" not in txt)
    has_summary = ("ALL TESTS PASSED" in txt) or ("ALL INTEGRATION TESTS PASSED" in txt)
    ok = (rc2 == 0) and nf == 0 and np == expected and has_summary and not timed
    rec.update(sim_rc=rc2, assertions_pass=np, assertions_fail=nf,
               has_pass_marker=has_summary, sim_timeout=timed,
               status="PASS" if ok else "FAIL",
               reason="" if ok else f"np={np}/{expected} nf={nf} timeout={timed} marker={has_summary}")
    rec["waveform_exists"] = (REPO / rec["waveform"]).is_file()
    return rec


def negative_control():
    """按 REVIEW_POLICY：用已知错误确认测试能失败。"""
    negdir = BUILD / "verify_negctl"
    negdir.mkdir(parents=True, exist_ok=True)
    src = Path("verification/unit/tb_pc_reg.v").read_text(encoding="utf-8")
    patched = src.replace("32'h0000000c", "32'h0000000d")
    patched_flag = patched != src
    tbf = negdir / "tb_pc_reg_neg.v"
    tbf.write_text(patched, encoding="utf-8", newline="")
    vvp = negdir / "neg.vvp"
    cmd = ["iverilog", "-g2012", "-Wall", "-I", "rtl/core", "-s", "tb_pc_reg",
           "-o", str(vvp), "rtl/core/pc_reg.v", str(tbf)]
    rc, out, err = run(cmd, timeout=90)
    if rc != 0:
        return {"status": "FAIL", "reason": "negative control failed to compile",
                "patched": patched_flag, "err": (err or "")[-300:]}
    rc2, out2, err2 = run(["vvp", str(vvp)], timeout=60)
    txt = (out2 or "") + "\n" + (err2 or "")
    nf = sum(1 for l in txt.splitlines() if FAIL_RE.match(l))
    has_pass = "ALL TESTS PASSED" in txt
    detected = nf > 0 and not has_pass
    return {"status": "PASS" if (patched_flag and detected) else "FAIL",
            "reason": "" if detected else "harness did not detect injected fault",
            "patched": patched_flag, "fail_lines": nf, "false_pass_marker": has_pass}


# ============================================================================
# 报告
# ============================================================================
def build_markdown(rep):
    L = []
    A = L.append
    A("# Stage1 + Stage2 全量检核报告")
    A("")
    A(f"- 生成时间：{rep['generated_at']}")
    A(f"- 基线 commit：`{rep['commit']}` ｜ dirty：{rep['dirty']}")
    A(f"- 工具：{rep['tools']['iverilog']} ｜ {rep['tools']['vvp']} ｜ Python {rep['tools']['python']}")
    A(f"- 依据：governance/REVIEW_POLICY.md、docs/architecture/TECHNICAL_BASELINE.md")
    A("")
    A("## 1. 用例结果")
    A("")
    A("| 用例 | 编译 | 警告 | 断言 PASS | 期望 | FAIL | 退出码 | 波形 | 状态 |")
    A("|------|------|------|-----------|------|------|--------|------|------|")
    for c in rep["cases"]:
        A(f"| {c['name']} | rc={c['compile_rc']} | {c.get('compile_warnings','-')} | "
          f"{c.get('assertions_pass','-')} | {c['expected_assertions']} | {c.get('assertions_fail','-')} | "
          f"{c.get('sim_rc','-')} | {'✓' if c.get('waveform_exists') else '✗'} | {c['status']} |")
    A("")
    A(f"**合计断言：{rep['total_pass']} PASS / {rep['total_fail']} FAIL**")
    A("")
    A("### 1.1 编译警告（逐条解释，不得静默）")
    A("")
    _anyw = False
    for _c in rep["cases"]:
        for _w in _c.get("warning_lines", []):
            A(f"- `{_c['name']}`：`{_w}`"); _anyw = True
    if not _anyw:
        A("- 无")
    else:
        A("")
        A("> 说明：以上为 Icarus 的 timescale 提示——`rtl/core/*.v` 未声明 `timescale`，而 testbench 声明了 `1ns/1ps`。")
        A("> 功能仿真不受影响（延时只在 TB 中），但建议 RTL 显式声明时间单位或由顶层统一，避免后续时序误判。属**观察项**。")
    A("")
    A("## 2. 负向对照（REVIEW_POLICY：必须证明测试能失败）")
    A("")
    n = rep["negative_control"]
    A(f"- 注入故障：篡改 `tb_pc_reg.v` 期望值 | 检出 FAIL 行数={n.get('fail_lines')} | "
      f"是否误报通过={n.get('false_pass_marker')} | 状态：**{n['status']}**")
    A("")
    A("## 3. 接口核对")
    A("")
    A("| 模块 | 状态 | 缺失 | 多余 |")
    A("|------|------|------|------|")
    for i in rep["interfaces"]:
        A(f"| {i['module']} | {i['status']} | {','.join(i.get('missing', i.get('missing_from_impl', []))) or '-'} | "
          f"{','.join(i.get('extra', [])) or '-'} |")
    A("")
    obs = next((i for i in rep["interfaces"] if i["module"] == "if_stage:I-port-vs-frozen"), None)
    if obs and obs.get("observations"):
        A(f"> **观察项**：I 端口实现包含 {', '.join(obs['observations'])}，"
          f"技术路线的冻结列表未显式列出；按规则应提「接口变更请求」或更新冻结列表。")
        A("")
    A("## 4. 结构与链接")
    A("")
    A(f"- `python scripts/check_repository.py` → **{rep['structure']['status']}**：{rep['structure']['tail']}")
    A("")
    A("## 5. 未运行项（NOT_RUN）")
    A("")
    for x in rep["not_run"]:
        A(f"- {x}")
    A("")
    A("## 6. 结论")
    A("")
    A(f"**{rep['verdict']}**")
    A("")
    A("> 本报告证明：编译/仿真/边界/负例/接口/结构。**不**证明综合、布局布线、上板、")
    A("> 系统级集成与真实指令程序；这些仍需在对应阶段以独立证据验收。")
    return "\n".join(L)


def main():
    import datetime
    head, dirty = git_meta()
    tools = {"iverilog": tool_version(["iverilog", "-V"]),
             "vvp": tool_version(["vvp", "-V"]),
             "python": sys.version.split()[0],
             "platform": sys.platform}
    cases = [run_case(*c) for c in CASES]
    neg = negative_control()
    ifaces = check_interfaces()
    rc_chk, out_chk, err_chk = run([sys.executable, "scripts/check_repository.py"], timeout=180)
    chk_txt = ((out_chk or "") + (err_chk or "")).strip().splitlines()
    struct = {"status": "PASS" if rc_chk == 0 else "FAIL", "rc": rc_chk,
              "tail": chk_txt[-1] if chk_txt else ""}

    total_pass = sum(c.get("assertions_pass", 0) for c in cases)
    total_fail = sum(c.get("assertions_fail", 0) for c in cases)
    all_pass = (all(c["status"] == "PASS" for c in cases) and neg["status"] == "PASS"
                and all(i["status"] == "PASS" for i in ifaces) and struct["status"] == "PASS")

    rep = {
        "generated_at": datetime.datetime.now().isoformat(timespec="seconds"),
        "commit": head, "dirty": dirty, "tools": tools,
        "cases": cases, "negative_control": neg, "interfaces": ifaces,
        "structure": struct, "total_pass": total_pass, "total_fail": total_fail,
        "not_run": ["综合（synthesis）", "布局布线与时序", "FPGA 上板 / ILA",
                    "系统级联合仿真（需 EX/MEM/WB/顶层）",
                    "EX mispredict → redirect 联合回归（需成员B EX）",
                    "真实指令程序 / 架构测试（Step2+）"],
        "verdict": "✅ ALL CHECKS PASSED（仿真阶段）" if all_pass else "❌ 存在 FAIL，详见上表",
    }
    (BUILD / "verification_report.json").write_text(
        json.dumps(rep, ensure_ascii=False, indent=2), encoding="utf-8")
    md = build_markdown(rep)
    (BUILD / "verification_report.md").write_text(md, encoding="utf-8")

    print(md)
    print(f"\n报告已写入 build/verification_report.md 与 .json")
    sys.exit(0 if all_pass else 1)


if __name__ == "__main__":
    main()
