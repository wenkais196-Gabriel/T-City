"""EVD-02：值班执法人员要能“看见地上有东西”。

原生玩法（qb-policejob 原版，老服同款）只有「手电照着 + 1.5 米内」才浮出文字。
实机验证的结论是：地上确实有弹壳数据，但**没人能发现它**——玩家反馈就是“我看不到弹壳”。

这里加的是提示层，不是替代拾取流程：

* 值班 LEO、25 米内 → 一枚小箭头 + 距离（DrawMarker 细柱 + ▼ 文字）；
* 平民、下班 → 什么都不画（证据位置不对外暴露）；
* 超出 25 米 → 不画（避免全城箭头，也避免逐帧遍历变成热点）。

测法：真跑 client/evidence.lua（桩掉 FiveM 原生），直接调 EvidenceHints.DrawCasings。
"""

from __future__ import annotations

import re
import shutil
import subprocess
import textwrap
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
EVIDENCE = BASE / "resources" / "[custom]" / "custom-police" / "client" / "evidence.lua"

_BACKTICK = re.compile(r"`([^`\n]+)`")


def cfx_source() -> str:
    """CfxLua 的反引号哈希不是标准 Lua，换成 GetHashKey('...') 再跑。"""
    return _BACKTICK.sub(lambda m: "GetHashKey(%r)" % m.group(1), EVIDENCE.read_text(encoding="utf-8"))


STUBS = """
-- ── FiveM 原生 / 资源依赖桩 ─────────────────────────────
__markers, __texts, __events, __threads, __prints = {}, {}, {}, {}, {}
function __say(s) io.write(tostring(s) .. string.char(10)) end
function print(...) __prints[#__prints + 1] = table.concat({ ... }, ' ') end
function TriggerServerEvent(name, ...) __events[#__events + 1] = { name = name, args = { ... } } end
function TriggerEvent(...) end
function CreateThread(fn) __threads[#__threads + 1] = fn end
function Wait(_ms) end
function RegisterNetEvent(_name, _fn) end
function RegisterCommand(_name, _fn, _restricted) end
function RegisterNUICallback() end
function GetConvarInt(_name, default) return default end

-- 向量：`#(a - b)` 走 __len
local vmt = {}
vmt.__sub = function(a, b)
    return setmetatable({ dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z }, {
        __len = function(t) return math.sqrt(t.dx * t.dx + t.dy * t.dy + t.dz * t.dz) end,
    })
end
function vector3(x, y, z) return setmetatable({ x = x, y = y, z = z }, vmt) end

function PlayerPedId() return 1 end
function PlayerId() return 0 end
function GetEntityCoords(_ped) return vector3(0.0, 0.0, 0.0) end
function GetOffsetFromEntityInWorldCoords(_ped, x, y, z) return vector3(x, y, z) end
function GetSelectedPedWeapon(_ped) return 0 end
function IsPedShooting(_ped) return false end
function IsPlayerFreeAiming(_id) return false end
function IsControlJustReleased(_a, _b) return false end
function GetStreetNameAtCoord(_x, _y, _z) return 1, 2 end
function GetStreetNameFromHashKey(_h) return 'Street' end
function GetHashKey(name)
    local h = 0
    for i = 1, #name do h = (h * 31 + name:byte(i)) % 2147483647 end
    return h
end
function DrawMarker(...) __markers[#__markers + 1] = { ... } end

LocalPlayer = { state = { isLoggedIn = true } }
PlayerJob = { type = 'leo', onduty = true }
Lang = { t = function(key, _params) return key end }
Config = { AmmoLabels = {} }
QBCore = {
    Shared = { Weapons = {}, Items = {} },
    Functions = {
        Progressbar = function() end,
        Notify = function() end,
        HasItem = function() return false end,
    },
}
CFShared = {
    DrawText3D = function(x, y, z, text) __texts[#__texts + 1] = { x = x, y = y, z = z, text = text } end,
    LoadModel = function() return true end,
    ReleaseModel = function() end,
    Report = function() end,
}
"""


def lua() -> str:
    exe = shutil.which("lua5.4") or shutil.which("lua")
    if not exe:
        pytest.skip("lua5.4 不可用")
    return exe


def run(body: str) -> dict:
    script = STUBS + "\n" + cfx_source() + "\n" + textwrap.dedent(body)
    proc = subprocess.run([lua(), "-"], input=script, capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, f"Lua 执行失败:\n{proc.stderr[-800:]}"
    out = {}
    for line in proc.stdout.strip().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


ADD_CASING = """
        -- 直接往客户端的 Casings 表里塞一条（等价于服务端广播过来的 evidence:client:AddCasing）
        Casings['abc'] = { type = 12345, serie = 'S1', coords = { x = %s, y = 0.0, z = 0.0 } }
"""


def test_on_duty_officer_sees_an_arrow_with_a_distance():
    out = run(ADD_CASING % "8.0" + """
        __say = function(s) io.write(tostring(s) .. string.char(10)) end
        local drawn = EvidenceHints.DrawCasings(vector3(0.0, 0.0, 0.0))
        __say('drawn=' .. tostring(drawn))
        __say('markers=' .. tostring(#__markers))
        __say('marker_type=' .. tostring(__markers[1] and __markers[1][1]))
        __say('texts=' .. tostring(#__texts))
        __say('has_arrow=' .. tostring(__texts[1] and __texts[1].text:find('▼') ~= nil))
        __say('has_distance=' .. tostring(__texts[1] and __texts[1].text:find('8%.0m') ~= nil))
        __say('above_ground=' .. tostring(__texts[1] and __texts[1].z > 0.0))
    """)
    assert out["drawn"] == "1"
    assert out["markers"] == "1" and out["marker_type"] == "1", "地面要有一个细柱标记"
    assert out["texts"] == "1"
    assert out["has_arrow"] == "true", "箭头符号丢了就只是柱子，玩家仍然不知道那是什么"
    assert out["has_distance"] == "true", "带上距离才知道还要走多远"
    assert out["above_ground"] == "true", "文字要浮在落点上方，不能埋进地面"


def test_civilian_and_off_duty_see_nothing_and_far_ones_are_skipped():
    far = (ADD_CASING % "400.0").replace("'abc'", "'far'")
    out = run((ADD_CASING % "8.0") + far + """
        __say = function(s) io.write(tostring(s) .. string.char(10)) end
        local pos = vector3(0.0, 0.0, 0.0)

        __say('leo=' .. tostring(EvidenceHints.DrawCasings(pos)))
        __say('leo_markers=' .. tostring(#__markers))

        -- 平民
        _G.__markers, _G.__texts = {}, {}
        PlayerJob = { type = 'none', onduty = true }
        __say('civilian=' .. tostring(EvidenceHints.DrawCasings(pos)))
        __say('civilian_markers=' .. tostring(#__markers))

        -- 下班警察
        PlayerJob = { type = 'leo', onduty = false }
        __say('offduty=' .. tostring(EvidenceHints.DrawCasings(pos)))
        __say('offduty_markers=' .. tostring(#__markers))

        -- 重新值班：400 米外那颗不该被画
        PlayerJob = { type = 'leo', onduty = true }
        __say('onduty_again=' .. tostring(EvidenceHints.DrawCasings(pos)))
    """)
    assert out["leo"] == "1", "8 米那颗要画"
    assert out["civilian"] == "0" and out["civilian_markers"] == "0", "平民不该看到证据位置"
    assert out["offduty"] == "0" and out["offduty_markers"] == "0", "下班状态也不该看到"
    assert out["onduty_again"] == "1", "400 米外那颗必须跳过（否则遍历和绘制都变成热点）"
