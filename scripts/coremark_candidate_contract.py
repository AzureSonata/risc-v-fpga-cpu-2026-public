"""Pure validation shared by candidate preparation and board preflight.

No vendor process or hardware is opened by this module. Exact artifact hashes
are checked independently from semantic clock/firmware checks.
"""
from __future__ import annotations
import hashlib
import json
from fractions import Fraction
from pathlib import Path
import re

CLOCK_PROFILES = {100_058_824: (63, 17), 125_470_588: (79, 17),
                  # 76.235294 MHz = 27 MHz x 48/17: routed Fmax ~79.3 MHz 时的可闭合回退档
                  76_235_294: (48, 17), 73_058_824: (46, 17),
                  # 68.294118 MHz = 27 MHz x 43/17: routed 73.06 MHz 时 setup +0.057 ns，
                  # 降到此档可为最差路径留约 +1.0 ns 余量（板级余量目标）。
                  68_294_118: (43, 17)}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def clock_profile(cpu_hz: int, uart_baud: int = 230400) -> dict:
    if cpu_hz not in CLOCK_PROFILES:
        raise ValueError(f"unsupported verified PLL profile {cpu_hz}; choose {sorted(CLOCK_PROFILES)}")
    if uart_baud <= 0:
        raise ValueError("uart-baud must be positive")
    f, o = CLOCK_PROFILES[cpu_hz]
    exact = Fraction(27_000_000 * f, o)
    divisor = round(exact / uart_baud)
    if not 1 <= divisor <= 65535:
        raise ValueError("UART divisor must fit the existing 16-bit UART counter")
    actual_baud = exact / divisor
    error = float(abs(actual_baud / uart_baud - 1))
    if error > 0.02:
        raise ValueError("UART baud quantization error exceeds 2 percent")
    return {"reference_hz": 27_000_000, "pll_f": f, "pll_o": o,
            "exact_cpu_hz_numerator": exact.numerator, "exact_cpu_hz_denominator": exact.denominator,
            "cpu_hz": cpu_hz, "rounding": "nearest integer Hz", "uart_baud": uart_baud,
            "uart_div": divisor, "actual_uart_baud": float(actual_baud), "uart_relative_error": error}


def validate_board_clock(mode: str, cpu_hz: int, uart_baud: int) -> dict:
    """Validate a board wrapper's implemented clock controls before preflight.

    The legacy single-issue wrapper currently hardwires the 63/17 PLL and
    UART_DIV=869. Only the dual candidate wrapper exposes PLL and UART
    parameters, so legacy m/zmmul runs must retain their actual defaults.
    """
    if mode not in ("m", "zmmul", "dual_m"):
        raise ValueError(f"unsupported board mode {mode!r}")
    if mode != "dual_m" and (cpu_hz, uart_baud) != (100_058_824, 115_200):
        raise ValueError("legacy m/zmmul board top is fixed at 100058824 Hz and 115200 baud")
    return clock_profile(cpu_hz, uart_baud)


def validate_firmware(image: Path, m_mode: int, cpu_hz: int, iterations: int) -> tuple[Path, dict]:
    manifest_path = image.with_name("manifest.json")
    if not image.is_file() or not manifest_path.is_file():
        raise ValueError(f"HEX/manifest missing: {image}")
    if iterations <= 0:
        raise ValueError("iterations must be positive")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
    expected_marches = ({"rv32i_zmmul", "rv32i_zicsr_zmmul"} if m_mode == 1
                        else {"rv32im", "rv32im_zicsr"})
    expected = {"mode": "performance", "iterations": iterations, "timer_hz": cpu_hz}
    for key, value in expected.items():
        if manifest.get(key) != value:
            raise ValueError(f"firmware {key}: expected {value!r}, found {manifest.get(key)!r}")
    if manifest.get("march") not in expected_marches:
        raise ValueError(f"firmware march: expected one of {sorted(expected_marches)}, found {manifest.get('march')!r}")
    if manifest.get("files", {}).get("coremark.hex") != sha256(image):
        raise ValueError("CoreMark HEX SHA-256 does not match its manifest")
    return manifest_path, manifest


def validate_clock_artifacts(out: Path, clock: dict) -> None:
    text = (out / "coremark100mhz.fdc").read_text(encoding="utf-8-sig")
    matches = re.findall(r"create_generated_clock[^\n]*-multiply_by\s+\{?(\d+)\}?\s+-divide_by\s+\{?(\d+)\}?", text)
    if matches != [(str(clock["pll_f"]), str(clock["pll_o"]))]:
        raise ValueError("generated clock FDC does not match the selected PLL ratio")
    netlist = (out / "dual_coremark_syn.v").read_text(encoding="utf-8-sig", errors="replace")
    def parameter(name: str) -> int:
        values = re.findall(r"\." + name + r"\(\s*(?:\d+'s?d)?(\d+)\s*\)", netlist)
        if len(values) != 1:
            raise ValueError(f"expected exactly one netlist PLL {name}")
        return int(values[0])
    if (parameter("STATIC_RATIOF"), parameter("STATIC_RATIO0"), parameter("STATIC_RATIOI"), parameter("STATIC_RATIOM")) != (clock["pll_f"], clock["pll_o"], 1, 1):
        raise ValueError("actual netlist PLL parameters disagree with FDC/firmware frequency")


def parse_timing_margins(report: str, required_corners: tuple[str, ...] = ("Slow Corner", "Fast Corner")) -> dict:
    number = r"[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?"
    heading = re.compile(r"^\s*(Setup|Hold) Summary\(([^)]+)\):\s*$", re.IGNORECASE)
    row = re.compile(rf"^\s*(\S+)\s+(\S+)\s+({number})\s+({number})\s+(\d+)\s+(\d+)\s*$")
    summaries: dict[str, dict[str, list[dict]]] = {}
    current: tuple[str, str] | None = None
    for line in report.splitlines():
        match = heading.match(line)
        if match:
            kind = match.group(1).lower()
            corner = match.group(2).strip()
            current = (kind, corner)
            summaries.setdefault(corner.casefold(), {"setup": [], "hold": []})
            continue
        if current is None:
            continue
        if re.match(r"^\s*={8,}\s*$", line):
            current = None
            continue
        if re.search(r"\b(?:Recovery|Removal|Minimum Pulse Width|Clock) Summary\(", line, re.IGNORECASE):
            current = None
            continue
        match = row.match(line)
        if not match:
            continue
        kind, corner = current
        summaries[corner.casefold()][kind].append({
            "launch_clock": match.group(1),
            "capture_clock": match.group(2),
            "margin_ns": float(match.group(3)),
            "failing_endpoints": int(match.group(5)),
            "total_endpoints": int(match.group(6)),
        })

    missing = []
    for corner in required_corners:
        entry = summaries.get(corner.casefold())
        if not entry or not entry["setup"] or not entry["hold"]:
            missing.append(corner)
    if missing:
        raise ValueError("missing setup/hold summary rows for required corners: " + ", ".join(missing))

    setup_rows = [item for entry in summaries.values() for item in entry["setup"]]
    hold_rows = [item for entry in summaries.values() for item in entry["hold"]]
    if not setup_rows or not hold_rows:
        raise ValueError("timing report has no numeric setup WNS or hold WHS summary rows")
    return {
        "setup_min_ns": min(item["margin_ns"] for item in setup_rows),
        "hold_min_ns": min(item["margin_ns"] for item in hold_rows),
        "corners": {
            corner: {
                "setup_min_ns": min(row["margin_ns"] for row in values["setup"]),
                "hold_min_ns": min(row["margin_ns"] for row in values["hold"]),
                "setup_rows": values["setup"],
                "hold_rows": values["hold"],
            }
            for corner, values in ((name, summaries[name.casefold()]) for name in summaries)
        },
    }


def parse_synthesis_design_summary(report: str) -> dict:
    """Reject a nominal synthesis success that contains only PLL/IO stubs."""
    patterns = {
        "luts": r"(?m)^\s*Total LUTs:\s*([\d,]+)\b",
        "registers": r"(?m)^\s*Total Registers:\s*([\d,]+)\b",
        "drm": r"(?m)^\s*Total DRM\s*=\s*([\d,.]+)\b",
        "apm": r"(?m)^\s*Total APMs\s*=\s*([\d,.]+)\b",
    }
    resources = {}
    for name, pattern in patterns.items():
        match = re.search(pattern, report)
        if not match:
            raise ValueError(f"synthesis report missing {name} resource summary")
        resources[name] = float(match.group(1).replace(",", ""))

    clock_summary = re.search(r"Clock Summary\s*:(.*?)(?:\n\s*Clock Groups\s*:|\Z)", report, re.DOTALL)
    if not clock_summary:
        raise ValueError("synthesis report missing clock summary")
    cpu_clock = re.search(
        r"(?m)^\s*cpu_clk\s+\S+\s+\{[^}]+\}\s+Generated\s+\([^)]*\)\s+(\d+)\s+(\d+)\s+\{",
        clock_summary.group(1),
    )
    if not cpu_clock:
        raise ValueError("synthesis report missing generated cpu_clk endpoint count")
    cpu_clock_loads = int(cpu_clock.group(1))
    cpu_clock_non_clock_loads = int(cpu_clock.group(2))
    total_logic_resources = sum(resources.values())
    return {
        "resources": resources,
        "total_logic_resources": total_logic_resources,
        "cpu_clk_loads": cpu_clock_loads,
        "cpu_clk_non_clock_loads": cpu_clock_non_clock_loads,
        "valid_cpu_design": total_logic_resources > 0 and cpu_clock_loads > 0,
    }


def assess_stage(out: Path, top: str, phase: str, returncode: int, process_output: str = "", *, started_ns: int | None = None, cpu_hz: int | None = None, required_setup_margin_ns: float | None = None, required_hold_margin_ns: float | None = None) -> dict:
    if (required_setup_margin_ns is None) != (required_hold_margin_ns is None):
        raise ValueError("setup and hold timing margin thresholds must be provided together")
    directory = {"synthesize": "synthesize", "pnr": "place_route", "report_timing": "report_timing", "gen_bit_stream": "generate_bitstream"}[phase]
    run_log = out / directory / "run.log"
    text = process_output + "\n" + (run_log.read_text(encoding="utf-8-sig", errors="replace") if run_log.is_file() else "")
    errors = bool(re.search(r"(?m)^\s*(?:E: |ERROR:)", text)) or "Program Error Out." in text
    artifact = {"synthesize": out / directory / f"{top}.snr", "pnr": out / directory / f"{top}.prr",
                "report_timing": out / directory / f"{top}.rtr", "gen_bit_stream": out / directory / f"{top}.sbit"}[phase]
    artifact_ok = artifact.is_file() and artifact.stat().st_size > 0
    markers = {"synthesize": f"Design '{top}' has been successfully synthesized to architecture-specific objects.",
               "pnr": f"Design '{top}' has been placed and routed successfully.",
               "report_timing": "Report timing is finished successfully.",
               "gen_bit_stream": "Generating Programming File done."}
    fresh = started_ns is None or (artifact_ok and run_log.is_file() and artifact.stat().st_mtime_ns >= started_ns and run_log.stat().st_mtime_ns >= started_ns)
    complete = returncode == 0 and not errors and artifact_ok and markers[phase] in text and fresh
    item = {"status": "PASS" if complete else "FAILED", "exit": returncode,
            "log": f"{directory}/run.log", "artifact": str(artifact.relative_to(out)),
            "artifact_sha256": sha256(artifact) if artifact_ok else None}
    if started_ns is not None:
        item["started_ns"] = started_ns
        item["fresh_artifact_and_log"] = fresh
    if phase == "report_timing":
        report = artifact.read_text(encoding="utf-8-sig", errors="replace") if artifact_ok else ""
        item["constraints_met"] = complete and "Design Summary : All Constraints Met." in report and "VIOLATED" not in report
        if required_setup_margin_ns is not None and required_hold_margin_ns is not None:
            item["required_timing_margins_ns"] = {
                "setup_min": required_setup_margin_ns,
                "hold_min": required_hold_margin_ns,
                "required_corners": ["Slow Corner", "Fast Corner"],
            }
            try:
                margins = parse_timing_margins(report)
                item["timing_margins_ns"] = margins
                item["timing_margins_met"] = (
                    margins["setup_min_ns"] >= required_setup_margin_ns
                    and margins["hold_min_ns"] >= required_hold_margin_ns
                )
            except ValueError as exc:
                item["timing_margins_met"] = False
                item["timing_margin_parse_error"] = str(exc)
            item["constraints_met"] &= item["timing_margins_met"]
        if cpu_hz is not None:
            frequencies = re.findall(r"(?m)^\s*cpu_clk\s+([0-9.]+) MHz\s+", report)
            item["clock_frequency_matches"] = len(frequencies) == 1 and abs(float(frequencies[0]) * 1_000_000 - cpu_hz) <= 200
            item["constraints_met"] &= item["clock_frequency_matches"]
        if not item["constraints_met"]:
            item["status"] = "FAILED"
    if phase == "synthesize":
        report = artifact.read_text(encoding="utf-8-sig", errors="replace") if artifact_ok else ""
        try:
            item["synthesis_design"] = parse_synthesis_design_summary(report)
            item["synthesis_design_valid"] = item["synthesis_design"]["valid_cpu_design"]
        except ValueError as exc:
            item["synthesis_design_valid"] = False
            item["synthesis_design_parse_error"] = str(exc)
        if not item["synthesis_design_valid"]:
            item["status"] = "FAILED"
    if phase == "gen_bit_stream":
        sidecar = out / directory / f"{top}.smsk"
        item["smsk_sha256"] = sha256(sidecar) if sidecar.is_file() and sidecar.stat().st_size > 0 else None
        if item["smsk_sha256"] is None:
            item["status"] = "FAILED"
    if item["status"] != "PASS":
        reasons = ["requires zero process exit, no tool errors, nonempty artifact and stage completion marker"]
        if phase == "synthesize" and not item.get("synthesis_design_valid"):
            if item.get("synthesis_design_parse_error"):
                reasons.append(item["synthesis_design_parse_error"])
            else:
                reasons.append("synthesis report has no mapped logic resources or no generated cpu_clk endpoints")
        if phase == "report_timing" and required_setup_margin_ns is not None and required_hold_margin_ns is not None:
            if item.get("timing_margin_parse_error"):
                reasons.append(item["timing_margin_parse_error"])
            elif item.get("timing_margins_ns") and not item.get("timing_margins_met"):
                margins = item["timing_margins_ns"]
                reasons.append(
                    f"minimum setup {margins['setup_min_ns']:.3f} ns / hold {margins['hold_min_ns']:.3f} ns "
                    f"below required {required_setup_margin_ns:.3f} ns / {required_hold_margin_ns:.3f} ns"
                )
        item["reason"] = "; ".join(reasons)
    return item


def parse_uart_score(raw: bytes, firmware: dict) -> dict:
    text = re.sub(r"^COREMARK-UART\s+", "", raw.decode("ascii", errors="replace"), flags=re.MULTILINE)
    def number(pattern: str, base: int = 10) -> int:
        values = re.findall(pattern, text, re.MULTILINE)
        if len(values) != 1:
            raise ValueError(f"UART field missing or duplicated: {pattern}; count={len(values)}")
        return int(values[0], base)
    iterations = number(r"^Iterations\s*:\s*(\d+)\s*$")
    reported_ticks = number(r"^Total ticks\s*:\s*(\d+)\s*$")
    seedcrc = number(r"^seedcrc\s*:\s*0x([0-9a-fA-F]+)\s*$", 16)
    crc = {"seedcrc": f"{seedcrc:04x}"}
    for key in ("list", "matrix", "state"):
        value = number(r"^\[0\]crc" + key + r"\s*:\s*0x([0-9a-fA-F]+)\s*$", 16)
        crc[key] = f"{value:04x}"
    windows = re.findall(
        r"^PORT-RAW timer_start=(\d+) timer_stop=(\d+) ticks=(\d+) timer_hz=(\d+)"
        r"(?: wrap_limit=(\d+)| timer_bits=(32|64))\s*$", text, re.MULTILINE)
    if len(windows) != 1:
        raise ValueError("expected exactly one raw counter window")
    bits = firmware.get("timer_bits", 32)
    start, stop, raw_ticks, hz = map(int, windows[0][:4])
    wrap_limit, raw_bits = windows[0][4:]
    modulus = 2**bits if bits in (32, 64) else 0
    if bits not in (32, 64):
        raise ValueError("firmware counter width must be 32 or 64 bits")
    if wrap_limit and int(wrap_limit) != modulus:
        raise ValueError("raw counter wrap limit disagrees with firmware manifest")
    if raw_bits and int(raw_bits) != bits:
        raise ValueError("raw counter width disagrees with firmware manifest")
    if not all(0 <= value < modulus for value in (start, stop, raw_ticks)) or raw_ticks == 0:
        raise ValueError("counter range/ticks invalid")
    if iterations != firmware["iterations"] or hz != firmware["timer_hz"]:
        raise ValueError("UART iterations/frequency disagree with firmware manifest")
    if bits == 32:
        ticks = reported_ticks
        if ticks != raw_ticks:
            raise ValueError("32-bit CoreMark and raw counter ticks disagree")
    else:
        ticks = raw_ticks
        if reported_ticks != (ticks & 0xFFFF_FFFF):
            raise ValueError("CoreMark's 32-bit display disagrees with the low half of the 64-bit timer")
    if ticks != ((stop - start) % modulus):
        raise ValueError("raw counter window disagrees with reported ticks")
    expected = {"seedcrc": "e9f5", "list": "e714", "matrix": "1fd7", "state": "8e3a"}
    if crc != expected:
        raise ValueError(f"CoreMark CRC mismatch: expected={expected}, observed={crc}")
    if "Correct operation validated." not in text or any(x in text for x in ("ERROR!", "Errors detected", "ASSERT-FAIL", "TRAP", "TIMEOUT")):
        raise ValueError("CoreMark validation marker missing or error present")
    seconds = ticks / hz
    return {"software_validation": "PASS", "iterations": iterations, "ticks": ticks,
            "timer_hz_configured": hz, "timer_bits": bits, "elapsed_timer_seconds": seconds,
            "minimum_10s_window_met": seconds >= 10.0,
            "coremark_per_mhz_from_configured_timer": iterations * 1_000_000 / ticks,
            "crc": crc, "physical_clock_measurement": "NOT_MEASURED; frequency is configured from PLL/reference"}
