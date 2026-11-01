"""G17：`QBCore.Player.Save` 必须把**数据**交给 qb-inventory，而不是 source。

为什么单独立一条：真机 2026-11-01 进角色时刷红字

    qb-inventory SCRIPT ERROR: Execution of function reference in script host failed
      > ref (@qb-inventory/server/functions.lua:106)   ← GetPlayer(source)
      > Save (@qb-core/server/player.lua:597)
      > ref (@qb-core/server/player.lua:21)            ← CheckPlayerData
      > safeCb (@oxmysql/dist/build.js:118)            ← oxmysql 回调

`QBCore.Functions.GetPlayer` 是跨资源**函数引用**，在数据库回调里不可用。所以 `Save()` 只能走
`SaveInventory(PlayerData, true)`（offline 形态），不能走 `SaveInventory(source)`。

而既有的 `test_persistence_single_owner.py` 把 `GetResourceState` 桩成 `'missing'`，helper 直接
return —— 把实现改回 `SaveInventory(source)`，那 12 条依然全绿（验收方实测）。所以这里单独给
导出调用本身加断言：

  * 第一个参数必须是带 `citizenid` 的表（不是数字 source）；
  * 第二个参数必须是 `true`（offline 形态）；
  * 调用期间不许碰 `QBCore.Functions.GetPlayer`（那是函数引用，正是崩因）。
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path

PLAYER = Path(__file__).resolve().parents[3] / "resources" / "[qb]" / "qb-core" / "server" / "player.lua"


def _helper_source() -> str:
    lines = PLAYER.read_text(encoding="utf-8").splitlines()
    start = next(i for i, l in enumerate(lines) if l.startswith("local function saveInventoryDeferred("))
    end = next(i for i in range(start + 1, len(lines)) if lines[i] == "end")
    return "\n".join(lines[start:end + 1])


HARNESS = r"""
-- qb-inventory 在跑：让 helper 真的走到导出调用
GetResourceState = function(name) return name == 'qb-inventory' and 'started' or 'missing' end

captured = {}
getPlayerCalls = 0

QBCore = {
    Functions = {
        GetPlayer = function(src)
            getPlayerCalls = getPlayerCalls + 1
            error('Save 不该在数据库回调里调跨资源函数引用 GetPlayer')
        end,
    },
}

exports = setmetatable({}, {
    __index = function(_, resource)
        return setmetatable({}, {
            __index = function(_, method)
                -- FiveM 的 `exports[r]:M(a, b)` 会把 exports 代理当 self 传进来，框架会剥掉它；
                -- 这里同样剥掉，否则测出来的是 mock 的形状而不是真实调用形状。
                return function(_, ...)
                    local args = { ... }
                    captured[#captured + 1] = {
                        resource = resource,
                        method = method,
                        arg1Type = type(args[1]),
                        arg1Citizenid = type(args[1]) == 'table' and args[1].citizenid or nil,
                        arg2 = args[2],
                        argCount = select('#', ...),
                    }
                end
            end
        })
    end,
})
"""

TAIL = r"""
local playerData = { citizenid = 'CID1', items = { { name = 'bread', amount = 2, slot = 1 } } }

saveInventoryDeferred(playerData)

local first = captured[1] or {}
local nilSkipped = 0
saveInventoryDeferred(nil)            -- 不该产生调用
saveInventoryDeferred('CID1')         -- 字符串也不是数据形态，不该产生调用
nilSkipped = #captured

print('RESULT ' .. string.format(
    '{"calls":%d,"resource":"%s","method":"%s","arg1Type":"%s","cid":"%s","arg2":%s,"argCount":%d,"afterInvalid":%d,"getPlayerCalls":%d}',
    #captured == 0 and 0 or 1,
    tostring(first.resource or ''), tostring(first.method or ''),
    tostring(first.arg1Type or ''), tostring(first.arg1Citizenid or ''),
    tostring(first.arg2), first.argCount or 0, nilSkipped, getPlayerCalls
))
"""


def _run() -> dict:
    with tempfile.NamedTemporaryFile(mode="w", suffix=".lua", delete=False, encoding="utf-8") as fh:
        fh.write(HARNESS + "\n" + _helper_source() + "\n" + TAIL)
        tmp = fh.name
    try:
        proc = subprocess.run(["lua5.4", tmp], capture_output=True, text=True, timeout=20)
    finally:
        os.unlink(tmp)
    assert proc.returncode == 0, f"Lua 执行失败：\n{proc.stderr}\n{proc.stdout}"
    line = next((l for l in proc.stdout.splitlines() if l.startswith("RESULT ")), None)
    assert line, f"没有拿到 RESULT 行：\n{proc.stdout}"
    return json.loads(line[len("RESULT "):])


def test_save_hands_playerdata_to_inventory_not_a_source_id():
    r = _run()
    assert r["calls"] == 1, "没有调用 qb-inventory:SaveInventory —— 背包根本不会落库"
    assert r["resource"] == "qb-inventory" and r["method"] == "SaveInventory", r
    assert r["arg1Type"] == "table", (
        f"第一个参数是 {r['arg1Type']} —— 传 source 会让 qb-inventory 走 online 分支，"
        "那里会调跨资源函数引用 GetPlayer，在数据库回调里必崩（真机 2026-11-01）"
    )
    assert r["cid"] == "CID1", f"传给 qb-inventory 的表不是玩家数据：{r}"
    assert r["arg2"] is True, "第二个参数必须是 true（offline 形态），否则又会走 GetPlayer"


def test_save_never_calls_the_cross_resource_getplayer():
    r = _run()
    assert r["getPlayerCalls"] == 0, "Save 调了 QBCore.Functions.GetPlayer —— 跨资源函数引用在 DB 回调里不可用"


def test_helper_ignores_non_table_payloads():
    r = _run()
    assert r["afterInvalid"] == 1, (
        f"传入 nil / 字符串时又产生了额外调用（总调用 {r['afterInvalid']} 次）—— 会在离线/半加载状态写坏背包"
    )
