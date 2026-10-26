-- server/phone_apps.lua — server-authoritative job app registry.
--
-- Apps register a manifest plus query/action handlers. The client only ever
-- receives the metadata (id/label/icon) it is allowed to see; queries and
-- actions are re-authorised here against the player's job/onduty state, so
-- hiding a tile in the NUI is never the permission check.

PhoneApps = {}
local apps = {}

-- The resource-local QBCore upvalue lives in main.lua, which loads after this
-- file; resolve the export lazily and cache it on _G.
local function core()
    if type(_G.QBCore) == 'table' then return _G.QBCore end
    local ok, value = pcall(function() return exports['qb-core']:GetCoreObject() end)
    if ok and type(value) == 'table' then
        _G.QBCore = value
        return value
    end
    return nil
end
local LIMITS = { id = 32, label = 48, icon = 8, query = 32, action = 32 }

local function trim(value)
    return type(value) == 'string' and value:match('^%s*(.-)%s*$') or nil
end

local function validName(value)
    return type(value) == 'string' and #value > 0 and #value <= 32 and value:match('^[a-z0-9_]+$') ~= nil
end

local function playerData(source)
    local qb = core()
    local Player = qb and qb.Functions and qb.Functions.GetPlayer(source)
    if not Player or type(Player.PlayerData) ~= 'table' then return nil end
    return Player.PlayerData
end

local function audienceAllows(app, data)
    local audience = app.audience or {}
    local jobs = audience.jobs
    if type(jobs) ~= 'table' or #jobs == 0 then return true end
    local job = type(data.job) == 'table' and data.job or {}
    local name = type(job.name) == 'string' and job.name or ''
    local allowed = false
    for _, wanted in ipairs(jobs) do
        if wanted == name then allowed = true break end
    end
    if not allowed then return false end
    if audience.onduty and job.onduty ~= true then return false end
    return true
end

function PhoneApps.Register(def)
    if type(def) ~= 'table' then return false, 'invalid_app' end
    local id = validName(def.id) and def.id or nil
    if not id then return false, 'invalid_id' end
    if apps[id] then return false, 'duplicate_id' end
    local label = trim(def.label)
    if not label or #label == 0 or #label > LIMITS.label then return false, 'invalid_label' end
    local icon = type(def.icon) == 'string' and def.icon:sub(1, LIMITS.icon) or '📱'
    if type(def.queries) ~= 'table' then def.queries = {} end
    if type(def.actions) ~= 'table' then def.actions = {} end
    for name in pairs(def.queries) do
        if not validName(name) then return false, 'invalid_query' end
    end
    for name in pairs(def.actions) do
        if not validName(name) then return false, 'invalid_action' end
    end
    apps[id] = {
        id = id,
        label = label,
        icon = icon,
        audience = type(def.audience) == 'table' and def.audience or {},
        queries = def.queries,
        actions = def.actions,
    }
    return true
end

--- Apps this player may see. Metadata only; handlers stay server-side.
function PhoneApps.ForPlayer(source)
    local data = playerData(source)
    if not data then return {} end
    local list = {}
    for _, app in pairs(apps) do
        if audienceAllows(app, data) then
            local queries, actions = {}, {}
            for name in pairs(app.queries) do queries[#queries + 1] = name end
            for name in pairs(app.actions) do actions[#actions + 1] = name end
            table.sort(queries)
            table.sort(actions)
            list[#list + 1] = {
                id = app.id, label = app.label, icon = app.icon,
                queries = queries, actions = actions,
            }
        end
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

local function resolve(source, appId)
    local data = playerData(source)
    -- 调用方一定是玩家，所以"拿不到数据"几乎只有一种原因：角色还在加载。
    -- 用 player_not_ready 而不是 player_not_found，前端才好区分"稍后重试"和"根本不存在"。
    if not data then return nil, nil, 'player_not_ready' end
    local app = apps[appId]
    if not app then return nil, nil, 'app_not_found' end
    if not audienceAllows(app, data) then return nil, nil, 'app_forbidden' end
    return app, data, nil
end

---@return boolean ok, table|string result
function PhoneApps.Query(source, appId, queryName, params)
    local app, _, err = resolve(source, appId)
    if not app then return false, err end
    local handler = app.queries[queryName]
    if type(handler) ~= 'function' then return false, 'query_not_found' end
    local ok, result = pcall(handler, source, type(params) == 'table' and params or {})
    if not ok then
        print(('[custom-phone][apps] query %s:%s failed: %s'):format(appId, queryName, tostring(result)))
        return false, 'query_failed'
    end
    if type(result) ~= 'table' then return false, 'query_failed' end
    return true, result
end

local function errorCode(value)
    if type(value) == 'string' and value ~= '' then return value end
    if type(value) == 'number' then return tostring(value) end
    return 'rejected'
end

--- Run one app action and flatten its structured result into the
--- `ok, result|error` contract used by `phone:server:appAction`.
---
--- Handler result shapes:
---   true                        -> true, {}
---   { ok = true, ... }          -> true, result (data preserved)
---   { ok = false, error, detail } -> false, error, detail
---   false / nil                 -> false, 'action_rejected' (legacy)
---   { ... } without `ok`        -> true, result (legacy table success)
---@return boolean ok, table|string result, string|nil detail
function PhoneApps.Action(source, appId, actionName, params)
    local app, _, err = resolve(source, appId)
    if not app then return false, err end
    local handler = app.actions[actionName]
    if type(handler) ~= 'function' then return false, 'action_not_found' end
    local ok, result = pcall(handler, source, type(params) == 'table' and params or {})
    if not ok then
        print(('[custom-phone][apps] action %s:%s failed: %s'):format(appId, actionName, tostring(result)))
        return false, 'action_failed'
    end
    if type(result) == 'table' and result.ok == false then
        local code = errorCode(result.error)
        if result.detail ~= nil then
            print(('[custom-phone][apps] action %s:%s rejected (%s): %s')
                :format(appId, actionName, code, tostring(result.detail)))
            return false, code, tostring(result.detail)
        end
        return false, code
    end
    if result == false or result == nil then return false, 'action_rejected' end
    return true, type(result) == 'table' and result or {}
end

return PhoneApps
