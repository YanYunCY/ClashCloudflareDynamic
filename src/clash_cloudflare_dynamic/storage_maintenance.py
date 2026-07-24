from __future__ import annotations

import datetime as dt
import os
import re
import shutil
import sqlite3
import stat
import time
from pathlib import Path
from typing import Callable


MANAGED_BACKUP_PREFIXES = (
    "aggressive-mode",
    "background-notify",
    "database-corrupt",
    "feature-update",
    "final-code-review",
    "final-provider-rollback",
    "final-review",
    "health-launcher-python",
    "health-launcher-pythonw",
    "install",
    "notification-details",
    "notification-window-fix",
    "performance-final",
    "performance-final-observability",
    "performance-improvements",
    "priority-fix",
    "review-five-improvements",
    "review-fixes",
    "runtime-update",
    "stability-update",
    "test-sync",
)
MANAGED_BACKUP_NAME = re.compile(
    r"^(?:"
    + "|".join(re.escape(prefix) for prefix in MANAGED_BACKUP_PREFIXES)
    + r")-\d{8}-\d{6}(?:-\d+)*$"
)
ROOT_BACKUP_FILE_NAME = re.compile(r"^(.+)\.backup-(\d{8}-\d{6})(?:-\d+)*$")
CORRUPTION_MESSAGES = (
    "database disk image is malformed",
    "file is not a database",
    "database schema is corrupt",
    "malformed database schema",
)
_VERIFIED_DATABASES: set[Path] = set()


class SQLiteIntegrityError(sqlite3.DatabaseError):
    pass


def is_sqlite_corruption_error(exc: BaseException) -> bool:
    if isinstance(exc, SQLiteIntegrityError):
        return True
    code = getattr(exc, "sqlite_errorcode", None)
    if isinstance(code, int):
        base_code = code & 0xFF
        corruption_codes = {
            getattr(sqlite3, "SQLITE_CORRUPT", 11),
            getattr(sqlite3, "SQLITE_NOTADB", 26),
        }
        if base_code in corruption_codes:
            return True
    message = str(exc).lower()
    return any(marker in message for marker in CORRUPTION_MESSAGES)


def _is_reparse_point(path: Path) -> bool:
    try:
        item_stat = path.stat(follow_symlinks=False)
    except OSError:
        return True
    attributes = getattr(item_stat, "st_file_attributes", 0)
    reparse_flag = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
    return path.is_symlink() or bool(attributes & reparse_flag)


def cleanup_managed_backups(
    backup_root: Path,
    retention_days: float = 30,
    minimum_keep: int = 10,
    logger: Callable[[str], None] | None = None,
    now: float | None = None,
) -> int:
    if not backup_root.is_dir():
        return 0

    cutoff = (time.time() if now is None else float(now)) - max(
        1.0, float(retention_days)
    ) * 86400
    keep_count = max(0, int(minimum_keep))
    try:
        root_resolved = backup_root.resolve()
        children = list(backup_root.iterdir())
    except OSError as exc:
        if logger:
            logger(f"Cannot inspect backup root {backup_root}: {exc}")
        return 0
    candidates: list[tuple[float, Path]] = []

    for child in children:
        if (
            not MANAGED_BACKUP_NAME.fullmatch(child.name)
            or not child.is_dir()
            or _is_reparse_point(child)
        ):
            continue
        try:
            candidates.append((child.stat().st_mtime, child))
        except OSError as exc:
            if logger:
                logger(f"Cannot inspect backup {child}: {exc}")

    candidates.sort(key=lambda item: (item[0], item[1].name), reverse=True)
    deleted = 0
    for modified, child in candidates[keep_count:]:
        if modified >= cutoff:
            continue
        try:
            resolved = child.resolve()
            if resolved.parent != root_resolved or resolved == root_resolved:
                raise RuntimeError(f"Unsafe backup path: {resolved}")
            shutil.rmtree(resolved)
            deleted += 1
        except (OSError, RuntimeError) as exc:
            if logger:
                logger(f"Cannot remove backup {child}: {exc}")
    return deleted


def cleanup_root_backup_files(
    install_root: Path,
    keep_per_file: int = 3,
    retention_days: float = 30,
    logger: Callable[[str], None] | None = None,
    now: float | None = None,
) -> int:
    """清理安装根目录中散落的 *.backup-YYYYMMDD-HHMMSS 文件。

    遍历 *install_root* 下的直接子文件，匹配 ``ROOT_BACKUP_FILE_NAME``
    正则，按 base name 分组后，每组保留最新 *keep_per_file* 份，并删除
    mtime 超过 *retention_days* 天的旧文件。

    Remove stale ``*.backup-YYYYMMDD-HHMMSS`` files that accumulate in the
    installation root directory.  Files are grouped by their base name (the
    part before the ``.backup-`` suffix).  Within each group the newest
    *keep_per_file* copies are always retained; any copy whose mtime exceeds
    *retention_days* days is removed.

    Parameters
    ----------
    install_root:
        Root directory to scan (one level only, files only).
    keep_per_file:
        Minimum number of backups to retain per base name regardless of age.
    retention_days:
        Age threshold in days.  Files older than this are eligible for removal.
    logger:
        Optional callback for diagnostic messages.
    now:
        Override for the current time (seconds since epoch).  Defaults to
        ``time.time()``.

    Returns
    -------
    int
        Number of files deleted.
    """
    if not install_root.is_dir():
        return 0

    cutoff = (time.time() if now is None else float(now)) - max(
        1.0, float(retention_days)
    ) * 86400
    keep = max(0, int(keep_per_file))

    try:
        children = list(install_root.iterdir())
    except OSError as exc:
        if logger:
            logger(f"Cannot inspect install root {install_root}: {exc}")
        return 0

    # Group matching files by their base name (first capture group).
    groups: dict[str, list[tuple[float, Path]]] = {}
    for child in children:
        if not child.is_file() or _is_reparse_point(child):
            continue
        match = ROOT_BACKUP_FILE_NAME.fullmatch(child.name)
        if not match:
            continue
        base_name = match.group(1)
        try:
            mtime = child.stat().st_mtime
        except OSError as exc:
            if logger:
                logger(f"Cannot inspect backup file {child}: {exc}")
            continue
        groups.setdefault(base_name, []).append((mtime, child))

    deleted = 0
    for base_name, entries in groups.items():
        # Sort newest-first so slicing beyond *keep* gives the oldest copies.
        entries.sort(key=lambda item: (item[0], item[1].name), reverse=True)
        for modified, child in entries[keep:]:
            if modified >= cutoff:
                continue
            try:
                child.unlink()
                deleted += 1
            except OSError as exc:
                if logger:
                    logger(f"Cannot remove backup file {child}: {exc}")
    return deleted


def _next_corrupt_backup_directory(backup_root: Path) -> Path:
    backup_root.mkdir(parents=True, exist_ok=True)
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    base = backup_root / f"database-corrupt-{stamp}-{os.getpid()}"
    candidate = base
    suffix = 1
    while candidate.exists():
        candidate = backup_root / f"{base.name}-{suffix}"
        suffix += 1
    candidate.mkdir()
    return candidate


def backup_corrupt_sqlite_database(
    database_path: Path,
    backup_root: Path,
) -> Path:
    sources = [
        database_path,
        database_path.with_name(database_path.name + "-wal"),
        database_path.with_name(database_path.name + "-shm"),
    ]
    existing = [path for path in sources if path.is_file()]
    if not existing:
        raise FileNotFoundError(database_path)

    backup_directory = _next_corrupt_backup_directory(backup_root)
    try:
        for source in existing:
            temp = backup_directory / f".{source.name}.tmp"
            target = backup_directory / source.name
            shutil.copy2(source, temp)
            os.replace(temp, target)
    except Exception:
        # The originals remain untouched until every backup copy succeeds.
        shutil.rmtree(backup_directory, ignore_errors=True)
        raise

    # Remove sidecars first and the main database last. If removal fails, the
    # verified backup remains available and the caller will abort recovery.
    for source in reversed(existing):
        source.unlink()
    return backup_directory


def _connect_and_initialize(
    database_path: Path,
    initializer: Callable[[sqlite3.Connection], None],
    timeout: float,
    verify: bool,
) -> sqlite3.Connection:
    had_existing_data = (
        database_path.is_file() and database_path.stat().st_size > 0
    )
    connection = sqlite3.connect(database_path, timeout=timeout)
    try:
        if verify and had_existing_data:
            check = connection.execute("PRAGMA quick_check(1)").fetchone()
            if not check or str(check[0]).lower() != "ok":
                detail = check[0] if check else "no result"
                raise SQLiteIntegrityError(
                    f"SQLite quick_check failed: {detail}"
                )
        initializer(connection)
        if verify and not had_existing_data:
            check = connection.execute("PRAGMA quick_check(1)").fetchone()
            if not check or str(check[0]).lower() != "ok":
                detail = check[0] if check else "no result"
                raise SQLiteIntegrityError(
                    f"SQLite quick_check failed: {detail}"
                )
        connection.commit()
        return connection
    except Exception:
        connection.close()
        raise


def connect_sqlite_with_recovery(
    database_path: Path,
    backup_root: Path,
    initializer: Callable[[sqlite3.Connection], None],
    timeout: float = 30,
    logger: Callable[[str], None] | None = None,
) -> sqlite3.Connection:
    database_key = database_path.resolve()
    verify = database_key not in _VERIFIED_DATABASES
    try:
        connection = _connect_and_initialize(
            database_path, initializer, timeout, verify
        )
        _VERIFIED_DATABASES.add(database_key)
        return connection
    except sqlite3.DatabaseError as exc:
        if not is_sqlite_corruption_error(exc) or not database_path.is_file():
            raise
        backup_directory = backup_corrupt_sqlite_database(
            database_path, backup_root
        )
        if logger:
            logger(
                "Corrupt SQLite database backed up to "
                f"{backup_directory}; rebuilding"
            )
        _VERIFIED_DATABASES.discard(database_key)
        connection = _connect_and_initialize(
            database_path, initializer, timeout, True
        )
        _VERIFIED_DATABASES.add(database_key)
        return connection
