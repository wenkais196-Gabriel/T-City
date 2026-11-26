-- fixtures/industry_ui_probe.lua — S5 快照测试的假 DB 扩展。
--
-- 必须加载在 industry_sales_probe.lua **之后**：S5 复用 S4 的假 DB（treasury /
-- demand / sales / audit / 事件都已实现），这里只补三件事：
--
--   1. `__facilityRows`：S4 的 fixture 只存 `stock` 数字，`Facility.Get` 需要整行
--      （facility_type / level / workstations / produced_units）；
--   2. 把 `FROM industry_facility` 的 single 查询改成返回整行，并让 stock 与
--      `__facilities` 保持同步（SettleSale 扣库存只改 `__facilities`）；
--   3. `UPDATE ... SET workstations = workstations + 1`（S5 雇工位用例）。

__facilityRows = {}

local __baseUiReset = __reset
function __reset()
    __baseUiReset()
    __facilityRows = {}
end

---@param orgId string
---@param stock number
---@param opts table|nil { type, level, workstations, produced_units }
function __seedFacilityRow(orgId, stock, opts)
    opts = opts or {}
    __facilities[orgId] = tonumber(stock) or 0
    __facilityRows[orgId] = {
        org_id = orgId,
        facility_type = opts.type or 'mine',
        level = opts.level or 1,
        workstations = opts.workstations or 0,
        recipe_id = opts.recipe_id,
        stock = tonumber(stock) or 0,
        last_tick_at = opts.last_tick_at or 0,
        created_at = opts.created_at or 0,
        produced_units = opts.produced_units or 0,
    }
end

--- 快照身份字段的统一回显（多个用例原本各抄一遍）。
function __emitSnapshotIdentity(snap)
    __emit('ORG', tostring(snap and snap.orgLabel))
    __emit('GRADE', tostring(snap and snap.gradeName))
    __emit('ISBOSS', tostring(snap and snap.isBoss))
    __emit('BAL', tostring(snap and snap.balance))
end

--- 「这次到底写没写库」的统一回显（销售笔数 / 库存 / 金库 / 工位）。
function __emitWriteState()
    __emit('SALES', tostring(__salesCount()))
    __emit('STOCK', tostring(__stock('mining_co')))
    __emit('BAL', tostring(__balance('mining_co')))
    __emit('WS', tostring(__facilityRows['mining_co'].workstations))
end

--- 写操作类用例的通用种子（余额 0、库存 10、工位 3、配额 20/0）。
function __seedBasic(opts)
    opts = opts or {}
    __reset()
    __seedOrg('mining_co', opts.balance or 0)
    __seedFacilityRow('mining_co', opts.stock or 10, { workstations = opts.workstations or 3 })
    __seedDemand('iron_ore', opts.total or 20, opts.used or 0)
end

--- 模拟「本周期已经卖过 qty 件」：orgUsed 的分子来自 industry_sales。
function __seedSale(orgId, item, qty)
    local id = 1000 + #__sales + 1
    local row = __industrySaleRow({
        id = id,
        org_id = orgId,
        cycle_no = 0,
        item_name = item,
        qty = tonumber(qty) or 0,
        unit_price = 50,
        revenue = 0,
        ref = 'seed:' .. tostring(id),
    })
    __sales[#__sales + 1] = row
    __saleRefs[tostring(orgId) .. '\0' .. row.ref] = row
end

local __baseUiSingle = MySQL.single.await
MySQL.single = { await = function(sql, values)
    if sql:find('FROM industry_facility', 1, true) then
        local orgId = values[1]
        local row = __facilityRows[orgId]
        if not row then return nil end
        local result = __industryCopy(row)
        result.stock = __facilities[orgId] or 0
        return result
    end
    return __baseUiSingle(sql, values)
end }

local __baseUiUpdate = MySQL.update.await
MySQL.update = { await = function(sql, values)
    if sql:find('UPDATE industry_facility SET workstations', 1, true) then
        local orgId = values[1]
        local current = tonumber(values[2])
        local cap = tonumber(values[3])
        local row = __facilityRows[orgId]
        if not row or tonumber(row.workstations) ~= current then
            return { affectedRows = 0 }
        end
        if cap and current >= cap then return { affectedRows = 0 } end
        row.workstations = current + 1
        return { affectedRows = 1 }
    end
    return __baseUiUpdate(sql, values)
end }
