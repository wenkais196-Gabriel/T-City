"""test_police_audit_writer.py — 审计唯一写者（真跑 Lua，桩只替换 MySQL/print）。

这条测试的存在理由是一次真库实测：旧写法在 `detail = nil` 时生成的 SQL 会让
MariaDB 报语法错，而 `pcall` 返回 **true**（oxmysql 把错误当返回值），于是调用方
`if not audit(...)` 把失败当成功 —— **审计行静默丢失**。

所以这里钉三件事：
1. 参数数组里不能留洞（nil 的 target/detail 必须变成 SQL 里的 NULL）；
2. 数据库返回错误字符串必须判为失败；
3. 截断与 actor_kind 的默认值。
"""

from __future__ import annotations

import shutil
import subprocess
import textwrap
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
AUDIT = BASE / "resources" / "[custom]" / "custom-police" / "server" / "audit.lua"

STUBS = """
__sql = {}
__params = {}
__rows = {}
__mode = 'ok'          -- 'ok' | 'error_string' | 'throw'
MySQL = {}
function MySQL.query_await(sql, values)
    __sql[#__sql + 1] = sql
    __params[#__params + 1] = values
    if __mode == 'throw' then error('connection lost', 0) end
    if __mode == 'error_string' then
        return "You have an error in your SQL syntax; check the manual near '?)' at line 1"
    end
    local n = #values
    for i = 0, 4 do
        if i < n then __rows[i + 1] = true end
    end
    return { affectedRows = 1 }
end
MySQL.query = { await = MySQL.query_await }
__printed = {}
function print(line) __printed[#__printed + 1] = tostring(line) end
function __say(t) io.write(tostring(t) .. string.char(10)) end
"""


def lua() -> str:
    exe = shutil.which("lua5.4") or shutil.which("lua")
    if not exe:
        pytest.skip("lua5.4 不可用")
    return exe


def run(body: str) -> dict:
    script = STUBS + "\n" + AUDIT.read_text(encoding="utf-8") + "\n" + textwrap.dedent(body)
    proc = subprocess.run([lua(), "-"], input=script, capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, f"Lua 执行失败:\n{proc.stderr}"
    out = {}
    for line in proc.stdout.strip().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def test_full_arguments_produce_placeholders_for_all_five_columns():
    out = run("""
        local ok = PoliceAudit.Write('cid1', 'incident.create', '42', '详细说明')
        __say('ok=' .. tostring(ok))
        __say('sql=' .. __sql[1])
        __say('params=' .. #__params[1])
    """)
    assert out["ok"] == "true"
    assert out["params"] == "5", "五个列都要有参数"
    assert "NULL" not in out["sql"]


def test_nil_target_and_detail_become_null_not_a_parameter_hole():
    """这就是那个 bug：旧的写法在这里生成 `?, ?, ?, ?` 配 3 个参数。"""
    out = run("""
        local ok = PoliceAudit.Write('cid1', 'unit.duty')
        __say('ok=' .. tostring(ok))
        __say('sql=' .. __sql[1])
        __say('params=' .. #__params[1])
        __say('holes=' .. tostring(__params[1][4]))
    """)
    assert out["ok"] == "true"
    assert out["params"] == "3", "只有 actor/kind/action 三个参数"
    assert "NULL, NULL" in out["sql"], "target 与 detail 必须是 SQL 里的 NULL"
    assert out["holes"] == "nil"


def test_database_error_string_is_reported_as_failure():
    """oxmysql 把 SQL 错误当返回值给；不检查这一点 = 审计可以静默丢失。"""
    out = run("""
        __mode = 'error_string'
        local ok = PoliceAudit.Write('cid1', 'citation.create', '7', 'x')
        __say('ok=' .. tostring(ok))
        __say('printed=' .. tostring(#__printed > 0))
    """)
    assert out["ok"] == "false"
    assert out["printed"] == "true", "失败必须留下日志，否则没人知道审计没写进去"


def test_exception_is_reported_as_failure():
    out = run("""
        __mode = 'throw'
        local ok = PoliceAudit.Write('cid1', 'citation.create', '7', 'x')
        __say('ok=' .. tostring(ok))
    """)
    assert out["ok"] == "false"


def test_actor_kind_defaults_to_player_and_can_be_overridden():
    out = run("""
        PoliceAudit.Write('cid1', 'a.b', nil, nil)
        PoliceAudit.Write('agent:9', 'a.b', nil, nil, 'agent')
        PoliceAudit.WriteAgent(9, 'a.c', 'target1', 'detail')
        __say('kind1=' .. tostring(__params[1][2]))
        __say('kind2=' .. tostring(__params[2][2]))
        __say('kind3=' .. tostring(__params[3][2]))
        __say('actor3=' .. tostring(__params[3][1]))
    """)
    assert out["kind1"] == "player"
    assert out["kind2"] == "agent"
    assert out["kind3"] == "agent"
    assert out["actor3"] == "agent:9"


def test_long_fields_are_truncated():
    out = run("""
        PoliceAudit.Write('cid1', 'a.b', string.rep('T', 200), string.rep('D', 2000))
        __say('target_len=' .. #__params[1][4])
        __say('detail_len=' .. #__params[1][5])
    """)
    assert int(out["target_len"]) <= 64
    assert int(out["detail_len"]) <= 500


def test_empty_action_is_refused_without_touching_the_db():
    out = run("""
        __say('empty=' .. tostring(PoliceAudit.Write('cid', '')))
        __say('nil_action=' .. tostring(PoliceAudit.Write('cid', nil)))
        __say('queries=' .. #__sql)
    """)
    assert out["empty"] == "false"
    assert out["nil_action"] == "false"
    assert out["queries"] == "0"
