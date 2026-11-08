-- tests/unit/layer3_business/fixtures/mechanic_probe.lua
-- 真加载 qb-mechanicjob 的 config.lua + const.lua + server/main.lua。
-- 重点：喷漆只能由"本店员工 + 在本店喷漆位旁 + 车在附近"触发；removeItem 的 part/amount 有界。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local state = { players = {}, vehicleCoords = { x = 0.0, y = 0.0, z = 0.0 }, broadcasts = {}, removed = {}, frozen = {} }

local function makePlayer(source, jobName, onduty)
    local player = {}
    player.PlayerData = {
        source = source, citizenid = 'CID' .. source, name = 'p' .. source, license = 'LIC' .. source,
        job = { name = jobName or 'unemployed', onduty = onduty == true, grade = { level = 4 } },
        gang = { name = 'none', grade = { level = 0 } },
        metadata = {}, money = { cash = 1000, bank = 1000 }, items = {},
        charinfo = { firstname = 'T', lastname = 'P' },
    }
    player.Functions = {
        RemoveItem = function(name, amount) return true end,
        AddItem = function() return true end,
        Notify = function() end,
        SetMetaData = function() end,
    }
    return player
end

local QBCoreMock = {
    Functions = {
        GetPlayer = function(source) return state.players[tonumber(source) or -1] end,
        HasPermission = function() return false end,
        GetIdentifier = function() return 'license:abc' end,
        CreateCallback = function() end,
        GetPlayers = function() return {} end,
        GetClosestVehicle = function() return 0, 999.0 end,
        CreateUseableItem = function() end,
    },
    Shared = {
        Items = {
            repairkit = { name = 'repairkit', label = 'Repair Kit' },
            advancedrepairkit = { name = 'advancedrepairkit', label = 'Advanced Repair Kit' },
            veh_armor = { name = 'veh_armor', label = 'Armor' },
            cleaningkit = { name = 'cleaningkit', label = 'Cleaning Kit' },
        },
        Vehicles = setmetatable({}, { __index = function() return { brand = 'x', name = 'y', type = 'automobile' } end }),
    },
    Commands = { Add = function() end },
}

local handlers = {}
RegisterNetEvent = function(name, fn) handlers[name] = fn end
RegisterServerEvent = RegisterNetEvent
AddEventHandler = function(name, fn) handlers[name] = fn end
RegisterCommand = function() end
TriggerClientEvent = function(name, target, ...) state.broadcasts[#state.broadcasts + 1] = { name = name, args = { ... } } end
TriggerEvent = function() end
CreateThread = function() end
SetTimeout = function(_, fn) end
Wait = function() end
GetCurrentResourceName = function() return 'qb-mechanicjob' end
GetPlayerName = function(source) return 'player' .. tostring(source) end
GetConvar = function(_, default) return default end
IsPlayerAceAllowed = function() return false end
GetGameTimer = function() return 1000 end
GetPlayers = function() return {} end
DropPlayer = function() end

local vectorMeta = {}
vectorMeta.__sub = function(a, b)
    return setmetatable({ x = (a.x or 0) - (b.x or 0), y = (a.y or 0) - (b.y or 0), z = (a.z or 0) - (b.z or 0) }, vectorMeta)
end
vectorMeta.__len = function(a) return math.sqrt((a.x or 0) ^ 2 + (a.y or 0) ^ 2 + (a.z or 0) ^ 2) end
local function vec3(x, y, z) return setmetatable({ x = x or 0.0, y = y or 0.0, z = z or 0.0 }, vectorMeta) end
vector2 = function(x, y) return { x = x, y = y } end
vector3 = vec3
vector4 = function(x, y, z, w) local v = vec3(x, y, z); v.w = w; return v end

local pedCoords = {}
GetPlayerPed = function(source) return source end
GetEntityCoords = function(entity)
    if entity == state.vehicle then return vec3(state.vehicleCoords.x, state.vehicleCoords.y, state.vehicleCoords.z) end
    local coords = pedCoords[entity]
    if coords then return vec3(coords.x, coords.y, coords.z) end
    return vec3(0.0, 0.0, 0.0)
end
NetworkGetEntityFromNetworkId = function(netId) if state.vehicle and netId == 777 then return state.vehicle end return 0 end
DoesEntityExist = function(entity) return entity == state.vehicle end
FreezeEntityPosition = function(entity, frozen) state.frozen[#state.frozen + 1] = frozen end
StartParticles = function() end
StopParticles = function() end
GetPaintTypeIndex = function(index) return tonumber(index) or 1 end
GetVehicleColours = function() return 0, 0 end
SetVehicleColours = function() end
GetVehicleCustomPrimaryColour = function() return 1, 2, 3 end
GetVehicleCustomSecondaryColour = function() return 4, 5, 6 end
TransitionVehicleColor = function() end

Lang = { t = function(a, b) local key = type(a) == 'string' and a or b; return tostring(key) end }
json = { encode = function() return '{}' end, decode = function() return {} end }
MySQL = {
    query = { await = function() return {} end },
    single = { await = function() return nil end },
    scalar = { await = function() return 0 end },
    insert = function() end,
    update = function() end,
}
exports = setmetatable({}, {
    __call = function(_, name, fn) rawset(exports, name, fn) end,
    __index = function(_, name)
        if name == 'qb-core' then return { GetCoreObject = function() return QBCoreMock end } end
        if name == 'qb-inventory' then
            return {
                RemoveItem = function(_, src, item, amount)
                    state.removed[#state.removed + 1] = { src = src, item = item, amount = amount }
                    return state.removeItemResult ~= false
                end,
                OpenInventory = function() end,
            }
        end
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

load_lua(RES .. '/config/config.lua', 'config/config.lua')
local okConst = pcall(load_lua, RES .. '/config/const.lua', 'config/const.lua')
load_lua(RES .. '/server/main.lua', 'server/main.lua')

local function fire(src, name, ...)
    local handler = handlers[name] or error('handler 未注册: ' .. name)
    _G.source = src
    local ok, err = pcall(handler, ...)
    _G.source = nil
    if not ok then OUT[#OUT + 1] = 'HANDLER_ERROR|' .. name .. '|' .. tostring(err) end
end

-- 找一家 managed 门店
local shopName, shop = nil, nil
for name, value in pairs(Config.Shops) do
    if value.managed and value.paint then shopName, shop = name, value break end
end
assert(shopName ~= nil, '没有 managed 且带 paint 的门店')

state.vehicle = 900
state.players[1] = makePlayer(1, 'unemployed', false)          -- 路人
state.players[2] = makePlayer(2, shopName, true)              -- 本店技工
state.players[3] = makePlayer(3, shopName, true)              -- 本店技工，但站得很远
pedCoords[2] = { x = shop.paint.x, y = shop.paint.y, z = shop.paint.z }

-- ── 1. 路人给别人的车喷漆 ──
emit('SCENARIO', 'spray-guards')
state.vehicleCoords = { x = shop.paint.x + 3.0, y = shop.paint.y, z = shop.paint.z }
state.broadcasts = {}
pedCoords[1] = { x = shop.paint.x + 3.0, y = shop.paint.y, z = shop.paint.z }
fire(1, 'qb-mechanicjob:server:sprayVehicle', 777, 1, 1, 1, 1, { primary = { 255, 0, 0 } })
emit('SPRAY_NON_MECHANIC_BLOCKED', tostring(#state.broadcasts == 0))

-- 技工但车在地图另一头
state.vehicleCoords = { x = 5000.0, y = 5000.0, z = 0.0 }
state.broadcasts = {}
fire(2, 'qb-mechanicjob:server:sprayVehicle', 777, 1, 1, 1, 1, { primary = { 255, 0, 0 } })
emit('SPRAY_FAR_VEHICLE_BLOCKED', tostring(#state.broadcasts == 0))

-- 技工在店里但 station 不在这家店（换个位置）
state.vehicleCoords = { x = shop.paint.x + 2.0, y = shop.paint.y, z = shop.paint.z }
state.broadcasts = {}
pedCoords[3] = { x = shop.paint.x + 500.0, y = shop.paint.y, z = shop.paint.z }
fire(3, 'qb-mechanicjob:server:sprayVehicle', 777, 1, 1, 1, 1, { primary = { 255, 0, 0 } })
emit('SPRAY_OFF_BOOTH_BLOCKED', tostring(#state.broadcasts == 0))

-- 正常：技工在喷漆位旁给身边的车喷
state.broadcasts = {}
fire(2, 'qb-mechanicjob:server:sprayVehicle', 777, 1, 1, 1, 1, { primary = { 255, 0, 0 } })
emit('SPRAY_ALLOWED', tostring(#state.broadcasts > 0))

-- colors 为 nil 不能打崩事件线程
state.broadcasts = {}
fire(2, 'qb-mechanicjob:server:sprayVehicle', 777)
emit('SPRAY_NIL_COLORS_SAFE', tostring(#state.broadcasts == 0))

-- ── 2. removeItem：顾客也会调，所以只做有界校验 ──
emit('SCENARIO', 'remove-item')
state.removed = {}
fire(1, 'qb-mechanicjob:server:removeItem', 'repairkit', 1)
emit('REMOVEITEM_VALID', tostring(#state.removed == 1 and state.removed[1].amount == 1))

state.removed = {}
fire(1, 'qb-mechanicjob:server:removeItem', 'not_a_real_item', 1)
emit('REMOVEITEM_UNKNOWN_BLOCKED', tostring(#state.removed == 0))

state.removed = {}
fire(1, 'qb-mechanicjob:server:removeItem', 'repairkit', -5)
emit('REMOVEITEM_NEGATIVE_CLAMPED', tostring(#state.removed == 1 and state.removed[1].amount == 1))

state.removed = {}
fire(1, 'qb-mechanicjob:server:removeItem', 'repairkit', 9999)
emit('REMOVEITEM_HUGE_CLAMPED', tostring(#state.removed == 1 and state.removed[1].amount == 10))

state.removed = {}
fire(1, 'qb-mechanicjob:server:removeItem', 'repairkit', 'x')
emit('REMOVEITEM_BAD_AMOUNT_DEFAULT', tostring(#state.removed == 1 and state.removed[1].amount == 1))

emit('SCENARIO', 'done')
io.write(table.concat(OUT, '\n'), '\n')
