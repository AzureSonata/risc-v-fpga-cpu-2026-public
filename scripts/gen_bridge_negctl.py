#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 mem_burst_bridge 的负向对照突变体（批 (d-0)，ADR-CACHE-INTEGRATION D-C4）。

桥是 Cache 接入唯一的新 RTL，必须有独立的"违规必被抓"证明，否则 (d-1)/(d-2) 的绿
建立在未验证的桥上。两条对照（配合 tb_mem_burst_bridge）：

  1) mem_burst_bridge_negctl_errswallow.sv
     读方向 beat 的 error 被吞（恒 0）→ cache 侧拿到 error=0 的残行，
     整行不分配的裁决依据被破坏。预期被测：T2（错误逐 beat 透传）必须捕获。
  2) mem_burst_bridge_negctl_beatfreeze.sv
     beat 计数错位：4 笔单字读的地址不递增（全部命中 word0）→
     填充行内容错位但 last/timing 全部正常，命中返回错数据且无任何 error。
     预期被测：T1（req addr 序列）必须捕获。

语义：先**全量**校验所有锚点，任一命中数 != 1 即整体退出且**不写任何文件**
（与 gen_ifstage_negctl.py / gen_irq_negctl.py 同模板；避免"部分再生"混合状态）。
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "rtl/memory/mem_burst_bridge.sv"
OUT = ROOT / "verification/negctl/rtl"

ERR_ANCHOR = "                        rd_beat_error <= rsp_error;\n"
ADDR_ANCHOR = (
    "    assign req_addr  = (state == S_W_REQ) ? w_addr_q : rd_word_addr;\n"
)

MUTANTS = [
    ("mem_burst_bridge_negctl_errswallow.sv",
     ERR_ANCHOR,
     "                        // NEGCTL：读 beat 的 error 被吞（恒 0）——\n"
     "                        // cache 拿到 error=0 的残行，整行不分配裁决失效，T2 必须捕获\n"
     "                        rd_beat_error <= 1'b0;\n"),
    ("mem_burst_bridge_negctl_beatfreeze.sv",
     ADDR_ANCHOR,
     "    assign req_addr  = (state == S_W_REQ) ? w_addr_q\n"
     "                     : {r_line_addr[31:2], 2'b00};   // NEGCTL：地址不随 beat 递增，\n"
     "                                                     // 4 笔请求全部命中 word0，T1 必须捕获\n"),
]


def main() -> int:
    src = CORE.read_text(encoding="utf-8")
    # 全量预校验：任一锚点失配即整体退出、不写任何文件（防"部分再生"混合状态）
    for name, anchor, _repl in MUTANTS:
        hits = src.count(anchor)
        if hits != 1:
            print("ERROR: %s 锚点在 mem_burst_bridge.sv 命中 %d 次（要求 1）；未写出任何文件"
                  % (name, hits))
            return 1
    OUT.mkdir(parents=True, exist_ok=True)
    for name, anchor, repl in MUTANTS:
        (OUT / name).write_text(src.replace(anchor, repl, 1), encoding="utf-8")
        print("生成 verification/negctl/rtl/" + name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
