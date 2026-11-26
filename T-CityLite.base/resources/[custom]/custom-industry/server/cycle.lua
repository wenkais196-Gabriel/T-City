-- server/cycle.lua — S6 周期状态机（权威在 industry_state 单行表）。
--
-- 四条铁律（写错任何一条，线上线下都会出现跨周期资产）：
--
-- 1. **状态不住内存、也不住 world_state**：每次读都查 `industry_state`；
--    冷启动 / 重启后从 DB 续跑（迁移种子行是 'uninitialized'，首次启动才写时间边界）。
-- 2. **推进许可只有一条**：`UPDATE ... WHERE cycle_no/phase/phase_ends_at <= ?` 的
--    `affectedRows == 1`。副作用（配额种子、审计、公告）只在拿到 1 之后执行。
-- 3. **一次 tick 只推进一格**：停机跨多个边界时，下一次 tick 再从新的 phase_ends_at
--    继续补推；不跳段、也不在一次 tick 里连推四格。
-- 4. **结算先于跨周期推进**：衰退结束时先跑 S7，`settled_cycle_no` 没到位就不推进。
--
-- 时间：DB 里存 datetime，读写两侧都用 UNIX_TIMESTAMP() / FROM_UNIXTIME(?)；
-- Lua 只处理 epoch 秒（os.time 口径）。

IndustryCycle = {}

local MAX_ORG_CYCLE = 1000000

local function cycleConfig()
    return Config.Industry.Cycle or {}
end

local function phaseConfig(phase)
    local phases = cycleConfig().Phases
    if type(phases) ~= 'table' then return nil end
    local cfg = phases[phase]
    if type(cfg) ~= 'table' then return nil end
    return cfg
end

function IndustryCycle.PhaseOrder()
    local order = cycleConfig().Order
    if type(order) ~= 'table' then return {} end
    return order
end

--- 阶段真实秒数：PhaseSeconds 覆盖优先，否则 design_days / Scale。
---@param phase string
---@return number|nil
function IndustryCycle.PhaseSeconds(phase)
    local cfg = phaseConfig(phase)
    if not cfg then return nil end

    local cycle = cycleConfig()
    local override = tonumber(cycle.PhaseSeconds) or 0
    if override > 0 then return math.max(1, math.floor(override)) end

    -- Scale 是「设计秒数 ÷ 真实秒数」；默认 1 即原速。
    local scale = tonumber(cycle.Scale) or 1
    if scale <= 0 then scale = 1 end
    local days = tonumber(cfg.days) or 1
    return math.max(1, math.floor(days * 86400 / scale))
end

--- 本 **周期** 的结束时间（衰退阶段结束），不是当前阶段的结束时间。
--- 公告提前量是「结算前 7 天」，所以必须拿周期末端做比较。
---@param state table
---@return number
function IndustryCycle.CycleEndsAt(state)
    if type(state) ~= 'table' then return 0 end
    local endEpoch = tonumber(state.ends_epoch) or 0
    if state.legacy then return endEpoch end

    local order = IndustryCycle.PhaseOrder()
    local index
    for position = 1, #order do
        if order[position] == state.phase then index = position break end
    end
    if not index then return endEpoch end

    for position = index + 1, #order do
        endEpoch = endEpoch + (IndustryCycle.PhaseSeconds(order[position]) or 0)
    end
    return endEpoch
end

--- 结算前公告提前量。压缩验收时自动取 PhaseSeconds，默认 7 天。
---@return number
function IndustryCycle.WarningSeconds()
    local cycle = cycleConfig()
    local explicit = tonumber(cycle.WarningSeconds) or 0
    if explicit > 0 then return math.floor(explicit) end

    local override = tonumber(cycle.PhaseSeconds) or 0
    if override > 0 then return math.max(1, math.floor(override)) end

    local scale = tonumber(cycle.Scale) or 1
    if scale <= 0 then scale = 1 end
    return math.max(1, math.floor(7 * 86400 / scale))
end

---@param phase string
---@return string|nil
function IndustryCycle.NextPhase(phase)
    local order = IndustryCycle.PhaseOrder()
    for index = 1, #order do
        if order[index] == phase then return order[index + 1] end
    end
    return nil
end

--- S4 静态占位（cycle 0 / static）的读数。既覆盖「表里还没有行」，
--- 也覆盖迁移刚落地、Lua 还没 Initialize 的窗口；倍率恒为 1、可购置。
local function fallbackState()
    local sales = Config.Industry.Sales or {}
    return {
        cycle_no = math.floor(tonumber(sales.CycleNo) or 0),
        phase = tostring(sales.Phase or 'static'),
        label = '静态',
        started_epoch = 0,
        ends_epoch = 0,
        warning_done = false,
        settled_cycle_no = 0,
        result_announced_cycle = 0,
        production = 1,
        price = 1,
        quota = 1,
        purchasable = true,
        legacy = true,
    }
end

local STATE_SELECT =
    'SELECT id, cycle_no, phase, '
        .. 'UNIX_TIMESTAMP(phase_started_at) AS started_epoch, '
        .. 'UNIX_TIMESTAMP(phase_ends_at) AS ends_epoch, '
        .. '(warning_announced_at IS NOT NULL) AS warning_done, '
        .. 'settled_cycle_no, result_announced_cycle '
        .. 'FROM industry_state WHERE id = 1 LIMIT 1'

--- 当前权威周期状态。读库失败返回 nil, 'db_error'（**不**回落成倍率 1：
--- 读不到阶段时让调用方 fail closed，而不是按扩张期发钱）。
---@return table|nil state, string|nil errcode
function IndustryCycle.Current()
    local row, err = Db.Single(STATE_SELECT, {})
    if err then return nil, 'db_error' end
    if not row then return fallbackState(), nil end

    local phase = tostring(row.phase or '')
    if phase == 'uninitialized' or phase == 'static' then
        -- 迁移种子行 / 旧占位：倍率仍按 1 处理，等 Initialize 写入真实阶段。
        local state = fallbackState()
        state.cycle_no = math.max(0, math.floor(tonumber(row.cycle_no) or state.cycle_no))
        state.uninitialized = phase == 'uninitialized'
        return state, nil
    end

    local cfg = phaseConfig(phase)
    if not cfg then return nil, 'bad_phase' end

    local cycleNo = tonumber(row.cycle_no)
    local started = tonumber(row.started_epoch)
    local ends = tonumber(row.ends_epoch)
    if not cycleNo or not started or not ends then return nil, 'db_error' end

    return {
        cycle_no = math.floor(cycleNo),
        phase = phase,
        label = tostring(cfg.label or phase),
        started_epoch = started,
        ends_epoch = ends,
        -- 用 boolean 列而不是 UNIX_TIMESTAMP(NULL)：不同驱动对 NULL 的回包形状不一致。
        warning_done = row.warning_done == true
            or tonumber(row.warning_done) == 1
            or row.warning_done == '1',
        settled_cycle_no = math.max(0, math.floor(tonumber(row.settled_cycle_no) or 0)),
        result_announced_cycle = math.max(
            0, math.floor(tonumber(row.result_announced_cycle) or 0)),
        production = tonumber(cfg.production) or 1,
        price = tonumber(cfg.price) or 1,
        quota = tonumber(cfg.quota) or 1,
        purchasable = cfg.purchasable == true,
        legacy = false,
    }, nil
end

--- 首次启动：把种子行（或缺失行）写成 cycle 1 / expansion。
--- 已有真实阶段的库**一律不动** —— 重启必须从 DB 续跑。
---@param now number|nil epoch 秒
---@return boolean ok, string|nil errcode
function IndustryCycle.Initialize(now)
    now = math.floor(tonumber(now) or os.time())
    local state, err = IndustryCycle.Current()
    if not state then return false, err end
    if not state.legacy then return true, nil end

    local duration = IndustryCycle.PhaseSeconds('expansion')
    if not duration then return false, 'bad_phase' end
    local ends = now + duration

    -- 并发启动只有一个 INSERT 能成功；PK id = 1 是锁。
    Db.Insert(
        'INSERT IGNORE INTO industry_state (id, cycle_no, phase, '
            .. 'phase_started_at, phase_ends_at) '
            .. 'VALUES (1, 1, ?, FROM_UNIXTIME(?), FROM_UNIXTIME(?))',
        { 'expansion', now, ends })

    -- 只改写占位阶段；真实阶段（哪怕刚好被别人写了）保持原样。
    local affected, updateErr = Db.Update(
        'UPDATE industry_state SET cycle_no = 1, phase = ?, '
            .. 'phase_started_at = FROM_UNIXTIME(?), phase_ends_at = FROM_UNIXTIME(?), '
            .. 'warning_announced_at = NULL, settled_cycle_no = 0, '
            .. 'result_announced_cycle = 0 '
            .. 'WHERE id = 1 AND phase IN (?, ?)',
        { 'expansion', now, ends, 'uninitialized', 'static' })
    if updateErr then return false, 'db_error' end

    local fresh = IndustryCycle.Current()
    if not fresh or fresh.legacy then
        -- 迁移没跑 / 写不进去：不要假装初始化成功，Tick 会持续报错。
        return false, 'db_error'
    end
    return true, nil
end

--- 控制台强制换阶段（唯一的人为手段）。把边界重置为 now → now + duration。
---@param phase string
---@param cycleNo number|nil nil = 保持当前周期
---@param now number|nil
---@return boolean ok, string|nil errcode, table|nil info
function IndustryCycle.SetPhase(phase, cycleNo, now)
    if not phaseConfig(phase) then return false, 'bad_phase' end
    now = math.floor(tonumber(now) or os.time())

    local current, err = IndustryCycle.Current()
    if not current then return false, err end

    local target = tonumber(cycleNo) or current.cycle_no
    target = math.floor(target)
    if target < 0 or target > MAX_ORG_CYCLE then return false, 'bad_cycle' end

    local duration = IndustryCycle.PhaseSeconds(phase)
    if not duration then return false, 'bad_phase' end
    local ends = now + duration

    -- 控制台换阶段不重置 warning 水位：同一周期已经公告过就不再喊第二遍。
    local affected, updateErr = Db.Update(
        'UPDATE industry_state SET cycle_no = ?, phase = ?, '
            .. 'phase_started_at = FROM_UNIXTIME(?), phase_ends_at = FROM_UNIXTIME(?) '
            .. 'WHERE id = 1',
        { target, phase, now, ends })
    if updateErr then return false, 'db_error' end
    if affected ~= 1 then return false, 'no_state' end

    -- 新阶段要有自己的配额行；种子函数是幂等的。
    if IndustrySales and IndustrySales.EnsureSeed then IndustrySales.EnsureSeed() end
    return true, nil, {
        cycle_no = target,
        phase = phase,
        started_epoch = now,
        ends_epoch = ends,
    }
end

--- 只有可购置阶段允许建厂 / 雇工位。读库失败时 fail closed。
---@return boolean|nil open, string|nil errcode
function IndustryCycle.CanPurchase()
    local state, err = IndustryCycle.Current()
    if not state then return nil, err end
    return state.purchasable == true, nil
end

local function auditAdvance(fromPhase, toPhase, cycleNo, startEpoch, endEpoch)
    if not IndustryAudit or not IndustryAudit.Write then return end
    IndustryAudit.Write('*', nil, 'cycle.advance', ('{"from":"%s","to":"%s",'
        .. '"cycle_no":%d,"started_at":%d,"ends_at":%d}'):format(
        tostring(fromPhase), tostring(toPhase), cycleNo, startEpoch, endEpoch))
end

local lastWarnAttempt = 0
local lastResultAttempt = 0

local function retrySeconds()
    return math.max(1, math.floor(tonumber(cycleConfig().RetryLogSeconds) or 300))
end

--- 结算前公告：**每个周期只发一次**（告警的是周期末端，不是阶段末端）。
--- 成功发布才写 warning_announced_at；失败下一 tick 重试。
local function maybeWarn(state, now)
    if state.warning_done then return end
    local cycleEndsAt = IndustryCycle.CycleEndsAt(state)
    local warningAt = cycleEndsAt - IndustryCycle.WarningSeconds()
    if now < warningAt then return end
    if now - lastWarnAttempt < retrySeconds() then return end
    lastWarnAttempt = now

    if not IndustryAnnounce or not IndustryAnnounce.Warning then return end
    if not IndustryAnnounce.Warning(state.cycle_no, cycleEndsAt - now) then return end

    Db.Update(
        'UPDATE industry_state SET warning_announced_at = FROM_UNIXTIME(?) '
            .. 'WHERE id = 1 AND cycle_no = ? '
            .. 'AND warning_announced_at IS NULL',
        { now, state.cycle_no })
end

--- 结算成功但公告失败时，后续 tick 补发（结果表已是幂等事实，公告只是通知）。
local function maybeResultAnnounce(state, now)
    if state.settled_cycle_no <= state.result_announced_cycle then return end
    if now - lastResultAttempt < retrySeconds() then return end
    lastResultAttempt = now
    if not IndustryAnnounce or not IndustryAnnounce.Result then return end
    IndustryAnnounce.Result(state.settled_cycle_no)
end

local ticking = false

--- 单次推进。一次 tick 最多推进一个阶段；跨边界停机由后续 tick 依次补推。
---@param now number|nil
---@return boolean ok, string|nil errcode, table|nil info
function IndustryCycle.Tick(now)
    now = math.floor(tonumber(now) or os.time())
    if ticking then return false, 'busy' end
    ticking = true
    local called, ok, err, info = pcall(function() return IndustryCycle.TickOnce(now) end)
    ticking = false
    if not called then
        print(('[custom-industry] CRITICAL cycle tick crashed: %s'):format(tostring(ok)))
        return false, 'db_error'
    end
    return ok, err, info
end

--- Tick 的实体（单独暴露便于测试直接构造坏形状；正常调用走 Tick 的 pcall）。
---@param now number
---@return boolean ok, string|nil errcode, table|nil info
function IndustryCycle.TickOnce(now)
    local state, err = IndustryCycle.Current()
    if not state then return false, err end

    if state.legacy then
        local ok, initErr = IndustryCycle.Initialize(now)
        if not ok then return false, initErr end
        return true, nil, { initialized = true }
    end

    maybeResultAnnounce(state, now)
    maybeWarn(state, now)

    if now < state.ends_epoch then
        return true, nil, { advanced = false, phase = state.phase }
    end

    -- 衰退结束：先结算，settled_cycle_no 没到就不允许跨周期推进。
    if state.phase == 'recession' and state.settled_cycle_no < state.cycle_no then
        if type(IndustrySettlement) ~= 'table' or not IndustrySettlement.SettleCycle then
            return false, 'settlement_unavailable'
        end
        local settled, settleErr = IndustrySettlement.SettleCycle(
            state.cycle_no, { trigger = 'cycle_end' })
        if not settled then return false, settleErr or 'settlement_failed' end
    end

    local nextPhase = IndustryCycle.NextPhase(state.phase)
    local nextCycle = state.cycle_no
    if not nextPhase then
        local order = IndustryCycle.PhaseOrder()
        nextPhase = order[1]
        nextCycle = state.cycle_no + 1
    end
    if not nextPhase then return false, 'bad_phase' end

    local duration = IndustryCycle.PhaseSeconds(nextPhase)
    if not duration then return false, 'bad_phase' end

    -- 新阶段从旧阶段的**计划结束时间**开始：停机越久，补推越快追平绝对日程。
    local startEpoch = state.ends_epoch
    local endEpoch = startEpoch + duration

    local affected, updateErr
    if state.phase == 'recession' then
        affected, updateErr = Db.Update(
            'UPDATE industry_state SET cycle_no = ?, phase = ?, '
                .. 'phase_started_at = FROM_UNIXTIME(?), phase_ends_at = FROM_UNIXTIME(?), '
                .. 'warning_announced_at = NULL '
                .. 'WHERE id = 1 AND cycle_no = ? AND phase = ? '
                .. 'AND phase_ends_at <= FROM_UNIXTIME(?) AND settled_cycle_no >= ?',
            {
                nextCycle, nextPhase, startEpoch, endEpoch,
                state.cycle_no, state.phase, now, state.cycle_no,
            })
    else
        -- 同一周期内换阶段：**不清** warning 水位（周期只公告一次）。
        affected, updateErr = Db.Update(
            'UPDATE industry_state SET cycle_no = ?, phase = ?, '
                .. 'phase_started_at = FROM_UNIXTIME(?), phase_ends_at = FROM_UNIXTIME(?) '
                .. 'WHERE id = 1 AND cycle_no = ? AND phase = ? '
                .. 'AND phase_ends_at <= FROM_UNIXTIME(?)',
            {
                nextCycle, nextPhase, startEpoch, endEpoch,
                state.cycle_no, state.phase, now,
            })
    end
    if updateErr then return false, 'db_error' end
    if affected ~= 1 then return false, 'conflict' end

    -- 副作用只在拿到推进许可之后执行。
    if nextCycle ~= state.cycle_no then
        -- 新一轮：公告重试节流清零，避免压缩周期里沿用上一轮的 300 秒冷却。
        lastWarnAttempt = 0
        lastResultAttempt = 0
    end
    if IndustrySales and IndustrySales.EnsureSeed then IndustrySales.EnsureSeed() end
    auditAdvance(state.phase, nextPhase, nextCycle, startEpoch, endEpoch)

    return true, nil, {
        advanced = true,
        from = state.phase,
        to = nextPhase,
        cycle_no = nextCycle,
        started_epoch = startEpoch,
        ends_epoch = endEpoch,
    }
end

--- main.lua 在产业开启时调用一次：只做初始化，不新建线程
--- （周期 tick 挂到 S3 已有的 30 秒生产线程上，见 production.lua 的 onTick）。
---@return boolean ok, string|nil errcode
function IndustryCycle.Start()
    local ok, err = IndustryCycle.Initialize(os.time())
    if not ok then
        print(('[custom-industry] cycle init failed: %s'):format(tostring(err)))
    end
    return ok, err
end
