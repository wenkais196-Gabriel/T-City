"""CMD-GUARD-01 — 命令处理器不得在 `GetPlayer` 返回 nil 时索引 `PlayerData`。

为什么单列一条门槛：聊天命令可以从**服务端控制台**执行，此时 `source = 0`，
`QBCore.Functions.GetPlayer(0)` 返回 nil；玩家在本帧刚掉线也是同理。于是
`local Player = GetPlayer(src)` 之后紧跟 `Player.PlayerData...` 的写法会在控制台
报 `attempt to index a nil value (local 'Player')`，并且**整条命令后续逻辑全部失效**
（qb-core 的 command 分发在 pcall 外，错误直接吞掉返回）。

2026-10-25 实测：`/status`（qb-ambulancejob）就是这样在控制台炸的；同形状的写法在
命令处理器里共 39 处，已于同一批修复。

规则的范围被刻意收窄到命令处理器：
- 事件处理器里 `source` 一定是一个真实玩家，nil 不可能出现；把它们纳入只会产生噪音；
- 真正需要判空的是"可能被控制台调用"的入口。

qb-core 自己的 `server/commands.lua` 定义了这个 API（`function QBCore.Commands.Add(...)`），
不是调用点，扫描时跳过定义行。

Run: ``python3 -m pytest -q tests/architecture/test_command_guards.py``
"""

from __future__ import annotations

import re
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]  # T-CityLite.base/
RESOURCES = BASE / "resources"
API_DEFINITION = RESOURCES / "[qb]" / "qb-core" / "server" / "commands.lua"

COMMAND_START_RE = re.compile(
    r"(?<!function )(?<!function\s)(QBCore\.Commands\.Add|RegisterCommand)\s*\(\s*['\"](?P<name>[^'\"]+)['\"]"
)
GETPLAYER_SOURCE_RE = re.compile(
    r"GetPlayer(?:ByCitizenId)?\s*\(\s*(?:source|src)\s*\)"
)
PLAYERDATA_RE = re.compile(r"\b(?P<var>\w+)\.PlayerData")


def _blocks(lines: list[str]):
    """按括号深度切出每条命令的定义块（够用：命令体里不会出现未闭合括号）。"""
    index = 0
    while index < len(lines):
        match = COMMAND_START_RE.search(lines[index])
        if not match:
            index += 1
            continue
        depth, start = 0, index
        while index < len(lines):
            depth += lines[index].count("(") - lines[index].count(")")
            index += 1
            if depth <= 0:
                break
        yield match.group("name"), start + 1, lines[start:index]


def is_guarded(body: str, var: str) -> bool:
    return bool(
        re.search(rf"if\s+not\s+{re.escape(var)}\b", body)
        or re.search(rf"if\s+{re.escape(var)}\s+then", body)
        or re.search(rf"{re.escape(var)}\s*==\s*nil", body)
        or re.search(rf"assert\s*\(\s*{re.escape(var)}\b", body)
    )


def scan_command_guards(root: Path) -> list[str]:
    problems: list[str] = []
    for lua in sorted(root.rglob("*.lua")):
        if "node_modules" in lua.parts or lua.resolve() == API_DEFINITION.resolve():
            continue
        try:
            text = lua.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        if "Commands.Add" not in text and "RegisterCommand" not in text:
            continue
        lines = text.splitlines()
        for name, lineno, block in _blocks(lines):
            body = "\n".join(block)
            if not GETPLAYER_SOURCE_RE.search(body):
                continue
            match = PLAYERDATA_RE.search(body)
            if not match:
                continue
            var = match.group("var")
            # 只检查"来自 source 的 Player 变量"，避免误判目标玩家的 GetPlayer(id)
            player_line = re.search(
                rf"local\s+{re.escape(var)}\s*=\s*QBCore\.Functions\.GetPlayer\s*\(\s*(?:source|src)\s*\)",
                body,
            )
            if not player_line:
                continue
            if not is_guarded(body, var):
                problems.append(f"{lua.relative_to(root.parent)}:{lineno} /{name}")
    return problems


def test_command_handlers_guard_missing_player():
    problems = scan_command_guards(RESOURCES)
    assert not problems, (
        "命令可从控制台 (source=0) 或玩家掉线时触发，GetPlayer 会是 nil；"
        "索引 PlayerData 前必须判空：\n" + "\n".join(problems)
    )


def test_guard_rule_actually_fires():
    """反向校验：未判空的形状必须被抓到，判空的形状必须放过。"""
    bad = [
        "QBCore.Commands.Add('x', 'help', {}, false, function(source, _)",
        "    local Player = QBCore.Functions.GetPlayer(source)",
        "    if Player.PlayerData.job.name == 'police' then return end",
        "end)",
    ]
    assert scan_command_guards_from_lines(bad), "unguarded shape must be reported"

    good = [
        "QBCore.Commands.Add('x', 'help', {}, false, function(source, _)",
        "    local Player = QBCore.Functions.GetPlayer(source)",
        "    if not Player then return end",
        "    if Player.PlayerData.job.name == 'police' then return end",
        "end)",
    ]
    assert not scan_command_guards_from_lines(good), "guarded shape must pass"

    # 目标玩家的 GetPlayer(arg) 不在规则范围内
    target = [
        "QBCore.Commands.Add('y', 'help', {}, false, function(source, args)",
        "    local Target = QBCore.Functions.GetPlayer(tonumber(args[1]))",
        "    if Target then Target.PlayerData.job.name = 'x' end",
        "end)",
    ]
    assert not scan_command_guards_from_lines(target)


def scan_command_guards_from_lines(lines: list[str]) -> list[str]:
    """同一条规则，喂内存里的行（供反向校验使用）。"""
    problems = []
    for name, lineno, block in _blocks(lines):
        body = "\n".join(block)
        if not GETPLAYER_SOURCE_RE.search(body):
            continue
        match = PLAYERDATA_RE.search(body)
        if not match:
            continue
        var = match.group("var")
        if not re.search(
            rf"local\s+{re.escape(var)}\s*=\s*QBCore\.Functions\.GetPlayer\s*\(\s*(?:source|src)\s*\)",
            body,
        ):
            continue
        if not is_guarded(body, var):
            problems.append(f"line {lineno} /{name}")
    return problems
