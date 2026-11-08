#!/usr/bin/env python3
"""把 migrations/ 下全部迁移对一个**干净库**连跑两遍，证明它们可重复执行（P2-3）。

为什么用 `docker exec mariadb` 而不是驱动：迁移里有 `CREATE TRIGGER … BEGIN … END`
（体内带分号）。用 Python 驱动就要自己实现 SQL 切分器 —— 注释里的分号、触发器体里的分号、
`SELECT` 未取结果（`Unread result found`）三件事都要各自兜一遍，而 CLI 本来就处理好了。
这里只做"跑两遍、收集错误"，判据简单，失败信息直接来自服务端。

前置：`tcity-mariadb` 容器在跑（`docker start tcity-mariadb`），口令从 `server.cfg` 的
`mysql_connection_string` 解析（**不打印**）。

用法::

    python3 tools/dev/migrations_double_apply.py            # 跑两遍并出结论
    python3 tools/dev/migrations_double_apply.py --keep-db  # 跑完保留库，便于手工查看

退出码：0 = 两遍都 0 错误；1 = 有错误或环境不对。
"""

from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
BASE = REPO / "T-CityLite.base"
CFG = BASE / "server.cfg"
MIGRATIONS = BASE / "migrations"
SEED = BASE / "tests" / "fixtures" / "tcity_schema.sql"
SCRATCH_DB = "tcity_mig_probe"
CONTAINER = "tcity-mariadb"


class EnvironmentBroken(RuntimeError):
    """容器/口令/客户端不可用 —— 调用方据此 skip 而不是报错。"""


def credentials() -> tuple[str, str]:
    if not CFG.exists():
        raise EnvironmentBroken(f"找不到 {CFG}（server.cfg 是 gitignored，只有运行树里有）")
    line = next(
        (line for line in CFG.read_text(encoding="utf-8", errors="ignore").splitlines()
         if "mysql_connection_string" in line),
        None,
    )
    if not line:
        raise EnvironmentBroken("server.cfg 里没有 mysql_connection_string")
    match = re.search(r"mysql://([^:]+):([^@]+)@", line)
    if not match:
        raise EnvironmentBroken("mysql_connection_string 不是 mysql://user:pass@host 形式")
    return match.group(1), match.group(2)


def container_running() -> bool:
    try:
        out = subprocess.run(["docker", "inspect", "-f", "{{.State.Running}}", CONTAINER],
                             capture_output=True, text=True, timeout=20)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False
    return out.returncode == 0 and out.stdout.strip() == "true"


def client_binary() -> str:
    out = subprocess.run(["docker", "exec", CONTAINER, "sh", "-c",
                          "command -v mariadb || command -v mysql"], capture_output=True, text=True)
    path = (out.stdout or "").strip().splitlines()
    if out.returncode != 0 or not path:
        raise EnvironmentBroken("容器里找不到 mariadb / mysql 客户端")
    return path[-1]


def run_sql(binary: str, user: str, password: str, database: str | None, stdin_text: str):
    args = ["docker", "exec", "-i", CONTAINER, binary, f"-u{user}", f"-p{password}", "--batch", "--raw"]
    if database:
        args.append(database)
    return subprocess.run(args, input=stdin_text, capture_output=True, text=True, timeout=300)


def double_apply(keep_db: bool = False) -> tuple[int, list[str]]:
    """返回 (成功遍数, 错误列表)。"""
    user, password = credentials()
    if not container_running():
        raise EnvironmentBroken(f"{CONTAINER} 没在跑（docker start {CONTAINER}）")
    binary = client_binary()

    created = run_sql(binary, user, password, None,
                      f"DROP DATABASE IF EXISTS {SCRATCH_DB}; "
                      f"CREATE DATABASE {SCRATCH_DB} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;")
    if created.returncode != 0:
        raise EnvironmentBroken(f"建库失败：{(created.stderr or '').strip()[:200]}")

    seeded = run_sql(binary, user, password, SCRATCH_DB, SEED.read_text(encoding="utf-8"))
    if seeded.returncode != 0:
        raise EnvironmentBroken(f"基线 schema 铺设失败：{(seeded.stderr or '').strip()[:200]}")

    files = sorted(MIGRATIONS.glob("*.sql"),
                   key=lambda path: [int(part) for part in re.match(r"^v([\d.]+)_", path.name).group(1).split(".")])
    errors: list[str] = []
    clean_passes = 0
    for attempt in (1, 2):
        pass_errors = []
        for path in files:
            result = run_sql(binary, user, password, SCRATCH_DB, path.read_text(encoding="utf-8"))
            if result.returncode != 0:
                first = (result.stderr or "").strip().splitlines()
                pass_errors.append(f"第 {attempt} 遍 {path.name}: {first[-1] if first else 'unknown'}")
        errors.extend(pass_errors)
        if not pass_errors:
            clean_passes += 1
        print(f"第 {attempt} 遍：{len(files) - len(pass_errors)}/{len(files)} 成功")

    if not keep_db:
        run_sql(binary, user, password, None, f"DROP DATABASE IF EXISTS {SCRATCH_DB};")
    return clean_passes, errors


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--keep-db", action="store_true", help="跑完保留探针库")
    args = parser.parse_args(argv)

    try:
        clean, errors = double_apply(keep_db=args.keep_db)
    except EnvironmentBroken as exc:
        print(f"环境不满足：{exc}", file=sys.stderr)
        return 1

    for line in errors:
        print(f"  ! {line}")
    print(f"结论：{clean}/2 遍无错误")
    return 0 if clean == 2 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
