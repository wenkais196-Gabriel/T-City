"""test_client_shared.py — 客户端共享助手（真跑 Lua，只桩 FiveM 原生函数）。

为什么值得写：`client/shared.lua` 的产物全是"发出去的事件"和"打印的行"，在服务端日志里
看不见。但它做的事（加载后发就绪信标）正是判断"客户端有没有加载到新代码"的依据——
如果信标本身发不出去，整套可观测性就是空的。

这里把 FiveM 原生函数全部打桩（TriggerServerEvent / GetCurrentResourceName /
GetResourceMetadata / CreateThread / Wait / 绘图与模型函数），然后**执行真文件**，
断言它发了什么。客户端那一半在没有真玩家的环境下，这是能拿到的最强证据。
"""

from __future__ import annotations

import shutil
import subprocess
import textwrap
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
SHARED = BASE / "resources" / "[standalone]" / "core-framework" / "client" / "shared.lua"

STUBS = """
-- ── FiveM 原语桩 ──────────────────────────────────────────
__events = {}          -- { {name=..., args={...}}, ... }
__threads = {}
__prints = {}
__now = 1000
__loaded = {}
__modelInCdimage = {}

function TriggerServerEvent(name, ...) __events[#__events + 1] = { name = name, args = { ... } } end
function CreateThread(fn) __threads[#__threads + 1] = fn end
function Wait(_ms) end
Citizen = { Wait = function(_ms) end }
function GetGameTimer() return __now end
function GetCurrentResourceName() return 'custom-police' end
function GetResourceMetadata(res, key, _index) return key == 'version' and '1.7.0' or nil end
function GetConvarInt(name, default) return default end
function print(line) __prints[#__prints + 1] = tostring(line) end
-- 绘图 / 文本
function SetTextScale() end
function SetTextFont() end
function SetTextProportional() end
function SetTextColour() end
function BeginTextCommandDisplayText() end
function SetTextCentre() end
function AddTextComponentSubstringPlayerName() end
function SetDrawOrigin() end
function EndTextCommandDisplayText() end
function DrawRect() end
function ClearDrawOrigin() end
-- 模型
function IsModelInCdimage(hash) return __modelInCdimage[hash] == true end
function HasModelLoaded(hash) return __loaded[hash] == true end
function RequestModel(hash) __loaded[hash] = true end
function SetModelAsNoLongerNeeded(hash) __loaded[hash] = nil end
"""


def lua() -> str:
    exe = shutil.which("lua5.4") or shutil.which("lua")
    if not exe:
        pytest.skip("lua5.4 不可用")
    return exe


def run(body: str) -> dict:
    script = STUBS + "\n" + SHARED.read_text(encoding="utf-8") + "\n" + textwrap.dedent(body)
    proc = subprocess.run([lua(), "-"], input=script, capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, f"Lua 执行失败:\n{proc.stderr}"
    out = {}
    for line in proc.stdout.strip().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def test_the_file_prints_one_boot_line():
    out = run("__say = function(s) io.write(tostring(s) .. string.char(10)) end\n"
              "__say('prints=' .. #__prints)\n"
              "__say('line=' .. tostring(__prints[1]))")
    assert out["prints"] == "1", "启动自证只该有一行（F8 里刷屏很烦）"
    assert "client shared ready" in out["line"]


def test_it_defers_the_beacon_to_a_thread_and_sends_it_there():
    out = run("""
        __say = function(s) io.write(tostring(s) .. string.char(10)) end
        __say('threads=' .. #__threads)
        __say('events_before=' .. #__events)
        for _, fn in ipairs(__threads) do fn() end
        __say('events_after=' .. #__events)
        __say('name=' .. tostring(__events[1] and __events[1].name))
        __say('arg1=' .. tostring(__events[1] and __events[1].args[1]))
        __say('arg2=' .. tostring(__events[1] and __events[1].args[2]))
    """)
    assert out["threads"] == "1", "信标必须延后发（否则可能早于服务端注册）"
    assert out["events_before"] == "0"
    assert out["events_after"] == "1"
    assert out["name"] == "core-framework:server:clientReady"
    assert out["arg1"] == "custom-police", "信标要带上宿主资源名"
    assert out["arg2"] == "1.7.0", "信标要带上版本，才能判断是不是新客户端"


def test_report_sends_a_sanitised_kind_and_message():
    out = run("""
        __say = function(s) io.write(tostring(s) .. string.char(10)) end
        CFShared.Report('error', 'boom')
        CFShared.Report('nonsense', 'fallback to info')
        CFShared.Report('error', '')
        __say('count=' .. #__events)
        __say('k1=' .. tostring(__events[1].args[1]))
        __say('m1=' .. tostring(__events[1].args[2]))
        __say('k2=' .. tostring(__events[2].args[1]))
    """)
    assert out["count"] == "2", "空消息不该发"
    assert out["k1"] == "error"
    assert out["m1"] == "boom"
    assert out["k2"] == "info", "未知 kind 必须降级成 info 而不是原样转发"


def test_load_model_guards_cdimage_and_timeout():
    out = run("""
        __say = function(s) io.write(tostring(s) .. string.char(10)) end
        __say('missing=' .. tostring(CFShared.LoadModel(12345)))
        __modelInCdimage[777] = true
        __say('present=' .. tostring(CFShared.LoadModel(777)))
        __say('bad=' .. tostring(CFShared.LoadModel(nil)))
        -- 超时：模型在 cdimage 里但永远加载不出来
        __modelInCdimage[888] = true
        local orig = RequestModel
        RequestModel = function() end
        __now = 1000
        local ticks = 0
        Citizen.Wait = function() ticks = ticks + 1; __now = __now + 100 end
        __say('timeout=' .. tostring(CFShared.LoadModel(888, 500)))
        __say('ticks_positive=' .. tostring(ticks > 0))
    """)
    assert out["missing"] == "false", "不在 cdimage 里必须直接 false（服务器没这个模型）"
    assert out["present"] == "true"
    assert out["bad"] == "false"
    assert out["timeout"] == "false", "超时必须返回 false，否则线程永久卡住"
    assert out["ticks_positive"] == "true"


def test_draw_text_releases_draw_origin():
    """ClearDrawOrigin 漏掉会让后续所有 2D 绘制偏移到世界坐标——肉眼可见但难查。"""
    src = SHARED.read_text(encoding="utf-8")
    body = src[src.index("function CFShared.DrawText3D"):]
    body = body[:body.index("\nend\n")]
    assert "ClearDrawOrigin()" in body
