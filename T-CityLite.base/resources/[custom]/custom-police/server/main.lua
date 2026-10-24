-- Variables
QBCore = exports['qb-core']:GetCoreObject()
local updatingCops = false

-- 自动警情限流: source -> 上次触发时间 (模块级)
local autoAlertCooldown = {}
local AUTO_ALERT_COOLDOWN = 10

local function sanitizeAlertCoords(coords)
    if type(coords) ~= 'table' then return nil end
    local x, y, z = tonumber(coords.x), tonumber(coords.y), tonumber(coords.z)
    if not x or not y or not z then return nil end
    -- Reject NaN/inf and absurd coordinates instead of forwarding client data.
    if x ~= x or y ~= y or z ~= z then return nil end
    if math.abs(x) > 10000.0 or math.abs(y) > 10000.0 or math.abs(z) > 10000.0 then
        return nil
    end
    return { x = x, y = y, z = z }
end

local function sanitizeAlertText(text)
    if type(text) ~= 'string' then return nil end
    text = text:gsub('^%s+', ''):gsub('%s+$', '')
    if text == '' then return nil end
    if #text > 200 then
        if utf8 and utf8.offset then
            local ok, byteEnd = pcall(utf8.offset, text, 201)
            if ok and byteEnd then text = text:sub(1, byteEnd - 1) end
        else
            text = text:sub(1, 200)
        end
    end
    return text
end

-- Functions

local function UpdateBlips()
    local dutyPlayers = {}
    local players = QBCore.Functions.GetQBPlayers()
    for i = 1, #players do
        local v = players[i]
        if v and (v.PlayerData.job.type == 'leo' or v.PlayerData.job.type == 'ems') and v.PlayerData.job.onduty then
            local coords = GetEntityCoords(GetPlayerPed(v.PlayerData.source))
            local heading = GetEntityHeading(GetPlayerPed(v.PlayerData.source))
            dutyPlayers[#dutyPlayers + 1] = {
                source = v.PlayerData.source,
                label = v.PlayerData.metadata['callsign'],
                job = v.PlayerData.job.name,
                location = {
                    x = coords.x,
                    y = coords.y,
                    z = coords.z,
                    w = heading
                }
            }
        end
    end
    TriggerClientEvent('police:client:UpdateBlips', -1, dutyPlayers)
end

local function GetCurrentCops()
    local amount = 0
    local players = QBCore.Functions.GetQBPlayers()
    for _, v in pairs(players) do
        if v and v.PlayerData.job.type == 'leo' and v.PlayerData.job.onduty then
            amount = amount + 1
        end
    end
    return amount
end

-- Callbacks

QBCore.Functions.CreateCallback('police:GetDutyPlayers', function(_, cb)
    local dutyPlayers = {}
    local players = QBCore.Functions.GetQBPlayers()
    for _, v in pairs(players) do
        if v and v.PlayerData.job.type == 'leo' and v.PlayerData.job.onduty then
            dutyPlayers[#dutyPlayers + 1] = {
                source = v.PlayerData.source,
                label = v.PlayerData.metadata['callsign'],
                job = v.PlayerData.job.name
            }
        end
    end
    cb(dutyPlayers)
end)

QBCore.Functions.CreateCallback('police:GetCops', function(_, cb)
    local amount = 0
    local players = QBCore.Functions.GetQBPlayers()
    for _, v in pairs(players) do
        if v and v.PlayerData.job.type == 'leo' and v.PlayerData.job.onduty then
            amount = amount + 1
        end
    end
    cb(amount)
end)

QBCore.Functions.CreateCallback('police:server:isPlayerDead', function(_, cb, playerId)
    local Player = QBCore.Functions.GetPlayer(playerId)
    cb(Player.PlayerData.metadata['isdead'])
end)

QBCore.Functions.CreateCallback('police:IsSilencedWeapon', function(source, cb, weapon)
    local Player = QBCore.Functions.GetPlayer(source)
    local itemInfo = Player.Functions.GetItemByName(QBCore.Shared.Weapons[weapon]['name'])
    local retval = false
    if itemInfo then
        if itemInfo.info and itemInfo.info.attachments then
            for k in pairs(itemInfo.info.attachments) do
                if itemInfo.info.attachments[k].component == 'COMPONENT_AT_AR_SUPP_02' or
                    itemInfo.info.attachments[k].component == 'COMPONENT_AT_AR_SUPP' or
                    itemInfo.info.attachments[k].component == 'COMPONENT_AT_PI_SUPP_02' or
                    itemInfo.info.attachments[k].component == 'COMPONENT_AT_PI_SUPP' then
                    retval = true
                end
            end
        end
    end
    cb(retval)
end)

QBCore.Functions.CreateCallback('police:server:IsPoliceForcePresent', function(_, cb)
    local retval = false
    local players = QBCore.Functions.GetQBPlayers()
    for _, v in pairs(players) do
        if v and v.PlayerData.job.type == 'leo' and v.PlayerData.job.grade.level >= 2 then
            retval = true
            break
        end
    end
    cb(retval)
end)

-- Events

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        CreateThread(function()
            MySQL.query("DELETE FROM inventories WHERE identifier = 'policetrash'")
        end)
    end
end)

RegisterNetEvent('qb-policejob:server:stash', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    if Player.PlayerData.job.type ~= 'leo' then return end
    local citizenId = Player.PlayerData.citizenid
    local stashName = 'policestash_' .. citizenId
    exports['qb-inventory']:OpenInventory(src, stashName)
end)

RegisterNetEvent('qb-policejob:server:trash', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    if Player.PlayerData.job.type ~= 'leo' then return end
    exports['qb-inventory']:OpenInventory(src, 'policetrash', {
        maxweight = 4000000,
        slots = 300,
    })
end)

RegisterNetEvent('qb-policejob:server:evidence', function(currentEvidence)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    if Player.PlayerData.job.type ~= 'leo' then return end
    exports['qb-inventory']:OpenInventory(src, currentEvidence, {
        maxweight = 4000000,
        slots = 500,
    })
end)

RegisterNetEvent('police:server:policeAlert', function(text)
    local src = source
    -- 🔒 Security: 仅 LEO 可发警用通知
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    if Player.PlayerData.job.type ~= 'leo' and Player.PlayerData.job.name ~= 'ambulance' then return end
    local ped = GetPlayerPed(src)
    local coords = GetEntityCoords(ped)
    local players = QBCore.Functions.GetQBPlayers()
    for _, v in pairs(players) do
        if v and v.PlayerData.job.type == 'leo' and v.PlayerData.job.onduty then
            local alertData = { title = Lang:t('info.new_call'), coords = { x = coords.x, y = coords.y, z = coords.z }, description = text }
            TriggerClientEvent('qb-phone:client:addPoliceAlert', v.PlayerData.source, alertData)
            TriggerClientEvent('police:client:policeAlert', v.PlayerData.source, coords, text)
        end
    end
end)

-- 系统自动警报 (车辆盗窃等) — 仅限在勤警察调用 + 每 source 10 秒 1 次
RegisterNetEvent('police:server:autoAlert', function(coords, text)
    local src = source
    -- source 0 means a trusted server-side resource (e.g. custom-vehicles
    -- hotwire alarms) used TriggerEvent; client-originated calls must still be
    -- on-duty police.
    local isSystem = src == 0
    if not isSystem then
        local Player = QBCore.Functions.GetPlayer(src)
        if not Player or not PolicePolicy.Can(Player.PlayerData, 'incident.create') then return end
    end
    local cooldownKey = isSystem and 'system' or src

    local now = os.time()
    for otherSrc, lastAt in pairs(autoAlertCooldown) do
        if now - lastAt > 60 then autoAlertCooldown[otherSrc] = nil end
    end
    local last = autoAlertCooldown[cooldownKey]
    if last and now - last < AUTO_ALERT_COOLDOWN then return end

    local alertCoords = sanitizeAlertCoords(coords)
    local message = sanitizeAlertText(text)
    if not alertCoords or not message then return end
    autoAlertCooldown[cooldownKey] = now

    local sent = 0
    local players = QBCore.Functions.GetQBPlayers()
    for _, v in pairs(players) do
        if v and v.PlayerData.job.type == 'leo' and v.PlayerData.job.onduty then
            local alertData = {
                title = Lang:t('info.new_call'),
                coords = alertCoords,
                description = message,
            }
            TriggerClientEvent('qb-phone:client:addPoliceAlert', v.PlayerData.source, alertData)
            TriggerClientEvent('police:client:policeAlert', v.PlayerData.source, alertCoords, message)
            sent = sent + 1
        end
    end
    print(('[autoAlert] %s | 值班警察: %d 人'):format(message, sent))
end)

RegisterNetEvent('police:server:UpdateCurrentCops', function()
    local amount = 0
    local players = QBCore.Functions.GetQBPlayers()
    if updatingCops then return end
    updatingCops = true
    for _, v in pairs(players) do
        if v and v.PlayerData.job.type == 'leo' and v.PlayerData.job.onduty then
            amount = amount + 1
        end
    end
    TriggerClientEvent('police:SetCopCount', -1, amount)
    updatingCops = false
end)

RegisterNetEvent('police:server:SetHandcuffStatus', function(isHandcuffed)
    local src = source
    -- 🔒 Security: 仅接受 boolean 类型 + 仅限 LEO 或 EMS 调用
    if type(isHandcuffed) ~= 'boolean' then return end
    local Player = QBCore.Functions.GetPlayer(src)
    if Player then
        -- 只有执法/医疗人员才能设置他人手铐状态；玩家自己不能解锁
        local jobType = Player.PlayerData.job.type
        if isHandcuffed == false then
            -- 解锁手铐：必须是 LEO 或 EMS
            if jobType ~= 'leo' and Player.PlayerData.job.name ~= 'ambulance' then return end
        end
        Player.Functions.SetMetaData('ishandcuffed', isHandcuffed)
    end
end)

RegisterNetEvent('police:server:showFingerprint', function(playerId)
    local src = source
    TriggerClientEvent('police:client:showFingerprint', playerId, src)
    TriggerClientEvent('police:client:showFingerprint', src, playerId)
end)

RegisterNetEvent('police:server:showFingerprintId', function(sessionId)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local fid = Player.PlayerData.metadata['fingerprint']
    TriggerClientEvent('police:client:showFingerprintId', sessionId, fid)
    TriggerClientEvent('police:client:showFingerprintId', src, fid)
end)

RegisterNetEvent('police:server:SetTracker', function(targetId)
    local src = source
    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(targetId)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(playerCoords - targetCoords) > 2.5 then return DropPlayer(src, 'Attempted exploit abuse') end

    local Target = QBCore.Functions.GetPlayer(targetId)
    if not QBCore.Functions.GetPlayer(src) or not Target then return end

    local TrackerMeta = Target.PlayerData.metadata['tracker']
    if TrackerMeta then
        Target.Functions.SetMetaData('tracker', false)
        TriggerClientEvent('QBCore:Notify', targetId, Lang:t('success.anklet_taken_off'), 'success')
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.took_anklet_from', { firstname = Target.PlayerData.charinfo.firstname, lastname = Target.PlayerData.charinfo.lastname }), 'success')
        TriggerClientEvent('police:client:SetTracker', targetId, false)
    else
        Target.Functions.SetMetaData('tracker', true)
        TriggerClientEvent('QBCore:Notify', targetId, Lang:t('success.put_anklet'), 'success')
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.put_anklet_on', { firstname = Target.PlayerData.charinfo.firstname, lastname = Target.PlayerData.charinfo.lastname }), 'success')
        TriggerClientEvent('police:client:SetTracker', targetId, true)
    end
end)

RegisterNetEvent('police:server:SendTrackerLocation', function(coords, requestId)
    local Target = QBCore.Functions.GetPlayer(source)
    local msg = Lang:t('info.target_location', { firstname = Target.PlayerData.charinfo.firstname, lastname = Target.PlayerData.charinfo.lastname })
    local alertData = {
        title = Lang:t('info.anklet_location'),
        coords = {
            x = coords.x,
            y = coords.y,
            z = coords.z
        },
        description = msg
    }
    TriggerClientEvent('police:client:TrackerMessage', requestId, msg, coords)
    TriggerClientEvent('qb-phone:client:addPoliceAlert', requestId, alertData)
end)

-- Threads

CreateThread(function()
    while true do
        Wait(1000 * 60 * 10)
        local curCops = GetCurrentCops()
        TriggerClientEvent('police:SetCopCount', -1, curCops)
    end
end)

CreateThread(function()
    while true do
        Wait(5000)
        UpdateBlips()
    end
end)

-- Items

QBCore.Functions.CreateUseableItem('handcuffs', function(source)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player.Functions.GetItemByName('handcuffs') then return end
    TriggerClientEvent('police:client:CuffPlayerSoft', src)
end)

QBCore.Functions.CreateUseableItem('moneybag', function(source, item)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    if not Player.Functions.GetItemByName('moneybag') or not item.info or item.info == '' then return end
    if not Player.PlayerData.job.type == 'leo' then return end
    if not exports['qb-inventory']:RemoveItem(src, 'moneybag', 1, item.slot, 'qb-policejob:moneybag') then return end
    Player.Functions.AddMoney('cash', tonumber(item.info.cash), 'qb-policejob:moneybag')
end)
