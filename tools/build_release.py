#!/usr/bin/env python3
"""Build the Windows-compatible flat release package from the source tree."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import tempfile
import zipfile


PACKAGE_NAME = "ClashCloudflareDynamic"

CORE_FILES = (
    "dynamic_selector.py",
    "health_monitor_launcher.py",
    "storage_maintenance.py",
)

WINDOWS_FILES = (
    "deep_scan_5000.bat",
    "diagnose.bat",
    "health_monitor.ps1",
    "install_aggressive_5000_30min.ps1",
    "install_hybrid_5000.ps1",
    "light_scan_200.bat",
    "notify_windows.ps1",
    "quick_test.bat",
    "run_now.bat",
    "setup.ps1",
    "uninstall.ps1",
)

EXAMPLE_FILES = (
    "settings.example.json",
    "node_template.example.json",
    "node_template.vless.example.json",
    "node_template.trojan.example.json",
)

ROOT_METADATA_FILES = (
    "LICENSE",
    "NOTICE.md",
    "README.md",
    "SECURITY.md",
)

CONFIG_FILES = (
    "config.template.yaml",
    "seed_ips.txt",
)

CRLF_SUFFIXES = {".bat", ".ps1"}
LF_SUFFIXES = {"", ".json", ".md", ".py", ".txt", ".yaml", ".yml"}
UTF8_BOM = b"\xef\xbb\xbf"

FORBIDDEN_FILE_NAMES = {
    "settings.json",
    "node_template.json",
    "state.json",
    "dynamic_selector.lock",
    "cloudflare_ranges_cache.txt",
    "health_monitor_state.json",
}

FORBIDDEN_DIRECTORY_NAMES = {
    ".git",
    ".github",
    "__pycache__",
    "backups",
    "logs",
    "providers",
    "tests",
    "tools",
}


def repository_root() -> Path:
    return Path(__file__).resolve().parents[1]


def choose_layout_directory(standard: Path, legacy: Path) -> Path:
    """Prefer the standard tree; legacy fallback supports transition builds."""
    return standard if standard.is_dir() else legacy


def require_regular_file(path: Path, root: Path) -> Path:
    if path.is_symlink():
        raise RuntimeError(f"release source must not be a symbolic link: {path}")
    resolved = path.resolve(strict=True)
    try:
        resolved.relative_to(root.resolve(strict=True))
    except ValueError as exc:
        raise RuntimeError(f"release source escapes repository: {path}") from exc
    if not resolved.is_file():
        raise RuntimeError(f"release source is not a regular file: {path}")
    return resolved


def release_manifest(root: Path) -> tuple[tuple[Path, Path], ...]:
    core_root = choose_layout_directory(
        root / "src" / "clash_cloudflare_dynamic",
        root,
    )
    config_root = choose_layout_directory(root / "config", root)
    windows_root = root / "scripts" / "windows"
    examples_root = root / "examples"

    entries: list[tuple[Path, Path]] = []
    entries.extend((core_root / name, Path(name)) for name in CORE_FILES)
    entries.extend((windows_root / name, Path(name)) for name in WINDOWS_FILES)
    entries.extend(
        (examples_root / name, Path("examples") / name)
        for name in EXAMPLE_FILES
    )
    entries.extend((config_root / name, Path(name)) for name in CONFIG_FILES)
    entries.extend((root / name, Path(name)) for name in ROOT_METADATA_FILES)

    destinations = [destination.as_posix().casefold() for _, destination in entries]
    if len(destinations) != len(set(destinations)):
        raise RuntimeError("release manifest contains duplicate destinations")

    return tuple(
        (require_regular_file(source, root), destination)
        for source, destination in entries
    )


def is_forbidden_release_path(relative_path: Path) -> bool:
    lowered_parts = tuple(part.casefold() for part in relative_path.parts)
    name = relative_path.name.casefold()
    if any(part in FORBIDDEN_DIRECTORY_NAMES for part in lowered_parts[:-1]):
        return True
    if name in FORBIDDEN_FILE_NAMES:
        return True
    if name.startswith("test_"):
        return True
    if name.endswith((".db", ".db-shm", ".db-wal", ".sqlite", ".sqlite3")):
        return True
    if name.startswith("clash_cloudflare_dynamic") and name.endswith((".yaml", ".yml")):
        return True
    if name.endswith((".lock", ".log", ".tmp", ".bak", ".zip")):
        return True
    return False


def validate_staged_package(
    package_root: Path,
    required_destinations: set[Path],
) -> None:
    staged_files = sorted(
        path.relative_to(package_root)
        for path in package_root.rglob("*")
        if path.is_file()
    )
    forbidden = [path for path in staged_files if is_forbidden_release_path(path)]
    if forbidden:
        joined = ", ".join(path.as_posix() for path in forbidden)
        raise RuntimeError(f"forbidden private/runtime files entered release: {joined}")

    for json_path in package_root.joinpath("examples").glob("*.json"):
        with json_path.open("r", encoding="utf-8-sig") as handle:
            json.load(handle)

    missing = sorted(required_destinations.difference(staged_files))
    if missing:
        joined = ", ".join(path.as_posix() for path in missing)
        raise RuntimeError(f"release is missing required files: {joined}")


def normalized_release_bytes(source: Path, destination: Path) -> bytes:
    """Return canonical bytes independent of the checkout's line endings."""
    data = source.read_bytes()
    suffix = destination.suffix.casefold()
    if suffix not in CRLF_SUFFIXES | LF_SUFFIXES:
        return data

    text = data.decode("utf-8-sig").replace("\r\n", "\n").replace("\r", "\n")
    if suffix in CRLF_SUFFIXES:
        text = text.replace("\n", "\r\n")
    encoded = text.encode("utf-8")
    return UTF8_BOM + encoded if suffix == ".ps1" else encoded


def safe_remove_tree(path: Path, allowed_parent: Path) -> None:
    resolved = path.resolve()
    parent = allowed_parent.resolve()
    if resolved.parent != parent or resolved.name != PACKAGE_NAME:
        raise RuntimeError(f"refusing to remove unexpected path: {resolved}")
    if resolved.exists():
        shutil.rmtree(resolved)


def write_archive(package_root: Path, archive_path: Path) -> None:
    temporary_archive = archive_path.with_name(f".{archive_path.name}.{os.getpid()}.tmp")
    try:
        with zipfile.ZipFile(
            temporary_archive,
            mode="w",
            compression=zipfile.ZIP_STORED,
        ) as archive:
            for source in sorted(package_root.rglob("*")):
                if source.is_file():
                    archive_name = Path(PACKAGE_NAME) / source.relative_to(package_root)
                    info = zipfile.ZipInfo(
                        archive_name.as_posix(),
                        date_time=(1980, 1, 1, 0, 0, 0),
                    )
                    info.compress_type = zipfile.ZIP_STORED
                    info.external_attr = 0o100644 << 16
                    archive.writestr(info, source.read_bytes())
        os.replace(temporary_archive, archive_path)
    finally:
        temporary_archive.unlink(missing_ok=True)


def build_release(
    root: Path,
    dist_root: Path,
    create_archive: bool = True,
) -> tuple[Path, Path | None]:
    root = root.resolve(strict=True)
    dist_root = dist_root.resolve()
    dist_root.mkdir(parents=True, exist_ok=True)
    package_root = dist_root / PACKAGE_NAME
    manifest = release_manifest(root)
    required_destinations = {destination for _, destination in manifest}

    with tempfile.TemporaryDirectory(prefix=".release-", dir=dist_root) as temporary:
        staged_root = Path(temporary) / PACKAGE_NAME
        staged_root.mkdir()
        for source, destination in manifest:
            target = staged_root / destination
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(normalized_release_bytes(source, destination))
        validate_staged_package(staged_root, required_destinations)

        safe_remove_tree(package_root, dist_root)
        os.replace(staged_root, package_root)

    archive_path: Path | None = None
    if create_archive:
        archive_path = dist_root / f"{PACKAGE_NAME}.zip"
        write_archive(package_root, archive_path)
    return package_root, archive_path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--dist-dir",
        type=Path,
        help="output parent directory (default: <repository>/dist)",
    )
    parser.add_argument(
        "--no-archive",
        action="store_true",
        help="build only the unpacked package",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = repository_root()
    dist_root = args.dist_dir if args.dist_dir else root / "dist"
    package_root, archive_path = build_release(
        root,
        dist_root,
        create_archive=not args.no_archive,
    )
    print(f"release directory: {package_root}")
    if archive_path is not None:
        print(f"release archive: {archive_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
