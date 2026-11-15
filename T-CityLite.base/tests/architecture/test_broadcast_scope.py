"""S7 闸门：受众感知广播 —— `[custom]` 下每一处全服广播都必须登记。

背景：`TriggerClientEvent(<event>, -1, ...)` 把消息发给**所有在线玩家**。证据类事件
（血滴 / 指纹 / 弹壳）带着 DNA、血型、指纹与枪号，平民不该收到；其余全服广播也应当
逐条说明"为什么必须是全服"，否则 `-1` 会一直是最省事的写法，受众范围悄悄扩大。

判据两条：

1. `test_every_custom_broadcast_is_registered`（前向）
   * 扫 `resources/[custom]/**/*.lua` 的 `TriggerClientEvent(<event>, -1, ...)`；
   * 每条必须在 `broadcast_allowlist.json` 有 `file + event` 匹配的条目，
     且 `audience / reason / owner / expires / sites` 齐全；
   * `audience` 必须是 `all`（代码还是 `-1`，登记成 `job` 就是撒谎）；
   * 登记处的 `sites` 必须等于实际广播点数：同一 file+event 偷偷多一处也要红；
   * 新未登记 → 红；登记项没有对应代码（死条目）→ 红；过期 → 红。

2. `test_reverse_unregistered_broadcast_is_rejected`（反向）
   * 合成 `TriggerClientEvent('probe:client:all', -1)` → 必须报；
   * 合成注释里的 `-1` → 必须不报；
   * 合成 `Broadcast.Scope(...)` → 必须不报（helper 自身不是业务广播点）。

扫描器只认**代码**：`lua_source.blank_noise` 先把注释与字符串抹成空白（长度/行号不变），
所以文案或注释里的示例代码不会被当成真调用。
"""

from __future__ import annotations

import json
import re
from datetime import date
from pathlib import Path

import lua_source

BASE = Path(__file__).resolve().parents[2]
CUSTOM = BASE / "resources" / "[custom]"
ALLOWLIST = Path(__file__).with_name("broadcast_allowlist.json")

#: 登记项必填字段。`sites` 让"同 file+event 多冒一处"也要显形。
REQUIRED_FIELDS = ("file", "event", "audience", "reason", "owner", "expires", "sites")

_CALL = re.compile(r"\bTriggerClientEvent\s*\(")
_QUOTED = re.compile(r"(['\"])(.*?)\1", re.S)


def _arguments(code: str, open_index: int, close_index: int) -> list[tuple[int, int]]:
    """按顶层逗号切参数，返回每个参数的 `(start, end)` 偏移。

    `code` 是字符串已抹白的结构化视图，所以括号/逗号只可能来自真代码。
    """
    bounds: list[tuple[int, int]] = []
    start, depth = open_index + 1, 0
    for index in range(open_index + 1, close_index - 1):
        char = code[index]
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        elif char == "," and depth == 0:
            bounds.append((start, index))
            start = index + 1
    bounds.append((start, close_index - 1))
    return bounds


def _scan_source(source: str, rel: str) -> list[dict]:
    """返回 `source` 里所有发往 `-1` 的 TriggerClientEvent 调用点。"""
    code = lua_source.blank_noise(source)                      # 注释 + 字符串 → 空白
    text = lua_source.blank_noise(source, keep_strings=True)   # 注释 → 空白，字符串保留
    sites: list[dict] = []
    for match in _CALL.finditer(code):
        open_index = match.end() - 1
        arguments = _arguments(code, open_index, lua_source.match_paren(code, open_index))
        if len(arguments) < 2 or re.sub(r"\s+", "", code[slice(*arguments[1])]) != "-1":
            continue
        raw_event = text[slice(*arguments[0])].strip()
        literal = _QUOTED.fullmatch(raw_event)
        sites.append({
            "file": rel,
            "event": literal.group(2) if literal else raw_event,
            "dynamic": literal is None,
            "line": lua_source.line_of(code, match.start()),
        })
    return sites


def _scan_repo() -> list[dict]:
    sites: list[dict] = []
    for path in sorted(CUSTOM.rglob("*.lua")):
        sites.extend(_scan_source(path.read_text(encoding="utf-8", errors="ignore"),
                                  path.relative_to(BASE).as_posix()))
    return sites


def _audit(sites: list[dict], entries: list[dict]) -> list[str]:
    """返回问题清单（空 = 全部登记且没有死条目/过期条目）。"""
    problems: list[str] = []
    registered: dict[tuple[str, str], int] = {}
    seen: set[tuple[str, str]] = set()
    today = date.today()

    for entry in entries:
        key = (str(entry.get("file", "")), str(entry.get("event", "")))
        missing = [field for field in REQUIRED_FIELDS if not str(entry.get(field, "")).strip()]
        if missing:
            problems.append(f"{key[0] or '?'} {key[1] or '?'}: 登记项缺字段 {', '.join(missing)}")
            continue
        if key in seen:
            problems.append(f"{key[0]} {key[1]}: 重复登记")
            continue
        seen.add(key)
        if entry["audience"] != "all":
            problems.append(
                f"{key[0]} {key[1]}: audience={entry['audience']!r}，但代码仍是 -1 全服广播 —— "
                "要收窄受众请改用 Broadcast.Scope，并从登记表删除这一条")
        try:
            if date.fromisoformat(str(entry["expires"])) < today:
                problems.append(f"{key[0]} {key[1]}: 登记已于 {entry['expires']} 过期 —— 修掉广播或续期")
        except ValueError:
            problems.append(f"{key[0]} {key[1]}: expires 不是 ISO 日期：{entry['expires']!r}")
        if type(entry["sites"]) is not int or entry["sites"] < 1:
            problems.append(f"{key[0]} {key[1]}: sites 必须是正整数")
            continue
        registered[key] = entry["sites"]

    actual: dict[tuple[str, str], list[dict]] = {}
    for site in sites:
        actual.setdefault((site["file"], site["event"]), []).append(site)

    for key, found in actual.items():
        expected = registered.get(key)
        if expected is None:
            for site in found:
                label = site["event"] if not site["dynamic"] else f"<动态表达式 {site['event']}>"
                problems.append(f"{site['file']}:{site['line']}  {label}  未登记")
        elif len(found) != expected:
            lines = ", ".join(str(site["line"]) for site in found)
            problems.append(
                f"{key[0]} {key[1]}: 登记 {expected} 处，实际 {len(found)} 处（{lines} 行）—— "
                "多出的广播点没有单独审过")
    for key, expected in registered.items():
        if key not in actual:
            problems.append(f"{key[0]} {key[1]}: 死条目（登记 {expected} 处，代码里一处都不命中）")
    return problems


def test_every_custom_broadcast_is_registered():
    sites = _scan_repo()
    assert sites, "扫描器一处全服广播都没找到 —— 扫描范围被改坏了？"
    entries = json.loads(ALLOWLIST.read_text(encoding="utf-8"))["entries"]
    problems = _audit(sites, entries)
    assert not problems, (
        "[custom] 下每一处 TriggerClientEvent(<event>, -1, ...) 都必须在 "
        "tests/architecture/broadcast_allowlist.json 登记（audience/reason/owner/expires/sites）：\n  "
        + "\n  ".join(problems))


def test_reverse_unregistered_broadcast_is_rejected():
    rel = "resources/[custom]/probe/server/probe.lua"

    found = _scan_source("TriggerClientEvent('probe:client:all', -1)\n", rel)
    problems = _audit(found, [])
    assert problems and "probe:client:all" in problems[0] and "未登记" in problems[0], problems

    commented = (
        "-- TriggerClientEvent('probe:client:all', -1)\n"
        "--[[\nTriggerClientEvent('probe:client:all', -1)\n]]\n"
        "local text = \"TriggerClientEvent('probe:client:all', -1)\"\n"
    )
    assert _audit(_scan_source(commented, rel), []) == [], "注释/字符串里的示例被误报了"

    scoped = "Broadcast.Scope('probe:client:all', { all = true })\n"
    assert _audit(_scan_source(scoped, rel), []) == [], "Broadcast.Scope 被当成业务广播点了"

    entry = {"file": rel, "event": "probe:client:all", "sites": 1, "audience": "all",
             "reason": "probe", "owner": "probe", "expires": "2027-03-31"}
    assert _audit(found, [entry]) == [], "已登记的广播不应被报出来"
