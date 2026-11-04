#!/usr/bin/env python3
"""Export the locked KWS model images as byte-addressed $readmemh inputs."""
from __future__ import annotations

import argparse
import hashlib
import json
import struct
from pathlib import Path


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_hex(path: Path, data: bytes) -> None:
    # newline="" keeps the image LF-only on Windows too, so the SHA-256 quoted in
    # the manifests and evidence is identical on every platform.
    path.write_text("".join("%02x\n" % b for b in data), encoding="ascii", newline="")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", type=Path, default=Path.cwd())
    ap.add_argument(
        "--model",
        default="micro_speech-230c9",
        help="model id under fpga/kws/generated/ (default: micro_speech-230c9)",
    )
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    root = args.repo.resolve()
    model = root / "fpga/kws/generated" / args.model
    manifest = json.loads((model / "generated_manifest.json").read_text(encoding="utf-8"))
    packed = (model / "params_rom.bin").read_bytes()
    quant = (model / "quant.mem").read_bytes()
    desc = (model / "layers.mem").read_bytes()
    rom = manifest["rom"]
    expected = rom["params_rom_sha256"]
    if sha256(packed) != expected:
        raise SystemExit("FAIL: params_rom.bin SHA-256 does not match manifest")
    if sha256(quant) != rom["quant_rom_sha256"]:
        raise SystemExit("FAIL: quant.mem SHA-256 does not match manifest")
    if len(packed) != rom["params_rom_bytes"] or len(quant) != rom["quant_rom_bytes"]:
        raise SystemExit("FAIL: model ROM byte count does not match manifest")
    if len(desc) != 256:
        raise SystemExit("FAIL: expected two 128-byte descriptors")
    images = {
        "dw_weights.hex": packed[0:640],
        "fc_weights.hex": packed[672:16672],
        "bias.hex": packed[640:672] + packed[16672:16688],
        "quant.hex": quant,
        "descriptor.hex": desc,
    }
    out = model / "readmemh"
    for name, data in images.items():
        dst = out / name
        encoded = "".join("%02x\n" % b for b in data)
        if args.check:
            # Compare decoded text: $readmemh ignores line endings, and the frozen
            # 230c9 images are CRLF while freshly generated ones are LF.
            if not dst.exists() or dst.read_text(encoding="ascii") != encoded:
                raise SystemExit("FAIL: generated image stale or missing: %s" % dst.relative_to(root))
        else:
            out.mkdir(parents=True, exist_ok=True)
            dst.write_text(encoded, encoding="ascii", newline="")
        print("PASS: %s bytes=%d sha256=%s" % (dst.relative_to(root), len(data), sha256(data)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
