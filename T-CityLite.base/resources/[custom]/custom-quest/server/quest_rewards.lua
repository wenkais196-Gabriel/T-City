-- quest_rewards.lua — 任务奖励分发器
--
-- 统一通过 AddScaledMoney 出口发放奖励
-- 支持: 金钱 + 物品 + （未来）经验/技能
--
-- 设计原则: 100% 经统一经济出口，带审计日志

QuestRewards = QuestRewards or {}

local QBCore = exports['qb-core']:GetCoreObject()

--- 发放任务奖励
---@param source number 玩家 source
---@param rewards table 奖励配置 { money = {...}, items = {...} }
---@param questId string 任务 ID（审计用）
---@return boolean success
function QuestRewards.GrantRewards(source, rewards, questId)
    if not rewards then return true end

    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return false end

    local citizenid = Player.PlayerData.citizenid
    local granted = {}

    -- 1. 金钱奖励（v0.7.2: 物流非自有车抽成）
    if rewards.money then
        local minAmount = rewards.money.min or 0
        local maxAmount = rewards.money.max or minAmount
        local amount = minAmount
        if maxAmount > minAmount then
            amount = math.random(minAmount, maxAmount)
        end
        local accountType = rewards.money.type or Config.Quest.Rewards.DefaultAccountType

        -- v0.7.2: 物流任务非自有车收益打折
        if GetLogisticsBinding then
            local binding = GetLogisticsBinding(citizenid, questId)
            if binding and binding.isRental and binding.rentalFeePct > 0 then
                local cut = math.floor(amount * binding.rentalFeePct / 100)
                amount = amount - cut
                TriggerClientEvent('QBCore:Notify', source,
                    ('📋 非自有车抽成 %d%% (-$%d)'):format(binding.rentalFeePct, cut), 'primary')
            end
        end

        -- v0.8a: 货物损伤扣减（CalculateCargoDamagePenalty 来自 logistics_validators）
        local damageMultiplier = 1.0
        if CalculateCargoDamagePenalty then
            local dmgMult, dmgNote = CalculateCargoDamagePenalty(citizenid, questId)
            if dmgMult and dmgMult < 1.0 then
                damageMultiplier = dmgMult
                if dmgNote then
                    TriggerClientEvent('QBCore:Notify', source, dmgNote, 'error')
                end
            end
        end

        -- v0.8a: 时效奖惩（CalculateTimeBonus 来自 logistics_validators）
        local timeMultiplier = 1.0
        if CalculateTimeBonus then
            local timeMult, timeNote = CalculateTimeBonus(citizenid, questId)
            if timeMult then
                timeMultiplier = timeMult
                if timeNote then
                    local notifyType = timeMult >= 1.0 and 'success' or 'error'
                    TriggerClientEvent('QBCore:Notify', source, timeNote, notifyType)
                end
            end
        end

        -- 应用损伤 + 时效倍率
        local finalAmount = math.floor(amount * damageMultiplier * timeMultiplier + 0.5)
        if finalAmount < 1 then finalAmount = 1 end

        -- 如有修正，追加通知
        if finalAmount ~= amount then
            local delta = finalAmount - amount
            if delta > 0 then
                TriggerClientEvent('QBCore:Notify', source,
                    ('📊 时效+货物修正：+$%d'):format(delta), 'success')
            else
                TriggerClientEvent('QBCore:Notify', source,
                    ('📊 时效+货物修正：-$%d'):format(math.abs(delta)), 'error')
            end
        end

        if finalAmount > 0 then
            -- v0.7.2: 优先 custom-economy，fallback custom-main，再 fallback QBCore
            local useScaled = false
            if Config.Quest.Rewards.UseAddScaledMoney then
                if exports['custom-economy'] and exports['custom-economy'].AddScaledMoney then
                    exports['custom-economy']:AddScaledMoney(source, accountType, finalAmount, ('quest:%s'):format(questId))
                    useScaled = true
                elseif exports['custom-main'] and exports['custom-main'].AddScaledMoney then
                    exports['custom-main']:AddScaledMoney(source, accountType, finalAmount, ('quest:%s'):format(questId))
                    useScaled = true
                end
            end
            if not useScaled then
                Player.Functions.AddMoney(accountType, finalAmount, ('quest:%s'):format(questId))
            end
            table.insert(granted, ('$%d (%s)'):format(finalAmount, accountType))
        end
    end

    -- 2. 物品奖励
    if rewards.items then
        for _, itemReward in ipairs(rewards.items) do
            if itemReward.name and itemReward.count then
                local count = tonumber(itemReward.count) or 1
                if count > 0 then
                    Player.Functions.AddItem(itemReward.name, count)
                    table.insert(granted, ('%s x%d'):format(itemReward.name, count))
                end
            end
        end
    end

    -- 3. v0.7.0: 声望（Reputation）奖励
    if rewards.rep then
        for repType, amount in pairs(rewards.rep) do
            local repAmount = tonumber(amount) or 0
            if repAmount > 0 then
                Player.Functions.AddRep(repType, repAmount)
                table.insert(granted, ('%s rep +%d'):format(repType, repAmount))
            end
        end
    end

    -- 4. 审计日志
    if #granted > 0 then
        local logText = ('**%s** (%s) | Quest: %s | Rewards: %s'):format(
            GetPlayerName(source), citizenid, questId,
            table.concat(granted, ', ')
        )
        if exports['custom-logs'] then
            exports['custom-logs']:LogGeneric('任务奖励发放', logText, 65280)
        end

        TriggerClientEvent('QBCore:Notify', source,
            ('💰 任务结算 | %s'):format(table.concat(granted, ' | ')), 'success')
    end

    return true
end

print('[quest-rewards] ✅ 任务奖励分发器已加载 (v0.7.0)')
print('[quest-rewards]   统一出口: AddScaledMoney + AddItem + AddRep')