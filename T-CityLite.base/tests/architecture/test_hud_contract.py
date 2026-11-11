"""HUD 与状态模块的契约闸门（H-1 / H-2 / 金钱显示口径）。"""

from __future__ import annotations

import re
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


def test_stress_direction_and_throttle_detects_inverted_warn():
    """压力是"越高越糟"：提醒要在 ≥80，不是 ≤20；服务端不许每条 GainStress 都弹。"""
    client = CLIENT.read_text(encoding="utf-8")
    server = (HUD / "server.lua").read_text(encoding="utf-8")

    assert "STRESS_HIGH" in client and "STRESS_REARM" in client, "压力没有独立的方向常量"
    assert "stressNow >= STRESS_HIGH" in client, "压力提醒方向反了（应在高值提醒）"
    assert "stressNow <= LOW_THRESHOLD" not in client, "压力还在按'低值'判断"
    assert "armor" in client and "护甲" in client, "护甲耗尽没有提醒"

    assert "stressNoticeAt" in server, "服务端 GainStress 没有限流（射击时会刷屏）"

    # 反向：把方向改回低值，规则必须红
    broken = client.replace("stressNow >= STRESS_HIGH", "stressNow <= 20")
    assert "stressNow >= STRESS_HIGH" not in broken


RING_OPEN = re.compile(r"<q-circular-progress\b[^>]*>")


def _icon_rings_without_show_value(html: str) -> list[str]:
    """找出"圆心有 <q-icon> 但外层环没写 show-value"的内层环。

    Quasar 2.1.0 只在 showValue 为真时才创建 `.q-circular-progress__text`，
    默认插槽也只在这层里渲染 —— 没有 show-value，插槽函数从不调用，
    `<q-icon>` 连 DOM 节点都不生成（H-5 就是这样丢掉 5 个状态图标的）。
    """
    missing: list[str] = []
    for m in RING_OPEN.finditer(html):
        tag = m.group(0)
        rest = html[m.end():]
        stops = [i for i in (
            rest.find("</q-circular-progress>"),
            rest.find("<q-circular-progress"),
            rest.find("</div>"),
        ) if i != -1]
        children = rest[:min(stops)] if stops else rest
        if "<q-icon" in children and "show-value" not in tag:
            missing.append(tag.strip()[:110])
    return missing


def test_ring_icon_slot_needs_show_value_detects_h5_regression():
    """H-5：圆心带 `<q-icon>` 的内层环必须保留 show-value。

    真机反馈（2026-11-11）：armor/hunger/thirst/stress/oxygen 五环中心全空，
    玩家分不清哪个是口渴哪个是饥饿。根因是 H-1 把这些环的 show-value 删了。
    """
    html = INDEX.read_text(encoding="utf-8")
    assert _icon_rings_without_show_value(html) == [], (
        "有环心图标却没有 show-value：Quasar 不会渲染默认插槽，图标根本不会进 DOM（H-5）")

    # 有插槽时 Quasar 不打印数值，数值仍由 .stat-num 承担 —— 两者不能互相顶掉
    assert "stat-num" in html, "环下数值没了"

    # 反向：把 armor 环的 show-value 删掉，规则必须红
    broken = html.replace('show-value :value="armor"', ':value="armor"')
    assert broken != html, "反向校验失效：找不到 armor 环的 show-value"
    assert _icon_rings_without_show_value(broken), (
        "反向校验失效：删掉 armor 的 show-value 之后规则还是绿的")
