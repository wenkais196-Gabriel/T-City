-- fixtures/industry_sales_probe.lua — S4 销售 / 配额的离线假数据库。
--
-- 用法（见 test_industry_sales.py）：
--   fixture 作为 stubs → core-framework/server/db.lua → config* → treasury.lua
--   → audit.lua → sale.lua → body
--
-- 只实现被测路径会发出的语句。关键判据写在 SQL 文本上：
--
--   * 扣库存必须是 `SET stock = stock - ? ... AND stock >= ?`；少掉守卫就变成
--     无守卫扣减，库存不足用例必须红。
--   * 扣配额必须是 `quota_used + ? <= quota_total`，并且带
--     `SUM(s.qty) ... FLOOR(quota_total * ?)` 的本组织 50% 子查询。探针按
--     SQL 里是否出现 `SUM(s.qty)` 决定要不要执行「本组织累计」判据 ——
--     反向注入删掉这段条件时，第二家组织会真的卖出去，用例必须红。
--   * industry_sales 的 UNIQUE(org_id, ref) 由 `__saleRefs` 模拟。
--   * `__failTreasuryUpdate` 让 Treasury.Deposit 的第一步 UPDATE 失败，
--     用来验证「Deposit 失败 → 库存与配额都退回」。
--
-- 事件：`TriggerEvent('industry:sale', ...)` 被记进 __saleEvents（已入账才发）。

__orgs = {}
__ledger = {}
__ledgerRefs = {}
__sales = {}
__saleRefs = {}
__nextSaleId = 0
__nextLedgerId = 0
__demands = {}
__facilities = {}
__audits = {}
__saleEvents = {}
__sqlLog = {}
__convars = {}
__globalMultiplier = 1.0
__activityHeat = 1.0
__failTreasuryUpdate = false
__raceBeforeStockUpdate = nil
__raceFired = false

local function copy(row)
    local out = {}
    for key, value in pairs(row) do out[key] = value end
    return out
end

local function demandKey(cycleNo, phase, item)
    return tostring(cycleNo) .. '\0' .. tostring(phase) .. '\0' .. tostring(item)
end

function __reset()
    __orgs = {}
    __ledger = {}
    __ledgerRefs = {}
    __sales = {}
    __saleRefs = {}
    __nextSaleId = 0
    __nextLedgerId = 0
    __demands = {}
    __facilities = {}
    __audits = {}
    __saleEvents = {}
    __sqlLog = {}
    __globalMultiplier = 1.0
    __activityHeat = 1.0
    __failTreasuryUpdate = false
    __raceBeforeStockUpdate = nil
    __raceFired = false
end

function __seedOrg(orgId, balance)
    __orgs[orgId] = tonumber(balance) or 0
end

function __seedFacility(orgId, stock)
    __facilities[orgId] = tonumber(stock) or 0
end

function __seedDemand(item, total, used, cycleNo, phase)
    local cycle = cycleNo or 0
    local stage = phase or 'static'
    __demands[demandKey(cycle, stage, item)] = {
        cycle_no = cycle,
        phase = stage,
        item_name = item,
        quota_total = tonumber(total) or 0,
        quota_used = tonumber(used) or 0,
    }
end

function __demandRow(item, cycleNo, phase)
    local row = __demands[demandKey(cycleNo or 0, phase or 'static', item)]
    if not row then return nil end
    return copy(row)
end

function __stock(orgId)
    return __facilities[orgId]
end

function __salesRows()
    return __sales
end

function __salesCount()
    return #__sales
end

function __balance(orgId)
    return __orgs[orgId]
end

function __ledgerCount()
    return #__ledger
end

function __auditActions()
    local actions = {}
    for index, entry in ipairs(__audits) do actions[index] = entry.action end
    return table.concat(actions, ',')
end

function __saleEventCount()
    return #__saleEvents
end

function __lastSaleEvent()
    return __saleEvents[#__saleEvents]
end

function __emit(key, value)
    io.write(tostring(key) .. '|' .. tostring(value) .. string.char(10))
end

function TriggerEvent(name, ...)
    if name ~= 'industry:sale' then return end
    __saleEvents[#__saleEvents + 1] = { ... }
end

exports = setmetatable({}, {
    __index = function(_, resource)
        if resource ~= 'core_economy' then return nil end
        return {
            GetGlobalMultiplier = function() return __globalMultiplier end,
            GetActivityHeat = function() return __activityHeat end,
        }
    end,
})

function GetConvar(name, default)
    local value = __convars[name]
    if value == nil then return default end
    return tostring(value)
end

local function logSql(kind, sql)
    __sqlLog[#__sqlLog + 1] = kind .. ':' .. sql
end

local function orgSaleQty(orgId, cycleNo, item)
    local total = 0
    for _, row in ipairs(__sales) do
        if tostring(row.org_id) == tostring(orgId)
            and tostring(row.cycle_no) == tostring(cycleNo)
            and tostring(row.item_name) == tostring(item) then
            total = total + (tonumber(row.qty) or 0)
        end
    end
    return total
end

MySQL = {}

MySQL.update = { await = function(sql, values)
    logSql('update', sql)

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

        local stock = __facilities[orgId]
        if stock == nil or stock < qty then return { affectedRows = 0 } end
        __facilities[orgId] = stock - qty
        return { affectedRows = 1 }
    end

    if sql:find('UPDATE industry_facility SET stock = stock + ?', 1, true) then
        local qty = tonumber(values[1]) or 0
        local orgId = values[2]
        if __facilities[orgId] == nil then return { affectedRows = 0 } end
        __facilities[orgId] = __facilities[orgId] + qty
        return { affectedRows = 1 }
    end

    if sql:find('UPDATE industry_demand SET quota_used = quota_used + ?', 1, true) then
        local qty = tonumber(values[1]) or 0
        local cycleNo = values[2]
        local phase = values[3]
        local item = values[4]
        local row = __demands[demandKey(cycleNo, phase, item)]
        if not row then return { affectedRows = 0 } end

        if row.quota_used + qty > row.quota_total then return { affectedRows = 0 } end

        -- 只有 SQL 里真的带了「本组织累计」子查询才执行这条判据。
        if sql:find('SUM(s.qty)', 1, true) then
            local orgId = values[6]
            local saleCycle = values[7]
            local saleItem = values[8]
            local ratio = tonumber(values[10]) or 0.5
            local cap = math.floor(row.quota_total * ratio + 1e-9)
            if orgSaleQty(orgId, saleCycle, saleItem) + qty > cap then
                return { affectedRows = 0 }
            end
        end

        row.quota_used = row.quota_used + qty
        return { affectedRows = 1 }
    end

    if sql:find('UPDATE industry_demand SET quota_used = quota_used - ?', 1, true) then
        local qty = tonumber(values[1]) or 0
        local cycleNo = values[2]
        local phase = values[3]
        local item = values[4]
        local row = __demands[demandKey(cycleNo, phase, item)]
        if not row or row.quota_used < qty then return { affectedRows = 0 } end
        row.quota_used = row.quota_used - qty
        return { affectedRows = 1 }
    end

    if sql:find('UPDATE industry_demand SET quota_total = ?', 1, true) then
        local quota = tonumber(values[1]) or 0
        local cycleNo = values[2]
        local phase = values[3]
        local item = values[4]
        local row = __demands[demandKey(cycleNo, phase, item)]
        if not row or row.quota_used ~= 0 then return { affectedRows = 0 } end
        row.quota_total = quota
        return { affectedRows = 1 }
    end

    if sql:find('UPDATE org_treasury', 1, true) then
        if __failTreasuryUpdate then
            error('probe: forced treasury update failure')
        end
        local delta = tonumber(values[1]) or 0
        local orgId = values[2]
        local guarded = sql:find('balance + ? >= 0', 1, true) ~= nil
        if __orgs[orgId] == nil then return { affectedRows = 0 } end
        if guarded and (__orgs[orgId] + delta) < 0 then return { affectedRows = 0 } end
        __orgs[orgId] = __orgs[orgId] + delta
        return { affectedRows = 1 }
    end

    if sql:find('DELETE FROM industry_sales', 1, true) then
        local saleId = tonumber(values[1])
        local orgId = tostring(values[2])
        for index, row in ipairs(__sales) do
            if tonumber(row.id) == saleId and tostring(row.org_id) == orgId then
                table.remove(__sales, index)
                __saleRefs[orgId .. '\0' .. row.ref] = nil
                return { affectedRows = 1 }
            end
        end
        return { affectedRows = 0 }
    end

    return { affectedRows = 0 }
end }

MySQL.single = { await = function(sql, values)
    logSql('single', sql)

    if sql:find('FROM industry_demand', 1, true) then
        local row = __demands[demandKey(values[1], values[2], values[3])]
        if not row then return nil end
        return { quota_total = row.quota_total, quota_used = row.quota_used }
    end

    if sql:find('FROM industry_facility', 1, true) then
        local stock = __facilities[values[1]]
        if stock == nil then return nil end
        return { stock = stock }
    end

    if sql:find('FROM industry_sales', 1, true) then
        if sql:find('SUM(qty)', 1, true) then
            return { used = orgSaleQty(values[1], values[2], values[3]) }
        end
        local key = tostring(values[1]) .. '\0' .. tostring(values[2])
        local sale = __saleRefs[key]
        if not sale then return nil end
        return { id = sale.id }
    end

    if sql:find('FROM org_treasury', 1, true) then
        local orgId = values[1]
        if __orgs[orgId] == nil then return nil end
        return { balance = __orgs[orgId] }
    end

    if sql:find('FROM org_ledger', 1, true) then
        local key = tostring(values[1]) .. '\0' .. tostring(values[2])
        if __ledgerRefs[key] then return { id = __ledgerRefs[key] } end
        return nil
    end

    return nil
end }

MySQL.query = { await = function(sql)
    logSql('query', sql)
    return {}
end }

MySQL.insert = { await = function(sql, values)
    logSql('insert', sql)

    if sql:find('INSERT IGNORE INTO industry_demand', 1, true) then
        local cycleNo = values[1]
        local phase = values[2]
        local item = values[3]
        local key = demandKey(cycleNo, phase, item)
        if __demands[key] then return { affectedRows = 0 } end
        __demands[key] = {
            cycle_no = cycleNo,
            phase = phase,
            item_name = item,
            quota_total = tonumber(values[4]) or 0,
            quota_used = 0,
        }
        return { affectedRows = 1 }
    end

    if sql:find('INSERT INTO industry_sales', 1, true) then
        local orgId = tostring(values[1])
        local ref = tostring(values[7])
        local key = orgId .. '\0' .. ref
        if __saleRefs[key] then
            error("Duplicate entry '" .. ref .. "' for key 'industry_sales.uniq_org_ref'")
        end
        __nextSaleId = __nextSaleId + 1
        local sale = {
            id = __nextSaleId,
            org_id = orgId,
            cycle_no = values[2],
            item_name = values[3],
            qty = tonumber(values[4]),
            unit_price = tonumber(values[5]),
            revenue = tonumber(values[6]),
            ref = ref,
        }
        __sales[#__sales + 1] = sale
        __saleRefs[key] = sale
        return { insertId = __nextSaleId }
    end

    if sql:find('INSERT INTO org_ledger', 1, true) then
        local orgId = tostring(values[1])
        local ref = tostring(#values == 7 and values[6] or values[5])
        local key = orgId .. '\0' .. ref
        if __ledgerRefs[key] then
            error("Duplicate entry '" .. ref .. "' for key 'org_ledger.uniq_org_ref'")
        end
        __nextLedgerId = __nextLedgerId + 1
        __ledgerRefs[key] = __nextLedgerId
        __ledger[#__ledger + 1] = {
            id = __nextLedgerId,
            org_id = orgId,
            delta = values[2],
            balance_after = values[3],
            reason = values[4],
            ref = ref,
        }
        return { insertId = __nextLedgerId }
    end

    if sql:find('INSERT INTO industry_audit', 1, true) then
        if #values == 4 then
            __audits[#__audits + 1] = {
                org_id = values[1], actor_cid = values[2], action = values[3], payload = values[4],
            }
        else
            __audits[#__audits + 1] = {
                org_id = values[1], actor_cid = nil, action = values[2], payload = values[3],
            }
        end
        return { insertId = 1 }
    end

    if sql:find('INSERT IGNORE INTO org_treasury', 1, true) then
        local orgId = values[1]
        if __orgs[orgId] == nil then
            __orgs[orgId] = 0
            return { affectedRows = 1 }
        end
        return { affectedRows = 0 }
    end

    return { insertId = 0 }
end }

MySQL.scalar = { await = function() return 0 end }
MySQL.execute = { await = function() return 1 end }
