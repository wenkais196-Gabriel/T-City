"""警察序章卡在第一步：两条真机 bug。

日志证据（2026-10-31 真机）：
  [quest-manager] 🔗 ExecuteNode (first): quest=police_ch1_first_shift, step=step_report_station, type=reach
  [quest-nodes] ⚠️ Unknown node type: reach → REACH

1. 模板里 reach 步骤用的是小写 type，`_eventMap` 里只有 GOTO/INTERACT/…，没有 REACH，
   于是 ExecuteNode 直接 return —— 客户端拿不到 blip 和触发区，玩家永远走不到第一步。
2. `QuestManager.AbandonQuest` 只出现在注释和调用点，函数体不存在：
   `quest:server:abandon` 落到 nil，`exports['custom-quest']:AbandonQuest` 报
   "No such export AbandonQuest"，玩家卡在坏任务里还退不出来。
"""

from __future__ import annotations

import pathlib

REPO = pathlib.Path(__file__).resolve().parents[3]
MGR = REPO / "T-CityLite.base/resources/[custom]/custom-quest/server/quest_manager.lua"
MAIN = REPO / "T-CityLite.base/resources/[custom]/custom-quest/server/main.lua"
CFG = REPO / "T-CityLite.base/resources/[custom]/custom-quest/config/quests/quest_police_ch1_first_shift.lua"


def test_reach_steps_are_dispatched_to_the_client() -> None:
    src = MGR.read_text(encoding="utf-8")
    at = src.index("_eventMap = {")
    block = src[at:src.index("},")]
    assert "REACH" in block, "reach 步骤必须能下发，否则客户端没有触发区"
    assert "GOTO" in block


def test_every_step_type_in_the_police_prologue_is_mapped() -> None:
    mappedsrc = MGR.read_text(encoding="utf-8")
    at = mappedsrc.index("_eventMap = {")
    block = mappedsrc[at:mappedsrc.index("},", at)]
    quest = CFG.read_text(encoding="utf-8")
    import re

    steps = quest[quest.index("steps = {"):]
    types = set(re.findall(r"\{ id = '[a-z_]+'.*?type = '([a-z_]+)'", steps))
    missing = [t for t in types if t.upper() not in block]
    assert not missing, f"序章用了未映射的步骤类型：{missing}"


def test_abandon_quest_exists_and_is_exported() -> None:
    src = MGR.read_text(encoding="utf-8")
    assert "function QuestManager.AbandonQuest(" in src, "函数体必须存在"
    at = src.index("function QuestManager.AbandonQuest(")
    block = src[at:at + 2000]
    assert "QuestDB.AbandonQuest" in block
    assert "CancelAllNodes" in block, "放弃时要收起节点"
    assert "InvalidateActive" in block, "缓存要失效，否则界面还显示在跑"

    main = MAIN.read_text(encoding="utf-8")
    assert "exports('AbandonQuest', QuestManager.AbandonQuest)" in main
    assert "12 exports" in main


def test_every_template_step_type_is_mapped_or_server_only() -> None:
    """全局扫一遍模板：每个步骤类型要么有客户端节点，要么显式声明为服务端自洽。"""
    import re

    base = MGR.parents[1]
    mgr = MGR.read_text(encoding="utf-8")
    block = mgr[mgr.index("_eventMap = {"):mgr.index("},", mgr.index("_eventMap = {"))]
    mapped = set(re.findall(r"([A-Z_]+)\s*=", block))
    only = mgr[mgr.index("_serverOnly = {"):mgr.index("},", mgr.index("_serverOnly = {"))]
    server_only = set(re.findall(r"([A-Z_]+)\s*=", only))

    used = {}
    for f in (base / "config/quests").glob("*.lua"):
        txt = f.read_text(encoding="utf-8")
        if "steps = {" not in txt:
            continue
        steps = txt[txt.index("steps = {"):]
        for t in re.findall(r"\{ id = '[^']+'.*?type = '([a-z_]+)'", steps):
            used.setdefault(t.upper(), set()).add(f.name)

    missing = {t: sorted(v) for t, v in used.items() if t not in mapped | server_only}
    assert not missing, f"这些步骤类型既没客户端节点也没登记为 server-only：{missing}"
