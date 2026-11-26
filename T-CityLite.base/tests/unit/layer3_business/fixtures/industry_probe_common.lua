-- fixtures/industry_probe_common.lua — industry 假 DB 的共享语义层。
--
-- 由 tests/unit/layer3_business/industry_harness.py 在**所有 industry 探针之前**
-- 注入（sales / cycle / treasury / facility / production / ui）。探针之间逐份复制的
-- 东西全部收在这里（issue #377）：
--
--   1. 行构造器（facility / ledger / audit / demand / sale）；
--   2. 共享状态读取（余额 / 设施库存 / 审计 / 流水 / 卖单）；
--   3. 假 DB 的 SQL 求值（UPDATE / INSERT / SELECT 的 affectedRows 语义）；
--   4. 世界接口桩（__emit / exports / TriggerEvent / GetConvar）。
--
-- 边界：这里只实现「真库会怎么做」。探针各自保留**特有的 SQL 形状、失败注入与
-- 状态机**（cycle 的 phase 闸门、facility 的工位 CAS、treasury 的 __uniqueRef 等）。
-- 条件不满足一律返回 affectedRows = 0，不存在「认不出的语句就当成功」的兜底。
--
-- 状态容器按探针的既有形状读取：S1/S4 的 `__orgs` 是数字表，S6 的 `__treasuries`
-- 是行表；设施同理（S4 数字、S2/S6 行）。适配只在这里做一份。

-- ── 行构造器 ─────────────────────────────────────────────────────

function __industryCopy(row)
    local out = {}
    for key, value in pairs(row) do out[key] = value end
    return out
end

function __industryDemandKey(cycleNo, phase, item)
    return tostring(cycleNo) .. '\0' .. tostring(phase) .. '\0' .. tostring(item)
end

---@param orgId string
---@param values table|nil
function __industryFacilityRow(orgId, values)
    values = values or {}
    return {
        org_id = orgId,
        facility_type = values.facility_type or 'mine',
        level = values.level or 1,
        workstations = values.workstations or 0,
        recipe_id = values.recipe_id,
        stock = values.stock or 0,
        produced_units = values.produced_units or 0,
        last_tick_epoch = values.last_tick_epoch or 0,
    }
end

function __industryLedgerRow(id, orgId, delta, balanceAfter, reason, ref)
    return {
        id = id,
        org_id = orgId,
        delta = delta,
        balance_after = balanceAfter,
        reason = reason,
        ref = ref,
    }
end

--- `industry_audit` 的两种参数形状：带 actor（4 个）与不带 actor（3 个）。
function __industryAuditEntry(values)
    if #values == 4 then
        return {
            org_id = values[1], actor_cid = values[2], action = values[3], payload = values[4],
        }
    end
    return {
        org_id = values[1], actor_cid = nil, action = values[2], payload = values[3],
    }
end

function __industryDemandRow(cycleNo, phase, item, total, used)
    return {
        cycle_no = cycleNo,
        phase = phase,
        item_name = item,
        quota_total = tonumber(total) or 0,
        quota_used = tonumber(used) or 0,
    }
end

function __industrySaleRow(fields)
    return {
        id = fields.id,
        org_id = fields.org_id,
        cycle_no = fields.cycle_no,
        item_name = fields.item_name,
        qty = tonumber(fields.qty),
        unit_price = tonumber(fields.unit_price),
        revenue = tonumber(fields.revenue),
        ref = fields.ref,
    }
end

-- ── 世界接口桩 ───────────────────────────────────────────────────

function __emit(key, value)
    io.write(tostring(key) .. '|' .. tostring(value) .. string.char(10))
end

__convars = __convars or {}

function GetConvar(name, default)
    local value = __convars[name]
    if value == nil then return default end
    return tostring(value)
end

__saleEvents = __saleEvents or {}

function TriggerEvent(name, ...)
    if name ~= 'industry:sale' then return end
    __saleEvents[#__saleEvents + 1] = { ... }
end

--- 资源导出面：`exports[resource]` 回资源表，`exports('name', fn)` 记录自注册。
--- core_economy 的系数导出是 S4/S6 共用的，默认就挂上；探针只追加自己的资源。
function __industryExports(resources)
    resources = resources or {}
    resources.core_economy = resources.core_economy or {
        GetGlobalMultiplier = function() return __globalMultiplier end,
        GetActivityHeat = function() return __activityHeat end,
    }
    return setmetatable({}, {
        __index = function(_, resource) return resources[resource] end,
        __call = function(_, name, fn)
            __exportFns = __exportFns or {}
            __exportFns[name] = fn
        end,
    })
end

-- ── 共享状态读取 ─────────────────────────────────────────────────

--- 设施库存：S4/UI 的 `__facilities[orgId]` 是数字，S2/S6 是整行。
function __industryFacilityStock(orgId)
    local row = __facilities and __facilities[orgId]
    if row == nil then return nil end
    if type(row) == 'table' then return tonumber(row.stock) or 0 end
    return tonumber(row) or 0
end

function __industryFacilitySetStock(orgId, stock)
    local row = __facilities[orgId]
    if type(row) == 'table' then
        row.stock = stock
    else
        __facilities[orgId] = stock
    end
end

function __facility(orgId)
    return __facilities[orgId]
end

function __facilitySeed(orgId, values)
    __facilities[orgId] = __industryFacilityRow(orgId, values)
end

function __seedFacility(orgId, values)
    __facilitySeed(orgId, values)
end

function __facilityCount()
    local count = 0
    for _ in pairs(__facilities) do count = count + 1 end
    return count
end

function __stock(orgId)
    return __industryFacilityStock(orgId)
end

--- S1 的种子名是 `__seed`，S4/UI 是 `__seedOrg`：都写数字表。
function __seed(orgId, balance)
    __orgs[orgId] = balance
end

function __seedOrg(orgId, balance)
    __orgs[orgId] = tonumber(balance) or 0
end

function __balance(orgId)
    return __orgs and __orgs[orgId]
end

--- S6 的金库是行表（balance / prestige / cycle_no）。
function __seedTreasury(orgId, balance, prestige)
    __treasuries[orgId] = {
        balance = tonumber(balance) or 0,
        prestige = tonumber(prestige) or 0,
        cycle_no = 0,
    }
end

function __treasury(orgId)
    return __treasuries and __treasuries[orgId]
end

--- 两种金库表示的统一读写：S6 有 `__treasuries`，其余用 `__orgs`。
function __industryTreasuryBalance(orgId)
    if __treasuries then
        local row = __treasuries[orgId]
        return row and row.balance
    end
    return __orgs and __orgs[orgId]
end

function __industryTreasurySetBalance(orgId, balance)
    if __treasuries then
        local row = __treasuries[orgId]
        if row then row.balance = balance end
        return
    end
    __orgs[orgId] = balance
end

function __ledgerCount()
    return #__ledger
end

function __salesCount()
    return #__sales
end

function __salesRows()
    return __sales
end

function __auditCount(action)
    local count = 0
    for _, entry in ipairs(__audits) do
        if entry.action == action then count = count + 1 end
    end
    return count
end

function __auditPayload(action)
    for _, entry in ipairs(__audits) do
        if entry.action == action then return entry.payload end
    end
    return nil
end

function __lastAuditPayload(action)
    local found
    for _, entry in ipairs(__audits) do
        if entry.action == action then found = entry.payload end
    end
    return found
end

function __auditActions()
    local actions = {}
    for index, entry in ipairs(__audits) do actions[index] = entry.action end
    return table.concat(actions, ',')
end

--- 卖单流水合计。orgId 为 nil 时统计全服（读路径对账用），否则只统计该组织。
function __industrySaleQty(orgId, cycleNo, item)
    local total = 0
    for _, row in ipairs(__sales) do
        local sameOrg = orgId == nil or tostring(row.org_id) == tostring(orgId)
        if sameOrg
            and tostring(row.cycle_no) == tostring(cycleNo)
            and tostring(row.item_name) == tostring(item) then
            total = total + (tonumber(row.qty) or 0)
        end
    end
    return total
end

--- 写语句日志。`__writeCount` 只在 S6 存在（dry-run 断言用）。
function __industryLogSql(kind, sql)
    __sqlLog[#__sqlLog + 1] = kind .. ':' .. sql
    if __writeCount and (kind == 'update' or kind == 'insert' or kind == 'delete') then
        __writeCount = __writeCount + 1
    end
end

--- 已执行的 UPDATE 里 SQL 文本包含 needle 的条数（证明正常路径没有多写库）。
function __sqlUpdateCount(needle)
    local count = 0
    for _, entry in ipairs(__sqlLog) do
        if entry:sub(1, 6) == 'update' and entry:find(needle, 1, true) then
            count = count + 1
        end
    end
    return count
end

-- ── SQL 求值：金库 / 流水 ────────────────────────────────────────

--- `UPDATE org_treasury SET balance = balance + ?`（余额守卫由 SQL 文本决定）。
function __industryUpdateTreasury(sql, values)
    if not sql:find('org_treasury', 1, true) then return nil end

    if __failTreasuryUpdate then
        error('probe: forced treasury update failure')
    end

    local delta = tonumber(values[1]) or 0
    local orgId = values[2]
    local guarded = sql:find('balance + ? >= 0', 1, true) ~= nil

    -- 交错点必须在「读余额 / 判断」之后、真正写余额之前。
    if __race and not __raceFired then
        __raceFired = true
        local hook = __race
        __race = nil
        hook()
    end

    local balance = __industryTreasuryBalance(orgId)
    if balance == nil then return { affectedRows = 0 } end
    if guarded and (balance + delta) < 0 then return { affectedRows = 0 } end

    __industryTreasurySetBalance(orgId, balance + delta)
    return { affectedRows = 1 }
end

function __industryReadTreasury(sql, values)
    local orgId = values[1]
    if sql:find('COUNT(*)', 1, true) then
        return { n = __industryTreasuryBalance(orgId) ~= nil and 1 or 0 }
    end
    if __treasuries then
        local row = __treasuries[orgId]
        if not row then return nil end
        return { balance = row.balance, prestige = row.prestige }
    end
    -- S4/S5 的金库是数字表，prestige 另存 `__prestige`（S8 读取路径用）；
    -- 没种过 prestige 的组织按 0 返回，与真库「列有默认值」一致。
    local balance = __orgs and __orgs[orgId]
    if balance == nil then return nil end
    return { balance = balance, prestige = __prestige and __prestige[orgId] or 0 }
end

--- `INSERT IGNORE INTO org_treasury`：已存在 → 0 行；否则建行（插的是余额 0）。
function __industryInsertTreasury(values)
    local orgId = values[1]
    if __treasuries then
        if __treasuries[orgId] then return { affectedRows = 0 } end
        __treasuries[orgId] = {
            balance = 0,
            prestige = tonumber(values[2]) or 0,
            cycle_no = tonumber(values[3]) or 0,
        }
        return { affectedRows = 1 }
    end
    if __orgs[orgId] ~= nil then return { affectedRows = 0 } end
    __orgs[orgId] = 0
    return { affectedRows = 1 }
end

--- 流水 ref 的位置随语句形状变化：
---   有 actor 七参 → values[6]；无 actor 六参 → values[5]；
---   INSERT IGNORE（org/delta/reason/ref 四参）→ values[4]。
local function ledgerRef(sql, values)
    if sql:find('INSERT IGNORE INTO org_ledger', 1, true) then return tostring(values[4]) end
    return tostring(#values == 7 and values[6] or values[5])
end

function __industryReadLedger(values)
    local key = tostring(values[1]) .. '\0' .. tostring(values[2])
    local refs = __ledgerRefs or __refs
    local id = refs[key]
    if id == nil then return nil end
    if id == true then id = 1 end
    return { id = id }
end

--- `INSERT [IGNORE] INTO org_ledger`。唯一键是真库事实：`__uniqueRef` 由迁移文件
--- 决定（S1），其余探针默认唯一；IGNORE 撞键返回 0 行而不是抛错。
function __industryInsertLedger(sql, values)
    local ignore = sql:find('INSERT IGNORE INTO org_ledger', 1, true) ~= nil
    local orgId = tostring(values[1])
    local ref = ledgerRef(sql, values)
    local key = orgId .. '\0' .. ref
    local refs = __ledgerRefs or __refs

    local delta, balanceAfter, reason
    if ignore then
        if refs[key] then return { affectedRows = 0 } end
        delta, balanceAfter, reason = values[2], 0, values[3]
    else
        if __opaqueInsertError then
            -- 模拟「驱动把 SQL 错误当字符串回包」：db.lua 会归一化成 db_error，
            -- 唯一键冲突的原文因此丢失。
            return 'probe: opaque driver error'
        end
        local unique = __uniqueRef
        if unique == nil then unique = true end
        if unique and refs[key] then
            error("Duplicate entry '" .. ref .. "' for key 'org_ledger.uniq_org_ref'")
        end
        if __failLedgerInsert then error('probe: forced ledger insert failure') end
        delta, balanceAfter, reason = values[2], values[3], values[4]
    end

    __nextLedgerId = (__nextLedgerId or 0) + 1
    refs[key] = __nextLedgerId
    __ledger[#__ledger + 1] = __industryLedgerRow(
        __nextLedgerId, orgId, tonumber(delta), tonumber(balanceAfter), reason, ref)
    return { insertId = __nextLedgerId }
end

function __industryInsertAudit(values)
    __audits[#__audits + 1] = __industryAuditEntry(values)
    return { insertId = 1 }
end

-- ── SQL 求值：配额 / 卖单 ────────────────────────────────────────

--- `UPDATE industry_demand ...`：配额增/减、对账回填、改总额。
--- 本组织 50% 上限只在 SQL 真的带 `SUM(s.qty)` 子查询时求值。
function __industryUpdateDemand(sql, values)
    if sql:find('UPDATE industry_demand SET quota_used = quota_used + ?', 1, true) then
        local qty = tonumber(values[1]) or 0
        local row = __demands[__industryDemandKey(values[2], values[3], values[4])]
        if not row then return { affectedRows = 0 } end
        if row.quota_used + qty > row.quota_total then return { affectedRows = 0 } end

        if sql:find('SUM(s.qty)', 1, true) then
            local used = __industrySaleQty(values[6], values[7], values[8]) + qty
            local ratio = tonumber(values[10]) or 0.5
            local cap = math.floor(row.quota_total * ratio + 1e-9)
            if used > cap then return { affectedRows = 0 } end
        end

        row.quota_used = row.quota_used + qty
        return { affectedRows = 1 }
    end

    if sql:find('UPDATE industry_demand SET quota_used = quota_used - ?', 1, true) then
        local qty = tonumber(values[1]) or 0
        local row = __demands[__industryDemandKey(values[2], values[3], values[4])]
        if not row or row.quota_used < qty then return { affectedRows = 0 } end
        row.quota_used = row.quota_used - qty
        return { affectedRows = 1 }
    end

    -- 配额对账：只有计数器真的落后于流水时才条件回填（quota_used < ? 是幂等守卫）。
    if sql:find('UPDATE industry_demand SET quota_used = ?', 1, true) then
        if not sql:find('quota_used < ?', 1, true) then
            error('probe: 对账 UPDATE 缺 quota_used < ? 幂等守卫')
        end
        local flow = tonumber(values[1]) or 0
        local row = __demands[__industryDemandKey(values[2], values[3], values[4])]
        local guard = tonumber(values[5]) or 0
        if not row or row.quota_used >= guard then return { affectedRows = 0 } end
        row.quota_used = flow
        return { affectedRows = 1 }
    end

    if sql:find('UPDATE industry_demand SET quota_total = ?', 1, true) then
        local row = __demands[__industryDemandKey(values[2], values[3], values[4])]
        if not row or row.quota_used ~= 0 then return { affectedRows = 0 } end
        row.quota_total = tonumber(values[1]) or 0
        return { affectedRows = 1 }
    end

    return nil
end

function __industryReadDemand(sql, values)
    if sql:find('COUNT(*)', 1, true) then
        local count = 0
        for _, row in pairs(__demands) do
            if tostring(row.cycle_no) == tostring(values[1]) then count = count + 1 end
        end
        return { n = count }
    end
    local row = __demands[__industryDemandKey(values[1], values[2], values[3])]
    return row and { quota_total = row.quota_total, quota_used = row.quota_used } or nil
end

function __industryInsertDemand(values)
    local key = __industryDemandKey(values[1], values[2], values[3])
    if __demands[key] then return { affectedRows = 0 } end
    __demands[key] = __industryDemandRow(values[1], values[2], values[3], values[4], 0)
    return { affectedRows = 1 }
end

function __industryReadSales(sql, values)
    if sql:find('COUNT(*)', 1, true) then
        local count = 0
        for _, row in ipairs(__sales) do
            if tostring(row.cycle_no) == tostring(values[1]) then count = count + 1 end
        end
        return { n = count }
    end

    if sql:find('SUM(revenue)', 1, true) then
        local total = 0
        for _, row in ipairs(__sales) do
            if tostring(row.org_id) == tostring(values[1])
                and tostring(row.cycle_no) == tostring(values[2]) then
                total = total + (tonumber(row.revenue) or 0)
            end
        end
        return { total = total }
    end

    if sql:find('SUM(qty)', 1, true) then
        -- 带 org_id 的是单组织累计；不带的是全服流水（读路径对账）。
        if sql:find('org_id = ?', 1, true) then
            return { used = __industrySaleQty(values[1], values[2], values[3]) }
        end
        return { used = __industrySaleQty(nil, values[1], values[2]) }
    end

    for _, row in ipairs(__sales) do
        if tostring(row.org_id) == tostring(values[1]) and row.ref == values[2] then
            return { id = row.id }
        end
    end
    return nil
end

--- `INSERT INTO industry_sales`。S4 的 `__saleRefs` 模拟 UNIQUE(org_id, ref)；
--- S6 不维护这张映射，重复键不会被拦（预置卖单本来也不走 INSERT）。
function __industryInsertSales(values)
    local orgId = tostring(values[1])
    local ref = tostring(values[7])
    local key = orgId .. '\0' .. ref
    if __saleRefs and __saleRefs[key] then
        error("Duplicate entry '" .. ref .. "' for key 'industry_sales.uniq_org_ref'")
    end

    __nextSaleId = (__nextSaleId or 0) + 1
    local row = __industrySaleRow({
        id = __nextSaleId,
        org_id = orgId,
        cycle_no = values[2],
        item_name = values[3],
        qty = values[4],
        unit_price = values[5],
        revenue = values[6],
        ref = ref,
    })
    __sales[#__sales + 1] = row
    if __saleRefs then __saleRefs[key] = row end
    return { insertId = __nextSaleId }
end

--- `DELETE FROM industry_sales`：按卖单 id（S4 回滚）或按 (org, cycle)（S6 结算）。
function __industryDeleteSales(sql, values)
    if not sql:find('DELETE FROM industry_sales', 1, true) then return nil end

    if sql:find('WHERE id = ?', 1, true) then
        local saleId = tonumber(values[1])
        local orgId = tostring(values[2])
        for index, row in ipairs(__sales) do
            if tonumber(row.id) == saleId and tostring(row.org_id) == orgId then
                table.remove(__sales, index)
                if __saleRefs then __saleRefs[orgId .. '\0' .. row.ref] = nil end
                return { affectedRows = 1 }
            end
        end
        return { affectedRows = 0 }
    end

    local removed = 0
    for index = #__sales, 1, -1 do
        local row = __sales[index]
        if tostring(row.org_id) == tostring(values[1])
            and tostring(row.cycle_no) == tostring(values[2]) then
            table.remove(__sales, index)
            removed = removed + 1
        end
    end
    return { affectedRows = removed }
end

-- ── SQL 求值：设施 ───────────────────────────────────────────────

--- 生产结算的 CAS：stock / produced_units / last_tick_at 三个条件全在 WHERE 里。
function __industryApplyFacilityProduction(values)
    local produced = tonumber(values[1]) or 0
    local newLast = tonumber(values[3]) or 0
    local row = __facilities[values[4]]
    if not row then return { affectedRows = 0 } end
    if tonumber(row.last_tick_epoch) ~= tonumber(values[5]) then
        return { affectedRows = 0 }
    end
    if tonumber(row.stock) ~= tonumber(values[6]) then return { affectedRows = 0 } end

    row.stock = tonumber(row.stock) + produced
    row.produced_units = tonumber(row.produced_units) + produced
    row.last_tick_epoch = newLast
    return { affectedRows = 1 }
end

--- `UPDATE industry_facility SET stock = stock -/+ ?` 与生产 CAS。
--- 扣库存必须带 `stock >= ?` 守卫；少掉就变成无守卫扣减，用例必须红。
function __industryUpdateFacility(sql, values)
    if sql:find('UPDATE industry_facility SET stock = stock - ?', 1, true) then
        if not sql:find('stock >= ?', 1, true) then
            error('probe: 扣库存 UPDATE 缺 stock >= ? 守卫')
        end
        local qty = tonumber(values[1]) or 0
        local orgId = values[2]

        -- 在第一次扣库存落库前插入另一个同组织请求，制造 await 交错。
        if __raceBeforeStockUpdate and not __raceFired then
            __raceFired = true
            local hook = __raceBeforeStockUpdate
            __raceBeforeStockUpdate = nil
            hook()
        end

        local stock = __industryFacilityStock(orgId)
        if stock == nil or stock < qty then return { affectedRows = 0 } end
        __industryFacilitySetStock(orgId, stock - qty)
        return { affectedRows = 1 }
    end

    if sql:find('UPDATE industry_facility', 1, true)
        and sql:find('produced_units', 1, true) then
        return __industryApplyFacilityProduction(values)
    end

    if sql:find('UPDATE industry_facility SET stock = stock + ?', 1, true) then
        local qty = tonumber(values[1]) or 0
        local orgId = values[2]
        local stock = __industryFacilityStock(orgId)
        if stock == nil then return { affectedRows = 0 } end
        __industryFacilitySetStock(orgId, stock + qty)
        return { affectedRows = 1 }
    end

    return nil
end

--- `SELECT ... FROM industry_facility`。
--- mode = nil / 'basic'：S4 只读库存；'cycle'：S6 的 COUNT / 整行 / 产量投影；
--- 'rich'：S2 的整行读取。
function __industryReadFacility(sql, values, mode)
    local orgId = values[1]
    if sql:find('COUNT(*)', 1, true) then
        return { n = __facilities[orgId] and 1 or 0 }
    end

    local row = __facilities[orgId]
    if not row then return nil end

    if mode == 'rich' then return __industryCopy(row) end
    if mode == 'cycle' then
        if sql:find('UNIX_TIMESTAMP(last_tick_at)', 1, true) then
            return __industryCopy(row)
        end
        if sql:find('produced_units', 1, true) and not sql:find('facility_type', 1, true) then
            return { produced_units = row.produced_units }
        end
        return { stock = row.stock }
    end
    return { stock = __industryFacilityStock(orgId) }
end

--- `DELETE FROM industry_facility WHERE org_id = ?`（结算清空设施与库存）。
function __industryDeleteFacility(sql, values)
    if not sql:find('DELETE FROM industry_facility', 1, true) then return nil end
    local orgId = values[1]
    if not __facilities[orgId] then return { affectedRows = 0 } end
    __facilities[orgId] = nil
    return { affectedRows = 1 }
end

--- `DELETE FROM industry_demand WHERE cycle_no = ?`（结算清空本周期配额行）。
function __industryDeleteDemand(sql, values)
    if not sql:find('DELETE FROM industry_demand', 1, true) then return nil end
    local removed = 0
    for key, row in pairs(__demands) do
        if tostring(row.cycle_no) == tostring(values[1]) then
            __demands[key] = nil
            removed = removed + 1
        end
    end
    return { affectedRows = removed }
end

--- `INSERT INTO industry_facility`：撞主键抛 Duplicate（Db.Insert 归一成 db_error）。
function __industryInsertFacility(sql, values)
    if not sql:find('INSERT INTO industry_facility', 1, true) then return nil end

    local orgId = values[1]
    if __facilities[orgId] then
        error("Duplicate entry '" .. tostring(orgId) .. "' for key 'PRIMARY'")
    end
    if __failFacilityInsert then error('probe: forced facility insert failure') end

    -- 没有 AUTO_INCREMENT：Db.Insert 会归一成 no_insert_id，这不是错误。
    __facilities[orgId] = __industryFacilityRow(orgId, { facility_type = values[2] })
    return { affectedRows = 1 }
end

-- ── 组合分发：探针只处理自己特有的表，其余交给这里 ──────────────

---@param options table|nil { facility = 'basic'|'cycle'|'rich' }
function __industrySingle(sql, values, options)
    options = options or {}
    if sql:find('FROM industry_facility', 1, true) then
        return __industryReadFacility(sql, values, options.facility)
    end
    if sql:find('FROM industry_demand', 1, true) then
        return __industryReadDemand(sql, values)
    end
    if sql:find('FROM industry_sales', 1, true) then
        return __industryReadSales(sql, values)
    end
    if sql:find('FROM org_treasury', 1, true) then
        return __industryReadTreasury(sql, values)
    end
    if sql:find('FROM org_ledger', 1, true) then
        return __industryReadLedger(values)
    end
    return nil
end

function __industryInsert(sql, values)
    if sql:find('INSERT IGNORE INTO org_treasury', 1, true) then
        return __industryInsertTreasury(values)
    end
    if sql:find('INSERT IGNORE INTO org_ledger', 1, true)
        or sql:find('INSERT INTO org_ledger', 1, true) then
        return __industryInsertLedger(sql, values)
    end
    if sql:find('INSERT IGNORE INTO industry_demand', 1, true) then
        return __industryInsertDemand(values)
    end
    if sql:find('INSERT INTO industry_sales', 1, true) then
        return __industryInsertSales(values)
    end
    if sql:find('INSERT INTO industry_audit', 1, true) then
        return __industryInsertAudit(values)
    end
    if sql:find('INSERT INTO industry_facility', 1, true) then
        return __industryInsertFacility(sql, values)
    end
    return nil
end

function __industryUpdate(sql, values)
    local result = __industryUpdateFacility(sql, values)
    if result then return result end
    result = __industryDeleteFacility(sql, values)
    if result then return result end
    result = __industryDeleteDemand(sql, values)
    if result then return result end
    result = __industryDeleteSales(sql, values)
    if result then return result end
    result = __industryUpdateDemand(sql, values)
    if result then return result end
    return __industryUpdateTreasury(sql, values)
end

--- MySQL.scalar / execute 的固定桩（所有探针一致）。
function __industryMysqlTail()
    MySQL.scalar = { await = function() return 0 end }
    MySQL.execute = { await = function() return 1 end }
end
