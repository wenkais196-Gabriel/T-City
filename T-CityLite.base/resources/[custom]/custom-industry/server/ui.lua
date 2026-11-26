-- server/ui.lua — S5 产业 UI：服务端只读快照 + 玩家侧写入口。
--
-- 本文件是 Boss 菜单与手机 App 共用的**唯一**读模型：
--   * Snapshot 的所有数字都来自 SQL / Treasury.Get / Config；前端不做二次计算。
--   * EstimateSale 只读，收益复用 IndustrySales.QuoteRevenue（与 SettleSale 同一套系数）。
--   * Sell / HireWorkstation 是玩家侧写入口：先复验成员身份 + Boss，再委托既有模块。
--
-- 客户端传来的数据一律不可信：
--   * orgId 必须能通过 IndustryAccess.OrgMembership（等价于「就是自己的组织」）；
--   * qty 会被夹到 [1, maxQty]；负数/小数/非数字直接 bad_qty，不写库；
--   * 价格 / 倍率 / 收益 / 配额字段收到就忽略并记录，不参与任何计算。
--
-- 本文件没有 net event；对客户端只暴露 QBCore callback（Register 时注册）。
-- 跨资源只读入口是 exports：CanAccessIndustry / GetIndustrySnapshot /
-- EstimateIndustrySale / SellIndustryStock。

IndustryUi = {}

local BOSS_GRADE_FALLBACK = 4

-- 与 commands.lua 相同的惰性解析：FiveM 不跨资源共享 Lua 全局，qb-core 的导出
-- 只能在第一次使用时取一次并缓存（见 [custom]/AGENTS.md 的已知坑）。
local QBCore
local coreLastError = nil

local function core()
    if QBCore then return QBCore end
    local ok, value = pcall(function() return exports['qb-core']:GetCoreObject() end)
    if ok and type(value) == 'table' then
        QBCore = value
        return value
    end
    coreLastError = ok and ('not a table: ' .. type(value)) or tostring(value)
    return nil
end

local function resolvePlayer(value)
    if type(value) == 'table' and type(value.PlayerData) == 'table' then return value end
    if type(value) ~= 'number' then return nil end
    local qb = core()
    if not qb or type(qb.Functions) ~= 'table' then return nil end
    local player = qb.Functions.GetPlayer(value)
    if player and type(player.PlayerData) == 'table' then return player end
    return nil
end

local function enabled()
    return Config.Industry.Enabled == true
end

local function toInt(value)
    local number = tonumber(value)
    if not number or number ~= number or number ~= math.floor(number) then return nil end
    return number
end

local function bossGrade()
    return tonumber(Config.Industry.BossGrade) or BOSS_GRADE_FALLBACK
end

--- 玩家所属组织。按键排序后逐个判定，保证同一玩家只拿到一个稳定结果。
---@param Player table QBCore 玩家对象
---@return string|nil orgId
function IndustryUi.PlayerOrgId(Player)
    if type(Player) ~= 'table' or type(Player.PlayerData) ~= 'table' then return nil end
    local orgIds = {}
    for orgId in pairs(Config.Industry.OrgWhitelist or {}) do
        orgIds[#orgIds + 1] = orgId
    end
    table.sort(orgIds)
    for _, orgId in ipairs(orgIds) do
        if IndustryAccess.OrgMembership(Player, orgId) then return orgId end
    end
    return nil
end

--- 解析并复验目标组织：nil 表示取调用者自己的组织；显式 orgId 必须是调用者的组织。
---@return string|nil orgId, string|nil errcode
local function resolveOrgId(Player, orgId)
    if orgId == nil then
        local own = IndustryUi.PlayerOrgId(Player)
        if not own then return nil, 'not_member' end
        return own, nil
    end
    if not IndustryOrgId.IsValid(orgId) then return nil, 'bad_org' end
    if not IndustryAccess.OrgMembership(Player, orgId) then return nil, 'not_member' end
    return orgId, nil
end

--- 组织展示名与职级名取自玩家自己的 job/gang（与 OrgWhitelist 的 kind 对齐）。
local function orgIdentity(Player, orgId)
    local def = Config.Industry.OrgWhitelist[orgId]
    local data = Player.PlayerData
    local identity
    if def and def.kind == 'gang' then
        identity = data.gang
    else
        identity = data.job
    end
    if type(identity) ~= 'table' or identity.name ~= (def and def.name) then
        identity = nil
    end

    local label = identity and identity.label or orgId
    local grade = identity and identity.grade
    local gradeName = type(grade) == 'table' and grade.name or ''
    return tostring(label), tostring(gradeName)
end

local function limitingReason(info)
    if info.stock <= 0 then return 'stock' end
    if info.org.remaining <= 0 then return 'org_cap' end
    if info.demand.remaining <= 0 then return 'demand' end
    -- maxQty > 0：再按「哪个上限最小」说明是库存还是某层配额；
    -- 只剩配置 MaxQty 兜底时给 none。
    if info.maxQty == info.stock then return 'stock' end
    if info.maxQty == info.org.remaining then return 'org_cap' end
    if info.maxQty == info.demand.remaining then return 'demand' end
    return 'none'
end

local function saleBlocked(info)
    if info.stock <= 0 then return 'stock' end
    if info.org.remaining <= 0 then return 'org_cap' end
    if info.demand.remaining <= 0 then return 'demand' end
    if info.maxQty <= 0 then return 'none' end
    return nil
end

--- 手机 App 可见性：只要求成员身份（与 IndustryAccess 同一套 job/gang 判定）。
---@param value number|table source 或 QBCore 玩家对象
---@return boolean
function IndustryUi.CanAccess(value)
    if not enabled() then return false end
    local Player = resolvePlayer(value)
    if not Player then return false end
    return IndustryUi.PlayerOrgId(Player) ~= nil
end

--- 只读快照。未建厂时 facility / demand / sellable 全部省略。
---@param value number|table source 或 QBCore 玩家对象
---@param orgId string|nil 必须等于调用者自己的组织；nil 表示自动解析
---@return table|nil snapshot, string|nil errcode
function IndustryUi.Snapshot(value, orgId)
    if not enabled() then return nil, 'disabled' end

    local Player = resolvePlayer(value)
    if not Player then return nil, 'not_player' end

    local resolved, orgErr = resolveOrgId(Player, orgId)
    if not resolved then return nil, orgErr end

    local member, level = IndustryAccess.OrgMembership(Player, resolved)
    if not member then return nil, 'not_member' end

    local orgLabel, gradeName = orgIdentity(Player, resolved)

    -- 阶段只用于展示与「购置是否开放」；价格/配额倍率由 sale.lua 在服务端算。
    local cycleState, cycleErr = IndustryCycle.Current()
    if not cycleState then return nil, cycleErr or 'db_error' end

    local balance, balanceErr = Treasury.GetBalance(resolved)
    if balance == nil then
        if balanceErr == 'no_account' then
            balance = 0
        else
            return nil, balanceErr or 'db_error'
        end
    end

    local snapshot = {
        orgId = resolved,
        orgLabel = orgLabel,
        gradeName = gradeName,
        isBoss = level >= bossGrade(),
        balance = balance,
        producedUnits = 0,
        phase = {
            key = cycleState.phase,
            label = cycleState.label,
            cycleNo = cycleState.cycle_no,
            endsAt = cycleState.ends_epoch,
            productionMultiplier = cycleState.production,
            priceMultiplier = cycleState.price,
            quotaMultiplier = cycleState.quota,
            purchasable = cycleState.purchasable == true,
        },
    }

    local row, facilityErr = Facility.Get(resolved)
    if not row then
        if facilityErr == 'not_built' then return snapshot, nil end
        return nil, facilityErr or 'db_error'
    end

    local facilityType = tostring(row.facility_type or '')
    local facilityConfig = Config.Industry.Facilities[facilityType]
    if type(facilityConfig) ~= 'table' then return nil, 'bad_type' end

    local item = (Config.Industry.Sales or {}).SeedItem
    local info, infoErr = IndustrySales.Inspect(resolved, item)
    if not info then return nil, infoErr or 'db_error' end

    local workstations = math.floor(tonumber(row.workstations) or 0)
    local workstationCap = math.floor(tonumber(facilityConfig.workstationCap) or 0)
    local stock = math.floor(tonumber(row.stock) or 0)
    local levelNum = math.floor(tonumber(row.level) or 1)
    local nextCost = Facility.WorkstationCost(facilityType, workstations)

    local hireBlocked
    if cycleState.purchasable ~= true then
        hireBlocked = 'phase' -- 衰退期：买不了，但卖得掉
    elseif workstations >= workstationCap then
        hireBlocked = 'cap'
    elseif nextCost == nil or balance < nextCost then
        hireBlocked = 'funds'
    end

    snapshot.producedUnits = math.floor(tonumber(row.produced_units) or 0)
    snapshot.facility = {
        built = true,
        type = facilityType,
        label = facilityConfig.label or facilityType,
        level = levelNum,
        maxLevel = math.floor(tonumber(facilityConfig.maxLevel) or 1),
        workstations = workstations,
        workstationCap = workstationCap,
        stock = stock,
        stockCap = math.floor(tonumber(facilityConfig.stockCap) or 0),
        nextWorkstationCost = nextCost,
        hireBlocked = hireBlocked,
    }
    snapshot.demand = {
        item = info.item,
        unitPrice = info.unitPrice,
        globalTotal = info.demand.total,
        globalUsed = info.demand.used,
        globalRemaining = info.demand.remaining,
        orgCap = info.org.cap,
        orgUsed = info.org.used,
        orgRemaining = info.org.remaining,
    }
    snapshot.sellable = {
        maxQty = info.maxQty,
        blocked = saleBlocked(info),
    }
    return snapshot, nil
end

local UNTRUSTED_FIELDS = {
    'price', 'unit_price', 'unitPrice', 'revenue', 'multiplier',
    'quota_used', 'quotaUsed', 'global_remaining', 'org_remaining',
}

--- 前端带价格/倍率/收益字段时只记录一次，绝不参与计算（不是报错）。
local function noteUntrusted(orgId, untrusted)
    if type(untrusted) ~= 'table' then return end
    local found = {}
    for _, key in ipairs(UNTRUSTED_FIELDS) do
        if untrusted[key] ~= nil then found[#found + 1] = key end
    end
    if #found > 0 then
        print(('[custom-industry] ignored client-supplied pricing fields org=%s keys=%s'):format(
            tostring(orgId), table.concat(found, ',')))
    end
end

--- 只读报价：qty 会被夹到 [1, maxQty]；revenue 与 SettleSale 同一套系数。
--- blocked 说明「为什么卖不了这么多」：stock / org_cap / demand / none。
---@param value number|table source 或 QBCore 玩家对象
---@param orgId string|nil
---@param qty number|string 不可信输入
---@return table|nil estimate, string|nil errcode
function IndustryUi.EstimateSale(value, orgId, qty)
    if not enabled() then return nil, 'disabled' end

    local Player = resolvePlayer(value)
    if not Player then return nil, 'not_player' end

    local resolved, orgErr = resolveOrgId(Player, orgId)
    if not resolved then return nil, orgErr end

    local item = (Config.Industry.Sales or {}).SeedItem
    local info, infoErr = IndustrySales.Inspect(resolved, item)
    if not info then return nil, infoErr or 'db_error' end

    local requested = toInt(qty)
    if not requested or requested < 1 then
        return {
            ok = false, qty = 0, unitPrice = info.unitPrice, revenue = 0,
            blocked = 'none', maxQty = info.maxQty, error = 'bad_qty',
        }, nil
    end

    local effective = math.min(requested, info.maxQty)
    if effective < 1 then
        return {
            ok = false, qty = 0, unitPrice = info.unitPrice, revenue = 0,
            blocked = limitingReason(info), maxQty = info.maxQty,
        }, nil
    end

    local revenue, revenueErr = IndustrySales.QuoteRevenue(info.unitPrice, effective)
    if not revenue then return nil, revenueErr or 'bad_amount' end

    local blocked
    if effective < requested then blocked = limitingReason(info) end

    return {
        ok = true,
        qty = effective,
        unitPrice = info.unitPrice,
        revenue = revenue,
        blocked = blocked,
        maxQty = info.maxQty,
    }, nil
end

--- 玩家侧卖单。qty 不可信：非法形状拒绝，超过 maxQty 夹紧。
---@return boolean ok, string|nil errcode, table|nil result
function IndustryUi.Sell(value, orgId, qty, untrusted)
    if not enabled() then return false, 'disabled' end

    local Player = resolvePlayer(value)
    if not Player then return false, 'not_player' end

    local resolved, orgErr = resolveOrgId(Player, orgId)
    if not resolved then return false, orgErr end

    if not IndustryAccess.IsOrgBoss(Player, resolved) then return false, 'not_boss' end

    noteUntrusted(resolved, untrusted)

    local item = (Config.Industry.Sales or {}).SeedItem
    local info, infoErr = IndustrySales.Inspect(resolved, item)
    if not info then return false, infoErr or 'db_error' end

    local requested = toInt(qty)
    if not requested or requested < 1 then return false, 'bad_qty' end

    local effective = math.min(requested, info.maxQty)
    if effective < 1 then
        local reason = limitingReason(info)
        if reason == 'stock' then return false, 'stock_empty' end
        if reason == 'org_cap' then return false, 'org_cap_reached' end
        if reason == 'demand' then return false, 'demand_exhausted' end
        return false, 'bad_qty'
    end

    local ok, saleErr, result = IndustrySales.SellForPlayer(
        Player, resolved, item, effective, nil)
    if not ok then return false, saleErr or 'db_error' end

    if type(result) == 'table' then result.requested_qty = requested end
    return true, nil, result
end

--- 玩家侧雇工位。金额只走设施模块既有的 Treasury 扣款路径。
---@return boolean ok, string|nil errcode, number|nil cost, number|nil workstations
function IndustryUi.HireWorkstation(value, orgId)
    if not enabled() then return false, 'disabled' end

    local Player = resolvePlayer(value)
    if not Player then return false, 'not_player' end

    local resolved, orgErr = resolveOrgId(Player, orgId)
    if not resolved then return false, orgErr end

    if not IndustryAccess.IsOrgBoss(Player, resolved) then return false, 'not_boss' end

    return Facility.AddWorkstation(resolved, {
        actor = Player.PlayerData.citizenid,
    })
end

-- 跨资源只读入口在加载期注册：手机 App 的 audience.visible 需要它稳定存在，
-- 否则 industry_enable=false 时每次拉 App 列表都会在 pcall 里撞一次 No such export。
-- 四个函数自己都先判 Config.Industry.Enabled（关闭时返回 false / 'disabled'），
-- 所以「注册了但整套不启动」不会产生任何业务副作用。
exports('CanAccessIndustry', IndustryUi.CanAccess)
exports('GetIndustrySnapshot', IndustryUi.Snapshot)
exports('EstimateIndustrySale', IndustryUi.EstimateSale)
exports('SellIndustryStock', IndustryUi.Sell)

local function respond(cb, ok, data, errcode)
    if ok then
        cb({ ok = true, data = data })
    else
        cb({ ok = false, error = errcode or 'db_error' })
    end
end

--- 服务端接线：只在 industry_enable 打开时由 main.lua 调用。
function IndustryUi.Register()
    local qb = core()
    -- ⚠️ 跨资源导出的函数在本 build 是**可调用表**（`type(fn) == 'table'`，靠 __call 调用）。
    -- 所以不能写 `type(qb.Functions.CreateCallback) ~= 'function'` —— 那条守卫恒真，
    -- 会把整套 UI 回调静默掉（实测：qb=table functions=table createCallback=table）。
    -- 同一个坑在 AGENTS.md 的 NUI `cb` 一条里记过；这里只判 nil 与可调用性。
    local createCallback = qb and qb.Functions and qb.Functions.CreateCallback
    if not createCallback then
        print(('[custom-industry] UI callbacks not registered: qb=%s err=%s'):format(
            type(qb), tostring(coreLastError)))
        return false
    end

    -- 客户端启动时先问一次「产业开没开」；关闭时这里不会注册，客户端也就不注入菜单。
    qb.Functions.CreateCallback('industry:server:uiState', function(_source, cb)
        cb({ ok = true, enabled = true })
    end)

    -- 组织菜单入口（/orgmenu）：qb-management 的两个菜单（qb-bossmenu 与 qb-orgmenu）
    -- 会在同一坐标抢交互，玩家会随机进其中一个，而「产业」项只注入组织菜单。
    -- 给组织菜单一个确定入口；这里只校验「在某个组织里」，是否 Boss 由各动作自己复验。
    qb.Functions.CreateCallback('industry:server:canOpenOrgMenu', function(source, cb)
        local Player = resolvePlayer(source)
        if not Player then cb({ ok = false, error = 'no_player' }) return end
        local resolved = resolveOrgId(Player, nil)
        if not resolved then cb({ ok = false, error = 'no_org' }) return end
        cb({ ok = true, orgId = resolved, isBoss = IndustryAccess.IsOrgBoss(Player, resolved) })
    end)

    qb.Functions.CreateCallback('industry:server:snapshot', function(source, cb, orgId)
        local snapshot, err = IndustryUi.Snapshot(source, orgId)
        respond(cb, snapshot ~= nil, snapshot, err)
    end)

    -- Boss 菜单只操作调用者自己的组织，因此不在回调参数里收 orgId；
    -- 手机 App 的 exports 仍接受 orgId 并做同一套复验。
    qb.Functions.CreateCallback('industry:server:estimate', function(source, cb, qty)
        local estimate, err = IndustryUi.EstimateSale(source, nil, qty)
        respond(cb, estimate ~= nil, estimate, err)
    end)

    qb.Functions.CreateCallback('industry:server:sell', function(source, cb, qty, untrusted)
        local ok, err, result = IndustryUi.Sell(source, nil, qty, untrusted)
        respond(cb, ok, result, err)
    end)

    qb.Functions.CreateCallback('industry:server:hire', function(source, cb, orgId)
        local ok, err, cost, workstations = IndustryUi.HireWorkstation(source, orgId)
        respond(cb, ok, { cost = cost, workstations = workstations }, err)
    end)

    return true
end
