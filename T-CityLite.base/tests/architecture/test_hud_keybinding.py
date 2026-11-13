"""键位归属：`I` 只能留给载具中控屏（qb-hud 的设置菜单不许再抢这个键）。

背景（2026-11-13 真机）：qb-hud 早先注册过 `RegisterKeyMapping('hud', …, 'I')`，后来那行被注释掉了，
但**五M 把绑定持久化在玩家本机**（`fivem.cfg` 里 `rbind qb-hud KEYBOARD I "hud"`），删代码不删绑定。
于是按 I 同时触发 `hud`（弹 HUD 设置、拿走 NUI 焦点）和 `dashboard`（中控屏，被挤掉）。
修法：HUD 设置改名 `hudsettings`，旧名 `hud` 只做空操作接住残留绑定。

判定逻辑写成**可喂合成文本的纯函数**，所以每条规则都能当场证明会红：
合成坏形状 → 必须被拒；真实仓库 → 必须干净。正反断言放在同一个用例里，
避免「规则存在但从未被证明」再攒新的技术债。
"""

from __future__ import annotations

import re
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
HUD = BASE / "resources/[qb]/qb-hud/client.lua"
DASHBOARD = BASE / "resources/[system]/tcity-dashboard/client/main.lua"


def _active_code(text: str) -> str:
    """去掉整行注释后的代码（注释掉的键位映射是允许的，不能算违规）。"""
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("--"))


def i_key_binding_violations(text: str) -> list[str]:
    """qb-hud 里生效的 `RegisterKeyMapping(..., 'I')`：有一条就算违规。"""
    return re.findall(r"RegisterKeyMapping\([^)]*['\"]I['\"]", _active_code(text))


def legacy_hud_command_body(text: str) -> str:
    """取 `RegisterCommand('hud', function() … end` 的函数体；没注册时返回哨兵值。"""
    match = re.search(r"RegisterCommand\('hud',\s*function\(\)(.*?)\bend", _active_code(text), re.S)
    return "<not-registered>" if not match else match.group(1).strip()


def test_i_binding_gate_detects_a_reintroduced_bind_and_clears_the_real_tree():
    # 反向：合成的坏形状必须被拒
    bad = "\n".join([
        "RegisterKeyMapping('hud', 'Open HUD Settings', 'keyboard', 'I')",
        "RegisterKeyMapping('other', 'x', 'keyboard', 'J')",
    ])
    assert i_key_binding_violations(bad), "规则没抓住重新出现的 I 键绑定（等于没有这条闸）"

    # 正向控制：注释掉的旧映射、别的键都不许被算成违规
    assert not i_key_binding_violations(
        "-- RegisterKeyMapping('hud', 'Open HUD Settings', 'keyboard', 'I')"
    ), "把注释掉的键位也算成违规（会误报）"

    # 真实仓库必须干净
    assert not i_key_binding_violations(HUD.read_text(encoding="utf-8")), (
        "qb-hud 又把 I 键绑上了 —— 会和载具中控屏抢键。"
        "要临时用键位请让玩家在五M设置的按键绑定里自己绑，或改用 /hudsettings。"
    )


def test_legacy_hud_command_gate_rejects_logic_and_accepts_the_empty_noop():
    # 反向：给旧命令塞任何界面逻辑都必须被拒
    with_logic = "RegisterCommand('hud', function() SendNUIMessage({action='open'}) end, false)"
    assert legacy_hud_command_body(with_logic) != "", "旧命令里加了逻辑却没被拦住（按 I 会重新弹界面）"

    # 反向：命令没注册时要能被识别出来（否则残留绑定变成未知命令）
    assert legacy_hud_command_body("RegisterCommand('hudsomething', function() end)") == "<not-registered>"

    # 真实仓库：旧命令必须存在、函数体必须为空
    real = HUD.read_text(encoding="utf-8")
    body = legacy_hud_command_body(real)
    assert body != "<not-registered>", "旧命令名 `hud` 没注册 —— 玩家本机残留的 I 绑定会变成未知命令"
    assert body == "", f"旧命令 `hud` 里又加了逻辑（唯一职责是静默接住残留绑定）：{body[:120]}"

    # 正向控制：改名后的真实入口存在，且中控屏仍占着 I
    assert "RegisterCommand('hudsettings'" in _active_code(real), "HUD 设置的入口改名后不存在了"
    dashboard = _active_code(DASHBOARD.read_text(encoding="utf-8"))
    assert re.search(r"RegisterKeyMapping\('dashboard',[^)]*'I'\)", dashboard), (
        "载具中控屏不再占用 I 键 —— 现在按 I 什么都没发生"
    )
