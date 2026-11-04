#!/usr/bin/env python3
"""Host-only candidate contract checks. Never opens PDS, serial or JTAG."""
from __future__ import annotations
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from coremark_candidate_contract import clock_profile, validate_board_clock, validate_firmware, validate_clock_artifacts, assess_stage, parse_uart_score, sha256
from run_dual_coremark_sim import parse_coremark

TOP = "dual_issue_coremark_board_top"


class ContractTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def image(self, hz=100058824, iterations=1280):
        p = self.root / "coremark.hex"
        p.write_bytes(b"00000013\n")
        manifest = {"mode": "performance", "march": "rv32im_zicsr", "iterations": iterations,
                    "timer_hz": hz, "files": {"coremark.hex": sha256(p)}}
        (self.root / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        return p, manifest

    def clock_files(self, f=79, o=17):
        (self.root / "coremark100mhz.fdc").write_text(f"create_generated_clock -name {{cpu_clk}} -multiply_by {{{f}}} -divide_by {{{o}}}\n")
        (self.root / "dual_coremark_syn.v").write_text(f"GTP_PPLL #(.STATIC_RATIOF(32'sd{f}), .STATIC_RATIO0(32'sd{o}), .STATIC_RATIOI(32'sd1), .STATIC_RATIOM(32'sd1)) pll();\n")

    def test_clock_profiles_rounding_and_uart(self):
        old = clock_profile(100058824)
        new = clock_profile(125470588)
        self.assertEqual((old["pll_f"], old["pll_o"], old["uart_div"]), (63, 17, 434))
        self.assertEqual((new["pll_f"], new["pll_o"], new["uart_div"]), (79, 17, 545))
        self.assertEqual(round(new["exact_cpu_hz_numerator"] / new["exact_cpu_hz_denominator"]), 125470588)
        self.assertLess(new["uart_relative_error"], 0.001)

    def test_unverified_frequency_rejected(self):
        with self.assertRaises(ValueError): clock_profile(125000000)

    def test_board_mode_clock_matches_implemented_wrapper(self):
        legacy = validate_board_clock("m", 100058824, 115200)
        self.assertEqual((legacy["pll_f"], legacy["pll_o"], legacy["uart_div"]), (63, 17, 869))
        dual = validate_board_clock("dual_m", 125470588, 230400)
        self.assertEqual((dual["pll_f"], dual["pll_o"], dual["uart_div"]), (79, 17, 545))
        with self.assertRaises(ValueError): validate_board_clock("m", 125470588, 115200)
        with self.assertRaises(ValueError): validate_board_clock("zmmul", 100058824, 230400)
        with self.assertRaises(ValueError): validate_board_clock("dual_m", 125470588, 0)

    def test_bad_uart_rejected(self):
        with self.assertRaises(ValueError): clock_profile(100058824, 0)
        with self.assertRaises(ValueError): clock_profile(100058824, 1)

    def test_parameterized_firmware(self):
        image, _ = self.image(125470588, 10000)
        self.assertEqual(validate_firmware(image, 2, 125470588, 10000)[1]["iterations"], 10000)

    def test_default_firmware(self):
        image, _ = self.image()
        self.assertEqual(validate_firmware(image, 2, 100058824, 1280)[1]["timer_hz"], 100058824)

    def test_firmware_wrong_frequency_or_iterations(self):
        image, _ = self.image()
        with self.assertRaises(ValueError): validate_firmware(image, 2, 125470588, 1280)
        with self.assertRaises(ValueError): validate_firmware(image, 2, 100058824, 10000)
        with self.assertRaises(ValueError): validate_firmware(image, 1, 100058824, 1280)

    def test_modified_hex_rejected(self):
        image, _ = self.image()
        image.write_bytes(b"00000000\n")
        with self.assertRaises(ValueError): validate_firmware(image, 2, 100058824, 1280)

    def test_actual_pll_matches_fdc(self):
        self.clock_files()
        validate_clock_artifacts(self.root, clock_profile(125470588))

    def test_change_only_fdc_rejected(self):
        self.clock_files()
        (self.root / "dual_coremark_syn.v").write_text("GTP_PPLL #(.STATIC_RATIOF(32'sd63), .STATIC_RATIO0(32'sd17), .STATIC_RATIOI(1), .STATIC_RATIOM(1)) pll();")
        with self.assertRaises(ValueError): validate_clock_artifacts(self.root, clock_profile(125470588))

    def test_duplicate_pll_rejected(self):
        self.clock_files()
        p = self.root / "dual_coremark_syn.v"
        p.write_text(p.read_text() * 2)
        with self.assertRaises(ValueError): validate_clock_artifacts(self.root, clock_profile(125470588))

    def stage(self, phase, marker, report):
        directory, extension = {"synthesize": ("synthesize", "snr"), "pnr": ("place_route", "prr"),
                                "report_timing": ("report_timing", "rtr"), "gen_bit_stream": ("generate_bitstream", "sbit")}[phase]
        d = self.root / directory; d.mkdir()
        (d / "run.log").write_text(marker)
        (d / f"{TOP}.{extension}").write_text(report)
        return d

    def test_zero_exit_without_report_is_not_pass(self):
        self.assertEqual(assess_stage(self.root, TOP, "report_timing", 0)["status"], "FAILED")

    def test_synthesis_requires_vendor_completion(self):
        marker = f"Design '{TOP}' has been successfully synthesized to architecture-specific objects."
        self.stage("synthesize", marker, self.synthesis_snr())
        self.assertEqual(assess_stage(self.root, TOP, "synthesize", 0)["status"], "PASS")
        self.assertEqual(assess_stage(self.root, TOP, "synthesize", 1)["status"], "FAILED")
        self.assertEqual(assess_stage(self.root, TOP, "synthesize", 0, "Program Error Out.")["status"], "FAILED")

    @staticmethod
    def synthesis_snr(luts=1200, registers=850, drm=2, apm=0, cpu_clk_loads=850):
        return (f"Total LUTs: {luts} of 66600 (1.80%)\n"
                f"Total Registers: {registers} of 133200 (0.64%)\n"
                f"Total DRM = {drm}.0 of 155 (1.29%)\n"
                f"Total APMs = {apm}.00 of 240 (0.00%)\n"
                "Clock Summary:\n"
                " Clock                    Period       Waveform            Type                  Clock   Non-clock\n"
                f" cpu_clk                  7.9700       {{0.0000 3.9840}}     Generated (ref_clk)    {cpu_clk_loads}           0  {{u_pll.u_pll/CLKOUT0}}\n"
                "Clock Groups:\n")

    def test_synthesis_rejects_empty_mapping_and_clockless_cpu(self):
        marker = f"Design '{TOP}' has been successfully synthesized to architecture-specific objects."

        d = self.stage("synthesize", marker, self.synthesis_snr())
        result = assess_stage(self.root, TOP, "synthesize", 0)
        self.assertEqual(result["status"], "PASS")
        self.assertTrue(result["synthesis_design_valid"])
        self.assertEqual(result["synthesis_design"]["cpu_clk_loads"], 850)

        (d / f"{TOP}.snr").write_text(self.synthesis_snr(luts=0, registers=0, drm=0, apm=0, cpu_clk_loads=0))
        result = assess_stage(self.root, TOP, "synthesize", 0)
        self.assertEqual(result["status"], "FAILED")
        self.assertFalse(result["synthesis_design_valid"])
        self.assertIn("no mapped logic resources", result["reason"])

        (d / f"{TOP}.snr").write_text(self.synthesis_snr(cpu_clk_loads=0))
        result = assess_stage(self.root, TOP, "synthesize", 0)
        self.assertEqual(result["status"], "FAILED")
        self.assertFalse(result["synthesis_design_valid"])
        self.assertIn("no generated cpu_clk endpoints", result["reason"])

    def test_timing_requires_constraints_met(self):
        d = self.stage("report_timing", "Report timing is finished successfully.", "Design Summary : All Constraints Met.")
        self.assertTrue(assess_stage(self.root, TOP, "report_timing", 0)["constraints_met"])
        (d / f"{TOP}.rtr").write_text("VIOLATED")
        self.assertEqual(assess_stage(self.root, TOP, "report_timing", 0)["status"], "FAILED")

    @staticmethod
    def timing_report(slow_setup=1.000, fast_setup=4.275, slow_hold=0.137, fast_hold=0.103):
        def setup(corner, margin):
            return (f"Setup Summary({corner}):\n"
                    " Launch Clock           Capture Clock              WNS(ns)     TNS(ns)      Endpoints      Endpoints\n"
                    f" cpu_clk                cpu_clk                      {margin:.3f}       0.000              0          26995\n"
                    "================================================================================\n")
        def hold(corner, margin):
            return (f"Hold Summary({corner}):\n"
                    " Launch Clock           Capture Clock              WHS(ns)     THS(ns)      Endpoints      Endpoints\n"
                    f" cpu_clk                cpu_clk                      {margin:.3f}       0.000              0          26986\n"
                    "================================================================================\n")
        return ("Design Summary : All Constraints Met.\nTiming analysis mode : multi corner\n"
                + setup("Slow Corner", slow_setup) + hold("Slow Corner", slow_hold)
                + setup("Fast Corner", fast_setup) + hold("Fast Corner", fast_hold))

    def test_dual_timing_gate_enforces_setup_hold_margins_in_every_corner(self):
        kwargs = {"required_setup_margin_ns": 1.0, "required_hold_margin_ns": 0.10}
        d = self.stage("report_timing", "Report timing is finished successfully.", self.timing_report())
        result = assess_stage(self.root, TOP, "report_timing", 0, **kwargs)
        self.assertTrue(result["constraints_met"])
        self.assertEqual(result["timing_margins_ns"]["setup_min_ns"], 1.0)
        self.assertEqual(result["timing_margins_ns"]["hold_min_ns"], 0.103)

        report = d / f"{TOP}.rtr"
        report.write_text(self.timing_report(slow_setup=0.999))
        self.assertFalse(assess_stage(self.root, TOP, "report_timing", 0, **kwargs)["constraints_met"])
        report.write_text(self.timing_report(fast_hold=0.099))
        self.assertFalse(assess_stage(self.root, TOP, "report_timing", 0, **kwargs)["constraints_met"])
        report.write_text(self.timing_report().replace("Setup Summary(Fast Corner):", "Setup Summary(Fast Corner Missing):"))
        self.assertFalse(assess_stage(self.root, TOP, "report_timing", 0, **kwargs)["constraints_met"])

    def test_bitstream_requires_sidecar(self):
        d = self.stage("gen_bit_stream", "Generating Programming File done.", "sbit bytes")
        self.assertEqual(assess_stage(self.root, TOP, "gen_bit_stream", 0)["status"], "FAILED")
        (d / f"{TOP}.smsk").write_bytes(b"mask")
        self.assertEqual(assess_stage(self.root, TOP, "gen_bit_stream", 0)["status"], "PASS")

    @staticmethod
    def transcript(bits=32, hz=100058824, iterations=1280, ticks=1834493791):
        modulus = 2**bits
        start = modulus - 100
        stop = (start + ticks) % modulus
        displayed_ticks = ticks if bits == 32 else ticks & 0xFFFF_FFFF
        raw_width = f"wrap_limit={modulus}" if bits == 32 else f"timer_bits={bits}"
        return (f"Iterations : {iterations}\nTotal ticks : {displayed_ticks}\nseedcrc : 0xe9f5\n"
                "[0]crclist : 0xe714\n[0]crcmatrix : 0x1fd7\n[0]crcstate : 0x8e3a\n"
                "Correct operation validated.\n"
                f"PORT-RAW timer_start={start} timer_stop={stop} ticks={ticks} timer_hz={hz} {raw_width}\n").encode()

    def test_uart_legacy_window_with_rollover(self):
        r = parse_uart_score(self.transcript(), {"timer_hz": 100058824, "iterations": 1280})
        self.assertTrue(r["minimum_10s_window_met"])
        self.assertAlmostEqual(r["coremark_per_mhz_from_configured_timer"], 0.6977401647689742)

    def test_uart_64bit_ticks_above_uint32(self):
        r = parse_uart_score(self.transcript(64, 125470588, 10000, 9000000000),
                             {"timer_hz": 125470588, "iterations": 10000, "timer_bits": 64})
        self.assertEqual(r["ticks"], 9000000000)
        self.assertTrue(r["minimum_10s_window_met"])

    def test_full_sim_parser_uses_raw_64bit_counter(self):
        text = self.transcript(64, 125470588, 10000, 9000000000).decode()
        text += "[0]crcfinal : 0x8799\n"
        result = parse_coremark(text, "performance", 125470588, 10000, timer_bits=64)
        self.assertEqual(result["ticks"], 9000000000)
        self.assertEqual(result["simulated_coremark_per_mhz"], 10000 * 1_000_000 / 9_000_000_000)

    def test_verilator_runner_rejects_uart_divider_from_other_clock(self):
        image, _ = self.image(125470588, 10000)
        out = self.root / "runner-clock-mismatch"
        result = subprocess.run(
            [sys.executable, str(Path(__file__).with_name("run_dual_coremark_sim.py")),
             "--hex", str(image), "--manifest", str(self.root / "manifest.json"),
             "--uart-div", "434", "--out-dir", str(out)],
            capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match the firmware clock profile", result.stdout + result.stderr)

    def test_uart_wrong_width_or_crc_or_duplicate(self):
        fw = {"timer_hz": 100058824, "iterations": 1280}
        with self.assertRaises(ValueError): parse_uart_score(self.transcript(64), fw)
        with self.assertRaises(ValueError): parse_uart_score(self.transcript().replace(b"0xe714", b"0xe715"), fw)
        with self.assertRaises(ValueError): parse_uart_score(self.transcript() + b"Iterations : 1280\n", fw)

    def test_uart_below_ten_seconds_is_not_score(self):
        r = parse_uart_score(self.transcript(ticks=10), {"timer_hz": 100058824, "iterations": 1280})
        self.assertFalse(r["minimum_10s_window_met"])

    def test_help_does_not_open_vendor_or_board(self):
        for script in ("run_dual_issue_pds_candidate.py", "build_coremark_candidate.py", "run_coremark_board_once.py"):
            result = subprocess.run([sys.executable, str(Path(__file__).with_name(script)), "--help"], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
            self.assertIn(b"--cpu-hz", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
