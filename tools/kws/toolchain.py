"""统一工具路径解析：环境变量 → 已知绝对路径 → PATH，并做版本校验。

为什么需要它
------------
仓库里多个脚本把工具路径写死成 `C:/msys64/ucrt64/bin/...`。换一台机器（本机就没有
`C:/msys64`）时，脚本不是给出 FAIL，而是在 `subprocess.run` 处抛
`FileNotFoundError` —— traceback 与 FAIL 在交付里含义完全不同：
FAIL 是判据输出，traceback 是脚本自己坏了。

本模块的约定
------------
1. 顺序：显式环境变量 → 调用方给的候选 → 本模块内置候选 → PATH。
2. **显式环境变量一旦设置就必须有效**：路径不存在或版本不符时直接报错，
   不回退到别的路径（否则"我指定了工具"和"实际用的工具"会不一致）。
3. 版本校验用工具自身的版本命令；**校验不过的候选直接跳过**。
   典型场景：PATH 上有 Icarus 11.0，而本项目基线是 13.0，不能静默用 11.0 跑出另一套数字。
4. 找不到工具时由 `resolve_or_exit` 打印 `NOT_RUN: ...` 并 **exit 2**，不抛 traceback。

用法
----
    from toolchain import resolve_or_exit, describe
    clang = resolve_or_exit("KWS_CLANG", "clang", version_args=("--version",))
    iverilog = resolve_or_exit("KWS_IVERILOG", "iverilog", version_marker="13.0")

环境变量
--------
KWS_CLANG / KWS_IVERILOG / KWS_VVP / KWS_QEMU
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class ToolNotFound(RuntimeError):
    """工具不可用（缺失或版本不符）。"""

    def __init__(self, env_name: str, exe_name: str, reason: str, tried: list[str]):
        self.env_name = env_name
        self.exe_name = exe_name
        self.reason = reason
        self.tried = tried
        super().__init__(reason)


# 只登记**本仓库出现过**的路径；不含别人机器上的私有路径。
KNOWN_CANDIDATES: dict[str, tuple[str, ...]] = {
    "clang": (
        r"C:/msys64/ucrt64/bin/clang.exe",
        r"D:/紫光同创/tools/iverilog13-independent/ucrt64/bin/clang.exe",
    ),
    "iverilog": (
        r"D:/紫光同创/tools/iverilog13-independent/ucrt64/bin/iverilog.exe",
        r"D:/qtt/tools/iverilog13-independent/ucrt64/bin/iverilog.exe",
        r"C:/msys64/ucrt64/bin/iverilog.exe",
    ),
    "vvp": (
        r"D:/紫光同创/tools/iverilog13-independent/ucrt64/bin/vvp.exe",
        r"D:/qtt/tools/iverilog13-independent/ucrt64/bin/vvp.exe",
        r"C:/msys64/ucrt64/bin/vvp.exe",
    ),
    "qemu-system-riscv32": (
        r"C:/msys64/ucrt64/bin/qemu-system-riscv32.exe",
    ),
}

DEFAULT_VERSION_ARGS: dict[str, tuple[str, ...]] = {
    "iverilog": ("-V",),
    "vvp": ("-V",),
    "clang": ("--version",),
    "qemu-system-riscv32": ("--version",),
}


def version_text(path: Path, version_args: tuple[str, ...] | None = None) -> str:
    """返回工具版本输出（失败时返回可读说明，不抛异常）。"""
    args = version_args if version_args is not None else ("-V",)
    try:
        p = subprocess.run(
            [str(path), *args],
            capture_output=True,
            timeout=20,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return f"<无法执行: {exc}>"
    raw = (p.stdout or b"") + (p.stderr or b"")
    return raw.decode("utf-8", "replace").strip()


def describe(path: Path, version_args: tuple[str, ...] | None = None) -> str:
    """版本输出的第一行，用于报告 JSON 与日志。"""
    text = version_text(path, version_args)
    return text.splitlines()[0].strip() if text else "<无版本输出>"


def _usable(
    path: Path,
    version_marker: str | None,
    version_args: tuple[str, ...] | None,
) -> tuple[bool, str]:
    if not path.is_file():
        return False, "文件不存在"
    if version_marker is None:
        return True, ""
    text = version_text(path, version_args)
    if version_marker not in text:
        first = text.splitlines()[0] if text else "<无版本输出>"
        return False, f"版本不符（要求含 '{version_marker}'，实测 '{first}'）"
    return True, ""


def try_resolve(
    env_name: str,
    exe_name: str,
    *,
    version_marker: str | None = None,
    version_args: tuple[str, ...] | None = None,
    extra_candidates: tuple[str, ...] = (),
) -> Path | None:
    """解析工具路径；找不到返回 None。环境变量无效时抛 ToolNotFound。"""
    if version_args is None:
        version_args = DEFAULT_VERSION_ARGS.get(exe_name)

    tried: list[str] = []

    explicit = os.environ.get(env_name)
    if explicit:
        p = Path(explicit)
        tried.append(f"${env_name}={p}")
        ok, why = _usable(p, version_marker, version_args)
        if not ok:
            raise ToolNotFound(
                env_name, exe_name,
                f"环境变量 {env_name} 指向的工具不可用：{why}",
                tried,
            )
        return p

    candidates = [Path(c) for c in extra_candidates]
    candidates += [Path(c) for c in KNOWN_CANDIDATES.get(exe_name, ())]
    on_path = shutil.which(exe_name)
    if on_path:
        candidates.append(Path(on_path))

    for p in candidates:
        ok, why = _usable(p, version_marker, version_args)
        tried.append(f"{p}" + ("" if ok else f"（{why}）"))
        if ok:
            return p

    return None


def resolve_or_exit(
    env_name: str,
    exe_name: str,
    *,
    version_marker: str | None = None,
    version_args: tuple[str, ...] | None = None,
    extra_candidates: tuple[str, ...] = (),
    purpose: str = "",
) -> Path:
    """解析工具路径；不可用时打印 NOT_RUN 并 exit 2。"""
    label = purpose or exe_name
    try:
        path = try_resolve(
            env_name, exe_name,
            version_marker=version_marker,
            version_args=version_args,
            extra_candidates=extra_candidates,
        )
    except ToolNotFound as exc:
        print(f"NOT_RUN: {label} 不可用 —— {exc.reason}", file=sys.stderr)
        for item in exc.tried:
            print(f"         已尝试: {item}", file=sys.stderr)
        print(f"         请设置 {env_name}=<可执行文件绝对路径>", file=sys.stderr)
        raise SystemExit(2) from None

    if path is None:
        print(f"NOT_RUN: {label} 不可用 —— 未找到可执行文件", file=sys.stderr)
        for c in list(extra_candidates) + list(KNOWN_CANDIDATES.get(exe_name, ())):
            print(f"         已尝试: {c}", file=sys.stderr)
        print(f"         请设置 {env_name}=<可执行文件绝对路径>", file=sys.stderr)
        raise SystemExit(2)

    return path


def record(path: Path, version_args: tuple[str, ...] | None = None) -> dict[str, str]:
    """写进报告 JSON 的工具记录：真实路径 + 版本首行。"""
    return {"path": str(path), "version": describe(path, version_args)}
