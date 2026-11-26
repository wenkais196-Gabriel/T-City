-- server/production.lua — S3 惰性生产：设施库存按时间结算。
--
-- 本片只**物化**（进 industry_facility.stock），不**货币化**（不进金库/银行）。
-- 库存满了就冻结；结算本身不产生任何通知或回执，避免刷屏。
--
-- 铁律：
--   1. 只有一份结算逻辑：Compute 是纯函数，tick / 玩家上线 / 控制台入口
--      都调它（再往下都走 SettleFacility）。没有「离线专用公式」。
--   2. 客户端没有任何输入：公式只读 last_tick_at / workstations / stock / config。
--      本文件没有 net event，也不接受调用方传 dt 或产量。
--   3. 写库只走 Db.Update，且 last_tick_at 是 CAS：读到的旧值不再匹配就重读重算。
--      affectedRows 是唯一裁决依据，并发 tick / 上线不会双算。
--   4. produced_units 只增不减（S7 结算要读它）；S4 卖掉库存也不回退它。
--   5. 停机追赶：单次结算最多前进 max_catchup_seconds 秒；超出部分留给下一次
--      tick，不跳段、也不一次算完。真正的离线通胀闸是库存上限。

IndustryProduction = {}

local SECONDS_PER_HOUR = 3600
local MAX_SETTLE_ATTEMPTS = 3
local SETTLE_BATCH_LIMIT = 200

local validOrg = IndustryOrgId.IsValid -- 统一在 server/org_id.lua（S4 合并 4 份重复实现）

local function nonNegativeNumber(value, fallback)
    local number = tonumber(value)
    if not number or number ~= number or number < 0 then return fallback end -- NaN
    return number
end

local function nonNegativeInt(value, fallback)
    local number = nonNegativeNumber(value, fallback)
    return math.floor(number)
end

local function productionConfig()
    return Config.Industry.Production or {}
end

--- 纯函数：按时间差算出这次结算的产量与新的 last_tick_at。
---
--- 取整规则（写死在这里，单测逐条断言）：
---   expected = floor(workstations × unitsPerHour × multiplier × effectiveDt / 3600)
---   向下取整；不足 1 单位的时间不产出，且**不前进** last_tick_at，
---   留给下一次结算继续累计（否则 1 秒 tick + 低速率会永远 floor 成 0）。
---
--- 库存上限：
---   produced = min(expected, max(cap - stock, 0))
---   库存写满时，把这整段时间都前进掉 —— 满仓期间的时间不能在 S4 卖出后补算。
---
--- 停机追赶：
---   effectiveDt = min(max(now - lastTickAt, 0), maxCatchup)
---   单次 newLastTickAt - lastTickAt 永远 ≤ maxCatchup。
---
---@param opts table {
---   now:number, lastTickAt:number, workstations:integer, stock:integer,
---   cap:integer, unitsPerHour:number, multiplier:number, maxCatchup:integer
--- }
---@return table plan {
---   produced:integer, newLastTickAt:integer, dt:integer, effectiveDt:integer,
---   expected:integer, space:integer, blocked:string|nil, advancedSeconds:integer
--- }
function IndustryProduction.Compute(opts)
    opts = opts or {}

    local now = nonNegativeInt(opts.now, 0)
    -- 坏掉的 last_tick_at 按 now 处理（不产出），不能按 0 处理：那等于白送一段追赶。
    local lastTickAt = nonNegativeInt(opts.lastTickAt, now)
    local workstations = nonNegativeInt(opts.workstations, 0)
    local stock = nonNegativeInt(opts.stock, 0)
    local cap = nonNegativeInt(opts.cap, 0)
    local unitsPerHour = nonNegativeNumber(opts.unitsPerHour, 0)
    local multiplier = nonNegativeNumber(opts.multiplier, 0)
    local maxCatchup = nonNegativeInt(opts.maxCatchup, 0)

    local dt = now - lastTickAt
    if dt < 0 then dt = 0 end -- 服务器时钟回拨：不倒退 last_tick_at
    local effectiveDt = math.min(dt, maxCatchup)

    local space = cap - stock
    if space < 0 then space = 0 end

    local plan = {
        produced = 0,
        newLastTickAt = lastTickAt,
        dt = dt,
        effectiveDt = effectiveDt,
        expected = 0,
        space = space,
        blocked = nil,
        advancedSeconds = 0,
    }

    if effectiveDt <= 0 then
        plan.blocked = 'no_time'
        return plan
    end

    -- 不会产出、也不该积压时间的情况：整段时间前进掉（仍然 ≤ maxCatchup）。
    local function advanceWithoutProduction(reason)
        plan.blocked = reason
        plan.newLastTickAt = lastTickAt + effectiveDt
        plan.advancedSeconds = effectiveDt
        return plan
    end

    if cap <= 0 then return advanceWithoutProduction('cap_zero') end
    if workstations <= 0 then return advanceWithoutProduction('no_workstations') end
    if space <= 0 then return advanceWithoutProduction('stock_full') end

    local ratePerHour = workstations * unitsPerHour * multiplier
    if ratePerHour <= 0 then return advanceWithoutProduction('no_rate') end

    local expected = math.floor(ratePerHour * effectiveDt / SECONDS_PER_HOUR)
    plan.expected = expected
    if expected <= 0 then
        -- 不足一个单位：不前进 last_tick_at，时间继续累计。
        return plan
    end

    local produced = math.min(expected, space)
    plan.produced = produced

    if produced < expected then
        -- 库存写满：整段时间前进，避免满仓时间在 S4 卖出后补算。
        plan.blocked = 'stock_full'
        plan.newLastTickAt = lastTickAt + effectiveDt
        plan.advancedSeconds = effectiveDt
        return plan
    end

    -- 只前进「产出这些整数单位所需的时间」，不足一个单位的时间留在
    -- last_tick_at 里。这样 1 秒 tick + 12 单位/小时也不会永远产不出。
    local consumed = math.floor((produced * SECONDS_PER_HOUR) / ratePerHour)
    local advanced = math.min(consumed, effectiveDt)
    if advanced < 1 then advanced = effectiveDt end -- 高倍率下 1 秒产多单位
    plan.newLastTickAt = lastTickAt + advanced
    plan.advancedSeconds = advanced
    return plan
end

--- 读设施行。时间显式转成 epoch 秒，不依赖驱动对 timestamp 的字符串格式。
---@return table|nil row, string|nil errcode
local function readFacility(orgId)
    local row, err = Db.Single(
        'SELECT org_id, facility_type, workstations, stock, '
            .. 'UNIX_TIMESTAMP(last_tick_at) AS last_tick_epoch '
            .. 'FROM industry_facility WHERE org_id = ? LIMIT 1',
        { orgId })
    if err then return nil, 'db_error' end
    if not row then return nil, 'not_built' end
    return row, nil
end

local function emptyResult(plan, row)
    return {
        produced = 0,
        stock = tonumber(row.stock) or 0,
        last_tick_at = plan.newLastTickAt,
        expected = plan.expected,
        blocked = plan.blocked,
        settled = false,
    }
end

--- 结算一个组织设施。并发调用安全（last_tick_at CAS + affectedRows 裁决）。
---
--- 失败方向：返回 false 时数据库没有被本函数改动。
---@param orgId string
---@param opts table|nil { now = number|nil, trigger = string|nil }
---@return boolean ok, string|nil errcode, table|nil result
function IndustryProduction.SettleFacility(orgId, opts)
    if not validOrg(orgId) then return false, 'bad_org' end

    opts = opts or {}
    local now = nonNegativeInt(opts.now, os.time())

    for _ = 1, MAX_SETTLE_ATTEMPTS do
        local row, readErr = readFacility(orgId)
        if readErr then return false, readErr end

        local facilityType = tostring(row.facility_type or '')
        local facility = Config.Industry.Facilities[facilityType]
        if not facility then return false, 'bad_type' end

        -- 阶段倍率只从 cycle 状态拿；读不到就 fail closed，不按 1 倍继续产。
        if type(IndustryCycle) ~= 'table' or not IndustryCycle.Current then
            return false, 'db_error'
        end
        local cycleState, cycleErr = IndustryCycle.Current()
        if not cycleState then return false, cycleErr or 'db_error' end

        local config = productionConfig()
        local cap = nonNegativeInt(facility.stockCap, 0)
        local plan = IndustryProduction.Compute({
            now = now,
            lastTickAt = tonumber(row.last_tick_epoch),
            workstations = row.workstations,
            stock = row.stock,
            cap = cap,
            unitsPerHour = config.UnitsPerHour,
            multiplier = config.Multiplier * (tonumber(cycleState.production) or 1),
            maxCatchup = config.MaxCatchupSeconds,
        })

        if plan.advancedSeconds <= 0 then
            -- 没有时间可结算（dt=0 / 不足一个单位）：不写库，天然幂等。
            return true, nil, emptyResult(plan, row)
        end

        local oldLastTick = tonumber(row.last_tick_epoch) or 0
        local oldStock = tonumber(row.stock) or 0
        local affected, updateErr = Db.Update(
            'UPDATE industry_facility '
                .. 'SET stock = stock + ?, produced_units = produced_units + ?, '
                .. 'last_tick_at = FROM_UNIXTIME(?) '
                .. 'WHERE org_id = ? AND last_tick_at = FROM_UNIXTIME(?) AND stock = ?',
            {
                plan.produced, plan.produced, plan.newLastTickAt,
                orgId, oldLastTick, oldStock,
            })
        if updateErr then return false, 'db_error' end

        if affected == 1 then
            return true, nil, {
                produced = plan.produced,
                stock = oldStock + plan.produced,
                last_tick_at = plan.newLastTickAt,
                expected = plan.expected,
                blocked = plan.blocked,
                settled = true,
            }
        end

        -- affected = 0：读完之后别人结算过（或 S4 卖了库存）。重读重算。
    end

    return false, 'conflict'
end

--- 结算当前所有设施（tick 用）。一条查询 + 逐个 CAS，没有全表 UPDATE。
---@param opts table|nil
---@return boolean ok, string|nil errcode, table|nil stats
function IndustryProduction.SettleAll(opts)
    local rows, err = Db.Query(
        'SELECT org_id FROM industry_facility ORDER BY org_id LIMIT ?',
        { SETTLE_BATCH_LIMIT })
    if err then return false, 'db_error' end

    local stats = { settled = 0, failed = 0 }
    for _, row in ipairs(rows or {}) do
        local ok = IndustryProduction.SettleFacility(tostring(row.org_id), opts)
        if ok then stats.settled = stats.settled + 1 else stats.failed = stats.failed + 1 end
    end
    return true, nil, stats
end

--- 玩家上线时按他所属的组织补算。和 tick 走同一个 SettleFacility。
---@param Player table|nil QBCore 玩家对象
---@return number settled
function IndustryProduction.SettleForPlayer(Player)
    if not Player or not Player.PlayerData then return 0 end

    local settled = 0
    for orgId in pairs(Config.Industry.OrgWhitelist or {}) do
        local member = IndustryAccess.OrgMembership(Player, orgId)
        if member then
            local ok = IndustryProduction.SettleFacility(orgId, { trigger = 'player_loaded' })
            if ok then settled = settled + 1 end
        end
    end
    return settled
end

--- 启动接线：玩家上线补算 + 周期心跳。
---
--- 周期状态机不另起线程：main.lua 把 `IndustryCycle.Tick` 作为 hooks.onTick
--- 挂到这条 30 秒心跳上（少一条轮询线程 = 不涨 io_budget 的 unknown-interval 档）。
--- tick 顺序：先推进周期（可能换阶段/结算），再结算生产 —— 新阶段倍率当轮生效。
---@param hooks table|nil { onTick = function(now) end }
function IndustryProduction.Start(hooks)
    hooks = hooks or {}

    AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
        IndustryProduction.SettleForPlayer(Player)
    end)

    CreateThread(function()
        local waitMs = math.max(1, math.floor(tonumber(productionConfig().TickSeconds) or 30)) * 1000
        while true do
            Wait(waitMs)
            if hooks.onTick then
                local called, tickErr = pcall(hooks.onTick, os.time())
                if not called then
                    print(('[custom-industry] CRITICAL cycle tick failed: %s'):format(
                        tostring(tickErr)))
                end
            end
            local ok, err = IndustryProduction.SettleAll({ trigger = 'tick' })
            if not ok then
                -- 只在数据库失败时留一行；满仓/无工位是正常状态，不刷屏。
                print(('[custom-industry] production tick failed: %s'):format(tostring(err)))
            end
        end
    end)
end
