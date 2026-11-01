"""P1-4 阶段 B：core-framework 的 compat 不许再给 QBCore.Functions.GetPlayer 打补丁。

为什么单独立一条测试：这条猴补的所有后果都只在**运行时**暴露 ——
- 缓存命中时多一次 `GetPlayerName` native（qb-core 本来就是一次表查）；
- `QBCore.Player.Logout` → `OnPlayerUnload` → 200ms 后才把 `Players[src]` 置 nil，
  而 compat 没监听这个事件，于是停在选人界面的玩家会被返回**已登出**的 Player 表；
- 本资源重启后旧 funcref 留在 qb-core 的表里，新实例再包一层。

所以判据是三条身份断言（不是"跑起来没报错"）：
  G4  `QBCore.Functions.GetPlayer(src)` 就是 qb-core 的实现（同一引用，没有中间层）
  G3  `Players[src]` 被清空之后（= 登出的那一刻），`GetPlayer(src)` 必须返回 nil
  G5  `GetPlayer('1')`（字符串 source）不抛错 —— 旧实现的 `source <= 0` 会 `attempt to compare string with number`

harness：用 mock 的 FiveM 环境 exec compat.lua，然后在同一个 Lua state 里做断言。
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path

import pytest

COMPAT = (
    Path(__file__).resolve().parents[3]
    / "resources"
    / "[standalone]"
    / "core-framework"
    / "compat.lua"
)

MOCK = r"""
-- ── FiveM 最小 mock ────────────────────────────────────────────────
_G.QBCore = {
    Players = {},
    Functions = {
        -- qb-core 的真实语义：数字或数字字符串 → 表查
        GetPlayer = function(source)
            if tonumber(source) ~= nil then
                return _G.QBCore.Players[tonumber(source)]
            end
            return nil
        end,
        Notify = function(source, text, kind, length) return true end,
    },
}
function GetCoreObject() return _G.QBCore end
-- compat 加载**之前**的引用：用来断言它没有被替换
_origGetPlayer = _G.QBCore.Functions.GetPlayer
exports = setmetatable({}, {
    -- exports['qb-core']:GetCoreObject()  → 冒号调用，返回一张带 GetCoreObject 的表
    __index = function() return { GetCoreObject = function(_, ...) return _G.QBCore end } end,
})
_handlers = {}
AddEventHandler = function(name, fn) _handlers[name] = _handlers[name] or {}; table.insert(_handlers[name], fn) end
RegisterNetEvent = function() end
TriggerEvent = function() end
TriggerClientEvent = function() end
CreateThread = function(fn) end
Wait = function() end
GetPlayerName = function(src) if type(src) ~= 'number' then return nil end return 'P' .. tostring(src) end
GetPlayerPing = function() return 1 end
-- print 保持原样：探测结果靠它输出
"""


def run_lua(code: str) -> dict:
    with open(COMPAT, encoding="utf-8") as handle:
        compat = handle.read()
    script = MOCK + "\n" + compat + "\n" + code
    with tempfile.NamedTemporaryFile(mode="w", suffix=".lua", delete=False, encoding="utf-8") as fh:
        fh.write(script)
        tmp = fh.name
    try:
        proc = subprocess.run(["lua5.4", tmp], capture_output=True, text=True, timeout=20)
    finally:
        os.unlink(tmp)
    if proc.returncode != 0:
        raise AssertionError(f"Lua 执行失败：\n{proc.stderr}\n{proc.stdout}")
    for line in proc.stdout.splitlines():
        if line.startswith("RESULT "):
            return json.loads(line[len("RESULT "):])
    raise AssertionError(f"没有拿到 RESULT 行：\n{proc.stdout}")


PROBE = r"""
local player = { PlayerData = { source = 1, citizenid = 'CID1', job = { name = 'police' } }, Functions = {} }
_G.QBCore.Players[1] = player

-- G4：函数本身必须还是 qb-core 那一个（compat 没有替换它），且返回值就是表里那张
local stillOriginal = _G.QBCore.Functions.GetPlayer == _origGetPlayer
local viaCore = _G.QBCore.Functions.GetPlayer(1)

-- G3：登出的那一刻（Players 被清空）之后必须返回 nil
_G.QBCore.Players[1] = nil
local afterLogout = _G.QBCore.Functions.GetPlayer(1)

-- G5：字符串 source 不能抛错
local okString, stringResult = pcall(function() return _G.QBCore.Functions.GetPlayer('1') end)

print('RESULT ' .. string.format(
    '{"sameFunction":%s,"identity":%s,"afterLogout":%s,"stringOk":%s,"stringResult":%s}',
    tostring(stillOriginal),
    tostring(viaCore == player),
    tostring(afterLogout == nil),
    tostring(okString),
    stringResult == nil and 'null' or '"not-nil"'
))
"""


def test_getplayer_is_not_wrapped_and_clears_on_logout():
    result = run_lua(PROBE)
    assert result["sameFunction"] is True, (
        "QBCore.Functions.GetPlayer 被 compat 替换了 —— 它必须还是 qb-core 那一个函数"
    )
    assert result["identity"] is True, "GetPlayer 返回的不是 Players[src] 那张表"
    assert result["afterLogout"] is True, (
        "Players[src] 被清空后 GetPlayer(src) 仍返回对象 —— 登出/选人界面期间会拿到前任 Player 表"
    )


def test_getplayer_accepts_string_source():
    result = run_lua(PROBE)
    assert result["stringOk"] is True, (
        "GetPlayer('1') 抛错了 —— 旧实现的 `source <= 0` 对字符串 source 会 attempt to compare string with number"
    )
