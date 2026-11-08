-- tests/unit/layer3_business/test_drugs_delivery_authority.py 用的 Lua 沙箱：
-- 只加载 qb-drugs 的 config.lua 与 server/deliveries.lua，把 FiveM 运行时替换成记录器，
-- 然后真的触发 net event，观察"扣了多少 / 给了多少货 / 结算发了多少钱"。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

-- ── 运行时 mock ─────────────────────────────────────────────────────────────
local state = {
    money = { cash = 100000, bank = 0 },
    items = {},
    addedMoney = {},
    removedMoney = {},
    addedItems = {},
    removedItems = {},
    notifications = {},
    now = 0,
}

local player = {
    PlayerData = { source = 1, citizenid = 'TESTCID', charinfo = { phone = '555-0100' }, metadata = { rep = { dealer = 5 } } },
    Functions = {
        -- 注意：资源里都是 `Player.Functions.X(...)` 这种**点调用**，mock 不能带 self 形参
        GetMoney = function(account) return state.money[account] or 0 end,
        AddMoney = function(account, amount, reason)
            state.money[account] = (state.money[account] or 0) + amount
            state.addedMoney[#state.addedMoney + 1] = { account = account, amount = amount, reason = reason }
            return true
        end,
        RemoveMoney = function(account, amount, reason)
            if (state.money[account] or 0) < amount then return false end
            state.money[account] = state.money[account] - amount
            state.removedMoney[#state.removedMoney + 1] = { account = account, amount = amount, reason = reason }
            return true
        end,
        GetItemByName = function(name)
            return state.items[name] and { name = name, amount = state.items[name] } or nil
        end,
        RemoveItem = function(name, amount)
            local have = state.items[name] or 0
            if have < (amount or 0) then return false end
            state.items[name] = have - amount
            if state.items[name] == 0 then state.items[name] = nil end
            state.removedItems[#state.removedItems + 1] = { item = name, amount = amount, source = 1 }
            return true
        end,
        AddRep = function() end,
        GetRep = function() return 5 end,
    },
}

local QBCoreMock = {
    Functions = {
        GetPlayer = function(source) return source == 1 and player or nil end,
        GetDutyCount = function() return 0 end,
        CreateCallback = function() end,
        GetQBPlayers = function() return {} end,
    },
    Commands = { Add = function() end },
    ServerCallbacks = {},
    Shared = { Items = { weed_brick = { label = 'Weed Brick' }, coke_brick = { label = 'Coke Brick' } } },
}

local handlers = {}
local events = {}

exports = setmetatable({}, {
    __call = function(_, name, fn) rawset(exports, name, fn) end,
    __index = function(_, name)
        if name == 'qb-core' then
            return { GetCoreObject = function() return QBCoreMock end }
        end
        return setmetatable({}, {
            __index = function(_, method)
                return function(_, ...)
                    local args = { ... }
                    if method == 'AddItem' then
                        local src, item, amount = args[1], args[2], args[3]
                        state.items[item] = (state.items[item] or 0) + amount
                        state.addedItems[#state.addedItems + 1] = { item = item, amount = amount, source = src }
                    elseif method == 'RemoveItem' then
                        local src, item, amount = args[1], args[2], args[3]
                        state.items[item] = math.max(0, (state.items[item] or 0) - amount)
                        state.removedItems[#state.removedItems + 1] = { item = item, amount = amount, source = src }
                    end
                    return true
                end
            end,
        })
    end,
})

RegisterNetEvent = function(name, fn) handlers[name] = fn end
AddEventHandler = function(name, fn) handlers[name] = fn end
TriggerClientEvent = function(name, source, ...)
    local args = { ... }
    events[#events + 1] = { name = name, source = source, args = args }
    if name == 'QBCore:Notify' and args[1] then
        state.notifications[#state.notifications + 1] = tostring(args[1])
    end
end
TriggerServerEvent = function() end
-- 真定时器：accept 靠 SetTimeout(2000) 释放排他锁，no-op 会让后续场景全被锁挡住（CC 复核抓到过）
local timers = {}
SetTimeout = function(delay, fn)
    timers[#timers + 1] = { due = state.now + (tonumber(delay) or 0), fn = fn }
end
local function tick(milliseconds)
    state.now = state.now + (milliseconds or 0)
    local due = {}
    for _, timer in ipairs(timers) do
        if timer.due <= state.now then due[#due + 1] = timer end
    end
    for _, timer in ipairs(due) do
        for index, candidate in ipairs(timers) do
            if candidate == timer then table.remove(timers, index) break end
        end
        timer.fn()
    end
end
GetGameTimer = function() return state.now end
GetPlayerName = function(source) return 'Tester' .. tostring(source) end
GetCurrentResourceName = function() return 'qb-drugs' end
Wait = function() end
json = { encode = function() return '{}' end, decode = function() return {} end }
MySQL = setmetatable({}, { __index = function() return setmetatable({}, { __call = function() end, __index = function() return function() end end }) end })
CreateThread = function() end
Lang = { t = function(key) return key end }
GetConvar = function(_, default) return default end
GetConvarInt = function(_, default) return tonumber(default) or 0 end
vector3 = function(x, y, z) return { x = x, y = y, z = z } end
vector4 = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end

-- FiveM 的 net event handler 里 `source` 是隐式全局，这里手动设
local function fire(name, ...)
    _G.source = 1
    assert(handlers[name], 'handler 未注册: ' .. name)
    -- handler 抛错也要继续跑后面的场景（旧实现遇到伪造 key 会直接崩）
    local ok, err = pcall(handlers[name], ...)
    _G.source = nil
    if not ok then
        OUT[#OUT + 1] = 'HANDLER_ERROR|' .. tostring(err)
    end
    return ok
end

dofile(RES .. '/shared/money_format.lua')
dofile(RES .. '/config.lua')
dofile(RES .. '/server/deliveries.lua')

-- ── 场景 1：恶意接单（押金 0、数量 999、报酬自填）─────────────────────────────
local malicious = {
    item = 1,           -- weed_brick，Config 里 payout = 1000
    amount = 999,       -- 想一次拿 999 个
    deposit = 0,        -- 想不交押金
    basePayout = 999999,
    distance = 100,
    fastTime = 999999,
    maxTime = 999999,
    coords = { x = 1.0, y = 2.0 },
    locationLabel = 'Test Drop',
    itemData = { payout = 1000 },   -- 旧代码会读它；新代码不看
}
fire('qb-drugs:server:acceptDelivery', malicious)

emit('SCENARIO', 'accept')
emit('DEDUCTED', state.removedMoney[1] and state.removedMoney[1].amount or -1)
emit('EXPECTED_DEPOSIT', math.ceil(Config.DeliveryItems[1].payout * Config.DeliveryDepositRate))
emit('ITEM_AMOUNT', state.addedItems[1] and state.addedItems[1].amount or -1)
emit('CASH_AFTER_ACCEPT', state.money.cash)

-- ── 场景 2：恶意结算（把押金说成 10 亿）───────────────────────────────────────
state.items[Config.DeliveryItems[1].item] = 1     -- 背包里有 1 个货，正常回收
state.now = 100                                    -- 服务端计时：100ms 后完成
fire('qb-drugs:server:successDelivery', { item = 1, amount = 999, deposit = 1e9, basePayout = 1e9, itemData = { payout = 1000 } }, true)

emit('SCENARIO', 'settle')
emit('PAID', state.addedMoney[1] and state.addedMoney[1].amount or -1)
emit('PAID_REASON', state.addedMoney[1] and state.addedMoney[1].reason or '')
emit('CASH_AFTER_SETTLE', state.money.cash)

-- ── 场景 3：重放同一个结算（没有新记录，不能再发一次）──────────────────────────
local paidBefore = #state.addedMoney
fire('qb-drugs:server:successDelivery', { item = 1, amount = 1, deposit = 500, itemData = { payout = 1000 } }, true)
emit('SCENARIO', 'replay')
emit('PAID_COUNT_DELTA', #state.addedMoney - paidBefore)

-- ── 场景 4：伪造商品 key ─────────────────────────────────────────────────────
tick(3000)      -- 释放上一单的排他锁，否则这里测到的是 "Please wait..." 而不是商品校验
local removedBefore = #state.removedMoney
fire('qb-drugs:server:acceptDelivery', { item = 'not_an_item', amount = 1, deposit = 0 })
emit('SCENARIO', 'fake-item')
emit('DEDUCT_COUNT_DELTA', #state.removedMoney - removedBefore)

-- ── 场景 5：背包里没有货时结算 → 不发钱 ──────────────────────────────────────
tick(3000)
fire('qb-drugs:server:acceptDelivery', { item = 2, amount = 1, distance = 100 })
state.items[Config.DeliveryItems[2].item] = nil
local paidBefore5 = #state.addedMoney
state.now = state.now + 100
fire('qb-drugs:server:successDelivery', { item = 2, amount = 1, itemData = { payout = 1000 } }, true)
emit('SCENARIO', 'missing-item')
emit('PAID_COUNT_DELTA', #state.addedMoney - paidBefore5)


-- ── 场景 6：连续接两单 —— 第二单必须被拒（否则覆盖记录 = 白扣押金 + 多留一个货）──────
tick(3000)
local deductBefore6 = #state.removedMoney
fire('qb-drugs:server:acceptDelivery', { item = 2, amount = 1, distance = 100 })   -- 第一单
tick(3000)
fire('qb-drugs:server:acceptDelivery', { item = 1, amount = 1, distance = 100 })   -- 第二单，应被拒
emit('SCENARIO', 'double-accept')
emit('DEDUCT_COUNT_DELTA', #state.removedMoney - deductBefore6)

-- ── 场景 7：断线后 source 被复用给别的角色 → 旧记录不能结算 ──────────────────────
-- 先清掉场景 6 留下的活跃单（否则这里的 accept 会被"已有活跃单"挡住，测的就不是 source 复用了）
fire('qb-drugs:server:failDelivery', {})
tick(3000)
local accepted7 = fire('qb-drugs:server:acceptDelivery', { item = 1, amount = 1, distance = 100 })
emit('ACCEPT_OK', accepted7 and 'yes' or 'no')
state.items[Config.DeliveryItems[1].item] = 1
player.PlayerData.citizenid = 'OTHERCID'                                          -- source 复用了
local paidBefore7 = #state.addedMoney
tick(100)
fire('qb-drugs:server:successDelivery', { item = 1, amount = 1, itemData = { payout = 1000 } }, true)
emit('SCENARIO', 'source-reuse')
emit('PAID_COUNT_DELTA', #state.addedMoney - paidBefore7)

-- 断线回调本身也要清记录：清完之后再结算同样不发钱
player.PlayerData.citizenid = 'TESTCID'
if handlers['playerDropped'] then
    _G.source = 1
    handlers['playerDropped']()
    _G.source = nil
end
local paidBefore8 = #state.addedMoney
fire('qb-drugs:server:successDelivery', { item = 1, amount = 1, itemData = { payout = 1000 } }, true)
emit('SCENARIO', 'after-drop')
emit('PAID_COUNT_DELTA', #state.addedMoney - paidBefore8)

-- ── 场景 8：接单后掉线，重新上线 → 回收货物 + 退还押金 ──────────────────────────
tick(3000)
state.items[Config.DeliveryItems[1].item] = nil
fire('qb-drugs:server:acceptDelivery', { item = 1, amount = 1, distance = 100 })
local cashBefore8 = state.money.cash
fire('playerDropped', {})
state.items[Config.DeliveryItems[1].item] = 1      -- 掉线时货还在背包
tick(5000)
fire('QBCore:Server:PlayerLoaded', player)
emit('SCENARIO', 'drop-settlement')
emit('REFUND', state.money.cash - cashBefore8)
emit('ITEM_LEFT', tostring(state.items[Config.DeliveryItems[1].item] or 0))

-- ── 场景 9：掉线前把货用掉了 → 押金不退 ────────────────────────────────────────
tick(3000)
fire('qb-drugs:server:acceptDelivery', { item = 1, amount = 1, distance = 100 })
local cashBefore9 = state.money.cash
fire('playerDropped', {})
state.items[Config.DeliveryItems[1].item] = nil     -- 货没了
tick(5000)
fire('QBCore:Server:PlayerLoaded', player)
emit('SCENARIO', 'drop-settlement-missing-item')
emit('REFUND', state.money.cash - cashBefore9)

io.write(table.concat(OUT, '\n'), '\n')
