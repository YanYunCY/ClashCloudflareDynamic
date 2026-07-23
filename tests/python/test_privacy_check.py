from __future__ import annotations

from contextlib import redirect_stdout
import io
import tempfile
import unittest
from unittest import mock
from pathlib import Path

from tools import privacy_check


class PrivacyCheckTests(unittest.TestCase):
    def test_private_json_credentials_are_detected(self) -> None:
        self.assertTrue(
            privacy_check.contains_private_json_value(
                {"secret": "fixture-value"}
            )
        )
        self.assertFalse(
            privacy_check.contains_private_json_value(
                {"secret": "", "uuid": privacy_check.ZERO_UUID}
            )
        )

    def test_only_public_node_placeholders_are_accepted(self) -> None:
        public_template = {
            "type": "vmess",
            "port": 443,
            "uuid": privacy_check.ZERO_UUID,
            "servername": "replace-with-your-domain.example",
            "ws-opts": {
                "path": "/your-websocket-path",
                "headers": {"Host": "replace-with-your-domain.example"},
            },
        }
        self.assertTrue(
            privacy_check.public_node_template_is_safe(public_template)
        )
        private_template = dict(public_template)
        private_template["servername"] = "private.example.invalid"
        self.assertFalse(
            privacy_check.public_node_template_is_safe(private_template)
        )

        trojan_template = {
            "type": "trojan",
            "port": 8443,
            "password": "replace-with-your-password",
            "sni": "replace-with-your-domain.example",
            "network": "ws",
            "ws-opts": {
                "path": "/your-websocket-path",
                "headers": {"Host": "replace-with-your-domain.example"},
            },
        }
        self.assertTrue(
            privacy_check.public_node_template_is_safe(trojan_template)
        )
        trojan_template["password"] = "fixture-private-password"
        self.assertFalse(
            privacy_check.public_node_template_is_safe(trojan_template)
        )

    def test_personal_windows_paths_and_accounts_are_detected(self) -> None:
        user_path = "C:" + "\\" + "Users" + "\\" + "sample-user"
        account = "Admin" + "istrator"
        self.assertIsNotNone(privacy_check.USER_PROFILE_RE.search(user_path))
        self.assertIsNotNone(privacy_check.PERSONAL_ACCOUNT_RE.search(account))

    def test_archives_backups_and_runtime_files_are_rejected(self) -> None:
        self.assertIn(".cmd", privacy_check.TEXT_SUFFIXES)
        for name in (
            "release.zip",
            "settings.json.backup-20260723",
            "state.json",
            "history.sqlite3-wal",
            "notification_20260723.html",
        ):
            with self.subTest(name=name):
                self.assertTrue(privacy_check.is_sensitive_file(Path(name)))
        self.assertFalse(privacy_check.is_sensitive_file(Path("README.md")))

    def test_tracked_sensitive_directories_are_rejected(self) -> None:
        for name in (
            "settings.json",
            "backups/install-20260723/settings.json",
            "logs/dynamic_selector.log",
            "providers/cloudflare_active.yaml",
            "src/__pycache__/module.pyc",
        ):
            with self.subTest(name=name):
                self.assertTrue(
                    privacy_check.is_sensitive_tracked_path(Path(name))
                )
        self.assertFalse(
            privacy_check.is_sensitive_tracked_path(Path("examples/settings.example.json"))
        )

    def test_main_fails_when_backup_is_force_tracked(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            tracked_backup = root / "backups" / "install" / "settings.json"
            tracked_backup.parent.mkdir(parents=True)
            tracked_backup.write_text('{"secret":"fixture"}', encoding="utf-8")
            output = io.StringIO()
            with (
                mock.patch.object(privacy_check, "ROOT", root),
                mock.patch.object(
                    privacy_check,
                    "git_tracked_files",
                    return_value={"backups/install/settings.json"},
                ),
                mock.patch.object(privacy_check, "check_gitignore"),
                mock.patch.object(
                    privacy_check,
                    "iter_publishable_files",
                    return_value=iter(()),
                ),
                redirect_stdout(output),
            ):
                result = privacy_check.main()

        self.assertEqual(result, 1)
        self.assertIn("backups/install/settings.json", output.getvalue())
        self.assertNotIn("fixture", output.getvalue())

    def test_main_fails_closed_when_git_inventory_is_unavailable(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            output = io.StringIO()
            with (
                mock.patch.object(privacy_check, "ROOT", root),
                mock.patch.object(
                    privacy_check,
                    "git_tracked_files",
                    side_effect=RuntimeError("fixture git failure"),
                ),
                mock.patch.object(privacy_check, "check_gitignore"),
                mock.patch.object(
                    privacy_check,
                    "iter_publishable_files",
                    return_value=iter(()),
                ),
                redirect_stdout(output),
            ):
                result = privacy_check.main()

        self.assertEqual(result, 1)
        self.assertIn("无法核验 Git 已跟踪文件", output.getvalue())
        self.assertNotIn("fixture git failure", output.getvalue())


if __name__ == "__main__":
    unittest.main()
