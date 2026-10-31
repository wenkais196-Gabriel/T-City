#!/usr/bin/env python3
"""AI 调度员 MVP —— 「agent 拿内容 → 解析 → 落成 call 卡草稿」。

分工刻意划在这里：
  * 脚本只负责**取内容**（短信/收件箱文件）和**提交草稿**（走 custom-director 的
    `police_call_draft` 动作，L2 审批）；
  * **解析由 agent（LLM）做** —— 脚本不猜、不套模板，把原文原样交出去，
    由模型产出 `title / details / code / priority`。

用法：
    # 1) 取待处理内容（默认读 phone_messages，按游标增量）
    python tools/agent/dispatch_mvp.py fetch --limit 10 > inbox.json

    # 2) agent 解析 inbox.json，写出 parsed.json（结构见下）

    # 3) 提交草稿（默认只 propose，落在草稿箱等人采纳）
    python tools/agent/dispatch_mvp.py submit parsed.json

parsed.json 结构：
    [
      {"source_id": 12,
       "title": "南区加油站有人持刀",
       "details": "单人，黑色外套，站在 3 号加油机旁",
       "code": "10-32",
       "priority": 2,
       "confidence": "high"}          # 可选，仅写进 details 备注
    ]

设计约束（与仓库规矩一致）：
  * 幂等键按来源 id 生成 —— 同一条短信重复提交不会产生第二张卡；
  * 默认**不审批**：草稿必须由警员在 MDT 里采纳；
  * `--approve` 只在自测时用，需要 admin token；
  * 令牌只从本地 server.cfg 读，不打印、不落盘。
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys
import urllib.error
import urllib.request

CFG = pathlib.Path("T-CityLite.base/server.cfg")
CURSOR = pathlib.Path.home() / "AppData/Local/hermes/cache/scratch/dispatch_mvp_cursor.json"
BASE = "http://127.0.0.1:30130/custom-director"
CONTAINER = "tcity-mariadb"
DB_NAME = "TCityLite"


def convar(name: str) -> str | None:
    if not CFG.exists():
        return None
    src = CFG.read_text(encoding="utf-8", errors="ignore")
    m = re.search(r'^\s*set(?:r)?\s+%s\s+"([^"]+)"' % re.escape(name), src, re.M)
    return m.group(1) if m else None


def mysql_password() -> str:
    line = [l for l in CFG.read_text(encoding="utf-8", errors="ignore").splitlines()
            if l.startswith("set mysql_connection_string")][0]
    m = re.search(r"mysql://([^:]+):([^@]+)@([^/]+)/([^?\"']+)", line)
    if m is None:
        sys.exit("server.cfg 里的 mysql_connection_string 解析不出密码")
    return m.group(2)


def query(sql: str) -> list[dict]:
    """跑一条 SELECT，返回行字典。表头由 --batch 输出首行给出。"""
    cmd = ["docker", "exec", "-e", f"MYSQL_PWD={mysql_password()}", CONTAINER,
           "mariadb", "-u", "root", "-h", "127.0.0.1", DB_NAME, "--batch", "-e", sql]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"db error: {out.stderr.strip()[:200]}")
    lines = out.stdout.rstrip("\n").split("\n")
    if len(lines) < 2:
        return []
    head = lines[0].split("\t")
    return [dict(zip(head, line.split("\t"))) for line in lines[1:]]


def load_cursor() -> int:
    if CURSOR.exists():
        try:
            return int(json.loads(CURSOR.read_text(encoding="utf-8")).get("last_id", 0))
        except Exception:
            return 0
    return 0


def save_cursor(value: int) -> None:
    CURSOR.parent.mkdir(parents=True, exist_ok=True)
    CURSOR.write_text(json.dumps({"last_id": value}), encoding="utf-8")


def cmd_fetch(args) -> None:
    since = args.since if args.since is not None else load_cursor()
    rows = query(
        "SELECT id, sender_number, message, DATE_FORMAT(timestamp, '%Y-%m-%d %H:%i') AS at "
        f"FROM phone_messages WHERE id > {int(since)} ORDER BY id ASC LIMIT {int(args.limit)};")
    # 只交原文：解析是 agent 的事，脚本不预判内容
    print(json.dumps({"since": since, "count": len(rows), "items": rows}, ensure_ascii=False, indent=2))


def post(path: str, body: dict, token: str) -> tuple[int, dict]:
    req = urllib.request.Request(BASE + path, data=json.dumps(body).encode(), method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("X-Agent-Id", convar("agent_actions_agent_id") or "mcp.local")
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        raw = e.read() or b"{}"
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"raw": raw[:200].decode("utf-8", "replace")}


def cmd_submit(args) -> None:
    agent = convar("agent_actions_token")
    admin = convar("agent_actions_admin_token")
    if not agent:
        sys.exit("server.cfg 里没有 agent_actions_token，无法提交")

    cards = json.loads(pathlib.Path(args.file).read_text(encoding="utf-8"))
    if isinstance(cards, dict):
        cards = cards.get("cards", [])
    results, max_id = [], load_cursor()

    for card in cards:
        source_id = int(card.get("source_id") or 0)
        args_body = {
            "title": card["title"],
            "details": card.get("details", ""),
            "code": card.get("code", "911"),
            "priority": int(card.get("priority", 2)),
        }
        if card.get("raw_text"):
            args_body["raw_text"] = card["raw_text"]
        key = f"dispatch_mvp/{source_id or abs(hash(card['title'])) % 100000}/{args_body['code']}"

        status, body = post("/agent/v1/act",
                            {"type": "police_call_draft", "args": args_body, "idempotency_key": key},
                            agent)
        row = {"source_id": source_id, "propose": status, "doc_id": body.get("id"),
               "status": body.get("status"), "code": body.get("code")}

        if args.approve and body.get("id") and admin:
            status2, body2 = post(f"/agent/v1/actions/{body['id']}/approve",
                                 {"approver": "dev:dispatch-mvp"}, admin)
            row.update({"approve": status2, "result": body2.get("result") or body2.get("error")})
        results.append(row)
        max_id = max(max_id, source_id)

    print(json.dumps({"submitted": len(results), "results": results}, ensure_ascii=False, indent=2))
    if args.advance_cursor and max_id:
        save_cursor(max_id)


def main() -> None:
    ap = argparse.ArgumentParser(description="AI 调度员 MVP：取内容 / 提交草稿")
    sub = ap.add_subparsers(dest="cmd", required=True)

    f = sub.add_parser("fetch", help="取待处理内容（增量，按游标）")
    f.add_argument("--limit", type=int, default=10)
    f.add_argument("--since", type=int, default=None, help="覆盖游标（调试用）")

    s = sub.add_parser("submit", help="提交解析后的 call 卡草稿")
    s.add_argument("file")
    s.add_argument("--approve", action="store_true", help="自测用：提交后立刻审批（需要 admin token）")
    s.add_argument("--advance-cursor", action="store_true", help="提交成功后把游标推到最后一条")

    args = ap.parse_args()
    {"fetch": cmd_fetch, "submit": cmd_submit}[args.cmd](args)


if __name__ == "__main__":
    main()
