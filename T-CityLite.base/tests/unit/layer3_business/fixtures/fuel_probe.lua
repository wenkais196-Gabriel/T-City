-- tests/unit/layer3_business/fixtures/fuel_probe.lua
-- 真加载 qb-fuel 的 config.lua + server/main.lua。
-- 重点：升数/桶内油量由服务端复算，且只能在加油站附近交易。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local state = { players = {}, callbacks = {}, coords = { x = 9999.0, y = 9999.0, z = 0.0 }, money = 100000, removed = {} }

local function makePlayer(source)
    local player = {}
    player.PlayerData = {
        source = source, citizenid = 'CID' .. source,
        money = setmetatable({ cash = state.money, bank = state.money }, {
            __index = function(t, key) return rawget(t, key) end,
        }),
        job = { name = 'unemployed', onduty = false, grade = { level = 0 } },
        gang = { name = 'none' }, metadata = {}, items = {},
    }
    player.Functions = {
        RemoveMoney = function(moneyType, amount, reason)
            state.removed[#state.removed + 1] = { moneyType = moneyType, amount = amount, reason = reason }
            if amount <= 0 then return false end
            if player.PlayerData.money[moneyType] < amount then return false end
            player.PlayerData.money[moneyType] = player.PlayerData.money[moneyType] - amount
            return true
        end,
        GetItemByName = function(name)
            if state.itemName == name then return state.item end
            return nil
        end,
        RemoveItem = function(name, amount, slot) state.removedItem = { name = name, amount = amount, slot = slot } return true end,
        AddItem = function(name, amount, slot, info) state.addedItem = { name = name, amount = amount, slot = slot, info = info } return true end,
        Notify = function(message, kind) state.notified = kind end,
    }
    return player
end

local QBCoreMock = {
    Functions = {
        GetPlayer = function(source) return state.players[tonumber(source) or -1] end,
        CreateCallback = function(name, fn) state.callbacks[name] = fn end,
        HasPermission = function() return false end,
    },
    Shared = { Items = setmetatable({}, { __index = function() return {} end }) },
    Commands = { Add = function() end },
}

local callbacks = {}
local handlers = {}
RegisterNetEvent = function(name, fn) handlers[name] = fn end
RegisterServerEvent = RegisterNetEvent
AddEventHandler = function(name, fn) handlers[name] = fn end
TriggerClientEvent = function() end
TriggerEvent = function() end
CreateThread = function() end
Wait = function() end
GetPlayerName = function(source) return 'player' .. tostring(source) end
GetPlayerPed = function(source) return source end
GetConvar = function(_, default) return default end

local vectorMeta = {}
vectorMeta.__sub = function(a, b)
    return setmetatable({ x = (a.x or 0) - (b.x or 0), y = (a.y or 0) - (b.y or 0), z = (a.z or 0) - (b.z or 0) }, vectorMeta)
end
vectorMeta.__len = function(a) return math.sqrt((a.x or 0) ^ 2 + (a.y or 0) ^ 2 + (a.z or 0) ^ 2) end
local function vec3(x, y, z) return setmetatable({ x = x or 0.0, y = y or 0.0, z = z or 0.0 }, vectorMeta) end
vector2 = function(x, y) return { x = x, y = y } end
vector3 = vec3
vector4 = function(x, y, z, w) local v = vec3(x, y, z); v.w = w; return v end
GetEntityCoords = function() return state.coords end

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
    source = source:gsub('`([A-Za-z0-9_]+)`', "GetHashKey('%1')")
    assert(load(source, '@' .. chunkname))()
end

QBCore = QBCoreMock
load_lua(RES .. '/Config.lua', 'Config.lua')   -- 注意 qb-fuel 的配置文件名是大写 C（CI 在 Linux 上跑，大小写敏感）
load_lua(RES .. '/server/main.lua', 'server/main.lua')

local function fire(name, ...)
    local handler = handlers[name] or error('handler 未注册: ' .. name)
    _G.source = 1
    local ok, err = pcall(handler, ...)
    _G.source = nil
    if not ok then OUT[#OUT + 1] = 'HANDLER_ERROR|' .. name .. '|' .. tostring(err) end
end

state.players[1] = makePlayer(1)

local refill = nil
for name, fn in pairs({}) do refill = fn end
-- 回调在 `state.callbacks` 里（CreateCallback 的桩）
refill = state.callbacks['qb-fuel:server:refillVehicle'] or error('refillVehicle 回调未注册')

local function callRefill(litres)
    local result
    local ok, err = pcall(refill, 1, function(value) result = value end, litres)
    if not ok then OUT[#OUT + 1] = 'HANDLER_ERROR|refillVehicle|' .. tostring(err) end
    return result
end

local function moveToStation(distance)
    local station = Config.GasStations[1]
    state.coords = vec3(station.x + (distance or 0.0), station.y, station.z)
end

-- ── 1. 不在加油站不能加油 ──
emit('SCENARIO', 'station-range')
state.coords = vec3(0.0, 0.0, 0.0)
state.removed = {}
emit('REFILL_FAR_BLOCKED', tostring(callRefill(50) == false and #state.removed == 0))

moveToStation(3.0)
state.removed = {}
local okNear = callRefill(50)
emit('REFILL_NEAR_ALLOWED', tostring(okNear == true and #state.removed == 1 and state.removed[1].amount == 50 * Config.FuelPrice))

-- ── 2. 负数 / 坏类型 / 天文数字 ──
state.removed = {}
emit('REFILL_NEGATIVE_BLOCKED', tostring(callRefill(-50) == false and #state.removed == 0))
emit('REFILL_STRING_NUMERIC_ALLOWED', tostring(callRefill('50') == true))   -- '50' 经 tonumber 是合法数字
emit('REFILL_GARBAGE_STRING_BLOCKED', tostring(callRefill('abc') == false))
emit('REFILL_TABLE_BLOCKED', tostring(callRefill({}) == false))

state.removed = {}
callRefill(99999)
emit('REFILL_CLAMPED_TO_300', tostring(#state.removed == 1 and state.removed[1].amount == 300 * Config.FuelPrice))

-- ── 3. 油桶：只能减不能加 ──
emit('SCENARIO', 'jerry-can')
state.itemName = 'weapon_petrolcan'
state.item = { name = 'weapon_petrolcan', slot = 3, info = { fuel = 10, ammo = 10 } }
state.addedItem = nil
state.notified = nil
fire('qb-fuel:server:setCanFuel', 40)          -- 想白加到满
emit('CAN_INCREASE_BLOCKED', tostring(state.addedItem == nil and state.notified == 'error'))

state.item.info = { fuel = 25, ammo = 25 }
state.addedItem = nil
fire('qb-fuel:server:setCanFuel', 5)           -- 正常倒油扣减
emit('CAN_DECREASE_ALLOWED', tostring(state.addedItem and state.addedItem.info.fuel == 5))

state.item.info = { fuel = 25, ammo = 25 }
state.addedItem = nil
fire('qb-fuel:server:setCanFuel', -999)
emit('CAN_NEGATIVE_CLAMPED', tostring(state.addedItem and state.addedItem.info.fuel == 0))

-- info 缺失的老油桶：不能抛错，补油要付钱
state.item.info = nil
state.removed = {}
fire('qb-fuel:server:refillJerryCan')
emit('CAN_REFILL_NO_INFO_SAFE', tostring(state.addedItem and state.addedItem.info
    and state.addedItem.info.fuel == Config.JerryCanLitre and #state.removed == 1))

-- 不在加油站时买/补油桶都被拒
state.coords = vec3(0.0, 0.0, 0.0)
state.item.info = { fuel = 0, ammo = 0 }
state.removed = {}
state.addedItem = nil
fire('qb-fuel:server:refillJerryCan')
emit('CAN_REFILL_FAR_BLOCKED', tostring(#state.removed == 0 and state.addedItem == nil))

state.removed = {}
state.addedItem = nil
fire('qb-fuel:server:buyJerryCan')
emit('CAN_BUY_FAR_BLOCKED', tostring(#state.removed == 0 and state.addedItem == nil))

emit('SCENARIO', 'done')
io.write(table.concat(OUT, '\n'), '\n')
