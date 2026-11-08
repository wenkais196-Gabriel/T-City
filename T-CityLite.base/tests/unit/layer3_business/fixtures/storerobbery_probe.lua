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

-- ── 1. callCops：客户端编坐标应被丢弃 ──
emit('SCENARIO', 'callcops-coords')
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

-- ── 2. 坏 kind / 坏 key 不崩 ──
emit('SCENARIO', 'callcops-bad-input')
fireAs(1, 'qb-storerobbery:server:callCops', 'nonsense', 1, 'X', fakeCoords)
fireAs(1, 'qb-storerobbery:server:callCops', 'cashier', 9999, 'X', fakeCoords)
fireAs(1, 'qb-storerobbery:server:callCops', nil, nil, nil, nil)

-- ── 3. setSafeStatus：站远处不能把保险箱标成已抢 ──
emit('SCENARIO', 'safe-remote')
local safeKey = 1
Config.Safes[safeKey].robbed = false
state.coords = vector3(9999.0, 9999.0, 9999.0)
fireAs(1, 'qb-storerobbery:server:setSafeStatus', safeKey)
emit('SAFE_ROBBED_REMOTE', tostring(Config.Safes[safeKey].robbed))

emit('SCENARIO', 'safe-close')
local anchor = Config.Safes[safeKey][1]
state.coords = vector3(anchor.x, anchor.y, anchor.z)
fireAs(1, 'qb-storerobbery:server:setSafeStatus', safeKey)
emit('SAFE_ROBBED_CLOSE', tostring(Config.Safes[safeKey].robbed))

emit('SCENARIO', 'done')
io.write(table.concat(OUT, '\n'), '\n')
