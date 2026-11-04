"""Evidence-parser checks: reject partial, mismatched and timed-out outputs."""
import importlib.util
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location("dual_coremark_runner", ROOT / "scripts/run_dual_coremark_sim.py")
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


def uart_fixture(mode="performance", iterations=1280, ticks=1834493791, short=False):
    # Independent published EEMBC 2K vectors, not values read from the parser.
    crc = ({"seedcrc": "e9f5", "list": "e714", "matrix": "1fd7", "state": "8e3a"}
           if mode == "performance" else
           {"seedcrc": "18f2", "list": "e3c1", "matrix": "0747", "state": "8d84"})
    lines = [f"Total ticks : {ticks}", f"Iterations : {iterations}",
             f"seedcrc : 0x{crc['seedcrc']}", f"[0]crclist : 0x{crc['list']}",
             f"[0]crcmatrix : 0x{crc['matrix']}", f"[0]crcstate : 0x{crc['state']}",
             "[0]crcfinal : 0x1234",
             f"PORT-RAW timer_start=0 timer_stop={ticks} ticks={ticks} timer_hz=100058824 timer_bits=64"]
    if short:
        lines.extend(["ERROR! Must execute for at least 10 secs for a valid result!", "Errors detected"])
    else:
        lines.append("Correct operation validated. See README.md for run and reporting rules.")
    return "\n".join(lines) + "\n"


class CoreMarkEvidence(unittest.TestCase):
    def test_complete_performance_and_validation(self):
        for mode in ("performance", "validation"):
            r = runner.parse_coremark(uart_fixture(mode), mode, 100058824, 1280, timer_bits=64)
            self.assertTrue(r["official_run_rules_pass"])
            self.assertEqual(r["physical_score"], "NOT_RUN")

    def test_crc_mismatch_rejected_even_with_success_text(self):
        with self.assertRaisesRegex(ValueError, "CRC mismatch"):
            runner.parse_coremark(uart_fixture().replace("0xe714", "0xe715"), "performance", 100058824, 1280)

    def test_partial_output_rejected(self):
        for text in (uart_fixture().split("[0]crcfinal")[0], uart_fixture().replace("[0]crcfinal : 0x1234\n", "")):
            with self.assertRaises(ValueError):
                runner.parse_coremark(text, "performance", 100058824, 1280)

    def test_short_complete_is_explicit_crc_only(self):
        text = uart_fixture(iterations=32, ticks=12000000, short=True)
        with self.assertRaises(ValueError):
            runner.parse_coremark(text, "performance", 100058824, 32)
        r = runner.parse_coremark(text, "performance", 100058824, 32,
                                  allow_short_run=True, timer_bits=64)
        self.assertFalse(r["official_run_rules_pass"])
        self.assertTrue(r["short_run_crc_only"])
        with self.assertRaises(ValueError):
                runner.parse_coremark(text + "ERROR! data type mismatch\n", "performance", 100058824, 32,
                                      True, timer_bits=64)

    def test_wrong_iterations_and_duplicate_fields_rejected(self):
        for text, n in ((uart_fixture(), 32), (uart_fixture() + "Iterations : 1280\n", 1280)):
            with self.assertRaises(ValueError):
                runner.parse_coremark(text, "performance", 100058824, n)

    def test_window_requires_marker_and_exact_partition(self):
        data = {"cycles": 10, "total_cycles": 10, "retire0": 4, "retire1": 2,
                "primary_fetch_wait": 6, "primary_issue_progress": 4,
                "lsu_primary_load": 0, "lsu_primary_store": 0, "primary_lsu": 0,
                "lsu_state_idle": 0, "lsu_state_req_wait": 0, "lsu_state_wait_rsp": 0,
                "lsu_state_misaligned": 0, "lsu_state_unknown": 0,
                "lane1_pair_nonpairable": 0, "lane1_pair_raw": 0,
                "lane1_pair_waw": 0, "lane1_pair_other": 0, "lane1_blocked": 0,
                "lane1_backend_redirect": 0, "lane1_backend_lsu": 0,
                "lane1_backend_mdu": 0, "lane1_backend_csr": 0,
                "lane1_backend_other": 0, "lane1_backend_blocked": 0,
                "lane1_offer": 0, "issue1": 0}
        text = "PERF_JSON " + json.dumps(data) + "\nSIM_WINDOW_DONE\n"
        self.assertEqual(runner.parse_performance_output(text, "window", 10)["ipc"], 0.6)
        for bad in (text.replace("SIM_WINDOW_DONE", "$finish"), text + "SIM_TIMEOUT\n",
                    text.replace('"primary_fetch_wait": 6', '"primary_fetch_wait": 5'), text + text):
            with self.assertRaises(ValueError):
                runner.parse_performance_output(bad, "window", 10)
        with self.assertRaises(ValueError):
            runner.parse_performance_output(text, "window", 11)

    def test_complete_performance_window_matches_coremark_mcycle(self):
        data = {
            "cycles": 10, "total_cycles": 20, "mcycle_samples": 2, "mcycle_retries": 0,
            "mcycle_window_start": 100, "mcycle_window_stop": 110,
            "mcycle_window_start_cycle": 5, "mcycle_window_stop_cycle": 15,
            "issue0": 10, "issue1": 0, "retire0": 10, "retire1": 0,
            "primary_redirect": 0, "primary_lsu": 0, "primary_mdu": 0,
            "primary_csr": 0, "primary_fetch_wait": 0,
            "primary_issue_progress": 10, "primary_other_wait": 0,
            "lsu_primary_load": 0, "lsu_primary_store": 0,
            "lsu_state_idle": 0, "lsu_state_req_wait": 0,
            "lsu_state_wait_rsp": 0, "lsu_state_misaligned": 0,
            "lsu_state_unknown": 0, "lane1_pair_nonpairable": 0,
            "lane1_pair_raw": 0, "lane1_pair_waw": 0,
            "lane1_pair_other": 0, "lane1_blocked": 0,
            "lane1_backend_redirect": 0, "lane1_backend_lsu": 0,
            "lane1_backend_mdu": 0, "lane1_backend_csr": 0,
            "lane1_backend_other": 0, "lane1_backend_blocked": 0,
            "lane1_offer": 0,
        }
        text = "PERF_JSON " + json.dumps(data) + "\nSIM_UART_DONE\n"
        coremark = {"timer_start": 100, "timer_stop": 110, "ticks": 10}
        self.assertEqual(runner.parse_performance_output(text, "complete", 1, coremark)["cycles"], 10)
        with self.assertRaisesRegex(ValueError, "CoreMark benchmark ticks"):
            runner.parse_performance_output(text, "complete", 1, coremark | {"ticks": 11})
        with self.assertRaisesRegex(ValueError, "mcycle samples disagree"):
            runner.parse_performance_output(text, "complete", 1, coremark | {"timer_start": 99})
        with self.assertRaisesRegex(ValueError, "low-word CSR sample events"):
            runner.parse_performance_output(text.replace('"mcycle_window_stop_cycle": 15',
                                                         '"mcycle_window_stop_cycle": 16'),
                                            "complete", 1, coremark)


if __name__ == "__main__":
    unittest.main()
