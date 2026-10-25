"""INV-01：SetInventory 必须接受两种 identifier（source 数字 / citizenid 字符串）。

真实故障（服务端日志里成片出现）：qb-inventory 给玩家注册的方法传的是 **source**（数字），
而 SetInventory 的脱敏 print 做了 `#identifier`——数字上取长度直接抛错。这段 print 在
`player.Functions.SetPlayerData('items', items)` **之前**，所以每次开火更新弹药/耐久都在
这里中断：

    [qb-inventory] SCRIPT ERROR: functions.lua:146: attempt to get length of a number value
    > handler (@qb-weapons/server/main.lua:130)
    [qb-weapons] SCRIPT ERROR: error object is not a string

后果不是"日志难看"，是**物品表根本没写回玩家**。这条测试真跑 functions.lua（它是纯函数
定义，没有加载期副作用），分别用数字和字符串各调用一次。
"""

from __future__ import annotations

import re
import shutil
import subprocess
import textwrap
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
FUNCTIONS = BASE / "resources" / "[qb]" / "qb-inventory" / "server" / "functions.lua"

STUBS = """
-- ── 环境桩 ──────────────────────────────────────────────
Inventories, Drops = {}, {}
Config = { StashSize = { maxweight = 100000, slots = 50 } }
__logs = {}
__prints = {}
__exports = {}
json = {
    encode = function(v) return '{}' end,
    decode = function(s) return {} end,
}
exports = setmetatable({}, {
    __call = function(_, name, fn) __exports[name] = fn end,
})
function print(...) __prints[#__prints + 1] = table.concat({ ... }, ' ') end
function GetPlayerName(src) if type(src) == 'number' then return 'Tester' .. tostring(src) end return nil end
function GetInvokingResource() return 'test-harness' end
function TriggerEvent(name, ...) __logs[#__logs + 1] = { name = name, args = { ... } } end
function GetPlayer(src) return nil end
function GetHashKey(name)
    -- 稳定的假哈希：同一个名字永远同一个数，方便断言
    local h = 0
    for i = 1, #name do h = (h * 31 + name:byte(i)) % 2147483647 end
    return h
end
function IsPlayerAceAllowed() return false end

-- 假玩家：记录 SetPlayerData 到底有没有被调用
__setCalls = 0
__setItems = nil
__player = {
    Offline = false,
    PlayerData = {
        source = 7,
        citizenid = 'ABC12345',
        name = 'Tester Seven',
        items = {},
    },
    Functions = {
        SetPlayerData = function(key, value)
            __setCalls = __setCalls + 1
            if key == 'items' then __setItems = value end
            __player.PlayerData[key] = value
        end,
    },
}
QBCore = {
    Functions = {
        -- 数字 = 按 source 找；字符串 = 按 citizenid 找（和真实现一致）
        GetPlayer = function(id)
            if id == 7 or id == 'ABC12345' then return __player end
            return nil
        end,
    },
    Shared = { Items = {}, Weapons = {} },
}
"""


def lua() -> str:
    exe = shutil.which("lua5.4") or shutil.which("lua")
    if not exe:
        pytest.skip("lua5.4 不可用")
    return exe


#: CfxLua 的反引号哈希（`weapon_pistol`）不是标准 Lua，lua5.4 解析不了。
#: 跑之前换成 GetHashKey('...')——桩函数，语义一致，且只影响测试里的那份源码。
_BACKTICK = re.compile(r"`([^`\n]+)`")


def cfx_source() -> str:
    return _BACKTICK.sub(lambda m: "GetHashKey(%r)" % m.group(1), FUNCTIONS.read_text(encoding="utf-8"))


def run(body: str) -> dict:
    script = STUBS + "\n" + cfx_source() + "\n" + textwrap.dedent(body)
    proc = subprocess.run([lua(), "-"], input=script, capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, f"Lua 执行失败（说明加载或调用就炸了）:\n{proc.stderr}"
    out = {}
    for line in proc.stdout.strip().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def test_set_inventory_accepts_a_numeric_source_and_a_citizenid(tmp_path):
    out = run("""
        __say = function(s) io.write(tostring(s) .. string.char(10)) end
        local setInv = __exports['SetInventory']
        __say('registered=' .. tostring(setInv ~= nil))

        -- ① 数字 source（qb-weapons 走的这条路，历史上直接抛错）
        local ok, err = pcall(setInv, 7, { [1] = { name = 'weapon_pistol', amount = 1 } })
        __say('numeric_ok=' .. tostring(ok))
        __say('numeric_err=' .. tostring(err))
        __say('numeric_set_calls=' .. tostring(__setCalls))

        -- ② citizenid 字符串（离线库存 / 跨资源调用）
        __setCalls = 0
        local ok2, err2 = pcall(setInv, 'ABC12345', { [1] = { name = 'water', amount = 1 } })
        __say('string_ok=' .. tostring(ok2))
        __say('string_err=' .. tostring(err2))
        __say('string_set_calls=' .. tostring(__setCalls))

        __say('logs=' .. tostring(#__logs))
    """)
    assert out["registered"] == "true"
    assert out["numeric_ok"] == "true", f"数字 identifier 仍然报错：{out['numeric_err']}"
    assert out["numeric_set_calls"] == "1", "必须真的把物品表写回玩家（历史上在脱敏 print 处中断）"
    assert out["string_ok"] == "true", f"citizenid 路径报错：{out['string_err']}"
    assert out["string_set_calls"] == "1"
    assert int(out["logs"]) >= 2, "两条日志（items set + Inventory Set）都要发出去"
