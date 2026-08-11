#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Native v2rayN/Xray backend for the Cloudflare preferred-IP selector.

The module deliberately keeps the running v2rayN proxy out of the scan data
path.  Candidates built from the user's own public-install template are
exposed on temporary loopback HTTP ports by the Xray binary bundled with
v2rayN.  Only validated nodes are written to v2rayN's SQLite database.

The running v2rayN desktop process is never terminated for node changes.  A
dedicated database row acts as the active slot: its profile payload is replaced
transactionally and v2rayN's own Reload command hot-reloads only the child core.
"""

from __future__ import annotations

import concurrent.futures
import contextlib
import copy
import datetime as dt
import hashlib
import ipaddress
import json
import os
import random
import shutil
import socket
import sqlite3
import statistics
import subprocess
import tempfile
import time
import urllib.parse
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterator

try:
    from . import dynamic_selector as selector
except ImportError:
    import dynamic_selector as selector


ROOT = Path(__file__).resolve().parent
RUNTIME_ROOT = (
    Path(os.environ.get("LOCALAPPDATA", str(ROOT)))
    / "ClashCloudflareDynamic"
    / "v2rayn"
)
ACTIVE_STATE_PATH = RUNTIME_ROOT / "active_pools.json"
BACKUP_DIR = RUNTIME_ROOT / "backups"
XRAY_LOG_PATH = RUNTIME_ROOT / "xray_scan.log"
NRPT_TUN_DNS_COMMENT = "CCD v2rayN TUN DNS workaround"
AUTO_MODE = "cf"
AUTO_MODES = (AUTO_MODE,)

# Explicit overrides around geoip/geosite fallbacks. Microsoft Store uses
# global Azure/CDN names which are not reliably present in geosite:cn, while
# Microsoft account/Office endpoints should remain proxied.
MICROSOFT_STORE_DOMAINS = (
    "domain:apps.microsoft.com",
    "domain:livetileedge.dsx.mp.microsoft.com",
    "domain:storeedgefd.dsx.mp.microsoft.com",
    "domain:displaycatalog.mp.microsoft.com",
    "domain:storecatalog.mp.microsoft.com",
    "domain:purchase.md.mp.microsoft.com",
    "domain:licensing.mp.microsoft.com",
    "domain:licensing.md.mp.microsoft.com",
    "domain:storecatalogrevocation.storequality.microsoft.com",
    "domain:manage.devcenter.microsoft.com",
    "domain:share.microsoft.com",
    "domain:sfdataservice.microsoft.com",
    "domain:storeedge.microsoft.com",
    "domain:winstore.net",
    "domain:dl.delivery.mp.microsoft.com",
    "domain:tlu.dl.delivery.mp.microsoft.com",
    "domain:prod.do.dsp.mp.microsoft.com",
    "domain:delivery.mp.microsoft.com",
    "domain:download.windowsupdate.com",
    "domain:windowsupdate.com",
    "domain:update.microsoft.com",
    "domain:emdl.ws.microsoft.com",
    "domain:definitionupdates.microsoft.com",
    "domain:tsfe.trafficshaping.dsp.mp.microsoft.com",
    "domain:api.cdp.microsoft.com",
    "domain:ctldl.windowsupdate.com",
    "domain:img-prod-cms-rt-microsoft-com.akamaized.net",
    "domain:img-s-msn-com.akamaized.net",
    "domain:wns.windows.com",
    "domain:tile-service.weather.microsoft.com",
    "domain:cdn.onenote.net",
    "domain:evoke-windowsservices-tas.msedge.net",
    "domain:assets1.xboxlive.com",
    "domain:assets2.xboxlive.com",
    "domain:assets3.xboxlive.com",
    "domain:assets4.xboxlive.com",
    "domain:dlassets-ssl.xboxlive.com",
    "domain:da.xboxservices.com",
    "domain:msftconnecttest.com",
    "domain:store.rg-adguard.net",
)
MICROSOFT_GLOBAL_DOMAINS = (
    "domain:login.live.com",
    "domain:login.microsoft.com",
    "domain:login.microsoftonline.com",
    "domain:account.microsoft.com",
    "domain:account.live.com",
    "domain:microsoftonline.com",
    "domain:office.com",
    "domain:office.net",
    "domain:sharepoint.com",
    "domain:onedrive.live.com",
    "domain:live.com",
    "domain:azure.com",
)
OVERSEAS_SERVICE_DOMAINS = (
    "geosite:openai",
    "geosite:google",
    "geosite:youtube",
    "geosite:twitter",
    "geosite:telegram",
    "geosite:github",
    "geosite:cloudflare@cn",
    "geosite:tiktok",
    "geosite:gfw",
    "geosite:greatfire",
)
WEBRTC_STUN_PORTS = "3478,5349,19302-19309"


def _speed_url(settings: dict[str, Any], purpose: str) -> str:
    """Return the v2rayN-specific URL for a benchmark stage.

    A small static object is used for health checks and broad rough probes,
    while formal three-run measurements use the larger object.  Keeping these
    URLs separate avoids both public benchmark rate limits and accidentally
    downloading the formal payload for every rough candidate.
    """
    keys = {
        "probe": ("v2rayn_speed_probe_url", "speed_test_base_url"),
        "formal": ("v2rayn_speed_test_url", "speed_test_base_url"),
        "health": (
            "v2rayn_health_check_url",
            "v2rayn_speed_probe_url",
            "speed_test_base_url",
        ),
    }
    if purpose not in keys:
        raise ValueError(f"未知测速用途：{purpose}")
    for key in keys[purpose]:
        value = str(settings.get(key, "")).strip()
        if value:
            return value
    raise RuntimeError(f"v2rayN {purpose} 测速 URL 未配置")


@dataclass(frozen=True)
class PoolSpec:
    key: str
    label: str
    active_prefix: str
    discovery_prefix: str
    template: dict[str, Any]


@dataclass(frozen=True)
class CandidateProxy:
    key: str
    pool: str
    ip: str
    name: str
    port: int
    template: dict[str, Any]


def _load_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        return copy.deepcopy(default)


def _save_json_atomic(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        temporary.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def _stable_id(namespace: str, value: str) -> str:
    digest = hashlib.sha256(f"{namespace}\0{value}".encode("utf-8")).digest()
    # v2rayN stores Snowflake IDs as strings backed by signed Int64 values.
    return str((int.from_bytes(digest[:8], "big") & ((1 << 62) - 1)) + (1 << 61))


def _auto_group_specs() -> dict[str, dict[str, Any]]:
    """Return the generic public AUTO subscription group."""

    return {
        AUTO_MODE: {
            "id": _stable_id("v2rayn-pool", "auto-cf"),
            "remarks": "AUTO-CF｜Cloudflare 自动优选",
            "memo": "只使用安装时由用户提供的节点模板自动优选 Cloudflare 入口",
        },
    }


def _auto_slot_remarks(mode: str, target_remarks: str) -> str:
    if mode != AUTO_MODE:
        raise RuntimeError(f"未知自动模式：{mode}")
    return f"AUTO-CF｜当前：{target_remarks}"


def _full_routing_rules() -> list[dict[str, Any]]:
    """Return the complete Clash-equivalent route used by Xray and TUN.

    v2rayN has one active proxy outbound instead of Clash's per-service selector
    groups. Explicit overseas rules precede China fallbacks to protect against
    geolocation mistakes, and DNS rules precede the final catch-all so they
    cannot be shadowed.
    """

    definitions: list[tuple[str, dict[str, Any]]] = [
        (
            "block-quic",
            {
                "Port": "443",
                "Network": "udp",
                "OutboundTag": "block",
                "Remarks": "01 | BLOCK | QUIC UDP 443 (force proxied TCP)",
            },
        ),
        (
            "block-ads",
            {
                "OutboundTag": "block",
                "Domain": ["geosite:category-ads-all"],
                "Remarks": "02 | BLOCK | Ads and tracking domains",
            },
        ),
        (
            "private-ip",
            {
                "OutboundTag": "direct",
                "Ip": ["geoip:private"],
                "Remarks": "03 | DIRECT | LAN and private IP ranges",
            },
        ),
        (
            "private-domain",
            {
                "OutboundTag": "direct",
                "Domain": ["geosite:private"],
                "Remarks": "04 | DIRECT | LAN and private domains",
            },
        ),
        (
            "webrtc-stun-proxy",
            {
                "Port": WEBRTC_STUN_PORTS,
                "Network": "udp",
                "OutboundTag": "proxy",
                "Remarks": "05 | PROXY | WebRTC/STUN UDP anti-leak",
            },
        ),
        (
            "bittorrent",
            {
                "OutboundTag": "direct",
                "Protocol": ["bittorrent"],
                "Remarks": "06 | DIRECT | BitTorrent",
            },
        ),
        (
            "china-dns-ip",
            {
                "OutboundTag": "direct",
                "Ip": [
                    "119.29.29.29",
                    "223.5.5.5",
                    "223.6.6.6",
                    "1.12.12.12",
                    "120.53.53.53",
                ],
                "Remarks": "07 | DIRECT | Mainland DNS server IPs",
            },
        ),
        (
            "china-dns-domain",
            {
                "OutboundTag": "direct",
                "Domain": [
                    "domain:dns.alidns.com",
                    "domain:alidns.com",
                    "domain:doh.pub",
                    "domain:dot.pub",
                ],
                "Remarks": "08 | DIRECT | Mainland DNS domains",
            },
        ),
        (
            "microsoft-store-direct",
            {
                "OutboundTag": "direct",
                "Domain": list(MICROSOFT_STORE_DOMAINS),
                "Remarks": "09 | DIRECT | Microsoft Store, CDN and Windows Update",
            },
        ),
        (
            "microsoft-global-proxy",
            {
                "OutboundTag": "proxy",
                "Domain": list(MICROSOFT_GLOBAL_DOMAINS),
                "Remarks": "10 | PROXY | Microsoft login, Office and global cloud",
            },
        ),
        (
            "overseas-services",
            {
                "OutboundTag": "proxy",
                "Domain": list(OVERSEAS_SERVICE_DOMAINS),
                "Remarks": "11 | PROXY | AI, Google, social, GitHub and restricted sites",
            },
        ),
        (
            "game-compat-domain",
            {
                "OutboundTag": "direct",
                "Domain": [
                    "domain:xiaoheihe.cn",
                    "domain:max-c.com",
                    "domain:volcvideo.com",
                ],
                "Remarks": "12 | DIRECT | Mainland game helper/CDN compatibility",
            },
        ),
        (
            "china-ip",
            {
                "OutboundTag": "direct",
                "Ip": ["geoip:cn"],
                "Remarks": "13 | DIRECT | Mainland China IP ranges",
            },
        ),
        (
            "china-domain",
            {
                "OutboundTag": "direct",
                "Domain": ["geosite:cn"],
                "Remarks": "14 | DIRECT | Mainland China domains",
            },
        ),
        (
            "dns-direct-inbound",
            {
                "InboundTag": ["direct-dns-1", "direct-dns-2"],
                "OutboundTag": "direct",
                "Remarks": "15 | DIRECT | DNS selected for mainland resolver",
            },
        ),
        (
            "dns-proxy-inbound",
            {
                "InboundTag": ["dns-module"],
                "OutboundTag": "proxy",
                "Remarks": "16 | PROXY | DNS selected for remote DoH",
            },
        ),
        (
            "overseas-final",
            {
                "Port": "0-65535",
                "OutboundTag": "proxy",
                "Remarks": "17 | PROXY | Final overseas and unknown traffic",
            },
        ),
    ]
    result: list[dict[str, Any]] = []
    for key, definition in definitions:
        result.append(
            {
                "Id": _stable_id("v2rayn-routing-rule", key),
                **definition,
                "Enabled": True,
            }
        )
    return result


def _ensure_full_routing(settings: dict[str, Any]) -> dict[str, Any]:
    """Persist the full split route in v2rayN without reloading the live core."""

    paths = _v2rayn_paths(settings)
    route_id = _stable_id("v2rayn-routing", "ccd-full-split")
    rules = _full_routing_rules()
    serialized = json.dumps(rules, ensure_ascii=False, separators=(",", ":"))
    with sqlite3.connect(paths["db"], timeout=30) as connection:
        connection.execute("PRAGMA busy_timeout=30000")
        existing = connection.execute(
            "SELECT Remarks,RuleSet,RuleNum,Enabled,IsActive "
            "FROM RoutingItem WHERE Id=?",
            (route_id,),
        ).fetchone()
        other_active = connection.execute(
            "SELECT COUNT(*) FROM RoutingItem WHERE Id<>? AND IsActive=1",
            (route_id,),
        ).fetchone()[0]
        expected = (
            "CCD Full Split | CN DIRECT | Overseas PROXY | Store DIRECT | DNS/WebRTC Safe",
            serialized,
            len(rules),
            1,
            1,
        )
        if existing == expected and not other_active:
            return {"id": route_id, "changed": False, "backup": ""}

        stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        backup_path = BACKUP_DIR / f"guiNDB-before-full-routing-{stamp}.db"
        _database_backup(connection, backup_path)
        max_sort = connection.execute(
            "SELECT COALESCE(MAX(Sort),0) FROM RoutingItem"
        ).fetchone()[0]
        with connection:
            connection.execute("UPDATE RoutingItem SET IsActive=0")
            connection.execute(
                """
                INSERT INTO RoutingItem
                (Id,Remarks,Url,RuleSet,RuleNum,Enabled,Locked,CustomIcon,
                 CustomRulesetPath4Singbox,DomainStrategy,
                 DomainStrategy4Singbox,Sort,IsActive)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(Id) DO UPDATE SET
                    Remarks=excluded.Remarks,RuleSet=excluded.RuleSet,
                    RuleNum=excluded.RuleNum,Enabled=1,Locked=0,
                    DomainStrategy=excluded.DomainStrategy,
                    DomainStrategy4Singbox=excluded.DomainStrategy4Singbox,
                    IsActive=1
                """,
                (
                    route_id,
                    expected[0],
                    "",
                    serialized,
                    len(rules),
                    1,
                    0,
                    None,
                    None,
                    "AsIs",
                    "",
                    int(max_sort) + 1,
                    1,
                ),
            )
    return {"id": route_id, "changed": True, "backup": str(backup_path)}


def _generated_full_routing_is_active(settings: dict[str, Any]) -> bool:
    config_path = _v2rayn_paths(settings)["root"] / "binConfigs" / "config.json"
    config = _load_json(config_path, {})
    if not isinstance(config, dict):
        return False
    routing = config.get("routing")
    rules = routing.get("rules") if isinstance(routing, dict) else None
    if isinstance(rules, list):
        has_ads = any(
            isinstance(rule, dict)
            and rule.get("outboundTag") == "block"
            and "geosite:category-ads-all" in (rule.get("domain") or [])
            for rule in rules
        )
        has_final_proxy = any(
            isinstance(rule, dict)
            and rule.get("outboundTag") == "proxy"
            and str(rule.get("port") or "") == "0-65535"
            for rule in rules
        )
        has_store_direct = any(
            isinstance(rule, dict)
            and rule.get("outboundTag") == "direct"
            and "domain:apps.microsoft.com" in (rule.get("domain") or [])
            for rule in rules
        )
        has_webrtc_protection = any(
            isinstance(rule, dict)
            and rule.get("outboundTag") == "proxy"
            and str(rule.get("port") or "") == WEBRTC_STUN_PORTS
            and str(rule.get("network") or "") == "udp"
            for rule in rules
        )
        return has_ads and has_store_direct and has_webrtc_protection and has_final_proxy

    route = config.get("route")
    rules = route.get("rules") if isinstance(route, dict) else None
    if not isinstance(rules, list):
        return False
    has_ads = any(
        isinstance(rule, dict)
        and rule.get("action") == "reject"
        and "geosite-category-ads-all" in (rule.get("rule_set") or [])
        for rule in rules
    )
    has_store_direct = any(
        isinstance(rule, dict)
        and rule.get("outbound") == "direct"
        and "apps.microsoft.com" in (rule.get("domain_suffix") or [])
        for rule in rules
    )
    has_webrtc_protection = any(
        isinstance(rule, dict)
        and rule.get("outbound") == "proxy"
        and "udp" in (rule.get("network") or [])
        and "19302:19309" in (rule.get("port_range") or [])
        for rule in rules
    )
    has_final_proxy = any(
        isinstance(rule, dict)
        and rule.get("outbound") == "proxy"
        and "0:65535" in (rule.get("port_range") or [])
        for rule in rules
    )
    return has_ads and has_store_direct and has_webrtc_protection and has_final_proxy


def _v2rayn_root(settings: dict[str, Any]) -> Path:
    raw = str(settings.get("v2rayn_root", "%LOCALAPPDATA%/v2rayN")).strip()
    return Path(os.path.expandvars(raw)).resolve()


def _v2rayn_paths(settings: dict[str, Any]) -> dict[str, Path]:
    root = _v2rayn_root(settings)
    return {
        "root": root,
        "exe": root / "v2rayN.exe",
        "db": root / "guiConfigs" / "guiNDB.db",
        "config": root / "guiConfigs" / "guiNConfig.json",
        "xray": root / "bin" / "xray" / "xray.exe",
    }


def _required_core_names(
    settings: dict[str, Any], *, include_desktop: bool = False
) -> tuple[str, ...]:
    names = ["db", "config", "xray"]
    if include_desktop:
        names.insert(0, "exe")
    return tuple(names)


def _load_pools(settings: dict[str, Any]) -> list[PoolSpec]:
    """Load exactly the node template supplied by the installing user."""

    template = selector.load_template()
    protocol = str(template.get("type") or "vmess").strip().upper()
    return [
        PoolSpec(
            key=AUTO_MODE,
            label=f"Cloudflare {protocol}",
            active_prefix="CF-A",
            discovery_prefix="CF-D",
            template=template,
        )
    ]


def _load_active_state(settings: dict[str, Any]) -> dict[str, list[str]]:
    state = _load_json(ACTIVE_STATE_PATH, {})
    if not isinstance(state, dict):
        state = {}
    result: dict[str, list[str]] = {AUTO_MODE: []}
    values = state.get(AUTO_MODE, [])
    if isinstance(values, list):
        for raw in values:
            try:
                ip = str(ipaddress.IPv4Address(str(raw)))
            except ipaddress.AddressValueError:
                continue
            if ip not in result[AUTO_MODE]:
                result[AUTO_MODE].append(ip)
    if not result[AUTO_MODE]:
        result[AUTO_MODE] = selector.load_seed_ips()
    return result


def _save_active_state(active: dict[str, list[str]]) -> None:
    payload: dict[str, Any] = {
        key: list(dict.fromkeys(values)) for key, values in active.items()
    }
    payload["updated_at"] = selector.now_iso()
    _save_json_atomic(ACTIVE_STATE_PATH, payload)


def _generate_candidates(
    ranges: list[ipaddress.IPv4Network],
    settings: dict[str, Any],
    active: dict[str, list[str]],
    rng: random.Random,
) -> tuple[list[str], set[str], int, int, int]:
    fixed: set[str] = set(selector.load_seed_ips())
    for values in active.values():
        fixed.update(values)
    fixed.update(
        selector.load_historical_ips(int(settings.get("historical_ips_to_retest", 100)))
    )
    fixed = {ip for ip in fixed if selector.in_ranges(ip, ranges)}
    candidates = set(fixed)
    for ip in list(fixed):
        network = ipaddress.ip_network(f"{ip}/24", strict=False)
        for _ in range(int(settings.get("neighbor_samples_per_active", 2))):
            candidate = selector.random_ip(network, rng)
            if selector.in_ranges(candidate, ranges):
                candidates.add(candidate)
    neighbor_count = len(candidates.difference(fixed))

    target = max(1, int(settings.get("random_samples_per_run", 160)))
    recent = selector.load_recently_sampled_ips(
        float(settings.get("new_ip_retest_days", 30))
    )
    fresh = reused = attempts = 0
    while fresh < target and attempts < max(100, target * 50):
        candidate = selector.random_ip(selector.choose_network(ranges, rng), rng)
        attempts += 1
        if candidate in recent or candidate in candidates:
            continue
        candidates.add(candidate)
        fresh += 1
    attempts = 0
    while fresh + reused < target and attempts < max(100, target * 20):
        candidate = selector.random_ip(selector.choose_network(ranges, rng), rng)
        attempts += 1
        if candidate in candidates:
            continue
        candidates.add(candidate)
        reused += 1
    return (
        sorted(candidates, key=lambda value: int(ipaddress.IPv4Address(value))),
        fixed,
        neighbor_count,
        fresh,
        reused,
    )


def _xray_outbound(template: dict[str, Any], ip: str, tag: str) -> dict[str, Any]:
    protocol = str(template.get("type") or "vmess").lower()
    if protocol == "vless":
        xhttp = template.get("xhttp-opts") or {}
        host = str(xhttp.get("host") or template.get("servername") or "").strip()
        path = str(xhttp.get("path") or "/")
        mode = str(xhttp.get("mode") or "auto").strip()
        sni = str(template.get("servername") or host).strip()
        fingerprint = str(template.get("client-fingerprint") or "chrome").strip()
        tls: dict[str, Any] = {
            "serverName": sni,
            "allowInsecure": bool(template.get("skip-cert-verify", False)),
            "fingerprint": fingerprint,
        }
        alpn = template.get("alpn")
        if isinstance(alpn, list) and alpn:
            tls["alpn"] = [str(item) for item in alpn]
        return {
            "tag": tag,
            "protocol": "vless",
            "settings": {
                "vnext": [
                    {
                        "address": ip,
                        "port": int(template.get("port", 2087)),
                        "users": [
                            {
                                "id": str(template["uuid"]),
                                "encryption": str(template.get("encryption") or "none"),
                            }
                        ],
                    }
                ]
            },
            "streamSettings": {
                "network": "xhttp",
                "security": "tls",
                "tlsSettings": tls,
                "xhttpSettings": {"path": path, "host": host, "mode": mode},
            },
        }
    if protocol != "vmess":
        raise RuntimeError(f"不支持的 Xray 优选协议：{protocol}")
    ws = template.get("ws-opts") or {}
    headers = ws.get("headers") or {}
    host = str(headers.get("Host") or template.get("servername") or "").strip()
    path = str(ws.get("path") or "/")
    sni = str(template.get("servername") or host).strip()
    fingerprint = str(template.get("client-fingerprint") or "chrome").strip()
    user_security = str(template.get("cipher") or "auto").strip()
    return {
        "tag": tag,
        "protocol": "vmess",
        "settings": {
            "vnext": [
                {
                    "address": ip,
                    "port": int(template.get("port", 443)),
                    "users": [
                        {
                            "id": str(template["uuid"]),
                            "alterId": int(template.get("alterId", 0)),
                            "security": user_security,
                        }
                    ],
                }
            ]
        },
        "streamSettings": {
            "network": "ws",
            "security": "tls",
            "tlsSettings": {
                "serverName": sni,
                "allowInsecure": False,
                "fingerprint": fingerprint,
            },
            "wsSettings": {"path": path, "headers": {"Host": host}},
        },
    }


def _candidate_key(pool: str, ip: str) -> str:
    return f"{pool}:{ip}"


class XrayBatch:
    def __init__(
        self,
        xray: Path,
        pools: list[PoolSpec],
        ips: list[str],
        base_port: int,
    ) -> None:
        self.xray = xray
        self.pools = pools
        self.ips = ips
        self.base_port = base_port
        self.process: subprocess.Popen[str] | None = None
        self.temp_dir: tempfile.TemporaryDirectory[str] | None = None
        self.log_handle: Any | None = None
        self.proxies: dict[str, CandidateProxy] = {}

    def __enter__(self) -> "XrayBatch":
        self.temp_dir = tempfile.TemporaryDirectory(prefix="ccd-xray-", dir=RUNTIME_ROOT)
        root = Path(self.temp_dir.name)
        inbounds: list[dict[str, Any]] = []
        outbounds: list[dict[str, Any]] = []
        rules: list[dict[str, Any]] = []
        index = 0
        for pool in self.pools:
            for ip in self.ips:
                port = self.base_port + index
                if port >= 65535:
                    raise RuntimeError("Xray 临时测试端口超出范围")
                inbound_tag = f"in-{index}"
                outbound_tag = f"out-{index}"
                key = _candidate_key(pool.key, ip)
                name = f"{pool.discovery_prefix} | {ip}"
                self.proxies[key] = CandidateProxy(
                    key=key,
                    pool=pool.key,
                    ip=ip,
                    name=name,
                    port=port,
                    template=pool.template,
                )
                inbounds.append(
                    {
                        "listen": "127.0.0.1",
                        "port": port,
                        "protocol": "http",
                        "tag": inbound_tag,
                        "settings": {"allowTransparent": False},
                    }
                )
                outbounds.append(_xray_outbound(pool.template, ip, outbound_tag))
                rules.append(
                    {
                        "type": "field",
                        "inboundTag": [inbound_tag],
                        "outboundTag": outbound_tag,
                    }
                )
                index += 1
        payload = {
            "log": {"loglevel": "warning"},
            "inbounds": inbounds,
            "outbounds": outbounds,
            "routing": {"domainStrategy": "AsIs", "rules": rules},
        }
        config_path = root / "config.json"
        _save_json_atomic(config_path, payload)
        test = subprocess.run(
            [str(self.xray), "run", "-test", "-c", str(config_path)],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=30,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            check=False,
        )
        if test.returncode != 0:
            raise RuntimeError(
                "Xray 候选配置校验失败：" + (test.stderr.strip() or test.stdout.strip())
            )
        self.log_handle = XRAY_LOG_PATH.open("a", encoding="utf-8")
        self.process = subprocess.Popen(
            [str(self.xray), "run", "-c", str(config_path)],
            cwd=str(root),
            stdout=self.log_handle,
            stderr=subprocess.STDOUT,
            text=True,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        deadline = time.monotonic() + 15
        sample_ports = [self.base_port, self.base_port + max(0, index - 1)]
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError("Xray 候选测试核心提前退出")
            if all(_port_open(port) for port in sample_ports):
                return self
            time.sleep(0.1)
        raise RuntimeError("Xray 候选测试端口未就绪")

    def __exit__(self, *_: Any) -> None:
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        if self.log_handle is not None:
            self.log_handle.close()
        if self.temp_dir is not None:
            self.temp_dir.cleanup()


def _port_open(port: int) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.25):
            return True
    except OSError:
        return False


def _curl_delay(
    curl_bin: str,
    proxy_url: str,
    url: str,
    timeout_ms: int,
) -> float | None:
    timeout_seconds = max(1.0, timeout_ms / 1000)
    proc = subprocess.run(
        [
            curl_bin,
            "--silent",
            "--show-error",
            "--output",
            os.devnull,
            "--proxy",
            proxy_url,
            "--noproxy",
            "",
            "--connect-timeout",
            str(min(5.0, timeout_seconds)),
            "--max-time",
            str(timeout_seconds),
            "--write-out",
            "%{http_code} %{time_total}",
            url,
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=timeout_seconds + 3,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        check=False,
    )
    if proc.returncode != 0:
        return None
    try:
        code_text, seconds_text = proc.stdout.strip().split()[-2:]
        if not 200 <= int(code_text) < 400:
            return None
        return round(float(seconds_text) * 1000, 2)
    except (ValueError, IndexError):
        return None


def _measure_delays(
    proxies: dict[str, CandidateProxy],
    settings: dict[str, Any],
    curl_bin: str,
) -> tuple[dict[str, float], dict[str, list[float]], dict[str, float]]:
    repeats = max(1, int(settings.get("delay_repeats", 3)))
    require_all = bool(settings.get("require_all_repeats", True))
    timeout_ms = int(settings.get("delay_timeout_ms", 7000))
    url = str(settings.get("delay_test_url", "https://www.gstatic.com/generate_204"))
    workers = min(64, max(1, int(settings.get("v2rayn_delay_workers", 48))))
    samples: dict[str, list[float]] = {key: [] for key in proxies}
    failed: set[str] = set()
    for round_index in range(1, repeats + 1):
        keys = [key for key in proxies if not (require_all and key in failed)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
            futures = {
                pool.submit(
                    _curl_delay,
                    curl_bin,
                    f"http://127.0.0.1:{proxies[key].port}",
                    url,
                    timeout_ms,
                ): key
                for key in keys
            }
            done = 0
            for future in concurrent.futures.as_completed(futures):
                key = futures[future]
                value = future.result()
                if value is None:
                    failed.add(key)
                else:
                    samples[key].append(value)
                done += 1
                if done % 50 == 0 or done == len(futures):
                    selector.log(
                        f"Xray 真实协议冷启动响应第 {round_index}/{repeats} 轮："
                        f"{done}/{len(futures)}"
                    )
        if round_index < repeats:
            time.sleep(max(0.0, float(settings.get("delay_repeat_interval_seconds", 0.5))))
    valid = {
        key: round(statistics.fmean(values), 2)
        for key, values in samples.items()
        if len(values) >= (repeats if require_all else max(1, repeats - 1))
    }
    stddev = {
        key: round(statistics.pstdev(samples[key]), 2)
        if len(samples[key]) > 1
        else 0.0
        for key in valid
    }
    retry_enabled = bool(settings.get("v2rayn_delay_retry_on_empty", True))
    retry_ratio = max(
        0.0,
        min(1.0, float(settings.get("v2rayn_delay_retry_min_valid_ratio", 0.05))),
    )
    if (
        retry_enabled
        and len(valid) < max(1, int(len(proxies) * retry_ratio))
        and len(proxies) > 1
    ):
        retry_settings = copy.deepcopy(settings)
        retry_settings["v2rayn_delay_retry_on_empty"] = False
        retry_settings["v2rayn_delay_workers"] = min(
            max(1, int(settings.get("v2rayn_delay_retry_workers", 8))),
            max(1, int(settings.get("v2rayn_delay_workers", 48))),
        )
        backoff = max(
            0.0,
            min(30.0, float(settings.get("v2rayn_delay_retry_backoff_seconds", 2.0))),
        )
        selector.log(
            "Xray 冷启动响应有效数过低，疑似瞬时 TLS/并发波动；"
            f"首次 {len(valid)}/{len(proxies)}，等待 {backoff:g} 秒后以 "
            f"{retry_settings['v2rayn_delay_workers']} 并发重试"
        )
        if backoff:
            time.sleep(backoff)
        return _measure_delays(proxies, retry_settings, curl_bin)
    return valid, {key: samples[key] for key in valid}, stddev


def _select_probe_keys(
    delays: dict[str, float],
    limit: int,
    rng: random.Random,
    proxies: dict[str, CandidateProxy] | None = None,
) -> list[str]:
    ordered = sorted(delays, key=lambda key: delays[key])
    limit = min(len(ordered), max(1, int(limit)))
    result: list[str] = []
    if proxies:
        for pool_key in dict.fromkeys(proxy.pool for proxy in proxies.values()):
            best = next(
                (
                    key
                    for key in ordered
                    if key in proxies and proxies[key].pool == pool_key
                ),
                None,
            )
            if best is not None and best not in result and len(result) < limit:
                result.append(best)
    low_count = max(1, int(limit * 0.75))
    for key in ordered:
        if len(result) >= low_count:
            break
        if key not in result:
            result.append(key)
    remainder = [key for key in ordered if key not in result]
    rng.shuffle(remainder)
    result.extend(remainder[: limit - len(result)])
    return result


def _windows_physical_default_interface_index() -> int | None:
    """Return the active non-TUN IPv4 default-route interface on Windows."""

    if os.name != "nt":
        return None
    script = r"""
$ErrorActionPreference='Stop'
$physical=Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' |
  Where-Object {$_.State -eq 'Alive' -and $_.NextHop -ne '0.0.0.0' -and $_.InterfaceAlias -notmatch '(?i)tun'} |
  Sort-Object RouteMetric | Select-Object -First 1
if(-not $physical){ throw '未找到 TUN 之外的物理默认路由' }
[Console]::OutputEncoding=[Text.UTF8Encoding]::new()
$physical.InterfaceIndex
"""
    probe = _run_powershell(script)
    if probe.returncode != 0:
        detail = probe.stderr.strip() or probe.stdout.strip()
        raise RuntimeError(f"TCP 初筛物理接口探测失败：{detail}")
    try:
        interface_index = int(probe.stdout.strip())
    except ValueError as exc:
        raise RuntimeError(
            f"TCP 初筛物理接口解析失败：{probe.stdout.strip()}"
        ) from exc
    if interface_index <= 0:
        raise RuntimeError(f"TCP 初筛物理接口无效：{interface_index}")
    return interface_index


def _database_backup(connection: sqlite3.Connection, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(target) as backup:
        connection.backup(backup)


def _profile_row(pool: PoolSpec, ip: str) -> dict[str, Any]:
    template = pool.template
    protocol = str(template.get("type") or "vmess").lower()
    if protocol == "vless":
        transport = template.get("xhttp-opts") or {}
        host = str(transport.get("host") or template.get("servername") or "")
        path = str(transport.get("path") or "/")
        transport_extra = {
            "Host": host,
            "Path": path,
            "XhttpMode": str(transport.get("mode") or "auto"),
        }
        proto_extra = {
            "Flow": str(template.get("flow") or "") or None,
            "VlessEncryption": str(template.get("encryption") or "none"),
        }
        config_type = 5
        network = "xhttp"
        alpn_value = template.get("alpn")
        alpn = ",".join(str(item) for item in alpn_value) if isinstance(alpn_value, list) else str(alpn_value or "")
    elif protocol == "vmess":
        transport = template.get("ws-opts") or {}
        headers = transport.get("headers") or {}
        host = str(headers.get("Host") or template.get("servername") or "")
        path = str(transport.get("path") or "/")
        transport_extra = {"RawHeaderType": "none", "Host": host, "Path": path}
        proto_extra = {
            "AlterId": str(template.get("alterId", 0)),
            "VmessSecurity": str(template.get("cipher") or "auto"),
        }
        config_type = 1
        network = "ws"
        alpn = ""
    else:
        raise RuntimeError(f"不支持写入 v2rayN 的协议：{protocol}")
    sni = str(template.get("servername") or host)
    return {
        "IndexId": _stable_id(f"v2rayn-{pool.key}", ip),
        "ConfigType": config_type,
        "CoreType": 2,
        "ConfigVersion": 4,
        "Subid": _stable_id("v2rayn-pool", pool.key),
        "IsSub": 1,
        "PreSocksPort": None,
        "DisplayLog": 1,
        "Remarks": f"{pool.active_prefix} | {ip}",
        "Address": ip,
        "Port": int(template.get("port", 443)),
        "Password": str(template["uuid"]),
        "Username": "",
        "Network": network,
        "HeaderType": "",
        "RequestHost": "",
        "Path": "",
        "StreamSecurity": "tls",
        "AllowInsecure": "",
        "Sni": sni,
        "Alpn": alpn,
        "Fingerprint": str(template.get("client-fingerprint") or "chrome"),
        "PublicKey": "",
        "ShortId": "",
        "SpiderX": "",
        "Mldsa65Verify": "",
        "Extra": "",
        "MuxEnabled": None,
        "Cert": "",
        "CertSha": "",
        "EchConfigList": "",
        "VerifyPeerCertByName": "",
        "Finalmask": "",
        "ProtoExtra": json.dumps(proto_extra, separators=(",", ":")),
        "TransportExtra": json.dumps(transport_extra, separators=(",", ":")),
        "Ports": "",
        "AlterId": 0,
        "Flow": "",
        "Id": "",
        "Security": "",
    }


def _upsert_v2rayn_profiles(
    settings: dict[str, Any],
    pools: list[PoolSpec],
    active: dict[str, list[str]],
    metrics: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    paths = _v2rayn_paths(settings)
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup_path = BACKUP_DIR / f"guiNDB-{stamp}.db"
    inserted = updated = deleted = 0
    with sqlite3.connect(paths["db"], timeout=30) as connection:
        connection.execute("PRAGMA busy_timeout=30000")
        integrity = connection.execute("PRAGMA quick_check").fetchone()
        if not integrity or integrity[0] != "ok":
            raise RuntimeError("v2rayN 数据库 quick_check 失败")
        _database_backup(connection, backup_path)
        current_config = _load_json(paths["config"], {})
        current_id = str(current_config.get("IndexId", "")) if isinstance(current_config, dict) else ""
        columns = [row[1] for row in connection.execute("PRAGMA table_info(ProfileItem)")]
        with connection:
            max_sort = connection.execute("SELECT COALESCE(MAX(Sort),0) FROM SubItem").fetchone()[0]
            for offset, pool in enumerate(pools, 1):
                sub_id = _stable_id("v2rayn-pool", pool.key)
                connection.execute(
                    """
                    INSERT INTO SubItem
                    (Id,Remarks,Url,MoreUrl,Enabled,UserAgent,Sort,Filter,
                     AutoUpdateInterval,UpdateTime,ConvertTarget,PrevProfile,
                     NextProfile,PreSocksPort,Memo,CustomCoreType)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(Id) DO UPDATE SET Remarks=excluded.Remarks,
                        Enabled=1, CustomCoreType=2
                    """,
                    (
                        sub_id,
                        f"CCD {pool.label} (Xray)",
                        "",
                        "",
                        1,
                        "",
                        int(max_sort) + offset,
                        "",
                        0,
                        "",
                        "",
                        "",
                        "",
                        None,
                        "由 Cloudflare 优选脚本维护；凭据不进入公开仓库",
                        2,
                    ),
                )
                keep_ids: set[str] = set()
                for ip in active.get(pool.key, []):
                    row = _profile_row(pool, ip)
                    keep_ids.add(row["IndexId"])
                    exists = connection.execute(
                        "SELECT 1 FROM ProfileItem WHERE IndexId=?", (row["IndexId"],)
                    ).fetchone()
                    values = [row.get(column) for column in columns]
                    placeholders = ",".join("?" for _ in columns)
                    updates = ",".join(
                        f'"{column}"=excluded."{column}"'
                        for column in columns
                        if column != "IndexId"
                    )
                    connection.execute(
                        f'INSERT INTO ProfileItem ({",".join(columns)}) '
                        f"VALUES ({placeholders}) ON CONFLICT(IndexId) DO UPDATE SET {updates}",
                        values,
                    )
                    inserted += 0 if exists else 1
                    updated += 1 if exists else 0
                    metric = metrics.get(_candidate_key(pool.key, ip), {})
                    if metric:
                        connection.execute(
                            """
                            INSERT INTO ProfileExItem(IndexId,Delay,Speed,Sort,Message,IpInfo)
                            VALUES(?,?,?,?,?,?)
                            ON CONFLICT(IndexId) DO UPDATE SET
                              Delay=excluded.Delay,Speed=excluded.Speed,
                              Sort=excluded.Sort,Message=excluded.Message
                            """,
                            (
                                row["IndexId"],
                                int(round(float(metric.get("delay_ms", 0)))),
                                int(round(float(metric.get("speed_Mbps", 0)) * 1_000_000 / 8)),
                                0,
                                "三次平均；Xray 真实链路",
                                "",
                            ),
                        )
                existing = connection.execute(
                    "SELECT IndexId FROM ProfileItem WHERE Subid=?", (sub_id,)
                ).fetchall()
                for (index_id,) in existing:
                    if index_id in keep_ids or index_id == current_id:
                        continue
                    connection.execute("DELETE FROM ProfileExItem WHERE IndexId=?", (index_id,))
                    connection.execute("DELETE FROM ProfileItem WHERE IndexId=?", (index_id,))
                    deleted += 1
    return {
        "backup": str(backup_path),
        "inserted": inserted,
        "updated": updated,
        "deleted": deleted,
    }


def _read_system_proxy() -> dict[str, Any]:
    if os.name != "nt":
        return {"enabled": False, "server": ""}
    import winreg

    path = r"Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, path) as key:
        try:
            enabled = int(winreg.QueryValueEx(key, "ProxyEnable")[0])
        except OSError:
            enabled = 0
        try:
            server = str(winreg.QueryValueEx(key, "ProxyServer")[0])
        except OSError:
            server = ""
    return {"enabled": bool(enabled), "server": server}


def _configured_mixed_proxy(settings: dict[str, Any]) -> tuple[str, str]:
    """Return the loopback proxy URL and WinINET host:port value."""

    raw = str(settings.get("mixed_proxy", "http://127.0.0.1:10808")).strip()
    parsed = urllib.parse.urlsplit(raw)
    try:
        port = parsed.port
    except ValueError as exc:
        raise RuntimeError("mixed_proxy 端口无效") from exc
    if parsed.scheme not in {"http", "https"} or not parsed.hostname or not port:
        raise RuntimeError("mixed_proxy 必须是带端口的本地 HTTP(S) URL")
    try:
        address = ipaddress.ip_address(parsed.hostname)
    except ValueError as exc:
        if parsed.hostname.casefold() != "localhost":
            raise RuntimeError("mixed_proxy 必须使用本机回环地址") from exc
    else:
        if not address.is_loopback:
            raise RuntimeError("mixed_proxy 必须使用本机回环地址")
    return raw, f"{parsed.hostname}:{port}"


def _tun_enabled(settings: dict[str, Any]) -> bool:
    config = _load_json(_v2rayn_paths(settings)["config"], {})
    if not isinstance(config, dict):
        return False
    tun = config.get("TunModeItem")
    return bool(tun.get("EnableTun")) if isinstance(tun, dict) else False


def _configured_index_id(settings: dict[str, Any]) -> str:
    config = _load_json(_v2rayn_paths(settings)["config"], {})
    return str(config.get("IndexId", "")) if isinstance(config, dict) else ""


def _active_slot_ids(settings: dict[str, Any]) -> dict[str, str]:
    configured = str(settings.get("v2rayn_active_slot_id", "")).strip()
    return {
        AUTO_MODE: configured or _stable_id("v2rayn-active-slot", AUTO_MODE),
    }


def _active_slot_id(settings: dict[str, Any], mode: str) -> str:
    if mode not in AUTO_MODES:
        raise RuntimeError(f"未知自动模式：{mode}")
    return _active_slot_ids(settings)[mode]


def _slot_state_path(mode: str) -> Path:
    return RUNTIME_ROOT / f"active_slot_state_{mode}.json"


def _switch_state_path(mode: str) -> Path:
    return RUNTIME_ROOT / f"switch_state_{mode}.json"


def _selected_auto_mode(settings: dict[str, Any]) -> str | None:
    configured_id = _configured_index_id(settings)
    return next(
        (mode for mode, slot_id in _active_slot_ids(settings).items() if configured_id == slot_id),
        None,
    )


def _profile_dict(connection: sqlite3.Connection, index_id: str) -> dict[str, Any]:
    columns = [row[1] for row in connection.execute("PRAGMA table_info(ProfileItem)")]
    row = connection.execute(
        f'SELECT {",".join(columns)} FROM ProfileItem WHERE IndexId=?',
        (index_id,),
    ).fetchone()
    if row is None:
        raise RuntimeError(f"v2rayN 节点不存在：{index_id}")
    return dict(zip(columns, row))


def _write_profile_dict(
    connection: sqlite3.Connection,
    profile: dict[str, Any],
) -> None:
    columns = [row[1] for row in connection.execute("PRAGMA table_info(ProfileItem)")]
    placeholders = ",".join("?" for _ in columns)
    updates = ",".join(
        f'"{column}"=excluded."{column}"'
        for column in columns
        if column != "IndexId"
    )
    connection.execute(
        f'INSERT INTO ProfileItem ({",".join(columns)}) VALUES ({placeholders}) '
        f"ON CONFLICT(IndexId) DO UPDATE SET {updates}",
        [profile.get(column) for column in columns],
    )


def _profile_allowed_for_mode(profile: dict[str, Any], mode: str) -> bool:
    if mode != AUTO_MODE:
        return False
    remarks = str(profile.get("Remarks") or "")
    return remarks.startswith("CF-A |")


def _same_profile_payload(left: dict[str, Any], right: dict[str, Any]) -> bool:
    fields = (
        "ConfigType",
        "CoreType",
        "Address",
        "Port",
        "Password",
        "Username",
        "Network",
        "StreamSecurity",
        "Sni",
        "Alpn",
        "Fingerprint",
        "PublicKey",
        "ShortId",
        "ProtoExtra",
        "TransportExtra",
    )
    return all(left.get(field) == right.get(field) for field in fields)


def _initial_target_profile(
    connection: sqlite3.Connection,
    settings: dict[str, Any],
    mode: str,
) -> dict[str, Any]:
    slot_ids = set(_active_slot_ids(settings).values())
    rows = connection.execute(
        "SELECT IndexId FROM ProfileItem ORDER BY rowid"
    ).fetchall()
    candidates: list[dict[str, Any]] = []
    for (index_id,) in rows:
        if str(index_id) in slot_ids:
            continue
        profile = _profile_dict(connection, str(index_id))
        if _profile_allowed_for_mode(profile, mode):
            candidates.append(profile)
    if not candidates:
        raise RuntimeError(f"没有可用于 AUTO-{mode.upper()} 的初始节点")
    candidates.sort(key=lambda row: str(row.get("Remarks") or ""))
    return candidates[0]


def _ensure_auto_slots(settings: dict[str, Any]) -> dict[str, str]:
    """Create the generic hot-reload slot without touching the live core."""

    paths = _v2rayn_paths(settings)
    slot_ids = _active_slot_ids(settings)
    group_specs = _auto_group_specs()
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(paths["db"], timeout=30) as connection:
        connection.execute("PRAGMA busy_timeout=30000")
        stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        _database_backup(connection, BACKUP_DIR / f"guiNDB-before-auto-slots-{stamp}.db")
        max_sort = connection.execute("SELECT COALESCE(MAX(Sort),0) FROM SubItem").fetchone()[0]
        with connection:
            for offset, mode in enumerate(AUTO_MODES, 1):
                spec = group_specs[mode]
                connection.execute(
                    """
                    INSERT INTO SubItem
                    (Id,Remarks,Url,MoreUrl,Enabled,UserAgent,Sort,Filter,
                     AutoUpdateInterval,UpdateTime,ConvertTarget,PrevProfile,
                     NextProfile,PreSocksPort,Memo,CustomCoreType)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(Id) DO UPDATE SET Remarks=excluded.Remarks,
                        Enabled=1,Memo=excluded.Memo,CustomCoreType=2
                    """,
                    (
                        spec["id"],
                        spec["remarks"],
                        "",
                        "",
                        1,
                        "",
                        int(max_sort) + offset,
                        "",
                        0,
                        "",
                        "",
                        "",
                        "",
                        None,
                        spec["memo"],
                        2,
                    ),
                )
            for mode, slot_id in slot_ids.items():
                state = _load_json(_slot_state_path(mode), {})
                old_slot: dict[str, Any] | None = None
                with contextlib.suppress(RuntimeError):
                    old_slot = _profile_dict(connection, slot_id)
                source: dict[str, Any] | None = None
                target_id = ""
                if isinstance(state, dict):
                    candidate_id = str(state.get("target_id", "")).strip()
                    if candidate_id and candidate_id not in slot_ids.values():
                        with contextlib.suppress(RuntimeError):
                            candidate = _profile_dict(connection, candidate_id)
                            if _profile_allowed_for_mode(candidate, mode):
                                source = candidate
                                target_id = candidate_id
                if source is None:
                    source = _initial_target_profile(connection, settings, mode)
                    target_id = str(source["IndexId"])
                replacement = dict(source)
                replacement["IndexId"] = slot_id
                replacement["Subid"] = group_specs[mode]["id"]
                replacement["IsSub"] = 1
                target_remarks = str(source.get("Remarks") or target_id)
                replacement["Remarks"] = _auto_slot_remarks(mode, target_remarks)
                _write_profile_dict(connection, replacement)
                selected_now = _configured_index_id(settings) == slot_id
                needs_reload = bool(
                    selected_now
                    and (
                        old_slot is None
                        or not _same_profile_payload(old_slot, replacement)
                        or (isinstance(state, dict) and state.get("needs_reload"))
                    )
                )
                _save_json_atomic(
                    _slot_state_path(mode),
                    {
                        "time": selector.now_iso(),
                        "slot_id": slot_id,
                        "target_id": target_id,
                        "target_remarks": target_remarks,
                        "needs_reload": needs_reload,
                    },
                )
    return slot_ids


def _replace_active_slot(
    settings: dict[str, Any],
    target_id: str,
    mode: str,
) -> tuple[dict[str, Any], str]:
    """Copy a target profile into the active slot and return its old contents."""

    paths = _v2rayn_paths(settings)
    slot_id = _active_slot_id(settings, mode)
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(paths["db"], timeout=30) as connection:
        connection.execute("PRAGMA busy_timeout=30000")
        old_slot = _profile_dict(connection, slot_id)
        target = _profile_dict(connection, target_id)
        if not _profile_allowed_for_mode(target, mode):
            raise RuntimeError(
                f"拒绝把 {target.get('Remarks') or target_id} 写入 AUTO-{mode.upper()}"
            )
        stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        _database_backup(connection, BACKUP_DIR / f"guiNDB-before-hot-switch-{stamp}.db")
        replacement = dict(target)
        replacement["IndexId"] = slot_id
        # Keep the slot in its original visible group so v2rayN never prunes it.
        replacement["Subid"] = old_slot.get("Subid")
        replacement["IsSub"] = old_slot.get("IsSub")
        target_remarks = str(target.get("Remarks") or target_id)
        replacement["Remarks"] = _auto_slot_remarks(mode, target_remarks)
        with connection:
            _write_profile_dict(connection, replacement)
    return old_slot, target_remarks


def _restore_active_slot(settings: dict[str, Any], profile: dict[str, Any]) -> None:
    paths = _v2rayn_paths(settings)
    with sqlite3.connect(paths["db"], timeout=30) as connection:
        connection.execute("PRAGMA busy_timeout=30000")
        with connection:
            _write_profile_dict(connection, profile)


def _invoke_v2rayn_reload(executable: Path) -> None:
    """Invoke Reload even when v2rayN's WPF window is hidden in the tray."""

    if os.name != "nt":
        raise RuntimeError("v2rayN 热重载只支持 Windows")
    escaped = str(executable).replace("'", "''")
    script = rf"""
$ErrorActionPreference='Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class CcdV2rayNWindowBridge {{
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lp, IntPtr p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  public delegate bool EnumWindowsProc(IntPtr h, IntPtr p);
  public static IntPtr FindMain(uint targetPid) {{
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, unused) => {{
      uint pid;
      GetWindowThreadProcessId(h, out pid);
      if (pid != targetPid) return true;
      var title = new StringBuilder(512);
      var klass = new StringBuilder(256);
      GetWindowText(h, title, title.Capacity);
      GetClassName(h, klass, klass.Capacity);
      if (title.ToString().StartsWith("v2rayN", StringComparison.OrdinalIgnoreCase) ||
          klass.ToString().StartsWith("HwndWrapper[v2rayN", StringComparison.OrdinalIgnoreCase)) {{
        if (found == IntPtr.Zero || IsWindowVisible(h)) found = h;
      }}
      return true;
    }}, IntPtr.Zero);
    return found;
  }}
}}
'@
$cim=Get-CimInstance Win32_Process -Filter "Name='v2rayN.exe'" |
  Where-Object {{$_.ExecutablePath -eq '{escaped}'}} | Select-Object -First 1
if(-not $cim){{throw 'v2rayN is not running'}}
$p=Get-Process -Id $cim.ProcessId
$previousForeground=[CcdV2rayNWindowBridge]::GetForegroundWindow()
$hwnd=[IntPtr]::Zero
$event=$null
try {{
  $md5=[Security.Cryptography.MD5]::Create()
  $eventName=(-join ($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($cim.ExecutablePath)) |
    ForEach-Object {{ $_.ToString('x2') }}))
  try {{
    $event=[Threading.EventWaitHandle]::OpenExisting($eventName)
    $event.Set() | Out-Null
  }} catch {{
    throw "v2rayN single-instance event unavailable: $($_.Exception.Message)"
  }}
  $element=$null
  for($attempt=0; $attempt -lt 100 -and -not $element; $attempt++) {{
    $hwnd=[CcdV2rayNWindowBridge]::FindMain([uint32]$cim.ProcessId)
    if($hwnd -ne [IntPtr]::Zero) {{
      try {{
        $root=[System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
        $condition=New-Object System.Windows.Automation.PropertyCondition(
          [System.Windows.Automation.AutomationElement]::AutomationIdProperty,'menuReload')
        $element=$root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$condition)
      }} catch {{ $element=$null }}
    }}
    if(-not $element) {{ Start-Sleep -Milliseconds 100 }}
  }}
  if($hwnd -eq [IntPtr]::Zero){{throw 'v2rayN main window could not be located after tray notification'}}
  if(-not $element){{throw 'v2rayN reload control was not found after showing the main window'}}
  $pattern=$null
  if(-not $element.TryGetCurrentPattern(
    [System.Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)){{
    throw 'v2rayN reload control cannot be invoked'
  }}
  $pattern.Invoke()
  Start-Sleep -Milliseconds 250
}} finally {{
  if($hwnd -ne [IntPtr]::Zero) {{
    [CcdV2rayNWindowBridge]::PostMessage($hwnd,0x0010,[IntPtr]::Zero,[IntPtr]::Zero) | Out-Null
  }}
  if($event) {{ $event.Dispose() }}
  if($previousForeground -ne [IntPtr]::Zero) {{
    [CcdV2rayNWindowBridge]::SetForegroundWindow($previousForeground) | Out-Null
  }}
}}
"""
    proc = subprocess.run(
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=20,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        check=False,
    )
    if proc.returncode != 0:
        detail = proc.stderr.strip() or proc.stdout.strip()
        raise RuntimeError(f"v2rayN 热重载失败：{detail}")


def _ensure_tun_dns_nrpt(settings: dict[str, Any]) -> None:
    """Persist the Windows DNS workaround required by v2rayN 7.24.6 TUN."""

    if os.name != "nt" or not _tun_enabled(settings):
        return
    comment = NRPT_TUN_DNS_COMMENT.replace("'", "''")
    script = rf"""
$ErrorActionPreference='Stop'
$rule=Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
  Where-Object {{$_.Comment -eq '{comment}'}} | Select-Object -First 1
if(-not $rule){{
  Add-DnsClientNrptRule -Namespace '.' -NameServers '119.29.29.29' `
    -Comment '{comment}' | Out-Null
}}
Clear-DnsClientCache
"""
    proc = subprocess.run(
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=20,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        check=False,
    )
    if proc.returncode != 0:
        detail = proc.stderr.strip() or proc.stdout.strip()
        raise RuntimeError(f"TUN DNS 策略修复失败：{detail}")


def _tun_dns_nrpt_present() -> bool:
    if os.name != "nt":
        return False
    comment = NRPT_TUN_DNS_COMMENT.replace("'", "''")
    script = (
        "$rule=Get-DnsClientNrptRule -ErrorAction SilentlyContinue | "
        f"Where-Object {{$_.Comment -eq '{comment}'}} | Select-Object -First 1; "
        "if($rule){exit 0}else{exit 1}"
    )
    proc = subprocess.run(
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
        capture_output=True,
        timeout=15,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        check=False,
    )
    return proc.returncode == 0


def _refresh_system_proxy() -> None:
    import ctypes

    internet_option_settings_changed = 39
    internet_option_refresh = 37
    wininet = ctypes.WinDLL("wininet", use_last_error=True)
    wininet.InternetSetOptionW(0, internet_option_settings_changed, 0, 0)
    wininet.InternetSetOptionW(0, internet_option_refresh, 0, 0)


def _set_system_proxy(server: str) -> None:
    if os.name != "nt":
        raise RuntimeError("安全切换只支持 Windows")
    import winreg

    path = r"Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    with winreg.CreateKey(winreg.HKEY_CURRENT_USER, path) as key:
        winreg.SetValueEx(key, "ProxyEnable", 0, winreg.REG_DWORD, 1)
        winreg.SetValueEx(key, "ProxyServer", 0, winreg.REG_SZ, server)
    _refresh_system_proxy()


def _clear_system_proxy() -> None:
    if os.name != "nt":
        return
    import winreg

    path = r"Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    with winreg.CreateKey(winreg.HKEY_CURRENT_USER, path) as key:
        winreg.SetValueEx(key, "ProxyEnable", 0, winreg.REG_DWORD, 0)
    _refresh_system_proxy()


def _v2rayn_pids(executable: Path) -> list[int]:
    escaped = str(executable).replace("'", "''")
    script = (
        "$p=Get-CimInstance Win32_Process -Filter \"Name='v2rayN.exe'\" | "
        f"Where-Object {{$_.ExecutablePath -eq '{escaped}'}} | "
        "Select-Object -ExpandProperty ProcessId; $p"
    )
    proc = subprocess.run(
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=15,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        check=False,
    )
    result: list[int] = []
    for line in proc.stdout.splitlines():
        try:
            result.append(int(line.strip()))
        except ValueError:
            continue
    return result


def _stop_v2rayn(executable: Path) -> None:
    pids = _v2rayn_pids(executable)
    if not pids:
        return
    for pid in pids:
        subprocess.run(
            ["taskkill.exe", "/PID", str(pid), "/T", "/F"],
            capture_output=True,
            timeout=15,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            check=False,
        )
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline and _v2rayn_pids(executable):
        time.sleep(0.25)
    if _v2rayn_pids(executable):
        raise RuntimeError("v2rayN 进程未能安全停止")


def _start_v2rayn(executable: Path, settings: dict[str, Any]) -> None:
    if os.name == "nt":
        # Starting this WPF application from a headless Python worker can make
        # .NET's FontCache URI initialization crash.  The user's existing
        # interactive-logon task provides the same environment as normal boot.
        task_name = str(settings.get("v2rayn_start_task", "v2rayN AutoStart")).strip()
        if not task_name:
            raise RuntimeError("未配置 v2rayN 交互式启动任务")
        result = subprocess.run(
            ["schtasks.exe", "/Run", "/TN", task_name],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=15,
            check=False,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        if result.returncode != 0:
            detail = result.stderr.strip() or result.stdout.strip()
            raise RuntimeError(f"v2rayN 启动任务失败：{detail}")
        return
    subprocess.Popen(
        [str(executable)],
        cwd=str(executable.parent),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def _wait_proxy_verified(proxy_url: str, settings: dict[str, Any], timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    port = int(proxy_url.rsplit(":", 1)[1])
    while time.monotonic() < deadline:
        if _port_open(port):
            result = selector.speed_test(
                selector.find_curl(),
                proxy_url,
                _speed_url(settings, "health"),
                64_000,
                12,
            )
            if result.get("ok"):
                return True
        time.sleep(0.5)
    return False


def _wait_tun_verified(settings: dict[str, Any], timeout: float) -> bool:
    """Verify a no-proxy request so success depends on the active TUN route."""

    deadline = time.monotonic() + timeout
    curl_bin = selector.find_curl()
    base_url = _speed_url(settings, "health")
    while time.monotonic() < deadline:
        nonce = f"{int(time.time() * 1000)}-{random.randrange(1_000_000)}"
        separator = "&" if "?" in base_url else "?"
        proc = subprocess.run(
            [
                curl_bin,
                "--silent",
                "--show-error",
                "--location",
                "--proxy",
                "",
                "--noproxy",
                "*",
                "--output",
                os.devnull,
                "--connect-timeout",
                "8",
                "--max-time",
                "12",
                "--write-out",
                "%{http_code}",
                f"{base_url}{separator}bytes=64000&cfdyn={nonce}",
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=17,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            check=False,
        )
        if proc.returncode == 0:
            with contextlib.suppress(ValueError):
                if 200 <= int(proc.stdout.strip()) < 400:
                    return True
        time.sleep(0.5)
    return False


def _safe_activate(
    settings: dict[str, Any],
    target_id: str,
    mode: str,
) -> dict[str, Any]:
    paths = _v2rayn_paths(settings)
    original_proxy = _read_system_proxy()
    tun_enabled = _tun_enabled(settings)
    if not original_proxy["enabled"] and not tun_enabled:
        raise RuntimeError("系统代理和 TUN 均未启用；拒绝执行自动切换")
    slot_id = _ensure_auto_slots(settings)[mode]
    configured_id = _configured_index_id(settings)
    old_id = _current_index_id(settings, mode)
    if target_id == old_id:
        return {"switched": False, "old_id": old_id, "new_id": target_id}
    if configured_id != slot_id:
        raise RuntimeError(
            "v2rayN 热切换槽尚未设为当前节点；为避免结束 v2rayN，已拒绝旧式重启切换"
        )

    old_slot, target_remarks = _replace_active_slot(settings, target_id, mode)
    verify_seconds = float(settings.get("v2rayn_restart_verify_seconds", 35))
    proxy_url, system_proxy_server = _configured_mixed_proxy(settings)
    try:
        _invoke_v2rayn_reload(paths["exe"])
        if not _wait_proxy_verified(proxy_url, settings, verify_seconds):
            raise RuntimeError(
                f"新 v2rayN 节点未通过 {system_proxy_server} 真实下载验证"
            )
        if tun_enabled:
            _ensure_tun_dns_nrpt(settings)
            if not _wait_tun_verified(settings, verify_seconds):
                raise RuntimeError("新 v2rayN 节点未通过 TUN 直接请求验证")
        if original_proxy["enabled"]:
            _set_system_proxy(system_proxy_server)
        _save_json_atomic(
            _slot_state_path(mode),
            {
                "time": selector.now_iso(),
                "slot_id": slot_id,
                "target_id": target_id,
                "target_remarks": target_remarks,
                "needs_reload": False,
            },
        )
        return {"switched": True, "old_id": old_id, "new_id": target_id}
    except Exception:
        selector.log("v2rayN 新节点热重载失败，正在原进程内回滚活动槽")
        _restore_active_slot(settings, old_slot)
        with contextlib.suppress(Exception):
            _invoke_v2rayn_reload(paths["exe"])
            _ensure_tun_dns_nrpt(settings)
            _wait_proxy_verified(proxy_url, settings, verify_seconds)
            if original_proxy["enabled"]:
                _set_system_proxy(str(original_proxy["server"]))
        raise


def _current_index_id(settings: dict[str, Any], mode: str | None = None) -> str:
    configured_id = _configured_index_id(settings)
    selected_mode = mode or _selected_auto_mode(settings)
    if selected_mode is None or configured_id != _active_slot_id(settings, selected_mode):
        return configured_id
    state = _load_json(_slot_state_path(selected_mode), {})
    if isinstance(state, dict) and str(state.get("slot_id", "")) == configured_id:
        if bool(state.get("needs_reload")):
            return configured_id
        target_id = str(state.get("target_id", "")).strip()
        if target_id:
            return target_id
    return configured_id


def _profile_display_name(settings: dict[str, Any], index_id: str) -> str:
    if not index_id:
        return "未知"
    paths = _v2rayn_paths(settings)
    try:
        with sqlite3.connect(paths["db"]) as connection:
            row = connection.execute(
                "SELECT Remarks,Address FROM ProfileItem WHERE IndexId=?",
                (index_id,),
            ).fetchone()
    except sqlite3.Error:
        row = None
    if not row:
        return index_id
    return str(row[0] or row[1] or index_id)


def _candidate_profile_id(pool: str, ip: str) -> str:
    return _stable_id(f"v2rayn-{pool}", ip)


def _choose_switch(
    settings: dict[str, Any],
    ranked: list[dict[str, Any]],
    current_id: str,
    mode: str,
) -> tuple[str, str]:
    state_path = _switch_state_path(mode)
    if not ranked:
        return current_id, "没有通过三次正式测速的候选"
    best = ranked[0]
    target_id = str(best["profile_id"])
    if target_id == current_id:
        state = _load_json(state_path, {})
        if isinstance(state, dict):
            state.update({"pending_id": "", "pending_wins": 0})
            _save_json_atomic(state_path, state)
        return current_id, "当前线路已是高速组内最低延迟候选"

    state = _load_json(state_path, {})
    if not isinstance(state, dict):
        state = {}
    current = next((row for row in ranked if row.get("profile_id") == current_id), None)
    fast_floor = float(best.get("fast_speed_floor_Mbps", 0))
    qualifies = current is None or float(current.get("speed_Mbps", 0)) < fast_floor
    if current is not None and not qualifies:
        gain_ms = float(current["delay_ms"]) - float(best["delay_ms"])
        gain_ratio = gain_ms / max(float(current["delay_ms"]), 1.0)
        qualifies = (
            gain_ms >= float(settings.get("minimum_latency_gain_ms", 5))
            or gain_ratio >= float(settings.get("minimum_latency_gain_ratio", 0.03))
        )
    if not qualifies:
        state.update({"pending_id": "", "pending_wins": 0})
        _save_json_atomic(state_path, state)
        return current_id, "当前线路仍在高速组且延迟改善不足，防抖保留"

    if state.get("pending_id") == target_id:
        wins = int(state.get("pending_wins", 0)) + 1
    else:
        wins = 1
    state.update({"pending_id": target_id, "pending_wins": wins})
    required = max(1, int(settings.get("required_consecutive_wins", 1)))
    if wins < required:
        _save_json_atomic(state_path, state)
        return current_id, f"候选已连续胜出 {wins}/{required} 轮，等待防抖确认"

    last_switch_text = str(state.get("last_switch", ""))
    if current is not None and last_switch_text:
        try:
            last_switch = dt.datetime.fromisoformat(last_switch_text)
            elapsed = selector.now() - last_switch
            minimum = float(settings.get("minimum_switch_interval_hours", 0.5))
            if elapsed.total_seconds() < minimum * 3600:
                _save_json_atomic(state_path, state)
                return current_id, "未到最短切换间隔，防抖保留"
        except ValueError:
            pass
    state.update({"pending_id": "", "pending_wins": 0})
    _save_json_atomic(state_path, state)
    return target_id, "候选通过高速组、最低延迟与防抖条件"


def _record_successful_switch(mode: str, target_id: str) -> None:
    state_path = _switch_state_path(mode)
    state = _load_json(state_path, {})
    if not isinstance(state, dict):
        state = {}
    state.update(
        {
            "pending_id": "",
            "pending_wins": 0,
            "last_switch": selector.now_iso(),
            "current_id": target_id,
        }
    )
    _save_json_atomic(state_path, state)


def _diagnose(settings: dict[str, Any]) -> int:
    paths = _v2rayn_paths(settings)
    issues: list[str] = []
    for name in _required_core_names(settings, include_desktop=True):
        if not paths[name].is_file():
            issues.append(f"缺少 {name}：{paths[name]}")
    try:
        pools = _load_pools(settings)
    except Exception as exc:
        pools = []
        issues.append(str(exc))
    configured_id = _configured_index_id(settings) if paths["config"].is_file() else ""
    selected_mode = _selected_auto_mode(settings) if paths["config"].is_file() else None
    current_id = _current_index_id(settings, selected_mode) if paths["config"].is_file() else ""
    slot_ids = _active_slot_ids(settings)
    profile_count = native_count = vless_count = 0
    active_routing_name = "未知"
    active_routing_rule_count = 0
    if paths["db"].is_file():
        try:
            with sqlite3.connect(paths["db"]) as connection:
                check = connection.execute("PRAGMA quick_check").fetchone()
                if not check or check[0] != "ok":
                    issues.append("v2rayN SQLite quick_check 失败")
                profile_count = connection.execute("SELECT COUNT(*) FROM ProfileItem").fetchone()[0]
                native_count = connection.execute(
                    "SELECT COUNT(*) FROM ProfileItem WHERE ConfigType=1 AND CoreType=2"
                ).fetchone()[0]
                vless_count = connection.execute(
                    "SELECT COUNT(*) FROM ProfileItem WHERE ConfigType=5 AND CoreType=2"
                ).fetchone()[0]
                active_routing = connection.execute(
                    "SELECT Remarks,RuleNum FROM RoutingItem "
                    "WHERE IsActive=1 ORDER BY Sort LIMIT 1"
                ).fetchone()
                if active_routing:
                    active_routing_name = str(active_routing[0] or "未命名")
                    active_routing_rule_count = int(active_routing[1] or 0)
                if current_id and not connection.execute(
                    "SELECT 1 FROM ProfileItem WHERE IndexId=?", (current_id,)
                ).fetchone():
                    issues.append("guiNConfig.IndexId 在数据库中不存在")
        except sqlite3.Error as exc:
            issues.append(f"v2rayN 数据库错误：{exc}")
    proxy = _read_system_proxy()
    tun_enabled = _tun_enabled(settings)
    if not proxy["enabled"] and not tun_enabled:
        issues.append("Windows 系统代理未启用；安全自动切换会拒绝运行")
    auto_switch_idle = bool(settings.get("v2rayn_auto_switch", True)) and selected_mode is None
    if tun_enabled and not _tun_dns_nrpt_present():
        issues.append("TUN DNS 的 NRPT 修复策略缺失")
    print("客户端模式：v2rayN 原生 Xray")
    print("v2rayN：", paths["root"])
    print("TUN 模式：", "已启用" if tun_enabled else "未启用")
    print("系统代理：", proxy.get("server") if proxy["enabled"] else "未启用")
    print("当前目标 ID：", current_id or "未知")
    print("活动槽 ID：", configured_id or "未知")
    print("当前自动模式：", selected_mode.upper() if selected_mode else "未选择")
    if auto_switch_idle:
        print("自动切换状态：已待命；选择 AUTO-CF 后才接管自动优选")
    print("AUTO-CF ID：", slot_ids[AUTO_MODE])
    print(
        "持久分流：",
        f"{active_routing_name}（{active_routing_rule_count} 条）",
    )
    print(
        "当前核心分流：",
        "全覆盖已生效"
        if _generated_full_routing_is_active(settings)
        else "等待下一次安全热重载",
    )
    print("TUN DNS 策略：", "已启用" if _tun_dns_nrpt_present() else "未启用")
    print("配置总数：", profile_count)
    print("原生 Xray VMess 节点数：", native_count)
    print("原生 Xray VLESS 节点数：", vless_count)
    print("优选池：", ", ".join(pool.label for pool in pools) or "无")
    if issues:
        for issue in issues:
            print("诊断失败：", issue)
        return 1
    return 0


def _quick_settings(settings: dict[str, Any]) -> dict[str, Any]:
    value = copy.deepcopy(settings)
    value["random_samples_per_run"] = min(
        int(value.get("random_samples_per_run", 160)), 200
    )
    value["discovery_provider_limit"] = min(
        int(value.get("discovery_provider_limit", 120)), 120
    )
    value["speed_probe_candidates"] = min(
        int(value.get("speed_probe_candidates", 40)), 24
    )
    value["speed_candidates"] = min(
        int(value.get("quick_speed_candidates", 8)), 8
    )
    value["speed_test_bytes"] = min(
        int(value.get("quick_speed_test_bytes", value.get("speed_test_bytes", 3_000_000))),
        int(value.get("speed_test_bytes", 3_000_000)),
    )
    value["speed_timeout_seconds"] = min(
        float(value.get("quick_speed_timeout_seconds", value.get("speed_timeout_seconds", 20))),
        float(value.get("speed_timeout_seconds", 20)),
    )
    value["tcp_workers"] = min(int(value.get("tcp_workers", 64)), 48)
    return value


def _formal_xray_candidate_limit(
    configured_total: int,
    pool_count: int,
) -> int:
    """Give every configured public template pool at least one formal slot."""

    pool_count = max(1, int(pool_count))
    return max(pool_count, int(configured_total))


def _run_powershell(script: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=15,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        check=False,
    )


def _tcp_failure_summary(rows: list[dict[str, Any]], limit: int = 3) -> str:
    counts: dict[str, int] = {}
    for row in rows:
        error = str(row.get("error") or "未知的即时连接失败").strip()
        counts[error] = counts.get(error, 0) + 1
    ordered = sorted(counts.items(), key=lambda item: (-item[1], item[0]))
    return "；".join(f"{error} × {count}" for error, count in ordered[:limit])


def _tcp_stage_with_recovery(
    candidates: list[str], settings: dict[str, Any]
) -> list[dict[str, Any]]:
    """Retry a globally failed direct TCP stage after transient network faults."""

    retries = min(
        5,
        max(0, int(settings.get("v2rayn_tcp_global_failure_retries", 2))),
    )
    retry_delay = min(
        60.0,
        max(0.0, float(settings.get("v2rayn_tcp_global_retry_delay_seconds", 5))),
    )
    rows: list[dict[str, Any]] = []
    for attempt_index in range(retries + 1):
        rows = selector.tcp_stage(candidates, settings)
        reachable = sum(1 for row in rows if row.get("reachable"))
        if reachable:
            if attempt_index:
                selector.log(
                    f"TCP 443 初筛在第 {attempt_index + 1} 轮恢复："
                    f"{reachable}/{len(rows)} 可达"
                )
            return rows
        summary = _tcp_failure_summary(rows)
        if attempt_index >= retries:
            selector.log(f"TCP 443 初筛连续整批失败：{summary}")
            return rows
        delay = retry_delay * (attempt_index + 1)
        selector.log(
            f"TCP 443 初筛第 {attempt_index + 1} 轮整批失败：{summary}；"
            f"等待 {delay:g} 秒后自动重试"
        )
        if delay:
            time.sleep(delay)
    return rows


def _notify_v2rayn_result(
    *,
    quick: bool,
    selected_mode: str | None,
    ranked: list[dict[str, Any]],
    failed_rows: list[dict[str, Any]],
    decision: dict[str, Any],
    summary: dict[str, Any],
) -> None:
    scan_name = "轻扫" if quick else "深扫"
    mode_name = f"AUTO-{selected_mode.upper()}" if selected_mode else "未选择 AUTO"
    result_name = "已自动切换" if decision.get("switched") else "保持当前线路"
    best = ranked[0]
    best_name = str(best.get("discovery_node") or best.get("ip") or "未知")
    message = "\n".join(
        [
            f"分组：{mode_name}",
            f"结果：{result_name}",
            f"最佳：{best_name}",
            f"三次平均：{float(best.get('speed_Mbps', 0)):.2f} Mbps / "
            f"冷启动代理响应 {float(best.get('delay_ms', 0)):.2f} ms",
            f"原因：{decision.get('reason', '')}",
        ]
    )
    title = f"v2rayN {scan_name}：{result_name}"
    report_path: Path | None = None
    try:
        report_path = selector.create_notification_report(
            title,
            message,
            decision=decision,
            summary=summary,
            ranked=ranked,
            failed_rows=failed_rows,
        )
    except OSError as exc:
        selector.log(f"生成 v2rayN 扫描通知报告失败：{exc}")
    selector.send_windows_notification(title, message, report_path)


def run(args: Any, settings: dict[str, Any]) -> int:
    run_started = time.monotonic()
    run_started_at = selector.now_iso()
    quick = bool(getattr(args, "quick", False))
    if bool(getattr(args, "setup_v2rayn_auto", False)):
        pools = _load_pools(settings)
        active = _load_active_state(settings)
        db_result = _upsert_v2rayn_profiles(settings, pools, active, {})
        slots = _ensure_auto_slots(settings)
        routing = _ensure_full_routing(settings)
        print(
            "AUTO-CF 已写入 v2rayN 数据库（未重载核心）："
            f"ID={slots[AUTO_MODE]}；备份={db_result['backup']}"
        )
        print(
            "全覆盖分流已写入 v2rayN 数据库（未重载核心）："
            f"ID={routing['id']}，{'已更新' if routing['changed'] else '无需变更'}"
        )
        return 0
    if bool(getattr(args, "diagnose", False)):
        return _diagnose(settings)

    run_settings = _quick_settings(settings) if quick else copy.deepcopy(settings)
    paths = _v2rayn_paths(run_settings)
    for name in _required_core_names(run_settings):
        if not paths[name].is_file():
            raise RuntimeError(f"v2rayN {name} 不存在：{paths[name]}")
    routing = _ensure_full_routing(settings)
    if routing["changed"]:
        selector.log(
            "v2rayN 全覆盖分流已持久化；将在下一次原生核心热重载时生效，"
            f"备份 {routing['backup']}"
        )
    dry_run = bool(getattr(args, "v2rayn_dry_run", False))
    lock = selector.try_acquire_run_lock()
    if lock is None:
        message = "已有优选任务正在运行，本轮 v2rayN 扫描跳过"
        selector.log(message)
        selector.try_write_run_status(quick, "skipped", run_started_at, reason=message)
        selector.send_windows_notification(
            f"v2rayN {'轻扫' if quick else '深扫'}：本轮已跳过",
            message,
        )
        return 0
    stage_durations: dict[str, float] = {}
    stage_clock = time.monotonic()

    def finish_stage(name: str) -> None:
        nonlocal stage_clock
        current = time.monotonic()
        stage_durations[name] = round(
            stage_durations.get(name, 0.0) + current - stage_clock,
            3,
        )
        stage_clock = current

    try:
        selected_mode = _selected_auto_mode(run_settings)
        pools = _load_pools(run_settings)
        if selected_mode is None:
            selector.log("当前未选择 AUTO-CF：本轮只更新节点库，不自动切换")
        if not pools:
            raise RuntimeError(f"自动模式 {selected_mode or 'none'} 没有可用优选池")
        active = _load_active_state(run_settings)
        current_id = _current_index_id(run_settings, selected_mode)
        ranges = selector.load_official_ranges(run_settings)
        rng = random.Random()
        candidates, fixed, neighbor_count, fresh, reused = _generate_candidates(
            ranges, run_settings, active, rng
        )
        selector.log(
            f"v2rayN/Xray 候选 {len(candidates)} 个：固定/历史 {len(fixed)}，"
            f"邻近探索 {neighbor_count}，新随机 {fresh}，复用随机 {reused}"
        )
        finish_stage("candidate_generation")
        tcp_settings = copy.deepcopy(run_settings)
        tcp_settings["tcp_probe_socks_proxy"] = ""
        if _tun_enabled(run_settings):
            physical_interface = _windows_physical_default_interface_index()
            if physical_interface is None:
                raise RuntimeError("TUN 已启用，但无法为 TCP 初筛绑定物理接口")
            tcp_settings["tcp_outbound_interface_index"] = physical_interface
            selector.log(
                f"TCP 443 初筛已绑定物理接口 IF {physical_interface}，避免 TUN 回灌"
            )
        tcp_rows = _tcp_stage_with_recovery(candidates, tcp_settings)
        selector.write_discovery_log(tcp_rows)
        selector.record_tcp_history(tcp_rows)
        discovery_ips = selector.select_discovery_ips(
            tcp_rows,
            fixed,
            int(run_settings.get("discovery_provider_limit", 120)),
            None,
            set(ip for values in active.values() for ip in values),
            run_settings.get("discovery_new_ip_share", 0.4),
        )
        if not discovery_ips:
            raise RuntimeError("TCP 443 初筛后没有候选")
        finish_stage("tcp_probe")
        selector.log(
            f"原生 Xray 真实协议验证：{len(pools)} 个池 × {len(discovery_ips)} 个 IP"
        )
        curl_bin = selector.find_curl()
        base_port = int(run_settings.get("v2rayn_test_port_start", 18000))
        all_rows: list[dict[str, Any]] = []
        metrics: dict[str, dict[str, Any]] = {}
        protocol_attempted_count = 0
        protocol_valid_count = 0
        with XrayBatch(paths["xray"], pools, discovery_ips, base_port) as batch:
            protocol_attempted_count = len(batch.proxies)
            delays, delay_samples, delay_stddev = _measure_delays(
                batch.proxies, run_settings, curl_bin
            )
            selector.log(
                "三次原生 Xray 冷启动响应有效："
                f"{len(delays)}/{len(batch.proxies)}"
            )
            if not delays:
                raise RuntimeError("所有 Xray 候选真实代理测试失败")
            protocol_valid_count = len(delays)
            selector.record_vm_history([batch.proxies[key].name for key in delays])
            finish_stage("vmess_delay")
            probe_keys = _select_probe_keys(
                delays,
                int(run_settings.get("speed_probe_candidates", 40)),
                rng,
                batch.proxies,
            )
            probe_results: list[dict[str, Any]] = []
            for index, key in enumerate(probe_keys, 1):
                proxy = batch.proxies[key]
                proxy_url = f"http://127.0.0.1:{proxy.port}"
                result = selector.speed_test(
                    curl_bin,
                    proxy_url,
                    _speed_url(run_settings, "probe"),
                    int(run_settings.get("speed_probe_bytes", 250_000)),
                    float(run_settings.get("speed_probe_timeout_seconds", 10)),
                )
                row = {
                    "time": selector.now_iso(),
                    "ip": proxy.ip,
                    "node": proxy.name,
                    "candidate_key": key,
                    "delay_ms": delays[key],
                    "speed_ok": bool(result.get("ok")),
                    "speed_Mbps": result.get("speed_Mbps", 0),
                    "ttfb_ms": result.get("ttfb_ms"),
                    "size_download": result.get("size_download", 0),
                    "timed_out": bool(result.get("timed_out")),
                    "error": result.get("error", ""),
                }
                probe_results.append(row)
                selector.log(
                    f"Xray 速度粗测 {index}/{len(probe_keys)} {key}："
                    f"{row['speed_Mbps']} Mbps" if row["speed_ok"] else
                    f"Xray 速度粗测 {index}/{len(probe_keys)} {key} 失败：{row['error']}"
                )
            selector.write_speed_probe_log(probe_results)
            selector.record_speed_history(probe_results)
            finish_stage("speed_probe")
            passed = [row for row in probe_results if row["speed_ok"]]
            passed.sort(key=lambda row: (-float(row["speed_Mbps"]), float(row["delay_ms"])))
            formal_limit = _formal_xray_candidate_limit(
                int(run_settings.get("speed_candidates", 20)),
                len(pools),
            )
            formal_keys: list[str] = []
            for pool in pools:
                best_for_pool = next(
                    (
                        str(row["candidate_key"])
                        for row in passed
                        if batch.proxies[str(row["candidate_key"])].pool == pool.key
                    ),
                    None,
                )
                if best_for_pool and best_for_pool not in formal_keys:
                    formal_keys.append(best_for_pool)
            for row in passed:
                key = str(row["candidate_key"])
                if key not in formal_keys:
                    formal_keys.append(key)
                if len(formal_keys) >= formal_limit:
                    break
            formal_keys = formal_keys[:formal_limit]
            current_candidate_key = next(
                (
                    key
                    for key, proxy in batch.proxies.items()
                    if key in delays
                    and _candidate_profile_id(proxy.pool, proxy.ip) == current_id
                ),
                None,
            )
            if current_candidate_key and current_candidate_key not in formal_keys:
                formal_keys.append(current_candidate_key)
                selector.log(
                    f"当前节点 {current_candidate_key} 作为防误判额外加入正式测速"
                )
            if not formal_keys:
                raise RuntimeError("原生 Xray 速度粗测没有候选通过")

            proxy_urls = {
                key: f"http://127.0.0.1:{batch.proxies[key].port}"
                for key in formal_keys
            }
            warmed: set[str] = set()

            def run_one(key: str, _: int) -> dict[str, Any]:
                if key not in warmed and bool(run_settings.get("speed_warmup_enabled", True)):
                    selector.warmup_speed_test(
                        curl_bin,
                        proxy_urls[key],
                        _speed_url(run_settings, "probe"),
                        int(run_settings.get("speed_warmup_bytes", 131_072)),
                        float(run_settings.get("speed_warmup_timeout_seconds", 8)),
                        progress_prefix=f"{key} ",
                    )
                    warmed.add(key)
                return selector.parallel_speed_test(
                    curl_bin,
                    proxy_urls[key],
                    _speed_url(run_settings, "formal"),
                    int(run_settings["speed_test_bytes"]),
                    float(run_settings["speed_timeout_seconds"]),
                    int(run_settings.get("v2rayn_speed_concurrency", 5)),
                    int(run_settings.get("v2rayn_speed_stream_bytes", 4_000_000)),
                )

            results = selector.interleaved_speed_tests(
                formal_keys,
                run_one,
                int(run_settings.get("speed_repeats", 3)),
                float(run_settings.get("speed_repeat_interval_seconds", 0.5)),
                bool(run_settings.get("require_all_repeats", True)),
                rng,
            )
            maximum_cv = float(run_settings.get("maximum_speed_cv", 0.45))
            for key in formal_keys:
                result = results[key]
                stable = (
                    bool(result.get("ok"))
                    and float(result.get("speed_cv", 0)) <= maximum_cv
                )
                proxy = batch.proxies[key]
                row = {
                    "time": selector.now_iso(),
                    "ip": proxy.ip,
                    "discovery_node": proxy.name,
                    "selection_name": proxy.name,
                    "candidate_id": key,
                    "candidate_key": key,
                    "candidate_type": str(
                        proxy.template.get("type") or "vmess"
                    ).lower(),
                    "pool": proxy.pool,
                    "profile_id": _candidate_profile_id(proxy.pool, proxy.ip),
                    "delay_ms": delays.get(key, 1e9),
                    "delay_samples_ms": ",".join(
                        f"{value:.2f}" for value in delay_samples.get(key, [])
                    ),
                    "delay_stddev_ms": delay_stddev.get(key, 0),
                    **result,
                    "speed_stable": stable,
                    "speed_ok": bool(result.get("ok")) and stable,
                }
                if result.get("ok") and not stable:
                    row["error"] = (
                        f"三次速度波动过大：CV={float(result.get('speed_cv', 0)):.1%}"
                    )
                all_rows.append(row)
                metrics[key] = row

        finish_stage("formal_speed")

        ranked = selector.rank_rows(all_rows, run_settings.get("fast_speed_ratio", 0.95))
        selector.write_latest(all_rows)
        selector.append_history(ranked, int(run_settings.get("history_max_rows", 10_000)))
        if not ranked:
            raise RuntimeError("没有候选通过三次正式测速和稳定性门槛")
        selector.log("v2rayN/Xray 本轮正式排名：")
        for index, row in enumerate(ranked, 1):
            selector.log(
                f"{index}. {row['candidate_id']} "
                f"三次全程速度[{row.get('speed_samples_Mbps', '')}] "
                f"平均 {row['speed_Mbps']} Mbps σ={row.get('speed_stddev_Mbps', 0)}；"
                f"短传输峰值平均 {row.get('payload_speed_Mbps', 0)} Mbps（仅诊断）；"
                f"并发 {row.get('parallel_concurrency', 1)}×"
                f"{row.get('parallel_stream_bytes', 0)} bytes/流；"
                f"原始冷启动响应[{row.get('delay_samples_ms', '')}] "
                f"平均 {row['delay_ms']} ms σ={row.get('delay_stddev_ms', 0)}"
            )

        pool_size = max(1, int(run_settings.get("active_pool_size", 40)))
        next_active: dict[str, list[str]] = {
            key: list(values) for key, values in active.items()
        }
        for pool in pools:
            winners = [
                str(row["ip"])
                for row in ranked
                if row.get("pool") == pool.key
            ]
            combined = winners + active.get(pool.key, [])
            next_active[pool.key] = list(dict.fromkeys(combined))[:pool_size]
        if dry_run:
            selector.log("v2rayN dry-run：未写数据库、未切换系统代理")
            return 0

        _save_active_state(next_active)
        db_result = _upsert_v2rayn_profiles(run_settings, pools, next_active, metrics)
        selector.log(
            "v2rayN 原生节点库已更新："
            f"新增 {db_result['inserted']}，更新 {db_result['updated']}，"
            f"清理 {db_result['deleted']}；备份 {db_result['backup']}"
        )
        finish_stage("active_provider")
        slot_ids = _ensure_auto_slots(run_settings)
        current_row = next(
            (row for row in all_rows if str(row.get("profile_id")) == current_id),
            None,
        )
        current_name_before = (
            str(current_row.get("discovery_node") or current_row.get("ip"))
            if current_row
            else _profile_display_name(run_settings, current_id)
        )
        current_ip_before = (
            str(current_row.get("ip")) if current_row else current_name_before
        )
        if selected_mode is None:
            target_id = current_id
            reason = "当前未选择 AUTO-CF；已更新节点库但未自动切换"
        else:
            target_id, reason = _choose_switch(
                run_settings, ranked, current_id, selected_mode
            )
        reason = reason.replace("延迟", "冷启动响应")
        decision = {
            "time": selector.now_iso(),
            "client_mode": "v2rayn",
            "auto_mode": selected_mode,
            "auto_slot_id": slot_ids.get(selected_mode) if selected_mode else None,
            "current_id": current_id,
            "target_id": target_id,
            "reason": reason,
            "best": ranked[0],
            "current_name_before": current_name_before,
            "current_ip_before": current_ip_before,
            "current_metrics": current_row or {},
            "switched": False,
        }
        if (
            selected_mode is not None
            and target_id != current_id
            and bool(run_settings.get("v2rayn_auto_switch", True))
        ):
            switch_result = _safe_activate(run_settings, target_id, selected_mode)
            decision.update(switch_result)
            if switch_result.get("switched"):
                _record_successful_switch(selected_mode, target_id)
        elif target_id != current_id:
            decision["reason"] += "；自动切换已关闭"
        if decision.get("switched"):
            decision["current_name_after"] = str(
                ranked[0].get("discovery_node") or ranked[0].get("ip") or target_id
            )
            decision["current_ip_after"] = str(ranked[0].get("ip") or target_id)
        else:
            decision["current_name_after"] = current_name_before
            decision["current_ip_after"] = current_ip_before
        finish_stage("decision")
        selector.save_json_atomic(selector.DECISION_JSON, decision)
        selector.log(decision["reason"])
        selected_pool_keys = {pool.key for pool in pools}
        previous_pool_size = sum(
            len(active.get(key, [])) for key in selected_pool_keys
        )
        current_pool_size = sum(
            len(next_active.get(key, [])) for key in selected_pool_keys
        )
        new_active_count = sum(
            len(set(next_active.get(key, [])) - set(active.get(key, [])))
            for key in selected_pool_keys
        )
        failed_rows = [row for row in all_rows if not row.get("speed_ok")]
        timeout_counts = {
            "tcp_probe": sum(
                1 for row in tcp_rows
                if "timed out" in str(row.get("error", "")).lower()
                or "超时" in str(row.get("error", ""))
            ),
            "speed_probe": sum(
                1 for row in probe_results if row.get("timed_out")
            ),
            "formal_speed": sum(
                int(row.get("timeout_runs", 0)) for row in all_rows
            ),
        }
        summary = {
            "client_mode": "v2rayn",
            "summary_schema_version": 2,
            "candidate_count": len(candidates),
            "fixed_candidate_count": len(fixed),
            "neighbor_candidate_count": neighbor_count,
            "random_new_count": fresh,
            "random_reused_count": reused,
            "tcp_reachable_count": sum(
                1 for row in tcp_rows if row.get("reachable")
            ),
            "tcp_failed_count": sum(
                1 for row in tcp_rows if not row.get("reachable")
            ),
            "discovery_pool_count": protocol_attempted_count,
            "discovery_not_selected_count": max(
                0,
                sum(1 for row in tcp_rows if row.get("reachable"))
                - len(discovery_ips),
            ),
            "vm_valid_count": protocol_valid_count,
            "proxy_valid_count": protocol_valid_count,
            "proxy_failed_count": max(
                0, protocol_attempted_count - protocol_valid_count
            ),
            "speed_probe_selected_count": len(probe_keys),
            "speed_probe_attempted_count": len(probe_results),
            "speed_probe_passed_count": len(passed),
            "speed_probe_failed_count": max(0, len(probe_results) - len(passed)),
            "speed_probe_not_selected_count": max(
                0, protocol_valid_count - len(probe_keys)
            ),
            "formal_selected_count": len(formal_keys),
            "formal_attempted_count": len(all_rows),
            "formal_passed_count": len(ranked),
            "formal_failed_count": len(failed_rows),
            "formal_not_selected_count": max(
                0,
                len(passed) - len(formal_keys),
            ),
            "fast_group_count": sum(
                1 for row in ranked if row.get("fast_group")
            ),
            "outside_fast_group_count": sum(
                1 for row in ranked if not row.get("fast_group")
            ),
            "speed_passed_count": len(ranked),
            "speed_attempted_count": len(all_rows),
            "failed_count": (
                sum(1 for row in tcp_rows if not row.get("reachable"))
                + max(0, protocol_attempted_count - protocol_valid_count)
                + max(0, len(probe_results) - len(passed))
                + len(failed_rows)
            ),
            "timeout_count_total": sum(timeout_counts.values()),
            "active_pool_size": current_pool_size,
            "fixed_proxy_count": 0,
            "new_active_count": new_active_count,
            "pool_size_delta": current_pool_size - previous_pool_size,
            "deferred_count": 0,
            "duration_seconds": round(time.monotonic() - run_started, 1),
            "stage_durations_seconds": stage_durations,
            "timeout_counts": timeout_counts,
            "auto_mode": selected_mode,
        }
        selector.try_write_run_status(
            quick,
            "success",
            run_started_at,
            reason=str(decision["reason"]),
            summary=summary,
        )
        _notify_v2rayn_result(
            quick=quick,
            selected_mode=selected_mode,
            ranked=ranked,
            failed_rows=failed_rows,
            decision=decision,
            summary=summary,
        )
        return 0
    finally:
        selector.release_run_lock(lock)
