#!/usr/bin/env python3
"""数据库备份 / 恢复演练（开服前必须有，且必须演练过一次）。

为什么不用 `mysqldump > file`：
  * 连接串在 gitignored 的 `server.cfg` 里，口令不能出现在命令行（会进 shell history 与进程列表）；
  * 本机 DB 跑在 docker 容器里（`tcity-mariadb`），宿主机不一定装了客户端；
  * 备份完必须**验货**：文件存在 ≠ 能恢复。

做法：从 `server.cfg` 解析连接串（只用来连，不打印口令）→ 在容器里跑 `mariadb-dump` 并把结果
写进 `backups/`（gitignored）→ 记录一条 manifest（时间、大小、sha256、表数）→ 按保留策略删旧文件。

用法::

    python3 tools/dev/db_backup.py                 # 备份 + 保留策略
    python3 tools/dev/db_backup.py --keep 14       # 保留 14 份
    python3 tools/dev/db_backup.py --list          # 看现有备份
    python3 tools/dev/db_backup.py --restore FILE --to-scratch
                                                   # 恢复到 scratch 库（恢复演练，不动生产库）

退出码：0 成功；1 备份/恢复失败；2 环境缺失（没有 server.cfg / docker / 容器没起）。
"""

from __future__ import annotations

import argparse
import hashlib
import os
import json
import re
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SERVER_CFG = Path(os.environ.get("TCITY_SERVER_CFG", str(REPO / "T-CityLite.base" / "server.cfg")))
BACKUP_DIR = REPO / "backups"
DEFAULT_KEEP = 7
CONTAINER = "tcity-mariadb"


def connection() -> tuple[str, str, str, str]:
    """(host, user, password, database) —— 从 server.cfg 解析，绝不打印口令。"""
    if not SERVER_CFG.exists():
        raise SystemExit("[backup] 找不到 server.cfg（这份文件是 gitignored 的，只在部署机上）")
    text = SERVER_CFG.read_text(encoding="utf-8", errors="ignore")
    match = re.search(r'set\s+mysql_connection_string\s+"mysql://([^:]+):([^@]*)@([^/]+)/([^?"]+)', text)
    if not match:
        raise SystemExit("[backup] server.cfg 里没有可解析的 mysql_connection_string")
    user, password, hostport, database = match.groups()
    host = hostport.split(":")[0]
    return host, user, password, database


def docker_available() -> bool:
    return shutil.which("docker") is not None and subprocess.run(
        ["docker", "ps", "--format", "{{.Names}}"], capture_output=True, text=True
    ).returncode == 0


def container_running() -> bool:
    result = subprocess.run(["docker", "ps", "--format", "{{.Names}}"], capture_output=True, text=True)
    return CONTAINER in (result.stdout or "").split()


def dump(database: str) -> bytes:
    """在容器里导出（单事务、不锁表），口令通过环境变量传，不进命令行。"""
    _, user, password, _ = connection()
    command = [
        "docker", "exec", "-i", "-e", "MYSQL_PWD", CONTAINER,
        "mariadb-dump", f"-u{user}", "--single-transaction", "--skip-lock-tables",
        "--routines", "--triggers", "--default-character-set=utf8mb4", database,
    ]
    # `-e MYSQL_PWD` 只传变量**名**，值从子进程环境继承 → 口令不出现在宿主机 argv（ps/WMI/EDR）
    result = subprocess.run(command, capture_output=True, env={**os.environ, "MYSQL_PWD": password})
    if result.returncode != 0:
        raise SystemExit(f"[backup] dump 失败：{(result.stderr or b'').decode('utf-8', 'ignore')[:300]}")
    return result.stdout


def table_count(sql: bytes) -> int:
    return sql.count(b"CREATE TABLE")


def write_backup(payload: bytes) -> Path:
    BACKUP_DIR.mkdir(exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    path = BACKUP_DIR / f"tcity-{stamp}.sql"
    tmp = path.with_suffix(".sql.tmp")
    with tmp.open("wb") as handle:
        handle.write(payload)
        handle.flush()
        os.fsync(handle.fileno())
    tmp.replace(path)          # 原子替换：中途被杀不会留下半截 .sql
    manifest = BACKUP_DIR / f"tcity-{stamp}.json"
    manifest.write_text(json.dumps({
        "file": path.name,
        "bytes": len(payload),
        "sha256": hashlib.sha256(payload).hexdigest(),
        "tables": table_count(payload),
        "created_at": datetime.now().isoformat(timespec="seconds"),
    }, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    return path


def prune(keep: int) -> list[str]:
    backups = sorted(BACKUP_DIR.glob("tcity-*.sql"), key=lambda path: path.stat().st_mtime, reverse=True)
    removed = []
    for path in backups[keep:]:
        path.unlink(missing_ok=True)
        path.with_suffix(".json").unlink(missing_ok=True)
        removed.append(path.name)
    return removed


def list_backups() -> int:
    if not BACKUP_DIR.exists():
        print("[backup] 还没有任何备份")
        return 0
    rows = sorted(BACKUP_DIR.glob("tcity-*.sql"), key=lambda path: path.stat().st_mtime, reverse=True)
    for path in rows:
        meta = path.with_suffix(".json")
        info = json.loads(meta.read_text(encoding="utf-8")) if meta.exists() else {}
        print(f"{path.name}  {path.stat().st_size / 1024:.0f} KB  表 {info.get('tables', '?')}  "
              f"{info.get('created_at', '')}")
    print(f"共 {len(rows)} 份，目录 {BACKUP_DIR}")
    return 0


def restore(source: Path, scratch: bool) -> int:
    """恢复演练：默认恢复到 `<db>_restore_probe`，绝不覆盖正在用的库。"""
    if not source.exists():
        print(f"[backup] 找不到 {source}", file=sys.stderr)
        return 2
    _, user, password, database = connection()
    target = f"{database}_restore_probe" if scratch else database
    if target == database:
        print("[backup] 拒绝直接恢复到生产库：请先 --to-scratch 演练，确认后再手工切库", file=sys.stderr)
        return 2

    create = subprocess.run(
        ["docker", "exec", "-i", "-e", "MYSQL_PWD", CONTAINER,
         "mariadb", f"-u{user}", "-e",
         f"DROP DATABASE IF EXISTS {target}; CREATE DATABASE {target} CHARACTER SET utf8mb4;"],
        capture_output=True, text=True, env={**os.environ, "MYSQL_PWD": password},
    )
    if create.returncode != 0:
        print(f"[backup] 建库失败：{create.stderr[:300]}", file=sys.stderr)
        return 1

    load = subprocess.run(
        ["docker", "exec", "-i", "-e", "MYSQL_PWD", CONTAINER,
         "mariadb", f"-u{user}", target],
        input=source.read_bytes(), capture_output=True, env={**os.environ, "MYSQL_PWD": password},
    )
    if load.returncode != 0:
        print(f"[backup] 恢复失败：{(load.stderr or b'').decode('utf-8', 'ignore')[:300]}", file=sys.stderr)
        return 1

    check = subprocess.run(
        ["docker", "exec", "-i", "-e", "MYSQL_PWD", CONTAINER,
         "mariadb", f"-u{user}", "-N", "-e",
         "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE();", target],
        capture_output=True, text=True, env={**os.environ, "MYSQL_PWD": password},
    )
    tables = (check.stdout or "").strip()
    print(f"[backup] 恢复演练完成：{source.name} → {target}，表数 {tables}")
    print(f"[backup] 确认无误后可以删掉演练库：DROP DATABASE {target};")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="数据库备份 / 恢复演练")
    parser.add_argument("--keep", type=int, default=DEFAULT_KEEP, help="保留几份（默认 7）")
    parser.add_argument("--list", action="store_true", help="列出已有备份")
    parser.add_argument("--restore", type=Path, default=None, help="恢复到演练库")
    parser.add_argument("--to-scratch", action="store_true", help="恢复到 <db>_restore_probe")
    args = parser.parse_args(argv)

    if args.list:
        return list_backups()

    if not docker_available():
        print("[backup] 没有 docker（或引擎没起）", file=sys.stderr)
        return 2
    if not container_running():
        print(f"[backup] 容器 {CONTAINER} 没在跑：先 docker start {CONTAINER}", file=sys.stderr)
        return 2

    if args.restore:
        return restore(args.restore, scratch=args.to_scratch)

    _, _, _, database = connection()
    payload = dump(database)
    path = write_backup(payload)
    removed = prune(args.keep)
    print(f"[backup] {path.name}  {len(payload) / 1024:.0f} KB  表 {table_count(payload)}"
          + (f"  清理旧文件 {len(removed)} 份" if removed else ""))
    print("[backup] 提醒：备份没演练过等于没有。跑一次 `--restore <file> --to-scratch`")
    return 0


if __name__ == "__main__":
    sys.exit(main())
