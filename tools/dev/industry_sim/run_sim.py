#!/usr/bin/env python3
"""P4 #412 — 产业仿真器：驱动**真实 Lua**（production / sale / settlement / cycle）。

和 `sim_seasons.py` 的分工：

* `sim_seasons.py` 是 Python **复刻**规则，只能看形状，会与线上漂移；
* 本文件通过 `tests/unit/layer3_business/industry_harness.py` 的假 DB 装配链
  加载 `custom-industry/server/*.lua`，**不重写任何公式**。价格、产量、配额、
  税、季度结算全部由真实 Lua 计算，仿真器只做三件事：

  1. 注入时间（`now` 一律显式传入，不用 `os.time()` 当业务时钟）；
  2. 把策略压成唯一的 `decide(ctx) -> {build, sell, upgrade_stock}`；
  3. 把每周读数与末尾汇总转成 JSONL。

假 DB 的公共 SQL 语义复用 `fixtures/industry_probe_common.lua`；缺少的 SQL 形状
（两时钟 `industry_state`、设施 rich 读、提现周额度流水、季度 DELETE）由本文件
的 `SIM_DB_GLUE` 补齐 —— 那里只做**数据库模拟**，没有业务公式。

确定性：时间从固定的 2024-01-01（周一）本地零点开始，按 3600 秒步进；
所有 ref 由仿真器生成；输出不含 epoch、随机数或时间戳。同参数两次跑逐字节一致。

用法::

    python tools/dev/industry_sim/run_sim.py --weeks 13 --policy steady --out /tmp/a.jsonl
    python tools/dev/industry_sim/run_sim.py --weeks 13 --policy steady --out /tmp/a.jsonl \
        --baseline T-CityLite.base/tests/architecture/industry_sim_baseline.json

退出码：0 正常 / 2 基线偏离超阈值 / 1 仿真或输入错误。
"""

from __future__ import annotations

import argparse
import json
import sys
import types
from pathlib import Path

THIS = Path(__file__).resolve()
REPO = THIS.parents[3]
BASE = REPO / "T-CityLite.base"
HARNESS_DIR = BASE / "tests" / "unit" / "layer3_business"
DEFAULT_BASELINE = BASE / "tests" / "architecture" / "industry_sim_baseline.json"

# industry_harness 顶部的 `import pytest` 只服务 pytest 用例里的 lua5.4 缺失跳过；
# 本 runner 用 PATH 上的 python（可能没有 pytest）也要能跑，所以缺 pytest 时塞一个
# 只有 skip 的占位模块。**不伪造任何断言能力**。
try:  # noqa: SIM105 - 保持依赖最小，不用 contextlib
    import pytest  # noqa: F401
except ModuleNotFoundError:
    _fake_pytest = types.ModuleType("pytest")

    def _skip(message: str) -> None:
        raise RuntimeError(message)

    _fake_pytest.skip = _skip  # type: ignore[attr-defined]
    sys.modules["pytest"] = _fake_pytest

sys.path.insert(0, str(HARNESS_DIR))
import industry_harness  # noqa: E402  （路径必须先插进去）

ORG_ID = "mining_co"
FACILITY_TYPE = "mine"
DEFAULT_SALE_PRICE = 50
START_HOURS = 168
DEFAULT_WEEKS = 13

#: 四种策略 = 一个 `decide(ctx)` 的四组参数。仿真器不复制公式；
#: `decide` 只决定「建几个 / 卖不卖 / 升不升库存」，能不能做成由真实 Lua 裁决。
#:
#:   sell_mode   never / always / price（price 时 price_multiplier >= threshold 才卖）
#:   build_mode  none / affordable / after_upgrade（后者先升库存，钱不够再建工位）
POLICIES: dict[str, dict[str, object]] = {
    "idle": {
        "sell_mode": "never",
        "build_mode": "none",
        "upgrade_stock": False,
        "bootstrap": False,
    },
    "steady": {
        "sell_mode": "always",
        "build_mode": "none",
        "upgrade_stock": False,
        "bootstrap": True,
    },
    "max": {
        "sell_mode": "always",
        "build_mode": "affordable",
        "upgrade_stock": False,
        "bootstrap": True,
    },
    "hoard": {
        "sell_mode": "price",
        "price_threshold": 1.2,
        "build_mode": "after_upgrade",
        "upgrade_stock": True,
        "bootstrap": True,
    },
}


# ── 假 DB 扩展（只补 SQL 形状，不含业务公式）─────────────────────────────
SIM_DB_GLUE = r"""
-- 整个扩展包进 do ... end：Lua 主 chunk 的活跃 local 上限是 200，模块链本身
-- 已经接近上限；把 helper / 包装函数的 local 收进独立作用域，不占主 chunk 的槽位。
do
-- P4 #412：industry_cycle_probe.lua 之上的仿真假 DB 扩展。
-- 缺的五类形状：
--   1. 两时钟 industry_state（quarter_no / season / season_* / quarter_*）；
--   2. 设施 rich 读（facility.lua 需要 facility_type / workstations / stock_level）；
--   3. workstations / stock_level 两条 CAS UPDATE（生产 UPDATE 不拦）；
--   4. 提现周额度的 SUM(-delta) 读（ledger 行写 created_at = 仿真时钟）；
--   5. 季度结算的 DELETE（无 cycle 维度的 sales / BETWEEN 的 demand）。
-- 业务公式（价格/产量/配额/税/结算）一律在 server/*.lua，这里只模拟真库语义。

__simNow = 0

__simState = {
    cycle_no = 0,
    phase = 'uninitialized',
    phase_started_epoch = 0,
    phase_ends_epoch = 0,
    quarter_no = 1,
    season = 'spring',
    season_no = 1,
    season_started_epoch = nil,
    season_ends_epoch = nil,
    quarter_started_epoch = nil,
    quarter_ends_epoch = nil,
    warning_epoch = nil,
    settled_cycle_no = 0,
    result_announced_cycle = 0,
}

local function simStateRead(sql)
    local state = __simState
    if sql:find('SELECT settled_cycle_no', 1, true) then
        return { settled_cycle_no = state.settled_cycle_no }
    end
    if sql:find('SELECT result_announced_cycle', 1, true) then
        return { result_announced_cycle = state.result_announced_cycle }
    end
    return {
        id = 1,
        cycle_no = state.cycle_no,
        phase = state.phase,
        started_epoch = state.phase_started_epoch,
        ends_epoch = state.phase_ends_epoch,
        warning_done = state.warning_epoch ~= nil and 1 or 0,
        warning_epoch = state.warning_epoch,
        settled_cycle_no = state.settled_cycle_no,
        result_announced_cycle = state.result_announced_cycle,
        quarter_no = state.quarter_no,
        season = state.season,
        season_no = state.season_no,
        season_started_epoch = state.season_started_epoch,
        season_ends_epoch = state.season_ends_epoch,
        quarter_started_epoch = state.quarter_started_epoch,
        quarter_ends_epoch = state.quarter_ends_epoch,
    }
end

local function simStateUpdate(sql, values)
    local state = __simState

    -- 结算 / 结果公告水位：只增不减（SQL 自带 `< ?` 幂等闸）。
    if sql:find('SET settled_cycle_no = ?', 1, true) then
        local wanted = tonumber(values[1]) or 0
        local guard = tonumber(values[2]) or 0
        if state.settled_cycle_no >= guard then return { affectedRows = 0 } end
        state.settled_cycle_no = wanted
        return { affectedRows = 1 }
    end
    if sql:find('SET result_announced_cycle = ?', 1, true) then
        local wanted = tonumber(values[1]) or 0
        local guard = tonumber(values[2]) or 0
        if state.result_announced_cycle >= guard then return { affectedRows = 0 } end
        state.result_announced_cycle = wanted
        return { affectedRows = 1 }
    end
    if sql:find('SET warning_announced_at = FROM_UNIXTIME(?)', 1, true) then
        if state.warning_epoch ~= nil then return { affectedRows = 0 } end
        if tonumber(values[2]) ~= state.cycle_no then return { affectedRows = 0 } end
        state.warning_epoch = tonumber(values[1])
        return { affectedRows = 1 }
    end

    -- Initialize：占位阶段 → 两时钟 cycle 1 / spring / quarter 1。
    if sql:find('SET cycle_no = 1, phase = ?', 1, true)
        and sql:find('phase IN (?, ?)', 1, true) then
        if state.phase ~= values[10] and state.phase ~= values[11] then
            return { affectedRows = 0 }
        end
        state.cycle_no = 1
        state.phase = values[1]
        state.phase_started_epoch = tonumber(values[2])
        state.phase_ends_epoch = tonumber(values[3])
        state.quarter_no = 1
        state.season = values[4]
        state.season_no = tonumber(values[5])
        state.season_started_epoch = tonumber(values[6])
        state.season_ends_epoch = tonumber(values[7])
        state.quarter_started_epoch = tonumber(values[8])
        state.quarter_ends_epoch = tonumber(values[9])
        state.warning_epoch = nil
        state.settled_cycle_no = 0
        state.result_announced_cycle = 0
        return { affectedRows = 1 }
    end

    -- 旧单时钟接两时钟：保留原 phase 边界，只补 season 列。
    if sql:find('SET phase = ?, quarter_no = ?', 1, true)
        and sql:find('season_started_at IS NULL', 1, true) then
        if state.season_started_epoch ~= nil then return { affectedRows = 0 } end
        if state.cycle_no ~= tonumber(values[9]) then return { affectedRows = 0 } end
        state.phase = values[1]
        state.quarter_no = tonumber(values[2])
        state.season = values[3]
        state.season_no = tonumber(values[4])
        state.season_started_epoch = tonumber(values[5])
        state.season_ends_epoch = tonumber(values[6])
        state.quarter_started_epoch = tonumber(values[7])
        state.quarter_ends_epoch = tonumber(values[8])
        state.warning_epoch = nil
        state.settled_cycle_no = 0
        state.result_announced_cycle = 0
        return { affectedRows = 1 }
    end

    -- RollSeason：cycle/phase/season_no/season_ends_at 四道闸；跨季度再加
    -- settled_cycle_no >= quarter_no。少任何一道都必须 0 行。
    if sql:find('SET cycle_no = ?, phase = ?', 1, true)
        and sql:find('season_ends_at <= FROM_UNIXTIME(?)', 1, true) then
        if state.cycle_no ~= tonumber(values[12]) then return { affectedRows = 0 } end
        if state.phase ~= values[13] then return { affectedRows = 0 } end
        if state.season_no ~= tonumber(values[14]) then return { affectedRows = 0 } end
        if state.season_ends_epoch > tonumber(values[15]) then return { affectedRows = 0 } end
        if sql:find('settled_cycle_no >= ?', 1, true) then
            if state.settled_cycle_no < tonumber(values[16]) then
                return { affectedRows = 0 }
            end
        end
        state.cycle_no = tonumber(values[1])
        state.phase = values[2]
        state.phase_started_epoch = tonumber(values[3])
        state.phase_ends_epoch = tonumber(values[4])
        state.quarter_no = tonumber(values[5])
        state.season = values[6]
        state.season_no = tonumber(values[7])
        state.season_started_epoch = tonumber(values[8])
        state.season_ends_epoch = tonumber(values[9])
        state.quarter_started_epoch = tonumber(values[10])
        state.quarter_ends_epoch = tonumber(values[11])
        if sql:find('warning_announced_at = NULL', 1, true) then
            state.warning_epoch = nil
        end
        return { affectedRows = 1 }
    end

    -- 两时钟 SetPhase（控制台入口）：只要求 season_started_at IS NOT NULL。
    if sql:find('SET cycle_no = ?, phase = ?', 1, true)
        and sql:find('season_started_at IS NOT NULL', 1, true) then
        if state.season_started_epoch == nil then return { affectedRows = 0 } end
        state.cycle_no = tonumber(values[1])
        state.phase = values[2]
        state.phase_started_epoch = tonumber(values[3])
        state.phase_ends_epoch = tonumber(values[4])
        state.quarter_no = tonumber(values[5])
        state.season = values[6]
        state.season_no = tonumber(values[7])
        state.season_started_epoch = tonumber(values[8])
        state.season_ends_epoch = tonumber(values[9])
        state.quarter_started_epoch = tonumber(values[10])
        state.quarter_ends_epoch = tonumber(values[11])
        return { affectedRows = 1 }
    end

    -- 旧单时钟 SetPhase（本仿真不走这条；保留形状，不静默吞掉）。
    if sql:find('SET cycle_no = ?, phase = ?', 1, true) then
        state.cycle_no = tonumber(values[1])
        state.phase = values[2]
        state.phase_started_epoch = tonumber(values[3])
        state.phase_ends_epoch = tonumber(values[4])
        return { affectedRows = 1 }
    end

    return { affectedRows = 0 }
end

local function simFacilityHire(sql, values)
    local orgId = values[1]
    local current = tonumber(values[2])
    local cap = tonumber(values[3])
    local row = __facilities[orgId]
    if not row then return { affectedRows = 0 } end
    if tonumber(row.workstations) ~= current then return { affectedRows = 0 } end
    if sql:find('workstations < ?', 1, true) and cap and current >= cap then
        return { affectedRows = 0 }
    end
    row.workstations = current + 1
    return { affectedRows = 1 }
end

local function simFacilityStockLevel(sql, values)
    local orgId = values[1]
    local current = tonumber(values[2])
    local maxLevel = tonumber(values[3])
    local row = __facilities[orgId]
    if not row then return { affectedRows = 0 } end
    if tonumber(row.stock_level) ~= current then return { affectedRows = 0 } end
    if sql:find('stock_level < ?', 1, true) and maxLevel and current >= maxLevel then
        return { affectedRows = 0 }
    end
    row.stock_level = current + 1
    return { affectedRows = 1 }
end

-- 提现周额度：真库按 org_ledger.created_at >= FROM_UNIXTIME(?) 求和。
-- 仿真里 created_at 就是写入时的 __simNow（见下面的 insert 包装）。
local function simWithdrawnThisWeek(values)
    local orgId = tostring(values[1])
    local since = tonumber(values[2]) or 0
    local total = 0
    for _, row in ipairs(__ledger) do
        local reason = row.reason
        if tostring(row.org_id) == orgId
            and (reason == 'withdraw' or reason == 'withdraw-rollback')
            and (tonumber(row.created_at) or 0) >= since then
            total = total - (tonumber(row.delta) or 0)
        end
    end
    if total < 0 then total = 0 end
    return { total = total }
end

-- 季度结算：两时钟的 DELETE 形状（旧单时钟的带 cycle 版本仍交给公共层）。
local function simDeleteSales(sql, values)
    if sql:find('WHERE id = ?', 1, true) then return nil end
    if sql:find('AND cycle_no', 1, true) then return nil end
    if not sql:find('WHERE org_id = ?', 1, true) then return nil end
    local orgId = tostring(values[1])
    local removed = 0
    for index = #__sales, 1, -1 do
        if tostring(__sales[index].org_id) == orgId then
            table.remove(__sales, index)
            removed = removed + 1
        end
    end
    return { affectedRows = removed }
end

local function simDeleteDemand(sql, values)
    if not sql:find('BETWEEN ? AND ?', 1, true) then return nil end
    local fromCycle = tonumber(values[1]) or 0
    local toCycle = tonumber(values[2]) or 0
    local removed = 0
    for key, row in pairs(__demands) do
        local cycleNo = tonumber(row.cycle_no) or -1
        if cycleNo >= fromCycle and cycleNo <= toCycle then
            __demands[key] = nil
            removed = removed + 1
        end
    end
    return { affectedRows = removed }
end

local __simBaseSingle = MySQL.single.await
MySQL.single = { await = function(sql, values)
    if sql:find('FROM industry_state', 1, true) then
        __industryLogSql('single', sql)
        return simStateRead(sql)
    end
    if sql:find('FROM org_ledger', 1, true) and sql:find('SUM(-delta)', 1, true) then
        __industryLogSql('single', sql)
        return simWithdrawnThisWeek(values)
    end
    if sql:find('FROM industry_facility', 1, true) then
        __industryLogSql('single', sql)
        return __industryReadFacility(sql, values, 'rich')
    end
    return __simBaseSingle(sql, values)
end }

local __simBaseUpdate = MySQL.update.await
MySQL.update = { await = function(sql, values)
    if sql:find('UPDATE industry_state', 1, true) then
        __industryLogSql('update', sql)
        return simStateUpdate(sql, values)
    end
    if sql:find('UPDATE industry_facility', 1, true) then
        if sql:find('SET workstations = workstations + 1', 1, true) then
            __industryLogSql('update', sql)
            return simFacilityHire(sql, values)
        end
        if sql:find('SET stock_level = stock_level + 1', 1, true) then
            __industryLogSql('update', sql)
            return simFacilityStockLevel(sql, values)
        end
        return __simBaseUpdate(sql, values)
    end
    if sql:find('DELETE FROM industry_sales', 1, true) then
        local handled = simDeleteSales(sql, values)
        if handled then
            __industryLogSql('update', sql)
            return handled
        end
        return __simBaseUpdate(sql, values)
    end
    if sql:find('DELETE FROM industry_demand', 1, true) then
        local handled = simDeleteDemand(sql, values)
        if handled then
            __industryLogSql('update', sql)
            return handled
        end
        return __simBaseUpdate(sql, values)
    end
    return __simBaseUpdate(sql, values)
end }

local __simBaseInsert = MySQL.insert.await
MySQL.insert = { await = function(sql, values)
    if sql:find('INSERT IGNORE INTO industry_state', 1, true) then
        -- 单行表在仿真启动时就种好了；Initialize 的 INSERT IGNORE 必然是 0 行。
        __industryLogSql('insert', sql)
        return { affectedRows = 0 }
    end
    return __simBaseInsert(sql, values)
end }

-- 流水行补 created_at（提现周额度派生依赖它）。业务字段仍由公共层写。
local __simBaseLedgerInsert = __industryInsertLedger
function __industryInsertLedger(sql, values)
    local before = #__ledger
    local result = __simBaseLedgerInsert(sql, values)
    for index = before + 1, #__ledger do
        __ledger[index].created_at = __simNow
    end
    return result
end

-- ── 世界接口：qb-core / Money / 客户端事件 ─────────────────────────────
__simPersonalBank = 0

local __simBoss = {
    PlayerData = {
        citizenid = 'cid-sim-boss',
        source = 1,
        job = { name = 'miner', label = '仿真矿业', grade = { level = 4, name = 'Boss' } },
    },
    Functions = {
        AddMoney = function(_, amount)
            __simPersonalBank = __simPersonalBank + (tonumber(amount) or 0)
            return true
        end,
        RemoveMoney = function() return true end,
    },
}

local __simCore = {
    Commands = {
        Add = function(name, _, __, ___, handler) __handlers[name] = handler end,
    },
    Functions = {
        GetPlayer = function(source)
            if tonumber(source) == 1 then return __simBoss end
            return nil
        end,
        HasPermission = function() return false end,
        -- 结算按**在线成员**分配；仿真不模拟在线名单，所以返回空表。
        GetQBPlayers = function() return {} end,
    },
}

local __simBaseExports = exports
exports = setmetatable({}, {
    __index = function(_, resource)
        if resource == 'qb-core' then
            return { GetCoreObject = function() return __simCore end }
        end
        return __simBaseExports[resource]
    end,
    __call = function(_, name, fn) return __simBaseExports(name, fn) end,
})

function Money(value) return tostring(value) end
function TriggerClientEvent() end
function RegisterCommand() end
function AddEventHandler() end
function CreateThread() end
function Wait() end
function SetTimeout() end
-- 模块的日志不进入 stdout（stdout 只留 WEEK|/SUMMARY| 协议行）。
function print() end
end
"""


DRIVER_TEMPLATE = r"""
do
    local ORG = '@@ORG@@'
    local WEEKS = @@WEEKS@@
    local HOURS = @@HOURS@@
    local TOTAL = WEEKS * HOURS
    local ITEM = Config.Industry.Sales.SeedItem or 'iron_ore'
    local POLICY = '@@POLICY@@'
    local SPEC = @@SPEC@@
    -- 固定起点：2024-01-01 是周一，天然对齐 Treasury.WeekStart 的自然周桶。
    -- 输出不含 epoch，所以跨时区只影响周桶内部对齐，不影响可比性。
    local START = os.time({ year = 2024, month = 1, day = 1, hour = 0, min = 0, sec = 0 })

    -- 策略接口：仿真器只调用这一个函数。四种策略 = SPEC 的四组参数。
    -- decide 不计算价格/产量/配额；它只回答「建几个工位 / 卖多少 / 升不升库存」，
    -- 每一步能不能做成仍由真实 Lua 裁决（余额、上限、配额、阶段可购置性）。
    local function decide(ctx)
        local sell = 0
        if SPEC.sell_mode == 'always' then
            sell = ctx.stock
        elseif SPEC.sell_mode == 'price'
            and ctx.price_multiplier >= (SPEC.price_threshold or 0) then
            sell = ctx.stock
        end

        local upgrade = false
        if SPEC.upgrade_stock
            and ctx.stock_upgrade_cost >= 0
            and ctx.treasury >= ctx.stock_upgrade_cost then
            upgrade = true
        end

        local build = 0
        if SPEC.build_mode == 'affordable' then
            if ctx.workstations < ctx.workstation_cap
                and ctx.treasury >= ctx.workstation_cost then
                build = 1
            end
        elseif SPEC.build_mode == 'after_upgrade' and not upgrade then
            if ctx.workstations < ctx.workstation_cap
                and ctx.treasury >= ctx.workstation_cost then
                build = 1
            end
        end

        return { build = build, sell = sell, upgrade_stock = upgrade }
    end

    local function number(value)
        return math.floor(tonumber(value) or 0)
    end

    IndustryCommands.Now = function() return __simNow end
    IndustryCommands.Register()

    __simNow = START
    local initOk, initErr = IndustryCycle.Initialize(__simNow)
    if not initOk then error('cycle initialize failed: ' .. tostring(initErr)) end
    local seedOk, seedErr = IndustrySales.EnsureSeed()
    if not seedOk then error('demand seed failed: ' .. tostring(seedErr)) end

    local accountOk, accountErr = Treasury.EnsureAccount(ORG)
    if not accountOk then error('treasury account failed: ' .. tostring(accountErr)) end
    local depositOk, depositErr = Treasury.Deposit(ORG, 200000, 'sim-starter', {
        ref = 'sim:starter:q1', cycleNo = 1,
    })
    if not depositOk then error('starter deposit failed: ' .. tostring(depositErr)) end

    if SPEC.bootstrap == true then
        local builtOk, builtErr = Facility.Build(ORG, '@@FACILITY@@', { ref = 'sim:build:q1' })
        if not builtOk then error('facility build failed: ' .. tostring(builtErr)) end
        local row = __facilities[ORG]
        if not row then error('facility row missing after build') end
        -- 真库默认值：v4.6 stock_level = 0；last_tick_at = current_timestamp。
        row.stock_level = 0
        row.last_tick_epoch = __simNow
        local hiredOk, hiredErr = Facility.AddWorkstation(ORG, { ref = 'sim:hire:q1:1' })
        if not hiredOk then error('first workstation failed: ' .. tostring(hiredErr)) end
    end

    local weekRevenue = 0
    local weekWithdrawals = 0
    local weekTax = 0
    local totalRevenue = 0
    local totalWithdrawals = 0
    local totalTax = 0
    local saleSeq = 0

    local function emitWeek(week)
        local state = IndustryCycle.Current()
        if not state then error('cycle state unavailable') end
        local row = __facilities[ORG]
        local treasury = __treasuries[ORG]
        local demand = __demands[__industryDemandKey(state.cycle_no, state.phase, ITEM)]
        local facilityType = row and row.facility_type or '@@FACILITY@@'
        io.write(('WEEK|%d|%d|%s|%d|%d|%d|%d|%d|%d|%d|%d|%d\n'):format(
            week,
            number(state.quarter_no),
            tostring(state.season_name),
            row and number(row.workstations) or 0,
            row and number(row.stock) or 0,
            row and number(Facility.StockCapFor(row.stock_level, facilityType)) or 0,
            demand and number(demand.quota_used) or 0,
            number(weekRevenue),
            treasury and number(treasury.balance) or 0,
            treasury and number(treasury.prestige) or 0,
            number(weekWithdrawals),
            number(weekTax)))
        io.flush()
        weekRevenue, weekWithdrawals, weekTax = 0, 0, 0
    end

    for hour = 1, TOTAL do
        __simNow = START + hour * 3600

        -- 每周第一小时：Boss 顶格提现。周额度 + 20% 税全部走真实命令路径
        -- （IndustryCommands.Register 注册的 orgfundwithdraw handler）。
        if (hour - 1) % HOURS == 0 then
            local quota = number(Config.Industry.WeeklyWithdrawQuota)
            if quota > 0 then
                local before = __treasuries[ORG] and number(__treasuries[ORG].balance) or 0
                local bankBefore = __simPersonalBank
                __handlers['orgfundwithdraw'](1, { ORG, tostring(quota) })
                local after = __treasuries[ORG] and number(__treasuries[ORG].balance) or 0
                local gross = before - after
                if gross > 0 then
                    local net = __simPersonalBank - bankBefore
                    weekWithdrawals = weekWithdrawals + gross
                    totalWithdrawals = totalWithdrawals + gross
                    weekTax = weekTax + (gross - net)
                    totalTax = totalTax + (gross - net)
                end
            end
        end

        -- 生产：惰性结算，now 由仿真器注入（与真机 tick 一样只调 SettleFacility）。
        local prodOk, prodErr = IndustryProduction.SettleFacility(ORG, {
            now = __simNow, trigger = 'sim',
        })
        if not prodOk and prodErr ~= 'not_built' then
            error('production settle failed at hour ' .. hour .. ': ' .. tostring(prodErr))
        end

        -- 决策上下文：只放读数与配置价格，不含任何业务公式。
        local state = IndustryCycle.Current()
        if not state then error('cycle state unavailable') end
        local row = __facilities[ORG]
        local treasury = __treasuries[ORG]
        local stockLevel = row and number(row.stock_level) or 0
        local workstations = row and number(row.workstations) or 0
        local workstationCost = Facility.WorkstationCost('@@FACILITY@@', workstations)
        local upgradeCost = Facility.StockUpgradeCost('@@FACILITY@@', stockLevel)
        local ctx = {
            week = math.floor((hour - 1) / HOURS) + 1,
            hour = hour,
            quarter = number(state.quarter_no),
            season = tostring(state.season_name),
            season_no = number(state.season_no),
            price_multiplier = tonumber(state.price) or 1,
            production_multiplier = tonumber(state.production) or 1,
            treasury = treasury and number(treasury.balance) or 0,
            prestige = treasury and number(treasury.prestige) or 0,
            stock = row and number(row.stock) or 0,
            stock_level = stockLevel,
            stock_level_max = number(Config.Industry.Facilities['@@FACILITY@@'].stockLevelMax),
            stock_cap = row and number(Facility.StockCapFor(stockLevel, '@@FACILITY@@')) or 0,
            workstations = workstations,
            workstation_cap = number(Config.Industry.Facilities['@@FACILITY@@'].workstationCap),
            workstation_cost = workstationCost and number(workstationCost) or 0,
            stock_upgrade_cost = upgradeCost and number(upgradeCost) or -1,
            has_facility = row ~= nil,
        }
        local action = decide(ctx)

        -- 建工位：decide 只说数量；余额/上限由真实 Facility.AddWorkstation 裁决。
        for index = 1, math.max(0, number(action.build)) do
            local hiredOk = Facility.AddWorkstation(ORG, {
                ref = ('sim:hire:%d:%d'):format(hour, index),
            })
            if not hiredOk then break end
        end

        -- 卖货：先问真实快照的最大可卖量（库存/配额/50% 上限都在 Lua 里算），
        -- 再走 SettleSale。策略返回的 sell 只表示「本小时卖不卖」。
        if (tonumber(action.sell) or 0) > 0 and row then
            local info = IndustrySales.Inspect(ORG, ITEM)
            local maxQty = info and number(info.maxQty) or 0
            if maxQty > 0 then
                saleSeq = saleSeq + 1
                local saleOk, saleErr, saleResult = IndustrySales.SettleSale(
                    ORG, ITEM, maxQty, ('sim:sale:%d'):format(saleSeq))
                if saleOk then
                    weekRevenue = weekRevenue + number(saleResult.revenue)
                    totalRevenue = totalRevenue + number(saleResult.revenue)
                elseif saleErr ~= 'demand_exhausted' and saleErr ~= 'org_cap_reached'
                    and saleErr ~= 'stock_empty' and saleErr ~= 'busy' then
                    error('sale failed at hour ' .. hour .. ': ' .. tostring(saleErr))
                end
            end
        end

        -- 升级库存上限（P3）：失败（没钱 / 满级 / 并发）不影响主循环。
        if action.upgrade_stock and row then
            Facility.UpgradeStock(ORG, { ref = ('sim:stock:%d'):format(hour) })
        end

        if hour % HOURS == 0 then
            emitWeek(hour / HOURS)
        end

        if hour < TOTAL then
            -- 季节滚动放在小时末尾：这一小时的产量/销售属于**刚结束的季节**，
            -- 与「区间结算」口径一致（Tick 用计划结束时间作为新季节起点）。
            local tickOk, tickErr = IndustryCycle.Tick(__simNow)
            if not tickOk then
                error('cycle tick failed at hour ' .. hour .. ': ' .. tostring(tickErr))
            end
        else
            -- 季度末：先记录结算前快照，再调真实 SettleQuarter，最后 Tick 跨入下一季度
            -- （settled_cycle_no 已到位，tickTwoClock 不会重复结算）。
            local endRow = __facilities[ORG]
            local endTreasury = __treasuries[ORG]
            local endWorkstations = endRow and number(endRow.workstations) or 0
            local endStockLevel = endRow and number(endRow.stock_level) or 0
            local endStock = endRow and number(endRow.stock) or 0
            local endCap = endRow
                and number(Facility.StockCapFor(endRow.stock_level, endRow.facility_type))
                or 0
            local endTreasuryBalance = endTreasury and number(endTreasury.balance) or 0
            local endPrestige = endTreasury and number(endTreasury.prestige) or 0

            -- 结算**当前**季度：13 周跑完时就是 quarter 1；跑更多周也不会结算错季度。
            local finalState = IndustryCycle.Current()
            if not finalState then error('cycle state unavailable at quarter end') end
            local settleOk, settleErr, summary = IndustrySettlement.SettleQuarter(
                number(finalState.quarter_no), {
                    trigger = 'sim_quarter_end', cycleNo = number(finalState.cycle_no),
                })
            if not settleOk then
                error('quarter settle failed: ' .. tostring(settleErr))
            end
            local tickOk, tickErr = IndustryCycle.Tick(__simNow)
            if not tickOk then
                error('quarter roll failed: ' .. tostring(tickErr))
            end
            local afterTreasury = __treasuries[ORG]
            io.write(('SUMMARY|%s|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d\n'):format(
                POLICY, WEEKS,
                number(summary.revenue),
                endWorkstations, endStockLevel, endStock, endCap,
                -- SettleQuarter 的 summary 不带 produced_units；用结算前的设施行快照，
                -- 它才是本季度真实累计产出（production.lua 只增不减地写这一列）。
                number(endRow and endRow.produced_units or 0),
                number(totalRevenue), number(totalWithdrawals), number(totalTax),
                endTreasuryBalance, endPrestige,
                afterTreasury and number(afterTreasury.balance) or 0,
                number(summary.starter_granted)))
            io.flush()
        end
    end
end
"""


def _lua_value(value: object) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    return "'" + str(value).replace("\\", "\\\\").replace("'", "\\'") + "'"


def _lua_spec(spec: dict[str, object]) -> str:
    return "{ " + ", ".join(f"{key} = {_lua_value(value)}" for key, value in spec.items()) + " }"


def _driver_body(policy: str, weeks: int) -> str:
    return (
        DRIVER_TEMPLATE.replace("@@ORG@@", ORG_ID)
        .replace("@@FACILITY@@", FACILITY_TYPE)
        .replace("@@POLICY@@", policy)
        .replace("@@SPEC@@", _lua_spec(POLICIES[policy]))
        .replace("@@WEEKS@@", str(weeks))
        .replace("@@HOURS@@", str(START_HOURS))
    )


def _parse_stdout(stdout: str, policy: str, weeks: int) -> tuple[list[dict], dict]:
    weekly: list[dict] = []
    summary: dict | None = None
    for line in stdout.splitlines():
        if line.startswith("WEEK|"):
            parts = line.split("|")
            if len(parts) != 13:
                raise RuntimeError(f"WEEK 行字段数不对（{len(parts)}）：{line!r}")
            weekly.append(
                {
                    "kind": "week",
                    "week": int(parts[1]),
                    "quarter": int(parts[2]),
                    "season": parts[3],
                    "workstations": int(parts[4]),
                    "stock": int(parts[5]),
                    "stock_cap": int(parts[6]),
                    "quota_used": int(parts[7]),
                    "revenue": int(parts[8]),
                    "treasury": int(parts[9]),
                    "prestige": int(parts[10]),
                    "withdrawals": int(parts[11]),
                    "tax_burned": int(parts[12]),
                }
            )
        elif line.startswith("SUMMARY|"):
            parts = line.split("|")
            if len(parts) != 16:
                raise RuntimeError(f"SUMMARY 行字段数不对（{len(parts)}）：{line!r}")
            summary = {
                "kind": "summary",
                "policy": parts[1],
                "weeks": int(parts[2]),
                "quarter_revenue": int(parts[3]),
                "workstations": int(parts[4]),
                "stock_level": int(parts[5]),
                "stock_end": int(parts[6]),
                "stock_cap": int(parts[7]),
                "produced_units": int(parts[8]),
                "total_revenue": int(parts[9]),
                "total_withdrawals": int(parts[10]),
                "total_tax_burned": int(parts[11]),
                "treasury_before_settle": int(parts[12]),
                "prestige_before_settle": int(parts[13]),
                "treasury_after_roll": int(parts[14]),
                "starter_granted": int(parts[15]),
            }
    if summary is None:
        raise RuntimeError(f"Lua 输出里没有 SUMMARY 行：\n{stdout[-4000:]}")
    if len(weekly) != weeks:
        raise RuntimeError(f"应有 {weeks} 条 WEEK 行，实际 {len(weekly)} 条")
    if summary["policy"] != policy or summary["weeks"] != weeks:
        raise RuntimeError(f"SUMMARY 与入参不一致：{summary}")
    return weekly, summary


def run_simulation(
    *,
    policy: str,
    weeks: int = DEFAULT_WEEKS,
    sale_price: int | None = None,
) -> tuple[list[dict], dict]:
    """跑一次 N 周仿真，返回 (weekly rows, summary)。不写文件。"""
    if policy not in POLICIES:
        raise ValueError(f"未知策略：{policy}")
    if weeks < 1:
        raise ValueError("weeks 必须 >= 1")

    convars = {"industry_enable": "true"}
    if sale_price is not None:
        convars["industry_sale_price"] = str(sale_price)

    stdout = industry_harness.run_sim_script(
        _driver_body(policy, weeks), convars=convars, glue=SIM_DB_GLUE
    )
    return _parse_stdout(stdout, policy, weeks)


def write_jsonl(rows: list[dict], out_path: Path) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8", newline="\n") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")))
            handle.write("\n")


def compare_to_baseline(
    summary: dict, baseline: dict, tolerance: float = 0.10
) -> list[str]:
    """关键字段相对基线偏离超过 tolerance 时返回差异描述；空列表 = 通过。"""
    metrics = baseline.get("metrics") or {}
    problems: list[str] = []
    for key in ("quarter_revenue", "workstations", "stock_level"):
        if key not in metrics:
            problems.append(f"{key}: 基线缺这个字段")
            continue
        expected = metrics[key]
        actual = summary.get(key)
        if not isinstance(actual, (int, float)):
            problems.append(f"{key}: 仿真结果缺这个字段")
            continue
        if expected == 0:
            deviation = 0.0 if actual == 0 else float("inf")
        else:
            deviation = abs(actual - expected) / abs(expected)
        if deviation > tolerance:
            shown = "∞" if deviation == float("inf") else f"{deviation:+.1%}"
            problems.append(
                f"{key}: baseline={expected} actual={actual} 偏离 {shown}（阈值 ±{tolerance:.0%}）"
            )
    return problems


def _baseline_payload(summary: dict, weeks: int, sale_price: int | None) -> dict:
    return {
        "_comment": (
            "P4 #412 产业仿真基线。生成方式："
            "python tools/dev/industry_sim/run_sim.py --weeks 13 --policy steady "
            "--out <tmp>.jsonl --write-baseline "
            "T-CityLite.base/tests/architecture/industry_sim_baseline.json。"
            "口径：驱动真实 Lua（production/sale/settlement/cycle），单组织 mining_co，"
            "初始金库 200000（Treasury.Deposit），每周顶格提现 WeeklyWithdrawQuota，"
            "第 13 周末调用 SettleQuarter(1) 后 Tick 跨入下一季度。"
            "metrics 为季度结算口径：quarter_revenue = industry_cycle_results.revenue"
            "（本季卖单流水合计）；workstations / stock_level 是结算**前**的设施行快照。"
            "仿真为了防漂移而不做在线成员分配（GetQBPlayers 返回空）。"
        ),
        "policy": "steady",
        "weeks": weeks,
        "sale_price": DEFAULT_SALE_PRICE if sale_price is None else sale_price,
        "metrics": {
            "quarter_revenue": summary["quarter_revenue"],
            "workstations": summary["workstations"],
            "stock_level": summary["stock_level"],
        },
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="产业仿真器：驱动真实 Lua 跑 N 周")
    parser.add_argument("--weeks", type=int, default=DEFAULT_WEEKS,
                        help=f"仿真周数（默认 {DEFAULT_WEEKS} = 1 季度）")
    parser.add_argument("--policy", choices=sorted(POLICIES), default="steady",
                        help="策略：idle / steady / max / hoard")
    parser.add_argument("--out", type=Path, required=True,
                        help="JSONL 输出路径（每周一行 + 末尾 summary 一行）")
    parser.add_argument("--baseline", type=Path, default=None,
                        help="与基线 JSON 比对；超阈值时退出码 2")
    parser.add_argument("--tolerance", type=float, default=0.10,
                        help="基线允许的相对偏离（默认 0.10 = ±10%%）")
    parser.add_argument("--sale-price", type=int, default=None,
                        help="覆盖 industry_sale_price convar（服务端权威自证用）")
    parser.add_argument("--write-baseline", type=Path, default=None,
                        help="把本次 summary 写成基线 JSON（只允许 steady）")
    args = parser.parse_args(argv)

    if args.write_baseline is not None and args.policy != "steady":
        parser.error("--write-baseline 只允许 --policy steady")

    try:
        weekly, summary = run_simulation(
            policy=args.policy, weeks=args.weeks, sale_price=args.sale_price
        )
    except (RuntimeError, ValueError) as exc:
        print(f"[sim] 失败：{exc}", file=sys.stderr)
        return 1

    records = weekly + [summary]
    write_jsonl(records, args.out)

    print(
        f"[sim] policy={summary['policy']} weeks={summary['weeks']} "
        f"季度收入={summary['quarter_revenue']} 工位={summary['workstations']} "
        f"库存级={summary['stock_level']} 提现={summary['total_withdrawals']} "
        f"税={summary['total_tax_burned']}"
    )

    if args.write_baseline is not None:
        payload = _baseline_payload(summary, args.weeks, args.sale_price)
        args.write_baseline.parent.mkdir(parents=True, exist_ok=True)
        with args.write_baseline.open("w", encoding="utf-8", newline="\n") as handle:
            handle.write(json.dumps(payload, ensure_ascii=False, indent=2))
            handle.write("\n")
        print(f"[sim] 基线已写入 {args.write_baseline}")

    if args.baseline is not None:
        if not args.baseline.is_file():
            print(f"[sim] 基线不存在：{args.baseline}", file=sys.stderr)
            return 1
        baseline = json.loads(args.baseline.read_text(encoding="utf-8"))
        problems = compare_to_baseline(summary, baseline, args.tolerance)
        if problems:
            print("BASELINE MISMATCH:")
            for problem in problems:
                print(f"  - {problem}")
            return 2
        print(f"BASELINE OK: 关键字段在 ±{args.tolerance:.0%} 内")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
