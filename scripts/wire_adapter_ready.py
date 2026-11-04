#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""批 (d-2)：把 cache_path 的新端口 `adapter_ready_i` 接到两侧。

- I 侧：`.adapter_ready_i(i_br_rsp_ready)`
- D 侧：`.adapter_ready_i(d_br_rsp_ready)`

⚠️ 坑位：这类"读全文→改→写回"绝不要用 PowerShell（会写 BOM，Icarus 静默跳过整个 .sv；
   中文注释还会乱码）。用本脚本或编辑工具。见 lessons/LESSON-001 附录 T1/T3/T4。
"""
from pathlib import Path

P = Path(__file__).resolve().parents[1] / "rtl/soc/cpu_mem_subsystem.sv"

I_OLD = ("        .adapter_rsp_rdata(i_cv_rsp_rdata), .adapter_rsp_error(i_cv_rsp_error),\n"
         "        .path_is_cache_o(), .path_drives_adapter_o(i_path_drives_adp)\n")
I_NEW = ("        .adapter_rsp_rdata(i_cv_rsp_rdata), .adapter_rsp_error(i_cv_rsp_error),\n"
         "        // Cache 事务的响应由桥取走（**不能**用 CPU 的 i_rsp_ready：见 cache_path ⚠️ 坑位）\n"
         "        .adapter_ready_i(i_br_rsp_ready),\n"
         "        .path_is_cache_o(), .path_drives_adapter_o(i_path_drives_adp)\n")

D_OLD = ("        .adapter_rsp_rdata(d_cv_rsp_rdata), .adapter_rsp_error(d_cv_rsp_error),\n"
         "        .path_is_cache_o(), .path_drives_adapter_o(d_path_drives_adp)\n")
D_NEW = ("        .adapter_rsp_rdata(d_cv_rsp_rdata), .adapter_rsp_error(d_cv_rsp_error),\n"
         "        // Cache 事务的响应由桥取走（**不能**用 CPU 的 d_rsp_ready：见 cache_path ⚠️ 坑位）\n"
         "        .adapter_ready_i(d_br_rsp_ready),\n"
         "        .path_is_cache_o(), .path_drives_adapter_o(d_path_drives_adp)\n")


def main() -> int:
    src = P.read_text(encoding="utf-8")
    n_i = src.count(I_OLD)
    n_d = src.count(D_OLD)
    print("anchor hits: I=%d D=%d" % (n_i, n_d))
    if n_i != 1 or n_d > 1:
        print("ERROR: 锚点命中数不符（要求 I=1, D<=1），未修改任何文件")
        return 1
    out = src.replace(I_OLD, I_NEW, 1)
    if n_d == 1:
        out = out.replace(D_OLD, D_NEW, 1)
    P.write_text(out, encoding="utf-8")
    print("OK: adapter_ready_i 已接线（I%s D%s）" % ("✓", "✓" if n_d == 1 else "—(未启用)"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
