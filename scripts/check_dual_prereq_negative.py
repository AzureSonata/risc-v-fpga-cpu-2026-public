#!/usr/bin/env python3
"""Check that dual-issue integration tests reject disabled M/error/target/load-pair paths."""
from pathlib import Path
import run_tests as suite
root=Path(__file__).resolve().parents[1]
source=(root/'rtl/core/dual_issue_full_core.sv').read_text(encoding='utf-8')
recipes=[
 ('mdu_start_removed','dual_mdu_matrix',[(".start_i(issue0 && d0_is_mdu)",".start_i(1'b0)")]),
 ('ifault_dropped','dual_ifault_matrix',[(".in0_fault(wf_q0_fault)",".in0_fault(1'b0)"),(".in1_fault(wf_q1_fault)",".in1_fault(1'b0)")]),
 ('misalign_ignored','dual_ifault_matrix',[("(|ex0_branch_pc[1:0])","1'b0")]),
 ('load_alu_pair_removed','dual_issue_full_load_alu',[(".s0_is_alu(d0_is_alu || d0_load_pairable)",".s0_is_alu(d0_is_alu)")]),
]
for label,test,changes in recipes:
 text=source
 for before,after in changes:
  if text.count(before)!=1:raise SystemExit('mutation anchor mismatch: '+before)
  text=text.replace(before,after)
 output=root/'build'/('dual_negative_'+label+'.sv');output.parent.mkdir(exist_ok=True)
 output.write_text(text,encoding='utf-8')
 record=next(row for row in suite.TESTS if row[0]==test)
 result=suite.run_test(*record,artifact_prefix='prereq_negative_',negctl_rtl={'dual_issue_full_core.sv':str(output)})
 if result['status']!='FAIL' or 'compil' in str(result.get('reason','')).lower():
  raise SystemExit('FAIL: mutation not caught by behavior: '+label+' '+str(result))
 print('CAUGHT: '+label)
print('PASS: 4/4 dual prerequisite mutations caught; not hardware proof')
