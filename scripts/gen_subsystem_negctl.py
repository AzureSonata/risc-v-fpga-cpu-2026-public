#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 cpu_mem_subsystem 的负向对照突变体（接入层）。

本生成器覆盖两类对照，均针对**接入层**（`rtl/soc/cpu_mem_subsystem.sv`）：

  A. UART 接入（2026-09-28 步骤 27 建立；批 (d-1) 时因该文件新增 Cache 接入而失效，
     故在此**确定性再生** —— 突变体是完整源码拷贝，源一变就必须同步再生，
     否则"编译失败"会被误计为捕获，对照变成假阳性）：
    1) cpu_mem_subsystem_negctl_uarttie.sv
       D 侧 UART 回退为 tie-off（TX 恒高、rsp 恒 error）⇒ T8 必须捕获「无帧」。
    2) cpu_mem_subsystem_negctl_wdata.sv
       UART 写数据恒 0 ⇒ 帧结构合法但内容错，T8 必须捕获「字节错」。

语义：先**全量**校验所有锚点，任一命中数 != 1 即整体退出且**不写任何文件**
（与 gen_bridge_negctl.py / gen_cachepath_negctl.py / gen_ifstage_negctl.py 同模板）。
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "rtl/soc/cpu_mem_subsystem.sv"
OUT = ROOT / "verification/negctl/rtl"

# 锚点 1：UART 真实实例的 TX 接线（回退为恒高 = 永远不发帧）
TX_ANCHOR = "        .uart_tx(uart_tx), .uart_rx(uart_rx)\n"
# 锚点 2：UART 写数据接线（恒 0 = 帧结构合法但内容错）
WDATA_ANCHOR = "        .write(ad_u_write), .wdata(ad_u_wdata), .wstrb(ad_u_wstrb),\n"

MUTANTS = [
    ("cpu_mem_subsystem_negctl_uarttie.sv",
     TX_ANCHOR,
     "        // NEGCTL：D 侧 UART 回退为 tie-off（TX 恒高 = 永不发帧），T8 必须捕获「无帧」\n"
     "        .uart_tx(), .uart_rx(uart_rx)\n"),
    ("cpu_mem_subsystem_negctl_wdata.sv",
     WDATA_ANCHOR,
     "        // NEGCTL：UART 写数据恒 0（帧结构合法但内容错），T8 必须捕获「字节错」\n"
     "        .write(ad_u_write), .wdata(32'h0), .wstrb(ad_u_wstrb),\n"),
]


def main() -> int:
    src = SRC.read_text(encoding="utf-8")
    for name, anchor, _repl in MUTANTS:
        hits = src.count(anchor)
        if hits != 1:
            print("ERROR: %s 锚点在 cpu_mem_subsystem.sv 命中 %d 次（要求 1）；未写出任何文件"
                  % (name, hits))
            return 1
    OUT.mkdir(parents=True, exist_ok=True)
    for name, anchor, repl in MUTANTS:
        (OUT / name).write_text(src.replace(anchor, repl, 1), encoding="utf-8")
        print("生成 verification/negctl/rtl/" + name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
