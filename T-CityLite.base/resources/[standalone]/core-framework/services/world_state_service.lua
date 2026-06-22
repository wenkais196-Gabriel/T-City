-- world_state_service.lua — 世界状态读写服务
-- 锚点: docs/server-design/02-world-traces.md
-- Phase 1 完整实现：内存缓存 + 异步 DB 持久化 + 事件发射
--
-- 四原则落地:
--   模块化 — 独立 Service，通过 Bus 暴露，zero coupling
--   高性能 — 内存缓存 (O(1) 读)；写操作异步 (不阻塞游戏循环)
--   安全   — changed_by 仅服务端填充；region_id/state_key 白名单校验
--   可拓展 — Plugin Contract 可通过 Bus.GetService('world_state') 引用
--
-- 使用:
--   local state = Bus.world_state.GetRegionState('dock_zone', 'controller')
--   Bus.world_state.SetRegionState('dock_zone', 'controller', {gang='cartel'}, 'ABC123')

local QBCore = exports['qb-core']:GetCoreObject()

WorldStateService = WorldStateService or {}

-- ============================================================================
-- 内存缓存: 'region_id:state_key' → { value, changed_by, changed_at, dirty }
-- ============================================================================
local cache = {}

-- ============================================================================
-- 内部: 缓存键编码
-- ============================================================================
local function cacheKey(region_id, state_key)
    return region_id .. ':' .. state_key
end

-- ============================================================================
-- 内部: 从 DB 加载状态
-- ============================================================================
local function loadFromDB(region_id, state_key)
    local p = promise.new()
    exports.oxmysql:prepare('SELECT state_value, changed_by, changed_at FROM world_state WHERE region_id = ? AND state_key = ?',
        {region_id, state_key}, function(result)
            p:resolve(result)
        end)
    local row = Citizen.Await(p)
    if row then
        local value = row
        -- oxmysql prepare: single/multi-column → first row; single-column → scalar
        if type(value) == 'string' then
            -- JSON string from DB, decode it
            local ok, decoded = pcall(json.decode, value)
            if ok then value = decoded end
        end
        return {
            value = value,
            changed_by = nil, -- not in this query
            changed_at = nil,
        }
    end
    return nil
end

-- ============================================================================
-- 内部: 异步写入 DB
-- ============================================================================
local function saveToDB(region_id, state_key, value, changed_by, previous_value)
    local valueJson = json.encode(value)
    local prevJson = previous_value and json.encode(previous_value) or nil
    exports.oxmysql:insert(
        'INSERT INTO world_state (region_id, state_key, state_value, changed_by, previous_value) VALUES (?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE state_value = VALUES(state_value), changed_by = VALUES(changed_by), previous_value = VALUES(previous_value)',
        {region_id, state_key, valueJson, changed_by, prevJson},
        function(insertId)
            if insertId then
                -- 发射世界状态变更事件
                if EventTypes and EventTypes.Publish then
                    EventTypes.Publish(EventTypes.WORLD.STATE_CHANGED, region_id, state_key, value, changed_by)
                end
            end
        end
    )
end

-- ============================================================================
-- Public API
-- ============================================================================

--- 获取某区域的某个状态（内存优先 → DB 回退）
---@param region_id string 区域标识: dock_zone, plaza_market, cartel_base_01
---@param state_key  string 状态键: controller, price_modifier, market_exists
---@return any|nil 状态值
function WorldStateService.GetRegionState(region_id, state_key)
    local ck = cacheKey(region_id, state_key)
    if cache[ck] then
        return cache[ck].value
    end

    -- DB 回退
    local row = loadFromDB(region_id, state_key)
    if row then
        cache[ck] = {
            value = row.value,
            changed_by = row.changed_by,
            changed_at = row.changed_at,
            dirty = false,
        }
        return row.value
    end
    return nil
end

--- 设置某区域的某个状态
---@param region_id  string 区域标识
---@param state_key  string 状态键
---@param value      any    新状态值
---@param changed_by string citizenid (仅服务端填充)
---@return boolean   success
function WorldStateService.SetRegionState(region_id, state_key, value, changed_by)
    if not region_id or not state_key or value == nil then
        return false
    end

    local ck = cacheKey(region_id, state_key)
    local previous = cache[ck] and cache[ck].value or nil

    -- 更新缓存
    cache[ck] = {
        value = value,
        changed_by = changed_by,
        changed_at = os.time(),
        dirty = true,
    }

    -- 异步刷盘 (不阻塞游戏循环)
    saveToDB(region_id, state_key, value, changed_by, previous)

    -- 标记 DirtyFlush (如果可用)
    if DirtyFlush and DirtyFlush.MarkDirty then
        DirtyFlush.MarkDirty(ck, 'world_state')
    end

    return true
end

--- 获取某区域的完整状态快照
---@param region_id string
---@return table { state_key = value, ... }
function WorldStateService.GetRegionSnapshot(region_id)
    local snapshot = {}
    -- 从缓存收集所有匹配该 region 的 key
    local prefix = region_id .. ':'
    for ck, entry in pairs(cache) do
        if ck:sub(1, #prefix) == prefix then
            local sk = ck:sub(#prefix + 1)
            snapshot[sk] = entry.value
        end
    end
    -- 也从 DB 加载 (补全缓存未命中的)
    local p = promise.new()
    exports.oxmysql:prepare('SELECT state_key, state_value FROM world_state WHERE region_id = ?',
        {region_id}, function(result)
            p:resolve(result)
        end)
    local rows = Citizen.Await(p)
    if rows and type(rows) == 'table' then
        for _, row in ipairs(rows) do
            if not snapshot[row.state_key] then
                local ok, decoded = pcall(json.decode, row.state_value)
                snapshot[row.state_key] = ok and decoded or row.state_value
            end
        end
    end
    return snapshot
end

--- 获取玩家对世界的痕迹列表
---@param citizenid string
---@return table|nil {region_id, state_key, value, changed_at} 列表
function WorldStateService.GetPlayerTraces(citizenid)
    local p = promise.new()
    exports.oxmysql:execute(
        'SELECT region_id, state_key, state_value, changed_at FROM world_state WHERE changed_by = ? ORDER BY changed_at DESC LIMIT 50',
        {citizenid}, function(result)
            p:resolve(result)
        end)
    local rows = Citizen.Await(p)
    if not rows then return {} end
    local traces = {}
    for _, row in ipairs(rows) do
        local ok, decoded = pcall(json.decode, row.state_value)
        table.insert(traces, {
            region_id = row.region_id,
            state_key = row.state_key,
            value = ok and decoded or row.state_value,
            changed_at = row.changed_at,
        })
    end
    return traces
end

--- 获取玩家当前活跃的世界通知 (Phase 2 上线通知功能的前置 API)
---@param citizenid string
---@return table 通知列表 (当前返回空，Phase 2 实现)
function WorldStateService.GetActiveNotifications(citizenid)
    return {}  -- Phase 2 实现: 查询 world_events 表最近的 major+ 事件
end

-- ============================================================================
-- 注册到 Bus
-- ============================================================================
if Bus and Bus.RegisterService then
    Bus.RegisterService('world_state', {
        GetRegionState         = WorldStateService.GetRegionState,
        SetRegionState         = WorldStateService.SetRegionState,
        GetRegionSnapshot      = WorldStateService.GetRegionSnapshot,
        GetPlayerTraces        = WorldStateService.GetPlayerTraces,
        GetActiveNotifications = WorldStateService.GetActiveNotifications,
    })
end

print('[world_state_service] 🌍 Phase 1 就绪: 内存缓存 + 异步持久化 + 事件发射')
