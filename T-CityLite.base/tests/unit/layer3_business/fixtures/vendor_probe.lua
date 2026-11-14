-- vendor_probe.lua — 真跑 quest_vendor.lua（标记块抽取，不复制实现）
--
-- 只桩五类外部符号：
--   * GetGameTimer                 → 可控毫秒时钟
--   * exports['qb-core']           → 假 Player（记录 AddMoney 调用）
--   * RegisterNetEvent / TriggerClientEvent → 记录调用，断言内核一个都不发
--   * GetPlayerPed / 常用 native   → 占位（本内核不依赖实体）
--   * QuestVendor._random = 0      → 所有区间取最小值，排期可预测
--
-- 覆盖 10 条硬性不变量 + 边界（count<=0 / 未知 item / 会话不存在 / 原料耗尽）：
--   1 报价金额服务端算（客户端多传的参数被忽略）
--   2 offerId 一次性（第二次 already_settled，不重复加钱/扣库存）
--   3 过期（expired，库存与钱不动）
--   4 报价时库存不足直接拒绝（不生成 offer）
--   5 两人同时买最后一份（AddMoney 内 yield 模拟并发）→ 第二个 sold_out
--   6 连续拒绝 3 次 → 60 秒冷却
--   7 每摊 1 位 / 每玩家 1 位 / 全局 8 位
--   8 打烊后所有入口返回 closed
--   9 钱只走 AddMoney('cash', ...) 且 reason 固定
--  10 Close 后会话立即消失、重复 Close 返回 nil
--
-- 用法:
--   lua5.4 tests/unit/layer3_business/fixtures/vendor_probe.lua \
--       "resources/[custom]/custom-quest/server/quest_vendor.lua"

local SOURCE = arg[1]
if not SOURCE then
    error('用法: lua5.4 vendor_probe.lua <quest_vendor.lua>')
end

local file = assert(io.open(SOURCE, 'r'))
local text = file:read('a')
file:close()

local function extract(name)
    local pattern = '\r?\n%-%- %[' .. name .. '%] begin\r?\n(.-)\r?\n%-%- %[' .. name .. '%] end'
    local body = ('\n' .. text):match(pattern)
    if not body then error('找不到标记块: ' .. name) end
    return body
end

-- ---------------------------------------------------------------------------
-- 桩：时钟 / 玩家 / 事件
-- ---------------------------------------------------------------------------

local state = {
    now = 1000000,
    moneyCalls = {},
    netEvents = {},
    clientEvents = {},
    triggeredEvents = {},
}

GetGameTimer = function() return state.now end
-- 就算有人把 Now() 的 GetGameTimer 分支删掉，时间仍然是可控的
os.time = function() return math.floor(state.now / 1000) end
GetPlayerPed = function() return 1 end
IsPointOnRoad = function() return false end
GetEntityCoords = function() return { x = 0.0, y = 0.0, z = 0.0 } end

RegisterNetEvent = function(name) state.netEvents[#state.netEvents + 1] = name end
RegisterServerEvent = RegisterNetEvent
AddEventHandler = function() end
TriggerClientEvent = function(name) state.clientEvents[#state.clientEvents + 1] = name end
TriggerEvent = function(name) state.triggeredEvents[#state.triggeredEvents + 1] = name end
CreateThread = function() end
Wait = function() end
SetTimeout = function() end

local players = {}
local sourceCounter = 0

local function addPlayer(citizenid, opts)
    opts = opts or {}
    sourceCounter = sourceCounter + 1
    local source = opts.source or sourceCounter
    local player = {
        PlayerData = { citizenid = citizenid, source = source, money = { cash = 0 } },
        Functions = {},
        yieldNext = opts.yieldNext == true,
        failNext = opts.failNext == true,
    }
    player.Functions.AddMoney = function(moneytype, amount, reason)
        state.moneyCalls[#state.moneyCalls + 1] = {
            citizenid = citizenid,
            moneytype = moneytype,
            amount = amount,
            reason = reason,
        }
        if player.yieldNext then
            player.yieldNext = false
            coroutine.yield('addmoney-yield')
        end
        if player.failNext then
            player.failNext = false
            return false
        end
        player.PlayerData.money[moneytype] = (player.PlayerData.money[moneytype] or 0) + amount
        return true
    end
    players[citizenid] = player
    return player
end

local QBCoreMock = {
    Functions = {
        GetPlayerByCitizenId = function(citizenid) return players[citizenid] end,
        GetPlayer = function(source)
            for _, player in pairs(players) do
                if player.PlayerData.source == source then return player end
            end
            return nil
        end,
        GetPlayers = function()
            local out = {}
            for _, player in pairs(players) do out[#out + 1] = player.PlayerData.source end
            return out
        end,
    },
}

exports = setmetatable({}, {
    __call = function(_, name, fn) rawset(exports, name, fn) end,
    __index = function(_, name)
        if name == 'qb-core' then
            return {
                GetPlayerByCitizenId = function(_, citizenid) return players[citizenid] end,
                GetPlayer = function(_, source) return QBCoreMock.Functions.GetPlayer(source) end,
                GetCoreObject = function() return QBCoreMock end,
            }
        end
        return setmetatable({}, { __index = function() return function() return nil end end })
    end,
})

local chunk = assert(load(extract('quest%-vendor'), 'quest-vendor'))
chunk()

-- ---------------------------------------------------------------------------
-- 测试脚手架
-- ---------------------------------------------------------------------------

local results = {}
local function check(name, ok, detail)
    results[#results + 1] = { name = name, ok = ok and true or false, detail = detail or '' }
end

local function newWorld()
    QuestVendor.Reset()
    QuestVendor._now = nil          -- 走 GetGameTimer 桩
    QuestVendor._random = 0         -- 每个区间都取最小值
    state.now = 1000000
    state.moneyCalls = {}
    state.netEvents = {}
    state.clientEvents = {}
    state.triggeredEvents = {}
    players = {}
    sourceCounter = 0
end

local DEFAULT_CFG = {
    prices = { common = 6, rare = 9, exotic = 14 },
    first_customer_ms = { 8000, 15000 },
    interval_ms = { 15000, 40000 },
    patience_ms = 45000,
    max_global_npcs = 8,
    reject_cooldown_ms = 60000,
    max_rejects = 3,
    max_offers_per_session = 32,
}

local function makeCfg(overrides)
    local cfg = {}
    for key, value in pairs(DEFAULT_CFG) do cfg[key] = value end
    for key, value in pairs(overrides or {}) do cfg[key] = value end
    cfg.now = state.now
    return cfg
end

local function findAction(actions, name, citizenid)
    for _, action in ipairs(actions) do
        if action.action == name and (not citizenid or action.citizenid == citizenid) then
            return action
        end
    end
    return nil
end

--- 推进到第一位顾客到达，并返回 spawn 动作。
local function arrive(citizenid)
    state.now = state.now + 8000
    return findAction(QuestVendor.Tick(state.now), 'spawn_customer', citizenid)
end

-- 1) 报价金额服务端算：自定义价格 + 品质系数，客户端多传的“价格”被忽略
do
    newWorld()
    addPlayer('cid-price')
    local session = QuestVendor.Open('cid-price', 'quest-hotdog', 101, makeCfg({
        prices = { common = 1, rare = 7, exotic = 13 },
        quality_multiplier = { common = 1.0, rare = 1.5, exotic = 1.0 },
    }))
    QuestVendor.AddStock('cid-price', 'rare', 5)
    assert(arrive('cid-price'))
    -- 第 5 个参数是伪造的价格；CreateOffer 只认 item + count
    local offer = QuestVendor.CreateOffer('cid-price', 'rare', 2, 777, 999999)
    check('price_server_side',
        offer ~= nil
            and offer.unitPrice == 11       -- floor(7 × 1.5 + 0.5)
            and offer.price == 22           -- 11 × 2
            and offer.item == 'rare'
            and offer.count == 2
            and offer.npcNetId == 777
            and session.stock.rare == 5,
        ('unit=%s total=%s'):format(tostring(offer and offer.unitPrice),
            tostring(offer and offer.price)))
end

-- 2) offerId 一次性：第二次 already_settled，钱与库存都不重复
do
    newWorld()
    addPlayer('cid-idem')
    local session = QuestVendor.Open('cid-idem', 'quest-hotdog', 101, makeCfg())
    QuestVendor.AddStock('cid-idem', 'rare', 2)
    assert(arrive('cid-idem'))
    local offer = QuestVendor.CreateOffer('cid-idem', 'rare', 1)
    local okFirst, first = QuestVendor.SettleOffer('cid-idem', offer.offerId)
    local stockAfterFirst = session.stock.rare
    local okSecond, secondErr = QuestVendor.SettleOffer('cid-idem', offer.offerId)
    check('offer_idempotent',
        okFirst == true and first ~= nil and first.price == 9
            and stockAfterFirst == 1
            and session.sold == 1 and session.revenue == 9
            and okSecond == nil and secondErr == 'already_settled'
            and #state.moneyCalls == 1
            and state.moneyCalls[1].amount == 9
            and session.stock.rare == 1,
        ('first=%s stock=%s second=%s money=%d'):format(
            tostring(okFirst), tostring(session.stock.rare), tostring(secondErr),
            #state.moneyCalls))
end

-- 3) 过期：expired，库存/钱/销量都不动；重放仍是 expired
do
    newWorld()
    addPlayer('cid-exp')
    local session = QuestVendor.Open('cid-exp', 'quest-hotdog', 101, makeCfg())
    QuestVendor.AddStock('cid-exp', 'rare', 1)
    assert(arrive('cid-exp'))
    local offer = QuestVendor.CreateOffer('cid-exp', 'rare', 1)
    state.now = offer.expiresAt + 1
    local okExpired, expiredErr = QuestVendor.SettleOffer('cid-exp', offer.offerId)
    local okAgain, againErr = QuestVendor.SettleOffer('cid-exp', offer.offerId)
    check('offer_expiry',
        okExpired == nil and expiredErr == 'expired'
            and okAgain == nil and againErr == 'expired'
            and session.stock.rare == 1
            and session.sold == 0 and session.revenue == 0
            and #state.moneyCalls == 0,
        ('first=%s again=%s stock=%s money=%d'):format(
            tostring(expiredErr), tostring(againErr),
            tostring(session.stock.rare), #state.moneyCalls))
end

-- 4) 库存不足在报价时就拒绝，不生成 offer
do
    newWorld()
    addPlayer('cid-stock')
    local session = QuestVendor.Open('cid-stock', 'quest-hotdog', 101, makeCfg())
    QuestVendor.AddStock('cid-stock', 'rare', 1)
    assert(arrive('cid-stock'))
    local offer, err = QuestVendor.CreateOffer('cid-stock', 'rare', 2)
    local hasOffer = next(session.offers) ~= nil
    check('quote_rejects_insufficient_stock',
        offer == nil and err == 'insufficient_stock'
            and hasOffer == false and session.seq == 0
            and session.npc.active == true,
        ('err=%s offer=%s seq=%s'):format(tostring(err), tostring(hasOffer),
            tostring(session.seq)))
end

-- 5) 并发：最后一个成品，先预扣库存再发钱；AddMoney 里 yield，第二个必须 sold_out
do
    newWorld()
    local player = addPlayer('cid-race', { yieldNext = true })
    local session = QuestVendor.Open('cid-race', 'quest-hotdog', 101, makeCfg())
    QuestVendor.AddStock('cid-race', 'common', 1)

    local co = coroutine.create(function()
        return QuestVendor.Purchase('cid-race', 'common', 1)
    end)
    local okResume = coroutine.resume(co)
    local reservedStock = session.stock.common
    local busyWhileSuspended = session.busy
    local okSecond, secondErr = QuestVendor.Purchase('cid-race', 'common', 1)
    local okResumeAgain, okFirst, first = coroutine.resume(co)
    check('purchase_serial_last_item',
        okResume == true
            and reservedStock == 0 and busyWhileSuspended == true
            and okSecond == nil and secondErr == 'sold_out'
            and okResumeAgain == true and okFirst == true
            and type(first) == 'table' and first.total == 6
            and session.stock.common == 0
            and session.sold == 1 and session.revenue == 6
            and session.busy == false
            and #state.moneyCalls == 1
            and state.moneyCalls[1].amount == 6,
        ('reserved=%s busy=%s second=%s money=%d'):format(
            tostring(reservedStock), tostring(busyWhileSuspended),
            tostring(secondErr), #state.moneyCalls))
    assert(player.PlayerData.money.cash == 6)
end

-- 6) 连续拒绝 3 次 → 60 秒不再生成；冷却结束后恢复
do
    newWorld()
    local session = QuestVendor.Open('cid-rej', 'quest-hotdog', 101, makeCfg())
    QuestVendor.AddStock('cid-rej', 'common', 10)
    local t0 = state.now

    state.now = t0 + 8000
    assert(findAction(QuestVendor.Tick(state.now), 'spawn_customer', 'cid-rej'))
    local offer1 = QuestVendor.CreateOffer('cid-rej', 'common', 1)
    local reject1 = QuestVendor.RejectOffer('cid-rej', offer1.offerId)

    state.now = state.now + 15000
    assert(findAction(QuestVendor.Tick(state.now), 'spawn_customer', 'cid-rej'))
    local offer2 = QuestVendor.CreateOffer('cid-rej', 'common', 1)
    local reject2 = QuestVendor.RejectOffer('cid-rej', offer2.offerId)

    state.now = state.now + 15000
    assert(findAction(QuestVendor.Tick(state.now), 'spawn_customer', 'cid-rej'))
    local offer3 = QuestVendor.CreateOffer('cid-rej', 'common', 1)
    local reject3 = QuestVendor.RejectOffer('cid-rej', offer3.offerId)
    local cooldownUntil = session.npc.cooldownUntil

    local blocked = true
    for _, at in ipairs({ t0 + 68000, t0 + 97999 }) do
        state.now = at
        if findAction(QuestVendor.Tick(at), 'spawn_customer', 'cid-rej') then
            blocked = false
        end
    end

    state.now = cooldownUntil + 1
    local resumed = findAction(QuestVendor.Tick(state.now), 'spawn_customer', 'cid-rej')
    check('reject_suppression',
        reject1 == true and reject2 == true and reject3 == true
            and cooldownUntil == t0 + 98000
            and blocked == true
            and resumed ~= nil,
        ('cooldownUntil=%s blocked=%s resumed=%s'):format(
            tostring(cooldownUntil), tostring(blocked), tostring(resumed ~= nil)))
end

-- 7) 并发上限：每玩家 1 位、每摊 1 位、全局 8 位
do
    newWorld()
    addPlayer('cid-owner')
    local first = QuestVendor.Open('cid-owner', 'quest-hotdog', 101, makeCfg())
    local dup, dupErr = QuestVendor.Open('cid-owner', 'quest-hotdog', 101, makeCfg())

    QuestVendor.Reset()
    players = {}
    sourceCounter = 0
    for index = 1, 9 do
        local cid = 'cid-cap-' .. index
        addPlayer(cid)
        QuestVendor.Open(cid, 'quest-hotdog', 200 + index, makeCfg())
        QuestVendor.AddStock(cid, 'common', 1)
    end
    state.now = state.now + 8000
    local spawnCount = 0
    for _, action in ipairs(QuestVendor.Tick(state.now)) do
        if action.action == 'spawn_customer' then spawnCount = spawnCount + 1 end
    end

    QuestVendor.Reset()
    players = {}
    sourceCounter = 0
    addPlayer('cid-booth-a')
    addPlayer('cid-booth-b')
    QuestVendor.Open('cid-booth-a', 'quest-hotdog', 300, makeCfg())
    QuestVendor.Open('cid-booth-b', 'quest-hotdog', 300, makeCfg())
    QuestVendor.AddStock('cid-booth-a', 'common', 1)
    QuestVendor.AddStock('cid-booth-b', 'common', 1)
    state.now = state.now + 8000
    local sameBoothSpawns = 0
    for _, action in ipairs(QuestVendor.Tick(state.now)) do
        if action.action == 'spawn_customer' then sameBoothSpawns = sameBoothSpawns + 1 end
    end

    check('npc_concurrency_caps',
        first ~= nil and dup == nil and dupErr == 'already_open'
            and spawnCount == 8 and sameBoothSpawns == 1,
        ('per_player=%s global=%d same_booth=%d'):format(
            tostring(dupErr), spawnCount, sameBoothSpawns))
end

-- 8) 打烊：questId 不符不关；Close 后会话立即消失；重复 Close 返回 nil；所有入口 closed
do
    newWorld()
    addPlayer('cid-closed')
    QuestVendor.Open('cid-closed', 'quest-hotdog', 101, makeCfg())
    QuestVendor.AddStock('cid-closed', 'common', 2)

    local mismatched = QuestVendor.Close('cid-closed', 'other-quest', 'mismatch')
    local stillOpen = QuestVendor.Get('cid-closed')
    local summary = QuestVendor.Close('cid-closed', 'quest-hotdog', 'owner_left')
    local repeatClose = QuestVendor.Close('cid-closed', 'quest-hotdog', 'again')

    local createOk, createErr = QuestVendor.CreateOffer('cid-closed', 'common', 1)
    local buyOk, buyErr = QuestVendor.Purchase('cid-closed', 'common', 1)
    local settleOk, settleErr = QuestVendor.SettleOffer('cid-closed', 'offer-x')
    local addOk, addErr = QuestVendor.AddStock('cid-closed', 'common', 1)
    local rawOk, rawErr = QuestVendor.ConsumeRaw('cid-closed')
    local rejectOk, rejectErr = QuestVendor.RejectOffer('cid-closed', 'offer-x')

    check('closed_session_guards',
        mismatched == nil and stillOpen ~= nil
            and summary ~= nil and summary.sold == 0
            and summary.stock.common == 2 and summary.raw == 30
            and summary.reason == 'owner_left'
            and repeatClose == nil
            and QuestVendor.Get('cid-closed') == nil
            and createOk == nil and createErr == 'closed'
            and buyOk == nil and buyErr == 'closed'
            and settleOk == nil and settleErr == 'closed'
            and addOk == nil and addErr == 'closed'
            and rawOk == nil and rawErr == 'closed'
            and rejectOk == nil and rejectErr == 'closed',
        ('summary=%s repeat=%s create=%s buy=%s settle=%s add=%s raw=%s reject=%s'):format(
            tostring(summary ~= nil), tostring(repeatClose),
            tostring(createErr), tostring(buyErr), tostring(settleErr),
            tostring(addErr), tostring(rawErr), tostring(rejectErr)))
end

-- 9) 找不到在线玩家时结算必须原子失败：不扣库存、不加钱、offer 仍可重试
do
    newWorld()
    local session = QuestVendor.Open('cid-nop', 'quest-hotdog', 101, makeCfg())
    QuestVendor.AddStock('cid-nop', 'rare', 2)
    assert(arrive('cid-nop'))
    local offer = QuestVendor.CreateOffer('cid-nop', 'rare', 1)
    local ok, err = QuestVendor.SettleOffer('cid-nop', offer.offerId)
    check('settle_without_player_is_atomic',
        ok == nil and err == 'no_player'
            and session.stock.rare == 2
            and session.sold == 0 and session.revenue == 0
            and #state.moneyCalls == 0
            and session.offers[offer.offerId].state == 'open',
        ('err=%s stock=%s state=%s'):format(tostring(err),
            tostring(session.stock.rare), tostring(session.offers[offer.offerId].state)))
end

-- 10) 玩家购买路径同样服务端计价，且只调用一次 AddMoney('cash', ..., 'quest-vendor-sale')
do
    newWorld()
    local player = addPlayer('cid-buy-price')
    QuestVendor.Open('cid-buy-price', 'quest-hotdog', 101, makeCfg({
        prices = { common = 4, rare = 9, exotic = 14 },
    }))
    QuestVendor.AddStock('cid-buy-price', 'common', 3)
    local ok, result = QuestVendor.Purchase('cid-buy-price', 'common', 2)
    local call = state.moneyCalls[1]
    check('purchase_price_server_side',
        ok == true and result ~= nil
            and result.unitPrice == 4 and result.total == 8
            and #state.moneyCalls == 1
            and call.moneytype == 'cash'
            and call.amount == 8
            and call.reason == 'quest-vendor-sale'
            and player.PlayerData.money.cash == 8,
        ('total=%s calls=%d reason=%s'):format(
            tostring(result and result.total), #state.moneyCalls,
            tostring(call and call.reason)))
end

-- 11) 边界：count <= 0 / 非整数 / 非数字 → bad_count，且不生成 offer
do
    newWorld()
    local session = QuestVendor.Open('cid-bad', 'quest-hotdog', 101, makeCfg())
    QuestVendor.AddStock('cid-bad', 'common', 5)
    assert(arrive('cid-bad'))
    local allBad = true
    local seen = {}
    for _, value in ipairs({ 0, -1, 1.5, 'abc' }) do
        local offer, err = QuestVendor.CreateOffer('cid-bad', 'common', value)
        seen[#seen + 1] = tostring(err)
        if offer ~= nil or err ~= 'bad_count' then allBad = false end
    end
    local buyOk, buyErr = QuestVendor.Purchase('cid-bad', 'common', 0)
    check('bad_count_rejected',
        allBad and buyOk == nil and buyErr == 'bad_count' and session.seq == 0
            and next(session.offers) == nil,
        ('create=%s buy=%s'):format(table.concat(seen, ','), tostring(buyErr)))
end

-- 12) 边界：未知 item → bad_item（报价 / 购买 / 加库存三处一致）
do
    newWorld()
    QuestVendor.Open('cid-item', 'quest-hotdog', 101, makeCfg())
    local offerOk, offerErr = QuestVendor.CreateOffer('cid-item', 'diamond', 1)
    local buyOk, buyErr = QuestVendor.Purchase('cid-item', 'diamond', 1)
    local addOk, addErr = QuestVendor.AddStock('cid-item', 'diamond', 1)
    check('unknown_item_rejected',
        offerOk == nil and offerErr == 'bad_item'
            and buyOk == nil and buyErr == 'bad_item'
            and addOk == nil and addErr == 'bad_item',
        ('create=%s buy=%s add=%s'):format(
            tostring(offerErr), tostring(buyErr), tostring(addErr)))
end

-- 13) 边界：会话不存在时所有入口返回 closed（而不是崩溃）
do
    newWorld()
    local cid = 'cid-ghost'
    local _, createErr = QuestVendor.CreateOffer(cid, 'common', 1)
    local _, buyErr = QuestVendor.Purchase(cid, 'common', 1)
    local _, settleErr = QuestVendor.SettleOffer(cid, 'offer-x')
    local _, addErr = QuestVendor.AddStock(cid, 'common', 1)
    local _, rawErr = QuestVendor.ConsumeRaw(cid)
    local _, rejectErr = QuestVendor.RejectOffer(cid, 'offer-x')
    check('missing_session_is_closed',
        createErr == 'closed' and buyErr == 'closed' and settleErr == 'closed'
            and addErr == 'closed' and rawErr == 'closed' and rejectErr == 'closed',
        ('create=%s buy=%s settle=%s add=%s raw=%s reject=%s'):format(
            tostring(createErr), tostring(buyErr), tostring(settleErr),
            tostring(addErr), tostring(rawErr), tostring(rejectErr)))
end

-- 14) 原料：默认 30，做一份扣一份，耗尽返回 false, 'no_raw'
do
    newWorld()
    local session = QuestVendor.Open('cid-raw', 'quest-hotdog', 101, makeCfg())
    local drained = true
    for index = 1, 30 do
        local ok, remaining = QuestVendor.ConsumeRaw('cid-raw')
        if not ok or remaining ~= 30 - index then drained = false end
    end
    local ok, err = QuestVendor.ConsumeRaw('cid-raw')
    check('raw_consumption',
        drained and session.raw == 0
            and ok == false and err == 'no_raw',
        ('remaining=%s err=%s'):format(tostring(session.raw), tostring(err)))
end

-- 15) 库存别名：接受 S3 的 hotdog_* 物品 id，也接受档位名
do
    newWorld()
    local session = QuestVendor.Open('cid-alias', 'quest-hotdog', 101, makeCfg())
    local ok1, exotic = QuestVendor.AddStock('cid-alias', 'hotdog_exotic', 2)
    local ok2, rare = QuestVendor.AddStock('cid-alias', 'rare', 1)
    check('stock_alias_and_add_stock',
        ok1 == true and exotic == 2
            and ok2 == true and rare == 1
            and session.stock.exotic == 2
            and session.stock.rare == 1,
        ('exotic=%s rare=%s'):format(tostring(exotic), tostring(rare)))
end

-- 16) 单场报价上限：达到 max_offers_per_session 后返回 offer_limit
do
    newWorld()
    QuestVendor.Open('cid-limit', 'quest-hotdog', 101, makeCfg({ max_offers_per_session = 2 }))
    QuestVendor.AddStock('cid-limit', 'common', 10)

    state.now = state.now + 8000
    assert(findAction(QuestVendor.Tick(state.now), 'spawn_customer', 'cid-limit'))
    local offer1 = QuestVendor.CreateOffer('cid-limit', 'common', 1)
    assert(QuestVendor.RejectOffer('cid-limit', offer1.offerId))

    state.now = state.now + 15000
    assert(findAction(QuestVendor.Tick(state.now), 'spawn_customer', 'cid-limit'))
    local offer2 = QuestVendor.CreateOffer('cid-limit', 'common', 1)
    assert(QuestVendor.RejectOffer('cid-limit', offer2.offerId))

    state.now = state.now + 15000
    assert(findAction(QuestVendor.Tick(state.now), 'spawn_customer', 'cid-limit'))
    local offer3, err = QuestVendor.CreateOffer('cid-limit', 'common', 1)
    check('offer_limit',
        offer3 == nil and err == 'offer_limit',
        ('err=%s'):format(tostring(err)))
end

-- 17) 没库存不生成顾客：补货后下一次 Tick 才会生成
do
    newWorld()
    QuestVendor.Open('cid-empty', 'quest-hotdog', 101, makeCfg())
    state.now = state.now + 8000
    local beforeRestock = findAction(QuestVendor.Tick(state.now), 'spawn_customer', 'cid-empty')
    QuestVendor.AddStock('cid-empty', 'common', 1)
    local afterRestock = findAction(QuestVendor.Tick(state.now), 'spawn_customer', 'cid-empty')
    check('no_spawn_without_stock',
        beforeRestock == nil and afterRestock ~= nil,
        ('before=%s after=%s'):format(tostring(beforeRestock ~= nil),
            tostring(afterRestock ~= nil)))
end

-- 18) Tick 不产生任何网络事件/发钱：内核只返回动作
do
    newWorld()
    QuestVendor.Open('cid-tick', 'quest-hotdog', 101, makeCfg())
    QuestVendor.AddStock('cid-tick', 'common', 1)
    state.now = state.now + 8000
    local actions = QuestVendor.Tick(state.now)
    check('tick_actions_are_side_effect_free',
        type(actions) == 'table' and #actions == 1
            and actions[1].action == 'spawn_customer'
            and #state.netEvents == 0 and #state.clientEvents == 0
            and #state.moneyCalls == 0,
        ('actions=%d net=%d client=%d money=%d'):format(
            #actions, #state.netEvents, #state.clientEvents, #state.moneyCalls))
end

-- 19) 付款明确失败（AddMoney 返回 false）→ 库存回滚，不记销量/收入
do
    newWorld()
    local player = addPlayer('cid-payfail', { failNext = true })
    local session = QuestVendor.Open('cid-payfail', 'quest-hotdog', 101, makeCfg())
    QuestVendor.AddStock('cid-payfail', 'common', 1)
    local ok, err = QuestVendor.Purchase('cid-payfail', 'common', 1)
    check('money_failure_rolls_back_stock',
        ok == nil and err == 'money_failed'
            and session.stock.common == 1
            and session.sold == 0 and session.revenue == 0
            and #state.moneyCalls == 1
            and player.PlayerData.money.cash == 0,
        ('err=%s stock=%s sold=%s money=%d'):format(
            tostring(err), tostring(session.stock.common),
            tostring(session.sold), #state.moneyCalls))
end

-- ---------------------------------------------------------------------------
-- 汇总
-- ---------------------------------------------------------------------------

local failures = 0
for _, result in ipairs(results) do
    if not result.ok then failures = failures + 1 end
    print(('%-40s %s  %s'):format(result.name, result.ok and 'OK' or 'FAIL', result.detail))
end
print(('SUMMARY %d/%d'):format(#results - failures, #results))
os.exit(failures == 0 and 0 or 1)
