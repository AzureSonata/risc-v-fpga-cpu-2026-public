# -*- coding: utf-8 -*-
"""生成 UART 接入的两个负向对照突变体（步骤 27，证明 T8 非空、可捕获缺陷）。

用法：`python verification/negctl/gen_uart_mutants.py`（在工作区根目录执行）。

突变体（写入 verification/negctl/rtl/，均为 rtl/soc/cpu_mem_subsystem.sv 的整份副本）：

1. `cpu_mem_subsystem_negctl_uarttie.sv`
   D 侧 UART 回退为 tie-off（不接真实设备，`uart_tx` 恒为高）
   —— 用于证明「UART 未接入」会被 T8 捕获：解不出帧 → 等待超时 → FAIL。

2. `cpu_mem_subsystem_negctl_wdata.sv`
   保留真实 uart 实例，但写入 UART 的数据恒为 0（`.wdata(32'h0)`）
   —— 帧结构仍然合法（起始位/停止位正确）而**内容错**，
   用于证明 T8 校验的是字节内容，而非仅仅「线上有活动」。

维护说明：源文件 `cpu_mem_subsystem.sv` 若结构变动导致锚点失配，本脚本会
`AssertionError` 中止（不静默产出错误突变体）；此时需同步更新突变体。
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "rtl" / "soc" / "cpu_mem_subsystem.sv"
OUT = Path(__file__).resolve().parent / "rtl"

src = SRC.read_text(encoding="utf-8")
OUT.mkdir(parents=True, exist_ok=True)

# ---------------- 突变体 1：UART 不接入（tie-off，TX 恒高） ----------------
head = ("    // D 侧 UART：**真实设备**（0x1000_0000 数据 / 0x1000_0004 状态）\n"
        "    uart #(.DIV(UART_DIV)) u_uart (\n")
assert src.count(head) == 1, "UART 实例锚点命中 %d 次（要求 1 次）" % src.count(head)
i = src.index(head)
j = src.index("    );\n", i) + len("    );\n")
tie = (
    "    // [负向对照] UART **不接入**：回退为 tie-off（ready=1、下一拍 error、TX 恒高）\n"
    "    reg ad_u_rsp_v;\n"
    "    always @(posedge clk) begin\n"
    "        if (rst == `RstEnable) ad_u_rsp_v <= 1'b0;\n"
    "        else                   ad_u_rsp_v <= ad_u_req_valid && ad_u_req_ready;\n"
    "    end\n"
    "    assign ad_u_req_ready = 1'b1;  assign ad_u_rsp_valid = ad_u_rsp_v;\n"
    "    assign ad_u_error = 1'b1;      assign ad_u_rdata = 32'b0;\n"
    "    assign uart_tx = 1'b1;         // 线路恒为高：永不出现起始位\n"
)
(OUT / "cpu_mem_subsystem_negctl_uarttie.sv").write_text(
    src[:i] + tie + src[j:], encoding="utf-8")

# ---------------- 突变体 2：写数据恒 0（帧合法但内容错） ----------------
anchor = "        .write(ad_u_write), .wdata(ad_u_wdata), .wstrb(ad_u_wstrb),\n"
assert src.count(anchor) == 1, "wdata 锚点命中 %d 次（要求 1 次）" % src.count(anchor)
(OUT / "cpu_mem_subsystem_negctl_wdata.sv").write_text(
    src.replace(anchor,
                "        .write(ad_u_write), .wdata(32'h0000_0000), .wstrb(ad_u_wstrb),"
                "  // [负向对照] 写数据恒 0\n",
                1),
    encoding="utf-8")

print("已生成 2 个 UART 负向对照突变体 ->", OUT)
