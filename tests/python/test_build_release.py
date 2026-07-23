from __future__ import annotations

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


if __name__ == "__main__":
    unittest.main()
