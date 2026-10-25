"""test_police_records.py — 案卷/逮捕/报告的唯一写者（真跑 Lua，桩只替换 MySQL）。

这三张表收口前的形状里藏着同一个 bug：`case_id`/`incident_id` 在参数数组**中间**，
调用方常常传 nil，于是数组出现空洞 → oxmysql 截断 → 参数少于占位符 → MariaDB 语法错 →
`InsertId()` 拿到错误字符串 → 调用方返回 db_error。真库探针实测（2026-10-25）确认：
旧形状 `ok=true` 但结果是错误字符串，所以"不带案卷建报告"这条路一直是坏的。

这里钉：列集合按需拼接、无参数洞、案号格式、justice_case_id 的字符串语义、判决字段更新。
"""

from __future__ import annotations

import shutil
import subprocess
import textwrap
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
SRC = BASE / "resources" / "[custom]" / "custom-police" / "server" / "records.lua"

STUBS = """
__inserts, __updates = {}, {}
__nextId = 900
__insertResult = nil
__updateResult = nil

MySQL = {}
MySQL.insert = { await = function(sql, values)
    __inserts[#__inserts + 1] = { sql = sql, values = values }
    if __insertResult ~= nil then return __insertResult end
    __nextId = __nextId + 1
    return __nextId
end }
MySQL.update = { await = function(sql, values)
    __updates[#__updates + 1] = { sql = sql, values = values }
    if __updateResult ~= nil then return __updateResult end
    return { affectedRows = 1 }
end }
function InsertId(value)
    if type(value) == 'number' then return value end
    if type(value) == 'table' then return tonumber(value.insertId) end
    return nil
end
function print(_) end
function __say(t) io.write(tostring(t) .. string.char(10)) end
function __noHoles(values)
    for i = 1, #values do if values[i] == nil then return false end end
    return true
end
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


# ── 报告 ────────────────────────────────────────────────────────


def test_report_without_case_or_incident_writes_no_holes():
    """旧 p1/p2 在这里必挂：case_id 是 nil 且位于数组中间。"""
    out = run("""
        local id = PoliceRecords.InsertReport('cid', { title = '报告标题', body = '正文' })
        __say('id=' .. tostring(id))
        __say('values=' .. #__inserts[1].values)
        __say('no_holes=' .. tostring(__noHoles(__inserts[1].values)))
        __say('case_in_sql=' .. tostring(__inserts[1].sql:find('case_id') ~= nil))
        __say('incident_in_sql=' .. tostring(__inserts[1].sql:find('incident_id') ~= nil))
    """)
    assert out["id"] != "nil"
    assert out["no_holes"] == "true"
    assert out["case_in_sql"] == "false", "没有 case_id 就不该出现这一列"
    assert out["incident_in_sql"] == "false"


def test_report_keeps_every_field_the_callers_pass():
    out = run("""
        PoliceRecords.InsertReport('cid', {
            title = '逮捕报告', body = '正文', kind = 'arrest', status = 'submitted',
            incident_id = 3, case_id = 4, subject_citizenid = 'sub', location = '巷道',
            charges = '[{"id":1}]', is_bolo = 1, bolo_kind = 'person', bolo_target = 'sub',
        })
        local sql = __inserts[1].sql
        __say('values=' .. #__inserts[1].values)
        __say('no_holes=' .. tostring(__noHoles(__inserts[1].values)))
        for _, col in ipairs({'kind','status','incident_id','case_id','subject_citizenid',
                              'location','charges','is_bolo','bolo_kind','bolo_target'}) do
            __say(col .. '=' .. tostring(sql:find(col, 1, true) ~= nil))
        end
    """)
    assert out["no_holes"] == "true"
    for col in ("kind", "status", "incident_id", "case_id", "subject_citizenid",
                "location", "charges", "is_bolo", "bolo_kind", "bolo_target"):
        assert out[col] == "true", f"{col} 没写进 SQL"


def test_report_requires_a_title():
    out = run("""
        __say('short=' .. tostring((PoliceRecords.InsertReport('cid', { title = 'ab' }))))
        __say('none=' .. tostring((PoliceRecords.InsertReport('cid', nil))))
        __say('inserts=' .. #__inserts)
    """)
    assert out["short"] == "nil"
    assert out["none"] == "nil"
    assert out["inserts"] == "0"


def test_report_db_error_string_is_a_failure():
    out = run("""
        __insertResult = 'You have an error in your SQL syntax'
        __say('id=' .. tostring((PoliceRecords.InsertReport('cid', { title = '标题' }))))
    """)
    assert out["id"] == "nil"


# ── 案卷 ────────────────────────────────────────────────────────


def test_case_gets_the_year_based_number():
    out = run("""
        local id, no = PoliceRecords.InsertCase('cid', { title = '案卷标题', summary = '摘要' })
        __say('id=' .. tostring(id))
        __say('no=' .. tostring(no))
        __say('update_sql=' .. tostring(__updates[1].sql))
    """)
    assert out["id"] != "nil"
    assert out["no"].startswith("CASE-"), out["no"]
    assert out["no"].endswith("000901"), out["no"]  # __nextId 900 + 1
    assert "SET case_no" in out["update_sql"]


def test_case_title_is_validated():
    out = run("""
        __say('short=' .. tostring((PoliceRecords.InsertCase('cid', { title = 'x' }))))
        __say('inserts=' .. #__inserts)
    """)
    assert out["short"] == "nil"
    assert out["inserts"] == "0"


# ── 逮捕 ────────────────────────────────────────────────────────


def test_arrest_without_case_or_incident():
    out = run("""
        local id = PoliceRecords.InsertArrest('officer-cid', { citizenid = 'target', charges = '持械抢劫' })
        __say('id=' .. tostring(id))
        __say('values=' .. #__inserts[1].values)
        __say('no_holes=' .. tostring(__noHoles(__inserts[1].values)))
        __say('case_in_sql=' .. tostring(__inserts[1].sql:find('case_id') ~= nil))
    """)
    assert out["id"] != "nil"
    assert out["no_holes"] == "true"
    assert out["case_in_sql"] == "false"


def test_arrest_with_case_and_incident_includes_both():
    out = run("""
        PoliceRecords.InsertArrest('officer', { citizenid = 't', charges = '罪名',
            incident_id = 2, case_id = 3 })
        __say('values=' .. #__inserts[1].values)
        __say('case=' .. tostring(__inserts[1].sql:find('case_id') ~= nil))
        __say('incident=' .. tostring(__inserts[1].sql:find('incident_id') ~= nil))
    """)
    assert int(out["values"]) == 5
    assert out["case"] == "true" and out["incident"] == "true"


def test_arrest_rejects_missing_charges():
    out = run("""
        __say('no_charges=' .. tostring((PoliceRecords.InsertArrest('o', { citizenid = 't' }))))
        __say('short=' .. tostring((PoliceRecords.InsertArrest('o', { citizenid = 't', charges = 'x' }))))
        __say('no_target=' .. tostring((PoliceRecords.InsertArrest('o', { charges = '罪名' }))))
    """)
    assert out["no_charges"] == "nil"
    assert out["short"] == "nil"
    assert out["no_target"] == "nil"


# ── 链接与判决 ──────────────────────────────────────────────────


def test_link_report_builds_only_the_requested_columns():
    out = run("""
        __say('case=' .. tostring(PoliceRecords.LinkReport(7, { case_id = 3 })))
        __say('sql1=' .. __updates[1].sql)
        __say('justice=' .. tostring(PoliceRecords.LinkReport(7, { justice_case_id = 'CASE-0001' })))
        __say('sql2=' .. __updates[2].sql)
        __say('both=' .. tostring(PoliceRecords.LinkReport(7, { case_id = 3, justice_case_id = 'CASE-0001' })))
        __say('sql3=' .. __updates[3].sql)
        __say('empty=' .. tostring(PoliceRecords.LinkReport(7, {})))
    """)
    assert out["case"] == "true"
    assert "SET case_id = ?" in out["sql1"] and "justice_case_id" not in out["sql1"]
    assert out["justice"] == "true"
    assert "justice_case_id = ?" in out["sql2"]
    assert "case_id = ?, justice_case_id = ?" in out["sql3"]
    assert out["empty"] == "false", "什么也没给就不该发 UPDATE"


def test_verdict_survives_a_string_justice_id():
    out = run("""
        local ok, affected = PoliceRecords.RecordVerdict('CASE-0001', '{"v":1}', 'closed')
        __say('ok=' .. tostring(ok))
        __say('affected=' .. tostring(affected))
        __say('id_arg=' .. tostring(__updates[1].values[3]))
    """)
    assert out["ok"] == "true"
    assert out["affected"] == "1"
    assert out["id_arg"] == "CASE-0001", "justice_case_id 是 VARCHAR，字符串要原样传"


def test_verdict_reports_write_failures():
    out = run("""
        __updateResult = 'boom'
        local ok, affected = PoliceRecords.RecordVerdict('CASE-0001', '{}', 'closed')
        __say('ok=' .. tostring(ok))
        __say('affected=' .. tostring(affected))
    """)
    assert out["ok"] == "false"
    assert out["affected"] == "0"
