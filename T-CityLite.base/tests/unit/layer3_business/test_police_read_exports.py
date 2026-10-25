"""FIT-04/FIT-05 — the MDT board reads are capability-gated and audited.

``GetUnits`` (citizenid + display name) and ``GetIncidents`` (description /
coordinates) are sensitive reads. Both must:

1. take the requesting officer's ``source`` (the phone query forwards it);
2. pass ``PolicePolicy.Can`` before touching the database;
3. write the audit row **before** the SELECT;
4. return ``false, 'audit_unavailable'`` when the audit write fails, so a DB
   hiccup never releases the rows unaudited (fail-closed).

Static assertions pin the source shape; the Lua harness drives the real
``p0.lua`` against a MySQL/QBCore stub and proves the ordering and the
fail-closed branch at runtime.

    python3 -m pytest -q tests/unit/layer3_business/test_police_read_exports.py
"""
from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]  # T-CityLite.base/
POLICE = BASE / "resources" / "[custom]" / "custom-police"
P0 = POLICE / "server/p0.lua"
POLICY = POLICE / "shared/policy.lua"
PHONE_MDT = BASE / "resources" / "[custom]" / "custom-phone/server/apps/police_mdt.lua"
LUA_BIN = shutil.which("lua5.4")


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def p0_block(start_marker: str, end_marker: str) -> str:
    source = read(P0)
    start = source.index(start_marker)
    end = source.index(end_marker, start)
    return source[start:end]


def test_get_units_requires_units_view_and_audits_before_the_query():
    block = p0_block("function P.GetUnits(", "function P.CreateIncident(")
    assert "function P.GetUnits(source)" in block
    assert "PolicePolicy.Can(actor, 'units.view')" in block
    assert "if not audit(actor.citizenid, 'units.view', nil, nil) then" in block
    assert "return false, 'audit_unavailable'" in block
    audit_at = block.index("audit(actor.citizenid")
    query_at = block.index("MySQL.query.await")
    assert audit_at < query_at, "GetUnits writes its audit row after the SELECT"


def test_get_incidents_requires_incident_update_and_audits_before_the_query():
    block = p0_block("function P.GetIncidents(", "function P.AssignUnit(")
    assert "function P.GetIncidents(source, status)" in block
    # There is no incident.view capability in shared/policy.lua; the live
    # incident board uses the existing incident.update gate.
    assert "PolicePolicy.Can(actor, 'incident.update')" in block
    assert "if not audit(actor.citizenid, 'incident.view', tostring(status or 'active'), nil) then" in block
    assert "return false, 'audit_unavailable'" in block
    audit_at = block.index("audit(actor.citizenid")
    query_at = block.index("MySQL.query.await")
    assert audit_at < query_at, "GetIncidents writes its audit row after the SELECT"


def test_phone_forwards_the_caller_source_to_both_board_reads():
    source = read(PHONE_MDT)
    assert "exports['custom-police']:GetUnits(source)" in source
    assert "exports['custom-police']:GetIncidents(source, params and params.status)" in source


HARNESS = r"""
-- Generated FIT-04 harness: load the real shared policy + p0 dispatch layer
-- against a QBCore/MySQL stub, then prove the sensitive reads fail closed.
local registry = {}
local audits = {}
local events = {}
local auditFails = false

local QBCore = { Functions = {} }
local players = {
    [1] = {
        PlayerData = {
            source = 1,
            citizenid = 'CID1',
            charinfo = { firstname = 'Alice', lastname = 'Smith' },
            job = { name = 'police', onduty = true, grade = { level = 2 } },
            metadata = {},
        },
    },
}
function QBCore.Functions.GetPlayer(src) return players[tonumber(src) or 0] end
function QBCore.Functions.GetPlayerByCitizenId(cid)
    for _, p in pairs(players) do
        if p.PlayerData.citizenid == cid then return p end
    end
end
function QBCore.Functions.GetPlayers()
    local list = {}
    for src in pairs(players) do list[#list + 1] = src end
    table.sort(list)
    return list
end

exports = setmetatable({}, {
    __call = function(_, name, fn) registry[name] = fn end,
    __index = function()
        return setmetatable({}, {
            __index = function() return function() return QBCore end end,
        })
    end,
})

MySQL = {
    insert = {
        await = function(sql, params)
            if sql:find('police_audit', 1, true) then
                audits[#audits + 1] = { sql = sql, params = params }
                events[#events + 1] = 'audit'
                if auditFails then error('audit db down') end
            else
                events[#events + 1] = 'insert'
            end
            return 1
        end,
    },
    query = {
        await = function(sql, params)
            if sql:find('INSERT INTO police_audit', 1, true) then
                audits[#audits + 1] = { sql = sql, params = params }
                events[#events + 1] = 'audit'
                if auditFails then error('audit db down') end
                return 1
            end
            events[#events + 1] = 'query'
            if sql:find('police_units', 1, true) then
                return { { citizenid = 'CID1', callsign = '1A', dept = 'PATROL',
                           status = 'available', incident_id = 7 } }
            elseif sql:find('police_incidents', 1, true) then
                return { { id = 7, code = '911', title = 'Robbery', description = 'Store',
                           priority = 1, status = 'open', disposition = nil,
                           npc_template = nil, x = 1, y = 2, z = 3,
                           created_at = '2026-01-01' } }
            end
            return {}
        end,
    },
    single = { await = function() return nil end },
    update = { await = function() return { affectedRows = 1 } end },
}
function InsertId() return 1 end
function AddEventHandler() end
function RegisterNetEvent() end
function CreateThread() end
function Wait() end
function GetCurrentResourceName() return 'custom-police' end
function TriggerClientEvent() end

dofile(__POLICY__)
dofile(__AUDIT__)   -- 审计唯一写者（p0 的 audit() 包装委派给它）
dofile(__P0__)

local function expect(condition, message)
    if not condition then error(message, 2) end
end

local function reset()
    audits = {}
    events = {}
end

-- GetUnits: audit failure refuses the read before any query.
auditFails = true
reset()
local ok, err = registry.GetUnits(1)
expect(ok == false and err == 'audit_unavailable', 'GetUnits must fail closed on audit failure')
expect(#events == 1 and events[1] == 'audit', 'GetUnits queried after a failed audit')
expect(#audits == 1 and audits[1].params[3] == 'units.view', 'GetUnits audit action')

-- GetUnits success: audit first, then query, PII mapping intact.
auditFails = false
reset()
local units = registry.GetUnits(1)
expect(type(units) == 'table' and units.count == 1, 'GetUnits success shape')
expect(units.units[1].citizenid == 'CID1', 'unit citizenid missing')
expect(units.units[1].name == 'Alice Smith', 'unit display name missing')
expect(#events == 2 and events[1] == 'audit' and events[2] == 'query',
    'GetUnits must audit before the SELECT')

-- Non-officer and off-duty callers never reach the audit/query.
reset()
ok, err = registry.GetUnits(99)
expect(ok == false and err == 'not_police', 'GetUnits non-officer')
expect(#events == 0, 'GetUnits non-officer audited or queried')

-- GetIncidents: audit failure refuses the read before any query.
auditFails = true
reset()
ok, err = registry.GetIncidents(1)
expect(ok == false and err == 'audit_unavailable', 'GetIncidents must fail closed on audit failure')
expect(#events == 1 and events[1] == 'audit', 'GetIncidents queried after a failed audit')
expect(#audits == 1 and audits[1].params[3] == 'incident.view', 'GetIncidents audit action')

-- GetIncidents success: audit first, then query.
auditFails = false
reset()
local incidents = registry.GetIncidents(1, nil)
expect(type(incidents) == 'table' and incidents.count == 1, 'GetIncidents success shape')
expect(incidents.incidents[1].id == 7, 'incident id missing')
expect(#events == 2 and events[1] == 'audit' and events[2] == 'query',
    'GetIncidents must audit before the SELECT')

-- Invalid status is a stable error and never queries.
reset()
ok, err = registry.GetIncidents(1, 'closed')
expect(ok == false and err == 'invalid_status', 'GetIncidents invalid status code')
expect(#events == 0, 'GetIncidents invalid status audited or queried')

-- Off-duty officers are rejected by the capability table.
players[1].PlayerData.job.onduty = false
reset()
ok, err = registry.GetUnits(1)
expect(ok == false and err == 'not_on_duty', 'GetUnits off-duty')
ok, err = registry.GetIncidents(1)
expect(ok == false and err == 'not_on_duty', 'GetIncidents off-duty')
expect(#events == 0, 'off-duty reads audited or queried')

print('police read export harness ok')
"""


@pytest.mark.skipif(LUA_BIN is None, reason="lua5.4 is not installed")
def test_board_reads_fail_closed_under_lua(tmp_path: Path) -> None:
    script = HARNESS.replace("__AUDIT__", json.dumps(str(P0.parent / "audit.lua"))).replace(
        "__POLICY__", json.dumps(str(POLICY))).replace(
        "__P0__", json.dumps(str(P0))
    )
    harness = tmp_path / "police_read_export_harness.lua"
    harness.write_text(script, encoding="utf-8")
    result = subprocess.run(
        [LUA_BIN, str(harness)],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, f"{result.stdout}\n{result.stderr}"
    assert "police read export harness ok" in result.stdout
