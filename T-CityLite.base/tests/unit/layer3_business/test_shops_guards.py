"""P1-3 批 19：qb-shops（5）。

`qb-shops:server:RestockShopItems` 是「跑完一趟货车后发工资」的入口，`deliveryPay` 里有 10 米距离校验，
但**没有冷却也没有次数概念**：站在交货点循环发就能一遍遍拿 `Config.DeliveryPrice`（500/次）+ 10% 概率的
`Config.RewardItem`。本轮加 30 秒冷却。

`qb-shops:server:PaySlip(drops)` 更直接：**全仓没有任何客户端调用点**（deliveries.lua 只发
`RestockShopItems` / `DoBail`），却按客户端给的 `drops` 直接 `AddMoney('bank', 500 * drops)` ——
站在交货点发 `PaySlip(99999)` 就是 500 × 99999 的印钞机。既然没人用，改成只认服务端来源。

`UpdateShopItems(shop, itemData, amount)` 的 `itemData.slot` / `amount` 全来自客户端：坏 slot 直接
`attempt to index a nil value` 打断事件线程，负数 amount 会把库存**加上去**（白拿货）。

`openShop(data)` 的 `data` 为 nil 时 `data.shop` 抛错，且没有距离校验（可以在任意位置开任意店的界面）。
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


def test_restock_pay_is_distance_and_cooldown_bound():
    data = _run("shops_probe.lua", "[qb]/qb-shops")
    assert data["RESTOCK_FAR_BLOCKED"] == "true", "不在交货点也能结算补货工资"
    assert data["RESTOCK_NEAR_PAID"] == "true", "正常交货被拒（过度收紧）"
    assert data["RESTOCK_COOLDOWN_BLOCKED"] == "true", "冷却内可以重复领工资（旧版就是这样）"
    assert data["RESTOCK_AFTER_COOLDOWN_PAID"] == "true", "冷却过后领不到（过度收紧）"
    assert data["RESTOCK_BAD_ARGS_SAFE"] == "true", "shop 为 nil / 不存在的店会抛错"


def test_payslip_is_not_reachable_from_clients():
    """全仓没有客户端调用点，却按客户端给的 drops 发钱。"""
    data = _run("shops_probe.lua", "[qb]/qb-shops")
    assert data["PAYSLIP_CLIENT_BLOCKED"] == "true", "客户端发 PaySlip(99999) 就能印钞（旧版就是这样）"


def test_shop_stock_updates_are_bounded():
    data = _run("shops_probe.lua", "[qb]/qb-shops")
    assert data["STOCK_DECREMENT_OK"] == "true", "正常结账扣库存被拒（过度收紧）"
    assert data["STOCK_NEGATIVE_BLOCKED"] == "true", "负数数量会把库存加上去（旧版就是这样）"
    assert data["STOCK_BAD_SLOT_SAFE"] == "true", "坏 slot 打断事件线程（旧版就是这样）"


def test_open_shop_requires_being_there():
    data = _run("shops_probe.lua", "[qb]/qb-shops")
    assert data["OPENSHOP_NIL_DATA_SAFE"] == "true", "data 为 nil 时抛错（旧版就是这样）"
    assert data["OPENSHOP_NEAR_ALLOWED"] == "true", "站在店门口开不了界面（过度收紧）"
    assert data["OPENSHOP_FAR_BLOCKED"] == "true", "能在任意位置开任意店（旧版就是这样）"
