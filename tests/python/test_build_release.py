from __future__ import annotations

import json
import tempfile
import unittest
import zipfile
from pathlib import Path

from tools import build_release


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


class ReleaseBuildTests(unittest.TestCase):
    def test_release_is_flat_complete_and_deterministic(self) -> None:
        expected = {
            destination
            for _, destination in build_release.release_manifest(REPOSITORY_ROOT)
        }
        with tempfile.TemporaryDirectory() as temp_dir:
            dist_root = Path(temp_dir)
            package_root, archive_path = build_release.build_release(
                REPOSITORY_ROOT,
                dist_root,
            )
            self.assertIsNotNone(archive_path)
            assert archive_path is not None
            first_archive = archive_path.read_bytes()

            staged = {
                path.relative_to(package_root)
                for path in package_root.rglob("*")
                if path.is_file()
            }
            self.assertEqual(staged, expected)
            self.assertFalse(
                any(build_release.is_forbidden_release_path(path) for path in staged)
            )
            for relative in staged:
                data = (package_root / relative).read_bytes()
                with self.subTest(line_endings=relative.as_posix()):
                    if relative.suffix.casefold() in build_release.CRLF_SUFFIXES:
                        self.assertNotIn(b"\n", data.replace(b"\r\n", b""))
                    elif relative.suffix.casefold() in build_release.LF_SUFFIXES:
                        self.assertNotIn(b"\r", data)
                    if relative.suffix.casefold() == ".ps1":
                        self.assertTrue(data.startswith(build_release.UTF8_BOM))

            settings = json.loads(
                (package_root / "examples" / "settings.example.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(settings["speed_test_bytes"], 20_000_000)
            self.assertEqual(settings["speed_timeout_seconds"], 60)
            self.assertEqual(settings["quick_speed_test_bytes"], 3_000_000)
            self.assertEqual(settings["quick_speed_timeout_seconds"], 20)
            for private_topology_key in (
                "v2rayn_enable_sg",
                "v2rayn_enable_la_vless",
                "v2rayn_compare_hy2",
                "v2rayn_active_slot_ids",
                "v2rayn_sg_recovery_provider",
                "v2rayn_la_vless_recovery_profile",
            ):
                self.assertNotIn(private_topology_key, settings)

            published_text = "\n".join(
                (package_root / relative).read_text(
                    encoding="utf-8-sig",
                    errors="ignore",
                )
                for relative in staged
                if relative.suffix.casefold()
                in {".json", ".md", ".ps1", ".py", ".txt", ".yaml", ".yml"}
            )
            for private_topology_marker in (
                "AUTO-LA",
                "AUTO-SG",
                "e0a4ee22-c8d3-4975-a102-de1f410de7b3.yaml",
            ):
                self.assertNotIn(private_topology_marker, published_text)

            with zipfile.ZipFile(archive_path) as archive:
                archived = set(archive.namelist())
            self.assertEqual(
                archived,
                {
                    (Path(build_release.PACKAGE_NAME) / path).as_posix()
                    for path in expected
                },
            )

            _, rebuilt_archive = build_release.build_release(
                REPOSITORY_ROOT,
                dist_root,
            )
            assert rebuilt_archive is not None
            self.assertEqual(first_archive, rebuilt_archive.read_bytes())

    def test_forbidden_runtime_paths_are_recognized(self) -> None:
        for relative in (
            Path(".git/config"),
            Path("tests/test_runtime.py"),
            Path("logs/latest.log"),
            Path("settings.json"),
            Path("discovery_history.sqlite3"),
        ):
            with self.subTest(path=relative.as_posix()):
                self.assertTrue(
                    build_release.is_forbidden_release_path(relative)
                )

    def test_zip_create_system_is_pinned_to_zero(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            dist_root = Path(temp_dir)
            _, archive_path = build_release.build_release(
                REPOSITORY_ROOT,
                dist_root,
            )
            self.assertIsNotNone(archive_path)
            assert archive_path is not None

            with zipfile.ZipFile(archive_path) as archive:
                for info in archive.infolist():
                    with self.subTest(file=info.filename):
                        self.assertEqual(
                            info.create_system,
                            0,
                            f"ZipInfo.create_system should be 0 (FAT/DOS) for "
                            f"deterministic builds, got {info.create_system}",
                        )


if __name__ == "__main__":
    unittest.main()
