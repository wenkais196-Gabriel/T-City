"""P1-4 阶段 C：compat 不许再包装 `Player.Functions.AddMoney`。

这条猴补今天是**死代码**（`_G` 不跨资源，core-framework 里 `_G.Bus.EconomyService` 恒 nil →
ES 分支整段跳过，永远回落），所以删除是零语义变更。但"死代码"不等于"无害"：

* 它每 10 分钟把 Notify 与 AddMoney 的计数混在一起打印，运维会以为加钱走了新路径；
* 它把 `Player.Functions.AddMoney` 换成一个**形参是 `self` 的闭包**，而全仓 60 处调用点都是
  3 参 dot 调用 —— 一旦有人"顺手修好"ES 可见性，`self = 'cash'`，每个加钱点直接 SCRIPT ERROR；
* 若修好传参而不改签名，pcall 回落 + 原函数各调一次 ES → 双倍加钱。

所以判据是"函数引用不变"（G6），而不是"加钱成功了"。
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path

COMPAT = (
    Path(__file__).resolve().parents[3]
    / "resources"
    / "[standalone]"
    / "core-framework"
    / "compat.lua"
)

MOCK = r"""
_G.QBCore = {
    Players = {},
    Functions = {
        GetPlayer = function(source) return _G.QBCore.Players[tonumber(source) or 0] end,
        Notify = function() return true end,
    },
}
function GetCoreObject() return _G.QBCore end
exports = setmetatable({}, {
    __index = function() return { GetCoreObject = function(_, ...) return _G.QBCore end } end,
})
_handlers = {}
AddEventHandler = function(name, fn) _handlers[name] = _handlers[name] or {}; table.insert(_handlers[name], fn) end
RegisterNetEvent = function() end
TriggerEvent = function() end
TriggerClientEvent = function() end
CreateThread = function(fn) end
Wait = function() end
GetPlayerName = function(src) return 'P' .. tostring(src) end
GetPlayerPing = function() return 1 end
"""

PROBE = r"""
-- 一张"玩家表"：AddMoney 是**标记函数**，包装层一旦替换它，引用就变了
local function markerAddMoney(self, moneytype, amount, reason) return 'marker' end
local player = {
    PlayerData = { source = 1, citizenid = 'CID1', money = { cash = 0, bank = 0 } },
    Functions = { AddMoney = markerAddMoney },
}
_G.QBCore.Players[1] = player

-- 触发 compat 挂的 PlayerLoaded handler（旧实现就是在这里替换 AddMoney 的）
for _, fn in ipairs(_handlers['QBCore:Server:PlayerLoaded'] or {}) do
    fn(player)
end

local same = player.Functions.AddMoney == markerAddMoney
local result = player.Functions.AddMoney(player, 'cash', 100, 'probe')

print('RESULT ' .. string.format(
    '{"sameFunction":%s,"callResult":"%s"}',
    tostring(same),
    tostring(result)
))
"""


def _run() -> dict:
    with open(COMPAT, encoding="utf-8") as handle:
        compat = handle.read()
    with tempfile.NamedTemporaryFile(mode="w", suffix=".lua", delete=False, encoding="utf-8") as fh:
        fh.write(MOCK + "\n" + compat + "\n" + PROBE)
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


def test_addmoney_is_not_wrapped_on_player_loaded():
    result = _run()
    assert result["sameFunction"] is True, (
        "PlayerLoaded 之后 Player.Functions.AddMoney 被替换了 —— compat 还在包装它"
    )
    assert result["callResult"] == "marker", (
        "加钱调用没有落到玩家自己的实现上（被中间的闭包截走了）"
    )
