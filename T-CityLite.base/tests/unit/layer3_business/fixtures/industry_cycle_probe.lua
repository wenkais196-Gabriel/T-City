-- fixtures/industry_cycle_probe.lua — S6/S7 的离线假数据库（真跑 Lua，只替换 MySQL）。
--
-- 覆盖 cycle.lua / settlement.lua / announce.lua / commands_cycle.lua 以及
-- sale.lua / facility.lua / production.lua 的**读点**：
--
--   industry_state          单行：cycle_no / phase / epoch 边界 / 公告水位
--   industry_cycle_results  UNIQUE(org_id, cycle_no) 由 `__results` 模拟
--   industry_facility / industry_sales / industry_demand / org_treasury / org_ledger
--
-- 公共 SQL 求值（设施 / 配额 / 卖单 / 金库 / 流水 / 审计）在
-- industry_probe_common.lua。本文件只保留周期特有的形状与状态机：
--
--   * 任何 SQL 提到 `players` 都会直接 error —— 结算触碰个人层时用例必须大声失败。
--   * `__sqlWrites` 统计真正的写语句；dry-run 用例断言它为 0。
--   * `__raceBeforeStateUpdate` 在推进 UPDATE 落库前触发一次，用来制造
--     「读到的旧阶段 + 别人先改了」的交错（affectedRows = 0 是唯一推进许可）。
--   * `__failNextSettlementUpdate` / `__failNextAppliedUpdate` 模拟结算中途崩溃。
--   * 推进语句必须四道闸齐全（SET 子句 + 三个 WHERE 条件）；缺任何一道就按 0 行
--     拒绝 —— 否则删掉 WHERE 里的闸门在测试里完全看不出来。

__convars = {}

-- 构造器来自 industry_probe_common.lua（industry_harness 负责注入）。
local copy = __industryCopy
local demandKey = __industryDemandKey

local function resultKey(orgId, cycleNo)
    return tostring(orgId) .. '\0' .. tostring(cycleNo)
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

-- 初始状态与 reset 共用一份赋值（避免模块级初始化块再抄一遍）。
__reset()

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

function __seedSale(orgId, cycleNo, item, qty, unitPrice, revenue)
    __nextSaleId = __nextSaleId + 1
    __sales[#__sales + 1] = __industrySaleRow({
        id = __nextSaleId,
        org_id = orgId,
        cycle_no = cycleNo,
        item_name = item or 'iron_ore',
        qty = qty,
        unit_price = unitPrice or 50,
        revenue = revenue or 0,
        ref = 'seed-sale-' .. __nextSaleId,
    })
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
    __demands[demandKey(cycleNo, phase, item)] =
        __industryDemandRow(cycleNo, phase, item, total, used)
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

function RegisterCommand(name, handler, restricted)
    __native[#__native + 1] = { name = name, restricted = restricted }
    __handlers[name] = handler
end

exports = __industryExports({
    ['custom-phone'] = {
        PostCityBulletin = function(_, text)
            if __failBulletins then return false, 'db_error' end
            __bulletins[#__bulletins + 1] = tostring(text)
            return true, #__bulletins
        end,
    },
})

MySQL = {}

MySQL.update = { await = function(sql, values)
    __industryLogSql('update', sql)
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

    -- ── org_treasury：结算清零（S7 转生），其余走公共语义 ─────────
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

    return __industryUpdate(sql, values) or { affectedRows = 0 }
end }

MySQL.single = { await = function(sql, values)
    __industryLogSql('single', sql)
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

    return __industrySingle(sql, values, { facility = 'cycle' })
end }

MySQL.query = { await = function(sql, values)
    __industryLogSql('query', sql)
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
    __industryLogSql('insert', sql)
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

    return __industryInsert(sql, values) or { insertId = 0 }
end }

__industryMysqlTail()
