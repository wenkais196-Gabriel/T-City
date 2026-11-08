-- tests/unit/layer3_business/fixtures/vehicleshop_probe.lua
-- 真加载 qb-vehicleshop 的 config.lua + server/bus.lua + server/finance-lifecycle.lua。
-- 覆盖：试驾生成回调、试驾载具删除、换展车、员工发试驾、分期计时器归属、逾期检查。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local state = {
    callbacks = {},
    broadcasts = {},
    created = {},
    deleted = {},
    players = {},
    money = {},
}

local function makePlayer(source, jobName, onduty, citizenid)
    local player = {}
    player.PlayerData = {
        source = source,
        citizenid = citizenid or ('CID' .. source),
        license = 'LIC' .. source,
        job = { name = jobName or 'unemployed', onduty = onduty == true },
        metadata = { licences = { driver = true } },
        money = { cash = 100000, bank = 100000 },
    }
    player.Functions = {
        SetMetaData = function(key, value) player.PlayerData.metadata[key] = value end,
        RemoveMoney = function() return true end,
        AddMoney = function() return true end,
    }
    return player
end

local QBCoreMock = {
    Functions = {
        GetPlayer = function(source) return state.players[tonumber(source) or -1] end,
        GetQBPlayers = function()
            local list = {}
            for _, player in pairs(state.players) do list[#list + 1] = player end
            return list
        end,
        HasItem = function() return false end,
        CreateCallback = function(name, fn) state.callbacks[name] = fn end,
        Notify = function() end,
        GetDutyCount = function() return 0 end,
        CreateUseableItem = function() end,
    },
    Shared = {
        Vehicles = setmetatable({}, {
            __index = function(_, key)
                -- 只有测试里显式登记过的车型才算"存在"
                if state.vehicleModels[key] then
                    return { name = key, brand = 'test', model = key, price = 50000, type = 'automobile', category = 'sedan' }
                end
                return nil
            end,
        }),
        Items = setmetatable({}, { __index = function(_, key) return { label = tostring(key) } end }),
    },
    Commands = { Add = function() end },
}

state.vehicleModels = { ardent = true, schafter2 = true, adder = true, police = true, police = true }

local handlers = {}
RegisterNetEvent = function(name, fn) handlers[name] = fn end
RegisterServerEvent = RegisterNetEvent
AddEventHandler = function(name, fn) handlers[name] = fn end
TriggerClientEvent = function(name, target, ...)
    state.broadcasts[#state.broadcasts + 1] = { name = name, target = target, args = { ... } }
end
TriggerEvent = function() end
CreateThread = function(fn) if type(fn) == 'function' then end end
SetTimeout = function(_, fn) end
Wait = function() end
GetGameTimer = function() return 1000 end
os.time = os.time
GetConvar = function(_, default) return default end
GetPlayerName = function(source) return 'player' .. tostring(source) end
GetPlayerPed = function(source) return source end
GetPlayerIdentifiers = function() return { 'license:abc' } end

local vectorMeta = {}
vectorMeta.__sub = function(a, b)
    return setmetatable({ x = (a.x or 0) - (b.x or 0), y = (a.y or 0) - (b.y or 0), z = (a.z or 0) - (b.z or 0) }, vectorMeta)
end
vectorMeta.__len = function(a) return math.sqrt((a.x or 0) ^ 2 + (a.y or 0) ^ 2 + (a.z or 0) ^ 2) end
local function vec3(x, y, z) return setmetatable({ x = x or 0.0, y = y or 0.0, z = z or 0.0 }, vectorMeta) end
local function vec4(x, y, z, w)
    local value = vec3(x, y, z)
    value.w = w
    value.xyz = vec3(x, y, z)
    return value
end
vector2 = function(x, y) return setmetatable({ x = x or 0.0, y = y or 0.0 }, vectorMeta) end
vector3 = vec3
vector4 = vec4
GetEntityCoords = function(entity) return state.coords or vec3(0.0, 0.0, 0.0) end

local ENTITIES = {}
CreateVehicleServerSetter = function(hash, vehType, x, y, z, w)
    local entity = 2000 + #state.created + 1
    ENTITIES[entity] = { hash = hash, coords = { x = x, y = y, z = z, w = w } }
    state.created[#state.created + 1] = { hash = hash, x = x, y = y, z = z }
    return entity
end
NetworkGetNetworkIdFromEntity = function(entity) return entity + 100 end
NetworkGetEntityFromNetworkId = function(netId) return netId - 100 end
DoesEntityExist = function(entity) return ENTITIES[entity] ~= nil end
DeleteEntity = function(entity) state.deleted[#state.deleted + 1] = entity; ENTITIES[entity] = nil end
SetVehicleNumberPlateText = function() end
GetVehicleTypeByModel = function() return 'automobile' end
GetHashKey = function(value) return 'hash:' .. tostring(value) end

Lang = { t = function(a, b) local key = type(a) == 'string' and a or b; return tostring(key) end }
json = { encode = function() return '{}' end, decode = function() return {} end }
MySQL = {
    query = { await = function() return {} end },
    single = { await = function() return nil end },
    scalar = { await = function() return 0 end },
    rawExecute = { await = function() return nil end },
    update = function() return 1 end,
    insert = function() return 1 end,
    Async = { execute = function() end },
}

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
    assert(load(source, '@' .. chunkname))()
end

load_lua(RES .. '/config.lua', 'config.lua')
load_lua(RES .. '/server/bus.lua', 'bus.lua')
load_lua(RES .. '/server/finance-lifecycle.lua', 'finance-lifecycle.lua')

local function fireAs(src, name, ...)
    _G.source = src
    local handler = handlers[name]
    if not handler then error('handler 未注册: ' .. name) end
    local ok, err = pcall(handler, ...)
    _G.source = nil
    if not ok then OUT[#OUT + 1] = 'HANDLER_ERROR|' .. name .. '|' .. tostring(err) end
    return ok
end

local function callCallback(name, src, ...)
    local fn = state.callbacks[name]
    if not fn then error('callback 未注册: ' .. name) end
    local packed = nil
    local function cb(...) packed = { ... } end
    local ok, err = pcall(fn, src, cb, ...)
    if not ok then OUT[#OUT + 1] = 'HANDLER_ERROR|' .. name .. '|' .. tostring(err) end
    return packed
end

state.players[1] = makePlayer(1, 'unemployed', false)       -- 平民
state.players[2] = makePlayer(2, 'cardealer', true)         -- 在职店员
state.players[3] = makePlayer(3, 'cardealer', false)        -- 下班店员

-- 找一家"展台里有登记车型"的车店，站在它的试驾点上（同一个车型可能在多家店展出）
local shopName, shop, showroomModel = nil, nil, nil
for name, cfg in pairs(Config.Shops) do
    for _, entry in pairs(cfg['ShowroomVehicles'] or {}) do
        if type(entry) == 'table' and state.vehicleModels[entry.chosenVehicle] then
            shopName, shop, showroomModel = name, cfg, entry.chosenVehicle
            break
        end
    end
    if shop then break end
end
assert(shop ~= nil, '配置文件里找不到可用的展车')
local spawnPoint = shop['TestDriveSpawn']
state.coords = vec3(spawnPoint.x, spawnPoint.y, spawnPoint.z)

-- ── 1. 试驾生成回调：展台没有的车型必须被拒 ──
emit('SCENARIO', 'spawn-not-in-showroom')
local out = callCallback('qb-vehicleshop:server:spawnvehicle', 1, 'TD123456', 'police', vec4(spawnPoint.x, spawnPoint.y, spawnPoint.z, 0.0))
emit('SPAWN_FOREIGN_MODEL_BLOCKED', tostring(out == nil or out[1] == nil))

-- ── 2. 坐标在 5 公里外 → 拒绝 ──
emit('SCENARIO', 'spawn-far')
out = callCallback('qb-vehicleshop:server:spawnvehicle', 1, 'TD123456', showroomModel, vec4(5000.0, 5000.0, 30.0, 0.0))
emit('SPAWN_FAR_BLOCKED', tostring(out == nil or out[1] == nil))

-- ── 3. 合法试驾 → 生成并记账 ──
emit('SCENARIO', 'spawn-ok')
out = callCallback('qb-vehicleshop:server:spawnvehicle', 1, 'TD123456', showroomModel, vec4(spawnPoint.x, spawnPoint.y, spawnPoint.z, 0.0))
local ownNetId = out and tonumber(out[1]) or nil
emit('SPAWN_OK', tostring(ownNetId ~= nil))

-- ── 4. deleteVehicle：别人不能删，自己能删 ──
emit('SCENARIO', 'delete')
local deletedBefore = #state.deleted
fireAs(2, 'qb-vehicleshop:server:deleteVehicle', ownNetId, 'TD123456')
emit('DELETE_FOREIGN_BLOCKED', tostring(#state.deleted == deletedBefore))
fireAs(1, 'qb-vehicleshop:server:deleteVehicle', ownNetId, 'TD123456')
emit('DELETE_OWN_ALLOWED', tostring(#state.deleted == deletedBefore + 1))
-- 重复删除（记录已清）：不该再删一次
local after = #state.deleted
fireAs(1, 'qb-vehicleshop:server:deleteVehicle', ownNetId, 'TD123456')
emit('DELETE_REPLAY_BLOCKED', tostring(#state.deleted == after))

-- ── 5. swapVehicle：只有在职店员能换展车 ──
emit('SCENARIO', 'swap')
local b = #state.broadcasts
fireAs(1, 'qb-vehicleshop:server:swapVehicle', { toVehicle = 'adder', ClosestVehicle = 1, ClosestShop = shopName })
emit('SWAP_CIVILIAN_BLOCKED', tostring(#state.broadcasts == b))
fireAs(3, 'qb-vehicleshop:server:swapVehicle', { toVehicle = 'adder', ClosestVehicle = 1, ClosestShop = shopName })
emit('SWAP_OFFDUTY_BLOCKED', tostring(#state.broadcasts == b))
fireAs(2, 'qb-vehicleshop:server:swapVehicle', { toVehicle = 'adder', ClosestVehicle = 1, ClosestShop = shopName })
emit('SWAP_DEALER_ALLOWED', tostring(#state.broadcasts > b))

-- ── 6. customTestDrive：非店员 / 非展台车型必须被拒 ──
emit('SCENARIO', 'custom-testdrive')
b = #state.broadcasts
fireAs(1, 'qb-vehicleshop:server:customTestDrive', showroomModel, 2)
emit('TESTDRIVE_CIVILIAN_BLOCKED', tostring(#state.broadcasts == b))
fireAs(2, 'qb-vehicleshop:server:customTestDrive', 'police', 1)
emit('TESTDRIVE_FOREIGN_MODEL_BLOCKED', tostring(#state.broadcasts == b))

-- ── 7. addPlayer：传别人的 citizenid 也只能动自己的计时器 ──
emit('SCENARIO', 'finance-timer')
fireAs(1, 'qb-vehicleshop:server:addPlayer', 'CID-VICTIM')
local timer = nil
for index = 1, 80 do
    local name, value = debug.getupvalue(handlers['qb-vehicleshop:server:addPlayer'], index)
    if not name then break end
    if name == 'financetimer' then timer = value end
end
emit('TIMER_VICTIM_UNTOUCHED', tostring(timer ~= nil and timer['CID-VICTIM'] == nil))
emit('TIMER_SELF_SET', tostring(timer ~= nil and timer['CID1'] ~= nil))

-- ── 8. checkFinance：player 不存在时不崩、且有冷却 ──
emit('SCENARIO', 'check-finance')
local okMissing = fireAs(99, 'qb-vehicleshop:server:checkFinance')
emit('CHECKFINANCE_MISSING_PLAYER_SAFE', tostring(okMissing))
local okFirst = fireAs(1, 'qb-vehicleshop:server:checkFinance')
local okSecond = fireAs(1, 'qb-vehicleshop:server:checkFinance')
emit('CHECKFINANCE_NO_CRASH', tostring(okFirst and okSecond))

emit('SCENARIO', 'done')
io.write(table.concat(OUT, '\n'), '\n')
