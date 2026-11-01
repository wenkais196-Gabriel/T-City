"""G8：`_G.Bus.EconomyService` 只能有一个写者（qb-core），否则经济链路会出现"包装→ES→包装"递归。

为什么需要这条：仓库里有两份 EconomyService —— qb-core 那份直接写内存，core-framework 那份
内部会回调 `Player.Functions.AddMoney`。任何"统一两份实现"的动作只要把 core-framework 那份挂到
`_G.Bus.EconomyService`，调用链就变成 `Player.Functions.AddMoney → ES → Player.Functions.AddMoney`
的无限递归。这条静态断言把"谁可以注册"钉死。

注意作用域：`_G.Bus` 是**资源私有**的（FiveM 每个 resource 一个 Lua 状态），所以 qb-core 注册的是
它自己状态里的那张表；这条闸门管的是"不许出现第二个写者"，不是"跨资源共享"。
"""

from __future__ import annotations

import re
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]  # T-CityLite.base/
RESOURCES = BASE / "resources"

#: 唯一允许写 `_G.Bus.EconomyService` 的文件（相对 resources/）
OWNER = "[qb]/qb-core/server/services/economy_service.lua"

PATTERN = re.compile(r"_G\.Bus\.EconomyService\s*(?<![=<>~])=(?!=)")


def _writers() -> list[str]:
    hits: list[str] = []
    for path in sorted(RESOURCES.rglob("*.lua")):
        text = path.read_text(encoding="utf-8", errors="ignore")
        # 去掉行注释，避免文档性注释被算成写者
        text = re.sub(r"--[^\n]*", "", text)
        if PATTERN.search(text):
            hits.append(path.relative_to(RESOURCES).as_posix())
    return hits


def test_economy_service_has_a_single_registrar():
    writers = _writers()
    assert writers == [OWNER], (
        "`_G.Bus.EconomyService` 的写者必须只有 qb-core 那份实现，实际：\n  "
        + "\n  ".join(writers or ["（一个都没有）"])
        + "\ncore-framework 的 EconomyService 内部会回调 Player.Functions.AddMoney，"
        "把它挂上去会形成 包装→ES→包装 的无限递归。"
    )
