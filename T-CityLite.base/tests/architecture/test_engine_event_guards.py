"""TS-5 引擎层 — qb-core 的调试事件必须有来源守卫。

为什么单独一个文件：`test_net_event_auth.py` 的扫描范围是 custom-police / custom-phone /
core-framework，引擎层（qb-core）不在范围内。于是 `QBCore:DebugSomething` 这种裸的
`RegisterServerEvent` 从来没被任何闸门看过 —— 任何客户端都能让服务端打印任意表，
既能刷屏也能用深层表放大内存与 IO。

这里只钉一件事：该 handler 必须能区分"客户端触发"与"服务端自己 Debug"，并且给 indent 上限。
反向用例保证这条断言不是恒真。
"""

from __future__ import annotations

import re
import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
DEBUG_LUA = BASE / "resources" / "[qb]" / "qb-core" / "server" / "debug.lua"

REGISTER_RE = re.compile(r"RegisterServerEvent\(\s*'QBCore:DebugSomething'")
CLAMP_RE = re.compile(r"math\.min\(\s*depth,\s*MAX_DEBUG_INDENT\)")
TOKENS = {
    "server_vs_client": "GetInvokingResource",
    "ace_guard": "IsPlayerAceAllowed",
    "ace_name": "'qb.debug'",
    "indent_clamp": "MAX_DEBUG_INDENT",
}


#: 反向校验用的坏形状：同名的 handler，但没有来源守卫，indent 直接透传。
UNGUARDED = """RegisterServerEvent('QBCore:DebugSomething', function(tbl, indent, resource)
    print('debug')
    tPrint(tbl, indent)
end)
"""


def read_source() -> str:
    return DEBUG_LUA.read_text(encoding="utf-8")


def handler_body(text: str) -> str:
    """Return the handler body up to the closing `end)` on its own line."""
    lines = text.splitlines()
    start = None
    for index, line in enumerate(lines):
        if REGISTER_RE.search(line):
            start = index
            break
    assert start is not None, "QBCore:DebugSomething 不见了 —— 更新本闸门之前先确认事件名"
    body: list[str] = []
    for line in lines[start + 1:]:
        if line.strip() == "end)":
            break
        body.append(line)
    return "\n".join(body)


def missing_tokens(text: str) -> list[str]:
    body = handler_body(text)
    return [name for name, token in TOKENS.items() if token not in body]


def test_rejects_a_handler_without_a_source_guard():
    # 反向：合成的无守卫形状必须先被判红，否则下面是恒真断言
    assert missing_tokens(UNGUARDED) == [
        "server_vs_client", "ace_guard", "ace_name", "indent_clamp",
    ], "无守卫的形状没有被判红 —— 这条规则是恒真的"

    text = read_source()
    assert REGISTER_RE.search(text), "QBCore:DebugSomething 不是 RegisterServerEvent 了"
    assert missing_tokens(text) == [], (
        "QBCore:DebugSomething 缺少守卫，客户端可以任意刷服务端日志：\n"
        + "\n".join(f"  - {name}" for name in missing_tokens(text))
        + "\n修法：用 GetInvokingResource() 区分服务端自触发，其它来源要求 "
          "IsPlayerAceAllowed(src, 'qb.debug')，并把 indent 钳到 MAX_DEBUG_INDENT。"
    )


def test_rejects_unclamped_client_indent():
    # 反向：indent 直接透传的形状必须匹配不到钳制
    assert not CLAMP_RE.search(handler_body(UNGUARDED)), (
        "indent 直接透传的形状没有被判红 —— 钳制规则是恒真的"
    )

    body = handler_body(read_source())
    assert CLAMP_RE.search(body), (
        "indent 直接来自客户端，必须 tonumber + math.min 钳到 MAX_DEBUG_INDENT，"
        "否则深层嵌套表会让 tPrint 递归到栈溢出"
    )
    assert "tPrint(tbl, depth)" in body, "钳制后的值没有被真正传给 tPrint"


# ── 行为验证：静态正则只能证明"文本里有守卫"，跑一遍才能证明"守卫真的拦得住" ──

HARNESS = r"""
__prints = {}
print = function(...)
    local n = select('#', ...)
    local parts = {}
    for i = 1, n do parts[i] = tostring(select(i, ...)) end
    __prints[#__prints + 1] = table.concat(parts, '\t')
end
__handlers = {}
__ace = {}
__invoking = nil
RegisterServerEvent = function(name, fn) __handlers[name] = fn end
GetInvokingResource = function() return __invoking end
IsPlayerAceAllowed = function(src, ace) return __ace[src] == true end
TriggerEvent = function() end
QBCore = { Debug = function() end, ShowError = function() end, ShowSuccess = function() end }
source = nil
"""

PROBE = r"""
local H = assert(__handlers['QBCore:DebugSomething'], 'handler 没有注册')

local function fire(src, invoking, tbl, indent)
    __prints = {}
    source = src
    __invoking = invoking
    H(tbl or { k = 1 }, indent or 0, 'test')
    return #__prints
end

-- 1) 普通客户端：必须静默
assert(fire(123, nil, { k = 1 }) == 0, '无 ACE 的客户端竟然打印了')

-- 2) 持 ACE 的客户端：放行
__ace[123] = true
assert(fire(123, nil, { k = 1 }) >= 2, '持 qb.debug 的玩家被误伤')
__ace[123] = nil

-- 3) 控制台（source = 0）：放行
assert(fire(0, nil, { k = 1 }) >= 2, '控制台被误伤')

-- 4) 服务端自触发（GetInvokingResource 有值）：放行，不能误伤 QBCore.Debug
assert(fire(123, 'qb-core', { k = 1 }) >= 2, '服务端自触发被误伤')

-- 5) 深度上限：30 层嵌套 + indent=50，打印行数必须有界
local deep = {}
local cursor = deep
for _ = 1, 30 do
    cursor.child = {}
    cursor = cursor.child
end
local lines = fire(0, nil, deep, 50)
local lines0 = fire(0, nil, deep, 0)
io.write('DEPTH_LINES=' .. tostring(lines) .. '\\n')
assert(lines <= 12, '深度没有被截断，打印了 ' .. lines .. ' 行')
assert(lines0 <= 12, 'indent=0 时 tPrint 自身的深度上限没生效，打印了 ' .. lines0 .. ' 行')
"""


def test_rejects_hostile_client_and_caps_depth_at_runtime():
    """跑真实 debug.lua：无 ACE 的客户端必须静默，深表必须被截断。"""
    script = HARNESS + "\n" + read_source() + "\n" + PROBE
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False, encoding="utf-8") as handle:
        handle.write(script)
        path = handle.name

    result = subprocess.run(["lua5.4", path], capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, f"行为验证失败：\n{result.stderr}\n{result.stdout}"
    assert "DEPTH_LINES=" in result.stdout
