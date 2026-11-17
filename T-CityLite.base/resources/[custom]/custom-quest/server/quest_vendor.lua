-- server/quest_vendor.lua — 顾客会话（热狗线 S4）
--
-- 这一片只做「有人来买」的服务端内核：
--   * NPC 顾客的生成节奏 / 耐心 / 连续拒绝抑制（Tick 只返回动作，不 spawn、不发事件）
--   * 报价（金额、库存、一次性 offerId）
--   * 成交（NPC 报价与玩家购买两条路径共用库存与计价）
--
-- 职责边界（与 S1/S3 保持一致）：
--   * 会话是内存态；Close 立即删会话，重复 Close 返回 nil；
--   * 钱只走 Player.Functions 的现金入口（reason = quest-vendor-sale），一次成交一次调用；
--   * 本文件不注册网络事件、不 spawn 实体、不写库；Tick 只推进状态并返回动作，
--     由接线方（main.lua 的 exports / 客户端）决定怎么生成与提示。
--
-- 会话形态（字段名与 docs/plan/jobs-content/11-hotdog-dev-plan.md §S4 对齐）：
--   Session = {
--       citizenid, questId, boothNetId,
--       state = 'open',
--       stock = { exotic = 0, rare = 0, common = 0 },
--       raw = 30,
--       sold = 0, revenue = 0, served = 0,
--       -- served = 本班“接待过”的顾客数（NPC 成交/拒绝、玩家顾客成交各算 1 位；
--       -- 超时离开不算）；与 sold（售出份数，一单可能 2 份）分开，状态条显示的是顾客数。
--       offers = { [offerId] = { item, count, unitPrice, price, expiresAt, npcNetId, state } },
--       npc = { active, nextAt, consecutiveRejects, cooldownUntil },
--       seq = 0,
--   }
--
-- 串行策略（为什么不用 QuestMutex）：
--   QuestMutex 是按 questId + 玩家 source 加锁、30 分钟自动过期，而这里的临界区是
--   「一个会话的库存」，跨玩家、只持续一次 AddMoney 调用；套上去只会让锁的生命周期
--   和库存的生命周期错位。真正需要防的是 AddMoney 期间发生 yield（未来接 DB 时很可能）
--   导致两个买家都通过库存检查 —— 所以采用「先扣库存再发钱，失败回滚」+ 会话级 busy：
--   任何第二个请求要么看到已扣减的库存（sold_out），要么看到 busy，绝不会超卖。
--
-- 测试：tests/unit/layer3_business/fixtures/vendor_probe.lua 通过标记块抽取本文件
-- 的真实实现来跑；反向校验见同名 pytest。

-- [quest-vendor] begin
QuestVendor = QuestVendor or {}

--- 品质档位。顺序固定，便于测试与显示；库存/价格表的键都只认这三个。
local QUALITIES = { 'exotic', 'rare', 'common' }

--- 默认参数。全部可以在 Open 的 cfg 里覆盖；逻辑里不写死任何数字。
QuestVendor.DEFAULTS = {
    prices = { common = 6, rare = 9, exotic = 14 },          -- 每份单价（服务端唯一真相）
    quality_multiplier = { common = 1.0, rare = 1.0, exotic = 1.0 },
    item_ids = { common = 'hotdog_common', rare = 'hotdog_rare', exotic = 'hotdog_exotic' },
    first_customer_ms = { 8000, 15000 },
    interval_ms = { 15000, 40000 },
    -- 顾客走位时间：从 25–40 m 走过来。默认 45 s 覆盖 40 m 步行 + 绕路余量。
    inbound_budget_ms = 45000,
    patience_ms = 45000,
    max_global_npcs = 8,
    reject_cooldown_ms = 60000,
    max_rejects = 3,
    max_offers_per_session = 32,
    initial_raw = 30,                                        -- v1 抽象原料库存（推车自带）
}

--- citizenid → session
local Sessions = {}

-- ---------------------------------------------------------------------------
-- 时间与随机：都可注入，探针不 sleep、不吃真实随机
-- ---------------------------------------------------------------------------

--- 统一毫秒时钟。探针设置 QuestVendor._now（数字或函数）即可冻结时间。
---@return number
function QuestVendor.Now()
    local injected = QuestVendor._now
    if type(injected) == 'function' then
        local value = tonumber(injected())
        if value then return value end
    elseif type(injected) == 'number' then
        return injected
    end
    if type(GetGameTimer) == 'function' then
        return GetGameTimer()
    end
    return os.time() * 1000
end

--- 0..1 随机源。探针设成 0 就能拿到每个区间的最小值。
---@return number
function QuestVendor.Random01()
    local injected = QuestVendor._random
    local value = nil
    if type(injected) == 'function' then
        value = tonumber(injected())
    elseif type(injected) == 'number' then
        value = injected
    end
    if value then
        if value ~= value then return 0 end                 -- NaN
        if value <= 0 then return 0 end
        if value >= 1 then return 0.999999 end
        return value
    end
    return math.random()
end

--- 从 { min, max } 取一个整数毫秒；坏形状回落到 0。
---@param range table|nil
---@return number
local function randomMs(range)
    local min = tonumber(range and range[1]) or 0
    local max = tonumber(range and range[2]) or min
    if max < min then min, max = max, min end
    local span = max - min
    return math.floor(min + QuestVendor.Random01() * (span + 1))
end

-- ---------------------------------------------------------------------------
-- 配置归一化
-- ---------------------------------------------------------------------------

---@param value any
---@param default number
---@param allowZero boolean|nil
---@return number
local function intOr(value, default, allowZero)
    local number = tonumber(value)
    if not number or number ~= number then return default end
    number = math.floor(number)                 -- 先取整再校验：0.5 不能被当成「非零」
    if number < 0 or (number == 0 and not allowZero) then return default end
    return number
end

---@param value any
---@param default table
---@return table
local function rangeOr(value, default)
    local min, max = default[1], default[2]
    if type(value) == 'table' then
        local a, b = tonumber(value[1]), tonumber(value[2])
        if a and b and a == a and b == b then
            min, max = math.max(0, math.floor(a)), math.max(0, math.floor(b))
            if max < min then min, max = max, min end
        end
    end
    return { min, max }
end

--- 复制并校验配置。复制而不是引用：调用方之后改表不能影响已开的会话。
---@param config table|nil
---@return table
local function normalizeConfig(config)
    config = type(config) == 'table' and config or {}
    local defaults = QuestVendor.DEFAULTS

    local sourcePrices = type(config.prices) == 'table' and config.prices or {}
    local sourceMultipliers = type(config.quality_multiplier) == 'table'
        and config.quality_multiplier or {}
    local sourceItemIds = type(config.item_ids) == 'table' and config.item_ids or {}

    local prices, multipliers, itemIds = {}, {}, {}
    for _, quality in ipairs(QUALITIES) do
        local price = tonumber(sourcePrices[quality])
        if not price or price ~= price or price < 0 then
            price = defaults.prices[quality]
        end
        prices[quality] = price

        local multiplier = tonumber(sourceMultipliers[quality])
        if not multiplier or multiplier ~= multiplier or multiplier <= 0 then
            multiplier = defaults.quality_multiplier[quality]
        end
        multipliers[quality] = multiplier

        local itemId = sourceItemIds[quality]
        if type(itemId) ~= 'string' or itemId == '' then
            itemId = defaults.item_ids[quality]
        end
        itemIds[quality] = itemId
    end

    return {
        prices = prices,
        quality_multiplier = multipliers,
        item_ids = itemIds,
        first_customer_ms = rangeOr(config.first_customer_ms, defaults.first_customer_ms),
        interval_ms = rangeOr(config.interval_ms, defaults.interval_ms),
        inbound_budget_ms = intOr(config.inbound_budget_ms, defaults.inbound_budget_ms, false),
        patience_ms = intOr(config.patience_ms, defaults.patience_ms, false),
        max_global_npcs = intOr(config.max_global_npcs, defaults.max_global_npcs, false),
        reject_cooldown_ms = intOr(config.reject_cooldown_ms, defaults.reject_cooldown_ms, false),
        max_rejects = intOr(config.max_rejects, defaults.max_rejects, false),
        max_offers_per_session = intOr(config.max_offers_per_session,
            defaults.max_offers_per_session, false),
        initial_raw = intOr(config.initial_raw, defaults.initial_raw, true),
    }
end

--- item 既接受档位名（'rare'），也接受 S3 的物品 id（'hotdog_rare'）。
---@param cfg table
---@param item any
---@return string|nil quality
local function normalizeQuality(cfg, item)
    if type(item) ~= 'string' or item == '' then return nil end
    for _, quality in ipairs(QUALITIES) do
        if item == quality or item == cfg.item_ids[quality] then
            return quality
        end
    end
    return nil
end

--- 单价 = cfg.prices[品质] × cfg.quality_multiplier[品质]，四舍五入到整数。
---@param cfg table
---@param quality string
---@return number
local function unitPrice(cfg, quality)
    local base = tonumber(cfg.prices[quality]) or 0
    local multiplier = tonumber(cfg.quality_multiplier[quality]) or 1
    return math.max(0, math.floor(base * multiplier + 0.5))
end

-- ---------------------------------------------------------------------------
-- 会话小工具
-- ---------------------------------------------------------------------------

---@param session table
---@return number
local function stockTotal(session)
    local total = 0
    for _, quality in ipairs(QUALITIES) do
        total = total + (tonumber(session.stock[quality]) or 0)
    end
    return total
end

---@param session table
---@return table
local function stockCopy(session)
    return {
        exotic = session.stock.exotic or 0,
        rare = session.stock.rare or 0,
        common = session.stock.common or 0,
    }
end

--- 全局正在等待/点单的 NPC 数（跨所有会话）。
---@return number
local function activeNpcCount()
    local count = 0
    for _, session in pairs(Sessions) do
        if session.state == 'open' and session.npc.active then
            count = count + 1
        end
    end
    return count
end

--- 同一摊位是否已经有别的顾客（每摊 1 位）。
---@param boothNetId number
---@param exceptCitizenid string
---@return boolean
local function boothHasActiveNpc(boothNetId, exceptCitizenid)
    for citizenid, session in pairs(Sessions) do
        if citizenid ~= exceptCitizenid
            and session.state == 'open'
            and session.boothNetId == boothNetId
            and session.npc.active then
            return true
        end
    end
    return false
end

--- 顾客离开（拒绝/超时/耐心耗尽）后的计数与排期。
--- 连续拒绝达到 max_rejects 时进入冷却；冷却结束后仍按正常间隔排下一位。
---@param session table
---@param now number
local function registerReject(session, now)
    local npc = session.npc
    npc.consecutiveRejects = npc.consecutiveRejects + 1
    npc.nextAt = now + randomMs(session.cfg.interval_ms)
    if npc.consecutiveRejects >= session.cfg.max_rejects then
        npc.consecutiveRejects = 0
        npc.cooldownUntil = now + session.cfg.reject_cooldown_ms
    end
end

--- 让一位客户离开：清等待标记、按拒绝计数、排下一位。
---@param session table
---@param offer table|nil 未成交的报价（会被标记成 expired）
---@param now number
local function leaveCustomer(session, offer, now)
    if offer then
        offer.state = 'expired'
        offer.expiredAt = now
    end
    session.npc.active = false
    session.npc.offerId = nil
    session.npc.spawnedAt = nil
    registerReject(session, now)
end

-- ---------------------------------------------------------------------------
-- 玩家解析与付款
-- ---------------------------------------------------------------------------

--- 按 citizenid 找在线 Player。qb-core 各版本的导出不统一，按优先级依次尝试：
---   1. exports['qb-core']:GetPlayerByCitizenId（部分整合包会补这个导出）
---   2. 全局 QBCore.Functions.GetPlayerByCitizenId（本仓 qb-core 的权威实现）
---   3. GetCoreObject() 拿到的 Functions，最后才扫 GetPlayers + GetPlayer
--- 找不到就返回 nil —— 结算方此时必须放弃，不能动库存（离线玩家没有合法写入路径）。
---@param citizenid string
---@return table|nil
local function resolvePlayer(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return nil end

    local qb = nil
    local okExports, exported = pcall(function() return exports['qb-core'] end)
    if okExports then qb = exported end

    if qb then
        local okDirect, player = pcall(function() return qb:GetPlayerByCitizenId(citizenid) end)
        if okDirect and type(player) == 'table' then return player end
    end

    local core = nil
    if type(QBCore) == 'table' then
        core = QBCore
    elseif qb then
        local okCore, object = pcall(function() return qb:GetCoreObject() end)
        if okCore and type(object) == 'table' then core = object end
    end

    if core and type(core.Functions) == 'table' then
        local byCitizenid = core.Functions.GetPlayerByCitizenId
        if type(byCitizenid) == 'function' then
            local okPlayer, player = pcall(byCitizenid, citizenid)
            if okPlayer and type(player) == 'table' then return player end
        end

        local getPlayers = core.Functions.GetPlayers
        local getPlayer = core.Functions.GetPlayer
        if type(getPlayers) == 'function' and type(getPlayer) == 'function' then
            local okList, sources = pcall(getPlayers)
            if okList and type(sources) == 'table' then
                for _, source in ipairs(sources) do
                    local okOne, player = pcall(getPlayer, source)
                    if okOne and type(player) == 'table'
                        and type(player.PlayerData) == 'table'
                        and tostring(player.PlayerData.citizenid) == citizenid then
                        return player
                    end
                end
            end
        end
    end
    return nil
end

--- 成交付款：现金、一次成交一次调用、reason 固定。
--- 金额为 0 时不调用 AddMoney（qb-core 的 ValidateAmount 会拒绝 0）。
---@param player table
---@param amount number
---@return boolean paid
local function payCash(player, amount)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then return true end
    if type(player) ~= 'table' or type(player.Functions) ~= 'table'
        or type(player.Functions.AddMoney) ~= 'function' then
        return false
    end
    -- 用 pcall 包住是给「未来 AddMoney 内部接 DB」留的保险：抛错时调用方会回滚库存。
    local ok, paid = pcall(function()
        return player.Functions.AddMoney('cash', amount, 'quest-vendor-sale')
    end)
    if not ok then return false end
    return paid ~= false
end

-- ---------------------------------------------------------------------------
-- 生命周期
-- ---------------------------------------------------------------------------

--- 开卖：建会话并排第一位顾客。成功返回会话表；失败返回 nil, reason。
---@param citizenid string
---@param questId string
---@param boothNetId number
---@param cfg table|nil
---@return table|nil session
---@return string|nil reason
function QuestVendor.Open(citizenid, questId, boothNetId, cfg)
    if type(citizenid) ~= 'string' or citizenid == '' then return nil, 'bad_args' end
    if type(questId) ~= 'string' or questId == '' then return nil, 'bad_args' end

    local netId = tonumber(boothNetId)
    if not netId or netId ~= netId or netId <= 0 or netId % 1 ~= 0 then
        return nil, 'bad_args'
    end
    if Sessions[citizenid] then return nil, 'already_open' end

    local config = normalizeConfig(cfg)
    local now = tonumber(type(cfg) == 'table' and cfg.now) or QuestVendor.Now()

    local session = {
        citizenid = citizenid,
        questId = questId,
        boothNetId = math.floor(netId),
        state = 'open',
        stock = { exotic = 0, rare = 0, common = 0 },
        raw = config.initial_raw,
        sold = 0,
        revenue = 0,
        served = 0,   -- 本班已接待的顾客数（NPC 成交/拒绝、玩家成交各 1；超时不加）
        offers = {},
        npc = {
            active = false,
            nextAt = now + randomMs(config.first_customer_ms),
            consecutiveRejects = 0,
            cooldownUntil = 0,
        },
        seq = 0,
        cfg = config,
        openedAt = now,
    }
    Sessions[citizenid] = session
    return session
end

--- 打烊：清会话并返回汇总。重复调用返回 nil（不报错）。
--- 传了 questId 但与会话不符时不关（避免 A 任务结束把 B 摊位的库存结掉）。
---@param citizenid string
---@param questId string|nil
---@param reason string|nil
---@return table|nil summary { sold, revenue, stock, raw, ... }
function QuestVendor.Close(citizenid, questId, reason)
    local session = Sessions[citizenid]
    if not session then return nil end
    if questId and session.questId ~= questId then return nil end

    Sessions[citizenid] = nil
    return {
        citizenid = session.citizenid,
        questId = session.questId,
        boothNetId = session.boothNetId,
        sold = session.sold,
        revenue = session.revenue,
        stock = stockCopy(session),
        raw = session.raw,
        reason = reason or 'closed',
    }
end

--- 取会话（只读用途；不要拿它改状态）。
---@param citizenid string
---@return table|nil
function QuestVendor.Get(citizenid)
    return Sessions[citizenid]
end

--- 当前打开的会话数（运维/测试）。
---@return number
function QuestVendor.ActiveSessionCount()
    local count = 0
    for _ in pairs(Sessions) do count = count + 1 end
    return count
end

-- ---------------------------------------------------------------------------
-- 库存 / 原料
-- ---------------------------------------------------------------------------

--- S3 做出一份热狗后加库存。
---@param citizenid string
---@param quality string|nil 'exotic' | 'rare' | 'common'（也接受 hotdog_* 物品 id）
---@param count number
---@return boolean|nil ok
---@return number|string reasonOrNewCount
function QuestVendor.AddStock(citizenid, quality, count)
    local session = Sessions[citizenid]
    if not session then return nil, 'closed' end

    local tier = normalizeQuality(session.cfg, quality)
    if not tier then return nil, 'bad_item' end

    local amount = tonumber(count)
    if not amount or amount ~= amount or amount <= 0 or amount % 1 ~= 0 then
        return nil, 'bad_count'
    end

    session.stock[tier] = session.stock[tier] + math.floor(amount)
    return true, session.stock[tier]
end

--- 消耗一份原料。不够返回 false, 'no_raw'（与调用方约定，不抛错）。
---@param citizenid string
---@return boolean|nil ok
---@return number|string reasonOrRemaining
function QuestVendor.ConsumeRaw(citizenid)
    local session = Sessions[citizenid]
    if not session then return nil, 'closed' end
    if session.raw <= 0 then return false, 'no_raw' end

    session.raw = session.raw - 1
    return true, session.raw
end

-- ---------------------------------------------------------------------------
-- 报价（NPC 路径）
-- ---------------------------------------------------------------------------

-- [quest-vendor-offer-lifetime] begin
--- 报价生命周期 = 走位时间 + 决策耐心。
--- 顾客在 25–40 m 外生成、走到摊位前才看得到面板；如果 expiresAt 只加 patience，
--- 走位会吃掉玩家一大半决策时间。cfg 来自 normalizeConfig，两段都已归一化成正整数。
--- 服务端仍然只有一个绝对过期时刻 —— 客户端不报到位也不会让报价永远活着。
---@param cfg table|nil
---@return number
local function offerLifetimeMs(cfg)
    local inbound = math.max(0, math.floor(tonumber(cfg and cfg.inbound_budget_ms) or 0))
    local patience = math.max(0, math.floor(tonumber(cfg and cfg.patience_ms) or 0))
    return inbound + patience
end
-- [quest-vendor-offer-lifetime] end

--- 生成报价。客户端/接线方只能给 item + count，金额一律按会话配置算。
---@param citizenid string
---@param item string 'exotic' | 'rare' | 'common'（也接受 hotdog_* 物品 id）
---@param count number
---@param npcNetId number|nil 可选：顾客实体 netId，仅用于回传/清理
---@return table|nil offer
---@return string|nil reason
function QuestVendor.CreateOffer(citizenid, item, count, npcNetId)
    local session = Sessions[citizenid]
    if not session or session.state ~= 'open' then return nil, 'closed' end

    local tier = normalizeQuality(session.cfg, item)
    if not tier then return nil, 'bad_item' end

    local amount = tonumber(count)
    if not amount or amount ~= amount or amount <= 0 or amount % 1 ~= 0 then
        return nil, 'bad_count'
    end
    amount = math.floor(amount)

    if not session.npc.active then return nil, 'no_customer' end

    local pending = session.npc.offerId and session.offers[session.npc.offerId]
    if pending and pending.state == 'open' then return nil, 'offer_pending' end

    if session.seq >= session.cfg.max_offers_per_session then
        return nil, 'offer_limit'
    end

    -- 库存不足在报价时就拒绝：不让玩家等到成交才发现卖不了。
    if (session.stock[tier] or 0) < amount then
        return nil, 'insufficient_stock'
    end

    local now = QuestVendor.Now()
    local unit = unitPrice(session.cfg, tier)
    session.seq = session.seq + 1
    local offerId = ('offer-%s-%d'):format(tostring(citizenid), session.seq)

    local offer = {
        offerId = offerId,
        citizenid = citizenid,
        item = tier,
        count = amount,
        unitPrice = unit,
        price = unit * amount,
        -- 生命周期 = 走位时间 + 决策耐心：走位不能吃掉玩家的决策窗口。
        expiresAt = now + offerLifetimeMs(session.cfg),
        npcNetId = tonumber(npcNetId) or nil,
        state = 'open',
        createdAt = now,
    }
    session.offers[offerId] = offer
    session.npc.offerId = offerId

    return {
        offerId = offerId,
        item = tier,
        count = amount,
        unitPrice = unit,
        price = unit * amount,
        expiresAt = offer.expiresAt,
        inboundMs = session.cfg.inbound_budget_ms,
        patienceMs = session.cfg.patience_ms,
        npcNetId = offer.npcNetId,
    }
end

--- 成交 NPC 报价：一次性 offerId、未过期、库存够、钱由服务端算。
--- 失败路径一律不动库存/钱；成功路径先扣库存再发钱，发钱失败回滚。
---@param citizenid string
---@param offerId string
---@return boolean|nil ok
---@return table|string resultOrReason
function QuestVendor.SettleOffer(citizenid, offerId)
    local session = Sessions[citizenid]
    if not session or session.state ~= 'open' then return nil, 'closed' end
    if type(offerId) ~= 'string' or offerId == '' then return nil, 'unknown_offer' end

    local offer = session.offers[offerId]
    if not offer then return nil, 'unknown_offer' end

    -- 这一条就是幂等闸：第二次结算必须在任何扣减之前返回。
    -- 注意：这里没有「state ~= open 一律拒绝」的兜底分支 —— 否则把上面这条
    -- already_settled 判断删掉后，兜底会替它挡住重放，反向校验就测不出重复加钱。
    if offer.state == 'settled' then return nil, 'already_settled' end
    if offer.state == 'expired' then return nil, 'expired' end
    if offer.state == 'rejected' then return nil, 'rejected' end

    -- AddMoney 是唯一的潜在 yield 点；它还没返回时，第二个请求只能看到 busy。
    if offer.settling or session.busy then return nil, 'busy' end

    local now = QuestVendor.Now()
    if now > offer.expiresAt then
        leaveCustomer(session, offer, now)
        return nil, 'expired'
    end

    if (session.stock[offer.item] or 0) < offer.count then
        return nil, 'insufficient_stock'
    end

    local player = resolvePlayer(citizenid)
    if not player then return nil, 'no_player' end

    offer.settling = true
    session.busy = true
    session.stock[offer.item] = session.stock[offer.item] - offer.count
    local paid = payCash(player, offer.price)
    session.busy = false

    if not paid then
        session.stock[offer.item] = session.stock[offer.item] + offer.count
        offer.settling = false
        return nil, 'money_failed'
    end

    offer.settling = false
    offer.state = 'settled'
    offer.settledAt = now
    session.sold = session.sold + offer.count
    session.revenue = session.revenue + offer.price
    session.served = session.served + 1   -- 一位顾客（不是一份热狗）
    session.npc.active = false
    session.npc.offerId = nil
    session.npc.spawnedAt = nil
    session.npc.consecutiveRejects = 0
    session.npc.nextAt = now + randomMs(session.cfg.interval_ms)

    return true, {
        offerId = offerId,
        item = offer.item,
        count = offer.count,
        unitPrice = offer.unitPrice,
        price = offer.price,
        sold = session.sold,
        revenue = session.revenue,
        stock = session.stock[offer.item],
    }
end

--- 玩家按 N 拒绝报价。没有这个入口，连续拒绝抑制就无法被玩法触发。
---@param citizenid string
---@param offerId string
---@return boolean|nil ok
---@return table|string resultOrReason
function QuestVendor.RejectOffer(citizenid, offerId)
    local session = Sessions[citizenid]
    if not session or session.state ~= 'open' then return nil, 'closed' end
    if type(offerId) ~= 'string' or offerId == '' then return nil, 'unknown_offer' end

    local offer = session.offers[offerId]
    if not offer then return nil, 'unknown_offer' end
    -- 只接受还活着的报价；已结算/已过期/已拒绝统一返回自身状态。
    if offer.state ~= 'open' then return nil, offer.state end
    if offer.settling or session.busy then return nil, 'busy' end

    local now = QuestVendor.Now()
    if now > offer.expiresAt then
        leaveCustomer(session, offer, now)
        return nil, 'expired'
    end

    offer.state = 'rejected'
    offer.rejectedAt = now
    session.npc.active = false
    session.npc.offerId = nil
    session.npc.spawnedAt = nil
    -- 拒绝也是一次“接待”：玩家确实处理了这位顾客，只是没成交。
    -- 超时离开（leaveCustomer）不计，因为玩家从头到尾没接手。
    session.served = session.served + 1
    registerReject(session, now)

    return true, {
        offerId = offerId,
        consecutiveRejects = session.npc.consecutiveRejects,
        cooldownUntil = session.npc.cooldownUntil,
        nextAt = session.npc.nextAt,
    }
end

-- ---------------------------------------------------------------------------
-- 玩家购买（另一条路径，共用库存与计价）
-- ---------------------------------------------------------------------------

--- 玩家直接购买成品。与 NPC 报价共用库存和价格表，同样串行扣减。
---@param citizenid string
---@param item string
---@param count number
---@return boolean|nil ok
---@return table|string resultOrReason
function QuestVendor.Purchase(citizenid, item, count)
    local session = Sessions[citizenid]
    if not session or session.state ~= 'open' then return nil, 'closed' end

    local tier = normalizeQuality(session.cfg, item)
    if not tier then return nil, 'bad_item' end

    local amount = tonumber(count)
    if not amount or amount ~= amount or amount <= 0 or amount % 1 ~= 0 then
        return nil, 'bad_count'
    end
    amount = math.floor(amount)

    -- 库存检查放在 busy 之前：最后一份被前一个请求预扣后，第二个买家
    -- 自然拿到 sold_out，而不是一个不可重试的 busy。
    if (session.stock[tier] or 0) < amount then
        return nil, 'sold_out'
    end
    if session.busy then return nil, 'busy' end

    local player = resolvePlayer(citizenid)
    if not player then return nil, 'no_player' end

    local unit = unitPrice(session.cfg, tier)
    local total = unit * amount

    session.busy = true
    session.stock[tier] = session.stock[tier] - amount
    local paid = payCash(player, total)
    session.busy = false

    if not paid then
        session.stock[tier] = session.stock[tier] + amount
        return nil, 'money_failed'
    end

    session.sold = session.sold + amount
    session.revenue = session.revenue + total
    -- 玩家顾客也占一位（一次购买算一位顾客，不按份数累加）。
    session.served = session.served + 1

    return true, {
        item = tier,
        count = amount,
        unitPrice = unit,
        total = total,
        sold = session.sold,
        revenue = session.revenue,
        stock = session.stock[tier],
    }
end

-- ---------------------------------------------------------------------------
-- Tick：纯推进
-- ---------------------------------------------------------------------------

--- 推进所有打开会话，返回动作列表。不 spawn、不发事件、不碰钱。
--- 动作：
---   { action='spawn_customer', citizenid, questId, boothNetId }
---   { action='offer_expired',  citizenid, questId, boothNetId, offerId, item, count, npcNetId }
---   { action='npc_timeout',    citizenid, questId, boothNetId }
---@param now number|nil
---@return table[] actions
function QuestVendor.Tick(now)
    now = tonumber(now) or QuestVendor.Now()
    local actions = {}

    for _, session in pairs(Sessions) do
        if session.state == 'open' then
            -- 1) 报价过期：顾客离开，库存/钱都不动，拒绝计数 +1。
            --    正在结算（AddMoney 未返回）的报价不能被 Tick 抢先判过期。
            for offerId, offer in pairs(session.offers) do
                if offer.state == 'open' and not offer.settling and now > offer.expiresAt then
                    leaveCustomer(session, offer, now)
                    actions[#actions + 1] = {
                        action = 'offer_expired',
                        citizenid = session.citizenid,
                        questId = session.questId,
                        boothNetId = session.boothNetId,
                        offerId = offerId,
                        item = offer.item,
                        count = offer.count,
                        npcNetId = offer.npcNetId,
                    }
                end
            end

            -- 2) 已经生成但迟迟没下单的顾客（接线方没调 CreateOffer）不能永久占坑。
            if session.npc.active and not session.npc.offerId
                and session.npc.spawnedAt
                and (now - session.npc.spawnedAt) > session.cfg.patience_ms then
                session.npc.active = false
                session.npc.spawnedAt = nil
                registerReject(session, now)
                actions[#actions + 1] = {
                    action = 'npc_timeout',
                    citizenid = session.citizenid,
                    questId = session.questId,
                    boothNetId = session.boothNetId,
                }
            end

            -- 3) 该来下一位了：每摊 1 位、每玩家 1 位（会话唯一）、全局上限。
            if not session.npc.active
                and now >= session.npc.nextAt
                and now >= session.npc.cooldownUntil
                and stockTotal(session) > 0
                and not boothHasActiveNpc(session.boothNetId, session.citizenid)
                and activeNpcCount() < session.cfg.max_global_npcs then
                session.npc.active = true
                session.npc.spawnedAt = now
                session.npc.offerId = nil
                actions[#actions + 1] = {
                    action = 'spawn_customer',
                    citizenid = session.citizenid,
                    questId = session.questId,
                    boothNetId = session.boothNetId,
                }
            end
        end
    end

    return actions
end

--- 测试/运维用：清空内存态（不碰钱、不写库）。
function QuestVendor.Reset()
    Sessions = {}
end
-- [quest-vendor] end

print('[quest-vendor] ready')
