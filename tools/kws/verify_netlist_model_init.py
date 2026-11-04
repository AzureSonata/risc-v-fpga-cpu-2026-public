#!/usr/bin/env python3
"""Check which generated model a Yosys board netlist actually carries.

Parses the `initial` block assignments that Yosys emits for the KWS model ROM
memories and compares them, value by value, against the `$readmemh` images of
every generated model under fpga/kws/generated/. The netlist bakes the model in
at Yosys time, so this is the check that answers "did the board netlist really
pick up model X?".
"""
from __future__ import annotations

import argparse
import hashlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# netlist array -> (readmemh file, expected element count)
ARRAYS = {
    "dw_weights": ("dw_weights.hex", 640),
    "fc_weights": ("fc_weights.hex", 16000),
    "biases": ("bias.hex", 48),
    "quant": ("quant.hex", 96),
}
DESCRIPTORS = ("descriptor.hex", 128)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def hex_values(path: Path) -> list[int]:
    return [int(line, 16) for line in path.read_text(encoding="ascii").splitlines() if line]


def parse_netlist(text: str) -> dict[str, dict[int, int]]:
    found: dict[str, dict[int, int]] = {}
    for array in [*ARRAYS, "descriptors"]:
        pattern = re.compile(
            rf"^\s*{array}\[(\d+)\]\s*=\s*\d+'([hd])([0-9a-fA-F_]+);$",
            flags=re.MULTILINE,
        )
        found[array] = {
            int(index): int(digits.replace("_", ""), 16 if base == "h" else 10)
            for index, base, digits in pattern.findall(text)
        }
    return found


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--netlist",
        type=Path,
        default=ROOT / "build/pds/kws_soc_board/pangu100proplus_w3_kws_board_top_syn.v",
    )
    ap.add_argument("--expect", help="model id that must match 100%%")
    args = ap.parse_args()
    netlist = args.netlist if args.netlist.is_absolute() else ROOT / args.netlist

    text = netlist.read_text(encoding="utf-8", errors="replace")
    net = parse_netlist(text)
    print(f"netlist {netlist.as_posix()} bytes={netlist.stat().st_size} sha256={sha256(netlist)}")
    print()

    models = sorted(p.name for p in (ROOT / "fpga/kws/generated").iterdir() if p.is_dir())
    targets: dict[str, dict[str, list[int]]] = {}
    for model in models:
        readmemh = ROOT / "fpga/kws/generated" / model / "readmemh"
        if not readmemh.is_dir():
            continue
        images = {array: hex_values(readmemh / name) for array, (name, _) in ARRAYS.items()}
        desc = hex_values(readmemh / DESCRIPTORS[0])
        images["descriptors"] = [
            desc[i] | (desc[i + 1] << 8) for i in range(0, len(desc) - 1, 2)
        ]
        targets[model] = images

    failed = False
    for array in [*ARRAYS, "descriptors"]:
        values = net[array]
        expected = ARRAYS.get(array, DESCRIPTORS)[1]
        print(f"{array}[0:{expected - 1}] netlist_entries={len(values)}")
        if len(values) != expected:
            print(f"  UNEXPECTED entry count (expected {expected})")
            failed = True
        for model, images in targets.items():
            reference = images[array]
            pairs = [(i, values.get(i)) for i in range(expected)]
            same = sum(1 for i, v in pairs if v == reference[i])
            first = next((i for i, v in pairs if v != reference[i]), None)
            detail = "" if first is None else (
                f" first_diff={first} netlist=0x{values.get(first, 0):x} model=0x{reference[first]:x}"
            )
            print(f"  {model:<28} same={same}/{expected}{detail}")
            if args.expect and model == args.expect and same != expected:
                failed = True
    print()
    print("RESULT:", "FAIL" if failed else "PASS")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
