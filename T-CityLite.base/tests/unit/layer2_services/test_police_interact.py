"""test_police_interact.py — 区域内按 E 的唯一实现（真跑 Lua，桩只替换原生）。

收口前 `job.lua` 有 8 段一模一样的逐帧轮询（值班、储物柜、垃圾桶、直升机、拖车场、车库、
指纹、证据），每段 14~17 行，差别只有"哪个 flag""要不要在车里""按下去做什么"。
这里钉住统一后的行为，免得以后再拷一份出去：

* 区域外（active 为假）→ 线程退出，不按键；
* 不在警察职业（allowed 为假）→ 线程退出；
* 需要车的场合：不在车里时不响应，但仍保持存活；
* 按下 → onPress 一次、after 一次，然后退出；
* onPress 返回 false → 不退出（留给"这次不能用"的场景）。
"""

from __future__ import annotations

import shutil
import subprocess
import textwrap
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
SRC = BASE / "resources" / "[custom]" / "custom-police" / "client" / "interact.lua"

STUBS = """
__threads = {}
function CreateThread(fn) __threads[#__threads + 1] = fn end
__calls = { ped = 0, coords = 0, control = 0, waits = 0 }
__inVehicle = false
__keyDown = false
function PlayerPedId() __calls.ped = __calls.ped + 1; return 1 end
function IsPedInAnyVehicle(_ped, _atGetIn) return __inVehicle end
function IsControlJustReleased(_group, _control)
    __calls.control = __calls.control + 1
    return __keyDown
end
__stopAfter = 1e9
function Wait(_ms)
    __calls.waits = __calls.waits + 1
    if __calls.waits >= __stopAfter then error('__stop', 0) end   -- 死循环的安全阀
end
function __say(t) io.write(tostring(t) .. string.char(10)) end
"""


def lua() -> str:
    exe = shutil.which("lua5.4") or shutil.which("lua")
    if not exe:
        pytest.skip("lua5.4 不可用")
    return exe


def run(body: str) -> dict:
    script = STUBS + "\n" + SRC.read_text(encoding="utf-8") + "\n" + textwrap.dedent(body)
    proc = subprocess.run([lua(), "-"], input=script, capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, f"Lua 执行失败:\n{proc.stderr}"
    out = {}
    for line in proc.stdout.strip().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def test_rejects_missing_callbacks():
    out = run("""
        __say('none=' .. tostring(PoliceInteract.Watch(nil)))
        __say('no_press=' .. tostring(PoliceInteract.Watch({ active = function() return true end })))
        __say('threads=' .. #__threads)
    """)
    assert out["none"] == "false"
    assert out["no_press"] == "false"
    assert out["threads"] == "0", "参数不全时不该起线程"


def test_press_fires_once_and_ends_the_thread():
    out = run("""
        local pressed, after = 0, 0
        __keyDown = true
        PoliceInteract.Watch({
            active = function() return true end,
            onPress = function() pressed = pressed + 1 end,
            after = function() after = after + 1 end,
        })
        __threads[1]()
        __say('pressed=' .. pressed)
        __say('after=' .. after)
        __say('control_checks=' .. __calls.control)
    """)
    assert out["pressed"] == "1"
    assert out["after"] == "1"
    assert out["control_checks"] == "1", "按下后就该退出，不能继续每帧查"


def test_leaving_the_zone_ends_the_thread_without_pressing():
    out = run("""
        local inside = true
        local pressed = 0
        __keyDown = true
        PoliceInteract.Watch({
            active = function() return inside end,
            onPress = function() pressed = pressed + 1 end,
        })
        inside = false
        __threads[1]()
        __say('pressed=' .. pressed)
        __say('controls=' .. __calls.control)
    """)
    assert out["pressed"] == "0"
    assert out["controls"] == "0", "离开区域后不该再查按键"


def test_wrong_job_ends_the_thread():
    out = run("""
        local pressed = 0
        __keyDown = true
        PoliceInteract.Watch({
            active = function() return true end,
            allowed = function() return false end,
            onPress = function() pressed = pressed + 1 end,
        })
        __threads[1]()
        __say('pressed=' .. pressed)
    """)
    assert out["pressed"] == "0"


def test_require_vehicle_ignores_the_key_until_the_player_is_in_a_car():
    out = run("""
        local pressed = 0
        __keyDown = true
        PoliceInteract.Watch({
            active = function() return true end,
            requireVehicle = true,
            onPress = function() pressed = pressed + 1 end,
        })
        -- 不在车里：跑两轮（靠安全阀打断死循环），按键不该生效
        __stopAfter = 2
        pcall(__threads[1])
        __say('pressed_outside=' .. pressed)
        __say('ped_calls=' .. __calls.ped)

        -- 上车后重跑：第一轮就该响应并退出
        __inVehicle = true
        __calls.waits = 0
        __stopAfter = 5
        pcall(__threads[1])
        __say('pressed_inside=' .. pressed)
    """)
    assert out["pressed_outside"] == "0", "不在车里时按键不该触发"
    assert out["pressed_inside"] == "1", "上车后按键应当触发一次"
    assert int(out["ped_calls"]) >= 2, "requireVehicle 必须真的问过 IsPedInAnyVehicle"


def test_on_press_can_refuse_and_keep_watching():
    out = run("""
        local attempts = 0
        __keyDown = true
        PoliceInteract.Watch({
            active = function() return true end,
            onPress = function() attempts = attempts + 1; return false end,
        })
        __say('exists=' .. tostring(PoliceInteract.Watch ~= nil))
    """)
    assert out["exists"] == "true"
    src = SRC.read_text(encoding="utf-8")
    assert "if opts.onPress() ~= false then" in src, (
        "onPress 返回 false 时必须继续等待，而不是把线程结束掉")
