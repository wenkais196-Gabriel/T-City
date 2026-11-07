"""G16：金额审计日志必须能吃小数 —— `%d` 遇上 0.5 会抛，而 money 是先加后记。

真机复现（2026-11-01，控制台）：`givemoney 1 cash 0.5` 连跑 10 次，每次都是

    SCRIPT ERROR: @qb-core/server/services/economy_service.lua:74:
      bad argument #4 to 'format' (number has no integer representation)

而 `EconomyService.AddMoney` 的顺序是「写内存 → UpdatePlayerData → fireMoneyEvents →
fireAuditLog」：钱已经进账了，审计那一步才炸。后果是**余额变了但没有审计日志**，
调用方还收到一个错误（一旦有人给它套 pcall 回落，就是双倍入账）。

工资佣金这类按比例结算的地方本来就会产生小数，所以这不是"边界情况"。

做法：从 economy_service.lua 抽出真实的 `fmtAmount` + `fireAuditLog`，用假玩家跑，
断言不抛错且金额渲染正确（整数不带小数点、小数保留两位）。
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path

ECONOMY = (
    Path(__file__).resolve().parents[3]
    / "resources"
    / "[qb]"
    / "qb-core"
    / "server"
    / "services"
    / "economy_service.lua"
)


def _audit_source() -> str:
    lines = ECONOMY.read_text(encoding="utf-8").splitlines()
    start = next(i for i, l in enumerate(lines) if l.startswith("local function fmtAmount"))
    end = next(i for i, l in enumerate(lines) if l.startswith("local function fireAuditLog"))
    stop = next(i for i in range(end, len(lines)) if lines[i] == "end")
    return "\n".join(lines[start:stop + 1])


PRELUDE = r"""
local captured = {}
TriggerEvent = function(name, ...)
    local args = { ... }
    captured[#captured + 1] = { name = name, message = args[4] }  -- CreateLog(logType, label, color, message)
end
GetPlayerName = function(src) return 'Player' .. tostring(src) end
"""

TAIL = r"""
local player = { PlayerData = { name = 'Tester', citizenid = 'CID1', source = 1 } }

local okSmall, errSmall = pcall(fireAuditLog, player, 'cash', 0.5, 'add', 500.5, 'commission')
local okInt, errInt = pcall(fireAuditLog, player, 'cash', 500, 'add', 1000, 'salary')

local smallMsg = captured[1] and captured[1].message or ''
local intMsg = captured[2] and captured[2].message or ''

print('RESULT ' .. string.format(
    '{"smallOk":%s,"smallMsg":"%s","intOk":%s,"intMsg":"%s","err":"%s"}',
    tostring(okSmall), smallMsg:gsub('"', "'"),
    tostring(okInt), intMsg:gsub('"', "'"),
    tostring(errSmall or '')
))
"""


def _run() -> dict:
    with tempfile.NamedTemporaryFile(mode="w", suffix=".lua", delete=False, encoding="utf-8") as fh:
        fh.write(PRELUDE + "\n" + _audit_source() + "\n" + TAIL)
        tmp = fh.name
    try:
        proc = subprocess.run(["lua5.4", tmp], capture_output=True, text=True, timeout=20)
    finally:
        os.unlink(tmp)
    assert proc.returncode == 0, f"Lua 执行失败：\n{proc.stderr}\n{proc.stdout}"
    line = next((l for l in proc.stdout.splitlines() if l.startswith("RESULT ")), None)
    assert line, f"没有拿到 RESULT 行：\n{proc.stdout}"
    return json.loads(line[len("RESULT "):])


def test_audit_log_accepts_fractional_amounts():
    r = _run()
    assert r["smallOk"] is True, (
        f"小数金额写审计日志抛错了（{r['err']}）—— 钱已入账但审计丢失，调用方还会收到错误"
    )
    assert "$0.50" in r["smallMsg"], f"小数金额没有正确渲染：{r['smallMsg']!r}"
    assert "500.50" in r["smallMsg"], f"小数余额没有正确渲染：{r['smallMsg']!r}"


def test_audit_log_keeps_integers_clean():
    r = _run()
    assert r["intOk"] is True, f"整数金额写审计日志抛错了（{r['err']}）"
    assert "$500 " in r["intMsg"] + " ", f"整数金额被渲染成小数：{r['intMsg']!r}"
    assert "1000" in r["intMsg"] and "1000.00" not in r["intMsg"], (
        f"整数余额被渲染成小数：{r['intMsg']!r}"
    )
