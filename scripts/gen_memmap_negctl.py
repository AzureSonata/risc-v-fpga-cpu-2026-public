# -*- coding: utf-8 -*-
"""生成 memory-map adapter 的负向对照突变体（锚点唯一性校验）。

对照 1 romwriteok：从 unsupported 中移除 `(sel_rom & write)` —— 写只读 ROM
  不再报 error，而是被转发给 ROM 并返回"成功"响应（只读写静默通过）。
  预期被测：tb_mem_map 的 T2a/T2b。

对照 2 errswallow：把 error 通路的 req_ready 由 `~err_pending_q` 改为恒 1 ——
  上一笔 error 响应尚未取走时就接受下一笔请求，请求被吞掉
  （违反"一次请求接受只对应一次响应"）。
  预期被测：tb_mem_map 的 T10b/T10d 与 T11 计数对账。
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "rtl/soc/mem_map_adapter.sv"
OUT = ROOT / "verification/negctl/rtl"

MUTATIONS = {
    "mem_map_adapter_negctl_romwriteok.sv": (
        "                     | (sel_rom & write)\n",
        "                     // NEGCTL: 移除只读判定，写 ROM 将被静默接受\n",
    ),
    "mem_map_adapter_negctl_errswallow.sv": (
        "    assign req_ready = (sel_enc == SEL_ERR) ? ~err_pending_q : dev_req_ready;",
        "    assign req_ready = (sel_enc == SEL_ERR) ? 1'b1 : dev_req_ready;  // NEGCTL: 吞请求",
    ),
}

src = SRC.read_text(encoding="utf-8")
OUT.mkdir(parents=True, exist_ok=True)

for name, (anchor, repl) in MUTATIONS.items():
    n = src.count(anchor)
    assert n == 1, "锚点 %r 出现 %d 次（要求恰好 1 次）" % (anchor, n)
    (OUT / name).write_text(src.replace(anchor, repl, 1), encoding="utf-8")
    print("生成 verification/negctl/rtl/%s" % name)
