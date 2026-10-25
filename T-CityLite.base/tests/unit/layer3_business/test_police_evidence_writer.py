"""test_police_evidence_writer.py — 证据唯一写者（真跑 Lua，桩只替换 MySQL）。

这段代码在收口前是**整条坏掉的**，而且很难看出来：

    INSERT INTO police_evidence (exhibit_no, incident_id, ...) VALUES (?, ?, ...)
    { nil, incidentId, reportId, ... }        -- 参数数组第一个就是洞

oxmysql 在洞处截断参数列表 → 发出的参数少于占位符 → MariaDB 报
"You have an error in your SQL syntax ... near '?)'" → `InsertId()` 拿到错误字符串 →
返回 'db_error'。**每一次证据登记都失败**，而服务端日志里只有业务层的一句"登记失败"。
真库探针实测（2026-10-25）确认：旧形状 ok=true/结果是错误字符串，新形状正常插入。

所以这里钉：列集合按需拼接、无参数洞、链记录的 note 为 nil 时不留洞、校验与拒绝原因。
"""

from __future__ import annotations

import shutil
import subprocess
import textwrap
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
SRC = BASE / "resources" / "[custom]" / "custom-police" / "server" / "p2_evidence.lua"

STUBS = """
__sql, __params, __chains, __audits = {}, {}, {}, {}
__nextId = 500
__caseExists, __incidentExists = true, true
__insertResult = nil

MySQL = {}
MySQL.insert = { await = function(sql, values)
    if sql:find('police_evidence_chain', 1, true) then
        __chains[#__chains + 1] = { sql = sql, values = values }
        return 1
    end
    if not sql:find('INSERT INTO police_evidence ', 1, true) then return 1 end
    __sql[#__sql + 1] = sql
    __params[#__params + 1] = values
    if __insertResult ~= nil then return __insertResult end
    __nextId = __nextId + 1
    return __nextId
end }
__updates = {}
MySQL.update = { await = function(sql, values)
    __updates[#__updates + 1] = { sql = sql, values = values }
    return { affectedRows = 1 }
end }
MySQL.single = { await = function(sql, _values)
    if sql:find('police_cases', 1, true) then return __caseExists and { id = 1 } or nil end
    if sql:find('police_incidents', 1, true) then return __incidentExists and { id = 1 } or nil end
    return nil
end }
MySQL.query = { await = function() return {} end }
MySQL.scalar = { await = function() return 0 end }

function InsertId(value)
    if type(value) == 'number' then return value end
    if type(value) == 'table' then return tonumber(value.insertId) end
    return nil
end
PoliceAudit = { Write = function(_, action, target, detail)
    __audits[#__audits + 1] = { action = action, target = target, detail = detail }
    return true
end }
PolicePolicy = { Can = function() return true end }
QBCore = { Functions = { GetPlayer = function(src)
    if tonumber(src) == 1 then
        return { PlayerData = { citizenid = 'cid1', source = 1,
            job = { name = 'police', onduty = true, grade = { level = 3 } }, metadata = {} } }
    end
    return nil
end } }
__exported = {}
exports = setmetatable({}, {
    __call = function(_, name, fn) __exported[name] = fn end,   -- exports('Name', fn)
    __index = function() return setmetatable({}, { __index = function() return function() return QBCore end end }) end,
})
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


def test_register_with_only_a_label_and_one_parent():
    """旧实现在这里必定 db_error（第一个参数是 nil）。"""
    out = run("""
        local row = PoliceEvidenceWriter.Register('probe-cid', { label = '弹壳', incident_id = 7 })
        __say('ok=' .. tostring(row ~= nil))
        __say('exhibit=' .. tostring(row and row.exhibit_no))
        __say('params=' .. #__params[1])
        local no_holes = true
        for i = 1, #__params[1] do if __params[1][i] == nil then no_holes = false end end
        __say('no_holes=' .. tostring(no_holes))
    """)
    assert out["ok"] == "true"
    assert out["exhibit"].startswith("EX-"), "展品号由自增 id 推导"
    assert out["no_holes"] == "true", "参数数组里不能有洞"


def test_optional_fields_are_only_included_when_present():
    out = run("""
        PoliceEvidenceWriter.Register('cid', { label = '弹壳', incident_id = 7 })
        local sql = __sql[1]
        __say('desc_in_sql=' .. tostring(sql:find('description') ~= nil))
        __say('location_in_sql=' .. tostring(sql:find('location') ~= nil))
        PoliceEvidenceWriter.Register('cid', {
            label = '刀', report_id = 3, description = '带血', location = '巷道' })
        local sql2 = __sql[2]
        __say('desc2=' .. tostring(sql2:find('description') ~= nil))
        __say('loc2=' .. tostring(sql2:find('location') ~= nil))
        __say('incident2=' .. tostring(sql2:find('incident_id') ~= nil))
    """)
    assert out["desc_in_sql"] == "false", "没给 description 就不该出现在列里"
    assert out["location_in_sql"] == "false"
    assert out["desc2"] == "true" and out["loc2"] == "true"
    assert out["incident2"] == "false"
    assert out["desc2"] == "true"


def test_chain_entry_without_a_note_does_not_leave_a_hole():
    out = run("""
        local ok = PoliceEvidenceWriter.Chain(9, 'audited', 'cid', nil)
        __say('ok=' .. tostring(ok))
        __say('values=' .. #__chains[1].values)
        __say('sql=' .. __chains[1].sql)
    """)
    assert out["ok"] == "true"
    assert out["values"] == "3", "note 为 nil 时只传三个参数"
    assert "NULL)" in out["sql"], "note 必须写成 SQL 里的 NULL"


def test_register_writes_the_first_chain_entry():
    out = run("""
        local row = PoliceEvidenceWriter.Register('cid', { label = '弹壳', incident_id = 7 })
        __say('chains=' .. #__chains)
        __say('action=' .. tostring(__chains[1] and __chains[1].values[2]))
        __say('chain_ok=' .. tostring(row and row.chain_ok))
    """)
    assert out["chains"] == "1"
    assert out["action"] == "collected"
    assert out["chain_ok"] == "true"


def test_validation_reasons():
    out = run("""
        local _, r1 = PoliceEvidenceWriter.Register('cid', { label = 'x', incident_id = 7 })
        local _, r2 = PoliceEvidenceWriter.Register('cid', { label = '弹壳' })
        __caseExists = false
        local _, r3 = PoliceEvidenceWriter.Register('cid', { label = '弹壳', case_id = 5 })
        __incidentExists = false
        local _, r4 = PoliceEvidenceWriter.Register('cid', { label = '弹壳', incident_id = 9 })
        local _, r5 = PoliceEvidenceWriter.Register('cid', nil)
        __say('short=' .. tostring(r1))
        __say('no_parent=' .. tostring(r2))
        __say('no_case=' .. tostring(r3))
        __say('no_incident=' .. tostring(r4))
        __say('not_table=' .. tostring(r5))
    """)
    assert out["short"] == "invalid_label"
    assert out["no_parent"] == "missing_case"
    assert out["no_case"] == "case_not_found"
    assert out["no_incident"] == "incident_not_found"
    assert out["not_table"] == "invalid_params"


def test_export_register_audits_and_reports_the_exhibit():
    out = run("""
        local result = EV.Register(1, { label = '弹壳', incident_id = 7 })
        __say('ok=' .. tostring(result ~= nil))
        __say('audits=' .. #__audits)
        __say('action=' .. tostring(__audits[1] and __audits[1].action))
        __say('target=' .. tostring(__audits[1] and __audits[1].target))
    """)
    assert out["ok"] == "true", "有玩家 + 有权限时应当登记成功"
    assert out["audits"] == "1", "登记成功才记一条审计"
    assert out["action"] == "evidence.register"
    assert out["target"].startswith("EX-"), "审计的 target 是展品号"
