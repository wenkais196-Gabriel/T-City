-- tests/unit/layer3_business/fixtures/shops_probe.lua
-- 真加载 qb-shops 的 config.lua + server/main.lua。
-- 重点：补货工资/工资事件不能被客户端循环触发；库存扣减的 slot/amount 有界。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local state = {
    players = {}, coords = { x = 0.0, y = 0.0, z = 0.0 }, now = 1000,
    paid = {}, broadcasts = {}, added = {}, saved = 0, rep = {},
}

local function makePlayer(source)
    local player = {}
    player.PlayerData = {
        source = source, citizenid = 'CID' .. source, name = 'p' .. source, license = 'LIC' .. source,
        job = { name = 'unemployed', onduty = false, grade = { level = 0 } },
        gang = { name = 'none', grade = { level = 0 } },
        metadata = {}, money = { cash = 10000, bank = 10000 }, items = {},
        charinfo = { firstname = 'T', lastname = 'P' },
    }
    player.Functions = {
        AddMoney = function(moneyType, amount, reason)
            state.paid[#state.paid + 1] = { moneyType = moneyType, amount = amount, reason = reason }
            return true
        end,
        RemoveMoney = function() return true end,
        AddItem = function() return true end,
        RemoveItem = function() return true end,
        AddRep = function(rep, amount) state.rep[#state.rep + 1] = { rep = rep, amount = amount } return true end,
        GetRep = function() return 0 end,
        Notify = function() end,
        SetMetaData = function() end,
    }
    return player
end

local QBCoreMock = {
    Functions = {
        GetPlayer = function(source) return state.players[tonumber(source) or -1] end,
        HasPermission = function() return false end,
        CreateCallback = function() end,
        GetPlayers = function() return {} end,
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
TriggerClientEvent = function(name, target, arg1, arg2) state.broadcasts[#state.broadcasts + 1] = { name = name, target = target, arg1 = arg1, arg2 = arg2 } end
TriggerEvent = function() end
CreateThread = function() end
Wait = function() end
GetGameTimer = function() return state.now end
GetCurrentResourceName = function() return 'qb-shops' end
GetPlayerName = function(source) return 'player' .. tostring(source) end
GetConvar = function(_, default) return default end
GetConvarFloat = function(_, default) return tonumber(default) or 1.0 end
GetPlayerPed = function(source) return tonumber(source) or 0 end
GetEntityCoords = function() return vector3(state.coords.x, state.coords.y, state.coords.z) end
SaveResourceFile = function() state.saved = state.saved + 1 return true end
LoadResourceFile = function() return nil end
IsPlayerAceAllowed = function() return false end

local vectorMeta = {}
vectorMeta.__sub = function(a, b)
    return setmetatable({ x = (a.x or 0) - (b.x or 0), y = (a.y or 0) - (b.y or 0), z = (a.z or 0) - (b.z or 0) }, vectorMeta)
end
vectorMeta.__len = function(a) return math.sqrt((a.x or 0) ^ 2 + (a.y or 0) ^ 2 + (a.z or 0) ^ 2) end
local function vec3(x, y, z) return setmetatable({ x = x or 0.0, y = y or 0.0, z = z or 0.0 }, vectorMeta) end
vector2 = function(x, y) return { x = x, y = y } end
vector3 = vec3
vector4 = function(x, y, z, w) local v = vec3(x, y, z); v.w = w; return v end

Lang = { t = function(a, b) local key = type(a) == 'string' and a or b; return tostring(key) end }
json = {
    encode = function() return '{}' end,
    decode = function() return {} end,
}
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
                AddItem = function(_, src, item, amount) state.added[#state.added + 1] = { src = src, item = item, amount = amount } return true end,
                CreateShop = function(_, shop) state.broadcasts[#state.broadcasts + 1] = { name = 'CreateShop', arg1 = shop } end,
                OpenShop = function(_, src, shopName) state.broadcasts[#state.broadcasts + 1] = { name = 'OpenShop', arg1 = shopName } end,
            }
        end
        if name == 'core_economy' then return { GetGlobalMultiplier = function() return 1.0 end } end
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

-- 租车成功的唯一标志是服务端让客户端生成货车；被拒时只会发一条 error 通知，
-- 所以不能用"有没有广播"来判断（会把拒绝通知误读成成功）。
local function sawSpawnVehicle()
    for _, entry in ipairs(state.broadcasts) do
        if entry.name == 'qb-shops:client:SpawnVehicle' then return true end
    end
    return false
end

state.players[1] = makePlayer(1)

-- 找一家有 delivery 点、且 useStock 的店
local shopName, shop = nil, nil
for name, value in pairs(Config.Locations) do
    if value.delivery and value.useStock then shopName, shop = name, value break end
end
assert(shopName, '没有带 delivery 的店')

-- ── 0. 职业门 + 押金会话（R0 / R0.3，2026-11-13）──
--     冷却只限速，不证明"跑了这一趟"；凭据必须是 DoBail(true) 扣过押金的会话。
--     而会话只有（在岗的）trucker 才能开：否则收押金换车却结算不了，等于骗钱。
emit('SCENARIO', 'gates')
state.coords = { x = shop.delivery.x + 1.0, y = shop.delivery.y, z = shop.delivery.z }

-- 0a 非 trucker（默认 unemployed）租不到车
state.broadcasts = {}
fire(1, 'qb-shops:server:DoBail', true)
emit('RENTAL_NON_TRUCKER_BLOCKED', tostring(not sawSpawnVehicle()))

-- 0b 在岗 trucker 但还没付押金：不能结算（会话门）
state.players[1].PlayerData.job = { name = 'trucker', onduty = true, grade = { level = 0 } }
state.paid = {}
fire(1, 'qb-shops:server:RestockShopItems', shopName)
emit('RESTOCK_NO_SESSION_BLOCKED', tostring(#state.paid == 0))

-- 0c 付押金换车（正常流程）→ 有会话，可以结算；每站给 delivery 声望
state.broadcasts = {}
fire(1, 'qb-shops:server:DoBail', true)
emit('RENTAL_TRUCKER_ALLOWED', tostring(sawSpawnVehicle()))
state.paid = {}
state.rep = {}
state.now = state.now + 31000
fire(1, 'qb-shops:server:RestockShopItems', shopName)
emit('RESTOCK_SESSION_OPEN_PAID', tostring(#state.paid == 1 and state.paid[1].amount == Config.DeliveryPrice))
emit('RESTOCK_REP_GRANTED', tostring(#state.rep == 1 and state.rep[1].rep == 'delivery'))
-- 默认不给 cryptostick（一根 ≈ $1,000，会把这一档收益抬到 $6k+/h）
emit('RESTOCK_NO_BONUS_ITEM', tostring(Config.DeliveryCryptostickChance == 0 and #state.added == 0))

-- 0d 在岗起租、中途下班：不结算（防"租完就换职业"）
state.players[1].PlayerData.job.onduty = false
state.now = state.now + 31000
state.paid = {}
fire(1, 'qb-shops:server:RestockShopItems', shopName)
emit('RESTOCK_OFFDUTY_BLOCKED', tostring(#state.paid == 0))
state.players[1].PlayerData.job.onduty = true

-- ── 1. 不在交货点：不付钱 ──
emit('SCENARIO', 'restock')
state.coords = { x = 0.0, y = 0.0, z = 0.0 }
state.paid = {}
fire(1, 'qb-shops:server:RestockShopItems', shopName)
emit('RESTOCK_FAR_BLOCKED', tostring(#state.paid == 0))

-- ── 2. 在交货点：付一次 ──
state.now = state.now + 31000
state.coords = { x = shop.delivery.x + 1.0, y = shop.delivery.y, z = shop.delivery.z }
state.paid = {}
fire(1, 'qb-shops:server:RestockShopItems', shopName)
emit('RESTOCK_NEAR_PAID', tostring(#state.paid == 1 and state.paid[1].amount == Config.DeliveryPrice))

-- ── 3. 冷却内再发：不付 ──
state.paid = {}
fire(1, 'qb-shops:server:RestockShopItems', shopName)
emit('RESTOCK_COOLDOWN_BLOCKED', tostring(#state.paid == 0))

-- 冷却键是「玩家 + 店」：同一玩家 30 秒内跑完**另一家店**必须照付
-- （送货路线里相邻两家的交货点可能只隔 47 米，只按玩家计会吞掉第二趟工资）
-- 现网只配了 1 家带 delivery 的店，这里造第二家（测的是冷却键，不是配置）
local otherName = 'probe_second_shop'
local other = {
    label = 'Probe Shop', useStock = true, products = {},
    coords = vec3(500.0, 500.0, 30.0),
    delivery = vec3(510.0, 500.0, 30.0),
}
Config.Locations[otherName] = other
state.coords = { x = other.delivery.x + 1.0, y = other.delivery.y, z = other.delivery.z }
state.paid = {}
fire(1, 'qb-shops:server:RestockShopItems', otherName)
emit('RESTOCK_OTHER_SHOP_ALLOWED', tostring(#state.paid == 1))

-- 冷却过后同一家店可以再付
state.now = state.now + 31000
state.coords = { x = shop.delivery.x + 1.0, y = shop.delivery.y, z = shop.delivery.z }
state.paid = {}
fire(1, 'qb-shops:server:RestockShopItems', shopName)
emit('RESTOCK_AFTER_COOLDOWN_PAID', tostring(#state.paid == 1))

-- 坏参数不崩
local okBadShop = fire(1, 'qb-shops:server:RestockShopItems', nil)
local okBadShop2 = fire(1, 'qb-shops:server:RestockShopItems', 'not_a_shop')
emit('RESTOCK_BAD_ARGS_SAFE', tostring(okBadShop and okBadShop2))

-- ── 3c. 会话上限与关闭（R0，2026-11-13）──
--     一趟（付一次押金）最多结算 Config.MaxDeliveries 次，与客户端 JobsDone 同口径；
--     关闭会话（还车退押金）后不再结算。原来这两条都不存在 = 无限刷。
emit('SCENARIO', 'session-cap')
fire(1, 'qb-shops:server:DoBail', true)
state.paid = {}
state.coords = { x = shop.delivery.x + 1.0, y = shop.delivery.y, z = shop.delivery.z }
for _ = 1, Config.MaxDeliveries + 5 do
    state.now = state.now + 31000
    fire(1, 'qb-shops:server:RestockShopItems', shopName)
end
emit('RESTOCK_SESSION_CAP', tostring(#state.paid == Config.MaxDeliveries))
emit('RESTOCK_SESSION_CAP_COUNT', tostring(#state.paid))

fire(1, 'qb-shops:server:DoBail', false)
state.now = state.now + 31000
state.paid = {}
fire(1, 'qb-shops:server:RestockShopItems', shopName)
emit('RESTOCK_SESSION_CLOSED_BLOCKED', tostring(#state.paid == 0))

-- ── 4. PaySlip：客户端来源直接拒（全仓无调用点）──
--     坐标放到 DeliveryLocations.main 旁边，让旧版**真的付钱**，这条才有区分度
emit('SCENARIO', 'payslip')
local delivery = Config.DeliveryLocations['main'].coords
state.coords = { x = delivery.x, y = delivery.y, z = delivery.z }
state.paid = {}
fire(1, 'qb-shops:server:PaySlip', 99999)
emit('PAYSLIP_CLIENT_BLOCKED', tostring(#state.paid == 0))

-- ── 5. 库存扣减 ──
emit('SCENARIO', 'stock')
local slot = 1
local before = shop.products[slot].amount
fire(1, 'qb-shops:server:UpdateShopItems', shopName, { slot = slot }, 3)
emit('STOCK_DECREMENT_OK', tostring(shop.products[slot].amount == before - 3))

local current = shop.products[slot].amount
local okNeg = fire(1, 'qb-shops:server:UpdateShopItems', shopName, { slot = slot }, -50)
emit('STOCK_NEGATIVE_BLOCKED', tostring(okNeg and shop.products[slot].amount == current))

local okBadSlot = fire(1, 'qb-shops:server:UpdateShopItems', shopName, { slot = 9999 }, 1)
local okNilSlot = fire(1, 'qb-shops:server:UpdateShopItems', shopName, {}, 1)
emit('STOCK_BAD_SLOT_SAFE', tostring(okBadSlot and okNilSlot))

-- ── 6. openShop：data 必填 + 距离 ──
emit('SCENARIO', 'openshop')
local okNilData = fire(1, 'qb-shops:server:openShop', nil)
emit('OPENSHOP_NIL_DATA_SAFE', tostring(okNilData))

state.broadcasts = {}
state.coords = { x = shop.coords.x + 1.0, y = shop.coords.y, z = shop.coords.z }
fire(1, 'qb-shops:server:openShop', { shop = shopName })
emit('OPENSHOP_NEAR_ALLOWED', tostring(#state.broadcasts > 0))

state.broadcasts = {}
state.coords = { x = 0.0, y = 0.0, z = 0.0 }
fire(1, 'qb-shops:server:openShop', { shop = shopName })
emit('OPENSHOP_FAR_BLOCKED', tostring(#state.broadcasts == 0))

emit('SCENARIO', 'done')
io.write(table.concat(OUT, '\n'), '\n')
