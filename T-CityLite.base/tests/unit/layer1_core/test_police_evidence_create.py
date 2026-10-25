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
-- 文件里用的是冒号调用 Lang:t(key)：桩必须把 self 放第一位，否则返回整个 Lang 表
Lang = { t = function(_self, key, _params) return key end }
Config = { AmmoLabels = { AMMO_PISTOL = '9mm' } }
MySQL = setmetatable({}, { __index = function() return function() end end })

-- 库存导出桩：记录 AddItem/RemoveItem，用来判断"证据袋到底给了没、里面装了什么"
__inventory = { adds = {}, removes = {} }
exports = setmetatable({}, {
    __index = function(_t, resource)
        return setmetatable({}, {
            __index = function(_r, fn)
                return function(_self, src, item, amount, slot, info, reason)
                    if fn == 'AddItem' then
                        __inventory.adds[#__inventory.adds + 1] =
                            { src = src, item = item, amount = amount, info = info, reason = reason }
                    elseif fn == 'RemoveItem' then
                        __inventory.removes[#__inventory.removes + 1] =
                            { src = src, item = item, amount = amount, reason = reason }
                    end
                    return true
                end
            end,
        })
    end,
})
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
        __lastDropId = ev.args[1]
    end
    __say('prints=' .. tostring(#__prints))
    for i = 1, #__prints do __say('print' .. i .. '=' .. __prints[i]) end
end

--- 直接调拾取 handler，看库存桩收到了什么
local function pickup(event, id, info)
    freshPlayer()
    source = 1
    __clientEvents, __prints = {}, {}
    __inventory.adds, __inventory.removes = {}, {}
    __events[event](id, info)
    __say('adds=' .. tostring(#__inventory.adds))
    __say('removes=' .. tostring(#__inventory.removes))
    local add = __inventory.adds[1]
    if add then
        local i = add.info or {}
        __say('bag_item=' .. tostring(add.item))
        __say('bag_serie=' .. tostring(i.serie))
        __say('bag_ammotype=' .. tostring(i.ammotype))
        __say('bag_bloodtype=' .. tostring(i.bloodtype))
        __say('bag_dnalabel=' .. tostring(i.dnalabel))
        __say('bag_fingerprint=' .. tostring(i.fingerprint))
        __say('bag_street=' .. tostring(i.street))
        __say('bag_label=' .. tostring(i.label))
    end
end

local function freshPlayerWithBlood()
    __players[1] = {
        PlayerData = {
            source = 1,
            citizenid = 'CIT1',
            metadata = { bloodtype = 'AB-', fingerprint = 'FP-SERVER' },
        },
        Functions = { GetItemByName = function(_name) return nil end },
    }
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


def test_pickup_refuses_an_id_the_server_never_tracked():
    """幽灵痕迹换不出证据袋。

    服务端只在"表满 500"时才顺手清一次过期行，客户端却可能因为清场广播丢失、
    或玩家一直站在原地看着旧标记，仍然按 G。旧代码不核对 id，改过的客户端甚至能
    凭空造一个 id 换证据袋；现在必须先在本服务的记录里存在。
    """
    out = run("""
        __convars['tcity_evidence_debug'] = 1
        pickup('evidence:server:AddCasingToInventory', 424242, { street = 'St', ammotype = 999, serie = 'FORGED' })
        __say('prints=' .. tostring(#__prints))
        __say('print1=' .. tostring(__prints[1]))
    """)
    assert out["adds"] == "0", "服务端没有这颗弹壳，就不能给证据袋"
    assert out["removes"] == "0", "连空袋子也不该扣"
    assert "not tracked here" in out.get("print1", ""), out


def test_casing_bag_comes_from_the_server_record_not_the_client_claim():
    """客户端只能提供街道名，weapon/serie 一律以服务端记录为准。"""
    out = run("""
        fire(453432689, { x = 0.0, y = 0.0, z = 0.0 })
        local id = __lastDropId
        pickup('evidence:server:AddCasingToInventory', id,
            { street = 'Alta St', ammotype = 999, serie = 'FORGED', label = 'Forged Label', type = 'casing' })
    """)
    assert out["adds"] == "1"
    assert out["bag_ammotype"] == "453432689", "武器哈希必须来自服务端记录，不能是客户端声称的 999"
    assert out["bag_serie"] == "nil", "服务端没有序号就应该是空，而不是客户端的 FORGED"
    assert out["bag_street"] == "Alta St", "街道名只有客户端拿得到，这一项可以采信"
    assert out["bag_label"] == "info.casing", "标签由服务端按类型给，不采信客户端传的 label"


def test_blood_bag_uses_the_server_dna_and_bloodtype():
    out = run("""
        freshPlayerWithBlood()
        source = 1
        __clientEvents = {}
        __events['evidence:server:CreateBloodDrop']('CIT1', 'AB-', { x = 0.0, y = 0.0, z = 0.0 })
        local id = __clientEvents[1].args[1]
        pickup('evidence:server:AddBlooddropToInventory', id,
            { street = 'Vinewood', bloodtype = 'Z+', dnalabel = 'FAKE' })
    """)
    assert out["adds"] == "1"
    assert out["bag_bloodtype"] == "AB-", "血型必须来自服务端记录"
    assert out["bag_dnalabel"] == "43495431", "DNA 必须是服务端把 citizenid 转十六进制（CIT1）"
    assert out["bag_street"] == "Vinewood"


def test_fingerprint_bag_uses_the_server_fingerprint():
    out = run("""
        freshPlayerWithBlood()
        source = 1
        __clientEvents = {}
        __events['evidence:server:CreateFingerDrop']({ x = 0.0, y = 0.0, z = 0.0 })
        local id = __clientEvents[1].args[1]
        pickup('evidence:server:AddFingerprintToInventory', id, { street = 'Mirror Park', fingerprint = 'FAKE-FP' })
    """)
    assert out["adds"] == "1"
    assert out["bag_fingerprint"] == "FP-SERVER", "指纹必须来自服务端记录"
    assert out["bag_street"] == "Mirror Park"


def test_expired_drops_are_swept_and_clients_are_told():
    """TTL 必须真的生效，而且要广播——否则客户端屏幕上留着幽灵箭头。

    以前的 TTL 只在"表满 500"时才顺手跑一次，等于没到上限就整局不清；而且清的时候
    一声不响，客户端那条 Remove* 永远收不到，箭头会一直挂在原地（按 G 也换不到东西）。
    """
    out = run("""
        __convars['tcity_evidence_debug'] = 1

        -- 一颗新鲜弹壳：清扫不能动它
        fire(453432689, { x = 0.0, y = 0.0, z = 0.0 })
        local freshId = __lastDropId
        __clientEvents = {}
        __say('fresh_removed=' .. tostring(EvidenceMaintenance.PruneExpired()))
        __say('fresh_broadcast=' .. tostring(#__clientEvents))

        -- 把 TTL 调成 -1，任何一行都算过期
        __convars['tcity_evidence_ttl'] = -1
        __clientEvents = {}
        __say('expired_removed=' .. tostring(EvidenceMaintenance.PruneExpired()))
        __say('expired_broadcast=' .. tostring(#__clientEvents))
        if __clientEvents[1] then
            __say('broadcast_event=' .. tostring(__clientEvents[1].name))
            __say('broadcast_id=' .. tostring(__clientEvents[1].args[1]))
            __say('broadcast_id_matches=' .. tostring(__clientEvents[1].args[1] == freshId))
        end

        -- 清掉之后，客户端那个 id 再来拾取必须被拒
        pickup('evidence:server:AddCasingToInventory', freshId, { street = 'St' })
    """)
    assert out["fresh_removed"] == "0", "默认 30 分钟，刚生成的不能清"
    assert out["fresh_broadcast"] == "0", "没清就不该广播"
    assert out["expired_removed"] == "1", "过期了必须清掉"
    assert out["expired_broadcast"] == "1", "清掉必须广播，否则客户端留着幽灵箭头"
    assert out["broadcast_event"] == "evidence:client:RemoveCasing"
    assert out["broadcast_id_matches"] == "true", "广播的必须是那一颗的 id"
    assert out["adds"] == "0", "清掉之后不能再换出证据袋"


def test_the_sweep_covers_blood_and_fingerprints_too():
    out = run("""
        freshPlayerWithBlood()
        source = 1
        __clientEvents = {}
        __events['evidence:server:CreateBloodDrop']('CIT1', 'AB-', { x = 0.0, y = 0.0, z = 0.0 })
        local bloodId = __clientEvents[1].args[1]
        __clientEvents = {}
        __events['evidence:server:CreateFingerDrop']({ x = 0.0, y = 0.0, z = 0.0 })
        local fingerId = __clientEvents[1].args[1]

        __convars['tcity_evidence_ttl'] = -1
        __clientEvents = {}
        __say('removed=' .. tostring(EvidenceMaintenance.PruneExpired()))
        local names = {}
        for i = 1, #__clientEvents do names[i] = __clientEvents[i].name end
        __say('events=' .. table.concat(names, ','))
        __say('blood_id=' .. tostring(bloodId))
        __say('finger_id=' .. tostring(fingerId))
    """)
    assert out["removed"] == "2"
    events = out["events"].split(",")
    assert "evidence:client:RemoveBlooddrop" in events, out
    assert "evidence:client:RemoveFingerprint" in events, out
