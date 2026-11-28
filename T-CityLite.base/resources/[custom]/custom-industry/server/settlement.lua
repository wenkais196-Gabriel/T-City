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

-- ── 季度分配（P2 #410）──────────────────────────────────────────────
-- 本仓库没有 `org_members` 表（全仓 grep 0 命中）。当前成员名单取 QBCore 在线
-- 玩家，判定与 announce.lua 的推送名单完全一致（IndustryAccess.OrgMembership）；
-- 离线成员不在本轮分配范围 —— 分配只走 Player.Functions.AddMoney（个人层只写
-- bank），离线对象要落盘会重写整行，越过「其它字段一个字节都不能动」的边界。
-- 没有在线 Boss 时不分配：余额仍按旧口径由 ApplySettlement 清零。
--
-- 比例：Boss 组拿 total × QuarterBossShare，其余成员平分剩余；没有非 Boss 成员
-- 时（单人组织）Boss 拿 100%。除不尽的余数给排序后的第一个 Boss，保证
-- 「分配总额 == 剩余金库」，不会把零头留在账上。
local QBCore

local function core()
    if QBCore then return QBCore end
    local ok, value = pcall(function() return exports['qb-core']:GetCoreObject() end)
    if ok and type(value) == 'table' then QBCore = value end
    return QBCore
end

local DISTRIBUTE_REASON = 'industry-quarter-share'

--- 在线且属于该组织的玩家。失败返回 nil（调用方按「本轮不分配」处理）。
---@param orgId string
---@return table|nil members sorted by citizenid
local function collectMembers(orgId)
    if type(IndustryAccess) ~= 'table' or not IndustryAccess.OrgMembership then return nil end
    local coreObject = core()
    if not coreObject then return nil end
    local functions = coreObject.Functions
    if type(functions) ~= 'table' then return nil end

    local called, players = pcall(function() return functions.GetQBPlayers() end)
    if not called or type(players) ~= 'table' then return nil end

    local members = {}
    for _, Player in pairs(players) do
        local data = type(Player) == 'table' and Player.PlayerData or nil
        local cid = type(data) == 'table' and data.citizenid or nil
        if type(cid) == 'string' and cid ~= '' then
            local member, grade = IndustryAccess.OrgMembership(Player, orgId)
            if member then
                members[#members + 1] = {
                    player = Player,
                    citizenid = cid,
                    grade = tonumber(grade) or 0,
                }
            end
        end
    end
    table.sort(members, function(a, b) return a.citizenid < b.citizenid end)
    return members
end

--- 把总额拆成每个在线成员的份额。
---@param total number
---@param members table
---@param bossShare number 0..1
---@return table|nil shares, table|nil info
local function planShares(total, members, bossShare)
    local bossGrade = tonumber(Config.Industry.BossGrade) or 4
    local bosses, regular = {}, {}
    for _, member in ipairs(members) do
        if member.grade >= bossGrade then
            bosses[#bosses + 1] = member
        else
            regular[#regular + 1] = member
        end
    end
    if #bosses == 0 then return nil end

    local memberEach = 0
    if #regular > 0 then
        memberEach = math.floor(total * (1 - bossShare) / #regular + 1e-9)
    end
    local bossTotal = total - memberEach * #regular
    local shares = {}
    local perBoss = math.floor(bossTotal / #bosses)
    local remainder = bossTotal - perBoss * #bosses
    for index, member in ipairs(bosses) do
        shares[#shares + 1] = {
            player = member.player,
            amount = perBoss + (index == 1 and remainder or 0),
        }
    end
    for _, member in ipairs(regular) do
        if memberEach > 0 then
            shares[#shares + 1] = { player = member.player, amount = memberEach }
        end
    end
    return shares, {
        boss_total = bossTotal,
        member_each = memberEach,
        boss_count = #bosses,
        member_count = #regular,
    }
end

---@return number paid, number failed
local function payoutShares(orgId, periodNo, shares)
    local paid, failed = 0, 0
    for _, share in ipairs(shares) do
        -- 分成到整美元后可能为 0（小金额/多人）：AddMoney 不接受 0，直接跳过。
        if share.amount > 0 then
            local ok, credited = pcall(function()
                return share.player.Functions.AddMoney('bank', share.amount, DISTRIBUTE_REASON)
            end)
            if ok and credited == true then
                paid = paid + share.amount
            else
                failed = failed + share.amount
                -- 日志不带 citizenid / 姓名：金额与组织足够定位。
                print(('[custom-industry] quarter share failed org=%s quarter=%d amount=%d'):format(
                    tostring(orgId), periodNo, share.amount))
            end
        end
    end
    return paid, failed
end

local function distributePayload(periodNo, total, info, paid, failed, resultCode)
    return ('{"quarter_no":%d,"total":%d,"boss_total":%d,"member_each":%d,'
        .. '"boss_count":%d,"member_count":%d,"paid":%d,"failed":%d,"result":"%s"}'):format(
        periodNo, total, info.boss_total, info.member_each,
        info.boss_count, info.member_count, paid, failed, resultCode)
end

--- 把 result.balance_cleared 从金库提出并按比例发给在线成员。
--- 幂等事实是 org_ledger 的 UNIQUE(org_id, ref)（ref = quarter-distribute:<季度>）：
--- 重试时看到这一行就不再发第二次（钱宁可少发也不发两遍）。
---@return table|nil info, string|nil errcode
local function distributeQuarter(orgId, periodNo, result, cycleNo)
    local shareRate = tonumber(Config.Industry.QuarterBossShare)
    if not shareRate or shareRate ~= shareRate or shareRate < 0 or shareRate > 1 then
        return nil
    end
    local total = nonNegative(result and result.balance_cleared)
    if total <= 0 then return nil end

    local members = collectMembers(orgId)
    if not members or #members == 0 then return nil end
    local shares, info = planShares(total, members, shareRate)
    if not shares then return nil end

    local ref = 'quarter-distribute:' .. tostring(periodNo)
    local existing, lookupErr = Db.Single(
        'SELECT id FROM org_ledger WHERE org_id = ? AND ref = ? LIMIT 1',
        { orgId, ref })
    if lookupErr then return nil, 'db_error' end
    if existing then
        print(('[custom-industry] quarter distribute already claimed org=%s quarter=%d total=%d'):format(
            tostring(orgId), periodNo, total))
        return { already = true, total = total, paid = 0, failed = 0, result = 'already' }
    end

    local withdrawn, withdrawErr = Treasury.Withdraw(orgId, total, 'quarter-distribute', {
        ref = ref,
        cycleNo = cycleNo,
    })
    if not withdrawn then
        if withdrawErr == 'duplicate_ref' then
            return { already = true, total = total, paid = 0, failed = 0, result = 'already' }
        end
        if withdrawErr == 'insufficient_funds' then
            -- 快照之后余额被提走：本轮不分配，交给 ApplySettlement 按旧口径清零。
            print(('[custom-industry] quarter distribute skipped org=%s quarter=%d: balance changed'):format(
                tostring(orgId), periodNo))
            return nil
        end
        return nil, withdrawErr or 'db_error'
    end

    local paid, failed = payoutShares(orgId, periodNo, shares)
    local resultCode = failed == 0 and 'ok' or (paid > 0 and 'partial' or 'failed')
    if IndustryAudit and IndustryAudit.Write then
        IndustryAudit.Write(orgId, nil, 'treasury.distribute',
            distributePayload(periodNo, total, info, paid, failed, resultCode))
    end
    return {
        total = total,
        paid = paid,
        failed = failed,
        result = resultCode,
        boss_total = info.boss_total,
        member_each = info.member_each,
        boss_count = info.boss_count,
        member_count = info.member_count,
    }
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

    -- 先分配、后清零：分配要真的从金库扣款（Treasury.Withdraw 的余额守卫），
    -- 清零则是绝对值幂等操作。分配失败时 settlement 停下重试；已扣过（唯一 ref）
    -- 的轮次不再发第二次。
    local distribution = nil
    if not legacy and not starterDone then
        local distributeErr
        distribution, distributeErr = distributeQuarter(orgId, periodNo, result, cycleNoForLedger)
        if distributeErr then return false, distributeErr end
    end
    local distributed = distribution and nonNegative(distribution.total) or 0

    if not starterDone then
        -- 已分配的金额已经以 quarter-distribute 流水离开金库，不能再写一次
        -- settlement-clear（否则同一笔钱在流水里出现两次）。
        local cleared = nonNegative(result.balance_cleared) - distributed
        if cleared < 0 then cleared = 0 end
        local applied, treasuryErr = Treasury.ApplySettlement(orgId, {
            prestigeAfter = nonNegative(result.prestige_after),
            cycleNo = cycleNoForLedger,
            clearedBalance = cleared,
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
        distributed = distributed,
        distribute_paid = distribution and nonNegative(distribution.paid) or 0,
        distribute_failed = distribution and nonNegative(distribution.failed) or 0,
        distribute_result = distribution and distribution.result or nil,
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
            distributed = 0,
            distribute_paid = 0,
            distribute_failed = 0,
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
        distributed = 0,
        distribute_paid = 0,
        distribute_failed = 0,
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
            addCount(summary, 'distributed', info and info.distributed)
            addCount(summary, 'distribute_paid', info and info.distribute_paid)
            addCount(summary, 'distribute_failed', info and info.distribute_failed)
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
                .. '"starter_granted":%d,"distributed":%d}'):format(
                period, trigger,
                summary.orgs, summary.settled, summary.skipped,
                summary.facility_deleted, summary.sales_deleted,
                summary.demand_deleted, summary.prestige_awarded,
                summary.starter_granted, summary.distributed))
        end
    end

    -- 公告失败不阻断结算：结果表已经是权威事实，下一 tick 会补发。
    if IndustryAnnounce and IndustryAnnounce.Result then
        IndustryAnnounce.Result(period, { twoClock = not legacy })
    end

    print(('[custom-industry] settlement done %s=%d orgs=%d settled=%d skipped=%d '
        .. 'facility=%d sales=%d demand=%d prestige=+%d starter=%d distributed=%d'):format(
        periodLabel(legacy), period, summary.orgs, summary.settled, summary.skipped,
        summary.facility_deleted, summary.sales_deleted,
        summary.demand_deleted, summary.prestige_awarded, summary.starter_granted,
        summary.distributed))
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
