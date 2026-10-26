"""警情来源统一 + 去重：报警必须落成 police_incidents 的一行。

现场问题：玩家被抢后报警，警察手机响、地图插旗，但 MDT 警情板是空的——
``police:server:policeAlert`` 只发通知，从不建单。于是"报警"在系统里等于没发生：
不能派单、不能清场、不留记录、进不了统计。

同一个改动还要解决两件事：

1. 通知标题必须带单号（``#38 911: ...``），否则手机上的"有人报警"和板上哪一行
   对不上；
2. 同码、同地、5 分钟内的重复报警并进同一单，否则一次抢劫被五个人报警就是五条单，
   警员分不清哪条是真事件。

这里用 lua5.4 驱动真实的 p0.lua（MySQL/QBCore 桩），验证插入、合并、通知三件事。
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
MAIN = POLICE / "server/main.lua"
PHONE_EMERGENCY = BASE / "resources" / "[custom]" / "custom-phone/server/emergency.lua"
LUA_BIN = shutil.which("lua5.4")


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


HARNESS = r"""
-- 警情建单 / 合并 / 通知 harness
local registry = {}
local inserts, updates, notifies, queries = {}, {}, {}, {}
local mergeRow = nil          -- 合并查询返回什么
local nextId = 41

local players = {
    [1] = { PlayerData = { source = 1, citizenid = 'CID_CIV',
        charinfo = { firstname = 'Bob', lastname = 'Civil' },
        job = { name = 'unemployed', onduty = false }, metadata = {} } },
    [2] = { PlayerData = { source = 2, citizenid = 'CID_COP',
        charinfo = { firstname = 'Alice', lastname = 'Cop' },
        job = { name = 'police', type = 'leo', onduty = true }, metadata = {} } },
}

local QBCore = { Functions = {} }
function QBCore.Functions.GetPlayer(src) return players[tonumber(src) or 0] end
function QBCore.Functions.GetPlayers()
    local list = {}
    for src in pairs(players) do list[#list + 1] = src end
    table.sort(list)
    return list
end
function QBCore.Functions.GetQBPlayers() return players end
function QBCore.Functions.GetPlayerByCitizenId(cid)
    for _, p in pairs(players) do
        if p.PlayerData.citizenid == cid then return p end
    end
end
function QBCore.Functions.GetDutyCount() return 1 end

exports = setmetatable({}, {
    __call = function(_, name, fn) registry[name] = fn end,
    __index = function()
        return setmetatable({}, { __index = function() return function() return QBCore end end })
    end,
})

MySQL = {
    insert = { await = function(sql, params)
        if sql:find('police_audit', 1, true) then return 1 end
        inserts[#inserts + 1] = { sql = sql, params = params }
        return nextId
    end },
    query = { await = function(sql, params)
        queries[#queries + 1] = { sql = sql, params = params }
        if sql:find('police_incidents', 1, true) and sql:find('SQRT', 1, true) then
            return mergeRow and { mergeRow } or {}
        end
        return {}
    end },
    update = { await = function(sql, params)
        updates[#updates + 1] = { sql = sql, params = params }
        return { affectedRows = 1 }
    end },
}

Outbox = { Enqueue = function(kind, payload)
    notifies[#notifies + 1] = payload
    return true
end }

function InsertId(v) return v end
function AddEventHandler() end
function RegisterNetEvent() end
function CreateThread() end
function Wait() end
function GetCurrentResourceName() return 'custom-police' end
function TriggerClientEvent() end
function GetPlayerName() return 'Bob Civil' end
function Lang_t(key) return key end
Lang = { t = function(_, key) return key end }

dofile(__POLICY__)
dofile(__AUDIT__)
dofile(__P0__)

local function expect(cond, msg)
    if not cond then error(msg, 2) end
end

local function reset()
    inserts, updates, notifies, queries = {}, {}, {}, {}
    mergeRow = nil
end

-- 1. 报警建单：插入一行，并且通知在勤警察，标题带单号
reset()
local result = registry.CreateIncident(1, {
    code = '911', title = '有人持枪抢店', description = '好麦坞大道', priority = 2,
    x = 100.0, y = 200.0, z = 30.0,
})
expect(type(result) == 'table' and result.id == nextId, 'CreateIncident 应返回新建的 id')
expect(#inserts == 1, '应当插入一行 police_incidents')
expect(#updates == 0, '没有可合并的单时不该执行 UPDATE')
expect(#notifies == 1, '应当只通知一个在勤警察（平民不在收件人里）')
local title = tostring(notifies[1].title)
expect(title:find('#41', 1, true) ~= nil, '通知标题必须带警情单号: ' .. title)
expect(title:find('911', 1, true) ~= nil, '通知标题必须带 code: ' .. title)
expect(tostring(notifies[1].app_id) == 'police_mdt', '通知应落在 police_mdt app')

-- 2. 去重：同码同地 5 分钟内的第二条报警并进原来那单，不插入、不二次通知
reset()
mergeRow = { id = 41, title = '有人持枪抢店', status = 'open', distance = 12.5 }
local merged = registry.CreateIncident(1, {
    code = '911', title = '有人持枪抢店', description = '好麦坞大道', priority = 2,
    x = 100.0, y = 205.0, z = 30.0,
})
expect(type(merged) == 'table' and merged.merged == true, '重复报警应标记为 merged')
expect(merged.id == 41, '合并后应返回原来那单的 id')
expect(#inserts == 0, '合并时不该插入新行')
expect(#updates == 1, '合并时应刷新 last_activity_at')
expect(#notifies == 0, '合并时不该再通知一遍（同一条警情响五遍等于没有警情）')

-- 3. 距离太远不合并
reset()
mergeRow = { id = 41, title = '有人持枪抢店', status = 'open', distance = 240.0 }
local far = registry.CreateIncident(1, {
    code = '911', title = '有人持枪抢店', description = '另一个街区', priority = 2,
    x = 900.0, y = 900.0, z = 30.0,
})
expect(type(far) == 'table' and far.merged ~= true, '超出半径的报警不该合并')
expect(#inserts == 1, '超出半径应插入新行')
expect(#notifies == 1, '新的单要通知')

-- 4. 系统来源（没有玩家可校验）：走 CreateIncidentSystem 并记录来源
reset()
local sysResult = registry.CreateIncidentFromSystem('resource:system', {
    code = '911', title = '车辆防盗警报', description = 'Vinewood', priority = 2,
    x = 10.0, y = 20.0, z = 30.0,
})
expect(type(sysResult) == 'table' and sysResult.id == nextId, '系统建单应成功')
expect(#inserts == 1 and inserts[1].params[5] == 'resource:system',
    '系统建单应把 created_by 写成来源标识')

print('police alert dispatch harness ok')
"""


@pytest.mark.skipif(LUA_BIN is None, reason="lua5.4 is not installed")
def test_alert_paths_detect_duplicates_and_create_incidents(tmp_path: Path) -> None:
    script = (
        HARNESS.replace("__POLICY__", json.dumps(str(POLICY)))
        .replace("__AUDIT__", json.dumps(str(AUDIT)))
        .replace("__P0__", json.dumps(str(P0)))
    )
    harness = tmp_path / "police_alert_dispatch_harness.lua"
    harness.write_text(script, encoding="utf-8")
    result = subprocess.run([LUA_BIN, str(harness)], capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, f"{result.stdout}\n{result.stderr}"
    assert "police alert dispatch harness ok" in result.stdout


def test_missing_incident_creation_is_rejected_in_both_alert_paths() -> None:
    """两条报警路径都必须建单，而不是自己发通知就完事。"""
    source = read(MAIN)
    for event in ("police:server:policeAlert", "police:server:autoAlert"):
        start = source.index(event)
        block = source[start:start + 2200]
        assert "createIncidentForAlert" in block, f"{event} 没有建单"
        # 反向校验：旧实现里的那条"直接给手机推送一条警报"必须消失，
        # 否则同一次报警会同时走通知和建单，警察收到两条。
        assert "qb-phone:client:addPoliceAlert" not in block, (
            f"{event} 还在自己推手机通知——通知应只由建单负责（带单号）"
        )


def test_notification_without_an_incident_id_is_rejected() -> None:
    source = read(P0)
    block_start = source.index("local function notifyOnDutyIncident")
    block = source[block_start:block_start + 700]
    assert "'#%s %s: %s'" in block, "通知标题必须带单号，否则手机通知和警情板对不上"


def test_unbounded_merge_window_is_rejected() -> None:
    source = read(P0)
    assert "MERGE_WINDOW_MINUTES = 5" in source
    assert "MERGE_RADIUS_METERS = 60" in source, "合并半径必须是有限值，不能无限吞并"
    assert "distance" in source, "合并必须按距离判断，不能只看 code"


def test_phone_911_bypassing_the_police_authority_is_rejected() -> None:
    """手机报警只做清洗与限流，建单权威仍在 custom-police。"""
    source = read(PHONE_EMERGENCY)
    assert "PhoneRateLimit.Allow" in source, "手机 911 必须限流"
    assert "CreateIncident" in source, "手机 911 必须调用 custom-police 的建单导出"
    assert "INSERT INTO police_incidents" not in source, "手机层不许直接写警情表"
    assert "[%c]" in source, "玩家输入必须清掉控制字符（会被写进通知与日志）"
