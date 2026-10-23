local function DnaHash(s)
    local h = string.gsub(s, '.', function(c)
        return string.format('%02x', string.byte(c))
    end)
    return h
end

-- License

QBCore.Commands.Add('grantlicense', Lang:t('commands.license_grant'), { { name = 'id', help = Lang:t('info.player_id') }, { name = 'license', help = Lang:t('info.license_type') } }, true, function(source, args)
    local src = source
    local validTypes = { driver = true, weapon = true, pilot = true, boat = true, heavy = true }
    local Player = QBCore.Functions.GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.grade.level >= Config.LicenseRank then
        if validTypes[args[2]] then
            local targetId = tonumber(args[1])
            local SearchedPlayer = QBCore.Functions.GetPlayer(targetId)
            if not SearchedPlayer then return end
            -- 🔄 委托给 custom-certificates 统一管理
            local success, msg = exports['custom-certificates']:GrantLicense(targetId, args[2])
            if success then
                TriggerClientEvent('QBCore:Notify', SearchedPlayer.PlayerData.source, Lang:t('success.granted_license'), 'success')
                TriggerClientEvent('QBCore:Notify', src, Lang:t('success.grant_license'), 'success')
            else
                TriggerClientEvent('QBCore:Notify', src, msg or Lang:t('error.license_already'), 'error')
            end
        else
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.error_license_type'), 'error')
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.rank_license'), 'error')
    end
end)

QBCore.Commands.Add('revokelicense', Lang:t('commands.license_revoke'), { { name = 'id', help = Lang:t('info.player_id') }, { name = 'license', help = Lang:t('info.license_type') } }, true, function(source, args)
    local src = source
    local validTypes = { driver = true, weapon = true, pilot = true, boat = true, heavy = true }
    local Player = QBCore.Functions.GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.grade.level >= Config.LicenseRank then
        if validTypes[args[2]] then
            local targetId = tonumber(args[1])
            local SearchedPlayer = QBCore.Functions.GetPlayer(targetId)
            if not SearchedPlayer then return end
            -- 🔄 委托给 custom-certificates 统一管理（含实体证件移除）
            local success, msg = exports['custom-certificates']:RevokeLicense(targetId, args[2])
            if success then
                TriggerClientEvent('QBCore:Notify', SearchedPlayer.PlayerData.source, Lang:t('error.revoked_license'), 'error')
                TriggerClientEvent('QBCore:Notify', src, Lang:t('success.revoke_license'), 'success')
            else
                TriggerClientEvent('QBCore:Notify', src, msg or Lang:t('error.error_license'), 'error')
            end
        else
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.error_license'), 'error')
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.rank_revoke'), 'error')
    end
end)

-- 🔧 新增: 暂停执照（对接 custom-certificates）
QBCore.Commands.Add('suspendlicense', '暂停玩家执照', { { name = 'id', help = Lang:t('info.player_id') }, { name = 'license', help = Lang:t('info.license_type') } }, true, function(source, args)
    local src = source
    local validTypes = { driver = true, weapon = true, pilot = true, boat = true, heavy = true }
    local Player = QBCore.Functions.GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.grade.level >= Config.LicenseRank then
        if validTypes[args[2]] then
            local targetId = tonumber(args[1])
            local SearchedPlayer = QBCore.Functions.GetPlayer(targetId)
            if not SearchedPlayer then return end
            local success, msg = exports['custom-certificates']:SuspendLicense(targetId, args[2])
            if success then
                TriggerClientEvent('QBCore:Notify', SearchedPlayer.PlayerData.source, ('你的 %s 执照已被暂停'):format(args[2]), 'error')
                TriggerClientEvent('QBCore:Notify', src, ('已暂停玩家 %s 的 %s 执照'):format(targetId, args[2]), 'success')
            else
                TriggerClientEvent('QBCore:Notify', src, msg or '操作失败', 'error')
            end
        else
            TriggerClientEvent('QBCore:Notify', src, '无效的执照类型', 'error')
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.rank_license'), 'error')
    end
end)

-- 🔧 新增: 恢复执照（对接 custom-certificates）
QBCore.Commands.Add('reinstatelicense', '恢复玩家执照', { { name = 'id', help = Lang:t('info.player_id') }, { name = 'license', help = Lang:t('info.license_type') } }, true, function(source, args)
    local src = source
    local validTypes = { driver = true, weapon = true, pilot = true, boat = true, heavy = true }
    local Player = QBCore.Functions.GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.grade.level >= Config.LicenseRank then
        if validTypes[args[2]] then
            local targetId = tonumber(args[1])
            local SearchedPlayer = QBCore.Functions.GetPlayer(targetId)
            if not SearchedPlayer then return end
            local success, msg = exports['custom-certificates']:ReinstateLicense(targetId, args[2])
            if success then
                TriggerClientEvent('QBCore:Notify', SearchedPlayer.PlayerData.source, ('你的 %s 执照已恢复'):format(args[2]), 'success')
                TriggerClientEvent('QBCore:Notify', src, ('已恢复玩家 %s 的 %s 执照'):format(targetId, args[2]), 'success')
            else
                TriggerClientEvent('QBCore:Notify', src, msg or '操作失败', 'error')
            end
        else
            TriggerClientEvent('QBCore:Notify', src, '无效的执照类型', 'error')
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.rank_license'), 'error')
    end
end)

QBCore.Commands.Add('takedrivinglicense', Lang:t('commands.drivinglicense'), {}, false, function(source)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        TriggerClientEvent('police:client:SeizeDriverLicense', source)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

-- Objects

QBCore.Commands.Add('spikestrip', Lang:t('commands.place_spike'), {}, false, function(source)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        TriggerClientEvent('police:client:SpawnSpikeStrip', src)
    end
end)

QBCore.Commands.Add('pobject', Lang:t('commands.place_object'), { { name = 'type', help = Lang:t('info.poobject_object') } }, true, function(source, args)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local type = args[1]:lower()
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        if type == 'cone' then
            TriggerClientEvent('police:client:spawnCone', src)
        elseif type == 'barrier' then
            TriggerClientEvent('police:client:spawnBarrier', src)
        elseif type == 'roadsign' then
            TriggerClientEvent('police:client:spawnRoadSign', src)
        elseif type == 'tent' then
            TriggerClientEvent('police:client:spawnTent', src)
        elseif type == 'light' then
            TriggerClientEvent('police:client:spawnLight', src)
        elseif type == 'delete' then
            TriggerClientEvent('police:client:deleteObject', src)
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

-- Department & District Management

QBCore.Commands.Add('setdept', '分配警员部门 (SWAT/CID/TRAFFIC/PATROL)', { { name = 'id', help = Lang:t('info.player_id') }, { name = 'dept', help = 'SWAT / CID / TRAFFIC / PATROL' } }, true, function(source, args)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local targetId = tonumber(args[1])
    local dept = args[2] and args[2]:upper()
    if Player.PlayerData.job.type ~= 'leo' or Player.PlayerData.job.grade.level < 3 then
        TriggerClientEvent('QBCore:Notify', src, '仅副警监 (Lieutenant) 及以上可分配部门', 'error')
        return
    end
    if not Config.Departments[dept] then
        TriggerClientEvent('QBCore:Notify', src, ('无效部门: %s (可选: SWAT, CID, TRAFFIC, PATROL)'):format(dept or 'nil'), 'error')
        return
    end
    local Target = QBCore.Functions.GetPlayer(targetId)
    if not Target then TriggerClientEvent('QBCore:Notify', src, '目标玩家不在线', 'error'); return end
    if Target.PlayerData.job.type ~= 'leo' then TriggerClientEvent('QBCore:Notify', src, '目标不是执法人员', 'error'); return end
    local success = exports['custom-career']:SetPlayerDepartment(targetId, dept)
    if success then
        TriggerClientEvent('QBCore:Notify', src, ('已将 %s 分配至 %s'):format(Target.PlayerData.charinfo.firstname, Config.Departments[dept].label), 'success')
        TriggerClientEvent('QBCore:Notify', Target.PlayerData.source, ('你已被分配至 %s 部门'):format(Config.Departments[dept].label), 'success')
    else
        TriggerClientEvent('QBCore:Notify', src, '操作失败', 'error')
    end
end)

QBCore.Commands.Add('setdistrict', '分配警员辖区 (MissionRow/Paleto/Sandy)', { { name = 'id', help = Lang:t('info.player_id') }, { name = 'district', help = 'MissionRow / Paleto / Sandy' } }, true, function(source, args)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local targetId = tonumber(args[1])
    local district = args[2]
    if Player.PlayerData.job.type ~= 'leo' or Player.PlayerData.job.grade.level < 3 then
        TriggerClientEvent('QBCore:Notify', src, '仅副警监 (Lieutenant) 及以上可分配辖区', 'error')
        return
    end
    if not Config.Districts[district] then
        TriggerClientEvent('QBCore:Notify', src, ('无效辖区: %s (可选: MissionRow, Paleto, Sandy)'):format(district or 'nil'), 'error')
        return
    end
    local Target = QBCore.Functions.GetPlayer(targetId)
    if not Target then TriggerClientEvent('QBCore:Notify', src, '目标玩家不在线', 'error'); return end
    if Target.PlayerData.job.type ~= 'leo' then TriggerClientEvent('QBCore:Notify', src, '目标不是执法人员', 'error'); return end
    local success = exports['custom-career']:SetPlayerDistrict(targetId, district)
    if success then
        TriggerClientEvent('QBCore:Notify', src, ('已将 %s 分配至 %s 辖区'):format(Target.PlayerData.charinfo.firstname, Config.Districts[district].label), 'success')
        TriggerClientEvent('QBCore:Notify', Target.PlayerData.source, ('你已被分配至 %s 辖区'):format(Config.Districts[district].label), 'success')
    else
        TriggerClientEvent('QBCore:Notify', src, '操作失败', 'error')
    end
end)

-- Interaction

QBCore.Commands.Add('cuff', Lang:t('commands.cuff_player'), {}, false, function(source)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        TriggerClientEvent('police:client:CuffPlayer', src)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('escort', Lang:t('commands.escort'), {}, false, function(source)
    local src = source
    TriggerClientEvent('police:client:EscortPlayer', src)
end)

QBCore.Commands.Add('callsign', Lang:t('commands.callsign'), { { name = 'name', help = Lang:t('info.callsign_name') } }, false, function(source, args)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    Player.Functions.SetMetaData('callsign', table.concat(args, ' '))
end)

QBCore.Commands.Add('jail', Lang:t('commands.jail_player'), {}, false, function(source)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        TriggerClientEvent('police:client:JailPlayer', src)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('unjail', Lang:t('commands.unjail_player'), { { name = 'id', help = Lang:t('info.player_id') } }, true, function(source, args)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        local targetId = tonumber(args[1])
        TriggerClientEvent('prison:client:UnjailPerson', targetId)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('seizecash', Lang:t('commands.seizecash'), {}, false, function(source)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        TriggerClientEvent('police:client:SeizeCash', src)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('sc', Lang:t('commands.softcuff'), {}, false, function(source)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        TriggerClientEvent('police:client:CuffPlayerSoft', src)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('fine', Lang:t('commands.fine'), { { name = 'id', help = Lang:t('info.player_id') }, { name = 'amount', help = Lang:t('info.amount') } }, false, function(source, args)
    local biller = QBCore.Functions.GetPlayer(source)
    local billed = QBCore.Functions.GetPlayer(tonumber(args[1]))
    local amount = tonumber(args[2])

    if biller.PlayerData.job.type ~= 'leo' then
        TriggerClientEvent('QBCore:Notify', source, Lang:t('error.on_duty_police_only'), 'error')
        return
    end

    if not billed then
        TriggerClientEvent('QBCore:Notify', source, Lang:t('error.not_online'), 'error')
        return
    end

    if biller.PlayerData.citizenid == billed.PlayerData.citizenid then
        TriggerClientEvent('QBCore:Notify', source, Lang:t('error.fine_yourself'), 'error')
        return
    end

    if amount <= 0 then
        TriggerClientEvent('QBCore:Notify', source, Lang:t('error.amount_higher'), 'error')
        return
    end

    if billed.Functions.RemoveMoney('bank', amount, 'paid-fine') then
        TriggerClientEvent('QBCore:Notify', source, Lang:t('info.fine_issued'), 'success')
        TriggerClientEvent('QBCore:Notify', billed.PlayerData.source, Lang:t('info.received_fine'))
        exports['qb-banking']:AddMoney(biller.PlayerData.job.name, amount, 'Fine')
    elseif billed.Functions.RemoveMoney('cash', amount, 'paid-fine') then
        TriggerClientEvent('QBCore:Notify', source, Lang:t('info.fine_issued'), 'success')
        TriggerClientEvent('QBCore:Notify', billed.PlayerData.source, Lang:t('info.received_fine'))
        exports['qb-banking']:AddMoney(biller.PlayerData.job.name, amount, 'Fine')
    else
        MySQL.Async.insert('INSERT INTO phone_invoices (citizenid, amount, society, sender, sendercitizenid) VALUES (?, ?, ?, ?, ?)', { billed.PlayerData.citizenid, amount, biller.PlayerData.job.name, biller.PlayerData.charinfo.firstname, biller.PlayerData.citizenid }, function(id)
            if id then
                TriggerClientEvent('qb-phone:client:AcceptorDenyInvoice', billed.PlayerData.source, id, biller.PlayerData.charinfo.firstname, biller.PlayerData.job.name, biller.PlayerData.citizenid, amount, GetInvokingResource())
            end
        end)
        TriggerClientEvent('qb-phone:RefreshPhone', billed.PlayerData.source)
    end
end)

-- Evidence

QBCore.Commands.Add('clearcasings', Lang:t('commands.clear_casign'), {}, false, function(source)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        TriggerClientEvent('evidence:client:ClearCasingsInArea', src)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('clearblood', Lang:t('commands.clearblood'), {}, false, function(source)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        TriggerClientEvent('evidence:client:ClearBlooddropsInArea', src)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('takedna', Lang:t('commands.takedna'), { { name = 'id', help = Lang:t('info.player_id') } }, true, function(source, args)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local OtherPlayer = QBCore.Functions.GetPlayer(tonumber(args[1]))
    if not OtherPlayer or Player.PlayerData.job.type ~= 'leo' or not Player.PlayerData.job.onduty then return end
    if exports['qb-inventory']:RemoveItem(src, 'empty_evidence_bag', 1, false, 'qb-policejob:takedna') then
        local info = {
            label = Lang:t('info.dna_sample'),
            type = 'dna',
            dnalabel = DnaHash(OtherPlayer.PlayerData.citizenid)
        }
        if not exports['qb-inventory']:AddItem(src, 'filled_evidence_bag', 1, false, info, 'qb-policejob:takedna') then return end
        TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items['filled_evidence_bag'], 'add')
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.have_evidence_bag'), 'error')
    end
end)

-- 🔍 警用 3D 文档查验（对接 custom-documents）

QBCore.Commands.Add('checkid', '查验目标玩家ID卡', { { name = 'id', help = Lang:t('info.player_id') } }, true, function(source, args)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or Player.PlayerData.job.type ~= 'leo' or not Player.PlayerData.job.onduty then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
        return
    end
    local targetId = tonumber(args[1])
    local targetPed = GetPlayerPed(targetId)
    local playerPed = GetPlayerPed(src)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    -- 🛡️ 物理距离校验（3.5m 查验距离）
    if #(playerCoords - targetCoords) > 3.5 then
        TriggerClientEvent('QBCore:Notify', src, '目标距离太远（需 < 3.5m）', 'error')
        return
    end
    -- 委托 custom-documents 进行 ID 卡查验
    QBCore.Functions.TriggerCallback('custom-documents:server:verifyPlayer', src, function(result)
        if not result then
            TriggerClientEvent('QBCore:Notify', src, '查验失败', 'error')
            return
        end
        if result.error then
            TriggerClientEvent('QBCore:Notify', src, result.error, 'error')
            return
        end
        -- 展示目标玩家证照状态
        local lines = { ('📋 玩家: %s (CID: %s)'):format(result.targetName, result.targetCitizenId) }
        for _, lic in ipairs(result.licenses) do
            lines[#lines + 1] = ('  %s %s — %s'):format(lic.label, lic.hasLicence and '✅ 持有' or '❌ 未持有', lic.statusLabel)
        end
        TriggerClientEvent('chat:addMessage', src, {
            color = { 100, 180, 255 }, multiline = true,
            args = { '🔍 证照查验', table.concat(lines, '\n') }
        })
        -- F8 审计日志
        print(('[POLICE-CHECK] %s (src=%s) verified licenses of %s (target=%s)')
            :format(GetPlayerName(src), src, result.targetName, targetId))
    end, targetId)
end)

QBCore.Commands.Add('checklicense', '查验目标玩家证照状态', { { name = 'id', help = Lang:t('info.player_id') } }, true, function(source, args)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or Player.PlayerData.job.type ~= 'leo' or not Player.PlayerData.job.onduty then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
        return
    end
    local targetId = tonumber(args[1])
    local targetPed = GetPlayerPed(targetId)
    local playerPed = GetPlayerPed(src)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(playerCoords - targetCoords) > 3.5 then
        TriggerClientEvent('QBCore:Notify', src, '目标距离太远（需 < 3.5m）', 'error')
        return
    end
    QBCore.Functions.TriggerCallback('custom-documents:server:verifyPlayer', src, function(result)
        if not result or result.error then
            TriggerClientEvent('QBCore:Notify', src, result and result.error or '查验失败', 'error')
            return
        end
        local lines = { ('📋 %s 的证照状态:'):format(result.targetName) }
        for _, lic in ipairs(result.licenses) do
            lines[#lines + 1] = ('  %s: %s'):format(lic.label, lic.statusLabel)
        end
        TriggerClientEvent('chat:addMessage', src, {
            color = { 255, 200, 100 }, multiline = true,
            args = { '📜 证照状态', table.concat(lines, '\n') }
        })
        print(('[POLICE-CHECK] %s (src=%s) checked licenses of %s (target=%s)')
            :format(GetPlayerName(src), src, result.targetName, targetId))
    end, targetId)
end)

QBCore.Commands.Add('anklet', Lang:t('commands.anklet'), {}, false, function(source)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        TriggerClientEvent('police:client:CheckDistance', src)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('ankletlocation', Lang:t('commands.ankletlocation'), { { name = 'cid', help = Lang:t('info.citizen_id') } }, true, function(source, args)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        local citizenid = args[1]
        local Target = QBCore.Functions.GetPlayerByCitizenId(citizenid)
        if not Target then return end
        if Target.PlayerData.metadata['tracker'] then
            TriggerClientEvent('police:client:SendTrackerLocation', Target.PlayerData.source, src)
        else
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.no_anklet'), 'error')
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

-- Vehicle

QBCore.Commands.Add('depot', Lang:t('commands.depot'), { { name = 'price', help = Lang:t('info.impound_price') } }, false, function(source, args)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        TriggerClientEvent('police:client:ImpoundVehicle', src, false, tonumber(args[1]))
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('impound', Lang:t('commands.impound'), {}, false, function(source)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        TriggerClientEvent('police:client:ImpoundVehicle', src, true)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

-- Misc

QBCore.Commands.Add('cam', Lang:t('commands.camera'), { { name = 'camid', help = Lang:t('info.camera_id') } }, false, function(source, args)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        TriggerClientEvent('police:client:ActiveCamera', src, tonumber(args[1]))
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('paytow', Lang:t('commands.paytow'), { { name = 'id', help = Lang:t('info.player_id') } }, true, function(source, args)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        local playerId = tonumber(args[1])
        local OtherPlayer = QBCore.Functions.GetPlayer(playerId)
        if OtherPlayer then
            if OtherPlayer.PlayerData.job.name == 'tow' then
                OtherPlayer.Functions.AddMoney('bank', 500, 'police-tow-paid')
                TriggerClientEvent('QBCore:Notify', OtherPlayer.PlayerData.source, Lang:t('success.tow_paid'), 'success')
                TriggerClientEvent('QBCore:Notify', src, Lang:t('info.tow_driver_paid'))
            else
                TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_towdriver'), 'error')
            end
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('paylawyer', Lang:t('commands.paylawyer'), { { name = 'id', help = Lang:t('info.player_id') } }, true, function(source, args)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' or Player.PlayerData.job.name == 'judge' then
        local playerId = tonumber(args[1])
        local OtherPlayer = QBCore.Functions.GetPlayer(playerId)
        if not OtherPlayer then return end
        if OtherPlayer.PlayerData.job.name == 'lawyer' then
            OtherPlayer.Functions.AddMoney('bank', 500, 'police-lawyer-paid')
            TriggerClientEvent('QBCore:Notify', OtherPlayer.PlayerData.source, Lang:t('success.tow_paid'), 'success')
            TriggerClientEvent('QBCore:Notify', src, Lang:t('info.paid_lawyer'))
        else
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_lawyer'), 'error')
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('911p', Lang:t('commands.police_report'), { { name = 'message', help = Lang:t('commands.message_sent') } }, false, function(source, args)
    local src = source
    local message
    if args[1] then message = table.concat(args, ' ') else message = Lang:t('commands.civilian_call') end
    local ped = GetPlayerPed(src)
    local coords = GetEntityCoords(ped)
    local players = QBCore.Functions.GetQBPlayers()
    for _, v in pairs(players) do
        if v and v.PlayerData.job.type == 'leo' and v.PlayerData.job.onduty then
            local alertData = { title = Lang:t('commands.emergency_call'), coords = { x = coords.x, y = coords.y, z = coords.z }, description = message }
            TriggerClientEvent('qb-phone:client:addPoliceAlert', v.PlayerData.source, alertData)
            TriggerClientEvent('police:client:policeAlert', v.PlayerData.source, coords, message)
        end
    end
end)
