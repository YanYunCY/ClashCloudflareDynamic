import os
import sqlite3
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from clash_cloudflare_dynamic import storage_maintenance as maintenance


def initialize_test_database(connection: sqlite3.Connection) -> None:
    connection.execute(
        "CREATE TABLE IF NOT EXISTS samples (id INTEGER PRIMARY KEY)"
    )


class BackupCleanupTests(unittest.TestCase):
    def test_cleanup_keeps_newest_ten_and_unmanaged_directories(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir) / "backups"
            root.mkdir()
            now = time.time()
            directories = []
            for index in range(12):
                child = root / f"install-202501{index + 1:02d}-010101"
                child.mkdir()
                modified = now - (40 + index) * 86400
                os.utime(child, (modified, modified))
                directories.append((modified, child))
            unmanaged = root / "manual-do-not-delete"
            unmanaged.mkdir()
            timestamped_manual = root / "manual-archive-20200101-010101"
            timestamped_manual.mkdir()
            old = now - 365 * 86400
            os.utime(unmanaged, (old, old))
            os.utime(timestamped_manual, (old, old))

            deleted = maintenance.cleanup_managed_backups(
                root, retention_days=30, minimum_keep=10, now=now
            )

            newest = {
                path
                for _, path in sorted(directories, reverse=True)[:10]
            }
            self.assertEqual(deleted, 2)
            self.assertEqual(
                {path for _, path in directories if path.exists()}, newest
            )
            self.assertTrue(unmanaged.is_dir())
            self.assertTrue(timestamped_manual.is_dir())

    def test_recent_backup_is_kept_beyond_minimum_count(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir) / "backups"
            root.mkdir()
            now = time.time()
            recent = root / "install-20260723-010101"
            recent.mkdir()
            os.utime(recent, (now - 86400, now - 86400))

            deleted = maintenance.cleanup_managed_backups(
                root, retention_days=30, minimum_keep=0, now=now
            )

            self.assertEqual(deleted, 0)
            self.assertTrue(recent.is_dir())


class RootBackupFileCleanupTests(unittest.TestCase):
    def test_old_backups_are_deleted_newest_kept(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            now = time.time()
            # Create 5 backup files for the same base name "settings.json"
            files = []
            for index in range(5):
                name = f"settings.json.backup-202501{index + 1:02d}-010101"
                path = root / name
                path.write_bytes(b"x")
                mtime = now - (40 + index) * 86400
                os.utime(path, (mtime, mtime))
                files.append((mtime, path))

            deleted = maintenance.cleanup_root_backup_files(
                root, keep_per_file=2, retention_days=30, now=now
            )

            # Newest 2 should be kept, oldest 3 are beyond retention and beyond keep
            self.assertEqual(deleted, 3)
            surviving = [p for _, p in files if p.exists()]
            self.assertEqual(len(surviving), 2)
            # The two survivors should be the newest (index 0 and 1)
            surviving_names = {p.name for p in surviving}
            self.assertIn("settings.json.backup-20250101-010101", surviving_names)
            self.assertIn("settings.json.backup-20250102-010101", surviving_names)

    def test_non_matching_files_are_not_touched(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            now = time.time()
            old = now - 365 * 86400

            # These should NOT be touched (don't match *.backup-YYYYMMDD-HHMMSS)
            normal_file = root / "settings.json"
            normal_file.write_bytes(b"config")
            os.utime(normal_file, (old, old))

            log_file = root / "dynamic_selector.log"
            log_file.write_bytes(b"log")
            os.utime(log_file, (old, old))

            subdir = root / "backups"
            subdir.mkdir()
            os.utime(subdir, (old, old))

            # One valid backup file that is old
            backup = root / "settings.json.backup-20200101-000000"
            backup.write_bytes(b"old")
            os.utime(backup, (old, old))

            deleted = maintenance.cleanup_root_backup_files(
                root, keep_per_file=0, retention_days=30, now=now
            )

            self.assertEqual(deleted, 1)
            self.assertTrue(normal_file.exists())
            self.assertTrue(log_file.exists())
            self.assertTrue(subdir.exists())
            self.assertFalse(backup.exists())

    def test_multiple_base_names_are_tracked_independently(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            now = time.time()
            old = now - 60 * 86400

            # Two old backups for "config.yaml" — both should be deleted
            config1 = root / "config.yaml.backup-20240101-000000"
            config2 = root / "config.yaml.backup-20240102-000000"
            config1.write_bytes(b"c1")
            config2.write_bytes(b"c2")
            os.utime(config1, (old, old))
            os.utime(config2, (old, old))

            # Two old backups for "settings.json" — keep 1, delete 1
            settings1 = root / "settings.json.backup-20240101-000000"
            settings2 = root / "settings.json.backup-20240102-000000"
            settings1.write_bytes(b"s1")
            settings2.write_bytes(b"s2")
            os.utime(settings1, (old, old))
            os.utime(settings2, (old, old))

            deleted = maintenance.cleanup_root_backup_files(
                root, keep_per_file=1, retention_days=30, now=now
            )

            # config.yaml: 2 old, keep=1, so 1 deleted
            # settings.json: 2 old, keep=1, so 1 deleted
            self.assertEqual(deleted, 2)
            # For each group the newest survives
            self.assertTrue(config2.exists())
            self.assertFalse(config1.exists())
            self.assertTrue(settings2.exists())
            self.assertFalse(settings1.exists())


class SQLiteRecoveryTests(unittest.TestCase):
    def test_corrupt_database_is_backed_up_then_rebuilt(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            database = root / "history.sqlite3"
            backup_root = root / "backups"
            corrupt_content = b"this is not sqlite"
            database.write_bytes(corrupt_content)
            logs = []

            connection = maintenance.connect_sqlite_with_recovery(
                database,
                backup_root,
                initialize_test_database,
                logger=logs.append,
            )
            try:
                table = connection.execute(
                    "SELECT name FROM sqlite_master WHERE name='samples'"
                ).fetchone()
            finally:
                connection.close()

            backups = list(backup_root.glob("database-corrupt-*"))
            self.assertEqual(table, ("samples",))
            self.assertEqual(len(backups), 1)
            self.assertEqual(
                (backups[0] / database.name).read_bytes(), corrupt_content
            )
            self.assertTrue(logs)

    def test_locked_database_error_is_not_classified_as_corruption(self):
        error = sqlite3.OperationalError("database is locked")
        self.assertFalse(maintenance.is_sqlite_corruption_error(error))

    @mock.patch.object(maintenance.shutil, "copy2", side_effect=OSError("disk full"))
    def test_failed_backup_does_not_remove_corrupt_database(self, _copy):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            database = root / "history.sqlite3"
            database.write_bytes(b"not sqlite")

            with self.assertRaisesRegex(OSError, "disk full"):
                maintenance.connect_sqlite_with_recovery(
                    database,
                    root / "backups",
                    initialize_test_database,
                )

            self.assertEqual(database.read_bytes(), b"not sqlite")


if __name__ == "__main__":
    unittest.main()
