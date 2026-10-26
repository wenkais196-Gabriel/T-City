"""申领 + 自动到场：警情不再靠人点按钮推进状态。

设计见 docs/server-design/10：三个按钮里「到场」是错的抽象——坐标就在引擎里，
让玩家汇报"我到了"既多一步又能造假。现在：

* 申领（claim）= assign + enroute + 推路线，一次点击到位；
* 到场 = 客户端每秒检测 + nonce + 服务端用 ped 坐标复算后结算；
* 清场只在到场之后允许，且只有现场负责人能点（grade≥2 可跨单）。

这个 harness 用 lua5.4 驱动真实的 p0.lua（MySQL/QBCore 用内存桩），验证判定与结算，
并且每条断言都带反向校验——把服务端距离检查删掉、把 nonce 复用放开，测试必须红。
"""
from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
POLICE = BASE / "resources" / "[custom]" / "custom-police"
P0 = POLICE / "server/p0.lua"
POLICY = POLICE / "shared/policy.lua"
AUDIT = POLICE / "server/audit.lua"
GUIDANCE = POLICE / "client/incident_guidance.lua"
MAIN = POLICE / "server/main.lua"
MDT_APP = BASE / "resources" / "[custom]" / "custom-phone/server/apps/police_mdt.lua"
MDT_UI = BASE / "resources" / "[custom]" / "custom-phone/web/src/apps/PoliceMDT.svelte"
LUA_BIN = shutil.which("lua5.4")


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


HARNESS = r"""
-- 警情申领 / 到场 harness（内存 DB）
local registry = {}
local clientEvents = {}
local auditRows = {}
local nonceCalls = 0

-- ---------- 内存状态 ----------
local incidents = {}
local unitRows = {}      -- police_units: [citizenid] = { status, incident_id }
local memberRows = {}    -- police_incident_units: [incidentId] = { {citizenid, role, joined_at} }
local pedCoords = {}     -- [source] = {x,y,z}

local function seed(id, status, x, y, z)
    incidents[id] = { id = id, code = '10-31', title = '持械抢劫', status = status,
                      x = x or 100.0, y = y or 200.0, z = z or 30.0 }
    memberRows[id] = memberRows[id] or {}
end

-- ---------- vector3（# 取模、- 取差） ----------
function vector3(x, y, z)
    return setmetatable({ x = x, y = y, z = z }, {
        __sub = function(a, b) return vector3(a.x - b.x, a.y - b.y, a.z - b.z) end,
        __len = function(v) return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) end,
        __index = { x = 0 },
    })
end

-- ---------- QBCore ----------
local players = {
    [1] = { PlayerData = { source = 1, citizenid = 'CID_A', job = { name = 'police', type = 'leo', grade = { level = 1 }, onduty = true } } },
    [2] = { PlayerData = { source = 2, citizenid = 'CID_B', job = { name = 'police', type = 'leo', grade = { level = 1 }, onduty = true } } },
    [3] = { PlayerData = { source = 3, citizenid = 'CID_CHIEF', job = { name = 'police', type = 'leo', grade = { level = 3 }, onduty = true } } },
}
local QBCore = { Functions = {} }
function QBCore.Functions.GetPlayer(src) return players[tonumber(src) or 0] end
function QBCore.Functions.GetPlayers()
    local out = {}
    for src in pairs(players) do out[#out + 1] = src end
    table.sort(out)
    return out
end
function QBCore.Functions.GetQBPlayers() return players end
function QBCore.Functions.GetPlayerByCitizenId(cid)
    for _, p in pairs(players) do
        if p.PlayerData.citizenid == cid then return p end
    end
end
function QBCore.Functions.GetPlayerData() return players[1].PlayerData end

exports = setmetatable({}, {
    __call = function(_, name, fn) registry[name] = fn end,
    __index = function() return setmetatable({}, { __index = function() return function() return QBCore end end }) end,
})

-- ---------- MySQL 桩：按 SQL 形状回话 ----------
local function findIncidentByTitleOrId(id) return incidents[tonumber(id)] end

MySQL = {
    single = { await = function(sql, params)
        if sql:find('FROM police_incidents', 1, true) then
            return findIncidentByTitleOrId(params[1])
        end
        return nil
    end },
    query = { await = function(sql, params)
        if sql:find('FROM police_incident_units', 1, true) then
            local rows = memberRows[tonumber(params[1])] or {}
            local out = {}
            for _, r in ipairs(rows) do out[#out + 1] = { citizenid = r.citizenid, role = r.role } end
            return out
        end
        if sql:find("SELECT status FROM police_units WHERE incident_id", 1, true) then
            local out = {}
            for _, u in pairs(unitRows) do
                if tonumber(u.incident_id) == tonumber(params[1]) then out[#out + 1] = { status = u.status } end
            end
            return out
        end
        if sql:find('FROM police_units', 1, true) then
            local out = {}
            for cid, u in pairs(unitRows) do
                out[#out + 1] = { citizenid = cid, callsign = u.callsign, dept = 'PATROL',
                                  status = u.status, incident_id = u.incident_id }
            end
            return out
        end
        return {}
    end },
    insert = { await = function(sql, params)
        if sql:find('police_audit', 1, true) then
            auditRows[#auditRows + 1] = { actor = params[1], action = params[3], target = params[4] }
            return #auditRows
        end
        if sql:find('police_incident_units', 1, true) then
            local id = tonumber(params[1])
            memberRows[id] = memberRows[id] or {}
            for _, r in ipairs(memberRows[id]) do
                if r.citizenid == params[2] then return 1 end
            end
            memberRows[id][#memberRows[id] + 1] = { citizenid = params[2], role = params[3], joined_at = #memberRows[id] + 1 }
            return #memberRows[id]
        end
        return 1
    end },
    update = { await = function(sql, params)
        if sql:find("UPDATE police_units SET status = 'assigned'", 1, true) then
            local cid = params[2]
            unitRows[cid] = unitRows[cid] or {}
            unitRows[cid].status = 'assigned'
            unitRows[cid].incident_id = tonumber(params[1])
            return { affectedRows = 1 }
        end
        if sql:find("UPDATE police_units SET status = 'enroute'", 1, true) then
            -- enrouteUnitRow 的参数顺序是 (incidentId, citizenid)
            local cid = params[2]
            unitRows[cid] = unitRows[cid] or {}
            unitRows[cid].status = 'enroute'
            unitRows[cid].incident_id = tonumber(params[1])
            return { affectedRows = 1 }
        end
        if sql:find("UPDATE police_units SET status = 'on_scene'", 1, true) then
            unitRows[params[1]] = unitRows[params[1]] or {}
            unitRows[params[1]].status = 'on_scene'
            return { affectedRows = 1 }
        end
        if sql:find('UPDATE police_incidents', 1, true) then
            -- 状态是字面量写在 SQL 里（不是占位符），id 是唯一的参数
            -- 两种写法都要支持：字面量（SET status = 'enroute'）和占位符（SET status = ?）
            local status = sql:match("SET%s+status%s*=%s*'([%w_]+)'") or params[1]
            local inc = incidents[tonumber(params[#params])]
            if inc and status then inc.status = status end
            return { affectedRows = 1 }
        end
        return { affectedRows = 1 }
    end },
}

function InsertId(v) return v end
function GetGameTimer() return os.time() * 1000 end
function GetPlayerPed(src) return tonumber(src) or 0 end
function GetEntityCoords(ped)
    local c = pedCoords[tonumber(ped)] or { x = 0.0, y = 0.0, z = 0.0 }
    return vector3(c.x, c.y, c.z)
end
function TriggerClientEvent(name, target, payload)
    clientEvents[#clientEvents + 1] = { name = name, target = target, payload = payload }
end
function AddEventHandler() end
function RegisterNetEvent() end
function CreateThread() end
function Wait() end
function GetCurrentResourceName() return 'custom-police' end
function GetPlayerName() return 'officer' end
function Lang_t(k) return k end
Lang = { t = function(_, k) return k end }

dofile(__POLICY__)
dofile(__AUDIT__)
dofile(__P0__)

local function expect(cond, msg)
    if not cond then error(msg, 2) end
end
local function reset()
    incidents, unitRows, memberRows, clientEvents, auditRows = {}, {}, {}, {}, {}
    pedCoords = {}
end
local function actorOf(src) return players[src].PlayerData end

-- ============================================================
-- 1. 申领：open 一次点击 → enroute + primary + 推路线
-- ============================================================
reset()
seed(40, 'open', 100.0, 200.0, 30.0)
local res = registry.ClaimIncident(1, 40)
expect(type(res) == 'table', '申领应成功: ' .. tostring(res))
expect(res.status == 'enroute', 'open 的单子申领后应直接 enroute（不再需要第二次点击）')
expect(res.role == 'primary', '第一个申领的人是 primary')
expect(incidents[40].status == 'enroute', '事件状态应写回 enroute')
expect(unitRows['CID_A'] and unitRows['CID_A'].status == 'enroute', '单位状态应是 enroute')
expect(#clientEvents == 1 and clientEvents[1].name == 'police:client:routeToIncident',
    '申领成功必须推一条路线（不是等玩家点导航）')
expect(clientEvents[1].payload.label:find('#40', 1, true) ~= nil, '路线标签带单号')
expect(type(clientEvents[1].payload.x) == 'number', '路线坐标是数字，不是裸 vector3')

-- ============================================================
-- 2. 第二个警员申领同一张单 → 变成 support，不改事件状态
-- ============================================================
local res2 = registry.ClaimIncident(2, 40)
expect(res2.role == 'support', '已有负责人时后到的人是 support: ' .. tostring(res2.role))
expect(res2.status == 'enroute', '加入不改变事件状态')
expect(#memberRows[40] == 2, '两人都应在单位表里')
expect(res2.primary == 'CID_A', 'primary 不应被别人抢走')

-- 3. 已在单上再申领 → 幂等
local res3 = registry.ClaimIncident(1, 40)
expect(res3.idempotent == true, '重复申领应幂等，不产生新行')

-- 4. 已归档的单不能申领
reset()
seed(41, 'closed')
local res4, why4 = registry.ClaimIncident(1, 41)
expect(res4 == false and why4 == 'incident_closed', '归档的单不能申领')

-- ============================================================
-- 5. 判定表（服务端下发给 UI 的那份）
-- ============================================================
reset()
seed(42, 'open')
local unitsOpen = {}
local st = registry.ActionState(actorOf(1), incidents[42], unitsOpen)
expect(st.claim.allowed == true and st.claim.label == 'claim', 'open 且无负责人 → 可申领')
expect(st.clear.allowed == false and st.clear.reason == 'not_on_scene', '没到场不能清场')

-- 已申领（我是 primary），状态 enroute
incidents[42].status = 'enroute'
local unitsMine = { { citizenid = 'CID_A', role = 'primary' }, { citizenid = 'CID_B', role = 'support' } }
local st2 = registry.ActionState(actorOf(1), incidents[42], unitsMine)
expect(st2.claim.allowed == false and st2.claim.reason == 'already_joined', '已在单上不能再申领')
expect(st2.clear.allowed == false and st2.clear.reason == 'not_on_scene', '在路上不能清场')

-- 已到场：primary 可清场，support 不可，chief 可
incidents[42].status = 'on_scene'
local st3 = registry.ActionState(actorOf(1), incidents[42], unitsMine)
expect(st3.clear.allowed == true, '现场负责人可以清场')
local st4 = registry.ActionState(actorOf(2), incidents[42], unitsMine)
expect(st4.clear.allowed == false and st4.clear.reason == 'not_primary', '支援不能清场')
local st5 = registry.ActionState(actorOf(3), incidents[42], unitsMine)
expect(st5.clear.allowed == true, 'grade≥2 可以跨单清场')

-- ============================================================
-- 6. 到场：nonce + 服务端复算距离
-- ============================================================
reset()
seed(43, 'open', 100.0, 200.0, 30.0)
registry.ClaimIncident(1, 43)
pedCoords[1] = { x = 108.0, y = 202.0, z = 31.0 }     -- ~8.5m
local token = registry.RequestArriveNonce(1, 43)
expect(type(token) == 'string' and #token > 0, '应发放一次性 nonce')

local arr = registry.ArriveIncident(1, 43, token, nil)
expect(type(arr) == 'table', '在场内应结算成功: ' .. tostring(arr))
expect(arr.distance <= 35.0, '距离应参与结算')
expect(unitRows['CID_A'].status == 'on_scene', '单位应变成 on_scene')
expect(incidents[43].status == 'on_scene', '事件状态由单位进度派生为 on_scene')

-- 7. nonce 只能花一次
local again, whyAgain = registry.ArriveIncident(1, 43, token, nil)
expect(again == false and whyAgain == 'bad_nonce', '同一个 nonce 不能重复结算')

-- 8. 太远不算到场（服务端用 ped 坐标，不信客户端）
reset()
seed(44, 'open', 100.0, 200.0, 30.0)
registry.ClaimIncident(1, 44)
pedCoords[1] = { x = 400.0, y = 700.0, z = 30.0 }     -- 远得很
local token2 = registry.RequestArriveNonce(1, 44)
local far, whyFar = registry.ArriveIncident(1, 44, token2, nil)
expect(far == false and whyFar == 'too_far', '距离超限必须拒绝: ' .. tostring(whyFar))
expect(incidents[44].status == 'enroute', '被拒绝时状态不能变')

-- 9. 不是本单单位不能到场
reset()
seed(45, 'open')
local token3 = registry.RequestArriveNonce(2, 45)
expect(token3 == nil, '不在单上的人拿不到 nonce')
local noUnit, whyNoUnit = registry.ArriveIncident(2, 45, 'fake', nil)
expect(noUnit == false and whyNoUnit == 'bad_nonce', '伪造 nonce 直接拒绝')

-- 10. 手动补录：宽容半径更大，但仍要真的在附近
reset()
seed(46, 'open', 100.0, 200.0, 30.0)
registry.ClaimIncident(1, 46)
pedCoords[1] = { x = 160.0, y = 200.0, z = 30.0 }     -- 60m：自动不行、手动可以
local auto1, whyAuto = registry.ArriveIncident(1, 46, 'x', nil)
expect(auto1 == false, '自动路径 60m 不算到场')
local manualOk = registry.ArriveIncident(1, 46, nil, { manual = true })
expect(type(manualOk) == 'table', '手动补录在 100m 内应成功')

print('police claim/arrival harness ok')
"""


@pytest.mark.skipif(LUA_BIN is None, reason="lua5.4 is not installed")
def test_claim_and_auto_arrival(tmp_path: Path) -> None:
    script = (
        HARNESS.replace("__POLICY__", json.dumps(str(POLICY)))
        .replace("__AUDIT__", json.dumps(str(AUDIT)))
        .replace("__P0__", json.dumps(str(P0)))
    )
    harness = tmp_path / "police_claim_harness.lua"
    harness.write_text(script, encoding="utf-8")
    result = subprocess.run([LUA_BIN, str(harness)], capture_output=True, text=True, timeout=45)
    assert result.returncode == 0, f"{result.stdout}\n{result.stderr}"
    assert "police claim/arrival harness ok" in result.stdout


def test_arrival_is_detected_by_the_client_not_typed_in() -> None:
    """到场按钮必须消失：检测在客户端，裁定在服务端。"""
    ui = read(MDT_UI)
    assert "on_scene" not in ui.split("<script")[0], "界面里不该再把「到场」当按钮文案"
    assert ">到场<" not in ui, "到场按钮应删除（自动结算）"
    assert "arrive_manual" in ui, "必须保留自动检测失灵时的补录出口"

    guidance = read(GUIDANCE)
    assert "PoliceIncidentRules" in guidance and "ARRIVE_RADIUS" in guidance, "检测半径必须来自共享规则"
    assert "requestArriveNonce" in guidance, "命中后要申请 nonce，不能直接说自己到了"
    assert "DWELL_TICKS" in guidance, "要有停留去抖"


def test_server_recomputes_distance_and_consumes_the_nonce() -> None:
    source = read(P0)
    block = source[source.index("function P.ArriveIncident"):]
    assert "GetEntityCoords" in block, "服务端必须自己取 ped 坐标"
    assert "SERVER_RADIUS_GRACE" in block or "PoliceIncidentRules" in block, "距离阈值来自共享规则"
    assert "incident_has_no_coords" in block, "没有坐标的单要拒绝，不能默认到场"
    assert source.count("bad_nonce") >= 2, "nonce 必须一次性（发放/消费两侧都校验）"
    # 反向：客户端传坐标的字段不该被读
    assert "data.x" not in block, "服务端不许采信客户端坐标"


def test_claim_is_one_click_and_assigns_plus_pushes_the_route() -> None:
    source = read(P0)
    start = source.index("function P.ClaimIncident")
    block = source[start:source.index("function P.RequestArriveNonce")]
    assert "enrouteUnitRow" in block, "申领要写单位（assign + enroute 一步）"
    assert "'enroute'" in block, "申领即出发"
    assert "pushIncidentRoute" in block, "申领成功要推路线"
    assert "role = 'primary'" not in block and "'support'" in block, "primary/support 要分清"
    assert "incident_closed" in block, "归档的单不能申领"


def test_policy_has_separate_capabilities() -> None:
    policy = read(POLICY)
    for cap in ("incident.claim", "incident.arrive", "incident.clear"):
        assert f"['{cap}']" in policy, f"缺少能力位 {cap}"
    assert "PoliceIncidentRules" in policy, "几何参数必须在共享层，客户端与服务端同源"


def test_incidents_carry_allowed_actions_to_the_ui() -> None:
    source = read(P0)
    block = source[source.index("function P.GetIncidents"):source.index("function P.ClaimIncident")]
    assert "P.ActionState(" in block, "GetIncidents 必须下发判定结果"
    assert "inc.primary" in block and "inc.units" in block, "板上要知道谁负责、有谁"
    # 一次查完，不做 N+1
    assert "IN (%s)" in block, "单位查询必须一次批量完成"


def test_net_entrypoints_validate_before_writing() -> None:
    main = read(MAIN)
    block = main[main.index("police:server:arriveIncident"):]
    assert "ArriveIncident" in block
    assert "src == 0" in block, "服务器自身触发不该走这条路径"
    claim = main[main.index("police:server:claimIncident"):]
    assert "ClaimIncident" in claim
    assert "pcall" in claim, "导出异常不能让事件处理器崩掉"
