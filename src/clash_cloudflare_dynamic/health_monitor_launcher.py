#!/usr/bin/env python3
"""Launch the PowerShell health monitor without creating a console window."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parent
LAUNCH_LOG = ROOT / "logs" / "health_monitor_launcher.log"
LAUNCH_LOG_MAX_BYTES = 1_000_000
LAUNCH_LOG_BACKUPS = 2


def rotate_launch_log_if_needed(
    path: Path = LAUNCH_LOG,
    max_bytes: int = LAUNCH_LOG_MAX_BYTES,
    backups: int = LAUNCH_LOG_BACKUPS,
) -> None:
    maximum = max(1_024, int(max_bytes))
    backup_count = max(1, min(20, int(backups)))
    if not path.is_file() or path.stat().st_size < maximum:
        return
    oldest = path.with_name(f"{path.name}.{backup_count}")
    oldest.unlink(missing_ok=True)
    for index in range(backup_count - 1, 0, -1):
        source = path.with_name(f"{path.name}.{index}")
        if source.is_file():
            os.replace(source, path.with_name(f"{path.name}.{index + 1}"))
    os.replace(path, path.with_name(f"{path.name}.1"))


def append_launch_error(message: str) -> None:
    try:
        LAUNCH_LOG.parent.mkdir(parents=True, exist_ok=True)
        rotate_launch_log_if_needed(LAUNCH_LOG)
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
