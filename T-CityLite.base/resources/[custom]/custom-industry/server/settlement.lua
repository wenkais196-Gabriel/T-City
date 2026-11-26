-- server/settlement.lua — S7 结算 / 转生。
--
-- 清分边界写在**表级显式清单**（spec §12）：
--
--   产业层 → 全清
--     industry_facility      设施行（level / workstations / stock / produced_units 全在这行）
--     industry_sales         本周期卖单流水
--     industry_demand        本周期未成交配额
--     org_treasury.balance   余额归零（流水表保留，清分本身写一条 settlement-clear）
--
--   个人层 → 一个字节都不动
--     players / player_vehicles / inventories / 任何 Player.Functions
--     本文件没有这些表的 SQL，也没有玩家对象入参；测试用 checksum 与静态扫描双重钉住。
--
--   永久层 → prestige
--     prestige = floor(sqrt(累计销售额 / K))，累积到 org_treasury.prestige；
--     industry_cycle_results 保留每周期快照。
--
-- 幂等 / 崩溃恢复：
--   * UNIQUE(org_id, cycle_no) 是数据库事实；重复结算被它挡住。
--   * 结果行先落库（applied = 0），再清分，最后 applied = 1。
--   * prestige 写**绝对值**（prestige_before + awarded），重试不会重复累加。
--   * 清分里的 DELETE 天然幂等；清分前的余额快照存在结果表，重试能补写流水。
--   * 没有跨表事务（db.lua 不提供）：失败就保持 applied = 0，下一 tick 继续。
--
-- 执行顺序（与 spec §12 一致）：dry-run（只打印将删行数） → 真删 → 审计。

IndustrySettlement = {}

local MAX_CYCLE = 1000000

local function cycleConfig()
    return Config.Industry.Cycle or {}
end

local function toInt(value)
    local number = tonumber(value)
    if not number or number ~= number or number ~= math.floor(number) then return nil end
    return number
end

local function nonNegative(value)
    local number = tonumber(value)
    if not number or number ~= number or number < 0 then return 0 end
    return math.floor(number)
end

--- prestige = floor(sqrt(累计销售额 / K))。K 来自配置（默认 500）。
---@param revenue number
---@return number
function IndustrySettlement.PrestigeFor(revenue)
    local k = tonumber(cycleConfig().PrestigeK) or 500
    if k <= 0 then k = 500 end
    local total = nonNegative(revenue)
    return math.floor(math.sqrt(total / k) + 1e-9)
end

--- 本周期需要处理的组织：有设施、本周期有卖单、或金库有行。
--- 显式列名 + LIMIT；结果在 Lua 里排序，保证执行顺序稳定。
---@param cycleNo number
---@return table|nil orgIds, string|nil errcode
local function listOrgs(cycleNo)
    local limit = math.max(1, math.floor(tonumber(cycleConfig().MaxOrgsPerSettle) or 500))
    local rows, err = Db.Query(
        'SELECT org_id FROM industry_facility '
            .. 'UNION SELECT org_id FROM industry_sales WHERE cycle_no = ? '
            .. 'UNION SELECT org_id FROM org_treasury '
            .. 'LIMIT ?',
        { cycleNo, limit })
    if err then return nil, 'db_error' end

    local seen = {}
    local orgIds = {}
    for _, row in ipairs(rows or {}) do
        local orgId = tostring(row.org_id or '')
        if orgId ~= '' and not seen[orgId] then
            seen[orgId] = true
            orgIds[#orgIds + 1] = orgId
        end
    end
    table.sort(orgIds)
    return orgIds, nil
end

--- 单行聚合；失败返回 0（调用方已经把 db_error 折叠成业务上的「无数据」）。
local function scalarCount(sql, params)
    local row, err = Db.Single(sql, params)
    if err or not row then return 0 end
    return nonNegative(row.n or row.total or row.revenue)
end

---@return table|nil row, string|nil errcode
local function readResult(orgId, cycleNo)
    local row, err = Db.Single(
        'SELECT revenue, produced_units, score, prestige_awarded, prestige_before, '
            .. 'prestige_after, balance_cleared, applied '
            .. 'FROM industry_cycle_results WHERE org_id = ? AND cycle_no = ? LIMIT 1',
        { orgId, cycleNo })
    if err then return nil, 'db_error' end
    return row, nil
end

--- 收支点：读本组织本周期累计销售额。
local function readRevenue(orgId, cycleNo)
    local row, err = Db.Single(
        'SELECT COALESCE(SUM(revenue), 0) AS total FROM industry_sales '
            .. 'WHERE org_id = ? AND cycle_no = ? LIMIT 1',
        { orgId, cycleNo })
    if err then return nil, 'db_error' end
    return nonNegative(row and row.total), nil
end

local function readProduced(orgId)
    local row, err = Db.Single(
        'SELECT produced_units FROM industry_facility WHERE org_id = ? LIMIT 1',
        { orgId })
    if err then return nil, 'db_error' end
    if not row then return 0, nil end
    return nonNegative(row.produced_units), nil
end

local function readTreasury(orgId)
    local row, err = Db.Single(
        'SELECT balance, prestige FROM org_treasury WHERE org_id = ? LIMIT 1',
        { orgId })
    if err then return nil, 'db_error' end
    if not row then return { balance = 0, prestige = 0 }, nil end
    return {
        balance = nonNegative(row.balance),
        prestige = nonNegative(row.prestige),
    }, nil
end

--- 结果行：已存在就复用（崩溃恢复时不能重新计算，否则会把重试之间新增的
--- 销售额吃进同一周期），不存在就按当前快照计算并插入。
---@return table|nil result, string|nil errcode, boolean inserted
local function ensureResult(orgId, cycleNo)
    local existing, readErr = readResult(orgId, cycleNo)
    if readErr then return nil, readErr, false end
    if existing then return existing, nil, false end

    local revenue, revenueErr = readRevenue(orgId, cycleNo)
    if not revenue then return nil, revenueErr, false end
    local produced, producedErr = readProduced(orgId)
    if not produced then return nil, producedErr, false end
    local treasury, treasuryErr = readTreasury(orgId)
    if not treasury then return nil, treasuryErr, false end

    local awarded = IndustrySettlement.PrestigeFor(revenue)
    local result = {
        revenue = revenue,
        produced_units = produced,
        score = revenue,
        prestige_awarded = awarded,
        prestige_before = treasury.prestige,
        prestige_after = treasury.prestige + awarded,
        balance_cleared = treasury.balance,
        applied = 0,
    }

    local id, insertErr = Db.Insert(
        'INSERT INTO industry_cycle_results '
            .. '(org_id, cycle_no, revenue, produced_units, score, prestige_awarded, '
            .. 'prestige_before, prestige_after, balance_cleared, applied) '
            .. 'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)',
        {
            orgId, cycleNo, revenue, produced, revenue, awarded,
            treasury.prestige, treasury.prestige + awarded, treasury.balance,
        })
    if id then return result, nil, true end

    -- 唯一键冲突（并发/上次崩溃后已插过）→ 读回来继续，不重复发 prestige。
    local raced, racedErr = readResult(orgId, cycleNo)
    if racedErr then return nil, racedErr, false end
    if raced then return raced, nil, false end
    if insertErr == 'no_insert_id' then return nil, 'db_error', false end
    return nil, 'db_error', false
end

--- 单个组织的清分。结果行 applied = 1 时直接跳过（幂等）。
---@return boolean ok, string|nil errcode, table|nil info
local function settleOrg(orgId, cycleNo)
    local result, resultErr = ensureResult(orgId, cycleNo)
    if not result then return false, resultErr end

    if nonNegative(result.applied) == 1 then
        return true, nil, { org_id = orgId, skipped = true }
    end

    -- ① 金库：余额归零 + prestige 写绝对值（重试不会重复累加）。
    if type(Treasury) ~= 'table' or not Treasury.ApplySettlement then
        return false, 'treasury_unavailable'
    end
    local applied, treasuryErr = Treasury.ApplySettlement(orgId, {
        prestigeAfter = nonNegative(result.prestige_after),
        cycleNo = cycleNo,
        clearedBalance = nonNegative(result.balance_cleared),
        ref = 'settle:' .. tostring(cycleNo),
    })
    if not applied then return false, treasuryErr or 'db_error' end

    -- ② 产业层删除：显式两张表；个人层不在本文件的任何 SQL 里。
    local facilityDeleted, facilityErr = Db.Update(
        'DELETE FROM industry_facility WHERE org_id = ?', { orgId })
    if facilityErr then return false, 'db_error' end

    local salesDeleted, salesErr = Db.Update(
        'DELETE FROM industry_sales WHERE org_id = ? AND cycle_no = ?',
        { orgId, cycleNo })
    if salesErr then return false, 'db_error' end

    -- ③ 标记完成。affected = 0 也视为完成（另一条路径先标了，prestige 仍是绝对值）。
    local _, markErr = Db.Update(
        'UPDATE industry_cycle_results SET applied = 1, applied_at = current_timestamp '
            .. 'WHERE org_id = ? AND cycle_no = ? AND applied = 0',
        { orgId, cycleNo })
    if markErr then return false, 'db_error' end

    return true, nil, {
        org_id = orgId,
        skipped = false,
        facility_deleted = facilityDeleted or 0,
        sales_deleted = salesDeleted or 0,
        prestige_awarded = nonNegative(result.prestige_awarded),
        revenue = nonNegative(result.revenue),
        produced_units = nonNegative(result.produced_units),
    }
end

local function addCount(summary, key, value)
    summary[key] = (summary[key] or 0) + nonNegative(value)
end

--- dry-run：只读，打印「将删 N 行 / 将写 M 行」，不写库。
---@param cycleNo number|nil
---@return table|nil report, string|nil errcode
function IndustrySettlement.Preview(cycleNo)
    local cycle = toInt(cycleNo)
    if not cycle or cycle < 0 or cycle > MAX_CYCLE then return nil, 'bad_cycle' end

    local orgIds, orgErr = listOrgs(cycle)
    if not orgIds then return nil, orgErr end

    local report = {
        cycle_no = cycle,
        orgs = #orgIds,
        results = 0,
        resume = 0,
        facility_rows = 0,
        sales_rows = 0,
        demand_rows = 0,
        treasury_rows = 0,
        treasury_balance = 0,
        prestige_awarded = 0,
    }

    for _, orgId in ipairs(orgIds) do
        local existing = readResult(orgId, cycle)
        if existing and nonNegative(existing.applied) == 1 then
            -- 已结算：不会写结果，也不会再删这个组织的设施。
        elseif existing then
            report.resume = report.resume + 1
            report.prestige_awarded = report.prestige_awarded
                + nonNegative(existing.prestige_awarded)
        else
            local revenue = readRevenue(orgId, cycle) or 0
            report.results = report.results + 1
            report.prestige_awarded = report.prestige_awarded
                + IndustrySettlement.PrestigeFor(revenue)
        end

        report.facility_rows = report.facility_rows + scalarCount(
            'SELECT COUNT(*) AS n FROM industry_facility WHERE org_id = ? LIMIT 1',
            { orgId })
        report.treasury_rows = report.treasury_rows + scalarCount(
            'SELECT COUNT(*) AS n FROM org_treasury WHERE org_id = ? LIMIT 1',
            { orgId })
        local treasury = readTreasury(orgId)
        report.treasury_balance = report.treasury_balance
            + (treasury and treasury.balance or 0)
    end

    report.sales_rows = scalarCount(
        'SELECT COUNT(*) AS n FROM industry_sales WHERE cycle_no = ? LIMIT 1', { cycle })
    report.demand_rows = scalarCount(
        'SELECT COUNT(*) AS n FROM industry_demand WHERE cycle_no = ? LIMIT 1', { cycle })

    print(('[custom-industry] settlement dry-run cycle=%d: orgs=%d results=%d resume=%d '
        .. 'facility_rows=%d sales_rows=%d demand_rows=%d treasury_rows=%d '
        .. 'balance=%d prestige=%d'):format(
        report.cycle_no, report.orgs, report.results, report.resume,
        report.facility_rows, report.sales_rows, report.demand_rows,
        report.treasury_rows, report.treasury_balance, report.prestige_awarded))
    return report, nil
end

local settling = false

--- 真结算。同一周期重复调用由 UNIQUE(org_id, cycle_no) 与 applied 挡住。
---@param cycleNo number|nil
---@param opts table|nil { trigger = string|nil, dryRun = boolean|nil }
---@return boolean ok, string|nil errcode, table|nil summary
function IndustrySettlement.SettleCycle(cycleNo, opts)
    opts = opts or {}
    local cycle = toInt(cycleNo)
    if not cycle or cycle < 0 or cycle > MAX_CYCLE then return false, 'bad_cycle' end

    if opts.dryRun == true then
        local report, err = IndustrySettlement.Preview(cycle)
        if not report then return false, err end
        return true, nil, report
    end

    if settling then return false, 'busy' end
    settling = true

    local called, ok, err, summary = pcall(function()
        return IndustrySettlement.SettleCycleLocked(cycle, opts)
    end)
    settling = false

    if not called then
        print(('[custom-industry] CRITICAL settlement crashed cycle=%d: %s'):format(
            cycle, tostring(ok)))
        return false, 'db_error'
    end
    return ok, err, summary
end

--- SettleCycle 的实体（调用方必须已经拿到 settling 锁）。
---@param cycle number
---@param opts table
---@return boolean ok, string|nil errcode, table|nil summary
function IndustrySettlement.SettleCycleLocked(cycle, opts)
    -- 已完成水位：同一周期第二次结算直接拒绝（不重复发 prestige、不重复公告）。
    local stateRow, stateErr = Db.Single(
        'SELECT settled_cycle_no FROM industry_state WHERE id = 1 LIMIT 1', {})
    if stateErr then return false, 'db_error' end
    if stateRow and math.floor(tonumber(stateRow.settled_cycle_no) or 0) >= cycle then
        return true, nil, {
            cycle_no = cycle,
            already_settled = true,
            orgs = 0,
            settled = 0,
            skipped = 0,
            failed = 0,
            facility_deleted = 0,
            sales_deleted = 0,
            demand_deleted = 0,
            prestige_awarded = 0,
            revenue = 0,
        }
    end

    local orgIds, orgErr = listOrgs(cycle)
    if not orgIds then return false, orgErr end

    local summary = {
        cycle_no = cycle,
        orgs = #orgIds,
        settled = 0,
        skipped = 0,
        failed = 0,
        facility_deleted = 0,
        sales_deleted = 0,
        demand_deleted = 0,
        prestige_awarded = 0,
        revenue = 0,
    }
    local firstErr

    for _, orgId in ipairs(orgIds) do
        local ok, err, info = settleOrg(orgId, cycle)
        if not ok then
            summary.failed = summary.failed + 1
            firstErr = firstErr or err or 'db_error'
            print(('[custom-industry] settlement failed org=%s cycle=%d err=%s'):format(
                tostring(orgId), cycle, tostring(err or 'db_error')))
        elseif info and info.skipped then
            summary.skipped = summary.skipped + 1
        else
            summary.settled = summary.settled + 1
            addCount(summary, 'facility_deleted', info and info.facility_deleted)
            addCount(summary, 'sales_deleted', info and info.sales_deleted)
            addCount(summary, 'prestige_awarded', info and info.prestige_awarded)
            addCount(summary, 'revenue', info and info.revenue)
        end
    end

    -- 有组织失败：保留本周期数据，下一次 tick 继续；已成功的组织靠 applied=1 跳过。
    if firstErr then
        return false, firstErr, summary
    end

    -- 全服配额行只在本周期结算完成后删一次；DELETE 幂等。
    local demandDeleted, demandErr = Db.Update(
        'DELETE FROM industry_demand WHERE cycle_no = ?', { cycle })
    if demandErr then return false, 'db_error', summary end
    summary.demand_deleted = summary.demand_deleted + nonNegative(demandDeleted)

    -- settled_cycle_no 只增不减；affected = 0 表示已经结算过（重复调用被拒）。
    Db.Update(
        'UPDATE industry_state SET settled_cycle_no = ? '
            .. 'WHERE id = 1 AND settled_cycle_no < ?',
        { cycle, cycle })

    if IndustryAudit and IndustryAudit.Write then
        local trigger = tostring(opts.trigger or 'manual'):gsub('[^%w_%-]', '_')
        IndustryAudit.Write('*', nil, 'cycle.settle', ('{"cycle_no":%d,"trigger":"%s",'
            .. '"orgs":%d,"settled":%d,"skipped":%d,"facility_deleted":%d,'
            .. '"sales_deleted":%d,"demand_deleted":%d,"prestige_awarded":%d}'):format(
            cycle, trigger,
            summary.orgs, summary.settled, summary.skipped,
            summary.facility_deleted, summary.sales_deleted,
            summary.demand_deleted, summary.prestige_awarded))
    end

    -- 公告失败不阻断结算：结果表已经是权威事实，下一 tick 会补发。
    if IndustryAnnounce and IndustryAnnounce.Result then
        IndustryAnnounce.Result(cycle)
    end

    print(('[custom-industry] settlement done cycle=%d orgs=%d settled=%d skipped=%d '
        .. 'facility=%d sales=%d demand=%d prestige=+%d'):format(
        cycle, summary.orgs, summary.settled, summary.skipped,
        summary.facility_deleted, summary.sales_deleted,
        summary.demand_deleted, summary.prestige_awarded))
    return true, nil, summary
end
