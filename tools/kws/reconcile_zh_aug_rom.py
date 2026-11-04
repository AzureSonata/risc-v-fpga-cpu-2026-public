#!/usr/bin/env python3
"""Compare the packed model_zh_aug_s20261030 ROM against the owner's board_rom/*.hex."""
from __future__ import annotations

import hashlib
import json
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GEN = ROOT / "fpga/kws/generated/model_zh_aug_s20261030"
SRC = ROOT / "verification/kws/k7/model_zh_aug_s20261030"


def lines(p: Path) -> list[str]:
    return [l.strip() for l in p.read_text().splitlines() if l.strip()]


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def cmp(name: str, ours: list[int], theirs: list[int], expected_sum: str | None) -> dict:
    n = min(len(ours), len(theirs))
    same = sum(1 for i in range(n) if ours[i] == theirs[i])
    first = next((i for i in range(n) if ours[i] != theirs[i]), None)
    s = sum(ours) & 0xFFFFFFFF
    row = {
        "name": name,
        "our_values": len(ours),
        "board_values": len(theirs),
        "compared": n,
        "same": same,
        "ratio": same / n if n else 0.0,
        "first_diff": first,
        "our_sum32": "%08x" % s,
        "expected_sum32": expected_sum,
        "sum32_match": (("%08x" % s) == expected_sum) if expected_sum else None,
    }
    if first is not None:
        row["diff_detail"] = "idx %d: ours=%08x board=%08x" % (first, ours[first], theirs[first])
    return row


def main() -> int:
    init = json.loads((SRC / "board_rom_init.json").read_text(encoding="utf-8"))
    sums = {r["name"]: r["sum32"] for r in init["roms"]}

    params = (GEN / "params_rom.bin").read_bytes()
    quant = (GEN / "quant.mem").read_bytes()
    dw_w = params[0:640]
    dw_b = list(struct.unpack("<8i", params[640:672]))
    fc_w = params[672:16672]
    fc_b = list(struct.unpack("<4i", params[16672:16688]))
    qw = list(struct.unpack("<24i", quant))
    qm = qw[0::2]
    qs = qw[1::2]

    board = SRC / "board_rom"
    b_dw = [int(x, 16) for x in lines(board / "board_dw_w.hex")]
    b_fc = [int(x, 16) for x in lines(board / "board_fc_w.hex")]
    b_b = [int(x, 16) for x in lines(board / "board_bias.hex")]
    b_qm = [int(x, 16) for x in lines(board / "board_qmult.hex")]
    b_qs = [int(x, 16) for x in lines(board / "board_qshift.hex")]

    ours_bias = [v & 0xFFFFFFFF for v in dw_b + fc_b]

    rows = [
        cmp("dw_w", list(dw_w), b_dw[:640], sums["dw_w"]),
        cmp("fc_w", list(fc_w), b_fc[:16000], sums["fc_w"]),
        cmp("bias", ours_bias, b_b[:12], sums["bias"]),
        cmp("qmult", [v & 0xFFFFFFFF for v in qm], b_qm[:12], sums["qmult"]),
        cmp("qshift", [v & 0xFFFFFFFF for v in qs], b_qs[:12], sums["qshift"]),
    ]

    print("%-8s %-6s %-7s %-7s %-7s %-9s %-9s %-6s %s" % (
        "rom", "ours", "board", "same", "ratio", "our_sum32", "expect", "match", "first_diff"))
    for r in rows:
        print("%-8s %-6d %-7d %-7d %6.2f%%  %-9s %-9s %-6s %s" % (
            r["name"], r["our_values"], r["board_values"], r["same"], r["ratio"] * 100,
            r["our_sum32"], r["expected_sum32"], r["sum32_match"], r["first_diff"]))

    print()
    print("board padding check (used vs full):")
    print("  dw_w    board[640:] all zero:", all(v == 0 for v in b_dw[640:]))
    print("  fc_w    board[16000:] all zero:", all(v == 0 for v in b_fc[16000:]))
    print("  bias    board[12:] all zero:", all(v == 0 for v in b_b[12:]))
    print("  qmult   board[12:] all one:", all(v == 1 for v in b_qm[12:]))
    print("  qshift  board[12:] all zero:", all(v == 0 for v in b_qs[12:]))

    print()
    print("all-equal check (0 diff over compared range):",
          all(r["first_diff"] is None for r in rows))
    print("all sum32 reproduced:", all(r["sum32_match"] for r in rows))

    # byte-level: rebuild the owner's board images straight from OUR packed ROM,
    # applying the padding rules declared in board_rom_init.json, and hash the
    # resulting text so the comparison is byte-exact rather than value-exact.
    text = {
        "board_dw_w.hex": ["%02x" % b for b in dw_w] + ["00"] * 384,
        "board_fc_w.hex": ["%02x" % b for b in fc_w] + ["00"] * 384,
        "board_bias.hex": ["%08x" % v for v in ours_bias] + ["00000000"] * 1012,
        "board_qmult.hex": ["%08x" % v for v in [v & 0xFFFFFFFF for v in qm]] + ["00000001"] * 1012,
        "board_qshift.hex": ["%08x" % v for v in [v & 0xFFFFFFFF for v in qs]] + ["00000000"] * 1012,
    }
    declared = {Path(r["out_file"]).name: r["out_sha256"] for r in init["roms"]}
    print()
    print("board images rebuilt from our ROM (byte-exact, incl. padding):")
    for fn, vals in text.items():
        raw = ("".join(v + "\n" for v in vals)).encode("ascii")
        theirs = (board / fn).read_bytes()
        print("  %-20s bytes=%6d sha256=%s identical=%s declared_match=%s" % (
            fn, len(raw), sha(raw), raw == theirs, sha(raw) == declared[fn]))

    print()
    print("deliverable sha256:")
    for rel in ["params_rom.bin", "quant.mem", "layers.mem", "generated_manifest.json"]:
        p = GEN / rel
        print("  %-24s bytes=%6d sha256=%s" % (rel, p.stat().st_size, sha(p.read_bytes())))
    for rel in ["dw_weights.hex", "fc_weights.hex", "bias.hex", "quant.hex", "descriptor.hex"]:
        p = GEN / "readmemh" / rel
        print("  readmemh/%-16s bytes=%6d sha256=%s" % (rel, p.stat().st_size, sha(p.read_bytes())))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
