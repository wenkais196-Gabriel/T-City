-- server/quest_vendor_bridge.lua — 把 S4 内核接到 quest 的事件平面上
--
-- quest_vendor.lua 是一片纯内核：不认识 source、不 spawn、不推事件。
-- 本文件负责：
--   1. 摊位摆好 → 开会话 → 推 `quest:client:vendorState`
--   2. 每秒 Tick → 把 `spawn_customer` 变成真的报价 → 推 `quest:client:vendorOffer`
--   3. 接收客户端动作 → 校验 → 调内核 → 回执
--
-- 只开**一条**新的 net event：`quest:server:vendorAction`。
-- 理由：成交 / 拒绝 / 购买都是玩家主动动作，没有既有通用通道可借
-- （`nodeComplete` 会推进任务 —— 借它等于「买一根热狗就把任务推进一格」）。
-- 合成一条带 action 白名单的事件，入口与校验点各只有一个，比开四条更好审计。
--
-- 这条事件的校验（全部在服务端）：
--   * action 白名单（accept / reject / purchase），其余直接丢弃
--   * 限流：每人 5 秒内最多 10 次
--   * 距离：必须在摊位 6 m 内（买家也一样，不能远程下单）
--   * 归属：accept / reject 只能由摊主本人发；买家不能买自己摊上的
--
-- 买家的钱：内核的 `Purchase` 只负责「扣库存 + 给摊主记收入」，它不知道买家是谁。
-- 所以买家这条路径**先扣买家**，内核失败再把钱退回去 —— 顺序反过来，
-- 一旦买家付不出，食物已经发出去了。

QuestVendorBridge = QuestVendorBridge or {}

local ACTIONS = { accept = true, reject = true, purchase = true, cook = true, close = true, move = true }
local ACTION_WINDOW_MS = 5000
local ACTION_LIMIT = 10
local NEAR_BOOTH = 6.0

--- 旁观者推送半径：交互距离是 6 m，广播 10 m 让正在走近的玩家提前拿到摊位状态。
local PUBLIC_RADIUS = 10.0

--- citizenid → { count, windowStart }
local Rate = {}
--- citizenid → true（该摊的 Tick 循环是否在跑）
local Ticking = {}
--- citizenid → stepId（客户端收摊时要拿它回调 nodeComplete）
local StepIds = {}
--- 最近一次 CloseFor 的汇总（citizenid → { summary, questId, at }）。
--- 为什么需要：摊主按 E 收摊时 CloseFor 已经把会话销毁并返回汇总；任务完成路径
--- 会再调一次 CloseFor（此时已无会话 → nil），账单的售出 / 成品回收 / 原料回收行
--- 就会全变 0。这份缓存只给「收摊之后的终结路径」取一次，取走即删。
local LastSummary = {}
--- 缓存上界：超过 30 分钟不再用于结算；同一 citizenid 开新会话也会清掉。
local SUMMARY_TTL_MS = 30 * 60 * 1000

local function NowMs()
    if type(GetGameTimer) == 'function' then return GetGameTimer() end
    return os.time() * 1000
end

local function ResolvePlayer(citizenid)
    if type(citizenid) ~= 'string' then return nil end
    local players = type(GetPlayers) == 'function' and GetPlayers() or {}
    for _, rawSrc in ipairs(players) do
        local src = tonumber(rawSrc)
        local player = src and exports['qb-core']:GetPlayer(src)
        if player and player.PlayerData and player.PlayerData.citizenid == citizenid then
            return player
        end
    end
    return nil
end

--- 摊位的摆放配置（服务端挪位时复用同一套判据）
local function boothStepCfgOf(questId)
    if type(QuestRegistry) ~= 'table' or type(QuestRegistry.GetTemplate) ~= 'function' then return nil end
    local template = QuestRegistry.GetTemplate(questId)
    for _, step in ipairs(template and template.steps or {}) do
        if step.type == 'booth' and step.data then return step.data end
    end
    return nil
end
--- 模板里「售卖」那一步的 id。收摊由服务端推进，不再让客户端报 stepId ——
-- 客户端手里那个 stepId 是**摆摊**那一步的（`vendorState` 是开卖时推的），
-- 拿它去 nodeComplete 会被判 `Step order violation`（真机已实测：
-- expected step_sell, got step_place_stand，红字刷屏）。
local function vendorStepIdOf(questId)
    if type(QuestRegistry) ~= 'table' or type(QuestRegistry.GetTemplate) ~= 'function' then return nil end
    local template = QuestRegistry.GetTemplate(questId)
    for _, step in ipairs(template and template.steps or {}) do
        if step.type == 'vendor' then return step.id end
    end
    return nil
end
local function PushState(citizenid, reason)
    local player = ResolvePlayer(citizenid)
    if not player then return end
    local session = QuestVendor and QuestVendor.Get and QuestVendor.Get(citizenid)
    if not session then return end
    TriggerClientEvent('quest:client:vendorState', player.PlayerData.source, {
        questId = session.questId,
        stepId = StepIds[citizenid],
        boothNetId = session.boothNetId,
        state = session.state,
        stock = session.stock,
        raw = session.raw,
        prices = session.cfg and session.cfg.prices or {},
        sold = session.sold,
        revenue = session.revenue,
        reason = reason,
    })
end

--- 摊位摆好后开会话（由 validate_booth_place 成功路径调用）
---@param source number
---@param citizenid string
---@param questId string
---@param boothNetId number
---@param cfg table|nil 价格 / 节奏（没给就用内核默认）
---@param stepId string|nil 客户端收摊时要回调的步骤 id
---@return boolean ok
---@return string|nil err
function QuestVendorBridge.OpenFor(source, citizenid, questId, boothNetId, cfg, stepId)
    if type(QuestVendor) ~= 'table' or type(QuestVendor.Open) ~= 'function' then
        return false, 'vendor_unavailable'
    end
    local session, err = QuestVendor.Open(citizenid, questId, boothNetId, cfg)
    if not session then return false, err end

    -- 新会话开始 = 上一班的汇总作废，避免旧数据被下一班的完成路径取走。
    LastSummary[citizenid] = nil

    StepIds[citizenid] = stepId

    -- 初始库存：S3 的小游戏还没接进客户端，`AddStock` 暂时没有调用方。
    -- 不给起始货的话 Tick 永远不会说「可以来顾客」（它要求 stockTotal > 0），
    -- 真机表现就是「摆好摊以后一个人都不来」。接了做热狗之后再把这个配置去掉。
    local starting = type(cfg) == 'table' and cfg.starting_stock or nil
    if type(starting) == 'table' then
        for quality, count in pairs(starting) do
            local amount = tonumber(count)
            if amount and amount > 0 then QuestVendor.AddStock(citizenid, quality, amount) end
        end
    end

    PushState(citizenid, 'opened')
    QuestVendorBridge.PushBystanders(citizenid)
    QuestVendorBridge.StartTick(citizenid)
    print(('[vendor-bridge] 🍔 开卖：%s | %s | netId=%s'):format(
        citizenid, tostring(questId), tostring(boothNetId)))
    return true, nil
end

--- 关会话（收摊 / 任务结束 / 断线）。幂等。
--- 返回值语义不变：能关掉会话时返回汇总，重复调用仍返回 nil。
function QuestVendorBridge.CloseFor(citizenid, questId, reason)
    if type(QuestVendor) ~= 'table' or type(QuestVendor.Close) ~= 'function' then return nil end
    local summary = QuestVendor.Close(citizenid, questId, reason)
    QuestVendorBridge.StopTick(citizenid)
    StepIds[citizenid] = nil
    PushState(citizenid, 'closed')
    -- 会话已经销毁（或 questId 不匹配时仍在），PushBystanders 按剩余会话推导 open/closed。
    QuestVendorBridge.PushBystanders(citizenid)
    -- 只多存一份，不改返回值：给「收摊之后才完成」的路径取用。
    -- 写缓存时顺手清一遍过期项，避免只有 Close 才触发清理导致表无界增长。
    if summary then
        local now = NowMs()
        for other, entry in pairs(LastSummary) do
            if now - entry.at > SUMMARY_TTL_MS then LastSummary[other] = nil end
        end
        LastSummary[citizenid] = { summary = summary, questId = summary.questId, at = now }
    end
    return summary
end

--- 取走最近一次 CloseFor 的汇总（一次性消费）。
--- 完成路径在第二次 CloseFor 拿到 nil 之后调用它；任务不匹配或已过期时返回 nil，
--- 且不会误删别的任务的缓存。
---@param citizenid string
---@param questId string|nil 传了就只接受同一任务的缓存
---@return table|nil summary
function QuestVendorBridge.TakeLastSummary(citizenid, questId)
    if type(citizenid) ~= 'string' then return nil end
    local entry = LastSummary[citizenid]
    if not entry then return nil end
    if NowMs() - entry.at > SUMMARY_TTL_MS then
        LastSummary[citizenid] = nil
        return nil
    end
    if questId and entry.questId ~= questId then return nil end
    -- 一次性消费：取走即删，重复调用返回 nil。
    LastSummary[citizenid] = nil
    return entry.summary
end

--- 每摊一个 Tick 循环：1 秒一次，会话关闭即退出。
--- 为什么不是全局一个循环：全局要扫所有会话，且一个摊卡住会拖慢所有人；
--- 每摊一个的开销只是「每秒一次表查询」。
function QuestVendorBridge.StartTick(citizenid)
    if Ticking[citizenid] then return end
    Ticking[citizenid] = true

    CreateThread(function()
        while Ticking[citizenid] do
            Wait(1000)
            if not Ticking[citizenid] then break end

            local session = QuestVendor and QuestVendor.Get and QuestVendor.Get(citizenid)
            if not session or session.state ~= 'open' then
                Ticking[citizenid] = nil
                break
            end

            local actions = QuestVendor.Tick(NowMs()) or {}
            for _, action in ipairs(actions) do
                if action.action == 'spawn_customer' and action.citizenid == citizenid then
                    QuestVendorBridge.OfferToOwner(citizenid)
                elseif action.action == 'offer_expired' and action.citizenid == citizenid then
                    local player = ResolvePlayer(citizenid)
                    if player then
                        TriggerClientEvent('quest:client:vendorOfferExpired',
                            player.PlayerData.source, { offerId = action.offerId })
                    end
                end
            end

            PushState(citizenid, 'update')
            -- 每秒一次：让刚走进 10 m 的玩家补到摊位状态，菜单才会出现。
            QuestVendorBridge.PushBystanders(citizenid)
        end
    end)
end

function QuestVendorBridge.StopTick(citizenid)
    Ticking[citizenid] = nil
end

--- 挑一个「有库存的口味 + 不超过库存的份数」生成报价。
--- 口味与份数在服务端随机，金额仍由内核按 cfg 查表算 —— 客户端全程没有机会改价。
function QuestVendorBridge.OfferToOwner(citizenid)
    local session = QuestVendor and QuestVendor.Get and QuestVendor.Get(citizenid)
    if not session then return end

    local available = {}
    for _, quality in ipairs({ 'exotic', 'rare', 'common' }) do
        if (session.stock[quality] or 0) > 0 then
            available[#available + 1] = quality
        end
    end
    if #available == 0 then return end

    local pick = available[math.random(#available)]
    local stock = session.stock[pick] or 0
    local count = (stock >= 2 and math.random() < 0.5) and 2 or 1

    local offer, err = QuestVendor.CreateOffer(citizenid, pick, count)
    if not offer then
        -- offer_pending / offer_limit 属于正常节奏，不刷日志
        if err ~= 'offer_pending' and err ~= 'offer_limit' then
            print(('[vendor-bridge] ⚠️ CreateOffer 失败：%s | %s'):format(citizenid, tostring(err)))
        end
        return
    end

    local player = ResolvePlayer(citizenid)
    if not player then return end
    TriggerClientEvent('quest:client:vendorOffer', player.PlayerData.source, {
        questId = session.questId,
        stepId = StepIds[citizenid],
        offerId = offer.id,
        item = offer.item,
        count = offer.count,
        unitPrice = offer.unitPrice,
        price = offer.price,
        expiresAt = offer.expiresAt,
    })
end

--- 做热狗的小游戏配置（三档：0 失误异域 / 1 失误稀有 / ≥2 普通）。
-- 放在函数里而不是常量：调用方（模板）将来要能按等级换难度。
function QuestVendorBridge.CookConfig()
    return {
        ttl_sec = 60,
        count = 10,        -- KeyMinigame(10)：10 个键
        max_faults = 10,
        tiers = {
            { max_faults = 0, tier = 'exotic', item = 'hotdog_exotic' },
            { max_faults = 1, tier = 'rare', item = 'hotdog_rare' },
            { max_faults = 10, tier = 'common', item = 'hotdog_common' },
        },
    }
end
--- 限流：每人 5 秒最多 10 次动作
local function RateLimited(citizenid)
    local now = NowMs()
    local record = Rate[citizenid]
    if not record or (now - record.windowStart) > ACTION_WINDOW_MS then
        Rate[citizenid] = { count = 1, windowStart = now }
        return false
    end
    record.count = record.count + 1
    return record.count > ACTION_LIMIT
end

local function NearBooth(source, booth)
    if type(booth) ~= 'table' or type(booth.x) ~= 'number' then return true end
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return false end
    local coords = GetEntityCoords(ped)
    local dx, dy = coords.x - booth.x, coords.y - booth.y
    return (dx * dx + dy * dy) <= (NEAR_BOOTH * NEAR_BOOTH)
end

local function UnitPriceOf(session, item)
    local prices = session and session.cfg and session.cfg.prices
    local price = type(prices) == 'table' and prices[item]
    return tonumber(price)
end

-- [vendor-bystander] begin
-- 旁观者 payload 的**唯一**构造点。返回表的键就是字段白名单：
--   isOwner / boothNetId / state / coords / items（可买档位 + 单价）。
-- 库存明细、收入、押金、顾客报价、citizenid、玩家名一律不进来。
-- 运行时探针 tests/unit/layer3_business/fixtures/vendor_bystander_probe.lua
-- 会喂一个塞满摊主私有字段的假会话，并深扫返回值。
local PUBLIC_QUALITIES = { 'common', 'rare', 'exotic' }

---@param booth table QuestBooth 记录（netId / x / y / z）
---@param session table|nil 会话；打烊后为 nil
---@param state string 'open' | 'closed'
---@return table payload
function QuestVendorBridge.BuildBystanderPayload(booth, session, state)
    local items = {}
    if state == 'open' and type(session) == 'table' then
        local prices = type(session.cfg) == 'table' and session.cfg.prices or {}
        local stock = type(session.stock) == 'table' and session.stock or {}
        for _, quality in ipairs(PUBLIC_QUALITIES) do
            local unitPrice = tonumber(prices[quality])
            local count = tonumber(stock[quality]) or 0
            if unitPrice and unitPrice > 0 and count > 0 then
                items[#items + 1] = { quality = quality, unitPrice = unitPrice }
            end
        end
    end
    return {
        isOwner = false,
        boothNetId = booth.netId,
        state = state,
        coords = { x = booth.x, y = booth.y, z = booth.z },
        items = items,
    }
end
-- [vendor-bystander] end

--- 只给摊位附近的旁观者：与摊主 PushState 完全分开，避免把私有字段带出去。
--- 受众由 Broadcast.Scope 按坐标计算；这里**不**用 TriggerClientEvent(..., -1)。
--- 每台摊位的 Tick（1 秒）也会调用它，让刚走进半径的玩家能补到当前状态。
---@param citizenid string
---@return number recipients
function QuestVendorBridge.PushBystanders(citizenid)
    if type(Broadcast) ~= 'table' or type(Broadcast.Scope) ~= 'function' then return 0 end
    if type(QuestBooth) ~= 'table' or type(QuestBooth.Get) ~= 'function' then return 0 end

    local booth = QuestBooth.Get(citizenid)
    if type(booth) ~= 'table' or type(booth.x) ~= 'number' then return 0 end

    local session = nil
    if type(QuestVendor) == 'table' and type(QuestVendor.Get) == 'function' then
        session = QuestVendor.Get(citizenid)
    end
    local state = session and session.state == 'open' and 'open' or 'closed'
    local payload = QuestVendorBridge.BuildBystanderPayload(booth, session, state)
    return Broadcast.Scope('quest:client:vendorState', {
        coords = vector3(booth.x, booth.y, booth.z),
        radius = PUBLIC_RADIUS,
    }, payload)
end

--- 入口鉴权：这一个函数就是 `quest:server:vendorAction` 的全部守卫证据
-- （tests/architecture/net_event_guard_helpers.json 里登记的就是它）。
-- 刻意做成「一次调用、三个返回值」，而不是把校验散在 handler 里 ——
-- 散着写的话，闸门只能看见「handler 里有 GetPlayer」，看不见「校验失败一定 return」。
QuestVendorGuard = QuestVendorGuard or {}

--- 结果写进调用方给的 ctx 表：这样调用点可以写成闸门要的形状
-- `if not QuestVendorGuard.Validate(...) then return end` ——
-- 多返回值写法闸门认不出来，会把这条事件当成「没鉴权」。
function QuestVendorGuard.Validate(src, action, payload, ctx)
    if type(ctx) ~= 'table' then return false end
    local Player = exports['qb-core']:GetPlayer(src)
    if not Player then return false end
    local citizenid = Player.PlayerData.citizenid
    if type(citizenid) ~= 'string' or citizenid == '' then return false end
    if type(action) ~= 'string' or not ACTIONS[action] then return false end
    if type(payload) ~= 'table' then return false end
    if RateLimited(citizenid) then return false end
    ctx.player = Player
    ctx.citizenid = citizenid
    return true
end

RegisterNetEvent('quest:server:vendorAction', function(action, payload)
    local ctx = {}
    if not QuestVendorGuard.Validate(source, action, payload, ctx) then return end
    local Player, citizenid = ctx.player, ctx.citizenid
    local src = source

    -- 做热狗：两段式。start 发 nonce（一次性），report 交 faults。
    -- faults 是客户端唯一能编的数字，所以服务端从 nonce 反查会话、按 tiers 映射品质，
    -- 客户端拿不到「直接说我做了一份异域热狗」这条路。
    if action == 'cook' then
        local session = QuestVendor.Get(citizenid)
        if not session or session.state ~= 'open' then
            TriggerClientEvent('QBCore:Notify', src, '先摆摊才能做热狗', 'error', 4000)
            return
        end

        local mode = payload.mode
        if mode == 'start' then
            if (session.raw or 0) <= 0 then
                TriggerClientEvent('QBCore:Notify', src, '原料用完了', 'error', 4000)
                return
            end
            local nonce, err = QuestMinigame.Start(citizenid, session.questId, 'cook', QuestVendorBridge.CookConfig())
            if not nonce then
                local messages = { already_open = '正在做上一份', bad_config = '小游戏配置有问题' }
                TriggerClientEvent('QBCore:Notify', src, messages[err] or '现在做不了', 'error', 4000)
                return
            end
            TriggerClientEvent('quest:client:cookStart', src, { nonce = nonce })
            return
        end

        if mode == 'report' then
            local nonce = payload.nonce
            local ok, result = QuestMinigame.Resolve(citizenid, nonce, {
                faults = payload.faults,
                quit = payload.quit == true,
            })
            if not ok then
                local messages = {
                    already_used = '这次已经结算过了',
                    unknown_nonce = '没有这次制作',
                    expired = '太慢了，这份废了',
                    bad_faults = '上报数据不合法',
                    wrong_owner = '不是你的这次制作',
                }
                TriggerClientEvent('QBCore:Notify', src, messages[result] or '制作失败', 'error', 4000)
                return
            end

            if result and result.quit then
                TriggerClientEvent('QBCore:Notify', src, '这一份没做完（原料没扣）', 'primary', 3000)
                return
            end

            -- 成功：扣一份原料、加一份成品。顺序很重要：
            -- 先扣原料再加成品，反之原料已经耗尽时会凭空多出一份热狗。
            local consumed = QuestVendor.ConsumeRaw(citizenid)
            if not consumed then
                TriggerClientEvent('QBCore:Notify', src, '原料用完了', 'error', 4000)
                return
            end
            local added = QuestVendor.AddStock(citizenid, result.tier, 1)
            if not added then
                TriggerClientEvent('QBCore:Notify', src, '成品放不下了', 'error', 4000)
                return
            end
            TriggerClientEvent('QBCore:Notify', src,
                ('做好了：%s（失误 %s 次）'):format(tostring(result.tier), tostring(result.faults)),
                'success', 4000)
            PushState(citizenid, 'update')
            QuestVendorBridge.PushBystanders(citizenid)
            return
        end

        return
    end

    if action == 'purchase' then
        local booth = QuestBooth and QuestBooth.FindByNetId and QuestBooth.FindByNetId(payload.boothNetId)
        if not booth then
            TriggerClientEvent('QBCore:Notify', src, '摊位已经收摊了', 'error', 4000)
            return
        end
        if not NearBooth(src, booth) then
            TriggerClientEvent('QBCore:Notify', src, '离摊位太远了', 'error', 4000)
            return
        end
        if booth.ownerCitizenid == citizenid then
            TriggerClientEvent('QBCore:Notify', src, '不能买自己摊上的东西', 'error', 4000)
            return
        end

        local session = QuestVendor.Get(booth.ownerCitizenid)
        if not session or session.state ~= 'open' then
            TriggerClientEvent('QBCore:Notify', src, '摊主已经收摊了', 'error', 4000)
            return
        end

        local item = payload.item
        local unit = UnitPriceOf(session, item)
        if not unit then
            TriggerClientEvent('QBCore:Notify', src, '没有这个口味', 'error', 4000)
            return
        end
        local cash = Player.PlayerData.money and Player.PlayerData.money.cash or 0
        if cash < unit then
            -- 金额一律 `$%s` + QuestMoney：单价将来可能带小数（折扣/系数），
            -- `$%d` 在 Lua 5.4 遇到 0.5 会直接抛 format 错。
            TriggerClientEvent('QBCore:Notify', src,
                ('现金不够（要 $%s）'):format(QuestMoney(unit)), 'error', 4000)
            return
        end

        -- 先扣买家：内核只负责「扣库存 + 给摊主钱」，它不知道买家是谁。
        -- 顺序反过来就会在买家付不出时白送一份。
        if not Player.Functions.RemoveMoney('cash', unit, 'quest-vendor-buy') then
            TriggerClientEvent('QBCore:Notify', src, '付款失败', 'error', 4000)
            return
        end

        local ok, result = QuestVendor.Purchase(booth.ownerCitizenid, item, 1)
        if not ok then
            Player.Functions.AddMoney('cash', unit, 'quest-vendor-buy-refund')
            local messages = {
                sold_out = '这个口味卖完了',
                closed = '摊主已经收摊了',
                busy = '摊主正忙，稍等一下',
                money_failed = '摊主那边收款失败，钱已退回',
            }
            TriggerClientEvent('QBCore:Notify', src, messages[result] or '买不了，钱已退回', 'error', 4000)
            return
        end

        TriggerClientEvent('QBCore:Notify', src,
            ('买到了：%s · $%s'):format(tostring(item), tostring(unit)), 'success', 4000)
        -- 收银：买家与摊主各一声（常量文件名/音量）；不是 -1 全服广播。
        TriggerClientEvent('InteractSound_CL:PlayOnOne', src, 'Shop', 0.3)
        local owner = ResolvePlayer(booth.ownerCitizenid)
        if owner then
            TriggerClientEvent('QBCore:Notify', owner.PlayerData.source,
                ('玩家买了 1 份 %s · +$%s'):format(tostring(item), tostring(unit)), 'success', 4000)
            TriggerClientEvent('InteractSound_CL:PlayOnOne', owner.PlayerData.source, 'Shop', 0.25)
        end
        PushState(booth.ownerCitizenid, 'update')
        QuestVendorBridge.PushBystanders(booth.ownerCitizenid)
        return
    end

    -- 挪摊位：玩家放下车之后想微调位置。校验与首次摆放**同一条判据**，
    -- 只是不再登记实体（车还是那辆，netId 不变）。
    if action == 'move' then
        local booth = QuestBooth.Get(citizenid)
        if not booth then return end
        local pos = { x = tonumber(payload.x), y = tonumber(payload.y), z = tonumber(payload.z) }
        if not pos.x or not pos.y then return end

        local cfg = boothStepCfgOf(booth.questId)
        if cfg then
            local ok, reason = QuestBooth.ValidatePlacement(citizenid, cfg, pos, payload.hints)
            if not ok then
                TriggerClientEvent('QBCore:Notify', src, reason or '这里放不了', 'error', 4000)
                return
            end
        end

        QuestBooth.MoveTo(citizenid, pos)
        -- 推一次状态给摊主，UI 才能知道摊位换了位置（这里曾经写成未定义的 PushFor，
        -- 运行期 attempt to call a nil value，挪位后界面不刷新）。
        PushState(citizenid, 'moved')
        QuestVendorBridge.PushBystanders(citizenid)
        return
    end

    if action == 'close' then
        local booth = QuestBooth and QuestBooth.Get and QuestBooth.Get(citizenid)
        if not booth then return end
        if not NearBooth(src, booth) then
            TriggerClientEvent('QBCore:Notify', src, '离摊位太远了', 'error', 4000)
            return
        end
        local summary = QuestVendorBridge.CloseFor(citizenid, booth.questId, 'closed_by_player')

        -- 推进任务这一步必须由服务端做：客户端不知道当前是哪一步
        -- （它只知道「摆摊那一步」的 id —— 拿那个报上去就是 step order violation）。
        local stepId = vendorStepIdOf(booth.questId)
        if stepId then
            local advanced, msg = QuestManager.AdvanceStep(citizenid, booth.questId, stepId, {})
            if not advanced then
                print(('[vendor-bridge] ⚠️ 收摊后推进失败：%s | %s | %s')
                    :format(tostring(citizenid), tostring(stepId), tostring(msg)))
            end
        else
            print(('[vendor-bridge] ⚠️ 模板里没有 vendor 步骤：%s')
                :format(tostring(booth.questId)))
        end
        if summary then
            TriggerClientEvent('QBCore:Notify', src,
                ('收摊了 · 本班售出 %s 份 · 收入 $%s'):format(
                    tostring(summary.sold or 0), QuestMoney(summary.revenue or 0)),
                'success', 6000)
        end
        return
    end

    -- accept / reject：只有摊主本人、且必须在摊位附近
    local booth = QuestBooth and QuestBooth.Get and QuestBooth.Get(citizenid)
    if not booth or not NearBooth(src, booth) then
        TriggerClientEvent('QBCore:Notify', src, '离摊位太远了', 'error', 4000)
        return
    end

    local offerId = payload.offerId
    if type(offerId) ~= 'string' or offerId == '' then return end

    if action == 'accept' then
        local ok, result = QuestVendor.SettleOffer(citizenid, offerId)
        if not ok then
            local messages = {
                already_settled = '这单已经结过了',
                expired = '顾客走开了',
                closed = '已经收摊了',
                insufficient_stock = '库存不够了',
                busy = '正在收款，稍等',
                money_failed = '收款失败',
            }
            TriggerClientEvent('QBCore:Notify', src, messages[result] or '成交失败', 'error', 4000)
            return
        end
        TriggerClientEvent('QBCore:Notify', src,
            ('成交：%s ×%s · +$%s'):format(tostring(result.item), tostring(result.count),
                tostring(result.price or result.total or '?')), 'success', 4000)
        -- 收银：只给摊主本人播；文件名与音量都是服务端常量，不转发任何客户端参数。
        TriggerClientEvent('InteractSound_CL:PlayOnOne', src, 'Shop', 0.35)
    else
        local ok = QuestVendor.RejectOffer(citizenid, offerId)
        if not ok then return end
        TriggerClientEvent('QBCore:Notify', src, '已拒绝这位顾客', 'primary', 3000)
    end

    PushState(citizenid, 'update')
    QuestVendorBridge.PushBystanders(citizenid)
end)

--- 断线：必须关会话（摊主不在，顾客会一直等），并停掉 Tick
AddEventHandler('playerDropped', function()
    local src = source
    local Player = exports['qb-core']:GetPlayer(src)
    if not Player then return end
    local citizenid = Player.PlayerData.citizenid
    QuestVendorBridge.StopTick(citizenid)
    if QuestVendor and QuestVendor.Get and QuestVendor.Get(citizenid) then
        QuestVendor.Close(citizenid, nil, 'dropped')
    end
    -- 摊位实体还在，但会话已经关了：告诉附近买家“摊主收摊了”。
    QuestVendorBridge.PushBystanders(citizenid)
    Rate[citizenid] = nil
    StepIds[citizenid] = nil
end)

print('[vendor-bridge] ready')
