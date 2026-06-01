local QBCore = exports['qb-core']:GetCoreObject()

-- 经济运行状态
local EconomyState = {
    TotalEarned = 0,
    TotalSpent = 0,
    Events = 0,
    RewardScale = QBConfig.Custom.Economy.RewardScale or 1.0,
    PriceScale = QBConfig.Custom.Economy.PriceScale or 1.0
}

-- 辅助函数：输出调试日志
local function DebugPrint(msg)
    if QBConfig.Custom.General.EnableDebug then
        print(('[custom-main][economy] %s'):format(msg))
    end
end

-- ==========================================
--                  公 开 导 出
-- ==========================================

-- 1. 获取当前全服的奖励倍率
local function GetEconomyRewardScale()
    return EconomyState.RewardScale
end

exports('GetEconomyRewardScale', GetEconomyRewardScale)

-- 2. 获取当前全服的价格倍率
local function GetEconomyPriceScale()
    return EconomyState.PriceScale
end

exports('GetEconomyPriceScale', GetEconomyPriceScale)

-- 3. 统一的高价值资金发放出口 (AddScaledMoney)
-- @param src number 玩家服务器 ID
-- @param moneytype string 钱包类型 ('cash' / 'bank' / 'crypto')
-- @param baseAmount number 基础发放额度
-- @param reason string 资金来源描述
-- @return finalAmount number, scale number 发放后的最终金额与当时倍率
local function AddScaledMoney(src, moneytype, baseAmount, reason)
    reason = reason or "unknown-rewards"
    moneytype = moneytype:lower()
    baseAmount = tonumber(baseAmount) or 0
    if baseAmount <= 0 then return 0, 1.0 end

    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return 0, 1.0 end

    -- 使用当前的动态奖励倍率缩放资金
    local scale = EconomyState.RewardScale or 1.0
    local finalAmount = math.floor(baseAmount * scale + 0.5)

    -- 执行资金给予
    Player.Functions.AddMoney(moneytype, finalAmount, reason)

    DebugPrint(("AddScaledMoney: Player=%s, Type=%s, BaseAmount=%s, ScaledAmount=%s, Scale=%.2f, Reason=%s"):format(
        GetPlayerName(src), moneytype, baseAmount, finalAmount, scale, reason
    ))

    -- 审计高额或常规变化
    local auditText = ("**玩家**: %s (%s)\n**类型**: %s\n**原始金额**: $%d\n**结算金额**: $%d (倍率: %.2f)\n**原因**: %s"):format(
        GetPlayerName(src), Player.PlayerData.citizenid, moneytype, baseAmount, finalAmount, scale, reason
    )
    
    if finalAmount >= 20000 then
        -- 绿金高额警报，高亮显示
        exports['custom-main']:LogEconomy("大额资金发放", auditText, 65280) -- 绿色
    else
        exports['custom-main']:LogEconomy("常规资金结算", auditText, 4289797) -- 翡翠绿
    end

    return finalAmount, scale
end

exports('AddScaledMoney', AddScaledMoney)

-- ==========================================
--               资 金 流 向 统 计
-- ==========================================

-- 拦截 OnMoneyChange 全服统计流向
AddEventHandler('QBCore:Server:OnMoneyChange', function(src, moneytype, amount, action, reason)
    if not QBConfig.Custom.Economy.Enable then return end

    amount = tonumber(amount) or 0
    if amount <= 0 then return end

    if action == 'add' then
        EconomyState.TotalEarned = EconomyState.TotalEarned + amount
    elseif action == 'remove' then
        EconomyState.TotalSpent = EconomyState.TotalSpent + amount
    end

    EconomyState.Events = EconomyState.Events + 1
end)

-- ==========================================
--               自 适 应 调 节 环 境
-- ==========================================

CreateThread(function()
    local cfg = QBConfig.Custom.Economy
    if not cfg.Enable or cfg.SampleWindowMinutes <= 0 then 
        DebugPrint("自适应经济调节已禁用 (SampleWindowMinutes = 0 或 Enable = false)")
        return 
    end

    while true do
        local intervalMs = cfg.SampleWindowMinutes * 60 * 1000
        Wait(intervalMs)

        local totalEarned = EconomyState.TotalEarned
        local totalSpent = EconomyState.TotalSpent
        local netFlow = totalEarned - totalSpent
        local oldScale = EconomyState.RewardScale
        local newScale = oldScale

        DebugPrint(("经济体检周期触发: 全服总流入=%d, 总流出=%d, 净流向=%d, 当前倍率=%.2f"):format(
            totalEarned, totalSpent, netFlow, oldScale
        ))

        -- 判定自适应微调逻辑
        if netFlow > cfg.HighInflationNetPerHour then
            -- 偏向通胀：轻微降低全服结算奖励
            newScale = math.max(cfg.MinRewardScale, oldScale - cfg.RewardScaleStep)
        elseif netFlow < cfg.LowActivityNetPerHour then
            -- 偏向冷清：轻微调高全服结算奖励以做刺激
            newScale = math.min(cfg.MaxRewardScale, oldScale + cfg.RewardScaleStep)
        end

        -- 重置流向统计
        EconomyState.TotalEarned = 0
        EconomyState.TotalSpent = 0
        EconomyState.Events = 0
        EconomyState.RewardScale = newScale

        -- 记录调整日志
        if math.abs(newScale - oldScale) > 0.0001 then
            local auditText = ("**体检周期资金流动**:\n全服流入: $%d\n全服流出: $%d\n净差额: $%d\n\n**奖励倍率变化**: 从 %.2f 调整至 %.2f"):format(
                totalEarned, totalSpent, netFlow, oldScale, newScale
            )
            exports['custom-main']:LogEconomy("自适应经济倍率微调", auditText, 16776960) -- 黄色
        else
            DebugPrint(("经济体平衡，奖励倍率维持 %.2f 不变"):format(oldScale))
        end
    end
end)
