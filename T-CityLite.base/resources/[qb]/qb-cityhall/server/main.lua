local QBCore = exports['qb-core']:GetCoreObject()
local availableJobs = Config.AvailableJobs

-- Exports

local function AddCityJob(jobName, toCH)
    if availableJobs[jobName] then return false, 'already added' end
    availableJobs[jobName] = {
        ['label'] = toCH.label,
        ['isManaged'] = toCH.isManaged
    }
    return true, 'success'
end

exports('AddCityJob', AddCityJob)

-- Functions

local function giveStarterItems()
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end
    for _, v in pairs(QBCore.Shared.StarterItems) do
        local info = {}
        if v.item == 'id_card' then
            info.citizenid = Player.PlayerData.citizenid
            info.firstname = Player.PlayerData.charinfo.firstname
            info.lastname = Player.PlayerData.charinfo.lastname
            info.birthdate = Player.PlayerData.charinfo.birthdate
            info.gender = Player.PlayerData.charinfo.gender
            info.nationality = Player.PlayerData.charinfo.nationality
        elseif v.item == 'driver_license' then
            info.firstname = Player.PlayerData.charinfo.firstname
            info.lastname = Player.PlayerData.charinfo.lastname
            info.birthdate = Player.PlayerData.charinfo.birthdate
            info.type = 'Class C Driver License'
        end
        exports['qb-inventory']:AddItem(source, v.item, 1, false, info, 'qb-cityhall:giveStarterItems')
    end
end

-- Callbacks

QBCore.Functions.CreateCallback('qb-cityhall:server:receiveJobs', function(_, cb)
    cb(availableJobs)
end)

QBCore.Functions.CreateCallback('qb-cityhall:server:getIdentityData', function(source, cb, hallId)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return cb({}) end

    local licensesMeta = Player.PlayerData.metadata['licences']
    local certStatus = Player.PlayerData.metadata['cert_status']
    local availableLicenses = {}

    for license, data in pairs(Config.Cityhalls[hallId].licenses) do
        if not data.metadata then
            -- 无 metadata 的物品（如 id_card）始终显示
            data.canApply = true
            data.applyLabel = data.label
            availableLicenses[license] = data
        elseif certStatus then
            local status = certStatus[data.metadata] or 'unclaimed'
            if status == 'suspended' then
                -- 显示但标注暂停
                data.canApply = false
                data.applyLabel = data.label .. ' [SUSPENDED — Contact Police]'
                availableLicenses[license] = data
            elseif status == 'revoked' then
                -- 显示但标注吊销
                data.canApply = false
                data.applyLabel = data.label .. ' [REVOKED — Contact Police]'
                availableLicenses[license] = data
            elseif status == 'held' then
                -- 已有权限，检查是否有实体证件
                local hasItem = false
                local items = Player.PlayerData.items
                if items then
                    for _, invItem in pairs(items) do
                        if invItem and invItem.name == license then
                            hasItem = true
                            break
                        end
                    end
                end
                if hasItem then
                    data.canApply = false
                    data.applyLabel = data.label .. ' [ALREADY IN INVENTORY]'
                else
                    data.canApply = true
                    data.applyLabel = data.label .. ' (Re-issue — $' .. data.cost .. ')'
                end
                availableLicenses[license] = data
            else
                -- unclaimed：首次申领
                data.canApply = true
                data.applyLabel = data.label .. ' — $' .. data.cost
                availableLicenses[license] = data
            end
        else
            -- 向后兼容：没有 cert_status 的老玩家
            local hasAuthority = licensesMeta and licensesMeta[data.metadata]
            if hasAuthority then
                data.canApply = true
                data.applyLabel = data.label .. ' (Re-issue — $' .. data.cost .. ')'
            else
                data.canApply = true
                data.applyLabel = data.label .. ' — $' .. data.cost
            end
            availableLicenses[license] = data
        end
    end

    cb(availableLicenses)
end)

-- Events

RegisterNetEvent('qb-cityhall:server:requestId', function(item, hall)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local itemInfo = Config.Cityhalls[hall].licenses[item]
    if not itemInfo then return end

    -- 对于证件类物品，先检查背包是否已有实体证件（防止重复申领）
    if itemInfo.metadata then
        local items = Player.PlayerData.items
        if items then
            for _, invItem in pairs(items) do
                if invItem and invItem.name == item then
                    TriggerClientEvent('QBCore:Notify', src,
                        ('You already have your %s certificate in your inventory'):format(itemInfo.label), 'error', 5000)
                    return
                end
            end
        end
    end

    -- 首次申领：如果玩家没有权限，本次购买同时授予权限
    -- 🔧 P1 修复: 委托给 custom-certificates 统一管理（不再手写 metadata）
    if itemInfo.metadata then
        local licences = Player.PlayerData.metadata['licences']
        if licences and not licences[itemInfo.metadata] then
            -- 检查状态（suspended/revoked 由 GrantLicense 内部校验）
            local success, msg = exports['custom-certificates']:GrantLicense(src, itemInfo.metadata)
            if not success then
                TriggerClientEvent('QBCore:Notify', src, msg or '授权失败', 'error', 5000)
                return
            end
        end
    end

    if not Player.Functions.RemoveMoney('cash', itemInfo.cost, 'cityhall id') then
        TriggerClientEvent('QBCore:Notify', src,
            ('You don\'t have enough money on you, you need %s cash'):format(itemInfo.cost), 'error')
        return
    end

    local info = {}
    if item == 'id_card' then
        info.citizenid = Player.PlayerData.citizenid
        info.firstname = Player.PlayerData.charinfo.firstname
        info.lastname = Player.PlayerData.charinfo.lastname
        info.birthdate = Player.PlayerData.charinfo.birthdate
        info.gender = Player.PlayerData.charinfo.gender
        info.nationality = Player.PlayerData.charinfo.nationality
    elseif item == 'driver_license' then
        info.firstname = Player.PlayerData.charinfo.firstname
        info.lastname = Player.PlayerData.charinfo.lastname
        info.birthdate = Player.PlayerData.charinfo.birthdate
        info.type = 'Class C Driver License'
        info.serial = ('cert-driver-%s'):format(Player.PlayerData.citizenid)
        info.citizenid = Player.PlayerData.citizenid
    elseif item == 'weaponlicense' then
        info.firstname = Player.PlayerData.charinfo.firstname
        info.lastname = Player.PlayerData.charinfo.lastname
        info.birthdate = Player.PlayerData.charinfo.birthdate
        info.serial = ('cert-weapon-%s'):format(Player.PlayerData.citizenid)
        info.citizenid = Player.PlayerData.citizenid
    elseif item == 'pilot_license' then
        info.firstname = Player.PlayerData.charinfo.firstname
        info.lastname = Player.PlayerData.charinfo.lastname
        info.birthdate = Player.PlayerData.charinfo.birthdate
        info.type = 'Pilot License'
        info.serial = ('cert-pilot-%s'):format(Player.PlayerData.citizenid)
        info.citizenid = Player.PlayerData.citizenid
    elseif item == 'boat_license' then
        info.firstname = Player.PlayerData.charinfo.firstname
        info.lastname = Player.PlayerData.charinfo.lastname
        info.birthdate = Player.PlayerData.charinfo.birthdate
        info.type = 'Boat License'
        info.serial = ('cert-boat-%s'):format(Player.PlayerData.citizenid)
        info.citizenid = Player.PlayerData.citizenid
    elseif item == 'heavy_license' then
        info.firstname = Player.PlayerData.charinfo.firstname
        info.lastname = Player.PlayerData.charinfo.lastname
        info.birthdate = Player.PlayerData.charinfo.birthdate
        info.type = 'Heavy Vehicle License'
        info.serial = ('cert-heavy-%s'):format(Player.PlayerData.citizenid)
        info.citizenid = Player.PlayerData.citizenid
    else
        return false
    end

    if not exports['qb-inventory']:AddItem(source, item, 1, false, info, 'qb-cityhall:server:requestId') then
        -- 退款
        Player.Functions.AddMoney('cash', itemInfo.cost, 'cityhall-refund')
        TriggerClientEvent('QBCore:Notify', src, 'Failed to add certificate — $' .. itemInfo.cost .. ' refunded', 'error', 5000)
        return
    end

    -- 🔧 P1 修复: cert_status 已在 GrantLicense 中由 custom-certificates 统一管理

    TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items[item], 'add')
    TriggerClientEvent('QBCore:Notify', src,
        ('You have received your %s for $%s'):format(itemInfo.label, itemInfo.cost), 'success', 5000)
end)

RegisterNetEvent('qb-cityhall:server:sendDriverTest', function(instructors)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    for i = 1, #instructors do
        local citizenid = instructors[i]
        local SchoolPlayer = QBCore.Functions.GetPlayerByCitizenId(citizenid)
        if SchoolPlayer then
            TriggerClientEvent('qb-cityhall:client:sendDriverEmail', SchoolPlayer.PlayerData.source, Player.PlayerData.charinfo)
        else
            local mailData = {
                sender = 'Township',
                subject = 'Driving lessons request',
                message = 'Hello,<br><br>We have just received a message that someone wants to take driving lessons.<br>If you are willing to teach, please contact them:<br>Name: <strong>' .. Player.PlayerData.charinfo.firstname .. ' ' .. Player.PlayerData.charinfo.lastname .. '<br />Phone Number: <strong>' .. Player.PlayerData.charinfo.phone .. '</strong><br><br>Kind regards,<br>Township Los Santos',
                button = {}
            }
            exports['qb-phone']:sendNewMailToOffline(citizenid, mailData)
        end
    end
    TriggerClientEvent('QBCore:Notify', src, 'An email has been sent to driving schools, and you will be contacted automatically', 'success', 5000)
end)

RegisterNetEvent('qb-cityhall:server:ApplyJob', function(job, cityhallCoords)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local ped = GetPlayerPed(src)
    local pedCoords = GetEntityCoords(ped)

    local data = {
        ['src'] = src,
        ['job'] = job
    }

    -- 🛡️ Security: 距离校验 + 职业可用性校验
    if #(pedCoords - cityhallCoords) >= 20.0 or not availableJobs[job] then
        return false
    end

    -- 🛡️ Security: 职业存在性校验
    local JobInfo = QBCore.Shared.Jobs[job]
    if not JobInfo then
        TriggerClientEvent('QBCore:Notify', src, 'Invalid job', 'error')
        return
    end

    -- 🛡️ Security: 职业前置条件校验 (最低等级 = 0 才能从市政厅申请)
    -- grade 必须存在且起始等级为 0
    if not JobInfo.grades or not JobInfo.grades['0'] then
        TriggerClientEvent('QBCore:Notify', src, 'This job cannot be applied for at the city hall', 'error')
        return
    end

    Player.Functions.SetJob(data.job)
    TriggerClientEvent('QBCore:Notify', data.src, Lang:t('info.new_job', { job = JobInfo.label }))
end)

RegisterNetEvent('qb-cityhall:server:getIDs', giveStarterItems)

RegisterNetEvent('QBCore:Client:UpdateObject', function()
    QBCore = exports['qb-core']:GetCoreObject()
end)

-- Commands

-- 🔧 自愈修复: /drivinglicense 教练指令 → 委托 custom-certificates
QBCore.Commands.Add('drivinglicense', 'Give a drivers license to someone', { { 'id', 'ID of a person' } }, true, function(source, args)
    local Player = QBCore.Functions.GetPlayer(source)
    local targetId = tonumber(args[1])
    local SearchedPlayer = QBCore.Functions.GetPlayer(targetId)
    if SearchedPlayer then
        -- 校验是否为驾校教练
        local isInstructor = false
        for i = 1, #Config.DrivingSchools do
            for id = 1, #Config.DrivingSchools[i].instructors do
                if Config.DrivingSchools[i].instructors[id] == Player.PlayerData.citizenid then
                    isInstructor = true
                    break
                end
            end
            if isInstructor then break end
        end
        if not isInstructor then
            TriggerClientEvent('QBCore:Notify', source, '你不是认证驾校教练', 'error')
            return
        end
        -- 🔄 委托给 custom-certificates 统一管理
        local success, msg = exports['custom-certificates']:GrantLicense(targetId, 'driver')
        if success then
            TriggerClientEvent('QBCore:Notify', SearchedPlayer.PlayerData.source, '你已通过考试！前往市政厅领取实体驾照', 'success', 5000)
            TriggerClientEvent('QBCore:Notify', source, ('已授予玩家 %s 驾驶执照权限'):format(targetId), 'success', 5000)
        else
            TriggerClientEvent('QBCore:Notify', source, msg or '此人已持有驾照', 'error')
        end
    else
        TriggerClientEvent('QBCore:Notify', source, 'Player Not Online', 'error')
    end
end)
