"""Run portable Verilator lint and Yosys synthesis checks for selected RTL modules.

This is a module-level sanity pass, not CPU-top, vendor-PDS, timing, or FPGA proof.
"""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl" / "core"
MODULES = {
    "pc_reg": [RTL / "pc_reg.sv"],
    "regfile": [RTL / "regfile.v"],
    "hazard_detection": [RTL / "hazard_detection.v"],
    "pipeline_control": [RTL / "pipeline_control.v"],
    "id_ex_reg": [RTL / "id_ex_reg.v"],
    "if_id": [RTL / "if_id.sv"],
    "if_stage": [RTL / "if_stage.sv"],
    "id_stage": [RTL / "id_stage.sv"],
    "riscv_lsu": [RTL / "riscv_lsu.sv"],
    "riscv_exec": [RTL / "riscv_alu.sv", RTL / "riscv_exec.sv"],
    "cpu_core_stage1": [
        RTL / "pc_reg.sv", RTL / "if_stage.sv", RTL / "if_id.sv",
        RTL / "id_stage.sv", RTL / "csr_file.sv", RTL / "id_ex_reg.v", RTL / "pipeline_control.v",
        RTL / "forwarding_unit.v", RTL / "hazard_detection.v",
        RTL / "riscv_alu.sv", RTL / "riscv_exec.sv", RTL / "riscv_lsu.sv",
        RTL / "regfile.v", RTL / "wb_stage.v", RTL / "retire_trace.v",
        RTL / "cpu_core_stage1.sv",
    ],
    "pangu100proplus_top": [
        RTL / "pc_reg.sv", RTL / "if_stage.sv", RTL / "if_id.sv",
        RTL / "id_stage.sv", RTL / "csr_file.sv", RTL / "id_ex_reg.v", RTL / "pipeline_control.v",
        RTL / "forwarding_unit.v", RTL / "hazard_detection.v",
        RTL / "riscv_alu.sv", RTL / "riscv_exec.sv", RTL / "riscv_lsu.sv",
        RTL / "regfile.v", RTL / "wb_stage.v", RTL / "retire_trace.v",
        RTL / "cpu_core_stage1.sv", ROOT / "rtl/soc/pangu100proplus_top.sv",
    ],
}


def find_tool(name: str) -> Path | None:
    found = shutil.which(name)
    if found:
        resolved = Path(found)
        if name == "verilator" and resolved.name.lower() in {"verilator", "verilator.exe"}:
            native_binary = resolved.parent / "verilator_bin.exe"
            if native_binary.is_file():
                return native_binary
        return resolved
    tool_bin = Path.home() / "Tools" / "msys64-stage1" / "ucrt64" / "bin"
    names = {
        "yosys": ["yosys.exe", "yosys"],
        "verilator": ["verilator_bin.exe", "verilator_bin"],
    }[name]
    for candidate_name in names:
        candidate = tool_bin / candidate_name
        if candidate.is_file():
            return candidate
    return None


def run_verilator(executable: Path, top: str, sources: list[Path]) -> int:
    env = os.environ.copy()
    verilator_root = env.get("VERILATOR_ROOT")
    if not verilator_root:
        candidate = executable.parent.parent / "share" / "verilator"
        if candidate.is_dir():
            verilator_root = str(candidate)
            env["VERILATOR_ROOT"] = verilator_root
    cmd = [
        str(executable), "--lint-only", "--sv", "-Wall", "-Wno-fatal",
        f"-I{RTL}", "--top-module", top, *map(str, sources),
    ]
    result = subprocess.run(cmd, cwd=ROOT, env=env, text=True, capture_output=True)
    print(f"Verilator {top}: exit={result.returncode}")
    if result.stdout:
        print(result.stdout.rstrip())
    if result.stderr:
        print(result.stderr.rstrip())
    return result.returncode


def run_yosys(executable: Path, top: str, sources: list[Path]) -> int:
    files = " ".join(str(path) for path in sources)
    script = (
        f'read_verilog -sv -I"{RTL}" {files}; '
        f"hierarchy -check -top {top}; proc; opt; check; "
        f"synth -top {top}; check; stat"
    )
    result = subprocess.run(
        [str(executable), "-p", script], cwd=ROOT, text=True, capture_output=True
    )
    print(f"Yosys {top}: exit={result.returncode}")
    output = result.stdout + result.stderr
    for line in output.splitlines():
        if "Found and reported" in line or "ERROR:" in line or "Warning:" in line:
            print(line)
    if result.returncode:
        print(output[-6000:])
    return result.returncode


def main() -> int:
    yosys = find_tool("yosys")
    verilator = find_tool("verilator")
    if not yosys or not verilator:
        print(f"Missing tool(s): yosys={yosys}, verilator={verilator}")
        return 2
    print(f"Yosys: {yosys}")
    print(f"Verilator: {verilator}")
    for tool, args in ((yosys, ["-V"]), (verilator, ["--version"])):
        version = subprocess.run([str(tool), *args], cwd=ROOT, text=True, capture_output=True)
        print((version.stdout or version.stderr).strip())
        if version.returncode:
            print(f"FAIL: version query exited {version.returncode}")
            return 2
    failures = []
    for top, sources in MODULES.items():
        missing = [str(path) for path in sources if not path.is_file()]
        if missing:
            print(f"{top}: missing source(s): {', '.join(missing)}")
            failures.append(top)
            continue
        if run_verilator(verilator, top, sources):
            failures.append(f"Verilator:{top}")
        if run_yosys(yosys, top, sources):
            failures.append(f"Yosys:{top}")
    if failures:
        print("FAIL: " + ", ".join(failures))
        return 1
    print(f"PASS: module-level lint+synthesis sanity ({len(MODULES)} tops)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
