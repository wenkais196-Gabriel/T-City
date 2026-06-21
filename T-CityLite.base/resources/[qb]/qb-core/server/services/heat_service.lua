-- ============================================================================
-- HeatService — 活动热度追踪引擎
-- ============================================================================
-- 核心原理:
--   "买多升，卖多降" — 高频完成的活动收益自动衰减，冷门活动收益自动翘起
--   引导玩家自发分散到不同产业链环节，减少策划人工干预
--
-- 数据结构:
--   activities[activityId] = {
--     completions = N,        -- 当前窗口内完成次数
--     totalBaseReward = M,    -- 当前窗口内累计基础奖励
--     lastReset = timestamp,  -- 上次窗口重置时间
--     heatCoefficient = 0.5~1.5,  -- 当前热度系数
--   }
--
-- 衰减算法:
--   每 sampleWindowMinutes 分钟:
--     - 统计所有活动的平均完成次数
--     - 高于平均的热门活动: heatCoefficient -= decayRate (地板 0.5)
--     - 低于平均的冷门活动: heatCoefficient += decayRate (天花板 1.5)
--     - 重置计数器
-- ============================================================================

local HeatService = {}

-- ── 配置 (从 QBConfig.Economy.Heat 读取) ────────────────────────────

HeatService.SAMPLE_WINDOW_MINUTES = 30
HeatService.DECAY_RATE = 0.05
HeatService.MIN_COEFFICIENT = 0.5
HeatService.MAX_COEFFICIENT = 1.5
HeatService.DEFAULT_COEFFICIENT = 1.0

-- ── 内部状态 ──────────────────────────────────────────────────────────

-- 活动热度数据
local activities = {}

-- 定时器句柄
local decayTimer = nil

-- 是否正在处理中
local isProcessing = false

-- ── 内部: 加载配置 ────────────────────────────────────────────────────

local function loadConfig()
    local econConfig = QBCore.Config.Economy
    if not econConfig or not econConfig.Heat then return end

    local heat = econConfig.Heat
    HeatService.SAMPLE_WINDOW_MINUTES = heat.sampleWindowMinutes or HeatService.SAMPLE_WINDOW_MINUTES
    HeatService.DECAY_RATE = heat.decayRate or HeatService.DECAY_RATE
    HeatService.MIN_COEFFICIENT = heat.minCoefficient or HeatService.MIN_COEFFICIENT
    HeatService.MAX_COEFFICIENT = heat.maxCoefficient or HeatService.MAX_COEFFICIENT
    HeatService.DEFAULT_COEFFICIENT = heat.defaultCoefficient or HeatService.DEFAULT_COEFFICIENT
end

---确保活动条目存在
---@param activityId string
local function ensureActivity(activityId)
    if not activities[activityId] then
        activities[activityId] = {
            completions = 0,
            totalBaseReward = 0,
            lastReset = os.time(),
            heatCoefficient = HeatService.DEFAULT_COEFFICIENT,
        }
    end
    return activities[activityId]
end

-- ── 公开 API ──────────────────────────────────────────────────────────

---记录一次活动完成 (每次有奖励发放时调用)
--- 当 core_economy 可用时，热度追踪由其内部的 TriggerReward 自动完成；
--- 此处仅作为 fallback（core_economy 未加载时）
---@param activityId string 活动标识 (如 'mining', 'taxi_mission', 'store_robbery')
---@param baseReward number 本次活动的基础奖励金额
function HeatService.RecordActivity(activityId, baseReward)
    -- 🔄 Unified: core_economy tracks activity via TriggerReward internally
    -- This fallback is only used when core_economy is not loaded
    if not activityId then
        activityId = 'unknown'
    end

    local act = ensureActivity(activityId)
    act.completions = act.completions + 1
    act.totalBaseReward = act.totalBaseReward + (tonumber(baseReward) or 0)
end

---获取活动当前热度系数（优先委托到 core_economy 统一热度源）
---@param activityId string
---@return number coefficient (0.5 ~ 1.5)
function HeatService.GetHeatCoefficient(activityId)
    -- 🔄 Unified: delegate to core_economy if available (single source of truth)
    local ce = _G.Bus and _G.Bus.CoreEconomy
    if ce and ce.GetActivityHeat then
        return ce.GetActivityHeat(activityId)
    end

    if not activityId then
        return HeatService.DEFAULT_COEFFICIENT
    end

    local act = activities[activityId]
    if not act then
        return HeatService.DEFAULT_COEFFICIENT
    end

    return act.heatCoefficient
end

---获取全服活动热度快照 (供任务系统/经济看板使用)
---@return table { [activityId] = { completions, totalBaseReward, heatCoefficient }, ... }
function HeatService.GetGlobalHeatSnapshot()
    local snapshot = {}
    for activityId, act in pairs(activities) do
        snapshot[activityId] = {
            completions = act.completions,
            totalBaseReward = act.totalBaseReward,
            heatCoefficient = act.heatCoefficient,
        }
    end
    return snapshot
end

---获取全服平均热度系数 (供自适应调节 Loop 使用)
---@return number avgCoefficient
function HeatService.GetGlobalAverageHeat()
    local total = 0
    local count = 0
    for _, act in pairs(activities) do
        total = total + act.heatCoefficient
        count = count + 1
    end
    if count == 0 then return HeatService.DEFAULT_COEFFICIENT end
    return total / count
end

---获取最热门和最冷门的活动 (供任务系统生成自适应任务)
---@return table|nil hottest {activityId, heatCoefficient}
---@return table|nil coldest {activityId, heatCoefficient}
function HeatService.GetExtremes()
    local hottest, coldest = nil, nil

    for activityId, act in pairs(activities) do
        if not hottest or act.heatCoefficient < hottest.heatCoefficient then
            hottest = { activityId = activityId, heatCoefficient = act.heatCoefficient }
        end
        if not coldest or act.heatCoefficient > coldest.heatCoefficient then
            coldest = { activityId = activityId, heatCoefficient = act.heatCoefficient }
        end
    end

    return hottest, coldest
end

---管理员手动重置某项活动的热度 (冷启动用)
---@param activityId string|nil nil = 全部重置
function HeatService.ResetHeat(activityId)
    if activityId then
        activities[activityId] = nil
        print(('[HeatService] Reset heat for: %s'):format(activityId))
    else
        activities = {}
        print('[HeatService] Reset ALL activity heat')
    end
end

---管理员手动设置某项活动的热度系数
---@param activityId string
---@param coefficient number
function HeatService.SetCoefficient(activityId, coefficient)
    if not activityId then return end
    coefficient = tonumber(coefficient) or HeatService.DEFAULT_COEFFICIENT
    if coefficient < HeatService.MIN_COEFFICIENT then coefficient = HeatService.MIN_COEFFICIENT end
    if coefficient > HeatService.MAX_COEFFICIENT then coefficient = HeatService.MAX_COEFFICIENT end

    local act = ensureActivity(activityId)
    act.heatCoefficient = coefficient
    print(('[HeatService] Set coefficient for %s: %.2f'):format(activityId, coefficient))
end

-- ── 核心: 定时衰减 Tick ──────────────────────────────────────────────

---执行一次衰减计算
local function runDecayCycle()
    if isProcessing then return end
    isProcessing = true

    local activityList = {}
    local totalCompletions = 0
    local count = 0

    -- 第一遍: 收集数据
    for activityId, act in pairs(activities) do
        count = count + 1
        totalCompletions = totalCompletions + act.completions
        activityList[#activityList + 1] = {
            id = activityId,
            completions = act.completions,
            ref = act,
        }
    end

    if count == 0 then
        isProcessing = false
        return
    end

    local avgCompletions = totalCompletions / count

    -- 第二遍: 调整系数
    local adjustments = 0
    for _, entry in ipairs(activityList) do
        local act = entry.ref
        local oldCoeff = act.heatCoefficient

        if entry.completions > avgCompletions * 1.2 then
            -- 热门活动: 降系数
            act.heatCoefficient = math.max(
                HeatService.MIN_COEFFICIENT,
                act.heatCoefficient - HeatService.DECAY_RATE
            )
        elseif entry.completions < avgCompletions * 0.8 then
            -- 冷门活动: 升系数
            act.heatCoefficient = math.min(
                HeatService.MAX_COEFFICIENT,
                act.heatCoefficient + HeatService.DECAY_RATE
            )
        else
            -- 中等活动: 向 1.0 回归
            if act.heatCoefficient > 1.0 then
                act.heatCoefficient = math.max(1.0, act.heatCoefficient - HeatService.DECAY_RATE * 0.5)
            elseif act.heatCoefficient < 1.0 then
                act.heatCoefficient = math.min(1.0, act.heatCoefficient + HeatService.DECAY_RATE * 0.5)
            end
        end

        if oldCoeff ~= act.heatCoefficient then
            adjustments = adjustments + 1
        end

        -- 重置窗口计数器
        act.completions = 0
        act.totalBaseReward = 0
        act.lastReset = os.time()
    end

    if adjustments > 0 then
        print(('[HeatService] Decay cycle: %d activities adjusted (avg completions: %.1f)'):format(adjustments, avgCompletions))
    end

    isProcessing = false
end

---启动定时衰减
local function startDecayTick()
    local intervalMs = HeatService.SAMPLE_WINDOW_MINUTES * 60 * 1000

    local function tick()
        runDecayCycle()
        decayTimer = SetTimeout(intervalMs, tick)
    end

    decayTimer = SetTimeout(intervalMs, tick)
    print(('[HeatService] Decay tick started (interval: %d min, decay: %.2f, range: %.1f-%.1f)')
        :format(HeatService.SAMPLE_WINDOW_MINUTES, HeatService.DECAY_RATE,
                HeatService.MIN_COEFFICIENT, HeatService.MAX_COEFFICIENT))
end

-- ── 生命周期 ──────────────────────────────────────────────────────────

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        loadConfig()

        if not _G.Bus then _G.Bus = {} end
        _G.Bus.HeatService = HeatService

        -- 🔄 Unified: skip own decay tick if core_economy is available (it has its own)
        local ce = _G.Bus.CoreEconomy
        if ce and ce.GetActivityHeat then
            print('[HeatService] ✅ Skipping decay tick — delegated to core_economy')
        else
            startDecayTick()
        end
        print('[HeatService] Registered to _G.Bus.HeatService')
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        if decayTimer then
            decayTimer = nil
        end
    end
end)

-- 立即可用
if not _G.Bus then _G.Bus = {} end
_G.Bus.HeatService = HeatService
