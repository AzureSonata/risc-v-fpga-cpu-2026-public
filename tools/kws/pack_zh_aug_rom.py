#!/usr/bin/env python3
"""Pack verification/kws/k7/model_zh_aug_s20261030 vectors into the K4 ROM layout.

Layout (copied from micro_speech-230c9/generated_manifest.json "rom"):
    params_rom.bin = dw_w[640B] + dw_bias[8 x int32 LE = 32B]
                   + fc_w[16000B] + fc_bias[4 x int32 LE = 16B]      = 16688 B
    quant.mem      = 12 x (int32 mult LE + int32 shift LE)             = 96 B
    layers.mem     = model-specific descriptors sourced from the packed 4-op
                     TFLite model; FC output zero point must match tensor 10.
"""
from __future__ import annotations

import hashlib
import json
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "verification/kws/k7/model_zh_aug_s20261030"
DST = ROOT / "fpga/kws/generated/model_zh_aug_s20261030"
SOURCE = SRC / "source"


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def lines(p: Path) -> list[str]:
    return [l.strip() for l in p.read_text().splitlines() if l.strip()]


def bytes8(p: Path) -> bytes:
    return bytes(int(x, 16) for x in lines(p))


def words32(p: Path) -> list[int]:
    return [int(x, 16) for x in lines(p)]


def main() -> int:
    source_manifest = json.loads((SOURCE / "source_manifest.json").read_text(encoding="utf-8"))

    def source_bytes(name: str) -> bytes:
        record = source_manifest["files"][name]
        data = (SOURCE / name).read_bytes()
        if len(data) != record["bytes"] or sha(data) != record["sha256"]:
            raise SystemExit("FAIL: source artifact does not match manifest: %s" % name)
        return data

    raw_model = source_bytes("micro_speech_quantized.tflite")
    packed_model = source_bytes("micro_speech_4ops.tflite")
    layers = source_bytes("layers.mem")
    source_params = source_bytes("params_rom.bin")
    source_quant = source_bytes("quant.mem")
    strip_gate = json.loads(source_bytes("strip_gate.json").decode("utf-8"))
    packed_source_manifest = json.loads(source_bytes("packed_generated_manifest.json").decode("utf-8"))
    if sha(raw_model) != source_manifest["models"]["raw_tflite"]["sha256"]:
        raise SystemExit("FAIL: raw TFLite hash differs from source model manifest")
    if sha(packed_model) != source_manifest["models"]["packed_4ops_tflite"]["sha256"]:
        raise SystemExit("FAIL: packed TFLite hash differs from source model manifest")
    if not strip_gate.get("logits_bit_identical") or not strip_gate.get("softmax_bit_identical"):
        raise SystemExit("FAIL: stripped 4-op model is not proven bit-identical to raw model")
    if strip_gate.get("ops_in") != source_manifest["parser"]["raw_graph_ops"]:
        raise SystemExit("FAIL: raw graph operators disagree with strip gate")
    if strip_gate.get("ops_out") != source_manifest["parser"]["packed_graph_ops"]:
        raise SystemExit("FAIL: packed graph operators disagree with strip gate")
    if len(layers) != 256:
        raise SystemExit("FAIL: expected two 128-byte model-specific descriptors")

    # Bind descriptors to the packed graph and validate their embedded CRCs.
    model_crc = zlib.crc32(packed_model) & 0xFFFFFFFF
    rom_binding = source_manifest["rom_binding"]
    if model_crc != rom_binding["model_crc32_of_packed_4ops_tflite"]:
        raise SystemExit("FAIL: packed model CRC32 disagrees with source contract")
    for index, expected in enumerate(rom_binding["layers"]):
        descriptor = bytearray(layers[index * 128:(index + 1) * 128])
        stored_model_crc = struct.unpack_from("<I", descriptor, 0x6C)[0]
        stored_descriptor_crc = struct.unpack_from("<I", descriptor, 0x70)[0]
        struct.pack_into("<I", descriptor, 0x70, 0)
        if stored_model_crc != model_crc:
            raise SystemExit("FAIL: descriptor %d references a different packed TFLite graph" % index)
        if zlib.crc32(descriptor) & 0xFFFFFFFF != stored_descriptor_crc:
            raise SystemExit("FAIL: descriptor %d CRC32 mismatch" % index)
        if stored_descriptor_crc != expected["descriptor_crc32"]:
            raise SystemExit("FAIL: descriptor %d CRC32 differs from source manifest" % index)
        if sha(layers[index * 128:(index + 1) * 128]) != expected["sha256"]:
            raise SystemExit("FAIL: descriptor %d bytes differ from source manifest" % index)

    # Descriptor fields are little-endian ABI data consumed by kws_model_rom.sv.
    fc_desc = layers[128:256]
    fc_in_zp = struct.unpack_from("<i", fc_desc, 0x48)[0]
    fc_out_zp = struct.unpack_from("<i", fc_desc, 0x4C)[0]
    fc_nout = struct.unpack_from("<I", fc_desc, 0x60)[0]
    fc_nin = struct.unpack_from("<I", fc_desc, 0x64)[0]
    fc_contract = source_manifest["contract"]["fully_connected"]
    if (fc_in_zp, fc_out_zp, fc_nin, fc_nout) != (
        fc_contract["input_zero_point"], fc_contract["output_zero_point"],
        fc_contract["input_shape"][1], fc_contract["output_shape"][1],
    ):
        raise SystemExit(
            "FAIL: FC descriptor disagrees with source TFLite contract: "
            "in_zp=%d out_zp=%d nin=%d nout=%d" % (fc_in_zp, fc_out_zp, fc_nin, fc_nout)
        )

    dw_w = bytes8(SRC / "vectors/dw_w.hex")
    fc_w = bytes8(SRC / "vectors/fc_w.hex")
    dw_b = words32(SRC / "vectors/dw_bias.hex")
    fc_b = words32(SRC / "vectors/fc_bias.hex")
    qm = words32(SRC / "vectors/quant_mult.hex")
    qs = words32(SRC / "vectors/quant_shift.hex")

    assert len(dw_w) == 640, len(dw_w)
    assert len(fc_w) == 16000, len(fc_w)
    assert len(dw_b) == 8 and len(fc_b) == 4, (len(dw_b), len(fc_b))
    assert len(qm) == 12 and len(qs) == 12, (len(qm), len(qs))

    dw_bias_bytes = b"".join(struct.pack("<i", v - (1 << 32) if v >= 1 << 31 else v) for v in dw_b)
    fc_bias_bytes = b"".join(struct.pack("<i", v - (1 << 32) if v >= 1 << 31 else v) for v in fc_b)
    params = dw_w + dw_bias_bytes + fc_w + fc_bias_bytes
    assert len(params) == 16688, len(params)
    if params != source_params:
        raise SystemExit("FAIL: packed parameter bytes differ from the frozen source ROM")

    quant = b"".join(
        struct.pack("<ii", m - (1 << 32) if m >= 1 << 31 else m, s - (1 << 32) if s >= 1 << 31 else s)
        for m, s in zip(qm, qs)
    )
    assert len(quant) == 96, len(quant)
    if quant != source_quant:
        raise SystemExit("FAIL: packed quant bytes differ from the frozen source ROM")

    qmult = [v - (1 << 32) if v >= (1 << 31) else v for v in qm]
    qshift = [v - (1 << 32) if v >= (1 << 31) else v for v in qs]
    if qmult[8:12] != fc_contract["q31_multiplier"] or qshift[8:12] != fc_contract["shift"]:
        raise SystemExit("FAIL: FC quant ROM differs from TFLite per-channel effective scales")

    for name, expected in source_manifest["vectors"].items():
        if sha((SRC / "vectors" / name).read_bytes()) != expected["sha256"]:
            raise SystemExit("FAIL: source vector does not match contract manifest: %s" % name)

    DST.mkdir(parents=True, exist_ok=True)
    (DST / "params_rom.bin").write_bytes(params)
    (DST / "quant.mem").write_bytes(quant)
    (DST / "layers.mem").write_bytes(layers)

    manifest = {
        "model_id": "model_zh_aug_s20261030",
        "source": {
            "repo": "risc-v-fpga-cpu-2026",
            "ref": "origin/sync/kws-20261019",
            "commit": source_manifest["origin"]["model_commit"],
            "vectors_dir": "verification/kws/k7/model_zh_aug_s20261030/vectors",
            "raw_tflite_sha256": sha(raw_model),
            "packed_4ops_tflite_sha256": sha(packed_model),
            "layers_mem_sha256": sha(layers),
            "packed_model_crc32": model_crc,
            "source_manifest_sha256": sha((SOURCE / "source_manifest.json").read_bytes()),
            "strip_gate_sha256": sha((SOURCE / "strip_gate.json").read_bytes()),
            "board_rom_init_sha256": sha((SRC / "board_rom_init.json").read_bytes()),
        },
        "toolchain": {
            "packer": "tools/kws/pack_zh_aug_rom.py",
            "layout_reference": "K4 128-byte descriptor ABI (compile_openeye.py)",
            "generator": "tools/kws/export_model_rom_hex.py",
        },
        "rom": {
            "params_rom_bytes": len(params),
            "params_rom_sha256": sha(params),
            "conv_weights": {"base": 0, "bytes": 640, "sha256": sha(dw_w)},
            "conv_bias_hw": {"base": 640, "bytes": 32, "sha256": sha(dw_bias_bytes)},
            "fc_weights": {"base": 672, "bytes": 16000, "sha256": sha(fc_w)},
            "fc_bias_hw": {"base": 16672, "bytes": 16, "sha256": sha(fc_bias_bytes)},
            "quant_rom_bytes": len(quant),
            "quant_rom_sha256": sha(quant),
            "source": {
                "dw_weights_sha256": sha((SRC / "vectors/dw_w.hex").read_bytes()),
                "dw_bias_sha256": sha((SRC / "vectors/dw_bias.hex").read_bytes()),
                "fc_weights_sha256": sha((SRC / "vectors/fc_w.hex").read_bytes()),
                "fc_bias_sha256": sha((SRC / "vectors/fc_bias.hex").read_bytes()),
                "quant_mult_sha256": sha((SRC / "vectors/quant_mult.hex").read_bytes()),
                "quant_shift_sha256": sha((SRC / "vectors/quant_shift.hex").read_bytes()),
            },
        },
        "descriptors": packed_source_manifest["descriptors"],
        "descriptors_note": "model-specific descriptors from the packed 4-op TFLite model; FC tensor 10 output zero point is 21",
        "model_contract": {
            "labels": source_manifest["origin"]["labels"],
            "source_model_commit": source_manifest["origin"]["model_commit"],
            "raw_graph_ops": source_manifest["parser"]["raw_graph_ops"],
            "packed_graph_ops": source_manifest["parser"]["packed_graph_ops"],
            "fully_connected_weight_scales": fc_contract["weight_scales"],
            "fully_connected_bias_scales": fc_contract["bias_scales"],
            "fully_connected_weight_zero_points": fc_contract["weight_zero_points"],
            "fully_connected_bias_zero_points": fc_contract["bias_zero_points"],
            "fc_input": {
                "tensor_index": fc_contract["input_tensor"],
                "shape": fc_contract["input_shape"],
                "scale": fc_contract["input_scale"],
                "zero_point": fc_contract["input_zero_point"],
            },
            "fully_connected_input_scale": fc_contract["input_scale"],
            "fc_output": {
                "tensor_index": fc_contract["output_tensor"],
                "shape": fc_contract["output_shape"],
                "scale": fc_contract["output_scale"],
                "zero_point": fc_contract["output_zero_point"],
            },
            "softmax_output": source_manifest["contract"]["softmax"],
        },
        "activation_peak_bytes": packed_source_manifest.get("activation_peak_bytes"),
        "evidence_status": {
            "parser_manifest_pack": "PASS (pack_zh_aug_rom.py)",
            "source_tflite_contract": "PASS (FlatBuffer tensor audit; see evidence/kws-model-contract-20261102)",
            "layer_descriptor_equivalence": "PASS (model-specific descriptor; FC output zero point=21)",
            "rom_tensor_binding": "PASS (weights, folded biases, and FC per-channel quantization matched)",
            "rtl_layer_output": "NOT_RUN (no RTL simulation in this contract audit)",
            "corrected_rtl_openeye_parity": "NOT_RUN (existing parity is bound to FC output zero point 14)",
            "pds": "NOT_RUN",
            "board": "NOT_RUN",
        },
    }
    (DST / "generated_manifest.json").write_text(
        json.dumps(manifest, indent=1, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    print("params_rom.bin bytes=%d sha256=%s" % (len(params), sha(params)))
    print("quant.mem      bytes=%d sha256=%s" % (len(quant), sha(quant)))
    print("layers.mem     bytes=%d sha256=%s" % (len(layers), sha(layers)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
