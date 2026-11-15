"""`QuestManager.X` 只许有一份定义：后一份会**静默覆盖**前一份。

真实事故（2026-11-13）：`quest_manager.lua` 里 `AbandonQuest` 被定义了两次。前一份带
「questId 必须是字符串 + 任务必须真的在进行中」两道校验，后一份没有 —— 后一份生效，
于是传 nil 也会一路走到 `QuestDB.AbandonQuest`，而前一份的注释还写着「不该走到这里」。
Lua 不报错、`luac -p` 也不报错，只有读代码才发现。

判定逻辑是纯函数（可喂合成文本），因此这条规则当场可证会红：
合成的重复定义必须被抓到，真实仓库必须唯一。
"""

from __future__ import annotations

import re
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
MANAGER = BASE / "resources/[custom]/custom-quest/server/quest_manager.lua"


def duplicate_definitions(text: str) -> list[str]:
    """返回被重复定义的 `QuestManager.<名字>`（只算函数定义，不算字段赋值）。"""
    names = re.findall(r"function\s+QuestManager\.(\w+)\s*\(", text)
    return sorted({name for name in names if names.count(name) > 1})


def test_duplicate_quest_manager_definitions_detects_dups_and_tree_is_clean():
    # 反向：合成一份重复定义，必须被抓到
    bad = "\n".join([
        "function QuestManager.AbandonQuest(source, questId)",
        "    return true",
        "end",
        "function QuestManager.AbandonQuest(source, questId)",
        "    return false",
        "end",
    ])
    assert duplicate_definitions(bad) == ["AbandonQuest"], "重复定义没被抓到（规则等于不存在）"

    # 正向控制：名字只出现一次（含 `QuestManager.x = ` 这类字段赋值）时不许误报
    clean = "\n".join([
        "function QuestManager.AbandonQuest(source, questId)",
        "    return true",
        "end",
        "QuestManager._completing = QuestManager._completing or {}",
    ])
    assert duplicate_definitions(clean) == [], "把字段赋值误判成重复定义"

    # 真实仓库必须唯一
    dups = duplicate_definitions(MANAGER.read_text(encoding="utf-8"))
    assert not dups, (
        "QuestManager 里有重复函数定义（Lua 静默覆盖，前一份的校验会消失）："
        + ", ".join(dups)
    )
