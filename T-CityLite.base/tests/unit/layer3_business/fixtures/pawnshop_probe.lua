-- tests/unit/layer3_business/fixtures/pawnshop_probe.lua
-- 真加载 qb-pawnshop 的 config.lua + server/main.lua。
-- 重点：卖出单价、熔炼配方与奖励都必须来自**服务端**配置，不能采信客户端参数。

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
    money = {},
    added = {},
    removed = {},
    startMelting = nil,
    players = {},
    hasItem = true,
    coords = nil,
}

local function makePlayer(source)
    local player = {}
    player.PlayerData = {
        source = source, citizenid = 'CID' .. source, license = 'LIC' .. source,
        job = { name = 'unemployed', onduty = false }, metadata = {},
        money = { cash = 1000, bank = 1000 }, items = {},
    }
    player.Functions = { SetMetaData = function() end, AddMoney = function() end }
    return player
end

local QBCoreMock = {
    Functions = {
        GetPlayer = function(source) return state.players[tonumber(source) or -1] end,
        CreateCallback = function(name, fn) state.callbacks = state.callbacks or {}; state.callbacks[name] = fn end,
        HasPermission = function() return false end,
    },
    Shared = { Items = setmetatable({}, { __index = function(_, k) return { label = tostring(k) } end }) },
    Commands = { Add = function() end },
}

local handlers = {}
RegisterNetEvent = function(name, fn) handlers[name] = fn end
RegisterServerEvent = RegisterNetEvent
AddEventHandler = function(name, fn) handlers[name] = fn end
TriggerClientEvent = function(name, target, ...)
    if name == 'qb-pawnshop:client:startMelting' then
        state.startMelting = { target = target, args = { ... } }
    end
end
TriggerEvent = function() end
CreateThread = function() end
Wait = function() end
GetGameTimer = function() return 1000 end
GetConvar = function(_, default) return default end
GetPlayerName = function(source) return 'player' .. tostring(source) end
GetPlayerPed = function(source) return source end
Lang = { t = function(a, b) local key = type(a) == 'string' and a or b; return tostring(key) end }
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
GetEntityCoords = function() return state.coords or vec3(0.0, 0.0, 0.0) end

exports = setmetatable({}, {
    __call = function(_, name, fn) rawset(exports, name, fn) end,
    __index = function(_, name)
        if name == 'qb-core' then return { GetCoreObject = function() return QBCoreMock end } end
        if name == 'custom-main' then
            return {
                CheckRateLimit = function() return true end,
                AddScaledMoney = function(_, src, account, amount, reason)
                    state.money[#state.money + 1] = { src = src, account = account, amount = amount, reason = reason }
                    return amount
                end,
            }
        end
        if name == 'qb-inventory' then
            return {
                AddItem = function(_, src, item, amount)
                    state.added[#state.added + 1] = { src = src, item = item, amount = amount }
                    return true
                end,
                RemoveItem = function(_, src, item, amount)
                    state.removed[#state.removed + 1] = { src = src, item = item, amount = amount }
                    return state.hasItem
                end,
            }
        end
        if name == 'custom-crime' then
            return { LaunderMoney = function(_, src, amount) state.launder = { src = src, amount = amount } end }
        end
        if name == 'qb-log' then return { CreateLog = function() end } end
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
GetHashKey = function(value) return 'hash:' .. tostring(value) end
MySQL = {
    query = { await = function() return {} end },
    single = { await = function() return nil end },
    scalar = { await = function() return 0 end },
    insert = function() end,
    update = function() end,
}

load_lua(RES .. '/config.lua', 'config.lua')
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

-- 站到当铺门口（Config.PawnLocation 第一项）
local pawnCoords = nil
for _, value in pairs(Config.PawnLocation) do pawnCoords = value.coords; break end
state.coords = vec3(pawnCoords.x, pawnCoords.y, pawnCoords.z)

local pawnEntry = Config.PawnItems[1]
local meltEntry = Config.MeltingItems[1]

-- ── 1. sellPawnItems：单价必须用服务端配置，不认客户端传的价格 ──
emit('SCENARIO', 'sell')
state.money = {}
state.removed = {}
fireAs(1, 'qb-pawnshop:server:sellPawnItems', pawnEntry.item, 2, 1000000)
emit('SELL_REMOVED', tostring(#state.removed == 1 and state.removed[1].amount == 2))
local paid = state.money[1] and state.money[1].amount or -1
emit('SELL_PAID_CONFIG_PRICE', tostring(paid == pawnEntry.price * 2))

state.money = {}
state.removed = {}
fireAs(1, 'qb-pawnshop:server:sellPawnItems', pawnEntry.item, 99999, pawnEntry.price)
emit('SELL_AMOUNT_CAPPED', tostring(#state.removed == 0 and #state.money == 0))

state.money = {}
state.removed = {}
fireAs(1, 'qb-pawnshop:server:sellPawnItems', 'not-a-pawn-item', 1, 100)
emit('SELL_UNKNOWN_ITEM_REJECTED', tostring(#state.removed == 0 and #state.money == 0))

-- ── 2. meltItemRemove：耗时用服务端配置，客户端提交的条目被忽略 ──
emit('SCENARIO', 'melt')
state.startMelting = nil
fireAs(1, 'qb-pawnshop:server:meltItemRemove', meltEntry.item, 3, { item = meltEntry.item, time = 1000, rewards = {} })
local sentEntry = state.startMelting and state.startMelting.args[1] or nil
local sentAmount = state.startMelting and state.startMelting.args[2] or nil
emit('MELT_USES_SERVER_ENTRY', tostring(type(sentEntry) == 'table' and sentEntry.meltTime == meltEntry.meltTime))
emit('MELT_AMOUNT_PASSED', tostring(sentAmount == 3))

state.startMelting = nil
fireAs(1, 'qb-pawnshop:server:meltItemRemove', 'not-a-melt-item', 1, meltEntry)
emit('MELT_UNKNOWN_ITEM_REJECTED', tostring(state.startMelting == nil))

-- ── 3. pickupMelted：只发服务端登记的待取回批次 ──
emit('SCENARIO', 'pickup')
state.added = {}
-- ① 什么都没熔（没有待取回批次）+ 客户端伪造 payload → 一件都不发
fireAs(1, 'qb-pawnshop:server:pickupMelted', {
    items = {
        { amount = 100, item = { item = meltEntry.item, reward = { { item = 'goldbar', amount = 99999 } } } },
    },
})
emit('PICKUP_WITHOUT_MELT_GIVES_NOTHING', tostring(#state.added == 0))

-- ② 正常熔炼一批（meltEntry.meltTime 分钟 × 1 件）→ 未到时间取不到
state.startMelting = nil
fireAs(1, 'qb-pawnshop:server:meltItemRemove', meltEntry.item, 1, meltEntry)
state.added = {}
fireAs(1, 'qb-pawnshop:server:pickupMelted')
emit('PICKUP_BEFORE_READY_GIVES_NOTHING', tostring(#state.added == 0))

-- ③ 把时间拨到熔炼完成之后 → 按服务端配方发奖一次
local waitSeconds = math.max(1, math.floor((tonumber(meltEntry.meltTime) or 0) * 60)) + 5
clock = clock + waitSeconds
state.added = {}
fireAs(1, 'qb-pawnshop:server:pickupMelted')
local expected = 0
for _, reward in pairs(meltEntry.rewards) do expected = expected + (reward.amount or 0) end
local got = 0
for _, add in ipairs(state.added) do got = got + (add.amount or 0) end
emit('PICKUP_PAYS_CONFIG_REWARDS', tostring(got == expected))

-- ④ 同一批只能领一次
state.added = {}
fireAs(1, 'qb-pawnshop:server:pickupMelted')
emit('PICKUP_SECOND_TIME_GIVES_NOTHING', tostring(#state.added == 0))

emit('SCENARIO', 'done')
io.write(table.concat(OUT, '\n'), '\n')
