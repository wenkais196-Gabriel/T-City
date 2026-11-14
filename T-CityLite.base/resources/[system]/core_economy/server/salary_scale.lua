-- server/salary_scale.lua — 薪资（paycheck）抑制：让「干活」成为主要收入
--
-- 为什么需要：qb-core 每 `PayCheckTimeOut` 分钟（默认 10 → 6 次/小时）按职业等级发一次
-- `QBShared.Jobs[job].grades[level].payment`，106 个等级的支付区间是 10–200，也就是
-- **$60–1,200/小时**的白拿收入。R1 把循环职业的干活收益定在 1,400–2,800 $/h，如果不压薪资，
-- 玩家最优策略仍是挑高薪职业挂机。
--
-- 做法：只改 `QBShared.Jobs` 这一张共享表（就是 PaycheckInterval 读的那张），不改 qb-core 的
-- 任何一行代码 —— 上游更新可以照常合并。两个 convar：
--   economy_salary_scale  乘数，默认 1.0（= 不动，安全默认）
--   economy_salary_cap    单次上限（美元），默认 0 = 不封顶
-- 每次应用都从**原始值**重算，所以 `restart core_economy` 不会把工资越压越低（幂等）。
--
-- 注意：这是「政治决定」而不是补丁 —— 数值见 docs/plan/jobs-content/04-numbers.md。

local Originals = {}   -- 'job:grade' → 原始 payment（只记第一次见到的值）
local AppliedScale = 1.0

local function key(jobName, gradeLevel)
    return tostring(jobName) .. ':' .. tostring(gradeLevel)
end

--- 读配置；非法值一律回落到安全默认（1.0 / 不封顶）
---@return number scale, number cap
local function readConfig()
    local scale = GetConvarFloat('economy_salary_scale', 1.0)
    if type(scale) ~= 'number' or scale ~= scale or scale <= 0 then scale = 1.0 end
    local cap = GetConvarInt('economy_salary_cap', 0)
    if type(cap) ~= 'number' or cap ~= cap or cap < 0 then cap = 0 end
    return scale, cap
end

--- 金额渲染：整数不带小数点、小数两位（与 custom-quest 的 QuestMoney 同语义）。
--- 不许写 `('$%d'):format(x)`：Lua 5.4 对小数直接抛 `number has no integer representation`，
--- 闸门 tests/architecture/test_money_format.py 也把这种写法列为只减不增的债。
local function formatMoney(value)
    local num = tonumber(value)
    if not num then return '0' end
    if num % 1 == 0 then return ('%d'):format(num) end
    return ('%.2f'):format(num)
end
--- 单次薪资的计算（纯函数，离线探针直接喂值）
---@param payment number 原始支付
---@param scale number 乘数
---@param cap number 单次上限，0 = 不封顶
---@return number
local function computeSalary(payment, scale, cap)
    payment = tonumber(payment) or 0
    if payment <= 0 then return payment end
    local scaled = math.floor(payment * scale + 0.5)
    if scaled < 1 then scaled = 1 end
    if cap > 0 and scaled > cap then scaled = cap end
    return scaled
end

--- 把缩放结果写回 QBShared.Jobs（幂等：永远从 Originals 算）
---@param jobs table QBShared.Jobs
---@param scale number
---@param cap number
---@return table report { jobs, grades, changed, before = {min,max}, after = {min,max} }
local function applyTo(jobs, scale, cap)
    local report = {
        jobs = 0, grades = 0, changed = 0,
        before = { min = math.huge, max = 0 },
        after = { min = math.huge, max = 0 },
    }
    if type(jobs) ~= 'table' then return report end

    for jobName, job in pairs(jobs) do
        local grades = type(job) == 'table' and type(job.grades) == 'table' and job.grades or nil
        if grades then
            report.jobs = report.jobs + 1
            for gradeLevel, grade in pairs(grades) do
                if type(grade) == 'table' and tonumber(grade.payment) then
                    local original = Originals[key(jobName, gradeLevel)]
                    if not original then
                        original = tonumber(grade.payment)
                        Originals[key(jobName, gradeLevel)] = original
                    end
                    local newPayment = computeSalary(original, scale, cap)
                    if newPayment ~= grade.payment then report.changed = report.changed + 1 end
                    grade.payment = newPayment
                    report.grades = report.grades + 1
                    report.before.min = math.min(report.before.min, original)
                    report.before.max = math.max(report.before.max, original)
                    report.after.min = math.min(report.after.min, newPayment)
                    report.after.max = math.max(report.after.max, newPayment)
                end
            end
        end
        -- 少数职业把 payment 写在 job 层（PaycheckInterval 的兜底分支会读它）
        if type(job) == 'table' and tonumber(job.payment) then
            local original = Originals[key(jobName, 'job')]
            if not original then
                original = tonumber(job.payment)
                Originals[key(jobName, 'job')] = original
            end
            local newPayment = computeSalary(original, scale, cap)
            if newPayment ~= job.payment then report.changed = report.changed + 1 end
            job.payment = newPayment
        end
    end

    if report.before.min == math.huge then report.before.min = 0 end
    if report.after.min == math.huge then report.after.min = 0 end
    return report
end

--- 对外入口：按 convar 应用一次（幂等，可重复调用）
---@param jobs table|nil 默认 QBCore.Shared.Jobs
---@return table|nil report
function ApplySalaryScale(jobs)
    if type(jobs) ~= 'table' then
        local ok, core = pcall(function() return exports['qb-core']:GetCoreObject() end)
        jobs = (ok and core and core.Shared and core.Shared.Jobs) or nil
    end
    if type(jobs) ~= 'table' then
        print('[core_economy] ⚠️ salary scale skipped: QBShared.Jobs 不可用（qb-core 还没起？）')
        return nil
    end

    local scale, cap = readConfig()
    AppliedScale = scale
    local report = applyTo(jobs, scale, cap)

    -- 换算成「每小时」给数值卡直接用：PayCheckTimeOut 分钟一发
    local perHour = 0
    local okCfg, core = pcall(function() return exports['qb-core']:GetCoreObject() end)
    if okCfg and core and core.Config and core.Config.Money and tonumber(core.Config.Money.PayCheckTimeOut) then
        local minutes = tonumber(core.Config.Money.PayCheckTimeOut)
        if minutes and minutes > 0 then perHour = 60 / minutes end
    end

    print(('[core_economy] 💼 salary scale ×%.2f (cap %s) → %d 职业 / %d 等级，改动 %d 个；'
        .. '单次 %d–%d → %d–%d%s')
        :format(scale, cap > 0 and ('$' .. cap) or 'off', report.jobs, report.grades, report.changed,
                report.before.min, report.before.max, report.after.min, report.after.max,
                perHour > 0 and ('；折算 $%s–%s/小时'):format(
                    formatMoney(report.after.min * perHour), formatMoney(report.after.max * perHour)) or ''))
    return report
end

--- 诊断用：当前生效的乘数（没有应用过时是 1.0）
function GetSalaryScale()
    return AppliedScale
end

exports('ApplySalaryScale', ApplySalaryScale)
exports('GetSalaryScale', GetSalaryScale)

-- qb-core 是依赖，正常已经起好；给 500ms 让 QBShared 填完，避免竞态下读到空表
CreateThread(function()
    Wait(500)
    ApplySalaryScale()
end)
