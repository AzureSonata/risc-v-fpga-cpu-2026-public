#!/usr/bin/env python3
"""Fail-closed integrity check for binary golden fixtures (K2/K3/K5).

Why this exists
---------------
`core.autocrlf=true` + `* text=auto` treated a `.bin` golden containing one 0x0A
byte as text: the committed blob was correct (4000 B) but the Windows working
copy was written back as 4001 B (CR inserted at offset 958). Any tool reading the
worktree (K4 RTL comparison, K5 tests, a reviewer) then saw a one-byte shift.

This checker compares the working-tree bytes with the blob at HEAD byte for byte,
and re-verifies each tensor file against the sha256 recorded in golden.json.
It fails red if any fixture differs, so the corruption cannot silently return.

Usage:
    python tools/kws/check_binary_fixtures.py
    python tools/kws/check_binary_fixtures.py --json-out verification/kws/fixture_integrity.json
    python tools/kws/check_binary_fixtures.py --self-test
Exit codes: 0 = all match, 1 = mismatch, 2 = setup error.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

BINARY_SUFFIXES = (".bin", ".s16le", ".mem", ".zst", ".elf", ".hex", ".coe", ".pcm")
ROOTS = ("verification/kws", "fpga/kws/generated")

# 这些后缀是**构建产物**，不是"应当逐字节等于 HEAD"的 golden。
# `tools/kws/build_k5_firmware.py` 每次跑都会重新链接并把结果 `shutil.copyfile` 到
# `verification/kws/k5/firmware/kws_fw.elf`；同一份源码连续两次构建 ELF 内容应当相同，
# 但**只要输入（源码/链接脚本/flags）变过，字节必然变**（2026-10-27 实测 11860 → 11856 B，
# 差异是 ELF 段偏移整体平移 4 B）。
# ⚠️ 坑位：把 `.elf` 塞进"worktree == HEAD"会变成**周期性假红**——每次重构建都红一次，
#    而它根本不是 corruption。对它只保留两道门：① 属性门（必须 `-text`）；
#    ② `firmware_build_manifest.json` 的 `elf_sha256` 与磁盘自洽（由构建脚本自己保证）。
#    （LESSON-009 §追加 / 日志 2026-10-26-06 §13.6）
REBUILT_SUFFIXES = (".elf",)


def git(repo: Path, *args: str, **kw) -> bytes:
    """留一条不打死的路：`check=False` 时失败返回 None，供"先试 HEAD 再回落 index"用。

    旧行为（失败即 SystemExit）对绝大多数调用是对的——命令跑不出来说明环境有问题，
    继续跑只会得到假结果。只有"这个文件可能还不该存在"这一种情况需要软失败。
    """
    p = subprocess.run(["git", "-C", str(repo)] + list(args), capture_output=True)
    if p.returncode != 0:
        if kw.get("check", True):
            raise SystemExit(f"git {' '.join(args)} failed: "
                             f"{p.stderr.decode('utf-8', 'replace')[:400]}")
        return None
    return p.stdout


def tracked_binaries(repo: Path) -> list[str]:
    out = git(repo, "ls-files", "-z").split(b"\0")
    files = []
    for raw in out:
        if not raw:
            continue
        rel = raw.decode("utf-8")
        if rel.endswith(BINARY_SUFFIXES) and any(rel.startswith(r + "/") for r in ROOTS):
            files.append(rel)
    return sorted(files)


def compare(name: str, work: bytes, blob: bytes) -> dict:
    ok = work == blob
    return {"file": name, "ok": ok, "work_bytes": len(work), "blob_bytes": len(blob),
            "work_sha256": hashlib.sha256(work).hexdigest(),
            "blob_sha256": hashlib.sha256(blob).hexdigest(),
            "detail": "identical" if ok else "worktree differs from HEAD blob (EOL damage?)"}


def judge_attrs(pairs: list[tuple[str, str]]) -> list[dict]:
    """pairs = [(probe_path, check-attr 报出的 text 取值)]；返回不通过项。

    ⚠️ 坑位：只靠"已入库文件逐个比字节"挡不住**新后缀**。2026-10-26 新增的 `.pcm` 夹具
    落在 `verification/kws/** text eol=lf` 的覆盖区里，checkout 会把 PCM 里的 `0D 0A`
    压成 `0A`（32,000 B 变短、`oov_manifest.json` 的 sha256 全部失配），
    而当时 `BINARY_SUFFIXES` 里没有 `.pcm` ⇒ 这个守卫**根本看不见它**。
    正确做法：后缀一进 `BINARY_SUFFIXES`，就必须在 `.gitattributes` 里有 `-text`
    （`-text` 要写在 `text eol=lf` 块**之后**，gitattributes 是 last-match-wins）。
    （LESSON-009 §追加 / 日志 2026-10-26-06 §13）
    """
    bad = []
    for probe, val in pairs:
        if val != "unset":
            bad.append({"probe": probe, "text_attr": val, "ok": False,
                        "detail": "该后缀在 .gitattributes 里不是 `-text` ⇒ checkout 会改写字节"})
    return bad


def attr_guard(repo: Path) -> list[dict]:
    """对 `BINARY_SUFFIXES` 逐个后缀问 git：`text` 属性是不是 unset。"""
    pairs = []
    for suf in BINARY_SUFFIXES:
        probe = f"verification/kws/_attr_probe{suf}"
        raw = git(repo, "check-attr", "text", "--", probe).decode("utf-8", "replace").strip()
        pairs.append((probe, raw.rsplit(":", 1)[-1].strip()))
    return judge_attrs(pairs)


def check(repo: Path) -> dict:
    results = []
    rebuilt = []
    for rel in tracked_binaries(repo):
        p = repo / rel
        if not p.is_file():
            results.append({"file": rel, "ok": False, "detail": "missing in worktree"})
            continue
        # 先试 HEAD；新入库的文件 HEAD 里还没有（"exists on disk, but not in 'HEAD'"），
        # 此时回落到 **index blob**（`git cat-file blob :<path>`）。
        # 不回落的话，每加一个新二进制夹具就会让整个检查中止——字节门反而失效。
        blob = git(repo, "cat-file", "blob", "HEAD:%s" % rel, check=False)
        if blob is None:
            blob = git(repo, "cat-file", "blob", ":%s" % rel, check=False)
        if blob is None:
            results.append({"file": rel, "ok": False,
                            "detail": "neither HEAD nor index has a blob for it"})
            continue
        row = compare(rel, p.read_bytes(), blob)
        if rel.endswith(REBUILT_SUFFIXES):
            # 构建产物：与 HEAD 不同是正常的（重构建），只记录不判负；属性门另算。
            row["rebuilt_artifact"] = True
            rebuilt.append(row)
            continue
        results.append(row)

    # golden.json records each tensor's sha256; verify it against the worktree file.
    meta_bad = []
    for gj in sorted((repo / "verification/kws/k2/vectors").glob("*/golden.json")):
        g = json.loads(gj.read_text(encoding="utf-8"))
        for key, t in g.get("tensors", {}).items():
            f = gj.parent / t["file"]
            if not f.is_file():
                meta_bad.append({"file": str(f.relative_to(repo)), "detail": "missing"})
                continue
            h = hashlib.sha256(f.read_bytes()).hexdigest()
            if h != t.get("sha256"):
                meta_bad.append({"file": str(f.relative_to(repo)), "detail": "sha256 != golden.json",
                                 "want": t.get("sha256"), "have": h})

    attr_bad = attr_guard(repo)
    failed = [r for r in results if not r["ok"]] + meta_bad + attr_bad
    return {"check_count": len(results), "golden_meta_count": sum(
                len(json.loads(g.read_text(encoding="utf-8")).get("tensors", {}))
                for g in (repo / "verification/kws/k2/vectors").glob("*/golden.json")),
            "attr_guard_count": len(BINARY_SUFFIXES),
            "rebuilt_count": len(rebuilt),
            "rebuilt_differs_from_head": sum(0 if r["ok"] else 1 for r in rebuilt),
            "failed": failed, "verdict": "PASS" if not failed else "FAIL", "files": results,
            "attr_guards": attr_bad, "rebuilt": rebuilt}


def self_test() -> int:
    blob = b"ABC\nDEF\x00\xff"          # contains LF but is binary
    good = compare("copy", blob, blob)
    bad = compare("crlf", blob.replace(b"\n", b"\r\n"), blob)
    no_op = good["ok"] is True and bad["ok"] is False
    print(f"{'PASS' if no_op else 'FAIL'}  self-test: identical bytes -> ok, CRLF-expanded bytes -> mismatch")
    # 注入必红：把 `text` 属性改回 set（等价于有人新增了后缀但忘了 `-text`）必须被抓到
    attr_bad = judge_attrs([("x.pcm", "lf"), ("y.bin", "unset")])
    attr_ok = len(attr_bad) == 1 and attr_bad[0]["probe"] == "x.pcm"
    print(f"{'PASS' if attr_ok else 'FAIL'}  self-test: text=lf 的后缀必须被判红、text=unset 的放行")
    return 0 if (no_op and attr_ok) else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    ap.add_argument("--json-out", type=Path)
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    repo = args.repo.resolve()
    if not (repo / ".git").exists() and not (repo / "HEAD").exists():
        print(f"SETUP-FAIL: not a git worktree: {repo}", file=sys.stderr)
        return 2
    res = check(repo)
    for r in res["files"]:
        if not r["ok"]:
            print(f"FAIL  {r['file']}  work={r['work_bytes']}B blob={r['blob_bytes']}B")
    for m in res["failed"]:
        if "want" in m:
            print(f"FAIL  {m['file']}  sha256 want={m['want'][:12]}… have={m['have'][:12]}…")
        elif m in res.get("attr_guards", []):
            print(f"FAIL  {m['probe']}  text={m['text_attr']}  {m['detail']}")
        elif m not in res["files"]:
            print(f"FAIL  {m}")
    print(f"{res['verdict']}: {res['check_count']} binary files + "
          f"{res['golden_meta_count']} golden tensors + "
          f"{res.get('attr_guard_count', 0)} attributes, {len(res['failed'])} failed"
          f"  [rebuilt artifacts: {res.get('rebuilt_count', 0)}, "
          f"{res.get('rebuilt_differs_from_head', 0)} differ from HEAD by design]")
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(res, ensure_ascii=False, indent=2) + "\n",
                                 encoding="utf-8", newline="\n")
    return 0 if res["verdict"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
