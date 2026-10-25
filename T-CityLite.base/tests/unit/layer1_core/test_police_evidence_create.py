"""EVD-03：服务端到底为什么把每一颗弹壳都丢了。

实机日志（开 tcity_evidence_debug）里，客户端明明发出来了：

    [client-report] info ChillyOtter2835(#1): casing sent weapon=453432689 onduty=true
    [custom-police] [evidence] rejected: coords too far src=1

而 `coordsNearSource` 只在三种情况下返回 nil：坐标形状不对、拿不到 ped、距离超过 25 米。
三种共用一个笼统的日志，等于什么都没说。这次把原因分档，并把「坐标必须是 {x,y,z} 表」
这条契约钉死在测试里——真实原因就是客户端发的是原生 vector3，服务端 `type(coords) ~= 'table'`
直接判非法。

测法：真跑 server/evidence.lua（桩掉 QBCore/PolicePolicy/原生），直接调注册进来的
`evidence:server:CreateCasing` handler，看广播与拒绝原因。
"""

from __future__ import annotations

import re
import shutil
import subprocess
import textwrap
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
SERVER = BASE / "resources" / "[custom]" / "custom-police" / "server" / "evidence.lua"
CLIENT = BASE / "resources" / "[custom]" / "custom-police" / "client" / "evidence.lua"

_BACKTICK = re.compile(r"`([^`\n]+)`")

STUBS = """
__events, __clientEvents, __callbacks, __prints = {}, {}, {}, {}
__convars = {}
__players = {}

function print(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
    __prints[#__prints + 1] = table.concat(parts, ' ')
end
function TriggerClientEvent(name, target, ...)
    __clientEvents[#__clientEvents + 1] = { name = name, target = target, args = { ... } }
end
function RegisterNetEvent(name, fn) __events[name] = fn end
function CreateThread(_fn) end
function Wait(_ms) end
function GetConvarInt(name, default) local v = __convars[name]; if v == nil then return default end return v end
function GetPlayerPed(src) return (src or 0) * 10 end
function GetPlayerName(src) return 'Player' .. tostring(src) end
function GetHashKey(_name) return 1 end

local vmt = {}
vmt.__sub = function(a, b)
    return setmetatable({ dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z }, {
        __len = function(t) return math.sqrt(t.dx * t.dx + t.dy * t.dy + t.dz * t.dz) end,
    })
end
function vector3(x, y, z) return setmetatable({ x = x, y = y, z = z }, vmt) end
function GetEntityCoords(_ped) return vector3(0.0, 0.0, 0.0) end

QBCore = {
    Functions = {
        CreateCallback = function(name, fn) __callbacks[name] = fn end,
        GetPlayer = function(src) return __players[src] end,
    },
    Shared = { Weapons = {}, Items = {} },
}
PolicePolicy = { Can = function() return true end }
Lang = { t = function(key, _params) return key end }
Config = { AmmoLabels = {} }
MySQL = setmetatable({}, { __index = function() return function() end end })
"""


def lua() -> str:
    exe = shutil.which("lua5.4") or shutil.which("lua")
    if not exe:
        pytest.skip("lua5.4 不可用")
    return exe


HARNESS = """
local function freshPlayer()
    __players[1] = {
        PlayerData = { source = 1, citizenid = 'CIT1', metadata = {} },
        Functions = { GetItemByName = function(_name) return nil end },
    }
end

-- __prints 故意不重置：要跨多次 fire 累积，才能一次看到所有拒绝原因
local function dump()
    __say('all_prints=' .. table.concat(__prints, ' | '))
end

local function fire(weapon, coords, src)
    freshPlayer()
    source = src or 1
    __clientEvents = {}
    __events['evidence:server:CreateCasing'](weapon, coords)
    __say('broadcasts=' .. tostring(#__clientEvents))
    if __clientEvents[1] then
        local ev = __clientEvents[1]
        __say('event=' .. tostring(ev.name))
        local where = ev.args[3]
        __say('where_x=' .. tostring(where and where.x))
        __say('id_is_number=' .. tostring(type(ev.args[1]) == 'number'))
    end
    __say('prints=' .. tostring(#__prints))
    for i = 1, #__prints do __say('print' .. i .. '=' .. __prints[i]) end
end
"""


def run(body: str) -> dict:
    script = STUBS + "\n" + STUBS_SAY + "\n" + cfx(SERVER) + "\n" + HARNESS + "\n" + textwrap.dedent(body)
    proc = subprocess.run([lua(), "-"], input=script, capture_output=True, text=True, timeout=90)
    assert proc.returncode == 0, f"Lua 执行失败:\n{proc.stderr[-900:]}"
    out = {}
    for line in proc.stdout.strip().splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            out[key.strip()] = value.strip()
    return out


STUBS_SAY = """
function __say(line) io.write(tostring(line) .. string.char(10)) end
"""


def cfx(path: Path) -> str:
    return _BACKTICK.sub(lambda m: "GetHashKey(%r)" % m.group(1), path.read_text(encoding="utf-8"))


def test_a_plain_table_casing_is_broadcast_to_everyone():
    out = run("""
        __convars['tcity_evidence_debug'] = 1
        fire(453432689, { x = 1.0, y = 2.0, z = 3.0 })
    """)
    assert out["broadcasts"] == "1", "坐标合法就必须广播出去"
    assert out["event"] == "evidence:client:AddCasing"
    assert out["where_x"] == "1.0"
    assert out["id_is_number"] == "true"
    assert out.get("print1", "").startswith("[evidence] casing"), out


def test_each_rejection_names_its_reason():
    out = run("""
        __convars['tcity_evidence_debug'] = 1

        __say('--- 坐标不是表 ---')
        fire(453432689, 'not a table')
        __say('--- 坐标是表但字段缺失 ---')
        fire(453432689, { x = 1.0 })
        __say('--- 距离超过 25 米 ---')
        fire(453432689, { x = 900.0, y = 0.0, z = 0.0 })
        __say('--- weapon 不是数字 ---')
        fire('weapon_pistol', { x = 0.0, y = 0.0, z = 0.0 })
        __say('--- 来源玩家不存在 ---')
        fire(453432689, { x = 0.0, y = 0.0, z = 0.0 }, 99)
        dump()
    """)
    # 每条拒绝都必须有自己的一句话，而不是统一说"coords too far"
    printed = out["all_prints"]
    assert "coords are not a {x,y,z} table" in printed
    assert "coords too far from ped" in printed
    assert "weapon not a number" in printed
    assert "no player" in printed
    assert out["broadcasts"] == "0", "被拒绝的请求不能广播"


def test_debug_off_broadcasts_without_logging():
    out = run("""
        __convars['tcity_evidence_debug'] = 0
        fire(453432689, { x = 1.0, y = 2.0, z = 3.0 })
    """)
    assert out["broadcasts"] == "1"
    assert out["prints"] == "0", "默认不许刷日志"


def test_the_casing_table_cap_is_enforced_and_says_so():
    out = run("""
        __convars['tcity_evidence_debug'] = 1
        for i = 1, 501 do
            freshPlayer()
            source = 1
            __events['evidence:server:CreateCasing'](453432689, { x = 0.0, y = 0.0, z = 0.0 })
        end
        -- 第 501 颗必须被上限挡住
        __prints = {}
        freshPlayer()
        source = 1
        __events['evidence:server:CreateCasing'](453432689, { x = 0.0, y = 0.0, z = 0.0 })
        __say('prints=' .. tostring(#__prints))
        __say('print1=' .. tostring(__prints[1]))
    """)
    assert out.get("print1", "").endswith("casing table full src=1"), out


def test_the_client_sends_a_plain_table_not_a_vector3():
    """跨文件契约：服务端只认 {x,y,z} 表，客户端就必须发普通表。

    这条断言就是这次的 bug：客户端发 `GetOffsetFromEntityInWorldCoords` 的返回值，
    那是原生 vector3，服务端 `type(coords) ~= 'table'` 判非法，每一枪都被丢掉。
    """
    source = CLIENT.read_text(encoding="utf-8")
    match = re.search(r"TriggerServerEvent\('evidence:server:CreateCasing',\s*(\w+),\s*(\w+)\)", source)
    assert match, "找不到弹壳上报调用点"
    argument = match.group(2)
    assert argument != "coords", "直接把 vector3 发出去会被服务端判成坐标非法"

    # 反向：确认那个变量确实是从字面量表赋值的，而不是别名转手
    assignment = re.search(rf"local\s+{argument}\s*=\s*\{{[^}}]*x\s*=", source)
    assert assignment, f"{argument} 必须由 {{ x = ..., y = ..., z = ... }} 字面量构造"
