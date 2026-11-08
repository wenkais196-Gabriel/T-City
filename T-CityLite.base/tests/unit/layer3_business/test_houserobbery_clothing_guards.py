"""P1-3 批 12：qb-houserobbery 与 qb-clothing。

**qb-houserobbery** 有两个问题性质不同：

- `SetBusyState(cabin, house, bool)` / `enterHouse(house)` / `searchFurniture(cabin, house)` 都拿客户端
  传来的 house/cabin 直接索引 `Config.Houses[...]` —— 坏 key 就是一个 nil 索引，把事件线程打崩。
  `SetBusyState` 还能把任意家具标成 isBusy，等于锁死整间房子的搜刮。
- **`searchFurniture` 的准入导出写错了资源名**：`exports['custom-main']:CheckHouseRobbery`，
  而这个导出只有 `custom-crime` 提供 → 每次搜刮都在这里抛
  `No such export CheckHouseRobbery in resource custom-main`，**整条房屋搜刮流程从来没跑通过**。

**qb-clothing** 集中在"客户端数据没有边界"：

- `saveSkin(model, skin)` 直接进 RAM 缓存与 `playerskins` 列，没有结构/长度校验；
- `saveOutfit` 在 `Player` 为 nil 时直接索引 `Player.PlayerData` 崩，且**没有条数上限**
  （可以无限往 `player_outfits` 插，每次插入还会把该玩家全部服装回读一遍）；
- `removeOutfit` 同样缺 Player 判空；
- `QBCore:Server:OnPlayerUnload(src)` 是服务端内部事件，客户端能自己发一份（还能传别人的 src）。
"""

from __future__ import annotations

import subprocess
from pathlib import Path

BASE = Path(__file__).resolve().parents[3]
FIXTURES = Path(__file__).resolve().parent / "fixtures"


def _run(probe: str, resource: str) -> dict[str, str]:
    proc = subprocess.run(
        ["lua5.4", (FIXTURES / probe).as_posix(), (BASE / "resources" / "[qb]" / resource).as_posix()],
        capture_output=True,
        text=True,
        timeout=90,
    )
    assert proc.returncode == 0, f"probe 失败：{proc.stderr} / {proc.stdout}"
    data: dict[str, str] = {}
    for line in proc.stdout.splitlines():
        if "|" not in line:
            continue
        key, _, value = line.partition("|")
        data.setdefault(key, value)
    assert "HANDLER_ERROR" not in data, f"handler 抛错：{data.get('HANDLER_ERROR')}"
    return data


# ══════════════════════════════════════════════════════════════════
# qb-houserobbery
# ══════════════════════════════════════════════════════════════════


def test_houserobbery_handlers_survive_bad_house_and_cabin_keys():
    """house / cabin 来自客户端，坏 key 不能让 `Config.Houses[...]` 抛错。"""
    data = _run("houserobbery_probe.lua", "qb-houserobbery")
    assert data["BUSY_BAD_HOUSE_SAFE"] == "true", "SetBusyState 坏 house 抛错"
    assert data["BUSY_BAD_CABIN_SAFE"] == "true", "SetBusyState 坏 cabin 抛错"
    assert data["BUSY_BAD_TYPE_SAFE"] == "true", "SetBusyState 非布尔参数抛错"
    assert data["BUSY_SET_OK"] == "true", "合法参数反而设置不了（过度收紧）"
    assert data["ENTER_BAD_HOUSE_SAFE"] == "true", "enterHouse 坏 house 抛错"
    assert data["ENTER_BAD_TYPE_SAFE"] == "true", "enterHouse 非字符串参数抛错"


def test_houserobbery_delegates_to_the_right_resource():
    """`searchFurniture` 的准入导出在 **custom-crime**，不是 custom-main。

    写错资源名时 `exports['custom-main']:CheckHouseRobbery` 会抛
    `No such export ... in resource custom-main`，整条搜刮流程永远失败。
    """
    data = _run("houserobbery_probe.lua", "qb-houserobbery")
    assert data["SEARCH_NO_ERROR"] == "true", "searchFurniture 抛错（导出资源名写错）"
    assert data["SEARCH_CHECK_DELEGATED"] == "true", "没有调用 custom-crime 的准入检查"
    assert data["SEARCH_MARKED_SEARCHED"] == "true", "搜完后没有标记 searched"


def test_houserobbery_search_is_server_authoritative():
    """已搜过的抽屉不能再搜；准入被拒时不能发奖。"""
    data = _run("houserobbery_probe.lua", "qb-houserobbery")
    assert data["SEARCH_AGAIN_BLOCKED"] == "true", "已搜过的抽屉还能再搜（服务端没有守着 searched）"
    assert data["SEARCH_BAD_ARGS_NO_ITEMS"] == "true", "坏参数仍然发出了奖励"
    assert data["SEARCH_DENIED_NO_ITEMS"] == "true", "准入被拒仍然发出了奖励"


# ══════════════════════════════════════════════════════════════════
# qb-clothing
# ══════════════════════════════════════════════════════════════════


def test_clothing_skin_payload_is_bounded():
    """皮肤直接进 RAM 缓存 + `playerskins` 列，必须有结构/长度上限。"""
    data = _run("clothing_probe.lua", "qb-clothing")
    assert data["SKIN_SAVE_OK"] == "true", "正常外观反而存不进去（过度收紧）"
    assert data["SKIN_HUGE_REJECTED"] == "true", "200 个字段的超大表被接受"
    assert data["SKIN_BAD_TYPE_REJECTED"] == "true", "非表结构被接受"
    assert data["SKIN_BAD_MODEL_REJECTED"] == "true", "超长 model 被接受"


def test_clothing_outfits_are_bounded_and_nil_safe():
    """服装保存要判空、要有条数上限、皮肤要有界。"""
    data = _run("clothing_probe.lua", "qb-clothing")
    assert data["OUTFIT_MISSING_PLAYER_SAFE"] == "true", "Player 不存在时 saveOutfit 抛错"
    assert data["OUTFIT_SAVED"] == "true", "正常保存反而失败（过度收紧）"
    assert data["OUTFIT_LIMIT_ENFORCED"] == "true", "超过上限仍能继续插库"
    assert data["OUTFIT_HUGE_SKIN_REJECTED"] == "true", "超大皮肤被写库"
    assert data["OUTFIT_LONG_NAME_REJECTED"] == "true", "超长服装名被写库"
    assert data["OUTFIT_REMOVE_MISSING_PLAYER_SAFE"] == "true", "Player 不存在时 removeOutfit 抛错"


def test_on_player_unload_only_runs_from_the_server():
    """`QBCore:Server:OnPlayerUnload` 是服务端内部事件，客户端不能自己发。"""
    data = _run("clothing_probe.lua", "qb-clothing")
    assert data["UNLOAD_CLIENT_BLOCKED"] == "true", "客户端触发了 OnPlayerUnload"
    assert data["UNLOAD_SERVER_ALLOWED"] == "true", "服务端触发也被挡（handler 变成死代码）"
