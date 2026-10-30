#!/usr/bin/env python3
"""支援单位的指标面板 —— 全部从 `police_audit` 聚合，不新增表。

回答四个问题（每个都能落到一条 SQL）：

  1. 请求成功率：`backup.spawned / backup.request`
  2. 到场/生成耗时：`backup.spawned` 的 `took=` 字段
  3. 平均存活：`backup.ended` / `backup.expired` 的 `live=` 字段
  4. 异常率：`spawn_failed | vehicle_lost | no_alive_ped | unknown` 占比 + `ack_rejected` 计数

用法：
    export TCITY_LIVE_TOKEN=...            # 不需要，但保持与其它工具一致
    python3 tools/dev/police_backup_metrics.py                 # 最近 24 小时
    python3 tools/dev/police_backup_metrics.py --hours 168     # 最近一周
    python3 tools/dev/police_backup_metrics.py --json          # 机读
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

# 「异常」只统计"单位本身没干成事"：生成失败、车丢了、NPC 全灭、未知原因、开不到人身边。
# dead / left / timeout / dismissed 是玩家侧的正常收尾（玩家死了、走远了、到点、主动撤回），
# 混进来会让异常率永远虚高。
ABNORMAL_REASONS = {"spawn_failed", "vehicle_lost", "no_alive_ped", "unknown", "escort_timeout"}


def mysql_dsn() -> tuple[str, str, str]:
    """(user, password, database) —— 与 police_live_probe 共用 server.cfg 的解析。"""
    from police_live_probe import mysql_dsn as probe_dsn

    user, password, _hostport, database = probe_dsn()
    return user, password, database


def fetch_rows(hours: int) -> list[list[str]]:
    user, password, database = mysql_dsn()
    container = os.environ.get("TCITY_DB_CONTAINER", "tcity-mariadb")
    sql = (
        "select action, target, detail, created_at from police_audit "
        "where action like 'backup.%' "
        f"and created_at >= date_sub(now(), interval {int(hours)} hour) "
        "order by id desc limit 5000;"
    )
    env = dict(os.environ)
    env["MYSQL_PWD"] = password
    result = subprocess.run(
        ["docker", "exec", "-e", f"MYSQL_PWD={password}", container,
         "mariadb", "-u", user, "-h", "127.0.0.1", database, "-e", sql],
        capture_output=True, text=True, env=env, timeout=45,
    )
    if result.returncode != 0:
        raise SystemExit(f"审计查询失败：{result.stderr.strip()[:200]}")
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    return [line.split("\t") for line in lines[1:]]


def _detail_value(detail: str, key: str) -> str | None:
    match = re.search(rf"{re.escape(key)}=([^;]+)", detail or "")
    return match.group(1) if match else None


def _detail_int(detail: str, key: str) -> int | None:
    raw = _detail_value(detail, key)
    try:
        return int(raw) if raw is not None else None
    except ValueError:
        return None


def summarize(rows: list[list[str]]) -> dict:
    """把审计行折叠成指标。纯函数：不碰数据库，单测直接喂行。"""
    counts: dict[str, int] = {}
    reasons: dict[str, int] = {}
    expiry_whys: dict[str, int] = {}
    live_seconds: list[int] = []
    spawn_seconds: list[int] = []
    phases_seen: dict[str, int] = {}

    for row in rows:
        if len(row) < 3:
            continue
        action = row[0].strip()
        detail = row[2] if len(row) > 2 else ""
        counts[action] = counts.get(action, 0) + 1

        if action in ("backup.ended",):
            reason = _detail_value(detail, "reason") or "unknown"
            reasons[reason] = reasons.get(reason, 0) + 1
            live = _detail_int(detail, "live")
            if live is not None:
                live_seconds.append(live)
        elif action == "backup.expired":
            why = _detail_value(detail, "why") or "unknown"
            expiry_whys[why] = expiry_whys.get(why, 0) + 1
            phase = _detail_value(detail, "phase")
            if phase:
                phases_seen[phase] = phases_seen.get(phase, 0) + 1
            live = _detail_int(detail, "live")
            if live is not None:
                live_seconds.append(live)
        elif action == "backup.spawned":
            took = _detail_int(detail, "took")
            if took is not None:
                spawn_seconds.append(took)

    requests = counts.get("backup.request", 0)
    spawned = counts.get("backup.spawned", 0)
    ended = counts.get("backup.ended", 0)
    expired = counts.get("backup.expired", 0)

    abnormal = sum(reasons.get(reason, 0) for reason in ABNORMAL_REASONS)

    def ratio(numerator: int, denominator: int) -> float | None:
        return round(numerator / denominator, 3) if denominator else None

    def average(values: list[int]) -> float | None:
        return round(sum(values) / len(values), 1) if values else None

    return {
        "requests": requests,
        "spawned": spawned,
        "ended": ended,
        "expired": expired,
        "ack_rejected": counts.get("backup.ack_rejected", 0),
        "engaged": counts.get("backup.engaged", 0),
        "spawn_rate": ratio(spawned, requests),
        "end_rate": ratio(ended, requests),
        "abnormal_rate": ratio(abnormal, requests),
        "avg_live_seconds": average(live_seconds),
        "avg_spawn_seconds": average(spawn_seconds),
        "end_reasons": dict(sorted(reasons.items(), key=lambda item: -item[1])),
        "expiry_whys": dict(sorted(expiry_whys.items(), key=lambda item: -item[1])),
        "expiry_phases": dict(sorted(phases_seen.items(), key=lambda item: -item[1])),
    }


def render(metrics: dict, hours: int) -> str:
    lines = [f"支援指标（最近 {hours} 小时，来源 police_audit）", ""]
    lines.append(f"  请求         {metrics['requests']}")
    lines.append(f"  生成成功     {metrics['spawned']}  （成功率 {metrics['spawn_rate']}）")
    lines.append(f"  正常结束     {metrics['ended']}  （{metrics['end_rate']}）")
    lines.append(f"  服务端过期   {metrics['expired']}")
    lines.append(f"  异常结束     {metrics['abnormal_rate']}")
    lines.append(f"  平均存活     {metrics['avg_live_seconds']} 秒")
    lines.append(f"  平均生成     {metrics['avg_spawn_seconds']} 秒")
    lines.append(f"  交战过的单   {metrics['engaged']}")
    lines.append(f"  ack 被拒     {metrics['ack_rejected']}")
    if metrics["end_reasons"]:
        lines.append("")
        lines.append("  结束原因分布：")
        for reason, count in metrics["end_reasons"].items():
            lines.append(f"    {reason:<16} {count}")
    if metrics["expiry_whys"]:
        lines.append("")
        lines.append("  服务端过期原因：")
        for why, count in metrics["expiry_whys"].items():
            lines.append(f"    {why:<24} {count}")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--hours", type=int, default=24)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    metrics = summarize(fetch_rows(args.hours))
    if args.json:
        print(json.dumps({"hours": args.hours, "metrics": metrics}, ensure_ascii=False, indent=2))
    else:
        print(render(metrics, args.hours))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
