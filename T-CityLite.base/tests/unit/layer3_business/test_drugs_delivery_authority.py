"""qb-drugs 配送：押金 / 报酬 / 时间窗口必须由**服务端**算，客户端改包改不动钱。

背景（2026-11-07，P1-5 阶段 F）：`acceptDelivery` 与 `successDelivery` 原来直接采信客户端
`deliveryData` 里的 `deposit` / `basePayout` / `amount` / `fastTime`。构造一个包就能：

| 攻击 | 旧行为（实测） |
|---|---|
| `{item=1, amount=999, deposit=0}` | 不交押金拿到 **999** 个 `weed_brick` |
| 结算时 `{deposit=1e9, basePayout=1e9, fastTime=1e9}` | `AddMoney(finalReward + deposit)` → 一次 **2,200,000,000** |
| 重放同一次结算 | 又发一次（没有"已结算"标记） |

现在接单时按 Config 算好并存档（`activeDeliveries[src]`），结算只认这份档；数量固定 1；
背包里没有货就不发钱；结算一次即消费掉记录。

做法：`fixtures/drugs_delivery_probe.lua` 用 mock 的 FiveM 运行时真的触发这两个 net event，
把「扣了多少 / 给了多少货 / 发了多少钱」打成 `KEY|VALUE` 行，这里逐条断言。
"""

from __future__ import annotations

import subprocess
from pathlib import Path

BASE = Path(__file__).resolve().parents[3]
RESOURCE = BASE / "resources" / "[qb]" / "qb-drugs"
PROBE = Path(__file__).resolve().parent / "fixtures" / "drugs_delivery_probe.lua"


def _run_probe() -> dict[str, list[str]]:
    proc = subprocess.run(
        ["lua5.4", PROBE.as_posix(), RESOURCE.as_posix()],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert proc.returncode == 0, f"probe 失败：\n{proc.stderr}\n{proc.stdout}"

    parsed: dict[str, list[str]] = {}
    for line in proc.stdout.splitlines():
        if "|" not in line:
            continue
        key, _, value = line.partition("|")
        parsed.setdefault(key, []).append(value)
    assert "HANDLER_ERROR" not in parsed, f"handler 抛错：{parsed.get('HANDLER_ERROR')}"
    return parsed


def test_accept_uses_server_side_deposit_and_quantity():
    data = _run_probe()
    # 客户端说 deposit=0、amount=999：押金必须按 Config 算（1000 × 0.5 = 500），数量固定 1
    assert data["DEDUCTED"][0] == "500", "押金没有按 Config 计算，客户端传的 deposit 仍被采信"
    assert data["EXPECTED_DEPOSIT"][0] == "500", "Config 变了？同步更新本断言"
    assert data["ITEM_AMOUNT"][0] == "1", "发货数量仍取客户端传的 amount（可一次刷 999 个）"
    assert data["CASH_AFTER_ACCEPT"][0] == "99500"


def test_settlement_ignores_client_supplied_deposit():
    data = _run_probe()
    paid = float(data["PAID"][0])
    # 正常结算 = 报酬 1000（合格档）× 1.0 + 押金 500 = 1500
    assert paid == 1500, f"结算金额不是服务端算出来的 1500，而是 {paid}"
    assert data["PAID_REASON"][0] == "配送奖励(合格)", "时间档位仍取客户端的 fastTime/maxTime"
    assert data["CASH_AFTER_SETTLE"][0] == "101000", "现金流水对不上（可能多为退款/奖励）"


def test_settlement_is_single_use_and_rejects_forged_payloads():
    data = _run_probe()
    # 顺序：replay / fake-item / missing-item / double-accept / source-reuse / after-drop
    assert data["PAID_COUNT_DELTA"][0] == "0", "重放结算又发了一次钱（缺『已结算』标记）"
    assert data["DEDUCT_COUNT_DELTA"][0] == "0", "伪造商品 key 仍然扣了钱（没有校验 Config.DeliveryItems）"
    assert data["PAID_COUNT_DELTA"][1] == "0", "背包里没有货也发了钱"


def test_only_one_active_delivery_per_player():
    data = _run_probe()
    # 第二单必须被拒：只应有 1 次扣款（第一单 500），否则记录被覆盖 → 押金白扣、货白留
    assert data["DEDUCT_COUNT_DELTA"][1] == "1", (
        f"连开两单时扣款 {data['DEDUCT_COUNT_DELTA'][1]} 次（应为 1）—— 第二单覆盖了第一单的记录"
    )


def test_dropped_player_cannot_settle_or_be_impersonated():
    data = _run_probe()
    # source 被复用给别的角色 → 旧记录不结算
    assert data["PAID_COUNT_DELTA"][2] == "0", "source 复用后新角色结算了别人留下的记录"
    # 掉线回调清记录后，同一个 source 再发结算也不发钱
    assert data["PAID_COUNT_DELTA"][3] == "0", "playerDropped 没有清记录，掉线后仍能结算"


def test_drop_settlement_refunds_only_when_goods_are_recovered():
    data = _run_probe()
    # 掉线时货还在背包 → 重新上线：回收货物 + 全额退押金，净额 0
    assert data["REFUND"][0] == "500", "重新上线没有退还押金（玩家白丢 500）"
    assert data["ITEM_LEFT"][0] == "0", "退还押金了但货物没回收 —— 等于白送一件货"
    # 掉线前货已被用掉 → 押金不退
    assert data["REFUND"][1] == "0", "货都不在了还退押金，等于可以白拿一件货"


def test_drop_settlement_survives_missing_inventory_api():
    data = _run_probe()
    # qb-inventory 未就绪（RemoveItem 为 nil）时不结算、也不丢 pending
    assert data["REFUND"][2] == "0", "qb-inventory 未就绪时仍然动了钱"
    # 下次上线（API 已注入）再结算，押金要补退
    assert data["REFUND"][3] == "500", "pending 被提前消费，玩家押金永久丢失"


def test_dealer_sale_requires_the_goods_before_paying():
    """卖货给 dealer：必须先真的扣掉货才发钱。

    旧实现忽略 `RemoveItem` 的返回值 —— 库存打空时随便调一次
    `updateDealerItems({slot=1}, 999, 'Sandy Dealer')` 就直接 `AddMoney(999 * 15)`。
    实测（旧代码）PAID=14985 且背包一件没有；假 slot 还会 `attempt to index a nil value` 崩服务端。
    """
    data = _run_probe()
    # 专用 key，不依赖 PAID 列表的位置（新增场景不会让断言错位）
    assert data["DEALER_PAID_NO_ITEMS"][0] == "0", "背包里没货也发钱了（印钱）"
    assert data["DEALER_PAID_FAKE_SLOT"][0] == "0", "伪造 slot 不该发钱"
    assert data["DEALER_PAID_NAME_MISMATCH"][0] == "0", "itemData.name 与 slot 不匹配时不该发钱"
    assert data["DEALER_PAID_WITH_ITEMS"][0] == "75", "正常卖 5 件（单价 15）应得 75"
    assert data["DEALER_ITEM_LEFT"][0] == "0", "发钱了但货没扣掉"
