#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""批 (d-2) 收尾：把**未通过验证**的 D 侧 Cache 接入块从 cpu_mem_subsystem.sv 中移除，
只保留已验证通过的 I 侧修复（地址图单一实例 + mem_map_adapter.sel_rom）。

⚠️ 坑位：不要用 PowerShell 做这种"读全文→改→写回"（会写 BOM，Icarus 会静默跳过整个 .sv，
   且中文注释会乱码不可逆）。用本脚本或编辑工具。见 lessons/LESSON-001 附录 T1/T3/T4。

D 侧实现与排查入口保留在 docs/logs/成员A/2026-09-30/05-*.md §4 与 git stash。
"""
from pathlib import Path

P = Path(__file__).resolve().parents[1] / "rtl/soc/cpu_mem_subsystem.sv"

START = "    // ==================================================================\n" \
        "    // D 侧 Cache 接入（批 (d-2)，ADR-CACHE-INTEGRATION；与 I 侧同构）\n"
END_ADP = "    mem_map_adapter #(.ACCEL_ENABLE(1'b0)) u_adapter_d (\n"

REPLACEMENT = (
    "    // ------------------------------------------------------------------\n"
    "    // D 侧 Cache 接入（批 (d-2)）**当前未启用**：RTL 已写，但在 I 侧缺陷修复后\n"
    "    // 仍验证失败（I-Cache 填充链在第 2 行推进不动：ic=S_FILL、beat 每 3 拍才 +1、\n"
    "    // 第 4 拍不出现）。按项目规则「未通过的改动不得进入 Review」，已回退为\n"
    "    // 「D 端口直连 adapter」的可用形态。\n"
    "    // 完整实现、逐拍证据与下轮第一步排查入口：\n"
    "    //   docs/logs/成员A/2026-09-30/05-批d2根因-同模块双实例导致Icarus不求值.md §4\n"
    "    //   （建议：在 i_br_req_ready / i_br_rsp_ready / i_cv_req_ready 三线逐拍打点，\n"
    "    //     确认第 4 拍 i_br_req_ready 是否被 i_path_drives_adp 误关断；\n"
    "    //     若确认，把「谁占用 adapter 口」由组合判据改为与路径锁同步的寄存器输出）\n"
    "    // ------------------------------------------------------------------\n"
)


def main() -> int:
    src = P.read_text(encoding="utf-8")
    i = src.find(START)
    j = src.find(END_ADP)
    if i < 0 or j < 0 or j <= i:
        print("ERROR: 锚点未找到（start=%d end=%d），未修改任何文件" % (i, j))
        return 1
    out = src[:i] + REPLACEMENT + src[j:]
    # 端口已由"上游 mux"驱动改为"直连 CPU 端口"
    out = out.replace(
        "        .req_valid(d_adp_req_valid), .req_ready(adp_d_req_ready), .addr(d_adp_req_addr),\n"
        "        .write(d_adp_req_write), .wdata(d_adp_req_wdata), .wstrb(d_adp_req_wstrb),\n"
        "        .rsp_valid(adp_d_rsp_valid), .rsp_ready(d_adp_d_rsp_ready),\n"
        "        .rdata(adp_d_rsp_rdata), .error(adp_d_rsp_error),\n",
        "        .req_valid(d_req_valid), .req_ready(d_req_ready), .addr(d_req_addr),\n"
        "        .write(d_write), .wdata(d_wdata), .wstrb(d_wstrb),\n"
        "        .rsp_valid(d_rsp_valid), .rsp_ready(d_rsp_ready),\n"
        "        .rdata(d_rdata), .error(d_error),\n",
    )
    P.write_text(out, encoding="utf-8")
    print("OK: 已移除未验证的 D 侧块，保留 I 侧修复")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
