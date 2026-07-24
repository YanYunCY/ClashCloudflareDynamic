import csv
import json
import os
import random
import socket
import sqlite3
import tempfile
import time
import unittest
from contextlib import closing
from pathlib import Path
from unittest import mock

from clash_cloudflare_dynamic import dynamic_selector as selector
from clash_cloudflare_dynamic import health_monitor_launcher as health_launcher


class FakeDelayAPI:
    def __init__(self, rounds):
        self.rounds = iter(rounds)

    def group_delay(self, group, test_url, timeout_ms):
        return next(self.rounds)


class StageTimerTests(unittest.TestCase):
    def test_stage_timer_accumulates_repeated_stages(self):
        clock = iter([10.0, 10.0, 11.2, 12.0, 14.5])
        timer = selector.StageTimer(clock=lambda: next(clock))

        timer.start("startup")
        timer.start("tcp_probe")
        timer.start("tcp_probe")
        durations = timer.finish()

        self.assertEqual(list(durations), ["startup", "tcp_probe"])
        self.assertEqual(durations["startup"], 1.2)
        self.assertEqual(durations["tcp_probe"], 3.3)


class HealthMonitorLauncherTests(unittest.TestCase):
    @mock.patch.object(health_launcher.subprocess, "run")
    def test_launcher_uses_no_console_and_propagates_exit_code(self, run):
        run.return_value = mock.Mock(returncode=7)
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            powershell = root / "powershell.exe"
            monitor = root / "health_monitor.ps1"
            powershell.write_bytes(b"")
            monitor.write_text("exit 7", encoding="utf-8")

            result = health_launcher.run_health_monitor(
                root=root,
                powershell_path=powershell,
                timeout_seconds=12,
            )

        self.assertEqual(result, 7)
        command = run.call_args.args[0]
        options = run.call_args.kwargs
        self.assertEqual(command[0], str(powershell))
        self.assertEqual(command[-2:], [str(monitor), "-Check"])
        self.assertEqual(
            options["creationflags"],
            getattr(health_launcher.subprocess, "CREATE_NO_WINDOW", 0),
        )
        self.assertIs(options["stdin"], health_launcher.subprocess.DEVNULL)
        self.assertIs(options["stdout"], health_launcher.subprocess.DEVNULL)
        self.assertIs(options["stderr"], health_launcher.subprocess.DEVNULL)
        self.assertEqual(options["timeout"], 12)

    @mock.patch.object(health_launcher.subprocess, "run")
    def test_launcher_timeout_is_reported_without_traceback(self, run):
        run.side_effect = health_launcher.subprocess.TimeoutExpired(
            ["powershell.exe"], 2
        )
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            powershell = root / "powershell.exe"
            monitor = root / "health_monitor.ps1"
            launch_log = root / "launcher.log"
            powershell.write_bytes(b"")
            monitor.write_text("exit 0", encoding="utf-8")
            with mock.patch.object(health_launcher, "LAUNCH_LOG", launch_log):
                result = health_launcher.run_health_monitor(
                    root=root,
                    powershell_path=powershell,
                    timeout_seconds=2,
                )

            self.assertEqual(result, 124)
            self.assertIn("等待超时", launch_log.read_text(encoding="utf-8"))

    def test_launcher_error_log_keeps_only_bounded_backups(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            launch_log = Path(temp_dir) / "launcher.log"
            launch_log.write_bytes(b"a" * 1024)
            health_launcher.rotate_launch_log_if_needed(
                launch_log, max_bytes=1024, backups=2
            )
            launch_log.write_bytes(b"b" * 1024)
            health_launcher.rotate_launch_log_if_needed(
                launch_log, max_bytes=1024, backups=2
            )
            launch_log.write_bytes(b"c" * 1024)
            health_launcher.rotate_launch_log_if_needed(
                launch_log, max_bytes=1024, backups=2
            )

            self.assertFalse(launch_log.exists())
            self.assertEqual(
                launch_log.with_name("launcher.log.1").read_bytes(),
                b"c" * 1024,
            )
            self.assertEqual(
                launch_log.with_name("launcher.log.2").read_bytes(),
                b"b" * 1024,
            )
            self.assertEqual(
                len(list(Path(temp_dir).glob("launcher.log.*"))), 2
            )


class MihomoPollingTests(unittest.TestCase):
    def test_mihomo_put_methods_forward_bounded_timeout(self):
        api = selector.MihomoAPI("http://127.0.0.1:9090", "")
        with mock.patch.object(api, "request") as request:
            api.select("group", "node", timeout=3.0)
            api.update_provider("provider", timeout=8.0)

        self.assertEqual(request.call_args_list[0].kwargs["timeout"], 3.0)
        self.assertEqual(request.call_args_list[1].kwargs["timeout"], 8.0)

    def test_poll_request_keeps_sub_100ms_remaining_budget(self):
        api = selector.MihomoAPI("http://127.0.0.1:9090", "")
        with mock.patch.object(api, "get_proxy", return_value={}) as get_proxy:
            selector._get_proxy_for_poll(api, "group", 0.02)

        self.assertEqual(get_proxy.call_args.kwargs["timeout"], 0.02)

    @mock.patch.object(selector.time, "sleep")
    def test_select_waits_until_group_now_matches(self, sleep):
        class FakeAPI:
            def __init__(self):
                self.states = iter([{"now": "old"}, {"now": "target"}])
                self.select_calls = []

            def select(self, group, node):
                self.select_calls.append((group, node))

            def get_proxy(self, group):
                return next(self.states)

        api = FakeAPI()
        result = selector.select_proxy_and_wait(
            api, "group", "target", 1.0, 0.05
        )

        self.assertEqual(result["now"], "target")
        self.assertEqual(api.select_calls, [("group", "target")])
        sleep.assert_called_once()

    def test_select_and_confirmation_share_one_timeout_budget(self):
        class FakeClock:
            def __init__(self):
                self.value = 10.0

            def __call__(self):
                return self.value

            def advance(self, seconds):
                self.value += seconds

        clock = FakeClock()

        class SlowSelectAPI:
            def select(self, group, node):
                clock.advance(2.0)

            def get_proxy(self, group):
                return {"now": "old"}

        with self.assertRaisesRegex(
            selector.MihomoConfirmationTimeout, "未确认选择"
        ):
            selector.select_proxy_and_wait(
                SlowSelectAPI(),
                "group",
                "target",
                3.0,
                10.0,
                clock=clock,
                sleeper=clock.advance,
            )

        self.assertEqual(clock.value, 13.0)

    def test_select_does_not_poll_after_request_consumes_budget(self):
        class FakeClock:
            def __init__(self):
                self.value = 30.0

            def __call__(self):
                return self.value

        clock = FakeClock()

        class ExhaustedAPI:
            def select(self, group, node):
                clock.value += 3.0

            def get_proxy(self, group):
                raise AssertionError("deadline 后不应再发 GET")

        observer = mock.Mock()
        with self.assertRaisesRegex(
            selector.MihomoConfirmationTimeout, "确认时间已耗尽"
        ):
            selector.select_proxy_and_wait(
                ExhaustedAPI(),
                "group",
                "target",
                3.0,
                0.05,
                clock=clock,
                timeout_observer=observer,
            )

        self.assertEqual(clock.value, 33.0)
        observer.assert_called_once_with()

    def test_proxy_poll_does_not_get_again_at_deadline(self):
        class FakeClock:
            def __init__(self):
                self.value = 0.0

            def __call__(self):
                return self.value

            def advance(self, seconds):
                self.value += seconds

        clock = FakeClock()
        calls = []

        class FakeAPI:
            def get_proxy(self, group):
                calls.append(clock.value)
                return {"now": "old"}

        with self.assertRaises(selector.MihomoConfirmationTimeout):
            selector.wait_for_proxy_now(
                FakeAPI(),
                "group",
                "target",
                1.0,
                1.0,
                clock=clock,
                sleeper=clock.advance,
            )

        self.assertEqual(calls, [0.0])

    def test_wait_for_proxy_now_timeout_reports_last_state(self):
        class FakeAPI:
            def get_proxy(self, group):
                return {"now": "old"}

        with self.assertRaisesRegex(
            selector.MihomoConfirmationTimeout, "最后状态 old"
        ):
            selector.wait_for_proxy_now(
                FakeAPI(), "group", "target", 0, 0.05
            )

    @mock.patch.object(selector.time, "sleep")
    def test_transient_poll_error_is_retried(self, sleep):
        class FakeAPI:
            def __init__(self):
                self.calls = 0

            def get_proxy(self, group):
                self.calls += 1
                if self.calls == 1:
                    raise selector.MihomoAPITransientError("temporary")
                return {"now": "target"}

        result = selector.wait_for_proxy_now(
            FakeAPI(), "group", "target", 1.0, 0.05
        )
        self.assertEqual(result["now"], "target")
        sleep.assert_called_once()

    @mock.patch.object(selector.time, "sleep")
    def test_transient_transport_timeout_is_counted_after_recovery(self, sleep):
        class FakeAPI:
            def __init__(self):
                self.calls = 0

            def get_proxy(self, group):
                self.calls += 1
                if self.calls == 1:
                    raise TimeoutError("timed out")
                return {"now": "target"}

        observer = mock.Mock()
        result = selector.wait_for_proxy_now(
            FakeAPI(),
            "group",
            "target",
            1.0,
            0.05,
            timeout_observer=observer,
        )

        self.assertEqual(result["now"], "target")
        observer.assert_called_once_with()
        sleep.assert_called_once()

    @mock.patch.object(selector.time, "sleep")
    def test_permanent_poll_error_fails_without_retry(self, sleep):
        api = mock.Mock()
        api.get_proxy.side_effect = selector.MihomoAPIPermanentError("HTTP 401")

        with self.assertRaisesRegex(selector.MihomoAPIPermanentError, "401"):
            selector.wait_for_proxy_now(
                api, "group", "target", 1.0, 0.05
            )

        self.assertEqual(api.get_proxy.call_count, 1)
        sleep.assert_not_called()

    @mock.patch.object(selector.time, "sleep")
    def test_wait_for_group_members_polls_for_exact_set(self, sleep):
        class FakeAPI:
            def __init__(self):
                self.states = iter([
                    {"all": ["old"]},
                    {"all": ["a", "b"]},
                ])

            def get_proxy(self, group):
                return next(self.states)

        result = selector.wait_for_group_members(
            FakeAPI(), "group", {"a", "b"}, 1.0, 0.05
        )
        self.assertEqual(set(result["all"]), {"a", "b"})
        sleep.assert_called_once()

    def test_wait_for_group_members_timeout_reports_difference(self):
        class FakeAPI:
            def get_proxy(self, group):
                return {"all": ["a", "unexpected"]}

        with self.assertRaisesRegex(
            selector.MihomoConfirmationTimeout, "缺少 1 个，多出 1 个"
        ):
            selector.wait_for_group_members(
                FakeAPI(), "group", {"a", "b"}, 0, 0.05
            )

    def test_group_poll_does_not_get_again_at_deadline(self):
        class FakeClock:
            def __init__(self):
                self.value = 0.0

            def __call__(self):
                return self.value

            def advance(self, seconds):
                self.value += seconds

        clock = FakeClock()
        calls = []

        class FakeAPI:
            def get_proxy(self, group):
                calls.append(clock.value)
                return {"all": ["old"]}

        with self.assertRaises(selector.MihomoConfirmationTimeout):
            selector.wait_for_group_members(
                FakeAPI(),
                "group",
                {"target"},
                1.0,
                1.0,
                clock=clock,
                sleeper=clock.advance,
            )

        self.assertEqual(calls, [0.0])


class AveragingTests(unittest.TestCase):
    def test_delay_transport_timeout_is_counted(self):
        api = mock.Mock()
        api.group_delay.side_effect = TimeoutError("timed out")
        observer = mock.Mock()

        with self.assertRaises(TimeoutError):
            selector.average_group_delays(
                api,
                "group",
                "url",
                5000,
                3,
                0,
                True,
                timeout_observer=observer,
            )

        observer.assert_called_once_with()

    @mock.patch.object(selector, "log")
    @mock.patch.object(selector.time, "sleep")
    def test_delay_average_requires_all_three_rounds(self, _sleep, _log):
        api = FakeDelayAPI(
            [
                {"CF-D | 1.1.1.1": 100, "CF-D | 2.2.2.2": 80},
                {"CF-D | 1.1.1.1": 110},
                {"CF-D | 1.1.1.1": 120, "CF-D | 2.2.2.2": 90},
            ]
        )

        averages, samples, deviations = selector.average_group_delays(
            api,
            "发现测速",
            "https://example.test/204",
            5000,
            repeats=3,
            repeat_interval_seconds=0,
            require_all_repeats=True,
        )

        self.assertEqual(averages, {"CF-D | 1.1.1.1": 110.0})
        self.assertEqual(samples["CF-D | 1.1.1.1"], [100, 110, 120])
        self.assertAlmostEqual(deviations["CF-D | 1.1.1.1"], 8.16)

    @mock.patch.object(selector, "log")
    @mock.patch.object(selector.time, "sleep")
    @mock.patch.object(selector, "speed_test")
    def test_speed_average_and_samples_use_three_runs(
        self, speed_test, _sleep, _log
    ):
        speed_test.side_effect = [
            {
                "ok": True,
                "speed_Mbps": 8.0,
                "speed_MB_per_s": 1.0,
                "ttfb_ms": 100.0,
                "total_ms": 1000.0,
            },
            {
                "ok": True,
                "speed_Mbps": 10.0,
                "speed_MB_per_s": 1.25,
                "ttfb_ms": 110.0,
                "total_ms": 900.0,
            },
            {
                "ok": True,
                "speed_Mbps": 12.0,
                "speed_MB_per_s": 1.5,
                "ttfb_ms": 120.0,
                "total_ms": 800.0,
            },
        ]

        result = selector.repeated_speed_test(
            "curl",
            "http://127.0.0.1:7890",
            "https://example.test/down",
            1000,
            5,
            repeats=3,
            repeat_interval_seconds=0,
            require_all_repeats=True,
        )

        self.assertTrue(result["ok"])
        self.assertEqual(result["speed_Mbps"], 10.0)
        self.assertEqual(result["speed_MB_per_s"], 1.25)
        self.assertNotIn("speed_MBps", result)
        self.assertEqual(result["speed_stddev_Mbps"], 1.63)
        self.assertEqual(result["speed_cv"], 0.1633)
        self.assertEqual(result["speed_samples_Mbps"], "8.00,10.00,12.00")
        self.assertEqual(result["ttfb_samples_ms"], "100.00,110.00,120.00")

    @mock.patch.object(selector, "log")
    @mock.patch.object(selector.time, "sleep")
    @mock.patch.object(selector, "speed_test")
    def test_speed_average_rejects_any_failed_run(
        self, speed_test, _sleep, _log
    ):
        passed = {
            "ok": True,
            "speed_Mbps": 8.0,
            "speed_MB_per_s": 1.0,
            "ttfb_ms": 100.0,
            "total_ms": 1000.0,
        }
        speed_test.side_effect = [
            passed,
            {"ok": False, "error": "下载量不足"},
            AssertionError("严格模式失败后不应继续测速"),
        ]

        result = selector.repeated_speed_test(
            "curl",
            "http://127.0.0.1:7890",
            "https://example.test/down",
            1000,
            5,
            repeats=3,
            repeat_interval_seconds=0,
            require_all_repeats=True,
        )

        self.assertFalse(result["ok"])
        self.assertEqual(result["successful_runs"], 1)
        self.assertEqual(result["attempted_runs"], 2)
        self.assertEqual(result["planned_runs"], 3)
        self.assertEqual(result["skipped_runs"], 1)
        self.assertEqual(result["speed_samples_Mbps"], "8.00,FAIL,SKIP")
        self.assertEqual(result["ttfb_samples_ms"], "100.00,FAIL,SKIP")
        self.assertEqual(result["speed_Mbps"], 8.0)
        self.assertEqual(result["speed_stddev_Mbps"], 0.0)
        self.assertEqual(result["run_errors"], "2:下载量不足")
        self.assertIn("成功 1/3 次", result["error"])
        self.assertEqual(speed_test.call_count, 2)
        self.assertEqual(_sleep.call_count, 1)

    @mock.patch.object(selector, "log")
    @mock.patch.object(selector.time, "sleep")
    @mock.patch.object(selector, "speed_test")
    def test_strict_speed_test_first_failure_skips_remaining_runs(
        self, speed_test, sleep, _log
    ):
        speed_test.return_value = {
            "ok": False,
            "timed_out": True,
            "error": "连接失败",
        }

        result = selector.repeated_speed_test(
            "curl", "proxy", "url", 1000, 5, 3, 0.5, True
        )

        self.assertFalse(result["ok"])
        self.assertEqual(speed_test.call_count, 1)
        sleep.assert_not_called()
        self.assertEqual(result["attempted_runs"], 1)
        self.assertEqual(result["planned_runs"], 3)
        self.assertEqual(result["skipped_runs"], 2)
        self.assertEqual(result["timeout_runs"], 1)
        self.assertEqual(result["speed_samples_Mbps"], "FAIL,SKIP,SKIP")

    @mock.patch.object(selector, "log")
    @mock.patch.object(selector.time, "sleep")
    @mock.patch.object(selector, "speed_test")
    def test_non_strict_speed_test_continues_after_one_failure(
        self, speed_test, sleep, _log
    ):
        passed = {
            "ok": True,
            "speed_Mbps": 8.0,
            "speed_MB_per_s": 1.0,
            "ttfb_ms": 100.0,
            "total_ms": 1000.0,
        }
        speed_test.side_effect = [
            {"ok": False, "error": "第一次失败"},
            passed,
            passed,
        ]

        result = selector.repeated_speed_test(
            "curl", "proxy", "url", 1000, 5, 3, 0.5, False
        )

        self.assertTrue(result["ok"])
        self.assertEqual(speed_test.call_count, 3)
        self.assertEqual(sleep.call_count, 2)
        self.assertEqual(result["attempted_runs"], 3)
        self.assertEqual(result["skipped_runs"], 0)
        self.assertEqual(result["speed_samples_Mbps"], "FAIL,8.00,8.00")


class SpeedJsonTests(unittest.TestCase):
    @mock.patch.object(selector.subprocess, "run")
    def test_speed_json_uses_unambiguous_byte_rate_key(self, run):
        run.return_value = mock.Mock(
            returncode=0,
            stderr="",
            stdout=json.dumps(
                {
                    "http_code": 200,
                    "time_starttransfer": 0.1,
                    "time_total": 1.0,
                    "size_download": 1_000_000,
                    "speed_download": 500_000,
                }
            ),
        )

        result = selector.speed_test(
            "curl",
            "http://127.0.0.1:7890",
            "https://example.test/down",
            1_000_000,
            5,
        )

        self.assertTrue(result["ok"])
        self.assertIn("speed_Mbps", result)
        self.assertIn("speed_MB_per_s", result)
        self.assertNotIn("speed_MBps", result)
        self.assertEqual(
            len({key.casefold() for key in result}),
            len(result),
        )
        command = run.call_args.args[0]
        self.assertEqual(command[command.index("--noproxy") + 1], "")
        self.assertEqual(
            run.call_args.kwargs["creationflags"],
            getattr(selector.subprocess, "CREATE_NO_WINDOW", 0),
        )
        self.assertFalse(result["timed_out"])

        with tempfile.TemporaryDirectory() as temp_dir:
            output = Path(temp_dir) / "decision.json"
            selector.save_json_atomic(output, {"best": result})
            payload = selector.load_json(output, {})
            self.assertNotIn("speed_MBps", payload["best"])

    @mock.patch.object(selector.subprocess, "run")
    def test_speed_json_rejects_short_response(self, run):
        run.return_value = mock.Mock(
            returncode=0,
            stderr="",
            stdout=json.dumps(
                {
                    "http_code": 200,
                    "time_starttransfer": 0.1,
                    "time_total": 0.1,
                    "size_download": 1,
                    "speed_download": 10,
                }
            ),
        )

        result = selector.speed_test(
            "curl",
            "http://127.0.0.1:7890",
            "https://example.test/down",
            1_000_000,
            5,
        )

        self.assertFalse(result["ok"])
        self.assertIn("下载量不足", result["error"])

    @mock.patch.object(selector.subprocess, "run")
    def test_speed_json_marks_curl_timeout(self, run):
        run.return_value = mock.Mock(
            returncode=28,
            stderr="Operation timed out",
            stdout="",
        )

        result = selector.speed_test(
            "curl", "proxy", "https://example.test/down", 1000, 5
        )

        self.assertFalse(result["ok"])
        self.assertTrue(result["timed_out"])


class TimeoutAndCsvTests(unittest.TestCase):
    def test_template_endpoint_accepts_custom_protocol_and_port(self):
        self.assertEqual(
            selector.template_endpoint({"type": "Trojan", "port": 8443}),
            ("trojan", 8443),
        )

    def test_template_endpoint_rejects_missing_protocol_or_invalid_port(self):
        for template in (
            {"port": 443},
            {"type": "vless", "port": 0},
            {"type": "vless", "port": 65536},
            {"type": "vless", "port": "invalid"},
            {"type": "hysteria2", "port": 443},
        ):
            with self.subTest(template=template):
                with self.assertRaises(RuntimeError):
                    selector.template_endpoint(template)

    @mock.patch.object(selector.urllib.request, "urlopen")
    @mock.patch.object(selector, "log")
    def test_official_range_timeout_is_counted_before_fallback(
        self, _log, urlopen
    ):
        urlopen.side_effect = TimeoutError("timed out")
        observer = mock.Mock()
        with tempfile.TemporaryDirectory() as temp_dir:
            cache = Path(temp_dir) / "ranges.txt"
            with mock.patch.object(selector, "RANGES_CACHE_PATH", cache):
                ranges = selector.load_official_ranges(
                    {
                        "ranges_cache_hours": 24,
                        "official_ipv4_url": "https://example.test/ips-v4",
                    },
                    timeout_observer=observer,
                )

        self.assertEqual(len(ranges), len(selector.FALLBACK_RANGES))
        observer.assert_called_once_with()

    @mock.patch.object(selector.socket, "create_connection")
    def test_tcp_probe_counts_only_timeouts(self, create_connection):
        create_connection.side_effect = [socket.timeout("timed out"), OSError("refused")]

        result = selector.tcp_probe(
            "1.1.1.1", attempts=2, timeout=0.1, port=8443
        )

        self.assertFalse(result["reachable"])
        self.assertEqual(result["port"], 8443)
        self.assertEqual(result["attempts"], 2)
        self.assertEqual(result["timeout_count"], 1)
        self.assertEqual(
            create_connection.call_args_list,
            [
                mock.call(("1.1.1.1", 8443), timeout=0.1),
                mock.call(("1.1.1.1", 8443), timeout=0.1),
            ],
        )

    def test_tcp_probe_rejects_invalid_template_port(self):
        with self.assertRaises(ValueError):
            selector.tcp_probe("1.1.1.1", attempts=1, timeout=0.1, port=0)

    def test_latest_csv_serializes_run_accounting_fields(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            latest = Path(temp_dir) / "latest.csv"
            row = {
                "time": "2026-07-23T12:00:00+08:00",
                "ip": "1.1.1.1",
                "protocol": "vless",
                "port": 8443,
                "speed_samples_Mbps": "FAIL,SKIP,SKIP",
                "successful_runs": 0,
                "attempted_runs": 1,
                "planned_runs": 3,
                "skipped_runs": 2,
                "timeout_runs": 1,
                "speed_ok": False,
            }
            with mock.patch.object(selector, "LATEST_CSV", latest):
                selector.write_latest([row])

            with latest.open("r", encoding="utf-8-sig", newline="") as stream:
                saved = next(csv.DictReader(stream))

        self.assertEqual(saved["attempted_runs"], "1")
        self.assertEqual(saved["planned_runs"], "3")
        self.assertEqual(saved["skipped_runs"], "2")
        self.assertEqual(saved["timeout_runs"], "1")
        self.assertEqual(saved["speed_samples_Mbps"], "FAIL,SKIP,SKIP")
        self.assertEqual(saved["protocol"], "vless")
        self.assertEqual(saved["port"], "8443")

    def test_discovery_and_probe_csv_include_protocol_and_port(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            discovery = root / "discovery.csv"
            probe = root / "probe.csv"
            with mock.patch.object(selector, "DISCOVERY_CSV", discovery):
                selector.write_discovery_log(
                    [
                        {
                            "ip": "1.1.1.1",
                            "port": 2053,
                            "reachable": True,
                            "tcp_ms": 20,
                            "successes": 1,
                            "attempts": 1,
                            "timeout_count": 0,
                        }
                    ],
                    "trojan",
                )
            with mock.patch.object(selector, "SPEED_PROBE_CSV", probe):
                selector.write_speed_probe_log(
                    [
                        {
                            "time": "2026-07-23T12:00:00+08:00",
                            "ip": "1.1.1.1",
                            "protocol": "trojan",
                            "port": 2053,
                        }
                    ]
                )

            with discovery.open(
                "r", encoding="utf-8-sig", newline=""
            ) as stream:
                discovery_row = next(csv.DictReader(stream))
            with probe.open(
                "r", encoding="utf-8-sig", newline=""
            ) as stream:
                probe_row = next(csv.DictReader(stream))

        self.assertEqual(discovery_row["protocol"], "trojan")
        self.assertEqual(discovery_row["port"], "2053")
        self.assertEqual(probe_row["protocol"], "trojan")
        self.assertEqual(probe_row["port"], "2053")

    def test_history_csv_migrates_context_columns(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            history = root / "history.csv"
            history.write_text(
                "time,ip,delay_ms,speed_Mbps,score\n"
                "old,1.1.1.1,100,8.0,90\n",
                encoding="utf-8",
            )
            with mock.patch.object(selector, "LOG_DIR", root), mock.patch.object(
                selector, "HISTORY_PATH", history
            ):
                selector.append_history(
                    [
                        {
                            "time": "new",
                            "protocol": "vmess",
                            "port": 443,
                            "ip": "2.2.2.2",
                            "delay_ms": 90,
                            "speed_Mbps": 9.0,
                            "score": 95,
                        }
                    ]
                )
            with history.open(
                "r", encoding="utf-8-sig", newline=""
            ) as stream:
                reader = csv.DictReader(stream)
                rows = list(reader)
                fields = reader.fieldnames

        self.assertEqual(
            fields,
            [
                "time",
                "protocol",
                "port",
                "ip",
                "delay_ms",
                "speed_Mbps",
                "score",
            ],
        )
        self.assertEqual(rows[0]["protocol"], "")
        self.assertEqual(rows[1]["protocol"], "vmess")
        self.assertEqual(rows[1]["port"], "443")


class RankingTests(unittest.TestCase):
    def test_fast_band_uses_average_speed_then_lowest_average_delay(self):
        rows = [
            {"ip": "1.1.1.1", "speed_ok": True, "speed_Mbps": 100, "delay_ms": 180},
            {"ip": "2.2.2.2", "speed_ok": True, "speed_Mbps": 98, "delay_ms": 140},
            {"ip": "3.3.3.3", "speed_ok": True, "speed_Mbps": 70, "delay_ms": 90},
        ]

        ranked = selector.rank_rows(rows, 0.95)

        self.assertEqual([row["ip"] for row in ranked], ["2.2.2.2", "1.1.1.1", "3.3.3.3"])
        self.assertTrue(ranked[0]["fast_group"])
        self.assertFalse(ranked[-1]["fast_group"])

    def test_fast_speed_ratio_is_normalized_consistently(self):
        self.assertEqual(selector.normalize_fast_speed_ratio(2), 1.0)
        self.assertEqual(selector.normalize_fast_speed_ratio(0.1), 0.5)
        self.assertEqual(selector.normalize_fast_speed_ratio("invalid"), 0.95)


class SwitchConfirmationTests(unittest.TestCase):
    def test_switch_state_updates_only_after_mihomo_confirms(self):
        class FakeAPI:
            def __init__(self):
                self.selected = []

            def select(self, group, node):
                self.selected.append((group, node))

            def get_proxy(self, group):
                return {"now": "CF-A | 2.2.2.2"}

        api = FakeAPI()
        state = {"pending_ip": "", "pending_wins": 0, "last_switch": None}
        decision = selector.decide_switch(
            api,
            {
                "auto_group": "自动选择",
                "fast_speed_ratio": 0.95,
                "selector_confirm_timeout_seconds": 0,
                "mihomo_poll_interval_seconds": 0.05,
            },
            [{"ip": "2.2.2.2", "speed_Mbps": 10.0, "delay_ms": 80}],
            None,
            state,
        )

        self.assertTrue(decision["switched"])
        self.assertEqual(state["current_ip"], "2.2.2.2")
        self.assertEqual(api.selected, [("自动选择", "CF-A | 2.2.2.2")])

    def test_unconfirmed_switch_does_not_modify_state(self):
        class FakeAPI:
            def select(self, group, node):
                pass

            def get_proxy(self, group):
                return {"now": "CF-A | 1.1.1.1"}

        state = {"pending_ip": "", "pending_wins": 0, "last_switch": None}
        original = dict(state)

        with self.assertRaisesRegex(RuntimeError, "未确认选择"):
            selector.decide_switch(
                FakeAPI(),
                {
                    "auto_group": "自动选择",
                    "fast_speed_ratio": 0.95,
                    "selector_confirm_timeout_seconds": 0,
                    "mihomo_poll_interval_seconds": 0.05,
                },
                [{"ip": "2.2.2.2", "speed_Mbps": 10.0, "delay_ms": 80}],
                None,
                state,
            )

        self.assertEqual(state, original)


class ProbeSelectionTests(unittest.TestCase):
    @mock.patch.object(selector, "load_historical_speed_scores")
    def test_probe_set_combines_latency_history_and_exploration(self, history):
        names = [f"CF-D | 1.1.1.{index}" for index in range(1, 7)]
        delays = {name: float(index * 10) for index, name in enumerate(names, 1)}
        history.return_value = {
            "1.1.1.4": 100.0,
            "1.1.1.5": 50.0,
        }
        settings = {
            "speed_candidates": 3,
            "speed_probe_candidates": 6,
            "speed_probe_latency_share": 0.5,
            "speed_probe_history_share": 1 / 3,
        }

        selected, counts = selector.select_speed_probe_names(
            delays,
            {"1.1.1.1", "1.1.1.2", "1.1.1.3", "1.1.1.4", "1.1.1.5"},
            None,
            settings,
            random.Random(7),
        )

        self.assertEqual(selected[:3], names[:3])
        self.assertEqual(selected[3:5], names[3:5])
        self.assertEqual(selected[5], names[5])
        self.assertEqual(
            counts,
            {
                "low_latency": 3,
                "history": 2,
                "exploration": 1,
                "current_extra": 0,
            },
        )

    @mock.patch.object(selector, "load_historical_speed_scores", return_value={})
    def test_current_node_is_appended_outside_probe_limit(self, _history):
        names = [f"CF-D | 2.2.2.{index}" for index in range(1, 6)]
        delays = {name: float(index * 10) for index, name in enumerate(names, 1)}

        selected, counts = selector.select_speed_probe_names(
            delays,
            set(),
            names[-1],
            {
                "speed_candidates": 3,
                "speed_probe_candidates": 3,
                "speed_probe_latency_share": 1,
                "speed_probe_history_share": 0,
            },
            random.Random(11),
        )

        self.assertEqual(selected, [*names[:3], names[-1]])
        self.assertEqual(counts["current_extra"], 1)


class ActivePoolTests(unittest.TestCase):
    def test_excluded_ips_are_not_restored_from_any_pool_source(self):
        active = selector.build_active_pool(
            ranked=[
                {"ip": "3.3.3.3"},
                {"ip": "4.4.4.4"},
            ],
            delays={
                "CF-D | 3.3.3.3": 10.0,
                "CF-D | 5.5.5.5": 20.0,
            },
            previous_active=["3.3.3.3", "6.6.6.6"],
            current_ip="3.3.3.3",
            pool_size=10,
            excluded_ips={"3.3.3.3", "6.6.6.6"},
        )

        self.assertEqual(active, ["4.4.4.4", "5.5.5.5"])

    def test_current_ip_is_kept_when_fixed_nodes_exceed_discovery_limit(self):
        rows = [
            {
                "ip": f"1.1.1.{index}",
                "reachable": True,
                "tcp_ms": float(index),
            }
            for index in range(1, 6)
        ]
        selected = selector.select_discovery_ips(
            rows,
            {row["ip"] for row in rows},
            limit=3,
            preferred_ip="1.1.1.5",
        )

        self.assertEqual(selected[0], "1.1.1.5")
        self.assertEqual(len(selected), 3)

    def test_discovery_pool_reserves_new_ip_quota(self):
        fixed = {f"10.0.0.{index}" for index in range(1, 13)}
        rows = [
            {"ip": ip, "reachable": True, "tcp_ms": float(index)}
            for index, ip in enumerate(sorted(fixed), 1)
        ]
        new_ips = [f"20.0.0.{index}" for index in range(1, 9)]
        rows.extend(
            {
                "ip": ip,
                "reachable": True,
                "tcp_ms": 100.0 + index,
            }
            for index, ip in enumerate(new_ips, 1)
        )

        selected = selector.select_discovery_ips(
            rows,
            fixed,
            limit=10,
            preferred_ip="10.0.0.12",
            priority_ips={"10.0.0.11", "10.0.0.12"},
            new_ip_share=0.4,
        )

        self.assertEqual(selected[0], "10.0.0.12")
        self.assertEqual(len(selected), 10)
        selected_new = [ip for ip in selected if ip not in fixed]
        self.assertEqual(selected_new, new_ips[:4])
        self.assertEqual(len(selected), len(set(selected)))

    def test_discovery_pool_backfills_when_new_quota_is_unavailable(self):
        fixed = {f"10.0.0.{index}" for index in range(1, 10)}
        rows = [
            {"ip": ip, "reachable": True, "tcp_ms": float(index)}
            for index, ip in enumerate(sorted(fixed), 1)
        ]
        rows.extend([
            {"ip": "20.0.0.1", "reachable": True, "tcp_ms": 20.0},
            {"ip": "20.0.0.2", "reachable": True, "tcp_ms": 21.0},
            {"ip": "20.0.0.3", "reachable": False, "tcp_ms": None},
        ])

        selected = selector.select_discovery_ips(
            rows, fixed, limit=10, new_ip_share=0.4
        )

        self.assertEqual(len(selected), 10)
        self.assertEqual(
            {ip for ip in selected if ip not in fixed},
            {"20.0.0.1", "20.0.0.2"},
        )

    def test_preferred_new_ip_counts_toward_quota(self):
        fixed = {f"10.0.0.{index}" for index in range(1, 9)}
        new_ips = [f"20.0.0.{index}" for index in range(1, 7)]
        rows = [
            {"ip": ip, "reachable": True, "tcp_ms": float(index)}
            for index, ip in enumerate([*sorted(fixed), *new_ips], 1)
        ]

        selected = selector.select_discovery_ips(
            rows,
            fixed,
            limit=10,
            preferred_ip="20.0.0.6",
            new_ip_share=0.4,
        )

        self.assertEqual(selected[0], "20.0.0.6")
        self.assertEqual(sum(ip not in fixed for ip in selected), 4)
        self.assertEqual(len(selected), 10)

    def test_discovery_pool_zero_limit_returns_empty(self):
        selected = selector.select_discovery_ips(
            [{"ip": "1.1.1.1", "reachable": True, "tcp_ms": 1.0}],
            {"1.1.1.1"},
            limit=0,
            preferred_ip="1.1.1.1",
            new_ip_share=0.4,
        )
        self.assertEqual(selected, [])


class DiscoveryHistoryTests(unittest.TestCase):
    def test_legacy_443_history_schema_is_migrated_with_port(self):
        with closing(sqlite3.connect(":memory:")) as connection:
            connection.execute(
                """
                CREATE TABLE ip_history (
                    ip TEXT PRIMARY KEY,
                    last_sampled REAL NOT NULL,
                    last_tcp_reachable INTEGER NOT NULL DEFAULT 0,
                    last_tcp_ms REAL,
                    last_vm_success REAL,
                    last_speed_success REAL,
                    last_speed_failure REAL
                )
                """
            )
            connection.execute(
                "INSERT INTO ip_history (ip, last_sampled) VALUES (?, ?)",
                ("1.1.1.1", 1.0),
            )

            selector.initialize_discovery_db(connection)

            columns = {
                str(row[1])
                for row in connection.execute("PRAGMA table_info(ip_history)")
            }
            self.assertIn("port", columns)
            port = connection.execute(
                "SELECT port FROM ip_history WHERE ip = ?", ("1.1.1.1",)
            ).fetchone()[0]
            self.assertEqual(port, 443)

    @mock.patch.object(selector, "log")
    def test_recent_tcp_samples_are_loaded_and_old_samples_expire(self, _log):
        base_time = 1_800_000_000.0
        with tempfile.TemporaryDirectory() as temp_dir:
            database = Path(temp_dir) / "discovery.sqlite3"
            opened_connections = []
            original_open = selector.open_discovery_db

            def tracked_open():
                connection = original_open()
                opened_connections.append(connection)
                return connection

            try:
                with mock.patch.object(selector, "DISCOVERY_DB_PATH", database):
                    with mock.patch.object(
                        selector,
                        "open_discovery_db",
                        side_effect=tracked_open,
                    ):
                        with mock.patch.object(
                            selector.time, "time", return_value=base_time
                        ):
                            selector.record_tcp_history(
                                [
                                    {
                                        "ip": "7.7.7.7",
                                        "port": 8443,
                                        "reachable": True,
                                        "tcp_ms": 12.5,
                                    },
                                    {
                                        "ip": "8.8.8.8",
                                        "port": 8443,
                                        "reachable": False,
                                        "tcp_ms": None,
                                    },
                                ]
                            )
                            self.assertEqual(
                                selector.load_recently_sampled_ips(30, 8443),
                                {"7.7.7.7", "8.8.8.8"},
                            )
                            self.assertEqual(
                                selector.load_recently_sampled_ips(30, 443),
                                set(),
                            )

                        with mock.patch.object(
                            selector.time,
                            "time",
                            return_value=base_time + 31 * 86400,
                        ):
                            self.assertEqual(
                                selector.load_recently_sampled_ips(30, 8443),
                                set(),
                            )
            finally:
                for connection in opened_connections:
                    connection.close()

    @mock.patch.object(selector, "log")
    def test_cleanup_removes_only_samples_older_than_90_days(self, _log):
        base_time = 1_800_000_000.0
        day = 86400
        with tempfile.TemporaryDirectory() as temp_dir:
            database = Path(temp_dir) / "discovery.sqlite3"
            with mock.patch.object(selector, "DISCOVERY_DB_PATH", database):
                with mock.patch.object(
                    selector.time, "time", return_value=base_time - 91 * day
                ):
                    selector.record_tcp_history(
                        [{"ip": "9.9.9.9", "reachable": False, "tcp_ms": None}]
                    )
                with mock.patch.object(
                    selector.time, "time", return_value=base_time - 90 * day
                ):
                    selector.record_tcp_history(
                        [{"ip": "9.9.9.10", "reachable": True, "tcp_ms": 20}]
                    )
                with mock.patch.object(
                    selector.time, "time", return_value=base_time - 10 * day
                ):
                    selector.record_tcp_history(
                        [{"ip": "9.9.9.11", "reachable": True, "tcp_ms": 15}]
                    )

                with mock.patch.object(
                    selector.time, "time", return_value=base_time
                ):
                    self.assertEqual(
                        selector.cleanup_discovery_history(90),
                        1,
                    )
                    self.assertEqual(
                        selector.load_recently_sampled_ips(90),
                        {"9.9.9.10", "9.9.9.11"},
                    )


class AtomicFileTests(unittest.TestCase):
    def test_copy_file_atomic_replaces_target_without_temp_file(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source = root / "source.yaml"
            target = root / "nested" / "target.yaml"
            source.write_bytes(b"new provider contents")
            target.parent.mkdir(parents=True)
            target.write_bytes(b"old provider contents")

            selector.copy_file_atomic(source, target)

            self.assertEqual(target.read_bytes(), source.read_bytes())
            self.assertEqual(source.read_bytes(), b"new provider contents")
            self.assertFalse(target.with_suffix(".yaml.tmp").exists())


class DeepScanDeferralTests(unittest.TestCase):
    def test_deep_scan_deferral_policy_is_limited_to_busy_non_quick_runs(self):
        self.assertTrue(selector.should_defer_deep_scan(False, True))
        self.assertFalse(selector.should_defer_deep_scan(True, True))
        self.assertFalse(selector.should_defer_deep_scan(False, False))
        self.assertFalse(selector.should_defer_deep_scan(False, True, False))

    @mock.patch.object(selector, "send_windows_notification")
    @mock.patch.object(selector, "log")
    @mock.patch.object(selector.time, "sleep")
    @mock.patch.object(
        selector,
        "foreground_busy_reason",
        return_value="检测到前台全屏程序",
    )
    def test_continuously_busy_deep_scan_is_skipped_after_maximum_deferrals(
        self, _busy_reason, sleep, _log, notification
    ):
        result = selector.defer_deep_scan_if_busy(
            {
                "deep_scan_busy_deferral_enabled": True,
                "deep_scan_recent_input_seconds": 120,
                "deep_scan_deferral_minutes": 15,
                "deep_scan_max_deferrals": 2,
            },
            quick=False,
        )

        self.assertIsNone(result)
        self.assertEqual(sleep.call_args_list, [mock.call(900), mock.call(900)])
        self.assertTrue(
            any(
                "已跳过" in str(call.args[0])
                for call in notification.call_args_list
            )
        )

    @mock.patch.object(selector, "send_windows_notification")
    @mock.patch.object(selector, "log")
    @mock.patch.object(selector.time, "sleep")
    @mock.patch.object(
        selector,
        "foreground_busy_reason",
        side_effect=[
            "检测到前台全屏程序",
            "检测到前台全屏程序",
            None,
        ],
    )
    def test_final_busy_recheck_can_resume_at_maximum_deferrals(
        self, _busy_reason, sleep, _log, notification
    ):
        result = selector.defer_deep_scan_if_busy(
            {
                "deep_scan_busy_deferral_enabled": True,
                "deep_scan_recent_input_seconds": 120,
                "deep_scan_deferral_minutes": 15,
                "deep_scan_max_deferrals": 2,
            },
            quick=False,
        )

        self.assertEqual(result, 2)
        self.assertEqual(sleep.call_args_list, [mock.call(900), mock.call(900)])
        self.assertFalse(
            any(
                "已跳过" in str(call.args[0])
                for call in notification.call_args_list
            )
        )

    @mock.patch.object(selector, "send_windows_notification")
    @mock.patch.object(selector, "log")
    @mock.patch.object(selector.time, "sleep")
    @mock.patch.object(
        selector,
        "foreground_busy_reason",
        return_value="检测到前台全屏程序",
    )
    def test_deferral_count_is_capped_to_sixty_minutes(
        self, _busy_reason, sleep, _log, _notification
    ):
        result = selector.defer_deep_scan_if_busy(
            {
                "deep_scan_busy_deferral_enabled": True,
                "deep_scan_deferral_minutes": 15,
                "deep_scan_max_deferrals": 5,
            },
            quick=False,
        )

        self.assertIsNone(result)
        self.assertEqual(sleep.call_args_list, [mock.call(900)] * 4)

    @mock.patch.object(selector, "send_windows_notification")
    @mock.patch.object(selector, "log")
    @mock.patch.object(selector.time, "sleep")
    @mock.patch.object(
        selector,
        "foreground_busy_reason",
        return_value="检测到前台全屏程序",
    )
    def test_single_deferral_is_used_when_requested_delay_exceeds_sixty_minutes(
        self, _busy_reason, sleep, _log, _notification
    ):
        result = selector.defer_deep_scan_if_busy(
            {
                "deep_scan_busy_deferral_enabled": True,
                "deep_scan_deferral_minutes": 61,
                "deep_scan_max_deferrals": 2,
            },
            quick=False,
        )

        self.assertIsNone(result)
        self.assertEqual(sleep.call_args_list, [mock.call(3600)])

    @mock.patch.object(selector, "foreground_busy_reason")
    @mock.patch.object(selector.time, "sleep")
    def test_quick_or_disabled_scan_never_waits_for_foreground_idle(
        self, sleep, busy_reason
    ):
        settings = {
            "deep_scan_busy_deferral_enabled": True,
            "deep_scan_deferral_minutes": 15,
            "deep_scan_max_deferrals": 4,
        }

        self.assertEqual(
            selector.defer_deep_scan_if_busy(settings, quick=True),
            0,
        )
        self.assertEqual(
            selector.defer_deep_scan_if_busy(
                {**settings, "deep_scan_busy_deferral_enabled": False},
                quick=False,
            ),
            0,
        )
        sleep.assert_not_called()
        busy_reason.assert_not_called()


class NotificationTests(unittest.TestCase):
    @staticmethod
    def _stage_funnel_summary():
        return {
            "candidate_count": 101,
            "tcp_reachable_count": 89,
            "tcp_failed_count": 12,
            "discovery_pool_count": 71,
            "discovery_not_selected_count": 18,
            "proxy_valid_count": 61,
            "proxy_failed_count": 10,
            "speed_probe_selected_count": 53,
            "speed_probe_attempted_count": 53,
            "speed_probe_passed_count": 45,
            "speed_probe_failed_count": 8,
            "speed_probe_not_selected_count": 8,
            "speed_probe_selected_not_attempted_count": 0,
            "formal_selected_count": 31,
            "speed_attempted_count": 31,
            "speed_passed_count": 31,
            "formal_failed_count": 0,
            "formal_not_selected_count": 14,
            "formal_selected_not_attempted_count": 0,
            "fast_group_count": 19,
            "outside_fast_group_count": 12,
            "active_pool_size": 24,
            "new_active_count": 5,
            "pool_size_delta": 0,
            "failed_count": 30,
            "duration_seconds": 125,
        }

    def test_stage_funnel_counts_keep_failures_and_capacity_exclusions_distinct(self):
        counts = selector.normalize_scan_summary_counts(
            self._stage_funnel_summary()
        )

        expected = {
            "tcp_failed_count": 12,
            "discovery_not_selected_count": 18,
            "proxy_failed_count": 10,
            "speed_probe_selected_count": 53,
            "speed_probe_attempted_count": 53,
            "speed_probe_failed_count": 8,
            "speed_probe_not_selected_count": 8,
            "speed_probe_selected_not_attempted_count": 0,
            "formal_selected_count": 31,
            "formal_failed_count": 0,
            "formal_not_selected_count": 14,
            "formal_selected_not_attempted_count": 0,
            "fast_group_count": 19,
            "outside_fast_group_count": 12,
        }
        self.assertEqual(
            {key: counts[key] for key in expected},
            expected,
        )
        self.assertEqual(
            counts["failed_count"],
            counts["tcp_failed_count"]
            + counts["proxy_failed_count"]
            + counts["speed_probe_failed_count"]
            + counts["formal_failed_count"],
        )
        self.assertNotEqual(
            counts["failed_count"],
            counts["discovery_not_selected_count"]
            + counts["speed_probe_not_selected_count"]
            + counts["formal_not_selected_count"]
            + counts["outside_fast_group_count"],
        )
        self.assertEqual(
            counts["candidate_count"],
            counts["tcp_reachable_count"] + counts["tcp_failed_count"],
        )
        self.assertEqual(
            counts["tcp_reachable_count"],
            counts["discovery_pool_count"]
            + counts["discovery_not_selected_count"],
        )
        self.assertEqual(
            counts["proxy_valid_count"],
            counts["speed_probe_selected_count"]
            + counts["speed_probe_not_selected_count"],
        )
        self.assertEqual(
            counts["speed_probe_selected_count"],
            counts["speed_probe_attempted_count"]
            + counts["speed_probe_selected_not_attempted_count"],
        )
        self.assertEqual(
            counts["speed_probe_passed_count"],
            counts["formal_selected_count"]
            + counts["formal_not_selected_count"],
        )
        self.assertEqual(
            counts["formal_passed_count"],
            counts["fast_group_count"] + counts["outside_fast_group_count"],
        )

    def test_selected_but_unexecuted_nodes_are_reported_separately(self):
        summary = self._stage_funnel_summary()
        summary.update(
            {
                "speed_probe_selected_count": 55,
                "speed_probe_attempted_count": 53,
                "speed_probe_selected_not_attempted_count": 2,
                "speed_probe_not_selected_count": 6,
                "formal_selected_count": 32,
                "formal_attempted_count": 31,
                "formal_selected_not_attempted_count": 1,
                "formal_not_selected_count": 13,
            }
        )

        self.assertIn(
            "已选未执行：粗测 2，正式 1",
            selector.format_scan_funnel_lines(summary),
        )

    def test_legacy_summary_does_not_invent_probe_counts(self):
        _, message = selector.build_scan_notification(
            {
                "current_ip_before": "192.0.2.1",
                "switched": False,
                "current_metrics": {"speed_Mbps": 9, "delay_ms": 30},
                "best": {"ip": "192.0.2.1", "speed_Mbps": 9, "delay_ms": 30},
            },
            quick=True,
            summary={
                "candidate_count": 500,
                "tcp_reachable_count": 250,
                "discovery_pool_count": 120,
                "proxy_valid_count": 100,
                "speed_attempted_count": 3,
                "speed_passed_count": 2,
                "active_pool_size": 40,
                "pool_size_delta": 0,
                "failed_count": 1,
            },
        )

        self.assertIn(
            "本轮：候选 500，TCP 250/500，链路 100/120，测速 2/3",
            message,
        )
        self.assertNotIn("粗测 0/0", message)
        self.assertNotIn("高速组外", message)

    def test_html_report_is_unique_complete_and_escaped(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            report_dir = Path(temp_dir) / "notification_reports"
            ranked = [
                {
                    "ip": "2.2.2.2",
                    "fast_group": True,
                    "speed_Mbps": 10.5,
                    "speed_samples_Mbps": "10.00,10.50,11.00",
                    "speed_stddev_Mbps": 0.41,
                    "speed_cv": 0.039,
                    "delay_ms": 92,
                    "delay_samples_ms": "90,92,94",
                    "delay_stddev_ms": 1.63,
                }
            ]
            with (
                mock.patch.object(
                    selector,
                    "speed_test",
                    side_effect=[
                        {
                            "ok": True,
                            "speed_Mbps": 4.0,
                            "speed_MB_per_s": 0.5,
                            "ttfb_ms": 125.0,
                            "total_ms": 1000.0,
                        },
                        {
                            "ok": False,
                            "error": "第二次失败 <script>alert(1)</script>",
                        },
                        AssertionError("失败后不应继续测速"),
                    ],
                ),
                mock.patch.object(selector.time, "sleep"),
                mock.patch.object(selector, "log"),
            ):
                failed_result = selector.repeated_speed_test(
                    "curl", "proxy", "url", 1000, 5, 3, 0, True
                )
            failed = [{
                "ip": "3.3.3.3",
                "delay_ms": 120,
                "delay_samples_ms": "118,120,122",
                "delay_stddev_ms": 1.63,
                **failed_result,
            }]
            decision = {
                "current_ip_before": "1.1.1.1",
                "current_ip_after": "2.2.2.2",
                "switched": True,
                "current_metrics": {
                    "speed_Mbps": 8.25,
                    "delay_ms": 135,
                },
                "best": ranked[0],
                "reason": "高速组内延迟最低",
            }
            summary = {
                "candidate_count": 500,
                "tcp_reachable_count": 250,
                "proxy_valid_count": 100,
                "speed_passed_count": 1,
                "speed_attempted_count": 2,
                "active_pool_size": 40,
                "new_active_count": 4,
                "failed_count": 1,
                "duration_seconds": 125,
                "stage_durations_seconds": {
                    "tcp_probe": 5.2,
                    "formal_speed": 52.4,
                },
                "timeout_counts": {
                    "tcp_probe": 1,
                    "formal_speed": 0,
                },
            }
            with mock.patch.object(
                selector, "NOTIFICATION_REPORT_DIR", report_dir
            ):
                first = selector.create_notification_report(
                    "扫描完成 <script>",
                    "已完成 & 可查看",
                    decision=decision,
                    summary=summary,
                    ranked=ranked,
                    failed_rows=failed,
                )
                second = selector.create_notification_report(
                    "扫描完成", "第二条", decision=decision
                )

            self.assertNotEqual(first, second)
            self.assertTrue(first.is_file())
            document = first.read_text(encoding="utf-8")
            self.assertIn("10.00,10.50,11.00", document)
            self.assertIn("90,92,94", document)
            self.assertIn("高速组内延迟最低", document)
            self.assertIn("4.00,FAIL,SKIP", document)
            self.assertIn("118,120,122", document)
            self.assertIn("2:第二次失败 &lt;script&gt;alert(1)&lt;/script&gt;", document)
            self.assertNotIn("<script>alert(1)</script>", document)
            self.assertIn("Content-Security-Policy", document)
            self.assertIn("2分05秒", document)
            self.assertIn("TCP 初筛", document)
            self.assertIn("正式测速", document)
            self.assertIn("52.40 秒", document)
            self.assertIn("超时次数", document)

    def test_notification_report_cleanup_only_removes_expired_reports(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            report_dir = Path(temp_dir)
            old_report = report_dir / "notification_old.html"
            recent_report = report_dir / "notification_recent.html"
            unrelated = report_dir / "other_old.html"
            for path in (old_report, recent_report, unrelated):
                path.write_text("test", encoding="utf-8")
            old_time = time.time() - 31 * 86400
            os.utime(old_report, (old_time, old_time))
            os.utime(unrelated, (old_time, old_time))

            with mock.patch.object(
                selector, "NOTIFICATION_REPORT_DIR", report_dir
            ):
                deleted = selector.cleanup_notification_reports(30)

            self.assertEqual(deleted, 1)
            self.assertFalse(old_report.exists())
            self.assertTrue(recent_report.exists())
            self.assertTrue(unrelated.exists())

    def test_notification_report_cleanup_also_caps_recent_file_count(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            report_dir = Path(temp_dir)
            baseline = time.time() - 60
            reports = []
            for index in range(5):
                report = report_dir / f"notification_{index}.html"
                report.write_text(str(index), encoding="utf-8")
                stamp = baseline + index
                os.utime(report, (stamp, stamp))
                reports.append(report)
            unrelated = report_dir / "manual_report.html"
            unrelated.write_text("keep", encoding="utf-8")

            with mock.patch.object(
                selector, "NOTIFICATION_REPORT_DIR", report_dir
            ):
                deleted = selector.cleanup_notification_reports(30, 3)

            self.assertEqual(deleted, 2)
            self.assertEqual(
                [path.name for path in reports if path.exists()],
                ["notification_2.html", "notification_3.html", "notification_4.html"],
            )
            self.assertTrue(unrelated.exists())

    def test_new_report_is_preserved_when_existing_files_have_future_times(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            report_dir = Path(temp_dir)
            future = time.time() + 3600
            for index in range(3):
                report = report_dir / f"notification_future_{index}.html"
                report.write_text(str(index), encoding="utf-8")
                stamp = future + index
                os.utime(report, (stamp, stamp))

            with mock.patch.object(
                selector, "NOTIFICATION_REPORT_DIR", report_dir
            ):
                created = selector.create_notification_report(
                    "扫描完成", "保留当前报告", maximum_count=2
                )

            self.assertTrue(created.is_file())
            self.assertEqual(
                len(list(report_dir.glob("notification_*.html"))), 2
            )

    def test_html_report_separates_funnel_failures_and_capacity_exclusions(self):
        summary = self._stage_funnel_summary()
        summary["fast_speed_ratio"] = 0.90
        ranked = [
            {
                "ip": f"192.0.2.{index}",
                "fast_group": index <= summary["fast_group_count"],
                "speed_Mbps": 100 - index,
                "delay_ms": 20 + index,
            }
            for index in range(1, summary["speed_passed_count"] + 1)
        ]
        decision = {
            "current_ip_before": ranked[0]["ip"],
            "current_ip_after": ranked[0]["ip"],
            "switched": False,
            "current_metrics": ranked[0],
            "best": ranked[0],
            "reason": "当前节点仍是高速组内最低延迟",
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            with mock.patch.object(
                selector,
                "NOTIFICATION_REPORT_DIR",
                Path(temp_dir) / "notification_reports",
            ):
                report = selector.create_notification_report(
                    "扫描完成",
                    "阶段漏斗已更新",
                    decision=decision,
                    summary=summary,
                    ranked=ranked,
                    failed_rows=[],
                )
            document = report.read_text(encoding="utf-8")

        expected_rows = [
            (
                "TCP 初筛",
                (101, 89, 12, 0, 18),
                "TCP 可达但未进入发现池",
            ),
            (
                "真实代理链路",
                (71, 61, 10, 0, 8),
                "链路有效但未进入速度粗测",
            ),
            (
                "速度粗测",
                (53, 45, 8, 0, 14),
                "粗测通过但未进入正式测速",
            ),
            (
                "正式三轮测速",
                (31, 31, 0, 0, 12),
                "未达到最高平均速度的 90%（高速组外，非失败）",
            ),
        ]
        for label, values, note in expected_rows:
            cells = "".join(f"<td>{value}</td>" for value in values)
            self.assertIn(
                f'<th scope="row">{label}</th>{cells}<td>{note}</td>',
                document,
            )
        self.assertIn("<h2>正式三轮测速淘汰（0）", document)
        self.assertIn(
            '<div class="success">本轮正式测速 31/31 全部通过</div>',
            document,
        )
        self.assertIn(
            "无正式测速淘汰项；此处不包含前序阶段失败或因名额限制未入选的 IP",
            document,
        )
        self.assertNotIn('<div class="warning">', document)

    def test_notification_keeps_failures_and_capacity_exclusions_distinct(self):
        _, message = selector.build_scan_notification(
            {
                "current_ip_before": "192.0.2.1",
                "switched": False,
                "current_metrics": {
                    "ip": "192.0.2.1",
                    "speed_Mbps": 99,
                    "delay_ms": 21,
                },
                "best": {
                    "ip": "192.0.2.1",
                    "speed_Mbps": 99,
                    "delay_ms": 21,
                },
            },
            quick=True,
            summary=self._stage_funnel_summary(),
        )

        message_lines = message.splitlines()
        self.assertIn(
            "流程：101 → TCP 89 → 代理 61 → "
            "粗测 45/53 → 正式 31/31",
            message_lines,
        )
        funnel_lines = [
            line
            for line in message_lines
            if line.startswith(("失败：", "名额未入选："))
        ]
        self.assertEqual(
            funnel_lines,
            [
                "失败：TCP 12，代理 10，粗测 8，正式 0",
                "名额未入选：TCP 后 18，代理后 8，粗测后 14；"
                "高速组外 12（非失败）",
            ],
        )
        self.assertNotIn("淘汰 30", "\n".join(funnel_lines))

    def test_switched_notification_contains_both_ips_and_metrics(self):
        title, message = selector.build_scan_notification(
            {
                "current_ip_before": "1.1.1.1",
                "current_ip_after": "2.2.2.2",
                "switched": True,
                "current_metrics": {
                    "ip": "1.1.1.1",
                    "speed_Mbps": 8.25,
                    "delay_ms": 135,
                },
                "best": {
                    "ip": "2.2.2.2",
                    "speed_Mbps": 10.5,
                    "delay_ms": 92,
                },
            },
            quick=True,
        )

        self.assertIn("轻量扫描", title)
        self.assertIn("已切换 IP", title)
        self.assertIn("切换前：1.1.1.1 | 8.25 Mbps / 135 ms", message)
        self.assertIn("切换后：2.2.2.2 | 10.50 Mbps / 92 ms", message)
        self.assertIn("变化：速度提升 2.25 Mbps，延迟降低 43 ms", message)

        _, message = selector.build_scan_notification(
            {
                "current_ip_before": "1.1.1.1",
                "current_ip_after": "2.2.2.2",
                "switched": True,
                "current_metrics": {
                    "speed_Mbps": 8.25,
                    "delay_ms": 135,
                },
                "best": {
                    "ip": "2.2.2.2",
                    "speed_Mbps": 10.5,
                    "delay_ms": 92,
                },
            },
            quick=True,
            summary={
                "node_protocol": "trojan",
                "node_port": 8443,
                "candidate_count": 500,
                "tcp_reachable_count": 250,
                "tcp_failed_count": 250,
                "proxy_valid_count": 100,
                "discovery_pool_count": 120,
                "discovery_not_selected_count": 130,
                "proxy_failed_count": 20,
                "speed_probe_attempted_count": 24,
                "speed_probe_passed_count": 20,
                "speed_probe_failed_count": 4,
                "speed_probe_not_selected_count": 76,
                "speed_passed_count": 2,
                "speed_attempted_count": 3,
                "formal_failed_count": 1,
                "formal_not_selected_count": 17,
                "fast_group_count": 2,
                "outside_fast_group_count": 0,
                "active_pool_size": 40,
                "new_active_count": 4,
                "pool_size_delta": 2,
                "failed_count": 275,
                "duration_seconds": 125,
            },
        )
        self.assertIn("入口：trojan / TCP 8443", message)
        self.assertIn(
            "流程：500 → TCP 250 → 代理 100 → "
            "粗测 20/24 → 正式 2/3",
            message,
        )
        self.assertIn(
            "失败：TCP 250，代理 20，粗测 4，正式 1",
            message,
        )
        self.assertIn(
            "名额未入选：TCP 后 130，代理后 76，粗测后 17；"
            "高速组外 0（非失败）",
            message,
        )
        self.assertIn(
            "正式池 40（新入 4，变化 +2），各阶段失败 275，耗时 2分05秒",
            message,
        )

    def test_unchanged_notification_contains_current_candidate_and_reason(self):
        reason = "候选只连续胜出 1/2 轮，暂不切换"
        title, message = selector.build_scan_notification(
            {
                "current_ip_before": "3.3.3.3",
                "switched": False,
                "current_metrics": {
                    "ip": "3.3.3.3",
                    "speed_Mbps": 9.0,
                    "delay_ms": 120,
                },
                "best": {
                    "ip": "4.4.4.4",
                    "speed_Mbps": 9.8,
                    "delay_ms": 98,
                },
                "reason": reason,
            },
            quick=False,
        )

        self.assertIn("深度扫描", title)
        self.assertIn("未切换 IP", title)
        self.assertIn("当前：3.3.3.3 | 9.00 Mbps / 120 ms", message)
        self.assertIn("最佳候选：4.4.4.4 | 9.80 Mbps / 98 ms", message)
        self.assertIn(f"原因：{reason}", message)

    def test_log_writes_file_when_stdout_is_none(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            log_dir = Path(temp_dir)
            run_log = log_dir / "dynamic_selector.log"
            with mock.patch.object(selector, "LOG_DIR", log_dir):
                with mock.patch.object(selector, "RUN_LOG", run_log):
                    with mock.patch.object(selector.sys, "stdout", None):
                        selector.log("后台任务日志")

            self.assertIn("后台任务日志", run_log.read_text(encoding="utf-8"))

    @mock.patch.object(selector.subprocess, "run")
    @mock.patch.object(selector.shutil, "which", return_value="powershell.exe")
    def test_windows_notification_runs_hidden_powershell(self, _which, run):
        run.return_value = mock.Mock(returncode=0, stderr="")
        with tempfile.TemporaryDirectory() as temp_dir:
            notify_script = Path(temp_dir) / "show_notification.ps1"
            notify_script.write_text("# test", encoding="utf-8")
            with mock.patch.object(selector, "NOTIFY_SCRIPT_PATH", notify_script):
                with mock.patch.object(selector.os, "name", "nt"):
                    result = selector.send_windows_notification(
                        "扫描完成", "当前节点保持不变"
                    )

        self.assertTrue(result)
        command = run.call_args.args[0]
        retention_index = command.index("-RetentionDays")
        self.assertEqual(
            command[retention_index + 1],
            str(selector.NOTIFICATION_REPORT_RETENTION_DAYS),
        )
        expected_limits = {
            "-MaxReportFiles": selector.NOTIFICATION_REPORT_MAX_FILES,
            "-DeliveryLogMaxBytes": selector.NOTIFICATION_DELIVERY_LOG_MAX_BYTES,
            "-DeliveryLogBackups": selector.NOTIFICATION_DELIVERY_LOG_BACKUPS,
        }
        for flag, expected in expected_limits.items():
            self.assertEqual(command[command.index(flag) + 1], str(expected))
        options = run.call_args.kwargs
        self.assertEqual(command[0], "powershell.exe")
        self.assertIn("-File", command)
        file_index = command.index("-File")
        self.assertEqual(command[file_index + 1], str(notify_script))
        self.assertEqual(
            options["creationflags"],
            getattr(selector.subprocess, "CREATE_NO_WINDOW", 0),
        )

    @mock.patch.object(selector.subprocess, "run")
    @mock.patch.object(selector.shutil, "which", return_value="powershell.exe")
    def test_windows_notification_passes_valid_report_path(self, _which, run):
        run.return_value = mock.Mock(returncode=0, stderr="")
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            report_dir = root / "notification_reports"
            report_dir.mkdir()
            report = report_dir / "notification_test.html"
            report.write_text("<!doctype html>", encoding="utf-8")
            notify_script = root / "notify_windows.ps1"
            notify_script.write_text("# test", encoding="utf-8")
            with mock.patch.object(selector, "NOTIFY_SCRIPT_PATH", notify_script):
                with mock.patch.object(
                    selector, "NOTIFICATION_REPORT_DIR", report_dir
                ):
                    with mock.patch.object(selector.os, "name", "nt"):
                        result = selector.send_windows_notification(
                            "扫描完成", "详情", report
                        )

        self.assertTrue(result)
        command = run.call_args.args[0]
        details_index = command.index("-DetailsPath")
        self.assertEqual(command[details_index + 1], str(report.resolve()))

    @mock.patch.object(selector, "log")
    @mock.patch.object(selector.subprocess, "run")
    @mock.patch.object(selector.shutil, "which", return_value="powershell.exe")
    def test_windows_notification_rejects_report_outside_directory(
        self, _which, run, log
    ):
        run.return_value = mock.Mock(returncode=0, stderr="")
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            report_dir = root / "notification_reports"
            report_dir.mkdir()
            outside = root / "outside.html"
            outside.write_text("<!doctype html>", encoding="utf-8")
            notify_script = root / "notify_windows.ps1"
            notify_script.write_text("# test", encoding="utf-8")
            with mock.patch.object(selector, "NOTIFY_SCRIPT_PATH", notify_script):
                with mock.patch.object(
                    selector, "NOTIFICATION_REPORT_DIR", report_dir
                ):
                    with mock.patch.object(selector.os, "name", "nt"):
                        result = selector.send_windows_notification(
                            "扫描完成", "详情", outside
                        )

        self.assertTrue(result)
        self.assertNotIn("-DetailsPath", run.call_args.args[0])
        self.assertIn("通知详情路径无效", log.call_args.args[0])

    def test_notification_script_uses_safe_html_and_structured_xml(self):
        script = selector.NOTIFY_SCRIPT_PATH.read_text(encoding="utf-8-sig")
        self.assertIn("CreateTextNode($Title)", script)
        self.assertIn("CreateTextNode($Message)", script)
        self.assertIn("[Net.WebUtility]::HtmlEncode", script)
        self.assertIn("[IO.Path]::GetFullPath", script)
        self.assertIn("[double]$RetentionDays = 30", script)
        self.assertIn("[int]$MaxReportFiles = 100", script)
        self.assertIn("[Math]::Min(3650, [Math]::Max(1, $RetentionDays))", script)
        self.assertIn("Select-Object -First $DeleteCount", script)
        self.assertIn("function Rotate-TextLog", script)
        self.assertIn("-ProtectedPath $InitialProtectedPath", script)
        self.assertIn("AddDays(-$NormalizedRetentionDays)", script)
        self.assertNotIn("latest_notification.txt", script)
        self.assertIn('scenario="urgent"', script)
        self.assertIn("$Toast.SuppressPopup = $false", script)
        self.assertIn("notification_delivery.log", script)


class ProviderUpdateTests(unittest.TestCase):
    def test_provider_does_not_poll_after_request_consumes_budget(self):
        class FakeClock:
            def __init__(self):
                self.value = 40.0

            def __call__(self):
                return self.value

        clock = FakeClock()

        class ExhaustedProviderAPI:
            def update_provider(self, provider):
                clock.value += 8.0

            def get_proxy(self, group):
                raise AssertionError("deadline 后不应再发 GET")

        observer = mock.Mock()
        with tempfile.TemporaryDirectory() as temp_dir:
            provider = Path(temp_dir) / "provider.yaml"
            with self.assertRaisesRegex(
                selector.MihomoConfirmationTimeout, "确认时间已耗尽"
            ):
                selector.update_provider_safely(
                    ExhaustedProviderAPI(),
                    "provider",
                    "group",
                    provider,
                    {"type": "vmess"},
                    ["1.1.1.1"],
                    "CF-A",
                    settle_seconds=8.0,
                    clock=clock,
                    timeout_observer=observer,
                )

        self.assertEqual(clock.value, 48.0)
        observer.assert_called_once_with()

    def test_provider_update_and_confirmation_share_one_timeout_budget(self):
        class FakeClock:
            def __init__(self):
                self.value = 20.0

            def __call__(self):
                return self.value

            def advance(self, seconds):
                self.value += seconds

        clock = FakeClock()

        class SlowProviderAPI:
            def update_provider(self, provider):
                clock.advance(6.0)

            def get_proxy(self, group):
                return {"all": []}

        with tempfile.TemporaryDirectory() as temp_dir:
            provider = Path(temp_dir) / "provider.yaml"
            with self.assertRaisesRegex(RuntimeError, "更新验证失败"):
                selector.update_provider_safely(
                    SlowProviderAPI(),
                    "provider",
                    "group",
                    provider,
                    {"type": "vmess"},
                    ["1.1.1.1"],
                    "CF-A",
                    settle_seconds=8.0,
                    poll_interval_seconds=10.0,
                    clock=clock,
                    sleeper=clock.advance,
                )

        self.assertEqual(clock.value, 28.0)

    @mock.patch.object(selector.time, "sleep")
    def test_provider_update_polls_until_expected_nodes_load(self, sleep):
        class EventuallyLoadedAPI:
            def __init__(self):
                self.states = iter([
                    {"all": ["CF-A | 9.9.9.9"]},
                    {"all": ["CF-A | 1.1.1.1"]},
                ])

            def update_provider(self, provider):
                pass

            def get_proxy(self, group):
                return next(self.states)

        with tempfile.TemporaryDirectory() as temp_dir:
            provider = Path(temp_dir) / "provider.yaml"
            selector.update_provider_safely(
                EventuallyLoadedAPI(),
                "provider",
                "group",
                provider,
                {"type": "vmess"},
                ["1.1.1.1"],
                "CF-A",
                settle_seconds=1.0,
            )

            self.assertTrue(provider.with_suffix(".yaml.last-good").is_file())
        sleep.assert_called_once()

    @mock.patch.object(selector.time, "sleep")
    def test_failed_first_provider_update_removes_unverified_file(self, _sleep):
        class FailedProviderAPI:
            def update_provider(self, provider):
                pass

            def get_proxy(self, group):
                return {"all": []}

        with tempfile.TemporaryDirectory() as temp_dir:
            provider = Path(temp_dir) / "provider.yaml"

            with self.assertRaisesRegex(RuntimeError, "已尝试恢复上一版本"):
                selector.update_provider_safely(
                    FailedProviderAPI(),
                    "provider",
                    "group",
                    provider,
                    {"type": "vmess"},
                    ["1.1.1.1"],
                    "CF-A",
                    settle_seconds=0,
                )

            self.assertFalse(provider.exists())
            self.assertFalse(provider.with_suffix(".yaml.last-good").exists())

    @mock.patch.object(selector.time, "sleep")
    def test_failed_provider_validation_restores_previous_file(self, _sleep):
        class FakeProviderAPI:
            def __init__(self):
                self.update_calls = 0
                self.get_calls = 0

            def update_provider(self, provider):
                self.update_calls += 1

            def get_proxy(self, group):
                self.get_calls += 1
                if self.get_calls == 1:
                    return {"all": []}
                return {"all": ["CF-A | 8.8.8.8"]}

        with tempfile.TemporaryDirectory() as temp_dir:
            provider = Path(temp_dir) / "provider.yaml"
            original = b'{"proxies":[{"name":"old","server":"8.8.8.8"}]}'
            provider.write_bytes(original)
            api = FakeProviderAPI()

            with self.assertRaisesRegex(RuntimeError, "已尝试恢复上一版本"):
                selector.update_provider_safely(
                    api,
                    "provider",
                    "group",
                    provider,
                    {"type": "vmess"},
                    ["1.1.1.1"],
                    "CF-A",
                    settle_seconds=0,
                )

            self.assertEqual(provider.read_bytes(), original)
            self.assertEqual(api.update_calls, 2)
            self.assertTrue(
                provider.with_suffix(".yaml.last-good").is_file()
            )

    @mock.patch.object(selector.time, "sleep")
    def test_successful_provider_update_advances_last_good(self, _sleep):
        class LoadedProviderAPI:
            def update_provider(self, provider):
                pass

            def get_proxy(self, group):
                return {"all": ["CF-A | 1.1.1.1"]}

        with tempfile.TemporaryDirectory() as temp_dir:
            provider = Path(temp_dir) / "provider.yaml"
            provider.write_bytes(b'{"proxies":[]}')

            selector.update_provider_safely(
                LoadedProviderAPI(),
                "provider",
                "group",
                provider,
                {"type": "vmess"},
                ["1.1.1.1"],
                "CF-A",
                settle_seconds=0,
            )

            last_good = provider.with_suffix(".yaml.last-good")
            self.assertEqual(last_good.read_bytes(), provider.read_bytes())

    @mock.patch.object(selector.time, "sleep")
    def test_provider_validation_rejects_unexpected_old_nodes(self, _sleep):
        class StaleProviderAPI:
            def __init__(self):
                self.update_calls = 0
                self.get_calls = 0

            def update_provider(self, provider):
                self.update_calls += 1

            def get_proxy(self, group):
                self.get_calls += 1
                if self.get_calls == 1:
                    return {
                        "all": ["CF-A | 1.1.1.1", "CF-A | 2.2.2.2"]
                    }
                return {"all": ["CF-A | 3.3.3.3"]}

        with tempfile.TemporaryDirectory() as temp_dir:
            provider = Path(temp_dir) / "provider.yaml"
            original = (
                b'{"proxies":[{"name":"CF-A | 3.3.3.3",'
                b'"server":"3.3.3.3"}]}'
            )
            provider.write_bytes(original)
            api = StaleProviderAPI()

            with self.assertRaisesRegex(RuntimeError, "多出 1 个"):
                selector.update_provider_safely(
                    api,
                    "provider",
                    "group",
                    provider,
                    {"type": "vmess"},
                    ["1.1.1.1"],
                    "CF-A",
                    settle_seconds=0,
                )

            self.assertEqual(provider.read_bytes(), original)
            self.assertEqual(api.update_calls, 2)


if __name__ == "__main__":
    unittest.main()
