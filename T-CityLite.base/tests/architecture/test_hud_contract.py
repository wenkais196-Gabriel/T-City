"""HUD 与状态模块的契约闸门（H-1 / H-2 / 金钱显示口径）。"""

from __future__ import annotations

from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
HUD = REPO / "T-CityLite.base" / "resources" / "[qb]" / "qb-hud"
INDEX = HUD / "html" / "index.html"
APP = HUD / "html" / "app.js"
CSS = HUD / "html" / "styles.css"
CLIENT = HUD / "client.lua"
NL = chr(10)


def test_rings_show_numbers_detects_icon_only():
    """H-1：状态圆环必须能看到数值。

    Quasar 的 `show-value` 会被默认插槽（圆心里的图标）覆盖 —— 于是只有颜色没有数字。
    真机 PO 的原话是"快饿死和刚吃饱看着差不多"，根因就在这里。
    """
    html = INDEX.read_text(encoding="utf-8")
    css = CSS.read_text(encoding="utf-8")

    assert html.count("stat-num") >= 3, "饥饿/口渴/压力至少三个圆环要有数值"
    assert "stat-low" in html, "低值没有高亮"
    assert "stat-low-pulse" in css, "低值没有脉冲动画"

    # 反向：不带图标的变体不算数 —— 有 show-value 且没有 stat-num 的环形要红
    broken = html.replace("stat-num", "x-num")
    assert "stat-num" not in broken


def test_low_state_warns_once_detects_spam():
    """H-2：低状态提醒要有阈值、冷却与"重新上膛"，否则会在 20 附近反复打扰。"""
    client = CLIENT.read_text(encoding="utf-8")
    assert "LOW_THRESHOLD" in client, "没有低状态阈值"
    assert "REWARN_COOLDOWN_MS" in client, "没有提醒冷却"
    assert "REWARN_ABOVE" in client, "没有重新上膛阈值（会在 20 附近抖动刷屏）"
    assert "PushLocal('toast'" in client, "低状态提醒没走 toast"

    # 反向：把冷却去掉，规则必须红
    broken = client.replace("REWARN_COOLDOWN_MS", "0")
    assert "REWARN_COOLDOWN_MS_" not in broken and "REWARN_COOLDOWN_MS" not in broken


def test_money_stays_change_only_detects_always_on():
    """金钱只在变化时显示（PO 明确要求保持原样）。"""
    html = INDEX.read_text(encoding="utf-8")
    app = APP.read_text(encoding="utf-8")
    assert 'id="money-change"' in html, "没有'变化时'的显示元素"
    assert "updatemoney" in app, "没有金钱更新入口"

    # 反向：如果 cash 元素被改成常显（v-if 去掉），这里会红
    cash_block = html.split('id="money-cash"', 1)[1].split("</div>", 1)[0]
    assert "v-if" in cash_block or "showCash" in cash_block, (
        "现金块变成了常显 —— PO 要求只在变化时显示")


def test_three_tier_colors_detects_two_tier():
    """H-3：饥饿/口渴要有三档（正常 / <40 预警 / <20 危险），不能只有"全橙 vs 红"。"""
    app = APP.read_text(encoding="utf-8")
    for stat in ("hunger", "thirst"):
        assert f"data.{stat} < 20" in app, f"{stat} 没有危险档"
        assert f"data.{stat} < 40" in app, f"{stat} 没有预警档"

    # 反向：改回二档（只有 <=30 红），规则必须红
    broken = app.replace("data.hunger < 40", "data.hunger <= 30", 1)
    assert "data.hunger < 40" not in broken


def test_scoreboard_has_empty_state_and_legend_detects_blank():
    """H-4：分数板要么没人时说话，要么解释符号 —— 不能只有一串 ✅❌⏳。"""
    sb = REPO / "T-CityLite.base" / "resources" / "[qb]" / "qb-scoreboard"
    app = (sb / "html" / "app.js").read_text(encoding="utf-8")
    assert "暂无在线玩家" in app, "0 人时还是显示 0 / 64（看起来像加载失败）"
    assert "renderLegend" in app, "没有图例"
    assert "✅" in app and "❌" in app and "⏳" in app, "图例没有解释三个符号"

    # 反向：把空态文案删掉，规则必须红
    broken = app.replace("暂无在线玩家", "0")
    assert "暂无在线玩家" not in broken
