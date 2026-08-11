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

    def test_public_backend_requires_only_v2rayn_xray_files(self):
        self.assertEqual(
            v2rayn_mode._required_core_names({}),
            ("db", "config", "xray"),
        )
        self.assertEqual(
            v2rayn_mode._required_core_names({}, include_desktop=True),
            ("exe", "db", "config", "xray"),
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
    def test_active_route_detection_supports_sing_box_hy2_tun_config(self):
        payload = {
            "route": {
                "rules": [
                    {
                        "action": "reject",
                        "rule_set": ["geosite-category-ads-all"],
                    },
                    {
                        "outbound": "direct",
                        "domain_suffix": ["apps.microsoft.com"],
                    },
                    {
                        "outbound": "proxy",
                        "network": ["udp"],
                        "port_range": ["19302:19309"],
                    },
                    {"outbound": "proxy", "port_range": ["0:65535"]},
                ]
            }
        }
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            config_dir = root / "binConfigs"
            config_dir.mkdir()
            (config_dir / "config.json").write_text(
                json.dumps(payload), encoding="utf-8"
            )
            with mock.patch.object(
                v2rayn_mode,
                "_v2rayn_paths",
                return_value={"root": root},
            ):
                self.assertTrue(v2rayn_mode._generated_full_routing_is_active({}))
                payload["route"]["rules"][1]["domain_suffix"] = []
                (config_dir / "config.json").write_text(
                    json.dumps(payload), encoding="utf-8"
                )
                self.assertFalse(v2rayn_mode._generated_full_routing_is_active({}))

    def test_full_route_matches_clash_split_and_keeps_ordered_leak_protection(self):
        rules = v2rayn_mode._full_routing_rules()
        by_key = {
            rule["Id"]: (index, rule)
            for index, rule in enumerate(rules)
        }

        def named(key: str):
            return by_key[v2rayn_mode._stable_id("v2rayn-routing-rule", key)]

        webrtc_index, webrtc = named("webrtc-stun-proxy")
        store_index, store = named("microsoft-store-direct")
        global_index, microsoft_global = named("microsoft-global-proxy")
        overseas_index, overseas = named("overseas-services")
        china_ip_index, _ = named("china-ip")
        dns_direct_index, _ = named("dns-direct-inbound")
        final_index, final = named("overseas-final")

        self.assertEqual(len(rules), 17)
        self.assertEqual(webrtc["Network"], "udp")
        self.assertEqual(webrtc["OutboundTag"], "proxy")
        self.assertIn("19302-19309", webrtc["Port"])
        self.assertEqual(store["OutboundTag"], "direct")
        self.assertIn("domain:apps.microsoft.com", store["Domain"])
        self.assertIn("domain:delivery.mp.microsoft.com", store["Domain"])
        self.assertEqual(microsoft_global["OutboundTag"], "proxy")
        self.assertIn("domain:login.microsoftonline.com", microsoft_global["Domain"])
        self.assertIn("geosite:openai", overseas["Domain"])
        self.assertIn("geosite:youtube", overseas["Domain"])
        self.assertIn("geosite:github", overseas["Domain"])
        self.assertEqual(final["Port"], "0-65535")
        self.assertLess(webrtc_index, china_ip_index)
        self.assertLess(store_index, china_ip_index)
        self.assertLess(global_index, china_ip_index)
        self.assertLess(overseas_index, china_ip_index)
        self.assertLess(dns_direct_index, final_index)

    def test_public_pool_is_neutral_and_uses_the_user_template(self):
        template = {
            "type": "vmess",
            "uuid": "11111111-1111-4111-8111-111111111111",
            "port": 443,
            "servername": "edge.test.invalid",
            "ws-opts": {"path": "/ws", "headers": {"Host": "edge.test.invalid"}},
        }
        with mock.patch.object(v2rayn_mode.selector, "load_template", return_value=template):
            pools = v2rayn_mode._load_pools({})

        self.assertEqual(len(pools), 1)
        self.assertEqual(pools[0].key, "cf")
        self.assertEqual(pools[0].active_prefix, "CF-A")
        self.assertEqual(pools[0].discovery_prefix, "CF-D")
        self.assertEqual(pools[0].label, "Cloudflare VMESS")
        self.assertIs(pools[0].template, template)

    def test_auto_group_is_generic_and_stable(self):
        first = v2rayn_mode._auto_group_specs()
        second = v2rayn_mode._auto_group_specs()

        self.assertEqual(set(first), {"cf"})
        self.assertEqual(first, second)
        self.assertIn("AUTO-CF", first["cf"]["remarks"])
        self.assertNotIn("LA", first["cf"]["remarks"])
        self.assertNotIn("SG", first["cf"]["remarks"])

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


class V2rayNDelayTests(unittest.TestCase):
    def test_empty_delay_round_retries_at_lower_concurrency(self):
        proxies = {
            str(index): v2rayn_mode.CandidateProxy(
                key=str(index),
                pool="cf",
                ip=f"198.51.100.{index + 1}",
                name=f"candidate-{index}",
                port=18000 + index,
                template={},
            )
            for index in range(4)
        }
        calls = 0

        def fake_delay(*_args):
            nonlocal calls
            calls += 1
            return None if calls <= len(proxies) else 12.5

        with (
            mock.patch.object(v2rayn_mode, "_curl_delay", side_effect=fake_delay),
            mock.patch.object(v2rayn_mode.time, "sleep"),
            mock.patch.object(v2rayn_mode.selector, "log"),
        ):
            valid, samples, stddev = v2rayn_mode._measure_delays(
                proxies,
                {
                    "delay_repeats": 3,
                    "require_all_repeats": True,
                    "v2rayn_delay_workers": 4,
                    "v2rayn_delay_retry_on_empty": True,
                    "v2rayn_delay_retry_min_valid_ratio": 0.05,
                    "v2rayn_delay_retry_workers": 2,
                    "v2rayn_delay_retry_backoff_seconds": 2.0,
                },
                "curl.exe",
            )

        self.assertEqual(set(valid), set(proxies))
        self.assertEqual(calls, len(proxies) * 4)
        self.assertEqual(samples["0"], [12.5, 12.5, 12.5])
        self.assertEqual(stddev["0"], 0.0)

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
    @unittest.skipUnless(os.name == "nt", "Windows-only reload bridge")
    def test_reload_uses_single_instance_event_for_hidden_tray_window(self):
        completed = mock.Mock(returncode=0, stdout="", stderr="")
        with mock.patch.object(
            v2rayn_mode.subprocess,
            "run",
            return_value=completed,
        ) as run:
            v2rayn_mode._invoke_v2rayn_reload(Path(r"C:\v2rayN\v2rayN.exe"))

        script = run.call_args.args[0][-1]
        self.assertIn("EventWaitHandle]::OpenExisting", script)
        self.assertIn("CcdV2rayNWindowBridge]::FindMain", script)
        self.assertIn("'menuReload'", script)
        self.assertIn("PostMessage($hwnd,0x0010", script)

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
            state_path = Path(temp_dir) / "switch_state_cf.json"
            with mock.patch.object(
                v2rayn_mode,
                "_switch_state_path",
                return_value=state_path,
            ):
                target_id, _ = v2rayn_mode._choose_switch(
                    {"required_consecutive_wins": 1},
                    ranked,
                    "old-target",
                    "cf",
                )
                selected_state = json.loads(state_path.read_text(encoding="utf-8"))
                v2rayn_mode._record_successful_switch("cf", target_id)
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
                return_value={"cf": "active-slot"},
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
                v2rayn_mode._safe_activate(settings, "new-target", "cf")

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
                "discovery_node": "Cloudflare VMess | 198.51.100.8",
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
            "auto_mode": "cf",
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
            "current_name_before": "AUTO-CF old",
            "current_name_after": "AUTO-CF new",
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
