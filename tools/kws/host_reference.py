#!/usr/bin/env python3
"""K2: PC host reference runner for the pinned micro_speech KWS graph.

Runs the *real* LiteRT interpreter (reference kernels, no delegate) on the pinned
`.tflite` and dumps every tensor at every op boundary, so later layers can be
compared byte-for-byte against RTL / firmware output.

Evidence boundary
-----------------
* This is a **host PC** result. It is not accuracy evidence, not FPGA evidence and
  not a statement about the board.
* `--fixture-id` must describe where the 1,960 INT8 bytes came from. Synthetic
  fixtures are allowed for engineering regression but MUST carry
  `"provenance_class": "synthetic"` and may never be reported as accuracy/FAR.
* Interpreter tensors are int8/int32; comparison is exact integer equality.

Usage
-----
  python tools/kws/host_reference.py --model <pinned .tflite> --out-dir <dir> \
      --fixture-id synth-lcg-20261017 --synthetic-lcg
  python tools/kws/host_reference.py ... --fixture-id official-yes30-x49 \
      --repeat-feature <40-byte .bin> --provenance "TFLM testdata yes_30ms.wav (commit 230c9d95)"
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

import numpy as np

FEATURE_BYTES = 1960
LABELS = ["silence", "unknown", "yes", "no"]


def sha256_bytes(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def lcg_bytes(n: int, seed: int = 20261017) -> bytes:
    """Deterministic synthetic payload (NOT audio, NOT a golden fixture)."""
    out = bytearray()
    s = seed
    for _ in range(n):
        s = (1103515245 * s + 12345) & 0x7FFFFFFF
        out.append((s >> 16) & 0xFF)
    return bytes(out)


def build_input(args) -> tuple[bytes, dict]:
    if args.synthetic_lcg:
        raw = lcg_bytes(FEATURE_BYTES, args.seed)
        return raw, {"provenance_class": "synthetic",
                     "provenance": f"LCG(seed={args.seed}) — engineering fixture only, not audio"}
    if args.repeat_feature:
        row = Path(args.repeat_feature).read_bytes()
        if len(row) != 40:
            raise SystemExit(f"feature row must be 40 bytes, got {len(row)}")
        raw = row * 49
        return raw, {"provenance_class": args.provenance_class,
                     "provenance": args.provenance or "40-byte feature row repeated 49x",
                     "feature_row_sha256": sha256_bytes(row)}
    if args.features_bin:
        raw = Path(args.features_bin).read_bytes()
        if len(raw) != FEATURE_BYTES:
            raise SystemExit(f"features must be {FEATURE_BYTES} bytes, got {len(raw)}")
        return raw, {"provenance_class": args.provenance_class,
                     "provenance": args.provenance or "external features file"}
    raise SystemExit("pick one of --synthetic-lcg / --repeat-feature / --features-bin")


def run(model: Path, raw: bytes, out_dir: Path) -> dict:
    from ai_edge_litert.interpreter import Interpreter, OpResolverType

    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "input_int8.bin").write_bytes(raw)
    x = np.frombuffer(raw, dtype=np.uint8).view(np.int8).reshape(1, FEATURE_BYTES)

    # ⚠️ 坑位：LiteRT 的 C++ 绑定用 ANSI 路径打开模型，本工作区路径含中文（06_日志与报告）
    # ⇒ model_path 直接失败 "model allocation is null/empty" ⇒ 必须用 model_content=bytes 读入。
    it = Interpreter(model_content=model.read_bytes(),
                     experimental_preserve_all_tensors=True,
                     experimental_op_resolver_type=OpResolverType.BUILTIN_REF)
    it.allocate_tensors()
    inp = it.get_input_details()[0]
    if list(inp["shape"]) != [1, FEATURE_BYTES] or inp["dtype"] != np.int8:
        raise SystemExit(f"unexpected model input {inp['shape']} {inp['dtype']}")
    it.set_tensor(inp["index"], x)
    it.invoke()

    details = {t["index"]: t for t in it.get_tensor_details()}
    tensors = {}
    for idx, t in sorted(details.items()):
        try:
            arr = np.ascontiguousarray(it.get_tensor(idx))
        except ValueError as exc:
            # Some valid exports retain a dead tensor in the FlatBuffer whose
            # arena buffer is not allocated by LiteRT. It is not an op input or
            # output and therefore has no executable boundary to compare.
            if "Tensor data is null" not in str(exc):
                raise
            continue
        name = t["name"] or f"t{idx}"
        safe = "".join(c if c.isalnum() or c in "-_." else "_" for c in name)[:40]
        fn = f"tensor_{idx:02d}_{safe}.bin"
        (out_dir / fn).write_bytes(arr.tobytes())
        q = t["quantization"]
        scale, zp = (float(q[0]), int(q[1])) if isinstance(q, tuple) and len(q) == 2 else (0.0, 0)
        tensors[idx] = {"index": idx, "name": name, "shape": arr.shape, "dtype": str(arr.dtype),
                        "file": fn, "sha256": sha256_bytes(arr.tobytes()),
                        "quantization": {"scale": scale, "zero_point": zp}}

    # per-op boundary snapshots
    ops = it._get_ops_details()
    layers = []
    for i, op in enumerate(ops):
        ins = [int(t) for t in op["inputs"] if int(t) >= 0]
        outs = [int(t) for t in op["outputs"] if int(t) >= 0]
        layers.append({"index": i, "op": op["op_name"], "inputs": ins, "outputs": outs,
                       "input_sha256": [tensors[t]["sha256"] for t in ins],
                       "output_sha256": [tensors[t]["sha256"] for t in outs]})
        for t in ins:
            (out_dir / f"layer_{i:02d}_{op['op_name']}_in_{t:02d}.bin").write_bytes(
                np.ascontiguousarray(it.get_tensor(t)).tobytes())
        for t in outs:
            (out_dir / f"layer_{i:02d}_{op['op_name']}_out_{t:02d}.bin").write_bytes(
                np.ascontiguousarray(it.get_tensor(t)).tobytes())

    logits = np.asarray(it.get_tensor(details[[o for o in ops if o["op_name"] == "FULLY_CONNECTED"][0]["outputs"][0]]["index"])).ravel()
    probs = np.asarray(it.get_tensor(it.get_output_details()[0]["index"])).ravel()
    argmax = int(np.argmax(probs))
    return {"tensors": tensors, "layers": layers,
            "final": {"logits_int8": [int(v) for v in logits],
                      "softmax_int8": [int(v) for v in probs],
                      "softmax_probs": [round((int(v) + 128) / 256.0, 6) for v in probs],
                      "argmax_index": argmax, "predicted_label": LABELS[argmax],
                      "max_probability": round((int(probs[argmax]) + 128) / 256.0, 6)}}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", type=Path, required=True)
    ap.add_argument("--out-dir", type=Path, required=True)
    ap.add_argument("--fixture-id", required=True)
    ap.add_argument("--synthetic-lcg", action="store_true")
    ap.add_argument("--seed", type=int, default=20261017)
    ap.add_argument("--repeat-feature", type=Path, help="40-byte feature row to repeat 49 times")
    ap.add_argument("--features-bin", type=Path, help="exactly 1960 INT8 bytes")
    ap.add_argument("--provenance", default="")
    ap.add_argument("--provenance-class", default="derived", choices=["official", "derived", "synthetic"])
    ap.add_argument("--json-out", type=Path)
    args = ap.parse_args()
    model = args.model.resolve()
    raw, prov = build_input(args)
    res = run(model, raw, args.out_dir.resolve())
    golden = {
        "fixture_id": args.fixture_id,
        "fixture": {**prov, "bytes": len(raw), "sha256": sha256_bytes(raw), "dtype": "int8", "shape": [1, FEATURE_BYTES]},
        "model": {"file": model.name, "sha256": sha256_bytes(model.read_bytes())},
        "labels": LABELS,
        "toolchain": {"runner": "tools/kws/host_reference.py",
                      "interpreter": "ai-edge-litert", "op_resolver": "BUILTIN_REF",
                      "python": sys.version.split()[0], "numpy": np.__version__},
        "evidence_status": {"host_pc_reference": "PASS (this run)", "layer_golden": "PASS (host PC)",
                            "accuracy": "NOT_RUN", "rtl": "NOT_RUN", "board": "NOT_RUN"},
        **res,
    }
    (args.out_dir / "golden.json").write_text(json.dumps(golden, ensure_ascii=False, indent=2) + "\n",
                                              encoding="utf-8", newline="\n")
    lines = [f"fixture {args.fixture_id}  sha256={golden['fixture']['sha256'][:16]}",
             f"model   {model.name} sha256={golden['model']['sha256'][:16]}"]
    lines += [f"t{idx:>2} {t['name'][:26]:26} {str(t['shape']):18} {t['dtype']:7} {t['sha256'][:16]}"
              for idx, t in sorted(golden["tensors"].items())]
    lines += [f"argmax={golden['final']['argmax_index']} label={golden['final']['predicted_label']} "
              f"p={golden['final']['max_probability']}",
              "PASS: host reference golden written to " + str(args.out_dir)]
    (args.out_dir / "run.log").write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    print("\n".join(lines))
    if args.json_out:
        args.json_out.write_text(json.dumps({"fixture_id": args.fixture_id,
                                             "fixture_sha256": golden["fixture"]["sha256"],
                                             "model_sha256": golden["model"]["sha256"],
                                             "final": golden["final"],
                                             "tensor_sha256": {k: v["sha256"] for k, v in golden["tensors"].items()}},
                                            ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
