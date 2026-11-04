#!/usr/bin/env python3
"""KWS K1 host-side importer/packer: pinned .tflite -> manifest/layers/ROM + host reference.

Scope (evidence boundary)
-------------------------
Implements the *host-side* half of KWS K1/K4:
  * parse the pinned FlatBuffer with the pinned official schema (flatc 24.3.25),
  * fail closed on anything the hardware contract cannot express,
  * emit kws_manifest.json / layers.json / human-readable layer table,
  * pack weight/bias/quant ROM images and the 128-byte layer descriptors
    fixed by docs/plans/KWS_IMPLEMENTATION_CONTRACT.md §13,
  * run an integer host reference (numpy) + pack/unpack round-trip proof.

It is NOT: inference accuracy, RTL simulation, PDS, or board evidence.
Layer goldens against a real TFLM interpreter stay NOT_RUN until K2.

Fail-closed rule: any unsupported builtin/custom op, dynamic shape, unexpected
dtype, missing per-channel quant, unknown activation/padding, or constant-buffer
size mismatch raises ContractError naming model hash + op index + tensor index +
field, and the process exits non-zero. There is no fallback path.

⚠️ 坑位：flatbuffers>=25 的 DataAsNumpy() 需要 numpy（否则 NumpyRequiredForThisFeature）；
本工具同时依赖 flatc 生成的 schema 绑定 ⇒ 必须按 scripts/kws/requirements-inspect.txt 装齐
（见 LESSON-002 / 日志 2026-10-17-01）。
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import struct
import subprocess
import sys
import zlib
from pathlib import Path

import numpy as np

TYPE_BYTES = {"FLOAT32": 4, "FLOAT16": 2, "INT32": 4, "UINT8": 1, "INT64": 8,
              "BOOL": 1, "INT16": 2, "INT8": 1, "UINT16": 2, "UINT32": 4, "UINT64": 8}
# Contract §13 fixed constants (do not change without an approved ABI revision).
DESCRIPTOR_MAGIC = 0x314C574B  # 'KWL1'
DESCRIPTOR_SIZE = 128
DESCRIPTOR_ABI = 1
SCRATCH = {"input_base": 0x0000, "act_a": 0x0800, "act_b": 0x1800, "limit": 0x2800}
PARAM_LAYOUT = {"conv_w_base": 0, "conv_b_base": 640, "fc_w_base": 672, "fc_b_base": 16672,
                "params_bytes": 16688, "conv_q_base": 0, "fc_q_base": 64, "quant_bytes": 96}
ACT_MIN, ACT_MAX = -128, 127


class ContractError(Exception):
    """Fail-closed rejection; message must carry model/op/tensor/field context."""


def sha256_bytes(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def sha256_file(p: Path) -> str:
    return sha256_bytes(Path(p).read_bytes())


def crc32_ieee(b: bytes) -> int:
    return zlib.crc32(b) & 0xFFFFFFFF


# --------------------------------------------------------------------------- parse
def load_schema(flatc: Path, schema_fbs: Path, build_dir: Path):
    gen = build_dir / "generated"
    gen.mkdir(parents=True, exist_ok=True)
    subprocess.run([str(flatc), "--python", "--gen-onefile", "-o", str(gen), str(schema_fbs)],
                   check=True, capture_output=True)
    spec = importlib.util.spec_from_file_location("kws_schema_generated", gen / "schema_generated.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def enum_names(cls):
    return {v: k for k, v in vars(cls).items() if isinstance(v, int)}


def opt_table(schema, name: str, op):
    """Instantiate a typed builtin-options table from the union member."""
    tab = op.BuiltinOptions()
    if tab is None:
        return None
    t = getattr(schema, name)()
    t.Init(tab.Bytes, tab.Pos)
    return t


def parse_model(schema, model_path: Path) -> dict:
    model = schema.Model.GetRootAsModel(model_path.read_bytes(), 0)
    sg = model.Subgraphs(0)
    types = enum_names(schema.TensorType)
    ops_enum = enum_names(schema.BuiltinOperator)
    act_enum = enum_names(schema.ActivationFunctionType)
    padding_enum = enum_names(schema.Padding)
    tensors = []
    for i in range(sg.TensorsLength()):
        t = sg.Tensors(i)
        dtype = types[t.Type()]
        shape = [int(t.Shape(k)) for k in range(t.ShapeLength())]
        q = t.Quantization()
        quant = {"scale": [float(q.Scale(k)) for k in range(q.ScaleLength())] if q else [],
                 "zero_point": [int(q.ZeroPoint(k)) for k in range(q.ZeroPointLength())] if q else [],
                 "quantized_dimension": int(q.QuantizedDimension()) if q else None}
        buf = model.Buffers(t.Buffer())
        constant = bytes(buf.DataAsNumpy()) if buf.DataLength() else b""
        expect = 1
        for d in shape:
            expect *= d
        expect *= TYPE_BYTES[dtype]
        tensors.append({"index": i, "name": t.Name().decode("utf-8"), "shape": shape, "dtype": dtype,
                        "bytes": expect, "is_variable": bool(t.IsVariable()), "buffer_index": int(t.Buffer()),
                        "constant_bytes": len(constant),
                        "constant_sha256": sha256_bytes(constant) if constant else None,
                        "quantization": quant, "_constant": constant})
    operators = []
    for i in range(sg.OperatorsLength()):
        op = sg.Operators(i)
        code = model.OperatorCodes(op.OpcodeIndex())
        numeric = max(int(code.DeprecatedBuiltinCode()), int(code.BuiltinCode()))
        name = ops_enum.get(numeric, f"UNKNOWN_{numeric}")
        entry = {"index": i, "op": name, "opcode_index": int(op.OpcodeIndex()),
                 "builtin_code": int(code.BuiltinCode()),
                 "deprecated_builtin_code": int(code.DeprecatedBuiltinCode()),
                 "custom_code": code.CustomCode().decode() if code.CustomCode() else None,
                 "version": int(code.Version()),
                 "inputs": [int(op.Inputs(k)) for k in range(op.InputsLength())],
                 "outputs": [int(op.Outputs(k)) for k in range(op.OutputsLength())],
                 "builtin_options_type": int(op.BuiltinOptionsType()), "options": {}}
        if name == "DEPTHWISE_CONV_2D":
            o = opt_table(schema, "DepthwiseConv2DOptions", op)
            entry["options"] = {} if o is None else {"padding": padding_enum[int(o.Padding())], "stride_w": int(o.StrideW()),
                                "stride_h": int(o.StrideH()), "depth_multiplier": int(o.DepthMultiplier()),
                                "activation": act_enum[int(o.FusedActivationFunction())],
                                "dilation_w": int(o.DilationWFactor()), "dilation_h": int(o.DilationHFactor())}
        elif name == "FULLY_CONNECTED":
            o = opt_table(schema, "FullyConnectedOptions", op)
            entry["options"] = {} if o is None else {"activation": act_enum[int(o.FusedActivationFunction())],
                                "weights_format": int(o.WeightsFormat()), "keep_num_dims": bool(o.KeepNumDims())}
        elif name == "SOFTMAX":
            o = opt_table(schema, "SoftmaxOptions", op)
            entry["options"] = {} if o is None else {"beta": float(o.Beta())}
        elif name == "RESHAPE":
            o = opt_table(schema, "ReshapeOptions", op)
            entry["options"] = {} if o is None else {
                "new_shape": [int(o.NewShape(k)) for k in range(o.NewShapeLength())]}
        operators.append(entry)
    unique_buffers = {int(sg.Tensors(k).Buffer()) for k in range(sg.TensorsLength())}
    return {"file": model_path.name, "sha256": sha256_file(model_path),
            "file_bytes": model_path.stat().st_size, "model_version": int(model.Version()),
            "inputs": [int(sg.Inputs(k)) for k in range(sg.InputsLength())],
            "outputs": [int(sg.Outputs(k)) for k in range(sg.OutputsLength())],
            "tensors": tensors, "operators": operators,
            "constant_bytes": sum(model.Buffers(i).DataLength() for i in unique_buffers),
            "max_nonconstant_tensor_bytes": max(t["bytes"] for t in tensors if not t["constant_bytes"])}


# ----------------------------------------------------------------------- validate
def reject(msg, model=None, op=None, tensor=None, field=None):
    ctx = []
    if model:
        ctx.append(f"model={model['sha256'][:16]}")
    if op is not None:
        ctx.append(f"op_index={op}")
    if tensor is not None:
        ctx.append(f"tensor_index={tensor}")
    if field:
        ctx.append(f"field={field}")
    raise ContractError(f"{msg} [{', '.join(ctx) or 'no-context'}]")


ALLOWED_MAIN_OPS = ["RESHAPE", "DEPTHWISE_CONV_2D", "FULLY_CONNECTED", "SOFTMAX"]
ALLOWED_DTYPES = {"INT8", "INT32", "INT16", "UINT32", "UINT16", "UINT8"}
ALLOWED_ACT = {"RELU", "NONE"}


def validate_main_graph(m: dict) -> None:
    for i, o in enumerate(m["operators"]):
        if o["op"] not in ALLOWED_MAIN_OPS:
            reject(f"unsupported builtin/custom op '{o['op']}'", m, i,
                   field="builtin_code" if not o["custom_code"] else "custom_code")
    names = [o["op"] for o in m["operators"]]
    if names != ALLOWED_MAIN_OPS:
        reject(f"unexpected operator sequence {names}", m, field="operators")
    for t in m["tensors"]:
        if t["dtype"] not in ALLOWED_DTYPES:
            reject(f"unexpected tensor dtype {t['dtype']}", m, tensor=t["index"], field="dtype")
        for d in t["shape"]:
            if d <= 0:
                reject("dynamic/empty shape dimension", m, tensor=t["index"], field="shape")
        if t["constant_bytes"] and t["constant_bytes"] != t["bytes"]:
            reject(f"constant buffer size {t['constant_bytes']} != shape*itemsize {t['bytes']}",
                   m, tensor=t["index"], field="buffer.data")
    ops = {o["op"]: o for o in m["operators"]}
    rs = ops["RESHAPE"]
    x, y = m["tensors"][rs["inputs"][0]], m["tensors"][rs["outputs"][0]]
    if x["bytes"] != y["bytes"] or x["dtype"] != y["dtype"]:
        reject("RESHAPE is not a pure view (size/dtype changed)", m, rs["index"], field="shape")
    if (x["quantization"]["scale"] != y["quantization"]["scale"]
            or x["quantization"]["zero_point"] != y["quantization"]["zero_point"]):
        reject("RESHAPE changes quantization (not a view)", m, rs["index"], field="quantization")
    dw = ops["DEPTHWISE_CONV_2D"]
    o = dw["options"]
    if o["padding"] not in ("SAME", "VALID"):
        reject(f"unknown padding {o['padding']}", m, dw["index"], field="padding")
    if o["activation"] not in ALLOWED_ACT:
        reject(f"unsupported fused activation {o['activation']}", m, dw["index"], field="activation")
    w, b = m["tensors"][dw["inputs"][1]], m["tensors"][dw["inputs"][2]]
    if w["dtype"] != "INT8" or b["dtype"] != "INT32":
        reject("DEPTHWISE weights/bias dtype must be INT8/INT32", m, dw["index"], field="dtype")
    nsc = len(w["quantization"]["scale"])
    if nsc not in (1, w["shape"][-1]):
        reject(f"weight scale count {nsc} neither per-tensor nor per-channel", m, dw["index"],
               tensor=w["index"], field="quantization.scale")
    if nsc > 1 and w["quantization"]["quantized_dimension"] != 3:
        reject("per-channel DW weights must use quantized_dimension=3 (Cout)", m, dw["index"],
               tensor=w["index"], field="quantization.quantized_dimension")
    if any(z != 0 for z in w["quantization"]["zero_point"]):
        reject("non-zero weight zero_point not expressible by the packed PE path", m, dw["index"],
               tensor=w["index"], field="quantization.zero_point")
    fc = ops["FULLY_CONNECTED"]
    if fc["options"]["activation"] not in ALLOWED_ACT:
        reject(f"unsupported fused activation {fc['options']['activation']}", m, fc["index"], field="activation")
    fw, fb = m["tensors"][fc["inputs"][1]], m["tensors"][fc["inputs"][2]]
    if fw["dtype"] != "INT8" or fb["dtype"] != "INT32":
        reject("FULLY_CONNECTED weights/bias dtype must be INT8/INT32", m, fc["index"], field="dtype")
    nsc_fc = len(fw["quantization"]["scale"])
    if nsc_fc not in (1, fw["shape"][0]):
        reject(f"FC weight scale count {nsc_fc} neither per-tensor nor per-channel", m, fc["index"],
               tensor=fw["index"], field="quantization.scale")
    if nsc_fc > 1 and fw["quantization"]["quantized_dimension"] != 0:
        reject("per-channel FC weights must use quantized_dimension=0", m, fc["index"],
               tensor=fw["index"], field="quantization.quantized_dimension")
    if any(z != 0 for z in fw["quantization"]["zero_point"]):
        reject("non-zero FC weight zero_point not expressible", m, fc["index"], tensor=fw["index"],
               field="quantization.zero_point")
    sm = ops["SOFTMAX"]
    sy = m["tensors"][sm["outputs"][0]]
    if sy["dtype"] != "INT8" or abs(sy["quantization"]["scale"][0] - 1.0 / 256.0) > 1e-12:
        reject("SOFTMAX int8 output must be scale=1/256", m, sm["index"], field="quantization.scale")


def check_quantizable(m: dict, op, x, w, b, y) -> list:
    """Per-channel Q31 multiplier/shift + worst-case accumulator width (contract §5.5/§5.9)."""
    wzp = w["quantization"]["zero_point"]
    if len(set(wzp)) > 1:
        reject("mixed weight zero_point across channels", m, op["index"], tensor=w["index"],
               field="quantization.zero_point")
    weights = np.frombuffer(w["_constant"], dtype=np.int8).astype(np.int64).reshape(w["shape"])
    biases = np.frombuffer(b["_constant"], dtype="<i4").astype(np.int64)
    in_zp = x["quantization"]["zero_point"][0]
    out_scale = y["quantization"]["scale"][0]
    channels = weights.shape[-1] if op["op"] == "DEPTHWISE_CONV_2D" else weights.shape[0]
    vectors = weights.reshape(-1, channels).T if op["op"] == "DEPTHWISE_CONV_2D" else weights
    scales = w["quantization"]["scale"]
    if len(scales) not in (1, channels):
        reject("per-channel scale count does not match channel count", m, op["index"],
               tensor=w["index"], field="quantization.scale")
    lo_x, hi_x = -128 - in_zp, 127 - in_zp
    rows = []
    for c, values in enumerate(vectors):
        neg, pos = int(values[values < 0].sum()), int(values[values > 0].sum())
        raw_lo, raw_hi = hi_x * neg + lo_x * pos, hi_x * pos + lo_x * neg
        folded = int(biases[c]) - in_zp * (neg + pos)
        if min(folded, raw_lo) < -(1 << 31) or max(folded, raw_hi) >= (1 << 31):
            reject("int32 accumulator overflow in legal INT8 domain", m, op["index"],
                   tensor=y["index"], field="accumulator")
        bits = 1
        while min(folded, raw_lo) < -(1 << (bits - 1)) or max(folded, raw_hi) >= (1 << (bits - 1)):
            bits += 1
        wscale = scales[c if len(scales) > 1 else 0]
        real = x["quantization"]["scale"][0] * wscale / out_scale
        frac, shift = math.frexp(real)
        mult = math.floor(frac * (1 << 31) + 0.5)
        if mult == (1 << 31):
            mult //= 2
            shift += 1
        rows.append({"channel": c, "real_multiplier": real, "q31_multiplier": int(mult), "shift": int(shift),
                     "bias_hw": int(folded), "raw_mac_min": int(raw_lo), "raw_mac_max": int(raw_hi),
                     "signed_bits": bits})
    return rows


def explicit_padding(in_h, in_w, k_h, k_w, s_h, s_w, mode: str):
    """Contract §5.1: out=ceil(in/stride); total=max((out-1)*stride+k-in,0); odd extra to bottom/right."""
    out_h, out_w = math.ceil(in_h / s_h), math.ceil(in_w / s_w)
    if mode == "VALID":
        return out_h, out_w, 0, 0, 0, 0
    total_h = max((out_h - 1) * s_h + k_h - in_h, 0)
    total_w = max((out_w - 1) * s_w + k_w - in_w, 0)
    return out_h, out_w, total_h // 2, total_h - total_h // 2, total_w // 2, total_w - total_w // 2


# --------------------------------------------------------------------------- pack
def pack_params(m: dict) -> dict:
    ops = {o["op"]: o for o in m["operators"]}
    dw, fc = ops["DEPTHWISE_CONV_2D"], ops["FULLY_CONNECTED"]
    w_dw = m["tensors"][dw["inputs"][1]]
    b_dw = m["tensors"][dw["inputs"][2]]
    w_fc = m["tensors"][fc["inputs"][1]]
    b_fc = m["tensors"][fc["inputs"][2]]
    src_dw = np.frombuffer(w_dw["_constant"], dtype=np.int8).reshape(w_dw["shape"])   # [1,Kh,Kw,Cout]
    # Contract §13: [1,Kh,Kw,Cout] -> [Cout,Kh,Kw,1]  (weight_layout=1 CONV OHWI)
    conv_w = np.ascontiguousarray(src_dw.transpose(3, 1, 2, 0))                       # [Cout,Kh,Kw,Cin]
    fc_w = np.frombuffer(w_fc["_constant"], dtype=np.int8).reshape(w_fc["shape"])     # [4,4000] output-major
    q_dw = check_quantizable(m, dw, m["tensors"][dw["inputs"][0]], w_dw, b_dw, m["tensors"][dw["outputs"][0]])
    q_fc = check_quantizable(m, fc, m["tensors"][fc["inputs"][0]], w_fc, b_fc, m["tensors"][fc["outputs"][0]])
    conv_bias = np.array([r["bias_hw"] for r in q_dw], dtype="<i4")
    fc_bias = np.array([r["bias_hw"] for r in q_fc], dtype="<i4")
    quant = b"".join(struct.pack("<ii", r["q31_multiplier"], r["shift"]) for r in q_dw + q_fc)
    params = conv_w.tobytes() + conv_bias.tobytes() + fc_w.tobytes() + fc_bias.tobytes()
    if len(params) != PARAM_LAYOUT["params_bytes"]:
        reject(f"packed parameter ROM is {len(params)}B, ABI fixes {PARAM_LAYOUT['params_bytes']}B",
               m, field="param_layout")
    if len(quant) != PARAM_LAYOUT["quant_bytes"]:
        reject(f"quant ROM is {len(quant)}B, ABI fixes {PARAM_LAYOUT['quant_bytes']}B", m, field="quant_layout")
    return {"conv_w": conv_w.tobytes(), "conv_bias": conv_bias.tobytes(), "fc_w": fc_w.tobytes(),
            "fc_bias": fc_bias.tobytes(), "params": params, "quant": quant,
            "conv_w_arr": conv_w, "fc_w_arr": fc_w, "conv_bias_arr": conv_bias, "fc_bias_arr": fc_bias,
            "q_dw": q_dw, "q_fc": q_fc,
            "src": {"dw_weights_sha256": sha256_bytes(w_dw["_constant"]),
                    "dw_bias_sha256": sha256_bytes(b_dw["_constant"]),
                    "fc_weights_sha256": sha256_bytes(w_fc["_constant"]),
                    "fc_bias_sha256": sha256_bytes(b_fc["_constant"])}}


def build_descriptors(m: dict, packed: dict, model_crc: int) -> list:
    ops = {o["op"]: o for o in m["operators"]}
    dw, fc = ops["DEPTHWISE_CONV_2D"], ops["FULLY_CONNECTED"]
    specs = [
        ("DEPTHWISE_CONV_2D", dw, 1, 1, SCRATCH["input_base"], SCRATCH["act_a"],
         PARAM_LAYOUT["conv_w_base"], PARAM_LAYOUT["conv_b_base"], PARAM_LAYOUT["conv_q_base"]),
        ("FULLY_CONNECTED", fc, 2, 2, SCRATCH["act_a"], SCRATCH["act_b"],
         PARAM_LAYOUT["fc_w_base"], PARAM_LAYOUT["fc_b_base"], PARAM_LAYOUT["fc_q_base"]),
    ]
    out = []
    for name, op, hw_op, layout, in_base, out_base, w_base, b_base, q_base in specs:
        x, w, b = [m["tensors"][i] for i in op["inputs"][:3]]
        y = m["tensors"][op["outputs"][0]]
        if name == "DEPTHWISE_CONV_2D":
            o = op["options"]
            ih, iw, ic = x["shape"][1], x["shape"][2], x["shape"][3]
            kh, kw = w["shape"][1], w["shape"][2]
            oh, ow, oc = y["shape"][1], y["shape"][2], y["shape"][3]
            p = explicit_padding(ih, iw, kh, kw, o["stride_h"], o["stride_w"], o["padding"])
            if (oh, ow) != (p[0], p[1]):
                reject("derived output shape disagrees with model", m, op["index"], field="output_shape")
            pad, stride, dil = p[2:], (o["stride_h"], o["stride_w"]), (o["dilation_h"], o["dilation_w"])
        else:
            # Contract §13 fixes FC input_h/w/c = 1/1/<flattened element count>.
            ih, iw, ic = 1, 1, math.prod(x["shape"])
            kh = kw = 1
            oh, ow, oc = 1, 1, y["shape"][1]
            pad, stride, dil = (0, 0, 0, 0), (1, 1), (1, 1)
        d = bytearray(DESCRIPTOR_SIZE)
        struct.pack_into("<I", d, 0x00, DESCRIPTOR_MAGIC)
        struct.pack_into("<I", d, 0x04, DESCRIPTOR_ABI)
        struct.pack_into("<I", d, 0x08, hw_op)
        struct.pack_into("<I", d, 0x0C, 1 if name == "FULLY_CONNECTED" else 0)   # last_hardware_layer
        struct.pack_into("<II", d, 0x10, in_base, out_base)
        struct.pack_into("<III", d, 0x18, w_base, b_base, q_base)
        struct.pack_into("<III", d, 0x24, ih, iw, ic)
        struct.pack_into("<III", d, 0x30, oh, ow, oc)
        struct.pack_into("<HH", d, 0x3C, kh, kw)
        struct.pack_into("<BBBB", d, 0x40, stride[0], stride[1], dil[0], dil[1])
        struct.pack_into("<BBBB", d, 0x44, pad[0], pad[1], pad[2], pad[3])
        struct.pack_into("<ii", d, 0x48, x["quantization"]["zero_point"][0],
                         y["quantization"]["zero_point"][0])
        struct.pack_into("<ii", d, 0x50, ACT_MIN, ACT_MAX)
        struct.pack_into("<I", d, 0x58, layout)
        struct.pack_into("<I", d, 0x5C, 32)
        struct.pack_into("<III", d, 0x60, math.prod(y["shape"]), math.prod(x["shape"]), math.prod(y["shape"]))
        struct.pack_into("<I", d, 0x6C, model_crc)
        struct.pack_into("<I", d, 0x70, 0)
        struct.pack_into("<I", d, 0x70, crc32_ieee(bytes(d)))
        rec = {"name": name, "hardware_op": hw_op, "bytes": bytes(d),
               "fields": {"kernel": [kh, kw], "stride": list(stride), "dilation": list(dil), "pad": list(pad),
                          "input_shape": [ih, iw, ic], "output_shape": [oh, ow, oc],
                          "weight_layout": layout, "accumulator_bits": 32,
                          "input_zp": x["quantization"]["zero_point"][0],
                          "output_zp": y["quantization"]["zero_point"][0],
                          "output_elements": math.prod(y["shape"]), "input_bytes": math.prod(x["shape"]),
                          "output_bytes": math.prod(y["shape"])}}
        validate_descriptor(rec["bytes"], m, name)
        out.append(rec)
    return out


def validate_descriptor(d: bytes, m: dict, name: str) -> None:
    """Descriptor self-check; rejection is fail-closed (no partial start)."""
    if len(d) != DESCRIPTOR_SIZE:
        reject("descriptor size must be 128B", m, field="descriptor.size")
    if struct.unpack_from("<I", d, 0x00)[0] != DESCRIPTOR_MAGIC:
        reject("bad descriptor magic", m, field="descriptor.magic")
    if struct.unpack_from("<I", d, 0x04)[0] != DESCRIPTOR_ABI:
        reject("unsupported descriptor ABI version", m, field="descriptor.abi_version")
    if struct.unpack_from("<I", d, 0x08)[0] not in (1, 2):
        reject("illegal hardware_op", m, field="descriptor.hardware_op")
    if struct.unpack_from("<I", d, 0x0C)[0] & ~1:
        reject("reserved flags bits set", m, field="descriptor.flags")
    if struct.unpack_from("<I", d, 0x58)[0] not in (1, 2):
        reject("illegal weight_layout", m, field="descriptor.weight_layout")
    if struct.unpack_from("<I", d, 0x5C)[0] != 32:
        reject("accumulator_bits must be 32 (20-bit path forbidden for this model)", m,
               field="descriptor.accumulator_bits")
    if any(d[0x74:0x80]):
        reject("reserved tail must be zero", m, field="descriptor.reserved")
    body = bytearray(d)
    struct.pack_into("<I", body, 0x70, 0)
    if crc32_ieee(bytes(body)) != struct.unpack_from("<I", d, 0x70)[0]:
        reject("descriptor CRC mismatch", m, field="descriptor.crc32")
    in_base, out_base = struct.unpack_from("<II", d, 0x10)
    for base, size, label in ((in_base, struct.unpack_from("<I", d, 0x64)[0], "input"),
                              (out_base, struct.unpack_from("<I", d, 0x68)[0], "output")):
        if base % 4 or base + size > SCRATCH["limit"]:
            reject(f"{label} scratch range [{base:#x},{base + size:#x}) outside 0..{SCRATCH['limit']:#x}",
                   m, field=f"descriptor.{label}_base")
    if name == "DEPTHWISE_CONV_2D" and in_base + 2048 != SCRATCH["act_a"]:
        reject("input staging must end at activation A", m, field="descriptor.input_base")
    w_base, b_base, q_base = struct.unpack_from("<III", d, 0x18)
    if w_base % 4 or b_base % 4 or q_base % 4:
        reject("parameter offsets must be 4-byte aligned", m, field="descriptor.offsets")
    if max(w_base + 4, b_base + 4) > PARAM_LAYOUT["params_bytes"]:
        reject("parameter offset beyond packed ROM", m, field="descriptor.offsets")



# -------------------------------------------------------- exact integer reference
def _gemmlowp_srdhm(a, b):
    """gemmlowp SaturatingRoundingDoublingHighMul on int64 arrays (exact, no float)."""
    ab = a.astype(np.int64) * b.astype(np.int64)
    nudge = np.where(ab >= 0, 1 << 30, 1 - (1 << 30)).astype(np.int64)
    num = ab + nudge
    d = np.int64(1 << 31)
    # truncation toward zero (NOT arithmetic shift: that would floor negatives)
    q = np.where(num >= 0, num // d, -((-num) // d)).astype(np.int64)
    return np.clip(q, -(1 << 31), (1 << 31) - 1)


def _gemmlowp_rounding_divide_by_pot(x, exponent):
    """gemmlowp RoundingDivideByPOT (round half away from zero, not truncation)."""
    x = x.astype(np.int64)
    if exponent == 0:
        return x
    mask = (1 << int(exponent)) - 1
    remainder = x & mask
    threshold = (mask >> 1) + (x < 0).astype(np.int64)
    return (x >> int(exponent)) + (remainder > threshold).astype(np.int64)


def requant_srdhm(acc: np.ndarray, mult: np.ndarray, shift: np.ndarray, out_zp,
                  act_min=ACT_MIN, act_max=ACT_MAX) -> np.ndarray:
    """TFLite/gemmlowp exact sequantisation: MultiplyByQuantizedMultiplier + zp + clamp.

    TFLite's order matters and is easy to get wrong:
        left  = max(shift, 0); right = max(-shift, 0)
        x1 = acc * 2**left
        x2 = SaturatingRoundingDoublingHighMul(x1, quantized_multiplier)   # truncating /2**31
        x3 = RoundingDivideByPOT(x2, right)                                # rounding shift
    A naive `(acc*mult) >> 31` then arithmetic shift differs on negatives and on
    rounding ties — it silently mismatches ~10% of this model's DW outputs.

    ⚠️ 坑位：TFLite 量化不是"先 SRDHM 再移位"，而是"先左移再 SRDHM 再 rounding-POT 右移"，
    且 SRDHM 的 /2^31 必须**向零截断**、右移必须**四舍五入**；否则 DW 输出约 10% 字节不符
    （见 LESSON-003 / 日志 2026-10-17-03）。
    """
    acc = np.asarray(acc, dtype=np.int64)
    mult = np.asarray(mult, dtype=np.int64)
    shift = np.asarray(shift, dtype=np.int64)
    left = np.maximum(shift, 0).astype(np.int64)
    right = np.maximum(-shift, 0).astype(np.int64)
    x = acc * np.left_shift(np.int64(1), np.broadcast_to(left, acc.shape))
    a = _gemmlowp_srdhm(x, np.broadcast_to(mult, acc.shape))
    right_b = np.broadcast_to(right, acc.shape)
    out = np.empty_like(a)
    for e in np.unique(right_b):
        sel = right_b == e
        out[sel] = _gemmlowp_rounding_divide_by_pot(a[sel], int(e))
    return np.clip(out + int(out_zp), act_min, act_max).astype(np.int8)


def accumulate_conv(x_q, w_ohwi, bias_hw, in_shape, k, stride, pad, out_shape, in_zp):
    """Cin=1 CONV (DW-equivalent) int64 accumulator, folded bias, explicit 4-side padding.

    Padding taps carry the *raw* input zero point, never 0 (contract 5.9).
    """
    ih, iw = in_shape
    oh, ow = out_shape
    kh, kw = k
    sh, sw = stride
    pt, pb, pl, pr = pad
    need_h, need_w = pt + sh * (oh - 1) + kh, pl + sw * (ow - 1) + kw
    xp = np.full((max(ih + pt + pb, need_h), max(iw + pl + pr, need_w)), in_zp, dtype=np.int64)
    xp[pt:pt + ih, pl:pl + iw] = np.asarray(x_q, dtype=np.int64).reshape(ih, iw)
    acc = np.zeros((oh, ow, w_ohwi.shape[0]), dtype=np.int64)
    for c in range(w_ohwi.shape[0]):
        wc = np.asarray(w_ohwi[c, :, :, 0], dtype=np.int64)
        for dy in range(kh):
            for dx in range(kw):
                acc[:, :, c] += xp[dy:dy + sh * (oh - 1) + 1:sh, dx:dx + sw * (ow - 1) + 1:sw] * wc[dy, dx]
        acc[:, :, c] += int(bias_hw[c])
    return acc


def conv_reference(x_q, w_ohwi, bias_hw, q, in_shape, k, stride, pad, out_shape, in_zp, out_zp):
    acc = accumulate_conv(x_q, w_ohwi, bias_hw, in_shape, k, stride, pad, out_shape, in_zp)
    mult = np.array([r["q31_multiplier"] for r in q], dtype=np.int64)
    shift = np.array([r["shift"] for r in q], dtype=np.int64)
    return requant_srdhm(acc, mult[None, None, :], shift[None, None, :], out_zp)


def centered_conv_reference(x_q, w_ohwi, bias_q, q, in_shape, k, stride, pad, out_shape, in_zp, out_zp):
    """Independent formulation: centered inputs (x_q - zp) + true bias_q, no bias folding."""
    ih, iw = in_shape
    oh, ow = out_shape
    kh, kw = k
    sh, sw = stride
    pt, pb, pl, pr = pad
    xc = np.full((ih + pt + pb, iw + pl + pr), 0, dtype=np.int64)     # centered pad == 0
    xc[pt:pt + ih, pl:pl + iw] = x_q.astype(np.int64) - in_zp
    acc = np.zeros((oh, ow, w_ohwi.shape[0]), dtype=np.int64)
    for c in range(w_ohwi.shape[0]):
        wc = w_ohwi[c, :, :, 0].astype(np.int64)
        for dy in range(kh):
            for dx in range(kw):
                acc[:, :, c] += xc[dy:dy + sh * (oh - 1) + 1:sh, dx:dx + sw * (ow - 1) + 1:sw] * wc[dy, dx]
        acc[:, :, c] += int(bias_q[c])
    mult = np.array([r["q31_multiplier"] for r in q], dtype=np.int64)
    shift = np.array([r["shift"] for r in q], dtype=np.int64)
    return requant_srdhm(acc, mult[None, None, :], shift[None, None, :], out_zp)


def fc_reference(x_q: np.ndarray, w_om: np.ndarray, bias_hw: np.ndarray, q: list, out_zp) -> np.ndarray:
    acc = x_q.astype(np.int64) @ w_om.astype(np.int64).T + bias_hw.astype(np.int64)
    mult = np.array([r["q31_multiplier"] for r in q], dtype=np.int64)
    shift = np.array([r["shift"] for r in q], dtype=np.int64)
    return requant_srdhm(acc, mult, shift, out_zp)


def softmax_int8(logits_q: np.ndarray, in_scale: float, out_scale: float, out_zp: int) -> np.ndarray:
    """CPU-side exact-reference softmax on int8 logits (TFLite dequant -> float -> quant).

    Reported separately from the accelerator path; it is the K4 CPU post-processing
    reference that must be matched byte-for-byte before argmax is trusted.
    """
    z = logits_q.astype(np.float64) * in_scale
    z = z - z.max()
    e = np.exp(z)
    p = e / e.sum()
    return np.clip(np.round(p / out_scale) + out_zp, ACT_MIN, ACT_MAX).astype(np.int8)


def synthetic_input(n: int, seed: int = 20261017) -> bytes:
    """Deterministic *synthetic* feature window. NOT a K2 golden fixture (no real PCM)."""
    out = bytearray()
    s = seed
    for _ in range(n):
        s = (1103515245 * s + 12345) & 0x7FFFFFFF
        out.append((s >> 16) & 0xFF)
    return bytes(out)


# ---------------------------------------------------------------------------- main
def emit_json(path: Path, obj) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")


def build_all(source: Path, flatc: Path, build_dir: Path, model_id: str) -> dict:
    manifest = json.loads((source / "manifest.json").read_text(encoding="utf-8"))
    for e in manifest["files"]:
        f = source / e["file"]
        if not f.is_file() or sha256_file(f) != e["sha256"] or f.stat().st_size != e["size"]:
            raise ContractError(f"Pinned source mismatch: {e['file']} (run tools/kws/verify_source_lock.py)")
    ver = subprocess.run([str(flatc), "--version"], capture_output=True, text=True).stdout.strip()
    if ver != manifest["flatc"]["version"]:
        raise ContractError(f"flatc version mismatch: {ver} != {manifest['flatc']['version']}")
    schema = load_schema(flatc, source / "schema.fbs", build_dir)
    main_file = manifest.get("main_model_file", "micro_speech_quantized.tflite")
    main = parse_model(schema, source / main_file)
    front = parse_model(schema, source / "audio_preprocessor_int8.tflite")
    validate_main_graph(main)
    packed = pack_params(main)
    model_crc = crc32_ieee((source / main["file"]).read_bytes())
    descriptors = build_descriptors(main, packed, model_crc)

    ops = {o["op"]: o for o in main["operators"]}
    dw, fc, sm = ops["DEPTHWISE_CONV_2D"], ops["FULLY_CONNECTED"], ops["SOFTMAX"]
    x = main["tensors"][main["inputs"][0]]
    y_fc = main["tensors"][fc["outputs"][0]]
    y_sm = main["tensors"][sm["outputs"][0]]
    return {"manifest": manifest, "main": main, "front": front, "packed": packed,
            "descriptors": descriptors, "model_crc": model_crc, "flatc_version": ver,
            "tensor_sha": {t["index"]: t["constant_sha256"] for t in main["tensors"] if t["constant_sha256"]},
            "input_tensor": x, "fc_out": y_fc, "sm_out": y_sm}


def write_artifacts(b: dict, out_model: Path, out_gen: Path, model_id: str) -> dict:
    main, packed, descs = b["main"], b["packed"], b["descriptors"]
    out_model.mkdir(parents=True, exist_ok=True)
    out_gen.mkdir(parents=True, exist_ok=True)
    ops = {o["op"]: o for o in main["operators"]}
    dw, fc, sm = ops["DEPTHWISE_CONV_2D"], ops["FULLY_CONNECTED"], ops["SOFTMAX"]

    def tinfo(i):
        t = main["tensors"][i]
        return {"tensor_id": i, "name": t["name"], "shape": t["shape"], "dtype": t["dtype"],
                "constant_bytes": t["constant_bytes"], "constant_sha256": t["constant_sha256"],
                "scale": t["quantization"]["scale"], "zero_point": t["quantization"]["zero_point"],
                "quantized_dimension": t["quantization"]["quantized_dimension"]}

    layers = []
    for idx, (op, mapping) in enumerate([(ops["RESHAPE"], "cpu"), (dw, "openeye"),
                                         (fc, "openeye"), (sm, "cpu")]):
        entry = {"index": idx, "op": op["op"], "mapping": mapping,
                 "input_tensors": [tinfo(i) for i in op["inputs"]],
                 "output_tensor": tinfo(op["outputs"][0]),
                 "params": op["options"], "version": op["version"],
                 "weights_sha256": None, "bias_sha256": None}
        if op["op"] == "DEPTHWISE_CONV_2D":
            entry.update(weights_sha256=tinfo(op["inputs"][1])["constant_sha256"],
                         bias_sha256=tinfo(op["inputs"][2])["constant_sha256"],
                         descriptor="layers.mem[0]", packed_weights_sha256=sha256_bytes(packed["conv_w"]),
                         packed_bias_sha256=sha256_bytes(packed["conv_bias"]),
                         weight_layout="CONV OHWI ([1,Kh,Kw,Cout] -> [Cout,Kh,Kw,1])",
                         quant=packed["q_dw"])
        if op["op"] == "FULLY_CONNECTED":
            entry.update(weights_sha256=tinfo(op["inputs"][1])["constant_sha256"],
                         bias_sha256=tinfo(op["inputs"][2])["constant_sha256"],
                         descriptor="layers.mem[1]", packed_weights_sha256=sha256_bytes(packed["fc_w"]),
                         packed_bias_sha256=sha256_bytes(packed["fc_bias"]),
                         weight_layout="FC output-major (unchanged)",
                         quant=packed["q_fc"])
        layers.append(entry)

    desc_meta = []
    for i, d in enumerate(descs):
        desc_meta.append({"index": i, "layer": d["name"], "hardware_op": d["hardware_op"],
                          "bytes": len(d["bytes"]), "sha256": sha256_bytes(d["bytes"]),
                          "crc32": struct.unpack_from("<I", d["bytes"], 0x70)[0], "fields": d["fields"]})

    source_meta = b["manifest"].get("source", {})
    generated_source = {
        "repo": source_meta.get("repo"),
        "ref": source_meta.get("ref"),
        "commit": source_meta.get("commit"),
        "path": source_meta.get("path", main["file"]),
        "file": main["file"],
        "sha256": main["sha256"],
        "bytes": main["file_bytes"],
    }
    generated_source = {k: v for k, v in generated_source.items() if v is not None}
    generated = {
        "model_id": model_id,
        "source": generated_source,
        "frontend": {"file": b["front"]["file"], "sha256": b["front"]["sha256"], "bytes": b["front"]["file_bytes"]},
        "toolchain": {"flatc": b["flatc_version"], "python": sys.version.split()[0],
                      "numpy": np.__version__, "generator": "tools/kws/compile_openeye.py",
                      "generator_sha256": sha256_file(Path(__file__).resolve())},
        "rom": {
            "params_rom_bytes": len(packed["params"]), "params_rom_sha256": sha256_bytes(packed["params"]),
            "conv_weights": {"base": PARAM_LAYOUT["conv_w_base"], "bytes": len(packed["conv_w"]),
                             "sha256": sha256_bytes(packed["conv_w"])},
            "conv_bias_hw": {"base": PARAM_LAYOUT["conv_b_base"], "bytes": len(packed["conv_bias"]),
                             "sha256": sha256_bytes(packed["conv_bias"])},
            "fc_weights": {"base": PARAM_LAYOUT["fc_w_base"], "bytes": len(packed["fc_w"]),
                           "sha256": sha256_bytes(packed["fc_w"])},
            "fc_bias_hw": {"base": PARAM_LAYOUT["fc_b_base"], "bytes": len(packed["fc_bias"]),
                           "sha256": sha256_bytes(packed["fc_bias"])},
            "quant_rom_bytes": len(packed["quant"]), "quant_rom_sha256": sha256_bytes(packed["quant"]),
            "source": packed["src"],
        },
        "descriptors": desc_meta,
        "model_crc32": b["model_crc"],
        "activation_peak_bytes": main["max_nonconstant_tensor_bytes"],
        "evidence_status": {
            "parser_manifest_pack": "PASS (this run)",
            "unsupported_layer_count": 0,
            "manifest_frozen": False,
            "layer_golden_vs_tflm": "NOT_RUN (K2)",
            "rtl_layer_output": "NOT_RUN (K4, owner 林文翔)",
            "pds": "NOT_RUN", "board": "NOT_RUN",
        },
    }

    kws_manifest = {
        "source": generated["source"],
        "model": {"path": str(b["manifest"].get("model", {}).get("path", b["manifest"]["files"][0]["path"])),
                  "sha256": main["sha256"],
                  "license_evidence": b["manifest"].get("model", {}).get("license_evidence", "not separately asserted; see source archive")},
        "frontend": {"path": str(b["manifest"]["files"][1]["path"]), "sha256": b["front"]["sha256"],
                     "sample_rate_hz": 16000, "model_sha256": b["front"]["sha256"]},
        "labels": ["silence", "unknown", "yes", "no"],
        "pcm": {"source_bits": 24, "valid_bits": None, "sample_shift": None, "sample_rate_hz": 16000,
                "channels": 1, "dtype": "int16",
                "note": "TODO(K2): 24-bit I2S slot -> S16 shift/round/saturation must come from a confirmed pcm manifest"},
        "input": {"shape": main["tensors"][main["inputs"][0]]["shape"],
                  "dtype": main["tensors"][main["inputs"][0]]["dtype"], "layout": "NHWC-ish [1,1960]",
                  "scale": main["tensors"][main["inputs"][0]]["quantization"]["scale"],
                  "zero_point": main["tensors"][main["inputs"][0]]["quantization"]["zero_point"]},
        "layers": layers,
        "output": {"shape": y_sm_out_shape(b), "dtype": b["sm_out"]["dtype"],
                   "scale": b["sm_out"]["quantization"]["scale"],
                   "zero_point": b["sm_out"]["quantization"]["zero_point"]},
        "toolchain": generated["toolchain"],
        "generated": {"rom_sha256": generated["rom"]["params_rom_sha256"],
                      "activation_peak_bytes": generated["activation_peak_bytes"]},
        # Contract §5: a manifest used as a *build input* may not contain null.
        # This one is DRAFT until K2 fixes the PCM/24-bit->S16 conversion.
        "manifest_status": "DRAFT",
        "manifest_blocked_by": ["pcm_manifest (K2): 24-bit I2S slot -> S16 shift/round/saturation unconfirmed",
                                "host golden / per-layer tensors (K2): NOT_RUN"],
        "pending_fields": ["pcm.valid_bits", "pcm.sample_shift"],
        "unsupported_layer_count": 0,
    }

    emit_json(out_model / "kws_manifest.json", kws_manifest)
    emit_json(out_model / "layers.json", {"model_id": model_id, "layers": layers})
    emit_json(out_gen / "generated_manifest.json", generated)
    (out_gen / "layers.mem").write_bytes(descs[0]["bytes"] + descs[1]["bytes"])
    (out_gen / "params_rom.bin").write_bytes(packed["params"])
    (out_gen / "weights.mem").write_bytes(packed["conv_w"] + packed["fc_w"])
    (out_gen / "bias.mem").write_bytes(packed["conv_bias"] + packed["fc_bias"])
    (out_gen / "quant.mem").write_bytes(packed["quant"])
    (out_model / "LAYER_TABLE.md").write_text(layer_table_md(b, layers, generated), encoding="utf-8", newline="\n")
    return {"layers": layers, "generated": generated, "kws_manifest": kws_manifest}


def y_sm_out_shape(b):
    return b["sm_out"]["shape"]


def layer_table_md(b, layers, generated) -> str:
    lines = ["# Layer table (generated, do not hand-edit)", "",
             f"- model `{generated['source']['file']}` SHA-256 `{generated['source']['sha256']}`",
             f"- flatc `{generated['toolchain']['flatc']}`, generator `{generated['toolchain']['generator']}`",
             "", "| # | op | mapping | input | output | params | packed sha256 |", "|---|---|---|---|---|---|---|"]
    for l in layers:
        ins = "; ".join(f"t{i['tensor_id']} {i['shape']} {i['dtype']}" for i in l["input_tensors"])
        o = l["output_tensor"]
        p = ", ".join(f"{k}={v}" for k, v in l["params"].items() if k != "new_shape") or "-"
        lines.append(f"| {l['index']} | {l['op']} | {l['mapping']} | {ins} | t{o['tensor_id']} {o['shape']} "
                     f"{o['dtype']} scale={o['scale']} zp={o['zero_point']} | {p} | "
                     f"{(l.get('packed_weights_sha256') or '-')[:16]} |")
    lines += ["", "## Descriptors (contract §13)", "",
              "| # | layer | hw_op | kernel | stride | pad T/B/L/R | layout | acc bits | CRC32 |", "|---|---|---|---|---|---|---|---|---|"]
    for d in generated["descriptors"]:
        f = d["fields"]
        lines.append(f"| {d['index']} | {d['layer']} | {d['hardware_op']} | {f['kernel']} | {f['stride']} | "
                     f"{f['pad']} | {f['weight_layout']} | {f['accumulator_bits']} | {d['crc32']:#010x} |")
    lines += ["", "## Evidence status", ""] + [f"- {k}: `{v}`" for k, v in generated["evidence_status"].items()]
    return "\n".join(lines) + "\n"



# ------------------------------------------------------------------------ self-test
def _descriptor_mutations(d: bytes) -> list:
    """Each mutation must be rejected by validate_descriptor (fail-closed)."""
    cases = []
    for label, off, val, fmt in [("magic", 0x00, 0xDEADBEEF, "<I"),
                                 ("abi_version", 0x04, 2, "<I"),
                                 ("hardware_op", 0x08, 3, "<I"),
                                 ("flags reserved", 0x0C, 0x2, "<I"),
                                 ("weight_layout", 0x58, 3, "<I"),
                                 ("accumulator_bits=20", 0x5C, 20, "<I"),
                                 ("input_base misaligned", 0x10, 0x0002, "<I"),
                                 ("output_base out of scratch", 0x14, 0x2000, "<I"),
                                 ("weight_base misaligned", 0x18, 0x0002, "<I"),
                                 ("bias_base beyond ROM", 0x1C, 17000, "<I")]:
        m = bytearray(d)
        struct.pack_into(fmt, m, off, val)
        body = bytearray(m)
        struct.pack_into("<I", body, 0x70, 0)
        struct.pack_into("<I", m, 0x70, crc32_ieee(bytes(body)))     # keep CRC valid: isolate the field error
        cases.append((f"descriptor field {label}", bytes(m)))
    m = bytearray(d)
    m[0x74] = 1
    cases.append(("descriptor reserved tail nonzero", bytes(m)))
    m = bytearray(d)
    struct.pack_into("<I", m, 0x70, struct.unpack_from("<I", m, 0x70)[0] ^ 1)
    cases.append(("descriptor CRC flipped", bytes(m)))
    return cases


def self_test(b: dict) -> int:
    """Positive controls + negative controls. Every case must land on its *expected* verdict."""
    import copy
    main, packed = b["main"], b["packed"]
    ops = {o["op"]: o for o in main["operators"]}
    dw, fc = ops["DEPTHWISE_CONV_2D"], ops["FULLY_CONNECTED"]
    x_t = main["tensors"][dw["inputs"][0]]
    y_t = main["tensors"][dw["outputs"][0]]
    w_t = main["tensors"][dw["inputs"][1]]
    b_t = main["tensors"][dw["inputs"][2]]
    in_shape = (x_t["shape"][1], x_t["shape"][2])
    out_shape = (y_t["shape"][1], y_t["shape"][2])
    n = math.prod(x_t["shape"])
    x_q = np.frombuffer(synthetic_input(n), dtype=np.uint8).view(np.int8).reshape(in_shape)
    d0 = b["descriptors"][0]
    f0 = d0["fields"]
    k, stride, pad = f0["kernel"], f0["stride"], f0["pad"]
    cw, cb, q1 = packed["conv_w_arr"], packed["conv_bias_arr"], packed["q_dw"]
    base = conv_reference(x_q, cw, cb, q1, in_shape, k, stride, pad, out_shape, f0["input_zp"], f0["output_zp"])
    results = []

    def record(name, ok, detail=""):
        results.append({"case": name, "verdict": "PASS" if ok else "FAIL", "detail": detail})
        print(f"{'PASS' if ok else 'FAIL'}  {name:56} {detail}")

    def differs(name, arr):
        mism = int((np.asarray(arr) != base).sum())
        record(f"[-] {name}", mism > 0, f"mismatches={mism}/{base.size}")

    # --- positive controls -------------------------------------------------
    src = np.frombuffer(w_t["_constant"], dtype=np.int8).reshape(w_t["shape"])          # [1,Kh,Kw,Cout]
    back = np.frombuffer(packed["conv_w"], dtype=np.int8).reshape(cw.shape).transpose(3, 0, 1, 2)
    record("[+] conv weight reorder round-trip == source DW weights",
           np.array_equal(back, src.transpose(0, 3, 1, 2)), "[Cout,Kh,Kw,1] -> back to [1,Kh,Kw,Cout]")
    bias_q = np.frombuffer(b_t["_constant"], dtype="<i4")
    centered = centered_conv_reference(x_q, cw, bias_q, q1, in_shape, k, stride, pad, out_shape,
                                       f0["input_zp"], f0["output_zp"])
    record("[+] folded-bias path == centered path (bias added once, pad=zp)",
           np.array_equal(base, centered), f"mismatches={int((base != centered).sum())}/{base.size}")
    all_min = np.full(in_shape, -128, dtype=np.int8)
    all_max = np.full(in_shape, 127, dtype=np.int8)
    ext = [conv_reference(all_min, cw, cb, q1, in_shape, k, stride, pad, out_shape, f0["input_zp"], f0["output_zp"]),
           conv_reference(all_max, cw, cb, q1, in_shape, k, stride, pad, out_shape, f0["input_zp"], f0["output_zp"])]
    record("[+] extreme inputs stay in int8 domain (no wrap)",
           all(a.dtype == np.int8 for a in ext), f"min/max outputs={int(ext[0].min())}/{int(ext[1].max())}")

    # --- negative controls: value-detectable ------------------------------
    sw = explicit_padding(in_shape[0], in_shape[1], k[1], k[0], stride[0], stride[1], "SAME")
    record("[-] kernel_h/kernel_w confusion changes derived padding", tuple(sw[2:]) != tuple(pad),
           f"swapped-kernel pad={list(sw[2:])} vs real {list(pad)}")
    differs("kernel_h/kernel_w confusion (pad from swapped kernel)",
            conv_reference(x_q, cw, cb, q1, in_shape, k, stride, list(sw[2:]), out_shape,
                           f0["input_zp"], f0["output_zp"]))
    pt, pb, pl, pr = pad
    record("[-] pad left/right swap NON-discriminating here (3==3) - documented, not a pass claim",
           True, "use top/bottom swap instead (4!=5)")
    differs("pad top/bottom swapped", conv_reference(x_q, cw, cb, q1, in_shape, k, stride, [pb, pt, pl, pr],
                                                     out_shape, f0["input_zp"], f0["output_zp"]))
    differs("padding taps filled with 0 instead of input_zp",
            conv_reference(x_q, cw, cb, q1, in_shape, k, stride, pad, out_shape, 0, f0["output_zp"]))
    record("[-] multiplier off by 1 LSB is NON-discriminating for typical inputs"
           " (|acc|<2^19 => LSB invisible)", True, "use a coarse tamper instead (below)")
    swapq = [dict(r) for r in q1]
    swapq[2], swapq[5] = dict(swapq[5]), dict(swapq[2])
    differs("two channels' q31 multiplier/shift swapped",
            conv_reference(x_q, cw, cb, swapq, in_shape, k, stride, pad, out_shape, f0["input_zp"], f0["output_zp"]))
    shiftq = [dict(r) for r in q1]
    shiftq[1]["shift"] += 1
    differs("one channel requant shift off by +1",
            conv_reference(x_q, cw, cb, shiftq, in_shape, k, stride, pad, out_shape, f0["input_zp"], f0["output_zp"]))
    twice = cb.astype(np.int64) + (cb.astype(np.int64) - bias_q.astype(np.int64))
    differs("bias applied twice", conv_reference(x_q, cw, twice, q1, in_shape, k, stride, pad, out_shape,
                                                 f0["input_zp"], f0["output_zp"]))
    differs("bias dropped entirely", conv_reference(x_q, cw, np.zeros_like(cb), q1, in_shape, k, stride, pad,
                                                    out_shape, f0["input_zp"], f0["output_zp"]))
    differs("kernel rows reversed (weight-order error)",
            conv_reference(x_q, np.ascontiguousarray(cw[:, ::-1, :, :]), cb, q1, in_shape, k, stride, pad,
                           out_shape, f0["input_zp"], f0["output_zp"]))
    # 20-bit PSUM: only a worst-case-aligned input exposes it (that is the point of the range proof).
    mult = np.array([r["q31_multiplier"] for r in q1], dtype=np.int64)
    shift = np.array([r["shift"] for r in q1], dtype=np.int64)
    worst, worst_c, worst_val = None, None, 0
    for c in range(cw.shape[0]):
        wc = cw[c, :, :, 0].astype(np.int64)
        for polarity in (1, -1):
            xa = np.full(in_shape, 0, dtype=np.int8)
            oy, ox = 12, 10
            for dy in range(k[0]):
                for dx in range(k[1]):
                    iy, ix = stride[0] * oy - pt + dy, stride[1] * ox - pl + dx
                    if 0 <= iy < in_shape[0] and 0 <= ix < in_shape[1]:
                        positive_extreme = wc[dy, dx] * polarity > 0
                        xa[iy, ix] = 127 if positive_extreme else -128
            a = accumulate_conv(xa, cw, cb, in_shape, k, stride, pad, out_shape, f0["input_zp"])
            v = int(np.abs(a).max())
            if v > worst_val:
                worst, worst_c, worst_val = xa, c, v
    a = accumulate_conv(worst, cw, cb, in_shape, k, stride, pad, out_shape, f0["input_zp"])
    a20 = ((a + (1 << 19)) % (1 << 20)) - (1 << 19)
    o20 = requant_srdhm(a20, mult[None, None, :], shift[None, None, :], f0["output_zp"])
    o32 = requant_srdhm(a, mult[None, None, :], shift[None, None, :], f0["output_zp"])
    record("[-] 20-bit accumulator wrap changes the output (worst-case-aligned input)",
           not np.array_equal(o20, o32),
           f"mismatches={int((o20 != o32).sum())}/{o32.size}, |acc|max={worst_val} (ch{worst_c}), "
           f"needs {max(r['signed_bits'] for r in q1)} bits")
    a_typ = accumulate_conv(x_q, cw, cb, in_shape, k, stride, pad, out_shape, f0["input_zp"])
    o20_typ = requant_srdhm(((a_typ + (1 << 19)) % (1 << 20)) - (1 << 19), mult[None, None, :],
                            shift[None, None, :], f0["output_zp"])
    record("[-] typical synthetic input MISSES the 20-bit bug (range proof is mandatory)",
           np.array_equal(o20_typ, base), "typical-input compare cannot see the 20-bit error")
    trunc = np.clip(((a * mult[None, None, :]) >> shift[None, None, :]) + f0["output_zp"],
                    ACT_MIN, ACT_MAX).astype(np.int8)
    record("[-] truncating shift instead of SRDHM rounds differently",
           not np.array_equal(trunc, o32), f"mismatches={int((trunc != o32).sum())}/{o32.size}")

    # --- negative controls: structural rejections -------------------------
    for label, mut in _descriptor_mutations(d0["bytes"]):
        try:
            validate_descriptor(mut, main, "DEPTHWISE_CONV_2D")
            record(f"[-] {label}", False, "NOT rejected")
        except ContractError as exc:
            record(f"[-] {label}", True, str(exc)[:72])

    def expect_reject(name, model_mut):
        try:
            validate_main_graph(model_mut)
            record(f"[-] {name}", False, "NOT rejected")
        except ContractError as exc:
            record(f"[-] {name}", True, str(exc)[:72])

    m2 = copy.deepcopy(main); m2["operators"][1]["op"] = "CONV_2D"
    expect_reject("unsupported op CONV_2D replacing DEPTHWISE_CONV_2D", m2)
    m2 = copy.deepcopy(main); m2["tensors"][main["inputs"][0]]["shape"] = [-1, 1960]
    expect_reject("dynamic shape dim -1", m2)
    m2 = copy.deepcopy(main); m2["tensors"][main["inputs"][0]]["dtype"] = "FLOAT32"
    expect_reject("unexpected dtype FLOAT32 on model input", m2)
    m2 = copy.deepcopy(main); m2["tensors"][dw["inputs"][1]]["quantization"]["scale"] = [0.5, 0.5, 0.5]
    expect_reject("weight scale count neither per-tensor nor per-channel", m2)
    m2 = copy.deepcopy(main); m2["tensors"][dw["inputs"][1]]["quantization"]["quantized_dimension"] = 0
    expect_reject("per-channel DW weights with wrong quantized_dimension", m2)
    m2 = copy.deepcopy(main)
    m2["tensors"][dw["inputs"][2]]["constant_bytes"] = m2["tensors"][dw["inputs"][2]]["bytes"] + 4
    expect_reject("constant buffer size vs shape mismatch", m2)
    m2 = copy.deepcopy(main); m2["operators"][1]["options"]["padding"] = "SAME_LOWER"
    expect_reject("unknown padding mode SAME_LOWER", m2)
    m2 = copy.deepcopy(main); m2["operators"][1]["options"]["activation"] = "TANH"
    expect_reject("unsupported fused activation TANH", m2)

    # FC + softmax reference sanity (4 outputs; NOT a golden)
    fc_out = fc_reference(base.reshape(-1), packed["fc_w_arr"], packed["fc_bias_arr"], packed["q_fc"],
                          b["fc_out"]["quantization"]["zero_point"][0])
    sm = softmax_int8(fc_out, b["fc_out"]["quantization"]["scale"][0], 1.0 / 256.0, -128)
    record("[+] FC reference gives 4 int8 outputs and softmax int8 output well-formed",
           fc_out.shape == (4,) and sm.shape == (4,) and sm.dtype == np.int8,
           f"logits_q={fc_out.tolist()} softmax_q={sm.tolist()}")

    failed = [r for r in results if r["verdict"] != "PASS"]
    print(f"\n{'PASS' if not failed else 'FAIL'}: {len(results)} control cases, {len(failed)} unexpected")
    return 0 if not failed else 1


# ---------------------------------------------------------------------------- CLI
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source-dir", type=Path, required=True, help="pinned dir with the 2 .tflite + manifest.json + schema.fbs")
    ap.add_argument("--flatc", type=Path, required=True, help="flatc v24.3.25 (see sources/upstream/kws-tflm-230c9/manifest.json)")
    ap.add_argument("--build-dir", type=Path, default=Path("build/kws-flatc"), help="scratch dir for generated schema bindings")
    ap.add_argument("--model-id", default="micro_speech-230c9")
    ap.add_argument("--out-model", type=Path, default=Path("verification/kws/model/micro_speech-230c9"))
    ap.add_argument("--out-generated", type=Path, default=Path("fpga/kws/generated/micro_speech-230c9"))
    ap.add_argument("--self-test", action="store_true", help="run host-reference + descriptor negative controls")
    ap.add_argument("--json-out", type=Path, help="write this run's machine-readable record here")
    args = ap.parse_args()
    try:
        b = build_all(args.source_dir.resolve(), args.flatc.resolve(), args.build_dir.resolve(), args.model_id)
        arts = write_artifacts(b, args.out_model.resolve(), args.out_generated.resolve(), args.model_id)
        print(f"PASS: parsed {b['main']['file']} ({b['main']['sha256'][:16]}): "
              f"{len(b['main']['tensors'])} tensors, {len(b['main']['operators'])} ops")
        print(f"PASS: params ROM {len(b['packed']['params'])}B sha256={sha256_bytes(b['packed']['params'])[:16]} "
              f"quant ROM {len(b['packed']['quant'])}B")
        for d in b["descriptors"]:
            print(f"PASS: descriptor {d['name']:20} crc32={struct.unpack_from('<I', d['bytes'], 0x70)[0]:#010x} "
                  f"kernel={d['fields']['kernel']} pad={d['fields']['pad']}")
        rc = self_test(b) if args.self_test else 0
        if args.json_out:
            emit_json(args.json_out.resolve(), {
                "model": b["main"]["file"], "model_sha256": b["main"]["sha256"],
                "flatc": b["flatc_version"], "python": sys.version.split()[0], "numpy": np.__version__,
                "params_rom_sha256": sha256_bytes(b["packed"]["params"]),
                "quant_rom_sha256": sha256_bytes(b["packed"]["quant"]),
                "descriptors": [{"name": d["name"], "sha256": sha256_bytes(d["bytes"]),
                                 "crc32": struct.unpack_from("<I", d["bytes"], 0x70)[0]} for d in b["descriptors"]],
                "artifacts": {"kws_manifest.json": sha256_file(args.out_model.resolve() / "kws_manifest.json"),
                              "layers.json": sha256_file(args.out_model.resolve() / "layers.json"),
                              "layers.mem": sha256_file(args.out_generated.resolve() / "layers.mem"),
                              "params_rom.bin": sha256_file(args.out_generated.resolve() / "params_rom.bin")},
                "self_test_exit": rc,
                "evidence_status": {"parser_manifest_pack": "PASS", "layer_golden_vs_tflm": "NOT_RUN",
                                    "rtl": "NOT_RUN", "pds": "NOT_RUN", "board": "NOT_RUN"}})
        return rc
    except (ContractError, ValueError, OSError, subprocess.CalledProcessError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
