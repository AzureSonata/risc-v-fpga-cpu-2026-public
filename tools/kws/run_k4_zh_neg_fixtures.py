#!/usr/bin/env python3
"""Compare the archived zh_neg_ab_20261101 LiteRT layers with OpenEye K4 RTL."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import struct
import subprocess
import sys
from pathlib import Path


FIXTURES = (
    "yes_1000ms_real49",
    "no_1000ms_real49",
    "silence_1000ms_real49",
    "noise_1000ms_real49",
)
RTL = (
    "rtl/accel/openeye_srdhm.sv",
    "rtl/accel/openeye_dw_conv.sv",
    "rtl/accel/openeye_fc.sv",
    "rtl/accel/openeye_top.sv",
)
TB = "verification/kws/k4/tb_openeye_k4.sv"
K6_TB = "verification/kws/k6/tb_kws_mmio_real.sv"
K6_RTL = (
    "rtl/soc/kws_in_w_ram.sv",
    "rtl/soc/kws_res_w_ram.sv",
    "rtl/soc/kws_model_rom.sv",
    "rtl/soc/kws_mmio.sv",
    "rtl/accel/openeye_top.sv",
    "rtl/accel/openeye_dw_conv.sv",
    "rtl/accel/openeye_fc.sv",
    "rtl/accel/openeye_srdhm.sv",
    "rtl/estop/kws_estop_watchdog.sv",
)
MODEL_ID = "zh_neg_ab_20261101"
MODEL_SHA256 = "3540b8b9fcfa1513abb9d2aae9f6e6ee68fe48adfb6cc2bd8ae9d0d3029eb43f"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_hex(path: Path, data: bytes) -> None:
    path.write_text("".join(f"{b:02x}\n" for b in data), encoding="ascii", newline="")


def write_hex_i32(path: Path, vals) -> None:
    path.write_text("".join(f"{int(v) & 0xffffffff:08x}\n" for v in vals),
                    encoding="ascii", newline="")


def run(cmd: list[str], cwd: Path) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                          encoding="utf-8", errors="replace", timeout=1800)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--repo", type=Path, default=Path.cwd())
    ap.add_argument("--iverilog", type=Path, required=True,
                    help="directory containing iverilog.exe and vvp.exe")
    ap.add_argument("--fixtures", nargs="*", default=list(FIXTURES))
    args = ap.parse_args()
    root = args.repo.resolve()
    iv = (args.iverilog / "iverilog.exe").resolve()
    vv = (args.iverilog / "vvp.exe").resolve()
    for exe in (iv, vv):
        if not exe.is_file():
            ap.error(f"missing tool: {exe}")
    iv_version = run([str(iv), "-V"], root)
    vv_version = run([str(vv), "-V"], root)

    model_root = root / "fpga/kws/generated" / MODEL_ID
    rom = (model_root / "params_rom.bin").read_bytes()
    quant = (model_root / "quant.mem").read_bytes()
    generated = json.loads((model_root / "generated_manifest.json").read_text(encoding="utf-8"))
    if generated["source"]["sha256"] != MODEL_SHA256:
        raise SystemExit("FAIL: generated model manifest does not identify the frozen hard-negative model")
    if len(rom) != 16688 or len(quant) != 96:
        raise SystemExit(f"FAIL: unexpected ROM sizes params={len(rom)} quant={len(quant)}")
    fc_out_zp = int(generated["descriptors"][1]["fields"]["output_zp"])

    build = root / "build/zh-neg-openeye-20261103/k4"
    build.mkdir(parents=True, exist_ok=True)
    results = []
    for fixture in args.fixtures:
        vec_in = root / "verification/kws/k2/vectors" / fixture / "layer_00_RESHAPE_out_04.bin"
        if not vec_in.is_file() or vec_in.stat().st_size != 1960:
            raise SystemExit(f"FAIL: missing/invalid K2 input fixture {vec_in}")
        raw = vec_in.read_bytes()
        refdir = build / "reference" / fixture
        host_cmd = [sys.executable, str(root / "tools/kws/host_reference.py"),
                    "--model", str(root / "verification/kws/k3/zh_neg_ab_20261101/openeye_source/m4ops.tflite"),
                    "--features-bin", str(vec_in), "--fixture-id", fixture,
                    "--provenance", f"K2 feature fixture SHA-256 {sha256(raw)}",
                    "--provenance-class", "derived", "--out-dir", str(refdir),
                    "--json-out", str(refdir.with_suffix(".json"))]
        host = run(host_cmd, root)
        if host.returncode != 0:
            print(host.stdout + host.stderr)
            raise SystemExit(f"FAIL: LiteRT reference failed for {fixture} (exit {host.returncode})")
        ref_json = json.loads(refdir.with_suffix(".json").read_text(encoding="utf-8"))
        dw_file = next(refdir.glob("layer_01_DEPTHWISE_CONV_2D_out_*.bin"))
        fc_file = next(refdir.glob("layer_02_FULLY_CONNECTED_out_*.bin"))
        dw = dw_file.read_bytes()
        fc = fc_file.read_bytes()
        if len(dw) != 4000 or len(fc) != 4:
            raise SystemExit(f"FAIL: unexpected LiteRT output sizes for {fixture}: DW={len(dw)} FC={len(fc)}")

        vdir = build / f"vectors_{fixture}"
        vdir.mkdir(parents=True, exist_ok=True)
        write_hex(vdir / "dw_in.hex", raw)
        write_hex(vdir / "golden_dw.hex", dw)
        write_hex(vdir / "golden_fc.hex", fc)
        write_hex(vdir / "dw_w.hex", rom[0:640])
        write_hex(vdir / "fc_w.hex", rom[672:16672])
        write_hex_i32(vdir / "dw_bias.hex", struct.unpack("<8i", rom[640:672]))
        write_hex_i32(vdir / "fc_bias.hex", struct.unpack("<4i", rom[16672:16688]))
        pairs = struct.unpack("<24i", quant)
        write_hex_i32(vdir / "quant_mult.hex", pairs[0::2])
        write_hex_i32(vdir / "quant_shift.hex", pairs[1::2])

        vdir_macro = vdir.relative_to(root).as_posix()
        exe = build / f"tb_{fixture}.vvp"
        compile_cmd = [str(iv), "-g2012", "-I", str(root / "rtl/accel"),
                       f"-Ptb_openeye_k4.FC_OUT_ZP={fc_out_zp}",
                       f'-DVECDIR_STR="{vdir_macro}"', "-s", "tb_openeye_k4", "-o", str(exe)]
        compile_cmd += [str(root / p) for p in RTL]
        compile_cmd.append(str(root / TB))
        comp = run(compile_cmd, root)
        log = build / f"{fixture}.log"
        if comp.returncode != 0:
            log.write_text(comp.stdout + comp.stderr, encoding="utf-8")
            raise SystemExit(f"FAIL: Icarus compile failed for {fixture}; see {log}")
        sim = run([str(vv), str(exe)], root)
        log.write_text("$ " + " ".join(compile_cmd) + "\n" + sim.stdout + sim.stderr,
                       encoding="utf-8", newline="")
        passed = sim.returncode == 0 and "PASS [tb_openeye_k4]" in sim.stdout
        k6_exe = build / f"k6_{fixture}.vvp"
        k6_compile_cmd = [str(iv), "-g2012", "-I", str(root / "rtl/accel"),
                          "-DKWS_MODEL_ZH_NEG", f'-DVECDIR_STR="{vdir_macro}"',
                          "-s", "tb_kws_mmio_real", "-o", str(k6_exe)]
        k6_compile_cmd += [str(root / p) for p in K6_RTL]
        k6_compile_cmd.append(str(root / K6_TB))
        k6_comp = run(k6_compile_cmd, root)
        k6_log = build / f"k6_{fixture}.log"
        if k6_comp.returncode != 0:
            k6_log.write_text(k6_comp.stdout + k6_comp.stderr, encoding="utf-8")
            raise SystemExit(f"FAIL: K6 Icarus compile failed for {fixture}; see {k6_log}")
        k6_sim = run([str(vv), str(k6_exe)], root)
        k6_log.write_text("$ " + " ".join(k6_compile_cmd) + "\n" + k6_sim.stdout + k6_sim.stderr,
                          encoding="utf-8", newline="")
        k6_passed = k6_sim.returncode == 0 and "RESULT PASS" in k6_sim.stdout
        argmax = re.search(r"argmax=(\d+) label=([^ ]+) p=([0-9.]+)", host.stdout)
        item = {
            "fixture": fixture,
            "input_sha256": sha256(raw),
            "lite_rt_dw_sha256": sha256(dw),
            "lite_rt_fc_sha256": sha256(fc),
            "fc_output_zero_point": fc_out_zp,
            "class_order": ["silence", "unknown", "yes", "no"],
            "host_output": ({"argmax": int(argmax.group(1)), "label": argmax.group(2),
                             "probability": float(argmax.group(3))} if argmax else None),
            "k4": "PASS" if passed else "FAIL",
            "k6_mmio": "PASS" if k6_passed else "FAIL",
            "log": str(log.relative_to(root)),
            "k6_log": str(k6_log.relative_to(root)),
            "logits_hex": fc.hex(),
        }
        results.append(item)
        print(f"{fixture}: K4={item['k4']} K6={item['k6_mmio']} | FC={fc.hex()} | "
              f"{item['host_output']['label'] if item['host_output'] else 'label-unavailable'}")
        if not passed:
            print(sim.stdout + sim.stderr)
        if not k6_passed:
            print(k6_sim.stdout + k6_sim.stderr)

    report = {
        "model_id": MODEL_ID,
        "model_sha256": MODEL_SHA256,
        "params_rom_sha256": sha256(rom),
        "quant_rom_sha256": sha256(quant),
        "tools": {
            "iverilog": (iv_version.stdout + iv_version.stderr).splitlines()[:2],
            "vvp": (vv_version.stdout + vv_version.stderr).splitlines()[:2],
        },
        "evidence_level": "LiteRT host reference vs OpenEye K4 and K6 MMIO RTL simulation",
        "not_evidence_for": ["classification accuracy/FAR", "PDS", "STA", "bitstream", "board"],
        "results": results,
    }
    report_path = build / "report.json"
    report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n",
                           encoding="utf-8", newline="")
    print(f"report: {report_path.relative_to(root)}")
    return 0 if all(r["k4"] == "PASS" and r["k6_mmio"] == "PASS" for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
