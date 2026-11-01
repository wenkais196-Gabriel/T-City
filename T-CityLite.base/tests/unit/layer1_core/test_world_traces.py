"""世界痕迹：读路径（R7）+ 唯一写者（world_trace_service）+ 结案挂钩。

三组断言，缺一不可：

1. **静态**：`world_state_service` 里不能再出现 `Citizen.Await` / `promise.new`（R7 回归闸门），
   且必须从 `rows[1]` 取行、从 `row.state_value` 取值 —— 旧实现是 `local value = row`。
2. **行为**（真 Lua 文件 + oxmysql 桩）：冷读不返回行表、reducer 递增、去抖、窗口计数、
   重启后从 DB 续写。
3. **挂钩**：`p0_incidents` 的结案分支必须（a）SELECT 带 x/y，（b）在 `pcall` 里调
   `service_world_trace_RecordAt`，（c）调用点在 `targetStatus == 'closed'` 之内。

    python3 -m pytest -q tests/unit/layer1_core/test_world_traces.py
"""
from __future__ import annotations

import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]  # T-CityLite.base/
CF = BASE / "resources" / "[standalone]" / "core-framework"
POLICE = BASE / "resources" / "[custom]" / "custom-police"
REGIONS = CF / "shared" / "regions.lua"
STATE = CF / "services" / "world_state_service.lua"
TRACE = CF / "services" / "world_trace_service.lua"
MANIFEST = CF / "fxmanifest.lua"
INCIDENTS = POLICE / "server" / "p0_incidents.lua"
LUA_BIN = shutil.which("lua5.4")

LONG_COMMENT_RE = re.compile(r"--\[(=*)\[.*?\]\1\]", re.DOTALL)
LINE_COMMENT_RE = re.compile(r"--[^\n]*")


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def code_only(src: str) -> str:
    return LINE_COMMENT_RE.sub("", LONG_COMMENT_RE.sub("", src))


# ---------------------------------------------------------------------------
# 1. 静态：R7 不许回来
# ---------------------------------------------------------------------------

def test_manifest_loads_regions_before_services_and_trace_after_state():
    manifest = read(MANIFEST)
    assert "shared/regions.lua" in manifest
    assert "services/world_trace_service.lua" in manifest
    assert manifest.index("services/world_state_service.lua") < manifest.index(
        "services/world_trace_service.lua"
    ), "world_trace_service 依赖 world_state_service，必须排在后面"


def test_world_state_service_never_blocks_the_game_thread():
    src = code_only(read(STATE))
    for forbidden in ("Citizen.Await", "promise.new", ":Wait("):
        assert forbidden not in src, f"R7 回归：读路径又出现阻塞调用 {forbidden}"
    # 旧实现的两处具体形态也必须消失。
    assert "local value = row" not in src, "R7 回归：又把整行当值"
    assert "changed_by = nil, -- not in this query" not in read(STATE)


def test_world_state_service_reads_first_row_explicitly():
    src = code_only(read(STATE))
    assert "rows[1]" in src
    assert "row.state_value" in src
    assert "changed_by = row.changed_by" in src
    # 异步变体必须存在，否则"不阻塞"就等于"读不到"。
    assert "function WorldStateService.GetRegionStateAsync(" in src
    assert "GetRegionStateAsync    = WorldStateService.GetRegionStateAsync" in src


def test_world_state_save_never_binds_a_nil_parameter():
    """本 build 的 oxmysql 是客户端插值的：nil 参数会留成字面量 `?` → 语法错误且静默。

    真机证据（2026-11-01）：world_state 的 INSERT 里 previous_value 传 nil 时，general_log
    记录到的语句末尾是 `, ?)`，行没有变化、也没有任何报错。所以参数位必须永远是字符串。
    """
    src = code_only(read(STATE))
    assert "local prevJson = 'null'" in src
    assert "prevJson = okPrev and encoded or nil" not in src


def test_trace_service_is_the_only_writer_and_is_registered():
    src = code_only(read(TRACE))
    assert "Bus.RegisterService('world_trace'" in src
    assert "WorldStateService.SetRegionState(" in src
    # 它自己不许碰 SQL —— 唯一写者仍然是 world_state_service。
    for forbidden in ("MySQL.", "oxmysql:", "INSERT INTO", "UPDATE "):
        assert forbidden not in src, f"world_trace_service 不许直接写库：{forbidden}"
    assert "T.MAX_RECENT = 50" in src
    assert "T.DEBOUNCE_MS = 30 * 1000" in src
    for code in ("'invalid_region'", "'invalid_state_key'", "'invalid_actor'",
                 "'invalid_payload'", "'debounced'", "'regions_unavailable'"):
        assert code in src, code


def test_police_close_branch_hooks_the_trace_inside_the_closed_branch():
    src = read(INCIDENTS)
    assert "SELECT id, status, x, y FROM police_incidents" in src

    # 挂钩被抽成 publishCloseTrace：区域判定 + 写痕迹 + 必要时发公告。
    helper_at = src.index("local function publishCloseTrace(")
    assert "Regions.RegionOf(tonumber(incident.x), tonumber(incident.y))" in src
    assert "service_world_trace_Record(" in src
    assert "PostCityBulletin(" in src

    close_at = src.index("if targetStatus == 'closed' then")
    call_at = src.index("pcall(publishCloseTrace")
    # 非 closed 分支的通用 UPDATE 必须在调用点之后 —— 说明调用点确实在 closed 分支里，
    # 而不是被塞到了函数末尾（那样状态变更类调用也会写痕迹）。
    next_branch = src.index("SET status = ?, last_activity_at = NOW()", close_at)
    assert helper_at < close_at < call_at < next_branch, "痕迹调用必须在 closed 分支内，且早于通用 UPDATE 分支"
    # 必须被 pcall 包住：痕迹失败不能让结案失败。
    assert "if not traceOk or traceRecorded ~= true then" in src


def test_police_manifest_uses_the_shared_region_table():
    manifest = read(POLICE / "fxmanifest.lua")
    assert "@core-framework/shared/regions.lua" in manifest, "警察要用同一份区域表，不要复制"


def test_city_bulletin_is_only_for_resolutions():
    src = code_only(read(INCIDENTS))
    assert "local ANNOUNCE_DISPOSITIONS = { arrest = true, cleared = true }" in src
    # 取消/误报/超时不该变成城市新闻。
    announce_line = [l for l in src.splitlines() if l.startswith("local ANNOUNCE_DISPOSITIONS")]
    assert announce_line and "cancelled" not in announce_line[0] and "stale" not in announce_line[0]
    # 节流：同一区域 30 分钟最多一条公告，且**不依赖** world_state 的读值
    # （CC 评审指出：冷缓存下 closed_24h 会被读成 0，公告静默丢失）。
    assert "local ANNOUNCE_COOLDOWN = 30 * 60" in src
    assert "if last and now - last < ANNOUNCE_COOLDOWN then return true end" in src
    assert "service_world_state_GetRegionState" not in src


# ---------------------------------------------------------------------------
# 2. 行为：真 Lua 文件 + oxmysql 桩
# ---------------------------------------------------------------------------

HARNESS = r"""
-- 世界痕迹 harness：把 oxmysql / Bus / json / os.time 换成可观测的桩，
-- 然后 dofile 三个真实文件（regions / world_state_service / world_trace_service）。
local clock = 1767225600        -- 2026-01-01T00:00:00Z
os.time = function() return clock end

local exported, services = {}, {}
exports = setmetatable({}, { __call = function(_, name, fn) exported[name] = fn end })
exports['qb-core'] = { GetCoreObject = function() return {} end }

json = {
    encode = function(v) return v end,      -- 桩：DB 里直接存 Lua 值，逻辑测试不关心序列化
    decode = function(v) return v end,
}

local rows = {}   -- 'region:key' -> { state_value, changed_by, changed_at }
local writes = 0
local failInsert = false

exports.oxmysql = {
    execute = function(_, sql, params, cb)
        local out = {}
        if sql:find('region_id = %? AND state_key = %?') then
            local row = rows[params[1] .. ':' .. params[2]]
            if row then out[1] = { state_value = row.state_value, changed_by = row.changed_by, changed_at = row.changed_at } end
        elseif sql:find('WHERE region_id = %?') then
            local prefix = params[1] .. ':'
            for k, row in pairs(rows) do
                if k:sub(1, #prefix) == prefix then
                    out[#out + 1] = { state_key = k:sub(#prefix + 1), state_value = row.state_value }
                end
            end
        elseif sql:find('changed_by = %?') then
            for k, row in pairs(rows) do
                if row.changed_by == params[1] then
                    local region, key = k:match('^(.-):(.+)$')
                    out[#out + 1] = { region_id = region, state_key = key,
                                      state_value = row.state_value, changed_at = row.changed_at }
                end
            end
        end
        cb(out)
    end,
    insert = function(_, sql, params, cb)
        if failInsert then return cb(nil) end
        writes = writes + 1
        rows[params[1] .. ':' .. params[2]] = {
            state_value = params[3], changed_by = params[4], changed_at = clock,
            previous_value = params[5],
        }
        cb(1)
    end,
}

Bus = {
    _services = {},
    RegisterService = function(name, methods)
        services[name] = methods
        Bus[name] = methods
        for methodName, fn in pairs(methods) do
            exported[('service_%s_%s'):format(name, methodName)] = fn
        end
    end,
}

local function expect(cond, msg)
    if not cond then error(msg, 2) end
end

dofile(__REGIONS__)
dofile(__STATE__)
dofile(__TRACE__)

expect(services.world_state ~= nil, 'world_state 已注册')
expect(services.world_trace ~= nil, 'world_trace 已注册')
expect(type(exported.service_world_trace_RecordAt) == 'function', '导出名是 service_world_trace_RecordAt')

local function RecordAt(...) return WorldTraceService.RecordAt(...) end

-- 0) 起始：没有被写过的痕迹
expect(WorldStateService.GetRegionState('south_ls', 'crime_pressure') == nil, '起始应为空')

-- 1) 参数校验：四种非法输入都给稳定错误码，且不落库
local before = writes
expect(WorldTraceService.Record('no_such_region', 'crime_pressure', nil, 'CID1') == false, '非法区域拒绝')
expect(select(2, WorldTraceService.Record('no_such_region', 'crime_pressure', nil, 'CID1')) == 'invalid_region', '错误码 invalid_region')
expect(select(2, WorldTraceService.Record('south_ls', 'nope', nil, 'CID1')) == 'invalid_state_key', '错误码 invalid_state_key')
expect(select(2, WorldTraceService.Record('south_ls', 'crime_pressure', nil, '')) == 'invalid_actor', '错误码 invalid_actor')
expect(select(2, WorldTraceService.Record('south_ls', 'crime_pressure', 'x', 'CID1')) == 'invalid_payload', '错误码 invalid_payload')
expect(writes == before, '非法输入不许落库')

-- 1.5) 首次写入（没有旧值）：previous_value 参数必须是字符串 'null'，不能是 nil
local savedParams = nil
local origInsert = exports.oxmysql.insert
exports.oxmysql.insert = function(_, sql, params, cb)
    if savedParams == nil and sql:find('INSERT INTO world_state') then savedParams = params end
    return origInsert(exports.oxmysql, sql, params, cb)
end
local okFirst, regionFirst = RecordAt(-47.91, -1758.43, 'crime_pressure', { incident_id = 699 }, 'CID0')
exports.oxmysql.insert = origInsert
expect(okFirst == true, '首次写入应被接受')
expect(savedParams ~= nil, '应当捕获到一次 world_state INSERT')
expect(type(savedParams[5]) == 'string', 'previous_value 参数不能是 nil（oxmysql 会留成 ?）')

-- 2) 第一条痕迹：closed_total=1，recent 一条，last_incident_id 记住
local ok, region = RecordAt(24.46, -1346.18, 'crime_pressure', { incident_id = 700, disposition = 'cited' }, 'CID1')
expect(ok == true and region == 'central_ls', '坐标 → 区域: ' .. tostring(region))
local v = WorldStateService.GetRegionState('central_ls', 'crime_pressure')
expect(type(v) == 'table' and v.closed_total == 1, 'closed_total=1')
expect(#v.recent == 1 and v.recent[1] == clock, 'recent 记下时间戳')
expect(v.last_incident_id == 700 and v.last_disposition == 'cited', '记住 incident_id/disposition')

-- 3) 读到的必须是「值」不是「行表」
expect(v.state_value == nil and v.changed_by == nil, 'GetRegionState 不许返回整行')

-- 4) 去抖：30 秒内的第二次被丢弃
local ok2, code2 = RecordAt(24.46, -1346.18, 'crime_pressure', { incident_id = 701 }, 'CID1')
expect(ok2 == false and code2 == 'debounced', '30s 内第二次被去抖')

-- 5) 过窗后第二次写入 → 累加
clock = clock + 31
local ok3 = RecordAt(24.46, -1346.18, 'crime_pressure', { incident_id = 702, disposition = 'cleared' }, 'CID2')
expect(ok3 == true, '过窗后可以写')
v = WorldStateService.GetRegionState('central_ls', 'crime_pressure')
expect(v.closed_total == 2 and #v.recent == 2, '闭包累加到 2')
expect(writes >= 2, '确实落库')

-- 6) recent 有界：连写 60 次，只保留 MAX_RECENT
for i = 1, 60 do
    clock = clock + 31
    RecordAt(24.46, -1346.18, 'crime_pressure', { incident_id = 800 + i }, 'CID3')
end
v = WorldStateService.GetRegionState('central_ls', 'crime_pressure')
expect(#v.recent <= 50, 'recent 有上界: ' .. tostring(#v.recent))
expect(v.closed_total == 62, 'closed_total 仍单调: ' .. tostring(v.closed_total))

-- 7) 窗口计数：24h 内 / 7d 内
local s = WorldTraceService.Summarize(v, clock)
expect(s.closed_24h == math.min(50, 62), '24h 计数只数窗口内的，实际 ' .. tostring(s.closed_24h))
expect(s.closed_7d >= s.closed_24h, '7d ≥ 24h')
expect(WorldTraceService.CountWithin({ clock - 10, clock - 100000 }, clock, 50) == 1, '窗口边界：超出窗的不计')

-- 8) 重启续写：清缓存后从 DB 读回历史再 +1（不是从 0 开始）
WorldStateService.ClearCache()
WorldTraceService.ClearDebounce()
clock = clock + 31
local ok4 = RecordAt(24.46, -1346.18, 'crime_pressure', { incident_id = 999 }, 'CID4')
expect(ok4 == true, '清缓存后仍可写')
v = WorldStateService.GetRegionState('central_ls', 'crime_pressure')
expect(v.closed_total == 63, '冷启动续写而不是归零: ' .. tostring(v.closed_total))

-- 9) 落库失败：缓存仍更新（游戏内看得见），但调用方收到失败
failInsert = true
WorldTraceService.ClearDebounce()
clock = clock + 31
local reported, reportDetail = nil, nil
RecordAt(24.46, -1346.18, 'crime_pressure', { incident_id = 1000 }, 'CID5', function(okWrite, detail)
    reported, reportDetail = okWrite, detail
end)
failInsert = false
expect(reported == false and reportDetail == 'save_failed', '落库失败必须回报 save_failed')

-- 10) city_wide 兜底：远离所有区域的坐标也能写
WorldTraceService.ClearDebounce()
local farOk, farRegion = RecordAt(3000.0, -5000.0, 'crime_pressure', { incident_id = 1001 }, 'CID6')
expect(farOk == true and farRegion == 'city_wide', '海上坐标兜底到 city_wide')

-- 11) 快照与玩家痕迹都是「回调」，不是返回值
local seenSnapshot, seenTraces
WorldStateService.GetRegionSnapshotAsync('central_ls', function(snap) seenSnapshot = snap end)
-- changed_by 是"最后一次写这一行的人"，所以这里必须用最后一次成功写入的 CID4；
-- 用最早的 CID1 会查不到（world_state 一行只有一个 changed_by，这是表的语义，不是 bug）。
WorldStateService.GetPlayerTraces('CID4', function(traces) seenTraces = traces end)
expect(type(seenSnapshot) == 'table' and seenSnapshot.crime_pressure ~= nil, '快照走回调')
expect(type(seenTraces) == 'table' and #seenTraces == 1, '玩家痕迹走回调且只回自己那行')
expect(seenTraces[1].region_id == 'central_ls', '痕迹行带 region_id')

print('world_traces harness ok')
"""


def _harness() -> str:
    return (
        HARNESS.replace("__REGIONS__", json.dumps(str(REGIONS)))
        .replace("__STATE__", json.dumps(str(STATE)))
        .replace("__TRACE__", json.dumps(str(TRACE)))
    )


@pytest.mark.skipif(LUA_BIN is None, reason="lua5.4 is not installed")
def test_trace_behaviour_under_lua(tmp_path: Path) -> None:
    harness = tmp_path / "world_traces_harness.lua"
    harness.write_text(_harness(), encoding="utf-8")
    result = subprocess.run([LUA_BIN, str(harness)], capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, f"{result.stdout}\n{result.stderr}"
    assert "world_traces harness ok" in result.stdout
