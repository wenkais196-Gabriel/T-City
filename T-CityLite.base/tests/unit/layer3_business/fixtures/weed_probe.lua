-- tests/unit/layer3_business/fixtures/weed_probe.lua
-- 真加载 qb-weed 的 config.lua + server/main.lua。
-- 重点：四个 handler 的参数/来源校验，以及 plantCache 的作用域修复（原来 handler 读的是全局 nil）。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local state = {
    players = {}, inserts = {}, deletes = {}, added = {}, removed = {}, broadcasts = {}, callbacks = {},
}

local function makePlayer(source)
    local player = {}
    player.PlayerData = {
        source = source, citizenid = 'CID' .. source, name = 'p' .. source, license = 'LIC' .. source,
        job = { name = 'unemployed', onduty = false, grade = { level = 0 } },
        gang = { name = 'none', grade = { level = 0 } },
        metadata = {}, money = { cash = 1000, bank = 1000 },
        items = { { name = 'empty_weed_bag', amount = 50, slot = 1 } },
        charinfo = { firstname = 'T', lastname = 'P' },
    }
    player.Functions = {
        GetItemByName = function(name)
            if name == 'empty_weed_bag' then return { name = name, amount = 50, slot = 1 } end
            return nil
        end,
        AddItem = function() return true end,
        RemoveItem = function() return true end,
        Notify = function() end,
        SetMetaData = function() end,
    }
    return player
end

local QBCoreMock = {
    Functions = {
        GetPlayer = function(source) return state.players[tonumber(source) or -1] end,
        CreateCallback = function(name, fn) state.callbacks[name] = fn end,
        CreateUseableItem = function() end,
        HasPermission = function() return false end,
    },
    Shared = { Items = setmetatable({}, { __index = function() return {} end }) },
    Commands = { Add = function() end },
}
QBCore = QBCoreMock

local handlers = {}
RegisterNetEvent = function(name, fn) handlers[name] = fn end
RegisterServerEvent = RegisterNetEvent
AddEventHandler = function(name, fn) handlers[name] = fn end
RegisterCommand = function() end
TriggerClientEvent = function(name, target, arg1) state.broadcasts[#state.broadcasts + 1] = { name = name, target = target, arg1 = arg1 } end
TriggerEvent = function() end
CreateThread = function(fn) state.thread = fn end
Wait = function() end
GetGameTimer = function() return 1000 end
GetCurrentResourceName = function() return 'qb-weed' end
GetPlayerName = function(source) return 'player' .. tostring(source) end

vector2 = function(x, y) return { x = x, y = y } end
vector3 = function(x, y, z) return { x = x or 0.0, y = y or 0.0, z = z or 0.0 } end
vector4 = function(x, y, z, w) return { x = x or 0.0, y = y or 0.0, z = z or 0.0, w = w or 0.0 } end

Lang = { t = function(a, b) local key = type(a) == 'string' and a or b; return tostring(key) end }
json = {
    encode = function(value)
        if type(value) ~= 'table' then return tostring(value) end
        return string.format('{"x":%s,"y":%s,"z":%s}', tostring(value.x or 0), tostring(value.y or 0), tostring(value.z or 0))
    end,
    decode = function(text)
        if type(text) ~= 'string' then return nil end
        local x, y, z = text:match('"x":([%-%d%.]+),"y":([%-%d%.]+),"z":([%-%d%.]+)')
        if not x then return nil end
        return { x = tonumber(x), y = tonumber(y), z = tonumber(z) }
    end,
}
MySQL = {
    insert = function(query, params) state.inserts[#state.inserts + 1] = { query = query, params = params } end,
    update = function() end,
    query = setmetatable({
        await = function() return {} end,
    }, {
        __call = function(_, query, params, cb)
            if query:find('DELETE', 1, true) then
                state.deletes[#state.deletes + 1] = { query = query, params = params }
            end
            if type(cb) == 'function' then cb({}) end
        end,
    }),
}
exports = setmetatable({}, {
    __call = function(_, name, fn) rawset(exports, name, fn) end,
    __index = function(_, name)
        if name == 'qb-core' then return { GetCoreObject = function() return QBCoreMock end } end
        if name == 'qb-inventory' then
            return {
                AddItem = function(_, src, item, amount) state.added[#state.added + 1] = { src = src, item = item, amount = amount } return true end,
                RemoveItem = function(_, src, item, amount) state.removed[#state.removed + 1] = { src = src, item = item, amount = amount } return true end,
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
    source = source:gsub('(%w+)%s*%+=%s*', '%1 = %1 + ')
    assert(load(source, '@' .. chunkname))()
end

load_lua(RES .. '/config.lua', 'config.lua')
load_lua(RES .. '/server/main.lua', 'server/main.lua')

local function fire(src, name, ...)
    local handler = handlers[name] or error('handler 未注册: ' .. name)
    _G.source = src
    local ok, err = pcall(handler, ...)
    _G.source = nil
    if not ok then OUT[#OUT + 1] = 'HANDLER_ERROR|' .. name .. '|' .. tostring(err) end
    return ok
end

state.players[1] = makePlayer(1)

local plantName = nil
for name in pairs(QBWeed.Plants) do plantName = name break end
assert(plantName, 'QBWeed.Plants 为空')
local coordsJson = json.encode({ x = 100.0, y = 200.0, z = 30.0 })
local house = 'probe_house'

-- ── 1. 正常种植 ──
emit('SCENARIO', 'place')
state.inserts = {}
fire(1, 'qb-weed:server:placePlant', coordsJson, plantName, house)
emit('PLACE_OK', tostring(#state.inserts == 1))

-- ── 2. 坏参数：无 Player / 坏 sort / 坏坐标 / 坏 house ──
state.inserts = {}
local okNoPlayer = fire(999, 'qb-weed:server:placePlant', coordsJson, plantName, house)
local okBadSort = fire(1, 'qb-weed:server:placePlant', coordsJson, 'not_a_plant', house)
local okBadCoords = fire(1, 'qb-weed:server:placePlant', 'not-json', plantName, house)
local okBadHouse = fire(1, 'qb-weed:server:placePlant', coordsJson, plantName, nil)
emit('PLACE_BAD_ARGS_BLOCKED', tostring(#state.inserts == 0
    and okNoPlayer and okBadSort and okBadCoords and okBadHouse))

-- ── 3. 单屋上限 ──
state.inserts = {}
for _ = 1, 40 do fire(1, 'qb-weed:server:placePlant', coordsJson, plantName, house) end
emit('PLACE_HOUSE_CAP', tostring(#state.inserts <= 20))

-- ── 4. 删除：未登记的 plantId 不能删 ──
emit('SCENARIO', 'remove')
state.deletes = {}
fire(1, 'qb-weed:server:removeDeathPlant', house, 123456)
emit('REMOVE_UNKNOWN_BLOCKED', tostring(#state.deletes == 0))

-- 4b. **本次会话刚种下的**植株必须能铲掉：plantid 在 DB 里是 varchar(50)，
--     客户端拿到的是字符串 —— 缓存键若用 math.random 的数字就会 miss。
--     （state.inserts 里最后一条 insert 的 params[5] 就是刚生成的 plantid）
local freshInsert = state.inserts[#state.inserts]
local freshPlantId = freshInsert and freshInsert.params and freshInsert.params[5]
-- 注意顺序：收获会把植株从缓存里删掉，所以先测收获、再测铲除
state.added = {}
state.removed = {}
fire(1, 'qb-weed:server:harvestPlant', house, 2, plantName, freshPlantId)
local harvested = false
for _, entry in ipairs(state.removed) do
    if entry.item == 'empty_weed_bag' then harvested = true end
end
emit('HARVEST_FRESH_PLANT_OK', tostring(type(freshPlantId) == 'string' and harvested))

state.deletes = {}
fire(1, 'qb-weed:server:removeDeathPlant', house, freshPlantId)
-- 已经被收获删掉的植株不该再删一次（这条同时验证 harvest 真的清了缓存）
emit('REMOVE_FRESH_PLANT_OK', tostring(type(freshPlantId) == 'string' and #state.deletes == 0))

-- ── 5. 收获：amount 夹取，无 Player 不崩 ──
emit('SCENARIO', 'harvest')
local plantedId = state.inserts[1] and 1 or nil
local okHarvestNoPlayer = fire(999, 'qb-weed:server:harvestPlant', house, 999, plantName, 1)
state.added = {}
state.removed = {}
fire(1, 'qb-weed:server:harvestPlant', house, 999, plantName, 1)
local seedAdd = nil
for _, entry in ipairs(state.added) do
    if type(entry.item) == 'string' and entry.item:find('_seed', 1, true) then seedAdd = entry end
end
emit('HARVEST_AMOUNT_CLAMPED', tostring(okHarvestNoPlayer
    and (seedAdd == nil or (seedAdd.amount >= 1 and seedAdd.amount <= 6))))

local okHarvestBadPlant = fire(1, 'qb-weed:server:harvestPlant', house, 1, 'not_a_plant', 1)
emit('HARVEST_BAD_PLANT_SAFE', tostring(okHarvestBadPlant))

-- 5b. 用**别人的 house** 收获同一个 plantid：必须什么都不发（缓存命中也要核归属）
state.added = {}
state.removed = {}
state.inserts = {}
fire(1, 'qb-weed:server:placePlant', coordsJson, plantName, 'other_house')
local foreignInsert = state.inserts[#state.inserts]
local foreignPlantId = foreignInsert and foreignInsert.params and foreignInsert.params[5]
state.added = {}
state.removed = {}
fire(1, 'qb-weed:server:harvestPlant', house, 2, plantName, foreignPlantId)
local leaked = #state.removed > 0
for _, entry in ipairs(state.added) do
    if type(entry.item) == 'string' and entry.item:find('weed_', 1, true) then leaked = true end
end
emit('HARVEST_WRONG_HOUSE_BLOCKED', tostring(not leaked))

-- ── 6. 施肥：坏 plantName 不崩（原来直接 nil 索引）──
emit('SCENARIO', 'food')
local okFoodBadPlant = fire(1, 'qb-weed:server:foodPlant', house, 5, 'not_a_plant', 1)
local okFoodNoAmount = fire(1, 'qb-weed:server:foodPlant', house, nil, plantName, 1)
emit('FOOD_BAD_ARGS_SAFE', tostring(okFoodBadPlant and okFoodNoAmount))

emit('SCENARIO', 'done')
io.write(table.concat(OUT, '\n'), '\n')
