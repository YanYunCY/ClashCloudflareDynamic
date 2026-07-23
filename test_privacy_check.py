from __future__ import annotations

import unittest
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
            "servername": "example.com",
            "ws-opts": {
                "path": "/your-websocket-path",
                "headers": {"Host": "example.com"},
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
            "sni": "example.com",
            "network": "ws",
            "ws-opts": {
                "path": "/your-websocket-path",
                "headers": {"Host": "example.com"},
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


if __name__ == "__main__":
    unittest.main()
