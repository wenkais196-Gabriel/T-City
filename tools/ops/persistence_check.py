#!/usr/bin/env python3
"""重启前后数据一致性对比：证明 kill -9 + 重启不丢钱、职业、物品、metadata。

用法::

    # 1) 重启前拍基线
    python3 tools/ops/persistence_check.py --take --out /tmp/persist-before.json

    # 2) 重启服务器

    # 3) 重启后对比
    python3 tools/ops/persistence_check.py --compare /tmp/persist-before.json

退出码：0 无差异 / 1 有差异 / 2 取数失败。

数据在哪（实测 schema，别按直觉猜）：

* 玩家：players(citizenid, money, job, metadata, inventory) —— 钱和职业是 JSON 文本，
  **玩家背包在 players.inventory**（不在 inventories 表里）；
* 容器：inventories(identifier, items) —— 汽车后备箱、公寓、组织仓库都在这，
  键是 glovebox-XXX / apartment… / policestash_<citizenid>，**不是 citizenid**。

设计约束：

* **行序无关**：DB 返回顺序不保证，比较一律按 citizenid / item 排序后再比，
  否则每天都假红，人就不看了；
* **缺失单独报**：重启后读不到某个 citizenid 是"数据丢了"，不是"数值变了"；
* **只读**：只 SELECT，不写任何东西。
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
URL_RE = re.compile(r"mysql://([^:]+):([^@]*)@([^/]+)/([^?\"']+)")

PLAYER_FIELDS = ("cash", "bank", "job", "job_grade", "onduty", "metadata")


def _creds():
    cfg = BASE / "server.cfg"
    if not cfg.is_file():
        return None
    match = URL_RE.search(cfg.read_text(encoding="utf-8", errors="ignore"))
    if not match:
        return None
    user, password, hostport, database = match.groups()
    return user, password, hostport.split(":")[0], database


def _mysql(sql, timeout=10):
    creds = _creds()
    if not creds:
        raise RuntimeError("server.cfg 里没有可用的 mysql 连接串")
    user, password, host, database = creds
    proc = subprocess.run(
        ["mysql", "-u", user, "-h", host, "-N", "-B", "-e", sql, database],
        capture_output=True,
        text=True,
        timeout=timeout,
        env={"MYSQL_PWD": password, "PATH": "/usr/local/bin:/usr/bin:/bin"},
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or "mysql 执行失败")
    return [line.split("\t") for line in proc.stdout.splitlines() if line]


def _json_obj(raw):
    try:
        value = json.loads(raw)
    except (ValueError, TypeError):
        return {}
    return value if isinstance(value, dict) else {}


def _json_items(raw):
    """items / inventory 列既可能是数组，也可能是 {slot: item} 字典。"""
    try:
        value = json.loads(raw)
    except (ValueError, TypeError):
        return []
    if isinstance(value, dict):
        value = list(value.values())
    return [item for item in value if isinstance(item, dict)]


def snapshot(players, items, stashes=None):
    """把玩家行、背包行、容器行压成可比较的快照。"""
    people = {}
    for row in players:
        citizenid = str(row["citizenid"])
        metadata = row.get("metadata") or {}
        if isinstance(metadata, str):
            metadata = _json_obj(metadata)
        people[citizenid] = {
            "cash": row.get("cash"),
            "bank": row.get("bank"),
            "job": row.get("job"),
            "job_grade": row.get("job_grade"),
            "onduty": row.get("onduty"),
            "metadata": {str(k): str(v) for k, v in sorted(metadata.items())},
        }

    inventory = {}
    for row in items:
        citizenid = str(row["citizenid"])
        name = str(row["item"])
        inventory.setdefault(citizenid, {})[name] = int(row.get("amount") or 0)

    stash_map = {}
    for row in stashes or []:
        identifier = str(row["identifier"])
        name = str(row["item"])
        stash_map.setdefault(identifier, {})[name] = int(row.get("amount") or 0)

    return {"players": people, "items": inventory, "stashes": stash_map}


def diff_snapshots(before, after):
    """逐字段比对，返回人话差异列表。空列表 = 数据没丢。"""
    diffs = []
    before_players = before.get("players", {})
    after_players = after.get("players", {})

    for citizenid in sorted(before_players):
        if citizenid not in after_players:
            diffs.append(f"{citizenid} 缺失：重启后读不到这名玩家（数据没落库）")
            continue
        old, new = before_players[citizenid], after_players[citizenid]
        for field in PLAYER_FIELDS:
            if old.get(field) != new.get(field):
                diffs.append(f"{citizenid}.{field}: {old.get(field)!r} → {new.get(field)!r}")

    before_items = before.get("items", {})
    after_items = after.get("items", {})
    for citizenid in sorted(set(before_items) | set(after_items)):
        old_items = before_items.get(citizenid, {})
        new_items = after_items.get(citizenid, {})
        for name in sorted(set(old_items) | set(new_items)):
            if old_items.get(name) != new_items.get(name):
                diffs.append(
                    f"{citizenid} 物品 {name}: {old_items.get(name, '无')} → {new_items.get(name, '无')}"
                )

    before_stash = before.get("stashes", {})
    after_stash = after.get("stashes", {})
    for identifier in sorted(set(before_stash) | set(after_stash)):
        old_items = before_stash.get(identifier, {})
        new_items = after_stash.get(identifier, {})
        for name in sorted(set(old_items) | set(new_items)):
            if old_items.get(name) != new_items.get(name):
                diffs.append(
                    f"容器 {identifier} 物品 {name}: "
                    f"{old_items.get(name, '无')} → {new_items.get(name, '无')}"
                )

    return diffs


def take():
    """从库里拍一份真实快照（只读）。"""
    players = []
    items = []

    for citizenid, money_raw, job_raw, metadata_raw, inventory_raw in _mysql(
        "SELECT citizenid, money, job, metadata, inventory FROM players"
    ):
        money = _json_obj(money_raw)
        job = _json_obj(job_raw)
        players.append(
            {
                "citizenid": citizenid,
                "cash": money.get("cash"),
                "bank": money.get("bank"),
                "job": job.get("name"),
                "job_grade": job.get("grade"),
                "onduty": job.get("onduty"),
                "metadata": metadata_raw,
            }
        )
        for entry in _json_items(inventory_raw or "[]"):
            items.append(
                {
                    "citizenid": citizenid,
                    "item": entry.get("name") or entry.get("item") or "unknown",
                    "amount": entry.get("amount") or entry.get("count") or 1,
                }
            )

    stashes = []
    for identifier, items_raw in _mysql("SELECT identifier, items FROM inventories"):
        for entry in _json_items(items_raw or "[]"):
            stashes.append(
                {
                    "identifier": identifier,
                    "item": entry.get("name") or entry.get("item") or "unknown",
                    "amount": entry.get("amount") or entry.get("count") or 1,
                }
            )

    return snapshot(players, items, stashes)


def main(argv=None):
    parser = argparse.ArgumentParser(description="重启前后玩家数据一致性对比")
    parser.add_argument("--take", action="store_true", help="拍快照")
    parser.add_argument("--compare", default=None, help="与基线快照比较")
    parser.add_argument("--out", default="/tmp/persist-snapshot.json", help="快照输出路径")
    args = parser.parse_args(argv)

    if not args.take and not args.compare:
        parser.print_help()
        return 2

    if args.take:
        try:
            snap = take()
        except (RuntimeError, OSError, subprocess.SubprocessError) as exc:
            print(f"[persistence] 取数失败: {exc}", file=sys.stderr)
            return 2
        Path(args.out).write_text(json.dumps(snap, ensure_ascii=False, indent=2), encoding="utf-8")
        print(
            f"[persistence] 已拍快照: {len(snap['players'])} 名玩家 / "
            f"{sum(len(v) for v in snap['items'].values())} 种背包物品 / "
            f"{len(snap['stashes'])} 个容器 → {args.out}"
        )
        return 0

    baseline_path = Path(args.compare)
    if not baseline_path.is_file():
        print(f"[persistence] 找不到基线: {baseline_path}", file=sys.stderr)
        return 2

    try:
        current = take()
    except (RuntimeError, OSError, subprocess.SubprocessError) as exc:
        print(f"[persistence] 取数失败: {exc}", file=sys.stderr)
        return 2

    baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
    diffs = diff_snapshots(baseline, current)
    if not diffs:
        print(f"OK 无差异（{len(current['players'])} 名玩家、背包与容器一致）")
        return 0

    print(f"[persistence] 发现 {len(diffs)} 处差异：")
    for item in diffs:
        print(f"  - {item}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
