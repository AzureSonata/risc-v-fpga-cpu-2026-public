"""Run the CPU-visible RV32I/Zmmul/M directed image in all extension modes."""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl" / "core"
TB = ROOT / "verification" / "system" / "tb_cpu_rv32im.sv"
TOOL_BIN = Path(os.environ["RISCV_FPGA_TOOL_BIN"]) if os.environ.get("RISCV_FPGA_TOOL_BIN") else None
SOURCES = [
    "pc_reg.sv", "branch_predictor.sv", "if_stage.sv", "if_id.sv", "id_stage.sv",
    "csr_file.sv", "id_ex_reg.v", "pipeline_control.v", "forwarding_unit.v",
    "hazard_detection.v", "riscv_alu.sv", "riscv_exec.sv", "rv32im_unit.sv",
    "riscv_lsu.sv", "regfile.v", "wb_stage.v", "retire_trace.v", "cpu_core_stage1.sv",
]


def find_tool(name: str) -> str | None:
    on_path = shutil.which(name)
    if on_path:
        return on_path
    if TOOL_BIN is None:
        return None
    return next((str(TOOL_BIN / f"{name}{suffix}") for suffix in (".exe", "")
                 if (TOOL_BIN / f"{name}{suffix}").is_file()), None)


def main() -> int:
    iverilog, vvp = find_tool("iverilog"), find_tool("vvp")
    if not iverilog or not vvp:
        print(f"FAIL: iverilog={iverilog} vvp={vvp}")
        return 2
    env = os.environ.copy()
    env["PATH"] = str(Path(iverilog).parent) + os.pathsep + env.get("PATH", "")
    with tempfile.TemporaryDirectory(prefix="cpu-rv32im-") as build_dir:
        print(f"Icarus: {iverilog}")
        for mode, name in ((0, "RV32I"), (1, "Zmmul"), (2, "M")):
            image = Path(build_dir) / f"mode-{mode}.vvp"
            command = [iverilog, "-g2012", "-Wall", "-I", str(RTL),
                       "-s", "tb_cpu_rv32im", f"-Ptb_cpu_rv32im.M_MODE={mode}",
                       "-o", str(image), *[str(RTL / source) for source in SOURCES], str(TB)]
            print(f"Compile: mode={mode} ({name})", flush=True)
            built = subprocess.run(command, cwd=ROOT, env=env, timeout=60)
            if built.returncode:
                print(f"FAIL: compile mode={name} exit={built.returncode}")
                return 1
            ran = subprocess.run([vvp, str(image)], cwd=ROOT, env=env,
                                 text=True, capture_output=True, timeout=60)
            output = (ran.stdout or "") + (ran.stderr or "")
            print(output, end="", flush=True)
            if ran.returncode or "FATAL" in output or "PASS:" not in output:
                print(f"FAIL: simulation mode={name} exit={ran.returncode}")
                return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
