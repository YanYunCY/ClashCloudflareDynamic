#!/usr/bin/env python3
"""Launch the PowerShell health monitor without creating a console window."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parent
LAUNCH_LOG = ROOT / "logs" / "health_monitor_launcher.log"


def append_launch_error(message: str) -> None:
    try:
        LAUNCH_LOG.parent.mkdir(parents=True, exist_ok=True)
        with LAUNCH_LOG.open("a", encoding="utf-8") as stream:
            stream.write(message.rstrip() + "\n")
    except OSError:
        pass


def run_health_monitor(
    root: Path = ROOT,
    powershell_path: Path | None = None,
    timeout_seconds: float = 240.0,
) -> int:
    system_root = Path(os.environ.get("SystemRoot", r"C:\Windows"))
    powershell = powershell_path or (
        system_root
        / "System32"
        / "WindowsPowerShell"
        / "v1.0"
        / "powershell.exe"
    )
    monitor = root / "health_monitor.ps1"
    if not powershell.is_file():
        append_launch_error(f"PowerShell 不存在：{powershell}")
        return 2
    if not monitor.is_file():
        append_launch_error(f"健康监控脚本不存在：{monitor}")
        return 3

    command = [
        str(powershell),
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(monitor),
        "-Check",
    ]
    try:
        completed = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=max(1.0, float(timeout_seconds)),
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
    except subprocess.TimeoutExpired:
        append_launch_error("健康监控启动器等待超时")
        return 124
    except OSError as exc:
        append_launch_error(f"健康监控启动失败：{exc}")
        return 1
    return int(completed.returncode)


if __name__ == "__main__":
    raise SystemExit(run_health_monitor())
