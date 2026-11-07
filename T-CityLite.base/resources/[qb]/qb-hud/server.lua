local QBCore = exports['qb-core']:GetCoreObject()

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

RegisterNetEvent('hud:server:GainStress', function(amount)
    if Config.DisableStress then return end
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
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
    TriggerClientEvent('QBCore:Notify', src, Lang:t('notify.stress_gain'), 'error', 1500)
end)

RegisterNetEvent('hud:server:RelieveStress', function(amount)
    if Config.DisableStress then return end
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

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
