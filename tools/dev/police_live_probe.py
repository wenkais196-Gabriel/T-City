#!/usr/bin/env python3
"""真机探针：一次打印「手机/客户端状态 + 资源数 + 最近的警察审计行」。

用途：写代码时每改一处，用它确认"现象真的变了"，而不是靠猜或看截图。
S1/S2 这类生命周期改动的验收全靠它（阶段、frame 栈、审计里的 reason）。

用法：
    export TCITY_LIVE_TOKEN=...                       # live token（只读）
    python3 tools/dev/police_live_probe.py            # 客户端状态 + 资源数
    python3 tools/dev/police_live_probe.py --audit 8  # 再追最近 8 行 backup.* 审计
    python3 tools/dev/police_live_probe.py --json     # 机读输出，便于脚本断言

审计查询读 server.cfg 里的 mysql 连接串（该文件不入库），容器名默认 tcity-mariadb。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

BASE = Path(__file__).resolve().parents[2] / "T-CityLite.base"
DEFAULT_API = "http://127.0.0.1:30130/custom-director/agent/v1"


def http_json(url: str, token: str) -> dict:
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(request, timeout=8) as response:
        return json.loads(response.read().decode("utf-8"))


def mysql_dsn() -> tuple[str, str, str, str]:
    for line in (BASE / "server.cfg").read_text(encoding="utf-8", errors="ignore").splitlines():
        if line.startswith("set mysql_connection_string"):
            match = re.search(r"mysql://([^:]+):([^@]+)@([^/]+)/([^?\"']+)", line)
            if match:
                user, password, hostport, database = match.groups()
                return user, password, hostport, database
    raise SystemExit("server.cfg 里找不到 mysql_connection_string")


def audit_rows(kind: str, limit: int) -> list[list[str]]:
    user, password, _hostport, database = mysql_dsn()
    container = os.environ.get("TCITY_DB_CONTAINER", "tcity-mariadb")
    sql = ("select id, action, target, detail, created_at from police_audit "
           f"where action like '{kind}%' order by id desc limit {limit};")
    env = dict(os.environ)
    env["MYSQL_PWD"] = password
    result = subprocess.run(
        ["docker", "exec", "-e", f"MYSQL_PWD={password}", container,
         "mariadb", "-u", user, "-h", "127.0.0.1", database, "-e", sql],
        capture_output=True, text=True, env=env, timeout=30,
    )
    if result.returncode != 0:
        raise SystemExit(f"审计查询失败：{result.stderr.strip()[:200]}")
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    return [line.split("\t") for line in lines[1:]]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--api", default=os.environ.get("TCITY_AGENT_API", DEFAULT_API))
    parser.add_argument("--token", default=os.environ.get("TCITY_LIVE_TOKEN", ""))
    parser.add_argument("--audit", type=int, default=0, help="追最近 N 条 backup.* 审计")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    if not args.token:
        raise SystemExit("缺少 TCITY_LIVE_TOKEN（live token 只读，放在 ~/.hermes/.tcity.env）")

    snapshot: dict = {}
    try:
        snapshot["clients"] = http_json(f"{args.api}/live/clients", args.token).get("clients") or []
    except urllib.error.URLError as exc:
        raise SystemExit(f"live/clients 不可达：{exc}") from exc
    snapshot["resources"] = (http_json(f"{args.api}/live/server", args.token).get("resources") or {})
    if args.audit:
        snapshot["audit"] = audit_rows("backup", args.audit)

    if args.json:
        print(json.dumps(snapshot, ensure_ascii=False, indent=2))
        return 0

    resources = snapshot["resources"]
    print(f"资源: started={resources.get('started')} total={resources.get('total')}")
    clients = snapshot["clients"]
    if not clients:
        print("客户端: 无（真机验证前先让客户端进游戏）")
    for client in clients:
        phone = (client.get("state") or {}).get("phone") or {}
        print(f"客户端 src={client.get('source')} cid={client.get('citizenid')}")
        print("  phone: open=%s keep=%s app=%s focus=%s frames=%s" % (
            phone.get("open"), phone.get("keep_input"),
            (phone.get("app") or {}).get("id"), phone.get("focus"), phone.get("frames")))
        for key in ("delegated", "custom_ui_state", "nav_edges", "backup"):
            if key in phone:
                print(f"  {key}: {phone[key]}")
    for row in snapshot.get("audit") or []:
        print("  audit:", " | ".join(row))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
