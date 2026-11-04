#!/usr/bin/env python3
"""Prepare the single Verilog design source consumed by the W3 KWS board PDS project.

This is the RTL normalization/input-generation stage only. It deliberately does
not invoke PDS, synthesis, device mapping, place-and-route, STA, or bitstream tools.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
INTEGRATED_REF = "1944dd5c"
PDS_CANDIDATE_INPUT_CHANGES = {
    "rtl/periph/sen0327_i2s_rx.sv": "separate the synchronous FIFO RAM write port from reset/control logic",
}
TOP = "pangu100proplus_w3_kws_board_top"
PDS_REL = Path("fpga/kws_soc_board/kws_soc_board.pds")
FDC_REL = Path("fpga/constraints/pangu100proplus_w3_kws.fdc")
ROM_REL = Path("build/w3-kws-live/kws_live.hex")
ROM_MANIFEST_REL = Path("build/w3-kws-live/w3_kws_live_manifest.json")
ROM_SHA256_LOCK_PREVIOUS = "2f20d708efdca61eef6afbf6b548f7ff69871c4553665832c3a6ac3930a530fe"
# Feature-gated firmware lock (Lead, 2026-11-03): the byte-identical integrated
# ROM is still the default; an explicitly pinned banner build may be allowed by
# setting KWS_ROM_SHA256_LOCK=<sha256> for a single documented run.
ROM_SHA256_LOCK = os.environ.get(
    "KWS_ROM_SHA256_LOCK",
    "56996e88634f443d5f5b36339ae3fbc8baeea93fd643bd13f642e4fc33eafeb1",
)
MODEL_ID = "zh_neg_ab_20261101"
MODEL_DIR = Path("fpga/kws/generated") / MODEL_ID
MODEL_READMEMH = MODEL_DIR / "readmemh"
MODEL_MANIFEST_REL = MODEL_DIR / "generated_manifest.json"
RTL_LIST_REL = Path(
    "evidence/system-final-wc-20261102/w3-kws-live-board-wrapper/verilator-soc-sources.txt"
)
RTL_INCLUDE_FILES = ("rtl/core/riscv_defs.svh",)
OUT_DIR = Path("build/pds/kws_soc_board")
OUT_REL = OUT_DIR / f"{TOP}_syn.v"
YOSYS_SCRIPT_REL = OUT_DIR / "prepare_kws_soc_board.ys"
RESULT_REL = OUT_DIR / "pds_input_manifest.json"
# Keep generated copies in the build tree. Historical tracked evidence must not
# be overwritten by a later candidate's input generation.
EVIDENCE_DIR_REL = OUT_DIR / "input-evidence"
EXPECTED_MODEL_FILES = (
    "dw_weights.hex", "fc_weights.hex", "bias.hex", "quant.hex", "descriptor.hex",
)
FIRMWARE_SOURCE_PREFIXES = (
    "firmware/kws/", "firmware/coremark/port/", "references/kws-signal-port-230c9/",
    "tools/kws/frontend_ref/rv32/",
)


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def git(*args: str, check: bool = True) -> str:
    result = subprocess.run(["git", *args], cwd=ROOT, text=True, capture_output=True)
    if check and result.returncode:
        raise RuntimeError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def tracked_paths(prefixes: tuple[str, ...]) -> list[str]:
    paths = git("ls-files").splitlines()
    return sorted(p for p in paths if p and any(p.startswith(prefix) for prefix in prefixes))


def verify_integrated_inputs(ref: str, paths: list[str]) -> list[str]:
    commit_check = subprocess.run(
        ["git", "cat-file", "-e", f"{ref}^{{commit}}"],
        cwd=ROOT, text=True, capture_output=True,
    )
    if commit_check.returncode:
        raise RuntimeError(f"integrated source revision is unavailable: {ref}")
    missing = [p for p in paths if not (ROOT / p).is_file()]
    if missing:
        raise RuntimeError(f"missing tracked input(s): {', '.join(missing)}")
    changed = git("diff", "--name-only", ref, "--", *paths).splitlines()
    unexpected = [p for p in changed if p not in PDS_CANDIDATE_INPUT_CHANGES]
    if unexpected:
        raise RuntimeError(
            f"design inputs differ from integrated revision {ref} outside the candidate allowlist: "
            f"{', '.join(unexpected)}"
        )
    return changed


def hash_paths(paths: list[str]) -> dict[str, str]:
    return {p.replace("\\", "/"): sha256(ROOT / p) for p in paths}


def assert_netlist_init(netlist: str, array: str, index: int, width: int, value: int) -> None:
    pattern = re.compile(
        rf"^\s*{re.escape(array)}\[{index}\]\s*=\s*{width}'([hd])([0-9a-fA-F_]+);",
        flags=re.MULTILINE,
    )
    matches = pattern.findall(netlist)
    if not matches:
        raise RuntimeError(f"generated design source lacks initialized {array}[{index}]")
    expected = value
    for base, digits in matches:
        actual = int(digits.replace("_", ""), 16 if base == "h" else 10)
        if actual != expected:
            raise RuntimeError(
                f"generated design source init mismatch at {array}[{index}]: "
                f"expected 0x{expected:x}, found 0x{actual:x}"
            )


def yosys_compatible_model_source(source: str) -> tuple[str, int]:
    """Lower constant descriptor helper calls for Yosys 0.66, preserving bits."""
    function_block = re.compile(
        r"\s*function \[31:0\] desc_u32\(input integer a\);.*?endfunction\s*"
        r"function \[31:0\] desc_s32\(input integer a\);.*?endfunction\s*",
        flags=re.DOTALL,
    )
    source, block_count = function_block.subn("\n", source)
    if block_count != 1:
        raise RuntimeError("unexpected kws_model_rom descriptor helper definitions")

    call = re.compile(r"desc_(?:u32|s32)\((16'h([0-9a-fA-F]+))(?:\s*\+\s*128)?\)")

    def expand(match: re.Match[str]) -> str:
        address = int(match.group(2), 16)
        if "+ 128" in match.group(0):
            address += 128
        return "{" + ", ".join(
            f"descriptors[16'h{address + offset:03x}]" for offset in (3, 2, 1, 0)
        ) + "}"

    lowered, count = call.subn(expand, source)
    if count != 12 or re.search(r"desc_(?:u32|s32)\(", lowered):
        raise RuntimeError(f"unexpected descriptor accessor call count: {count}")
    return lowered, count


def normalize_i2s_fifo_write_port(netlist: str) -> tuple[str, dict[str, object]]:
    """Collapse Yosys' common 16 bit-slice FIFO writes into one word write.

    This is deliberately strict: it only accepts a complete 0..15 write mask
    whose address, data, and full-word enable share the same condition and have
    no reset dependency. Any structural drift fails input generation.
    """
    modules = list(re.finditer(r"(?m)^module [^\n]*sen0327_i2s_rx \([^\n]*\);", netlist))
    if len(modules) != 1:
        raise RuntimeError(f"expected one generated I2S receiver module, found {len(modules)}")
    start = modules[0].start()
    end_match = re.search(r"(?m)^endmodule\s*$", netlist[modules[0].end():])
    if not end_match:
        raise RuntimeError("generated I2S receiver module has no endmodule")
    end = modules[0].end() + end_match.end()
    module_text = netlist[start:end]

    statement_re = re.compile(
        r"(?m)^\s*if\s*\((?P<enable>\w+)\[(?P<enable_bit>\d+)\]\)\s*\n"
        r"\s*fifo_mem\[(?P<address>\w+)\]\[(?P<lo>\d+):(?P<hi>\d+)\]\s*<=\s*"
        r"(?P<data>\w+)\[(?P<data_bit>\d+)\];\s*$"
    )
    writes = list(statement_re.finditer(module_text))
    if len(writes) != 16:
        raise RuntimeError(f"expected 16 generated fifo_mem bit writes, found {len(writes)}")
    bits = sorted(int(m.group("lo")) for m in writes)
    if bits != list(range(16)):
        raise RuntimeError(f"fifo_mem write bits are not a complete 0..15 word: {bits}")
    first = writes[0]
    enable, address, data = first.group("enable", "address", "data")
    for m in writes:
        bit = int(m.group("lo"))
        if (m.group("enable") != enable or int(m.group("enable_bit")) != bit
                or m.group("address") != address or int(m.group("hi")) != bit
                or m.group("data") != data or int(m.group("data_bit")) != bit):
            raise RuntimeError("fifo_mem bit writes do not share one enable/address/data word")

    def assignment(signal: str) -> str:
        found = re.findall(
            rf"(?m)^\s*assign\s+{re.escape(signal)}\s*=\s*([^;]+);\s*$",
            module_text,
        )
        if len(found) != 1:
            raise RuntimeError(f"expected one assignment for FIFO write signal {signal}, found {len(found)}")
        return found[0].strip()

    enable_match = re.fullmatch(
        r"(?P<condition>\w+)\s*\?\s*16'hffff\s*:\s*16'h0000", assignment(enable)
    )
    if not enable_match:
        raise RuntimeError("fifo_mem write enable is not a full-word 0xffff/0 mask")
    condition = enable_match.group("condition")
    data_match = re.fullmatch(
        r"(?P<condition>\w+)\s*\?\s*(?P<value>\w+\[\d+:\d+\])\s*:\s*16'hxxxx",
        assignment(data),
    )
    address_match = re.fullmatch(
        r"(?P<condition>\w+)\s*\?\s*(?P<value>\w+)\s*:\s*9'hxxx",
        assignment(address),
    )
    if (not data_match or not address_match
            or data_match.group("condition") != condition
            or address_match.group("condition") != condition
            or condition == "rst"):
        raise RuntimeError("fifo_mem address/data are not selected by the reset-independent full-word enable")

    blocks = [m for m in re.finditer(
        r"(?ms)^\s*always\s*@\(posedge clk\)\s*begin\n.*?^\s*end\s*$", module_text
    ) if "fifo_mem[" in m.group(0)]
    if len(blocks) != 1:
        raise RuntimeError(f"expected one fifo_mem write process, found {len(blocks)}")
    block = blocks[0]
    remaining = statement_re.sub("", block.group(0))
    remaining = re.sub(r"(?m)^\s*always\s*@\(posedge clk\)\s*begin\s*$", "", remaining)
    remaining = re.sub(r"(?m)^\s*end\s*$", "", remaining)
    if remaining.strip():
        raise RuntimeError("fifo_mem write process contains unexpected statements")

    replacement = (
        "  always @(posedge clk) begin\n"
        f"    if ({condition})\n"
        f"      fifo_mem[{address_match.group('value')}] <= {data_match.group('value')};\n"
        "  end"
    )
    normalized = netlist[:start] + module_text[:block.start()] + replacement + \
        module_text[block.end():] + netlist[end:]
    return normalized, {
        "module": modules[0].group(0).split()[1],
        "source_bit_writes": 16,
        "output_word_writes": 1,
        "condition": condition,
        "address": address_match.group("value"),
        "data": data_match.group("value"),
        "reset_independent": True,
        "architecture_change": False,
    }


def find_yosys(explicit: str | None) -> Path:
    configured = explicit or os.environ.get("YOSYS")
    if configured:
        candidate = Path(configured)
        if candidate.is_file():
            return candidate.resolve()
        located = shutil.which(configured)
        if located:
            return Path(located).resolve()
        raise RuntimeError(f"Yosys executable not found: {configured}")
    located = shutil.which("yosys")
    if located:
        return Path(located).resolve()
    raise RuntimeError("Yosys not found; pass --yosys or set YOSYS")


def verify_pds_wiring() -> str:
    text = (ROOT / PDS_REL).read_text(encoding="utf-8")
    expected_source = "../../build/pds/kws_soc_board/" + f"{TOP}_syn.v"
    if text.count(expected_source) != 1 or text.count(f'"{TOP}"') < 2:
        raise RuntimeError("PDS project does not uniquely select the expected board netlist/top")
    if text.count("../constraints/pangu100proplus_w3_kws.fdc") != 1:
        raise RuntimeError("PDS project does not uniquely select the W3 KWS board FDC")
    return expected_source


def verify_model() -> tuple[dict[str, str], dict[str, object]]:
    manifest_path = ROOT / MODEL_MANIFEST_REL
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("model_id") != MODEL_ID:
        raise RuntimeError("unexpected generated KWS model id")
    packed = ROOT / MODEL_DIR / "params_rom.bin"
    quant = ROOT / MODEL_DIR / "quant.mem"
    layers = ROOT / MODEL_DIR / "layers.mem"
    rom = manifest["rom"]
    if sha256(packed) != rom["params_rom_sha256"]:
        raise RuntimeError("params_rom.bin does not match the generated model manifest")
    if sha256(quant) != rom["quant_rom_sha256"]:
        raise RuntimeError("quant.mem does not match the generated model manifest")
    if len(layers.read_bytes()) != 256:
        raise RuntimeError("layers.mem size is not the expected two-descriptor image")
    readmemh = {name: sha256(ROOT / MODEL_READMEMH / name) for name in EXPECTED_MODEL_FILES}
    check = subprocess.run(
        [sys.executable, "tools/kws/export_model_rom_hex.py", "--check", "--model", MODEL_ID],
        cwd=ROOT, text=True, capture_output=True,
    )
    (ROOT / OUT_DIR).mkdir(parents=True, exist_ok=True)
    (ROOT / OUT_DIR / "model_rom_check.log").write_text(
        check.stdout + check.stderr, encoding="utf-8"
    )
    if check.returncode:
        raise RuntimeError("generated model $readmemh files failed exporter --check")
    return readmemh, {
        "model_id": manifest["model_id"],
        "generated_manifest_sha256": sha256(manifest_path),
        "params_rom_sha256": sha256(packed),
        "quant_rom_sha256": sha256(quant),
        "layers_mem_sha256": sha256(layers),
        "readmemh_sha256": readmemh,
        "exporter_check": "PASS",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-revision", default=INTEGRATED_REF)
    parser.add_argument("--yosys", help="Yosys executable or set YOSYS")
    parser.add_argument("--rebuild-firmware", action="store_true",
                        help="rebuild the frozen W3 live firmware ROM before binding it")
    args = parser.parse_args()

    try:
        out_dir = ROOT / OUT_DIR
        out_dir.mkdir(parents=True, exist_ok=True)

        if args.rebuild_firmware or not (ROOT / ROM_REL).is_file():
            build = subprocess.run(
                [sys.executable, "verification/kws/audio/build_live_app_rv32.py",
                 "--out-dir", ROM_REL.parent.as_posix()],
                cwd=ROOT, text=True, capture_output=True,
            )
            (out_dir / "firmware_build.log").write_text(
                build.stdout + build.stderr, encoding="utf-8"
            )
            if build.returncode:
                raise RuntimeError(f"firmware ROM build failed (exit {build.returncode})")

        rom = ROOT / ROM_REL
        rom_manifest = ROOT / ROM_MANIFEST_REL
        if not rom.is_file() or not rom_manifest.is_file():
            raise RuntimeError("firmware ROM or its build manifest is missing")
        rom_manifest_data = json.loads(rom_manifest.read_text(encoding="utf-8"))
        rom_hash = sha256(rom)
        recorded_rom_hash = rom_manifest_data["artifacts"]["kws_live.hex"]["sha256"]
        if rom_hash != recorded_rom_hash or rom_hash != ROM_SHA256_LOCK:
            raise RuntimeError(
                f"firmware ROM hash mismatch: actual={rom_hash}; "
                f"build_manifest={recorded_rom_hash}; locked={ROM_SHA256_LOCK}"
            )

        rtl_paths = [p.strip().replace("\\", "/") for p in
                     (ROOT / RTL_LIST_REL).read_text(encoding="utf-8").splitlines() if p.strip()]
        if not rtl_paths or any(not p.startswith("rtl/") for p in rtl_paths):
            raise RuntimeError("Verilator source list is empty or contains a non-RTL path")
        firmware_paths = tracked_paths(FIRMWARE_SOURCE_PREFIXES)
        fixed_paths = [
            *rtl_paths, *RTL_INCLUDE_FILES, PDS_REL.as_posix(), FDC_REL.as_posix(),
            MODEL_MANIFEST_REL.as_posix(),
            (MODEL_DIR / "params_rom.bin").as_posix(),
            (MODEL_DIR / "quant.mem").as_posix(),
            (MODEL_DIR / "layers.mem").as_posix(),
            *[(MODEL_READMEMH / name).as_posix() for name in EXPECTED_MODEL_FILES],
            "verification/kws/audio/build_live_app_rv32.py",
            "tools/kws/export_model_rom_hex.py",
        ]
        design_paths = sorted(set(fixed_paths + firmware_paths))
        candidate_input_changes = verify_integrated_inputs(args.source_revision, design_paths)
        selected_source = verify_pds_wiring()
        model_readmemh_hashes, model = verify_model()
        # `verify_model` hashes the actual $readmemh files; ensure the captured
        # values are exactly the same values that will be loaded by Yosys.
        if model_readmemh_hashes != model["readmemh_sha256"]:
            raise RuntimeError("model $readmemh hashes changed during preflight")

        yosys = find_yosys(args.yosys)
        version = subprocess.run([str(yosys), "-V"], cwd=ROOT,
                                 text=True, capture_output=True)
        if version.returncode:
            raise RuntimeError(f"cannot query Yosys version: {version.stderr.strip()}")
        frozen_sources: dict[str, str] = {}
        model_transform: dict[str, object] | None = None
        for rel in [*rtl_paths, *RTL_INCLUDE_FILES]:
            target_rel = f"src/{rel}"
            target = out_dir / target_rel
            target.parent.mkdir(parents=True, exist_ok=True)
            if rel == "rtl/soc/kws_model_rom.sv":
                original = (ROOT / rel).read_text(encoding="utf-8")
                lowered, call_count = yosys_compatible_model_source(original)
                target.write_text(lowered, encoding="utf-8", newline="")
                model_transform = {
                    "rule": "Yosys 0.66 constant descriptor accessor lowering",
                    "semantic_operation": "Replace each constant desc_u32/desc_s32(a) with {descriptors[a+3], descriptors[a+2], descriptors[a+1], descriptors[a]}; remove now-unused helper functions.",
                    "expanded_calls": call_count,
                    "original_sha256": sha256(ROOT / rel),
                    "frozen_copy_sha256": sha256(target),
                }
            else:
                shutil.copy2(ROOT / rel, target)
            frozen_sources[target_rel] = sha256(target)

        # Reuse the established PDS candidate preprocessing inputs: the macro
        # keeps the functional all-zero SRAM initialization without frontend
        # loop expansion, and the ROM macro reads the exact frozen firmware HEX.
        zero_rel = "src/memory/sram_zero_16384.mem"
        zero_path = out_dir / zero_rel
        zero_path.parent.mkdir(parents=True, exist_ok=True)
        zero_path.write_bytes(b"00\n" * 16384)
        (out_dir / "coremark.hex").parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(rom, out_dir / "coremark.hex")

        frozen_model_files: dict[str, str] = {}
        for rel in [MODEL_MANIFEST_REL.as_posix(),
                    (MODEL_DIR / "params_rom.bin").as_posix(),
                    (MODEL_DIR / "quant.mem").as_posix(),
                    (MODEL_DIR / "layers.mem").as_posix(),
                    *[(MODEL_READMEMH / name).as_posix() for name in EXPECTED_MODEL_FILES]]:
            target = out_dir / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / rel, target)
            frozen_model_files[rel] = sha256(target)

        source_args = " ".join(f'"src/{p}"' for p in rtl_paths)
        script_lines = [
            'read_verilog -sv -DKWS_MODEL_ZH_NEG -DCACHE_PATH_NO_ASSERT -DCOREMARK_PDS_INIT '
            f'-DCOREMARK_YOSYS_PREP -DDUAL_FIVE_STAGE -Isrc/rtl/core {source_args}',
            f'chparam -set ROM_INIT_FILE "coremark.hex" {TOP}',
            f'hierarchy -check -top {TOP}',
            "proc",
            "memory -nomap",
            # PDS 2022.2-SP6.4 aliases the behavioural 4R2W register-file
            # outputs onto one GND net during Compile if it remains unmapped.
            # Map only this FF-based register file; preserve RAM inference for
            # Cache, SRAM, firmware ROM, and model ROM memories.
            "select -module regfile_4r2w",
            "memory_map",
            "select *",
            "opt",
            "check",
            f'write_verilog -noattr "{OUT_REL.name}"',
        ]
        script = out_dir / YOSYS_SCRIPT_REL.name
        script.write_text("\n".join(script_lines) + "\n", encoding="ascii")
        yosys_run = subprocess.run(
            [str(yosys), "-s", YOSYS_SCRIPT_REL.name],
            cwd=out_dir, text=True, capture_output=True,
        )
        yosys_log_path = out_dir / "yosys_prepare.log"
        yosys_log_path.write_text(yosys_run.stdout + yosys_run.stderr, encoding="utf-8")
        if yosys_run.returncode:
            raise RuntimeError(f"Yosys input generation failed (exit {yosys_run.returncode})")
        log_text = yosys_run.stdout + yosys_run.stderr
        check_match = re.search(r"Found and reported (\d+) problems\.", log_text)
        if not check_match:
            raise RuntimeError("Yosys did not complete its hierarchy/check pass")
        check_problems = int(check_match.group(1))
        no_driver = re.findall(
            r"^Warning: Wire .* has no driver\.$", log_text, flags=re.MULTILINE
        )
        expected_no_driver = 36
        allowed_no_driver_fragments = (
            "d_byp_rsp_valid", "d_byp_rsp_data", "d_byp_rsp_error",
            "cache_mem_read", "cache_mem_write",
        )
        unexpected_no_driver = [
            line for line in no_driver
            if not any(fragment in line for fragment in allowed_no_driver_fragments)
        ]
        findings_match = (
            (check_problems == 0 and len(no_driver) == 0)
            or (check_problems == expected_no_driver and len(no_driver) == expected_no_driver)
        )
        if not findings_match or unexpected_no_driver:
            raise RuntimeError(
                f"unexpected Yosys check findings: problems={check_problems}, "
                f"no_driver={len(no_driver)}, unexpected={unexpected_no_driver[:3]}"
            )
        if not (out_dir / OUT_REL.name).is_file() or (out_dir / OUT_REL.name).stat().st_size == 0:
            raise RuntimeError("Yosys did not produce the non-empty PDS design source")
        netlist_text = (out_dir / OUT_REL.name).read_text(encoding="utf-8", errors="replace")
        netlist_text, fifo_write_transform = normalize_i2s_fifo_write_port(netlist_text)
        (out_dir / OUT_REL.name).write_text(netlist_text, encoding="utf-8")
        rom_words = [int(line, 16) for line in rom.read_text(encoding="ascii").splitlines() if line]
        init_checks: list[str] = []
        for index in sorted({0, len(rom_words) - 1}):
            assert_netlist_init(netlist_text, "mem", index, 32, rom_words[index])
            init_checks.append(f"firmware mem[{index}]")

        model_tables = {
            "dw_weights.hex": ("dw_weights", 8),
            "fc_weights.hex": ("fc_weights", 8),
            "bias.hex": ("biases", 8),
            "quant.hex": ("quant", 8),
        }
        for filename, (array, width) in model_tables.items():
            values = [int(line, 16) for line in
                      (ROOT / MODEL_READMEMH / filename).read_text(encoding="ascii").splitlines() if line]
            for index in sorted({0, len(values) - 1}):
                assert_netlist_init(netlist_text, array, index, width, values[index])
                init_checks.append(f"{filename} {array}[{index}]")
        descriptor = [int(line, 16) for line in
                      (ROOT / MODEL_READMEMH / "descriptor.hex").read_text(encoding="ascii").splitlines() if line]
        packed_descriptor = [descriptor[i] | (descriptor[i + 1] << 8)
                             for i in range(0, len(descriptor), 2)]
        for index in sorted({0, len(packed_descriptor) - 1}):
            assert_netlist_init(netlist_text, "descriptors", index, 16, packed_descriptor[index])
            init_checks.append(f"descriptor.hex descriptors[{index}]")

        input_hashes = hash_paths(design_paths)
        manifest = {
            "schema": "kws-soc-board-pds-input-v1",
            "status": "INPUT_GENERATION_PASS_PDS_NOT_RUN",
            "generated_at_utc": datetime.now(timezone.utc).isoformat(),
            "git": {
                "integrated_source_revision": args.source_revision,
                "working_head": git("rev-parse", "HEAD"),
                "input_paths_match_integrated_revision": not candidate_input_changes,
                "candidate_input_changes": {
                    path: PDS_CANDIDATE_INPUT_CHANGES[path]
                    for path in candidate_input_changes
                },
            },
            "top": TOP,
            "pds_project": {
                "path": PDS_REL.as_posix(),
                "sha256": sha256(ROOT / PDS_REL),
                "unique_design_source": selected_source,
                "design_source_count": 1,
                "constraint_path": "../constraints/pangu100proplus_w3_kws.fdc",
                "constraints_sha256": sha256(ROOT / FDC_REL),
            },
            "firmware_rom": {
                "path": ROM_REL.as_posix(),
                "sha256": rom_hash,
                "build_manifest": ROM_MANIFEST_REL.as_posix(),
                "build_manifest_sha256": sha256(rom_manifest),
                "elf_sha256": rom_manifest_data["artifacts"]["w3_kws_live.elf"]["sha256"],
                "build_command": "python verification/kws/audio/build_live_app_rv32.py --out-dir build/w3-kws-live",
            },
            "model": model,
            "rtl_source_list": RTL_LIST_REL.as_posix(),
            "rtl_source_list_sha256": sha256(ROOT / RTL_LIST_REL),
            "rtl_source_count": len(rtl_paths),
            "rtl_include_files": list(RTL_INCLUDE_FILES),
            "design_input_sha256": input_hashes,
            "frozen_snapshot": {
                "rtl_sha256": frozen_sources,
                "yosys_compat_model_transform": model_transform,
                "yosys_netlist_postprocess": {
                    "rule": "Collapse only the exact complete 16-bit FIFO write-mask process into one synchronous word write after checking the generated enables, address, and data selectors.",
                    "fifo_write_port_transform": fifo_write_transform,
                    "architecture_change": False,
                },
                "yosys_regfile_memory_map": {
                    "module": "regfile_4r2w",
                    "rule": "Map only this FF-based 4R2W register-file memory to explicit DFFs and decoders before PDS compile.",
                    "reason": "PDS 2022.2-SP6.4 reports these outputs as multiple drivers on one GND net when the memory remains unmapped.",
                    "architecture_change": False,
                },
                "generated_sram_zero_image": {
                    "path": zero_rel,
                    "bytes": zero_path.stat().st_size,
                    "sha256": sha256(zero_path),
                    "generator": "b'00\\n' * 16384; matches established COREMARK_YOSYS_PREP input",
                },
                "firmware_rom_copy": {
                    "path": "coremark.hex",
                    "sha256": sha256(out_dir / "coremark.hex"),
                    "matches_formal_rom": sha256(out_dir / "coremark.hex") == rom_hash,
                },
                "model_files_sha256": frozen_model_files,
            },
            "yosys": {
                "executable": str(yosys),
                "version": version.stdout.strip() or version.stderr.strip(),
                "script": YOSYS_SCRIPT_REL.as_posix(),
                "script_sha256": sha256(script),
                "preparation_script": "scripts/prepare_kws_soc_board_pds_input.py",
                "preparation_script_sha256": sha256(ROOT / "scripts/prepare_kws_soc_board_pds_input.py"),
                "log": "yosys_prepare.log",
                "exit_code": yosys_run.returncode,
                "check_result": (
                    f"Found and reported {check_problems} problems and {len(no_driver)} no-driver warnings; "
                    "all no-driver findings are limited to d_byp_rsp_* and intentionally open cache_mem_* outputs."
                ),
                "expected_no_driver_warning_count": len(no_driver),
                "firmware_and_model_init_samples": init_checks,
            },
            "generated_design_source": {
                "path": OUT_REL.as_posix(),
                "sha256": sha256(out_dir / OUT_REL.name),
                "bytes": (out_dir / OUT_REL.name).stat().st_size,
            },
            "prohibited_stages": {
                "pds_synthesis": "NOT_RUN",
                "device_mapping": "NOT_RUN",
                "place_route": "NOT_RUN",
                "sta": "NOT_RUN",
                "bitstream_generation": "NOT_RUN",
                "packaging_or_download": "NOT_RUN",
            },
        }
        evidence_dir = ROOT / EVIDENCE_DIR_REL
        evidence_dir.mkdir(parents=True, exist_ok=True)
        evidence_sources = {
            f"{TOP}_syn.v": out_dir / OUT_REL.name,
            "firmware_rom.kws_live.hex": rom,
            "prepare_kws_soc_board.ys": script,
            "yosys_prepare.log": yosys_log_path,
            "model_rom_check.log": out_dir / "model_rom_check.log",
            "verilator-soc-sources.txt": ROOT / RTL_LIST_REL,
        }
        if (out_dir / "firmware_build.log").is_file():
            evidence_sources["firmware_build.log"] = out_dir / "firmware_build.log"
        evidence_artifacts: dict[str, dict[str, object]] = {}
        for name, source in evidence_sources.items():
            destination = evidence_dir / name
            shutil.copy2(source, destination)
            evidence_artifacts[name] = {
                "sha256": sha256(destination),
                "bytes": destination.stat().st_size,
            }
        manifest["generated_design_source"]["evidence_copy"] = (
            EVIDENCE_DIR_REL / f"{TOP}_syn.v"
        ).as_posix()
        manifest["evidence_artifacts"] = evidence_artifacts
        result_path = ROOT / RESULT_REL
        result_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        shutil.copy2(result_path, evidence_dir / "pds_input_manifest.json")
        print(f"PASS: generated {OUT_REL.as_posix()} ({manifest['generated_design_source']['bytes']} bytes)")
        print(f"ROM SHA-256: {rom_hash}")
        print(f"Model manifest SHA-256: {model['generated_manifest_sha256']}")
        print(f"FDC SHA-256: {manifest['pds_project']['constraints_sha256']}")
        print(f"Output SHA-256: {manifest['generated_design_source']['sha256']}")
        print("PDS synthesis, device mapping, P&R, STA, and bitstream: NOT_RUN")
        return 0
    except (OSError, KeyError, RuntimeError, json.JSONDecodeError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
