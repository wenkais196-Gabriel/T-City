#!/usr/bin/env python3
"""只读 SQL 查询（玩法验证取证用）。

从 `server.cfg` 的 `mysql_connection_string` 解析出库名/账号（口令只进子进程环境，不进 argv、
不打印），走 `docker exec` 里的 mariadb 客户端执行。**只允许读**：语句必须以 SELECT / SHOW /
DESCRIBE / EXPLAIN 开头，其它一律拒绝 —— 这个工具是取证用的，不是运维入口。

    python3 tools/dev/db_query.py "SELECT citizenid, money FROM players LIMIT 3"
    python3 tools/dev/db_query.py --table players        # 表名 + 行数 + 列
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SERVER_CFG = REPO / "T-CityLite.base" / "server.cfg"
CONTAINER = "tcity-mariadb"

READ_ONLY = ("select", "show", "describe", "desc", "explain", "with")


def parse_dsn(text: str) -> dict[str, str]:
    match = re.search(
        r'set\s+mysql_connection_string\s+"mysql://([^:]+):([^@]+)@([^/]+)/([^?"]+)',
        text,
    )
    if not match:
        raise SystemExit("server.cfg 里没有可解析的 mysql_connection_string")
    user, password, host, database = match.groups()
    return {"user": user, "password": password, "host": host, "database": database}


def run_sql(database: str, user: str, password: str, sql: str) -> str:
    if not shutil.which("docker"):
        raise SystemExit("找不到 docker")
    command = [
        "docker", "exec", "-i", "-e", "MYSQL_PWD", CONTAINER,
        "mariadb", f"-u{user}", "-D", database, "--batch", "--raw",
    ]
    result = subprocess.run(
        command, input=sql, capture_output=True, text=True, timeout=120,
        env={"MYSQL_PWD": password, "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"},
    )
    if result.returncode != 0:
        raise SystemExit(f"SQL 失败：{result.stderr.strip()[:400]}")
    return result.stdout


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="只读 SQL 查询")
    parser.add_argument("sql", nargs="?", default="")
    parser.add_argument("--table", help="列出该表的结构与行数")
    parser.add_argument("--cfg", default=str(SERVER_CFG))
    args = parser.parse_args(argv)

    cfg_path = Path(args.cfg)
    if not cfg_path.exists():
        raise SystemExit(f"找不到 {cfg_path}")
    dsn = parse_dsn(cfg_path.read_text(encoding="utf-8", errors="ignore"))

    if args.table:
        table = args.table
        if not re.fullmatch(r"[A-Za-z0-9_]+", table):
            raise SystemExit("表名只能是字母数字下划线")
        print(run_sql(dsn["database"], dsn["user"], dsn["password"], f"SHOW COLUMNS FROM {table};"))
        print(run_sql(dsn["database"], dsn["user"], dsn["password"], f"SELECT COUNT(*) AS row_count FROM {table};"))
        return 0

    sql = args.sql.strip().rstrip(";")
    if not sql:
        raise SystemExit("给一条 SELECT，或 --table <表名>")
    if sql.split()[0].lower() not in READ_ONLY:
        raise SystemExit("只允许只读语句（SELECT / SHOW / DESCRIBE / EXPLAIN / WITH）")
    print(run_sql(dsn["database"], dsn["user"], dsn["password"], sql + ";"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
