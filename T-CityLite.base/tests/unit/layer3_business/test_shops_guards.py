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

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lua_probe import run_probe  # noqa: E402


def test_restock_pay_is_distance_and_cooldown_bound():
    data = run_probe("shops_probe.lua", "[qb]/qb-shops")
    assert data["RESTOCK_FAR_BLOCKED"] == "true", "不在交货点也能结算补货工资"
    assert data["RESTOCK_NEAR_PAID"] == "true", "正常交货被拒（过度收紧）"
    assert data["RESTOCK_COOLDOWN_BLOCKED"] == "true", "冷却内可以重复领工资（旧版就是这样）"
    assert data["RESTOCK_OTHER_SHOP_ALLOWED"] == "true", "同一玩家跑完另一家店被冷却吞掉（冷却键漏了 shop）"
    assert data["RESTOCK_AFTER_COOLDOWN_PAID"] == "true", "冷却过后领不到（过度收紧）"
    assert data["RESTOCK_BAD_ARGS_SAFE"] == "true", "shop 为 nil / 不存在的店会抛错"


def test_restock_pay_requires_a_paid_delivery_session():
    """冷却只限速，不证明「跑了这一趟」。R0（2026-11-13）加押金会话 + 每趟次数上限。"""
    data = run_probe("shops_probe.lua", "[qb]/qb-shops")
    assert data["RESTOCK_NO_SESSION_BLOCKED"] == "true", "没付押金也能在交货点领钱（旧版就是这样）"
    assert data["RESTOCK_SESSION_OPEN_PAID"] == "true", "付了押金反而领不到（过度收紧）"
    assert data["RESTOCK_SESSION_CAP"] == "true", (
        f"一趟能结算超过 MaxDeliveries 次：实测 {data.get('RESTOCK_SESSION_CAP_COUNT')}"
    )
    assert data["RESTOCK_SESSION_CLOSED_BLOCKED"] == "true", "还车（关闭会话）后仍能继续领钱"


def test_delivery_loop_is_trucker_only_and_pays_rep():
    """R0.3：送货循环归 trucker。租车与结算都受职业门约束；每站给 delivery 声望。"""
    data = run_probe("shops_probe.lua", "[qb]/qb-shops")
    assert data["RENTAL_NON_TRUCKER_BLOCKED"] == "true", "非 trucker 也能租车（收了押金却结算不了 = 骗钱）"
    assert data["RENTAL_TRUCKER_ALLOWED"] == "true", "在岗 trucker 租不到车（过度收紧）"
    assert data["RESTOCK_OFFDUTY_BLOCKED"] == "true", "在岗起租后下班仍能结算（职业门只看了一次）"
    assert data["RESTOCK_REP_GRANTED"] == "true", "跑完一站没有 delivery 声望"
    assert data["RESTOCK_NO_BONUS_ITEM"] == "true", (
        "每站还额外发 cryptostick（一根 ≈ $1,000）——把这一档收益抬到 $6k+/h"
    )


def test_payslip_is_not_reachable_from_clients():
    """全仓没有客户端调用点，却按客户端给的 drops 发钱。"""
    data = run_probe("shops_probe.lua", "[qb]/qb-shops")
    assert data["PAYSLIP_CLIENT_BLOCKED"] == "true", "客户端发 PaySlip(99999) 就能印钞（旧版就是这样）"


def test_shop_stock_updates_are_bounded():
    data = run_probe("shops_probe.lua", "[qb]/qb-shops")
    assert data["STOCK_DECREMENT_OK"] == "true", "正常结账扣库存被拒（过度收紧）"
    assert data["STOCK_NEGATIVE_BLOCKED"] == "true", "负数数量会把库存加上去（旧版就是这样）"
    assert data["STOCK_BAD_SLOT_SAFE"] == "true", "坏 slot 打断事件线程（旧版就是这样）"


def test_open_shop_requires_being_there():
    data = run_probe("shops_probe.lua", "[qb]/qb-shops")
    assert data["OPENSHOP_NIL_DATA_SAFE"] == "true", "data 为 nil 时抛错（旧版就是这样）"
    assert data["OPENSHOP_NEAR_ALLOWED"] == "true", "站在店门口开不了界面（过度收紧）"
    assert data["OPENSHOP_FAR_BLOCKED"] == "true", "能在任意位置开任意店（旧版就是这样）"
