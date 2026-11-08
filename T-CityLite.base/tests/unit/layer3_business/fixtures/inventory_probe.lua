-- tests/unit/layer3_business/fixtures/inventory_probe.lua
-- 真加载 qb-inventory 的 config/*.lua + server/main.lua，mock FiveM/oxmysql/state bag。
-- 覆盖：UpdateObject 的来源判定、售货机、关界面、用物品、掉落物打开与挪动、雪球冷却。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local clock = 1000000
os = setmetatable({ time = function() return clock end, date = os.date }, { __index = os })

local state = {
    coreFetches = 0,
    shops = {},
    shopOpened = nil,
    itemBoxes = {},
    playerInventoryOpened = nil,
    players = {},
    snowballs = 0,
    usedItems = {},
}

local function makePlayer(source, citizenid)
    local player = {}
    player.PlayerData = {
        source = source,
        citizenid = citizenid or ('CID' .. source),
        license = 'LIC' .. source,
        job = { name = 'unemployed', onduty = false },
        metadata = {},
        money = { cash = 1000, bank = 1000 },
        items = {},
    }
    player.Functions = {
        SetMetaData = function(key, value) player.PlayerData.metadata[key] = value end,
        RemoveMoney = function() return true end,
        AddMoney = function() return true end,
        SetInventory = function() end,
    }
    player.state = { inv_busy = false }
    return player
end

local QBCoreMock = {
    Functions = {
        GetPlayer = function(source) return state.players[tonumber(source) or -1] end,
        GetPlayers = function() return {} end,
        GetQBPlayers = function() return {} end,
        HasPermission = function() return false end,
        CreateCallback = function(name, fn) state.callbacks = state.callbacks or {}; state.callbacks[name] = fn end,
        Notify = function() end,
        AddPlayerMethod = function() end,
    },
    Shared = {
        Items = setmetatable({}, {
            __index = function(_, key)
                return { name = key, label = tostring(key), weight = 1, type = 'item', image = key .. '.png', unique = false, useable = true }
            end,
        }),
        Vehicles = setmetatable({}, { __index = function() return { brand = 'x', model = 'x' } end }),
    },
    Commands = { Add = function() end },
}

local handlers = {}
RegisterNetEvent = function(name, fn) handlers[name] = fn end
RegisterServerEvent = RegisterNetEvent
AddEventHandler = function(name, fn) handlers[name] = fn end
TriggerClientEvent = function(name, target, ...)
    if name == 'qb-inventory:client:openInventory' then
        state.playerInventoryOpened = { target = target, args = { ... } }
    elseif name == 'qb-inventory:client:ItemBox' then
        state.itemBoxes[#state.itemBoxes + 1] = { target = target, args = { ... } }
    end
end
TriggerEvent = function() end
CreateThread = function() end
SetTimeout = function(_, fn) end
Wait = function() end
GetGameTimer = function() return clock end
GetConvar = function(_, default) return default end
GetPlayerName = function(source) return 'player' .. tostring(source) end
GetPlayerPed = function(source) return source end
GetPlayerIdentifiers = function() return { 'license:abc' } end
GetCurrentResourceName = function() return 'qb-inventory' end
GetInvokingResource = function() return nil end

local vectorMeta = {}
vectorMeta.__sub = function(a, b)
    return setmetatable({ x = (a.x or 0) - (b.x or 0), y = (a.y or 0) - (b.y or 0), z = (a.z or 0) - (b.z or 0) }, vectorMeta)
end
vectorMeta.__len = function(a) return math.sqrt((a.x or 0) ^ 2 + (a.y or 0) ^ 2 + (a.z or 0) ^ 2) end
local function vec3(x, y, z) return setmetatable({ x = x or 0.0, y = y or 0.0, z = z or 0.0 }, vectorMeta) end
vector2 = function(x, y) return { x = x, y = y } end
vector3 = vec3
vector4 = function(x, y, z, w) local v = vec3(x, y, z); v.w = w; return v end
state.coords = vec3(0.0, 0.0, 0.0)
-- 实体坐标：掉落物实体用自己的位置（模拟"包被实体带到哪就在哪"）
state.entityCoords = {}
GetEntityCoords = function(entity)
    if entity and state.entityCoords[entity] then return state.entityCoords[entity] end
    return state.coords
end
NetworkGetEntityFromNetworkId = function(netId) return netId end
NetworkGetNetworkIdFromEntity = function(entity) return entity end
DoesEntityExist = function() return true end
DeleteEntity = function() end
CreateObjectNoOffset = function() return 1 end
TaskPlayAnim = function() end
GetHashKey = function(value) return 'hash:' .. tostring(value) end
SetVehicleNumberPlateText = function() end

Lang = { t = function(a, b) local key = type(a) == 'string' and a or b; return tostring(key) end }
json = { encode = function() return '{}' end, decode = function() return {} end }

MySQL = {
    query = { await = function() return {} end },
    single = { await = function() return nil end },
    scalar = { await = function() return 0 end },
    prepare = function() end,
    update = function() return 1 end,
    insert = function() return 1 end,
    Async = { execute = function() end },
}

exports = setmetatable({}, {
    __call = function(_, name, fn) rawset(exports, name, fn) end,
    __index = function(_, name)
        if name == 'qb-core' then
            return {
                GetCoreObject = function()
                    state.coreFetches = state.coreFetches + 1
                    return QBCoreMock
                end,
            }
        end
        return setmetatable({}, { __index = function() return function() return true end end })
    end,
})

-- state bag 兼容：Player(src) 返回带 .state 的对象
local function PlayerHook(source) return state.players[tonumber(source) or -1] or { state = {} } end
Player = function(source) return PlayerHook(source) end

-- server/functions.lua 里的全局函数：main.lua 只在运行时调用它们，
-- 这里用桩代替（探针不加载 functions.lua，避免一大串 oxmysql/QBCore 依赖）
state.itemCalls = {}
function AddItem(src, item, amount, slot, info, reason)
    state.itemCalls[#state.itemCalls + 1] = { op = 'add', src = src, item = item, amount = amount }
    return true
end
function RemoveItem(src, item, amount, slot, reason)
    state.itemCalls[#state.itemCalls + 1] = { op = 'remove', src = src, item = item, amount = amount }
    return true
end
function GetItemBySlot(src, slot) return state.itemsBySlot and state.itemsBySlot[src] and state.itemsBySlot[src][slot] or nil end
function GetItemByName(src, item) return nil end
function checkWeapon() end
function UseItem() end
function GetInventory(src) return {} end
function CreateShop(data) state.shops[#state.shops + 1] = data end
function OpenShop(src, name) state.shopOpened = { src = src, name = name } end
function getItem() return nil end
function getIdentifier(_, src) return src end

local function load_lua(path, chunkname)
    local handle = assert(io.open(path, 'r'))
    local source = handle:read('a')
    handle:close()
    -- CfxLua 的反引号哈希（`model`）不是标准 Lua，先换成 GetHashKey
    source = source:gsub('`([A-Za-z0-9_]+)`', "GetHashKey('%1')")
    assert(load(source, '@' .. chunkname))()
end

load_lua(RES .. '/config/config.lua', 'config/config.lua')
if io.open(RES .. '/config/vehicles.lua', 'r') then
    load_lua(RES .. '/config/vehicles.lua', 'config/vehicles.lua')
end
load_lua(RES .. '/server/main.lua', 'main.lua')

local function fireAs(src, name, ...)
    _G.source = src
    local handler = handlers[name]
    if not handler then error('handler 未注册: ' .. name) end
    local ok, err = pcall(handler, ...)
    _G.source = nil
    if not ok then OUT[#OUT + 1] = 'HANDLER_ERROR|' .. name .. '|' .. tostring(err) end
    return ok
end

state.players[1] = makePlayer(1)
state.players[2] = makePlayer(2)

local function upvalue(handlerName, wanted)
    local handler = handlers[handlerName]
    if not handler then return nil end
    for index = 1, 120 do
        local name, value = debug.getupvalue(handler, index)
        if not name then break end
        if name == wanted then return value end
    end
    return nil
end

-- ── 1. UpdateObject：客户端触发必须无效（source 是数字 0，不是空串）──
emit('SCENARIO', 'update-object')
local before = state.coreFetches
fireAs(1, 'QBCore:Server:UpdateObject')
emit('UPDATE_OBJECT_CLIENT_BLOCKED', tostring(state.coreFetches == before))
fireAs(0, 'QBCore:Server:UpdateObject')
emit('UPDATE_OBJECT_SERVER_ALLOWED', tostring(state.coreFetches == before + 1))

-- ── 2. openVending：非表 / 远处 / 近处 ──
emit('SCENARIO', 'vending')
local okBad = fireAs(1, 'qb-inventory:server:openVending', 42)
emit('VENDING_BAD_DATA_SAFE', tostring(okBad))
state.coords = vec3(100.0, 100.0, 100.0)
local okFar = fireAs(1, 'qb-inventory:server:openVending', { coords = vec3(0.0, 0.0, 0.0) })
emit('VENDING_FAR_NO_CRASH', tostring(okFar))
state.coords = vec3(0.0, 0.0, 0.0)

-- ── 3. closeInventory：非字符串 / 非法 targetId ──
emit('SCENARIO', 'close')
emit('CLOSE_BAD_ID_SAFE', tostring(fireAs(1, 'qb-inventory:server:closeInventory', 42)))
emit('CLOSE_BAD_TARGET_SAFE', tostring(fireAs(1, 'qb-inventory:server:closeInventory', 'otherplayer-notanumber')))

-- ── 4. useItem：非表 ──
emit('SCENARIO', 'use-item')
emit('USE_ITEM_BAD_SAFE', tostring(fireAs(1, 'qb-inventory:server:useItem', 7)))

-- ── 5. openDrop / updateDrop：掉落物归属 ──
emit('SCENARIO', 'drop')
-- Drops 是 main.lua 的全局表（不是局部/upvalue）
local Drops = assert(Drops, 'Drops 表取不到')
Drops['drop-1001'] = {
    name = 'drop-1001', label = 'Drop', items = {}, entityId = 1001,
    createdTime = clock, owner = 1, coords = vec3(0.0, 0.0, 0.0),
    maxweight = 1000, slots = 10, isOpen = true, openedBy = 1, openedAt = clock,
}
-- 远处的 3 号玩家调 openDrop：他在距离校验处就被拒，**不能**因此刷新租约。
-- 判据落在"他之后，站在包旁边的 2 号能不能立刻接管"上（租约被远程续租的话，2 号会被挡 120 秒）。
state.players[3] = makePlayer(3)
clock = clock + 130                       -- 租约已过期，允许接管
state.coords = vec3(500.0, 500.0, 0.0)
fireAs(3, 'qb-inventory:server:openDrop', 'drop-1001')
state.coords = vec3(0.5, 0.5, 0.0)
state.playerInventoryOpened = nil
fireAs(2, 'qb-inventory:server:openDrop', 'drop-1001')
emit('DROP_TAKEOVER_NOT_STOLEN_BY_REMOTE', tostring(state.playerInventoryOpened ~= nil))

-- 2 号玩家站在旁边，但掉落物是 1 号刚打开的（租约是新的）→ 120 秒内不能被抢开
Drops['drop-1001'].openedBy = 1
Drops['drop-1001'].openedAt = clock
state.coords = vec3(0.5, 0.5, 0.0)
state.playerInventoryOpened = nil
fireAs(2, 'qb-inventory:server:openDrop', 'drop-1001')
emit('DROP_LOCKED_BY_OPENER', tostring(state.playerInventoryOpened == nil))
-- 过了 2 分钟 → 允许接管（防止一个人开完不关把掉落物锁死）
clock = clock + 200
fireAs(2, 'qb-inventory:server:openDrop', 'drop-1001')
emit('DROP_TAKEOVER_AFTER_TIMEOUT', tostring(state.playerInventoryOpened ~= nil))
-- 包实体在 (0,0,0)：把服务端坐标挪到自己脚下（远处）必须被拒
local originalCoords = Drops['drop-1001'].coords
state.entityCoords[1001] = vec3(0.0, 0.0, 0.0)
state.coords = vec3(5.0, 5.0, 0.0)
fireAs(2, 'qb-inventory:server:updateDrop', 'drop-1001', vec3(5.0, 5.0, 0.0))
emit('DROP_MOVE_FOREIGN_BLOCKED', tostring(Drops['drop-1001'].coords == originalCoords))
-- 实体就在声称坐标旁边，且玩家本人也站在那里（正常"捡起再放下"）→ 放行，哪怕不是创建者
state.entityCoords[1001] = vec3(1.0, 1.0, 0.0)
state.coords = vec3(1.2, 1.2, 0.0)
fireAs(2, 'qb-inventory:server:updateDrop', 'drop-1001', vec3(1.0, 1.0, 0.0))
emit('DROP_MOVE_CARRIER_ALLOWED', tostring(Drops['drop-1001'].coords ~= originalCoords))

-- ── 6. snowball：冷却 ──
emit('SCENARIO', 'snowball')
local okS1 = fireAs(1, 'qb-inventory:server:snowball', 'add')
local okS2 = fireAs(1, 'qb-inventory:server:snowball', 'add')
emit('SNOWBALL_NO_CRASH', tostring(okS1 and okS2))

emit('SCENARIO', 'done')
io.write(table.concat(OUT, '\n'), '\n')
