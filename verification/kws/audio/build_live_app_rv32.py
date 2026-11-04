#!/usr/bin/env python3
"""Compile and link the live KWS app plus TFLM frontend for the SoC RV32IM ABI."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
REF = ROOT / "references/kws-signal-port-230c9"
RV32 = ROOT / "tools/kws/frontend_ref/rv32"


def run(argv: list[str]) -> None:
    p = subprocess.run(argv, cwd=ROOT, text=True, capture_output=True)
    if p.stdout:
        print(p.stdout, end="")
    if p.stderr:
        print(p.stderr, end="", file=sys.stderr)
    if p.returncode:
        raise SystemExit(p.returncode)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def version_line(program: str) -> str:
    p = subprocess.run([program, "--version"], cwd=ROOT, text=True, capture_output=True)
    output = p.stdout or p.stderr
    if p.returncode or not output.strip():
        return f"unavailable (exit {p.returncode})"
    return output.splitlines()[0]


def write_rom_hex(binary: Path, output: Path, capacity: int = 65536) -> int:
    image = binary.read_bytes()
    if len(image) > capacity:
        raise SystemExit(f"FAIL: ROM image is {len(image)} bytes, capacity is {capacity}")
    if len(image) % 4:
        image += b"\0" * (4 - len(image) % 4)
    with output.open("w", encoding="ascii", newline="\n") as stream:
        for offset in range(0, len(image), 4):
            stream.write(f"{int.from_bytes(image[offset:offset + 4], 'little'):08x}\n")
    return len(image)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out-dir", type=Path,
        help="retain ELF, map, binary and ROM $readmemh image in this directory",
    )
    parser.add_argument(
        "--define", action="append", default=[], metavar="NAME=VALUE",
        help=(
            "extra preprocessor define for the C sources, e.g. "
            "KWS_LIVE_GATE_PARAMS_VERIFIED=1 to compile the packaged rejector "
            "path into the live decision. Recorded in the build manifest."
        ),
    )
    args = parser.parse_args()

    cc_name = os.environ.get("RISCV_CC", "riscv32-unknown-elf-gcc")
    cxx_name = os.environ.get("RISCV_CXX", "riscv32-unknown-elf-g++")
    cc, cxx = shutil.which(cc_name), shutil.which(cxx_name)
    if cc is None or cxx is None:
        print(f"NOT_RUN: RV32 toolchain missing ({cc_name}, {cxx_name})", file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory(prefix="w3_kws_live_rv32_") as td_raw:
        td = Path(td_raw)
        kiss = td / "kissfft"
        obj_dir = td / "obj"
        obj_dir.mkdir()
        run([sys.executable, str(RV32 / "patch_kissfft.py"),
             "--src", str(REF / "third_party/kissfft"), "--out", str(kiss)])

        includes = [
            RV32 / "include",
            ROOT / "firmware/kws/include",
            REF,
            REF / "shims",
            kiss,
            kiss / "tools",
            REF / "third_party/kissfft",
            RV32,
        ]
        cflags = ["-std=c11", "-Os", "-flto", "-march=rv32im_zicsr", "-mabi=ilp32",
                  "-ffreestanding", "-fno-builtin", "-ffunction-sections", "-fdata-sections"]
        cflags.extend(f"-D{define}" for define in args.define)
        cxxflags = ["-std=c++17", "-Os", "-flto", "-march=rv32im_zicsr", "-mabi=ilp32",
                    "-ffreestanding", "-fno-exceptions", "-fno-rtti",
                    "-fno-threadsafe-statics", "-ffunction-sections", "-fdata-sections",
                    "-DKWS_PRECOMPUTED_TWIDDLES"]
        cxxflags.extend(f"-I{p}" for p in includes)
        cflags.extend(f"-I{p}" for p in includes)

        objects: list[Path] = []

        def compile_one(compiler: str, flags: list[str], src: Path, index: int) -> None:
            obj = obj_dir / f"{index:02d}_{src.stem}.o"
            run([compiler, *flags, "-c", str(src), "-o", str(obj)])
            objects.append(obj)

        c_sources = [
            ROOT / "firmware/kws/src/kws_live_app.c",
            ROOT / "firmware/kws/src/kws_live_decision.c",
            ROOT / "firmware/kws/src/kws_pcm_energy.c",
            ROOT / "firmware/kws/src/kws_gate.c",
            ROOT / "firmware/kws/src/kws_softmax.c",
            ROOT / "firmware/kws/src/kws_seg.c",
            ROOT / "firmware/kws/src/kws_estop.c",
            ROOT / "firmware/kws/src/kws_fan_control.c",
            ROOT / "firmware/kws/src/kws_runtime.c",
        ]
        for i, src in enumerate(c_sources):
            src_flags = cflags
            if src.name == "kws_runtime.c":
                src_flags = [flag for flag in cflags if flag != "-flto"]
            compile_one(cc, src_flags, src, i)

        entry = td / "live_entry.c"
        entry.write_text(
            "extern void w3_kws_live_main(void);\n"
            "int main(void) { w3_kws_live_main(); return 0; }\n",
            encoding="ascii",
        )
        compile_one(cc, cflags, entry, len(objects))
        compile_one(cc, cflags, ROOT / "firmware/coremark/port/start.S", len(objects))

        cpp_sources = [
            ROOT / "firmware/kws/src/kws_frontend.cpp",
            RV32 / "kiss_fft_int16_precomputed.cc",
            RV32 / "twiddles_q15.cc",
        ]
        cpp_sources.extend(sorted((REF / "signal/src").glob("*.cc")))
        for src in cpp_sources:
            compile_one(cxx, cxxflags, src, len(objects))

        elf = td / "w3_kws_live.elf"
        map_file = td / "w3_kws_live.map"
        binary = td / "w3_kws_live.bin"
        rom_hex = td / "w3_kws_live.hex"
        link = [cxx, "-Os", "-flto", "-march=rv32im_zicsr", "-mabi=ilp32", "-nostdlib",
                f"-Wl,-T,{ROOT / 'firmware/coremark/port/link.ld'}",
                "-Wl,--defsym,ROM_BYTES=65536", "-Wl,--defsym,RAM_BYTES=65536",
                "-Wl,--defsym,STACK_BYTES=8192", "-Wl,--gc-sections", "-Wl,-z,defs",
                f"-Wl,-Map,{map_file}", "-o", str(elf)]
        link.extend(str(obj) for obj in objects)
        link.append("-lgcc")
        run(link)
        objcopy_name = os.environ.get("RISCV_OBJCOPY", "riscv32-unknown-elf-objcopy")
        objcopy = shutil.which(objcopy_name)
        if objcopy is None:
            print(f"NOT_RUN: RV32 objcopy missing ({objcopy_name})", file=sys.stderr)
            return 2
        run([objcopy, "-O", "binary", str(elf), str(binary)])
        rom_bytes = write_rom_hex(binary, rom_hex)
        size = shutil.which("riscv32-unknown-elf-size")
        if size:
            run([size, str(elf)])
        print(f"PASS: live app + TFLM frontend linked for RV32IM/Zicsr; ELF {elf.stat().st_size} bytes")
        print(f"ROM image: {rom_bytes} bytes, {rom_bytes // 4} words (capacity 65536 bytes)")

        if args.out_dir is not None:
            out_dir = args.out_dir.resolve()
            out_dir.mkdir(parents=True, exist_ok=True)
            retained = {}
            for name, source in (("w3_kws_live.elf", elf), ("w3_kws_live.map", map_file),
                                 ("w3_kws_live.bin", binary), ("kws_live.hex", rom_hex)):
                target = out_dir / name
                shutil.copy2(source, target)
                retained[name] = {"bytes": target.stat().st_size, "sha256": sha256(target)}
            manifest = {
                "schema": "w3-kws-live-rv32im-v1",
                "target": {"march": "rv32im_zicsr", "mabi": "ilp32", "rom_capacity_bytes": 65536},
                "tools": {"cc": version_line(cc), "cxx": version_line(cxx),
                          "objcopy": version_line(objcopy)},
                "build": {"optimization": "-Os -flto", "linker_script": "firmware/coremark/port/link.ld",
                          "rom_bytes": rom_bytes, "rom_words": rom_bytes // 4,
                          "extra_defines": list(args.define)},
                "artifacts": retained,
            }
            manifest_path = out_dir / "w3_kws_live_manifest.json"
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
            print(f"Retained ELF, map, binary, kws_live.hex and manifest in {out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
