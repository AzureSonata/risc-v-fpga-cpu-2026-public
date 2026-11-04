#!/usr/bin/env python3
"""Run the K4 OpenEye core against EVERY k2 fixture and report byte-exactness.

Why: a single fixture passing could be luck.  The K3 target-parity work already
used 5 fixtures; here we use all 7 in-repo fixtures and require DW 4000/4000
and FC 4/4 byte-exact for each.

Usage (from repo root, after installing a standalone Icarus 13.0):
    python tools/kws/run_k4_all_fixtures.py --repo . --iverilog <dir with iverilog/vvp>
"""
import argparse
import os
import re
import shutil
import subprocess
import sys

RTL = [
    "rtl/accel/openeye_srdhm.sv",
    "rtl/accel/openeye_dw_conv.sv",
    "rtl/accel/openeye_fc.sv",
    "rtl/accel/openeye_top.sv",
]
TB = "verification/kws/k4/tb_openeye_k4.sv"


def run(cmd, cwd, timeout=1800):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                          encoding="utf-8", errors="replace", timeout=timeout)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--iverilog", required=True, help="dir containing iverilog.exe and vvp.exe")
    ap.add_argument("--fixtures", nargs="*", default=None)
    a = ap.parse_args()

    repo = os.path.abspath(a.repo)
    iv = os.path.join(a.iverilog, "iverilog.exe")
    vv = os.path.join(a.iverilog, "vvp.exe")
    for exe in (iv, vv):
        if not os.path.exists(exe):
            sys.exit("FAIL: missing %s" % exe)

    vecroot = os.path.join(repo, "verification", "kws", "k2", "vectors")
    fixtures = a.fixtures or sorted(d for d in os.listdir(vecroot)
                                    if os.path.isdir(os.path.join(vecroot, d)))
    if not fixtures:
        sys.exit("FAIL: no fixtures under %s" % vecroot)

    build = os.path.join(repo, "build", "k4")
    os.makedirs(build, exist_ok=True)

    print("iverilog: %s" % iv)
    print("fixtures: %d -> %s" % (len(fixtures), ", ".join(fixtures)))
    print()

    results = []
    for fx in fixtures:
        # Keep the sealed verification fixtures immutable. Recreate working hex
        # images under ignored build/ so reruns cannot rewrite golden evidence.
        vdir = os.path.join(build, "vectors_%s" % fx)
        # 1) 生成该 fixture 的 hex
        r = run([sys.executable, os.path.join(repo, "tools", "kws", "mkhex_k4.py"),
                 "--repo", repo, "--fixture", fx, "--out", vdir], repo)
        if r.returncode != 0:
            print("%-24s MKHEX FAIL: %s" % (fx, (r.stderr or r.stdout).strip()[:120]))
            results.append((fx, False, "mkhex fail"))
            continue

        # 2) 编译（用 VECDIR_STR 宏把路径写死；用**相对仓库根**的路径，
        #    避免仓库位于非 ASCII 路径时 Icarus 的字符串字面量被截断/乱码）
        vvp_out = os.path.join(build, "tb_%s.vvp" % fx)
        vdir_posix = os.path.relpath(vdir, repo).replace("\\", "/")
        r = run([iv, "-g2012", "-I", os.path.join(repo, "rtl", "accel"),
                 "-DVECDIR_STR=\"%s\"" % vdir_posix,
                 "-s", "tb_openeye_k4", "-o", vvp_out]
                + [os.path.join(repo, p) for p in RTL] + [os.path.join(repo, TB)], repo)
        if r.returncode != 0:
            print("%-24s COMPILE FAIL: %s" % (fx, (r.stderr or r.stdout).strip().splitlines()[-1][:120]))
            results.append((fx, False, "compile fail"))
            continue

        # 3) 运行
        r = run([vv, vvp_out], repo)
        out = (r.stdout or "") + (r.stderr or "")
        mdw = re.search(r"DW: (\d+) / (\d+) bytes match \((\d+) mismatch\)", out)
        mfc = re.search(r"FC: (\d+) / (\d+) bytes match \((\d+) mismatch\)", out)
        ok = r.returncode == 0 and mdw and mfc and mdw.group(3) == "0" and mfc.group(3) == "0"
        detail = "DW %s/%s FC %s/%s" % (mdw.group(1), mdw.group(2), mfc.group(1), mfc.group(2)) \
            if (mdw and mfc) else "no summary"
        print("%-24s %s  %s" % (fx, "PASS" if ok else "FAIL", detail))
        if not ok:
            for line in out.splitlines():
                if "first mismatch" in line or "FATAL" in line:
                    print("      %s" % line.strip()[:120])
        results.append((fx, ok, detail))

    npass = sum(1 for _, ok, _ in results if ok)
    print()
    print("=== SUMMARY: %d / %d fixtures byte-exact ===" % (npass, len(results)))
    if npass != len(results):
        print("FAIL [run_k4_all_fixtures]")
        sys.exit(1)
    print("PASS [run_k4_all_fixtures]")


if __name__ == "__main__":
    main()
