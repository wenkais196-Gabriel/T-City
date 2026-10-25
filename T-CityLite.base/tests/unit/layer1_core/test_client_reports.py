"""test_client_reports.py — 客户端可观测性通道的服务端一半（真跑 Lua）。

为什么要紧：这条通道**由客户端完全控制输入**，而它的输出是服务端日志。所以它必须
同时证明两件事——(1) 不会被客户端拿来伪造日志行；(2) 不会被当成日志放大器刷爆。

这里用真文件 + 桩环境跑：桩负责捕获 `RegisterNetEvent` 注册的处理器，然后我们以
伪造的 source 直接调用它们（服务端没法假装"某个玩家发了事件"，这是唯一能验证到
处理器内部的路径；客户端那一半要真玩家才能验，属于已知边界）。
"""

from __future__ import annotations

import shutil
import subprocess
import textwrap
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
MODULE = BASE / "resources" / "[standalone]" / "core-framework" / "server" / "client_reports.lua"

STUBS = """
__handlers = {}
function RegisterNetEvent(name, fn) __handlers[name] = fn end
__printed = {}
function __say(text) io.write(tostring(text) .. string.char(10)) end
function print(line) __printed[#__printed + 1] = tostring(line) end
function GetPlayerName(src) return 'Tester' .. tostring(src) end
-- 限流桩：真实现是 core-framework 的 owner；这里用最小可用的固定窗口，语义一致
__windows = {}
exports = setmetatable({}, {
    __index = function(_, resource)
        return setmetatable({}, {
            __index = function(_, method)
                return function(_, key, limit, windowMs)
                    local now = os.time()
                    local w = __windows[key]
                    if not w or now - w.start >= windowMs / 1000 then
                        __windows[key] = { count = 1, start = now }
                        return true
                    end
                    w.count = w.count + 1
                    return w.count <= limit
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


def run(body: str) -> dict:
    script = STUBS + "\n" + MODULE.read_text(encoding="utf-8") + "\n" + textwrap.dedent(body)
    proc = subprocess.run([lua(), "-"], input=script, capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, f"Lua 执行失败:\n{proc.stderr}"
    out = {}
    for line in proc.stdout.strip().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def test_both_events_are_registered():
    out = run("""
        __say('ready=' .. tostring(__handlers['core-framework:server:clientReady'] ~= nil))
        __say('report=' .. tostring(__handlers['core-framework:server:clientReport'] ~= nil))
    """)
    assert out == {"ready": "true", "report": "true"}


def test_ready_beacon_logs_resource_and_version():
    out = run("""
        source = 7
        __handlers['core-framework:server:clientReady']('custom-police', '1.7.0')
        __say('lines=' .. #__printed)
        __say('line0=' .. tostring(__printed[1]))
    """)
    assert out["lines"] == "1"
    assert "[client-ready]" in out["line0"]
    assert "custom-police" in out["line0"] and "v1.7.0" in out["line0"]
    assert "#7" in out["line0"], "日志里要能定位到玩家"


def test_newlines_are_stripped_so_clients_cannot_forge_log_lines():
    out = run("""
        source = 8
        __handlers['core-framework:server:clientReport']('error', 'boom\\n[ADMIN] fake line\\r\\nsecond')
        __say('lines=' .. #__printed)
        __say('line0=' .. tostring(__printed[1]))
    """)
    assert out["lines"] == "1", "一次上报只能产出一行日志"
    assert "\n" not in out["line0"]
    assert "[ADMIN] fake line" in out["line0"], "内容保留但被压进同一行"


def test_message_is_truncated():
    out = run("""
        source = 9
        local long = string.rep('x', 1000)
        __handlers['core-framework:server:clientReport']('error', long)
        __say('len=' .. #__printed[1])
    """)
    assert int(out["len"]) < 520, "长消息必须截断，否则一条上报就能刷满日志"


def test_invalid_kind_and_non_scalars_are_dropped():
    out = run("""
        source = 10
        __handlers['core-framework:server:clientReport']('debug', 'nope')
        __handlers['core-framework:server:clientReport']('error', { nested = true })
        __handlers['core-framework:server:clientReport']('error', '')
        __say('lines=' .. #__printed)
    """)
    assert out["lines"] == "0"


def test_report_is_rate_limited_per_player():
    out = run("""
        source = 11
        for _ = 1, 20 do
            __handlers['core-framework:server:clientReport']('warn', 'spam')
        end
        __say('lines=' .. #__printed)
    """)
    assert int(out["lines"]) <= 10, f"每玩家上限 10 条，实际写了 {out['lines']}"


def test_source_zero_is_ignored():
    out = run("""
        source = 0
        __handlers['core-framework:server:clientReady']('custom-police', '1.0.0')
        __handlers['core-framework:server:clientReport']('error', 'from server')
        __say('lines=' .. #__printed)
    """)
    assert out["lines"] == "0", "source=0 是服务端来源，不该被当成玩家上报"
