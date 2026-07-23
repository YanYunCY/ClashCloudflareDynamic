#!/usr/bin/env python3
"""Fail closed when a release tree contains private configuration or runtime data.

The report intentionally contains only a relative path and a finding category.
Matched values are never printed.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[1]
LOCAL_CONFIGS = {Path("settings.json"), Path("node_template.json")}
SKIP_DIRECTORIES = {
    ".git",
    "dist",
}
SENSITIVE_DIRECTORIES = {
    ".idea",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    ".venv",
    ".vscode",
    "__pycache__",
    "backups",
    "logs",
    "notification_reports",
    "providers",
    "venv",
}
TEXT_SUFFIXES = {
    "",
    ".bat",
    ".cmd",
    ".json",
    ".md",
    ".ps1",
    ".py",
    ".txt",
    ".yaml",
    ".yml",
}
SENSITIVE_FILE_NAMES = {
    "best_ips.txt",
    "cloudflare_ranges_cache.txt",
    "discovery_tcp.csv",
    "dynamic_selector.lock",
    "health_monitor_state.json",
    "history.csv",
    "last_decision.json",
    "latest.csv",
    "speed_probe.csv",
    "state.json",
}
SENSITIVE_SUFFIXES = {".db", ".log", ".sqlite", ".sqlite3"}
ARCHIVE_SUFFIXES = {".7z", ".rar", ".zip"}
REQUIRED_GITIGNORE_LINES = {
    "settings.json",
    "node_template.json",
    "*.local.json",
    "logs/",
    "providers/",
    "backups/",
    "state.json",
    "dynamic_selector.lock",
    "discovery_history.sqlite3*",
    "dist/",
}

USER_PROFILE_RE = re.compile(
    r"(?i)\b[a-z]:[\\/]" + "Users" + r"[\\/][^\\/\s'\"<>]+"
)
PERSONAL_ACCOUNT_RE = re.compile(r"(?i)\b" + "Admin" + "istrator" + r"\b")
YAML_CREDENTIAL_RE = re.compile(
    r"(?im)^\s*(?:secret|token|password|uuid|private-key)\s*:\s*"
    r"(?!\s*(?:['\"]{2})?\s*(?:#.*)?$).+"
)
ZERO_UUID = "00000000-0000-0000-0000-000000000000"
PUBLIC_CREDENTIAL_PLACEHOLDERS = {
    "<replace-me>",
    "change-me",
    "replace-with-your-password",
    "your-password",
}
PUBLIC_HOST_PLACEHOLDERS = {
    "example.com",
    "example.net",
    "example.org",
    "replace-with-your-domain.example",
}
CREDENTIAL_KEYS = {
    "api_key",
    "apikey",
    "auth",
    "client_secret",
    "credential",
    "password",
    "private_key",
    "secret",
    "token",
    "uuid",
}


def relative(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def add_finding(
    findings: set[tuple[str, str]], path: Path, category: str
) -> None:
    findings.add((relative(path), category))


def git_tracked_files() -> set[str]:
    try:
        result = subprocess.run(
            ["git", "-C", str(ROOT), "ls-files", "-z"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except OSError as exc:
        raise RuntimeError("无法执行 git ls-files") from exc
    if result.returncode != 0:
        raise RuntimeError("git ls-files 返回失败")
    return {
        item.decode("utf-8", errors="surrogateescape").replace("\\", "/")
        for item in result.stdout.split(b"\0")
        if item
    }


def iter_publishable_files(
    findings: set[tuple[str, str]],
) -> Iterable[Path]:
    for current_root, directories, files in os.walk(ROOT):
        root_path = Path(current_root)
        kept_directories: list[str] = []
        for name in directories:
            child = root_path / name
            lowered = name.lower()
            if lowered in SKIP_DIRECTORIES:
                continue
            if lowered in SENSITIVE_DIRECTORIES:
                add_finding(findings, child, "禁止发布的运行或备份目录")
                continue
            kept_directories.append(name)
        directories[:] = kept_directories

        for name in files:
            path = root_path / name
            if is_sensitive_file(path):
                add_finding(findings, path, "禁止发布的运行产物")
                continue
            yield path


def is_sensitive_file(path: Path) -> bool:
    lowered = path.name.lower()
    return bool(
        lowered in SENSITIVE_FILE_NAMES
        or path.suffix.lower() in SENSITIVE_SUFFIXES
        or path.suffix.lower() in ARCHIVE_SUFFIXES
        or lowered.endswith(".bak")
        or ".backup-" in lowered
        or ".sqlite" in lowered
        or lowered.startswith("notification_") and lowered.endswith(".html")
        or lowered.startswith("clash_cloudflare_dynamic")
        and path.suffix.lower() in {".yaml", ".yml"}
    )


def is_sensitive_tracked_path(relative_path: Path) -> bool:
    lowered_parts = {part.lower() for part in relative_path.parts[:-1]}
    return bool(
        lowered_parts.intersection(SENSITIVE_DIRECTORIES)
        or is_sensitive_file(relative_path)
        or relative_path in LOCAL_CONFIGS
    )


def read_text(path: Path) -> str | None:
    if path.suffix.lower() not in TEXT_SUFFIXES:
        return None
    try:
        if path.stat().st_size > 2_000_000:
            return None
        return path.read_text(encoding="utf-8-sig")
    except (OSError, UnicodeError):
        return None


def contains_private_json_value(value: Any, key: str = "") -> bool:
    if isinstance(value, dict):
        for child_key, child_value in value.items():
            normalized = str(child_key).strip().lower().replace("-", "_")
            if normalized in CREDENTIAL_KEYS:
                if child_value in (None, "", [], {}):
                    continue
                if normalized == "uuid" and str(child_value) == ZERO_UUID:
                    continue
                return True
            if contains_private_json_value(child_value, normalized):
                return True
        return False
    if isinstance(value, list):
        return any(contains_private_json_value(item, key) for item in value)
    return False


def public_node_template_is_safe(value: Any) -> bool:
    if not isinstance(value, dict):
        return False

    def credentials_are_placeholders(item: Any) -> bool:
        if isinstance(item, dict):
            for child_key, child_value in item.items():
                normalized = str(child_key).strip().lower().replace("-", "_")
                if normalized in CREDENTIAL_KEYS:
                    if child_value in (None, "", [], {}):
                        continue
                    text = str(child_value).strip().lower()
                    if normalized == "uuid" and text == ZERO_UUID:
                        continue
                    if text in PUBLIC_CREDENTIAL_PLACEHOLDERS:
                        continue
                    return False
                if not credentials_are_placeholders(child_value):
                    return False
            return True
        if isinstance(item, list):
            return all(credentials_are_placeholders(child) for child in item)
        return True

    if not credentials_are_placeholders(value):
        return False
    for host_key in ("server", "servername", "sni"):
        host = str(value.get(host_key, "")).strip().lower()
        if host and host not in PUBLIC_HOST_PLACEHOLDERS | {"server", "0.0.0.0"}:
            return False
    ws_options = value.get("ws-opts", {})
    if not isinstance(ws_options, dict):
        return False
    ws_path = str(ws_options.get("path", ""))
    if ws_path and ws_path != "/your-websocket-path":
        return False
    headers = ws_options.get("headers", {})
    if not isinstance(headers, dict):
        return False
    host = str(headers.get("Host", headers.get("host", ""))).lower()
    return not host or host in PUBLIC_HOST_PLACEHOLDERS


def check_json(path: Path, text: str, findings: set[tuple[str, str]]) -> None:
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        add_finding(findings, path, "公开 JSON 无法解析")
        return
    if path.name.lower().startswith("node_template"):
        if not public_node_template_is_safe(value):
            add_finding(findings, path, "节点示例包含非占位认证或域名")
        return
    if contains_private_json_value(value):
        add_finding(findings, path, "JSON 包含非空凭据字段")


def check_gitignore(findings: set[tuple[str, str]]) -> None:
    path = ROOT / ".gitignore"
    try:
        lines = {
            line.strip()
            for line in path.read_text(encoding="utf-8-sig").splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        }
    except OSError:
        add_finding(findings, path, "缺少隐私忽略规则")
        return
    if not REQUIRED_GITIGNORE_LINES.issubset(lines):
        add_finding(findings, path, "敏感文件忽略规则不完整")


def main() -> int:
    findings: set[tuple[str, str]] = set()
    try:
        tracked = git_tracked_files()
    except RuntimeError:
        tracked = set()
        add_finding(findings, ROOT / ".git", "无法核验 Git 已跟踪文件")
    for tracked_name in tracked:
        tracked_path = Path(tracked_name)
        if is_sensitive_tracked_path(tracked_path):
            add_finding(
                findings,
                ROOT / tracked_path,
                "敏感运行、配置或备份路径被 Git 跟踪",
            )

    check_gitignore(findings)
    checked = 0
    checker_path = Path(__file__).resolve()
    for path in iter_publishable_files(findings):
        checked += 1
        text = read_text(path)
        if text is None:
            continue
        if path.resolve() != checker_path:
            if USER_PROFILE_RE.search(text):
                add_finding(findings, path, "硬编码 Windows 用户目录")
            if PERSONAL_ACCOUNT_RE.search(text):
                add_finding(findings, path, "包含个人 Windows 账户名")
        if path.suffix.lower() == ".json":
            check_json(path, text, findings)
        elif path.suffix.lower() in {".yaml", ".yml"}:
            if YAML_CREDENTIAL_RE.search(text):
                add_finding(findings, path, "YAML 包含非空凭据")

    if findings:
        print("privacy check: FAILED")
        for path, category in sorted(findings):
            print(f"{path}: {category}")
        return 1

    print(f"privacy check: OK ({checked} publishable files checked)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
