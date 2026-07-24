#!/usr/bin/env python3
"""三方代码同步对账工具（marker 特征标记方案）。

背景：本项目有三份并存代码线（开源版 / 本地部署版 / 上下文包镜像），彼此
有意存在差异（协议、路径、文案），无法用全文 diff 对账。本工具改为检测一份
"必须三方一致存在"的核心逻辑特征清单（marker），只判断特征是否存在、出现次数
是否达标，而不比对具体内容，从而在不误报有意差异的前提下抓住"漏同步修复"。

纯标准库，Python 3.10+。
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path


SCHEMA_VERSION = 1


@dataclass(frozen=True)
class Marker:
    """一条特征标记：某文件里某个 pattern 至少要出现 min_count 次。"""

    id: str
    description: str
    file: str
    pattern: str
    min_count: int
    lines: tuple[str, ...] | None  # None = 适用所有线
    is_regex: bool
    added_in: str

    def applies_to(self, line_name: str) -> bool:
        return self.lines is None or line_name in self.lines


@dataclass(frozen=True)
class CheckResult:
    marker: Marker
    line_name: str
    file_path: Path
    file_exists: bool
    actual_count: int

    @property
    def ok(self) -> bool:
        return self.actual_count >= self.marker.min_count


class ManifestError(ValueError):
    """清单格式错误。"""


def load_manifest(manifest_path: Path) -> list[Marker]:
    """读取并校验 marker 清单。"""
    raw = read_text_tolerant(manifest_path)
    if raw is None:
        raise ManifestError(f"清单文件不存在：{manifest_path}")
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ManifestError(f"清单不是合法 JSON：{manifest_path}: {exc}") from exc

    if not isinstance(data, dict):
        raise ManifestError("清单根节点必须是对象。")

    schema_version = data.get("schema_version")
    if schema_version != SCHEMA_VERSION:
        raise ManifestError(
            f"schema_version 期望 {SCHEMA_VERSION}，实际 {schema_version!r}。"
        )

    raw_markers = data.get("markers")
    if not isinstance(raw_markers, list) or not raw_markers:
        raise ManifestError("markers 必须是非空数组。")

    markers: list[Marker] = []
    seen_ids: set[str] = set()
    for index, entry in enumerate(raw_markers):
        marker = _parse_marker(entry, index)
        if marker.id in seen_ids:
            raise ManifestError(f"marker id 重复：{marker.id}")
        seen_ids.add(marker.id)
        markers.append(marker)
    return markers


def _parse_marker(entry: object, index: int) -> Marker:
    if not isinstance(entry, dict):
        raise ManifestError(f"markers[{index}] 必须是对象。")

    def require(key: str) -> object:
        if key not in entry:
            raise ManifestError(f"markers[{index}] 缺少必填字段：{key}")
        return entry[key]

    marker_id = require("id")
    description = require("description")
    file = require("file")
    pattern = require("pattern")
    min_count = entry.get("min_count", 1)
    lines = entry.get("lines")
    is_regex = bool(entry.get("regex", False))
    added_in = entry.get("added_in", "")

    if not isinstance(marker_id, str) or not marker_id:
        raise ManifestError(f"markers[{index}].id 必须是非空字符串。")
    if not isinstance(file, str) or not file:
        raise ManifestError(f"marker {marker_id!r} 的 file 必须是非空字符串。")
    if not isinstance(pattern, str) or not pattern:
        raise ManifestError(f"marker {marker_id!r} 的 pattern 必须是非空字符串。")
    if not isinstance(min_count, int) or min_count < 1:
        raise ManifestError(f"marker {marker_id!r} 的 min_count 必须是正整数。")
    if lines is not None:
        if not isinstance(lines, list) or not all(
            isinstance(item, str) for item in lines
        ):
            raise ManifestError(f"marker {marker_id!r} 的 lines 必须是字符串数组。")
        lines = tuple(lines)
    if is_regex:
        try:
            re.compile(pattern)
        except re.error as exc:
            raise ManifestError(
                f"marker {marker_id!r} 的正则 pattern 非法：{exc}"
            ) from exc

    return Marker(
        id=marker_id,
        description=str(description),
        file=file,
        pattern=pattern,
        min_count=min_count,
        lines=lines,
        is_regex=is_regex,
        added_in=str(added_in),
    )


def read_text_tolerant(path: Path) -> str | None:
    """读取文本，utf-8-sig 容错；文件不存在返回 None。"""
    try:
        data = path.read_bytes()
    except (FileNotFoundError, NotADirectoryError, IsADirectoryError):
        return None
    for encoding in ("utf-8-sig", "utf-8"):
        try:
            return data.decode(encoding)
        except UnicodeDecodeError:
            continue
    # 最后兜底：宽松解码，避免因个别坏字节整体崩溃。
    return data.decode("utf-8", errors="replace")


def count_occurrences(text: str, marker: Marker) -> int:
    if marker.is_regex:
        return len(re.findall(marker.pattern, text))
    # 子串计数（不重叠），pattern 中的正则元字符按字面处理。
    return text.count(marker.pattern)


def check_markers(
    markers: list[Marker], lines: dict[str, Path]
) -> list[CheckResult]:
    """对每条 marker 在其适用的每条线上做检查。"""
    results: list[CheckResult] = []
    # 缓存每个 (line, file) 的文本，避免重复读盘。
    text_cache: dict[tuple[str, str], str | None] = {}
    for marker in markers:
        for line_name, root in lines.items():
            if not marker.applies_to(line_name):
                continue
            cache_key = (line_name, marker.file)
            if cache_key not in text_cache:
                text_cache[cache_key] = read_text_tolerant(root / marker.file)
            text = text_cache[cache_key]
            file_path = root / marker.file
            if text is None:
                results.append(
                    CheckResult(marker, line_name, file_path, False, 0)
                )
            else:
                results.append(
                    CheckResult(
                        marker,
                        line_name,
                        file_path,
                        True,
                        count_occurrences(text, marker),
                    )
                )
    return results


def format_report(
    results: list[CheckResult], lines: dict[str, Path]
) -> tuple[str, bool]:
    """生成中文对账报告，返回 (报告文本, 是否全部通过)。"""
    failures = [r for r in results if not r.ok]
    report_lines: list[str] = []
    report_lines.append("三方代码同步对账报告")
    report_lines.append("=" * 40)
    for line_name, root in lines.items():
        report_lines.append(f"  线 {line_name}: {root}")
    report_lines.append("")

    if not failures:
        checked = len({r.marker.id for r in results})
        report_lines.append(
            f"OK：{checked} 条 marker 在所有适用线上均满足，未发现漏同步。"
        )
        return "\n".join(report_lines), True

    # 按 marker 归组，输出缺失详情。
    report_lines.append(f"发现 {len(failures)} 处漏同步（MISSING）：")
    report_lines.append("")
    failures_by_marker: dict[str, list[CheckResult]] = {}
    for result in failures:
        failures_by_marker.setdefault(result.marker.id, []).append(result)

    for marker_id, marker_failures in failures_by_marker.items():
        marker = marker_failures[0].marker
        report_lines.append(f"[MISSING] marker: {marker.id}")
        report_lines.append(f"    说明: {marker.description}")
        report_lines.append(f"    文件: {marker.file}")
        report_lines.append(
            f"    特征: {marker.pattern!r}"
            f"（{'正则' if marker.is_regex else '子串'}，期望≥{marker.min_count}）"
        )
        if marker.added_in:
            report_lines.append(f"    引入版本: {marker.added_in}")
        for result in marker_failures:
            if not result.file_exists:
                reason = "文件缺失"
            else:
                reason = f"实际 {result.actual_count} 次 < 期望 {marker.min_count} 次"
            report_lines.append(
                f"    - 线 {result.line_name}: {reason}  ({result.file_path})"
            )
        report_lines.append("")

    # 逐线小结。
    report_lines.append("逐线小结：")
    for line_name in lines:
        line_failures = [r for r in failures if r.line_name == line_name]
        if line_failures:
            ids = ", ".join(sorted({r.marker.id for r in line_failures}))
            report_lines.append(
                f"  线 {line_name}: 缺失 {len(line_failures)} 条 -> {ids}"
            )
        else:
            report_lines.append(f"  线 {line_name}: 全部通过")
    return "\n".join(report_lines), False


def parse_line_argument(value: str) -> tuple[str, Path]:
    if "=" not in value:
        raise argparse.ArgumentTypeError(
            f"--line 需要 name=root 格式，收到：{value!r}"
        )
    name, _, root = value.partition("=")
    name = name.strip()
    root = root.strip()
    if not name or not root:
        raise argparse.ArgumentTypeError(
            f"--line 的 name 与 root 都不能为空：{value!r}"
        )
    return name, Path(root)


def resolve_lines(
    config_path: Path | None, cli_lines: list[tuple[str, Path]]
) -> dict[str, Path]:
    """合并配置文件默认线与命令行 --line；命令行优先。"""
    lines: dict[str, Path] = {}
    if config_path is not None:
        raw = read_text_tolerant(config_path)
        if raw is None:
            raise ManifestError(f"配置文件不存在：{config_path}")
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise ManifestError(f"配置文件不是合法 JSON：{config_path}: {exc}") from exc
        config_lines = data.get("lines")
        if not isinstance(config_lines, dict):
            raise ManifestError("配置文件的 lines 必须是对象（name -> root）。")
        for name, root in config_lines.items():
            if not isinstance(root, str) or not root:
                raise ManifestError(f"配置文件线 {name!r} 的 root 必须是非空字符串。")
            lines[name] = Path(root)
    for name, root in cli_lines:
        lines[name] = root  # 命令行覆盖配置文件同名线。
    return lines


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="三方代码同步对账工具（marker 特征标记方案）。",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        required=True,
        help="marker 清单 JSON 路径。",
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=None,
        help="可选：默认三线路径配置 JSON（含 lines 对象）。",
    )
    parser.add_argument(
        "--line",
        dest="lines",
        action="append",
        type=parse_line_argument,
        default=[],
        metavar="NAME=ROOT",
        help="指定一条代码线，name=root；可多次。覆盖配置文件同名线。",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    # 强制 UTF-8 输出，避免 GBK 控制台下中文报告乱码。
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            try:
                stream.reconfigure(encoding="utf-8", errors="replace")
            except (OSError, ValueError):
                pass
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        markers = load_manifest(args.manifest)
        lines = resolve_lines(args.config, args.lines)
    except ManifestError as exc:
        print(f"错误：{exc}", file=sys.stderr)
        return 2

    if not lines:
        print(
            "错误：未指定任何代码线。请用 --line name=root 或 --config 指定。",
            file=sys.stderr,
        )
        return 2

    results = check_markers(markers, lines)
    report, all_ok = format_report(results, lines)
    print(report)
    return 0 if all_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
