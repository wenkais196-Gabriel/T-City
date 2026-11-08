-- tests/unit/layer3_business/fixtures/weathersync_probe.lua
-- 真加载 qb-weathersync 的 config.lua + server/server.lua：
--   1) 非管理员调 setWeather 必须被拒（天气不变）；
--   2) 管理员可以改；
--   3) RequestStateSync 有按玩家冷却（第二次调用不再产生全服广播）；
--   4) 客户端触发 QBCore:Server:OnPlayerLoaded 被拒（只允许服务端）。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local state = { broadcasts = 0, permission = false, lastWeather = nil }

local QBCoreMock = {
    Functions = {
        GetPlayer = function(source) return { PlayerData = { source = source, citizenid = 'CID' } } end,
        HasPermission = function() return state.permission end,
        CreateCallback = function() end,
        GetDutyCount = function() return 0 end,
    },
    Commands = { Add = function() end },
    Shared = {},
}

local handlers = {}
RegisterNetEvent = function(name, fn) handlers[name] = fn end
RegisterServerEvent = RegisterNetEvent
AddEventHandler = function(name, fn) handlers[name] = fn end
TriggerClientEvent = function(name, target, ...)
    if name == 'qb-weathersync:client:SyncWeather' then
        state.broadcasts = state.broadcasts + 1
        state.lastWeather = select(1, ...)
    elseif name == 'qb-weathersync:client:SyncTime' then
        state.broadcasts = state.broadcasts + 1
    end
end
-- 服务端 TriggerEvent 会真的派发到同名 handler（资源里靠它触发 RequestStateSync）
TriggerEvent = function(name, ...)
    local target = handlers[name]
    if target then target(...) end
end
CreateThread = function() end
SetTimeout = function() end
Wait = function() end
GetGameTimer = function() return 0 end
GetConvar = function(_, default) return default end
IsPlayerAceAllowed = function() return false end
os = { time = os.time, date = os.date }
Lang = { t = function(a, b) local key = type(a) == 'string' and a or b; return tostring(key) end }
json = { encode = function() return '{}' end, decode = function() return {} end }

exports = setmetatable({}, {
    __call = function(_, name, fn) rawset(exports, name, fn) end,
    __index = function(_, name)
        if name == 'qb-core' then return { GetCoreObject = function() return QBCoreMock end } end
        return setmetatable({}, { __index = function() return function() return true end end })
    end,
})

local function load_lua(path, chunkname)
    local handle = assert(io.open(path, 'r'))
    local source = handle:read('a')
    handle:close()
    source = source:gsub('`([A-Z][A-Z0-9_]*)`', "GetHashKey('%1')")
    assert(load(source, '@' .. chunkname))()
end
GetHashKey = function(value) return 'hash:' .. tostring(value) end

load_lua(RES .. '/config.lua', 'config.lua')
load_lua(RES .. '/server/server.lua', 'server.lua')

local function fireAs(src, name, ...)
    _G.source = src
    local handler = handlers[name]
    if not handler then error('handler 未注册: ' .. name) end
    local ok, err = pcall(handler, ...)
    _G.source = nil
    if not ok then OUT[#OUT + 1] = 'HANDLER_ERROR|' .. tostring(err) end
    return ok
end

-- 天气以服务端广播出去的那份为准（handler 本身不直接引用 CurrentWeather）
local before = state.lastWeather

-- ── 1. 普通玩家改天气 → 拒绝 ──
emit('SCENARIO', 'set-weather-player')
fireAs(1, 'qb-weathersync:server:setWeather', 'THUNDER')
emit('WEATHER_UNCHANGED', tostring(state.lastWeather == before))

-- ── 2. 管理员改 → 生效 ──
emit('SCENARIO', 'set-weather-admin')
state.permission = true
fireAs(1, 'qb-weathersync:server:setWeather', 'THUNDER')
emit('WEATHER_CHANGED', tostring(state.lastWeather == 'THUNDER'))

-- ── 3. RequestStateSync 冷却：连点只广播一次 ──
emit('SCENARIO', 'state-sync-cooldown')
state.permission = false
local b = state.broadcasts
-- 用一个"没在冷却窗口里"的玩家（上面 setWeather 已经给 1 号刷过一次冷却）
fireAs(2, 'qb-weathersync:server:RequestStateSync')
fireAs(2, 'qb-weathersync:server:RequestStateSync')
-- 一次 RequestStateSync 会发两条（SyncWeather + SyncTime）；第二次被 5 秒冷却挡掉
emit('BROADCASTS_FROM_TWO_CALLS', tostring(state.broadcasts - b))

-- ── 4. 客户端触发 OnPlayerLoaded → 拒绝（不该再广播） ──
emit('SCENARIO', 'client-onplayerloaded')
b = state.broadcasts
fireAs(1, 'QBCore:Server:OnPlayerLoaded')
emit('BROADCASTS_FROM_CLIENT_TRIGGER', tostring(state.broadcasts - b))

emit('SCENARIO', 'done')
io.write(table.concat(OUT, '\n'), '\n')
