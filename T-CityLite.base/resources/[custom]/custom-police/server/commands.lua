local function DnaHash(s)
    local h = string.gsub(s, '.', function(c)
        return string.format('%02x', string.byte(c))
    end)
    return h
end

-- License

--- 命令回执（P-4）：统一走 custom-notify 的三层分派。
--- 以前这些全是 feedback(...)，命令回执和警情报警挤同一条通道，
--- 值班警察真正该看的东西会被自己的操作回执淹没。
---@param target number 目标玩家 source
---@param text string 文案
---@param kind string|nil 'success' | 'error' | nil
local function feedback(target, text, kind)
    -- 老代码里有 { text = ..., caption = ... } 的形态，Push 只接受字符串
    if type(text) == 'table' then
        text = text.text or text.caption or ''
    end
    local pushKind = (kind == 'error') and 'error' or 'feed'
    pcall(function()
        exports['custom-notify']:Push(target, pushKind, text)
    end)
end

QBCore.Commands.Add('grantlicense', Lang:t('commands.license_grant'), { { name = 'id', help = Lang:t('info.player_id') }, { name = 'license', help = Lang:t('info.license_type') } }, true, function(source, args)
    local src = source
    local validTypes = { driver = true, weapon = true, pilot = true, boat = true, heavy = true }
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end -- 控制台 (source=0) 或本帧刚掉线时 GetPlayer 为 nil
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.grade.level >= Config.LicenseRank then
        if validTypes[args[2]] then
            local targetId = tonumber(args[1])
            local SearchedPlayer = QBCore.Functions.GetPlayer(targetId)
            if not SearchedPlayer then return end
            -- 🔄 委托给 custom-certificates 统一管理
            local success, msg = exports['custom-certificates']:GrantLicense(targetId, args[2])
            if success then
                feedback(SearchedPlayer.PlayerData.source, Lang:t('success.granted_license'), 'success')
                feedback(src, Lang:t('success.grant_license'), 'success')
            else
                feedback(src, msg or Lang:t('error.license_already'), 'error')
            end
        else
            feedback(src, Lang:t('error.error_license_type'), 'error')
        end
    else
        feedback(src, Lang:t('error.rank_license'), 'error')
    end
end)

-- 🔧 新增: 暂停执照（对接 custom-certificates）
-- 🔧 新增: 恢复执照（对接 custom-certificates）
QBCore.Commands.Add('takedrivinglicense', Lang:t('commands.drivinglicense'), {}, false, function(source)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end -- 控制台 (source=0) 或本帧刚掉线时 GetPlayer 为 nil
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        TriggerClientEvent('police:client:SeizeDriverLicense', source)
    else
        feedback(src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

-- Objects

QBCore.Commands.Add('spikestrip', Lang:t('commands.place_spike'), {}, false, function(source)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end -- 控制台 (source=0) 或本帧刚掉线时 GetPlayer 为 nil
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        TriggerClientEvent('police:client:SpawnSpikeStrip', src)
    end
end)

QBCore.Commands.Add('pobject', Lang:t('commands.place_object'), { { name = 'type', help = Lang:t('info.poobject_object') } }, true, function(source, args)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end -- 控制台 (source=0) 或本帧刚掉线时 GetPlayer 为 nil
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
        feedback(src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

-- Department & District Management

QBCore.Commands.Add('setdept', '分配警员部门 (SWAT/CID/TRAFFIC/PATROL)', { { name = 'id', help = Lang:t('info.player_id') }, { name = 'dept', help = 'SWAT / CID / TRAFFIC / PATROL' } }, true, function(source, args)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end -- 控制台 (source=0) 或本帧刚掉线时 GetPlayer 为 nil
    local targetId = tonumber(args[1])
    local dept = args[2] and args[2]:upper()
    if Player.PlayerData.job.type ~= 'leo' or Player.PlayerData.job.grade.level < 3 then
        feedback(src, '仅副警监 (Lieutenant) 及以上可分配部门', 'error')
        return
    end
    if not Config.Departments[dept] then
        feedback(src, ('无效部门: %s (可选: SWAT, CID, TRAFFIC, PATROL)'):format(dept or 'nil'), 'error')
        return
    end
    local Target = QBCore.Functions.GetPlayer(targetId)
    if not Target then feedback(src, '目标玩家不在线', 'error'); return end
    if Target.PlayerData.job.type ~= 'leo' then feedback(src, '目标不是执法人员', 'error'); return end
    local success = exports['custom-career']:SetPlayerDepartment(targetId, dept)
    if success then
        feedback(src, ('已将 %s 分配至 %s'):format(Target.PlayerData.charinfo.firstname, Config.Departments[dept].label), 'success')
        feedback(Target.PlayerData.source, ('你已被分配至 %s 部门'):format(Config.Departments[dept].label), 'success')
    else
        feedback(src, '操作失败', 'error')
    end
end)

QBCore.Commands.Add('setdistrict', '分配警员辖区 (MissionRow/Paleto/Sandy)', { { name = 'id', help = Lang:t('info.player_id') }, { name = 'district', help = 'MissionRow / Paleto / Sandy' } }, true, function(source, args)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end -- 控制台 (source=0) 或本帧刚掉线时 GetPlayer 为 nil
    local targetId = tonumber(args[1])
    local district = args[2]
    if Player.PlayerData.job.type ~= 'leo' or Player.PlayerData.job.grade.level < 3 then
        feedback(src, '仅副警监 (Lieutenant) 及以上可分配辖区', 'error')
        return
    end
    if not Config.Districts[district] then
        feedback(src, ('无效辖区: %s (可选: MissionRow, Paleto, Sandy)'):format(district or 'nil'), 'error')
        return
    end
    local Target = QBCore.Functions.GetPlayer(targetId)
    if not Target then feedback(src, '目标玩家不在线', 'error'); return end
    if Target.PlayerData.job.type ~= 'leo' then feedback(src, '目标不是执法人员', 'error'); return end
    local success = exports['custom-career']:SetPlayerDistrict(targetId, district)
    if success then
        feedback(src, ('已将 %s 分配至 %s 辖区'):format(Target.PlayerData.charinfo.firstname, Config.Districts[district].label), 'success')
        feedback(Target.PlayerData.source, ('你已被分配至 %s 辖区'):format(Config.Districts[district].label), 'success')
    else
        feedback(src, '操作失败', 'error')
    end
end)

-- Interaction

QBCore.Commands.Add('cuff', Lang:t('commands.cuff_player'), {}, false, function(source)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end -- 控制台 (source=0) 或本帧刚掉线时 GetPlayer 为 nil
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        TriggerClientEvent('police:client:CuffPlayer', src)
    else
        feedback(src, Lang:t('error.on_duty_police_only'), 'error')
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

QBCore.Commands.Add('unjail', Lang:t('commands.unjail_player'), { { name = 'id', help = Lang:t('info.player_id') } }, true, function(source, args)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end -- 控制台 (source=0) 或本帧刚掉线时 GetPlayer 为 nil
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        local targetId = tonumber(args[1])
        local targetPlayer = targetId and QBCore.Functions.GetPlayer(targetId)
        if not targetPlayer then
            return feedback(src, '目标不在线', 'error')
        end
        -- DB sentence must be closed too: qb-prison ignores the client's
        -- SetJailStatus(0) once justice is authoritative.
        pcall(function()
            return exports['custom-justice']:ReleaseSentence(
                targetPlayer.PlayerData.citizenid, 'police_unjail')
        end)
        targetPlayer.Functions.SetMetaData('injail', 0)
        TriggerClientEvent('prison:client:UnjailPerson', targetId)
    else
        feedback(src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('seizecash', Lang:t('commands.seizecash'), {}, false, function(source)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end -- 控制台 (source=0) 或本帧刚掉线时 GetPlayer 为 nil
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        TriggerClientEvent('police:client:SeizeCash', src)
    else
        feedback(src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('sc', Lang:t('commands.softcuff'), {}, false, function(source)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end -- 控制台 (source=0) 或本帧刚掉线时 GetPlayer 为 nil
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        TriggerClientEvent('police:client:CuffPlayerSoft', src)
    else
        feedback(src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('fine', Lang:t('commands.fine'), { { name = 'id', help = Lang:t('info.player_id') }, { name = 'amount', help = Lang:t('info.amount') } }, false, function(source, args)
    local biller = QBCore.Functions.GetPlayer(source)
    if not biller then return end -- 控制台 (source=0) 或本帧刚掉线时 GetPlayer 为 nil
    local billed = QBCore.Functions.GetPlayer(tonumber(args[1]))
    local amount = tonumber(args[2])

    if biller.PlayerData.job.type ~= 'leo' then
        feedback(source, Lang:t('error.on_duty_police_only'), 'error')
        return
    end

    if not billed then
        feedback(source, Lang:t('error.not_online'), 'error')
        return
    end

    if biller.PlayerData.citizenid == billed.PlayerData.citizenid then
        feedback(source, Lang:t('error.fine_yourself'), 'error')
        return
    end

    if amount <= 0 then
        feedback(source, Lang:t('error.amount_higher'), 'error')
        return
    end

    if billed.Functions.RemoveMoney('bank', amount, 'paid-fine') then
        feedback(source, Lang:t('info.fine_issued'), 'success')
        feedback(billed.PlayerData.source, Lang:t('info.received_fine'))
        exports['qb-banking']:AddMoney(biller.PlayerData.job.name, amount, 'Fine')
    elseif billed.Functions.RemoveMoney('cash', amount, 'paid-fine') then
        feedback(source, Lang:t('info.fine_issued'), 'success')
        feedback(billed.PlayerData.source, Lang:t('info.received_fine'))
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
    if not Player then return end -- 控制台 (source=0) 或本帧刚掉线时 GetPlayer 为 nil
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        TriggerClientEvent('evidence:client:ClearCasingsInArea', src)
    else
        feedback(src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('clearblood', Lang:t('commands.clearblood'), {}, false, function(source)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end -- 控制台 (source=0) 或本帧刚掉线时 GetPlayer 为 nil
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        TriggerClientEvent('evidence:client:ClearBlooddropsInArea', src)
    else
        feedback(src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('takedna', Lang:t('commands.takedna'), { { name = 'id', help = Lang:t('info.player_id') } }, true, function(source, args)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end -- 控制台 (source=0) 或本帧刚掉线时 GetPlayer 为 nil
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
        feedback(src, Lang:t('error.have_evidence_bag'), 'error')
    end
end)

-- 🔍 警用 3D 文档查验（对接 custom-documents）

QBCore.Commands.Add('checkid', '查验目标玩家ID卡', { { name = 'id', help = Lang:t('info.player_id') } }, true, function(source, args)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or Player.PlayerData.job.type ~= 'leo' or not Player.PlayerData.job.onduty then
        feedback(src, Lang:t('error.on_duty_police_only'), 'error')
        return
    end
    local targetId = tonumber(args[1])
    local targetPed = GetPlayerPed(targetId)
    local playerPed = GetPlayerPed(src)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    -- 🛡️ 物理距离校验（3.5m 查验距离）
    if #(playerCoords - targetCoords) > 3.5 then
        feedback(src, '目标距离太远（需 < 3.5m）', 'error')
        return
    end
    -- 委托 custom-documents 进行 ID 卡查验
    QBCore.Functions.TriggerCallback('custom-documents:server:verifyPlayer', src, function(result)
        if not result then
            feedback(src, '查验失败', 'error')
            return
        end
        if result.error then
            feedback(src, result.error, 'error')
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

QBCore.Commands.Add('verifylicense', '查验目标玩家证照状态', { { name = 'id', help = Lang:t('info.player_id') } }, true, function(source, args)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or Player.PlayerData.job.type ~= 'leo' or not Player.PlayerData.job.onduty then
        feedback(src, Lang:t('error.on_duty_police_only'), 'error')
        return
    end
    local targetId = tonumber(args[1])
    local targetPed = GetPlayerPed(targetId)
    local playerPed = GetPlayerPed(src)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(playerCoords - targetCoords) > 3.5 then
        feedback(src, '目标距离太远（需 < 3.5m）', 'error')
        return
    end
    QBCore.Functions.TriggerCallback('custom-documents:server:verifyPlayer', src, function(result)
        if not result or result.error then
            feedback(src, result and result.error or '查验失败', 'error')
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
    if not Player then return end -- 控制台 (source=0) 或本帧刚掉线时 GetPlayer 为 nil
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        TriggerClientEvent('police:client:CheckDistance', src)
    else
        feedback(src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('ankletlocation', Lang:t('commands.ankletlocation'), { { name = 'cid', help = Lang:t('info.citizen_id') } }, true, function(source, args)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end -- 控制台 (source=0) 或本帧刚掉线时 GetPlayer 为 nil
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        local citizenid = args[1]
        local Target = QBCore.Functions.GetPlayerByCitizenId(citizenid)
        if not Target then return end
        if Target.PlayerData.metadata['tracker'] then
            TriggerClientEvent('police:client:SendTrackerLocation', Target.PlayerData.source, src)
        else
            feedback(src, Lang:t('error.no_anklet'), 'error')
        end
    else
        feedback(src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

-- Vehicle

QBCore.Commands.Add('depot', Lang:t('commands.depot'), { { name = 'price', help = Lang:t('info.impound_price') } }, false, function(source, args)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end -- 控制台 (source=0) 或本帧刚掉线时 GetPlayer 为 nil
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        TriggerClientEvent('police:client:ImpoundVehicle', src, false, tonumber(args[1]))
    else
        feedback(src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('impound', Lang:t('commands.impound'), {}, false, function(source)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end -- 控制台 (source=0) 或本帧刚掉线时 GetPlayer 为 nil
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        TriggerClientEvent('police:client:ImpoundVehicle', src, true)
    else
        feedback(src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

-- Misc

QBCore.Commands.Add('cam', Lang:t('commands.camera'), { { name = 'camid', help = Lang:t('info.camera_id') } }, false, function(source, args)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end -- 控制台 (source=0) 或本帧刚掉线时 GetPlayer 为 nil
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        TriggerClientEvent('police:client:ActiveCamera', src, tonumber(args[1]))
    else
        feedback(src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('paytow', Lang:t('commands.paytow'), { { name = 'id', help = Lang:t('info.player_id') } }, true, function(source, args)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end -- 控制台 (source=0) 或本帧刚掉线时 GetPlayer 为 nil
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        local playerId = tonumber(args[1])
        local OtherPlayer = QBCore.Functions.GetPlayer(playerId)
        if OtherPlayer then
            if OtherPlayer.PlayerData.job.name == 'tow' then
                OtherPlayer.Functions.AddMoney('bank', 500, 'police-tow-paid')
                feedback(OtherPlayer.PlayerData.source, Lang:t('success.tow_paid'), 'success')
                feedback(src, Lang:t('info.tow_driver_paid'))
            else
                feedback(src, Lang:t('error.not_towdriver'), 'error')
            end
        end
    else
        feedback(src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('paylawyer', Lang:t('commands.paylawyer'), { { name = 'id', help = Lang:t('info.player_id') } }, true, function(source, args)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end -- 控制台 (source=0) 或本帧刚掉线时 GetPlayer 为 nil
    if Player.PlayerData.job.type == 'leo' or Player.PlayerData.job.name == 'judge' then
        local playerId = tonumber(args[1])
        local OtherPlayer = QBCore.Functions.GetPlayer(playerId)
        if not OtherPlayer then return end
        if OtherPlayer.PlayerData.job.name == 'lawyer' then
            OtherPlayer.Functions.AddMoney('bank', 500, 'police-lawyer-paid')
            feedback(OtherPlayer.PlayerData.source, Lang:t('success.tow_paid'), 'success')
            feedback(src, Lang:t('info.paid_lawyer'))
        else
            feedback(src, Lang:t('error.not_lawyer'), 'error')
        end
    else
        feedback(src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('911p', Lang:t('commands.police_report'), { { name = 'message', help = Lang:t('commands.message_sent') } }, false, function(source, args)
    local src = source
    local message
    if args[1] then message = table.concat(args, ' ') else message = Lang:t('commands.civilian_call') end
    local ped = GetPlayerPed(src)
    local coords = GetEntityCoords(ped)
    -- 与 /911、policeAlert 走同一个入口：先有单，才有通知和地图标记。
    -- （以前这里只发通知+插旗，警情板上什么都没有。）
    local incident, reason = PoliceDispatch.CreateIncident(src, {
        code = '911', title = message, description = message, priority = 2,
        x = coords.x, y = coords.y, z = coords.z,
    })
    if not incident then
        feedback(src, ('报警失败：%s'):format(tostring(reason)), 'error')
        return
    end
    feedback(src, ('已受理（警情 #%s）'):format(tostring(incident.id)), 'success')
end)
