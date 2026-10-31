"""新增一个 agent 动作必须同时落到 policy.lua 的四处，缺一处就静默变成 unsupported_action。

这四处是在实机联调里一个一个被 `unsupported_action` / `player_not_found` 逼出来的：
1. `AgentPolicy.ACTIONS[...]` —— 注册表（propose 的第一道门）
2. `AgentPolicy.Normalize` —— 参数规范化（citizenid 这类字段在这里定形状）
3. `AgentPolicy.Preview` —— 审批人看到的预览（缺了就是在 propose 阶段 400）
4. `AgentPolicy.CheckPolicy` —— 真正的运行时闸门（缺了在 approve 前就拒）

另外记一条 Lua 坑：pattern 没有 `{n,m}`，写 `^[A-Za-z0-9_%-]{1,11}$` 永远不匹配，
症状是"合法 citizenid 被判非法"。长度要用 `#s` 判。
"""

from __future__ import annotations

import pathlib
import re

REPO = pathlib.Path(__file__).resolve().parents[3]
POLICY = REPO / "T-CityLite.base/resources/[custom]/custom-director/server/policy.lua"
ACTIONS = ("police_draft_report", "police_warrant_request", "police_incident_create")


def _sections() -> dict[str, str]:
    src = POLICY.read_text(encoding="utf-8")
    starts = {
        "actions": src.index("AgentPolicy.ACTIONS = {"),
        "normalize": src.index("function AgentPolicy.Normalize("),
        "preview": src.index("function AgentPolicy.Preview("),
        "check": src.index("function AgentPolicy.CheckPolicy("),
    }
    order = ["actions", "normalize", "preview", "check"]
    out = {}
    for i, name in enumerate(order):
        end = starts[order[i + 1]] if i + 1 < len(order) else len(src)
        out[name] = src[starts[name]:end]
    return out


def test_every_police_action_is_wired_in_all_four_places() -> None:
    sections = _sections()
    missing = []
    for action in ACTIONS:
        # ACTIONS 表用裸键（police_x = {），其它三处是字符串比较
        if f"{action} = " not in sections["actions"]:
            missing.append(f"{action}@actions")
        for place in ("normalize", "preview", "check"):
            if f"'{action}'" not in sections[place]:
                missing.append(f"{action}@{place}")
    assert not missing, f"动作没接全：{missing}"


def test_no_lua_pattern_uses_regex_quantifiers() -> None:
    src = POLICY.read_text(encoding="utf-8")
    bad = re.findall(r"match\('\[[^']*\]\{\d+,\d+\}", src)
    assert not bad, f"Lua pattern 里不能写 {{n,m}}：{bad}"
