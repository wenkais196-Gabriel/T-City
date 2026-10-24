local QBCore = exports['qb-core']:GetCoreObject()
local GotItems = {}
local AlarmActivated = false

-- One-shot restore marker for seized items. Reset when a new custodial
-- sentence starts, consumed by the first GiveJailItems after release.
local JailItemsRestored = {}

-- qb-prison no longer owns the clock. custom-justice's `justice_sentences` row
-- is authoritative; this event only projects the server-side remaining time
-- into `metadata.injail` (the value qb-prison restores from on reconnect).
RegisterNetEvent('prison:server:SetJailStatus', function(jailTime)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local metadata = Player.PlayerData.metadata or {}
    local cid = Player.PlayerData.citizenid

    local lookedUp, remainingSeconds = pcall(function()
        return exports['custom-justice']:RemainingSeconds(cid)
    end)

    local remainingMinutes
    if lookedUp and type(remainingSeconds) == 'number' then
        -- Never trust the client-supplied jailTime when the authority answers.
        remainingSeconds = math.max(0, math.floor(remainingSeconds))
        remainingMinutes = math.ceil(remainingSeconds / 60)
    else
        -- Justice unavailable: keep the legacy path, but bounded. Without
        -- this clamp a client could still set an arbitrary sentence.
        remainingMinutes = math.floor(tonumber(jailTime) or 0)
        remainingMinutes = math.max(0, math.min(120, remainingMinutes))
    end

    if remainingMinutes <= 0 then
        Player.Functions.SetMetaData('injail', 0)
        GotItems[src] = nil
        return
    end

    Player.Functions.SetMetaData('injail', remainingMinutes)
    JailItemsRestored[src] = nil

    if Player.PlayerData.job.name ~= 'unemployed' then
        Player.Functions.SetJob('unemployed')
        TriggerClientEvent('QBCore:Notify', src, Lang:t('info.lost_job'))
    end
end)

RegisterNetEvent('prison:server:SaveJailItems', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local metadata = Player.PlayerData.metadata or {}
    -- Items can only be seized while a sentence is active. Previously a free
    -- player could loop Save/Give to farm the $80 jail stipend.
    if (metadata.injail or 0) <= 0 then return end
    if not Player.PlayerData.metadata['jailitems'] or table.type(Player.PlayerData.metadata['jailitems']) == 'empty' then
        Player.Functions.SetMetaData('jailitems', Player.PlayerData.items)
        Player.Functions.AddMoney('cash', 80, 'jail money')
        Wait(2000)
        Player.Functions.ClearInventory()
        -- A new sentence starts a fresh one-shot restore window.
        JailItemsRestored[src] = nil
    end
end)

RegisterNetEvent('prison:server:GiveJailItems', function(escaped)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local metadata = Player.PlayerData.metadata or {}
    local jailItems = metadata['jailitems']
    local hasSeizedItems = type(jailItems) == 'table' and next(jailItems) ~= nil

    -- On release metadata.injail is already 0 when the client asks for its
    -- items back. Allow exactly one restoration of a non-empty snapshot and
    -- never while free with nothing to restore.
    if (metadata.injail or 0) <= 0 and not hasSeizedItems then return end
    if JailItemsRestored[src] or not hasSeizedItems then return end
    JailItemsRestored[src] = true

    if escaped then
        Player.Functions.SetMetaData('jailitems', {})
        return
    end
    for _, v in pairs(jailItems) do
        exports['qb-inventory']:AddItem(src, v.name, v.amount, false, v.info, 'prison:server:GiveJailItems')
    end
    Player.Functions.SetMetaData('jailitems', {})
end)

RegisterNetEvent('prison:server:ResetJailItems', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local metadata = Player.PlayerData.metadata or {}
    if (metadata.injail or 0) <= 0 then return end
    Player.Functions.SetMetaData('jailitems', {})
end)

RegisterNetEvent('prison:server:SecurityLockdown', function()
    TriggerClientEvent('prison:client:SetLockDown', -1, true)
    for _, v in pairs(QBCore.Functions.GetPlayers()) do
        local Player = QBCore.Functions.GetPlayer(v)
        if Player then
            if Player.PlayerData.job.name == 'police' and Player.PlayerData.job.onduty then
                TriggerClientEvent('prison:client:PrisonBreakAlert', v)
            end
        end
    end
end)

RegisterNetEvent('prison:server:SetGateHit', function(key)
    TriggerClientEvent('prison:client:SetGateHit', -1, key, true)
    if math.random(1, 100) <= 50 then
        for _, v in pairs(QBCore.Functions.GetPlayers()) do
            local Player = QBCore.Functions.GetPlayer(v)
            if Player then
                if Player.PlayerData.job.name == 'police' and Player.PlayerData.job.onduty then
                    TriggerClientEvent('prison:client:PrisonBreakAlert', v)
                end
            end
        end
    end
end)

RegisterNetEvent('prison:server:CheckRecordStatus', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local CriminalRecord = Player.PlayerData.metadata['criminalrecord']
    local currentDate = os.date('*t')

    if (CriminalRecord['date'].month + 1) == 13 then
        CriminalRecord['date'].month = 0
    end

    if CriminalRecord['hasRecord'] then
        if currentDate.month == (CriminalRecord['date'].month + 1) or currentDate.day == (CriminalRecord['date'].day - 1) then
            CriminalRecord['hasRecord'] = false
            CriminalRecord['date'] = nil
        end
    end
end)

RegisterNetEvent('prison:server:JailAlarm', function()
    if AlarmActivated then return end
    local playerPed = GetPlayerPed(source)
    local coords = GetEntityCoords(playerPed)
    local middle = vec2(Config.Locations['middle'].x, Config.Locations['middle'].y)
    if #(coords.xy - middle) < 200 then return error('"prison:server:JailAlarm" triggered whilst the player was too close to the prison, cancelled event') end
    TriggerClientEvent('prison:client:JailAlarm', -1, true)
    SetTimeout(5 * 60000, function()
        TriggerClientEvent('prison:client:JailAlarm', -1, false)
    end)
end)

RegisterNetEvent('prison:server:CheckChance', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or Player.PlayerData.metadata.injail == 0 or GotItems[src] then return end
    local chance = math.random(100)
    local odd = math.random(100)
    if chance ~= odd then return end
    if not exports['qb-inventory']:AddItem(src, 'phone', 1, false, false, 'prison:server:CheckChance') then return end
    TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items['phone'], 'add')
    TriggerClientEvent('QBCore:Notify', src, Lang:t('success.found_phone'), 'success')
    GotItems[src] = true
end)

QBCore.Functions.CreateCallback('prison:server:IsAlarmActive', function(_, cb)
    cb(AlarmActivated)
end)
