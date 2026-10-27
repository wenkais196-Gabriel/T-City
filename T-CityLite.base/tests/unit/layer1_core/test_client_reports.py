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


def test_twenty_resources_all_get_a_line_and_the_cap_still_bounds_the_log():
    """真正的形状：一次登录有 20 个资源各发一条信标。

    旧限流是 3 条/分钟 —— 把后 17 个直接丢了，"接上了"却只看得见 3 个。
    现在：同一资源 60s 内只记一条；每玩家总量 40 条/60s 挡住伪造资源名刷屏。
    """
    out = run("""
        __say = function(s) io.write(tostring(s) .. string.char(10)) end
        source = 1
        local ready = __handlers['core-framework:server:clientReady']
        -- ① 20 个不同资源（同时刻，和真登录一样）
        for i = 1, 20 do ready('res' .. i, '1.0.0')
        end
        __say('after20=' .. #__printed)

        -- ② 同一个资源再来两次 → 不该重复记
        ready('res1', '1.0.0')
        ready('res1', '1.0.0')
        __say('after_dup=' .. #__printed)

        -- ③ 继续伪造资源名，总量封顶 40
        for i = 21, 60 do ready('res' .. i, '1.0.0')
        end
        __say('after_flood=' .. #__printed)

        -- ④ 换一个玩家，额度独立
        local before = #__printed
        _G.source = 2
        ready('other', '1.0.0')
        __say('other_player=' .. (#__printed - before))
        __say('first_line=' .. tostring(__printed[1]))
    """)
    assert out["after20"] == "20", "20 个资源必须各记一条（旧限流会只留 3 条）"
    assert out["after_dup"] == "20", "同一资源不应重复记"
    assert out["after_flood"] == "40", "每玩家总量必须封顶在 40，否则伪造资源名能刷屏"
    assert out["other_player"] == "1", "限流按玩家隔离"
    assert "v1.0.0" in out["first_line"] and "Tester1" in out["first_line"]
