"""真机验收用的 `/tpme x y z`（devcmd 白名单里的一条）。

为什么需要它：真机验收要站到 qb-target 的 box zone 上（老板菜单等），但 GTA 把 OS 光标
锁在屏幕角、合成鼠标点击进不了 CEF，仓里又没有任何传送命令 —— 没有它，人只能靠跑图。
安全边界与 devcmd 完全一致：`agent_devcmd_enabled` 默认关，且只接受服务端下发的 adc。
"""

from __future__ import annotations

import pathlib

BASE = pathlib.Path(__file__).resolve().parents[2]
CLIENT = BASE / "resources" / "[custom]" / "custom-agent-client" / "client" / "main.lua"


def check(source: str) -> list[str]:
    errors: list[str] = []
    # 命令必须存在，并且自己再判一次 convar（不能只依赖 devcmd 白名单）
    if "RegisterCommand('tpme'" not in source:
        errors.append("缺少 RegisterCommand('tpme')")
    tpme_at = source.find("RegisterCommand('tpme'")
    if tpme_at >= 0:
        # 只取 tpme 自己的函数体：固定窗口会把后面 devcmd 的 convar 判断一起框进来，
        # 于是"删掉 tpme 的门禁"这种注入永远抓不到（假绿）。
        close = source.find("end, false)", tpme_at)
        body = source[tpme_at: close + 11] if close > tpme_at else source[tpme_at:tpme_at + 700]
        if "agent_devcmd_enabled" not in body:
            errors.append("tpme 没有自己的 convar 门禁（devcmd 关了它还能用）")
        if "SetEntityCoords" not in body:
            errors.append("tpme 没有调用 SetEntityCoords")
        if "tonumber(args[1])" not in body:
            errors.append("tpme 没有把参数转数字（会接受任意字符串）")
    # 白名单必须放行这条命令，否则 devcmd 只会回 not_allowed
    if "'^tpme %-?%d+%.?%d* %-?%d+%.?%d* %-?%d+%.?%d*$'" not in source:
        errors.append("DEVCMD_ALLOWED 里没有 tpme 的坐标 pattern")
    return errors


def test_tpme_wiring_detects_gutted_source() -> None:
    """当前源码合规 + 拿掉任一要素都必须被抓（`gate_coverage` 按名字认这条为"已证明"）。"""
    source = CLIENT.read_text(encoding="utf-8")
    assert not check(source), "\n".join(check(source))
    gutted = source.replace("RegisterCommand('tpme'", "RegisterCommand('tpmeX'", 1)
    assert check(gutted), "拿掉命令注册后闸门仍然全绿"
    unlisted = source.replace("'^tpme %-?%d+%.?%d*", "'^tpx %-?%d+%.?%d*", 1)
    assert check(unlisted), "拿掉白名单 pattern 后闸门仍然全绿"
    ungated = source.replace("if GetConvar('agent_devcmd_enabled', '0') ~= '1' then return end\n    local x, y, z",
                             "local x, y, z", 1)
    assert check(ungated), "去掉 tpme 自己的 convar 门禁后闸门仍然全绿"
