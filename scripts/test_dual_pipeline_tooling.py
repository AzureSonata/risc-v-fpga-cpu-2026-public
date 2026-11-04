"""Five-stage implementation selection and evidence binding; no hardware tools."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import unittest

import run_dual_issue_pds_candidate as pds
import run_dual_coremark_sim as sim


class VariantBinding(unittest.TestCase):
    def five(self):
        return pds.core_variant(True) | {"source_git_blob": {p: None for p in pds.FIVE_STAGE_RTL}}

    def test_legacy_snapshot_compatibility(self):
        pds.validate_core_variant({"source_git_blob": {"core/dual_issue_full_core.sv": "old"}}, "read_verilog -sv")
        pds.validate_core_variant(pds.core_variant(False) | {"source_git_blob": {}}, "read_verilog -sv")

    def test_five_stage_requires_metadata_define_and_full_closure(self):
        pds.validate_core_variant(self.five(), "read_verilog -sv -DDUAL_FIVE_STAGE src")
        cases = []
        for key, value in (("core_variant", "legacy"), ("core_pipeline", "legacy_nonuniform"), ("rtl_defines", [])):
            bad = self.five(); bad[key] = value; cases.append(bad)
        bad = self.five(); del bad["source_git_blob"][pds.FIVE_STAGE_RTL[-1]]; cases.append(bad)
        for bad in cases:
            with self.assertRaises(ValueError):
                pds.validate_core_variant(bad, "read_verilog -sv -DDUAL_FIVE_STAGE src")
        with self.assertRaisesRegex(ValueError, "synthesis define"):
            pds.validate_core_variant(self.five(), "read_verilog -sv src")
        with self.assertRaisesRegex(ValueError, "RTL closure"):
            pds.validate_core_variant(pds.core_variant(False) | {"source_git_blob": self.five()["source_git_blob"]}, "read_verilog -sv")

    def test_counter_policy_marks_legacy_mechanisms_not_applicable(self):
        policy = sim.FIVE_STAGE_COUNTER_SEMANTICS
        self.assertEqual(policy["core_pipeline"], 5)
        for key in ("young_issue0", "young_retire1", "completion_replace0", "completion_replace1"):
            self.assertIn(key, policy["legacy_only_not_applicable"])

    def test_five_stage_counter_partitions_keep_strict_parser(self):
        counters = {
            "cycles": 5, "total_cycles": 5, "issue0": 2, "issue1": 1, "retire0": 1, "retire1": 1,
            "primary_redirect": 1, "primary_lsu": 2, "primary_mdu": 0, "primary_csr": 0,
            "primary_fetch_wait": 0, "primary_issue_progress": 2, "primary_other_wait": 0,
            "lsu_primary_load": 1, "lsu_primary_store": 1, "lsu_state_idle": 0,
            "lsu_state_req_wait": 1, "lsu_state_wait_rsp": 1, "lsu_state_misaligned": 0, "lsu_state_unknown": 0,
            "lane1_pair_nonpairable": 0, "lane1_pair_raw": 1, "lane1_pair_waw": 0, "lane1_pair_other": 0,
            "lane1_blocked": 1, "lane1_offer": 2,
            "lane1_backend_redirect": 1, "lane1_backend_lsu": 1, "lane1_backend_mdu": 0,
            "lane1_backend_csr": 0, "lane1_backend_other": 0, "lane1_backend_blocked": 2,
        }
        classes = {key: 0 for key in (
            "lane1_lsu_lane0_nonalu", "lane1_lsu_lane0_hazard", "lane1_lsu_lane0_no_credit",
            "lane1_lsu_lane0_commit", "lane1_lsu_lane0_other", "lane1_lsu_lane0_mem",
            "lane1_lsu_lane0_mdu", "lane1_lsu_lane0_control", "lane1_lsu_lane0_csr_sys",
            "lane1_lsu_lane0_unknown")}
        classes["lane1_lsu_lane0_hazard"] = 1
        text = "PERF_JSON " + json.dumps(counters) + "\nPERF_DETAIL_JSON {}\nPERF_CLASS_JSON " + json.dumps(classes) + "\nSIM_WINDOW_DONE\n"
        self.assertEqual(sim.parse_performance_output(text, "window", 5)["ipc"], .4)
        for bad in (text.replace('"primary_lsu": 2', '"primary_lsu": 1'),
                    text.replace('"lane1_lsu_lane0_hazard": 1', '"lane1_lsu_lane0_hazard": 0')):
            with self.assertRaises(ValueError):
                sim.parse_performance_output(bad, "window", 5)

    def test_cli_exposes_explicit_opt_in(self):
        for script in ("run_dual_issue_pds_candidate.py", "run_dual_coremark_sim.py"):
            run = subprocess.run([sys.executable, str(Path(__file__).with_name(script)), "--help"], capture_output=True)
            self.assertEqual(run.returncode, 0)
            self.assertIn(b"--five-stage", run.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)

