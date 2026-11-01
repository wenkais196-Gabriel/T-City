-- world_trace_service.lua — 世界痕迹的唯一写者
--
-- 存在理由：`world_state` 表和服务早就有了，但**全仓零调用方**（2026-11-01 调研：
-- SetRegionState 在服务文件之外出现 0 次）。这个服务是它的第一个写者，负责把
-- "玩家的行为"翻译成"区域的持久状态"，并且只认白名单里的 region / state_key。
--
-- 为什么不让业务资源自己调 SetRegionState：
--   * region_id 一旦写进 DB 就改不动，必须统一由 regions.lua 判定（同一份边界）；
--   * 值结构（recent 时间戳窗口）需要一个稳定的 reducer，否则每个调用方各写一种形状；
--   * 宪法的"每张表单一写者"——写者就是本服务，业务只调导出。
--
-- 失败语义（重要）：痕迹**永远不影响业务结果**。调用方拿到 false 只记日志，
-- 结案/交易该成功还是成功。所以这里的失败一律返回 `false, <code>`，不抛错。

WorldTraceService = WorldTraceService or {}
local T = WorldTraceService

--- 最近 N 次事件的时间戳（秒）。上限存在的意义：world_state 是低写高频读的表，
--- 不能让它长成事件日志；要查历史去 police_audit / world_events。
T.MAX_RECENT = 50

--- 同一 (region, state_key) 的写去抖：30 秒内第二次直接 discard。
T.DEBOUNCE_MS = 30 * 1000

local lastWriteAt = {}

--- 已知的 state_key 与各自的 reducer。新增一种痕迹 = 这里加一行。
T.STATE_KEYS = { 'crime_pressure' }

local KNOWN = {}
for i = 1, #T.STATE_KEYS do KNOWN[T.STATE_KEYS[i]] = true end

local function isKnownStateKey(state_key)
    return type(state_key) == 'string' and KNOWN[state_key] == true
end

--- 窗口内计数（纯函数：now 由调用方给，方便离线测试）。
---@param recent table|nil
---@param now number 秒
---@param window number 秒
---@return number
function T.CountWithin(recent, now, window)
    if type(recent) ~= 'table' or type(now) ~= 'number' or type(window) ~= 'number' then return 0 end
    local from = now - window
    local count = 0
    for i = 1, #recent do
        local ts = recent[i]
        if type(ts) == 'number' and ts > from and ts <= now then count = count + 1 end
    end
    return count
end

--- 读侧摘要：调用方不该自己解释 recent 数组。
---@param value table|nil
---@param now number|nil
---@return table
function T.Summarize(value, now)
    local at = now or os.time()
    local recent = (type(value) == 'table' and type(value.recent) == 'table') and value.recent or {}
    return {
        closed_total = type(value) == 'table' and (tonumber(value.closed_total) or 0) or 0,
        closed_24h = T.CountWithin(recent, at, 24 * 60 * 60),
        closed_7d = T.CountWithin(recent, at, 7 * 24 * 60 * 60),
        last_closed_at = type(value) == 'table' and value.last_closed_at or nil,
        last_incident_id = type(value) == 'table' and value.last_incident_id or nil,
    }
end

--- crime_pressure 的 reducer：事件计数 + 有界时间戳窗口。
local function reduceCrimePressure(previous, payload)
    local value = type(previous) == 'table' and previous or {}
    local recent = {}
    if type(value.recent) == 'table' then
        for i = 1, #value.recent do
            local ts = value.recent[i]
            if type(ts) == 'number' then recent[#recent + 1] = ts end
        end
    end
    local at = os.time()
    recent[#recent + 1] = at
    while #recent > T.MAX_RECENT do table.remove(recent, 1) end

    return {
        closed_total = (tonumber(value.closed_total) or 0) + 1,
        recent = recent,
        last_closed_at = at,
        last_incident_id = (type(payload) == 'table' and payload.incident_id) or value.last_incident_id,
        last_disposition = (type(payload) == 'table' and payload.disposition) or value.last_disposition,
    }
end

local REDUCERS = {
    crime_pressure = reduceCrimePressure,
}

--- 写一条痕迹。**历史值从缓存/DB 读**，所以第一条痕迹在缓存冷时会走异步加载。
---@param region_id string
---@param state_key string
---@param payload table|nil 这次事件的结构化描述（incident_id / disposition …）
---@param changed_by string citizenid
---@param cb fun(ok: boolean, detail: string|table)|nil
---@return boolean, string|nil 立即结果：参数/去抖问题在写之前就能判定
function T.Record(region_id, state_key, payload, changed_by, cb)
    if type(Regions) ~= 'table' or type(Regions.IsValid) ~= 'function' then
        return false, 'regions_unavailable'
    end
    if not Regions.IsValid(region_id) then return false, 'invalid_region' end
    if not isKnownStateKey(state_key) then return false, 'invalid_state_key' end
    if payload ~= nil and type(payload) ~= 'table' then return false, 'invalid_payload' end
    if type(changed_by) ~= 'string' or changed_by == '' then return false, 'invalid_actor' end

    local debounceKey = region_id .. ':' .. state_key
    local nowMs = os.time() * 1000
    local last = lastWriteAt[debounceKey]
    if last and nowMs - last < T.DEBOUNCE_MS then
        return false, 'debounced'
    end
    lastWriteAt[debounceKey] = nowMs

    local reducer = REDUCERS[state_key]
    if type(reducer) ~= 'function' then return false, 'invalid_state_key' end

    if type(WorldStateService) ~= 'table' or type(WorldStateService.GetRegionStateAsync) ~= 'function' then
        return false, 'world_state_unavailable'
    end

    WorldStateService.GetRegionStateAsync(region_id, state_key, function(previous)
        local nextValue = reducer(previous, payload)
        local accepted, acceptErr = WorldStateService.SetRegionState(
            region_id, state_key, nextValue, changed_by,
            function(okWrite, saveErr)
                -- 落盘是异步的，所以"到底写没写进 DB"只能在这一层回报。
                if type(cb) ~= 'function' then return end
                if okWrite then cb(true, nextValue) else cb(false, saveErr or 'save_failed') end
            end)
        if not accepted and type(cb) == 'function' then
            cb(false, acceptErr or 'rejected')
        end
    end)
    return true
end

--- 按坐标写痕迹：region 由 regions.lua 判定，调用方不自己算区域。
---@param x number
---@param y number
---@param state_key string
---@param payload table|nil
---@param changed_by string
---@param cb fun(ok: boolean, detail: string|table)|nil
---@return boolean, string|nil
function T.RecordAt(x, y, state_key, payload, changed_by, cb)
    if type(Regions) ~= 'table' or type(Regions.RegionOf) ~= 'function' then
        return false, 'regions_unavailable'
    end
    local region_id = Regions.RegionOf(x, y)
    local accepted, detail = T.Record(region_id, state_key, payload, changed_by, cb)
    if not accepted then return false, detail end
    return true, region_id
end

--- 测试/诊断：清空去抖记录（不影响 DB 与缓存）。
function T.ClearDebounce()
    lastWriteAt = {}
end

if Bus and Bus.RegisterService then
    Bus.RegisterService('world_trace', {
        Record        = T.Record,
        RecordAt      = T.RecordAt,
        Summarize     = T.Summarize,
        CountWithin   = T.CountWithin,
        ClearDebounce = T.ClearDebounce,
    })
end

print('[world_trace_service] 🧭 就绪: 痕迹唯一写者（crime_pressure）')
