#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""批 (d-2) 排查：对比"有 D 块 / 无 D 块"两种 RTL 下的 if_stage 推进序列。

思路：响应被取走但 CPU 不推进 ⇒ 故障在流水线控制。把 hold/flush 与 if_stage 状态
逐拍打印出来，直接对比两种 RTL 的差异列。

用法（在仓库根运行）：
    python scripts/cmp_d2_stage.py            # 打印前 26 拍
"""
from pathlib import Path
import os
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
TB = ROOT / "verification/system/tb_cpu_mem_subsystem.sv"
SUB = ROOT / "rtl/soc/cpu_mem_subsystem.sv"

RTL = ["rtl/core/pc_reg.sv", "rtl/core/branch_predictor.sv", "rtl/core/if_stage.sv",
       "rtl/core/if_id.sv", "rtl/core/id_stage.sv", "rtl/core/csr_file.sv",
       "rtl/core/id_ex_reg.v", "rtl/core/pipeline_control.v", "rtl/core/forwarding_unit.v",
       "rtl/core/hazard_detection.v", "rtl/core/riscv_alu.sv", "rtl/core/riscv_exec.sv",
       "rtl/core/riscv_lsu.sv", "rtl/core/regfile.v", "rtl/core/wb_stage.v",
       "rtl/core/retire_trace.v", "rtl/core/cpu_core_stage1.sv",
       "rtl/soc/addr_decode.sv", "rtl/soc/mem_map_adapter.sv", "rtl/soc/cpu_mem_subsystem.sv",
       "rtl/memory/rom.sv", "rtl/memory/sram.sv", "rtl/memory/icache.sv",
       "rtl/memory/dcache.sv", "rtl/memory/mem_burst_bridge.sv", "rtl/memory/cache_path.sv",
       "rtl/periph/gpio.sv", "rtl/periph/timer.sv", "rtl/periph/uart.sv"]

PROBE = '''
    // [CMP] 逐拍打印流水线控制与 if_stage 状态
    integer cpn = 0;
    always @(negedge clk) begin
        if (!rst && cpn < 30) begin
            cpn = cpn + 1;
            $display("CMP t%0d seen=%0d | dv=%b dr=%b dw=%b da=%h | dsel=%b ddrv=%b | adpV=%b adpR=%b adpW=%b adpA=%h | adpSV=%b adpSR=%b | dcSt=%0d",
                cpn, seen,
                d_req_valid, d_req_ready, d_write, d_req_addr,
                u_sub.u_cache_path_d.sel_cache, u_sub.d_path_drives_adp,
                u_sub.d_adp_req_valid, u_sub.adp_d_req_ready, u_sub.d_adp_req_write,
                u_sub.d_adp_req_addr,
                u_sub.adp_d_rsp_valid, u_sub.d_adp_d_rsp_ready,
                u_sub.u_dcache.state);
        end
    end
'''


PROBE_NOD = '''
    // [CMP] 无 D 块版本的探针（不能引用 D 侧信号）
    integer cpn = 0;
    always @(negedge clk) begin
        if (!rst && cpn < 30) begin
            cpn = cpn + 1;
            $display("CMP t%0d seen=%0d | dv=%b dr=%b dw=%b da=%h | adpV=%b adpR=%b adpW=%b adpA=%h",
                cpn, seen,
                d_req_valid, d_req_ready, d_write, d_req_addr,
                d_req_valid, d_req_ready, d_write, d_req_addr);
        end
    end
'''


def build(tag: str) -> int:
    out = ROOT / f"build/cmp_{tag}.svvp"
    cmd = ["iverilog", "-g2012", "-I", "rtl/core", "-s", "tb_cpu_mem_subsystem",
           "-o", str(out)] + [str(ROOT / f) for f in RTL] + [str(TB)]
    r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                       errors="replace", cwd=str(ROOT))
    if r.returncode != 0:
        print(f"[{tag}] COMPILE FAIL")
        print("\n".join((r.stderr or "").splitlines()[-6:]))
        return 1
    r2 = subprocess.run(["vvp", str(out)], capture_output=True, text=True,
                        encoding="utf-8", errors="replace", cwd=str(ROOT))
    lines = [ln for ln in (r2.stdout or "").splitlines() if ln.startswith("CMP ")]
    print(f"===== {tag} =====")
    for ln in lines[:26]:
        print(ln)
    return 0


def main() -> int:
    orig = SUB.read_text(encoding="utf-8")
    tb_orig = TB.read_text(encoding="utf-8")
    try:
        # 1) 先把带 D 块的 RTL 就位（探针引用 D 侧信号，故必须两边都能编过）
        r = subprocess.run(["git", "show", "fe05f6a:rtl/soc/cpu_mem_subsystem.sv"],
                           capture_output=True, text=True, encoding="utf-8",
                           errors="replace", cwd=str(ROOT))
        if r.returncode != 0:
            print("无法取 fe05f6a 版本")
            return 1
        withd = r.stdout
        SUB.write_text(withd, encoding="utf-8")
        # 2) 注入探针
        if "[CMP]" not in tb_orig:
            TB.write_text(tb_orig.replace(
                "    // ---------------- 提交 scoreboard ----------------",
                "    // ---------------- 提交 scoreboard ----------------" + PROBE, 1),
                encoding="utf-8")
        build("withd")
        # 3) 无 D 块版本：探针里引用 D 侧信号会编不过，故用**去掉 D 相关字段**的探针
        SUB.write_text(orig, encoding="utf-8")
        TB.write_text(tb_orig.replace(
            "    // ---------------- 提交 scoreboard ----------------",
            "    // ---------------- 提交 scoreboard ----------------" + PROBE_NOD, 1),
            encoding="utf-8")
        build("nod")
    finally:
        SUB.write_text(orig, encoding="utf-8")
        TB.write_text(tb_orig, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
