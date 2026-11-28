-- server/apps/industry.lua — 产业 App（只读快照 + 卖出入参）。
--
-- 事实源全部在 custom-industry：本文件只做
--   1) 可见性：audience.visible 调 CanAccessIndustry（与 IndustryAccess 同一套 job/gang）；
--   2) 把 Snapshot 投影成 DynamicApp 能渲染的一行 KV（数字不再加工）；
--   3) sell 先调 EstimateIndustrySale（只读），再调 SellIndustryStock（服务端复验 Boss）；
--   4) hire 只把 orgId 交给 HireIndustryWorkstation（服务端复验成员 + Boss 后才扣款）。
--
-- 没有新增 NUI 回调/net event：专用页面用 snapshot / snapshot_estimate，兜底 DynamicApp
-- 仍只调 meta.queries[0]。所以第一查询必须叫 snapshot（注册表按名字排序；"snapshot" 是
-- "snapshot_estimate" 的前缀，排在最前），否则兜底列表会拿到报价而不是快照。

local BLOCK_TEXT = {
    stock = '库存不足',
    org_cap = '本组织配额已用完',
    demand = '全服配额已用完',
    none = '当前不可卖出',
    cap = '工位已满',
    funds = '金库余额不足',
    phase = '当前阶段不可购置',
    cap_reached = '工位已满',
    max_level = '库存已满级',
    insufficient_funds = '金库余额不足',
    purchases_closed = '当前阶段不可购置',
    not_built = '尚未建设施',
    conflict = '工位状态已变化，请重试',
    not_boss = '只有 Boss 能操作',
    not_member = '不是该组织成员',
}

local function validOrgId(value)
    if type(value) ~= 'string' then return nil end
    if #value == 0 or #value > 64 then return nil end
    if not value:match('^[%w_%-]+$') then return nil end
    return value
end

local function orgParam(params)
    if type(params) ~= 'table' then return nil end
    return validOrgId(params.orgId)
end

local function missingExport()
    print('[custom-phone][apps] industry unavailable: custom-industry export missing')
end

local function canAccess(source)
    -- 资源没起时不要靠 pcall 去撞 "No such export"（每次拉列表都会刷一行控制台）。
    if GetResourceState('custom-industry') ~= 'started' then return false end
    local ok, visible = pcall(function()
        return exports['custom-industry']:CanAccessIndustry(source)
    end)
    return ok and visible == true
end

local function getSnapshot(source, orgId)
    local ok, snapshot, err = pcall(function()
        return exports['custom-industry']:GetIndustrySnapshot(source, orgId)
    end)
    if not ok then missingExport() return nil, 'unavailable' end
    return snapshot, err
end

local function estimateSale(source, orgId, qty)
    local ok, estimate, err = pcall(function()
        return exports['custom-industry']:EstimateIndustrySale(source, orgId, qty)
    end)
    if not ok then missingExport() return nil, 'unavailable' end
    return estimate, err
end

local function sellStock(source, orgId, qty, params)
    local ok, sold, err, result = pcall(function()
        return exports['custom-industry']:SellIndustryStock(source, orgId, qty, params)
    end)
    if not ok then missingExport() return false, 'unavailable' end
    return sold, err, result
end

local function hireWorkstation(source, orgId)
    local ok, hired, err, cost, workstations = pcall(function()
        return exports['custom-industry']:HireIndustryWorkstation(source, orgId)
    end)
    if not ok then missingExport() return false, 'unavailable' end
    return hired, err, cost, workstations
end

local function upgradeStock(source, orgId)
    -- 与雇工位共用同一个导出（第三参选择动作），不扩 custom-industry 的导出面。
    local ok, upgraded, err, cost, stockLevel, stockCap = pcall(function()
        return exports['custom-industry']:HireIndustryWorkstation(source, orgId, 'stock')
    end)
    if not ok then missingExport() return false, 'unavailable' end
    return upgraded, err, cost, stockLevel, stockCap
end

--- DynamicApp 的兜底渲染是「key → value」列表；这里只做展示，不带写操作。
local function displayRow(snapshot)
    local row = {
        ['组织'] = snapshot.orgLabel,
        ['职级'] = snapshot.gradeName,
        ['身份'] = snapshot.isBoss and 'Boss' or '成员',
        ['金库余额'] = '$' .. Money(snapshot.balance or 0),
    }
    if not snapshot.facility then
        row['设施'] = '尚未建设施'
        return row
    end

    local facility = snapshot.facility
    local demand = snapshot.demand
    local sellable = snapshot.sellable

    row['设施'] = ('%s L%d · 工位 %d/%d'):format(
        facility.label, facility.level, facility.workstations, facility.workstationCap)
    row['库存'] = ('%d / %d'):format(facility.stock, facility.stockCap)
    row['配额'] = ('全服剩 %d / %d · 本组织剩 %d / %d'):format(
        demand.globalRemaining, demand.globalTotal, demand.orgRemaining, demand.orgCap)
    row['单位售价'] = '$' .. Money(demand.unitPrice or 0)
    row['累计产出'] = tostring(snapshot.producedUnits or 0)

    if snapshot.isBoss then
        if sellable.maxQty > 0 then
            row['可卖'] = ('最多 %d 件'):format(sellable.maxQty)
        else
            row['可卖'] = ('不可卖：%s'):format(
                BLOCK_TEXT[sellable.blocked] or '当前不可卖出')
        end
    end
    return row
end

PhoneApps.Register({
    id = 'industry',
    label = '产业',
    icon = '⛏️',
    audience = {
        -- 权限判定只有一处：custom-industry 的 IndustryAccess（job 与 gang 都覆盖）。
        -- custom-industry 没启动/关闭时导出不存在，pcall 失败 → 不可见（fail closed）。
        visible = function(source)
            return canAccess(source)
        end,
    },
    queries = {
        snapshot = function(source, params)
            local snapshot, err = getSnapshot(source, orgParam(params))
            if type(snapshot) ~= 'table' then
                return { rows = {}, count = 0, error = err or 'industry_unavailable' }
            end
            return {
                rows = { displayRow(snapshot) },
                count = 1,
                snapshot = snapshot,
            }
        end,
        -- 供将来的专用皮肤先报价、再 sell；DynamicApp 只调第一查询 snapshot。
        snapshot_estimate = function(source, params)
            local qty = type(params) == 'table' and params.qty or nil
            local estimate, err = estimateSale(source, orgParam(params), qty)
            if type(estimate) ~= 'table' then
                return { ok = false, error = err or 'unavailable' }
            end
            return { ok = true, estimate = estimate }
        end,
    },
    actions = {
        sell = function(source, params)
            local orgId = orgParam(params)
            local qty = type(params) == 'table' and params.qty or nil

            -- 先只读报价：拿到被服务端夹紧后的 qty 与收益，再进入写路径。
            local estimate, estimateErr = estimateSale(source, orgId, qty)
            if type(estimate) ~= 'table' then
                return { ok = false, error = estimateErr or 'estimate_failed' }
            end
            if estimate.ok ~= true then
                return {
                    ok = false,
                    error = estimate.error or estimate.blocked or 'not_sellable',
                    detail = BLOCK_TEXT[estimate.blocked] or '',
                }
            end

            -- params 原样作为「不可信附加值」传给服务端：价格/倍率字段会被忽略并记录。
            local sold, sellErr, result = sellStock(source, orgId, estimate.qty, params)
            if not sold then
                return { ok = false, error = sellErr or 'rejected' }
            end
            return {
                ok = true,
                qty = result and result.qty or estimate.qty,
                revenue = result and result.revenue or estimate.revenue,
                unit_price = result and result.unit_price or estimate.unitPrice,
                estimate = estimate,
            }
        end,
        hire = function(source, params)
            -- 只收 orgId：成本与工位号由服务端从配置/SQL 计算，客户端传了也不读。
            local orgId = orgParam(params)
            local hired, hireErr, cost, workstations = hireWorkstation(source, orgId)
            if not hired then
                return {
                    ok = false,
                    error = hireErr or 'rejected',
                    detail = BLOCK_TEXT[hireErr] or '',
                }
            end
            return { ok = true, cost = cost, workstations = workstations }
        end,
        upgrade_stock = function(source, params)
            -- P3（#411）：只收 orgId；价格 / 等级 / 上限全部由 custom-industry 计算。
            local orgId = orgParam(params)
            local upgraded, upgradeErr, cost, stockLevel, stockCap =
                upgradeStock(source, orgId)
            if not upgraded then
                return {
                    ok = false,
                    error = upgradeErr or 'rejected',
                    detail = BLOCK_TEXT[upgradeErr] or '',
                }
            end
            return {
                ok = true,
                cost = cost,
                stock_level = stockLevel,
                stock_cap = stockCap,
            }
        end,
    },
})
