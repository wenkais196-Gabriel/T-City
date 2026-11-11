local QBCore = exports['qb-core']:GetCoreObject()

-- 压力提示限流（每 source 30 秒最多一条，见 GainStress）
local stressNoticeAt = {}

-- qb-core 重启后，上面这份快照里的函数引用会全部失效（P1-6，PR #196）：
-- 本资源没有声明 qb-core 依赖，不会被重启级联带走，所以在 qb-core 起来时重解析一次。
AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= 'qb-core' then return end
    -- ⚠️ 不能在事件里同步调：真机实测此刻 export 引用可能还指向 qb-core 旧 script host，
    -- 会抛 `Execution of function reference in script host failed`。放线程里重试到拿到新表。
    CreateThread(function()
        for _ = 1, 30 do
            local ok, core = pcall(function() return exports['qb-core']:GetCoreObject() end)
            if ok and core then
                QBCore = core
                return
            end
            Wait(500)
        end
    end)
end)

QBCore.Commands.Add('cash', 'Check Cash Balance', {}, false, function(source, _)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end -- 控制台 (source=0) 或本帧刚掉线时 GetPlayer 为 nil
    local cashamount = Player.PlayerData.money.cash
    TriggerClientEvent('hud:client:ShowAccounts', source, 'cash', cashamount)
end)

QBCore.Commands.Add('bank', 'Check Bank Balance', {}, false, function(source, _)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end -- 控制台 (source=0) 或本帧刚掉线时 GetPlayer 为 nil
    local bankamount = Player.PlayerData.money.bank
    TriggerClientEvent('hud:client:ShowAccounts', source, 'bank', bankamount)
end)

QBCore.Commands.Add('dev', 'Enable/Disable developer Mode', {}, false, function(source, _)
    TriggerClientEvent('qb-admin:client:ToggleDevmode', source)
end, 'admin')

-- `amount` 来自客户端（client.lua 里是 math.random(1,3)，但事件本身谁都能发）：
-- 表/字符串会让 `currentStress + amount` 直接抛错，超大数字可以一键把压力拉满（或反向清零）。
local MAX_STRESS_STEP = 100

local function sanitizeStressStep(amount)
    local step = tonumber(amount)
    if not step or step <= 0 then return nil end
    if step > MAX_STRESS_STEP then step = MAX_STRESS_STEP end
    return step
end

RegisterNetEvent('hud:server:GainStress', function(amount)
    if Config.DisableStress then return end
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local step = sanitizeStressStep(amount)
    if not step then return end
    amount = step
    local job = Player.PlayerData.job
    if not job then return end
    if Config.WhitelistedJobs[job.type] or Config.WhitelistedJobs[job.name] then return end

    local meta = Player.PlayerData.metadata
    local currentStress = meta.stress or 0
    local newStress = currentStress + amount
    if newStress < 0 then newStress = 0 end
    if newStress > 100 then newStress = 100 end

    Player.Functions.SetMetaData('stress', newStress)
    TriggerClientEvent('hud:client:UpdateStress', src, newStress)
    -- CC 实测：射击时客户端按 10% 概率发 GainStress，扣一次扳机就能触发多条，
    -- 而这里每收一条就弹一次 error —— 玩家看到的是"压力+1"刷屏。
    -- 改成每 30 秒最多一条；真正的告警交给客户端的 H-2（压力 ≥80 才提醒）。
    local now = os.time()
    if not stressNoticeAt[src] or now - stressNoticeAt[src] >= 30 then
        stressNoticeAt[src] = now
        TriggerClientEvent('QBCore:Notify', src, Lang:t('notify.stress_gain'), 'error', 1500)
    end
end)

RegisterNetEvent('hud:server:RelieveStress', function(amount)
    if Config.DisableStress then return end
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local step = sanitizeStressStep(amount)
    if not step then return end
    amount = step

    local meta = Player.PlayerData.metadata
    local currentStress = meta.stress or 0
    local newStress = currentStress - amount
    if newStress < 0 then newStress = 0 end
    if newStress > 100 then newStress = 100 end

    Player.Functions.SetMetaData('stress', newStress)
    TriggerClientEvent('hud:client:UpdateStress', src, newStress)
    TriggerClientEvent('QBCore:Notify', src, Lang:t('notify.stress_removed'))
end)

QBCore.Functions.CreateCallback('hud:server:getMenu', function(_, cb)
    cb(Config.Menu)
end)
