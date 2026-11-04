#!/usr/bin/env python3
"""K6-M 二级：**真实几何 / 真实参数**的整 job 运行器。

与 run_k6_mmio.py 的分工：
  · run_k6_mmio.py      —— 小几何，只验协议与语义（2158 笔事务，不验数值）
  · run_k6_mmio_real.py —— 真实 49x40 -> 25x20x8 (4000 B) -> FC 4，验数值与 4000 偏移

判据（R1–R9，见 TB 头注释）：
  R1 终态：done=1 / err=0 / busy=0
  R2 CYCLE_COUNT ≈ 352,020（±32）
  R3 结果 RAM [0..3999] 与 golden_dw 逐字节相同
  R4 总线读 0x800 = golden_fc（4 个 int8 logit，RAM 偏移 4000）
  R5 0x800 != buffer[0..3]（映射不是恒等）
  R6 INPUT_CRC32 = TB 独立算的 zlib CRC
  R7 IRQ_EN 读回 1，START 前 irq 必为低
  R8 IRQ 见证：首个 irq=1 落在 busy 窗口内（正常完成 done 后 1 拍）
  R9 IRQ_PENDING 读出 1，写 CLR 后电平必掉、pending 读回 0
  （R7–R9 是 K6-04 要求的"IRQ 外部见证"，只用引脚 + 三个寄存器事务判定。
    GPIO 见证不在这里：本台 DUT 是 `kws_mmio`，没有 GPIO。）

负控 NEGCTL_DWOH_SYM：把 oh/ow 退回对称公式反推。
  预期变红，且**第一个 FAIL 必须是 R1**（核以 E_BUFFER=2 拒绝整个 job），
  这证明「oh/ow 必须由描述符给」不是一句空话：
  真实模型 49/2/10/pt=4 用对称公式算成 22x18，与 fc_nin=4000 不符 ⇒ geo_bad。

输出：verification/kws/k6/k6_mmio_real_report.json
退出码：0 = 基线与负控都符合预期；1 = 任一不符。
"""
import json
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from toolchain import describe, resolve_or_exit  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
IVERILOG: Path | None = None
VVP: Path | None = None
BUILD = ROOT / "build" / "k6mmio"
TB = "verification/kws/k6/tb_kws_mmio_real.sv"
TOP = "tb_kws_mmio_real"

RTL = [
        "rtl/soc/kws_in_w_ram.sv",
    "rtl/soc/kws_res_w_ram.sv",
    "rtl/soc/kws_model_rom.sv",
"rtl/soc/kws_mmio.sv",
    "rtl/accel/openeye_top.sv",
    "rtl/accel/openeye_dw_conv.sv",
    "rtl/accel/openeye_fc.sv",
    "rtl/accel/openeye_srdhm.sv",
    "rtl/estop/kws_estop_watchdog.sv",
]

CRITERIA = {
    "R1": "终态 done=1 / err=0 / busy=0",
    "R2": "CYCLE_COUNT ≈ 352,020（±32）",
    "R3": "结果 RAM [0..3999] 与 golden_dw 逐字节相同",
    "R4": "0x800 = golden_fc（RAM 偏移 4000）",
    "R5": "0x800 != buffer[0..3]（映射不是恒等）",
    "R6": "INPUT_CRC32 = 独立 zlib CRC",
    "R7": "IRQ_EN 读回 1，且 START 前 irq 必为低",
    "R8": "IRQ 见证：首个 irq=1 落在 busy 窗口内（正常完成 done 后 1 拍）",
    "R9": "IRQ_PENDING 读出 1；写 CLR 后电平必掉、pending 读回 0",
}


def run(cmd, cwd):
    p = subprocess.run(cmd, cwd=str(cwd), capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def build(tag, define=None):
    exe = BUILD / f"real_{tag}.vvp"
    cmd = [str(IVERILOG), "-g2012"]
    if define:
        cmd.append(f"-D{define}")
    cmd += ["-s", TOP, "-o", str(exe)] + [str(ROOT / f) for f in RTL] + [str(ROOT / TB)]
    rc, out = run(cmd, ROOT)
    return rc, out, exe


def parse(out):
    fails = [ln.strip() for ln in out.splitlines() if ln.strip().startswith("FAIL")]
    passes = [ln.strip() for ln in out.splitlines() if ln.strip().startswith("PASS")]
    m = re.search(r"SUMMARY cases=(\d+) fails=(\d+)", out)
    cases, nfail = (int(m.group(1)), int(m.group(2))) if m else (0, -1)
    m2 = re.search(r"PASS\s+R2 CYCLE_COUNT=(\d+)", out)
    m3 = re.search(r"PASS\s+R4 0x800 = ([0-9a-fA-F]+)", out)
    # K6-04：四段周期（TB 侧时间戳）
    m4 = re.search(r"SEG to_feature=(\d+) to_start=(\d+) to_start_nocrc=(\d+) "
                   r"busy=(\d+) logit_tail=(\d+) end_to_end=(\d+)", out)
    m5 = re.search(r"SEGCRC crc_read_block=(\d+)", out)
    seg = ({"to_feature": int(m4.group(1)), "to_start": int(m4.group(2)),
            "to_start_nocrc": int(m4.group(3)), "busy": int(m4.group(4)),
            "logit_tail": int(m4.group(5)), "end_to_end": int(m4.group(6)),
            "crc_read_block": int(m5.group(1)) if m5 else None} if m4 else None)
    return {"result": "PASS" if "RESULT PASS" in out else "FAIL",
            "cases": cases, "fails": nfail,
            "passed": [p.split()[1] for p in passes if len(p.split()) > 1],
            "fail_lines": fails,
            "cycle_count": int(m2.group(1)) if m2 else None,
            "logit_word": m3.group(1) if m3 else None,
            "segments": seg}


def main():
    global IVERILOG, VVP
    IVERILOG = resolve_or_exit("KWS_IVERILOG", "iverilog", version_marker="13.0",
                               purpose="iverilog 13.0")
    VVP = resolve_or_exit("KWS_VVP", "vvp", version_marker="13.0", purpose="vvp 13.0")

    BUILD.mkdir(parents=True, exist_ok=True)
    report = {
        "tool": f"iverilog ({IVERILOG.parent.as_posix()})",
        "toolchain": {"iverilog": describe(IVERILOG, ("-V",)),
                      "vvp": describe(VVP, ("-V",))},
        "tb": TB, "top": TOP,
        "geometry": {"in": "49x40 int8 (1960 B)", "dw_kernel": "10x8 stride2 pad 4/3",
                     "dw_out": "25x20x8 (4000 B)", "fc": "4000 -> 4"},
        "vectors": "verification/kws/k4/vectors (作者的封存向量，未重生成)",
        "criteria": CRITERIA,
        "runs": {},
    }
    ok_all = True

    rc, out, exe = build("base")
    if rc != 0:
        print(out)
        print("BUILD FAILED (baseline)")
        return 1
    _, out = run([str(VVP), str(exe)], ROOT)
    base = parse(out)
    report["runs"]["baseline"] = base
    print(f"baseline: {base['result']} cases={base['cases']} fails={base['fails']} "
          f"cycles={base['cycle_count']} logits={base['logit_word']}")
    if base["result"] != "PASS":
        ok_all = False
        for ln in base["fail_lines"][:10]:
            print("   ", ln)

    define = "NEGCTL_DWOH_SYM"
    rc, out, exe = build("negsym", define)
    if rc != 0:
        print(out)
        print(f"BUILD FAILED ({define})")
        return 1
    _, out = run([str(VVP), str(exe)], ROOT)
    r = parse(out)
    first_fail = r["fail_lines"][0] if r["fail_lines"] else ""
    hit = "R1" in first_fail
    good = (r["result"] == "FAIL") and hit
    r.update({
        "expected_red_case": "R1",
        "why": "oh/ow 退回对称公式 ⇒ 22x18 ⇒ dw_bytes=3168 != fc_nin=4000 ⇒ 核以 E_BUFFER=2 拒绝",
        "caught": good, "caught_by_expected_case": hit,
        "first_fail": first_fail,
    })
    report["runs"][define] = r
    print(f"{define}: {r['result']} fails={r['fails']} first_fail={first_fail[:60]} "
          f"-> {'OK' if good else 'BAD'}")
    ok_all = ok_all and good

    report["verdict"] = "PASS" if ok_all else "FAIL"
    report["scope"] = ("SIM only；真实几何 + 真实 params 的**单个完整 job**；"
                       "走 kws_mmio 的寄存器/buffer 窗/结果窗，不是直接例化核")
    report["answers"] = {
        "4000_offset_verified": bool(base["result"] == "PASS" and base.get("logit_word")),
        "note": ("0x800 读出的是 FC logits（RAM 偏移 4000），且与 golden_fc 逐字节相同；"
                 "同时 R5 证明它不是 buffer[0..3] 的别名"),
        "cycle_delta_vs_author": (None if base["cycle_count"] is None
                                  else base["cycle_count"] - 352020),
    }
    report["not_run"] = [
        "CPU 程序级跑真实几何（本台用总线直接写 buffer，不经过 CPU 取指/访存）",
        "PCM -> 前端 -> 49 帧窗口（K6-B 三/四/五级）",
        "多帧连续 job / 背靠背 START 的吞吐",
        "综合 / 时序 / 位流 / 板级",
        "跨机复现（本机 Icarus 13.0 单次结果）",
    ]
    # K6-04 独立产物：四段周期分项（**不与 PDS 六项相加**）
    seg = base.get("segments")
    k604 = {
        "item": "K6-04",
        "scope": "SIM；真几何 49x40 -> 25x20x8 (4000 B) -> FC 4；单个完整 job",
        "geometry": report["geometry"],
        "boundaries": {
            "to_feature": "第一个特征写事务开始 → 第 1,960 B 特征写入完成",
            "to_start": "特征完成 → CTRL.START 被接受（**含**一次 INPUT_CRC32 寄存器读）",
            "to_start_nocrc": "CRC 读完成 → START（真实启动开销；CRC 读本身被 crc32_buf 反压约 1,961 拍，单列为 crc_read_block）",
            "busy": "START 接受 → done 对总线可见",
            "logit_tail": "done 可见 → 4 个 logit 读完",
            "end_to_end": "第一个特征写事务开始 → logits 读完",
        },
        "cycles": seg,
        "cross_check": {
            "kernel_cycle_count": base.get("cycle_count"),
            "busy_minus_kernel": (seg["busy"] - base["cycle_count"])
            if seg and base.get("cycle_count") is not None else None,
            "tolerance": 64,
            "invariant": "to_feature + to_start + busy + logit_tail == end_to_end",
        },
        "how": ("TB 侧拍计数器；边界只由外部总线事务与 done 可见性定义，"
                "不复用 DUT 内部状态当期望值；边界在跑之前已冻结（见 TB 注释）"),
        "witness": {
            "bus": "全部特征写入/寄存器访问都是本 TB 主动发起的总线事务（bus_xfer 检查 req_ready 先于握手）",
            "irq": ("`irq` 引脚 + IRQ_EN@0x00C / IRQ_PENDING@0x044 / IRQ_CLR@0x010 三个寄存器事务："
                    "R7 使能（且 START 前必为低）→ R8 首个 irq=1 的拍号落在 busy 窗口内"
                    "（正常完成时 done 后 1 拍）→ R9 pending 读出 1、清零后电平必掉。"
                    "判据只用引脚与寄存器，不引用 irq_q/irq_en 内部信号"),
            "gpio": ("本台 DUT 是 `kws_mmio` 独立模块，**没有 GPIO**；GPIO 见证在 SoC 级台"
                     "（tb_kws_cpu_smoke：gpio=0x3219，5038 拍）与短缓冲负控（GPIO 保持 0）"
                     "里，不重复记在本台"),
        },
        "not_included": ["host 前端 PCM→特征时间", "PDS 资源/时序", "板级"],
        "negative_controls": {
            "shortbuf_1959B": "见 k6_shortbuf_report.json（少写 1 字节 ⇒ traps=1、GPIO 保持 0）",
            "start_not_accepted": "本台 R1/start_count 判据：START 未被接受即 FAIL",
            "lost_done": "guard 超时即 FAIL（不会假完成）",
        },
        "verdict": "PASS" if (seg and base["result"] == "PASS") else "FAIL",
    }
    k604_path = ROOT / "verification/kws/k6/k6_cycle_breakdown.json"
    k604_path.write_text(json.dumps(k604, ensure_ascii=False, indent=2) + "\n",
                         encoding="utf-8", newline="\n")
    report["k6_04"] = {"artifact": "verification/kws/k6/k6_cycle_breakdown.json",
                       "cycles": seg}

    out_path = ROOT / "verification/kws/k6/k6_mmio_real_report.json"
    out_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n",
                        encoding="utf-8", newline="\n")
    print(f"report: {out_path.relative_to(ROOT)}")
    print(f"VERDICT: {report['verdict']}")
    return 0 if ok_all else 1


if __name__ == "__main__":
    sys.exit(main())
