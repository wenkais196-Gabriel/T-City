-- fixtures/industry_cycle_probe.lua — S6/S7 的离线假数据库（真跑 Lua，只替换 MySQL）。
--
-- 覆盖 cycle.lua / settlement.lua / announce.lua / commands_cycle.lua 以及
-- sale.lua / facility.lua / production.lua 的**读点**：
--
--   industry_state          单行：cycle_no / phase / epoch 边界 / 公告水位
--   industry_cycle_results  UNIQUE(org_id, cycle_no) 由 `__results` 模拟
--   industry_facility / industry_sales / industry_demand / org_treasury / org_ledger
--
-- 关键约束：
--   * 任何 SQL 提到 `players` 都会直接 error —— 结算触碰个人层时用例必须大声失败。
--   * `__sqlWrites` 统计真正的写语句；dry-run 用例断言它为 0。
--   * `__raceBeforeStateUpdate` 在推进 UPDATE 落库前触发一次，用来制造
--     「读到的旧阶段 + 别人先改了」的交错（affectedRows = 0 是唯一推进许可）。
--   * `__failNextSettlementUpdate` / `__failNextAppliedUpdate` 用来模拟结算中途崩溃。

__convars = {}
__state = nil
__facilities = {}
__sales = {}
__demands = {}
__treasuries = {}
__ledger = {}
__ledgerRefs = {}
__results = {}
__audits = {}
__players = {}
__bulletins = {}
__saleEvents = {}
__sqlLog = {}
__writeCount = 0
__nextSaleId = 0
__nextLedgerId = 0
__nextResultId = 0
__raceBeforeStateUpdate = nil
__raceFired = false
__failNextSettlementUpdate = false
__failNextAppliedUpdate = false
__failBulletins = false
__personalTouched = false
__globalMultiplier = 1.0
__activityHeat = 1.0
__handlers = {}
__native = {}

local function copy(row)
    local out = {}
    for key, value in pairs(row) do out[key] = value end
    return out
end

local function demandKey(cycleNo, phase, item)
    return tostring(cycleNo) .. '\0' .. tostring(phase) .. '\0' .. tostring(item)
end

local function resultKey(orgId, cycleNo)
    return tostring(orgId) .. '\0' .. tostring(cycleNo)
end

local function logSql(kind, sql)
    __sqlLog[#__sqlLog + 1] = kind .. ':' .. sql
    if kind == 'update' or kind == 'insert' or kind == 'delete' then
        __writeCount = __writeCount + 1
    end
end

local function guardPersonal(sql)
    if sql:find('%f[%w]players%f[%W]') then
        -- 只打标记不抛错：db.lua 会 pcall 掉驱动错误，单靠 error 会被静默。
        -- 用例必须同时断言标记为 0 —— 这样"尝试写个人层但失败了"也会红。
        __personalTouched = true
        error('probe: settlement touched the personal layer: ' .. sql)
    end
end

function __reset()
    __state = nil
    __facilities = {}
    __sales = {}
    __demands = {}
    __treasuries = {}
    __ledger = {}
    __ledgerRefs = {}
    __results = {}
    __audits = {}
    __players = {}
    __bulletins = {}
    __saleEvents = {}
    __sqlLog = {}
    __writeCount = 0
    __nextSaleId = 0
    __nextLedgerId = 0
    __nextResultId = 0
    __raceBeforeStateUpdate = nil
    __raceFired = false
    __failNextSettlementUpdate = false
    __failNextAppliedUpdate = false
    __failBulletins = false
    __personalTouched = false
    __globalMultiplier = 1.0
    __activityHeat = 1.0
    __handlers = {}
    __native = {}
end

function __seedState(values)
    values = values or {}
    __state = {
        cycle_no = tonumber(values.cycle_no) or 1,
        phase = values.phase or 'expansion',
        started_epoch = tonumber(values.started_epoch) or 0,
        ends_epoch = tonumber(values.ends_epoch) or 0,
        warning_epoch = values.warning_epoch,
        settled_cycle_no = tonumber(values.settled_cycle_no) or 0,
        result_announced_cycle = tonumber(values.result_announced_cycle) or 0,
    }
end

function __stateRow()
    return __state and copy(__state) or nil
end

function __seedFacility(orgId, values)
    values = values or {}
    __facilities[orgId] = {
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

function __facility(orgId)
    return __facilities[orgId]
end

function __facilityCount()
    local count = 0
    for _ in pairs(__facilities) do count = count + 1 end
    return count
end

function __seedTreasury(orgId, balance, prestige)
    __treasuries[orgId] = {
        balance = tonumber(balance) or 0,
        prestige = tonumber(prestige) or 0,
        cycle_no = 0,
    }
end

function __treasury(orgId)
    return __treasuries[orgId]
end

function __seedSale(orgId, cycleNo, item, qty, unitPrice, revenue)
    __nextSaleId = __nextSaleId + 1
    __sales[#__sales + 1] = {
        id = __nextSaleId,
        org_id = orgId,
        cycle_no = cycleNo,
        item_name = item or 'iron_ore',
        qty = qty,
        unit_price = unitPrice or 50,
        revenue = revenue or 0,
        ref = 'seed-sale-' .. __nextSaleId,
    }
end

function __salesCount()
    return #__sales
end

function __salesFor(orgId, cycleNo)
    local count = 0
    for _, row in ipairs(__sales) do
        if tostring(row.org_id) == tostring(orgId)
            and tostring(row.cycle_no) == tostring(cycleNo) then
            count = count + 1
        end
    end
    return count
end

function __seedDemand(cycleNo, phase, item, total, used)
    __demands[demandKey(cycleNo, phase, item)] = {
        cycle_no = cycleNo,
        phase = phase,
        item_name = item,
        quota_total = tonumber(total) or 0,
        quota_used = tonumber(used) or 0,
    }
end

function __demandRow(cycleNo, phase, item)
    local row = __demands[demandKey(cycleNo, phase, item)]
    return row and copy(row) or nil
end

function __demandCount(cycleNo)
    local count = 0
    for _, row in pairs(__demands) do
        if tostring(row.cycle_no) == tostring(cycleNo) then count = count + 1 end
    end
    return count
end

function __seedPlayers(rows)
    __players = rows or {}
end

--- 个人层字节级指纹：按键排序后的 canonical 串做多项式哈希。
--- 结算前后必须完全一致（测试同时断言 checksum 与"SQL 不得提到 players"）。
local function serialize(value)
    if type(value) ~= 'table' then return type(value) .. ':' .. tostring(value) end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = tostring(key) end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
        local raw = value[key]
        if raw == nil and tonumber(key) then raw = value[tonumber(key)] end
        parts[#parts + 1] = key .. '=' .. serialize(raw)
    end
    return '{' .. table.concat(parts, ',') .. '}'
end

function __playersChecksum()
    local text = serialize(__players)
    local hash = 5381
    for index = 1, #text do
        hash = (hash * 33 + text:byte(index)) % 2147483647
    end
    local count = 0
    for _ in pairs(__players) do count = count + 1 end
    return ('rows=%d;len=%d;hash=%d'):format(count, #text, hash)
end

function __playersBytes()
    return serialize(__players)
end

function __result(orgId, cycleNo)
    local row = __results[resultKey(orgId, cycleNo)]
    return row and copy(row) or nil
end

function __resultCount(cycleNo)
    local count = 0
    for _, row in pairs(__results) do
        if tostring(row.cycle_no) == tostring(cycleNo) then
            count = count + 1
        end
    end
    return count
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

function __ledgerCount()
    return #__ledger
end

function __ledgerRow(ref)
    for _, row in ipairs(__ledger) do
        if row.ref == ref then return row end
    end
    return nil
end

function __bulletinCount()
    return #__bulletins
end

function __lastBulletin()
    return __bulletins[#__bulletins]
end

function __sqlWrites()
    return __writeCount
end

function __personalViolations()
    return __personalTouched and 1 or 0
end

function __emit(key, value)
    io.write(tostring(key) .. '|' .. tostring(value) .. string.char(10))
end

function GetConvar(name, default)
    local value = __convars[name]
    if value == nil then return default end
    return tostring(value)
end

function RegisterCommand(name, handler, restricted)
    __native[#__native + 1] = { name = name, restricted = restricted }
    __handlers[name] = handler
end

function TriggerEvent(name, ...)
    if name ~= 'industry:sale' then return end
    __saleEvents[#__saleEvents + 1] = { ... }
end

exports = setmetatable({}, {
    __index = function(_, resource)
        if resource == 'core_economy' then
            return {
                GetGlobalMultiplier = function() return __globalMultiplier end,
                GetActivityHeat = function() return __activityHeat end,
            }
        end
        if resource == 'custom-phone' then
            return {
                PostCityBulletin = function(_, text)
                    if __failBulletins then return false, 'db_error' end
                    __bulletins[#__bulletins + 1] = tostring(text)
                    return true, #__bulletins
                end,
            }
        end
        return nil
    end,
    __call = function(_, name, fn)
        __exportFns = __exportFns or {}
        __exportFns[name] = fn
    end,
})

MySQL = {}

MySQL.update = { await = function(sql, values)
    logSql('update', sql)
    guardPersonal(sql)

    -- ── industry_state ────────────────────────────────────────────
    if sql:find('UPDATE industry_state', 1, true) then
        local row = __state
        if not row then return { affectedRows = 0 } end

        if sql:find('SET warning_announced_at = FROM_UNIXTIME(?)', 1, true) then
            if row.warning_epoch ~= nil then return { affectedRows = 0 } end
            if tonumber(values[2]) ~= row.cycle_no then return { affectedRows = 0 } end
            row.warning_epoch = tonumber(values[1])
            return { affectedRows = 1 }
        end

        if sql:find('SET settled_cycle_no = ?', 1, true) then
            local wanted = tonumber(values[1]) or 0
            if row.settled_cycle_no >= wanted then return { affectedRows = 0 } end
            row.settled_cycle_no = wanted
            return { affectedRows = 1 }
        end

        if sql:find('SET result_announced_cycle = ?', 1, true) then
            local wanted = tonumber(values[1]) or 0
            if row.result_announced_cycle >= wanted then return { affectedRows = 0 } end
            row.result_announced_cycle = wanted
            return { affectedRows = 1 }
        end

        if sql:find('phase IN (?, ?)', 1, true) then
            if row.phase ~= values[4] and row.phase ~= values[5] then
                return { affectedRows = 0 }
            end
            row.cycle_no = 1
            row.phase = values[1]
            row.started_epoch = tonumber(values[2])
            row.ends_epoch = tonumber(values[3])
            row.warning_epoch = nil
            row.settled_cycle_no = 0
            row.result_announced_cycle = 0
            return { affectedRows = 1 }
        end

        -- 用 SET 子句识别「推进」这条语句（而不是按时间闸门的文本识别）：
        -- 假 DB 必须像真库一样要求四道闸都在，缺任何一道就当 0 行被拒。
        -- 否则「把 WHERE 里的条件删掉」在测试里完全看不出来 —— 2026-11-26 实测：
        -- 删掉 phase_ends_at 闸门后 25 条用例全绿，因为它们都走不进这条分支，
        -- 落到了下面的 SetPhase 兜底（无条件 affectedRows = 1）。
        local hasTimeGate = sql:find('phase_ends_at <= FROM_UNIXTIME(?)', 1, true) ~= nil
        local hasCycleGuard = sql:find('AND cycle_no = ?', 1, true) ~= nil
        local hasPhaseGuard = sql:find('AND phase = ?', 1, true) ~= nil
        local isAdvance = hasTimeGate or hasCycleGuard or hasPhaseGuard
        if isAdvance and not (hasTimeGate and hasCycleGuard and hasPhaseGuard) then
            -- 残缺的推进语句。真库会照它剩下的条件执行，假 DB 无法可靠求值 —— 直接当 0 行拒绝，
            -- 这样「删掉任何一道闸」都会在测试里显形（2026-11-26：只删时间闸门时 25 条全绿）。
            return { affectedRows = 0 }
        end
        if isAdvance then
            if __raceBeforeStateUpdate and not __raceFired then
                __raceFired = true
                local hook = __raceBeforeStateUpdate
                __raceBeforeStateUpdate = nil
                hook()
            end
            if tonumber(values[5]) ~= row.cycle_no then return { affectedRows = 0 } end
            if values[6] ~= row.phase then return { affectedRows = 0 } end
            if row.ends_epoch > tonumber(values[7]) then return { affectedRows = 0 } end
            if sql:find('settled_cycle_no >= ?', 1, true) then
                if row.settled_cycle_no < tonumber(values[8]) then
                    return { affectedRows = 0 }
                end
            end
            row.cycle_no = tonumber(values[1])
            row.phase = values[2]
            row.started_epoch = tonumber(values[3])
            row.ends_epoch = tonumber(values[4])
            if sql:find('warning_announced_at = NULL', 1, true) then
                row.warning_epoch = nil -- 只有跨周期推进才重置
            end
            return { affectedRows = 1 }
        end

        -- SetPhase：无 cycle/phase 守卫的控制台覆盖（保留 warning 水位）。
        -- 注意：走到这里必须是**控制台**那条语句；带守卫的推进语句已经在上面被识别，
        -- 不认识的形状返回 0，别用"无条件成功"兜住它。
        if sql:find('AND cycle_no = ?', 1, true) or sql:find('AND phase = ?', 1, true) then
            return { affectedRows = 0 }
        end
        row.cycle_no = tonumber(values[1])
        row.phase = values[2]
        row.started_epoch = tonumber(values[3])
        row.ends_epoch = tonumber(values[4])
        return { affectedRows = 1 }
    end

    -- ── industry_cycle_results ───────────────────────────────────
    if sql:find('UPDATE industry_cycle_results SET applied = 1', 1, true) then
        if __failNextAppliedUpdate then
            __failNextAppliedUpdate = false
            error('probe: forced applied update failure')
        end
        local row = __results[resultKey(values[1], values[2])]
        if not row or tonumber(row.applied) == 1 then return { affectedRows = 0 } end
        row.applied = 1
        return { affectedRows = 1 }
    end

    -- ── org_treasury ─────────────────────────────────────────────
    if sql:find('UPDATE org_treasury SET balance = 0', 1, true) then
        if __failNextSettlementUpdate then
            __failNextSettlementUpdate = false
            error('probe: forced settlement treasury failure')
        end
        local orgId = values[3]
        local row = __treasuries[orgId]
        if not row then return { affectedRows = 0 } end
        row.balance = 0
        row.prestige = tonumber(values[1]) or 0
        row.cycle_no = tonumber(values[2]) or 0
        return { affectedRows = 1 }
    end

    if sql:find('UPDATE org_treasury', 1, true) then
        local delta = tonumber(values[1]) or 0
        local orgId = values[2]
        local row = __treasuries[orgId]
        if not row then return { affectedRows = 0 } end
        if sql:find('balance + ? >= 0', 1, true) and row.balance + delta < 0 then
            return { affectedRows = 0 }
        end
        row.balance = row.balance + delta
        return { affectedRows = 1 }
    end

    -- ── industry_facility ────────────────────────────────────────
    if sql:find('UPDATE industry_facility SET stock = stock - ?', 1, true) then
        local qty = tonumber(values[1]) or 0
        local row = __facilities[values[2]]
        if not row or row.stock < qty then return { affectedRows = 0 } end
        row.stock = row.stock - qty
        return { affectedRows = 1 }
    end

    if sql:find('UPDATE industry_facility', 1, true)
        and sql:find('produced_units', 1, true) then
        -- 生产结算：stock/produced_units/last_tick_at 双条件 CAS。
        local produced = tonumber(values[1]) or 0
        local newLast = tonumber(values[3]) or 0
        local row = __facilities[values[4]]
        if not row then return { affectedRows = 0 } end
        if tonumber(row.last_tick_epoch) ~= tonumber(values[5]) then
            return { affectedRows = 0 }
        end
        if tonumber(row.stock) ~= tonumber(values[6]) then return { affectedRows = 0 } end
        row.stock = row.stock + produced
        row.produced_units = row.produced_units + produced
        row.last_tick_epoch = newLast
        return { affectedRows = 1 }
    end

    if sql:find('UPDATE industry_facility SET stock = stock + ?', 1, true) then
        local row = __facilities[values[2]]
        if not row then return { affectedRows = 0 } end
        row.stock = row.stock + (tonumber(values[1]) or 0)
        return { affectedRows = 1 }
    end

    if sql:find('DELETE FROM industry_facility', 1, true) then
        local orgId = values[1]
        if not __facilities[orgId] then return { affectedRows = 0 } end
        __facilities[orgId] = nil
        return { affectedRows = 1 }
    end

    -- ── industry_sales ───────────────────────────────────────────
    if sql:find('DELETE FROM industry_sales', 1, true) then
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

    -- ── industry_demand ──────────────────────────────────────────
    if sql:find('DELETE FROM industry_demand', 1, true) then
        local removed = 0
        for key, row in pairs(__demands) do
            if tostring(row.cycle_no) == tostring(values[1]) then
                __demands[key] = nil
                removed = removed + 1
            end
        end
        return { affectedRows = removed }
    end

    if sql:find('UPDATE industry_demand SET quota_used = quota_used + ?', 1, true) then
        local qty = tonumber(values[1]) or 0
        local row = __demands[demandKey(values[2], values[3], values[4])]
        if not row then return { affectedRows = 0 } end
        if row.quota_used + qty > row.quota_total then return { affectedRows = 0 } end
        if sql:find('SUM(s.qty)', 1, true) then
            local orgId = values[6]
            local used = qty
            for _, sale in ipairs(__sales) do
                if tostring(sale.org_id) == tostring(orgId)
                    and tostring(sale.cycle_no) == tostring(values[7])
                    and sale.item_name == values[8] then
                    used = used + (tonumber(sale.qty) or 0)
                end
            end
            local cap = math.floor(row.quota_total * (tonumber(values[10]) or 0.5) + 1e-9)
            if used > cap then return { affectedRows = 0 } end
        end
        row.quota_used = row.quota_used + qty
        return { affectedRows = 1 }
    end

    if sql:find('UPDATE industry_demand SET quota_used = quota_used - ?', 1, true) then
        local qty = tonumber(values[1]) or 0
        local row = __demands[demandKey(values[2], values[3], values[4])]
        if not row or row.quota_used < qty then return { affectedRows = 0 } end
        row.quota_used = row.quota_used - qty
        return { affectedRows = 1 }
    end

    if sql:find('UPDATE industry_demand SET quota_total = ?', 1, true) then
        local row = __demands[demandKey(values[2], values[3], values[4])]
        if not row or row.quota_used ~= 0 then return { affectedRows = 0 } end
        row.quota_total = tonumber(values[1]) or 0
        return { affectedRows = 1 }
    end

    return { affectedRows = 0 }
end }

MySQL.single = { await = function(sql, values)
    logSql('single', sql)
    guardPersonal(sql)

    if sql:find('FROM industry_state', 1, true) then
        local row = __state
        if not row then return nil end
        if sql:find('SELECT settled_cycle_no', 1, true) then
            return { settled_cycle_no = row.settled_cycle_no }
        end
        if sql:find('SELECT result_announced_cycle', 1, true) then
            return { result_announced_cycle = row.result_announced_cycle }
        end
        return {
            id = 1,
            cycle_no = row.cycle_no,
            phase = row.phase,
            started_epoch = row.started_epoch,
            ends_epoch = row.ends_epoch,
            warning_done = row.warning_epoch ~= nil and 1 or 0,
            warning_epoch = row.warning_epoch,
            settled_cycle_no = row.settled_cycle_no,
            result_announced_cycle = row.result_announced_cycle,
        }
    end

    if sql:find('FROM industry_cycle_results', 1, true) then
        if sql:find('ORDER BY revenue DESC', 1, true) then
            local best
            for _, row in pairs(__results) do
                if tostring(row.cycle_no) == tostring(values[1])
                    and (not best or row.revenue > best.revenue) then
                    best = row
                end
            end
            return best and copy(best) or nil
        end
        local row = __results[resultKey(values[1], values[2])]
        return row and copy(row) or nil
    end

    if sql:find('FROM industry_sales', 1, true) then
        if sql:find('COUNT(*)', 1, true) then
            local count = 0
            for _, row in ipairs(__sales) do
                if tostring(row.cycle_no) == tostring(values[1]) then
                    count = count + 1
                end
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
            local sameOrg = sql:find('org_id = ?', 1, true) ~= nil
            local total = 0
            for _, row in ipairs(__sales) do
                local matches
                if sameOrg then
                    matches = tostring(row.org_id) == tostring(values[1])
                        and tostring(row.cycle_no) == tostring(values[2])
                        and row.item_name == values[3]
                else
                    matches = tostring(row.cycle_no) == tostring(values[1])
                        and row.item_name == values[2]
                end
                if matches then total = total + (tonumber(row.qty) or 0) end
            end
            return { used = total }
        end
        for _, row in ipairs(__sales) do
            if tostring(row.org_id) == tostring(values[1]) and row.ref == values[2] then
                return { id = row.id }
            end
        end
        return nil
    end

    if sql:find('FROM industry_demand', 1, true) then
        if sql:find('COUNT(*)', 1, true) then
            local count = 0
            for _, row in pairs(__demands) do
                if tostring(row.cycle_no) == tostring(values[1]) then
                    count = count + 1
                end
            end
            return { n = count }
        end
        local row = __demands[demandKey(values[1], values[2], values[3])]
        return row and { quota_total = row.quota_total, quota_used = row.quota_used } or nil
    end

    if sql:find('FROM industry_facility', 1, true) then
        if sql:find('COUNT(*)', 1, true) then
            return { n = __facilities[values[1]] and 1 or 0 }
        end
        local row = __facilities[values[1]]
        if not row then return nil end
        if sql:find('UNIX_TIMESTAMP(last_tick_at)', 1, true) then
            return copy(row)
        end
        if sql:find('produced_units', 1, true) and not sql:find('facility_type', 1, true) then
            return { produced_units = row.produced_units }
        end
        return { stock = row.stock }
    end

    if sql:find('FROM org_treasury', 1, true) then
        if sql:find('COUNT(*)', 1, true) then
            return { n = __treasuries[values[1]] and 1 or 0 }
        end
        local row = __treasuries[values[1]]
        if not row then return nil end
        return { balance = row.balance, prestige = row.prestige }
    end

    if sql:find('FROM org_ledger', 1, true) then
        local key = tostring(values[1]) .. '\0' .. tostring(values[2])
        if __ledgerRefs[key] then return { id = __ledgerRefs[key] } end
        return nil
    end

    return nil
end }

MySQL.query = { await = function(sql, values)
    logSql('query', sql)
    guardPersonal(sql)

    if sql:find('UNION', 1, true) and sql:find('industry_facility', 1, true) then
        local seen = {}
        local rows = {}
        local function add(orgId)
            orgId = tostring(orgId)
            if orgId ~= '' and not seen[orgId] then
                seen[orgId] = true
                rows[#rows + 1] = { org_id = orgId }
            end
        end
        for orgId in pairs(__facilities) do add(orgId) end
        for _, sale in ipairs(__sales) do
            if tostring(sale.cycle_no) == tostring(values[1]) then add(sale.org_id) end
        end
        for orgId in pairs(__treasuries) do add(orgId) end
        table.sort(rows, function(a, b) return a.org_id < b.org_id end)
        local limit = tonumber(values[2]) or #rows
        while #rows > limit do table.remove(rows) end
        return rows
    end

    return {}
end }

MySQL.insert = { await = function(sql, values)
    logSql('insert', sql)
    guardPersonal(sql)

    if sql:find('INSERT IGNORE INTO industry_state', 1, true) then
        if __state then return { affectedRows = 0 } end
        __state = {
            cycle_no = 1,
            phase = values[1],
            started_epoch = tonumber(values[2]),
            ends_epoch = tonumber(values[3]),
            warning_epoch = nil,
            settled_cycle_no = 0,
            result_announced_cycle = 0,
        }
        return { affectedRows = 1 }
    end

    if sql:find('INSERT INTO industry_cycle_results', 1, true) then
        local key = resultKey(values[1], values[2])
        if __results[key] then
            error("Duplicate entry for key 'industry_cycle_results.uniq_org_cycle'")
        end
        __nextResultId = __nextResultId + 1
        __results[key] = {
            id = __nextResultId,
            org_id = values[1],
            cycle_no = tonumber(values[2]),
            revenue = tonumber(values[3]) or 0,
            produced_units = tonumber(values[4]) or 0,
            score = tonumber(values[5]) or 0,
            prestige_awarded = tonumber(values[6]) or 0,
            prestige_before = tonumber(values[7]) or 0,
            prestige_after = tonumber(values[8]) or 0,
            balance_cleared = tonumber(values[9]) or 0,
            applied = 0,
        }
        return { insertId = __nextResultId }
    end

    if sql:find('INSERT IGNORE INTO org_treasury', 1, true) then
        if __treasuries[values[1]] then return { affectedRows = 0 } end
        __treasuries[values[1]] = {
            balance = 0,
            prestige = tonumber(values[2]) or 0,
            cycle_no = tonumber(values[3]) or 0,
        }
        return { affectedRows = 1 }
    end

    if sql:find('INSERT IGNORE INTO org_ledger', 1, true) then
        local key = tostring(values[1]) .. '\0' .. tostring(values[4])
        if __ledgerRefs[key] then return { affectedRows = 0 } end
        __nextLedgerId = __nextLedgerId + 1
        __ledgerRefs[key] = __nextLedgerId
        __ledger[#__ledger + 1] = {
            id = __nextLedgerId,
            org_id = values[1],
            delta = tonumber(values[2]),
            balance_after = 0,
            reason = values[3],
            ref = values[4],
        }
        return { insertId = __nextLedgerId }
    end

    if sql:find('INSERT INTO org_ledger', 1, true) then
        local orgId = values[1]
        local ref = tostring(#values == 7 and values[6] or values[5])
        local key = orgId .. '\0' .. ref
        if __ledgerRefs[key] then
            error("Duplicate entry for key 'org_ledger.uniq_org_ref'")
        end
        __nextLedgerId = __nextLedgerId + 1
        __ledgerRefs[key] = __nextLedgerId
        __ledger[#__ledger + 1] = {
            id = __nextLedgerId,
            org_id = orgId,
            delta = tonumber(values[2]),
            balance_after = tonumber(values[3]),
            reason = values[4],
            ref = ref,
        }
        return { insertId = __nextLedgerId }
    end

    if sql:find('INSERT IGNORE INTO industry_demand', 1, true) then
        local key = demandKey(values[1], values[2], values[3])
        if __demands[key] then return { affectedRows = 0 } end
        __demands[key] = {
            cycle_no = values[1],
            phase = values[2],
            item_name = values[3],
            quota_total = tonumber(values[4]) or 0,
            quota_used = 0,
        }
        return { affectedRows = 1 }
    end

    if sql:find('INSERT INTO industry_sales', 1, true) then
        __nextSaleId = __nextSaleId + 1
        __sales[#__sales + 1] = {
            id = __nextSaleId,
            org_id = values[1],
            cycle_no = values[2],
            item_name = values[3],
            qty = tonumber(values[4]),
            unit_price = tonumber(values[5]),
            revenue = tonumber(values[6]),
            ref = values[7],
        }
        return { insertId = __nextSaleId }
    end

    if sql:find('INSERT INTO industry_audit', 1, true) then
        if #values == 4 then
            __audits[#__audits + 1] = {
                org_id = values[1], actor_cid = values[2],
                action = values[3], payload = values[4],
            }
        else
            __audits[#__audits + 1] = {
                org_id = values[1], actor_cid = nil,
                action = values[2], payload = values[3],
            }
        end
        return { insertId = 1 }
    end

    if sql:find('INSERT INTO industry_facility', 1, true) then
        if __facilities[values[1]] then error('Duplicate entry for key PRIMARY') end
        __facilities[values[1]] = {
            org_id = values[1], facility_type = values[2], level = 1,
            workstations = 0, stock = 0, produced_units = 0, last_tick_epoch = 0,
        }
        return { affectedRows = 1 }
    end

    return { insertId = 0 }
end }

MySQL.scalar = { await = function() return 0 end }
MySQL.execute = { await = function() return 1 end }
