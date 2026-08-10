from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from unittest import mock

from clash_cloudflare_dynamic import dynamic_selector as selector
from clash_cloudflare_dynamic import v2rayn_mode


class V2rayNPathTests(unittest.TestCase):
    def test_root_expands_environment_variable_without_machine_specific_default(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            with mock.patch.dict(os.environ, {"CCD_TEST_V2RAYN": temp_dir}):
                root = v2rayn_mode._v2rayn_root(
                    {"v2rayn_root": "%CCD_TEST_V2RAYN%"}
                )

        self.assertEqual(root, Path(temp_dir).resolve())

    def test_hysteria_core_is_required_only_when_comparison_is_enabled(self):
        self.assertIs(v2rayn_mode._hy2_comparison_enabled({}), False)
        self.assertIs(
            v2rayn_mode._hy2_comparison_enabled(
                {"v2rayn_compare_hy2": True}
            ),
            True,
        )
        self.assertEqual(
            v2rayn_mode._required_core_names({}),
            ("db", "config", "xray"),
        )
        self.assertEqual(
            v2rayn_mode._required_core_names(
                {"v2rayn_compare_hy2": True}, include_desktop=True
            ),
            ("exe", "db", "config", "xray", "hysteria"),
        )

    def test_configured_proxy_must_be_loopback_and_keeps_custom_port(self):
        self.assertEqual(
            v2rayn_mode._configured_mixed_proxy(
                {"mixed_proxy": "http://127.0.0.1:18080"}
            ),
            ("http://127.0.0.1:18080", "127.0.0.1:18080"),
        )
        for value in ("http://192.0.2.1:10808", "http://127.0.0.1"):
            with self.subTest(value=value):
                with self.assertRaises(RuntimeError):
                    v2rayn_mode._configured_mixed_proxy({"mixed_proxy": value})


class V2rayNConfigTests(unittest.TestCase):
    def test_auto_groups_are_separate_and_stable(self):
        first = v2rayn_mode._auto_group_specs()
        second = v2rayn_mode._auto_group_specs()

        self.assertEqual(set(first), {"la", "sg"})
        self.assertNotEqual(first["la"]["id"], first["sg"]["id"])
        self.assertEqual(first, second)
        self.assertIn("LA VMess + VLESS + HY2", first["la"]["remarks"])
        self.assertIn("仅 SG VMess", first["sg"]["remarks"])

    def test_vmess_xray_outbound_preserves_ws_tls_and_replaces_only_address(self):
        outbound = v2rayn_mode._xray_outbound(
            {
                "type": "vmess",
                "port": 443,
                "uuid": "11111111-1111-4111-8111-111111111111",
                "alterId": 0,
                "cipher": "auto",
                "servername": "edge.test.invalid",
                "ws-opts": {
                    "path": "/private-path",
                    "headers": {"Host": "edge.test.invalid"},
                },
            },
            "198.51.100.8",
            "candidate-1",
        )

        self.assertEqual(outbound["protocol"], "vmess")
        self.assertEqual(
            outbound["settings"]["vnext"][0]["address"], "198.51.100.8"
        )
        self.assertEqual(outbound["streamSettings"]["network"], "ws")
        self.assertEqual(
            outbound["streamSettings"]["tlsSettings"]["serverName"],
            "edge.test.invalid",
        )

    def test_quick_settings_keep_original_input_immutable(self):
        settings = {
            "random_samples_per_run": 5000,
            "discovery_provider_limit": 300,
            "speed_probe_candidates": 40,
            "speed_candidates": 20,
            "quick_speed_candidates": 8,
            "speed_test_bytes": 20_000_000,
            "quick_speed_test_bytes": 3_000_000,
            "speed_timeout_seconds": 60,
            "quick_speed_timeout_seconds": 20,
            "tcp_workers": 96,
        }

        quick = v2rayn_mode._quick_settings(settings)

        self.assertEqual(quick["random_samples_per_run"], 200)
        self.assertEqual(quick["speed_test_bytes"], 3_000_000)
        self.assertEqual(quick["speed_timeout_seconds"], 20)
        self.assertEqual(settings["random_samples_per_run"], 5000)

    def test_hy2_display_name_does_not_expose_server(self):
        label = v2rayn_mode._hy2_display_name(
            "server: private-gateway.test.invalid:24567\nauth: secret\n"
        )

        self.assertEqual(label, "HY2 | UDP 24567")
        self.assertNotIn("private-gateway", label)


class V2rayNDispatchTests(unittest.TestCase):
    def test_dynamic_selector_forwards_dry_run_flag_to_v2rayn_backend(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            settings_path = Path(temp_dir) / "settings.json"
            settings_path.write_text(
                json.dumps(
                    {
                        "client_mode": "v2rayn",
                        "official_ipv4_url": "https://example.invalid/ips-v4",
                        "speed_test_base_url": "https://example.invalid/down",
                    }
                ),
                encoding="utf-8",
            )
            captured: dict[str, object] = {}

            def fake_run(args: Namespace, settings: dict[str, object]) -> int:
                captured["dry_run"] = args.v2rayn_dry_run
                captured["mode"] = settings["client_mode"]
                return 17

            with (
                mock.patch.object(selector, "SETTINGS_PATH", settings_path),
                mock.patch.object(v2rayn_mode, "run", side_effect=fake_run),
                mock.patch.object(
                    sys, "argv", ["dynamic_selector.py", "--v2rayn-dry-run"]
                ),
            ):
                result = selector.main()

        self.assertEqual(result, 17)
        self.assertIs(captured["dry_run"], True)
        self.assertEqual(captured["mode"], "v2rayn")

    def test_backend_failure_notification_keeps_v2rayn_identity(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            settings_path = Path(temp_dir) / "settings.json"
            settings_path.write_text(
                json.dumps(
                    {
                        "client_mode": "v2rayn",
                        "official_ipv4_url": "https://example.invalid/ips-v4",
                        "speed_test_base_url": "https://example.invalid/down",
                    }
                ),
                encoding="utf-8",
            )
            with (
                mock.patch.object(selector, "SETTINGS_PATH", settings_path),
                mock.patch.object(
                    v2rayn_mode,
                    "run",
                    side_effect=RuntimeError("simulated backend failure"),
                ),
                mock.patch.object(selector, "log"),
                mock.patch.object(selector, "try_write_run_status"),
                mock.patch.object(
                    selector,
                    "create_notification_report",
                    return_value=None,
                ) as create_report,
                mock.patch.object(selector, "send_windows_notification") as notify,
                mock.patch.object(
                    sys,
                    "argv",
                    ["dynamic_selector.py", "--quick"],
                ),
            ):
                result = selector.main()

        self.assertEqual(result, 1)
        self.assertTrue(notify.call_args.args[0].startswith("v2rayN 轻量扫描"))
        self.assertEqual(
            create_report.call_args.kwargs["summary"]["client_mode"],
            "v2rayn",
        )


class V2rayNSwitchTests(unittest.TestCase):
    def test_switch_timestamp_is_recorded_only_after_activation_succeeds(self):
        ranked = [
            {
                "profile_id": "new-target",
                "speed_Mbps": 100.0,
                "fast_speed_floor_Mbps": 95.0,
                "delay_ms": 100.0,
            }
        ]
        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = Path(temp_dir) / "switch_state_la.json"
            with mock.patch.object(
                v2rayn_mode,
                "_switch_state_path",
                return_value=state_path,
            ):
                target_id, _ = v2rayn_mode._choose_switch(
                    {"required_consecutive_wins": 1},
                    ranked,
                    "old-target",
                    "la",
                )
                selected_state = json.loads(state_path.read_text(encoding="utf-8"))
                v2rayn_mode._record_successful_switch("la", target_id)
                switched_state = json.loads(state_path.read_text(encoding="utf-8"))

        self.assertEqual(target_id, "new-target")
        self.assertNotIn("last_switch", selected_state)
        self.assertNotIn("current_id", selected_state)
        self.assertEqual(switched_state["current_id"], "new-target")
        self.assertTrue(switched_state["last_switch"])

    def test_failed_switch_rollback_uses_configured_proxy_port(self):
        settings = {
            "mixed_proxy": "http://127.0.0.1:18080",
            "v2rayn_restart_verify_seconds": 1,
        }
        with (
            mock.patch.object(
                v2rayn_mode,
                "_v2rayn_paths",
                return_value={"exe": Path("v2rayN.exe")},
            ),
            mock.patch.object(
                v2rayn_mode,
                "_read_system_proxy",
                return_value={"enabled": True, "server": "127.0.0.1:18080"},
            ),
            mock.patch.object(v2rayn_mode, "_tun_enabled", return_value=False),
            mock.patch.object(
                v2rayn_mode,
                "_ensure_auto_slots",
                return_value={"la": "active-slot"},
            ),
            mock.patch.object(
                v2rayn_mode,
                "_configured_index_id",
                return_value="active-slot",
            ),
            mock.patch.object(
                v2rayn_mode,
                "_current_index_id",
                return_value="old-target",
            ),
            mock.patch.object(
                v2rayn_mode,
                "_replace_active_slot",
                return_value=({"IndexId": "active-slot"}, "new-target"),
            ),
            mock.patch.object(v2rayn_mode, "_invoke_v2rayn_reload"),
            mock.patch.object(
                v2rayn_mode,
                "_wait_proxy_verified",
                side_effect=(False, True),
            ) as proxy_checks,
            mock.patch.object(v2rayn_mode, "_restore_active_slot"),
            mock.patch.object(v2rayn_mode, "_ensure_tun_dns_nrpt"),
            mock.patch.object(v2rayn_mode, "_set_system_proxy"),
        ):
            with self.assertRaisesRegex(RuntimeError, "真实下载验证"):
                v2rayn_mode._safe_activate(settings, "new-target", "la")

        self.assertEqual(proxy_checks.call_count, 2)
        self.assertEqual(
            [call.args[0] for call in proxy_checks.call_args_list],
            ["http://127.0.0.1:18080", "http://127.0.0.1:18080"],
        )


class V2rayNReportTests(unittest.TestCase):
    def test_report_uses_physical_and_cold_start_labels(self):
        ranked = [
            {
                "ip": "198.51.100.8",
                "discovery_node": "LA VMess | 198.51.100.8",
                "fast_group": True,
                "speed_Mbps": 88.0,
                "speed_samples_Mbps": "87,88,89",
                "speed_stddev_Mbps": 0.82,
                "speed_cv": 0.0093,
                "delay_ms": 320,
                "delay_samples_ms": "310,320,330",
                "delay_stddev_ms": 8.16,
                "parallel_concurrency": 5,
                "parallel_stream_bytes": 4_000_000,
            }
        ]
        summary = {
            "client_mode": "v2rayn",
            "summary_schema_version": 2,
            "auto_mode": "la",
            "candidate_count": 20,
            "tcp_reachable_count": 15,
            "tcp_failed_count": 5,
            "discovery_pool_count": 10,
            "proxy_valid_count": 8,
            "proxy_failed_count": 2,
            "speed_probe_selected_count": 8,
            "speed_probe_attempted_count": 8,
            "speed_probe_passed_count": 5,
            "speed_probe_failed_count": 3,
            "formal_selected_count": 1,
            "formal_attempted_count": 1,
            "formal_passed_count": 1,
            "formal_failed_count": 0,
            "fast_group_count": 1,
            "stage_durations_seconds": {"tcp_probe": 1.2, "proxy_delay": 2.3},
        }
        decision = {
            "current_name_before": "AUTO-LA old",
            "current_name_after": "AUTO-LA new",
            "switched": True,
            "best": ranked[0],
            "current_metrics": ranked[0],
            "reason": "冷启动响应更低",
        }
        with tempfile.TemporaryDirectory() as temp_dir:
            with mock.patch.object(
                selector,
                "NOTIFICATION_REPORT_DIR",
                Path(temp_dir) / "reports",
            ):
                report = selector.create_notification_report(
                    "v2rayN 轻扫",
                    "完成",
                    decision=decision,
                    summary=summary,
                    ranked=ranked,
                )
            document = report.read_text(encoding="utf-8")

        self.assertIn("TCP 物理直连初筛", document)
        self.assertIn("真实协议冷启动响应", document)
        self.assertIn("平均冷启动代理响应 ms", document)
        self.assertIn("三次冷启动代理响应 ms", document)
        self.assertIn("节点/IP", document)
        self.assertIn("5×4000000 bytes/流", document)
        self.assertNotIn(">VMess 延迟<", document)


if __name__ == "__main__":
    unittest.main()
