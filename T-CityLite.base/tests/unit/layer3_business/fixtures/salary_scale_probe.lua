-- tests/unit/layer3_business/fixtures/salary_scale_probe.lua
-- 真加载 core_economy 的 server/salary_scale.lua，用桩跑薪资抑制的判定：
-- 安全默认 / 缩放+封顶 / 幂等 / 从原始值重算 / 顺序保持 / 非法配置 / job 层兜底。
--
-- 关键不变量（真机上出错会直接变成经济事故）：
--   1. 没配 convar 时**不能**动工资（默认 1.0）；
--   2. 重复应用必须稳定（restart core_economy 不许把工资越压越低）；
--   3. 改了 convar 要从**原始值**重算，而不是在当前值上再乘一次；
--   4. 缩放后高等级不能比低等级拿得少（单调性）。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

-- ── 桩 ──
local convars = { economy_salary_scale = '1.0', economy_salary_cap = '0' }
GetConvarFloat = function(name, default)
    local raw = convars[name]
    if raw == nil then return default end
    return tonumber(raw) or default
end
GetConvarInt = function(name, default)
    local raw = convars[name]
    if raw == nil then return default end
    return math.floor(tonumber(raw) or default)
end

local Jobs = {
    garbage = { grades = { ['0'] = { payment = 10 }, ['1'] = { payment = 40 }, ['2'] = { payment = 80 } } },
    police = { grades = { ['0'] = { payment = 120 }, ['1'] = { payment = 200 } } },
    mechanic = { grades = { ['0'] = { payment = 50 } }, payment = 30 },
}

local Core = {
    Shared = { Jobs = Jobs },
    Config = { Money = { PayCheckTimeOut = 10 } },
}

local Registered = {}
exports = setmetatable({}, {
    __call = function(_, name, fn) Registered[name] = fn end,
    __index = function(_, resource)
        if resource == 'qb-core' then
            return { GetCoreObject = function() return Core end }
        end
        return nil
    end,
})

Wait = function() end
CreateThread = function(fn) fn() end   -- 同步执行：加载即「启动时应用一次」

local handle = assert(io.open(RES .. '/server/salary_scale.lua', 'r'))
local source = handle:read('a'); handle:close()
assert(load(source, '@salary_scale.lua'))()

local apply = Registered['ApplySalaryScale'] or ApplySalaryScale
emit('EXPORTED', tostring(type(apply) == 'function'))

local function snapshot()
    return {
        g0 = Jobs.garbage.grades['0'].payment,
        g1 = Jobs.garbage.grades['1'].payment,
        g2 = Jobs.garbage.grades['2'].payment,
        p0 = Jobs.police.grades['0'].payment,
        p1 = Jobs.police.grades['1'].payment,
        m0 = Jobs.mechanic.grades['0'].payment,
        mjob = Jobs.mechanic.payment,
    }
end

-- ── 1. 安全默认：convar 是 1.0，加载后工资不许变 ──
local base = snapshot()
emit('DEFAULT_SCALE_NOOP', tostring(base.g1 == 40 and base.p1 == 200 and base.mjob == 30))

-- ── 2. 缩放 + 封顶：0.35 / cap 50 ──
convars.economy_salary_scale = '0.35'
convars.economy_salary_cap = '50'
local report = apply()
local scaled = snapshot()
emit('SCALED_G1', tostring(scaled.g1 == 14))        -- 40 * 0.35 = 14
emit('SCALED_G2_CAPPED', tostring(scaled.g2 == 28)) -- 80 * 0.35 = 28（未触顶）
emit('CAPPED_P1', tostring(scaled.p1 == 50))        -- 200 * 0.35 = 70 → 封顶 50
emit('JOB_LEVEL_SCALED', tostring(scaled.mjob == 11)) -- 30 * 0.35 = 10.5 → 11
emit('REPORT_COUNTS', tostring(report and report.jobs == 3 and report.grades == 6))

-- ── 3. 幂等：再应用一次，结果必须一模一样 ──
local again = snapshot()
apply()
local afterSecond = snapshot()
emit('IDEMPOTENT', tostring(
    again.g1 == afterSecond.g1 and again.g2 == afterSecond.g2 and
    again.p1 == afterSecond.p1 and again.mjob == afterSecond.mjob))

-- ── 4. 改 convar 从原始值重算（不是在上一次结果上再乘）──
convars.economy_salary_scale = '0.5'
convars.economy_salary_cap = '0'
apply()
local halved = snapshot()
emit('RESCALE_FROM_ORIGINAL', tostring(halved.g2 == 40 and halved.p1 == 100 and halved.mjob == 15))
emit('CAP_OFF_RESTORES_RANGE', tostring(halved.p1 == 100))

-- ── 5. 单调性：高等级不许低于低等级 ──
convars.economy_salary_scale = '0.35'
convars.economy_salary_cap = '50'
apply()
local mono = snapshot()
emit('MONOTONIC', tostring(mono.g0 <= mono.g1 and mono.g1 <= mono.g2))

-- ── 6. 非法配置一律回落安全默认 ──
convars.economy_salary_scale = '-1'
convars.economy_salary_cap = '-5'
apply()
local bad = snapshot()
emit('INVALID_SCALE_FALLBACK', tostring(bad.g1 == 40 and bad.p1 == 200 and bad.mjob == 30))

convars.economy_salary_scale = '1.0'
convars.economy_salary_cap = '0'
apply()
local restored = snapshot()
emit('RESTORED_BY_SCALE_1', tostring(restored.g0 == 10 and restored.g2 == 80 and restored.p1 == 200))

io.write(table.concat(OUT, '\n'), '\n')
