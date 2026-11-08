"""P1-3 批 14：qb-pawnshop 与 qb-multicharacter。

**qb-pawnshop —— 两条都是印钞机**

- `sellPawnItems(itemName, itemAmount, itemPrice)`：`itemPrice` 来自客户端，
  `totalPrice = itemAmount * itemPrice` —— 卖一块石头要价一百万，钱直接从 `AddScaledMoney` 进账。
- `pickupMelted(item)`：`item.items[*].item.reward` 是**客户端提交的奖励表**，服务端照着发物品 ——
  可以要 99999 个金条；`meltItemRemove` 的 `item.time` 同样来自客户端（决定熔炼耗时）。

**qb-multicharacter**

- `loadUserData(cData)`：`cData` 为 nil / 非表时直接索引崩；`citizenid` 非字符串时 `:sub` 崩。
  （归属校验本身在 qb-core 的 `Player.Login` 里，会比对 license 并踢人。）
- `createCharacter(data)`：`newData.charinfo = data` 把客户端整张表写进 `players.charinfo`；
  `cid` 未校验。
- `deleteCharacter(citizenid)`：类型未校验（归属由 qb-core 的 `DeleteCharacter` 比对 license）。
- `disconnect()`：只踢自己，登记即可。
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
# qb-pawnshop
# ══════════════════════════════════════════════════════════════════


def test_pawn_sale_price_comes_from_the_server():
    """卖出单价必须由服务端按 `Config.PawnItems` 计算，不能采信客户端传的 `itemPrice`。"""
    data = _run("pawnshop_probe.lua", "qb-pawnshop")
    assert data["SELL_REMOVED"] == "true", "正常售出没有扣物品"
    assert data["SELL_PAID_CONFIG_PRICE"] == "true", "入账金额不是「配置单价 × 数量」（客户端可以随便报价）"
    assert data["SELL_AMOUNT_CAPPED"] == "true", "超大数量没有被拦"
    assert data["SELL_UNKNOWN_ITEM_REJECTED"] == "true", "配置里没有的物品也能卖"


def test_pawn_melt_recipe_comes_from_the_server():
    """熔炼耗时与配方必须来自 `Config.MeltingItems`。"""
    data = _run("pawnshop_probe.lua", "qb-pawnshop")
    assert data["MELT_USES_SERVER_ENTRY"] == "true", "客户端提交的熔炼条目被直接采信"
    assert data["MELT_AMOUNT_PASSED"] == "true", "熔炼数量没有正确传递"
    assert data["MELT_UNKNOWN_ITEM_REJECTED"] == "true", "不在配方里的物品也能熔"


def test_pawn_pickup_is_driven_by_the_server_side_melt_state():
    """取回必须凭服务端登记的"熔炼批次"，不能凭客户端断言。

    第一版只把奖励表改成服务端配置，仍然可以站在当铺门口反复触发 `pickupMelted`
    无限领配置奖励（不需要原料、不需要等熔炼时间）—— 现在 `meltItemRemove` 成功扣料时登记
    `PendingMelt[src]`，取回只按这批发、到时间才发、发完清除。
    """
    data = _run("pawnshop_probe.lua", "qb-pawnshop")
    assert data["PICKUP_WITHOUT_MELT_GIVES_NOTHING"] == "true", "没熔炼过也能领奖励（可无限刷配置奖励）"
    assert data["PICKUP_BEFORE_READY_GIVES_NOTHING"] == "true", "熔炼还没到时间就能领"
    assert data["PICKUP_PAYS_CONFIG_REWARDS"] == "true", "正常取回没发到配置奖励（过度收紧）"
    assert data["PICKUP_SECOND_TIME_GIVES_NOTHING"] == "true", "同一批可以重复领取"


# ══════════════════════════════════════════════════════════════════
# qb-multicharacter
# ══════════════════════════════════════════════════════════════════


def test_load_user_data_survives_bad_payloads():
    """`cData` 来自客户端：nil / 非表 / 非字符串 citizenid 都不能打崩事件线程。"""
    data = _run("multicharacter_probe.lua", "qb-multicharacter")
    assert data["LOAD_NIL_SAFE"] == "true", "缺参数时抛错"
    assert data["LOAD_NOT_TABLE_SAFE"] == "true", "非表参数时抛错"
    assert data["LOAD_BAD_CITIZENID_SAFE"] == "true", "citizenid 非字符串时抛错"
    assert data["LOAD_VALID_REACHES_LOGIN"] == "true", "正常选角色反而进不去（过度收紧）"


def test_create_character_whitelists_charinfo():
    """`newData.charinfo = data` 原来把客户端整张表写进库；现在只留白名单字段。"""
    data = _run("multicharacter_probe.lua", "qb-multicharacter")
    assert data["CREATE_REACHES_LOGIN"] == "true", "正常创建反而失败（过度收紧）"
    assert data["CREATE_STRIPS_UNKNOWN_FIELDS"] == "true", "客户端夹带的 isAdmin/money/items/hugeblob 被写进角色数据"
    assert data["CREATE_KEEPS_WHITELIST"] == "true", "白名单字段反而丢了"
    assert data["CREATE_CID_NUMERIC"] == "true", "cid 没有归一化成数字"
    assert data["CREATE_BAD_DATA_SAFE"] == "true", "非表参数抛错"
    assert data["CREATE_MISSING_FIRSTNAME_REJECTED"] == "true", "缺 firstname 也建了角色"


def test_delete_character_validates_type():
    """`deleteCharacter(citizenid)` 先做类型校验（归属由 qb-core 比对 license）。"""
    data = _run("multicharacter_probe.lua", "qb-multicharacter")
    assert data["DELETE_BAD_TYPE_REJECTED"] == "true", "非字符串 citizenid 仍被送去删除"
    assert data["DELETE_VALID_REACHES_CORE"] == "true", "正常删除反而被挡（过度收紧）"


def test_disconnect_only_drops_the_caller():
    data = _run("multicharacter_probe.lua", "qb-multicharacter")
    assert data["DISCONNECT_DROPS_SELF"] == "true", "disconnect 没有只作用于调用者"
