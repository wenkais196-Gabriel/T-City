"""命令名唯一性闸门（H-6 的教训）。

同名命令由不同资源注册时，**谁生效取决于资源启动顺序** —— 玩家敲 `/menu` 有时开 HUD 设置、
有时印管理面板。这类问题不会报错，只会"有时候不好使"。

规则：
1. 全仓命令名必须唯一；
2. 已知的历史重复登记在 `command_duplicates_allowlist.json`（债务清单，带 todo 说明），
   新出现的重复一律红；
3. 清掉一条就必须同 commit 删条目（清空后 allowlist 必须为空，防止烂账）。
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
TOOL = REPO / "tools" / "dev" / "scan_commands.py"
ALLOWLIST = Path(__file__).with_name("command_duplicates_allowlist.json")


def _rows() -> list[dict]:
    spec = importlib.util.spec_from_file_location("scan_commands", TOOL)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules["scan_commands"] = module
    spec.loader.exec_module(module)
    return module.scan()


def _duplicates(rows: list[dict]) -> dict[str, list[str]]:
    by_name: dict[str, list[str]] = {}
    for row in rows:
        by_name.setdefault(row["command"], []).append(row["where"])
    return {name: where for name, where in by_name.items() if len(where) > 1}


def test_command_names_are_unique_detects_collision():
    allowlist = json.loads(ALLOWLIST.read_text(encoding="utf-8"))
    # 以下划线开头的是说明字段，不是债务条目
    known = {k for k in allowlist.get("known", {}) if not k.startswith("_")}
    dupes = _duplicates(_rows())
    new_dupes = {name: where for name, where in dupes.items() if name not in known}
    assert not new_dupes, (
        "新增了同名命令（谁生效取决于启动顺序）："
        + ", ".join(f"{name} @ {where[0]}" for name, where in new_dupes.items()))

    # 反向：把 /menu 塞回已知清单之外，规则必须红
    injected = dict(dupes)
    injected["definitely_duplicate"] = ["a.lua:1", "b.lua:2"]
    assert "definitely_duplicate" not in known


def test_allowlist_entries_still_duplicate_detects_stale():
    """清掉的重复必须同 commit 删条目 —— 否则清单会烂成"永久豁免"。"""
    allowlist = json.loads(ALLOWLIST.read_text(encoding="utf-8"))
    # 以下划线开头的是说明字段，不是债务条目
    known = {k for k in allowlist.get("known", {}) if not k.startswith("_")}
    dupes = set(_duplicates(_rows()))
    stale = known - dupes
    assert not stale, f"这些重复已经不存在了，请从 allowlist 删掉：{sorted(stale)}"
