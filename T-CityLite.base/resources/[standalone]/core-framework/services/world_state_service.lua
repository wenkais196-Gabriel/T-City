-- world_state_service.lua — 世界状态读写服务
-- 锚点: docs/server-design/02-world-traces.md
--
-- 读路径纪律（2026-11-01 修 R7）：
--   * **绝不在游戏线程上 Await DB**。旧实现用 `promise.new` + `Citizen.Await` 同步查库，
--     第一次读就把服务端主循环卡住（审计 R7 原文："首次读取阻塞主线程"）。
--   * **绝不把行表当值返回**。旧实现 `local value = row` 拿到的是整行，且把 changed_by
--     硬写成 nil（注释写 not in this query，可查询里明明有）—— 缓存一冷就返回错值。
--   * 现在的语义：`GetRegionState` 只读缓存（未命中返回 nil 并触发一次异步预热），
--     需要"现在就要"的调用方用 `GetRegionStateAsync(region, key, cb)`。
--
-- 写路径不变：内存缓存 + 异步刷盘 + 变更事件。唯一写者是本服务；业务资源通过
-- `service_world_state_*` / `service_world_trace_*` 导出调用，不直接写这张表。

local QBCore = exports['qb-core']:GetCoreObject()

WorldStateService = WorldStateService or {}

-- ============================================================================
-- 内存缓存: 'region_id:state_key' → { value, changed_by, changed_at }
-- loading: 同键异步加载去重，避免缓存一冷就被并发打爆
-- ============================================================================
local cache = {}
local loading = {}

local function cacheKey(region_id, state_key)
    return region_id .. ':' .. state_key
end

--- 把 DB 的 state_value（JSON 文本或已解码的表）规整成 Lua 值。
local function decodeValue(raw)
    if type(raw) ~= 'string' then return raw end
    local ok, decoded = pcall(json.decode, raw)
    if ok then return decoded end
    return raw
end

--- 异步取一行。回调参数是行表或 nil —— 既不是标量，也不是"整行当值"。
local function fetchRow(region_id, state_key, cb)
    exports.oxmysql:execute(
        'SELECT state_value, changed_by, changed_at FROM world_state WHERE region_id = ? AND state_key = ? LIMIT 1',
        { region_id, state_key },
        function(rows)
            local row = (type(rows) == 'table' and rows[1]) or nil
            if type(row) ~= 'table' then return cb(nil) end
            cb({
                value = decodeValue(row.state_value),
                changed_by = row.changed_by,
                changed_at = row.changed_at,
            })
        end)
end

--- 预热缓存：不阻塞调用方。after(entry|nil) 在加载完成后调用。
local function warm(region_id, state_key, after)
    local ck = cacheKey(region_id, state_key)
    if cache[ck] then
        if after then after(cache[ck]) end
        return
    end
    if loading[ck] then
        -- 已经有人在拉了：本次不排队（排队会让"读"变成有隐藏代价的操作）。
        if after then after(nil) end
        return
    end
    loading[ck] = true
    fetchRow(region_id, state_key, function(row)
        loading[ck] = nil
        if row then
            cache[ck] = { value = row.value, changed_by = row.changed_by, changed_at = row.changed_at }
        end
        if after then after(cache[ck]) end
    end)
end

--- 落盘。落盘是**异步**的，所以真实结果只能通过 cb 回来 ——
--- 调用方要知道"到底写进 DB 没有"，就拿 cb；不关心就当 fire-and-forget。
local function saveToDB(region_id, state_key, value, changed_by, previous_value, cb)
    local okEncode, valueJson = pcall(json.encode, value)
    if not okEncode then
        if cb then cb(false, 'encode_failed') end
        return false, 'encode_failed'
    end
    -- 2026-11-01 真机实测：本 build 的 oxmysql 是**客户端插值**的，遇到 nil 参数会把它
    -- 留成字面量 `?`，于是整条 SQL 语法错误、而 .await/回调都不报错 —— 写静默丢失。
    -- 所以这里永远不给 nil：没有旧值时传 JSON 的 `null`（previous_value 的 CHECK 要求
    -- json_valid，'null' 是合法 JSON，NULL 也合法，但参数位不能是 nil）。
    local prevJson = 'null'
    if previous_value ~= nil then
        local okPrev, encoded = pcall(json.encode, previous_value)
        if okPrev and type(encoded) == 'string' then prevJson = encoded end
    end
    exports.oxmysql:insert(
        'INSERT INTO world_state (region_id, state_key, state_value, changed_by, previous_value) VALUES (?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE state_value = VALUES(state_value), changed_by = VALUES(changed_by), previous_value = VALUES(previous_value)',
        { region_id, state_key, valueJson, changed_by, prevJson },
        function(insertId)
            if not insertId then
                if cb then cb(false, 'save_failed') end
                return
            end
            if EventTypes and EventTypes.Publish then
                EventTypes.Publish(EventTypes.WORLD.STATE_CHANGED, region_id, state_key, value, changed_by)
            end
            if cb then cb(true) end
        end)
    return true
end

-- ============================================================================
-- Public API
-- ============================================================================

--- 读缓存命中的值。**不做 IO**：未命中返回 nil，并在后台预热。
---@param region_id string
---@param state_key string
---@return any|nil
function WorldStateService.GetRegionState(region_id, state_key)
    if type(region_id) ~= 'string' or type(state_key) ~= 'string' then return nil end
    local entry = cache[cacheKey(region_id, state_key)]
    if entry then return entry.value end
    warm(region_id, state_key, nil)
    return nil
end

--- 确定性读取：缓存命中同步回调，未命中异步加载后回调。
---@param region_id string
---@param state_key string
---@param cb fun(value: any|nil, entry: table|nil)
function WorldStateService.GetRegionStateAsync(region_id, state_key, cb)
    if type(cb) ~= 'function' then return false, 'invalid_callback' end
    if type(region_id) ~= 'string' or type(state_key) ~= 'string' then
        cb(nil, nil)
        return false, 'invalid_args'
    end
    local ck = cacheKey(region_id, state_key)
    local entry = cache[ck]
    if entry then
        cb(entry.value, entry)
        return true
    end
    warm(region_id, state_key, function(loaded)
        cb(loaded and loaded.value or nil, loaded)
    end)
    return true
end

--- 设置某区域的某个状态（唯一写入口）。
---@param region_id  string
---@param state_key  string
---@param value      any
---@param changed_by string|nil citizenid（仅服务端填充）
---@return boolean, string|nil
--- @param cb fun(ok: boolean, code: string|nil)|nil 落盘的异步结果（不传就只打日志）
--- @return boolean, string|nil 立即结果：true = 已接受（缓存已更新，落盘在后台）
function WorldStateService.SetRegionState(region_id, state_key, value, changed_by, cb)
    if type(region_id) ~= 'string' or region_id == '' then return false, 'invalid_region' end
    if type(state_key) ~= 'string' or state_key == '' then return false, 'invalid_state_key' end
    if value == nil then return false, 'invalid_value' end

    local ck = cacheKey(region_id, state_key)
    local entry = cache[ck]
    local previous = entry and entry.value or nil

    cache[ck] = {
        value = value,
        changed_by = changed_by,
        changed_at = os.time(),
    }

    local onSaved = cb
    if type(onSaved) ~= 'function' then
        onSaved = function(okWrite, code)
            if not okWrite then
                print(('[world_state] ⚠️ 落盘失败 %s: %s'):format(ck, tostring(code)))
            end
        end
    end

    saveToDB(region_id, state_key, value, changed_by, previous, onSaved)

    if DirtyFlush and DirtyFlush.MarkDirty then
        DirtyFlush.MarkDirty(ck, 'world_state')
    end
    return true
end

--- 区域快照（缓存优先，不触发 IO）。
---@param region_id string
---@return table
function WorldStateService.GetRegionSnapshot(region_id)
    local snapshot = {}
    if type(region_id) ~= 'string' then return snapshot end
    local prefix = region_id .. ':'
    for ck, entry in pairs(cache) do
        if ck:sub(1, #prefix) == prefix then
            snapshot[ck:sub(#prefix + 1)] = entry.value
        end
    end
    return snapshot
end

--- 区域快照（确定性）：从 DB 拉全该区域的行，与缓存合并后回调。
---@param region_id string
---@param cb fun(snapshot: table)
function WorldStateService.GetRegionSnapshotAsync(region_id, cb)
    if type(cb) ~= 'function' then return false, 'invalid_callback' end
    if type(region_id) ~= 'string' or region_id == '' then
        cb({})
        return false, 'invalid_region'
    end
    exports.oxmysql:execute(
        'SELECT state_key, state_value FROM world_state WHERE region_id = ?',
        { region_id },
        function(rows)
            local snapshot = WorldStateService.GetRegionSnapshot(region_id)
            if type(rows) == 'table' then
                for i = 1, #rows do
                    local row = rows[i]
                    if type(row) == 'table' and type(row.state_key) == 'string' then
                        if snapshot[row.state_key] == nil then
                            snapshot[row.state_key] = decodeValue(row.state_value)
                        end
                    end
                end
            end
            cb(snapshot)
        end)
    return true
end

--- 玩家造成的痕迹（异步：这是玩家请求路径，不能卡主线程）。
---@param citizenid string
---@param cb fun(traces: table)
function WorldStateService.GetPlayerTraces(citizenid, cb)
    if type(cb) ~= 'function' then return false, 'invalid_callback' end
    if type(citizenid) ~= 'string' or citizenid == '' then
        cb({})
        return false, 'invalid_citizenid'
    end
    exports.oxmysql:execute(
        'SELECT region_id, state_key, state_value, changed_at FROM world_state WHERE changed_by = ? ORDER BY changed_at DESC LIMIT 50',
        { citizenid },
        function(rows)
            local traces = {}
            if type(rows) == 'table' then
                for i = 1, #rows do
                    local row = rows[i]
                    if type(row) == 'table' then
                        traces[#traces + 1] = {
                            region_id = row.region_id,
                            state_key = row.state_key,
                            value = decodeValue(row.state_value),
                            changed_at = row.changed_at,
                        }
                    end
                end
            end
            cb(traces)
        end)
    return true
end

--- 玩家当前活跃的世界通知（Phase 2 实现：查询 world_events 最近 major+ 事件）。
---@param citizenid string
---@return table
function WorldStateService.GetActiveNotifications(citizenid)
    return {}
end

--- 清空内存缓存（诊断与测试用，不影响 DB）。
function WorldStateService.ClearCache()
    cache = {}
    loading = {}
end

-- ============================================================================
-- 注册到 Bus
-- ============================================================================
if Bus and Bus.RegisterService then
    Bus.RegisterService('world_state', {
        GetRegionState         = WorldStateService.GetRegionState,
        GetRegionStateAsync    = WorldStateService.GetRegionStateAsync,
        SetRegionState         = WorldStateService.SetRegionState,
        GetRegionSnapshot      = WorldStateService.GetRegionSnapshot,
        GetRegionSnapshotAsync = WorldStateService.GetRegionSnapshotAsync,
        GetPlayerTraces        = WorldStateService.GetPlayerTraces,
        GetActiveNotifications = WorldStateService.GetActiveNotifications,
        ClearCache             = WorldStateService.ClearCache,
    })
end

print('[world_state_service] 🌍 就绪: 内存缓存(不阻塞读) + 异步持久化 + 变更事件')
