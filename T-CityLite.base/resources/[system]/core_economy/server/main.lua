-- ============================================================================
-- core_economy — 统一经济奖励网关 (The One Gateway)  v2.0
-- ============================================================================
-- 设计铁律:
--   "全服务器所有产出金钱/物品/声望的脚本，绝对禁止硬编码奖励数值。
--    必须全部通过本网关的 exports['core_economy']:TriggerReward() 统一发放。"
--
-- 统一奖励公式:
--   final = floor( base × global_multiplier × heat_coefficient × player_bonus )
--
--   global_multiplier  — 管理员/自适应调节 (Convar economy_reward_scale)
--   heat_coefficient   — 单活动热度衰减 (高频→降, 冷门→升, 0.5~1.5)
--   player_bonus       — VIP/活动buff/身份加成 (玩家 metadata.player_bonus)
--
-- Exports:
--   TriggerReward(source, activityId, baseReward, options) → 统一奖励
--   PreviewReward(source, activityId, baseReward)          → UI 预览
--   GetGlobalMultiplier()                                   → 当前全局乘数
--   GetActivityHeat(activityId)                             → 当前活动热度
--   ResetAllHeat()                                          → 重置热度 (管理员)
-- ============================================================================

local QBCore = exports['qb-core']:GetCoreObject()

-- ── 内部状态: 活动热度追踪 ────────────────────────────────────────────

-- 热度数据结构: { [activityId] = { completions=N, heatCoefficient=0.5~1.5, lastReset=ts } }
local heatState = {}

-- 配置
local HEAT_WINDOW_MINUTES = 30
local HEAT_DECAY_RATE = 0.05
local HEAT_MIN = 0.5
local HEAT_MAX = 1.5
local HEAT_DEFAULT = 1.0

-- ── 热度衰减算法 ──────────────────────────────────────────────────────

---@param activityId string
---@return number coefficient 0.5~1.5
local function getHeatCoefficient(activityId)
    if not activityId then return HEAT_DEFAULT end

    if not heatState[activityId] then
        heatState[activityId] = {
            completions = 0,
            heatCoefficient = HEAT_DEFAULT,
            lastReset = os.time(),
        }
    end

    return heatState[activityId].heatCoefficient
end

---记录一次活动完成
---@param activityId string
---@param baseAmount number
local function recordActivity(activityId, baseAmount)
    if not activityId then return end

    if not heatState[activityId] then
        heatState[activityId] = { completions = 0, heatCoefficient = HEAT_DEFAULT, lastReset = os.time() }
    end

    heatState[activityId].completions = heatState[activityId].completions + 1
end

---衰减循环: 每 30 分钟执行一次
local function decayCycle()
    -- 收集所有活动
    local entries = {}
    for aid, state in pairs(heatState) do
        entries[#entries + 1] = { id = aid, completions = state.completions, ref = state }
    end

    if #entries == 0 then return end

    -- 计算平均完成次数
    local total = 0
    for _, e in ipairs(entries) do total = total + e.completions end
    local avg = total / #entries

    for _, e in ipairs(entries) do
        local old = e.ref.heatCoefficient
        if e.completions > avg * 1.2 then
            e.ref.heatCoefficient = math.max(HEAT_MIN, old - HEAT_DECAY_RATE)
        elseif e.completions < avg * 0.8 then
            e.ref.heatCoefficient = math.min(HEAT_MAX, old + HEAT_DECAY_RATE)
        else
            -- 回归 1.0
            if old > 1.0 then e.ref.heatCoefficient = math.max(1.0, old - HEAT_DECAY_RATE * 0.5)
            elseif old < 1.0 then e.ref.heatCoefficient = math.min(1.0, old + HEAT_DECAY_RATE * 0.5) end
        end

        -- 重置窗口
        e.ref.completions = 0
        e.ref.lastReset = os.time()
    end
end

-- 启动定时衰减
CreateThread(function()
    while true do
        Wait(HEAT_WINDOW_MINUTES * 60 * 1000)
        decayCycle()
    end
end)

-- ── 全局乘数 ──────────────────────────────────────────────────────────

local function getGlobalMultiplier()
    -- 优先级: Convar economy_global_multiplier (手动) > economy_reward_scale (自适应) > 1.0
    local manual = GetConvarInt('economy_global_multiplier', -1)
    if manual > 0 then return manual / 100.0 end

    local adaptive = GetConvarInt('economy_reward_scale', -1)
    if adaptive > 0 then return adaptive / 100.0 end

    return 1.0
end

---获取玩家个人加成
local function getPlayerBonus(source)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player or not Player.PlayerData or not Player.PlayerData.metadata then
        return 1.0
    end
    local bonus = tonumber(Player.PlayerData.metadata.player_bonus) or 1.0
    return math.max(0.5, math.min(3.0, bonus))
end

-- ── 公开 API: TriggerReward ───────────────────────────────────────────

---统一奖励发放 — 全服唯一入口
---@param source number            玩家服务器 ID
---@param activityId string         活动标识 (如 'mining', 'store_robbery', 'quest:bank_escort')
---@param baseReward number|table   基础奖励 (数字=纯发钱; 表=复合奖励)
---@param options? table            { moneytype='bank'|'cash'|'crypto', reason?, skipHeat?, skipEvents? }
---@return boolean ok
---@return number? finalAmount      实际发放金额
---@return number? heatCoefficient  应用的热度系数 (供 UI 显示)
function TriggerReward(source, activityId, baseReward, options)
    options = options or {}
    if not source or tonumber(source) == nil then return false end
    source = tonumber(source)
    if source <= 0 then return false end

    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return false end

    -- ── 计算三层系数 ──────────────────────────────────────────────
    local globalMult = getGlobalMultiplier()
    local heatCoeff = options.skipHeat and 1.0 or getHeatCoefficient(activityId or 'unknown')
    local playerBonus = getPlayerBonus(source)
    local finalMult = globalMult * heatCoeff * playerBonus

    local reason = options.reason or activityId or 'unknown'
    local totalGranted = 0

    -- ── 分发奖励 ──────────────────────────────────────────────────
    if type(baseReward) == 'number' then
        -- 纯金钱
        local moneytype = options.moneytype or 'bank'
        local finalAmount = math.floor(baseReward * finalMult)
        if finalAmount > 0 then
            local ok = EconomyService.AddMoney(Player.PlayerData.citizenid, moneytype, finalAmount, reason)
            if ok then totalGranted = finalAmount end
        end

    elseif type(baseReward) == 'table' then
        -- 复合奖励: 金钱 + 物品 + 声望
        if baseReward.money then
            for mt, amt in pairs(baseReward.money) do
                local finalAmount = math.floor(tonumber(amt) * finalMult)
                if finalAmount > 0 then
                    EconomyService.AddMoney(Player.PlayerData.citizenid, mt, finalAmount, reason)
                    totalGranted = totalGranted + finalAmount
                end
            end
        end

        if baseReward.items and GetResourceState('qb-inventory') ~= 'missing' then
            for _, item in ipairs(baseReward.items) do
                exports['qb-inventory']:AddItem(source, item.name, item.amount or 1, false, item.info)
            end
        end

        if baseReward.rep then
            for repType, repAmt in pairs(baseReward.rep) do
                Player.Functions.AddRep(repType, tonumber(repAmt) or 0)
            end
        end
    end

    -- ── 记录活动热度 ──────────────────────────────────────────────
    if not options.skipHeat and activityId then
        local baseAmount = type(baseReward) == 'number' and baseReward or totalGranted
        recordActivity(activityId, baseAmount)
    end

    -- ── 广播事件 ──────────────────────────────────────────────────
    if not options.skipEvents then
        TriggerEvent('core_economy:rewardGranted', source, activityId or 'unknown', totalGranted, finalMult)
    end

    return true, totalGranted, heatCoeff
end

-- ── 辅助 Exports ──────────────────────────────────────────────────────

local function previewReward(source, activityId, baseReward)
    local globalMult = getGlobalMultiplier()
    local heatCoeff = getHeatCoefficient(activityId or 'unknown')
    local playerBonus = getPlayerBonus(source)
    local finalMult = globalMult * heatCoeff * playerBonus
    return math.floor((baseReward or 0) * finalMult), {
        globalMultiplier = globalMult,
        heatCoefficient = heatCoeff,
        playerBonus = playerBonus,
        finalMultiplier = finalMult,
    }
end

local function getGlobalMultiplier_export()
    return getGlobalMultiplier()
end

local function getActivityHeat_export(activityId)
    return getHeatCoefficient(activityId)
end

local function resetAllHeat_export()
    heatState = {}
    print('[core_economy] All activity heat reset by administrator')
end

-- ── 注册 Exports ──────────────────────────────────────────────────────

exports('TriggerReward', TriggerReward)
exports('PreviewReward', previewReward)
exports('GetGlobalMultiplier', getGlobalMultiplier_export)
exports('GetActivityHeat', getActivityHeat_export)
exports('ResetAllHeat', resetAllHeat_export)

-- ── 注册到 Bus ────────────────────────────────────────────────────────

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        if not _G.Bus then _G.Bus = {} end
        _G.Bus.CoreEconomy = {
            TriggerReward = TriggerReward,
            PreviewReward = previewReward,
            GetGlobalMultiplier = getGlobalMultiplier_export,
            GetActivityHeat = getActivityHeat_export,
            ResetAllHeat = resetAllHeat_export,
        }
        print('[core_economy] ✅ Unified Reward Gateway v2.0 started')
        print('[core_economy]    Formula: final = base × global(%.2f) × heat × bonus', getGlobalMultiplier())
    end
end)
