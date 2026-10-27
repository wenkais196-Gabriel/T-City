"""test_rate_limit.py — 限流原语的语义单测（真跑 Lua，不 mock 逻辑）。

为什么这些用例必须存在：限流是安全原语，off-by-one 就是"多数放过一次"。
真实调用探针第一次跑就抓到 `TokenBucket` 的 burst=2 放过了第 3 次——
首个分支建桶时给了满 tokens 却没有扣掉本次那一个。静态闸门看不见这种错，只有执行能看见。

覆盖：Cooldown（每键冷却）/ Window（固定窗口计数）/ TokenBucket（速率+突发）/ Reset（前缀）/
Sweep（过期清理）。时间通过 `GetGameTimer` 桩注入，不依赖 sleep。
"""

from __future__ import annotations

import shutil
import subprocess
import textwrap
from pathlib import Path

import pytest

CORE = Path(__file__).resolve().parents[3] / "resources" / "[standalone]" / "core-framework"
OWNER = CORE / "server" / "rate_limit.lua"

MOCK = """
-- 时间桩：测试里直接改 __now
__now = 1000
function GetGameTimer() return __now end
function os.time() return math.floor(__now / 1000) end
__exported = {}
function exports(name, fn)
    if type(name) == 'string' then __exported[name] = fn end
end
function IsDuplicityVersion() return true end
"""


def luac() -> str:
    exe = shutil.which("lua5.4") or shutil.which("lua")
    if not exe:
        pytest.skip("lua5.4 不可用")
    return exe


def run_lua(body: str) -> dict:
    """把 mock + owner + 断言体拼成一段 Lua 跑，返回 stdout 行。"""
    script = MOCK + "\n" + OWNER.read_text(encoding="utf-8") + "\n" + textwrap.dedent(body)
    proc = subprocess.run([luac(), "-"], input=script, capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, f"Lua 执行失败:\n{proc.stderr}"
    out = {}
    for line in proc.stdout.strip().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def test_exports_are_registered():
    out = run_lua("""
        for _, name in ipairs({'RateLimitCooldown', 'RateLimitWindow', 'RateLimitReset', 'RateLimitTokenBucket'}) do
            print(('has_%s=%s'):format(name, tostring(__exported[name] ~= nil)))
        end
    """)
    assert all(v == "true" for v in out.values()), out


def test_cooldown_blocks_then_recovers():
    out = run_lua("""
        print('first=' .. tostring(RateLimit.Cooldown('k', 1000)))
        __now = 1500
        print('inside=' .. tostring(RateLimit.Cooldown('k', 1000)))
        __now = 2000
        print('after=' .. tostring(RateLimit.Cooldown('k', 1000)))
        print('other_key=' .. tostring(RateLimit.Cooldown('k2', 1000)))
    """)
    assert out == {"first": "true", "inside": "false", "after": "true", "other_key": "true"}


def test_window_counts_within_window_and_resets():
    out = run_lua("""
        print('w1=' .. tostring(RateLimit.Window('w', 2, 1000)))
        print('w2=' .. tostring(RateLimit.Window('w', 2, 1000)))
        print('w3=' .. tostring(RateLimit.Window('w', 2, 1000)))
        __now = 1000 + 1001        -- 滑出窗口
        print('w4=' .. tostring(RateLimit.Window('w', 2, 1000)))
        print('w5=' .. tostring(RateLimit.Window('w', 2, 1000)))
    """)
    assert out == {"w1": "true", "w2": "true", "w3": "false", "w4": "true", "w5": "true"}


def test_token_bucket_allows_exactly_burst_then_throttles():
    """burst=N 只能连续放过 N 次——探针实测这里是 3 次，这是被此用例钉住的 bug。"""
    out = run_lua("""
        local r1 = RateLimit.TokenBucket('b', 60, 2)
        local r2 = RateLimit.TokenBucket('b', 60, 2)
        local r3, retry = RateLimit.TokenBucket('b', 60, 2)
        print('burst=' .. table.concat({tostring(r1), tostring(r2), tostring(r3)}, ','))
        print('retry_positive=' .. tostring(retry > 0))
    """)
    assert out["burst"] == "true,true,false", f"burst=2 放过了多余请求: {out['burst']}"
    assert out["retry_positive"] == "true", "被拒时必须给出正的重试间隔"


def test_token_bucket_refills_over_time():
    out = run_lua("""
        RateLimit.TokenBucket('r', 60000, 1)   -- 60000/min = 每分钟 1 个/毫秒 1 个
        local blocked = RateLimit.TokenBucket('r', 60000, 1)
        __now = 2100                            -- 100ms 后回满 1 个
        local after = RateLimit.TokenBucket('r', 60000, 1)
        print('blocked=' .. tostring(blocked))
        print('after_refill=' .. tostring(after))
    """)
    assert out["blocked"] == "false"
    assert out["after_refill"] == "true"


def test_reset_clears_a_whole_prefix_family():
    out = run_lua("""
        RateLimit.Cooldown('sec:1:kick', 5000)
        RateLimit.Window('sec:1:lookup', 1, 5000)
        RateLimit.Cooldown('sec:2:kick', 5000)
        RateLimit.Reset('sec:1:')
        print('one_kick=' .. tostring(RateLimit.Cooldown('sec:1:kick', 5000)))
        print('one_lookup=' .. tostring(RateLimit.Window('sec:1:lookup', 1, 5000)))
        print('two_kick=' .. tostring(RateLimit.Cooldown('sec:2:kick', 5000)))
    """)
    assert out["one_kick"] == "true", "Reset 没清掉玩家 1 的冷却"
    assert out["one_lookup"] == "true", "Reset 没清掉玩家 1 的窗口计数"
    assert out["two_kick"] == "false", "Reset 越界清掉了别的玩家"


def test_sweep_drops_expired_entries_only():
    out = run_lua("""
        RateLimit.Cooldown('old', 1000)
        __now = 1000 + 60000
        RateLimit.Cooldown('fresh', 1000)
        local before = RateLimit.Size()
        RateLimit.Sweep(30000)
        print('before=' .. before)
        print('after=' .. RateLimit.Size())
        print('fresh_still_blocked=' .. tostring(RateLimit.Cooldown('fresh', 1000)))
    """)
    assert int(out["before"]) >= 2
    assert int(out["after"]) < int(out["before"]), "Sweep 没清掉过期条目"
    assert out["fresh_still_blocked"] == "false", "Sweep 误清了未过期条目"


def test_bad_arguments_never_throw():
    out = run_lua("""
        print('nil_key=' .. tostring(pcall(function() return RateLimit.Cooldown(nil, 1000) end)))
        print('nan_amount=' .. tostring(pcall(function() return RateLimit.Window('x', 0/0, 0/0) end)))
        print('neg=' .. tostring(pcall(function() return RateLimit.TokenBucket('t', -5, -5) end)))
    """)
    assert all(v == "true" for v in out.values()), out
