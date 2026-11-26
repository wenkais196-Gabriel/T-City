-- server/sale.lua — S4 销售 / 配额。
--
-- 本文件是全仓**唯一**「无对应玩家扣款」的净增货币点：
--     Treasury.Deposit(orgId, revenue, 'sale', { ref = 'sale:' .. saleId })
-- 其它组织入账（S1 存款、S2 退款/补偿）都有对应的先扣或回滚，不是净增。
--
-- 执行顺序（写错方向就是白送钱）：
--   校验输入 → 读需求行 → 读库存 / 本组织累计
--    → 库存截断 → 本组织 50% 上限（超了就拒，不截断）→ 全服剩余截断
--    → 单条 UPDATE 扣库存（CAS: stock >= qty）
--    → 单条 UPDATE 扣配额（CAS: 全服剩余 + 本组织累计都在 WHERE 里）
--    → INSERT industry_sales（UNIQUE(org_id, ref) 是幂等键）
--    → Treasury.Deposit（ref = 'sale:' .. sale_id）
--    → 任一步失败都退回前面的状态。
--
-- 失败方向永远是「钱没进、库存还在」；不允许出现「配额扣了但没卖出去」。
--
-- 客户端只说「卖 N 件」：价格、倍率、配额剩余一律由服务端从配置 / core_economy 读，
-- 本函数没有 net event，也不读调用方传的表。
--
-- 授权：SettleSale 是服务端 API，不自己发明第二套权限判定。S5 的玩家侧入口必须先用
-- IndustryAccess.IsOrgBoss(Player, orgId) 放行（与 S1/S2 同一条判定），本片的
-- /orgsell 后台入口只接受控制台。

IndustrySales = {}

local MAX_ORG_LEN = 64
local ORG_PATTERN = '^[%w_%-]+$'
local MAX_ITEM_LEN = 64
local ITEM_PATTERN = '^[%w_%-]+$'
local MAX_REF_LEN = 96
local REF_PATTERN = '^[%w:_%-%.]+$'
local MAX_QTY = 1000000
-- 与 Treasury.validAmount 的上限一致：超过这个数的 revenue 一定入不了账。
local MAX_REVENUE = 1000000000000000

local seq = 0
--: 同一组织的在途卖单。配额 UPDATE 里的「本组织累计」读的是 industry_sales，
--: 而当前卖单要到第 ③ 步才插入；两个同组织请求在 await 之间交错时会都读到旧累计，
--: 各自通过 50% 判据。Lua 侧按 orgId 串行化（本资源是 SettleSale 的唯一调用方），
--: 数据库仍是全局配额的权威。
local busy = {}

local function salesConfig()
    return Config.Industry.Sales or {}
end

local function toInt(value)
    local number = tonumber(value)
    if not number or number ~= number or number ~= math.floor(number) then return nil end
    return number
end

local function positiveNumber(value, fallback)
    local number = tonumber(value)
    if not number or number ~= number or number <= 0 then return fallback end
    return number
end

local function validOrg(orgId)
    return type(orgId) == 'string'
        and #orgId > 0
        and #orgId <= MAX_ORG_LEN
        and orgId:match(ORG_PATTERN) ~= nil
end

local function validItem(item)
    return type(item) == 'string'
        and #item > 0
        and #item <= MAX_ITEM_LEN
        and item:match(ITEM_PATTERN) ~= nil
end

--- 缺省/形状不合法的 ref 改用服务端生成的 ref（形状不明的字符串不能当唯一键）。
local function normalizeRef(orgId, ref)
    if type(ref) == 'string' and #ref > 0 and #ref <= MAX_REF_LEN and ref:match(REF_PATTERN) then
        return ref
    end
    seq = seq + 1
    return ('sys:sale:%s:%d:%d'):format(orgId:sub(1, 24), os.time(), seq)
end

--- 系数只有一个来源：core_economy。本文件不写第二份「看起来差不多」的公式。
--- 资源没起 / 导出缺失时回落到 1.0（不是另写公式，是不加成）。
local function economyCoefficients(activityId)
    local global = 1.0
    local heat = 1.0
    if type(exports) ~= 'table' then return global, heat end

    local okGlobal, value = pcall(function()
        return exports['core_economy']:GetGlobalMultiplier()
    end)
    if okGlobal then global = positiveNumber(value, 1.0) end

    if type(activityId) == 'string' and activityId ~= '' then
        local okHeat, coefficient = pcall(function()
            return exports['core_economy']:GetActivityHeat(activityId)
        end)
        if okHeat then heat = positiveNumber(coefficient, 1.0) end
    end

    return global, heat
end

--- 审计 payload：金额 / 结果码 / ref / 物品 / 数量；不放玩家姓名等 PII。
local function auditPayload(amount, result, ref, item, qty)
    local safeResult = tostring(result or 'unknown'):gsub('[^%w_%-%.]', '_')
    local safeRef = tostring(ref or ''):gsub('[^%w:_%-%.]', '_')
    local safeItem = tostring(item or ''):gsub('[^%w_%-%.]', '_')
    return ('{"amount":%s,"result":"%s","ref":"%s","item":"%s","qty":%d}'):format(
        tostring(tonumber(amount) or 0), safeResult, safeRef, safeItem,
        math.floor(tonumber(qty) or 0))
end

local function audit(orgId, amount, result, ref, item, qty)
    IndustryAudit.Write(orgId, nil, 'industry.sale', auditPayload(amount, result, ref, item, qty))
end

---@return table|nil demand { total = int, used = int }, string|nil errcode
local function readDemand(cfg, item)
    local row, err = Db.Single(
        'SELECT quota_total, quota_used FROM industry_demand '
            .. 'WHERE cycle_no = ? AND phase = ? AND item_name = ? LIMIT 1',
        { cfg.CycleNo, cfg.Phase, item })
    if err then return nil, 'db_error' end
    if not row then return nil, 'no_demand' end

    local total = toInt(row.quota_total)
    local used = toInt(row.quota_used)
    if not total or not used or total < 0 or used < 0 then return nil, 'db_error' end
    return { total = total, used = used }, nil
end

---@return number|nil stock, string|nil errcode
local function readStock(orgId)
    local row, err = Db.Single(
        'SELECT stock FROM industry_facility WHERE org_id = ? LIMIT 1',
        { orgId })
    if err then return nil, 'db_error' end
    if not row then return nil, 'not_built' end

    local stock = toInt(row.stock)
    if not stock or stock < 0 then return nil, 'db_error' end
    return stock, nil
end

--- 本组织在本周期 / 本物品上的累计销量（50% 上限的分子）。
local function readOrgUsed(orgId, cfg, item)
    local row, err = Db.Single(
        'SELECT COALESCE(SUM(qty), 0) AS used FROM industry_sales '
            .. 'WHERE org_id = ? AND cycle_no = ? AND item_name = ? LIMIT 1',
        { orgId, cfg.CycleNo, item })
    if err then return nil, 'db_error' end

    local used = toInt(row and row.used or 0)
    if not used or used < 0 then return nil, 'db_error' end
    return used, nil
end

--- 单组织上限：floor(quota_total × 50%)。
local function orgCap(total, ratio)
    local value = tonumber(ratio)
    if not value or value ~= value or value < 0 then value = 0.5 end
    if value > 1 then value = 1 end
    return math.floor(total * value + 1e-9)
end

local function restoreStock(orgId, qty)
    local affected, err = Db.Update(
        'UPDATE industry_facility SET stock = stock + ? WHERE org_id = ?',
        { qty, orgId })
    if err or affected ~= 1 then
        print(('[custom-industry] CRITICAL sale stock rollback failed org=%s qty=%d err=%s'):format(
            tostring(orgId), qty, tostring(err or ('affected=' .. tostring(affected)))))
        return false
    end
    return true
end

local function restoreQuota(cfg, item, qty)
    local affected, err = Db.Update(
        'UPDATE industry_demand SET quota_used = quota_used - ? '
            .. 'WHERE cycle_no = ? AND phase = ? AND item_name = ? AND quota_used >= ?',
        { qty, cfg.CycleNo, cfg.Phase, item, qty })
    if err or affected ~= 1 then
        print(('[custom-industry] CRITICAL sale quota rollback failed item=%s qty=%d err=%s'):format(
            tostring(item), qty, tostring(err or ('affected=' .. tostring(affected)))))
        return false
    end
    return true
end

local function deleteSale(saleId, orgId)
    local affected, err = Db.Update(
        'DELETE FROM industry_sales WHERE id = ? AND org_id = ?',
        { saleId, orgId })
    if err or affected ~= 1 then
        print(('[custom-industry] CRITICAL sale row rollback failed org=%s id=%s err=%s'):format(
            tostring(orgId), tostring(saleId), tostring(err or ('affected=' .. tostring(affected)))))
        return false
    end
    return true
end

--- 配额 CAS 失败后重读一次，只为分类（重读不参与放行/拒绝）。
local function classifyQuotaFailure(orgId, cfg, item, qty)
    local demand = readDemand(cfg, item)
    if not demand then return 'db_error' end
    if demand.used >= demand.total then return 'demand_exhausted' end

    local used = readOrgUsed(orgId, cfg, item)
    if not used then return 'db_error' end
    if used + qty > orgCap(demand.total, cfg.OrgCapRatio) then return 'org_cap_reached' end
    return 'conflict'
end

--- 插卖单。唯一键冲突与「驱动没回 insertId」都通过插入后的存在性检查认回来；
--- 但两种情况都返回 duplicate_ref —— 无法区分「我刚插进去」与「上一次已经卖过」时，
--- 宁可拒绝也不能再入一次账。
local function insertSale(orgId, cfg, item, qty, unitPrice, revenue, ref)
    local id = Db.Insert(
        'INSERT INTO industry_sales (org_id, cycle_no, item_name, qty, unit_price, revenue, ref) '
            .. 'VALUES (?, ?, ?, ?, ?, ?, ?)',
        { orgId, cfg.CycleNo, item, qty, unitPrice, revenue, ref })
    if id then return id, nil end

    local row, lookupErr = Db.Single(
        'SELECT id FROM industry_sales WHERE org_id = ? AND ref = ? LIMIT 1',
        { orgId, ref })
    if not lookupErr and row and toInt(row.id) then return nil, 'duplicate_ref' end
    return nil, 'db_error'
end

--- 组织金库入账是「看得见的钱源」：dashboard 靠这个事件补组织侧的流入。
local function emitSaleEvent(orgId, item, qty, revenue)
    if type(TriggerEvent) ~= 'function' then return end
    pcall(TriggerEvent, 'industry:sale', orgId, item, qty, revenue)
end

--- 启动时确保种子需求行存在，并用 convar 校准「尚未使用」的配额。
--- 这不是调度：只在资源启动时跑一次。
---@return boolean ok, string|nil errcode
function IndustrySales.EnsureSeed()
    local cfg = salesConfig()
    if not validItem(cfg.SeedItem) then return false, 'bad_item' end

    local quota = toInt(cfg.SeedQuota)
    if not quota or quota < 0 then return false, 'bad_qty' end

    Db.Insert(
        'INSERT IGNORE INTO industry_demand (cycle_no, phase, item_name, quota_total, quota_used) '
            .. 'VALUES (?, ?, ?, ?, 0)',
        { cfg.CycleNo, cfg.Phase, cfg.SeedItem, quota })

    -- 只覆盖还没卖过的行：旋钮可以调，但不会把已经卖掉的配额改小。
    local _, err = Db.Update(
        'UPDATE industry_demand SET quota_total = ? '
            .. 'WHERE cycle_no = ? AND phase = ? AND item_name = ? AND quota_used = 0',
        { quota, cfg.CycleNo, cfg.Phase, cfg.SeedItem })
    if err then return false, 'db_error' end
    return true, nil
end

function IndustrySales.Start()
    local ok, err = IndustrySales.EnsureSeed()
    if not ok then
        print(('[custom-industry] demand seed failed: %s'):format(tostring(err)))
    end
end

--- 已持有组织锁的卖单主体。
---@return boolean ok, string|nil errcode, table|nil result
local function settleLocked(cfg, orgId, item, requested, ref)
    local prices = cfg.UnitPrices
    if type(prices) ~= 'table' then return false, 'bad_price' end
    local unitPrice = positiveNumber(prices[item], nil)
    if not unitPrice or unitPrice ~= math.floor(unitPrice) then return false, 'bad_price' end

    -- 系数只从 core_economy 拿；这里拿到的值只用于报价，不落库。
    local globalMultiplier, heat = economyCoefficients(cfg.ActivityId)

    local demand, demandErr = readDemand(cfg, item)
    if not demand then return false, demandErr end

    local stock, stockErr = readStock(orgId)
    if not stock then return false, stockErr end

    local orgUsed, usedErr = readOrgUsed(orgId, cfg, item)
    if not orgUsed then return false, usedErr end

    local globalRemaining = demand.total - demand.used
    if globalRemaining <= 0 then return false, 'demand_exhausted' end

    local cap = orgCap(demand.total, cfg.OrgCapRatio)
    local orgRemaining = cap - orgUsed
    if orgRemaining <= 0 then return false, 'org_cap_reached' end

    -- 库存是「有货就能卖」：按库存截断（测试里逐条断言这个选择）。
    local sellable = requested
    if sellable > stock then sellable = stock end
    if sellable <= 0 then return false, 'stock_empty' end

    -- 本组织 50% 上限**不截断**：请求超过自己的剩余份额直接拒绝（设计验收：
    -- 第二家组织超 5 件返回 org_cap_reached）。这一判据必须排在「全服剩余截断」
    -- 之前：第二家请求 6 件时全服只剩 5 件，若先截断成 5 就正好绕过 50% 闸门。
    if sellable > orgRemaining then return false, 'org_cap_reached' end

    -- 全服剩余按剩余量截断（跨组织抢配额时允许少卖，不报错）。
    if sellable > globalRemaining then sellable = globalRemaining end
    if sellable <= 0 then return false, 'demand_exhausted' end

    local unit = math.floor(unitPrice)
    local revenue = math.floor(unit * sellable * globalMultiplier * heat + 1e-9)
    if revenue <= 0 or revenue > MAX_REVENUE then return false, 'bad_amount' end

    local saleRef = normalizeRef(orgId, ref)

    -- ① 扣库存：单条 CAS，affectedRows 是唯一裁决依据。
    local stockAffected, stockUpdateErr = Db.Update(
        'UPDATE industry_facility SET stock = stock - ? WHERE org_id = ? AND stock >= ?',
        { sellable, orgId, sellable })
    if stockUpdateErr then return false, 'db_error' end
    if stockAffected ~= 1 then return false, 'conflict' end

    -- ② 扣配额：全服剩余与本组织累计（子查询 industry_sales）在同一条 UPDATE 里。
    local quotaAffected, quotaErr = Db.Update(
        'UPDATE industry_demand SET quota_used = quota_used + ? '
            .. 'WHERE cycle_no = ? AND phase = ? AND item_name = ? '
            .. 'AND quota_used + ? <= quota_total '
            .. 'AND (SELECT COALESCE(SUM(s.qty), 0) FROM industry_sales s '
            .. 'WHERE s.org_id = ? AND s.cycle_no = ? AND s.item_name = ?) + ? '
            .. '<= FLOOR(quota_total * ?)',
        {
            sellable, cfg.CycleNo, cfg.Phase, item,
            sellable, orgId, cfg.CycleNo, item, sellable, cfg.OrgCapRatio,
        })
    if quotaErr then
        if not restoreStock(orgId, sellable) then
            audit(orgId, revenue, 'rollback_failed', saleRef, item, sellable)
            return false, 'db_error'
        end
        return false, 'db_error'
    end
    if quotaAffected ~= 1 then
        local code = classifyQuotaFailure(orgId, cfg, item, sellable)
        if not restoreStock(orgId, sellable) then
            audit(orgId, revenue, 'rollback_failed', saleRef, item, sellable)
            return false, 'db_error'
        end
        return false, code
    end

    -- ③ 卖单落库：UNIQUE(org_id, ref) 是幂等键。
    local saleId, insertErr = insertSale(
        orgId, cfg, item, sellable, unit, revenue, saleRef)
    if not saleId then
        local quotaRestored = restoreQuota(cfg, item, sellable)
        local stockRestored = restoreStock(orgId, sellable)
        local result = (not quotaRestored or not stockRestored) and 'rollback_failed'
            or (insertErr or 'db_error')
        audit(orgId, revenue, result, saleRef, item, sellable)
        return false, insertErr or 'db_error'
    end

    -- ④ 唯一净增货币点：钱进组织金库。ref = 'sale:' .. sale_id 与卖单一一对应。
    local depositRef = 'sale:' .. tostring(saleId)
    local deposited, depositErr = Treasury.Deposit(orgId, revenue, 'sale', {
        ref = depositRef,
        cycleNo = cfg.CycleNo,
    })
    if not deposited then
        -- Deposit 的契约是失败时没有净变化；这里再把卖单 / 配额 / 库存退回。
        local saleRemoved = deleteSale(saleId, orgId)
        local quotaRestored = restoreQuota(cfg, item, sellable)
        local stockRestored = restoreStock(orgId, sellable)
        if not saleRemoved or not quotaRestored or not stockRestored then
            print(('[custom-industry] CRITICAL sale rollback failed org=%s ref=%s deposit=%s'):format(
                orgId, depositRef, tostring(depositErr or 'db_error')))
            audit(orgId, revenue, 'rollback_failed', depositRef, item, sellable)
        else
            audit(orgId, revenue, 'db_error', depositRef, item, sellable)
        end
        return false, 'db_error'
    end

    audit(orgId, revenue, 'ok', depositRef, item, sellable)
    emitSaleEvent(orgId, item, sellable, revenue)

    return true, nil, {
        sale_id = saleId,
        ref = saleRef,
        item = item,
        qty = sellable,
        unit_price = unit,
        revenue = revenue,
        quota_used = demand.used + sellable,
    }
end

--- 组织卖货。全仓唯一的净增货币出口。
---@param orgId string
---@param item string 配置里有价格的可卖物品（S4 只有 iron_ore）
---@param qty number 正整数；库存/全服剩余会截断，本组织 50% 上限会拒绝
---@param ref string|nil 幂等键；不合法时由服务端生成
---@return boolean ok, string|nil errcode, table|nil result
function IndustrySales.SettleSale(orgId, item, qty, ref)
    if not validOrg(orgId) then return false, 'bad_org' end
    if not validItem(item) then return false, 'bad_item' end

    local cfg = salesConfig()
    local maxQty = toInt(cfg.MaxQty) or MAX_QTY
    local requested = toInt(qty)
    if not requested or requested <= 0 or requested > maxQty then return false, 'bad_qty' end

    if busy[orgId] then return false, 'busy' end
    busy[orgId] = true

    local called, ok, err, result = pcall(settleLocked, cfg, orgId, item, requested, ref)
    busy[orgId] = nil

    if not called then
        -- 正常路径不会抛错（DB 调用都已被 Db.* 包了 pcall）；抛错时锁必须释放，
        -- 且不能向调用方报成功（此时可能已经动过库存/配额，留 CRITICAL 痕迹）。
        print(('[custom-industry] CRITICAL sale crashed org=%s item=%s err=%s'):format(
            tostring(orgId), tostring(item), tostring(ok)))
        return false, 'db_error'
    end
    return ok, err, result
end
