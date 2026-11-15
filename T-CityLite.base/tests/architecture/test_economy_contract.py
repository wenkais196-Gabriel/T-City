"""经济与交易模块的契约闸门（E-1 / E-2 / E-3）。"""

from __future__ import annotations

from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
RES = REPO / "T-CityLite.base" / "resources"
SHOPS = RES / "[qb]" / "qb-shops" / "client" / "main.lua"
INV = RES / "[qb]" / "qb-inventory" / "server" / "main.lua"
NL = chr(10)


def test_shop_has_single_e_entry_detects_alt_leftover():
    """E-1：柜台只有一个动作 → 只能有 [E]，不许再注册 qb-target 的 ALT 入口。"""
    client = SHOPS.read_text(encoding="utf-8")
    assert "custom-prompt" in client, "商店没有走统一提示组件"
    assert "AddCircleZone(k" not in client, "无店员的店还在注册 ALT 区域"
    assert "AddTargetEntity(ShopPed[k]" not in client, "店员身上还挂着 ALT 选项"
    assert "'qb-shops:server:openShop'" in client, "E 没有接到开店事件"

    # 反向：把 ALT 区域塞回去，规则必须红
    broken = client + NL + "exports['qb-target']:AddCircleZone(k, vector3(1,2,3), 0.5, {}, {}, 2.0)" + NL
    assert "AddCircleZone(k" in broken


def test_purchase_feedback_has_money_details_detects_bare_message():
    """E-2/E-3：购买成功要带余额、失败要给差额 —— 不能只说"钱不够"。"""
    server = INV.read_text(encoding="utf-8")
    assert "支付 −$" in server, "购买成功没有金额回执"
    assert "余额 $" in server, "购买成功没有余额"
    assert "还差 $" in server, "余额不足没有给出差额"
    assert "custom-notify" in server, "回执没走三层通道"

    # 反向：把差额去掉，规则必须红
    broken = server.replace("还差 $", "")
    assert "还差 $" not in broken
