-- ==============================================================
-- quest_hotdog_vendor_client.lua — 热狗摊 S4 客户端（卖：NPC 报价 / 玩家购买）
-- ==============================================================
-- 职责（只做表现与转发，不做裁决）：
--   1. 摊主：摊位 3 m 内画状态条，按 E 请求开卖/收摊（本地事件交给接线方）
--   2. 摊主：收到 vendorOffer 后画右下报价面板 + 顾客头顶 3D 提示，Y/N 转发
--   3. 玩家：别人摊位 2.5 m 内按 ALT 打开购买菜单，Enter 只发 purchase 请求
--   4. 清理：打烊 / 任务结束 / 资源停止，清面板、菜单、顾客 ped
--
-- 权威边界（为什么客户端只“转发”）：
--   * 价格、库存、能不能买全部由 server/quest_vendor.lua 决定；本文件用
--     vendorState 的数字只做显示。按下 Enter 时不带金额、不带库存判断结果，
--     也不把本地禁用当成权限（面板隐藏 ≠ 授权）。
--   * 唯一的客户端 → 服务端出口是 quest:server:vendorAction（action='purchase'）。
--     开卖/收摊/成交/拒绝都走本地 TriggerEvent，由接线方转成服务端动作。
--
-- 事件契约（只接收两条下行事件）：
--   quest:client:vendorState { questId, boothNetId, coords, state, stock, raw,
--                              prices, sold, revenue }
--   quest:client:vendorOffer { questId, offerId, npcNetId, item, count, price, expiresAt }
--
-- 键位（RegisterKeyMapping，玩家可在游戏设置里改）：
--   E = 摊主开卖/收摊；Y = 成交；N = 拒绝；ALT = 玩家购买菜单。
--   ⚠️ 与 UX 规格 §5.1 的差异：规格用 G 开卖/打烊、ALT 走 qb-target；
--      本片按任务书用 E / ALT。ALT 会同时触发 qb-target（它默认也绑 LMENU），
--      真机如果两套 UI 打架，应改成 qb-target 的一个选项或换键。
--
-- 买家侧依赖（主 agent 需要补的接线）：
--   vendorState 目前按契约只发给摊主。别的玩家要看到菜单，服务端必须把同一份
--   状态广播给摊位附近的玩家，并显式带 isOwner=false；否则客户端无法区分
--   “我的摊”和“别人的摊”，会把所有人都当成摊主（见 IsOwnPayload 的缺省分支）。
-- ==============================================================

local QBCore = nil
do
    local ok, core = pcall(function() return exports['qb-core']:GetCoreObject() end)
    if ok then QBCore = core end
end

-- ==============================================================
-- 常量
-- ==============================================================

-- 原生控制号（与 UX §5.1 保持一致：不新造控制，只做前台菜单导航）
local CONTROL_FRONTEND_UP      = 172
local CONTROL_FRONTEND_DOWN    = 173
local CONTROL_FRONTEND_ACCEPT  = 176
local CONTROL_FRONTEND_CANCEL  = 177
local CONTROL_FRONTEND_CANCEL2 = 202

local OWNER_DISTANCE = 3.0      -- 摊主状态条 / 开卖收摊
local BUYER_DISTANCE = 2.5      -- 玩家购买菜单
local PENDING_MS     = 3000     -- 发出开卖/收摊请求后等新 vendorState 的窗口
local BUY_DEBOUNCE_MS = 1500    -- 本地防连点；真正的频率闸在服务端
local WAIT_IDLE      = 500      -- 没有任何摊位时
local WAIT_FAR       = 150      -- 有摊位但玩家不在范围内
local WAIT_NEAR      = 0        -- 玩家在范围内 / 报价 / 菜单

-- 服务端时间戳与客户端 GetGameTimer 不同源时的兜底耐心。
-- 45s 是 server/quest_vendor.lua 的默认 patience_ms；只有在接线方既没给
-- remainingMs、expiresAt 又明显不是本机时钟时才会用到（见 vendorOffer 处理）。
local FALLBACK_PATIENCE_MS = 45000
local MAX_PLAUSIBLE_MS     = 180000   -- 超过 3 分钟的“剩余时间”一定不是耐心

local QUALITY_LABELS = {
    common = '普通',
    rare   = '稀有',
    exotic = '异域',
}

local QUALITY_LABELS_LONG = {
    common = '普通热狗',
    rare   = '稀有热狗',
    exotic = '异域热狗',
}

-- 符号是颜色的替代信息载体（UX A16）：看不清颜色也能分辨档位
local QUALITY_SYMBOLS = {
    common = '●',
    rare   = '◆',
    exotic = '★',
}

-- 菜单按任务书的顺序：普通 → 稀有 → 异域
local MENU_ORDER = { 'common', 'rare', 'exotic' }

local COLOR = {
    white = { 255, 255, 255, 235 },
    grey  = { 150, 150, 150, 200 },
    gold  = { 255, 205, 90, 255 },
    green = { 90, 220, 120, 255 },
    red   = { 235, 85, 85, 255 },
    amber = { 240, 175, 70, 255 },
}

-- ==============================================================
-- 本地状态（不要提升成全局！）
-- ==============================================================

local Booths = {}          -- [boothNetId] = booth 记录
local ActiveOffer = nil    -- 当前报价（同一时刻只显示一个）
local BuyMenu = nil        -- 购买菜单
local ResolvedOffers = {}  -- 已按过 Y/N 的 offerId，防止重复事件把面板弹回来

-- ==============================================================
-- 小工具
-- ==============================================================

local function NumberOr(value, default)
    local number = tonumber(value)
    if not number or number ~= number then return default or 0 end
    return number
end

--- FiveM 的 BOOL native 有时返回 1/0 而不是 true/false。
--- Lua 里 0 是 truthy，直接 if DoesEntityExist(...) 会把“不存在”当成“存在”。
local function NativeBool(value)
    return value == true or value == 1
end

--- 金额只用于显示；服务端才是唯一计价方。
local function Money(value)
    if type(QuestMoney) == 'function' then
        return QuestMoney(value)
    end
    local number = NumberOr(value, 0)
    if number % 1 == 0 then
        return ('%d'):format(number)
    end
    return ('%.2f'):format(number)
end

--- 同时接受档位名（'rare'）和 S3 的物品 id（'hotdog_rare'）。
local function NormalizeQuality(item)
    local value = tostring(item or '')
    local tier = value:match('^hotdog_(%a+)$')
    return tier or value
end

local function ToVec3(value)
    if type(value) ~= 'table' and type(value) ~= 'vector3' then return nil end
    local x, y, z = value.x, value.y, value.z
    if type(x) ~= 'number' or type(y) ~= 'number' then return nil end
    return vector3(x, y, tonumber(z) or 0.0)
end

--- NUI / 暂停菜单有焦点时，Y/N/E/ALT 不该穿透到游戏世界。
--- 玩家可见的提示。走 qb-core 的原生通知（与全仓其它资源一致），
-- 不用 chat：chat 会被别的消息顶掉，而这几条都是「刚做完一件事」的即时回执。
local function Notify(text, kind, duration)
    TriggerEvent('QBCore:Notify', text, kind or 'primary', duration or 4000)
end

local function UiHasFocus()
    local nui = type(IsNuiFocused) == 'function' and NativeBool(IsNuiFocused())
    local pause = type(IsPauseMenuActive) == 'function' and NativeBool(IsPauseMenuActive())
    return nui or pause
end

local function IsDeadPed(ped)
    return type(IsEntityDead) == 'function' and NativeBool(IsEntityDead(ped))
end

-- ==============================================================
-- 绘制助手：全部原生 DrawText / DrawRect，不引 NUI
-- ==============================================================

local function DrawText2D(x, y, text, scale, colour, centered)
    if type(text) ~= 'string' or text == '' then return end
    local c = colour or COLOR.white
    SetTextFont(4)
    SetTextScale(scale or 0.32, scale or 0.32)
    SetTextColour(c[1], c[2], c[3], c[4] or 255)
    SetTextDropShadow()
    SetTextOutline()
    if centered then
        SetTextCentre(true)
    end
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayText(x, y)
end

local function DrawPanel(x, y, w, h, alpha)
    DrawRect(x + w * 0.5, y + h * 0.5, w, h, 8, 8, 8, alpha or 180)
end

-- 3D 文字统一走 core-framework 的共享实现：
--   * [custom] 里自己再写一份 DrawText3D 会撞复用闸（这份预算只剩 4 份，qb-* 上游占着）；
--   * core-framework 在 fxmanifest 里排在本资源之前，加载期就包含 `@core-framework/client/shared.lua`，
--     所以这里不需要 fallback —— 真缺了它，是整个依赖坏了，不是这一句该兜的事。
local function DrawBoothText3D(x, y, z, text)
    CFShared.DrawText3D(x, y, z, text)
end

-- ==============================================================
-- 摊位归属
--
-- 缺省按“摊主”处理：本片契约里 vendorState 是发给摊主的。
-- 广播给买家时必须显式带 isOwner=false（或 ownerSource / ownerCitizenid），
-- 否则买家会看到“收摊”提示并误发开卖/收摊请求。客户端这条判断只影响
-- 显示哪套 UI；开卖/收摊的权限仍由服务端裁决。
-- ==============================================================

local function IsOwnPayload(payload)
    local isOwner = payload.isOwner
    if isOwner == nil then isOwner = payload.is_owner end
    if isOwner ~= nil then return isOwner == true end

    local ownerSource = NumberOr(payload.ownerSource or payload.owner_source, 0)
    if ownerSource > 0 then
        return ownerSource == GetPlayerServerId(PlayerId())
    end

    local ownerCitizenid = payload.ownerCitizenid or payload.owner_citizenid
    if type(ownerCitizenid) == 'string' and ownerCitizenid ~= '' and QBCore then
        local ok, data = pcall(function() return QBCore.Functions.GetPlayerData() end)
        if ok and type(data) == 'table' and data.citizenid then
            return tostring(data.citizenid) == ownerCitizenid
        end
    end

    return true
end

--- 摊位坐标：优先用服务端给的；没给就按 netId 反查实体。
--- 只用于距离和提示位置，不参与任何裁决。
local function CoordsFromPayload(payload, boothNetId)
    local coords = ToVec3(payload.coords)
    if coords then return coords end

    local entity = NetworkGetEntityFromNetworkId(boothNetId)
    if entity and entity ~= 0 and NativeBool(DoesEntityExist(entity)) then
        return GetEntityCoords(entity)
    end
    return nil
end

--- 找最近的摊位。wantOwn=true 只找摊主自己的，false 只找别人的。
local function NearestBooth(pedCoords, maxDistance, wantOwn)
    local best, bestDistance = nil, nil
    for _, booth in pairs(Booths) do
        if booth.coords and booth.isOwner == wantOwn then
            local distance = #(pedCoords - booth.coords)
            if distance <= maxDistance and (not bestDistance or distance < bestDistance) then
                best, bestDistance = booth, distance
            end
        end
    end
    return best, bestDistance
end

-- ==============================================================
-- 清理
-- ==============================================================

local function ClearOffer(reason)
    local offer = ActiveOffer
    ActiveOffer = nil
    if not offer then return end

    -- 本文件目前不生成顾客 ped（npcNetId 由接线方给）。保留这条路径是为了
    -- “如果生成了”时不会漏删：localPed 归客户端；npcOwned 是接线方明确
    -- 把网络 ped 的删除权交给客户端时才动，避免和服务端生成方重复删除打架。
    if offer.localPed and NativeBool(DoesEntityExist(offer.localPed)) then
        DeleteEntity(offer.localPed)
    end
    if offer.npcOwned and offer.npcNetId > 0 then
        local entity = NetworkGetEntityFromNetworkId(offer.npcNetId)
        if entity and entity ~= 0 and NativeBool(DoesEntityExist(entity)) then
            SetEntityAsMissionEntity(entity, true, true)
            DeleteEntity(entity)
        end
    end

    if reason then
        print(('[quest-hotdog-vendor] 报价清理：%s (%s)')
            :format(tostring(offer.offerId), tostring(reason)))
    end
end

local function ClearBuyMenu()
    BuyMenu = nil
end

local function CleanupQuest(questId, reason)
    -- offerId 的序号是每个会话从 1 开始的；任务结束/换会话时必须把
    -- “已经按过 Y/N”的记录一起清掉，否则下一轮第一单会被误吞。
    ResolvedOffers = {}

    if questId then
        if ActiveOffer and ActiveOffer.questId == questId then
            ClearOffer(reason)
        end
        if BuyMenu then
            local booth = Booths[BuyMenu.boothNetId]
            if not booth or booth.questId == questId then
                ClearBuyMenu()
            end
        end
        for netId, booth in pairs(Booths) do
            if booth.questId == questId then
                Booths[netId] = nil
            end
        end
    else
        ClearOffer(reason)
        ClearBuyMenu()
        Booths = {}
    end
end

-- ==============================================================
-- 下行事件 1：摊位状态
-- ==============================================================

RegisterNetEvent('quest:client:vendorState', function(payload)
    if type(payload) ~= 'table' then return end

    local boothNetId = math.floor(NumberOr(payload.boothNetId, 0))
    if boothNetId <= 0 then return end

    local questId = type(payload.questId) == 'string' and payload.questId or nil
    if not questId then return end

    local previous = Booths[boothNetId]
    local stock = type(payload.stock) == 'table' and payload.stock or {}
    local prices = type(payload.prices) == 'table' and payload.prices or {}
    local state = payload.state == 'open' and 'open' or 'closed'

    -- 状态没变时保留“收摊中…”：vendorState 每秒都会推一次，
    -- 不能因为一次普通 update 就把玩家刚按下的请求当成已完成。
    -- 状态真的从 open 翻到 closed（或反过来）时 sameState=false，pending 自然清掉。
    local sameState = previous ~= nil and previous.state == state

    local booth = {
        questId = questId,
        -- 收摊时要回调 nodeComplete(questId, stepId, 'vendor')，所以这一份必须存下来；
        -- 只存 questId 的话收摊后任务永远停在这一步。
        stepId = type(payload.stepId) == 'string' and payload.stepId or nil,
        boothNetId = boothNetId,
        coords = CoordsFromPayload(payload, boothNetId) or (previous and previous.coords),
        state = state,
        stock = {
            common = math.max(0, math.floor(NumberOr(stock.common, 0))),
            rare   = math.max(0, math.floor(NumberOr(stock.rare, 0))),
            exotic = math.max(0, math.floor(NumberOr(stock.exotic, 0))),
        },
        raw     = math.max(0, math.floor(NumberOr(payload.raw, 0))),
        prices  = {
            common = NumberOr(prices.common, 0),
            rare   = NumberOr(prices.rare, 0),
            exotic = NumberOr(prices.exotic, 0),
        },
        sold     = math.max(0, math.floor(NumberOr(payload.sold, 0))),
        revenue  = NumberOr(payload.revenue, 0),
        ownerAway = payload.ownerAway == true or payload.owner_away == true
            or payload.state == 'away',
        isOwner = IsOwnPayload(payload),
        updatedAt = GetGameTimer(),
        pendingAction = sameState and previous.pendingAction or nil,
        pendingUntil = sameState and previous.pendingUntil or nil,
    }
    Booths[boothNetId] = booth

    if payload.reason == 'opened' then
        -- 新一轮会话的 offer 序号从 1 重新开始（offerId 是 citizenid + seq）。
        -- 不清掉上一轮按过 Y/N 的 id，新会话第一单会被误判成“已经处理过”。
        if not ActiveOffer or not ActiveOffer.questId or ActiveOffer.questId == questId then
            ClearOffer('reopened')
            ResolvedOffers = {}
        end
    end

    if state == 'closed' then
        -- 打烊不是“把摊位忘了”：保留记录，摊主还要靠它按 E 开卖；
        -- 但要清掉一切营业中的瞬时 UI（报价 / 菜单 / 顾客 ped）。
        -- 这就是需求里的“state=closed → 清面板”，不能连开卖提示一起清掉。
        if ActiveOffer and (not ActiveOffer.questId or ActiveOffer.questId == questId) then
            ClearOffer('booth_closed')
        end
        if BuyMenu and BuyMenu.boothNetId == boothNetId then
            ClearBuyMenu()
        end
        if booth.isOwner then
            ResolvedOffers = {}
        end
    end

    -- 可选字段：vendorState.activeOfferId（接线方每秒推状态时带上当前有效报价）。
    -- 服务器已经清掉（过期 / 成交 / 拒绝）而客户端还挂着面板时，这里负责收掉。
    -- 不依赖第三条下行事件，也不会替玩家成交。
    local activeOfferId = payload.activeOfferId
    if activeOfferId == nil then activeOfferId = payload.active_offer_id end
    if activeOfferId ~= nil and ActiveOffer and ActiveOffer.questId == questId then
        local id = tostring(activeOfferId)
        if id == '' or id ~= ActiveOffer.offerId then
            ClearOffer('server_cleared')
        end
    end
end)

-- ==============================================================
-- 下行事件 2：NPC 报价
-- ==============================================================

RegisterNetEvent('quest:client:vendorOffer', function(payload)
    if type(payload) ~= 'table' then return end

    local offerId = tostring(payload.offerId or '')
    if offerId == '' then
        -- 没有 offerId 就没法对单：Y/N 发回去服务端也找不到这条报价。
        -- 常见原因是接线方把内核返回的 offer.offerId 写成了 offer.id（nil 键会被序列化丢掉）。
        print('[quest-hotdog-vendor] ⚠️ vendorOffer 缺少 offerId，已忽略')
        return
    end
    if ResolvedOffers[offerId] then return end

    local now = GetGameTimer()
    local expiresAt = NumberOr(payload.expiresAt, 0)
    local count = math.floor(NumberOr(payload.count, 0))
    if count <= 0 then return end

    -- 服务端与客户端的 GetGameTimer 不同源（服务器进程启动时刻 ≠ 客户端游戏启动时刻）。
    -- 正确的做法是接线方发 remainingMs（= offer.expiresAt - QuestVendor.Now()），
    -- 客户端换算成本地截止时间；下面的兜底只是让旧接线不至于把面板永远吞掉。
    local remaining = NumberOr(payload.remainingMs or payload.remaining_ms, 0)
    if remaining <= 0 then
        local absolute = expiresAt - now
        if absolute > 0 and absolute <= MAX_PLAUSIBLE_MS then
            -- 接线方已经把 expiresAt 换到了客户端时钟
            remaining = absolute
        elseif expiresAt > 0 and expiresAt <= MAX_PLAUSIBLE_MS then
            -- 接线方把“剩余毫秒”直接塞进了 expiresAt
            remaining = expiresAt
        else
            -- 两套时钟不同源，又没有 remainingMs：退回服务端默认耐心。
            -- 这是显示层的兜底，不参与成交；真正的修复在 quest_vendor_bridge.lua。
            remaining = FALLBACK_PATIENCE_MS
        end
    end
    expiresAt = now + remaining

    local unitPrice = NumberOr(payload.unitPrice or payload.unit_price, 0)
    if unitPrice <= 0 and count > 0 then
        -- 仅用于显示「$9/份」；成交金额仍以服务端返回的 price 为准。
        unitPrice = math.floor(NumberOr(payload.price, 0) / count + 0.5)
    end

    -- 同一时刻只显示一个报价：新报价直接替换旧的（需求明确）。
    -- 先走一遍 ClearOffer，旧报价如果带客户端 ped 才不会漏删。
    if ActiveOffer and ActiveOffer.offerId ~= offerId then
        ClearOffer('replaced')
    end

    ActiveOffer = {
        offerId = offerId,
        questId = type(payload.questId) == 'string' and payload.questId or nil,
        npcNetId = math.floor(NumberOr(payload.npcNetId, 0)),
        item = NormalizeQuality(payload.item),
        count = count,
        unitPrice = unitPrice,
        price = NumberOr(payload.price, 0),
        expiresAt = expiresAt,
        receivedAt = now,
        initialMs = math.max(1000, remaining),
        npcOwned = payload.npcOwned == true or payload.npc_owned == true,
        localPed = nil,
    }
end)

-- ==============================================================
-- 摊主动作：开卖 / 收摊
-- ==============================================================

local function HandleOwnerInteract()
    if UiHasFocus() then return end

    local now = GetGameTimer()
    local ped = PlayerPedId()
    if IsDeadPed(ped) then return end
    if NativeBool(IsPedInAnyVehicle(ped, false)) then return end

    local booth = NearestBooth(GetEntityCoords(ped), OWNER_DISTANCE, true)
    if not booth then return end
    if booth.pendingUntil and now < booth.pendingUntil then return end

    -- 本地只发请求；state 的最终变化以服务端回来的 vendorState 为准。
    -- 先给一个 3 秒的 pending，按 E 不会连发，也不会假装已经开/关了。
    if booth.state ~= 'open' then
        -- 开卖是服务端在「放下推车」那一刻自动做的，收摊之后这条路已经是终点。
        Notify('已经收摊了，回租赁点结算吧', 'primary', 4000)
        return
    end

    booth.pendingAction = 'close'
    booth.pendingUntil = now + PENDING_MS
    -- 两条消息各司其职：
    --   vendorAction('close') → 关顾客会话（不再来人、不再推报价）
    --   nodeComplete('vendor') → 推进任务（否则任务永远停在「开卖」这一步）
    -- 只发前者：摊收了但任务还在卖；只发后者：任务过了但顾客继续来。
    TriggerServerEvent('quest:server:vendorAction', 'close', {})
    if booth.stepId then
        TriggerServerEvent('quest:server:nodeComplete', booth.questId, booth.stepId, 'vendor', {})
    else
        print('[quest-hotdog-vendor-client] ⚠️ 收摊时没有 stepId —— 任务不会推进')
    end
end

-- ==============================================================
-- 做热狗：G 起小游戏 → KeyMinigame(10) → 只报 faults
--
-- 客户端拿不到「我做了几份」这种结论：份额由服务端按 nonce 反查会话决定，
-- 这里能发的只有「这一次我失误了几次」。
-- ==============================================================

local cookPending = false

local function HandleCook(ped)
    if UiHasFocus() then return end
    local booth = NearestBooth(GetEntityCoords(ped), OWNER_DISTANCE, true)
    if not booth or booth.state ~= 'open' then return end
    if cookPending then return end
    if (booth.raw or 0) <= 0 then return end

    cookPending = true
    TriggerServerEvent('quest:server:vendorAction', 'cook', { mode = 'start' })
    -- 服务端回 cookStart 才真的开小游戏；3 秒没回来就允许再按（服务端拒绝/超时都不会卡死）
    SetTimeout(3000, function() cookPending = false end)
end

RegisterNetEvent('quest:client:cookStart', function(payload)
    cookPending = false
    if type(payload) ~= 'table' or type(payload.nonce) ~= 'string' then return end

    local ok, result = pcall(function()
        return exports['qb-minigames']:KeyMinigame(10)
    end)
    if not ok or type(result) ~= 'table' then
        Notify('小游戏没起来（qb-minigames 不可用）', 'error', 5000)
        return
    end

    TriggerServerEvent('quest:server:vendorAction', 'cook', {
        mode = 'report',
        nonce = payload.nonce,
        faults = result.faults,
        quit = result.quit == true,
    })
end)

-- ==============================================================
-- 报价：Y 成交 / N 拒绝
-- ==============================================================

local function ResolveOffer(accept)
    if UiHasFocus() then return end
    if IsDeadPed(PlayerPedId()) then
        ClearOffer('dead')
        return
    end

    local offer = ActiveOffer
    if not offer then return end

    -- 到点就自然消失，不替玩家成交；服务端 Tick 也会把这条报价判过期。
    if GetGameTimer() >= offer.expiresAt then
        ClearOffer('timeout')
        return
    end

    -- 先本地收起，避免连按 Y/N 对同一 offerId 发两次。
    ActiveOffer = nil
    ResolvedOffers[offer.offerId] = true

    if accept then
        TriggerEvent('quest:hotdog:acceptOffer', offer.offerId)
    else
        TriggerEvent('quest:hotdog:rejectOffer', offer.offerId)
    end
end

-- ==============================================================
-- 玩家购买菜单
-- ==============================================================

--- 菜单里“不能买”的原因。仅用于显示和本地防误触；
--- 真正的库存/打烊/距离校验仍由服务端逐笔裁决。
local function MenuBlockReason(booth, quality)
    if booth.state ~= 'open' then return '打烊中' end
    if booth.ownerAway then return '摊主走开了' end
    if quality and (booth.stock[quality] or 0) <= 0 then return '售罄' end
    return nil
end

local function ToggleBuyMenu()
    if UiHasFocus() then return end
    if BuyMenu then
        ClearBuyMenu()
        return
    end

    local ped = PlayerPedId()
    if IsDeadPed(ped) then return end
    if NativeBool(IsPedInAnyVehicle(ped, false)) then return end

    local booth = NearestBooth(GetEntityCoords(ped), BUYER_DISTANCE, false)
    if not booth then return end
    if booth.isOwner then return end   -- 摊主不能买自己的货

    BuyMenu = {
        boothNetId = booth.boothNetId,
        selected = 1,
        openedAt = GetGameTimer(),
        lastBuyAt = 0,
        flash = nil,
        flashUntil = 0,
    }
end

--- 把“按下了某颗前台键”统一成一次查询。
--- DisableControlAction 之后 IsControlJustPressed 在不同版本上表现并不一致，
--- 所以两个入口都查一遍，避免菜单按键偶尔吞掉。
local function JustPressed(control)
    if NativeBool(IsControlJustPressed(0, control)) then return true end
    if type(IsDisabledControlJustPressed) == 'function'
        and NativeBool(IsDisabledControlJustPressed(0, control)) then
        return true
    end
    return false
end

local function SendPurchase(booth, quality)
    local reason = MenuBlockReason(booth, quality)
    local now = GetGameTimer()

    if reason then
        if BuyMenu then
            BuyMenu.flash = reason
            BuyMenu.flashUntil = now + 1500
        end
        return
    end

    -- 本地防连点只是输入节流；服务端仍要做频率/距离/库存校验。
    if BuyMenu and now - (BuyMenu.lastBuyAt or 0) < BUY_DEBOUNCE_MS then
        BuyMenu.flash = '别急，慢慢来'
        BuyMenu.flashUntil = now + 1200
        return
    end

    if BuyMenu then
        BuyMenu.lastBuyAt = now
        BuyMenu.flash = '已发出购买请求'
        BuyMenu.flashUntil = now + 1500
    end

    -- 唯一一条客户端 → 服务端事件。只发摊位与档位；金额、数量、库存由服务端算。
    TriggerServerEvent('quest:server:vendorAction', 'purchase', {
        boothNetId = booth.boothNetId,
        item = quality,
    })
end

local function DrawBuyMenu(booth, menu, now)
    local panel = { x = 0.635, y = 0.300, w = 0.345, h = 0.285 }
    DrawPanel(panel.x, panel.y, panel.w, panel.h, 190)

    local x = panel.x + 0.016
    local y = panel.y + 0.012

    DrawText2D(x, y, '热狗摊 · 今日菜单', 0.38, COLOR.gold)

    local stateText, stateColour
    if booth.state ~= 'open' then
        stateText, stateColour = '打烊中', COLOR.grey
    elseif booth.ownerAway then
        stateText, stateColour = '摊主走开了，暂时不能买', COLOR.amber
    else
        stateText, stateColour = '营业中', COLOR.green
    end
    DrawText2D(x, y + 0.034, stateText, 0.32, stateColour)

    for index, quality in ipairs(MENU_ORDER) do
        local rowY = y + 0.070 + (index - 1) * 0.042
        local selected = menu.selected == index
        if selected then
            -- 选中行用底色 + 行首 “>” 两个信号，不只靠颜色（UX A16）
            DrawRect(panel.x + panel.w * 0.5, rowY + 0.012,
                panel.w - 0.024, 0.036, 255, 255, 255, 28)
        end

        local stock = booth.stock[quality] or 0
        local price = booth.prices[quality] or 0
        local blocked = MenuBlockReason(booth, quality)
        local colour = blocked and COLOR.grey or COLOR.white
        if selected and not blocked then colour = COLOR.gold end

        local cursor = selected and '> ' or '  '
        local soldOut = (blocked == '售罄') and ' · 售罄' or ''
        local line = ('%s%s $%s  (库存 %d%s)'):format(
            cursor,
            QUALITY_LABELS[quality] or quality,
            Money(price),
            stock,
            soldOut)
        DrawText2D(x, rowY, line, 0.33, colour)
    end

    local footerY = y + 0.205
    DrawText2D(x, footerY, '上下键选择 · Enter 购买 1 份 · 退格 关闭', 0.28, COLOR.grey)

    if menu.flash and menu.flashUntil and now < menu.flashUntil then
        DrawText2D(x, footerY + 0.026, menu.flash, 0.28, COLOR.amber)
    end
end

local function UpdateBuyMenu(pedCoords, now)
    local menu = BuyMenu
    if not menu then return end

    local booth = Booths[menu.boothNetId]
    if not booth or booth.isOwner or not booth.coords then
        ClearBuyMenu()
        return
    end
    if #(pedCoords - booth.coords) > BUYER_DISTANCE then
        ClearBuyMenu()
        return
    end

    -- 菜单打开时把前台键从游戏手里拿回来，避免上下键/Enter 触发别的 UI。
    -- 不改变任何权限，只是输入优先级。
    DisableControlAction(0, CONTROL_FRONTEND_UP, true)
    DisableControlAction(0, CONTROL_FRONTEND_DOWN, true)
    DisableControlAction(0, CONTROL_FRONTEND_ACCEPT, true)
    DisableControlAction(0, CONTROL_FRONTEND_CANCEL, true)
    DisableControlAction(0, CONTROL_FRONTEND_CANCEL2, true)

    if JustPressed(CONTROL_FRONTEND_UP) then
        menu.selected = menu.selected - 1
        if menu.selected < 1 then menu.selected = #MENU_ORDER end
    elseif JustPressed(CONTROL_FRONTEND_DOWN) then
        menu.selected = menu.selected + 1
        if menu.selected > #MENU_ORDER then menu.selected = 1 end
    end

    if JustPressed(CONTROL_FRONTEND_ACCEPT) then
        SendPurchase(booth, MENU_ORDER[menu.selected])
    elseif JustPressed(CONTROL_FRONTEND_CANCEL) or JustPressed(CONTROL_FRONTEND_CANCEL2) then
        ClearBuyMenu()
        return
    end

    DrawBuyMenu(booth, menu, now)
end

-- ==============================================================
-- 绘制：报价面板 + 顾客 3D + 摊主状态条 + 买家提示
-- ==============================================================

local function DrawOffer(now)
    local offer = ActiveOffer
    if not offer then return end

    local remaining = offer.expiresAt - now
    if remaining <= 0 then
        ClearOffer('timeout')
        return
    end
    local seconds = math.max(0, math.ceil(remaining / 1000))

    -- 顾客头顶 3D：玩家要能一眼把“这个报价”对上“这位顾客”。
    -- 只画一个 3D 绘制点（UX §2.8 的 3D 文字预算）。
    if offer.npcNetId > 0 then
        local ped = NetworkGetEntityFromNetworkId(offer.npcNetId)
        if ped and ped ~= 0 and NativeBool(DoesEntityExist(ped)) then
            local coords = GetEntityCoords(ped)
            DrawBoothText3D(coords.x, coords.y, coords.z + 1.05,
                ('顾客 · 正在点单~n~耐心 %ds'):format(seconds))
        end
    end

    -- 右下角报价面板
    local panel = { x = 0.705, y = 0.705, w = 0.280, h = 0.205 }
    DrawPanel(panel.x, panel.y, panel.w, panel.h, 185)

    local x = panel.x + 0.014
    local y = panel.y + 0.012

    DrawText2D(x, y, '顾客点单', 0.36, COLOR.gold)

    local item = offer.item
    local itemLabel = QUALITY_LABELS_LONG[item] or tostring(item)
    DrawText2D(x, y + 0.032,
        ('%s %s ×%d'):format(QUALITY_SYMBOLS[item] or '●', itemLabel, offer.count),
        0.34, COLOR.white)

    DrawText2D(x, y + 0.062,
        ('$%s/份 · 共 $%s'):format(Money(offer.unitPrice), Money(offer.price)),
        0.32, COLOR.white)

    local patienceColour = COLOR.green
    if seconds <= 5 then
        patienceColour = COLOR.red
    elseif seconds <= 10 then
        patienceColour = COLOR.amber
    end
    DrawText2D(x, y + 0.092, ('耐心 %ds'):format(seconds), 0.32, patienceColour)

    -- 耐心条按“收到报价时的总耐心”归一化；最后 5 秒整条变红。
    local barX = panel.x + 0.014
    local barY = panel.y + 0.145
    local barW = panel.w - 0.028
    local ratio = math.max(0, math.min(1, remaining / offer.initialMs))
    DrawRect(barX + barW * 0.5, barY, barW, 0.010, 35, 35, 35, 220)
    if ratio > 0 then
        DrawRect(barX + barW * ratio * 0.5, barY, barW * ratio, 0.010,
            patienceColour[1], patienceColour[2], patienceColour[3], 230)
    end

    DrawText2D(x, y + 0.160, '[Y] 成交    [N] 拒绝', 0.33, COLOR.white)
end

local function DrawOwnerStatus(booth, now)
    local panel = { x = 0.015, y = 0.405, w = 0.270, h = 0.085 }
    DrawPanel(panel.x, panel.y, panel.w, panel.h, 175)

    local x = panel.x + 0.012
    local y = panel.y + 0.008

    local title = booth.state == 'open' and '热狗摊 · 营业中' or '热狗摊 · 已打烊'
    DrawText2D(x, y, title, 0.34, booth.state == 'open' and COLOR.green or COLOR.grey)

    -- 任务书要求的一行状态条：成品三档 / 原料 / 已售 / 收入
    local stock = booth.stock
    DrawText2D(x, y + 0.030,
        ('成品 异域 %d · 稀有 %d · 普通 %d · 原料 %d · 已售 %d · 收入 $%s'):format(
            stock.exotic, stock.rare, stock.common, booth.raw, booth.sold,
            Money(booth.revenue)),
        0.27, COLOR.white)

    local pending = booth.pendingUntil and now < booth.pendingUntil
    local prompt
    if pending then
        prompt = '[E] 收摊中…'
    elseif booth.state == 'open' then
        -- 开卖是「放下推车」那一刻服务端自动做的；营业中能做的只有两件事。
        prompt = booth.raw > 0 and '[E] 收摊 · [G] 做热狗' or '[E] 收摊（原料用完了）'
    else
        prompt = '已收摊 · 回租赁点结算'
    end
    DrawText2D(x, y + 0.058, prompt, 0.33,
        pending and COLOR.grey or COLOR.gold)
end

local function DrawBuyerPrompt(booth)
    local text, colour
    if booth.state ~= 'open' then
        text, colour = '[ALT] 热狗摊 · 打烊中', COLOR.grey
    elseif booth.ownerAway then
        text, colour = '[ALT] 摊主走开了', COLOR.amber
    else
        text, colour = '[ALT] 购买热狗', COLOR.gold
    end
    DrawText2D(0.5, 0.900, text, 0.36, colour, true)
end

-- ==============================================================
-- 主线程：只在有摊位/报价/菜单时醒着
-- ==============================================================

CreateThread(function()
    while true do
        local boothCount = 0
        for _ in pairs(Booths) do boothCount = boothCount + 1 end

        local sleep = WAIT_IDLE
        if ActiveOffer or BuyMenu then
            sleep = WAIT_NEAR
        elseif boothCount > 0 then
            sleep = WAIT_FAR
        end

        local now = GetGameTimer()
        local ped = PlayerPedId()
        local pedCoords = GetEntityCoords(ped)
        local dead = IsDeadPed(ped)

        -- 报价到 0 自动消失；不替玩家成交（服务端 Tick 也会判过期）。
        if ActiveOffer and (dead or now >= ActiveOffer.expiresAt) then
            ClearOffer(dead and 'dead' or 'timeout')
        end
        if BuyMenu and dead then
            ClearBuyMenu()
        end

        if ActiveOffer then
            DrawOffer(now)
        end

        if BuyMenu then
            UpdateBuyMenu(pedCoords, now)
        end

        if boothCount > 0 and not dead then
            local own = NearestBooth(pedCoords, OWNER_DISTANCE, true)
            if own then
                -- pending 超时还没有新状态：恢复提示，允许玩家再按一次。
                if own.pendingUntil and now >= own.pendingUntil then
                    own.pendingAction = nil
                    own.pendingUntil = nil
                end
                DrawOwnerStatus(own, now)
                if not ActiveOffer and not BuyMenu then
                    sleep = WAIT_NEAR
                end
            else
                local other = NearestBooth(pedCoords, BUYER_DISTANCE, false)
                if other then
                    if not BuyMenu then
                        DrawBuyerPrompt(other)
                    end
                    if not ActiveOffer and not BuyMenu then
                        sleep = WAIT_NEAR
                    end
                end
            end
        end

        Wait(sleep)
    end
end)

-- ==============================================================
-- 键位
--
-- 为什么用 RegisterKeyMapping 而不是每帧 IsControlJustPressed(0, 38)：
--   E / ALT 在别的资源里已经有绑定（qb-doorlock、qb-target），按键映射至少
--   允许玩家在设置里改键；菜单导航（上下/Enter/退格）仍走原生控制号。
-- ==============================================================

RegisterCommand('quest_hotdog_vendor_interact', function()
    HandleOwnerInteract()
end, false)
RegisterKeyMapping('quest_hotdog_vendor_interact', '热狗摊 · 开卖/收摊', 'keyboard', 'E')

RegisterCommand('quest_hotdog_vendor_cook', function()
    HandleCook(PlayerPedId())
end, false)
RegisterKeyMapping('quest_hotdog_vendor_cook', '热狗摊 · 做热狗', 'keyboard', 'G')

RegisterCommand('quest_hotdog_vendor_accept', function()
    ResolveOffer(true)
end, false)
RegisterKeyMapping('quest_hotdog_vendor_accept', '热狗摊 · 成交', 'keyboard', 'Y')

RegisterCommand('quest_hotdog_vendor_decline', function()
    ResolveOffer(false)
end, false)
RegisterKeyMapping('quest_hotdog_vendor_decline', '热狗摊 · 拒绝', 'keyboard', 'N')

RegisterCommand('quest_hotdog_vendor_menu', function()
    ToggleBuyMenu()
end, false)
RegisterKeyMapping('quest_hotdog_vendor_menu', '热狗摊 · 购买菜单', 'keyboard', 'LMENU')

-- ==============================================================
-- 任务结束清理
--
-- 这里用 AddEventHandler 挂**已经存在的**任务事件（client/main.lua 已经
-- RegisterNetEvent 过），不新增任何下行 net event。契约要求本文件只
-- RegisterNetEvent 两条 vendor 事件，所以不能自己再 RegisterNetEvent 一次。
-- ==============================================================

local function HandleQuestEnd(data, reason)
    local questId = nil
    if type(data) == 'table' then
        questId = data.quest_id or data.questId
    end
    if type(questId) ~= 'string' or questId == '' then
        questId = nil
    end
    CleanupQuest(questId, reason)
end

if Config and Config.Quest and Config.Quest.Events then
    AddEventHandler(Config.Quest.Events.QUEST_COMPLETED, function(data)
        HandleQuestEnd(data, 'completed')
    end)
    AddEventHandler(Config.Quest.Events.QUEST_FAILED, function(data)
        HandleQuestEnd(data, 'failed')
    end)
    AddEventHandler(Config.Quest.Events.QUEST_ABANDONED, function(data)
        HandleQuestEnd(data, 'abandoned')
    end)
end

-- 资源停止：客户端实体不删会一直留在世界里；面板/菜单也必须在重载前收掉。
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    CleanupQuest(nil, 'resourceStop')
end)

print('[quest-hotdog-vendor] 🌭 S4 客户端已就绪：状态条 / 报价面板 / 购买菜单 / 清理')
