import os
import sqlite3
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

import storage_maintenance as maintenance


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
