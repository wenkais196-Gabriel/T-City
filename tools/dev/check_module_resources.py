#!/usr/bin/env python3
"""核对「configs/modules 声明要跑的资源」是否真的在跑。

背景：FXServer 的 `restart X` 会连带停掉所有依赖 X 的资源，而且不会自动拉回来。
restart qb-inventory 曾一次停掉 12 个（qb-ambulancejob / custom-police / qb-cityhall …），
玩家侧表现为 /revive 之类的命令"没反应"——命令根本没注册。

用法：
    python3 tools/dev/check_module_resources.py \\
        --base T-CityLite.base \\
        --url http://127.0.0.1:30130/custom-director/agent/v1/live/server \\
        --token "$TCITY_LIVE_TOKEN"

退出码：0 = 声明要跑的资源都在跑；1 = 有缺口（会逐条列出）。
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.request
from pathlib import Path

ENSURE_RE = re.compile(r"^\s*ensure\s+(\S+)", re.MULTILINE)

#: 允许不跑的：dev/测试专用，或明确被我们取代的资源。
ALLOWED_MISSING = {
    "custom-testing",  # 自测套件，按需手动起
    "custom-agent-ops",  # 运维面板，按需
}


def declared_resources(base: Path) -> set[str]:
    names: set[str] = set()
    for cfg in sorted((base / "configs" / "modules").glob("*.cfg")):
        names.update(ENSURE_RE.findall(cfg.read_text(encoding="utf-8", errors="ignore")))
    return names


def running_state(url: str, token: str) -> dict:
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.loads(response.read().decode("utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="T-CityLite.base", help="T-CityLite.base 路径")
    parser.add_argument("--url", required=True, help="/live/server 的完整地址")
    parser.add_argument("--token", required=True, help="live token")
    args = parser.parse_args()

    declared = declared_resources(Path(args.base))
    payload = running_state(args.url, args.token)
    resources = payload.get("resources") or {}
    not_started = {name.strip() for name in (resources.get("not_started") or [])}

    missing = sorted(declared & not_started)
    unexpected = [name for name in missing if name not in ALLOWED_MISSING]

    print(f"started={resources.get('started')} total={resources.get('total')}")
    print(f"模块声明 {len(declared)} 个资源")
    if not missing:
        print("全部在跑 ✅")
        return 0
    for name in missing:
        tag = "(允许不跑)" if name in ALLOWED_MISSING else "❌"
        print(f"  {tag} {name}")
    if unexpected:
        print("\n修复：exec configs/modules/<module>.cfg（或 tools/dev/resync_modules.sh）")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
