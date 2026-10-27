"""test_police_citations.py — 罚单唯一写者（真跑 Lua，桩只替换 MySQL/审计）。

收口前的两个毛病，这两组测试就是它们的回归：
1. p1 的 INSERT 把 `plate`/`incident_id` 以 nil 塞进参数数组——不带车牌开罚单时数组出现空洞，
   oxmysql 截断 → MariaDB 语法错 → 开单永远返回 db_error。这里断言"不带车牌/不带案子"也能写成功。
2. 金额政策有两份（p1 自由金额、p2 按基准价 0.8~1.2 倍钳制）。这里断言只有一份公式。
"""

from __future__ import annotations

import shutil
import subprocess
import textwrap
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
SRC = BASE / "resources" / "[custom]" / "custom-police" / "server" / "citations.lua"

STUBS = """
__sql, __params, __audits = {}, {}, {}
__nextId = 100
__insertResult = nil          -- 覆盖返回值用（模拟错误字符串）
MySQL = {}
MySQL.insert = { await = function(sql, values)
    __sql[#__sql + 1] = sql
    __params[#__params + 1] = values
    if __insertResult ~= nil then return __insertResult end
    __nextId = __nextId + 1
    return __nextId
end }
MySQL.update = { await = function(sql, values)
    __sql[#__sql + 1] = sql
    __params[#__params + 1] = values
    return { affectedRows = 1 }
end }
function InsertId(value)
    if type(value) == 'number' then return value end
    if type(value) == 'table' then return tonumber(value.insertId or value.insert_id) end
    return nil
end
function PoliceAuditWriteStub(_, action, target, detail) __audits[#__audits + 1] = { action, target, detail } ; return true end
PoliceAudit = { Write = function(a, action, target, detail) return PoliceAuditWriteStub(a, action, target, detail) end }
function print(_) end
function __say(t) io.write(tostring(t) .. string.char(10)) end
"""


def lua() -> str:
    exe = shutil.which("lua5.4") or shutil.which("lua")
    if not exe:
        pytest.skip("lua5.4 不可用")
    return exe


def run(body: str) -> dict:
    script = STUBS + "\n" + SRC.read_text(encoding="utf-8") + "\n" + textwrap.dedent(body)
    proc = subprocess.run([lua(), "-"], input=script, capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, f"Lua 执行失败:\n{proc.stderr}"
    out = {}
    for line in proc.stdout.strip().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


# ── 金额政策 ────────────────────────────────────────────────────


def test_policy_amount_clamps_to_the_band_around_base():
    out = run("""
        __say('low=' .. tostring(PoliceCitations.PolicyAmount(1000, 100)))
        __say('high=' .. tostring(PoliceCitations.PolicyAmount(1000, 99999)))
        __say('base=' .. tostring(PoliceCitations.PolicyAmount(1000)))
        __say('mid=' .. tostring(PoliceCitations.PolicyAmount(1000, 1100)))
        __say('bad=' .. tostring(PoliceCitations.PolicyAmount(nil, 100)))
        __say('bad2=' .. tostring(PoliceCitations.PolicyAmount(1000, 'abc')))
    """)
    assert out["low"] == "800", "低于下限要抬到 0.8×base"
    assert out["high"] == "1200", "高于上限要压到 1.2×base"
    assert out["base"] == "1000", "不指定金额时取基准价"
    assert out["mid"] == "1100", "区间内原样保留"
    assert out["bad"] == "nil"
    assert out["bad2"] == "nil"


# ── 写入：列集合与 nil 洞 ────────────────────────────────────────


def test_citation_without_plate_or_incident_still_writes():
    """这就是旧 p1 的 bug：plate=nil 时参数数组被截断。"""
    out = run("""
        local id = PoliceCitations.Insert('officer-cid', {
            citizenid = 'target-cid', amount = 500, reason = '超速 25km/h',
        })
        __say('id=' .. tostring(id))
        __say('params=' .. #__params[1])
        __say('sql_has_null=' .. tostring(__sql[1]:find('INSERT INTO police_citations') ~= nil))
        __say('no_holes=' .. tostring(__params[1][#__params[1]] ~= nil))
    """)
    assert out["id"] != "nil"
    assert out["sql_has_null"] == "true"
    assert out["no_holes"] == "true", "参数数组末尾不能有空洞"
    assert int(out["params"]) == 4, "citizenid/officer/amount/reason 四个参数"


def test_optional_columns_are_added_only_when_present():
    out = run("""
        PoliceCitations.Insert('officer', {
            citizenid = 't', amount = 100, reason = '闯红灯',
            plate = 'abc123', incident_id = '7', charge_id = 'C1',
            base_amount = 100, report_id = 9,
        })
        __say('params=' .. #__params[1])
        __say('cols=' .. tostring(__sql[1]:find('plate') ~= nil))
        __say('charge=' .. tostring(__sql[1]:find('charge_id') ~= nil))
        __say('report=' .. tostring(__sql[1]:find('report_id') ~= nil))
    """)
    assert int(out["params"]) == 9, "四个必填 + plate/incident/charge/base/report = 9"
    assert out["cols"] == "true" and out["charge"] == "true" and out["report"] == "true"


def test_agent_path_amount_is_settled_by_the_policy():
    out = run("""
        local id, settled = PoliceCitations.Insert('officer', {
            citizenid = 't', amount = 99999, base_amount = 500, reason = '持械抢劫',
        })
        __say('id=' .. tostring(id))
        __say('settled=' .. tostring(settled))
        __say('stored=' .. tostring(__params[1][3]))
    """)
    assert out["id"] != "nil"
    assert out["settled"] == "600", "0.8~1.2×500 → 上限 600"
    assert out["stored"] == "600", "写进库的必须是结算后的金额"


def test_free_amount_must_be_within_the_players_band():
    out = run("""
        __say('zero=' .. tostring((PoliceCitations.Insert('o', { citizenid='t', amount=0, reason='abc' }))))
        __say('huge=' .. tostring((PoliceCitations.Insert('o', { citizenid='t', amount=99999, reason='abc' }))))
        __say('rows=' .. #__sql)
    """)
    assert out["zero"] == "nil"
    assert out["huge"] == "nil"
    assert out["rows"] == "0", "校验不过就不该碰数据库"


def test_reason_and_citizen_are_validated():
    out = run("""
        __say('short=' .. tostring((PoliceCitations.Insert('o', { citizenid='t', amount=10, reason='ab' }))))
        __say('nocid=' .. tostring((PoliceCitations.Insert('o', { amount=10, reason='abc' }))))
        __say('notable=' .. tostring((PoliceCitations.Insert('o', nil))))
    """)
    assert out["short"] == "nil"
    assert out["nocid"] == "nil"
    assert out["notable"] == "nil"


def test_audit_is_written_once_by_the_owner():
    out = run("""
        PoliceCitations.Insert('officer-cid', { citizenid='target-cid', amount=250, reason='无证驾驶' })
        __say('audits=' .. #__audits)
        __say('action=' .. tostring(__audits[1] and __audits[1][1]))
        __say('target=' .. tostring(__audits[1] and __audits[1][2]))
        __say('detail=' .. tostring(__audits[1] and __audits[1][3]))
    """)
    assert out["audits"] == "1", "一次开单只记一条审计"
    assert out["action"] == "citation.issue"
    assert out["target"] == "target-cid"
    assert out["detail"].startswith("$250"), "审计里要有结算金额"


def test_db_error_string_is_a_failure_not_an_id():
    out = run("""
        __insertResult = 'You have an error in your SQL syntax near ?)'
        local id, reason = PoliceCitations.Insert('o', { citizenid='t', amount=10, reason='abc' })
        __say('id=' .. tostring(id))
        __say('reason=' .. tostring(reason))
    """)
    assert out["id"] == "nil"
    assert out["reason"] == "db_error"


# ── 付款抢占 ────────────────────────────────────────────────────


def test_claim_paid_reports_whether_the_row_was_taken():
    out = run("""
        __say('claimed=' .. tostring((PoliceCitations.ClaimPaid(5, 'cid'))))
        __say('reverted=' .. tostring((PoliceCitations.RevertPaid(5))))
        __say('sqls=' .. #__sql)
    """)
    assert out["claimed"] == "true"
    assert out["reverted"] == "true"
    assert int(out["sqls"]) == 2


def test_band_edges_are_exact_not_float_drifted():
    """0.8/1.2 在双精度里不精确：旧实现在 base=500 时给出 401/599 而不是 400/600。"""
    out = run("""
        for _, base in ipairs({500, 1000, 250, 33}) do
            local low = PoliceCitations.PolicyAmount(base, 1)
            local high = PoliceCitations.PolicyAmount(base, 999999)
            __say('b' .. base .. '=' .. tostring(low) .. '/' .. tostring(high))
        end
    """)
    assert out["b500"] == "400/600"
    assert out["b1000"] == "800/1200"
    assert out["b250"] == "200/300"
    assert out["b33"] == "27/39", "26.4 上取整 27、39.6 下取整 39"
