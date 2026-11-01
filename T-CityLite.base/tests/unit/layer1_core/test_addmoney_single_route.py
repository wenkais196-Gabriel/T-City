"""G7：一次 `Player.Functions.AddMoney` 只能让余额 +1 —— 两条路径（ES 与回落）不许都跑。

背景（P1-4 决策 D1）：qb-core 的 `AddMoney` 里没有 `pcall`，所以不存在"ES 先写、抛错后回落再写"
的双倍路径。这条测试把这个性质**固定**下来：将来谁在 `AddMoney` 外面再包一层 try/fallback，
或者把 ES 调用改成"失败就再来一次"，这里会立刻红。

做法：从 qb-core 的 player.lua 里抽出真实的 `self.Functions.AddMoney` 函数体，直接跑（不是复述逻辑）。
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path

PLAYER_LUA = (
    Path(__file__).resolve().parents[3]
    / "resources"
    / "[qb]"
    / "qb-core"
    / "server"
    / "player.lua"
)


def _addmoney_source() -> str:
    """抽出 `function self.Functions.AddMoney(...)` 到同缩进的 `end`。"""
    lines = PLAYER_LUA.read_text(encoding="utf-8").splitlines()
    start = next(
        i for i, line in enumerate(lines)
        if line.strip().startswith("function self.Functions.AddMoney(")
    )
    indent = len(lines[start]) - len(lines[start].lstrip())
    closer = " " * indent + "end"
    end = next(i for i in range(start + 1, len(lines)) if lines[i] == closer)
    block = lines[start:end + 1]
    return "\n".join(line[indent:] for line in block)


PRELUDE = r"""
local online = { citizenid = 'CID1', money = { cash = 0, bank = 0 } }
local calls = { count = 0, amounts = {} }
local function make_es(mode)
    return {
        AddMoney = function(citizenid, moneytype, amount, reason)
            calls.count = calls.count + 1
            calls.amounts[#calls.amounts + 1] = amount
            -- 真实 ES 会先写内存
            online.money[moneytype] = (online.money[moneytype] or 0) + amount
            if mode == 'throw_after_write' then
                error('audit log exploded after write')
            end
            return true
        end,
    }
end

local self = { Offline = false, IsDirty = false, PlayerData = { citizenid = 'CID1', money = online.money }, Functions = {} }
"""

BODY = _addmoney_source()

TAIL = r"""

local function probe(label, esMode, esPresent)
    calls.count = 0
    calls.amounts = {}
    online.money.cash = 0
    self.IsDirty = false
    _G.Bus = esPresent and { EconomyService = make_es(esMode) } or nil
    local ok, result = pcall(function() return self.Functions.AddMoney('cash', 100, 'probe') end)
    return {
        label = label,
        ok = ok,
        result = result,
        balance = online.money.cash,
        esCalls = calls.count,
        dirty = self.IsDirty,
    }
end

local results = {
    probe('via_es', nil, true),
    probe('es_throws_after_write', 'throw_after_write', true),
    probe('fallback_no_es', nil, false),
}
print('RESULT ' .. '{' .. table.concat((function()
    local parts = {}
    for _, r in ipairs(results) do
        parts[#parts + 1] = ('"%s":{"ok":%s,"returnedTrue":%s,"balance":%d,"esCalls":%d,"dirty":%s}')
            :format(r.label, tostring(r.ok), tostring(r.result == true), r.balance, r.esCalls, tostring(r.dirty))
    end
    return parts
end)(), ',') .. '}')
"""


def _run() -> dict:
    with tempfile.NamedTemporaryFile(mode="w", suffix=".lua", delete=False, encoding="utf-8") as fh:
        fh.write(PRELUDE + BODY + TAIL)
        tmp = fh.name
    try:
        proc = subprocess.run(["lua5.4", tmp], capture_output=True, text=True, timeout=20)
    finally:
        os.unlink(tmp)
    assert proc.returncode == 0, f"Lua 执行失败：\n{proc.stderr}\n{proc.stdout}"
    line = next((ln for ln in proc.stdout.splitlines() if ln.startswith("RESULT ")), None)
    assert line, f"没有拿到 RESULT 行：\n{proc.stdout}"
    return json.loads(line[len("RESULT "):])


def test_addmoney_adds_exactly_once_per_call():
    r = _run()

    via_es = r["via_es"]
    assert via_es["ok"] is True and via_es["returnedTrue"] is True, "通过 ES 的加钱调用失败了"
    assert via_es["esCalls"] == 1, f"一次 AddMoney 调了 {via_es['esCalls']} 次 EconomyService.AddMoney"
    assert via_es["balance"] == 100, f"余额变成 {via_es['balance']}，应该只 +100"

    fallback = r["fallback_no_es"]
    assert fallback["balance"] == 100, f"没有 ES 时余额变成 {fallback['balance']}，应该只 +100"
    assert fallback["dirty"] is True, "回落路径没有把玩家标脏 —— 这次加钱永远不会落库"

    thrown = r["es_throws_after_write"]
    assert thrown["balance"] == 100, (
        f"ES 先写后抛错时余额变成 {thrown['balance']} —— 出现了「先写一次、回落再写一次」的双倍加钱"
    )
    assert thrown["ok"] is False, "ES 抛错被吞掉了 —— 加钱失败会变成静默成功"
