local function audit(cid, action, target, detail)
    -- 唯一写者见 server/audit.lua（这里只保留同名包装，调用点不用改）
    return PoliceAudit.Write(cid, action, target, detail)
end

RegisterNetEvent('police:server:SearchPlayer', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local PlayerData = Player.PlayerData
    if PlayerData.job.type ~= 'leo' then return end
    local player, distance = QBCore.Functions.GetClosestPlayer(src)
    if player ~= -1 and distance < 2.5 then
        local SearchedPlayer = QBCore.Functions.GetPlayer(tonumber(player))
        if not SearchedPlayer then return end
        exports['qb-inventory']:OpenInventoryById(src, tonumber(player))
        TriggerClientEvent('QBCore:Notify', src, Lang:t('info.cash_found', { cash = SearchedPlayer.PlayerData.money['cash'] }))
        TriggerClientEvent('QBCore:Notify', player, Lang:t('info.being_searched'))
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.none_nearby'), 'error')
    end
end)

RegisterNetEvent('police:server:CuffPlayer', function(playerId, isSoftcuff)
    local src = source
    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(playerId)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(playerCoords - targetCoords) > 2.5 then return DropPlayer(src, 'Attempted exploit abuse') end

    local Player = QBCore.Functions.GetPlayer(src)
    local CuffedPlayer = QBCore.Functions.GetPlayer(playerId)
    if not Player or not CuffedPlayer or (not Player.Functions.GetItemByName('handcuffs') and Player.PlayerData.job.type ~= 'leo') then return end

    TriggerClientEvent('police:client:GetCuffed', CuffedPlayer.PlayerData.source, Player.PlayerData.source, isSoftcuff)
end)

RegisterNetEvent('police:server:EscortPlayer', function(playerId)
    local src = source
    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(playerId)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(playerCoords - targetCoords) > 2.5 then return DropPlayer(src, 'Attempted exploit abuse') end

    local Player = QBCore.Functions.GetPlayer(source)
    local EscortPlayer = QBCore.Functions.GetPlayer(playerId)
    if not Player or not EscortPlayer then return end

    if (Player.PlayerData.job.type == 'leo' or Player.PlayerData.job.name == 'ambulance') or (EscortPlayer.PlayerData.metadata['ishandcuffed'] or EscortPlayer.PlayerData.metadata['isdead'] or EscortPlayer.PlayerData.metadata['inlaststand']) then
        TriggerClientEvent('police:client:GetEscorted', EscortPlayer.PlayerData.source, Player.PlayerData.source)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_cuffed_dead'), 'error')
    end
end)

RegisterNetEvent('police:server:KidnapPlayer', function(playerId)
    local src = source
    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(playerId)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(playerCoords - targetCoords) > 2.5 then return DropPlayer(src, 'Attempted exploit abuse') end

    local Player = QBCore.Functions.GetPlayer(source)
    local EscortPlayer = QBCore.Functions.GetPlayer(playerId)
    if not Player or not EscortPlayer then return end

    if EscortPlayer.PlayerData.metadata['ishandcuffed'] or EscortPlayer.PlayerData.metadata['isdead'] or EscortPlayer.PlayerData.metadata['inlaststand'] then
        TriggerClientEvent('police:client:GetKidnappedTarget', EscortPlayer.PlayerData.source, Player.PlayerData.source)
        TriggerClientEvent('police:client:GetKidnappedDragger', Player.PlayerData.source, EscortPlayer.PlayerData.source)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_cuffed_dead'), 'error')
    end
end)

RegisterNetEvent('police:server:SetPlayerOutVehicle', function(playerId)
    local src = source
    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(playerId)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(playerCoords - targetCoords) > 2.5 then return DropPlayer(src, 'Attempted exploit abuse') end

    local EscortPlayer = QBCore.Functions.GetPlayer(playerId)
    if not QBCore.Functions.GetPlayer(src) or not EscortPlayer then return end

    if EscortPlayer.PlayerData.metadata['ishandcuffed'] or EscortPlayer.PlayerData.metadata['isdead'] then
        TriggerClientEvent('police:client:SetOutVehicle', EscortPlayer.PlayerData.source)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_cuffed_dead'), 'error')
    end
end)

RegisterNetEvent('police:server:PutPlayerInVehicle', function(playerId)
    local src = source
    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(playerId)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(playerCoords - targetCoords) > 2.5 then return DropPlayer(src, 'Attempted exploit abuse') end

    local EscortPlayer = QBCore.Functions.GetPlayer(playerId)
    if not QBCore.Functions.GetPlayer(src) or not EscortPlayer then return end

    if EscortPlayer.PlayerData.metadata['ishandcuffed'] or EscortPlayer.PlayerData.metadata['isdead'] then
        TriggerClientEvent('police:client:PutInVehicle', EscortPlayer.PlayerData.source)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_cuffed_dead'), 'error')
    end
end)

RegisterNetEvent('police:server:BillPlayer', function(playerId, price)
    local src = source
    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(playerId)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(playerCoords - targetCoords) > 2.5 then return DropPlayer(src, 'Attempted exploit abuse') end

    local Player = QBCore.Functions.GetPlayer(src)
    local OtherPlayer = QBCore.Functions.GetPlayer(playerId)
    if not Player or not OtherPlayer or Player.PlayerData.job.type ~= 'leo' then return end

    -- 🛡️ Security: 罚金服务器端强制上限，防止客户端注入天价罚单
    local fineAmount = tonumber(price) or 0
    if fineAmount <= 0 then return end
    if fineAmount > 50000 then fineAmount = 50000 end

    OtherPlayer.Functions.RemoveMoney('bank', fineAmount, 'paid-bills')
    exports['qb-banking']:AddMoney('police', fineAmount, 'Fine paid')
    TriggerClientEvent('QBCore:Notify', OtherPlayer.PlayerData.source, Lang:t('info.fine_received', { fine = fineAmount }))
end)

RegisterNetEvent('police:server:JailPlayer', function(playerId, time)
    local src = source
    -- P6: legacy manual jail is retired. The /jail command and the
    -- police:client:JailPlayer handler are gone; new arrests must go through
    -- ArrestSubmit. Keep this handler only for internal/compat callers that
    -- pass source 0 — any client-sourced trigger is ignored.
    if src ~= 0 then return end
    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(playerId)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(playerCoords - targetCoords) > 2.5 then return DropPlayer(src, 'Attempted exploit abuse') end

    local Player = QBCore.Functions.GetPlayer(src)
    local OtherPlayer = QBCore.Functions.GetPlayer(playerId)
    if not Player or not OtherPlayer then return end

    -- Legacy manual jail entry point. It now uses the same capability table as
    -- the arrest submit path, rejects a missing/non-positive sentence instead
    -- of silently converting it to one minute, and is audited.
    local allowed = PolicePolicy.Can(Player.PlayerData, 'arrest.create')
    if not allowed then return end

    local jailTime = tonumber(time)
    if not jailTime or jailTime <= 0 then return end
    jailTime = math.floor(jailTime)
    if jailTime < 1 then return end
    if jailTime > 120 then jailTime = 120 end

    if not audit(Player.PlayerData.citizenid, 'arrest.register', OtherPlayer.PlayerData.citizenid,
            ('legacy /jail %d min'):format(jailTime)) then
        return
    end

    local currentDate = os.date('*t')
    if currentDate.day == 31 then
        currentDate.day = 30
    end

    OtherPlayer.Functions.SetMetaData('injail', jailTime)
    OtherPlayer.Functions.SetMetaData('criminalrecord', {
        ['hasRecord'] = true,
        ['date'] = currentDate
    })
    TriggerClientEvent('police:client:SendToJail', OtherPlayer.PlayerData.source, jailTime)
    TriggerClientEvent('QBCore:Notify', src, Lang:t('info.sent_jail_for', { time = jailTime }))
end)

RegisterNetEvent('police:server:SeizeCash', function(playerId)
    local src = source
    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(playerId)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(playerCoords - targetCoords) > 2.5 then return DropPlayer(src, 'Attempted exploit abuse') end
    local Player = QBCore.Functions.GetPlayer(src)
    local SearchedPlayer = QBCore.Functions.GetPlayer(playerId)
    if not Player or not SearchedPlayer then return end
    if Player.PlayerData.job.type ~= 'leo' then return end
    local moneyAmount = SearchedPlayer.PlayerData.money['cash']
    local info = { cash = moneyAmount }
    SearchedPlayer.Functions.RemoveMoney('cash', moneyAmount, 'police-cash-seized')
    exports['qb-inventory']:AddItem(src, 'moneybag', 1, false, info, 'police:server:SeizeCash')
    TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items['moneybag'], 'add')
    TriggerClientEvent('QBCore:Notify', SearchedPlayer.PlayerData.source, Lang:t('info.cash_confiscated'))
end)

RegisterNetEvent('police:server:SeizeDriverLicense', function(playerId)
    local src = source
    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(playerId)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(playerCoords - targetCoords) > 2.5 then return DropPlayer(src, 'Attempted exploit abuse') end

    local SearchedPlayer = QBCore.Functions.GetPlayer(playerId)
    local Player = QBCore.Functions.GetPlayer(src)
    -- 吊销驾照是警察强制措施：只有拿到 arrest.create（在勤 + grade≥1）的警官能做
    if not Player or not SearchedPlayer or not PolicePolicy.Can(Player.PlayerData, 'arrest.create') then return end

    -- 🔄 委托给 custom-certificates 统一管理（含实体证件移除 + cert_status 同步）
    local success, msg = exports['custom-certificates']:RevokeLicense(playerId, 'driver')
    if success then
        TriggerClientEvent('QBCore:Notify', SearchedPlayer.PlayerData.source, Lang:t('info.driving_license_confiscated'))
    else
        TriggerClientEvent('QBCore:Notify', src, msg or Lang:t('error.no_driver_license'), 'error')
    end
end)

RegisterNetEvent('police:server:RobPlayer', function(playerId)
    local src = source
    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(playerId)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(playerCoords - targetCoords) > 2.5 then return DropPlayer(src, 'Attempted exploit abuse') end

    local Player = QBCore.Functions.GetPlayer(src)
    local SearchedPlayer = QBCore.Functions.GetPlayer(playerId)
    -- 搜身取现是警察动作。此前只校验了 2.5m 距离，任何玩家都能掏空身边玩家
    -- 的现金；现在要求 arrest.create（在勤 + grade≥1）。
    if not Player or not SearchedPlayer or not PolicePolicy.Can(Player.PlayerData, 'arrest.create') then return end

    local money = SearchedPlayer.PlayerData.money['cash']
    Player.Functions.AddMoney('cash', money, 'police-player-robbed')
    SearchedPlayer.Functions.RemoveMoney('cash', money, 'police-player-robbed')
    exports['qb-inventory']:OpenInventoryById(src, playerId)
    TriggerClientEvent('QBCore:Notify', SearchedPlayer.PlayerData.source, Lang:t('info.cash_robbed', { money = money }))
    TriggerClientEvent('QBCore:Notify', Player.PlayerData.source, Lang:t('info.stolen_money', { stolen = money }))
end)

--- 最近一次盘查（P3-3）：MDT 的逮捕表单可以一键带进来。
--- 按**警员**记，只存在内存里：盘查是当下的动作，不需要历史。
local lastInspection = {}

local function rememberInspection(officerCid, targetCid, patchTable)
    local record = lastInspection[officerCid] or { at = os.time() }
    record.citizenid = targetCid
    record.at = os.time()
    for k, v in pairs(patchTable or {}) do record[k] = v end
    lastInspection[officerCid] = record
end

--- 查证件（P3-1）：对准的那个人是谁、有没有驾照。
--- 只回公开资料 —— 钱包、背包、案底都不在这里（那些要立案/搜查的依据）。
QBCore.Functions.CreateCallback('police:server:showId', function(source, cb, targetSrc)
    local src = source
    local Officer = QBCore.Functions.GetPlayer(src)
    if not Officer or Officer.PlayerData.job.name ~= 'police' or Officer.PlayerData.job.onduty ~= true then
        cb({ ok = false, reason = 'off_duty' })
        return
    end
    local target = tonumber(targetSrc)
    local Target = target and QBCore.Functions.GetPlayer(target)
    if not Target then
        cb({ ok = false, reason = 'target_offline' })
        return
    end
    -- 服务端自己量距离：客户端说"我在他对面"不算
    local a, b = GetPlayerPed(src), GetPlayerPed(target)
    if not a or a == 0 or not b or b == 0 then
        cb({ ok = false, reason = 'target_offline' })
        return
    end
    local dist = #(GetEntityCoords(a) - GetEntityCoords(b))
    if dist > 3.5 then
        PoliceAudit.Write(Officer.PlayerData.citizenid, 'id.check', Target.PlayerData.citizenid,
            ('too_far dist=%.1f'):format(dist))
        cb({ ok = false, reason = 'too_far' })
        return
    end

    local info = Target.PlayerData.charinfo or {}
    PoliceAudit.Write(Officer.PlayerData.citizenid, 'id.check', Target.PlayerData.citizenid,
        ('dist=%.1f'):format(dist))
    local displayName = ('%s %s'):format(tostring(info.firstname or ''), tostring(info.lastname or ''))
    rememberInspection(Officer.PlayerData.citizenid, Target.PlayerData.citizenid, { name = displayName })
    cb({
        ok = true,
        name = displayName,
        citizenid = Target.PlayerData.citizenid,
        job = Target.PlayerData.job and Target.PlayerData.job.label or '无业',
        license = Target.PlayerData.metadata and Target.PlayerData.metadata.licences
            and Target.PlayerData.metadata.licences.driver == true or false,
    })
end)


--- 酒测 / 药检（P3-2）。
--- 距离、在岗、目标在线全在服务端判；读数来自 Sobriety（酒）或目标 metadata（药）。
QBCore.Functions.CreateCallback('police:server:fieldTest', function(source, cb, targetSrc, kind)
    local src = source
    local Officer = QBCore.Functions.GetPlayer(src)
    if not Officer or Officer.PlayerData.job.name ~= 'police' or Officer.PlayerData.job.onduty ~= true then
        cb({ ok = false, reason = 'off_duty' })
        return
    end
    kind = tostring(kind or '')
    if kind ~= 'alcohol' and kind ~= 'drug' then
        cb({ ok = false, reason = 'invalid_kind' })
        return
    end
    local target = tonumber(targetSrc)
    local Target = target and QBCore.Functions.GetPlayer(target)
    if not Target then cb({ ok = false, reason = 'target_offline' }); return end

    local a, b = GetPlayerPed(src), GetPlayerPed(target)
    if not a or a == 0 or not b or b == 0 then cb({ ok = false, reason = 'target_offline' }); return end
    local dist = #(GetEntityCoords(a) - GetEntityCoords(b))
    if dist > 3.5 then cb({ ok = false, reason = 'too_far' }); return end

    -- 每人每类 60 秒一次：连续点不会刷出一排读数
    local allowed = exports['core-framework']:RateLimitCooldown(
        ('police:test:%s:%s:%s'):format(Officer.PlayerData.citizenid, Target.PlayerData.citizenid, kind), 60000)
    if not allowed then cb({ ok = false, reason = 'cooldown' }); return end

    local value, label, source_note
    if kind == 'alcohol' then
        -- 优先读 custom-consumables（饥渴/酒精的唯一写者）；它不在时才回退本地 Sobriety
        local read = false
        if GetResourceState('custom-consumables') == 'started' then
            local ok, level = pcall(function()
                return exports['custom-consumables']:GetAlcohol(Target.PlayerData.citizenid)
            end)
            if ok and type(level) == 'number' then
                value = level
                read = true
            end
        end
        if not read then
            value = Sobriety and Sobriety.Level(Target.PlayerData.citizenid) or 0.0
        end
        label = Sobriety and Sobriety.Label(value) or 'sober'
        source_note = 'breath'
    else
        local meta = Target.PlayerData.metadata or {}
        value = tonumber(meta.drug_level) or 0.0
        label = value >= 0.5 and 'positive' or (value >= 0.2 and 'trace' or 'negative')
        source_note = 'swab'
    end

    -- 先落审计（无论能不能挂证据）。
    PoliceAudit.Write(Officer.PlayerData.citizenid,
        ('fieldtest.%s'):format(kind), Target.PlayerData.citizenid,
        ('%.2f %s'):format(value, label))
    rememberInspection(Officer.PlayerData.citizenid, Target.PlayerData.citizenid, {
        [kind] = { value = value, label = label },
    })

    -- 能挂到现场就挂：evidence 表要求必须挂 case/incident/report（insertEvidence 的
    -- missing_case），所以找"这名警员当前正在处理的、还没结的警情"。没有就只留审计，
    -- 等立案后由 MDT 带入（P3-3 的 GetLastInspection 就是干这个的）。
    local attached, exhibitNo = false, nil
    local activeIncident = MySQL.single.await([[
        SELECT u.incident_id AS id
          FROM police_incident_units u
          JOIN police_incidents i ON i.id = u.incident_id
         WHERE u.citizenid = ?
           AND i.status IN ('open','assigned','enroute','on_scene')
         ORDER BY u.joined_at DESC
         LIMIT 1
    ]], { Officer.PlayerData.citizenid })
    if activeIncident and activeIncident.id then
        local label = ('%s：%s %.2f（%s）'):format(
            kind == 'alcohol' and '酒测' or '药检',
            Target.PlayerData.citizenid, value, label)
        local ok, result = pcall(function()
            return exports['custom-police']:RegisterEvidence(source, {
                label = label:sub(1, 120),
                incident_id = tonumber(activeIncident.id),
                location = ('%.0f,%.0f'):format(GetEntityCoords(b).x, GetEntityCoords(b).y),
            })
        end)
        if ok and type(result) == 'table' then
            attached = true
            exhibitNo = result.exhibit_no
        end
    end

    cb({ ok = true, kind = kind, value = value, label = label, evidence = attached, exhibit_no = exhibitNo })
end)


--- 最近一次盘查（P3-3）。只回给在岗警察，内容就是"刚才盘过谁、读数多少"。
exports('GetLastInspection', function(source)
    local actor = QBCore.Functions.GetPlayer(source)
    local data = actor and actor.PlayerData
    local allowed, why = PolicePolicy.Can(data, 'incident.update')
    if not allowed then return false, why or 'off_duty' end
    -- 读的是"谁被盘过、读数多少"：属于敏感读取，审计写不进去就失败关闭
    if not audit(data.citizenid, 'inspection.view', 'last', nil) then
        return false, 'audit_unavailable'
    end
    local record = lastInspection[data.citizenid]
    if not record then return { empty = true } end
    return {
        citizenid = record.citizenid,
        name = record.name,
        alcohol = record.alcohol,
        drug = record.drug,
        at = record.at,
    }
end)
