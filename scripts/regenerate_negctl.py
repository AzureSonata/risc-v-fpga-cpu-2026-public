#!/usr/bin/env python3
"""regenerate_negctl.py —— 从**当前** RTL 重新生成整份拷贝型负向对照突变体。

## 为什么需要这个脚本（⚠️ 坑位，务必先读）

`verification/negctl/rtl/<mod>_negctl_<mut>.sv` 是相应 RTL 的**整份拷贝 + 一处突变**，
在负向对照里会**替换**真实 RTL 参与编译。一旦源 RTL 被修改（修 bug、加特性），
这些拷贝就变成**陈旧实现**，后果有两种，都很难察觉：

1. 拷贝里若引用了新版才有的信号/宏 ⇒ **编译失败** ⇒ 该条负向对照被判"对照失效"，
   实际是**静默失去保障**（run_tests.py 会报 `突变体无法编译（多半未随源再生）`）；
2. 更糟：拷贝能编译，于是负控**在旧实现上做突变**，即使真实 RTL 已经修好/改坏，
   负控照样"捕获成功"——**负控不再作用于被测对象**，是假绿。

本仓库 2026-10-01 实测：`cache_path_negctl_nocache/bypassall.sv` 因 `cache_path.sv`
新增响应 skid 而失去 `TB_MUTATE_NO_SKID` 宏，双双编译失败；
`cpu_mem_subsystem_negctl_wdata/uarttie.sv` 则停在 09-30"重复 addr_decode 实例"修复之前。

## ⚠️ 坑位：不要用 PowerShell 读写这些 .sv

`Get-Content -Raw` 会**按系统代码页（cp936）猜编码**，把 UTF-8 中文注释重编码成乱码，
并把部分字节序列吞成换行（实测 266 行 → 252 行）；`Set-Content -Encoding UTF8` 则写 BOM，
Icarus 10.2 会**静默跳过**带 BOM 的 .sv。本脚本一律 `encoding="utf-8"`，且 `newline=""`
保持原有行尾（**不得**让 Python 把 LF 改成 CRLF，否则整份文件都会显示为改动）。

## 用法

    python scripts/regenerate_negctl.py            # 只检查（报告哪些突变体已陈旧）
    python scripts/regenerate_negctl.py --write     # 就地重生

退出码：0 = 全部最新/已重生；1 = 存在陈旧且未加 --write，或锚点不唯一。
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
NEGCTL = REPO / "verification" / "negctl" / "rtl"

# ⚠️ 坑位（2026-10-06 实测）：Windows 默认控制台是 cp936，本脚本打印 ✅/⚠️/ℹ️ 会抛
#    UnicodeEncodeError 并以 exit 1 终止——而它其实什么都没做错（与 run_perf_quadrant.py
#    同一类缺陷）。必须显式把 stdout 切到 UTF-8，否则脚本在**第一个** ✅ 处就崩，
#    上面的 --write 逻辑根本执行不到（表现为"命令失败、文件没生成"）。
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

# (突变体文件名, 源 RTL 相对仓库路径, 锚点, 替换)
# 锚点必须在源文件里**恰好出现一次**，否则视为对照失效并报错（不得静默跳过）。
MUTANTS: list[tuple[str, str, str, str]] = [
    (
        "cache_path_negctl_nocache.sv",
        "rtl/memory/cache_path.sv",
        "    wire sel_cache_now = cache_en && cacheable && (CACHE_WRITES || !up_write);",
        "    // NEGCTL：Cache 路径永不选中（全部走 bypass）——\n"
        "    // I-Cache 命中数恒 0，T9 必须捕获\n"
        "    wire sel_cache_now = 1'b0;",
    ),
    (
        "cache_path_negctl_bypassall.sv",
        "rtl/memory/cache_path.sv",
        "    wire sel_cache_now = cache_en && cacheable && (CACHE_WRITES || !up_write);",
        "    // NEGCTL：路径判据翻转（可缓存地址反而走 bypass）——\n"
        "    // 命中数归零/缺失异常，T9/T10 必须捕获\n"
        "    wire sel_cache_now = cache_en && !cacheable && (CACHE_WRITES || !up_write);",
    ),
    (
        "cache_path_negctl_rspbackpressure.sv",
        "rtl/memory/cache_path.sv",
        "    assign adapter_rsp_ready = adapter_self && !sel_cache && !bypass_skid_valid;",
        "    // NEGCTL(ADR-MEM-EXIT-001 E1)：把 adapter 响应消费恢复成依赖下游 up_rsp_ready\n"
        "    //   ⇒ 下游一卡就形成闭环反压，cache_path_exit 必须挂死/失败。\n"
        "    assign adapter_rsp_ready = (adapter_self && !sel_cache)\n"
        "                              ? (bypass_skid_valid ? 1'b0 : up_rsp_ready)\n"
        "                              : 1'b0;",
    ),
    (
        "cache_path_negctl_busyignore.sv",
        "rtl/memory/cache_path.sv",
        "    wire adapter_self      = !cache_txn_active && !cache_busy_i; // 1 = bypass owner",
        "    // NEGCTL(A2b 端口租用)：忽略后台 fill 占用，bypass 会抢走 adapter 口\n"
        "    //   ⇒ B4/B5 必须捕获（cache_path_exit 的端口保持判据）。\n"
        "    wire adapter_self      = !cache_txn_active; // NEGCTL busyignore",
    ),

    (
        "cpu_mem_subsystem_negctl_wdata.sv",
        "rtl/soc/cpu_mem_subsystem.sv",
        "        .write(ad_u_write), .wdata(ad_u_wdata), .wstrb(ad_u_wstrb),",
        "        // NEGCTL：UART 写数据恒 0（帧结构合法但内容错），T8 必须捕获「字节错」\n"
        "        .write(ad_u_write), .wdata(32'h0), .wstrb(ad_u_wstrb),",
    ),
    (
        "cpu_mem_subsystem_negctl_uarttie.sv",
        "rtl/soc/cpu_mem_subsystem.sv",
        "        .uart_tx(uart_tx), .uart_rx(uart_rx)",
        "        // NEGCTL：D 侧 UART 回退为 tie-off（TX 恒高 = 永不发帧），T8 必须捕获「无帧」\n"
        "        .uart_tx(), .uart_rx(uart_rx)",
    ),
    # ⚠️ 本条目是"从模糊路径抢救回来"的：`resync_negctl_mutants.py` 的歧义锚点消歧路径曾把它
    #   改成"删注释、留赋值" ⇒ **突变消失**（负控 48/48 → 47/48，看起来像漏检）。
    #   登记进本表（唯一锚点 + 替换）后，它不再经过模糊路径，内容稳定可核对。
    (
        "id_stage_negctl_illegallatch.sv",
        "rtl/core/id_stage.sv",
        "        // D-1 修复：illegal_instr_o 必须在默认区赋值，否则合法指令走正常\n"
        "        // opcode 分支时该输出不被赋值 -> always @(*) 综合出锁存器，\n"
        "        // 输出保持上一周期值（陈旧值），行为依赖历史。\n"
        "        illegal_instr_o = 1'b0;",
        "        // NEGCTL D-1 注入：**故意移除** illegal_instr_o 的默认赋值\n"
        "        //   ⇒ always @(*) 推断锁存器：合法指令走正常 opcode 分支时该输出不被赋值，\n"
        "        //     保持上一周期的陈旧值（行为依赖历史）。预期被 id_stage 套件捕获。\n"
        "        //   ⚠️ 本文件由本表（唯一锚点 + 替换）管理，**不要**再走 resync 的模糊路径：\n"
        "        //      2026-10-01 曾被模糊路径改成\"删注释、留赋值\"⇒ 突变消失 ⇒ 假通过 47/48。",
    ),
    (
        "mem_burst_bridge_negctl_errswallow.sv",
        "rtl/memory/mem_burst_bridge.sv",
        "                        rd_beat_error <= rsp_error;\n",
        "                        // NEGCTL：读 beat 的 error 被吞（恒 0）——\n"
        "                        // cache 拿到 error=0 的残行，整行不分配裁决失效，T2 必须捕获\n"
        "                        rd_beat_error <= 1'b0;\n",
    ),
    (
        "mem_burst_bridge_negctl_beatfreeze.sv",
        "rtl/memory/mem_burst_bridge.sv",
        "    assign req_addr  = (state == S_W_REQ) ? w_addr_q : rd_word_addr;\n",
        "    assign req_addr  = (state == S_W_REQ) ? w_addr_q\n"
        "                     : {r_line_addr[31:2], 2'b00};   // NEGCTL：地址不随 beat 递增，\n"
        "                                                     // 4 笔请求全部命中 word0，T1 必须捕获\n",
    ),
    # ------------------------------------------------------------------
    # Issue #15 第 5 项（2026-10-06）：retire/commit 专用负向对照。
    # 背景：主回归原有 8 条负控**全在 IF/前端**，而 wb_stage/retire_trace 的
    # "重复提交 / 漏提交 / valid=0 伪提交 / trap-x0 写门控"四条契约**一条负控都没有**；
    # tb_wb_trace 也从未登记进主回归。此表把 5 条突变体纳入唯一锚点管理，
    # 被测套件 = wb_trace（verification/unit/tb_wb_trace.v）。
    # ------------------------------------------------------------------
    (
        "wb_stage_negctl_fireblind.sv",
        "rtl/core/wb_stage.v",
        "    assign rd_we   = commit_fire && wb_valid && wb_writes_rd &&\n",
        "    // NEGCTL：忽略 commit_fire ⇒ 保持中的 MEM/WB 载荷被**重复提交**（重复写寄存器）。\n"
        "    // 预期被 tb_wb_trace 的 \"multi-cycle hold does not repeat commit\" 捕获。\n"
        "    assign rd_we   = wb_valid && wb_writes_rd &&\n",
    ),
    (
        "wb_stage_negctl_x0write.sv",
        "rtl/core/wb_stage.v",
        "                     (wb_rd != 5'd0) && !wb_trap;",
        "                     !wb_trap;   // NEGCTL：移除 x0 写门控 ⇒ x0 被真正写入，\n"
        "                                 // 预期被 \"x0 write is suppressed\" 捕获",
    ),
    (
        "wb_stage_negctl_trapwrite.sv",
        "rtl/core/wb_stage.v",
        "                     (wb_rd != 5'd0) && !wb_trap;",
        "                     (wb_rd != 5'd0);   // NEGCTL：移除 trap 写门控 ⇒ 陷阱指令仍写寄存器，\n"
        "                                        // 预期被 \"trap suppresses register write\" 捕获",
    ),
    (
        "retire_trace_negctl_validblind.sv",
        "rtl/core/retire_trace.v",
        "            if (commit_fire && retire_valid) begin",
        "            // NEGCTL：忽略 retire_valid ⇒ valid=0 也产生 trace 事件与 order 递增（伪提交）。\n"
        "            // 预期被 tb_wb_trace 的 \"fire without valid is an empty clock\" 捕获。\n"
        "            if (commit_fire) begin",
    ),
    (
        "retire_trace_negctl_dropx0.sv",
        "rtl/core/retire_trace.v",
        "            if (commit_fire && retire_valid) begin",
        "            // NEGCTL：丢弃 rd=x0 的退休事件 ⇒ 合法指令**漏提交**、order 少递增一次。\n"
        "            // 预期被 tb_wb_trace 的 \"x0 instruction still retires once\" 捕获。\n"
        "            if (commit_fire && retire_valid && (retire_rd != 5'd0)) begin",
    ),
    # Issue #15 第 4 项：整机联合契约（backend_hold + redirect 同拍）的鉴别力突变体。
    # 被测：tb_cpu_core_trap 的 T13 判据（联合场景 2 拍，要求同拍 flush_id_ex）。
    (
        "pipeline_control_negctl_holdwins.sv",
        "rtl/core/pipeline_control.v",
        "        if (redirect_valid) begin",
        "        // NEGCTL：让 backend_hold **吞掉** redirect 的年轻冲刷 ⇒ 同拍 flush_id_ex=0，\n"
        "        //         年轻 ID/EX 被保持而非丢弃（T13 契约破坏）。\n"
        "        if (redirect_valid && !backend_hold) begin",
    ),
    # PR66（2026-10-17）：结构改动后仍用唯一语义锚点管理三项负控，
    # 避免旧差异块错位覆盖当前语法/只匹配注释而失去功能突变。
    (
        "dcache_negctl_bytemask.sv",
        "rtl/memory/dcache.sv",
        "wire [31:0] store_line_data = (line[st_index] & ~st_mask) | (st_data & st_mask);",
        "wire [31:0] store_line_data = st_data; // NEGCTL: ignore byte mask",
    ),
    (
        "dual_full_negctl_dropillegal.sv",
        "rtl/core/dual_issue_full_core.sv",
        "wire s0_valid = fq_out0_valid;",
        "wire s0_valid = fq_out0_valid && !d0_illegal; // NEGCTL: filter illegal head",
    ),
    (
        "wide_imem_adapter_negctl_nostaleflush.sv",
        "rtl/memory/wide_imem_adapter.sv",
        "                    if (cpu_rsp_valid && cpu_rsp_ready) begin",
        "                    if ((cpu_rsp_valid && cpu_rsp_ready) || cpu_req_valid) begin "
        "// NEGCTL: new request may replace a backpressured response",
    ),
    (
        "fetch_queue_negctl_noflush.sv",
        "rtl/core/fetch_queue.sv",
        "        if (rst == `RstEnable || flush == `True)\n"
        "            count_q <= 4'd0;",
        "        // NEGCTL: retain occupancy across flush; current payload clear stays intact.\n"
        "        if (rst == `RstEnable)\n"
        "            count_q <= 4'd0;",
    ),
]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true", help="就地重生陈旧突变体")
    ap.add_argument("--only", help="只检查/重生指定输出文件名")
    args = ap.parse_args()

    stale: list[str] = []
    selected = [m for m in MUTANTS if args.only is None or m[0] == args.only]
    if not selected:
        ap.error("没有匹配的负控输出文件名")
    for out_name, src_rel, anchor, repl in selected:
        src_path = REPO / src_rel
        out_path = NEGCTL / out_name
        src = src_path.read_text(encoding="utf-8")
        n = src.count(anchor)
        if n != 1:
            print(f"  ❌ {out_name}: 锚点在 {src_rel} 出现 {n} 次（要求恰好 1 次）—— 拒绝生成")
            return 1
        want = src.replace(anchor, repl, 1)
        have = out_path.read_text(encoding="utf-8") if out_path.exists() else ""
        if have == want:
            print(f"  ✅ {out_name}: 与当前 {src_rel} 同步")
            continue
        stale.append(out_name)
        if args.write:
            out_path.write_text(want, encoding="utf-8", newline="")
            print(f"  🔧 {out_name}: 已从 {src_rel} 重生（{len(want.splitlines())} 行）")
        else:
            print(f"  ⚠️  {out_name}: **已陈旧**（需 --write 重生）")

    if stale and not args.write:
        print(f"\n  {len(stale)} 个突变体陈旧 —— 负向对照可能假绿或编译失败，请运行 --write")
        return 1

    if args.only is not None:
        print(f"\n  指定的 {len(selected)} 个突变体与当前 RTL 一致；其他突变体未检查")
        return 0

    # ⚠️⚠️ 坑位（**本脚本曾经的过度声称**，2026-10-01 由峥榕在 Icarus 13.0 复现暴露）：
    #   本表只登记 **4** 个突变体，而 `verification/negctl/rtl/` 里实际有 **42** 个文件。
    #   旧代码在表内检查通过后直接打印"**全部**突变体与当前 RTL 一致"⇒ 38 个**从未被检查**的
    #   突变体被这句话掩盖。后果实证：修好 `cpu_core_stage1.sv` 的"先用后声明"后，
    #   10 个 `cpu_core_stage1_negctl_*.sv` 仍带着旧声明顺序 ⇒ 13.0 下负控 18 条编译失败，
    #   而本脚本**照样报"全部一致"**。
    #   ⇒ 正确做法：**枚举目录**，把未纳管的文件数如实报出来，并指向 `resync_negctl_mutants.py`；
    #      "全部"只能用在真的覆盖全部的时候说（§7.15：绿有"跑通/覆盖/有鉴别力"三种含义）。
    managed = {m[0] for m in MUTANTS}
    all_files = sorted(p.name for p in NEGCTL.glob("*.sv"))
    unmanaged = [f for f in all_files if f not in managed]
    print(f"\n  锚点表内 {len(managed)} 个突变体与当前 RTL 一致"
          f"（目录共 {len(all_files)} 个文件）")
    if unmanaged:
        print(f"  ℹ️ 另有 **{len(unmanaged)}** 个突变体**不在本表**（早期一次性脚本生成），"
              f"其一致性由 `scripts/resync_negctl_mutants.py --prev <rev>` 负责：")
        print(f"     python scripts/resync_negctl_mutants.py --prev <上一版提交>        # 检查")
        print(f"     python scripts/resync_negctl_mutants.py --prev <上一版提交> --write # 重生")
    return 0


if __name__ == "__main__":
    sys.exit(main())
