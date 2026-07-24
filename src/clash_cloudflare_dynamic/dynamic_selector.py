#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Cloudflare 动态发现 + Clash/Mihomo 自动优选

每 30 分钟：
1. 从 Cloudflare 官方 IPv4 网段随机发现新候选；
2. 按节点模板配置的端口执行 TCP 初筛；
3. 写入“Cloudflare发现池”并让 Mihomo 热更新 provider；
4. 用用户真实的 Mihomo 节点协议与传输参数测试代理链路延迟；
5. 对前几名通过 Clash 隧道执行小文件下载测速；
6. 将通过测试的优质 IP 提升到“Cloudflare正式池”；
7. 每个候选连续测试 3 次取平均；在平均速度达到本轮最高平均速度 95% 的高速组中，选择平均延迟最低的节点。

仅从 Cloudflare 官方网段取样，只测试节点模板指定的单个 TCP 端口，
不扫描用户未选择的其他网络或端口。
"""

from __future__ import annotations

import argparse
import concurrent.futures
import copy
import csv
import datetime as dt
import html
import ipaddress
import json
import math
import os
import random
import shutil
import socket
import sqlite3
import statistics
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from contextlib import closing
from pathlib import Path
from typing import Any

try:
    from .storage_maintenance import (
        cleanup_managed_backups,
        cleanup_root_backup_files,
        connect_sqlite_with_recovery,
    )
except ImportError:  # Flat deployment bundle installed on Windows.
    from storage_maintenance import (
        cleanup_managed_backups,
        cleanup_root_backup_files,
        connect_sqlite_with_recovery,
    )

MODULE_DIR = Path(__file__).resolve().parent
REPOSITORY_ROOT = MODULE_DIR.parents[1]
IS_SOURCE_LAYOUT = (
    (REPOSITORY_ROOT / "scripts" / "windows").is_dir()
    and (REPOSITORY_ROOT / "config").is_dir()
)
ROOT = REPOSITORY_ROOT if IS_SOURCE_LAYOUT else MODULE_DIR
SETTINGS_PATH = ROOT / "settings.json"
TEMPLATE_PATH = ROOT / "node_template.json"
SEEDS_PATH = (
    REPOSITORY_ROOT / "config" / "seed_ips.txt"
    if IS_SOURCE_LAYOUT
    else ROOT / "seed_ips.txt"
)
VERGE_HOME = Path(os.environ.get("APPDATA", str(ROOT))) / "io.github.clash-verge-rev.clash-verge-rev"
PROVIDER_DIR = VERGE_HOME / "providers" / "ClashCloudflareDynamic"
ACTIVE_PROVIDER_PATH = PROVIDER_DIR / "cloudflare_active.yaml"
DISCOVERY_PROVIDER_PATH = PROVIDER_DIR / "cloudflare_discovery.yaml"
STATE_PATH = ROOT / "state.json"
RANGES_CACHE_PATH = ROOT / "cloudflare_ranges_cache.txt"
LOG_DIR = ROOT / "logs"
RUN_LOG = LOG_DIR / "dynamic_selector.log"
LATEST_CSV = LOG_DIR / "latest.csv"
DISCOVERY_CSV = LOG_DIR / "discovery_tcp.csv"
SPEED_PROBE_CSV = LOG_DIR / "speed_probe.csv"
DECISION_JSON = LOG_DIR / "last_decision.json"
LIGHT_RUN_STATUS_PATH = LOG_DIR / "last_run_light.json"
DEEP_RUN_STATUS_PATH = LOG_DIR / "last_run_deep.json"
BEST_IPS_PATH = LOG_DIR / "best_ips.txt"
HISTORY_PATH = LOG_DIR / "history.csv"
RUN_LOCK_PATH = ROOT / "dynamic_selector.lock"
DISCOVERY_DB_PATH = ROOT / "discovery_history.sqlite3"
NOTIFY_SCRIPT_PATH = (
    REPOSITORY_ROOT / "scripts" / "windows" / "notify_windows.ps1"
    if IS_SOURCE_LAYOUT
    else ROOT / "notify_windows.ps1"
)
NOTIFICATION_REPORT_DIR = LOG_DIR / "notification_reports"
BACKUP_DIR = ROOT / "backups"
NOTIFICATION_REPORT_RETENTION_DAYS = 30.0
NOTIFICATION_REPORT_MAX_FILES = 100
NOTIFICATION_DELIVERY_LOG_MAX_BYTES = 1_000_000
NOTIFICATION_DELIVERY_LOG_BACKUPS = 2

RUN_LOG_MAX_BYTES = 5_000_000
RUN_LOG_BACKUPS = 3
UDP_ONLY_PROTOCOLS = {"hysteria", "hysteria2", "tuic", "wireguard"}

STAGE_LABELS = {
    "startup": "启动与前台等待",
    "maintenance": "维护与清理",
    "candidate_generation": "候选生成",
    "tcp_probe": "TCP 初筛",
    "discovery_provider": "发现池更新",
    "proxy_delay": "代理链路延迟",
    "speed_probe": "速度粗测",
    "formal_speed": "正式测速",
    "active_provider": "正式池更新",
    "decision": "决策",
}

FALLBACK_RANGES = [
    "173.245.48.0/20",
    "103.21.244.0/22",
    "103.22.200.0/22",
    "103.31.4.0/22",
    "141.101.64.0/18",
    "108.162.192.0/18",
    "190.93.240.0/20",
    "188.114.96.0/20",
    "197.234.240.0/22",
    "198.41.128.0/17",
    "162.158.0.0/15",
    "104.16.0.0/13",
    "104.24.0.0/14",
    "172.64.0.0/13",
    "131.0.72.0/22",
]


def now() -> dt.datetime:
    return dt.datetime.now().astimezone()


def now_iso() -> str:
    return now().isoformat(timespec="seconds")


class StageTimer:
    """Accumulate wall-clock durations for named scan stages."""

    def __init__(self, clock: Any | None = None) -> None:
        self._clock = clock or time.monotonic
        self._current: str | None = None
        self._started = float(self._clock())
        self._durations: dict[str, float] = {}

    def start(self, name: str) -> None:
        stamp = float(self._clock())
        self._record(stamp)
        self._current = str(name)
        self._started = stamp

    def finish(self) -> dict[str, float]:
        self._record(float(self._clock()))
        self._current = None
        return {
            name: round(seconds, 3)
            for name, seconds in self._durations.items()
        }

    def _record(self, stamp: float) -> None:
        if self._current is not None:
            elapsed = max(0.0, stamp - self._started)
            self._durations[self._current] = (
                self._durations.get(self._current, 0.0) + elapsed
            )
        self._started = stamp


def configure_runtime_limits(settings: dict[str, Any]) -> None:
    global RUN_LOG_MAX_BYTES, RUN_LOG_BACKUPS
    global NOTIFICATION_REPORT_MAX_FILES
    global NOTIFICATION_DELIVERY_LOG_MAX_BYTES
    global NOTIFICATION_DELIVERY_LOG_BACKUPS
    RUN_LOG_MAX_BYTES = max(
        100_000, int(settings.get("run_log_max_bytes", 5_000_000))
    )
    RUN_LOG_BACKUPS = max(
        1, min(20, int(settings.get("run_log_backups", 3)))
    )
    NOTIFICATION_REPORT_MAX_FILES = max(
        1,
        min(10_000, int(settings.get("notification_report_max_files", 100))),
    )
    NOTIFICATION_DELIVERY_LOG_MAX_BYTES = max(
        64_000,
        int(settings.get("notification_delivery_log_max_bytes", 1_000_000)),
    )
    NOTIFICATION_DELIVERY_LOG_BACKUPS = max(
        1,
        min(
            20,
            int(settings.get("notification_delivery_log_backups", 2)),
        ),
    )


def rotate_run_log_if_needed() -> None:
    if not RUN_LOG.exists() or RUN_LOG.stat().st_size < RUN_LOG_MAX_BYTES:
        return
    oldest = RUN_LOG.with_name(f"{RUN_LOG.name}.{RUN_LOG_BACKUPS}")
    if oldest.exists():
        oldest.unlink()
    for index in range(RUN_LOG_BACKUPS - 1, 0, -1):
        source = RUN_LOG.with_name(f"{RUN_LOG.name}.{index}")
        if source.exists():
            os.replace(
                source,
                RUN_LOG.with_name(f"{RUN_LOG.name}.{index + 1}"),
            )
    os.replace(RUN_LOG, RUN_LOG.with_name(f"{RUN_LOG.name}.1"))


def log(message: str) -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    rotate_run_log_if_needed()
    line = f"[{now_iso()}] {message}"
    if sys.stdout is not None:
        try:
            print(line)
        except (OSError, ValueError):
            pass
    with RUN_LOG.open("a", encoding="utf-8") as f:
        f.write(line + "\n")


def set_low_process_priority() -> None:
    if os.name != "nt":
        return
    try:
        import ctypes
        from ctypes import wintypes

        below_normal_priority_class = 0x00004000
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.GetCurrentProcess.restype = wintypes.HANDLE
        kernel32.SetPriorityClass.argtypes = (
            wintypes.HANDLE,
            wintypes.DWORD,
        )
        kernel32.SetPriorityClass.restype = wintypes.BOOL
        handle = kernel32.GetCurrentProcess()
        if not kernel32.SetPriorityClass(handle, below_normal_priority_class):
            raise ctypes.WinError(ctypes.get_last_error())
    except (AttributeError, OSError):
        pass


def get_user_idle_seconds() -> float | None:
    if os.name != "nt":
        return None
    try:
        import ctypes
        from ctypes import wintypes

        class LASTINPUTINFO(ctypes.Structure):
            _fields_ = [
                ("cbSize", wintypes.UINT),
                ("dwTime", wintypes.DWORD),
            ]

        user32 = ctypes.WinDLL("user32", use_last_error=True)
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        user32.GetLastInputInfo.argtypes = (ctypes.POINTER(LASTINPUTINFO),)
        user32.GetLastInputInfo.restype = wintypes.BOOL
        kernel32.GetTickCount.restype = wintypes.DWORD
        info = LASTINPUTINFO()
        info.cbSize = ctypes.sizeof(info)
        if not user32.GetLastInputInfo(ctypes.byref(info)):
            return None
        elapsed_ms = (kernel32.GetTickCount() - info.dwTime) & 0xFFFFFFFF
        return elapsed_ms / 1000.0
    except (AttributeError, OSError):
        return None


def is_foreground_fullscreen() -> bool:
    if os.name != "nt":
        return False
    try:
        import ctypes
        from ctypes import wintypes

        class RECT(ctypes.Structure):
            _fields_ = [
                ("left", wintypes.LONG),
                ("top", wintypes.LONG),
                ("right", wintypes.LONG),
                ("bottom", wintypes.LONG),
            ]

        class MONITORINFO(ctypes.Structure):
            _fields_ = [
                ("cbSize", wintypes.DWORD),
                ("rcMonitor", RECT),
                ("rcWork", RECT),
                ("dwFlags", wintypes.DWORD),
            ]

        user32 = ctypes.WinDLL("user32", use_last_error=True)
        user32.GetForegroundWindow.restype = wintypes.HWND
        user32.GetShellWindow.restype = wintypes.HWND
        user32.IsIconic.argtypes = (wintypes.HWND,)
        user32.IsIconic.restype = wintypes.BOOL
        user32.GetWindowRect.argtypes = (wintypes.HWND, ctypes.POINTER(RECT))
        user32.GetWindowRect.restype = wintypes.BOOL
        user32.MonitorFromWindow.argtypes = (wintypes.HWND, wintypes.DWORD)
        user32.MonitorFromWindow.restype = wintypes.HANDLE
        user32.GetMonitorInfoW.argtypes = (
            wintypes.HANDLE,
            ctypes.POINTER(MONITORINFO),
        )
        user32.GetMonitorInfoW.restype = wintypes.BOOL

        window = user32.GetForegroundWindow()
        if not window or window == user32.GetShellWindow() or user32.IsIconic(window):
            return False
        rect = RECT()
        monitor_info = MONITORINFO()
        monitor_info.cbSize = ctypes.sizeof(monitor_info)
        monitor = user32.MonitorFromWindow(window, 2)
        if not monitor or not user32.GetWindowRect(window, ctypes.byref(rect)):
            return False
        if not user32.GetMonitorInfoW(monitor, ctypes.byref(monitor_info)):
            return False
        screen = monitor_info.rcMonitor
        tolerance = 2
        return (
            rect.left <= screen.left + tolerance
            and rect.top <= screen.top + tolerance
            and rect.right >= screen.right - tolerance
            and rect.bottom >= screen.bottom - tolerance
        )
    except (AttributeError, OSError):
        return False


def foreground_busy_reason(recent_input_seconds: float) -> str | None:
    if is_foreground_fullscreen():
        return "检测到前台全屏程序"
    idle_seconds = get_user_idle_seconds()
    if idle_seconds is not None and idle_seconds < max(0.0, recent_input_seconds):
        return f"检测到最近 {idle_seconds:.0f} 秒仍有键盘或鼠标输入"
    return None


def should_defer_deep_scan(
    quick: bool, foreground_busy: bool, enabled: bool = True
) -> bool:
    return bool(enabled and not quick and foreground_busy)


def defer_deep_scan_if_busy(
    settings: dict[str, Any], quick: bool
) -> int | None:
    enabled = bool(settings.get("deep_scan_busy_deferral_enabled", True))
    recent_seconds = max(
        0.0, float(settings.get("deep_scan_recent_input_seconds", 120))
    )
    deferral_minutes = min(
        60.0,
        max(1.0, float(settings.get("deep_scan_deferral_minutes", 15))),
    )
    max_deferrals = max(
        0, int(settings.get("deep_scan_max_deferrals", 4))
    )
    if max_deferrals and deferral_minutes * max_deferrals > 60:
        max_deferrals = max(1, int(60 // deferral_minutes))
    if quick or not enabled or max_deferrals == 0:
        return 0

    for deferral_index in range(max_deferrals):
        reason = foreground_busy_reason(recent_seconds)
        if not should_defer_deep_scan(quick, reason is not None, enabled):
            return deferral_index
        log(
            f"{reason}，深度扫描延后 {deferral_minutes:g} 分钟 "
            f"({deferral_index + 1}/{max_deferrals})"
        )
        if deferral_index == 0:
            send_windows_notification(
                "Clash 深度扫描：已延后",
                f"{reason}\n将在 {deferral_minutes:g} 分钟后重新检查，"
                f"最多延后 {max_deferrals} 次。轻量扫描不受影响。",
            )
        time.sleep(deferral_minutes * 60)

    reason = foreground_busy_reason(recent_seconds)
    if reason:
        message = (
            f"{reason}\n已累计延后 {max_deferrals} 次，"
            "为避免影响前台，本轮深度扫描已跳过。"
        )
        log(message.replace("\n", " "))
        send_windows_notification("Clash 深度扫描：本轮已跳过", message)
        return None
    log("深度扫描已达到最大延后次数，前台已空闲，本轮继续执行")
    return max_deferrals


def notification_report_path_is_safe(path: Path) -> bool:
    try:
        resolved = path.resolve(strict=True)
        resolved.relative_to(NOTIFICATION_REPORT_DIR.resolve(strict=True))
    except (OSError, ValueError):
        return False
    return resolved.is_file() and resolved.suffix.lower() == ".html"


def send_windows_notification(
    title: str,
    message: str,
    details_path: Path | None = None,
) -> bool:
    if os.name != "nt" or not NOTIFY_SCRIPT_PATH.is_file():
        return False
    powershell = shutil.which("powershell.exe") or shutil.which("powershell")
    if not powershell:
        return False
    cmd = [
        powershell,
        "-NoProfile",
        "-NonInteractive",
        "-WindowStyle",
        "Hidden",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(NOTIFY_SCRIPT_PATH),
        "-Title",
        title[:120],
        "-Message",
        message[:600],
        "-RetentionDays",
        str(NOTIFICATION_REPORT_RETENTION_DAYS),
        "-MaxReportFiles",
        str(NOTIFICATION_REPORT_MAX_FILES),
        "-DeliveryLogMaxBytes",
        str(NOTIFICATION_DELIVERY_LOG_MAX_BYTES),
        "-DeliveryLogBackups",
        str(NOTIFICATION_DELIVERY_LOG_BACKUPS),
    ]
    if details_path is not None:
        if notification_report_path_is_safe(details_path):
            cmd.extend(["-DetailsPath", str(details_path.resolve())])
        else:
            log(f"通知详情路径无效，改用简版报告：{details_path}")
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=15,
            check=False,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        log(f"Windows 通知发送失败：{exc}")
        return False
    if proc.returncode != 0:
        detail = proc.stderr.strip() or f"exit {proc.returncode}"
        log(f"Windows 通知发送失败：{detail}")
        return False
    return True


def cleanup_notification_reports(
    retention_days: Any = 30,
    maximum_count: Any = 100,
    protected_path: Path | None = None,
) -> int:
    try:
        days = min(3650.0, max(1.0, float(retention_days)))
    except (TypeError, ValueError):
        days = 30.0
    try:
        limit = min(10_000, max(1, int(maximum_count)))
    except (TypeError, ValueError, OverflowError):
        limit = 100
    if not NOTIFICATION_REPORT_DIR.is_dir():
        return 0

    cutoff = now().timestamp() - days * 86400
    deleted = 0
    retained: list[tuple[float, str, Path]] = []
    for path in NOTIFICATION_REPORT_DIR.glob("notification_*.html"):
        try:
            if not path.is_file():
                continue
            modified = path.stat().st_mtime
            if modified < cutoff:
                path.unlink()
                deleted += 1
            else:
                retained.append((modified, path.name, path))
        except OSError as exc:
            log(f"清理过期通知报告失败：{path.name}：{exc}")

    excess = max(0, len(retained) - limit)
    deletion_candidates = [
        item for item in sorted(retained) if item[2] != protected_path
    ]
    for _, _, path in deletion_candidates[:excess]:
        try:
            path.unlink()
            deleted += 1
        except OSError as exc:
            log(f"清理超额通知报告失败：{path.name}：{exc}")
    return deleted


def _html_text(value: Any) -> str:
    if value is None or value == "":
        return "-"
    return html.escape(str(value), quote=True)


def _html_number(value: Any, digits: int = 2) -> str:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return "-"
    return f"{number:.{digits}f}" if math.isfinite(number) else "-"


def _html_percent(value: Any, digits: int = 1) -> str:
    try:
        number = float(value) * 100
    except (TypeError, ValueError):
        return "-"
    return f"{number:.{digits}f}%" if math.isfinite(number) else "-"


def _nonnegative_count(value: Any) -> int:
    try:
        return max(0, int(value))
    except (TypeError, ValueError, OverflowError):
        return 0


def has_detailed_scan_summary(summary: dict[str, Any] | None) -> bool:
    if not isinstance(summary, dict):
        return False
    if _nonnegative_count(summary.get("summary_schema_version")) >= 2:
        return True
    return any(
        key in summary
        for key in (
            "tcp_failed_count",
            "discovery_not_selected_count",
            "proxy_failed_count",
            "speed_probe_attempted_count",
            "speed_probe_passed_count",
            "formal_attempted_count",
            "formal_passed_count",
        )
    )


def normalize_scan_summary_counts(summary: dict[str, Any] | None) -> dict[str, int]:
    """Return consistent stage-funnel counts, including legacy summary fallbacks."""
    data = summary if isinstance(summary, dict) else {}

    def explicit_or_derived(key: str, derived: int) -> int:
        if key in data:
            return _nonnegative_count(data.get(key))
        return max(0, derived)

    candidate_count = _nonnegative_count(data.get("candidate_count"))
    tcp_reachable_count = _nonnegative_count(data.get("tcp_reachable_count"))
    tcp_failed_count = explicit_or_derived(
        "tcp_failed_count", candidate_count - tcp_reachable_count
    )
    discovery_pool_count = _nonnegative_count(data.get("discovery_pool_count"))
    discovery_not_selected_count = explicit_or_derived(
        "discovery_not_selected_count",
        tcp_reachable_count - discovery_pool_count,
    )
    proxy_valid_count = _nonnegative_count(
        data.get("proxy_valid_count", data.get("vm_valid_count", 0))
    )
    proxy_failed_count = explicit_or_derived(
        "proxy_failed_count", discovery_pool_count - proxy_valid_count
    )
    speed_probe_attempted_count = _nonnegative_count(
        data.get("speed_probe_attempted_count")
    )
    speed_probe_selected_count = _nonnegative_count(
        data.get("speed_probe_selected_count", speed_probe_attempted_count)
    )
    speed_probe_passed_count = _nonnegative_count(
        data.get("speed_probe_passed_count")
    )
    speed_probe_failed_count = explicit_or_derived(
        "speed_probe_failed_count",
        speed_probe_attempted_count - speed_probe_passed_count,
    )
    speed_probe_not_selected_count = explicit_or_derived(
        "speed_probe_not_selected_count",
        (
            proxy_valid_count - speed_probe_selected_count
            if "speed_probe_selected_count" in data
            or "speed_probe_attempted_count" in data
            else 0
        ),
    )
    speed_probe_selected_not_attempted_count = explicit_or_derived(
        "speed_probe_selected_not_attempted_count",
        speed_probe_selected_count - speed_probe_attempted_count,
    )
    formal_attempted_count = _nonnegative_count(
        data.get("formal_attempted_count", data.get("speed_attempted_count", 0))
    )
    formal_selected_count = _nonnegative_count(
        data.get("formal_selected_count", formal_attempted_count)
    )
    formal_passed_count = _nonnegative_count(
        data.get("formal_passed_count", data.get("speed_passed_count", 0))
    )
    formal_failed_count = explicit_or_derived(
        "formal_failed_count", formal_attempted_count - formal_passed_count
    )
    formal_not_selected_count = explicit_or_derived(
        "formal_not_selected_count",
        (
            speed_probe_passed_count - formal_selected_count
            if "speed_probe_passed_count" in data
            else 0
        ),
    )
    formal_selected_not_attempted_count = explicit_or_derived(
        "formal_selected_not_attempted_count",
        formal_selected_count - formal_attempted_count,
    )
    fast_group_count = _nonnegative_count(data.get("fast_group_count"))
    outside_fast_group_count = explicit_or_derived(
        "outside_fast_group_count",
        formal_passed_count - fast_group_count if "fast_group_count" in data else 0,
    )
    failed_count = explicit_or_derived(
        "failed_count",
        tcp_failed_count
        + proxy_failed_count
        + speed_probe_failed_count
        + formal_failed_count,
    )
    return {
        "candidate_count": candidate_count,
        "tcp_reachable_count": tcp_reachable_count,
        "tcp_failed_count": tcp_failed_count,
        "discovery_pool_count": discovery_pool_count,
        "discovery_not_selected_count": discovery_not_selected_count,
        "proxy_valid_count": proxy_valid_count,
        "proxy_failed_count": proxy_failed_count,
        "speed_probe_selected_count": speed_probe_selected_count,
        "speed_probe_attempted_count": speed_probe_attempted_count,
        "speed_probe_passed_count": speed_probe_passed_count,
        "speed_probe_failed_count": speed_probe_failed_count,
        "speed_probe_not_selected_count": speed_probe_not_selected_count,
        "speed_probe_selected_not_attempted_count": (
            speed_probe_selected_not_attempted_count
        ),
        "formal_selected_count": formal_selected_count,
        "formal_attempted_count": formal_attempted_count,
        "formal_passed_count": formal_passed_count,
        "formal_failed_count": formal_failed_count,
        "formal_not_selected_count": formal_not_selected_count,
        "formal_selected_not_attempted_count": (
            formal_selected_not_attempted_count
        ),
        "fast_group_count": fast_group_count,
        "outside_fast_group_count": outside_fast_group_count,
        "failed_count": failed_count,
    }


def _report_metric_row(label: str, row: dict[str, Any] | None) -> str:
    data = row or {}
    return (
        "<tr>"
        f"<th scope=\"row\">{_html_text(label)}</th>"
        f"<td>{_html_text(data.get('ip'))}</td>"
        f"<td>{_html_number(data.get('speed_Mbps'))} Mbps</td>"
        f"<td>{_html_number(data.get('delay_ms'), 0)} ms</td>"
        "</tr>"
    )


def create_notification_report(
    title: str,
    message: str,
    *,
    decision: dict[str, Any] | None = None,
    summary: dict[str, Any] | None = None,
    ranked: list[dict[str, Any]] | None = None,
    failed_rows: list[dict[str, Any]] | None = None,
    retention_days: Any = 30,
    maximum_count: Any = None,
) -> Path:
    decision = decision or {}
    summary = summary or {}
    ranked = ranked or []
    failed_rows = failed_rows or []
    NOTIFICATION_REPORT_DIR.mkdir(parents=True, exist_ok=True)
    report_limit = (
        NOTIFICATION_REPORT_MAX_FILES
        if maximum_count is None
        else maximum_count
    )
    cleanup_notification_reports(retention_days, report_limit)

    timestamp = now()
    filename = (
        f"notification_{timestamp.strftime('%Y%m%d_%H%M%S_%f')}_"
        f"{os.getpid()}_{time.time_ns()}.html"
    )
    report_path = NOTIFICATION_REPORT_DIR / filename
    temp_path = report_path.with_suffix(report_path.suffix + ".tmp")

    current_ip = str(decision.get("current_ip_before") or "未知")
    best = decision.get("best") if isinstance(decision.get("best"), dict) else {}
    current_metrics = decision.get("current_metrics")
    if not isinstance(current_metrics, dict):
        current_metrics = best if best.get("ip") == current_ip else {}
    after_ip = str(
        decision.get("current_ip_after")
        or (best.get("ip") if decision.get("switched") else current_ip)
        or "未知"
    )
    after_metrics = best if decision.get("switched") else current_metrics

    counts = normalize_scan_summary_counts(summary)
    detailed_summary = has_detailed_scan_summary(summary)
    display_summary = {**summary, **counts}
    summary_labels = (
        [
            ("协议", "node_protocol"),
            ("端口", "node_port"),
            ("候选", "candidate_count"),
            ("TCP 可达", "tcp_reachable_count"),
            ("发现池", "discovery_pool_count"),
            ("发现池新 IP", "discovery_new_count"),
            ("链路有效", "proxy_valid_count"),
            ("粗测入选", "speed_probe_selected_count"),
            ("粗测通过", "speed_probe_passed_count"),
            ("粗测尝试", "speed_probe_attempted_count"),
            ("正式入选", "formal_selected_count"),
            ("正式通过", "formal_passed_count"),
            ("正式尝试", "formal_attempted_count"),
            ("高速组", "fast_group_count"),
            ("超时", "timeout_count_total"),
            ("正式池", "active_pool_size"),
            ("本轮新入", "new_active_count"),
            ("池大小变化", "pool_size_delta"),
            ("各阶段失败 IP", "failed_count"),
            ("前台延后", "deferred_count"),
        ]
        if detailed_summary
        else [
            ("协议", "node_protocol"),
            ("端口", "node_port"),
            ("候选", "candidate_count"),
            ("TCP 可达", "tcp_reachable_count"),
            ("发现池", "discovery_pool_count"),
            ("发现池新 IP", "discovery_new_count"),
            ("链路有效", "proxy_valid_count"),
            ("正式通过", "formal_passed_count"),
            ("正式尝试", "formal_attempted_count"),
            ("超时", "timeout_count_total"),
            ("正式池", "active_pool_size"),
            ("本轮新入", "new_active_count"),
            ("池大小变化", "pool_size_delta"),
            ("各阶段失败 IP", "failed_count"),
            ("前台延后", "deferred_count"),
        ]
    )
    summary_html = "".join(
        f"<div class=\"stat\"><dt>{_html_text(label)}</dt>"
        f"<dd>{_html_text(display_summary.get(key, 0))}</dd></div>"
        for label, key in summary_labels
    )
    funnel_rows = "".join(
        "<tr>"
        f"<th scope=\"row\">{_html_text(label)}</th>"
        f"<td>{entered}</td><td>{passed}</td><td>{failed}</td>"
        f"<td>{not_attempted}</td><td>{not_selected}</td>"
        f"<td>{_html_text(note)}</td>"
        "</tr>"
        for label, entered, passed, failed, not_attempted, not_selected, note in [
            (
                "TCP 初筛",
                counts["candidate_count"],
                counts["tcp_reachable_count"],
                counts["tcp_failed_count"],
                0,
                counts["discovery_not_selected_count"],
                "TCP 可达但未进入发现池",
            ),
            (
                "真实代理链路",
                counts["discovery_pool_count"],
                counts["proxy_valid_count"],
                counts["proxy_failed_count"],
                0,
                counts["speed_probe_not_selected_count"],
                "链路有效但未进入速度粗测",
            ),
            (
                "速度粗测",
                counts["speed_probe_selected_count"],
                counts["speed_probe_passed_count"],
                counts["speed_probe_failed_count"],
                counts["speed_probe_selected_not_attempted_count"],
                counts["formal_not_selected_count"],
                "粗测通过但未进入正式测速",
            ),
            (
                "正式三轮测速",
                counts["formal_selected_count"],
                counts["formal_passed_count"],
                counts["formal_failed_count"],
                counts["formal_selected_not_attempted_count"],
                counts["outside_fast_group_count"],
                (
                    "未达到最高平均速度的 "
                    f"{normalize_fast_speed_ratio(summary.get('fast_speed_ratio', 0.95)):.0%}"
                    "（高速组外，非失败）"
                ),
            ),
        ]
    )
    funnel_section = (
        '<h2>阶段漏斗</h2><div class="table-wrap"><table>'
        '<thead><tr><th>阶段</th><th>入选</th><th>通过</th>'
        '<th>阶段失败</th><th>已选未执行</th>'
        '<th>通过后未进入下一阶段（已包含于通过）</th><th>说明</th></tr></thead>'
        f'<tbody>{funnel_rows}</tbody></table></div>'
        if detailed_summary
        else (
            '<h2>阶段漏斗</h2><div class="reason">'
            "本轮摘要来自旧版数据，未记录完整的粗测与名额未入选统计。"
            "</div>"
        )
    )
    raw_stage_durations = summary.get("stage_durations_seconds", {})
    if not isinstance(raw_stage_durations, dict):
        raw_stage_durations = {}
    raw_timeout_counts = summary.get("timeout_counts", {})
    if not isinstance(raw_timeout_counts, dict):
        raw_timeout_counts = {}
    stage_rows = "".join(
        "<tr>"
        f"<th scope=\"row\">{_html_text(STAGE_LABELS.get(key, key))}</th>"
        f"<td>{_html_text(format_stage_duration(value))}</td>"
        f"<td>{_html_text(raw_timeout_counts.get(key, 0))}</td>"
        "</tr>"
        for key, value in raw_stage_durations.items()
    )
    if not stage_rows:
        stage_rows = '<tr><td colspan="3" class="empty">无阶段耗时数据</td></tr>'

    ranking_rows = []
    for index, row in enumerate(ranked, 1):
        speed_cv = row.get("speed_cv")
        speed_cv_percent = (
            float(speed_cv) * 100
            if isinstance(speed_cv, (int, float))
            else None
        )
        ranking_rows.append(
            "<tr>"
            f"<td>{index}</td>"
            f"<td><code>{_html_text(row.get('ip'))}</code></td>"
            f"<td>{'是' if row.get('fast_group') else '否'}</td>"
            f"<td>{_html_number(row.get('speed_Mbps'))}</td>"
            f"<td>{_html_text(row.get('speed_samples_Mbps'))}</td>"
            f"<td>{_html_number(row.get('speed_stddev_Mbps'))}</td>"
            f"<td>{_html_number(speed_cv_percent)}%</td>"
            f"<td>{_html_number(row.get('delay_ms'), 0)}</td>"
            f"<td>{_html_text(row.get('delay_samples_ms'))}</td>"
            f"<td>{_html_number(row.get('delay_stddev_ms'))}</td>"
            "</tr>"
        )
    if not ranking_rows:
        ranking_rows.append('<tr><td colspan="10" class="empty">无通过候选</td></tr>')

    rejected_rows = []
    for row in failed_rows:
        rejected_rows.append(
            "<tr>"
            f"<td><code>{_html_text(row.get('ip'))}</code></td>"
            f"<td>{_html_number(row.get('delay_ms'), 0)}</td>"
            f"<td>{_html_text(row.get('delay_samples_ms'))}</td>"
            f"<td>{_html_number(row.get('delay_stddev_ms'))}</td>"
            f"<td>{_html_number(row.get('speed_Mbps'))}</td>"
            f"<td>{_html_text(row.get('speed_samples_Mbps'))}</td>"
            f"<td>{_html_number(row.get('speed_stddev_Mbps'))}</td>"
            f"<td>{_html_percent(row.get('speed_cv'))}</td>"
            f"<td>{_html_text(row.get('ttfb_samples_ms'))}</td>"
            f"<td>{_html_text(row.get('successful_runs'))}/"
            f"{_html_text(row.get('attempted_runs'))}/"
            f"{_html_text(row.get('planned_runs', row.get('attempted_runs')))}</td>"
            f"<td>{_html_text(row.get('run_errors'))}</td>"
            f"<td>{_html_text(row.get('error') or '测速未通过')}</td>"
            "</tr>"
        )
    if not rejected_rows:
        rejected_rows.append(
            '<tr><td colspan="12" class="empty">'
            "无正式测速淘汰项；此处不包含前序阶段失败或因名额限制未入选的 IP"
            "</td></tr>"
        )

    formal_status = ""
    if counts["formal_attempted_count"] > 0:
        if counts["formal_failed_count"] == 0:
            formal_status = (
                '<div class="success">本轮正式测速 '
                f'{counts["formal_passed_count"]}/{counts["formal_attempted_count"]} '
                "全部通过</div>"
            )
        else:
            formal_status = (
                '<div class="warning">本轮正式测速 '
                f'{counts["formal_passed_count"]}/{counts["formal_attempted_count"]} '
                f'通过，正式淘汰 {counts["formal_failed_count"]}</div>'
            )

    reason = decision.get("reason") or "-"
    duration = format_duration(summary.get("duration_seconds"))
    document = f"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="referrer" content="no-referrer">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
  <title>{_html_text(title)}</title>
  <style>
    :root {{ color-scheme: light dark; font-family: "Segoe UI", "Microsoft YaHei", sans-serif; }}
    body {{ margin: 0; background: #f4f6f8; color: #17202a; }}
    main {{ max-width: 1180px; margin: 0 auto; padding: 28px 22px 48px; }}
    h1 {{ margin: 0 0 6px; font-size: 24px; }}
    h2 {{ margin: 30px 0 10px; font-size: 18px; }}
    .meta, .empty {{ color: #5d6d7e; }}
    .notice {{ margin: 18px 0; padding: 14px 16px; border-left: 4px solid #2374ab; background: #fff; white-space: pre-wrap; }}
    .stats {{ display: grid; grid-template-columns: repeat(auto-fit,minmax(120px,1fr)); gap: 8px; margin: 16px 0; }}
    .stat {{ padding: 10px 12px; border: 1px solid #d5dce3; background: #fff; }}
    dt {{ color: #5d6d7e; font-size: 13px; }} dd {{ margin: 3px 0 0; font-size: 20px; font-weight: 650; }}
    .table-wrap {{ overflow-x: auto; border: 1px solid #d5dce3; background: #fff; }}
    table {{ width: 100%; border-collapse: collapse; font-size: 14px; }}
    th, td {{ padding: 9px 10px; border-bottom: 1px solid #e5e9ed; text-align: left; white-space: nowrap; }}
    th {{ background: #edf1f4; font-weight: 650; }}
    code {{ font-family: Consolas, monospace; }}
    .reason, .success, .warning {{ padding: 12px 14px; background: #fff; border: 1px solid #d5dce3; }}
    .success {{ margin: 10px 0; border-left: 4px solid #238636; color: #116329; }}
    .warning {{ margin: 10px 0; border-left: 4px solid #d29922; color: #7d4e00; }}
    @media (prefers-color-scheme: dark) {{ body {{ background: #15191d; color: #edf2f7; }} .notice,.stat,.table-wrap,.reason,.success,.warning {{ background:#20262c; border-color:#3b4650; }} .success {{ color:#7ee787; }} .warning {{ color:#e3b341; }} th {{ background:#2b333b; }} th,td {{ border-color:#3b4650; }} .meta,.empty,dt {{ color:#aebac5; }} }}
  </style>
</head>
<body><main>
  <h1>{_html_text(title)}</h1>
  <div class="meta">{_html_text(timestamp.strftime('%Y-%m-%d %H:%M:%S %z'))} · 耗时 {_html_text(duration)}</div>
  <div class="notice">{_html_text(message)}</div>
  <h2>本轮概览</h2><dl class="stats">{summary_html}</dl>
  {funnel_section}
  <h2>阶段耗时</h2><div class="table-wrap"><table>
    <thead><tr><th>阶段</th><th>耗时</th><th>超时次数</th></tr></thead>
    <tbody>{stage_rows}</tbody>
  </table></div>
  <h2>切换前后</h2><div class="table-wrap"><table>
    <thead><tr><th>状态</th><th>IP</th><th>平均速度</th><th>平均延迟</th></tr></thead>
    <tbody>{_report_metric_row('切换前', {**current_metrics, 'ip': current_ip})}{_report_metric_row('切换后', {**after_metrics, 'ip': after_ip})}</tbody>
  </table></div>
  <h2>决策原因</h2><div class="reason">{_html_text(reason)}</div>
  <h2>正式测速排名</h2><div class="table-wrap"><table>
    <thead><tr><th>#</th><th>IP</th><th>高速组</th><th>平均速度 Mbps</th><th>三次速度 Mbps</th><th>速度 σ</th><th>速度 CV</th><th>平均延迟 ms</th><th>三次延迟 ms</th><th>延迟 σ</th></tr></thead>
    <tbody>{''.join(ranking_rows)}</tbody>
  </table></div>
  <h2>正式三轮测速淘汰（{counts["formal_failed_count"]}）——仅统计已进入正式测速的节点</h2>{formal_status}<div class="table-wrap"><table>
    <thead><tr><th>IP</th><th>平均延迟 ms</th><th>三次延迟 ms</th><th>延迟 σ</th><th>成功轮次平均速度 Mbps</th><th>三次速度 Mbps</th><th>速度 σ</th><th>速度 CV</th><th>三次 TTFB ms</th><th>成功/执行/计划</th><th>失败轮次</th><th>淘汰原因</th></tr></thead>
    <tbody>{''.join(rejected_rows)}</tbody>
  </table></div>
</main></body></html>
"""
    try:
        temp_path.write_text(document, encoding="utf-8")
        os.replace(temp_path, report_path)
    finally:
        try:
            temp_path.unlink(missing_ok=True)
        except OSError:
            pass
    cleanup_notification_reports(
        retention_days, report_limit, protected_path=report_path
    )
    return report_path


def format_notification_metrics(row: dict[str, Any] | None) -> str:
    if not row:
        return "测速未通过"
    try:
        speed = float(row.get("speed_Mbps", 0))
        delay = float(row.get("delay_ms", 0))
        return f"{speed:.2f} Mbps / {delay:.0f} ms"
    except (TypeError, ValueError):
        return "数据不可用"


def format_duration(seconds: Any) -> str:
    try:
        total = max(0, int(round(float(seconds))))
    except (TypeError, ValueError):
        return "未知"
    minutes, remaining = divmod(total, 60)
    if minutes:
        return f"{minutes}分{remaining:02d}秒"
    return f"{remaining}秒"


def format_stage_duration(seconds: Any) -> str:
    try:
        value = max(0.0, float(seconds))
    except (TypeError, ValueError):
        return "未知"
    if not math.isfinite(value):
        return "未知"
    if value < 1:
        return f"{value:.3f} 秒"
    if value < 60:
        return f"{value:.2f} 秒"
    return format_duration(value)


def format_stage_timings(stage_durations: dict[str, Any]) -> str:
    return "，".join(
        f"{STAGE_LABELS.get(name, name)} {format_stage_duration(seconds)}"
        for name, seconds in stage_durations.items()
    )


def format_timeout_counts(timeout_counts: dict[str, Any]) -> str:
    return "，".join(
        f"{STAGE_LABELS.get(name, name)} {int(count)}"
        for name, count in timeout_counts.items()
        if int(count) > 0
    ) or "无"


def format_notification_comparison(
    old: dict[str, Any] | None, new: dict[str, Any] | None
) -> str | None:
    if not old or not new:
        return None
    try:
        speed_change = float(new.get("speed_Mbps", 0)) - float(
            old.get("speed_Mbps", 0)
        )
        delay_change = float(old.get("delay_ms", 0)) - float(
            new.get("delay_ms", 0)
        )
    except (TypeError, ValueError):
        return None
    speed_word = "提升" if speed_change >= 0 else "下降"
    delay_word = "降低" if delay_change >= 0 else "增加"
    return (
        f"变化：速度{speed_word} {abs(speed_change):.2f} Mbps，"
        f"延迟{delay_word} {abs(delay_change):.0f} ms"
    )


def format_scan_funnel_lines(summary: dict[str, Any]) -> list[str]:
    counts = normalize_scan_summary_counts(summary)
    lines = [
        "流程：{candidates} → TCP {tcp} → 代理 {proxy} → "
        "粗测 {probe_passed}/{probe_attempted} → "
        "正式 {formal_passed}/{formal_attempted}".format(
            candidates=counts["candidate_count"],
            tcp=counts["tcp_reachable_count"],
            proxy=counts["proxy_valid_count"],
            probe_passed=counts["speed_probe_passed_count"],
            probe_attempted=counts["speed_probe_attempted_count"],
            formal_passed=counts["formal_passed_count"],
            formal_attempted=counts["formal_attempted_count"],
        ),
        "失败：TCP {tcp}，代理 {proxy}，粗测 {probe}，正式 {formal}".format(
            tcp=counts["tcp_failed_count"],
            proxy=counts["proxy_failed_count"],
            probe=counts["speed_probe_failed_count"],
            formal=counts["formal_failed_count"],
        ),
        "名额未入选：TCP 后 {tcp}，代理后 {proxy}，粗测后 {probe}；"
        "高速组外 {outside}（非失败）".format(
            tcp=counts["discovery_not_selected_count"],
            proxy=counts["speed_probe_not_selected_count"],
            probe=counts["formal_not_selected_count"],
            outside=counts["outside_fast_group_count"],
        ),
    ]
    probe_not_attempted = counts["speed_probe_selected_not_attempted_count"]
    formal_not_attempted = counts["formal_selected_not_attempted_count"]
    if probe_not_attempted or formal_not_attempted:
        lines.append(
            f"已选未执行：粗测 {probe_not_attempted}，正式 {formal_not_attempted}"
        )
    return lines


def build_scan_notification(
    decision: dict[str, Any],
    quick: bool,
    summary: dict[str, Any] | None = None,
) -> tuple[str, str]:
    mode = "轻量扫描" if quick else "深度扫描"
    current_ip = str(decision.get("current_ip_before") or "未知")
    best = decision.get("best")
    best_ip = str(best.get("ip", "未知")) if isinstance(best, dict) else "未知"
    current_metrics = decision.get("current_metrics")
    if not current_metrics and isinstance(best, dict) and best_ip == current_ip:
        current_metrics = best
    reason = str(decision.get("reason", ""))
    summary = summary or decision.get("scan_summary")
    lines: list[str] = []

    if decision.get("switched"):
        new_ip = str(decision.get("current_ip_after") or best_ip)
        title = f"Clash {mode}：已切换 IP"
        lines.extend(
            [
                f"路径：{current_ip} -> {new_ip}",
                f"切换前：{current_ip} | {format_notification_metrics(current_metrics)}",
                f"切换后：{new_ip} | {format_notification_metrics(best)}",
            ]
        )
        comparison = format_notification_comparison(current_metrics, best)
        if comparison:
            lines.append(comparison)
    else:
        title = f"Clash {mode}：未切换 IP"
        lines.extend([
            f"当前：{current_ip} | "
            f"{format_notification_metrics(current_metrics)}"
        ])
        if isinstance(best, dict) and best_ip != current_ip:
            lines.append(
                f"最佳候选：{best_ip} | {format_notification_metrics(best)}"
            )
            comparison = format_notification_comparison(current_metrics, best)
            if comparison:
                lines.append(comparison)

    if isinstance(summary, dict):
        if summary.get("node_protocol") and summary.get("node_port"):
            lines.append(
                f"入口：{summary['node_protocol']} / TCP {summary['node_port']}"
            )
        counts = normalize_scan_summary_counts(summary)
        if has_detailed_scan_summary(summary):
            lines.extend(format_scan_funnel_lines(summary))
        else:
            lines.append(
                "本轮：候选 {candidates}，TCP {tcp}/{candidates}，"
                "链路 {proxy}/{discovery}，"
                "测速 {passed}/{attempted}，发现池新 IP {new_discovery}".format(
                    candidates=counts["candidate_count"],
                    tcp=counts["tcp_reachable_count"],
                    proxy=counts["proxy_valid_count"],
                    discovery=counts["discovery_pool_count"],
                    passed=counts["formal_passed_count"],
                    attempted=counts["formal_attempted_count"],
                    new_discovery=summary.get("discovery_new_count", 0),
                )
            )
        lines.append(
            "正式池 {pool}（新入 {new_count}，变化 {delta:+d}），"
            "{failed_label} {failed}，耗时 {duration}".format(
                pool=summary.get("active_pool_size", 0),
                new_count=summary.get("new_active_count", 0),
                delta=int(summary.get("pool_size_delta", 0)),
                failed_label=(
                    "各阶段失败"
                    if has_detailed_scan_summary(summary)
                    else "淘汰"
                ),
                failed=counts["failed_count"],
                duration=format_duration(summary.get("duration_seconds")),
            )
        )
        timeout_counts = summary.get("timeout_counts", {})
        if isinstance(timeout_counts, dict):
            lines.append(f"超时次数：{format_timeout_counts(timeout_counts)}")
    if reason:
        lines.append(f"原因：{reason}")
    return title, "\n".join(lines)


def load_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return copy.deepcopy(default)
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError):
        return copy.deepcopy(default)


def save_json_atomic(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(
        json.dumps(value, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    os.replace(tmp, path)


def write_run_status(
    quick: bool,
    status: str,
    started_at: str,
    *,
    reason: str = "",
    summary: dict[str, Any] | None = None,
) -> Path:
    """Persist the latest actual scan outcome for the health monitor.

    Task Scheduler reports exit code 0 for intentional skips. A separate
    per-mode heartbeat prevents those skips from masquerading as completed
    scans and carries enough result data for basic quality validation.
    """
    normalized_status = str(status).strip().lower()
    if normalized_status not in {"success", "skipped", "failed"}:
        raise ValueError(f"未知运行状态：{status}")
    path = LIGHT_RUN_STATUS_PATH if quick else DEEP_RUN_STATUS_PATH
    payload: dict[str, Any] = {
        "schema_version": 1,
        "mode": "light" if quick else "deep",
        "status": normalized_status,
        "started_at": started_at,
        "completed_at": now_iso(),
        "reason": str(reason),
    }
    if isinstance(summary, dict):
        payload["scan_summary"] = summary
    save_json_atomic(path, payload)
    return path


def try_write_run_status(
    quick: bool,
    status: str,
    started_at: str,
    *,
    reason: str = "",
    summary: dict[str, Any] | None = None,
) -> bool:
    try:
        write_run_status(
            quick, status, started_at, reason=reason, summary=summary
        )
        return True
    except (OSError, TypeError, ValueError) as exc:
        log(f"写入扫描心跳失败：{exc}")
        return False


def try_acquire_run_lock() -> Any | None:
    """Prevent the light and deep scheduled tasks from running together."""
    RUN_LOCK_PATH.parent.mkdir(parents=True, exist_ok=True)
    handle = RUN_LOCK_PATH.open("a+b")
    try:
        handle.seek(0, os.SEEK_END)
        if handle.tell() == 0:
            handle.write(b"\0")
            handle.flush()
        handle.seek(0)

        if os.name == "nt":
            import msvcrt

            msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl

            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        return handle
    except OSError:
        handle.close()
        return None


def release_run_lock(handle: Any) -> None:
    try:
        handle.seek(0)
        if os.name == "nt":
            import msvcrt

            msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
        else:
            import fcntl

            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
    except OSError:
        pass
    finally:
        handle.close()


def load_settings() -> dict[str, Any]:
    value = load_json(SETTINGS_PATH, {})
    if not isinstance(value, dict):
        raise RuntimeError("settings.json 顶层必须是 JSON 对象")
    required = {
        "controller",
        "mixed_proxy",
        "active_provider_name",
        "discovery_provider_name",
        "auto_group",
        "discovery_group",
        "parent_group",
    }
    missing = sorted(required.difference(value))
    if missing:
        raise RuntimeError(
            "settings.json 缺少必要字段：" + ", ".join(missing)
        )
    return value


def load_template() -> dict[str, Any]:
    value = load_json(TEMPLATE_PATH, {})
    if not isinstance(value, dict) or not value:
        raise RuntimeError("node_template.json 无效")
    return value


def template_endpoint(template: dict[str, Any]) -> tuple[str, int]:
    protocol = str(template.get("type", "")).strip().lower()
    try:
        port = int(template["port"])
    except (KeyError, TypeError, ValueError) as exc:
        raise RuntimeError("node_template.json 缺少有效的节点端口") from exc
    if not protocol:
        raise RuntimeError("node_template.json 缺少节点协议 type")
    if protocol in UDP_ONLY_PROTOCOLS:
        raise RuntimeError(
            f"当前发现器使用 TCP 初筛，不支持 UDP/QUIC 专用协议 {protocol}"
        )
    if not 1 <= port <= 65535:
        raise RuntimeError(
            f"node_template.json 节点端口超出有效范围：{port}"
        )
    return protocol, port


def load_seed_ips() -> list[str]:
    result: list[str] = []
    if not SEEDS_PATH.exists():
        return result
    for raw in SEEDS_PATH.read_text(encoding="utf-8").splitlines():
        raw = raw.strip()
        if not raw or raw.startswith("#"):
            continue
        try:
            ip = str(ipaddress.IPv4Address(raw))
        except ipaddress.AddressValueError:
            continue
        if ip not in result:
            result.append(ip)
    return result


def make_node(template: dict[str, Any], ip: str, prefix: str) -> dict[str, Any]:
    node = copy.deepcopy(template)
    node["name"] = f"{prefix} | {ip}"
    node["server"] = ip
    return node


def write_provider(
    path: Path,
    template: dict[str, Any],
    ips: list[str],
    prefix: str,
) -> None:
    unique: list[str] = []
    for raw in ips:
        try:
            ip = str(ipaddress.IPv4Address(raw))
        except ipaddress.AddressValueError:
            continue
        if ip not in unique:
            unique.append(ip)
    payload = {"proxies": [make_node(template, ip, prefix) for ip in unique]}
    save_json_atomic(path, payload)


def copy_file_atomic(source: Path, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_name(f".{target.name}.{os.getpid()}.tmp")
    try:
        shutil.copy2(source, tmp)
        os.replace(tmp, target)
    finally:
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass


def update_provider_safely(
    api: "MihomoAPI",
    provider_name: str,
    group_name: str,
    path: Path,
    template: dict[str, Any],
    ips: list[str],
    prefix: str,
    settle_seconds: float = 1.5,
    poll_interval_seconds: float = 0.05,
    *,
    clock: Any | None = None,
    sleeper: Any | None = None,
    timeout_observer: Any | None = None,
) -> None:
    clock_fn = clock or time.monotonic
    backup_path = path.with_suffix(path.suffix + ".last-good")
    had_previous = path.is_file()
    provider_timeout = normalize_poll_seconds(settle_seconds, 8.0, 0.0)
    if had_previous and not backup_path.is_file():
        copy_file_atomic(path, backup_path)

    expected_names = {f"{prefix} | {ip}" for ip in ips}
    try:
        write_provider(path, template, ips, prefix)
        _update_provider_and_wait(
            api,
            provider_name,
            group_name,
            expected_names,
            provider_timeout,
            poll_interval_seconds,
            clock=clock_fn,
            sleeper=sleeper,
            timeout_observer=timeout_observer,
        )
        copy_file_atomic(path, backup_path)
    except Exception as exc:
        confirmation_timed_out = caused_by_confirmation_timeout(exc)
        rollback_error = ""
        if backup_path.is_file():
            try:
                rollback_ips = read_provider_ips(backup_path)
                rollback_names = {f"{prefix} | {ip}" for ip in rollback_ips}
                if not rollback_names:
                    raise RuntimeError("last-good provider 中没有有效节点")
                copy_file_atomic(backup_path, path)
                _update_provider_and_wait(
                    api,
                    provider_name,
                    group_name,
                    rollback_names,
                    provider_timeout,
                    poll_interval_seconds,
                    clock=clock_fn,
                    sleeper=sleeper,
                    timeout_observer=timeout_observer,
                )
            except Exception as rollback_exc:
                confirmation_timed_out = (
                    confirmation_timed_out
                    or caused_by_confirmation_timeout(rollback_exc)
                )
                rollback_error = f"；回滚也失败：{rollback_exc}"
        elif had_previous:
            rollback_error = "；没有可用的 last-good provider"
        else:
            try:
                path.unlink(missing_ok=True)
            except OSError as cleanup_exc:
                rollback_error = f"；清理未验证 provider 也失败：{cleanup_exc}"
        error_type = (
            MihomoConfirmationTimeout
            if confirmation_timed_out
            else RuntimeError
        )
        raise error_type(
            f"provider {provider_name} 更新验证失败，已尝试恢复上一版本："
            f"{exc}{rollback_error}"
        ) from exc


def read_provider_ips(path: Path) -> list[str]:
    payload = load_json(path, {})
    result: list[str] = []
    for node in payload.get("proxies", []) if isinstance(payload, dict) else []:
        raw = str(node.get("server", "")).strip()
        try:
            ip = str(ipaddress.IPv4Address(raw))
        except ipaddress.AddressValueError:
            continue
        if ip not in result:
            result.append(ip)
    return result


def ip_from_node_name(name: str) -> str | None:
    if "|" not in name:
        return None
    raw = name.rsplit("|", 1)[-1].strip()
    try:
        return str(ipaddress.IPv4Address(raw))
    except ipaddress.AddressValueError:
        return None


class MihomoAPITransientError(RuntimeError):
    """A local controller error that may clear during polling."""


class MihomoConfirmationTimeout(TimeoutError, RuntimeError):
    """Mihomo did not confirm a control-plane change before its deadline."""


class MihomoAPIPermanentError(RuntimeError):
    """An HTTP or response error that should fail without retrying."""


class MihomoAPI:
    def __init__(self, base_url: str, secret: str, timeout: float = 20.0) -> None:
        self.base_url = base_url.rstrip("/")
        self.secret = secret
        self.timeout = timeout
        # Build a dedicated opener that bypasses any system or environment proxy
        # so control-plane calls to 127.0.0.1 are never routed through the proxy
        # chain that this tool is actively switching. load_official_ranges()
        # uses urllib.request.urlopen directly and may still traverse a proxy.
        self._opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({})
        )

    @staticmethod
    def quote(value: str) -> str:
        return urllib.parse.quote(value, safe="")

    def request(
        self,
        method: str,
        path: str,
        body: dict[str, Any] | None = None,
        timeout: float | None = None,
    ) -> Any:
        url = self.base_url + path
        data = None
        headers = {"Accept": "application/json"}
        if self.secret:
            headers["Authorization"] = f"Bearer {self.secret}"
        if body is not None:
            data = json.dumps(body, ensure_ascii=False).encode("utf-8")
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            request_timeout = self.timeout if timeout is None else max(
                0.001, min(self.timeout, float(timeout))
            )
            with self._opener.open(req, timeout=request_timeout) as resp:
                raw = resp.read()
                if not raw:
                    return None
                return json.loads(raw.decode("utf-8"))
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise MihomoAPIPermanentError(
                f"Mihomo API {method} {path} 返回 HTTP {exc.code}: {detail}"
            ) from exc
        except urllib.error.URLError as exc:
            raise MihomoAPITransientError(
                f"无法连接 Mihomo API {self.base_url}: {exc.reason}"
            ) from exc
        except (OSError, TimeoutError) as exc:
            raise MihomoAPITransientError(
                f"Mihomo API {method} {path} 连接失败: {exc}"
            ) from exc

    def version(self) -> dict[str, Any]:
        return self.request("GET", "/version") or {}

    def get_proxy(
        self, name: str, timeout: float | None = None
    ) -> dict[str, Any]:
        return self.request(
            "GET", f"/proxies/{self.quote(name)}", timeout=timeout
        ) or {}

    def select(
        self, group: str, node: str, timeout: float | None = None
    ) -> None:
        self.request(
            "PUT",
            f"/proxies/{self.quote(group)}",
            {"name": node},
            timeout=timeout,
        )

    def update_provider(
        self, provider: str, timeout: float | None = None
    ) -> None:
        self.request(
            "PUT",
            f"/providers/proxies/{self.quote(provider)}",
            timeout=timeout,
        )

    def group_delay(
        self,
        group: str,
        test_url: str,
        timeout_ms: int,
    ) -> dict[str, int]:
        query = urllib.parse.urlencode(
            {"url": test_url, "timeout": timeout_ms, "expected": "204"}
        )
        result = self.request(
            "GET", f"/group/{self.quote(group)}/delay?{query}"
        )
        cleaned: dict[str, int] = {}
        if isinstance(result, dict):
            for name, raw in result.items():
                try:
                    delay = int(raw)
                except (TypeError, ValueError):
                    continue
                if 0 < delay < 65535:
                    cleaned[str(name)] = delay
        return cleaned


def normalize_poll_seconds(value: Any, default: float, minimum: float) -> float:
    try:
        seconds = float(value)
    except (TypeError, ValueError):
        seconds = default
    if not math.isfinite(seconds):
        seconds = default
    return max(minimum, seconds)


def _get_proxy_for_poll(
    api: Any, group: str, remaining_seconds: float
) -> dict[str, Any]:
    if isinstance(api, MihomoAPI):
        return api.get_proxy(
            group, timeout=min(1.0, max(0.001, remaining_seconds))
        )
    return api.get_proxy(group)


def _select_for_poll(
    api: Any, group: str, node_name: str, timeout_seconds: float
) -> None:
    if isinstance(api, MihomoAPI):
        api.select(group, node_name, timeout=timeout_seconds)
    else:
        api.select(group, node_name)


def _update_provider_for_poll(
    api: Any, provider: str, timeout_seconds: float
) -> None:
    if isinstance(api, MihomoAPI):
        api.update_provider(provider, timeout=timeout_seconds)
    else:
        api.update_provider(provider)


def _update_provider_and_wait(
    api: Any,
    provider: str,
    group: str,
    expected_names: set[str],
    timeout_seconds: float,
    poll_interval_seconds: Any,
    *,
    clock: Any | None = None,
    sleeper: Any | None = None,
    timeout_observer: Any | None = None,
) -> dict[str, Any]:
    clock_fn = clock or time.monotonic
    timeout = normalize_poll_seconds(timeout_seconds, 8.0, 0.0)
    deadline = float(clock_fn()) + timeout
    request_timeout = max(0.001, deadline - float(clock_fn()))
    try:
        _update_provider_for_poll(api, provider, request_timeout)
    except Exception as exc:
        if caused_by_transport_timeout(exc) and timeout_observer:
            timeout_observer()
        raise
    remaining = max(0.0, deadline - float(clock_fn()))
    if timeout > 0 and remaining <= 0:
        if timeout_observer:
            timeout_observer()
        raise MihomoConfirmationTimeout(
            f"Mihomo provider {provider} 更新后确认时间已耗尽"
        )
    return wait_for_group_members(
        api,
        group,
        expected_names,
        remaining,
        poll_interval_seconds,
        clock=clock_fn,
        sleeper=sleeper,
        timeout_observer=timeout_observer,
    )


def _is_transient_poll_error(exc: Exception) -> bool:
    return isinstance(exc, (MihomoAPITransientError, ConnectionError, TimeoutError))


def wait_for_proxy_now(
    api: Any,
    group: str,
    expected_name: str,
    timeout_seconds: Any,
    poll_interval_seconds: Any,
    *,
    clock: Any | None = None,
    sleeper: Any | None = None,
    timeout_observer: Any | None = None,
) -> dict[str, Any]:
    clock_fn = clock or time.monotonic
    sleep_fn = sleeper or time.sleep
    timeout = normalize_poll_seconds(timeout_seconds, 3.0, 0.0)
    interval = normalize_poll_seconds(poll_interval_seconds, 0.05, 0.02)
    deadline = float(clock_fn()) + timeout
    last_name = ""
    last_error: Exception | None = None
    last_timeout_recorded = False
    first_attempt = True

    while True:
        remaining = deadline - float(clock_fn())
        if remaining <= 0 and not (first_attempt and timeout == 0):
            if not last_timeout_recorded and timeout_observer:
                timeout_observer()
            detail = (
                f"最后错误 {type(last_error).__name__}: {last_error}"
                if last_error is not None
                else f"最后状态 {last_name or '空'}"
            )
            raise MihomoConfirmationTimeout(
                f"Mihomo 组 {group} 未确认选择 {expected_name}；{detail}"
            ) from last_error
        try:
            group_info = _get_proxy_for_poll(api, group, max(0.001, remaining))
            last_name = str(group_info.get("now", ""))
            last_error = None
            last_timeout_recorded = False
            if last_name == expected_name:
                return group_info
        except Exception as exc:
            if not _is_transient_poll_error(exc):
                raise
            last_error = exc
            last_timeout_recorded = caused_by_transport_timeout(exc)
            if last_timeout_recorded and timeout_observer:
                timeout_observer()
        first_attempt = False

        remaining = deadline - float(clock_fn())
        if remaining <= 0:
            if not last_timeout_recorded and timeout_observer:
                timeout_observer()
            detail = (
                f"最后错误 {type(last_error).__name__}: {last_error}"
                if last_error is not None
                else f"最后状态 {last_name or '空'}"
            )
            raise MihomoConfirmationTimeout(
                f"Mihomo 组 {group} 未确认选择 {expected_name}；{detail}"
            ) from last_error
        sleep_fn(min(interval, remaining))


def select_proxy_and_wait(
    api: Any,
    group: str,
    node_name: str,
    timeout_seconds: Any,
    poll_interval_seconds: Any,
    *,
    clock: Any | None = None,
    sleeper: Any | None = None,
    timeout_observer: Any | None = None,
) -> dict[str, Any]:
    clock_fn = clock or time.monotonic
    timeout = normalize_poll_seconds(timeout_seconds, 3.0, 0.0)
    deadline = float(clock_fn()) + timeout
    request_timeout = max(0.001, deadline - float(clock_fn()))
    try:
        _select_for_poll(api, group, node_name, request_timeout)
    except Exception as exc:
        if caused_by_transport_timeout(exc) and timeout_observer:
            timeout_observer()
        raise
    remaining = max(0.0, deadline - float(clock_fn()))
    if timeout > 0 and remaining <= 0:
        if timeout_observer:
            timeout_observer()
        raise MihomoConfirmationTimeout(
            f"Mihomo 组 {group} 选择 {node_name} 后确认时间已耗尽"
        )
    return wait_for_proxy_now(
        api,
        group,
        node_name,
        remaining,
        poll_interval_seconds,
        clock=clock_fn,
        sleeper=sleeper,
        timeout_observer=timeout_observer,
    )


def wait_for_group_members(
    api: Any,
    group: str,
    expected_names: set[str],
    timeout_seconds: Any,
    poll_interval_seconds: Any,
    *,
    clock: Any | None = None,
    sleeper: Any | None = None,
    timeout_observer: Any | None = None,
) -> dict[str, Any]:
    clock_fn = clock or time.monotonic
    sleep_fn = sleeper or time.sleep
    timeout = normalize_poll_seconds(timeout_seconds, 8.0, 0.0)
    interval = normalize_poll_seconds(poll_interval_seconds, 0.05, 0.02)
    deadline = float(clock_fn()) + timeout
    loaded_names: set[str] = set()
    last_error: Exception | None = None
    last_timeout_recorded = False
    first_attempt = True

    while True:
        remaining = deadline - float(clock_fn())
        if remaining <= 0 and not (first_attempt and timeout == 0):
            if not last_timeout_recorded and timeout_observer:
                timeout_observer()
            if last_error is not None:
                detail = (
                    f"最后错误 {type(last_error).__name__}: {last_error}"
                )
            else:
                missing = expected_names.difference(loaded_names)
                unexpected = loaded_names.difference(expected_names)
                detail = f"缺少 {len(missing)} 个，多出 {len(unexpected)} 个"
            raise MihomoConfirmationTimeout(
                f"Mihomo 组 {group} 成员不一致：{detail}"
            ) from last_error
        try:
            group_info = _get_proxy_for_poll(api, group, max(0.001, remaining))
            loaded_names = {
                str(name) for name in group_info.get("all", [])
            }
            last_error = None
            last_timeout_recorded = False
            if loaded_names == expected_names:
                return group_info
        except Exception as exc:
            if not _is_transient_poll_error(exc):
                raise
            last_error = exc
            last_timeout_recorded = caused_by_transport_timeout(exc)
            if last_timeout_recorded and timeout_observer:
                timeout_observer()
        first_attempt = False

        remaining = deadline - float(clock_fn())
        if remaining <= 0:
            if not last_timeout_recorded and timeout_observer:
                timeout_observer()
            if last_error is not None:
                detail = (
                    f"最后错误 {type(last_error).__name__}: {last_error}"
                )
            else:
                missing = expected_names.difference(loaded_names)
                unexpected = loaded_names.difference(expected_names)
                detail = f"缺少 {len(missing)} 个，多出 {len(unexpected)} 个"
            raise MihomoConfirmationTimeout(
                f"Mihomo 组 {group} 成员不一致：{detail}"
            ) from last_error
        sleep_fn(min(interval, remaining))


def caused_by_confirmation_timeout(exc: BaseException) -> bool:
    """Return whether an exception chain contains a confirmation timeout."""
    seen: set[int] = set()
    current: BaseException | None = exc
    while current is not None and id(current) not in seen:
        seen.add(id(current))
        if isinstance(current, MihomoConfirmationTimeout):
            return True
        current = current.__cause__ or current.__context__
    return False


def caused_by_transport_timeout(exc: BaseException) -> bool:
    """Return whether an exception chain contains a transport timeout."""
    seen: set[int] = set()
    current: BaseException | None = exc
    while current is not None and id(current) not in seen:
        seen.add(id(current))
        if isinstance(current, TimeoutError) and not isinstance(
            current, MihomoConfirmationTimeout
        ):
            return True
        reason = getattr(current, "reason", None)
        if isinstance(reason, TimeoutError):
            return True
        current = current.__cause__ or current.__context__
    return False


def average_group_delays(
    api: MihomoAPI,
    group: str,
    test_url: str,
    timeout_ms: int,
    repeats: int,
    repeat_interval_seconds: float,
    require_all_repeats: bool,
    *,
    timeout_observer: Any | None = None,
) -> tuple[dict[str, float], dict[str, list[int]], dict[str, float]]:
    """
    Run Mihomo group delay test multiple times.

    Returns:
    - average delay per node;
    - raw delay samples per node;
    - population standard deviation per node.
    """
    repeats = max(1, int(repeats))
    samples: dict[str, list[int]] = {}

    for round_index in range(1, repeats + 1):
        try:
            result = api.group_delay(group, test_url, timeout_ms)
        except Exception as exc:
            if caused_by_transport_timeout(exc) and timeout_observer:
                timeout_observer()
            raise
        log(
            f"真实代理链路延迟测试 {round_index}/{repeats}："
            f"{len(result)} 个节点有效"
        )
        for name, delay in result.items():
            samples.setdefault(name, []).append(int(delay))
        if round_index < repeats:
            time.sleep(max(0.0, float(repeat_interval_seconds)))

    minimum_successes = repeats if require_all_repeats else max(1, repeats - 1)
    averages: dict[str, float] = {}
    deviations: dict[str, float] = {}
    retained_samples: dict[str, list[int]] = {}

    for name, values in samples.items():
        if len(values) < minimum_successes:
            continue
        retained_samples[name] = values
        averages[name] = round(statistics.fmean(values), 2)
        deviations[name] = round(
            statistics.pstdev(values) if len(values) > 1 else 0.0,
            2,
        )

    return averages, retained_samples, deviations


def cache_is_fresh(path: Path, max_hours: float) -> bool:
    if not path.exists():
        return False
    age_seconds = time.time() - path.stat().st_mtime
    return age_seconds <= max_hours * 3600


def parse_ranges(text: str) -> list[ipaddress.IPv4Network]:
    result: list[ipaddress.IPv4Network] = []
    for raw in text.splitlines():
        raw = raw.strip()
        if not raw or raw.startswith("#"):
            continue
        try:
            net = ipaddress.ip_network(raw, strict=False)
        except ValueError:
            continue
        if isinstance(net, ipaddress.IPv4Network):
            result.append(net)
    return result


def load_official_ranges(
    settings: dict[str, Any], *, timeout_observer: Any | None = None
) -> list[ipaddress.IPv4Network]:
    cache_hours = float(settings.get("ranges_cache_hours", 24))
    if cache_is_fresh(RANGES_CACHE_PATH, cache_hours):
        cached = parse_ranges(RANGES_CACHE_PATH.read_text(encoding="utf-8"))
        if cached:
            return cached

    url = str(settings["official_ipv4_url"])
    req = urllib.request.Request(
        url, headers={"User-Agent": "Clash-Cloudflare-Dynamic/2.0"}
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            text = resp.read().decode("utf-8", errors="replace")
        ranges = parse_ranges(text)
        if not ranges:
            raise ValueError("官方列表为空")
        RANGES_CACHE_PATH.write_text(
            "\n".join(str(x) for x in ranges) + "\n", encoding="utf-8"
        )
        return ranges
    except Exception as exc:
        if caused_by_transport_timeout(exc) and timeout_observer:
            timeout_observer()
        log(f"官方网段获取失败，使用缓存/内置快照：{exc}")
        if RANGES_CACHE_PATH.exists():
            cached = parse_ranges(RANGES_CACHE_PATH.read_text(encoding="utf-8"))
            if cached:
                return cached
        return [ipaddress.ip_network(x) for x in FALLBACK_RANGES]


def in_ranges(ip: str, ranges: list[ipaddress.IPv4Network]) -> bool:
    obj = ipaddress.IPv4Address(ip)
    return any(obj in net for net in ranges)


def random_ip(net: ipaddress.IPv4Network, rng: random.Random) -> str:
    if net.num_addresses > 2:
        offset = rng.randrange(1, net.num_addresses - 1)
    else:
        offset = rng.randrange(net.num_addresses)
    return str(ipaddress.IPv4Address(int(net.network_address) + offset))


def choose_network(
    ranges: list[ipaddress.IPv4Network], rng: random.Random
) -> ipaddress.IPv4Network:
    # sqrt weighting: larger official blocks are sampled more, but do not dominate.
    weights = [math.sqrt(x.num_addresses) for x in ranges]
    return rng.choices(ranges, weights=weights, k=1)[0]


def initialize_discovery_db(connection: sqlite3.Connection) -> None:
    connection.execute(
        """
        CREATE TABLE IF NOT EXISTS ip_history (
            ip TEXT PRIMARY KEY,
            port INTEGER NOT NULL DEFAULT 443,
            last_sampled REAL NOT NULL,
            last_tcp_reachable INTEGER NOT NULL DEFAULT 0,
            last_tcp_ms REAL,
            last_vm_success REAL,
            last_speed_success REAL,
            last_speed_failure REAL
        )
        """
    )
    columns = {
        str(row[1]) for row in connection.execute("PRAGMA table_info(ip_history)")
    }
    if "port" not in columns:
        # Every version before configurable ports probed TCP 443 only.
        connection.execute(
            "ALTER TABLE ip_history ADD COLUMN port INTEGER NOT NULL DEFAULT 443"
        )
    connection.execute(
        """
        CREATE INDEX IF NOT EXISTS idx_ip_history_last_sampled
        ON ip_history(last_sampled)
        """
    )
    connection.execute(
        """
        CREATE INDEX IF NOT EXISTS idx_ip_history_port_last_sampled
        ON ip_history(port, last_sampled)
        """
    )


def open_discovery_db() -> sqlite3.Connection:
    return connect_sqlite_with_recovery(
        DISCOVERY_DB_PATH,
        BACKUP_DIR,
        initialize_discovery_db,
        timeout=30,
        logger=lambda message: log(f"SQLite 自动恢复：{message}"),
    )


def cleanup_discovery_history(
    retention_days: float = 30,
    vacuum_after_deleted_rows: int = 5000,
) -> int:
    cutoff = time.time() - max(1.0, float(retention_days)) * 86400
    try:
        vacuum_threshold = max(1, int(vacuum_after_deleted_rows))
    except (TypeError, ValueError):
        vacuum_threshold = 5000
    try:
        with closing(open_discovery_db()) as connection:
            with connection:
                cursor = connection.execute(
                    "DELETE FROM ip_history WHERE last_sampled < ?",
                    (cutoff,),
                )
                deleted = max(0, int(cursor.rowcount))
                connection.execute("PRAGMA optimize")
            if deleted >= vacuum_threshold:
                # VACUUM cannot run inside a transaction; the `with connection`
                # block above has already committed, so run it separately on the
                # same connection to reclaim the freed file space.
                try:
                    connection.execute("VACUUM")
                    log("已执行 VACUUM 回收空间")
                except sqlite3.OperationalError as exc:
                    log(f"VACUUM 回收空间失败，本轮跳过：{exc}")
            return deleted
    except sqlite3.Error as exc:
        log(f"清理 IP 扫描历史失败：{exc}")
        return 0


def load_recently_sampled_ips(retest_days: float, port: int = 443) -> set[str]:
    cutoff = time.time() - max(0.0, float(retest_days)) * 86400
    try:
        with closing(open_discovery_db()) as connection, connection:
            rows = connection.execute(
                "SELECT ip FROM ip_history WHERE port = ? AND last_sampled >= ?",
                (int(port), cutoff),
            )
            return {str(row[0]) for row in rows}
    except sqlite3.Error as exc:
        log(f"读取 IP 扫描历史失败，本轮允许重复抽样：{exc}")
        return set()


def record_tcp_history(rows: list[dict[str, Any]]) -> None:
    stamp = time.time()
    values = [
        (
            str(row["ip"]),
            int(row.get("port", 443)),
            stamp,
            1 if row.get("reachable") else 0,
            row.get("tcp_ms"),
        )
        for row in rows
    ]
    try:
        with closing(open_discovery_db()) as connection, connection:
            connection.executemany(
                """
                INSERT INTO ip_history (
                    ip, port, last_sampled, last_tcp_reachable, last_tcp_ms
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(ip) DO UPDATE SET
                    port = excluded.port,
                    last_sampled = excluded.last_sampled,
                    last_tcp_reachable = excluded.last_tcp_reachable,
                    last_tcp_ms = excluded.last_tcp_ms
                """,
                values,
            )
    except sqlite3.Error as exc:
        log(f"写入 IP 扫描历史失败：{exc}")


def record_vm_history(node_names: list[str]) -> None:
    stamp = time.time()
    values = [
        (ip, stamp, stamp)
        for ip in (ip_from_node_name(name) for name in node_names)
        if ip
    ]
    try:
        with closing(open_discovery_db()) as connection, connection:
            connection.executemany(
                """
                INSERT INTO ip_history (ip, last_sampled, last_vm_success)
                VALUES (?, ?, ?)
                ON CONFLICT(ip) DO UPDATE SET
                    last_vm_success = excluded.last_vm_success
                """,
                values,
            )
    except sqlite3.Error as exc:
        log(f"写入真实链路历史失败：{exc}")


def record_speed_history(rows: list[dict[str, Any]]) -> None:
    stamp = time.time()
    values = [
        (
            str(row["ip"]),
            stamp,
            stamp if row.get("speed_ok") else None,
            None if row.get("speed_ok") else stamp,
        )
        for row in rows
        if row.get("ip")
    ]
    try:
        with closing(open_discovery_db()) as connection, connection:
            connection.executemany(
                """
                INSERT INTO ip_history (
                    ip, last_sampled, last_speed_success, last_speed_failure
                ) VALUES (?, ?, ?, ?)
                ON CONFLICT(ip) DO UPDATE SET
                    last_speed_success = COALESCE(
                        excluded.last_speed_success,
                        ip_history.last_speed_success
                    ),
                    last_speed_failure = COALESCE(
                        excluded.last_speed_failure,
                        ip_history.last_speed_failure
                    )
                """,
                values,
            )
    except sqlite3.Error as exc:
        log(f"写入下载测速历史失败：{exc}")


def load_historical_ips(limit: int) -> list[str]:
    if not HISTORY_PATH.exists():
        return []
    rows: list[dict[str, Any]] = []
    try:
        with HISTORY_PATH.open("r", encoding="utf-8-sig", newline="") as f:
            rows = list(csv.DictReader(f))
    except OSError:
        return []
    rows.reverse()
    result: list[str] = []
    for row in rows:
        ip = row.get("ip", "")
        try:
            ip = str(ipaddress.IPv4Address(ip))
        except ipaddress.AddressValueError:
            continue
        if ip not in result:
            result.append(ip)
        if len(result) >= limit:
            break
    return result


def load_historical_speed_scores(
    samples_per_ip: int = 5, stability_penalty: float = 0.25
) -> dict[str, float]:
    """Return a recent multi-run speed reputation for probe selection.

    A single latest peak is too noisy for deciding which historical nodes earn
    scarce probe slots. Recent samples receive exponentially higher weight and
    unstable histories are penalized by their coefficient of variation.
    """
    if not HISTORY_PATH.exists():
        return {}
    try:
        with HISTORY_PATH.open("r", encoding="utf-8-sig", newline="") as f:
            rows = list(csv.DictReader(f))
    except OSError:
        return {}
    sample_limit = max(1, min(20, int(samples_per_ip)))
    penalty_factor = max(0.0, min(2.0, float(stability_penalty)))
    samples: dict[str, list[float]] = {}
    for row in reversed(rows):
        ip = str(row.get("ip", ""))
        values = samples.setdefault(ip, [])
        if len(values) >= sample_limit:
            continue
        try:
            speed = float(row.get("speed_Mbps", 0))
        except (TypeError, ValueError):
            continue
        if not math.isfinite(speed) or speed <= 0:
            continue
        values.append(speed)

    result: dict[str, float] = {}
    for ip, values in samples.items():
        if not values:
            continue
        weights = [0.70 ** index for index in range(len(values))]
        weighted_speed = sum(
            speed * weight for speed, weight in zip(values, weights)
        ) / sum(weights)
        mean_speed = statistics.fmean(values)
        speed_cv = (
            statistics.pstdev(values) / max(mean_speed, 0.001)
            if len(values) > 1
            else 0.0
        )
        result[ip] = round(
            weighted_speed / (1.0 + min(speed_cv, 2.0) * penalty_factor),
            4,
        )
    return result


def normalize_share(value: Any, default: float) -> float:
    try:
        share = float(value)
    except (TypeError, ValueError):
        share = default
    return min(1.0, max(0.0, share))


def select_speed_probe_names(
    delays: dict[str, float],
    fixed_ips: set[str],
    current_name: str | None,
    settings: dict[str, Any],
    rng: random.Random,
) -> tuple[list[str], dict[str, int]]:
    if not delays:
        return [], {"low_latency": 0, "history": 0, "exploration": 0}

    final_count = max(1, int(settings.get("speed_candidates", 8)))
    probe_limit = max(
        final_count, int(settings.get("speed_probe_candidates", final_count))
    )
    probe_limit = min(probe_limit, len(delays))
    latency_share = normalize_share(
        settings.get("speed_probe_latency_share", 0.50), 0.50
    )
    history_share = normalize_share(
        settings.get("speed_probe_history_share", 0.25), 0.25
    )
    latency_target = min(probe_limit, max(1, round(probe_limit * latency_share)))
    history_target = min(
        probe_limit - latency_target,
        max(0, round(probe_limit * history_share)),
    )

    selected: list[str] = []
    counts = {"low_latency": 0, "history": 0, "exploration": 0}

    def add(name: str, category: str) -> bool:
        if name not in delays or name in selected or len(selected) >= probe_limit:
            return False
        selected.append(name)
        counts[category] += 1
        return True

    for name, _ in sorted(delays.items(), key=lambda item: item[1]):
        if counts["low_latency"] >= latency_target:
            break
        add(name, "low_latency")

    historical_scores = load_historical_speed_scores(
        int(settings.get("historical_speed_samples_per_ip", 5)),
        float(settings.get("historical_speed_stability_penalty", 0.25)),
    )
    historical_names = sorted(
        (
            name
            for name in delays
            if (ip_from_node_name(name) or "") in historical_scores
        ),
        key=lambda name: (
            -historical_scores[ip_from_node_name(name) or ""],
            float(delays[name]),
        ),
    )
    for name in historical_names:
        if counts["history"] >= history_target:
            break
        add(name, "history")

    exploration_names = [
        name
        for name in delays
        if (ip_from_node_name(name) or "") not in fixed_ips
    ]
    rng.shuffle(exploration_names)
    remaining_names = list(delays)
    rng.shuffle(remaining_names)
    for name in [*exploration_names, *remaining_names]:
        if len(selected) >= probe_limit:
            break
        add(name, "exploration")

    if current_name and current_name in delays and current_name not in selected:
        selected.append(current_name)
        counts["current_extra"] = 1
    else:
        counts["current_extra"] = 0
    return selected, counts


def generate_candidates(
    ranges: list[ipaddress.IPv4Network],
    settings: dict[str, Any],
    rng: random.Random,
    port: int,
) -> tuple[list[str], set[str], int, int]:
    seeds = load_seed_ips()
    active = read_provider_ips(ACTIVE_PROVIDER_PATH)
    history = load_historical_ips(
        int(settings.get("historical_ips_to_retest", 50))
    )

    fixed: set[str] = {
        ip for ip in [*seeds, *active, *history] if in_ranges(ip, ranges)
    }
    candidates: set[str] = set(fixed)

    neighbor_count = int(settings.get("neighbor_samples_per_active", 1))
    for ip in active:
        network = ipaddress.ip_network(f"{ip}/24", strict=False)
        for _ in range(neighbor_count):
            candidate = random_ip(network, rng)
            if in_ranges(candidate, ranges):
                candidates.add(candidate)

    target = int(settings.get("random_samples_per_run", 160))
    recently_sampled = load_recently_sampled_ips(
        float(settings.get("new_ip_retest_days", 30)),
        port,
    )
    attempts = 0
    fresh_added = 0
    while fresh_added < target and attempts < max(100, target * 50):
        candidate = random_ip(choose_network(ranges, rng), rng)
        if candidate in recently_sampled:
            attempts += 1
            continue
        before = len(candidates)
        candidates.add(candidate)
        if len(candidates) > before:
            fresh_added += 1
        attempts += 1

    reused_added = 0
    attempts = 0
    while fresh_added + reused_added < target and attempts < max(100, target * 20):
        candidate = random_ip(choose_network(ranges, rng), rng)
        before = len(candidates)
        candidates.add(candidate)
        if len(candidates) > before:
            reused_added += 1
        attempts += 1

    ordered = sorted(candidates, key=lambda x: int(ipaddress.IPv4Address(x)))
    return ordered, fixed, fresh_added, reused_added


def tcp_probe(
    ip: str,
    attempts: int,
    timeout: float,
    port: int,
) -> dict[str, Any]:
    port = int(port)
    if not 1 <= port <= 65535:
        raise ValueError(f"TCP 端口超出有效范围：{port}")
    samples: list[float] = []
    timeout_count = 0
    for _ in range(max(1, attempts)):
        start = time.perf_counter()
        try:
            with socket.create_connection((ip, port), timeout=timeout):
                samples.append((time.perf_counter() - start) * 1000)
        except (socket.timeout, TimeoutError):
            timeout_count += 1
        except OSError:
            pass
    return {
        "ip": ip,
        "port": port,
        "reachable": bool(samples),
        "tcp_ms": round(statistics.median(samples), 2) if samples else None,
        "successes": len(samples),
        "attempts": max(1, attempts),
        "timeout_count": timeout_count,
    }


def tcp_stage(
    ips: list[str],
    settings: dict[str, Any],
    port: int,
) -> list[dict[str, Any]]:
    workers = int(settings.get("tcp_workers", 64))
    attempts = int(settings.get("tcp_attempts", 1))
    timeout = float(settings.get("tcp_timeout_seconds", 1.6))
    rows: list[dict[str, Any]] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {
            pool.submit(tcp_probe, ip, attempts, timeout, port): ip
            for ip in ips
        }
        done = 0
        total = len(futures)
        for future in concurrent.futures.as_completed(futures):
            rows.append(future.result())
            done += 1
            if done % 100 == 0 or done == total:
                log(f"TCP {port} 初筛：{done}/{total}")
    return rows


def write_discovery_log(
    rows: list[dict[str, Any]], protocol: str = ""
) -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    fields = [
        "time",
        "ip",
        "protocol",
        "port",
        "reachable",
        "tcp_ms",
        "successes",
        "attempts",
        "timeout_count",
    ]
    with DISCOVERY_CSV.open("w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        stamp = now_iso()
        for row in sorted(
            rows,
            key=lambda x: (
                not bool(x["reachable"]),
                float(x["tcp_ms"]) if x["tcp_ms"] is not None else 1e9,
            ),
        ):
            item = dict(row)
            item["time"] = stamp
            item["protocol"] = protocol
            writer.writerow(item)


def write_speed_probe_log(rows: list[dict[str, Any]]) -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    fields = [
        "time",
        "ip",
        "protocol",
        "port",
        "node",
        "delay_ms",
        "speed_ok",
        "speed_Mbps",
        "ttfb_ms",
        "size_download",
        "timed_out",
        "error",
    ]
    with SPEED_PROBE_CSV.open("w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def select_discovery_ips(
    tcp_rows: list[dict[str, Any]],
    fixed: set[str],
    limit: int,
    preferred_ip: str | None = None,
    priority_ips: set[str] | None = None,
    new_ip_share: Any = 0.0,
) -> list[str]:
    limit = max(0, int(limit))
    if limit == 0:
        return []
    reachable = [x for x in tcp_rows if x["reachable"]]
    reachable.sort(key=lambda x: float(x["tcp_ms"]))
    selected: list[str] = []
    priority = priority_ips or set()
    new_rows = [row for row in reachable if row["ip"] not in fixed]
    fixed_rows = [row for row in reachable if row["ip"] in fixed]

    try:
        share = float(new_ip_share)
    except (TypeError, ValueError):
        share = 0.0
    if not math.isfinite(share):
        share = 0.0
    share = min(1.0, max(0.0, share))
    new_target = min(len(new_rows), math.ceil(limit * share))
    fixed_target = max(0, limit - new_target)

    # Always retest the live node when it is reachable, even if fixed candidates
    # exceed the provider limit.
    if preferred_ip and any(
        row["ip"] == preferred_ip for row in reachable
    ):
        selected.append(preferred_ip)

    # Keep active nodes before other fixed/history nodes, while reserving a
    # configurable part of the provider for genuinely new IPs.
    priority_rows = [row for row in fixed_rows if row["ip"] in priority]
    other_fixed_rows = [row for row in fixed_rows if row["ip"] not in priority]
    for row in [*priority_rows, *other_fixed_rows]:
        if len(selected) >= fixed_target:
            break
        if row["ip"] not in selected:
            selected.append(row["ip"])

    selected_new = sum(1 for ip in selected if ip not in fixed)
    for row in new_rows:
        if len(selected) >= limit or selected_new >= new_target:
            break
        if row["ip"] not in selected:
            selected.append(row["ip"])
            selected_new += 1

    # Backfill either category when the other one has too few reachable nodes.
    for row in [*fixed_rows, *new_rows]:
        if len(selected) >= limit:
            break
        if row["ip"] not in selected:
            selected.append(row["ip"])
    return selected[:limit]


def find_curl() -> str:
    for name in ("curl.exe", "curl"):
        found = shutil.which(name)
        if found:
            return found
    raise RuntimeError("未找到 curl；Windows 10/11 通常自带 curl.exe")


def speed_test(
    curl_bin: str,
    proxy_url: str,
    base_url: str,
    byte_count: int,
    timeout_seconds: float,
) -> dict[str, Any]:
    requested_bytes = max(1, int(byte_count))
    nonce = f"{int(time.time() * 1000)}-{random.randrange(1_000_000)}"
    sep = "&" if "?" in base_url else "?"
    url = f"{base_url}{sep}bytes={requested_bytes}&cfdyn={nonce}"
    fmt = (
        '{"http_code":%{http_code},'
        '"time_starttransfer":%{time_starttransfer},'
        '"time_total":%{time_total},'
        '"size_download":%{size_download},'
        '"speed_download":%{speed_download}}'
    )
    cmd = [
        curl_bin,
        "--silent",
        "--show-error",
        "--location",
        "--proxy",
        proxy_url,
        "--noproxy",
        "",
        "--output",
        os.devnull,
        "--connect-timeout",
        str(min(timeout_seconds, 8)),
        "--max-time",
        str(timeout_seconds),
        "--write-out",
        fmt,
        url,
    ]
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout_seconds + 5,
            check=False,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
    except subprocess.TimeoutExpired as exc:
        return {"ok": False, "timed_out": True, "error": f"curl 超时: {exc}"}
    if proc.returncode != 0:
        return {
            "ok": False,
            "timed_out": proc.returncode == 28,
            "error": proc.stderr.strip() or f"curl exit {proc.returncode}",
        }
    try:
        payload = json.loads(proc.stdout.strip())
        code = int(payload.get("http_code", 0))
        size = float(payload.get("size_download", 0))
        speed = float(payload.get("speed_download", 0))
        total = float(payload.get("time_total", 0))
        ttfb = float(payload.get("time_starttransfer", 0))
    except (ValueError, TypeError, json.JSONDecodeError) as exc:
        return {
            "ok": False,
            "timed_out": False,
            "error": f"测速结果解析失败: {exc}",
        }
    minimum_size = requested_bytes * 0.9
    ok = 200 <= code < 400 and size >= minimum_size and speed > 0
    if ok:
        error = ""
    elif not 200 <= code < 400:
        error = f"HTTP {code}"
    elif size < minimum_size:
        error = (
            f"下载量不足：{int(size)}/{requested_bytes} bytes "
            f"(< 90%)"
        )
    else:
        error = f"无有效下载速度：{speed} bytes/s"
    return {
        "ok": ok,
        "timed_out": False,
        "http_code": code,
        "speed_Mbps": round(speed * 8 / 1_000_000, 2),
        "speed_MB_per_s": round(speed / 1_000_000, 2),
        "ttfb_ms": round(ttfb * 1000, 2),
        "total_ms": round(total * 1000, 2),
        "size_download": int(size),
        "error": error,
    }


def repeated_speed_test(
    curl_bin: str,
    proxy_url: str,
    base_url: str,
    byte_count: int,
    timeout_seconds: float,
    repeats: int,
    repeat_interval_seconds: float,
    require_all_repeats: bool,
    progress_prefix: str = "",
) -> dict[str, Any]:
    """
    Run download speed test repeatedly and average successful measurements.

    By default all configured rounds must succeed. This avoids promoting a node
    whose result is based on only one lucky successful attempt.
    """
    repeats = max(1, int(repeats))
    runs: list[dict[str, Any]] = []
    errors: list[str] = []
    speed_samples: list[str] = []
    ttfb_samples: list[str] = []
    run_errors: list[str] = []
    executed_runs = 0
    skipped_runs = 0
    timeout_runs = 0

    for round_index in range(1, repeats + 1):
        result = speed_test(
            curl_bin,
            proxy_url,
            base_url,
            byte_count,
            timeout_seconds,
        )
        executed_runs += 1
        if result.get("timed_out"):
            timeout_runs += 1
        if result.get("ok"):
            runs.append(result)
            speed_samples.append(
                f"{float(result.get('speed_Mbps', 0.0)):.2f}"
            )
            ttfb_samples.append(
                f"{float(result.get('ttfb_ms', 0.0)):.2f}"
            )
            log(
                f"{progress_prefix}第 {round_index}/{repeats} 次："
                f"{result.get('speed_Mbps', 0)} Mbps，"
                f"TTFB {result.get('ttfb_ms', 0)} ms"
            )
        else:
            error = str(result.get("error", "未知错误"))
            errors.append(error)
            speed_samples.append("FAIL")
            ttfb_samples.append("FAIL")
            run_errors.append(f"{round_index}:{error}")
            log(
                f"{progress_prefix}第 {round_index}/{repeats} 次失败：{error}"
            )
            if require_all_repeats and round_index < repeats:
                skipped_runs = repeats - round_index
                speed_samples.extend(["SKIP"] * skipped_runs)
                ttfb_samples.extend(["SKIP"] * skipped_runs)
                log(
                    f"{progress_prefix}严格三次模式已有失败，"
                    f"剩余 {skipped_runs} 次跳过"
                )
                break
        if round_index < repeats:
            time.sleep(max(0.0, float(repeat_interval_seconds)))

    minimum_successes = repeats if require_all_repeats else max(1, repeats - 1)
    enough_successes = len(runs) >= minimum_successes
    result_summary: dict[str, Any] = {
        "ok": enough_successes,
        "successful_runs": len(runs),
        "attempted_runs": executed_runs,
        "planned_runs": repeats,
        "skipped_runs": skipped_runs,
        "timeout_runs": timeout_runs,
        "speed_samples_Mbps": ",".join(speed_samples),
        "ttfb_samples_ms": ",".join(ttfb_samples),
        "run_errors": "；".join(run_errors),
        "error": "" if enough_successes else (
            f"成功 {len(runs)}/{repeats} 次；"
            + ("；".join(errors) if errors else "有效次数不足")
        ),
    }
    if not runs:
        return result_summary

    speed_values = [float(x["speed_Mbps"]) for x in runs]
    speed_mb_values = [
        float(x.get("speed_MB_per_s", x.get("speed_MBps", 0)))
        for x in runs
    ]
    ttfb_values = [float(x["ttfb_ms"]) for x in runs]
    total_values = [float(x["total_ms"]) for x in runs]

    mean_speed = statistics.fmean(speed_values)
    speed_stddev = (
        statistics.pstdev(speed_values) if len(speed_values) > 1 else 0.0
    )

    result_summary.update({
        "speed_Mbps": round(mean_speed, 2),
        "speed_MB_per_s": round(statistics.fmean(speed_mb_values), 2),
        "ttfb_ms": round(statistics.fmean(ttfb_values), 2),
        "total_ms": round(statistics.fmean(total_values), 2),
        "speed_stddev_Mbps": round(speed_stddev, 2),
        "speed_cv": round(speed_stddev / max(mean_speed, 0.001), 4),
        "ttfb_stddev_ms": round(
            statistics.pstdev(ttfb_values) if len(ttfb_values) > 1 else 0.0,
            2,
        ),
    })
    return result_summary


def summarize_speed_test_rounds(
    round_results: list[dict[str, Any] | None],
    repeats: int,
    require_all_repeats: bool,
) -> dict[str, Any]:
    """Aggregate executed, failed and skipped download-test rounds."""
    repeats = max(1, int(repeats))
    normalized = list(round_results[:repeats])
    if len(normalized) < repeats:
        normalized.extend([None] * (repeats - len(normalized)))

    runs: list[dict[str, Any]] = []
    errors: list[str] = []
    speed_samples: list[str] = []
    ttfb_samples: list[str] = []
    run_errors: list[str] = []
    executed_runs = 0
    skipped_runs = 0
    timeout_runs = 0

    for round_index, result in enumerate(normalized, 1):
        if result is None:
            skipped_runs += 1
            speed_samples.append("SKIP")
            ttfb_samples.append("SKIP")
            continue
        executed_runs += 1
        if result.get("timed_out"):
            timeout_runs += 1
        if result.get("ok"):
            runs.append(result)
            speed_samples.append(
                f"{float(result.get('speed_Mbps', 0.0)):.2f}"
            )
            ttfb_samples.append(
                f"{float(result.get('ttfb_ms', 0.0)):.2f}"
            )
            continue
        error = str(result.get("error", "未知错误"))
        errors.append(error)
        speed_samples.append("FAIL")
        ttfb_samples.append("FAIL")
        run_errors.append(f"{round_index}:{error}")

    minimum_successes = repeats if require_all_repeats else max(1, repeats - 1)
    enough_successes = len(runs) >= minimum_successes
    result_summary: dict[str, Any] = {
        "ok": enough_successes,
        "successful_runs": len(runs),
        "attempted_runs": executed_runs,
        "planned_runs": repeats,
        "skipped_runs": skipped_runs,
        "timeout_runs": timeout_runs,
        "speed_samples_Mbps": ",".join(speed_samples),
        "ttfb_samples_ms": ",".join(ttfb_samples),
        "run_errors": "；".join(run_errors),
        "error": "" if enough_successes else (
            f"成功 {len(runs)}/{repeats} 次；"
            + ("；".join(errors) if errors else "有效次数不足")
        ),
    }
    if not runs:
        return result_summary

    speed_values = [float(x["speed_Mbps"]) for x in runs]
    speed_mb_values = [
        float(x.get("speed_MB_per_s", x.get("speed_MBps", 0)))
        for x in runs
    ]
    ttfb_values = [float(x["ttfb_ms"]) for x in runs]
    total_values = [float(x["total_ms"]) for x in runs]
    mean_speed = statistics.fmean(speed_values)
    speed_stddev = (
        statistics.pstdev(speed_values) if len(speed_values) > 1 else 0.0
    )
    result_summary.update({
        "speed_Mbps": round(mean_speed, 2),
        "speed_MB_per_s": round(statistics.fmean(speed_mb_values), 2),
        "ttfb_ms": round(statistics.fmean(ttfb_values), 2),
        "total_ms": round(statistics.fmean(total_values), 2),
        "speed_stddev_Mbps": round(speed_stddev, 2),
        "speed_cv": round(speed_stddev / max(mean_speed, 0.001), 4),
        "ttfb_stddev_ms": round(
            statistics.pstdev(ttfb_values) if len(ttfb_values) > 1 else 0.0,
            2,
        ),
    })
    return result_summary


def build_interleaved_round_orders(
    node_names: list[str], repeats: int, rng: random.Random
) -> list[list[str]]:
    """Build balanced per-round orders for fair comparison over time."""
    unique_names = list(dict.fromkeys(node_names))
    repeats = max(1, int(repeats))
    if not unique_names:
        return [[] for _ in range(repeats)]
    base = list(unique_names)
    rng.shuffle(base)
    count = len(base)
    orders: list[list[str]] = []
    for round_index in range(repeats):
        offset = (round_index * count) // repeats
        order = base[offset:] + base[:offset]
        if round_index % 2 == 1:
            order.reverse()
        orders.append(order)
    return orders


def interleaved_speed_tests(
    node_names: list[str],
    run_one: Any,
    repeats: int,
    repeat_interval_seconds: float,
    require_all_repeats: bool,
    rng: random.Random,
) -> dict[str, dict[str, Any]]:
    """Run one download measurement per candidate per round."""
    repeats = max(1, int(repeats))
    names = list(dict.fromkeys(node_names))
    results: dict[str, list[dict[str, Any] | None]] = {
        name: [] for name in names
    }
    failed: set[str] = set()
    orders = build_interleaved_round_orders(names, repeats, rng)

    for round_index, order in enumerate(orders, 1):
        log(f"交错正式测速第 {round_index}/{repeats} 轮：{len(order)} 个候选")
        for node_name in order:
            if require_all_repeats and node_name in failed:
                results[node_name].append(None)
                log(f"{node_name} 第 {round_index}/{repeats} 次：SKIP")
                continue
            result = run_one(node_name, round_index)
            results[node_name].append(result)
            if result.get("ok"):
                log(
                    f"{node_name} 第 {round_index}/{repeats} 次："
                    f"{result.get('speed_Mbps', 0)} Mbps，"
                    f"TTFB {result.get('ttfb_ms', 0)} ms"
                )
            else:
                error = str(result.get("error", "未知错误"))
                log(
                    f"{node_name} 第 {round_index}/{repeats} 次失败：{error}"
                )
                if require_all_repeats:
                    failed.add(node_name)
        if round_index < repeats:
            time.sleep(max(0.0, float(repeat_interval_seconds)))

    return {
        name: summarize_speed_test_rounds(
            results[name], repeats, require_all_repeats
        )
        for name in names
    }


def normalize_fast_speed_ratio(value: Any) -> float:
    try:
        ratio = float(value)
    except (TypeError, ValueError):
        ratio = 0.95
    return min(1.0, max(0.50, ratio))


def rank_rows(
    rows: list[dict[str, Any]],
    fast_speed_ratio: float,
) -> list[dict[str, Any]]:
    """
    Selection policy:
    1. Find the fastest measured download speed in this round.
    2. Put nodes reaching fast_speed_ratio of that speed into the fast group.
    3. Inside the fast group, lower proxy delay wins.
    4. Nodes outside the fast group are ordered by speed, then delay.

    A ratio such as 0.95 avoids switching just because of a tiny, noisy
    single-run speed difference.
    """
    valid = [x for x in rows if x.get("speed_ok")]
    if not valid:
        return []

    ratio = normalize_fast_speed_ratio(fast_speed_ratio)
    max_speed = max(float(x["speed_Mbps"]) for x in valid)
    speed_floor = max_speed * ratio

    for row in valid:
        speed = float(row["speed_Mbps"])
        row["max_speed_Mbps"] = round(max_speed, 2)
        row["fast_speed_floor_Mbps"] = round(speed_floor, 2)
        row["speed_ratio_to_best"] = round(
            speed / max(max_speed, 0.001), 4
        )
        row["fast_group"] = speed >= speed_floor
        # Retain a readable score, but it no longer controls selection.
        row["score"] = round(
            100.0 * row["speed_ratio_to_best"], 2
        )

    fast_group = [x for x in valid if x["fast_group"]]
    other_group = [x for x in valid if not x["fast_group"]]

    # User's requested priority: among the fastest nodes, choose lowest delay.
    fast_group.sort(
        key=lambda x: (
            float(x["delay_ms"]),
            -float(x["speed_Mbps"]),
            float(x.get("ttfb_ms") or 1e9),
        )
    )
    other_group.sort(
        key=lambda x: (
            -float(x["speed_Mbps"]),
            float(x["delay_ms"]),
            float(x.get("ttfb_ms") or 1e9),
        )
    )
    return fast_group + other_group

def write_latest(rows: list[dict[str, Any]]) -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    fields = [
        "time",
        "ip",
        "protocol",
        "port",
        "discovery_node",
        "delay_ms",
        "delay_stddev_ms",
        "delay_samples_ms",
        "speed_Mbps",
        "speed_MB_per_s",
        "ttfb_ms",
        "total_ms",
        "speed_stddev_Mbps",
        "speed_cv",
        "speed_stable",
        "ttfb_stddev_ms",
        "speed_samples_Mbps",
        "ttfb_samples_ms",
        "run_errors",
        "successful_runs",
        "attempted_runs",
        "planned_runs",
        "skipped_runs",
        "timeout_runs",
        "score",
        "fast_group",
        "speed_ratio_to_best",
        "max_speed_Mbps",
        "fast_speed_floor_Mbps",
        "speed_ok",
        "error",
    ]
    with LATEST_CSV.open("w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def append_history(
    ranked: list[dict[str, Any]], max_rows: int = 10_000
) -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    fields = [
        "time",
        "protocol",
        "port",
        "ip",
        "delay_ms",
        "speed_Mbps",
        "score",
    ]
    max_rows = max(100, int(max_rows))
    try:
        existing_rows: list[dict[str, Any]] = []
        if HISTORY_PATH.exists():
            with HISTORY_PATH.open(
                "r", encoding="utf-8-sig", newline=""
            ) as f:
                existing_rows = list(csv.DictReader(f))
        rows = [*existing_rows, *ranked][-max_rows:]
        tmp = HISTORY_PATH.with_suffix(HISTORY_PATH.suffix + ".tmp")
        with tmp.open("w", encoding="utf-8-sig", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
            writer.writeheader()
            writer.writerows(rows)
        os.replace(tmp, HISTORY_PATH)
    except OSError as exc:
        log(f"裁剪历史 CSV 失败：{exc}")


def build_active_pool(
    ranked: list[dict[str, Any]],
    delays: dict[str, float],
    previous_active: list[str],
    current_ip: str | None,
    pool_size: int,
    excluded_ips: set[str] | None = None,
    allow_delay_only_backfill: bool = False,
) -> list[str]:
    result: list[str] = []
    excluded = excluded_ips or set()

    def add(ip: str | None) -> None:
        if ip and ip not in excluded and ip not in result:
            result.append(ip)

    # Keep current first so provider refresh does not remove the live node.
    add(current_ip)
    for row in ranked:
        add(row["ip"])
    for ip in previous_active:
        add(ip)
    if allow_delay_only_backfill:
        for node_name, _ in sorted(delays.items(), key=lambda x: x[1]):
            add(ip_from_node_name(node_name))
    return result[:pool_size]


def parse_time(value: str | None) -> dt.datetime | None:
    if not value:
        return None
    try:
        return dt.datetime.fromisoformat(value)
    except ValueError:
        return None


def decide_switch(
    api: MihomoAPI,
    settings: dict[str, Any],
    ranked: list[dict[str, Any]],
    current_ip: str | None,
    state: dict[str, Any],
    *,
    timeout_observer: Any | None = None,
) -> dict[str, Any]:
    """
    Switch to the lowest-latency node inside the fastest-speed band.

    Anti-flap rules still apply:
    - candidate must win required_consecutive_wins rounds;
    - current fast-group node is replaced only for a meaningful latency gain;
    - normal switches respect minimum_switch_interval_hours;
    - an unavailable current node is replaced immediately.
    """
    decision: dict[str, Any] = {
        "time": now_iso(),
        "current_ip_before": current_ip,
        "switched": False,
        "reason": "",
        "best": ranked[0] if ranked else None,
        "selection_policy": "fastest_band_then_lowest_latency",
    }
    if not ranked:
        decision["reason"] = "没有候选完成实际下载测速"
        return decision

    best = ranked[0]
    best_ip = str(best["ip"])
    best_active_name = f"CF-A | {best_ip}"
    fast_ratio = normalize_fast_speed_ratio(
        settings.get("fast_speed_ratio", 0.95)
    )
    max_speed = max(float(x["speed_Mbps"]) for x in ranked)
    speed_floor = max_speed * fast_ratio

    decision["max_speed_Mbps"] = round(max_speed, 2)
    decision["fast_speed_floor_Mbps"] = round(speed_floor, 2)
    selection_timeout = settings.get("selector_confirm_timeout_seconds", 3.0)
    poll_interval = settings.get("mihomo_poll_interval_seconds", 0.05)

    if current_ip == best_ip:
        state["pending_ip"] = ""
        state["pending_wins"] = 0
        decision["reason"] = "当前 IP 已是高速组中延迟最低的节点"
        return decision

    current_row = next((x for x in ranked if x["ip"] == current_ip), None)
    if current_ip is None or current_row is None:
        select_proxy_and_wait(
            api,
            str(settings["auto_group"]),
            best_active_name,
            selection_timeout,
            poll_interval,
            timeout_observer=timeout_observer,
        )
        state["pending_ip"] = ""
        state["pending_wins"] = 0
        state["last_switch"] = now_iso()
        state["current_ip"] = best_ip
        decision["switched"] = True
        decision["current_ip_after"] = best_ip
        decision["reason"] = "当前 IP 未通过本轮真实链路测速，立即切换到高速组最低延迟节点"
        return decision

    current_speed = float(current_row["speed_Mbps"])
    current_delay = float(current_row["delay_ms"])
    best_speed = float(best["speed_Mbps"])
    best_delay = float(best["delay_ms"])
    current_in_fast_group = current_speed >= speed_floor

    latency_gain_ms = current_delay - best_delay
    latency_gain_ratio = latency_gain_ms / max(current_delay, 1.0)
    minimum_latency_gain_ms = float(
        settings.get("minimum_latency_gain_ms", 5)
    )
    minimum_latency_gain_ratio = float(
        settings.get("minimum_latency_gain_ratio", 0.03)
    )

    if current_in_fast_group:
        qualifies = (
            latency_gain_ms >= minimum_latency_gain_ms
            or latency_gain_ratio >= minimum_latency_gain_ratio
        )
    else:
        # The current node is no longer in the fastest-speed band.
        qualifies = True

    decision.update(
        {
            "current_metrics": current_row,
            "current_in_fast_group": current_in_fast_group,
            "latency_gain_ms": round(latency_gain_ms, 2),
            "latency_gain_ratio": round(latency_gain_ratio, 4),
            "best_speed_vs_current_ratio": round(
                best_speed / max(current_speed, 0.001), 4
            ),
            "qualifies": qualifies,
        }
    )

    if not qualifies:
        state["pending_ip"] = ""
        state["pending_wins"] = 0
        decision["reason"] = (
            "当前 IP 仍在高速组内，候选延迟优势不足，保持当前节点"
        )
        return decision

    if state.get("pending_ip") == best_ip:
        state["pending_wins"] = int(state.get("pending_wins", 0)) + 1
    else:
        state["pending_ip"] = best_ip
        state["pending_wins"] = 1

    required = int(settings.get("required_consecutive_wins", 2))
    if int(state["pending_wins"]) < required:
        decision["reason"] = (
            f"高速组最低延迟候选已连续胜出 "
            f"{state['pending_wins']}/{required} 轮，暂不切换"
        )
        return decision

    last_switch = parse_time(state.get("last_switch"))
    min_hours = float(settings.get("minimum_switch_interval_hours", 1))
    if last_switch is not None:
        elapsed = (now() - last_switch).total_seconds() / 3600
        if elapsed < min_hours:
            decision["reason"] = (
                f"候选满足条件，但距上次切换仅 {elapsed:.1f} 小时；"
                f"最小间隔 {min_hours:g} 小时"
            )
            return decision

    select_proxy_and_wait(
        api,
        str(settings["auto_group"]),
        best_active_name,
        selection_timeout,
        poll_interval,
        timeout_observer=timeout_observer,
    )
    state["pending_ip"] = ""
    state["pending_wins"] = 0
    state["last_switch"] = now_iso()
    state["current_ip"] = best_ip
    decision["switched"] = True
    decision["current_ip_after"] = best_ip
    decision["reason"] = "已切换到下载速度高速组中代理延迟最低的节点"
    return decision

def diagnose(api: MihomoAPI, settings: dict[str, Any]) -> int:
    template = load_template()
    node_protocol, node_port = template_endpoint(template)
    version = api.version()
    auto = api.get_proxy(str(settings["auto_group"]))
    discovery = api.get_proxy(str(settings["discovery_group"]))
    parent = api.get_proxy(str(settings["parent_group"]))
    parent_now = str(parent.get("now", ""))
    auto_group = str(settings["auto_group"])

    try:
        ACTIVE_PROVIDER_PATH.resolve().relative_to(VERGE_HOME.resolve())
        DISCOVERY_PROVIDER_PATH.resolve().relative_to(VERGE_HOME.resolve())
        providers_in_safe_paths = True
    except ValueError:
        providers_in_safe_paths = False

    issues: list[str] = []
    if parent_now != auto_group:
        issues.append(
            f"{settings['parent_group']} 当前指向 {parent_now or '未知'}，"
            f"应指向 {auto_group}"
        )
    if not providers_in_safe_paths:
        issues.append("provider 路径不在 Clash Verge Rev SAFE_PATHS 内")
    for provider_path in (ACTIVE_PROVIDER_PATH, DISCOVERY_PROVIDER_PATH):
        if not provider_path.is_file():
            issues.append(f"provider 文件不存在：{provider_path}")

    print("Mihomo API：正常")
    print("版本：", version.get("version", "未知"))
    print("自动选择当前节点：", auto.get("now"))
    print("节点选择当前策略：", parent_now or "未知")
    print("正式池节点数：", len(auto.get("all", [])))
    print("发现池节点数：", len(discovery.get("all", [])))
    print("本地代理：", settings["mixed_proxy"])
    print("节点模板：", f"{node_protocol} / TCP {node_port}")
    print("provider SAFE_PATHS：", "正常" if providers_in_safe_paths else "异常")
    print("provider 目录：", PROVIDER_DIR)
    if issues:
        for issue in issues:
            print("诊断失败：", issue)
        return 1
    return 0


def main() -> int:
    global NOTIFICATION_REPORT_RETENTION_DAYS
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            try:
                stream.reconfigure(encoding="utf-8", errors="replace")
            except (OSError, ValueError):
                pass
    parser = argparse.ArgumentParser(
        description="Cloudflare 新 IP 动态发现与 Clash/Mihomo 自动优选"
    )
    parser.add_argument("--diagnose", action="store_true", help="检查 API 和策略组")
    parser.add_argument(
        "--quick",
        action="store_true",
        help="轻量模式：抽样最多 200 个新 IP，并减少下载测速流量",
    )
    args = parser.parse_args()

    lock_handle: Any | None = None
    settings: dict[str, Any] = {}
    failed_ips: set[str] = set()
    failure_summary: dict[str, Any] = {}
    failure_ranked: list[dict[str, Any]] = []
    failure_rows: list[dict[str, Any]] = []
    current_ip = ""
    run_started = time.monotonic()
    run_started_at = now_iso()
    stage = "加载配置"
    deferred_count = 0
    timeout_counts = {
        "candidate_generation": 0,
        "tcp_probe": 0,
        "discovery_provider": 0,
        "proxy_delay": 0,
        "speed_probe": 0,
        "formal_speed": 0,
        "active_provider": 0,
        "decision": 0,
    }
    stage_timer = StageTimer()
    stage_timer.start("startup")

    def enter_stage(error_stage: str, timing_stage: str) -> None:
        nonlocal stage
        stage = error_stage
        stage_timer.start(timing_stage)

    def record_timeout(stage_name: str) -> None:
        timeout_counts[stage_name] = timeout_counts.get(stage_name, 0) + 1

    try:
        settings = load_settings()
        try:
            NOTIFICATION_REPORT_RETENTION_DAYS = min(
                3650.0,
                max(
                    1.0,
                    float(settings.get("notification_report_retention_days", 30)),
                ),
            )
        except (TypeError, ValueError):
            NOTIFICATION_REPORT_RETENTION_DAYS = 30.0
        configure_runtime_limits(settings)
        api = MihomoAPI(
            str(settings["controller"]),
            str(settings.get("secret", "")),
        )
        if args.diagnose:
            return diagnose(api, settings)

        set_low_process_priority()
        enter_stage("等待前台空闲", "startup")
        deferred_result = defer_deep_scan_if_busy(settings, args.quick)
        if deferred_result is None:
            try_write_run_status(
                args.quick,
                "skipped",
                run_started_at,
                reason="前台持续繁忙，本轮深度扫描已跳过",
            )
            return 0
        deferred_count = deferred_result

        enter_stage("加载模板", "maintenance")
        template = load_template()
        node_protocol, candidate_port = template_endpoint(template)
        failure_summary.update(
            {
                "summary_schema_version": 2,
                "node_protocol": node_protocol,
                "node_port": candidate_port,
            }
        )
        log(
            f"节点模板：协议 {node_protocol}，"
            f"TCP 端口 {candidate_port}"
        )
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        lock_handle = try_acquire_run_lock()
        if lock_handle is None:
            mode = "轻量" if args.quick else "深度"
            message = f"已有扫描正在运行，本轮{mode}扫描跳过"
            log(message)
            send_windows_notification(
                f"Clash {mode}扫描：本轮已跳过",
                message,
            )
            try_write_run_status(
                args.quick, "skipped", run_started_at, reason=message
            )
            return 0

        enter_stage("清理过期备份", "maintenance")
        deleted_backups = cleanup_managed_backups(
            BACKUP_DIR,
            retention_days=settings.get("backup_retention_days", 30),
            minimum_keep=settings.get("backup_minimum_keep", 10),
            logger=lambda message: log(f"备份清理：{message}"),
        )
        if deleted_backups:
            log(f"已清理 {deleted_backups} 个过期备份目录")

        deleted_root_backups = cleanup_root_backup_files(
            ROOT,
            keep_per_file=settings.get("backup_root_keep_per_file", 3),
            retention_days=settings.get("backup_retention_days", 30),
            logger=lambda message: log(f"备份清理：{message}"),
        )
        if deleted_root_backups:
            log(f"已清理 {deleted_root_backups} 个过期根目录备份文件")

        if not args.quick:
            enter_stage("清理扫描历史", "maintenance")
            deleted = cleanup_discovery_history(
                float(settings.get("discovery_history_retention_days", 30)),
                int(settings.get("vacuum_after_deleted_rows", 5000)),
            )
            if deleted:
                log(f"已清理 {deleted} 条过期 IP 扫描历史")

        if args.quick:
            settings["random_samples_per_run"] = min(
                int(settings["random_samples_per_run"]), 200
            )
            settings["discovery_provider_limit"] = min(
                int(settings["discovery_provider_limit"]), 120
            )
            settings["speed_candidates"] = min(
                int(settings["speed_candidates"]), 8
            )
            settings["speed_test_bytes"] = min(
                int(settings["speed_test_bytes"]), 1_000_000
            )
            settings["speed_probe_candidates"] = min(
                int(settings.get("speed_probe_candidates", 24)), 24
            )
            settings["speed_probe_bytes"] = min(
                int(settings.get("speed_probe_bytes", 250_000)), 250_000
            )
            settings["tcp_workers"] = min(
                int(settings.get("tcp_workers", 64)), 48
            )

        enter_stage("连接 Mihomo API", "candidate_generation")
        try:
            version = api.version()
        except Exception as exc:
            if caused_by_transport_timeout(exc):
                record_timeout("candidate_generation")
            raise
        log(f"Mihomo API 已连接，版本 {version.get('version', '未知')}")

        enter_stage("读取当前节点", "candidate_generation")
        try:
            auto_info = api.get_proxy(str(settings["auto_group"]))
        except Exception as exc:
            if caused_by_transport_timeout(exc):
                record_timeout("candidate_generation")
            raise
        current_name = str(auto_info.get("now", ""))
        current_ip = ip_from_node_name(current_name)
        previous_active = read_provider_ips(ACTIVE_PROVIDER_PATH)

        enter_stage("获取 Cloudflare 网段", "candidate_generation")
        ranges = load_official_ranges(
            settings,
            timeout_observer=lambda: record_timeout("candidate_generation"),
        )
        log(f"Cloudflare 官方 IPv4 网段：{len(ranges)} 个")

        rng = random.Random()
        candidates, fixed, fresh_random, reused_random = generate_candidates(
            ranges, settings, rng, candidate_port
        )
        failure_summary["candidate_count"] = len(candidates)
        log(
            f"本轮候选 {len(candidates)} 个：固定/历史 {len(fixed)} 个，"
            f"30 天内未测随机 {fresh_random} 个，"
            f"重复随机 {reused_random} 个，其余为优胜邻域"
        )

        enter_stage(f"TCP {candidate_port} 初筛", "tcp_probe")
        tcp_rows = tcp_stage(candidates, settings, candidate_port)
        write_discovery_log(tcp_rows, node_protocol)
        record_tcp_history(tcp_rows)
        reachable_count = sum(1 for x in tcp_rows if x["reachable"])
        timeout_counts["tcp_probe"] = sum(
            int(row.get("timeout_count", 0)) for row in tcp_rows
        )
        failed_ips = {
            str(row["ip"]) for row in tcp_rows if not row.get("reachable")
        }
        failure_summary.update(
            {
                "tcp_reachable_count": reachable_count,
                "tcp_failed_count": len(tcp_rows) - reachable_count,
                "failed_count": len(failed_ips),
            }
        )
        log(
            f"TCP {candidate_port} 可连接："
            f"{reachable_count}/{len(tcp_rows)}"
        )

        discovery_ips = select_discovery_ips(
            tcp_rows,
            fixed,
            int(settings["discovery_provider_limit"]),
            current_ip,
            set(previous_active),
            settings.get("discovery_new_ip_share", 0.40),
        )
        failure_summary.update(
            {
                "discovery_pool_count": len(discovery_ips),
                "discovery_not_selected_count": max(
                    0, reachable_count - len(discovery_ips)
                ),
            }
        )
        if not discovery_ips:
            raise RuntimeError("没有可写入发现池的候选 IP")
        discovery_new_count = sum(1 for ip in discovery_ips if ip not in fixed)
        failure_summary["discovery_new_count"] = discovery_new_count
        log(
            f"发现池组成：固定/历史 {len(discovery_ips) - discovery_new_count} 个，"
            f"新 IP {discovery_new_count} 个"
        )

        enter_stage("更新发现池 provider", "discovery_provider")
        update_provider_safely(
            api,
            str(settings["discovery_provider_name"]),
            str(settings["discovery_group"]),
            DISCOVERY_PROVIDER_PATH,
            template,
            discovery_ips,
            "CF-D",
            settle_seconds=float(
                settings.get("provider_confirm_timeout_seconds", 8.0)
            ),
            poll_interval_seconds=float(
                settings.get("mihomo_poll_interval_seconds", 0.05)
            ),
            timeout_observer=lambda: record_timeout("discovery_provider"),
        )

        enter_stage("三轮真实代理链路延迟测试", "proxy_delay")
        delays, delay_samples, delay_stddev = average_group_delays(
            api,
            str(settings["discovery_group"]),
            str(settings["delay_test_url"]),
            int(settings["delay_timeout_ms"]),
            int(settings.get("delay_repeats", 3)),
            float(settings.get("delay_repeat_interval_seconds", 0.5)),
            bool(settings.get("require_all_repeats", True)),
            timeout_observer=lambda: record_timeout("proxy_delay"),
        )
        log(
            f"三轮平均延迟有效：{len(delays)}/{len(discovery_ips)}"
        )
        failure_summary.update(
            {
                "proxy_valid_count": len(delays),
                "proxy_failed_count": max(0, len(discovery_ips) - len(delays)),
            }
        )
        valid_delay_ips = {
            ip
            for ip in (ip_from_node_name(name) for name in delays)
            if ip
        }
        failed_ips.update(set(discovery_ips).difference(valid_delay_ips))
        failure_summary["failed_count"] = len(failed_ips)
        if not delays:
            raise RuntimeError("发现池全部真实代理链路三轮测试失败")
        record_vm_history(list(delays))

        speed_count = max(1, int(settings["speed_candidates"]))
        current_discovery_name = (
            f"CF-D | {current_ip}" if current_ip else None
        )
        curl_bin = find_curl()
        probe_names, probe_counts = select_speed_probe_names(
            delays,
            fixed,
            current_discovery_name,
            settings,
            rng,
        )
        failure_summary.update(
            {
                "speed_probe_selected_count": len(probe_names),
                "speed_probe_not_selected_count": max(
                    0, len(delays) - len(probe_names)
                ),
            }
        )
        log(
            f"速度粗测池 {len(probe_names)} 个：低延迟 "
            f"{probe_counts.get('low_latency', 0)}，历史高速 "
            f"{probe_counts.get('history', 0)}，随机探索 "
            f"{probe_counts.get('exploration', 0)}，当前节点追加 "
            f"{probe_counts.get('current_extra', 0)}"
        )

        enter_stage("速度粗测", "speed_probe")
        probe_rows: list[dict[str, Any]] = []
        for index, node_name in enumerate(probe_names, 1):
            ip = ip_from_node_name(node_name)
            if not ip:
                continue

            try:
                select_proxy_and_wait(
                    api,
                    str(settings["discovery_group"]),
                    node_name,
                    settings.get("selector_confirm_timeout_seconds", 3.0),
                    settings.get("mihomo_poll_interval_seconds", 0.05),
                    timeout_observer=lambda: record_timeout("speed_probe"),
                )
            except MihomoConfirmationTimeout as exc:
                probe_row = {
                    "time": now_iso(),
                    "ip": ip,
                    "protocol": node_protocol,
                    "port": candidate_port,
                    "node": node_name,
                    "delay_ms": delays[node_name],
                    "speed_ok": False,
                    "speed_Mbps": 0.0,
                    "ttfb_ms": None,
                    "size_download": 0,
                    "timed_out": False,
                    "error": f"节点选择确认失败：{exc}",
                }
                probe_rows.append(probe_row)
                failed_ips.add(ip)
                log(
                    f"速度粗测 {index}/{len(probe_names)}：{ip} 节点选择失败，"
                    f"跳过：{exc}"
                )
                continue

            result = speed_test(
                curl_bin,
                str(settings["mixed_proxy"]),
                str(settings["speed_test_base_url"]),
                int(settings.get("speed_probe_bytes", 250_000)),
                float(settings.get("speed_probe_timeout_seconds", 10)),
            )
            probe_row = {
                "time": now_iso(),
                "ip": ip,
                "protocol": node_protocol,
                "port": candidate_port,
                "node": node_name,
                "delay_ms": delays[node_name],
                "speed_ok": bool(result.get("ok")),
                "speed_Mbps": result.get("speed_Mbps", 0.0),
                "ttfb_ms": result.get("ttfb_ms"),
                "size_download": result.get("size_download", 0),
                "timed_out": bool(result.get("timed_out")),
                "error": result.get("error", ""),
            }
            probe_rows.append(probe_row)
            if probe_row["timed_out"]:
                timeout_counts["speed_probe"] += 1
            if probe_row["speed_ok"]:
                log(
                    f"速度粗测 {index}/{len(probe_names)}：{ip} | "
                    f"{probe_row['speed_Mbps']} Mbps | "
                    f"平均延迟 {delays[node_name]} ms"
                )
            else:
                failed_ips.add(ip)
                log(
                    f"速度粗测 {index}/{len(probe_names)}：{ip} 失败，"
                    f"本轮淘汰：{probe_row['error']}"
                )
        write_speed_probe_log(probe_rows)
        record_speed_history(probe_rows)

        passed_probe_rows = [row for row in probe_rows if row["speed_ok"]]
        passed_probe_rows.sort(
            key=lambda row: (
                -float(row["speed_Mbps"]),
                float(row["delay_ms"]),
            )
        )
        candidate_names = [
            str(row["node"]) for row in passed_probe_rows[:speed_count]
        ]
        passed_probe_names = {
            str(row["node"]) for row in passed_probe_rows
        }
        failure_summary.update(
            {
                "speed_probe_attempted_count": len(probe_rows),
                "speed_probe_passed_count": len(passed_probe_rows),
                "speed_probe_failed_count": len(probe_rows)
                - len(passed_probe_rows),
                "speed_probe_selected_not_attempted_count": max(
                    0, len(probe_names) - len(probe_rows)
                ),
                "failed_count": len(failed_ips),
            }
        )
        if (
            current_discovery_name
            and current_discovery_name in passed_probe_names
            and current_discovery_name not in candidate_names
        ):
            candidate_names.append(current_discovery_name)
        failure_summary.update(
            {
                "formal_selected_count": len(candidate_names),
                "formal_not_selected_count": max(
                    0, len(passed_probe_rows) - len(candidate_names)
                ),
            }
        )
        if not candidate_names:
            raise RuntimeError("速度粗测没有节点通过，保留上一版正式池")

        enter_stage("三轮正式下载测速", "formal_speed")
        rows: list[dict[str, Any]] = []
        maximum_speed_cv = max(
            0.0, float(settings.get("maximum_speed_cv", 0.45))
        )
        speed_repeats = int(settings.get("speed_repeats", 3))
        require_all_speed_repeats = bool(
            settings.get("require_all_repeats", True)
        )
        for index, node_name in enumerate(candidate_names, 1):
            ip = ip_from_node_name(node_name)
            if not ip:
                continue
            log(
                f"正式测速候选 {index}/{len(candidate_names)}："
                f"{ip}（三轮平均代理延迟 {delays[node_name]} ms，"
                f"原始值 {delay_samples.get(node_name, [])}）"
            )

        def run_formal_speed_round(
            node_name: str, round_index: int
        ) -> dict[str, Any]:
            try:
                select_proxy_and_wait(
                    api,
                    str(settings["discovery_group"]),
                    node_name,
                    settings.get("selector_confirm_timeout_seconds", 3.0),
                    settings.get("mihomo_poll_interval_seconds", 0.05),
                    timeout_observer=lambda: record_timeout("formal_speed"),
                )
            except MihomoConfirmationTimeout as exc:
                return {
                    "ok": False,
                    # The observer above already records this control-plane timeout.
                    "timed_out": False,
                    "error": f"节点选择确认失败：{exc}",
                }
            return speed_test(
                curl_bin,
                str(settings["mixed_proxy"]),
                str(settings["speed_test_base_url"]),
                int(settings["speed_test_bytes"]),
                float(settings["speed_timeout_seconds"]),
            )

        interleaved_results = interleaved_speed_tests(
            candidate_names,
            run_formal_speed_round,
            speed_repeats,
            float(settings.get("speed_repeat_interval_seconds", 0.5)),
            require_all_speed_repeats,
            rng,
        )

        for node_name in candidate_names:
            ip = ip_from_node_name(node_name)
            if not ip:
                continue
            result = interleaved_results[node_name]
            timeout_counts["formal_speed"] += int(
                result.get("timeout_runs", 0)
            )
            speed_cv = float(result.get("speed_cv", 0.0))
            speed_stable = bool(result.get("ok")) and (
                speed_cv <= maximum_speed_cv
            )
            speed_ok = bool(result.get("ok")) and speed_stable
            error = str(result.get("error", ""))
            if result.get("ok") and not speed_stable:
                error = (
                    f"三次速度波动过大：CV={speed_cv:.1%}，"
                    f"上限={maximum_speed_cv:.1%}"
                )
                log(f"{ip} {error}，本轮淘汰")
            if not speed_ok:
                failed_ips.add(ip)
            rows.append(
                {
                    "time": now_iso(),
                    "ip": ip,
                    "protocol": node_protocol,
                    "port": candidate_port,
                    "discovery_node": node_name,
                    "delay_ms": delays[node_name],
                    "delay_stddev_ms": delay_stddev.get(node_name, 0.0),
                    "delay_samples_ms": ",".join(
                        str(x) for x in delay_samples.get(node_name, [])
                    ),
                    "speed_ok": speed_ok,
                    "speed_stable": speed_stable,
                    "speed_Mbps": result.get("speed_Mbps", 0.0),
                    "speed_MB_per_s": result.get("speed_MB_per_s", 0.0),
                    "ttfb_ms": result.get("ttfb_ms"),
                    "total_ms": result.get("total_ms"),
                    "speed_stddev_Mbps": result.get("speed_stddev_Mbps"),
                    "speed_cv": result.get("speed_cv"),
                    "ttfb_stddev_ms": result.get("ttfb_stddev_ms"),
                    "speed_samples_Mbps": result.get(
                        "speed_samples_Mbps", ""
                    ),
                    "ttfb_samples_ms": result.get("ttfb_samples_ms", ""),
                    "run_errors": result.get("run_errors", ""),
                    "successful_runs": result.get("successful_runs", 0),
                    "attempted_runs": result.get("attempted_runs", 0),
                    "planned_runs": result.get("planned_runs", 0),
                    "skipped_runs": result.get("skipped_runs", 0),
                    "timeout_runs": result.get("timeout_runs", 0),
                    "error": error,
                }
            )

        ranked = rank_rows(
            rows,
            float(settings.get("fast_speed_ratio", 0.95)),
        )
        record_speed_history(rows)
        failed_rows = [x for x in rows if not x.get("speed_ok")]
        failure_ranked = ranked
        failure_rows = failed_rows
        failure_summary.update(
            {
                "formal_attempted_count": len(rows),
                "formal_passed_count": len(ranked),
                "formal_failed_count": len(failed_rows),
                "formal_selected_not_attempted_count": max(
                    0, len(candidate_names) - len(rows)
                ),
                "fast_group_count": sum(
                    1 for row in ranked if row.get("fast_group")
                ),
                "outside_fast_group_count": sum(
                    1 for row in ranked if not row.get("fast_group")
                ),
                "fast_speed_ratio": normalize_fast_speed_ratio(
                    settings.get("fast_speed_ratio", 0.95)
                ),
                "failed_count": len(failed_ips),
            }
        )
        write_latest(ranked + failed_rows)
        append_history(
            ranked,
            int(settings.get("history_max_rows", 10_000)),
        )
        if not ranked:
            raise RuntimeError(
                "没有节点通过三次正式下载测速，保留上一版正式池"
            )

        enter_stage("生成正式节点池", "active_provider")
        active_ips = build_active_pool(
            ranked,
            delays,
            previous_active,
            current_ip,
            int(settings["active_pool_size"]),
            failed_ips,
            bool(settings.get("allow_delay_only_pool_backfill", False)),
        )
        if not active_ips:
            raise RuntimeError("未生成正式优选池")

        enter_stage("更新正式池 provider", "active_provider")
        update_provider_safely(
            api,
            str(settings["active_provider_name"]),
            str(settings["auto_group"]),
            ACTIVE_PROVIDER_PATH,
            template,
            active_ips,
            "CF-A",
            settle_seconds=float(
                settings.get("provider_confirm_timeout_seconds", 8.0)
            ),
            poll_interval_seconds=float(
                settings.get("mihomo_poll_interval_seconds", 0.05)
            ),
            timeout_observer=lambda: record_timeout("active_provider"),
        )

        BEST_IPS_PATH.write_text(
            "\n".join(active_ips) + "\n", encoding="utf-8"
        )

        enter_stage("计算切换决策", "decision")
        state = load_json(
            STATE_PATH,
            {
                "pending_ip": "",
                "pending_wins": 0,
                "last_switch": None,
                "current_ip": current_ip,
            },
        )
        decision = decide_switch(
            api,
            settings,
            ranked,
            current_ip,
            state,
            timeout_observer=lambda: record_timeout("decision"),
        )
        stage_durations = stage_timer.finish()
        tcp_failed_count = len(tcp_rows) - reachable_count
        discovery_not_selected_count = max(
            0, reachable_count - len(discovery_ips)
        )
        proxy_failed_count = max(0, len(discovery_ips) - len(delays))
        speed_probe_attempted_count = len(probe_rows)
        speed_probe_selected_count = len(probe_names)
        speed_probe_passed_count = len(passed_probe_rows)
        speed_probe_failed_count = (
            speed_probe_attempted_count - speed_probe_passed_count
        )
        speed_probe_not_selected_count = max(
            0, len(delays) - speed_probe_selected_count
        )
        speed_probe_selected_not_attempted_count = max(
            0, speed_probe_selected_count - speed_probe_attempted_count
        )
        formal_attempted_count = len(rows)
        formal_selected_count = len(candidate_names)
        formal_passed_count = len(ranked)
        formal_failed_count = len(failed_rows)
        formal_not_selected_count = max(
            0, speed_probe_passed_count - formal_selected_count
        )
        formal_selected_not_attempted_count = max(
            0, formal_selected_count - formal_attempted_count
        )
        fast_group_count = sum(1 for row in ranked if row.get("fast_group"))
        outside_fast_group_count = max(
            0, formal_passed_count - fast_group_count
        )
        stage_failed_count = (
            tcp_failed_count
            + proxy_failed_count
            + speed_probe_failed_count
            + formal_failed_count
        )
        summary = {
            "summary_schema_version": 2,
            "node_protocol": node_protocol,
            "node_port": candidate_port,
            "candidate_count": len(candidates),
            "tcp_reachable_count": reachable_count,
            "tcp_failed_count": tcp_failed_count,
            "discovery_pool_count": len(discovery_ips),
            "discovery_new_count": discovery_new_count,
            "discovery_not_selected_count": discovery_not_selected_count,
            "proxy_valid_count": len(delays),
            "proxy_failed_count": proxy_failed_count,
            "speed_probe_selected_count": speed_probe_selected_count,
            "speed_probe_attempted_count": speed_probe_attempted_count,
            "speed_probe_passed_count": speed_probe_passed_count,
            "speed_probe_failed_count": speed_probe_failed_count,
            "speed_probe_not_selected_count": speed_probe_not_selected_count,
            "speed_probe_selected_not_attempted_count": (
                speed_probe_selected_not_attempted_count
            ),
            "formal_selected_count": formal_selected_count,
            "formal_attempted_count": formal_attempted_count,
            "formal_passed_count": formal_passed_count,
            "formal_failed_count": formal_failed_count,
            "formal_not_selected_count": formal_not_selected_count,
            "formal_selected_not_attempted_count": (
                formal_selected_not_attempted_count
            ),
            "fast_group_count": fast_group_count,
            "outside_fast_group_count": outside_fast_group_count,
            "fast_speed_ratio": normalize_fast_speed_ratio(
                settings.get("fast_speed_ratio", 0.95)
            ),
            # Backward-compatible aliases retained for existing consumers.
            "speed_passed_count": len(ranked),
            "speed_attempted_count": len(rows),
            "active_pool_size": len(active_ips),
            "new_active_count": len(set(active_ips).difference(previous_active)),
            "pool_size_delta": len(active_ips) - len(previous_active),
            "failed_count": len(failed_ips),
            "failure_event_count": stage_failed_count,
            "deferred_count": deferred_count,
            "duration_seconds": round(time.monotonic() - run_started, 1),
            "stage_durations_seconds": stage_durations,
            "timeout_counts": dict(timeout_counts),
            "timeout_count_total": sum(timeout_counts.values()),
        }
        decision["scan_summary"] = summary
        decision["node_protocol"] = node_protocol
        decision["node_port"] = candidate_port
        save_json_atomic(STATE_PATH, state)
        save_json_atomic(DECISION_JSON, decision)
        try_write_run_status(
            args.quick,
            "success",
            run_started_at,
            reason=str(decision.get("reason", "")),
            summary=summary,
        )

        if ranked:
            log("本轮实际下载测速排名：")
            for i, row in enumerate(ranked, 1):
                tag = "（新发现）" if row["ip"] not in fixed else ""
                group_tag = "【高速组】" if row.get("fast_group") else ""
                log(
                    f"{i}. {row['ip']} {tag}{group_tag} | "
                    f"平均延迟 {row['delay_ms']} ms "
                    f"(σ={row.get('delay_stddev_ms', 0)}) | "
                    f"平均速度 {row['speed_Mbps']} Mbps "
                    f"(σ={row.get('speed_stddev_Mbps', 0)}) | "
                    f"最高速占比 {row.get('speed_ratio_to_best', 0) * 100:.1f}%"
                )
        log(
            f"正式池已更新为 {len(active_ips)} 个 IP；"
            f"其中本轮新发现并进入正式池 "
            f"{sum(1 for x in active_ips if x not in fixed)} 个；"
            f"各阶段失败 IP {len(failed_ips)} 个"
        )
        log(
            "阶段漏斗："
            f"{len(candidates)} → TCP {reachable_count} → "
            f"代理 {len(delays)} → "
            f"粗测 {speed_probe_passed_count}/{speed_probe_attempted_count} → "
            f"正式 {formal_passed_count}/{formal_attempted_count}"
        )
        log(
            "阶段失败："
            f"TCP {tcp_failed_count}，代理 {proxy_failed_count}，"
            f"粗测 {speed_probe_failed_count}，正式 {formal_failed_count}；"
            "未入选："
            f"TCP 后 {discovery_not_selected_count}，"
            f"代理后 {speed_probe_not_selected_count}，"
            f"粗测后 {formal_not_selected_count}，"
            f"高速组外 {outside_fast_group_count}（非失败）"
        )
        log(f"切换决策：{decision['reason']}")
        log(
            "阶段耗时："
            + "，".join(
                f"{name}={seconds:.3f}s"
                for name, seconds in stage_durations.items()
            )
        )
        log(f"超时次数：{format_timeout_counts(timeout_counts)}")
        notification_title, notification_message = build_scan_notification(
            decision, args.quick, summary
        )
        report_path: Path | None = None
        try:
            report_path = create_notification_report(
                notification_title,
                notification_message,
                decision=decision,
                summary=summary,
                ranked=ranked,
                failed_rows=failed_rows,
                retention_days=settings.get(
                    "notification_report_retention_days", 30
                ),
                maximum_count=settings.get(
                    "notification_report_max_files", 100
                ),
            )
        except Exception as exc:
            log(f"生成完整通知报告失败，改用简版报告：{exc}")
        send_windows_notification(
            notification_title,
            notification_message,
            report_path,
        )
        return 0

    except Exception as exc:
        failed_stage_durations = stage_timer.finish()
        failure_summary.update(
            {
                "deferred_count": deferred_count,
                "duration_seconds": round(time.monotonic() - run_started, 1),
                "stage_durations_seconds": failed_stage_durations,
                "timeout_counts": dict(timeout_counts),
                "timeout_count_total": sum(timeout_counts.values()),
                "failed_count": len(failed_ips),
            }
        )
        partial_funnel = ""
        if has_detailed_scan_summary(failure_summary):
            partial_funnel = "\n" + "\n".join(
                format_scan_funnel_lines(failure_summary)
            )
        failure = (
            f"阶段：{stage}\n"
            f"耗时：{format_duration(time.monotonic() - run_started)}\n"
            f"阶段耗时：{format_stage_timings(failed_stage_durations)}\n"
            f"超时次数：{format_timeout_counts(timeout_counts)}\n"
            f"错误：{type(exc).__name__}: {exc}"
            f"{partial_funnel}"
        )
        log(f"运行失败：{failure}")
        if not args.diagnose:
            try_write_run_status(
                args.quick, "failed", run_started_at, reason=failure
            )
        if failed_stage_durations:
            log(
                "失败前阶段耗时："
                + "，".join(
                    f"{name}={seconds:.3f}s"
                    for name, seconds in failed_stage_durations.items()
                )
            )
        if not args.diagnose:
            mode = "轻量扫描" if args.quick else "深度扫描"
            failure_title = f"Clash {mode}：运行失败"
            report_path: Path | None = None
            try:
                report_path = create_notification_report(
                    failure_title,
                    failure,
                    decision={
                        "current_ip_before": current_ip,
                        "current_ip_after": current_ip,
                        "switched": False,
                        "reason": f"{stage}：{type(exc).__name__}: {exc}",
                    },
                    summary=failure_summary,
                    ranked=failure_ranked,
                    failed_rows=failure_rows,
                    retention_days=settings.get(
                        "notification_report_retention_days", 30
                    ),
                    maximum_count=settings.get(
                        "notification_report_max_files", 100
                    ),
                )
            except Exception as report_exc:
                log(f"生成失败通知报告失败：{report_exc}")
            send_windows_notification(
                failure_title,
                failure,
                report_path,
            )
        return 1
    finally:
        if lock_handle is not None:
            release_run_lock(lock_handle)


if __name__ == "__main__":
    raise SystemExit(main())
