"""可消耗物品契约闸门。

两个真实故障都出在"配置写了，但游戏里根本走不到"：

1. **名字对不上**：`custom-consumables/config.lua` 里写 `water` / `burger` / `weed_white`，
   而 `qb-core/shared/items.lua` 里叫 `water_bottle` / `tosti` / `weed_whitewidow`。
   玩家买了水喝了没反应，日志里也没有任何报错（`Config.Consumables[name]` 就是 nil）。
2. **入口挂错**：原来只 `RegisterNetEvent('qb-inventory:server:UseItem')`，
   但 qb-inventory 的用物品路径是 `CreateUseableItem` 注册的回调，**从不**发那个事件 ——
   所以整张表形同虚设。

这个闸门同时锁住两件事：表里的每个名字都必须真实存在于 items 表；服务端必须用
`CreateUseableItem` 把整张表逐项注册。
"""

from __future__ import annotations

import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
RES = REPO / "T-CityLite.base" / "resources"
CONSUMABLES_CONFIG = RES / "[custom]" / "custom-consumables" / "config.lua"
CONSUMABLES_SERVER = RES / "[custom]" / "custom-consumables" / "server" / "main.lua"
ITEMS = RES / "[qb]" / "qb-core" / "shared" / "items.lua"

ENTRY = re.compile(r"^\s{4}([a-z0-9_]+)\s*=\s*\{", re.M)


def _consumable_names(text: str) -> set[str]:
    """`Config.Consumables = { ... }` 块里的键。"""
    start = text.index("Config.Consumables = {")
    end = text.index("\n}\n", start)
    return set(ENTRY.findall(text[start:end]))


def _item_names(text: str) -> set[str]:
    return set(ENTRY.findall(text))


def test_consumable_names_exist_in_items():
    consumables = _consumable_names(CONSUMABLES_CONFIG.read_text(encoding="utf-8"))
    items = _item_names(ITEMS.read_text(encoding="utf-8"))
    missing = sorted(consumables - items)
    assert not missing, (
        "custom-consumables 里这些名字在 qb-core/shared/items.lua 里不存在，"
        "玩家用了不会有任何反应：" + ", ".join(missing)
    )


def test_consumables_are_registered_as_useable_items():
    raw = CONSUMABLES_SERVER.read_text(encoding="utf-8")
    # 只看代码，不看注释（注释里会提到那个"不该再挂"的事件名）
    code = "\n".join(line.split("--", 1)[0] for line in raw.splitlines())
    assert "QBCore.Functions.CreateUseableItem" in code, (
        "服务端没有用 CreateUseableItem 注册 —— qb-inventory 只认这条路径，"
        "监听 qb-inventory:server:UseItem 是死代码"
    )
    assert "qb-inventory:server:UseItem" not in code, "那个网络事件没人发，别再挂它"
    assert re.search(r"for\s+\w+\s+in\s+pairs\(Config\.Consumables\)", code), (
        "没有遍历整张表注册，新增物品会静默不可用"
    )


def test_reverse_consumable_name_mismatch_is_caught(tmp_path):
    """反向：表里写一个不存在的东西，闸门必须红。"""
    text = CONSUMABLES_CONFIG.read_text(encoding="utf-8")
    broken = text.replace("water_bottle = {", "definitely_not_an_item = {", 1)
    assert broken != text
    consumables = _consumable_names(broken)
    items = _item_names(ITEMS.read_text(encoding="utf-8"))
    assert consumables - items == {"definitely_not_an_item"}
