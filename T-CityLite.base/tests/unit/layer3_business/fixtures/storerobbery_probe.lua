-- tests/unit/layer3_business/fixtures/storerobbery_probe.lua
-- 真加载 qb-storerobbery 的 config.lua + server/main.lua，检查：
--   1) callCops 只认 Config 里真实存在的店，坐标取服务端配置（客户端传的坐标/店名一律丢弃）；
--   2) 坏 kind / 坏 key 不再 nil 索引崩服务端；
--   3) setSafeStatus 远端玩家不能把全服保险箱标成"已抢"，站到旁边才能。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local state = { clientEvents = {}, coords = nil }

local player = {
    PlayerData = { source = 1, citizenid = 'TESTCID', charinfo = { firstname = 'T', lastname = 'C' } },
    Functions = { GetItemByName = function() return nil end },
}

local QBCoreMock = {
    Functions = {
        GetPlayer = function(source) return source == 1 and player or nil end,
        CreateCallback = function() end,
        GetDutyCount = function() return 0 end,
    },
    Shared = { Items = setmetatable({}, { __index = function(_, k) return { label = tostring(k) } end }) },
    Commands = { Add = function() end },
}

local handlers = {}
RegisterNetEvent = function(name, fn) handlers[name] = fn end
RegisterServerEvent = RegisterNetEvent
AddEventHandler = function(name, fn) handlers[name] = fn end
TriggerClientEvent = function(name, target, ...)
    state.clientEvents[#state.clientEvents + 1] = { name = name, target = target, args = { ... } }
end
CreateThread = function() end
SetTimeout = function() end
ClearTimeout = function() end
Wait = function() end
DropPlayer = function() end
GetGameTimer = function() return 0 end
GetPlayerPed = function(src) return 1 end
GetEntityCoords = function() return state.coords or vector3(0.0, 0.0, 0.0) end
GetPlayerName = function() return 'Tester' end
GetConvar = function(_, default) return default end
os = { time = os.time, date = os.date }
Lang = { t = function(a, b) local key = type(a) == 'string' and a or b; return tostring(key) end }
json = { encode = function() return '{}' end, decode = function() return {} end }
-- FiveM 的 vector 支持 `-` 与 `#`，资源里靠 `#(coords - anchor.xyz)` 算距离，mock 也要实现
local vectorMeta = {}
vectorMeta.__index = vectorMeta
vectorMeta.__sub = function(a, b)
    return setmetatable({ x = (a.x or 0) - (b.x or 0), y = (a.y or 0) - (b.y or 0), z = (a.z or 0) - (b.z or 0) }, vectorMeta)
end
vectorMeta.__len = function(a)
    return math.sqrt((a.x or 0) ^ 2 + (a.y or 0) ^ 2 + (a.z or 0) ^ 2)
end
local function vec3(x, y, z)
    local value = setmetatable({ x = x, y = y, z = z }, vectorMeta)
    value.xyz = setmetatable({ x = x, y = y, z = z }, vectorMeta)
    return value
end
vector2 = function(x, y) return vec3(x, y, 0) end
vector3 = vec3
vector4 = function(x, y, z, w)
    local value = vec3(x, y, z)
    value.w = w
    return value
end
exports = setmetatable({}, {
    __call = function(_, name, fn) rawset(exports, name, fn) end,
    __index = function(_, name)
        if name == 'qb-core' then
            return { GetCoreObject = function() return QBCoreMock end }
        end
        -- custom-crime / custom-security / custom-economy / qb-inventory：一律放行
        return setmetatable({}, {
            __index = function(_, method)
                if method == 'CheckStoreRobbery' or method == 'CheckRateLimit' then
                    return function() return true end
                end
                if method == 'GetEconomyRewardScale' then
                    return function() return 1.0 end
                end
                return function() return true end
            end,
        })
    end,
})
MySQL = setmetatable({}, {
    __index = function()
        return setmetatable({}, { __call = function() return 1 end, __index = function() return function() return {} end end })
    end,
})

local function fireAs(src, name, ...)
    _G.source = src
    local handler = handlers[name]
    if not handler then error('handler 未注册: ' .. name) end
    local ok, err = pcall(handler, ...)
    _G.source = nil
    if not ok then OUT[#OUT + 1] = 'HANDLER_ERROR|' .. tostring(err) end
    return ok
end

local function load_lua(path, chunkname)
    local handle = assert(io.open(path, 'r'))
    local source = handle:read('a')
    handle:close()
    source = source:gsub('`([A-Z][A-Z0-9_]*)`', "GetHashKey('%1')")
    assert(load(source, '@' .. chunkname))()
end
GetHashKey = function(value) return 'hash:' .. tostring(value) end

load_lua(RES .. '/config.lua', 'config.lua')
load_lua(RES .. '/server/main.lua', 'main.lua')

-- 读 handler 闭包里的私有表（activeRobberies / recentStoreRobberies）
local function upvalueOf(handlerName, wanted)
    local handler = handlers[handlerName]
    for index = 1, 60 do
        local name, value = debug.getupvalue(handler, index)
        if not name then break end
        if name == wanted then return value end
    end
    return nil
end

local function setActiveRobbery(registerId, sourceId)
    local active = upvalueOf('qb-storerobbery:server:callCops', 'activeRobberies')
    if not active then return false end
    active[registerId] = { src = sourceId, startTime = 0 }
    return true
end

local function clearRobberies()
    local active = upvalueOf('qb-storerobbery:server:callCops', 'activeRobberies')
    if active then
        for key in pairs(active) do active[key] = nil end
    end
    local recent = upvalueOf('qb-storerobbery:server:callCops', 'recentStoreRobberies')
    if recent then
        for key in pairs(recent) do recent[key] = nil end
    end
end

-- ── 1. callCops：客户端编坐标应被丢弃（人站在店里，否则服务端会按距离拒）──
emit('SCENARIO', 'callcops-coords')
emit('ACTIVE_SETUP', tostring(setActiveRobbery(1, 1)))
local shopAnchor = Config.Registers[1][1]
state.coords = vector3(shopAnchor.x, shopAnchor.y, shopAnchor.z)
local fakeCoords = { x = 9999.0, y = 9999.0, z = 9999.0 }
local before = #state.clientEvents
fireAs(1, 'qb-storerobbery:server:callCops', 'cashier', 1, 'Fake Street', fakeCoords)
local alert = nil
for index = before + 1, #state.clientEvents do
    local event = state.clientEvents[index]
    if event.name == 'qb-phone:client:addPoliceAlert' then alert = event.args[1] end
end
emit('ALERT_SENT', alert ~= nil)
if alert then
    local anchor = Config.Registers[1][1]
    emit('ALERT_COORDS_MATCH_CONFIG', alert.coords.x == anchor.x and alert.coords.y == anchor.y)
    emit('ALERT_COORDS_FROM_CLIENT', alert.coords.x == fakeCoords.x)
end

-- ── 2. 坏 kind / 坏 key / 远处 → 都不该发警情 ──
emit('SCENARIO', 'callcops-bad-input')
local alertsBefore = 0
for _, event in ipairs(state.clientEvents) do
    if event.name == 'qb-phone:client:addPoliceAlert' then alertsBefore = alertsBefore + 1 end
end
clearRobberies()   -- 没有任何抢劫记录：站在店里也不该发警情
local anchor1 = Config.Registers[1][1]
state.coords = vector3(anchor1.x, anchor1.y, anchor1.z)
fireAs(1, 'qb-storerobbery:server:callCops', 'nonsense', 1, 'X', fakeCoords)
fireAs(1, 'qb-storerobbery:server:callCops', 'cashier', 9999, 'X', fakeCoords)
fireAs(1, 'qb-storerobbery:server:callCops', nil, nil, nil, nil)
state.coords = vector3(9999.0, 9999.0, 9999.0)            -- 走远
fireAs(1, 'qb-storerobbery:server:callCops', 'cashier', 1, 'X', fakeCoords)
local alertsAfter = 0
for _, event in ipairs(state.clientEvents) do
    if event.name == 'qb-phone:client:addPoliceAlert' then alertsAfter = alertsAfter + 1 end
end
emit('ALERTS_FROM_BAD_CALLS', alertsAfter - alertsBefore)

-- ── 3. setSafeStatus：必须有"本店正在进行的抢劫" + 站在保险箱旁 ──
emit('SCENARIO', 'safe-remote')
local safeKey = 1
Config.Safes[safeKey].robbed = false
state.coords = vector3(9999.0, 9999.0, 9999.0)
fireAs(1, 'qb-storerobbery:server:setSafeStatus', safeKey)
emit('SAFE_ROBBED_REMOTE', tostring(Config.Safes[safeKey].robbed))

emit('SCENARIO', 'safe-no-active-robbery')
-- 站在保险箱旁但没有任何 activeRobberies 记录：仍然不该标成已抢
local anchorSafe = Config.Safes[safeKey][1]
state.coords = vector3(anchorSafe.x, anchorSafe.y, anchorSafe.z)
fireAs(1, 'qb-storerobbery:server:setSafeStatus', safeKey)
emit('SAFE_ROBBED_WITHOUT_ROBBERY', tostring(Config.Safes[safeKey].robbed))

emit('SCENARIO', 'safe-close')
-- 模拟"本人正在抢这家店的收银台"（Config.Registers[1].safeKey == 1）
emit('ACTIVE_TABLE_FOUND', tostring(setActiveRobbery(1, 1)))
state.coords = vector3(anchorSafe.x, anchorSafe.y, anchorSafe.z)
fireAs(1, 'qb-storerobbery:server:setSafeStatus', safeKey)
emit('SAFE_ROBBED_CLOSE', tostring(Config.Safes[safeKey].robbed))

emit('SCENARIO', 'safe-recent-robbery')
-- 25 秒计时器已结束，但 10 分钟内本人抢过这家店：保险箱应当仍可标记
Config.Safes[safeKey].robbed = false
clearRobberies()
-- recentStoreRobberies 只被 HasRecentStoreRobbery 这个函数捕获，
-- handler 的 upvalue 里只有那个函数 → 再往下一层找
local recent = nil
local helper = upvalueOf('qb-storerobbery:server:setSafeStatus', 'HasRecentStoreRobbery')
if helper then
    for index = 1, 20 do
        local name, value = debug.getupvalue(helper, index)
        if not name then break end
        if name == 'recentStoreRobberies' then recent = value break end
    end
end
emit('RECENT_TABLE_FOUND', tostring(recent ~= nil))
if recent then recent[safeKey] = { citizenid = 'TESTCID', at = GetGameTimer() } end
state.coords = vector3(anchorSafe.x, anchorSafe.y, anchorSafe.z)
fireAs(1, 'qb-storerobbery:server:setSafeStatus', safeKey)
emit('SAFE_ROBBED_RECENT', tostring(Config.Safes[safeKey].robbed))

emit('SCENARIO', 'done')
io.write(table.concat(OUT, '\n'), '\n')
