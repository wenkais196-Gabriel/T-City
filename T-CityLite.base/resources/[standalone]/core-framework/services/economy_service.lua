-- economy_service.lua — 经济统一服务
-- 从 custom-economy 提取核心逻辑，作为独立 Service 注册到 Bus

local QBCore = exports['qb-core']:GetCoreObject()

local EconomyService = {}

-- ⚡ Cache: wageMultiplier convar lookup (avoids convar read on every money operation)
local cachedWageMultiplier = nil
local wageMultiplierExpiry = 0
local WAGE_MULTIPLIER_CACHE_TTL = 60

local function getWageMultiplier()
    local now = os.time()
    if cachedWageMultiplier and now < wageMultiplierExpiry then
        return cachedWageMultiplier
    end
    cachedWageMultiplier = GetConvarInt('economy_wage_multiplier', 100) / 100
    if cachedWageMultiplier < 0 then cachedWageMultiplier = 1.0 end
    wageMultiplierExpiry = now + WAGE_MULTIPLIER_CACHE_TTL
    return cachedWageMultiplier
end

-- ----------------------------------------------------
-- 获取玩家余额（内存优先）
-- ----------------------------------------------------
function EconomyService.GetBalance(source, accountType)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return 0 end
    if not accountType then
        return Player.PlayerData.money
    end
    return Player.PlayerData.money[accountType] or 0
end

-- ----------------------------------------------------
-- 带倍率缩放的加钱（统一出口）
-- ----------------------------------------------------
function EconomyService.AddScaled(source, accountType, amount, reason)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return 0, 1.0 end

    amount = tonumber(amount) or 0
    if amount <= 0 then return 0, 1.0 end

    -- 获取全局经济倍率（60s 缓存，避免每次操作读 convar）
    local wageMultiplier = getWageMultiplier()

    local scaledAmount = QBCore.Shared.Round(amount * wageMultiplier)
    if scaledAmount <= 0 then scaledAmount = amount end

    -- 走原生 AddMoney（自带 dirty 标记 + 事件触发）
    local success = Player.Functions.AddMoney(accountType, scaledAmount, reason or 'EconomyService.AddScaled')
    if not success then
        return 0, wageMultiplier
    end

    -- 标记脏数据
    if DirtyFlush then
        DirtyFlush.MarkDirty(Player.PlayerData.citizenid, 'money')
    end

    -- 审计日志（大额交易）
    if scaledAmount > 100000 and exports['custom-logs'] then
        exports['custom-logs']:LogEconomy('AddScaled', string.format(
            '**%s** (%s) | +$%d (%s) | Scale: %.2fx',
            GetPlayerName(source), Player.PlayerData.citizenid,
            scaledAmount, reason or 'unknown', wageMultiplier
        ), 65280)
    end

    return scaledAmount, wageMultiplier
end

-- ----------------------------------------------------
-- 玩家间转账（带安全校验）
-- ----------------------------------------------------
function EconomyService.Transfer(fromSource, toCitizenId, amount, reason)
    local fromPlayer = QBCore.Functions.GetPlayer(fromSource)
    if not fromPlayer then return false, 'Sender not found' end

    amount = tonumber(amount) or 0
    if amount <= 0 then return false, 'Invalid amount' end

    -- 自转拦截
    if fromPlayer.PlayerData.citizenid == toCitizenId then
        return false, 'Cannot transfer to yourself'
    end

    -- 余额检查
    if fromPlayer.PlayerData.money.bank < amount then
        return false, 'Insufficient funds'
    end

    -- 先扣发送方
    local deductSuccess = fromPlayer.Functions.RemoveMoney('bank', amount, 'Transfer: ' .. (reason or 'unknown'))
    if not deductSuccess then
        return false, 'Deduction failed'
    end

    -- 标记脏数据
    if DirtyFlush then
        DirtyFlush.MarkDirty(fromPlayer.PlayerData.citizenid, 'money')
    end

    -- 找接收方（在线）
    local toPlayer = QBCore.Functions.GetPlayerByCitizenId(toCitizenId)
    if toPlayer then
        toPlayer.Functions.AddMoney('bank', amount, 'Received: ' .. (reason or 'unknown'))
        if DirtyFlush then
            DirtyFlush.MarkDirty(toCitizenId, 'money')
        end
        return true, 'Transferred to online player'
    end

    -- ⚡ 接收方离线 → 异步写 DB（不阻塞回调线程）
    MySQL.update(
        'UPDATE players SET money = JSON_SET(money, "$.bank", JSON_EXTRACT(money, "$.bank") + ?) WHERE citizenid = ?',
        { amount, toCitizenId },
        function(affectedRows)
            if not affectedRows or affectedRows == 0 then
                -- 回滚
                fromPlayer.Functions.AddMoney('bank', amount, 'Transfer rollback: ' .. (reason or 'unknown'))
                print(('[economy_service] ❌ Offline transfer rollback for %s → %s: $%d'):format(
                    fromPlayer.PlayerData.citizenid, toCitizenId, amount))
            end
        end
    )

    return true, 'Transferred to offline player (async DB)'
end

-- ----------------------------------------------------
-- 注册到 Bus
-- ----------------------------------------------------
if Bus and Bus.RegisterService then
    Bus.RegisterService('economy', {
        GetBalance  = EconomyService.GetBalance,
        AddScaled   = EconomyService.AddScaled,
        Transfer    = EconomyService.Transfer,
    })
end

-- economy-service startup prints removed (production mode)
