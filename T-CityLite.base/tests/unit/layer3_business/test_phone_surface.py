"""形态（surface）：手机 / 平板是同一台设备的两种形态。

三件事必须被守住，否则很快就会长出两个产品：

1. **判定只在 Lua**（`client/core/surface_rules.lua`，纯函数）。
   keepInput 是 focus 的一部分——手机不锁输入、平板锁——所以必须在"打开"这一刻定下来，
   不能等 CEF 回话。优先级：入口 > 来电 > 载具 > 玩家偏好 > 窗口 > 默认。
2. **锁只用逐帧 DisableControlAction**。`SetPlayerControl(false)` / `FreezeEntityPosition`
   是粘性状态，循环一死人就永久卡住；逐帧禁用的最坏情况只是"这一帧没禁住"。
3. **任何关闭路径都解锁**。焦点没了但人还钉在原地，是最难查的那类故障。
"""
from __future__ import annotations

import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
PHONE = BASE / "resources" / "[custom]" / "custom-phone"
RULES = PHONE / "client/core/surface_rules.lua"
LOCK = PHONE / "client/core/device_lock.lua"
SURFACE = PHONE / "client/core/surface.lua"
MAIN = PHONE / "client/main.lua"
SHELL = PHONE / "web/src/components/DeviceShell.svelte"
SURFACE_TS = PHONE / "web/src/core/surface.ts"
APP = PHONE / "web/src/App.svelte"
LUA_BIN = shutil.which("lua5.4")


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


HARNESS = r"""
dofile(__RULES__)

local function expect(cond, msg)
    if not cond then error(msg, 2) end
end

local TABLET_MIN = { min_width = 900, min_height = 560 }

-- 1) 入口强制优先于一切
local kind, why = SurfaceRules.Decide({
    entry_surface = 'tablet', reason = 'incoming_call', in_vehicle = true,
    preference = 'phone', viewport = { width = 400, height = 800 }, limits = TABLET_MIN,
})
expect(kind == 'tablet' and why == 'entry', '入口强制必须最高优先级: ' .. tostring(kind) .. '/' .. tostring(why))

-- 2) 来电强制手机：整屏平板会锁移动，不能边开车边接电话
kind, why = SurfaceRules.Decide({
    reason = 'incoming_call', preference = 'tablet',
    viewport = { width = 1600, height = 900 }, limits = TABLET_MIN,
})
expect(kind == 'phone' and why == 'incoming_call', '来电必须小窗: ' .. tostring(kind))

-- 3) 载具中强制手机
kind, why = SurfaceRules.Decide({
    in_vehicle = true, preference = 'tablet',
    viewport = { width = 1600, height = 900 }, limits = TABLET_MIN,
})
expect(kind == 'phone' and why == 'in_vehicle', '载具中必须小窗: ' .. tostring(kind))

-- 4) 玩家偏好 tablet：窗口装得下才给平板，装不下降回手机
kind, why = SurfaceRules.Decide({
    preference = 'tablet', viewport = { width = 1600, height = 900 }, limits = TABLET_MIN,
})
expect(kind == 'tablet' and why == 'preference', '偏好 tablet + 大窗口应给平板: ' .. tostring(kind))

kind, why = SurfaceRules.Decide({
    preference = 'tablet', viewport = { width = 800, height = 500 }, limits = TABLET_MIN,
})
expect(kind == 'phone' and why == 'preference_too_small', '偏好 tablet 但窗口太小应降级: ' .. tostring(kind))

-- 视口未知（CEF 还没上报）时按玩家说的来，不擅自降级
kind, why = SurfaceRules.Decide({ preference = 'tablet', limits = TABLET_MIN })
expect(kind == 'tablet', '视口未知时应尊重偏好: ' .. tostring(kind))

kind, why = SurfaceRules.Decide({ preference = 'phone', viewport = { width = 1600, height = 900 } })
expect(kind == 'phone' and why == 'preference', '显式选手机就该是手机: ' .. tostring(kind))

-- 5) 关键回归：窗口大 ≠ 要平板。
-- FiveM 的 NUI 视口永远是整个游戏窗口，按视口升级等于"每次按 M 都锁住移动"。
for _, size in ipairs({ { 1920, 1080 }, { 2560, 1440 }, { 1600, 900 } }) do
    kind, why = SurfaceRules.Decide({
        preference = 'auto', viewport = { width = size[1], height = size[2] }, limits = TABLET_MIN,
    })
    expect(kind == 'phone' and why == 'default',
        string.format('%dx%d 无明确意图时应是手机，实际 %s/%s', size[1], size[2], tostring(kind), tostring(why)))
end

-- 8) 与 TS 的字面量一致
local expected = { 'phone', 'tablet' }
expect(#SurfaceRules.KINDS == 2, 'KINDS 应有两项')
for i, v in ipairs(expected) do
    expect(SurfaceRules.KINDS[i] == v, 'KINDS 与 web/src/core/surface.ts 不一致: ' .. tostring(SurfaceRules.KINDS[i]))
end

print('surface rules ok')
"""


@pytest.mark.skipif(LUA_BIN is None, reason="lua5.4 is not installed")
def test_surface_resolution_priority_and_thresholds(tmp_path: Path) -> None:
    script = HARNESS.replace("__RULES__", json.dumps(str(RULES)))
    harness = tmp_path / "surface_rules_harness.lua"
    harness.write_text(script, encoding="utf-8")
    result = subprocess.run([LUA_BIN, str(harness)], capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, f"{result.stdout}\n{result.stderr}"
    assert "surface rules ok" in result.stdout


def test_phone_and_tablet_literals_match_between_lua_and_typescript() -> None:
    ts = read(SURFACE_TS)
    lua = read(RULES)
    ts_kinds = set(re.findall(r"'(phone|tablet)'", ts.split("export const SURFACES")[0]))
    assert ts_kinds == {"phone", "tablet"}
    assert "SurfaceRules.PHONE = 'phone'" in lua
    assert "SurfaceRules.TABLET = 'tablet'" in lua
    # 任何一边加第三种形态都必须同改另一边，否则 SurfaceRules.KINDS 的断言会红
    assert "SURFACES" in ts and "SurfaceRules.KINDS" in lua


def _lua_code(text: str) -> str:
    """去掉 Lua 行注释：注释里可以提到"我们不用 FreezeEntityPosition"，实现里不行。"""
    return "\n".join(re.sub(r"--.*$", "", line) for line in text.split("\n"))


def test_the_lock_uses_per_frame_disabling_not_sticky_state() -> None:
    lock = _lua_code(read(LOCK))
    # 走 / 跑 / 跳 / 蹲 / 冲刺 / 移动
    for control in ("30", "31", "32", "33", "34", "35"):
        assert control in lock, f"移动锁缺 control {control}"
    assert "DisableControlAction" in lock
    # 粘性状态会让一次异常死循环变成永久钉死
    assert "FreezeEntityPosition" not in lock
    assert "SetPlayerControl" not in lock
    # 循环必须有退出条件，并且死亡/实体消失要主动解锁
    assert "while active do" in lock
    assert "IsEntityDead" in lock
    assert "DoesEntityExist" in lock


def test_every_close_path_unlocks() -> None:
    main = read(MAIN)
    close = main[main.index("local function ClosePhone"):main.index("local function OpenPhone")]
    assert "Surface.Reset()" in close, "关闭必须复位形态"
    assert "DeviceLock.End()" in close, "关闭必须解锁（焦点没了人还钉着是最难查的故障）"

    timeout_block = main[main.index("onTimeout = function()"):main.index("TriggerServerEvent('phone:server:focusState', { phase = 'open-ack-timeout' })")]
    assert "Surface.Reset()" in timeout_block and "DeviceLock.End()" in timeout_block, (
        "ack 超时是半开状态，必须同时复位和解锁")

    fix = main[main.index("RegisterCommand('phonefix'"):]
    assert "Surface.Reset()" in fix[:400] and "DeviceLock.End()" in fix[:400], "/phonefix 是救场命令，必须两样都做"


def test_opening_uses_one_decision_and_keeps_input_by_surface() -> None:
    main = read(MAIN)
    open_block = main[main.index("local function OpenPhone"):main.index("local function ClosePhone") if "local function ClosePhone" in main[main.index("local function OpenPhone"):] else len(main)]
    assert "Surface.Decide({" in open_block, "形态必须由 SurfaceRules 判定，不能就地写阈值"
    assert "Surface.Bind(kind)" in open_block
    # keepInput 跟形态绑定：手机 true（能边跑边看），平板 false（站定）
    assert "keepInput = (kind == 'phone')" in open_block
    assert "DeviceLock.Begin(kind)" in open_block
    # 平板不该播手机动画
    assert "if kind ~= 'phone' then return end" in open_block
    # 右键关闭只对手机生效
    assert "if kind == 'phone' and IsDisabledControlJustPressed(0, 25) then" in open_block


def test_client_no_longer_owns_a_boolean() -> None:
    main = read(MAIN)
    code = "\n".join(line for line in main.split("\n") if not line.strip().startswith("--"))
    assert "isPhoneOpen" not in code, (
        "设备开关只能有一个真值（Surface）；再留一个布尔就会出现两处不一致")


def test_apps_do_not_sniff_the_viewport() -> None:
    """app 只按容器宽度排布，不按 surface 身份/窗口尺寸分支。"""
    offenders = []
    for path in sorted((PHONE / "web/src/apps").rglob("*.svelte")):
        text = read(path)
        for token in ("matchMedia(", "window.innerWidth", "@media"):
            if token in text:
                offenders.append(f"{path.name}: {token}")
    assert not offenders, "app 里不许嗅探视口（差异应由容器宽度或 data-surface 决定）：\n" + "\n".join(offenders)


def test_shell_declares_surface_and_presets() -> None:
    shell = read(SHELL)
    assert 'data-surface={surface}' in shell, "外壳必须把形态写到 DOM 上，测试和样式才有锚点"
    assert "phone-wrapper" in shell, "保留 .phone-wrapper 类名：现有 NUI 测试按它选择"
    # 手机保留右下角/刘海/侧键/手势条；平板居中/无刘海/有关闭按钮
    assert "right: 30px" in shell and "bottom: 30px" in shell
    assert "{#if preset.notch}" in shell
    assert "{#if preset.homeBar}" in shell
    assert "preset.closeLabel" in shell

    ts = read(SURFACE_TS)
    assert "width: 375, height: 780" in ts
    assert "width: 1034, height: 676" in ts


def test_nui_reports_viewport_and_reads_surface_from_lua() -> None:
    app = read(APP)
    assert "fetchNui('surfaceInfo'" in app, "CEF 必须上报真实 CSS px，Lua 才不用猜"
    assert "surface.set(isSurface(data?.surface)" in app, "形态只认 Lua 下发的值"
    assert "<DeviceShell surface={$surface}>" in app
    main = read(MAIN)
    assert "RegisterNUICallback('surfaceInfo'" in main, "NUI 契约：fetchNui 必须有对应回调"
    # 换形态不等于退出：close 带 reason=switch 时不能把当前 app 清回桌面
    assert "data?.reason !== 'switch'" in app
