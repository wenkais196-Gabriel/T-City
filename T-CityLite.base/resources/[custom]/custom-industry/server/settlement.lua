-- server/settlement.lua — S7 结算 / 转生（P1 两时钟：季度软重置）。
--
-- 清分边界写在**表级显式清单**（spec §12）：
--
--   产业层 → 全清（季度结算）
--     industry_facility      设施行（level / workstations / stock / produced_units 全在这行）
--     industry_sales         本季度卖单流水
--     industry_demand        本季度配额行
--     org_treasury.balance   余额归零（流水表保留，清分本身写一条 settlement-clear）
--
--   个人层 → 一个字节都不动
--     players / player_vehicles / inventories / 任何 Player.Functions
--     本文件没有这些表的 SQL，也没有玩家对象入参；测试用 checksum 与静态扫描双重钉住。
--
--   永久层 → prestige + 起跑金
--     prestige = floor(sqrt(季度累计销售额 / K))，累积到 org_treasury.prestige；
--     industry_cycle_results 保留每季度快照（键 = quarter_no）。
--     季度软重置后给每个组织发一笔起跑金（base + prestige × stipend），
--     流水 ref = quarter-starter:<quarter>，唯一键保证重试不重复发。
--
-- 幂等 / 崩溃恢复：
--   * UNIQUE(org_id, quarter_no) 是数据库事实；重复结算被它挡住。
--   * 结果行先落库（applied = 0），再清分，最后 applied = 1。
--   * prestige 写**绝对值**（prestige_before + awarded），重试不会重复累加。
--   * 起跑金走 Treasury.Deposit 的唯一 ref；重试拿到 duplicate_ref 视为已发。
--   * 清分里的 DELETE 天然幂等；清分前的余额快照存在结果表，重试能补写流水。
--   * 没有跨表事务（db.lua 不提供）：失败就保持 applied = 0，下一 tick 继续。
--
-- 旧单时钟（S6/S7）仍走同一条实现：`SettleCycle` 是薄包装，legacy 选项让
-- 结果键回到 cycle_no、按单周期求和/删除、且不发起跑金。迁移日不需要两套代码。
--
-- 执行顺序（与 spec §12 一致）：dry-run（只打印将删行数） → 真删 → 审计。

IndustrySettlement = {}

local MAX_CYCLE = 1000000
-- 与 Treasury 的 MAX_AMOUNT 对齐：超过它的起跑金会被 Deposit 拒绝，结算永远卡住。
local MAX_GRANT = 1000000000000000

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

--- 季度起跑金 = base + 结算后 prestige × stipend（demo 口径）。
---@param result table|nil
---@return number
local function starterGrantFor(result)
    local base = math.floor(tonumber(cycleConfig().QuarterStarterGrant) or 0)
    local stipend = math.floor(tonumber(cycleConfig().QuarterPrestigeStipend) or 0)
    if base < 0 then base = 0 end
    if stipend < 0 then stipend = 0 end
    local prestige = nonNegative(result and result.prestige_after)
    local amount = base + stipend * prestige
    if amount > MAX_GRANT then amount = MAX_GRANT end
    return amount
end

--- 本周期/季度需要处理的组织：有设施、有卖单、或金库有行。
--- 显式列名 + LIMIT；结果在 Lua 里排序，保证执行顺序稳定。
--- 两时钟的卖单跨 13 周，所以不再按单个 cycle_no 过滤 —— 设施/金库兜住绝大多数
--- 组织，卖单 UNION 只补「有流水但没设施/金库行」的异常组织。
---@param limit number
---@return table|nil orgIds, string|nil errcode
local function listOrgs(limit)
    local rows, err = Db.Query(
        'SELECT org_id FROM industry_facility '
            .. 'UNION SELECT org_id FROM industry_sales '
            .. 'UNION SELECT org_id FROM org_treasury '
            .. 'LIMIT ?',
        { limit })
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

--- 结果键列：legacy = cycle_no，两时钟 = quarter_no（都在固定白名单里）。
local function keyColumn(legacy)
    return legacy and 'cycle_no' or 'quarter_no'
end

---@return table|nil row, string|nil errcode
local function readResult(orgId, periodNo, legacy)
    local row, err = Db.Single(
        'SELECT revenue, produced_units, score, prestige_awarded, prestige_before, '
            .. 'prestige_after, balance_cleared, applied '
            .. 'FROM industry_cycle_results WHERE org_id = ? AND '
            .. keyColumn(legacy) .. ' = ? LIMIT 1',
        { orgId, periodNo })
    if err then return nil, 'db_error' end
    return row, nil
end

--- 旧单时钟：读本组织本周期累计销售额。
local function readRevenue(orgId, cycleNo)
    local row, err = Db.Single(
        'SELECT COALESCE(SUM(revenue), 0) AS total FROM industry_sales '
            .. 'WHERE org_id = ? AND cycle_no = ? LIMIT 1',
        { orgId, cycleNo })
    if err then return nil, 'db_error' end
    return nonNegative(row and row.total), nil
end

--- 两时钟：本季度销售额 = 组织剩余全部卖单。
--- 每次季度结算都会清掉该组织全部卖单，所以「剩余全部」就是本季度。
local function readQuarterRevenue(orgId)
    local row, err = Db.Single(
        'SELECT COALESCE(SUM(revenue), 0) AS total FROM industry_sales '
            .. 'WHERE org_id = ? LIMIT 1',
        { orgId })
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
local function ensureResult(orgId, periodNo, opts)
    local legacy = opts.legacy == true
    local existing, readErr = readResult(orgId, periodNo, legacy)
    if readErr then return nil, readErr, false end
    if existing then return existing, nil, false end

    local revenue, revenueErr
    if legacy then
        revenue, revenueErr = readRevenue(orgId, periodNo)
    else
        revenue, revenueErr = readQuarterRevenue(orgId)
    end
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

    local id, insertErr
    if legacy then
        id, insertErr = Db.Insert(
            'INSERT INTO industry_cycle_results '
                .. '(org_id, cycle_no, revenue, produced_units, score, prestige_awarded, '
                .. 'prestige_before, prestige_after, balance_cleared, applied) '
                .. 'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)',
            {
                orgId, periodNo, revenue, produced, revenue, awarded,
                treasury.prestige, treasury.prestige + awarded, treasury.balance,
            })
    else
        -- cycle_no 保留旧列（本季度最后一周年份），历史行与工具仍能读；
        -- 幂等事实是 UNIQUE(org_id, quarter_no)。
        id, insertErr = Db.Insert(
            'INSERT INTO industry_cycle_results '
                .. '(org_id, quarter_no, revenue, produced_units, score, prestige_awarded, '
                .. 'prestige_before, prestige_after, balance_cleared, cycle_no, applied) '
                .. 'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)',
            {
                orgId, periodNo, revenue, produced, revenue, awarded,
                treasury.prestige, treasury.prestige + awarded, treasury.balance,
                nonNegative(opts.cycleNo or periodNo),
            })
    end
    if id then return result, nil, true end

    -- 唯一键冲突（并发/上次崩溃后已插过）→ 读回来继续，不重复发 prestige。
    local raced, racedErr = readResult(orgId, periodNo, legacy)
    if racedErr then return nil, racedErr, false end
    if raced then return raced, nil, false end
    if insertErr == 'no_insert_id' then return nil, 'db_error', false end
    return nil, 'db_error', false
end

--- 单个组织的清分。结果行 applied = 1 时直接跳过（幂等）。
---@return boolean ok, string|nil errcode, table|nil info
local function settleOrg(orgId, periodNo, opts)
    local legacy = opts.legacy == true
    local result, resultErr = ensureResult(orgId, periodNo, opts)
    if not result then return false, resultErr end

    if nonNegative(result.applied) == 1 then
        return true, nil, { org_id = orgId, skipped = true }
    end

    -- ① 金库：余额归零 + prestige 写绝对值（重试不会重复累加）。
    if type(Treasury) ~= 'table' or not Treasury.ApplySettlement then
        return false, 'treasury_unavailable'
    end
    local ref = legacy and ('settle:' .. tostring(periodNo))
        or ('settle-quarter:' .. tostring(periodNo))
    local cycleNoForLedger = legacy and periodNo or nonNegative(opts.cycleNo or periodNo)

    -- 起跑金已经发过（上一轮崩溃在 applied 标记之前）时，金库已经是最终态：
    -- 再跑 ApplySettlement 会把起跑金重新清零，而 Deposit 又被唯一 ref 挡住 ——
    -- 所以用流水存在性判断「这一步是否已完成」，而不是无条件重放。
    local starterRef = 'quarter-starter:' .. tostring(periodNo)
    local starterDone = false
    if not legacy then
        local paidRow, paidErr = Db.Single(
            'SELECT id FROM org_ledger WHERE org_id = ? AND ref = ? LIMIT 1',
            { orgId, starterRef })
        if paidErr then return false, 'db_error' end
        starterDone = paidRow ~= nil
    end

    if not starterDone then
        local applied, treasuryErr = Treasury.ApplySettlement(orgId, {
            prestigeAfter = nonNegative(result.prestige_after),
            cycleNo = cycleNoForLedger,
            clearedBalance = nonNegative(result.balance_cleared),
            ref = ref,
        })
        if not applied then return false, treasuryErr or 'db_error' end
    end

    -- ② 产业层删除：显式两张表；个人层不在本文件的任何 SQL 里。
    local facilityDeleted, facilityErr = Db.Update(
        'DELETE FROM industry_facility WHERE org_id = ?', { orgId })
    if facilityErr then return false, 'db_error' end

    -- 旧单时钟只删本周期流水；季度软重置清掉该组织全部卖单。
    local salesDeleted, salesErr
    if legacy then
        salesDeleted, salesErr = Db.Update(
            'DELETE FROM industry_sales WHERE org_id = ? AND cycle_no = ?',
            { orgId, periodNo })
    else
        salesDeleted, salesErr = Db.Update(
            'DELETE FROM industry_sales WHERE org_id = ?', { orgId })
    end
    if salesErr then return false, 'db_error' end

    -- ③ 季度起跑金（旧单时钟不发，避免改变历史结算口径）。
    local starterGranted = 0
    if not legacy and not starterDone then
        starterGranted = starterGrantFor(result)
        if starterGranted > 0 then
            local paid, payErr = Treasury.Deposit(orgId, starterGranted, 'quarter-starter', {
                ref = starterRef,
                cycleNo = cycleNoForLedger,
            })
            -- duplicate_ref = 上一轮已经发过（崩溃恢复），不是失败。
            if not paid and payErr ~= 'duplicate_ref' then
                return false, payErr or 'db_error'
            end
        end
    end

    -- ④ 标记完成。affected = 0 也视为完成（另一条路径先标了，prestige 仍是绝对值）。
    local _, markErr = Db.Update(
        'UPDATE industry_cycle_results SET applied = 1, applied_at = current_timestamp '
            .. 'WHERE org_id = ? AND ' .. keyColumn(legacy) .. ' = ? AND applied = 0',
        { orgId, periodNo })
    if markErr then return false, 'db_error' end

    return true, nil, {
        org_id = orgId,
        skipped = false,
        facility_deleted = facilityDeleted or 0,
        sales_deleted = salesDeleted or 0,
        prestige_awarded = nonNegative(result.prestige_awarded),
        revenue = nonNegative(result.revenue),
        produced_units = nonNegative(result.produced_units),
        starter_granted = starterGranted,
    }
end

local function addCount(summary, key, value)
    summary[key] = (summary[key] or 0) + nonNegative(value)
end

--- 当前权威状态（两时钟判定用）。
---@return table|nil state, string|nil errcode
local function currentState()
    if type(IndustryCycle) ~= 'table' or not IndustryCycle.Current then
        return nil, 'cycle_unavailable'
    end
    return IndustryCycle.Current()
end

--- legacy 判定：显式 opts.legacy 优先；否则看当前状态是否已接两时钟。
--- 读不到状态时返回 nil + errcode（调用方 fail closed，不按 legacy 猜）。
---@return boolean|nil legacy, string|nil errcode
local function resolveLegacy(opts)
    if opts and opts.legacy ~= nil then return opts.legacy == true, nil end
    local state, err = currentState()
    if not state then return nil, err or 'db_error' end
    return not state.two_clock, nil
end

local function periodLabel(legacy)
    return legacy and 'cycle' or 'quarter'
end

--- dry-run：只读，打印「将删 N 行 / 将写 M 行」，不写库。
---@param periodNo number|nil
---@param opts table|nil
---@return table|nil report, string|nil errcode
function IndustrySettlement.Preview(periodNo, opts)
    opts = opts or {}
    local legacy, legacyErr = resolveLegacy(opts)
    if legacy == nil then return nil, legacyErr end
    local period = toInt(periodNo)
    if not period or period < 0 or period > MAX_CYCLE then return nil, 'bad_period' end

    -- 命令层在两时钟下传的是当前周号；预览必须落到季度号。
    local state = currentState()
    if not legacy and state and state.two_clock then period = state.quarter_no end

    local limit = math.max(1, math.floor(tonumber(cycleConfig().MaxOrgsPerSettle) or 500))
    local orgIds, orgErr = listOrgs(limit)
    if not orgIds then return nil, orgErr end

    local report = {
        cycle_no = period,
        quarter_no = not legacy and period or nil,
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
        local existing = readResult(orgId, period, legacy)
        if existing and nonNegative(existing.applied) == 1 then
            -- 已结算：不会写结果，也不会再删这个组织的设施。
        elseif existing then
            report.resume = report.resume + 1
            report.prestige_awarded = report.prestige_awarded
                + nonNegative(existing.prestige_awarded)
        else
            local revenue
            if legacy then
                revenue = readRevenue(orgId, period) or 0
            else
                revenue = readQuarterRevenue(orgId) or 0
            end
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

    if legacy then
        report.sales_rows = scalarCount(
            'SELECT COUNT(*) AS n FROM industry_sales WHERE cycle_no = ? LIMIT 1',
            { period })
        report.demand_rows = scalarCount(
            'SELECT COUNT(*) AS n FROM industry_demand WHERE cycle_no = ? LIMIT 1',
            { period })
    else
        report.sales_rows = scalarCount(
            'SELECT COUNT(*) AS n FROM industry_sales LIMIT 1', {})
        report.demand_rows = scalarCount(
            'SELECT COUNT(*) AS n FROM industry_demand LIMIT 1', {})
    end

    print(('[custom-industry] settlement dry-run %s=%d: orgs=%d results=%d resume=%d '
        .. 'facility_rows=%d sales_rows=%d demand_rows=%d treasury_rows=%d '
        .. 'balance=%d prestige=%d'):format(
        periodLabel(legacy), report.cycle_no, report.orgs, report.results, report.resume,
        report.facility_rows, report.sales_rows, report.demand_rows,
        report.treasury_rows, report.treasury_balance, report.prestige_awarded))
    return report, nil
end

local settling = false

--- 真结算（统一入口）。重复调用由水位 / UNIQUE(org_id, quarter_no) / applied 挡住。
---@param periodNo number|nil
---@param opts table|nil { trigger, dryRun, legacy, cycleNo }
---@return boolean ok, string|nil errcode, table|nil summary
function IndustrySettlement.SettleQuarter(periodNo, opts)
    -- 兼容 §2 的签名 SettleQuarter(quarterNo, now)：第二参是数字时当成时间戳。
    if type(opts) == 'number' then opts = { now = opts } end
    opts = opts or {}
    local legacy, legacyErr = resolveLegacy(opts)
    if legacy == nil then return false, legacyErr end
    local period = toInt(periodNo)
    if not period or period < 0 or period > MAX_CYCLE then return false, 'bad_period' end

    if opts.dryRun == true then
        local report, err = IndustrySettlement.Preview(period, opts)
        if not report then return false, err end
        return true, nil, report
    end

    if settling then return false, 'busy' end
    settling = true

    local normalized = {}
    for key, value in pairs(opts) do normalized[key] = value end
    normalized.legacy = legacy

    local called, ok, err, summary = pcall(function()
        return IndustrySettlement.SettleQuarterLocked(period, normalized)
    end)
    settling = false

    if not called then
        print(('[custom-industry] CRITICAL settlement crashed %s=%d: %s'):format(
            periodLabel(legacy), period, tostring(ok)))
        return false, 'db_error'
    end
    return ok, err, summary
end

--- 旧入口：S6/S7 的「周期结算」。
--- 两时钟状态下它就是季度结算（命令层传进来的周号会被换算成当前季度号）；
--- 旧单时钟状态下强制 legacy=true，行为与 #409 之前逐字节一致。
---@param cycleNo number|nil
---@param opts table|nil
---@return boolean ok, string|nil errcode, table|nil summary
function IndustrySettlement.SettleCycle(cycleNo, opts)
    opts = opts or {}
    local state, stateErr = currentState()
    if not state then return false, stateErr or 'db_error' end
    if state.two_clock then
        return IndustrySettlement.SettleQuarter(state.quarter_no, opts)
    end
    local legacyOpts = {}
    for key, value in pairs(opts) do legacyOpts[key] = value end
    legacyOpts.legacy = true
    return IndustrySettlement.SettleQuarter(cycleNo, legacyOpts)
end

--- SettleQuarter 的实体（调用方必须已经拿到 settling 锁）。
---@param period number
---@param opts table
---@return boolean ok, string|nil errcode, table|nil summary
function IndustrySettlement.SettleQuarterLocked(period, opts)
    local legacy = opts.legacy == true
    -- 已完成水位：同一周期/季度第二次结算直接拒绝（不重复发 prestige / 起跑金）。
    local stateRow, stateErr = Db.Single(
        'SELECT settled_cycle_no FROM industry_state WHERE id = 1 LIMIT 1', {})
    if stateErr then return false, 'db_error' end
    if stateRow and math.floor(tonumber(stateRow.settled_cycle_no) or 0) >= period then
        local summary = {
            cycle_no = period,
            quarter_no = not legacy and period or nil,
            already_settled = true,
            orgs = 0,
            settled = 0,
            skipped = 0,
            failed = 0,
            facility_deleted = 0,
            sales_deleted = 0,
            demand_deleted = 0,
            prestige_awarded = 0,
            starter_granted = 0,
            revenue = 0,
        }
        return true, nil, summary
    end

    local limit = math.max(1, math.floor(tonumber(cycleConfig().MaxOrgsPerSettle) or 500))
    local orgIds, orgErr = listOrgs(limit)
    if not orgIds then return false, orgErr end

    local summary = {
        cycle_no = period,
        quarter_no = not legacy and period or nil,
        orgs = #orgIds,
        settled = 0,
        skipped = 0,
        failed = 0,
        facility_deleted = 0,
        sales_deleted = 0,
        demand_deleted = 0,
        prestige_awarded = 0,
        starter_granted = 0,
        revenue = 0,
    }
    local firstErr

    for _, orgId in ipairs(orgIds) do
        local ok, err, info = settleOrg(orgId, period, opts)
        if not ok then
            summary.failed = summary.failed + 1
            firstErr = firstErr or err or 'db_error'
            print(('[custom-industry] settlement failed org=%s %s=%d err=%s'):format(
                tostring(orgId), periodLabel(legacy), period, tostring(err or 'db_error')))
        elseif info and info.skipped then
            summary.skipped = summary.skipped + 1
        else
            summary.settled = summary.settled + 1
            addCount(summary, 'facility_deleted', info and info.facility_deleted)
            addCount(summary, 'sales_deleted', info and info.sales_deleted)
            addCount(summary, 'prestige_awarded', info and info.prestige_awarded)
            addCount(summary, 'starter_granted', info and info.starter_granted)
            addCount(summary, 'revenue', info and info.revenue)
        end
    end

    -- 有组织失败：保留本周期数据，下一次 tick 继续；已成功的组织靠 applied=1 跳过。
    if firstErr then
        return false, firstErr, summary
    end

    -- 配额行只在本周期/季度结算完成后删一次；DELETE 幂等。
    local demandDeleted, demandErr
    if legacy then
        demandDeleted, demandErr = Db.Update(
            'DELETE FROM industry_demand WHERE cycle_no = ?', { period })
    else
        -- 季度 = period 对应的 13 周（全局周号是 1 基）。
        local weeks = 13
        if type(IndustryCycle) == 'table' and IndustryCycle.WeeksPerQuarter then
            weeks = IndustryCycle.WeeksPerQuarter()
        end
        local fromWeek = (period - 1) * weeks + 1
        local toWeek = period * weeks
        demandDeleted, demandErr = Db.Update(
            'DELETE FROM industry_demand WHERE cycle_no BETWEEN ? AND ?',
            { fromWeek, toWeek })
    end
    if demandErr then return false, 'db_error', summary end
    summary.demand_deleted = summary.demand_deleted + nonNegative(demandDeleted)

    -- settled_cycle_no 只增不减；affected = 0 表示已经结算过（重复调用被拒）。
    Db.Update(
        'UPDATE industry_state SET settled_cycle_no = ? '
            .. 'WHERE id = 1 AND settled_cycle_no < ?',
        { period, period })

    if IndustryAudit and IndustryAudit.Write then
        local trigger = tostring(opts.trigger or 'manual'):gsub('[^%w_%-]', '_')
        if legacy then
            IndustryAudit.Write('*', nil, 'cycle.settle', ('{"cycle_no":%d,"trigger":"%s",'
                .. '"orgs":%d,"settled":%d,"skipped":%d,"facility_deleted":%d,'
                .. '"sales_deleted":%d,"demand_deleted":%d,"prestige_awarded":%d}'):format(
                period, trigger,
                summary.orgs, summary.settled, summary.skipped,
                summary.facility_deleted, summary.sales_deleted,
                summary.demand_deleted, summary.prestige_awarded))
        else
            IndustryAudit.Write('*', nil, 'cycle.settle', ('{"quarter_no":%d,"trigger":"%s",'
                .. '"orgs":%d,"settled":%d,"skipped":%d,"facility_deleted":%d,'
                .. '"sales_deleted":%d,"demand_deleted":%d,"prestige_awarded":%d,'
                .. '"starter_granted":%d}'):format(
                period, trigger,
                summary.orgs, summary.settled, summary.skipped,
                summary.facility_deleted, summary.sales_deleted,
                summary.demand_deleted, summary.prestige_awarded,
                summary.starter_granted))
        end
    end

    -- 公告失败不阻断结算：结果表已经是权威事实，下一 tick 会补发。
    if IndustryAnnounce and IndustryAnnounce.Result then
        IndustryAnnounce.Result(period, { twoClock = not legacy })
    end

    print(('[custom-industry] settlement done %s=%d orgs=%d settled=%d skipped=%d '
        .. 'facility=%d sales=%d demand=%d prestige=+%d starter=%d'):format(
        periodLabel(legacy), period, summary.orgs, summary.settled, summary.skipped,
        summary.facility_deleted, summary.sales_deleted,
        summary.demand_deleted, summary.prestige_awarded, summary.starter_granted))
    return true, nil, summary
end

--- 兼容旧调用方（tools / 测试）：等价于 SettleQuarter 的实体，legacy 由状态决定。
--- 两时钟下旧调用方传的是周号，这里同样换算成当前季度号（与 SettleCycle 一致）。
---@param cycleNo number
---@param opts table
---@return boolean ok, string|nil errcode, table|nil summary
function IndustrySettlement.SettleCycleLocked(cycleNo, opts)
    opts = opts or {}
    local state, stateErr = currentState()
    if not state then return false, stateErr or 'db_error' end
    if state.two_clock then
        local quarterOpts = {}
        for key, value in pairs(opts) do quarterOpts[key] = value end
        quarterOpts.legacy = false
        return IndustrySettlement.SettleQuarterLocked(state.quarter_no, quarterOpts)
    end
    if opts.legacy == nil then opts.legacy = true end
    return IndustrySettlement.SettleQuarterLocked(cycleNo, opts)
end
