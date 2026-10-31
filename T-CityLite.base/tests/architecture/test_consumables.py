"""custom-consumables：饥渴 / 酒精 / 药物的唯一写者。

背景：本服没有 qb-smallresources，而 qb-core 只在 loops.lua 里**读** metadata.hunger/thirst
来扣血 —— 没有任何地方写它。于是食物不顶饿、HUD 永远 100、警用酒测也没有数据源。
"""

from __future__ import annotations

import pathlib
import re

REPO = pathlib.Path(__file__).resolve().parents[3]
RES = REPO / "T-CityLite.base/resources/[custom]/custom-consumables"
CONFIG = RES / "config.lua"
SERVER = RES / "server/main.lua"
MANIFEST = RES / "fxmanifest.lua"
MODULE_CFG = REPO / "T-CityLite.base/configs/modules/custom.cfg"


def test_status_is_written_to_player_metadata() -> None:
    src = SERVER.read_text(encoding="utf-8")
    for key in ("hunger", "thirst"):
        assert f"SetMetaData('{key}'" in src, f"{key} 必须写进 metadata（qb-hud 读的是它）"
    assert "SetMetaData('alcohol'" in src
    assert "SetMetaData('drug_level'" in src


def test_item_use_verifies_ownership_and_cooldown() -> None:
    src = SERVER.read_text(encoding="utf-8")
    at = src.find("qb-inventory:server:UseItem")
    assert at != -1
    block = src[at:at + 900]
    assert "GetItemByName" in block, "没有这件物品的玩家发事件什么都不该发生"
    assert "cooldown" in src, "同类物品要有使用间隔"


def test_decay_is_server_side_and_single_writer() -> None:
    src = SERVER.read_text(encoding="utf-8")
    assert "Config.DecayIntervalMs" in src
    assert "while true do" in src and "Wait(Config.DecayIntervalMs)" in src
    # 衰减不能由客户端推：这里只认服务端线程
    assert "TriggerClientEvent('custom-consumables" not in src


def test_config_covers_food_drink_and_drugs() -> None:
    cfg = CONFIG.read_text(encoding="utf-8")
    table = cfg[cfg.find("Config.Consumables"):cfg.find("Config.DecayIntervalMs")]
    names = set(re.findall(r"^\s{4}([a-z_]+)\s*=\s*\{", table, re.M))
    assert {"water", "beer", "vodka"} <= names, "饮料"
    assert {"sandwich", "burger"} <= names, "食物"
    assert any(n.startswith("weed") for n in names), "药物"


def test_resource_starts_with_the_custom_module() -> None:
    assert "ensure custom-consumables" in MODULE_CFG.read_text(encoding="utf-8")
    manifest = MANIFEST.read_text(encoding="utf-8")
    assert "server/main.lua" in manifest and "config.lua" in manifest
