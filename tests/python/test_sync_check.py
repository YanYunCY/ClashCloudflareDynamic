from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from tools import sync_check


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def write_manifest(path: Path, markers: list[dict]) -> None:
    path.write_text(
        json.dumps({"schema_version": 1, "markers": markers}),
        encoding="utf-8",
    )


class SyncCheckTests(unittest.TestCase):
    def test_all_pass(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            for name in ("opensource", "deployment", "mirror"):
                write(root / name / "dynamic_selector.py", "def foo():\n    marker_x\n")
            manifest = root / "markers.json"
            write_manifest(
                manifest,
                [
                    {
                        "id": "m1",
                        "description": "marker x present",
                        "file": "dynamic_selector.py",
                        "pattern": "marker_x",
                        "min_count": 1,
                    }
                ],
            )
            lines = {
                "opensource": root / "opensource",
                "deployment": root / "deployment",
                "mirror": root / "mirror",
            }
            markers = sync_check.load_manifest(manifest)
            results = sync_check.check_markers(markers, lines)
            _, all_ok = sync_check.format_report(results, lines)
            self.assertTrue(all_ok)
            self.assertTrue(all(r.ok for r in results))

    def test_single_line_missing_marker(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            write(root / "opensource" / "d.py", "marker_x\n")
            write(root / "deployment" / "d.py", "marker_x\n")
            write(root / "mirror" / "d.py", "unrelated content\n")  # 漏同步
            manifest = root / "markers.json"
            write_manifest(
                manifest,
                [
                    {
                        "id": "m1",
                        "description": "marker x",
                        "file": "d.py",
                        "pattern": "marker_x",
                        "min_count": 1,
                    }
                ],
            )
            lines = {
                "opensource": root / "opensource",
                "deployment": root / "deployment",
                "mirror": root / "mirror",
            }
            markers = sync_check.load_manifest(manifest)
            results = sync_check.check_markers(markers, lines)
            report, all_ok = sync_check.format_report(results, lines)
            self.assertFalse(all_ok)
            self.assertIn("MISSING", report)
            self.assertIn("mirror", report)
            failing = [r for r in results if not r.ok]
            self.assertEqual(len(failing), 1)
            self.assertEqual(failing[0].line_name, "mirror")

    def test_missing_file(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            write(root / "opensource" / "d.py", "marker_x\n")
            # deployment 完全没有该文件
            manifest = root / "markers.json"
            write_manifest(
                manifest,
                [
                    {
                        "id": "m1",
                        "description": "marker x",
                        "file": "d.py",
                        "pattern": "marker_x",
                        "min_count": 1,
                    }
                ],
            )
            lines = {
                "opensource": root / "opensource",
                "deployment": root / "deployment",
            }
            markers = sync_check.load_manifest(manifest)
            results = sync_check.check_markers(markers, lines)
            report, all_ok = sync_check.format_report(results, lines)
            self.assertFalse(all_ok)
            self.assertIn("文件缺失", report)
            dep = [r for r in results if r.line_name == "deployment"][0]
            self.assertFalse(dep.file_exists)
            self.assertEqual(dep.actual_count, 0)

    def test_lines_field_filters_scope(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            write(root / "opensource" / "d.py", "only_here\n")
            write(root / "deployment" / "d.py", "no marker\n")  # 本不该要求它有
            manifest = root / "markers.json"
            write_manifest(
                manifest,
                [
                    {
                        "id": "os-only",
                        "description": "opensource only marker",
                        "file": "d.py",
                        "pattern": "only_here",
                        "min_count": 1,
                        "lines": ["opensource"],
                    }
                ],
            )
            lines = {
                "opensource": root / "opensource",
                "deployment": root / "deployment",
            }
            markers = sync_check.load_manifest(manifest)
            results = sync_check.check_markers(markers, lines)
            _, all_ok = sync_check.format_report(results, lines)
            # deployment 不在 lines 范围内，不应产生结果，也不应导致失败
            self.assertTrue(all_ok)
            self.assertEqual({r.line_name for r in results}, {"opensource"})

    def test_min_count_enforced(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            write(root / "a" / "d.py", "dup\ndup\n")  # 2 次，满足
            write(root / "b" / "d.py", "dup\n")  # 1 次，不满足
            manifest = root / "markers.json"
            write_manifest(
                manifest,
                [
                    {
                        "id": "twice",
                        "description": "must appear twice",
                        "file": "d.py",
                        "pattern": "dup",
                        "min_count": 2,
                    }
                ],
            )
            lines = {"a": root / "a", "b": root / "b"}
            markers = sync_check.load_manifest(manifest)
            results = sync_check.check_markers(markers, lines)
            _, all_ok = sync_check.format_report(results, lines)
            self.assertFalse(all_ok)
            by_line = {r.line_name: r for r in results}
            self.assertTrue(by_line["a"].ok)
            self.assertFalse(by_line["b"].ok)
            self.assertEqual(by_line["a"].actual_count, 2)
            self.assertEqual(by_line["b"].actual_count, 1)

    def test_utf8_sig_tolerant(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            path = root / "line" / "d.py"
            path.parent.mkdir(parents=True)
            path.write_bytes("﻿marker_x\n".encode("utf-8"))  # 带 BOM
            manifest = root / "markers.json"
            write_manifest(
                manifest,
                [
                    {
                        "id": "m1",
                        "description": "marker x",
                        "file": "d.py",
                        "pattern": "marker_x",
                        "min_count": 1,
                    }
                ],
            )
            lines = {"line": root / "line"}
            markers = sync_check.load_manifest(manifest)
            results = sync_check.check_markers(markers, lines)
            self.assertTrue(results[0].ok)

    def test_regex_marker(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            write(root / "line" / "d.py", "except FooError:\nexcept FooError:\n")
            manifest = root / "markers.json"
            write_manifest(
                manifest,
                [
                    {
                        "id": "re1",
                        "description": "regex two catches",
                        "file": "d.py",
                        "pattern": r"except\s+FooError",
                        "min_count": 2,
                        "regex": True,
                    }
                ],
            )
            lines = {"line": root / "line"}
            markers = sync_check.load_manifest(manifest)
            results = sync_check.check_markers(markers, lines)
            self.assertTrue(results[0].ok)
            self.assertEqual(results[0].actual_count, 2)

    def test_parse_line_argument(self) -> None:
        name, path = sync_check.parse_line_argument("opensource=/tmp/x")
        self.assertEqual(name, "opensource")
        self.assertEqual(path, Path("/tmp/x"))

    def test_config_and_cli_merge(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            config = root / "cfg.json"
            config.write_text(
                json.dumps(
                    {"lines": {"opensource": "/base/os", "mirror": "/base/mir"}}
                ),
                encoding="utf-8",
            )
            # CLI 覆盖 opensource，并新增 deployment
            cli = [
                ("opensource", Path("/override/os")),
                ("deployment", Path("/base/dep")),
            ]
            lines = sync_check.resolve_lines(config, cli)
            self.assertEqual(lines["opensource"], Path("/override/os"))
            self.assertEqual(lines["mirror"], Path("/base/mir"))
            self.assertEqual(lines["deployment"], Path("/base/dep"))

    def test_invalid_manifest_schema(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            manifest = Path(temp_dir) / "m.json"
            manifest.write_text(
                json.dumps({"schema_version": 99, "markers": []}),
                encoding="utf-8",
            )
            with self.assertRaises(sync_check.ManifestError):
                sync_check.load_manifest(manifest)

    def test_duplicate_marker_id_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            manifest = Path(temp_dir) / "m.json"
            write_manifest(
                manifest,
                [
                    {"id": "d", "description": "", "file": "f", "pattern": "p"},
                    {"id": "d", "description": "", "file": "f", "pattern": "q"},
                ],
            )
            with self.assertRaises(sync_check.ManifestError):
                sync_check.load_manifest(manifest)


if __name__ == "__main__":
    unittest.main()
