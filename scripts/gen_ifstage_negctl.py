# -*- coding: utf-8 -*-
"""确定性再生 if_stage 的 5 个负向对照突变体（批 (b) 遗留项修复）。

背景（为什么需要这个脚本）
--------------------------------------------------------------------------
`verification/negctl/rtl/if_stage_negctl_{orphan,double_req,strand,skiddrop,rstpol}.sv`
原先是 **BTB 接入（9407e1c）之前** 的 `if_stage.sv` 手工副本，且停留在更早的
"i_req_valid 为寄存输出" 版本（19 端口）。BTB 接入后 if_stage 变为 25 端口，
这 5 个副本缺少 `pred_hit_i/pred_taken_i/pred_target_i`，**编译失败**。
`run_tests.py --negative-controls` 收紧判据后（编译失败不再算捕获），
它们表现为 "对照失效"（6 条对照受影响，double_req 被 2 条对照复用）。

本脚本把 5 个突变体改为**从当前 `rtl/core/if_stage.sv` 派生**：
- 保留当前模块的全部端口与结构（含 BTB 预测锁存），因此必然能编译；
- 只注入各突变体原本想注入的那一处违规；
- 锚点必须**恰好出现 1 次**，否则整体报错退出、不写任何文件
  （源文件重构后一旦锚点漂移，负控必须立刻显式失败，绝不静默失效）。

注入意图来源（逐行比对 pre-BTB 源与 5 个陈旧副本得到）
--------------------------------------------------------------------------
orphan       IDLE 态也拉高 i_rsp_ready  → 无在途请求时完成响应握手（响应多于请求）
double_req   redirect 时 REQ 态同拍 fire 的请求被当作不存在（回 IDLE）→ outstanding>1
strand       redirect 与响应同拍时响应被消费但仍停 WAIT → 搁浅（30c8190 缺陷）
skiddrop     直写条件未排除 "本拍 buf 提升将占用输出槽" → 提升值被同拍直写覆盖
rstpol       复位极性反转为低有效 → 违反同步高有效复位契约

用法
--------------------------------------------------------------------------
    python scripts/gen_ifstage_negctl.py

退出码：0 = 5 个突变体全部按锚点生成；1 = 任一锚点不唯一/未找到（不写文件）。
"""

from pathlib import Path
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "rtl/core/if_stage.sv"
OUT_DIR = ROOT / "verification/negctl/rtl"

HEADER = """\
// ============================================================================
//  [负向对照突变体] {name} — 禁止综合、禁止用于正常回归
//
//  由 scripts/gen_ifstage_negctl.py 从 rtl/core/if_stage.sv 确定性再生，
//  请勿手工编辑本文件：修改请改生成器并重跑（锚点唯一性校验会守住漂移）。
//
//  注入的违规：{violation}
//
//  预期：{expect}
// ============================================================================
"""

# (突变体名, 锚点, 替换, 违规说明, 预期被哪条对照捕获)
MUTATIONS = [
    (
        "if_stage_negctl_orphan",
        "assign i_rsp_ready = (state == STATE_WAIT) && !buf_full;",
        "// NEGCTL：IDLE 态也接受响应 —— 制造孤立响应条件（响应多于请求）\n"
        "    assign i_rsp_ready = (state == STATE_WAIT || state == STATE_IDLE) && !buf_full;",
        "IDLE 态也拉高 i_rsp_ready，无在途请求时也能完成一次响应握手",
        "tb_random_delay（+negctl_orphan_rsp）孤立响应监控 + fires<responses 对账 FAIL",
    ),
    (
        "if_stage_negctl_double_req",
        "                if (state == STATE_WAIT || (state == STATE_REQ && i_req_valid && i_req_ready)) begin",
        "                // NEGCTL：REQ 态同拍 fire 的请求被当作不存在（回 IDLE）\n"
        "                //        → 旧响应未 drain 就发出第二笔请求，违反 outstanding<=1\n"
        "                if (state == STATE_WAIT) begin",
        "redirect 时忽略「REQ 态本拍请求已被接受」，直接回 IDLE 后再发新请求",
        "tb_random_delay Phase 5 + tb_redirect_race Test 2 的 outstanding 监控 FAIL",
    ),
    (
        "if_stage_negctl_strand",
        "                if (state == STATE_WAIT && i_rsp_valid && i_rsp_ready) begin\n"
        "                        // 响应本周期到达，已被消费 → 未完成请求立即 drain",
        "                if (1'b0) begin\n"
        "                        // 响应本周期到达，已被消费 → 未完成请求立即 drain",
        "redirect 与响应同拍时响应被握手消费，但 FSM 仍保持 WAIT（搁浅，30c8190）",
        "tb_redirect_race Test 1b：drain 后无指向 target 的新请求 FAIL",
    ),
    (
        "if_stage_negctl_skiddrop",
        "wire out_slot_free = !if_out_valid || (if_out_ready && !buf_valid);",
        "// NEGCTL：直写条件未排除「本拍 buf 提升将占用输出槽」→ 提升值被同拍直写覆盖\n"
        "    wire out_slot_free = !if_out_valid || if_out_ready;",
        "out_slot_free 丢失 !buf_valid 项，buf 提升值被同拍直写覆盖（载荷丢失）",
        "tb_payload_hold FAIL（Gate #3）",
    ),
    (
        "if_stage_negctl_rstpol",
        "if (rst == `RstEnable) begin",
        "if (rst == `RstDisable) begin  // NEGCTL：复位极性错误（低有效）",
        "复位极性反转：同步高有效复位契约被破坏",
        "tb_reset_polarity FAIL（Gate #4）",
    ),
]


def main():
    src = SRC.read_text(encoding="utf-8")

    # 先全量校验锚点唯一性：任一不符即整体失败，不写任何文件（避免半成品突变体）
    problems = []
    for name, anchor, _repl, _viol, _exp in MUTATIONS:
        n = src.count(anchor)
        if n != 1:
            problems.append(f"  ❌ {name}: 锚点出现 {n} 次（要求恰好 1 次）: {anchor!r}")
    if problems:
        print("锚点校验失败，未写入任何文件（if_stage.sv 可能已重构，请更新生成器锚点）：")
        for p in problems:
            print(p)
        return 1

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for name, anchor, repl, viol, exp in MUTATIONS:
        body = src.replace(anchor, repl, 1)
        text = HEADER.format(name=f"{name}.sv", violation=viol, expect=exp) + body
        out = OUT_DIR / f"{name}.sv"
        # 盘上写 CRLF，与 verification/negctl/rtl/ 下其余 30 个同类产物的实际字节一致
        # （.gitattributes 为 *.sv 声明 eol=lf，入库仍规范化为 LF；两者不冲突）。
        with out.open("w", encoding="utf-8", newline="\r\n") as fh:
            fh.write(text)
        print(f"生成 {out.relative_to(ROOT)}: {len(text.splitlines())} 行")

    print(f"OK: {len(MUTATIONS)} 个突变体已按当前 if_stage.sv 再生（锚点唯一性校验通过）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
