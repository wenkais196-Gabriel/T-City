"""P1-3 批 16：qb-fuel / qb-doorlock / qb-mechanicjob。

三个资源都有一类同样的问题：**客户端报什么就信什么**。

- `qb-fuel`：`setCanFuel(fuel)` 直接把客户端给的数字写进油桶 —— 加油语义是"扣减"
  （client 传 `canLiter - liter`），但服务端分不清"加满"和"扣减"，任何玩家发一条
  `setCanFuel(40)` 就白得 40 升油。`refillVehicle(litres)` 的升数也完全由客户端给
  （负数会让价格算成负数、垃圾字符串/表直接抛错），`buyJerryCan` / `refillJerryCan`
  全图任意位置都能下单。
- `qb-doorlock`：`updateState(doorID, locked, src, usedLockpick, unlockAnyway, ..., sentSource)`
  的鉴权对象是 `sentSource or source` —— 客户端塞第 8 个参数报一个在线警察的 server id，
  鉴权就按那个警察算，普通的门禁形同虚设。全仓客户端调用点都不传这个参数。
- `qb-mechanicjob`：`sprayVehicle` / `sprayVehicleCustom` 没有任何来源校验 —— 任何玩家可以给
  **地图上任意一辆车**免费改色，还能让服务端把它 `FreezeEntityPosition` 住 `PaintTime*1000`
  毫秒（顺手能把别人的车冻在路口）；`removeItem(part, amount)` 的 part/amount 也全是客户端给的。
    这个 handler 顾客修车时也会调（按配方逐项扣料），所以不能加职业限制，只做有界校验。
"""

from __future__ import annotations

import subprocess
from pathlib import Path

BASE = Path(__file__).resolve().parents[3]
FIXTURES = Path(__file__).resolve().parent / "fixtures"


def _run(probe: str, resource_path: str) -> dict[str, str]:
    proc = subprocess.run(
        ["lua5.4", (FIXTURES / probe).as_posix(), (BASE / "resources" / resource_path).as_posix()],
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
# qb-fuel
# ══════════════════════════════════════════════════════════════════


def test_fuel_refill_is_server_priced_and_station_bound():
    """`refillVehicle(litres)`：升数夹取、正数校验、必须在加油站附近，价格服务端算。"""
    data = _run("fuel_probe.lua", "[qb]/qb-fuel")
    assert data["REFILL_FAR_BLOCKED"] == "true", "不在加油站也能加油（旧版就是全图任意位置）"
    assert data["REFILL_NEAR_ALLOWED"] == "true", "正常加油被拒（过度收紧）"
    assert data["REFILL_NEGATIVE_BLOCKED"] == "true", "负数升数能过（价格会算成负数）"
    assert data["REFILL_GARBAGE_STRING_BLOCKED"] == "true", "垃圾字符串没挡住"
    assert data["REFILL_TABLE_BLOCKED"] == "true", "表参数没挡住（旧版直接抛错）"
    assert data["REFILL_CLAMPED_TO_300"] == "true", "天文数字没有被夹到 300 升"
    assert data["REFILL_STRING_NUMERIC_ALLOWED"] == "true", "'50' 是合法数字，不该被拒（过度收紧）"


def test_jerry_can_fuel_only_goes_down():
    """`setCanFuel(fuel)` 语义是扣减，只能单调递减；加满必须走付钱的 `refillJerryCan`。"""
    data = _run("fuel_probe.lua", "[qb]/qb-fuel")
    assert data["CAN_INCREASE_BLOCKED"] == "true", "客户端发一条 setCanFuel(40) 就能白加油"
    assert data["CAN_DECREASE_ALLOWED"] == "true", "正常倒油被拒（过度收紧）"
    assert data["CAN_NEGATIVE_CLAMPED"] == "true", "负数油量没夹到 0"
    assert data["CAN_REFILL_NO_INFO_SAFE"] == "true", "老油桶 info 为 nil 时抛错（旧版崩在这里）"
    assert data["CAN_REFILL_FAR_BLOCKED"] == "true", "不在加油站也能补油桶"
    assert data["CAN_BUY_FAR_BLOCKED"] == "true", "不在加油站也能买油桶"


# ══════════════════════════════════════════════════════════════════
# qb-doorlock
# ══════════════════════════════════════════════════════════════════


def test_door_state_change_authenticates_the_caller_not_a_named_player():
    """`sentSource` 是客户端可写的第 8 个参数，鉴权对象必须是 `source` 本人。"""
    data = _run("doorlock_probe.lua", "[qb]/qb-doorlock")
    assert data["FORGED_SOURCE_BLOCKED"] == "true", "普通玩家塞警察 id 就能开警察门（旧版直接放行）"
    assert data["COP_OPEN_ALLOWED"] == "true", "警察本人开门被拒（过度收紧）"
    assert data["CIVILIAN_OPEN_BLOCKED"] == "true", "普通玩家无权开门却开了"


def test_lockpick_removal_only_accepts_lockpicks():
    data = _run("doorlock_probe.lua", "[qb]/qb-doorlock")
    assert data["LOCKPICK_WHITELIST"] == "true", "非开锁器物品也被扣掉了"


# ══════════════════════════════════════════════════════════════════
# qb-mechanicjob
# ══════════════════════════════════════════════════════════════════


def test_spray_vehicle_requires_shop_employee_next_to_the_booth():
    """喷漆台在 client 侧是按 job 限制的（qb-target 的 paintbooth），服务端要等价。"""
    data = _run("mechanic_probe.lua", "[qb]/qb-mechanicjob")
    assert data["SPRAY_NON_MECHANIC_BLOCKED"] == "true", "路人能给别人的车免费改色"
    assert data["SPRAY_FAR_VEHICLE_BLOCKED"] == "true", "能给地图另一头的车改色"
    assert data["SPRAY_OFF_BOOTH_BLOCKED"] == "true", "员工不在本店喷漆位也能喷"
    assert data["SPRAY_ALLOWED"] == "true", "本店员工正常喷漆被拒（过度收紧）"
    assert data["SPRAY_NIL_COLORS_SAFE"] == "true", "colors 为 nil 打崩事件线程"


def test_mechanic_remove_item_is_bounded_but_still_works_for_customers():
    """顾客修车也会调这个 handler（按配方逐项扣料），所以只能做有界校验，不能加职业限制。"""
    data = _run("mechanic_probe.lua", "[qb]/qb-mechanicjob")
    assert data["REMOVEITEM_VALID"] == "true", "正常扣料被拒（过度收紧）"
    assert data["REMOVEITEM_UNKNOWN_BLOCKED"] == "true", "不存在的物品名也能扣"
    assert data["REMOVEITEM_NEGATIVE_CLAMPED"] == "true", "负数数量能过"
    assert data["REMOVEITEM_HUGE_CLAMPED"] == "true", "天文数字数量能过"
    assert data["REMOVEITEM_BAD_AMOUNT_DEFAULT"] == "true", "非数字数量没回落成 1"
