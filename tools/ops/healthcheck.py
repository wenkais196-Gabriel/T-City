#!/usr/bin/env python3
"""启动自检：把「84 资源 / 0 SCRIPT ERROR」变成一条命令的退出码。

用法::

    python3 tools/ops/healthcheck.py                       # 默认读 /var/log/tcity/console.log
    python3 tools/ops/healthcheck.py --log /tmp/tcity.log  # 指定日志
    python3 tools/ops/healthcheck.py --json out.json       # 机器可读
    python3 tools/ops/healthcheck.py --skip-http --skip-db # 只查日志

退出码：0 全部通过 / 1 有失败项 / 2 参数或环境错误。

设计约束（为什么这么写）：

* **不猜**：每一项阈值都来自本仓库实测（84 个资源、74 张表、三条启动标记）。
  改了 ensure 清单或迁移数量，要同步改这里的默认值，否则自检会骗人。
* **失败要说原因**：每条失败是一句人能直接照着修的话，不是 ``False``。
* **可离线**：``--skip-http`` / ``--skip-db`` 让 CI 和单测能跑纯解析部分。
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BASE = REPO / "T-CityLite.base"

# 启动后必须出现的标记：少了任何一个，说明那个系统的代码根本没跑起来。
MARKERS = {
    "story-engine": "剧情引擎已启动",
    "police-p0": "P0 dispatch layer loaded",
    "quest-registry": "任务注册器已加载",
    # 玩家能接到任务 = quest 导出就绪 + 手机 App 注册成功，缺一条这条链路就断了
    "quest-entry": "手机任务入口已就绪",
    "quest-app": "quests app registered",
}

# 实测基线：85 条 ensure / 84 个 Started（[cfx-default] 里有几个不带脚本的资源）。
DEFAULT_MIN_RESOURCES = 84
DEFAULT_EXPECTED_TABLES = 74
DEFAULT_URL = "http://localhost:30120/info.json"

ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
STARTED_RE = re.compile(r"Started resource\s+(\S+)")
ERROR_RE = re.compile(r"SCRIPT ERROR")

# start.sh 每次启动都会打这一行；systemd 的日志是**追加**的，所以"上一次崩溃留下的
# SCRIPT ERROR"会和这次启动混在同一个文件里。自检只看最后一次启动之后的部分，
# 否则一条历史报错会让之后每次自检都红，人就开始忽略它了。
BOOT_RE = re.compile(r"T-City Lite 开发服务器")


def strip_ansi(text: str) -> str:
    """去掉 FiveM 控制台的 ANSI 颜色码（原始 console.log 里全是这些）。"""
    return ANSI_RE.sub("", text)


def parse_console(text: str) -> dict:
    """解析控制台日志，返回 ``started_count`` / ``script_errors`` / ``markers``。

    同一个资源重启一次会再打一行 ``Started resource``，所以按资源名去重；
    但 ``SCRIPT ERROR`` 是逐条累加的，重复的行也必须算进去。
    """
    clean = strip_ansi(text)
    boot = None
    for boot in BOOT_RE.finditer(clean):
        pass
    if boot is not None:
        clean = clean[boot.start():]
    started = set(STARTED_RE.findall(clean))
    stats = {
        "started": sorted(started),
        "started_count": len(started),
        "script_errors": len(ERROR_RE.findall(clean)),
        "license_429": "HTTP 429" in clean,
        "markers": {key: (needle in clean) for key, needle in MARKERS.items()},
    }
    return stats


def evaluate(
    stats: dict,
    http_ok: bool,
    db_ok: bool,
    tables: int | None,
    min_resources: int = DEFAULT_MIN_RESOURCES,
    expected_tables: int = DEFAULT_EXPECTED_TABLES,
    license_429: bool | None = None,
) -> list[str]:
    """把一份快照判成「失败原因列表」。空列表 = 健康。"""
    failures: list[str] = []
    if license_429 is None:
        license_429 = bool(stats.get("license_429"))
    if license_429:
        failures.append(
            "Cfx.re 的 license 校验返回了 429（启动太快太多次）：停机等 20-30 分钟再起，"  
            "期间每次尝试都会续命限流"
        )


    if stats.get("started_count", 0) < min_resources:
        failures.append(
            f"只启动了 {stats.get('started_count', 0)} 个资源，至少应有 {min_resources} 个"
            "（少了谁：看日志里的 Failed to start / Couldn't find resource）"
        )

    if stats.get("script_errors", 0) > 0:
        failures.append(
            f"日志里有 {stats['script_errors']} 条 SCRIPT ERROR（先修脚本错误，再谈功能）"
        )

    for key, present in (stats.get("markers") or {}).items():
        if not present:
            failures.append(f"启动标记缺失 {key}：{MARKERS.get(key, '')} 没打印，说明该系统的服务端代码没跑起来")

    if not http_ok:
        failures.append("30120 端口没有响应（HTTP /info.json 超时或连不上）")

    if not db_ok:
        failures.append("数据库连接失败（检查 server.cfg 的 mysql_connection_string 与 mysqld 状态）")
    elif tables is not None and tables != expected_tables:
        failures.append(
            f"数据库表数量是 {tables}，期望 {expected_tables}（迁移没跑全，或连错了库）"
        )

    return failures


def check_http(url: str = DEFAULT_URL, timeout: float = 3.0) -> bool:
    """打 /info.json。用 urllib 而不是 curl，少一个外部依赖。"""
    import urllib.error
    import urllib.request

    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:  # noqa: S310 - 本机地址
            body = resp.read(2048)
        return resp.status == 200 and body.startswith(b"{")
    except (urllib.error.URLError, OSError, ValueError):
        return False


def _read_connection_string(cfg: Path) -> str | None:
    if not cfg.is_file():
        return None
    for line in cfg.read_text(encoding="utf-8", errors="ignore").splitlines():
        if "mysql://" in line:
            start = line.find("mysql://")
            end = line.find('"', start)
            return line[start:end] if end != -1 else line[start:].strip()
    return None


def check_db(timeout: int = 5) -> tuple[bool, int | None]:
    """连库并数表。返回 ``(是否连上, 表数量)``。"""
    url = _read_connection_string(BASE / "server.cfg")
    if not url:
        return False, None

    match = re.match(r"mysql://([^:]+):([^@]*)@([^/]+)/([^?]+)", url)
    if not match:
        return False, None
    user, password, host, database = match.groups()

    env = {"MYSQL_PWD": password, "PATH": "/usr/local/bin:/usr/bin:/bin"}
    sql = (
        "SELECT COUNT(*) FROM information_schema.TABLES "
        f"WHERE TABLE_SCHEMA='{database}'"
    )
    try:
        proc = subprocess.run(
            ["mysql", "-u", user, "-h", host.split(":")[0], "-N", "-B", "-e", sql],
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False, None
    if proc.returncode != 0:
        return False, None
    try:
        return True, int(proc.stdout.strip().splitlines()[0])
    except (IndexError, ValueError):
        return False, None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="T-City Lite 启动自检")
    parser.add_argument("--log", default="/var/log/tcity/console.log", help="控制台日志路径")
    parser.add_argument("--url", default=DEFAULT_URL, help="HTTP 探活地址")
    parser.add_argument("--min-resources", type=int, default=DEFAULT_MIN_RESOURCES)
    parser.add_argument("--expected-tables", type=int, default=DEFAULT_EXPECTED_TABLES)
    parser.add_argument("--skip-http", action="store_true", help="不探 HTTP（离线/单测用）")
    parser.add_argument("--skip-db", action="store_true", help="不连库（离线/单测用）")
    parser.add_argument("--json", dest="json_path", default=None, help="把结果写成 JSON")
    args = parser.parse_args(argv)

    log_path = Path(args.log)
    if not log_path.is_file():
        print(f"[healthcheck] 日志不存在: {log_path}", file=sys.stderr)
        print("[healthcheck] 提示: systemd 部署后日志在 /var/log/tcity/console.log；"
              "临时启动时用 --log /tmp/tcity_console.log", file=sys.stderr)
        return 2

    stats = parse_console(log_path.read_text(encoding="utf-8", errors="ignore"))
    http_ok = True if args.skip_http else check_http(args.url)
    if args.skip_db:
        db_ok, tables = True, None
    else:
        db_ok, tables = check_db()

    failures = evaluate(
        stats,
        http_ok=http_ok,
        db_ok=db_ok,
        license_429=stats.get("license_429", False),
        tables=tables,
        min_resources=args.min_resources,
        expected_tables=args.expected_tables,
    )

    report = {
        "ok": not failures,
        "failures": failures,
        "stats": stats,
        "http_ok": http_ok,
        "db_ok": db_ok,
        "tables": tables,
        "log": str(log_path),
    }
    if args.json_path:
        Path(args.json_path).write_text(
            json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
        )

    if failures:
        print(f"[healthcheck] 失败 {len(failures)} 项：")
        for item in failures:
            print(f"  - {item}")
        return 1

    print(
        "OK "
        f"资源 {stats['started_count']} 个 / "
        f"SCRIPT ERROR {stats['script_errors']} 条 / "
        f"标记 {len(stats['markers'])} 项齐全 / "
        f"表 {tables if tables is not None else '(跳过)'}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
