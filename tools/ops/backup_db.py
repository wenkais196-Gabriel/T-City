#!/usr/bin/env python3
"""数据库每日备份：mysqldump + 保留策略。

用法::

    python3 tools/ops/backup_db.py --dry-run     # 只打印将执行的命令
    python3 tools/ops/backup_db.py               # 真跑，落到 ~/backups/tcity/daily
    python3 tools/ops/backup_db.py --keep-days 14

设计约束（都是踩过或会踩的坑）：

* **口令不进 argv**：``ps aux`` 和 shell history 都能看到命令行，所以口令只经
  ``MYSQL_PWD`` 环境变量传给子进程；
* **失败要响**：``mysqldump`` 非 0 或产出 0 字节（磁盘满时就会）都返回非 0 并删掉半截文件
  —— 否则 cron 里静默失败，等到要恢复时才发现每天都是空壳；
* **当天文件永不删**：保留策略按文件名和 mtime 判断，只碰 ``tcity-*.sql.gz``。

退出码：0 成功 / 1 备份失败 / 2 配置或环境错误。
"""
from __future__ import annotations

import argparse
import fnmatch
import gzip
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BASE = REPO / "T-CityLite.base"
DEFAULT_CFG = BASE / "server.cfg"
DEFAULT_DEST = Path.home() / "backups" / "tcity"

URL_RE = re.compile(r"mysql://([^:]+):([^@]*)@([^/]+)/([^?\"']+)")
DUMP_NAME = "tcity-*.sql.gz"


def find_connection_string(cfg_text: str) -> str | None:
    """从 server.cfg 里取出 mysql 连接串（不校验口令强度，只取值）。"""
    match = URL_RE.search(cfg_text)
    return match.group(0) if match else None


def parse_mysql_url(url: str) -> dict:
    match = URL_RE.match(url)
    if not match:
        raise ValueError(f"无法解析连接串（需要 mysql://user:pass@host/db）: {mask_url(url)}")
    user, password, hostport, database = match.groups()
    host, _, port = hostport.partition(":")
    return {
        "user": user,
        "password": password,
        "host": host or "localhost",
        "port": port or "3306",
        "database": database,
    }


def mask_url(url: str) -> str:
    """日志和报错里只留 user@host/db，口令替换成 ***。"""
    match = URL_RE.search(url)
    if not match:
        return "<无法解析的连接串>"
    user, _password, hostport, database = match.groups()
    return f"mysql://{user}:***@{hostport}/{database}"


def build_dump_argv(conn: dict, out_path: Path) -> list[str]:
    """构造 mysqldump 参数。**口令不在其中**，由调用方经环境变量传入。"""
    return [
        "mysqldump",
        "-u",
        conn["user"],
        "-h",
        conn["host"],
        "-P",
        str(conn["port"]),
        "--single-transaction",   # InnoDB 一致性快照，不锁表
        "--routines",
        "--events",
        "--default-character-set=utf8mb4",
        "-r",
        str(out_path),
        conn["database"],
    ]


def plan_retention(files: list[Path], now: datetime, keep_days: int) -> list[Path]:
    """返回应当删除的文件。只认 ``tcity-*.sql.gz``，按 mtime 判过期。"""
    doomed: list[Path] = []
    for path in files:
        if not fnmatch.fnmatch(path.name, DUMP_NAME):
            continue
        try:
            age_days = (now - datetime.fromtimestamp(path.stat().st_mtime)).total_seconds() / 86400
        except OSError:
            continue
        if age_days > keep_days:
            doomed.append(path)
    return doomed


def _gzip_file(src: Path, dst: Path) -> int:
    """压缩并返回写入的原始字节数（用于判断是否空 dump）。"""
    written = 0
    with src.open("rb") as fin, gzip.open(dst, "wb", compresslevel=6) as fout:
        while True:
            chunk = fin.read(1024 * 1024)
            if not chunk:
                break
            written += len(chunk)
            fout.write(chunk)
    return written


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="T-City Lite 数据库备份")
    parser.add_argument("--cfg", default=str(DEFAULT_CFG), help="server.cfg 路径（读连接串）")
    parser.add_argument("--dest", default=str(DEFAULT_DEST), help="备份根目录")
    parser.add_argument("--keep-days", type=int, default=7, help="每日备份保留天数")
    parser.add_argument("--dry-run", action="store_true", help="只打印命令，不执行、不落盘")
    parser.add_argument("--no-retention", action="store_true", help="本次不清理旧备份")
    args = parser.parse_args(argv)

    cfg_path = Path(args.cfg)
    if not cfg_path.is_file():
        print(f"[backup] 找不到配置文件: {cfg_path}", file=sys.stderr)
        return 2

    url = find_connection_string(cfg_path.read_text(encoding="utf-8", errors="ignore"))
    if not url:
        print(f"[backup] {cfg_path} 里没有 mysql:// 连接串", file=sys.stderr)
        return 2
    try:
        conn = parse_mysql_url(url)
    except ValueError as exc:
        print(f"[backup] {exc}", file=sys.stderr)
        return 2

    dest = Path(args.dest).expanduser()
    daily = dest / "daily"
    stamp = datetime.now().strftime("%Y-%m-%d_%H%M")
    final = daily / f"tcity-{stamp}.sql.gz"
    staging = daily / f".tmp-{stamp}.sql"
    argv_dump = build_dump_argv(conn, staging)

    print(f"[backup] 目标: {mask_url(url)} → {final}")
    if args.dry_run:
        print(f"[backup] dry-run，将执行: {' '.join(argv_dump)}")
        print("[backup] dry-run，将保留最近 "
              f"{args.keep_days} 天的每日备份")
        return 0

    daily.mkdir(parents=True, exist_ok=True)
    if shutil.which("mysqldump") is None:
        print("[backup] 找不到 mysqldump（安装 mysql-client）", file=sys.stderr)
        return 2

    env = dict(os.environ)
    env["MYSQL_PWD"] = conn["password"]
    try:
        proc = subprocess.run(argv_dump, capture_output=True, env=env)
    except OSError as exc:
        print(f"[backup] 启动 mysqldump 失败: {exc}", file=sys.stderr)
        return 2

    if proc.returncode != 0:
        detail = (proc.stderr or b"").decode("utf-8", errors="replace").strip()
        print(f"[backup] mysqldump 失败（退出码 {proc.returncode}）: {detail}", file=sys.stderr)
        staging.unlink(missing_ok=True)
        return 1

    if not staging.is_file() or staging.stat().st_size == 0:
        print("[backup] dump 是空文件（磁盘满或权限问题？），按失败处理", file=sys.stderr)
        staging.unlink(missing_ok=True)
        return 1

    size = _gzip_file(staging, final)
    staging.unlink(missing_ok=True)
    if final.stat().st_size == 0 or size == 0:
        final.unlink(missing_ok=True)
        print("[backup] 压缩后为空，按失败处理", file=sys.stderr)
        return 1

    print(f"[backup] OK {final.name}（原始 {size / 1024 / 1024:.1f} MB）")

    if not args.no_retention:
        doomed = plan_retention(list(daily.glob("*.sql.gz")), now=datetime.now(), keep_days=args.keep_days)
        for path in doomed:
            path.unlink(missing_ok=True)
            print(f"[backup] 清理过期备份 {path.name}")
        if not doomed:
            print(f"[backup] 保留策略：无过期文件（保留 {args.keep_days} 天）")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
