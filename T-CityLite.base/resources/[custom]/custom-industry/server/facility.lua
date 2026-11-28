-- server/facility.lua — S2 设施 / 工位。
--
-- 铁律：
--   1. 组织层的钱只有一条出口：Treasury.Withdraw；退回只有 Treasury.Deposit。
--   2. 先扣钱、再改设施行；改行失败必须退回（失败方向永远是「钱没少、工位没加」）。
--   3. 工位上限与乐观锁在同一条 UPDATE 的 WHERE 里：
--        UPDATE industry_facility SET workstations = workstations + 1
--         WHERE org_id = ? AND workstations = ? AND workstations < ?
--      affectedRows 是唯一裁决依据；affected = 0 才重读一次区分 cap_reached / conflict。
--      注意：顺序执行时「预读上限」只用于避免无谓扣款，真正的守卫仍是 UPDATE。
--   4. 每次动作（成功与失败）写 industry_audit，payload 只有金额 / 结果码 / ref / 工位数。

Facility = {}

local seq = 0

local validOrg = IndustryOrgId.IsValid -- 统一在 server/org_id.lua（S4 合并 4 份重复实现）

local function normalizeActor(actor)
    if type(actor) == 'string' and #actor > 0 and #actor <= 64 then return actor end
    return nil
end

local function makeRef(kind, orgId, n)
    seq = seq + 1
    return ('fac:%s:%s:%d:%d:%d'):format(kind, orgId, n or 0, os.time(), seq)
end

--- 审计 payload：在 S1 的金额/结果码/ref 之外多带一个 workstations。
local function auditPayload(amount, result, ref, workstations)
    local safeResult = tostring(result or 'unknown'):gsub('[^%w_%-%.]', '_')
    local safeRef = tostring(ref or ''):gsub('[^%w:_%-%.]', '_')
    local count = math.floor(tonumber(workstations) or 0)
    return ('{"amount":%s,"result":"%s","ref":"%s","workstations":%d}'):format(
        tostring(tonumber(amount) or 0), safeResult, safeRef, count)
end

local function audit(orgId, actor, action, amount, result, ref, workstations)
    IndustryAudit.Write(orgId, actor, action,
        auditPayload(amount, result, ref, workstations))
end

--- 库存升级的审计 payload：在金额/结果码/ref 之外带库存等级。
--- 单独一份而不是改 `auditPayload`，避免既有设施动作的 payload 形状变化。
local function stockAuditPayload(amount, result, ref, stockLevel)
    local safeResult = tostring(result or 'unknown'):gsub('[^%w_%-%.]', '_')
    local safeRef = tostring(ref or ''):gsub('[^%w:_%-%.]', '_')
    local level = math.floor(tonumber(stockLevel) or 0)
    return ('{"amount":%s,"result":"%s","ref":"%s","stock_level":%d}'):format(
        tostring(tonumber(amount) or 0), safeResult, safeRef, level)
end

local function stockAudit(orgId, actor, amount, result, ref, stockLevel)
    IndustryAudit.Write(orgId, actor, 'facility.stock_upgrade',
        stockAuditPayload(amount, result, ref, stockLevel))
end

--- Treasury 的错误码里只有三个属于设施动作；其余一律折叠成 db_error。
--- （Withdraw 不会返回 no_account：账户不存在时 S1 报 insufficient_funds。）
local function treasuryCode(err)
    if err == 'bad_org' or err == 'insufficient_funds' or err == 'db_error' then
        return err
    end
    return 'db_error'
end

local function insertLikelySucceeded(id, err)
    if id then return true end
    -- industry_facility 没有 AUTO_INCREMENT：成功的 INSERT 也会被 Db.Insert
    -- 归一成 no_insert_id，那不是错误。
    return err == 'no_insert_id'
end

--- 购置闸：衰退期只关「买」，不关「卖」（卖在 sale.lua，本函数不碰）。
--- 读不到周期状态时 fail closed（返回 db_error），不把阶段限制静默跳过。
---@return boolean ok, string|nil errcode
local function purchaseGate()
    if type(IndustryCycle) ~= 'table' or not IndustryCycle.CanPurchase then
        return false, 'db_error'
    end
    local open, err = IndustryCycle.CanPurchase()
    if open == nil then return false, err or 'db_error' end
    if open ~= true then return false, 'purchases_closed' end
    return true, nil
end

--- 第 n 个工位成本：n = 当前 workstations + 1。
--- 即 WorkstationCost(type, 0) = baseCost（第 1 个工位）。
---@return number|nil cost, string|nil errcode
function Facility.WorkstationCost(facilityType, workstations)
    local config = Config.Industry.Facilities[facilityType]
    if not config then return nil, 'bad_type' end
    local current = math.floor(tonumber(workstations) or 0)
    if current < 0 then return nil, 'bad_type' end
    return math.floor(config.baseCost * (1.35 ^ current))
end

--- 库存上限 = 基础上限 + 每级增量 × 等级（#411）。
--- 等级来自 `industry_facility.stock_level`，这里夹到配置的 [0, stockLevelMax]：
--- 坏数据（负数 / 超过上限）不能让生产算出更小或更大的闸门。
--- 第二参默认 'mine'：当前只有一种设施类型，保持 `StockCapFor(level)` 的调用形状。
---@param level number|nil
---@param facilityType string|nil
---@return number cap 0 when the facility type is unknown（fail closed）
function Facility.StockCapFor(level, facilityType)
    local config = Config.Industry.Facilities[facilityType or 'mine']
    if type(config) ~= 'table' then return 0 end

    local base = math.floor(tonumber(config.stockCap) or 0)
    local step = math.floor(tonumber(config.stockCapPerLevel) or 0)
    local maxLevel = math.floor(tonumber(config.stockLevelMax) or 0)
    local current = math.floor(tonumber(level) or 0)
    if current < 0 then current = 0 end
    if current > maxLevel then current = maxLevel end
    return base + step * current
end

--- 从 level 升到 level+1 的价格：floor(baseCost × growth^level)（#411）。
--- 满级返回 nil：快照用 nil 表示「不可再升」，手机端据此禁用按钮。
---@return number|nil cost, string|nil errcode
function Facility.StockUpgradeCost(facilityType, level)
    local config = Config.Industry.Facilities[facilityType]
    if type(config) ~= 'table' then return nil, 'bad_type' end

    local current = math.floor(tonumber(level) or 0)
    local maxLevel = math.floor(tonumber(config.stockLevelMax) or 0)
    if current < 0 or current >= maxLevel then return nil, 'max_level' end

    local baseCost = tonumber(config.stockUpgradeBaseCost) or 0
    local growth = tonumber(config.stockUpgradeGrowth) or 1
    return math.floor(baseCost * (growth ^ current)), nil
end

--- 读整行（只读）。显式列名 + LIMIT，禁止 SELECT *。
---@return table|nil row, string|nil errcode
function Facility.Get(orgId)
    if not validOrg(orgId) then return nil, 'bad_org' end
    local row, err = Db.Single(
        'SELECT org_id, facility_type, level, workstations, stock_level, recipe_id, stock, '
            .. 'last_tick_at, created_at, produced_units '
            .. 'FROM industry_facility WHERE org_id = ? LIMIT 1',
        { orgId })
    if err then return nil, 'db_error' end
    if not row then return nil, 'not_built' end
    return row, nil
end

--- 建设施（L1，workstations = 0）。一组织一设施；已存在返回 already_built，不扣钱。
---@param orgId string
---@param facilityType string Config.Industry.Facilities 的键
---@param opts table|nil { actor = citizenid|nil, ref = string|nil }
---@return boolean ok, string|nil errcode, number|nil cost
function Facility.Build(orgId, facilityType, opts)
    if not validOrg(orgId) then return false, 'bad_org' end

    opts = opts or {}
    local actor = normalizeActor(opts.actor)
    local ref = opts.ref or makeRef('build', orgId, 0)

    local config = Config.Industry.Facilities[facilityType]
    if not config then
        audit(orgId, actor, 'facility.build', 0, 'bad_type', ref, 0)
        return false, 'bad_type'
    end

    local purchasable, gateErr = purchaseGate()
    if not purchasable then
        audit(orgId, actor, 'facility.build', 0, gateErr or 'purchases_closed', ref, 0)
        return false, gateErr or 'purchases_closed'
    end

    local cost = config.baseCost

    local existing, lookupErr = Db.Single(
        'SELECT org_id FROM industry_facility WHERE org_id = ? LIMIT 1',
        { orgId })
    if lookupErr then
        audit(orgId, actor, 'facility.build', cost, 'db_error', ref, 0)
        return false, 'db_error'
    end
    if existing then
        audit(orgId, actor, 'facility.build', 0, 'already_built', ref, 0)
        return false, 'already_built'
    end

    local paid, payErr = Treasury.Withdraw(orgId, cost, 'facility-build', {
        actor = actor,
        ref = ref,
    })
    if not paid then
        local code = treasuryCode(payErr)
        audit(orgId, actor, 'facility.build', cost, code, ref, 0)
        return false, code
    end

    local id, insertErr = Db.Insert(
        'INSERT INTO industry_facility (org_id, facility_type, level, workstations, stock) '
            .. 'VALUES (?, ?, 1, 0, 0)',
        { orgId, facilityType })

    if not insertLikelySucceeded(id, insertErr) then
        -- 并发 Build 会撞 PK；驱动把错误当字符串回包时原文会丢，用存在性检查认回来。
        local text = type(insertErr) == 'string' and insertErr:lower() or ''
        local duplicate = text:find('duplicate', 1, true) ~= nil
            or text:find('primary', 1, true) ~= nil
        if not duplicate then
            local row, rowErr = Db.Single(
                'SELECT org_id FROM industry_facility WHERE org_id = ? LIMIT 1',
                { orgId })
            duplicate = (not rowErr and row ~= nil)
        end

        local code = duplicate and 'already_built' or 'db_error'
        local refunded, refundErr = Treasury.Deposit(orgId, cost, 'facility-build-rollback', {
            actor = actor,
            ref = ref .. ':rb',
        })
        if not refunded then
            print(('[custom-industry] CRITICAL build rollback failed org=%s ref=%s err=%s'):format(
                orgId, ref, tostring(refundErr)))
            code = 'db_error'
        end
        audit(orgId, actor, 'facility.build', cost, code, ref, 0)
        return false, code
    end

    audit(orgId, actor, 'facility.build', cost, 'ok', ref, 0)
    return true, nil, cost
end

--- 雇一个工位。上限与并发都在同一条 UPDATE 里；affected = 0 时退款并重读定性。
---@param orgId string
---@param opts table|nil { actor = citizenid|nil, ref = string|nil }
---@return boolean ok, string|nil errcode, number|nil cost, number|nil workstations
function Facility.AddWorkstation(orgId, opts)
    if not validOrg(orgId) then return false, 'bad_org' end

    opts = opts or {}
    local actor = normalizeActor(opts.actor)

    local purchasable, gateErr = purchaseGate()
    if not purchasable then
        audit(orgId, actor, 'facility.hire', 0, gateErr or 'purchases_closed', opts.ref, 0)
        return false, gateErr or 'purchases_closed'
    end

    local row, readErr = Db.Single(
        'SELECT facility_type, workstations FROM industry_facility WHERE org_id = ? LIMIT 1',
        { orgId })
    if readErr then
        audit(orgId, actor, 'facility.hire', 0, 'db_error', opts.ref, 0)
        return false, 'db_error'
    end
    if not row then
        audit(orgId, actor, 'facility.hire', 0, 'not_built', opts.ref, 0)
        return false, 'not_built'
    end

    local facilityType = row.facility_type
    local config = Config.Industry.Facilities[facilityType]
    if not config then
        audit(orgId, actor, 'facility.hire', 0, 'bad_type', opts.ref, tonumber(row.workstations))
        return false, 'bad_type'
    end

    local current = math.floor(tonumber(row.workstations) or 0)
    local cap = math.floor(tonumber(config.workstationCap) or 0)
    local ref = opts.ref or makeRef('hire', orgId, current + 1)

    -- 预读只用于避免「上限了还先扣一笔再退」；真正的守卫在下面的 UPDATE。
    if current >= cap then
        audit(orgId, actor, 'facility.hire', 0, 'cap_reached', ref, current)
        return false, 'cap_reached'
    end

    local cost = Facility.WorkstationCost(facilityType, current)
    local paid, payErr = Treasury.Withdraw(orgId, cost, 'workstation-hire', {
        actor = actor,
        ref = ref,
    })
    if not paid then
        local code = treasuryCode(payErr)
        audit(orgId, actor, 'facility.hire', cost, code, ref, current)
        return false, code
    end

    -- 上限 + 乐观锁：affectedRows 是唯一裁决依据。
    local affected, updateErr = Db.Update(
        'UPDATE industry_facility SET workstations = workstations + 1 '
            .. 'WHERE org_id = ? AND workstations = ? AND workstations < ?',
        { orgId, current, cap })

    if updateErr then
        local refunded, refundErr = Treasury.Deposit(orgId, cost, 'workstation-rollback', {
            actor = actor,
            ref = ref .. ':rb',
        })
        if not refunded then
            print(('[custom-industry] CRITICAL hire rollback failed org=%s ref=%s err=%s'):format(
                orgId, ref, tostring(refundErr)))
        end
        audit(orgId, actor, 'facility.hire', cost, 'db_error', ref, current)
        return false, 'db_error'
    end

    if affected ~= 1 then
        -- 重读一次只为分类：cap_reached（别人填满）还是 conflict（别人改了工位）。
        local after, afterErr = Db.Single(
            'SELECT workstations FROM industry_facility WHERE org_id = ? LIMIT 1',
            { orgId })
        local code
        local count = current
        if afterErr then
            code = 'db_error'
        elseif not after then
            code = 'not_built'
        else
            count = math.floor(tonumber(after.workstations) or 0)
            code = count >= cap and 'cap_reached' or 'conflict'
        end

        local refunded, refundErr = Treasury.Deposit(orgId, cost, 'workstation-rollback', {
            actor = actor,
            ref = ref .. ':rb',
        })
        if not refunded then
            print(('[custom-industry] CRITICAL hire rollback failed org=%s ref=%s err=%s'):format(
                orgId, ref, tostring(refundErr)))
            code = 'db_error'
        end
        audit(orgId, actor, 'facility.hire', cost, code, ref, count)
        return false, code
    end

    local workstations = current + 1
    audit(orgId, actor, 'facility.hire', cost, 'ok', ref, workstations)
    return true, nil, cost, workstations
end

--- 退回一次失败的库存升级扣款。补偿失败只记录（钱与等级的不一致必须留痕）。
local function refundStockUpgrade(orgId, actor, cost, ref)
    local refunded, refundErr = Treasury.Deposit(orgId, cost, 'stock-upgrade-rollback', {
        actor = actor,
        ref = ref .. ':rb',
    })
    if not refunded then
        print(('[custom-industry] CRITICAL stock upgrade rollback failed org=%s ref=%s err=%s'):format(
            orgId, ref, tostring(refundErr)))
    end
    return refunded
end

--- 升级库存上限（P3/#411）。
---
--- Boss / 成员身份由 ui.lua 的玩家入口复验（本模块不持 Player 对象，避免出现第二份
--- 权限判定）；本函数只负责组织层：等级上限、金库扣款、等级行 CAS。
---
--- 顺序与工位一致：先扣钱（Treasury.Withdraw 的余额判定与扣减在同一条 UPDATE），
--- 再改等级；改行失败（DB 错误 / 并发冲突 / 读后别人升满）一律退回。
--- 等级上限与乐观锁都写在 UPDATE 的 WHERE 里，affectedRows 是唯一裁决依据：
---   UPDATE industry_facility SET stock_level = stock_level + 1
---    WHERE org_id = ? AND stock_level = ? AND stock_level < ?
---
---@param orgId string
---@param opts table|nil { actor = citizenid|nil, ref = string|nil }
---@return boolean ok, string|nil errcode, number|nil cost, number|nil stockLevel, number|nil stockCap
function Facility.UpgradeStock(orgId, opts)
    if not validOrg(orgId) then return false, 'bad_org' end

    opts = opts or {}
    local actor = normalizeActor(opts.actor)
    local ref = opts.ref or makeRef('stockup', orgId, 0)

    local row, readErr = Db.Single(
        'SELECT facility_type, stock_level FROM industry_facility WHERE org_id = ? LIMIT 1',
        { orgId })
    if readErr then
        stockAudit(orgId, actor, 0, 'db_error', ref, 0)
        return false, 'db_error'
    end
    if not row then
        stockAudit(orgId, actor, 0, 'not_built', ref, 0)
        return false, 'not_built'
    end

    local facilityType = tostring(row.facility_type or '')
    local config = Config.Industry.Facilities[facilityType]
    if type(config) ~= 'table' then
        stockAudit(orgId, actor, 0, 'bad_type', ref, 0)
        return false, 'bad_type'
    end

    local current = math.floor(tonumber(row.stock_level) or 0)
    if current < 0 then current = 0 end
    local maxLevel = math.floor(tonumber(config.stockLevelMax) or 0)
    if current >= maxLevel then
        stockAudit(orgId, actor, 0, 'max_level', ref, current)
        return false, 'max_level'
    end

    local cost = Facility.StockUpgradeCost(facilityType, current)
    if not cost then
        stockAudit(orgId, actor, 0, 'max_level', ref, current)
        return false, 'max_level'
    end

    -- 余额不足由 Treasury.Withdraw 的同一条守卫 UPDATE 拒绝；不先读余额（TOCTOU）。
    local paid, payErr = Treasury.Withdraw(orgId, cost, 'stock-upgrade', {
        actor = actor,
        ref = ref,
    })
    if not paid then
        local code = treasuryCode(payErr)
        stockAudit(orgId, actor, cost, code, ref, current)
        return false, code
    end

    local affected, updateErr = Db.Update(
        'UPDATE industry_facility SET stock_level = stock_level + 1 '
            .. 'WHERE org_id = ? AND stock_level = ? AND stock_level < ?',
        { orgId, current, maxLevel })

    if updateErr then
        refundStockUpgrade(orgId, actor, cost, ref)
        stockAudit(orgId, actor, cost, 'db_error', ref, current)
        return false, 'db_error'
    end

    if affected ~= 1 then
        -- 重读一次只为分类：max_level（别人升满）还是 conflict（别人改了等级）。
        local after, afterErr = Db.Single(
            'SELECT stock_level FROM industry_facility WHERE org_id = ? LIMIT 1',
            { orgId })
        local code
        local level = current
        if afterErr then
            code = 'db_error'
        elseif not after then
            code = 'not_built'
        else
            level = math.floor(tonumber(after.stock_level) or 0)
            if level < 0 then level = 0 end
            code = level >= maxLevel and 'max_level' or 'conflict'
        end

        local refunded = refundStockUpgrade(orgId, actor, cost, ref)
        if not refunded then code = 'db_error' end
        stockAudit(orgId, actor, cost, code, ref, level)
        return false, code
    end

    local newLevel = current + 1
    local newCap = Facility.StockCapFor(newLevel, facilityType)
    stockAudit(orgId, actor, cost, 'ok', ref, newLevel)
    return true, nil, cost, newLevel, newCap
end
